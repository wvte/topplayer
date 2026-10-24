import Foundation

/// Downloads and imports a playlist (Xtream API when the link is one, otherwise the M3U file) into the database.
public final class Importer {
    public typealias Emit = (String, [String: Any]) -> Void
    public static let demoURL = "asset:demo.m3u"

    private let db: Db
    private let dbPath: String
    private let cacheDir: URL
    private let emit: Emit
    private let lock = NSLock()
    private var running = Set<Int64>()
    /// Where the bundled test playlist lives (set by the app).
    public var demoFile: URL?

    public init(db: Db, dbPath: String, cacheDir: URL, emit: @escaping Emit) {
        self.db = db
        self.dbPath = dbPath
        self.cacheDir = cacheDir
        self.emit = emit
    }

    public func isRunning(_ pid: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running.contains(pid)
    }

    private func progress(_ pid: Int64, _ phase: String, _ done: Int64, _ total: Int64, percent: Int? = nil) {
        var o: [String: Any] = ["pid": pid, "phase": phase, "done": done, "total": total]
        if let p = percent { o["percent"] = p }
        emit("import.progress", o)
    }

    /// Blocking: call from a background queue. Always ends with an import.done event.
    public func refresh(_ pid: Int64) {
        lock.lock()
        if !running.insert(pid).inserted { lock.unlock(); return }
        lock.unlock()
        let started = Date()
        var done: [String: Any] = ["pid": pid]
        func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
        do {
            guard let pl = try db.playlist(pid) else { throw DbError(message: "Playlist not found") }
            let url = pl["url"] as? String ?? ""
            let ua = pl["ua"] as? String
            var counts: [Int]?
            var source = "m3u"
            var downloaded = started
            var timing = (parse: 0, index: 0)

            let xtream = (url.hasPrefix("local:") || url.hasPrefix("asset:")) ? nil : XtreamAccount.parse(url)
            if let a = xtream, (pl["xt_api"] as? Int64 ?? 1) != 0 {
                var files: XtreamImporter.Files?
                do {
                    progress(pid, "download", 0, 0)
                    files = try XtreamImporter.download(a, ua: ua, dir: cacheDir, pid: pid) { [self] d in progress(pid, "download", d, 0) }
                    downloaded = Date()
                    progress(pid, "parse", 0, 0)
                    let f = files!
                    let r = try importInto(pid: pid, source: "xtream") { core, headerEpg, sink, pct in
                        try XtreamImporter.feed(f, a, core, progress: { d, t in pct(Int(min(99, d * 100 / max(1, t)))) }, emit: sink)
                    }
                    counts = r.counts
                    timing = (r.parseMs, r.indexMs)
                    source = "xtream"
                } catch {
                    counts = nil
                    done["api_error"] = (error as? DbError)?.message ?? error.localizedDescription
                }
                files?.delete()
            }

            if counts == nil {
                let file = cacheDir.appendingPathComponent("playlist_\(pid).m3u")
                if url.hasPrefix("asset:") {
                    guard let demo = demoFile else { throw DbError(message: "Test playlist missing") }
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.copyItem(at: demo, to: file)
                } else {
                    progress(pid, "download", 0, 0)
                    try Net.download(url, ua: ua, to: file) { [self] d, t in progress(pid, "download", d, max(0, t)) }
                }
                downloaded = Date()
                progress(pid, "parse", 0, 0)
                let size = max(1, (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 1)
                let r = try importInto(pid: pid, source: "m3u") { core, headerEpg, sink, pct in
                    let reader = try LineReader(url: file)
                    var n = 0
                    M3uParser.parse(nextLine: { reader.nextLine() }, onHeader: { h in
                        for k in ["url-tvg", "x-tvg-url", "tvg-url"] where !(h[k] ?? "").isEmpty { headerEpg.pointee = h[k]!; break }
                    }, onEntry: { e in
                        n += 1
                        if n % 2500 == 0 { pct(Int(min(99, reader.bytesRead * 100 / size))) }
                        return sink(core.build(e))
                    })
                }
                counts = r.counts
                timing = (r.parseMs, r.indexMs)
            }
            let c = counts!
            done["source"] = source
            done["ms_download"] = ms(started, downloaded)
            done["ms_parse"] = timing.parse
            done["ms_index"] = timing.index
            done["ms_total"] = ms(started, Date())
            done["ok"] = true
            done["live"] = c[0]; done["movie"] = c[1]; done["series"] = c[2]; done["episodes"] = c[3]
        } catch {
            let msg = (error as? DbError)?.message ?? error.localizedDescription
            done["ok"] = false
            done["error"] = msg
            _ = try? db.conn.run("UPDATE playlists SET status=? WHERE id=?", ["error: " + msg, pid])
        }
        lock.lock(); running.remove(pid); lock.unlock()
        emit("import.done", done)
    }

    private final class Store: ImportStore {
        let pid: Int64
        let live, movie, series, ep: Connection.Statement

        init(pid: Int64, _ c: Connection) throws {
            self.pid = pid
            live = try c.prepare("INSERT INTO live(pid,k,num,name,sname,logo,grp,url,epg,ua,ref,ord) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)")
            movie = try c.prepare("INSERT INTO movie(pid,k,name,sname,year,logo,grp,url,ua,ref,ord) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
            series = try c.prepare("INSERT INTO series(pid,k,name,sname,logo,grp,ord,xt_id) VALUES(?,?,?,?,?,?,?,?)")
            ep = try c.prepare("INSERT INTO episode(pid,series_id,k,season,ep,name,url,logo,ua,ref,ord) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
        }

        private func opt(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

        func insertLive(_ r: ImportRow) {
            _ = try? live.insert([pid, r.key, r.num, r.name, r.sname, r.logo, r.grp, r.url, r.epgKey, opt(r.ua), opt(r.ref), r.ord])
        }
        func insertMovie(_ r: ImportRow) {
            _ = try? movie.insert([pid, r.key, r.name, r.sname, r.year, r.logo, r.grp, r.url, opt(r.ua), opt(r.ref), r.ord])
        }
        func insertSeries(_ r: ImportRow) -> Int64 {
            (try? series.insert([pid, r.seriesKey, r.seriesName, r.seriesNorm ?? "", r.logo, r.grp, r.ord, r.xtId])) ?? 0
        }
        func insertEpisode(_ r: ImportRow, seriesId: Int64, key: String, episode: Int, title: String) {
            _ = try? ep.insert([pid, seriesId, key, r.season, episode, title, r.url, r.logo, opt(r.ua), opt(r.ref), r.ord])
        }
    }

    struct Result { var counts: [Int]; var parseMs: Int; var indexMs: Int }

    /// feeder reads the rows and calls sink for each; sink returns false to stop. pct reports the progress in percent.
    private func importInto(pid: Int64, source: String,
                            feeder: (ImportCore, UnsafeMutablePointer<String>, (ImportRow) -> Bool, (Int) -> Void) throws -> Void) throws -> Result {
        let c = try Connection(path: dbPath)
        let parseStart = Date()
        var counts = [0, 0, 0, 0]
        var parseMs = 0, indexMs = 0
        var headerEpg = ""
        try c.transaction {
            // Without the indexes the inserts are about 3x faster; they are built again at the end, in the same transaction.
            try db.dropContentIndexes(c)
            for t in ["live", "movie", "series", "episode", "grp"] { try c.run("DELETE FROM \(t) WHERE pid=?", [pid]) }
            let core = ImportCore()
            let store = try Store(pid: pid, c)
            var lastPct = 0
            try withUnsafeMutablePointer(to: &headerEpg) { hp in
                try feeder(core, hp, { row in
                    core.consume(row, store)
                    if row.ord % 2500 == 0 && row.ord > 0 { self.progress(pid, "parse", Int64(row.ord), 0, percent: lastPct) }
                    return true
                }, { lastPct = $0 })
            }
            counts = core.counts
            for (id, n) in core.seriesEpisodes {
                try c.run("UPDATE series SET n_eps=?, n_seasons=?, logo=CASE WHEN logo='' THEN ? ELSE logo END WHERE id=?",
                          [n, core.seriesSeasons[id]?.count ?? 0, core.seriesLogo[id] ?? "", id])
            }
            for g in core.groups { try c.run("INSERT INTO grp(pid,kind,name,ord,n) VALUES(?,?,?,?,?)", [pid, g.kind, g.name, g.firstOrd, g.count]) }
            try c.run("UPDATE playlists SET n_live=?, n_movie=?, n_series=?, last_refresh=?, header_epg=?, status='ok', source=? WHERE id=?",
                      [counts[0], counts[1], counts[2], Db.nowMs(), headerEpg, source, pid])
            if counts.reduce(0, +) == 0 { throw DbError(message: "No channels found in playlist") }
            let indexStart = Date()
            progress(pid, "index", 0, 0)
            try db.createContentIndexes(c)
            parseMs = Int(indexStart.timeIntervalSince(parseStart) * 1000)
            indexMs = Int(Date().timeIntervalSince(indexStart) * 1000)
        }
        return Result(counts: counts, parseMs: parseMs, indexMs: indexMs)
    }
}
