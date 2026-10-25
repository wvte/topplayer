import Foundation

/// All persistent data: playlists, imported content, favourites, progress, recents and EPG.
/// Same schema and queries as the Android app (schema version 3), so backups and the UI behave the same.
public final class Db {
    public static let version = 3
    public let conn: Connection
    public let path: String

    public init(path: String) throws {
        self.path = path
        conn = try Connection(path: path)
        try migrate()
    }

    // MARK: schema

    private func migrate() throws {
        let v = Int(conn.scalar("PRAGMA user_version"))
        if v == 0 {
            try create()
        } else if v < Db.version {
            if v < 2 { try indexesV2() }
            if v < 3 {
                try conn.exec("ALTER TABLE series ADD COLUMN xt_id INTEGER DEFAULT 0")
                try conn.exec("ALTER TABLE series ADD COLUMN xt_sync INTEGER DEFAULT 0")
                try conn.exec("ALTER TABLE playlists ADD COLUMN xt_api INTEGER DEFAULT 1")
                try conn.exec("ALTER TABLE playlists ADD COLUMN source TEXT")
            }
        }
        try conn.exec("PRAGMA user_version=\(Db.version)")
    }

    private func create() throws {
        let statements = [
            "CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, url TEXT, ua TEXT, epg_url TEXT, auto_hours INTEGER DEFAULT 24, last_refresh INTEGER DEFAULT 0, enabled INTEGER DEFAULT 1, n_live INTEGER DEFAULT 0, n_movie INTEGER DEFAULT 0, n_series INTEGER DEFAULT 0, header_epg TEXT, status TEXT, sort INTEGER DEFAULT 0, xt_api INTEGER DEFAULT 1, source TEXT)",
            "CREATE TABLE live(id INTEGER PRIMARY KEY, pid INTEGER, k TEXT, num INTEGER, name TEXT, sname TEXT, logo TEXT, grp TEXT, url TEXT, epg TEXT, ua TEXT, ref TEXT, ord INTEGER)",
            "CREATE TABLE movie(id INTEGER PRIMARY KEY, pid INTEGER, k TEXT, name TEXT, sname TEXT, year INTEGER, logo TEXT, grp TEXT, url TEXT, ua TEXT, ref TEXT, ord INTEGER)",
            "CREATE TABLE series(id INTEGER PRIMARY KEY, pid INTEGER, k TEXT, name TEXT, sname TEXT, logo TEXT, grp TEXT, ord INTEGER, n_eps INTEGER DEFAULT 0, n_seasons INTEGER DEFAULT 0, xt_id INTEGER DEFAULT 0, xt_sync INTEGER DEFAULT 0)",
            "CREATE TABLE episode(id INTEGER PRIMARY KEY, pid INTEGER, series_id INTEGER, k TEXT, season INTEGER, ep INTEGER, name TEXT, url TEXT, logo TEXT, ua TEXT, ref TEXT, ord INTEGER)",
            "CREATE TABLE grp(pid INTEGER, kind TEXT, name TEXT, ord INTEGER, n INTEGER)",
            "CREATE INDEX grp_kind ON grp(kind)",
            "CREATE TABLE grp_pref(kind TEXT, name TEXT, hidden INTEGER DEFAULT 0, locked INTEGER DEFAULT 0, ord INTEGER, PRIMARY KEY(kind, name))",
            "CREATE TABLE fav(kind TEXT, k TEXT, title TEXT, logo TEXT, added INTEGER, ord INTEGER, PRIMARY KEY(kind, k))",
            "CREATE TABLE progress(k TEXT PRIMARY KEY, kind TEXT, title TEXT, sub TEXT, logo TEXT, series_k TEXT, season INTEGER, ep INTEGER, pos INTEGER, dur INTEGER, updated INTEGER, done INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0)",
            "CREATE INDEX progress_series ON progress(series_k)",
            "CREATE TABLE recent(k TEXT PRIMARY KEY, title TEXT, logo TEXT, at INTEGER)",
            "CREATE TABLE epg(chan TEXT, start INTEGER, stop INTEGER, title TEXT, descr TEXT)",
            "CREATE INDEX epg_cs ON epg(chan, start)",
            "CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)",
        ]
        try conn.transaction {
            for s in statements { try conn.exec(s) }
            try createContentIndexes(conn)
        }
    }

