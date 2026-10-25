import XCTest
@testable import TopplayerCore

final class ParserTests: XCTestCase {
    func parse(_ m3u: String) -> [M3uEntry] {
        var lines = m3u.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var it = lines.makeIterator()
        var out: [M3uEntry] = []
        M3uParser.parse(nextLine: { it.next() }, onHeader: { _ in }, onEntry: { out.append($0); return true })
        return out
    }

    func testVlcOptAfterExtInf() {
        let e = parse("#EXTM3U\n#EXTINF:-1 group-title=\"NL\",RTL 4\n#EXTVLCOPT:http-user-agent=Foo/1.0\n#EXTVLCOPT:http-referrer=http://r.example\nhttp://h/live/a.m3u8\n")[0]
        XCTAssertEqual(e.userAgent, "Foo/1.0")
        XCTAssertEqual(e.referrer, "http://r.example")
    }

    func testVlcOptBeforeExtInf() {
        let e = parse("#EXTM3U\n#EXTVLCOPT:http-user-agent=Foo/1.0\n#EXTVLCOPT:http-referrer=http://r.example\n#EXTINF:-1 group-title=\"NL\",RTL 4\nhttp://h/live/a.m3u8\n")[0]
        XCTAssertEqual(e.userAgent, "Foo/1.0")
        XCTAssertEqual(e.referrer, "http://r.example")
        XCTAssertEqual(e.group, "NL")
        XCTAssertEqual(e.name, "RTL 4")
    }

    func testGroupRules() {
        XCTAssertEqual(parse("#EXTM3U\n#EXTGRP:Sport\n#EXTINF:-1,ESPN\nhttp://h/live/e.m3u8\n")[0].group, "Sport")
        XCTAssertEqual(parse("#EXTM3U\n#EXTGRP:Sport\n#EXTINF:-1 group-title=\"Nieuws\",NOS\nhttp://h/live/e.m3u8\n")[0].group, "Nieuws")
    }

    func testOptionsDoNotLeak() {
        var two = parse("#EXTM3U\n#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=Foo\nhttp://h/a\n#EXTINF:-1,B\nhttp://h/b\n")
        XCTAssertNil(two[1].userAgent)
        two = parse("#EXTM3U\n#EXTINF:-1,A\nhttp://h/a\n#EXTVLCOPT:http-user-agent=Foo\n#EXTINF:-1,B\nhttp://h/b\n")
        XCTAssertEqual(two[1].userAgent, "Foo")
        XCTAssertNil(two[0].userAgent)
        two = parse("#EXTM3U\n#EXTINF:-1,Zonder url\n#EXTINF:-1,B\nhttp://h/b\n")
        XCTAssertEqual(two.count, 1)
        XCTAssertEqual(two[0].name, "B")
    }

    func testAttributesAndKodiOptions() {
        let e = parse("#EXTM3U\n#EXTINF:-1 tvg-id=\"npo1.nl\" tvg-logo=\"http://l/x.png\" group-title=\"NL | Algemeen\",NPO 1 HD\nhttp://h/live/1.ts|User-Agent=Mozilla%2F5.0&Referer=http://ref\n")[0]
        XCTAssertEqual(e.attr("tvg-id"), "npo1.nl")
        XCTAssertEqual(e.attr("tvg-logo"), "http://l/x.png")
        XCTAssertEqual(e.group, "NL | Algemeen")
        XCTAssertEqual(e.name, "NPO 1 HD")
        XCTAssertEqual(e.url, "http://h/live/1.ts")
        XCTAssertEqual(e.userAgent, "Mozilla/5.0")
        XCTAssertEqual(e.referrer, "http://ref")
    }

    func testNameWithCommaInsideQuotes() {
        let e = parse("#EXTM3U\n#EXTINF:-1 tvg-name=\"A, B\" group-title=\"X\",Show, deel 2\nhttp://h/a\n")[0]
        XCTAssertEqual(e.attr("tvg-name"), "A, B")
        XCTAssertEqual(e.name, "Show, deel 2")
    }
}

final class ClassifierTests: XCTestCase {
    func entry(_ name: String, url: String = "http://h/x", group: String = "") -> M3uEntry {
        let e = M3uEntry()
        e.name = name; e.url = url; e.group = group
        return e
    }

