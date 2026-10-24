import Foundation

/// XMLTV guide import. Keeps a window of 12h back to 4 days ahead, only for channels we know.
public final class EpgImporter {
    public typealias Emit = (String, [String: Any]) -> Void
    private let db: Db
    private let dbPath: String
    private let cacheDir: URL
    private let emit: Emit
    private let lock = NSLock()
    private var running = false

    public init(db: Db, dbPath: String, cacheDir: URL, emit: @escaping Emit) {
        self.db = db
        self.dbPath = dbPath
        self.cacheDir = cacheDir
        self.emit = emit
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func sources() throws -> [String] {
        var urls: [String] = []
        for p in try db.playlists() {
            if (p["enabled"] as? Int64 ?? 1) == 0 { continue }
            let custom = (p["epg_url"] as? String ?? "").trimmed
            let header = (p["header_epg"] as? String ?? "").trimmed
            let src = !custom.isEmpty ? custom : header
            if !src.isEmpty {
                for u in src.split(separator: ",").map({ String($0).trimmed }) where !u.isEmpty { if !urls.contains(u) { urls.append(u) } }
            } else if let x = XtreamAccount.parse(p["url"] as? String) {
                if !urls.contains(x.xmltv()) { urls.append(x.xmltv()) }
            }
        }
        return urls
    }

    /// Blocking: call from a background queue. Always ends with an epg.done event.
    public func refresh() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        var done: [String: Any] = [:]
        do {
            let urls = try sources()
            if urls.isEmpty {
                done = ["ok": false, "error": "no-source"]
            } else {
                var ourKeys = Set<String>()
                var nameMap: [String: String] = [:]
                for r in try db.conn.query("SELECT DISTINCT epg, name FROM live WHERE pid IN (SELECT id FROM playlists WHERE enabled=1)") {
                    guard let k = r["epg"] as? String, !k.isEmpty else { continue }
                    ourKeys.insert(k)
                    let nk = Classifier.epgNameKey(r["name"] as? String)
                    if !nk.isEmpty && nameMap[nk] == nil { nameMap[nk] = k }
                    if k.hasPrefix("n:") { nameMap[String(k.dropFirst(2))] = k }
                }
                let now = Double(Db.nowMs())
                let from = Int64(now - 12 * 3600_000), to = Int64(now + 4 * 24 * 3600_000)
                var files: [URL] = []
                for (i, u) in urls.enumerated() {
                    let f = cacheDir.appendingPathComponent("epg_\(i).xml")
                    emit("epg.progress", ["phase": "download"])
                    if (try? Net.download(u, to: f)) != nil { files.append(f) }
                }
                if files.isEmpty { throw DbError(message: "EPG download failed") }
                let c = try Connection(path: dbPath)
                var total = 0
                try c.transaction {
                    try c.run("DELETE FROM epg")
                    let ins = try c.prepare("INSERT INTO epg(chan,start,stop,title,descr) VALUES(?,?,?,?,?)")
                    for f in files {
                        emit("epg.progress", ["phase": "parse"])
                        let parser = XmlTv(ourKeys: ourKeys, nameMap: nameMap, from: from, to: to, insert: ins)
                        total += parser.run(file: f)
                        try? FileManager.default.removeItem(at: f)
                    }
                }
                db.kvSet("epg_updated", String(Db.nowMs()))
                done = ["ok": true, "programmes": total]
            }
        } catch {
            done = ["ok": false, "error": (error as? DbError)?.message ?? error.localizedDescription]
        }
        lock.lock(); running = false; lock.unlock()
        emit("epg.done", done)
    }

