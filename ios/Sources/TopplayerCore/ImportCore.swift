import Foundation

/// Everything the importer decides about playlist entries, without database code (so it can be tested).
/// Port of the Android ImportCore.
public final class ImportRow {
    public static let seriesXt = 3
    public var kind = 0 // Classifier.live / movie / episode / seriesXt
    public var ord = 0
    public var grp = ""
    public var logo = ""
    public var name = ""
    public var url = ""
    public var ua: String?
    public var ref: String?
    public var key = ""
    public var sname = ""
    public var num = 0
    public var epgKey = ""
    public var year = 0
    public var seriesKey = ""
    public var seriesName = ""
    public var seriesLower = ""
    public var seriesNorm: String?
    public var season = 0
    public var episode = 0
    public var episodeTitle = ""
    public var xtId: Int64 = 0
}

public protocol ImportStore: AnyObject {
    func insertLive(_ r: ImportRow)
    func insertMovie(_ r: ImportRow)
    func insertSeries(_ r: ImportRow) -> Int64
    func insertEpisode(_ r: ImportRow, seriesId: Int64, key: String, episode: Int, title: String)
}

public final class ImportCore {
    private var ord = 0
    private var liveNum = 0
    private var usedKeys = KeySet()
    private var seenSeries = Set<String>()

    public init() {}

    public func build(_ e: M3uEntry) -> ImportRow {
        let c = Classifier.classify(e)
        let r = ImportRow()
        r.kind = c.kind
        r.ord = ord; ord += 1
        r.grp = e.group.trimmed
        var logo = e.attr("tvg-logo")
        if logo.isEmpty { logo = e.attr("logo") }
        r.logo = logo
        r.name = e.name.trimmed
        r.url = e.url
        r.ua = e.userAgent
        r.ref = e.referrer
        if c.kind == Classifier.live {
            liveNum += 1
            var num = 0
            var ch = e.attr("tvg-chno")
            if ch.isEmpty { ch = e.attr("channel-number") }
            if !ch.isEmpty { num = Int(ch.trimmed) ?? 0 }
            r.num = num <= 0 ? liveNum : num
            let tvgId = e.attr("tvg-id").trimmed.lowercased()
            r.epgKey = !tvgId.isEmpty ? tvgId : "n:" + Classifier.epgNameKey(e.attr("tvg-name").isEmpty ? r.name : e.attr("tvg-name"))
            r.key = Classifier.uniqueKey(&usedKeys, "L|" + r.name.lowercased(), r.grp)
            r.sname = Classifier.normalize(r.name)
        } else if c.kind == Classifier.movie {
            r.key = Classifier.uniqueKey(&usedKeys, "M|" + r.name.lowercased(), r.grp)
            r.sname = Classifier.normalize(r.name)
            r.year = c.year
        } else {
            r.seriesName = c.seriesName
            r.seriesLower = c.seriesName.lowercased()
            r.seriesKey = "S|" + r.seriesLower
            r.season = c.season
            r.episode = c.episode
            r.episodeTitle = c.episodeTitle
            if seenSeries.insert(r.seriesKey).inserted { r.seriesNorm = Classifier.normalize(c.seriesName) }
        }
        return r
    }

    // Xtream API rows: names, icons, categories and addresses come ready made.

    public func buildLive(name: String, logo: String?, grp: String?, url: String, epgId: String?) -> ImportRow {
        let r = ImportRow()
        r.kind = Classifier.live
        r.ord = ord; ord += 1
        r.grp = grp ?? ""
        r.logo = logo ?? ""
        r.name = name
        r.url = url
        liveNum += 1
        r.num = liveNum
        let id = (epgId ?? "").trimmed.lowercased()
        r.epgKey = !id.isEmpty ? id : "n:" + Classifier.epgNameKey(name)
        r.key = Classifier.uniqueKey(&usedKeys, "L|" + name.lowercased(), r.grp)
        r.sname = Classifier.normalize(name)
        return r
    }

    public func buildMovie(name: String, logo: String?, grp: String?, url: String, year: Int) -> ImportRow {
        let r = ImportRow()
        r.kind = Classifier.movie
        r.ord = ord; ord += 1
        r.grp = grp ?? ""
        r.logo = logo ?? ""
        r.name = name
        r.url = url
        r.key = Classifier.uniqueKey(&usedKeys, "M|" + name.lowercased(), r.grp)
        r.sname = Classifier.normalize(name)
        r.year = year
        return r
    }

    public func buildSeriesXt(name: String, logo: String?, grp: String?, xtId: Int64) -> ImportRow {
        let r = ImportRow()
        r.kind = ImportRow.seriesXt
        r.ord = ord; ord += 1
        r.grp = grp ?? ""
        r.logo = logo ?? ""
        r.name = name
        r.seriesName = name
        r.seriesLower = name.lowercased()
        r.seriesKey = Classifier.uniqueKey(&usedKeys, "S|" + r.seriesLower, r.grp)
        r.seriesNorm = Classifier.normalize(name)
        r.xtId = xtId
        return r
    }

    // consume side
    public private(set) var counts = [0, 0, 0, 0] // live, movies, series, episodes
    private var seriesIds: [String: Int64] = [:]
    public private(set) var seriesEpisodes: [Int64: Int] = [:]
    public private(set) var seriesSeasons: [Int64: Set<Int>] = [:]
    public private(set) var seriesLogo: [Int64: String] = [:]
    public private(set) var groups: [(kind: String, name: String, firstOrd: Int, count: Int)] = []
    private var groupIndex: [String: Int] = [:]

    public func consume(_ r: ImportRow, _ store: ImportStore) {
        var grp: String? = r.grp
        var kindName: String
        if r.kind == Classifier.live {
            kindName = "live"
            store.insertLive(r)
            counts[0] += 1
        } else if r.kind == Classifier.movie {
            kindName = "movie"
            store.insertMovie(r)
            counts[1] += 1
        } else if r.kind == ImportRow.seriesXt {
            kindName = "series"
            _ = store.insertSeries(r)
            counts[2] += 1
        } else {
            kindName = "series"
            var sid = seriesIds[r.seriesKey]
            if sid == nil {
                if r.seriesNorm == nil { r.seriesNorm = Classifier.normalize(r.seriesName) }
                let id = store.insertSeries(r)
                sid = id
                seriesIds[r.seriesKey] = id
                seriesEpisodes[id] = 0
                seriesSeasons[id] = []
                counts[2] += 1
                if !r.logo.isEmpty { seriesLogo[id] = r.logo }
            } else {
                // a series only counts towards the group of its first episode
                grp = nil
                if seriesLogo[sid!] == nil && !r.logo.isEmpty { seriesLogo[sid!] = r.logo }
            }
            let id = sid!
            let season = r.season
            var ep = r.episode
            if ep == 0 { ep = (seriesEpisodes[id] ?? 0) + 1 }
            let key = "E|" + r.seriesLower + "|" + String(season) + "|" + String(ep)
            let title = r.episodeTitle.isEmpty ? r.name : r.episodeTitle
            store.insertEpisode(r, seriesId: id, key: key, episode: ep, title: title)
            seriesEpisodes[id, default: 0] += 1
            seriesSeasons[id, default: []].insert(season)
            counts[3] += 1
        }
        if let g = grp {
            let gk = kindName + "|" + g
            if let i = groupIndex[gk] { groups[i].count += 1 } else {
                groupIndex[gk] = groups.count
                groups.append((kindName, g, r.ord, 1))
            }
        }
    }
}