    func testYears() {
        let now = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(Classifier.extractYear("Blade Runner 2049"), 0)
        XCTAssertEqual(Classifier.extractYear("Dune (2021)"), 2021)
        XCTAssertEqual(Classifier.extractYear("Oppenheimer - 2023"), 2023)
        XCTAssertEqual(Classifier.extractYear("Heat 1995"), 1995)
        XCTAssertEqual(Classifier.extractYear("Wall-E"), 0)
        XCTAssertEqual(Classifier.extractYear("Film (\(now + 1))"), now + 1)
        XCTAssertEqual(Classifier.extractYear("Film (\(now + 2))"), 0)
    }

    func testUniqueKeys() {
        var used = KeySet()
        XCTAssertEqual(Classifier.uniqueKey(&used, "L|bbc one", "UK"), "L|bbc one")
        XCTAssertEqual(Classifier.uniqueKey(&used, "L|bbc one", "Sport"), "L|bbc one|sport")
        XCTAssertEqual(Classifier.uniqueKey(&used, "L|bbc one", "Sport"), "L|bbc one|sport|2")
        XCTAssertEqual(Classifier.uniqueKey(&used, "L|bbc two", "UK"), "L|bbc two")
        XCTAssertEqual(used.count, 4)
    }

    func testKeySetNoFalseHits() {
        var big = KeySet()
        var dup = 0
        for i in 0..<300_000 where !big.add("M|film \(i)") { dup += 1 }
        XCTAssertEqual(dup, 0)
        XCTAssertEqual(big.count, 300_000)
    }

    func testEpisodes() {
        var r = Classifier.classify(entry("Suits S01E02 - Pilot", url: "http://h/series/u/p/1.mkv"))
        XCTAssertEqual(r.kind, Classifier.episode)
        XCTAssertEqual(r.seriesName, "Suits")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 2)
        XCTAssertEqual(r.episodeTitle, "Pilot")
        r = Classifier.classify(entry("Brooklyn Nine-Nine 6x03", url: "http://h/movie/u/p/2.mp4", group: "Series NL"))
        XCTAssertEqual(r.kind, Classifier.episode)
        XCTAssertEqual(r.seriesName, "Brooklyn Nine-Nine")
        XCTAssertEqual(r.season, 6)
        XCTAssertEqual(r.episode, 3)
        r = Classifier.classify(entry("Breaking Bad Season 2 Episode 5", url: "http://h/series/u/p/3.mp4"))
        XCTAssertEqual(r.kind, Classifier.episode)
        XCTAssertEqual(r.seriesName, "Breaking Bad")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 5)
    }

    func testMoviesAndLive() {
        XCTAssertEqual(Classifier.classify(entry("Dune (2021)", url: "http://h/movie/u/p/9.mkv")).kind, Classifier.movie)
        XCTAssertEqual(Classifier.classify(entry("Some film", url: "http://h/files/film.mp4")).kind, Classifier.movie)
        XCTAssertEqual(Classifier.classify(entry("NPO 1 HD", url: "http://h/live/u/p/1.ts")).kind, Classifier.live)
        XCTAssertEqual(Classifier.classify(entry("Channel", url: "http://h/stream")).kind, Classifier.live)
        XCTAssertEqual(Classifier.classify(entry("Seven Samurai", url: "http://h/movie/u/p/9.mkv")).kind, Classifier.movie)
    }

    func testNormalize() {
        XCTAssertEqual(Classifier.normalize("Café Zoë - Déjà Vu!"), "cafe zoe deja vu")
        XCTAssertEqual(Classifier.normalize("  ...A  B  "), "a b")
        XCTAssertEqual(Classifier.epgNameKey("NL: NPO 1 HD"), "npo1")
        XCTAssertEqual(Classifier.epgNameKey("RTL 4 FHD"), "rtl4")
    }
}