    /// XMLTV time "20241006213000 +0200" (offset optional) to epoch millis.
    public static func parseTime(_ str: String?) -> Int64 {
        guard let s = str?.trimmed, s.utf16.count >= 12 else { return 0 }
        let u = Array(s.utf16)
        func num(_ a: Int, _ b: Int) -> Int? { Int(String(decoding: u[a..<b], as: UTF16.self)) }
        guard let y = num(0, 4), let mo = num(4, 6), let d = num(6, 8), let h = num(8, 10), let mi = num(10, 12) else { return 0 }
        var se = 0
        if u.count >= 14, let v = num(12, 14) { se = v }
        var epoch = ((daysFromCivil(y, mo, d) * 24 + Int64(h)) * 60 + Int64(mi)) * 60 + Int64(se)
        var off = ""
        if let sp = s.firstIndex(of: " ") { off = String(s[s.index(after: sp)...]).trimmed }
        else if u.count > 14 { off = String(decoding: u[14...], as: UTF16.self).trimmed }
        let ou = Array(off.utf16)
        if ou.count >= 5 && (ou[0] == 43 || ou[0] == 45), let oh = Int(String(decoding: ou[1..<3], as: UTF16.self)), let om = Int(String(decoding: ou[3..<5], as: UTF16.self)) {
            let sec = Int64(oh * 3600 + om * 60)
            epoch += ou[0] == 43 ? -sec : sec
        }
        return epoch * 1000
    }

    static func daysFromCivil(_ yIn: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(m <= 2 ? yIn - 1 : yIn)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * Int64(m + (m > 2 ? -3 : 9)) + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

final class XmlTv: NSObject, XMLParserDelegate {
    let ourKeys: Set<String>
    let nameMap: [String: String]
    let from: Int64, to: Int64
    let insert: Connection.Statement
    var idMap: [String: String] = [:]
    var curChannel: String?
    var progChan: String?
    var pStart: Int64 = 0, pStop: Int64 = 0
    var title: String?, desc: String?
    var text = ""
    var capture = ""
    var skipDepth = 0
    var inDisplayName = false
    var count = 0

    init(ourKeys: Set<String>, nameMap: [String: String], from: Int64, to: Int64, insert: Connection.Statement) {
        self.ourKeys = ourKeys
        self.nameMap = nameMap
        self.from = from
        self.to = to
        self.insert = insert
    }

    func run(file: URL) -> Int {
        guard let p = XMLParser(contentsOf: file) else { return 0 }
        p.delegate = self
        p.shouldProcessNamespaces = false
        p.parse()
        return count
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "channel":
            curChannel = a["id"]
            if let c = curChannel, ourKeys.contains(c.lowercased()) { idMap[c] = c.lowercased() }
        case "display-name":
            if curChannel != nil { capture = "display-name"; text = "" }
        case "programme":
            guard let ch = a["channel"] else { skipDepth = 1; return }
            var key = idMap[ch]
            if key == nil {
                let low = ch.lowercased()
                if ourKeys.contains(low) { key = low }
                else if let k = nameMap[Classifier.epgNameKey(ch)] { key = k }
                idMap[ch] = key ?? ""
            }
            guard let k = key, !k.isEmpty else { skipDepth = 1; return }
            pStart = EpgImporter.parseTime(a["start"])
            pStop = EpgImporter.parseTime(a["stop"])
            if pStop <= 0 { pStop = pStart + 3600_000 }
            if pStart <= 0 || pStop < from || pStart > to { skipDepth = 1; return }
            progChan = k
            title = nil
            desc = nil
        case "title" where progChan != nil:
            capture = "title"; text = ""
        case "desc" where progChan != nil:
            capture = "desc"; text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !capture.isEmpty { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "channel": curChannel = nil
        case "display-name" where capture == "display-name":
            capture = ""
            if let c = curChannel, idMap[c] == nil {
                if let k = nameMap[Classifier.epgNameKey(text)] { idMap[c] = k }
                else if let k2 = nameMap[Classifier.epgNameKey(c)] { idMap[c] = k2 }
            }
        case "title" where capture == "title":
            capture = ""
            if title == nil { title = text }
        case "desc" where capture == "desc":
            capture = ""
            if desc == nil { desc = text }
        case "programme":
            if let ch = progChan {
                let d = desc?.trimmed
                _ = try? insert.insert([ch, pStart, pStop, (title ?? "").trimmed, d])
                count += 1
                progChan = nil
            }
        default: break
        }
    }
}
