import Foundation

/// An Xtream Codes account found in a playlist link such as http://host:port/get.php?username=U&password=P&type=m3u&output=ts
public struct XtreamAccount {
    public let base: String
    public let user: String
    public let pass: String
    public let liveExt: String

    public static func parse(_ url: String?) -> XtreamAccount? {
        guard let u = url?.trimmed, let sr = u.range(of: "://"), sr.lowerBound != u.startIndex else { return nil }
        let schemePart = String(u[..<sr.upperBound])
        var rest = String(u[sr.upperBound...])
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var authority = rest
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[slash...])
        }
        guard path.hasSuffix("/get.php") || path.hasSuffix("/player_api.php") else { return nil }
        func param(_ name: String) -> String? {
            for kv in query.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.first.map(String.init) == name { return parts.count > 1 ? Text.urlDecode(String(parts[1])) : "" }
            }
            return nil
        }
        guard let user = param("username"), let pass = param("password"), !user.isEmpty else { return nil }
        let prefix = String(path[..<path.lastIndex(of: "/")!])
        let out = param("output")?.lowercased()
        let ext = (out == "m3u8" || out == "hls") ? "m3u8" : "ts"
        return XtreamAccount(base: schemePart + authority + prefix, user: user, pass: pass, liveExt: ext)
    }

    public func api(_ action: String?) -> String {
        base + "/player_api.php?username=" + Text.enc(user) + "&password=" + Text.enc(pass) + (action.map { "&action=" + $0 } ?? "")
    }
    public func xmltv() -> String { base + "/xmltv.php?username=" + Text.enc(user) + "&password=" + Text.enc(pass) }
    public func liveUrl(_ id: String) -> String { base + "/live/" + Text.enc(user) + "/" + Text.enc(pass) + "/" + id + "." + liveExt }
    public func movieUrl(_ id: String, _ ext: String) -> String { base + "/movie/" + Text.enc(user) + "/" + Text.enc(pass) + "/" + id + "." + ext }
    public func seriesUrl(_ id: String, _ ext: String) -> String { base + "/series/" + Text.enc(user) + "/" + Text.enc(pass) + "/" + id + "." + ext }
}

/// Reads a big JSON array of objects element by element, so a 50 MB answer never sits in memory as a whole.
public final class JsonArrayStream {
    private let handle: FileHandle
    public private(set) var bytesRead: Int64 = 0

    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    /// Calls body with every element (as a dictionary); body returns false to stop.
    public func forEachObject(_ body: ([String: Any]) -> Bool) throws {
        var depth = 0
        var inString = false
        var escape = false
        var current = Data()
        var started = false
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            for b in chunk {
                if inString {
                    if started { current.append(b) }
                    if escape { escape = false } else if b == 0x5C { escape = true } else if b == 0x22 { inString = false }
                    continue
                }
                switch b {
                case 0x22:
                    inString = true
                    if started { current.append(b) }
                case 0x5B: // [
                    depth += 1
                    if started { current.append(b) }
                case 0x7B: // {
                    depth += 1
                    if depth == 2 { started = true; current = Data() }
                    if started { current.append(b) }
                case 0x7D, 0x5D: // } ]
                    if started { current.append(b) }
                    depth -= 1
                    if b == 0x7D && started && depth == 1 {
                        started = false
                        if let o = try? JSONSerialization.jsonObject(with: current), let d = o as? [String: Any] {
                            if !body(d) { return }
                        }
                        current = Data()
                    }
                default:
                    if started { current.append(b) }
                }
            }
        }
    }
}

enum XtreamJSON {
    /// A value as text (the panels send numbers and strings mixed).
    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s.trimmed) { return i }
        return 0
    }
}

public enum XtreamImporter {
    public struct Files {
        let liveCats, vodCats, seriesCats, live, vod, series: URL

        init(dir: URL, pid: Int64) {
            let p = "xt_\(pid)_"
            liveCats = dir.appendingPathComponent(p + "live_categories.json")
            vodCats = dir.appendingPathComponent(p + "vod_categories.json")
            seriesCats = dir.appendingPathComponent(p + "series_categories.json")
            live = dir.appendingPathComponent(p + "live_streams.json")
            vod = dir.appendingPathComponent(p + "vod_streams.json")
            series = dir.appendingPathComponent(p + "series.json")
        }

        var all: [URL] { [liveCats, vodCats, seriesCats, live, vod, series] }
        func delete() { for f in all { try? FileManager.default.removeItem(at: f) } }
    }