    private func indexesV2() throws {
        for t in ["live", "movie", "series"] {
            try conn.exec("DROP INDEX IF EXISTS \(t)_pid")
            try conn.exec("DROP INDEX IF EXISTS \(t)_grp")
        }
        try createContentIndexes(conn)
    }

    /// Secondary indexes of the big tables. An import drops them, inserts everything and builds them again.
    static let contentIndexes: [(String, String)] = [
        ("live_k", "live(k)"), ("live_pid_ord", "live(pid, ord)"), ("live_grp_ord", "live(grp, pid, ord)"),
        ("movie_k", "movie(k)"), ("movie_pid_ord", "movie(pid, ord)"), ("movie_grp_ord", "movie(grp, pid, ord)"),
        ("movie_sname", "movie(sname COLLATE NOCASE)"), ("movie_year", "movie(year DESC, ord)"),
        ("series_k", "series(k)"), ("series_pid_ord", "series(pid, ord)"), ("series_grp_ord", "series(grp, pid, ord)"),
        ("series_sname", "series(sname COLLATE NOCASE)"),
        ("episode_series", "episode(series_id, season, ep)"), ("episode_k", "episode(k)"), ("episode_pid", "episode(pid)"),
    ]

    func dropContentIndexes(_ c: Connection) throws { for ix in Db.contentIndexes { try c.exec("DROP INDEX IF EXISTS \(ix.0)") } }
    func createContentIndexes(_ c: Connection) throws { for ix in Db.contentIndexes { try c.exec("CREATE INDEX IF NOT EXISTS \(ix.0) ON \(ix.1)") } }

    // MARK: helpers

    private func ua(_ t: String) -> String {
        "COALESCE(NULLIF(\(t).ua,''),(SELECT ua FROM playlists WHERE playlists.id=\(t).pid)) AS ua"
    }

    private var uaLive: String { ua("live") }

    /// Hides content from hidden (and, unless unlocked, locked) groups and disabled playlists.
    private func visible(_ table: String, _ kind: String, _ unlocked: Bool, sortIndex: Bool = false) -> String {
        let lockCond = unlocked ? "hidden=1" : "(hidden=1 OR locked=1)"
        var w = " " + (sortIndex ? "+" : "") + table + ".pid IN (SELECT id FROM playlists WHERE enabled=1) "
        if conn.scalar("SELECT COUNT(*) FROM grp_pref WHERE kind=? AND " + lockCond, [kind]) > 0 {
            w += "AND \(table).grp NOT IN (SELECT name FROM grp_pref WHERE kind='\(kind)' AND \(lockCond)) "
        }
        return w
    }

    private func indexedSort(_ group: String, _ sort: String) -> Bool {
        group.isEmpty && ["az", "za", "year", "new"].contains(sort)
    }

    private func orderBy(_ table: String, _ sort: String) -> String {
        switch sort {
        case "az": return " ORDER BY \(table).sname COLLATE NOCASE ASC"
        case "za": return " ORDER BY \(table).sname COLLATE NOCASE DESC"
        case "num": return " ORDER BY CASE WHEN \(table).num>0 THEN 0 ELSE 1 END, \(table).num, \(table).ord"
        case "year": return " ORDER BY \(table).year DESC, \(table).ord"
        case "new": return " ORDER BY \(table).id DESC"
        default: return " ORDER BY \(table).pid, \(table).ord"
        }
    }

    public func kvGet(_ k: String) -> String? { (try? conn.one("SELECT v FROM kv WHERE k=?", [k]))??["v"] as? String }
    public func kvSet(_ k: String, _ v: String) { _ = try? conn.run("INSERT OR REPLACE INTO kv(k,v) VALUES(?,?)", [k, v]) }

    // MARK: playlists

    public func playlists() throws -> [Row] { try conn.query("SELECT * FROM playlists ORDER BY sort, id") }
    public func playlist(_ id: Int64) throws -> Row? { try conn.one("SELECT * FROM playlists WHERE id=?", [id]) }

