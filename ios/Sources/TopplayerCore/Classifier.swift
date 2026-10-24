import Foundation

/// Decides whether a playlist entry is a live channel, a film or a series episode. Port of the Android Classifier.
public enum Classifier {
    public static let live = 0, movie = 1, episode = 2

    public struct Result {
        public var kind = 0
        public var seriesName = ""
        public var season = 0
        public var episode = 0
        public var episodeTitle = ""
        public var year = 0
        public var title = ""
    }

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let epSxe = rx(#"^(.*?)[\s._\-:|]*\b[Ss](?:eason|eizoen)?\s*\.?(\d{1,3})[\s._\-]*[Ee](?:p(?:isode)?)?\s*\.?(\d{1,4})(?!\d)(.*)$"#)
    private static let epX = rx(#"^(.*?)[\s._\-:|]+(\d{1,2})x(\d{1,3})(?!\d)(.*)$"#)
    private static let epWords = rx(#"^(.*?)[\s._\-:|]*(?:Season|Seizoen|Staffel|Saison)\s*(\d{1,3})[\s._\-,]*(?:Episode|Aflevering|Afl\.?|Folge|Ep\.?)\s*(\d{1,4})(?!\d)(.*)$"#, .caseInsensitive)
    private static let yearRx = rx(#"[\(\[]((?:19|20)\d{2})[\)\]]|\s-\s((?:19|20)\d{2})\s*$|\s((?:19|20)\d{2})\s*$"#)
    private static let leadSep = rx(#"^[\s\-:|.]+"#)
    private static let trailSep = rx(#"[\s._\-:|]+$"#)
    private static let multiSpace = rx(#"\s{2,}"#)
    private static let epgPrefix = rx(#"^\s*[\[(]?[A-Za-z]{2,3}[\])]?\s*[:|\-]+\s*"#)
    private static let epgQuality = rx(#"\b(?:uhd|fhd|hd|sd|hevc|h265|4k|8k|50fps|60fps|backup|raw|vip|plus\+)\b"#)
    private static let whitespace = rx(#"\s+"#)
    private static let seasonWords = ["eason", "eizoen", "taffel", "aison"]
    private static let vodExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "mpg", "mpeg", "divx", "ogv", "3gp", "vob", "xvid"]

    static var latestYear: Int { Calendar.current.component(.year, from: Date()) + 1 }

    public static func classify(_ e: M3uEntry) -> Result {
        var r = Result()
        let lowerUrl = e.url.lowercased()
        var type = e.attr("tvg-type").lowercased()
        if type.isEmpty { type = e.attr("type").lowercased() }
        let group = e.group.lowercased()

        var kind: Int
        if type == "live" || type == "stream" { kind = live }
        else if type == "movie" || type == "movies" || type == "vod" { kind = movie }
        else if type == "series" || type == "serie" || type == "tvshow" { kind = episode }
        else if lowerUrl.contains("/movie/") { kind = movie }
        else if lowerUrl.contains("/series/") { kind = episode }
        else if lowerUrl.contains("/live/") { kind = live }
        else if isVodExtension(lowerUrl) { kind = movie }
        else { kind = live }

        if kind != live {
            let parsed = parseEpisode(e.name, &r)
            if kind == episode && !parsed {
                r.seriesName = cleanSeriesName(e.name)
                r.season = 1
                r.episode = 0
                r.episodeTitle = ""
            } else if kind == movie && parsed && looksLikeSeriesGroup(group) {
                kind = episode
            } else if kind == movie && parsed && !looksLikeMovieGroup(group) {
                kind = episode
            }
            if kind == movie {
                r.title = e.name
                r.year = extractYear(e.name)
            }
        }
        r.kind = kind
        return r
    }

    static func looksLikeSeriesGroup(_ g: String) -> Bool {
        g.contains("serie") || g.contains("series") || g.contains("show") || g.contains("tv-") || g.contains("netflix")
            || g.contains("seizoen") || g.contains("season")
    }

    static func looksLikeMovieGroup(_ g: String) -> Bool {
        g.contains("movie") || g.contains("film") || g.contains("cinema") || (g.contains("vod") && !g.contains("serie"))
    }

    static func isVodExtension(_ lowerUrl: String) -> Bool {
        var path = lowerUrl
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard let dot = path.lastIndex(of: ".") else { return false }
        if let slash = path.lastIndex(of: "/"), dot < slash { return false }
        return vodExt.contains(String(path[path.index(after: dot)...]))
    }

    /// Cheap scan that is true for every name the three episode patterns can match, so most films skip the regexes.
    static func mayBeEpisode(_ name: String) -> Bool {
        let n = Array(name.utf16)
        let len = n.count
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        var i = 0
        while i < len {
            let c = n[i]
            if c == 115 || c == 83 { // s S
                var j = i + 1
                for w in seasonWords {
                    let wu = Array(w.utf16)
                    if j + wu.count <= len, String(decoding: n[j..<(j + wu.count)], as: UTF16.self).lowercased() == w {
                        j += wu.count
                        break
                    }
                }
                while j < len, n[j] == 32 || n[j] == 9 || n[j] == 10 || n[j] == 13 { j += 1 }
                if j < len, n[j] == 46 { j += 1 }
                if j < len, isDigit(n[j]) { return true }
            } else if c == 120, i > 0, i + 1 < len { // x
                if isDigit(n[i - 1]) && isDigit(n[i + 1]) { return true }
            }
            i += 1
        }
        return false
    }

    private static func fullMatch(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: s, options: [], range: all), m.range == all else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func parseEpisode(_ name: String, _ r: inout Result) -> Bool {
        if !mayBeEpisode(name) { return false }
        guard let g = fullMatch(epSxe, name) ?? fullMatch(epWords, name) ?? fullMatch(epX, name) else { return false }
        let show = cleanSeriesName(g[1])
        if show.isEmpty { return false }
        guard let season = Int(g[2]), let ep = Int(g[3]) else { return false }
        r.season = season
        r.episode = ep
        r.seriesName = show
        var rest = g[4].trimmed
        rest = replaceFirst(leadSep, rest, "").trimmed
        if !rest.contains(" ") { rest = rest.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmed }
        r.episodeTitle = rest
        return true
    }

    private static func replaceFirst(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return s }
        return ns.replacingCharacters(in: m.range, with: with)
    }

    private static func replaceAll(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    static func cleanSeriesName(_ s: String) -> String {
        var t = replaceFirst(trailSep, s.trimmed, "")
        t = t.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return replaceAll(multiSpace, t, " ").trimmed
    }

    /// Release year from a title, or 0. Years in the far future (like "Blade Runner 2049") are not release years.
    public static func extractYear(_ name: String) -> Int {
        let ns = name as NSString
        var y = 0
        let latest = latestYear
        for m in yearRx.matches(in: name, options: [], range: NSRange(location: 0, length: ns.length)) {
            for g in 1...3 where m.range(at: g).location != NSNotFound {
                if let found = Int(ns.substring(with: m.range(at: g))), found <= latest { y = found }
            }
        }
        return y
    }

    /// Keys identify a channel or film for favourites and history. The first one keeps the plain key, later ones with
    /// the same name get the group and if needed a counter.
    static func uniqueKey(_ used: inout KeySet, _ base: String, _ group: String) -> String {
        var key = base
        if used.add(key) { return key }
        key = base + "|" + group.lowercased()
        var n = 2
        while !used.add(key) {
            key = base + "|" + group.lowercased() + "|" + String(n)
            n += 1
        }
        return key
    }

    /// Lowercase, accent free, alphanumeric search key.
    public static func normalize(_ s: String?) -> String {
        guard let s = s else { return "" }
        var out = String.UnicodeScalarView()
        var space = false
        for sc in s.decomposedStringWithCanonicalMapping.unicodeScalars {
            let cat = sc.properties.generalCategory
            if cat == .nonspacingMark { continue }
            if sc.properties.isAlphabetic || cat == .decimalNumber {
                out.append(contentsOf: sc.properties.lowercaseMapping.unicodeScalars)
                space = false
            } else if !space && !out.isEmpty {
                out.append(" ")
                space = true
            }
        }
        if out.last == " " { out.removeLast() }
        return String(out)
    }

    /// Key used to match EPG channels by name. Drops quality tags like HD/FHD/4K and country prefixes.
    public static func epgNameKey(_ s: String?) -> String {
        let raw = s == nil ? "" : replaceFirst(epgPrefix, s!, "")
        var n = normalize(raw)
        n = replaceAll(epgQuality, n, " ")
        return replaceAll(whitespace, n, "")
    }
}

/// Remembers which keys were used, 8 bytes per key instead of the whole text (see the Android KeySet).
public struct KeySet {
    private var hashes = Set<UInt64>()

    public init() {}

    /// true when the key was new
    mutating func add(_ key: String) -> Bool { hashes.insert(KeySet.hash(key)).inserted }

    public var count: Int { hashes.count }

    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for c in s.utf16 {
            h ^= UInt64(c)
            h = h &* 0x100000001b3
        }
        h ^= h >> 33
        h = h &* 0xff51afd7ed558ccd
        h ^= h >> 33
        return h == 0 ? 1 : h
    }
}