    /// Checks the account and downloads everything. progress gets the bytes so far over all files.
    public static func download(_ a: XtreamAccount, ua: String?, dir: URL, pid: Int64, progress: ((Int64) -> Void)?) throws -> Files {
        try checkAccount(a, ua: ua)
        let f = Files(dir: dir, pid: pid)
        do {
            let actions = ["get_live_categories", "get_vod_categories", "get_series_categories", "get_live_streams", "get_vod_streams", "get_series"]
            var before: Int64 = 0
            for (i, file) in f.all.enumerated() {
                let offset = before
                try Net.download(a.api(actions[i]), ua: ua, to: file) { d, _ in progress?(offset + d) }
                before += (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                try requireJsonArray(file, actions[i])
            }
        } catch {
            f.delete()
            throw error
        }
        return f
    }

    static func checkAccount(_ a: XtreamAccount, ua: String?) throws {
        let data = try Net.getData(a.api(nil), ua: ua)
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw DbError(message: "Xtream API: unexpected answer") }
        guard let user = r["user_info"] as? [String: Any] else { throw DbError(message: "Xtream API: no account information") }
        let auth = XtreamJSON.str(user["auth"]) ?? "1"
        if auth == "0" || auth.lowercased() == "false" {
            throw DbError(message: "Xtream API: login refused (\(XtreamJSON.str(user["message"]) ?? "auth 0"))")
        }
        let status = XtreamJSON.str(user["status"]) ?? "Active"
        if !status.isEmpty && status.lowercased() != "active" { throw DbError(message: "Xtream API: account \(status)") }
    }

    /// A panel that does not know an action may answer with an object or a web page instead of a list.
    static func requireJsonArray(_ f: URL, _ action: String) throws {
        let h = try FileHandle(forReadingFrom: f)
        defer { try? h.close() }
        let head = h.readData(ofLength: 64)
        for c in head {
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xEF || c == 0xBB || c == 0xBF { continue }
            if c == 0x5B { return }
            throw DbError(message: "Xtream API: \(action) did not return a list")
        }
        throw DbError(message: "Xtream API: \(action) was empty")
    }

    static func categories(_ f: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        try JsonArrayStream(url: f).forEachObject { o in
            if let id = XtreamJSON.str(o["category_id"]), let name = XtreamJSON.str(o["category_name"]) { out[id] = name.trimmed }
            return true
        }
        return out
    }

    private static func ext(_ e: String?, _ fallback: String) -> String {
        guard let t = e?.trimmed.lowercased(), t.range(of: "^[a-z0-9]{2,5}$", options: .regularExpression) != nil else { return fallback }
        return t
    }

    /// Reads the downloaded lists into rows, in the order live, films, series. emit returns false to stop.
    public static func feed(_ f: Files, _ a: XtreamAccount, _ core: ImportCore, progress: (Int64, Int64) -> Void, emit: (ImportRow) -> Bool) throws {
        func size(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }
        let total = max(1, size(f.live) + size(f.vod) + size(f.series))
        var done: Int64 = 0
        let latest = Calendar.current.component(.year, from: Date()) + 1

        let liveCats = try categories(f.liveCats)
        let ls = try JsonArrayStream(url: f.live)
        var go = true
        try ls.forEachObject { o in
            progress(done + ls.bytesRead, total)
            guard let name = XtreamJSON.str(o["name"])?.trimmed, !name.isEmpty, let id = XtreamJSON.str(o["stream_id"])?.trimmed, !id.isEmpty else { return true }
            let grp = XtreamJSON.str(o["category_id"]).flatMap { liveCats[$0] } ?? ""
            go = emit(core.buildLive(name: name, logo: XtreamJSON.str(o["stream_icon"]), grp: grp, url: a.liveUrl(id), epgId: XtreamJSON.str(o["epg_channel_id"])))
            return go
        }
        if !go { return }
        done += size(f.live)

        let vodCats = try categories(f.vodCats)
        let vs = try JsonArrayStream(url: f.vod)
        try vs.forEachObject { o in
            progress(done + vs.bytesRead, total)
            guard let name = XtreamJSON.str(o["name"])?.trimmed, !name.isEmpty, let id = XtreamJSON.str(o["stream_id"])?.trimmed, !id.isEmpty else { return true }
            var y = 0
            if let ys = XtreamJSON.str(o["year"])?.trimmed, ys.range(of: "^(19|20)\\d\\d$", options: .regularExpression) != nil { y = Int(ys) ?? 0 }
            if y == 0 || y > latest { y = Classifier.extractYear(name) }
            let grp = XtreamJSON.str(o["category_id"]).flatMap { vodCats[$0] } ?? ""
            go = emit(core.buildMovie(name: name, logo: XtreamJSON.str(o["stream_icon"]), grp: grp, url: a.movieUrl(id, ext(XtreamJSON.str(o["container_extension"]), "mp4")), year: y))
            return go
        }
        if !go { return }
        done += size(f.vod)

        let seriesCats = try categories(f.seriesCats)
        let ss = try JsonArrayStream(url: f.series)
        try ss.forEachObject { o in
            progress(done + ss.bytesRead, total)
            guard let name = XtreamJSON.str(o["name"])?.trimmed, !name.isEmpty, let id = XtreamJSON.str(o["series_id"])?.trimmed, let xt = Int64(id) else { return true }
            let grp = XtreamJSON.str(o["category_id"]).flatMap { seriesCats[$0] } ?? ""
            go = emit(core.buildSeriesXt(name: name, logo: XtreamJSON.str(o["cover"]), grp: grp, xtId: xt))
            return go
        }
    }