    public func addPlaylist(name: String, url: String, ua: String, epgUrl: String, autoHours: Int) throws -> Int64 {
        let sort = conn.scalar("SELECT COALESCE(MAX(sort),0)+1 FROM playlists")
        try conn.run("INSERT INTO playlists(name,url,ua,epg_url,auto_hours,status,sort) VALUES(?,?,?,?,?,?,?)",
                     [name, url.trimmed, ua, epgUrl, autoHours, "new", sort])
        return conn.lastInsertId
    }

    public func updatePlaylist(_ id: Int64, _ p: [String: Any]) throws {
        var sets: [String] = []
        var args: [Any?] = []
        for s in ["name", "url", "ua", "epg_url"] { if let v = p[s] as? String { sets.append(s + "=?"); args.append(v) } }
        if let v = p["auto_hours"] as? NSNumber { sets.append("auto_hours=?"); args.append(v.intValue) }
        if let v = p["enabled"] as? NSNumber { sets.append("enabled=?"); args.append(v.boolValue ? 1 : 0) }
        if let v = p["xt_api"] as? NSNumber { sets.append("xt_api=?"); args.append(v.boolValue ? 1 : 0) }
        if sets.isEmpty { return }
        args.append(id)
        try conn.run("UPDATE playlists SET " + sets.joined(separator: ",") + " WHERE id=?", args)
    }

    public func deletePlaylist(_ id: Int64) throws {
        try conn.transaction {
            for t in ["live", "movie", "series", "episode", "grp"] { try conn.run("DELETE FROM \(t) WHERE pid=?", [id]) }
            try conn.run("DELETE FROM playlists WHERE id=?", [id])
        }
    }

    // MARK: groups

    public func groups(kind: String, includeHidden: Bool) throws -> [Row] {
        try conn.query("SELECT g.name AS name, SUM(g.n) AS n, MIN(g.ord) AS o, COALESCE(p.hidden,0) AS hidden,"
            + " COALESCE(p.locked,0) AS locked, p.ord AS pord FROM grp g"
            + " LEFT JOIN grp_pref p ON p.kind=g.kind AND p.name=g.name"
            + " WHERE g.kind=? AND g.pid IN (SELECT id FROM playlists WHERE enabled=1)"
            + (includeHidden ? "" : " AND COALESCE(p.hidden,0)=0")
            + " GROUP BY g.name ORDER BY CASE WHEN p.ord IS NULL THEN 1 ELSE 0 END, p.ord, o", [kind])
    }

    public func setGroupPref(kind: String, name: String, _ p: [String: Any]) throws {
        try conn.run("INSERT OR IGNORE INTO grp_pref(kind,name) VALUES(?,?)", [kind, name])
        if let v = p["hidden"] as? NSNumber { try conn.run("UPDATE grp_pref SET hidden=? WHERE kind=? AND name=?", [v.boolValue ? 1 : 0, kind, name]) }
        if let v = p["locked"] as? NSNumber { try conn.run("UPDATE grp_pref SET locked=? WHERE kind=? AND name=?", [v.boolValue ? 1 : 0, kind, name]) }
    }

    public func setGroupOrder(kind: String, names: [String]) throws {
        try conn.transaction {
            for (i, n) in names.enumerated() {
                try conn.run("INSERT OR IGNORE INTO grp_pref(kind,name) VALUES(?,?)", [kind, n])
                try conn.run("UPDATE grp_pref SET ord=? WHERE kind=? AND name=?", [i, kind, n])
            }
        }
    }

    public func resetGroupOrder(kind: String) throws { try conn.run("UPDATE grp_pref SET ord=NULL WHERE kind=?", [kind]) }

    // MARK: live, movies, series

    public func liveList(group: String, sort: String, unlocked: Bool, offset: Int, limit: Int) throws -> [Row] {
        var w = visible("live", "live", unlocked)
        var args: [Any?] = []
        if !group.isEmpty { w += " AND live.grp=?"; args.append(group) }
        args += [limit, offset]
        return try conn.query("SELECT id,k,num,name,logo,grp,url,epg,\(uaLive),ref FROM live WHERE" + w + orderBy("live", sort) + " LIMIT ? OFFSET ?", args)
    }

