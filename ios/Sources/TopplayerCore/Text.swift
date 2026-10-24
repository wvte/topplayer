import Foundation

/// Small string helpers shared by the parsers (the Android code works on UTF-16 indexes, so does this).
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func substr(_ a: Int, _ b: Int) -> String {
        let u = Array(utf16)
        let lo = max(0, min(a, u.count)), hi = max(lo, min(b, u.count))
        return String(decoding: u[lo..<hi], as: UTF16.self)
    }
}

enum Text {
    /// Percent-encodes everything except letters, digits and - . _ ~ (same as the Android app).
    static func enc(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Int(b)
            if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 45 || c == 46 || c == 95 || c == 126 {
                out.unicodeScalars.append(UnicodeScalar(UInt8(c)))
            } else {
                out += String(format: "%%%02X", c)
            }
        }
        return out
    }

    static func urlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

/// Reads a text file line by line without loading it (playlists can be 100 MB).
public final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var eof = false
    public private(set) var bytesRead: Int64 = 0

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    public func nextLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            if eof {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = Data()
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { eof = true } else {
                bytesRead += Int64(chunk.count)
                buffer.append(chunk)
            }
        }
    }
}