    // MARK: one series (get_series_info)

    public struct Episode { public var season = 0, number = 0; public var name = "", url = "", logo = "" }

    public static func parseSeriesInfo(_ r: [String: Any], _ a: XtreamAccount) -> (episodes: [Episode], details: [String: Any]) {
        var eps: [Episode] = []
        var details: [String: Any] = [:]
        let info = r["info"] as? [String: Any]
        func copy(_ from: [String: Any]?, _ to: inout [String: Any], _ key: String, _ alt: String? = nil) {
            guard let from = from else { return }
            var v: Any? = from[key]
            if (v == nil || (v as? String) == "" || v is NSNull), let alt = alt { v = from[alt] }
            if let v = v, !(v is NSNull), !String(describing: v).trimmed.isEmpty { to[key] = v }
        }
        for k in ["plot", "cast", "director", "genre"] { copy(info, &details, k) }
        copy(info, &details, "releaseDate", "release_date")
        for k in ["rating", "cover"] { copy(info, &details, k) }
        if let bd = info?["backdrop_path"] as? [Any], let first = bd.first { details["backdrop"] = XtreamJSON.str(first) ?? "" }
        var perEpisode: [String: Any] = [:]
        var seen = Set<String>()

        func add(_ arr: [Any]?, _ seasonFromKey: Int) {
            guard let arr = arr else { return }
            for (i, item) in arr.enumerated() {
                guard let e = item as? [String: Any] else { continue }
                let id = (XtreamJSON.str(e["id"]) ?? "").trimmed
                if id.isEmpty || id == "null" { continue }
                let season = e["season"] != nil ? XtreamJSON.int(e["season"]) : seasonFromKey
                var number = XtreamJSON.int(e["episode_num"])
                if number <= 0 { number = i + 1 }
                if !seen.insert("\(season)|\(number)").inserted { continue }
                let ei = e["info"] as? [String: Any]
                var ep = Episode()
                ep.season = season
                ep.number = number
                ep.name = XtreamJSON.str(e["title"]) ?? ""
                ep.url = a.seriesUrl(id, ext(XtreamJSON.str(e["container_extension"]), "mp4"))
                ep.logo = XtreamJSON.str(ei?["movie_image"]) ?? ""
                eps.append(ep)
                var o: [String: Any] = ["title": ep.name]
                for k in ["plot", "duration", "duration_secs", "movie_image", "rating"] { copy(ei, &o, k) }
                perEpisode["\(season)|\(number)"] = o
            }
        }
        if let em = r["episodes"] as? [String: Any] {
            for (key, value) in em { add(value as? [Any], Int(key.trimmed) ?? 0) }
        } else if let ea = r["episodes"] as? [Any] {
            for item in ea { add(item as? [Any], 0) }
        }
        details["episodes"] = perEpisode
        return (eps, details)
    }
}

/// Extras for Xtream playlists: film info, episodes of a series on demand.
public final class XtreamExtras {
    private let db: Db
    private let lock = NSLock()
    private static let day: Double = 24 * 3600 * 1000

    public init(db: Db) { self.db = db }

    private func cached(_ key: String, maxAge: Double) -> [String: Any]? {
        guard let v = db.kvGet(key), let o = (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any] else { return nil }
        if Double(Db.nowMs()) - (o["_at"] as? NSNumber ?? 0).doubleValue > maxAge { return nil }
        return o
    }

    private func store(_ key: String, _ o: [String: Any]) {
        var o = o
        o["_at"] = Db.nowMs()
        if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { db.kvSet(key, s) }
    }

    private static func copy(_ from: [String: Any], _ to: inout [String: Any], _ key: String, _ alt: String? = nil) {
        var v: Any? = from[key]
        if (v == nil || (v as? String) == "" || v is NSNull), let alt = alt { v = from[alt] }
        if let v = v, !(v is NSNull), !String(describing: v).trimmed.isEmpty { to[key] = v }
    }