    public func liveByKeys(_ keys: [String]) throws -> [Row] {
        var out: [Row] = []
        for k in keys {
            if let o = try conn.one("SELECT id,k,num,name,logo,grp,url,epg,\(uaLive),ref FROM live WHERE k=? AND pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY pid, ord LIMIT 1", [k]) { out.append(o) }
        }
        return out
    }

    public func movieList(group: String, sort: String, unlocked: Bool, offset: Int, limit: Int) throws -> [Row] {
        var w = visible("movie", "movie", unlocked, sortIndex: indexedSort(group, sort))
        var args: [Any?] = []
        if !group.isEmpty { w += " AND movie.grp=?"; args.append(group) }
        args += [limit, offset]
        return try conn.query("SELECT id,k,name,year,logo,grp FROM movie WHERE" + w + orderBy("movie", sort) + " LIMIT ? OFFSET ?", args)
    }

    public func movieCount(group: String, unlocked: Bool) -> Int64 {
        let w = visible("movie", "movie", unlocked)
        if !group.isEmpty { return conn.scalar("SELECT COUNT(*) FROM movie WHERE" + w + " AND movie.grp=?", [group]) }
        return conn.scalar("SELECT COUNT(*) FROM movie WHERE" + w)
    }

    public func movie(_ key: String) throws -> Row? {
        try conn.one("SELECT movie.*, \(ua("movie")), playlists.url AS purl, playlists.ua AS pua FROM movie JOIN playlists ON playlists.id=movie.pid WHERE movie.k=? AND playlists.enabled=1 ORDER BY movie.pid, movie.ord LIMIT 1", [key])
    }

    public func seriesList(group: String, sort: String, unlocked: Bool, offset: Int, limit: Int) throws -> [Row] {
        var w = visible("series", "series", unlocked, sortIndex: indexedSort(group, sort == "year" ? "" : sort))
        var args: [Any?] = []
        if !group.isEmpty { w += " AND series.grp=?"; args.append(group) }
        args += [limit, offset]
        let order = sort == "year" ? orderBy("series", "") : orderBy("series", sort)
        return try conn.query("SELECT id,k,name,logo,grp,n_eps,n_seasons FROM series WHERE" + w + order + " LIMIT ? OFFSET ?", args)
    }

    public func seriesCount(group: String, unlocked: Bool) -> Int64 {
        let w = visible("series", "series", unlocked)
        if !group.isEmpty { return conn.scalar("SELECT COUNT(*) FROM series WHERE" + w + " AND series.grp=?", [group]) }
        return conn.scalar("SELECT COUNT(*) FROM series WHERE" + w)
    }

    public func series(_ key: String) throws -> Row? {
        guard var s = try conn.one("SELECT series.*, playlists.url AS purl, playlists.ua AS pua FROM series JOIN playlists ON playlists.id=series.pid WHERE series.k=? AND playlists.enabled=1 ORDER BY series.pid, series.ord LIMIT 1", [key]) else { return nil }
        var eps = try conn.query("SELECT id,k,season,ep,name,url,logo,\(ua("episode")),ref FROM episode WHERE series_id=? ORDER BY season, ep, ord", [s["id"] as? Int64 ?? 0])
        var pm: [String: Row] = [:]
        for p in try conn.query("SELECT k,pos,dur,done,updated FROM progress WHERE series_k=?", [key]) { if let k = p["k"] as? String { pm[k] = p } }
        for i in eps.indices { if let k = eps[i]["k"] as? String, let p = pm[k] { eps[i]["progress"] = p } }
        s["episodes"] = eps
        return s
    }

    public func episode(_ k: String) throws -> Row? {
        try conn.one("SELECT episode.*, \(ua("episode")), series.k AS series_k, series.name AS series_name, series.logo AS series_logo FROM episode JOIN series ON series.id=episode.series_id WHERE episode.k=? AND episode.pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY episode.pid, episode.ord LIMIT 1", [k])
    }

