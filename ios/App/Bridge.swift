import Foundation
import UIKit
import WebKit
import TopplayerCore

/// Connects the web UI to the native side: same method names and answers as the Android bridge (TPN.request).
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    let db: Db
    let dbPath: String
    let cacheDir: URL
    var importer: Importer!
    var epg: EpgImporter!
    var xtream: XtreamExtras!
    var player: PlayerEngine!

    private let work = DispatchQueue(label: "tp.bridge", qos: .userInitiated, attributes: .concurrent)
    private let importQueue = DispatchQueue(label: "tp.import", qos: .utility)
    private let defaults = UserDefaults.standard
    private var sleepEndsAt: Int64 = 0
    private var sleepWarnTimer: Timer?
    private var sleepFireTimer: Timer?

    init(web: WKWebView?, db: Db, dbPath: String, cacheDir: URL) {
        self.web = web
        self.db = db
        self.dbPath = dbPath
        self.cacheDir = cacheDir
        super.init()
        importer = Importer(db: db, dbPath: dbPath, cacheDir: cacheDir) { [weak self] n, d in self?.emit(n, d) }
        importer.demoFile = Bundle.main.url(forResource: "demo", withExtension: "m3u")
        epg = EpgImporter(db: db, dbPath: dbPath, cacheDir: cacheDir) { [weak self] n, d in self?.emit(n, d) }
        xtream = XtreamExtras(db: db)
    }

    // MARK: preferences kept for the injected script

    var prefsJSON: String {
        if let s = defaults.string(forKey: "settings") { return s }
        // phones and tablets are smaller than a TV: start with a bigger interface
        let scale = UIDevice.current.userInterfaceIdiom == .pad ? 1.5 : 2.0
        return "{\"uiScale\":\(scale)}"
    }
    var stateJSON: String { defaults.string(forKey: "state") ?? "{}" }

    // MARK: messages from the web page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let t = m["t"] as? String else { return }
        switch t {
        case "prefs": defaults.set(m["v"] as? String ?? "{}", forKey: "settings")
        case "state": defaults.set(m["v"] as? String ?? "{}", forKey: "state")
        case "log": NSLog("Topplayer: %@", m["v"] as? String ?? "")
        case "req":
            guard let id = (m["id"] as? NSNumber)?.intValue, let method = m["m"] as? String else { return }
            let json = m["j"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            work.async { [weak self] in self?.dispatch(id, method, args) }
        default: break
        }
    }

    private func dispatch(_ id: Int, _ method: String, _ a: [String: Any]) {
        var ok = true
        var res: String
        do {
            res = Bridge.json(try handle(method, a))
        } catch {
            ok = false
            res = Bridge.json((error as? DbError)?.message ?? error.localizedDescription)
        }
        eval("TP.resolve(\(id),\(ok),\(res))")
    }

    static func json(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "null" }
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) { return s }
        return "null"
    }

    func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in self?.web?.evaluateJavaScript(js, completionHandler: nil) }
    }

    func emit(_ name: String, _ data: [String: Any]) {
        let n = Bridge.json(name)
        eval("window.TP&&TP.event(\(n),\(Bridge.json(data)))")
    }

    private func onMain<T>(_ f: @escaping () -> T) -> T {
        if Thread.isMainThread { return f() }
        return DispatchQueue.main.sync(execute: f)
    }

    // MARK: argument helpers

    private func s(_ a: [String: Any], _ k: String, _ d: String = "") -> String { a[k] as? String ?? d }
    private func i(_ a: [String: Any], _ k: String, _ d: Int = 0) -> Int { (a[k] as? NSNumber)?.intValue ?? d }
    private func l(_ a: [String: Any], _ k: String, _ d: Int64 = 0) -> Int64 { (a[k] as? NSNumber)?.int64Value ?? d }
    private func b(_ a: [String: Any], _ k: String, _ d: Bool = false) -> Bool { (a[k] as? NSNumber)?.boolValue ?? d }
    private func need(_ a: [String: Any], _ k: String) throws -> String {
        guard let v = a[k] as? String else { throw DbError(message: "Missing \(k)") }
        return v
    }

    private func refreshAsync(_ id: Int64, epgAfter: Bool) {
        importQueue.async { [self] in
            importer.refresh(id)
            if epgAfter { epg.refresh() }
        }
    }

    // MARK: dispatcher

    private func handle(_ m: String, _ a: [String: Any]) throws -> Any? {
        switch m {
        // app
        case "app.info":
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            var o: [String: Any] = ["version": v, "sdk": 0, "device": UIDevice.current.model + " (iOS " + UIDevice.current.systemVersion + ")", "ip": ""]
            o["platform"] = "ios"
            return o
        case "update.check": return ["available": false, "current": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", "code": 0, "name": "", "size": 0, "notes": ""]
        case "update.install": return ["status": "uptodate"]
        case "app.exit":
            onMain { self.player.stop() }
            return nil
        case "app.background": return nil
        case "app.keepScreenOn":
            let on = b(a, "on")
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
            return nil
        case "app.webBg":
            let c = s(a, "color")
            DispatchQueue.main.async { (self.web?.window?.rootViewController as? MainViewController)?.setBackground(hex: c) }
            return nil
        case "app.textInput": return nil
        case "app.orientation":
            let landscape = b(a, "landscape")
            DispatchQueue.main.async { (self.web?.window?.rootViewController as? MainViewController)?.requestOrientation(landscape: landscape) }
            return nil

        // playlists
        case "pl.list":
            var pls = try db.playlists()
            for k in pls.indices {
                let id = pls[k]["id"] as? Int64 ?? 0
                pls[k]["running"] = importer.isRunning(id)
                pls[k]["xtream"] = XtreamAccount.parse(pls[k]["url"] as? String) != nil
            }
            return pls
        case "pl.add":
            let id = try db.addPlaylist(name: s(a, "name", "Playlist"), url: try need(a, "url"), ua: s(a, "ua"), epgUrl: s(a, "epg_url"), autoHours: i(a, "auto_hours", 24))
            refreshAsync(id, epgAfter: b(a, "epg", true))
            return id
        case "pl.addDemo":
            let id = try db.addPlaylist(name: s(a, "name", "Topplayer testlijst"), url: Importer.demoURL, ua: "", epgUrl: "", autoHours: 0)
            refreshAsync(id, epgAfter: false)
            return id
        case "relay.poll": return [Any]()
        case "pl.update":
            try db.updatePlaylist(l(a, "id"), a)
            return nil
        case "pl.delete":
            try db.deletePlaylist(l(a, "id"))
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("playlist_\(l(a, "id")).m3u"))
            return nil
        case "pl.refresh":
            refreshAsync(l(a, "id"), epgAfter: true)
            return nil
        case "pl.autoRefresh":
            let now = Db.nowMs()
            var n = 0
            for p in try db.playlists() {
                let hours = Int64(p["auto_hours"] as? Int64 ?? 24)
                if (p["enabled"] as? Int64 ?? 1) == 0 || hours <= 0 { continue }
                if now - (p["last_refresh"] as? Int64 ?? 0) > hours * 3_600_000 {
                    refreshAsync(p["id"] as? Int64 ?? 0, epgAfter: false)
                    n += 1
                }
            }
            let last = db.kvGet("epg_updated").flatMap { Int64($0) }
            if n > 0 || last == nil || now - last! > 12 * 3_600_000 { importQueue.async { self.epg.refresh() } }
            return n
        case "epg.refresh":
            importQueue.async { self.epg.refresh() }
            return nil
        case "epg.status":
            return ["running": epg.isRunning, "updated": db.kvGet("epg_updated") as Any, "count": db.conn.scalar("SELECT COUNT(*) FROM epg")]

        // content
        case "groups": return try db.groups(kind: try need(a, "kind"), includeHidden: b(a, "all"))
        case "groups.pref":
            try db.setGroupPref(kind: try need(a, "kind"), name: try need(a, "name"), a)
            return nil
        case "groups.order":
            try db.setGroupOrder(kind: try need(a, "kind"), names: (a["names"] as? [String]) ?? [])
            return nil
        case "groups.resetOrder":
            try db.resetGroupOrder(kind: try need(a, "kind"))
            return nil
        case "live.list": return try db.liveList(group: s(a, "group"), sort: s(a, "sort"), unlocked: b(a, "unlocked"), offset: i(a, "offset"), limit: i(a, "limit", 5000))
        case "live.byKeys": return try db.liveByKeys((a["keys"] as? [String]) ?? [])
        case "movie.list":
            var o: [String: Any] = ["items": try db.movieList(group: s(a, "group"), sort: s(a, "sort"), unlocked: b(a, "unlocked"), offset: i(a, "offset"), limit: i(a, "limit", 60))]
            if b(a, "count") { o["total"] = db.movieCount(group: s(a, "group"), unlocked: b(a, "unlocked")) }
            return o
        case "movie.get": return try db.movie(try need(a, "k"))
        case "series.list":
            var o: [String: Any] = ["items": try db.seriesList(group: s(a, "group"), sort: s(a, "sort"), unlocked: b(a, "unlocked"), offset: i(a, "offset"), limit: i(a, "limit", 60))]
            if b(a, "count") { o["total"] = db.seriesCount(group: s(a, "group"), unlocked: b(a, "unlocked")) }
            return o
        case "series.get":
            let k = try need(a, "k")
            var err: String?
            do { try xtream.ensureEpisodes(k) } catch { err = (error as? DbError)?.message ?? error.localizedDescription }
            guard var sr = try db.series(k) else { return nil }
            if let e = err, (sr["episodes"] as? [Row])?.isEmpty ?? true { sr["xt_error"] = e }
            return sr
        case "episode.get": return try db.episode(try need(a, "k"))
        case "search": return try db.search(try need(a, "q"), unlocked: b(a, "unlocked"), limit: i(a, "limit", 40))
        case "xt.movie": return try xtream.movieInfo(try need(a, "k"))
        case "xt.series": return try xtream.seriesInfo(try need(a, "k"))

        // favourites / progress / recents
        case "fav.list": return try db.favList(kind: try need(a, "kind"), unlocked: b(a, "unlocked"))
        case "fav.keys": return try db.favKeys()
        case "fav.toggle": return try db.favToggle(kind: try need(a, "kind"), k: try need(a, "k"), title: s(a, "title"), logo: s(a, "logo"))
        case "fav.order":
            try db.favOrder(kind: try need(a, "kind"), keys: (a["keys"] as? [String]) ?? [])
            return nil
        case "progress.save":
            try db.saveProgress(a)
            return nil
        case "progress.get": return try db.progress(try need(a, "k"))
        case "progress.hide":
            try db.hideProgress(k: s(a, "k"), seriesK: s(a, "series_k"))
            return nil
        case "progress.watched":
            try db.setWatched(k: try need(a, "k"), done: b(a, "done", true), meta: a["meta"] as? [String: Any])
            return nil
        case "continue": return try db.continueList(limit: i(a, "limit", 20), unlocked: b(a, "unlocked"))
        case "recent.add":
            try db.addRecent(k: try need(a, "k"), title: s(a, "title"), logo: s(a, "logo"))
            return nil
        case "recent.list": return try db.recents(limit: i(a, "limit", 20), unlocked: b(a, "unlocked"))
        case "history.list": return try db.historyList()
        case "progress.clear": return ["removed": try db.clearProgress(scope: s(a, "scope", "one"), seriesK: s(a, "series_k"), k: s(a, "k"))]
        case "history.clear":
            try db.clearHistory()
            return nil
        case "epg.nowNext": return try db.nowNext(chans: (a["chans"] as? [String]) ?? [], now: l(a, "now", Db.nowMs()))
        case "epg.programmes": return try db.programmes(chan: try need(a, "chan"), from: l(a, "from"), to: l(a, "to"))
        case "epg.guide": return try db.guide(chans: (a["chans"] as? [String]) ?? [], from: l(a, "from"), to: l(a, "to"))

        // player (main thread)
        case "player.play":
            onMain { self.player.play(a) }
            return nil
        case "player.stop":
            onMain { self.player.stop() }
            return nil
        case "player.pause":
            DispatchQueue.main.async { self.player.pause() }
            return nil
        case "player.resume":
            DispatchQueue.main.async { self.player.resume() }
            return nil
        case "player.toggle":
            DispatchQueue.main.async { self.player.toggle() }
            return nil
        case "player.seekTo":
            DispatchQueue.main.async { self.player.seekTo(self.l(a, "ms")) }
            return nil
        case "player.seekBy":
            DispatchQueue.main.async { self.player.seekBy(self.l(a, "ms")) }
            return nil
        case "player.speed":
            DispatchQueue.main.async { self.player.setSpeed(Float((a["speed"] as? NSNumber)?.doubleValue ?? 1)) }
            return nil
        case "player.aspect":
            DispatchQueue.main.async { self.player.setAspect(self.s(a, "mode", "fit"), zoom: Float((a["zoom"] as? NSNumber)?.doubleValue ?? 1)) }
            return nil
        case "player.rect":
            let x = (a["x"] as? NSNumber)?.doubleValue ?? 0, y = (a["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (a["w"] as? NSNumber)?.doubleValue ?? 0, h = (a["h"] as? NSNumber)?.doubleValue ?? 0
            let vis = b(a, "visible", true)
            DispatchQueue.main.async { (self.web?.window?.rootViewController as? MainViewController)?.setVideoRect(x: x, y: y, w: w, h: h, visible: vis) }
            return nil
        case "player.tracks": return onMain { self.player.tracks() }
        case "player.select":
            DispatchQueue.main.async { self.player.selectTrack(type: self.s(a, "type"), id: self.s(a, "id")) }
            return nil
        case "player.configure":
            DispatchQueue.main.async { self.player.configure(a) }
            return nil

        // sleep timer
        case "sleep.set":
            let minutes = l(a, "minutes"), warn = l(a, "warn", 60)
            return onMain { self.setSleep(minutes: minutes, warn: warn); return self.sleepEndsAt }
        case "sleep.status": return sleepEndsAt
        case "img.prefetch": return nil
        case "server.start": return ["port": 0, "ip": "", "token": ""]
        case "server.stop": return nil
        case "backup.export":
            var o = try db.exportBackup()
            o["settings"] = (try? JSONSerialization.jsonObject(with: Data(prefsJSON.utf8))) ?? [String: Any]()
            return o
        default:
            throw DbError(message: "Unknown method \(m)")
        }
    }

    private func setSleep(minutes: Int64, warn: Int64) {
        sleepWarnTimer?.invalidate()
        sleepFireTimer?.invalidate()
        if minutes <= 0 { sleepEndsAt = 0; return }
        let ms = minutes * 60_000
        sleepEndsAt = Db.nowMs() + ms
        if warn > 0 && ms > warn * 1000 {
            sleepWarnTimer = Timer.scheduledTimer(withTimeInterval: Double(ms - warn * 1000) / 1000, repeats: false) { [weak self] _ in
                self?.emit("sleep.warning", ["seconds": warn])
            }
        }
        sleepFireTimer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: false) { [weak self] _ in
            self?.sleepEndsAt = 0
            self?.emit("sleep.fire", ["at": Db.nowMs()])
        }
    }
}