    public func movieInfo(_ key: String) throws -> [String: Any]? {
        guard let m = try db.movie(key), let x = XtreamAccount.parse(m["purl"] as? String) else { return nil }
        let url = m["url"] as? String ?? ""
        guard let r = url.range(of: "/movie/[^/]+/[^/]+/(\\d+)", options: .regularExpression) else { return nil }
        let id = String(url[r].split(separator: "/").last ?? "")
        let cacheKey = "xt:m:\(m["pid"] as? Int64 ?? 0):\(id)"
        if let c = cached(cacheKey, maxAge: 7 * Self.day) { return c }
        let json = try Net.getData(x.api("get_vod_info") + "&vod_id=" + id, ua: m["pua"] as? String)
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], let info = root["info"] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        Self.copy(info, &out, "plot", "description")
        Self.copy(info, &out, "cast", "actors")
        Self.copy(info, &out, "director")
        Self.copy(info, &out, "genre")
        Self.copy(info, &out, "releasedate", "release_date")
        for k in ["duration", "duration_secs", "rating", "country"] { Self.copy(info, &out, k) }
        Self.copy(info, &out, "movie_image", "cover_big")
        if let bd = info["backdrop_path"] as? [Any], let first = bd.first { out["backdrop"] = XtreamJSON.str(first) ?? "" }
        store(cacheKey, out)
        return out
    }

    private static let seriesRow = "SELECT series.id, series.k, series.name, series.pid, series.xt_id, series.xt_sync, playlists.url AS purl, playlists.ua AS pua FROM series JOIN playlists ON playlists.id=series.pid WHERE series.k=? AND playlists.enabled=1 ORDER BY series.pid, series.ord LIMIT 1"

    private func needsEpisodes(_ s: Row) -> Bool {
        let have = db.conn.scalar("SELECT COUNT(*) FROM episode WHERE series_id=?", [s["id"] as? Int64 ?? 0]) > 0
        return !have || Double(Db.nowMs()) - Double(s["xt_sync"] as? Int64 ?? 0) > 12 * 3600 * 1000
    }

    /// A series from the Xtream API is just a name until it is opened: fetch its episodes the first time and every 12 hours.
    public func ensureEpisodes(_ key: String) throws {
        guard var s = try db.conn.one(Self.seriesRow, [key]), (s["xt_id"] as? Int64 ?? 0) > 0, needsEpisodes(s) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let again = try db.conn.one(Self.seriesRow, [key]), needsEpisodes(again) else { return }
        s = again
        let have = db.conn.scalar("SELECT COUNT(*) FROM episode WHERE series_id=?", [s["id"] as? Int64 ?? 0]) > 0
        do { try fetchEpisodes(s) } catch { if !have { throw error } }
    }

    private func fetchEpisodes(_ s: Row) throws {
        guard let a = XtreamAccount.parse(s["purl"] as? String) else { return }
        let id = s["id"] as? Int64 ?? 0
        let data = try Net.getData(a.api("get_series_info") + "&series_id=\(s["xt_id"] as? Int64 ?? 0)", ua: s["pua"] as? String)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw DbError(message: "Xtream API: unexpected answer") }
        let parsed = XtreamImporter.parseSeriesInfo(root, a)
        if parsed.episodes.isEmpty { return }
        let key = s["k"] as? String ?? ""
        let base = key.hasPrefix("S|") ? String(key.dropFirst(2)) : key
        try db.conn.transaction {
            try db.conn.run("DELETE FROM episode WHERE series_id=?", [id])
            var seasons = Set<Int>()
            for (ord, e) in parsed.episodes.enumerated() {
                try db.conn.run("INSERT INTO episode(pid,series_id,k,season,ep,name,url,logo,ua,ref,ord) VALUES(?,?,?,?,?,?,?,?,NULL,NULL,?)",
                                [s["pid"] as? Int64 ?? 0, id, "E|\(base)|\(e.season)|\(e.number)", e.season, e.number, e.name, e.url, e.logo, ord])
                seasons.insert(e.season)
            }
            try db.conn.run("UPDATE series SET n_eps=?, n_seasons=?, xt_sync=? WHERE id=?", [parsed.episodes.count, seasons.count, Db.nowMs(), id])
        }
        store("xt:s:\(s["pid"] as? Int64 ?? 0):\(key)", parsed.details)
    }

    public func seriesInfo(_ key: String) throws -> [String: Any]? {
        guard let s = try db.conn.one("SELECT series.name, series.pid, series.xt_id, playlists.url AS purl, playlists.ua AS pua FROM series JOIN playlists ON playlists.id=series.pid WHERE series.k=? ORDER BY series.pid LIMIT 1", [key]),
              XtreamAccount.parse(s["purl"] as? String) != nil else { return nil }
        // Only series that came from the API have an id; the guess-by-name fallback of the Android app is not needed here.
        if (s["xt_id"] as? Int64 ?? 0) > 0 {
            try? ensureEpisodes(key)
            return cached("xt:s:\(s["pid"] as? Int64 ?? 0):\(key)", maxAge: 7 * Self.day)
        }
        return nil
    }
}