    public func search(_ q: String, unlocked: Bool, limit: Int) throws -> Row {
        let n = Classifier.normalize(q)
        if n.isEmpty { return [:] }
        let like = "%" + n.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "%"
        let starts = n + "%"
        return [
            "live": try conn.query("SELECT id,k,num,name,logo,grp,url,epg,\(uaLive),ref FROM live WHERE" + visible("live", "live", unlocked)
                + " AND sname LIKE ? GROUP BY k ORDER BY CASE WHEN sname LIKE ? THEN 0 ELSE 1 END, length(sname) LIMIT ?", [like, starts, limit]),
            "movie": try conn.query("SELECT id,k,name,year,logo,grp FROM movie WHERE" + visible("movie", "movie", unlocked)
                + " AND sname LIKE ? GROUP BY k ORDER BY CASE WHEN sname LIKE ? THEN 0 ELSE 1 END, year DESC LIMIT ?", [like, starts, limit]),
            "series": try conn.query("SELECT id,k,name,logo,grp,n_eps,n_seasons FROM series WHERE" + visible("series", "series", unlocked)
                + " AND sname LIKE ? GROUP BY k ORDER BY CASE WHEN sname LIKE ? THEN 0 ELSE 1 END, length(sname) LIMIT ?", [like, starts, limit]),
        ]
    }

    // MARK: parental lock

    func lockedGroups(_ kind: String, _ unlocked: Bool) -> Set<String> {
        if unlocked { return [] }
        let rows = (try? conn.query("SELECT name FROM grp_pref WHERE kind=? AND locked=1", [kind])) ?? []
        return Set(rows.compactMap { $0["name"] as? String })
    }

    func inLockedGroup(_ table: String, _ k: String, _ locked: Set<String>) -> Bool {
        if locked.isEmpty || k.isEmpty { return false }
        guard let g = try? conn.one("SELECT grp FROM \(table) WHERE k=? LIMIT 1", [k]) else { return false }
        return locked.contains(g["grp"] as? String ?? "")
    }

    // MARK: favourites

    public func favList(kind: String, unlocked: Bool) throws -> [Row] {
        let favs = try conn.query("SELECT kind,k,title,logo,added,ord FROM fav WHERE kind=? ORDER BY ord, added", [kind])
        let locked = lockedGroups(kind, unlocked)
        var out: [Row] = []
        for var f in favs {
            let k = f["k"] as? String ?? ""
            var cur: Row?
            switch kind {
            case "live": cur = try conn.one("SELECT id,k,num,name,logo,grp,url,epg,\(uaLive),ref FROM live WHERE k=? AND pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY pid, ord LIMIT 1", [k])
            case "movie": cur = try conn.one("SELECT id,k,name,year,logo,grp FROM movie WHERE k=? AND pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY pid, ord LIMIT 1", [k])
            case "series": cur = try conn.one("SELECT id,k,name,logo,grp,n_eps,n_seasons FROM series WHERE k=? AND pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY pid, ord LIMIT 1", [k])
            default: break
            }
            if var c = cur {
                if locked.contains(c["grp"] as? String ?? "") { continue }
                c["fav_ord"] = f["ord"] ?? 0
                out.append(c)
            } else {
                f["missing"] = true
                f["name"] = f["title"] ?? ""
                out.append(f)
            }
        }
        return out
    }

    public func favKeys() throws -> Row {
        var o = Row()
        for r in try conn.query("SELECT kind,k FROM fav") { o[(r["kind"] as? String ?? "") + "|" + (r["k"] as? String ?? "")] = true }
        return o
    }

    public func favToggle(kind: String, k: String, title: String, logo: String) throws -> Bool {
        if try conn.run("DELETE FROM fav WHERE kind=? AND k=?", [kind, k]) > 0 { return false }
        let ord = conn.scalar("SELECT COALESCE(MAX(ord),0)+1 FROM fav WHERE kind=?", [kind])
        try conn.run("INSERT OR REPLACE INTO fav(kind,k,title,logo,added,ord) VALUES(?,?,?,?,?,?)", [kind, k, title, logo, Db.nowMs(), ord])
        return true
    }

