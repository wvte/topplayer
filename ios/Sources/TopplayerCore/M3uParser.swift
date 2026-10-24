import Foundation

/// Streaming, forgiving M3U / M3U8 (extended) playlist parser. Port of the Android M3uParser.
public final class M3uEntry {
    public var name = ""
    public var url = ""
    public var group = ""
    public var userAgent: String?
    public var referrer: String?
    var fromExtInf = false
    public var attrs: [String: String] = [:]

    public init() {}

    public func attr(_ k: String) -> String { attrs[k] ?? "" }
}

public enum M3uParser {
    /// Calls onHeader for #EXTM3U and onEntry for every channel; onEntry returns false to stop.
    @discardableResult
    public static func parse(nextLine: () -> String?, onHeader: ([String: String]) -> Void, onEntry: (M3uEntry) -> Bool) -> Int {
        var cur: M3uEntry?
        var count = 0
        var first = true
        while var line = nextLine() {
            if first {
                if line.unicodeScalars.first == "\u{FEFF}" { line.unicodeScalars.removeFirst() }
                first = false
            }
            line = line.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let upper = String(line.prefix(12)).uppercased()
                if upper.hasPrefix("#EXTM3U") {
                    var h: [String: String] = [:]
                    _ = parseAttributes(line.substr(7, line.utf16.count), 0, &h)
                    onHeader(h)
                } else if upper.hasPrefix("#EXTINF:") {
                    let before = (cur != nil && !(cur!.fromExtInf)) ? cur : nil
                    let e = M3uEntry()
                    e.fromExtInf = true
                    parseExtInf(line.substr(8, line.utf16.count), e)
                    if let b = before {
                        if e.userAgent == nil { e.userAgent = b.userAgent }
                        if e.referrer == nil { e.referrer = b.referrer }
                        if e.group.isEmpty { e.group = b.group }
                    }
                    cur = e
                } else if upper.hasPrefix("#EXTGRP:") {
                    if cur == nil { cur = M3uEntry() }
                    if cur!.group.isEmpty { cur!.group = line.substr(8, line.utf16.count).trimmed }
                } else if upper.hasPrefix("#EXTVLCOPT") {
                    if cur == nil { cur = M3uEntry() }
                    var opt = ""
                    if let colon = line.firstIndex(of: ":") { opt = String(line[line.index(after: colon)...]).trimmed }
                    let lo = opt.lowercased()
                    if lo.hasPrefix("http-user-agent=") { cur!.userAgent = stripQuotes(opt.substr(16, opt.utf16.count)) }
                    else if lo.hasPrefix("http-referrer=") { cur!.referrer = stripQuotes(opt.substr(14, opt.utf16.count)) }
                    else if lo.hasPrefix("http-referer=") { cur!.referrer = stripQuotes(opt.substr(13, opt.utf16.count)) }
                }
                continue
            }
            // a URL line
            let e: M3uEntry
            if let c = cur { e = c } else {
                e = M3uEntry()
                e.name = line
            }
            var url = line
            // Kodi style "url|User-Agent=...&Referer=..."
            if let pipe = url.firstIndex(of: "|"), pipe != url.startIndex {
                let opts = String(url[url.index(after: pipe)...])
                url = String(url[..<pipe])
                for kv in opts.split(separator: "&", omittingEmptySubsequences: false) {
                    guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { continue }
                    let k = String(kv[..<eq]).trimmed.lowercased()
                    let v = Text.urlDecode(String(kv[kv.index(after: eq)...]).trimmed)
                    if k == "user-agent" { e.userAgent = v }
                    else if k == "referer" || k == "referrer" { e.referrer = v }
                }
            }
            e.url = url
            if e.group.isEmpty { e.group = e.attr("group-title") }
            if e.name.isEmpty { e.name = e.attr("tvg-name") }
            if e.name.isEmpty { e.name = url }
            count += 1
            if !onEntry(e) { break }
            cur = nil
        }
        return count
    }

    static func parseExtInf(_ s: String, _ e: M3uEntry) {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count && u[i] != 32 && u[i] != 44 && u[i] != 9 { i += 1 }
        let nameStart = parseAttributes(s, i, &e.attrs)
        if nameStart >= 0 && nameStart <= u.count { e.name = String(decoding: u[nameStart...], as: UTF16.self).trimmed }
        e.group = e.attr("group-title")
    }

    /// Parses key="value" pairs from index i until a comma outside quotes. Returns the index after that comma or -1.
    static func parseAttributes(_ s: String, _ start: Int, _ out: inout [String: String]) -> Int {
        let u = Array(s.utf16)
        let n = u.count
        var i = start
        func str(_ a: Int, _ b: Int) -> String { String(decoding: u[a..<max(a, b)], as: UTF16.self) }
        while i < n {
            let c = u[i]
            if c == 44 { return i + 1 }
            if c == 32 || c == 9 { i += 1; continue }
            let ks = i
            while i < n && u[i] != 61 && u[i] != 32 && u[i] != 44 { i += 1 }
            let key = str(ks, i).trimmed.lowercased()
            if i < n && u[i] == 61 {
                i += 1
                var val: String
                if i < n && (u[i] == 34 || u[i] == 39) {
                    let q = u[i]
                    i += 1
                    let vs = i
                    while i < n && u[i] != q { i += 1 }
                    val = str(vs, min(i, n))
                    if i < n { i += 1 }
                } else {
                    let vs = i
                    while i < n && u[i] != 32 && u[i] != 44 { i += 1 }
                    val = str(vs, i)
                }
                if !key.isEmpty { out[key] = val.trimmed }
            } else if i < n && u[i] == 44 {
                return i + 1
            }
        }
        return -1
    }

    static func stripQuotes(_ v: String) -> String {
        let t = v.trimmed
        let u = Array(t.utf16)
        if u.count >= 2 && (u[0] == 34 || u[0] == 39) && u[u.count - 1] == u[0] { return String(decoding: u[1..<(u.count - 1)], as: UTF16.self) }
        return t
    }
}