final class XtreamTests: XCTestCase {
    func testAccount() {
        let a = XtreamAccount.parse("http://line.example.xyz:8080/get.php?username=u%40x&password=p&type=m3u&output=ts")
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.base, "http://line.example.xyz:8080")
        XCTAssertEqual(a?.user, "u@x")
        XCTAssertEqual(a?.liveExt, "ts")
        XCTAssertEqual(a?.api("get_series"), "http://line.example.xyz:8080/player_api.php?username=u%40x&password=p&action=get_series")
        XCTAssertEqual(a?.liveUrl("12"), "http://line.example.xyz:8080/live/u%40x/p/12.ts")
        XCTAssertEqual(XtreamAccount.parse("https://h/prefix/get.php?username=a&password=b&output=m3u8")?.base, "https://h/prefix")
        XCTAssertEqual(XtreamAccount.parse("https://h/get.php?username=a&password=b&output=m3u8")?.liveExt, "m3u8")
        XCTAssertNil(XtreamAccount.parse("http://h/list.m3u"))
        XCTAssertNil(XtreamAccount.parse("http://h/get.php?password=b"))
        XCTAssertNil(XtreamAccount.parse(nil))
    }

    func testJsonArrayStream() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arr-\(UUID().uuidString).json")
        var s = "["
        for i in 0..<5000 { s += (i > 0 ? "," : "") + "{\"name\":\"A \\\"{x}\\\" \(i)\",\"id\":\(i),\"backdrop_path\":[\"a\",\"b\"],\"n\":{\"k\":[1,2]}}" }
        s += "]"
        try s.write(to: url, atomically: true, encoding: .utf8)
        var n = 0
        var last = ""
        try JsonArrayStream(url: url).forEachObject { o in
            n += 1
            last = o["name"] as? String ?? ""
            return true
        }
        XCTAssertEqual(n, 5000)
        XCTAssertEqual(last, "A \"{x}\" 4999")
        var seen = 0
        try JsonArrayStream(url: url).forEachObject { _ in seen += 1; return seen < 3 }
        XCTAssertEqual(seen, 3)
    }

    func testSeriesInfo() {
        let a = XtreamAccount.parse("http://h:80/get.php?username=u&password=p")!
        let json = """
        {"info":{"plot":"Plot","cast":"A, B","releaseDate":"2013-09-17","cover":"http://c","backdrop_path":["http://b1"]},
         "episodes":{"1":[{"id":"101","episode_num":1,"title":"Pilot","container_extension":"mkv","season":1,"info":{"movie_image":"http://i1","plot":"p1","duration":"22:00"}},
                          {"id":"102","episode_num":2,"title":"Second","container_extension":"mp4","season":1}],
                     "2":[{"id":"201","episode_num":1,"title":"S2E1"},{"id":"201","episode_num":1,"title":"dup"}]}}
        """
        let r = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let p = XtreamImporter.parseSeriesInfo(r, a)
        XCTAssertEqual(p.episodes.count, 3)
        let e1 = p.episodes.first { $0.season == 1 && $0.number == 1 }
        XCTAssertEqual(e1?.url, "http://h:80/series/u/p/101.mkv")
        XCTAssertEqual(e1?.logo, "http://i1")
        XCTAssertEqual(p.details["plot"] as? String, "Plot")
        XCTAssertEqual(p.details["backdrop"] as? String, "http://b1")
        XCTAssertNotNil((p.details["episodes"] as? [String: Any])?["1|2"])
    }

    func testSeriesInfoOddShapes() {
        let a = XtreamAccount.parse("http://h:80/get.php?username=u&password=p")!
        func eps(_ json: String) -> [XtreamImporter.Episode] {
            XtreamImporter.parseSeriesInfo(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any], a).episodes
        }
        // seasons as objects instead of lists, season "0" in the episode
        let d = eps(#"{"episodes":{"2":{"0":{"id":11,"episode_num":"1","season":"0"},"1":{"id":12,"episode_num":"2"}}}}"#)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d.first?.season, 2)
        XCTAssertEqual(d.first?.url, "http://h:80/series/u/p/11.mp4")
        // a list of seasons
        XCTAssertEqual(eps(#"{"episodes":[[{"id":"1","episode_num":1}],[{"id":"2","episode_num":1}]]}"#).map { $0.season }, [1, 2])
        // one flat list
        XCTAssertEqual(eps(#"{"episodes":[{"id":"1","episode_num":1,"season":3},{"id":"2","episode_num":2,"season":3}]}"#).count, 2)
    }

    func testEpgTime() {
        XCTAssertEqual(EpgImporter.parseTime("20241006213000 +0200"), 1728243000000)
        XCTAssertEqual(EpgImporter.parseTime("20241006193000"), 1728243000000)
        XCTAssertEqual(EpgImporter.parseTime("20241006213000 -0100"), 1728253800000)
        XCTAssertEqual(EpgImporter.parseTime("bad"), 0)
    }
}

final class DbTests: XCTestCase {
    var dir: URL!
    var path: String!
    var db: Db!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("t.db").path
        db = try Db(path: path)
    }

    func importFile(_ content: String) throws -> Int64 {
        let f = dir.appendingPathComponent("list.m3u")
        try content.write(to: f, atomically: true, encoding: .utf8)
        let pid = try db.addPlaylist(name: "T", url: f.absoluteString, ua: "", epgUrl: "", autoHours: 0)
        // local file import goes through the asset path of the importer
        var events: [(String, [String: Any])] = []
        let imp = Importer(db: db, dbPath: path, cacheDir: dir) { events.append(($0, $1)) }
        imp.demoFile = f
        try db.updatePlaylist(pid, ["url": Importer.demoURL])
        imp.refresh(pid)
        let done = events.last { $0.0 == "import.done" }?.1
        XCTAssertEqual(done?["ok"] as? Bool, true, "\(String(describing: done))")
        return pid
    }

    let sample = """
    #EXTM3U url-tvg="http://epg.example/guide.xml"
    #EXTINF:-1 tvg-id="npo1.nl" group-title="NL | Algemeen",NPO 1 HD
    http://h/live/u/p/1.ts
    #EXTINF:-1 tvg-id="npo2.nl" group-title="NL | Algemeen",NPO 2 HD
    http://h/live/u/p/2.ts
    #EXTINF:-1 group-title="Films",Dune (2021)
    http://h/movie/u/p/10.mkv
    #EXTINF:-1 group-title="Films",Heat (1995)
    http://h/movie/u/p/11.mkv
    #EXTINF:-1 group-title="Series",Suits S01E01 - Pilot
    http://h/series/u/p/21.mkv
    #EXTINF:-1 group-title="Series",Suits S01E02 - Kicking In
    http://h/series/u/p/22.mkv
    #EXTINF:-1 group-title="Series",Suits S02E01 - Return
    http://h/series/u/p/23.mkv
    #EXTINF:-1 group-title="Series",Dark S01E01
    http://h/series/u/p/31.mkv
    """

    func testImportAndLists() throws {
        _ = try importFile(sample)
        let pl = try db.playlists()[0]
        XCTAssertEqual(pl["n_live"] as? Int64, 2)
        XCTAssertEqual(pl["n_movie"] as? Int64, 2)
        XCTAssertEqual(pl["n_series"] as? Int64, 2)
        XCTAssertEqual(pl["header_epg"] as? String, "http://epg.example/guide.xml")
        XCTAssertEqual(pl["status"] as? String, "ok")
        XCTAssertEqual(try db.liveList(group: "", sort: "", unlocked: false, offset: 0, limit: 10).count, 2)
        let movies = try db.movieList(group: "", sort: "year", unlocked: false, offset: 0, limit: 10)
        XCTAssertEqual(movies.first?["name"] as? String, "Dune (2021)")
        XCTAssertEqual(db.movieCount(group: "Films", unlocked: false), 2)
        let groups = try db.groups(kind: "series", includeHidden: false)
        XCTAssertEqual(groups.first?["name"] as? String, "Series")
        XCTAssertEqual(groups.first?["n"] as? Int64, 2)
        let s = try db.series("S|suits")
        XCTAssertEqual((s?["episodes"] as? [Row])?.count, 3)
        XCTAssertEqual(s?["n_seasons"] as? Int64, 2)
        let found = try db.search("dune", unlocked: false, limit: 10)
        XCTAssertEqual((found["movie"] as? [Row])?.count, 1)
    }

    func testReimportReplaces() throws {
        let pid = try importFile(sample)
        var events: [(String, [String: Any])] = []
        let imp = Importer(db: db, dbPath: path, cacheDir: dir) { events.append(($0, $1)) }
        imp.demoFile = dir.appendingPathComponent("list.m3u")
        imp.refresh(pid)
        XCTAssertEqual(db.conn.scalar("SELECT COUNT(*) FROM live"), 2)
        XCTAssertEqual(db.conn.scalar("SELECT COUNT(*) FROM episode"), 4)
    }

    func testEmptyPlaylistFailsAndKeepsOldData() throws {
        let pid = try importFile(sample)
        let f = dir.appendingPathComponent("list.m3u")
        try "#EXTM3U\n".write(to: f, atomically: true, encoding: .utf8)
        var events: [(String, [String: Any])] = []
        let imp = Importer(db: db, dbPath: path, cacheDir: dir) { events.append(($0, $1)) }
        imp.demoFile = f
        imp.refresh(pid)
        XCTAssertEqual(events.last?.1["ok"] as? Bool, false)
        XCTAssertEqual(db.conn.scalar("SELECT COUNT(*) FROM live"), 2)
    }

    func testFavouritesProgressAndContinue() throws {
        _ = try importFile(sample)
        XCTAssertTrue(try db.favToggle(kind: "movie", k: "M|dune (2021)", title: "Dune", logo: ""))
        XCTAssertEqual(try db.favList(kind: "movie", unlocked: false).count, 1)
        XCTAssertFalse(try db.favToggle(kind: "movie", k: "M|dune (2021)", title: "Dune", logo: ""))

        try db.saveProgress(["k": "E|suits|1|1", "kind": "episode", "title": "Suits", "series_k": "S|suits", "season": 1, "ep": 1, "pos": 2_400_000, "dur": 2_400_000, "done": true])
        try db.saveProgress(["k": "M|dune (2021)", "kind": "movie", "title": "Dune", "pos": 600_000, "dur": 9_000_000, "done": false])
        let cont = try db.continueList(limit: 10, unlocked: false)
        XCTAssertEqual(cont.count, 2)
        let next = cont.first { ($0["series_k"] as? String) == "S|suits" }
        XCTAssertEqual(next?["k"] as? String, "E|suits|1|2")
        XCTAssertEqual(next?["next"] as? Bool, true)

        let s = try db.series("S|suits")
        let ep1 = (s?["episodes"] as? [Row])?.first
        XCTAssertNotNil(ep1?["progress"])

        let h = try db.historyList()
        XCTAssertEqual((h["series"] as? [Row])?.count, 1)
        XCTAssertEqual((h["movies"] as? [Row])?.count, 1)
        XCTAssertEqual(try db.clearProgress(scope: "series", seriesK: "", k: ""), 1)
        XCTAssertEqual(try db.clearProgress(scope: "one", seriesK: "", k: "M|dune (2021)"), 1)
        XCTAssertEqual(try db.continueList(limit: 10, unlocked: false).count, 0)
    }

    func testParentalLockHidesGroups() throws {
        _ = try importFile(sample)
        try db.setGroupPref(kind: "movie", name: "Films", ["locked": true])
        XCTAssertEqual(try db.movieList(group: "", sort: "", unlocked: false, offset: 0, limit: 10).count, 0)
        XCTAssertEqual(try db.movieList(group: "", sort: "", unlocked: true, offset: 0, limit: 10).count, 2)
        try db.setGroupPref(kind: "movie", name: "Films", ["locked": false, "hidden": true])
        XCTAssertEqual(try db.movieList(group: "", sort: "", unlocked: true, offset: 0, limit: 10).count, 0)
    }

    func testDemoPlaylistFromTheApp() throws {
        guard let demo = Bundle.module.url(forResource: "demo", withExtension: "m3u", subdirectory: "Resources") else { return XCTFail("demo.m3u missing") }
        let pid = try db.addPlaylist(name: "Demo", url: Importer.demoURL, ua: "", epgUrl: "", autoHours: 0)
        var events: [(String, [String: Any])] = []
        let imp = Importer(db: db, dbPath: path, cacheDir: dir) { events.append(($0, $1)) }
        imp.demoFile = demo
        imp.refresh(pid)
        let done = events.last { $0.0 == "import.done" }?.1
        XCTAssertEqual(done?["ok"] as? Bool, true, "\(String(describing: done))")
        XCTAssertGreaterThanOrEqual(db.conn.scalar("SELECT COUNT(*) FROM live"), 3)
        XCTAssertGreaterThan(db.conn.scalar("SELECT COUNT(*) FROM movie") + db.conn.scalar("SELECT COUNT(*) FROM series"), 0)
    }
}

final class GzipTests: XCTestCase {
    func testGunzip() throws {
        // "hello topplayer\n" repeated, compressed with gzip -9
        let b64 = "H4sIAAAAAAAC/8tIzcnJVyjJLyjISaxMLeLKGOWTxAcAYVaWlkABAAA="
        guard let gz = Data(base64Encoded: b64) else { return XCTFail("fixture") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("x.xml")
        try gz.write(to: f)
        XCTAssertTrue(Gzip.isGzip(f))
        try Gzip.inflateInPlace(f)
        XCTAssertFalse(Gzip.isGzip(f))
        let text = String(decoding: try Data(contentsOf: f), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("hello topplayer"), text)
        XCTAssertEqual(text.count, 320)
        // plain files are left alone
        try Gzip.inflateInPlace(f)
        XCTAssertEqual(String(decoding: try Data(contentsOf: f), as: UTF8.self), text)
    }
}