    public func favOrder(kind: String, keys: [String]) throws {
        try conn.transaction { for (i, k) in keys.enumerated() { try conn.run("UPDATE fav SET ord=? WHERE kind=? AND k=?", [i, kind, k]) } }
    }

    // MARK: progress

    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func saveProgress(_ p: [String: Any]) throws {
        func s(_ k: String) -> String { p[k] as? String ?? "" }
        func n(_ k: String) -> Int64 { (p[k] as? NSNumber)?.int64Value ?? 0 }
        let seriesK: String? = (p["series_k"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let done = (p["done"] as? NSNumber)?.boolValue ?? false
        try conn.run("INSERT OR REPLACE INTO progress(k,kind,title,sub,logo,series_k,season,ep,pos,dur,updated,done,hidden) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0)",
                     [s("k"), s("kind"), s("title"), s("sub"), s("logo"), seriesK, n("season"), n("ep"), n("pos"), n("dur"), Db.nowMs(), done ? 1 : 0])
    }

    public func progress(_ k: String) throws -> Row? { try conn.one("SELECT * FROM progress WHERE k=?", [k]) }

    public func hideProgress(k: String, seriesK: String) throws {
        if !seriesK.isEmpty { try conn.run("UPDATE progress SET hidden=1 WHERE series_k=?", [seriesK]) }
        else { try conn.run("UPDATE progress SET hidden=1 WHERE k=?", [k]) }
    }

    public func setWatched(k: String, done: Bool, meta: [String: Any]?) throws {
        var p = meta ?? [:]
        if let old = try progress(k) {
            for f in ["kind", "title", "sub", "logo", "series_k", "season", "ep", "dur"] where p[f] == nil { if let v = old[f] { p[f] = v } }
        }
        p["k"] = k
        p["pos"] = 0
        p["done"] = done
        try saveProgress(p)
    }

    public func continueList(limit: Int, unlocked: Bool) throws -> [Row] {
        let lockedMovies = lockedGroups("movie", unlocked)
        let lockedSeries = lockedGroups("series", unlocked)
        let raw = try conn.query("SELECT * FROM progress WHERE hidden=0 ORDER BY updated DESC LIMIT 200")
        var out: [Row] = []
        var seen = Set<String>()
        for p in raw {
            if out.count >= limit { break }
            let sk = p["series_k"] as? String ?? ""
            let done = p["done"] as? Int64 ?? 0
            let dur = p["dur"] as? Int64 ?? 0
            let pos = p["pos"] as? Int64 ?? 0
            if !sk.isEmpty {
                if !seen.insert(sk).inserted { continue }
                if inLockedGroup("series", sk, lockedSeries) { continue }
                if done == 1 || (dur > 0 && Double(pos) > Double(dur) * 0.95) {
                    guard let s = try conn.one("SELECT id,logo,name FROM series WHERE k=? AND pid IN (SELECT id FROM playlists WHERE enabled=1) ORDER BY pid, ord LIMIT 1", [sk]) else { continue }
                    let season = p["season"] as? Int64 ?? 0
                    let ep = p["ep"] as? Int64 ?? 0
                    guard let next = try conn.one("SELECT k,season,ep,name,logo FROM episode WHERE series_id=? AND (season>? OR (season=? AND ep>?)) ORDER BY season, ep LIMIT 1", [s["id"] as? Int64 ?? 0, season, season, ep]) else { continue }
                    let np = try progress(next["k"] as? String ?? "")
                    out.append([
                        "k": next["k"] ?? "", "kind": "episode", "series_k": sk, "title": s["name"] ?? "",
                        "season": next["season"] ?? 0, "ep": next["ep"] ?? 0, "sub": next["name"] ?? "", "logo": s["logo"] ?? "",
                        "pos": np?["pos"] ?? 0, "dur": np?["dur"] ?? 0, "next": true, "updated": p["updated"] ?? 0,
                    ])
                    continue
                }
                out.append(p)
            } else {
                if done == 1 { continue }
                if dur > 0 && Double(pos) > Double(dur) * 0.95 { continue }
                if pos < 20000 { continue }
                if inLockedGroup("movie", p["k"] as? String ?? "", lockedMovies) { continue }
                out.append(p)
            }
        }
        return out
    }

    public func historyList() throws -> Row {
        [
            "series": try conn.query("SELECT series_k AS k, MAX(title) AS title, MAX(logo) AS logo, COUNT(*) AS n, MAX(updated) AS updated FROM progress WHERE series_k IS NOT NULL AND series_k<>'' GROUP BY series_k ORDER BY updated DESC"),
            "movies": try conn.query("SELECT k, title, logo, pos, dur, done, updated FROM progress WHERE series_k IS NULL OR series_k='' ORDER BY updated DESC"),
        ]
    }

    /// scope: all | series | movies | one (series_k or k given). Returns rows removed.
    @discardableResult
    public func clearProgress(scope: String, seriesK: String, k: String) throws -> Int {
        switch scope {
        case "all": return try conn.run("DELETE FROM progress")
        case "series": return try conn.run("DELETE FROM progress WHERE series_k IS NOT NULL AND series_k<>''")
        case "movies": return try conn.run("DELETE FROM progress WHERE series_k IS NULL OR series_k=''")
        default:
            if !seriesK.isEmpty { return try conn.run("DELETE FROM progress WHERE series_k=?", [seriesK]) }
            if !k.isEmpty { return try conn.run("DELETE FROM progress WHERE k=?", [k]) }
            return 0
        }
    }

    public func clearHistory() throws {
        try conn.run("DELETE FROM recent")
        try conn.run("DELETE FROM progress")
    }

    // MARK: recents

    public func addRecent(k: String, title: String, logo: String) throws {
        try conn.run("INSERT OR REPLACE INTO recent(k,title,logo,at) VALUES(?,?,?,?)", [k, title, logo, Db.nowMs()])
        try conn.run("DELETE FROM recent WHERE k NOT IN (SELECT k FROM recent ORDER BY at DESC LIMIT 40)")
    }

    public func recents(limit: Int, unlocked: Bool) throws -> [Row] {
        let keys = try conn.query("SELECT k FROM recent ORDER BY at DESC LIMIT \(max(1, limit))").compactMap { $0["k"] as? String }
        let all = try liveByKeys(keys)
        let locked = lockedGroups("live", unlocked)
        return locked.isEmpty ? all : all.filter { !locked.contains($0["grp"] as? String ?? "") }
    }

    // MARK: EPG

    public func nowNext(chans: [String], now: Int64) throws -> Row {
        var out = Row()
        for ch in chans where !ch.isEmpty && out[ch] == nil {
            let arr = try conn.query("SELECT start,stop,title,descr FROM epg WHERE chan=? AND stop>? ORDER BY start LIMIT 2", [ch, now])
            if !arr.isEmpty { out[ch] = arr }
        }
        return out
    }

    public func programmes(chan: String, from: Int64, to: Int64) throws -> [Row] {
        try conn.query("SELECT start,stop,title,descr FROM epg WHERE chan=? AND stop>? AND start<? ORDER BY start", [chan, from, to])
    }

    public func guide(chans: [String], from: Int64, to: Int64) throws -> Row {
        var out = Row()
        for ch in chans where !ch.isEmpty && out[ch] == nil {
            out[ch] = try conn.query("SELECT start,stop,title FROM epg WHERE chan=? AND stop>? AND start<? ORDER BY start", [ch, from, to])
        }
        return out
    }

    public func epgChannelKeys() throws -> [String] {
        try conn.query("SELECT DISTINCT epg FROM live WHERE epg IS NOT NULL AND epg<>''").compactMap { $0["epg"] as? String }
    }

    // MARK: backup

    public func exportBackup() throws -> Row {
        [
            "playlists": try conn.query("SELECT name,url,ua,epg_url,auto_hours,enabled FROM playlists ORDER BY sort,id"),
            "fav": try conn.query("SELECT * FROM fav"),
            "progress": try conn.query("SELECT * FROM progress"),
            "recent": try conn.query("SELECT * FROM recent"),
            "grp_pref": try conn.query("SELECT * FROM grp_pref"),
        ]
    }
}
