import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Plain http:// over a socket of our own, the way the TV app fetches a playlist.
///
/// Why: on a Mac or iPhone, URLSession sends unencrypted HTTP from apps through iCloud Private Relay when that is on.
/// The IPTV server then sees an Apple relay address instead of the home connection, and many providers refuse those
/// (odd answers like HTTP 512). A socket of our own goes straight out, over IPv4 first, like the TV.
public enum DirectHTTP {
    /// The server answered with an error status. `message` is like "HTTP 512: text from the server".
    public struct ServerAnswer: Error {
        public let status: Int
        public let message: String
    }

    /// The connection itself did not work (no route, timeout, closed early). The caller may try another way.
    public struct Failure: Error {
        public let message: String
    }

    public enum Outcome {
        /// the body is in the file (as sent: it may be gzip)
        case saved
        /// the server sent us to an https:// address: the system's own HTTP stack handles that
        case https(String)
    }

    /// Downloads an http:// address into `target`, following up to five redirects.
    public static func fetch(_ address: String, ua: String, to target: URL, connectTimeout: Double = 15, readTimeout: Double = 45,
                             progress: ((Int64, Int64) -> Void)? = nil) throws -> Outcome {
        var current = address
        for _ in 0..<6 {
            guard let c = components(current), let host = c.host, !host.isEmpty else { throw Failure(message: "Bad address") }
            let scheme = (c.scheme ?? "").lowercased()
            if scheme == "https" { return .https(current) }
            guard scheme == "http" else { throw Failure(message: "Not an http address") }
            let port = c.port ?? 80
            var path = c.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let q = c.percentEncodedQuery { path += "?" + q }
            let hostHeader = (host.contains(":") ? "[" + host + "]" : host) + (port == 80 ? "" : ":\(port)")

            let fd = try open(host: host, port: port, connectTimeout: connectTimeout, readTimeout: readTimeout)
            defer { close(fd) }
            let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: \(ua)\r\nAccept: */*\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
            try sendAll(fd, Array(req.utf8))

            let r = Reader(fd: fd)
            var (status, headers) = try r.readHead()
            while status == 100 { (status, headers) = try r.readHead() }

            if [301, 302, 303, 307, 308].contains(status), let loc = headers["location"], !loc.isEmpty {
                guard let next = URL(string: loc, relativeTo: URL(string: current))?.absoluteURL.absoluteString else {
                    throw Failure(message: "Bad redirect")
                }
                current = next
                continue
            }

            let chunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
            let length = headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }

            if status >= 400 {
                // keep a little of the body: providers often say why in it
                var head: [UInt8] = []
                try? r.readBody(chunked: chunked, length: length) { part in
                    if head.count < 2048 { head.append(contentsOf: part.prefix(2048 - head.count)) }
                    if head.count >= 2048 { throw Failure(message: "enough") }
                }
                throw ServerAnswer(status: status, message: errorText(status, head))
            }

            try? FileManager.default.removeItem(at: target)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw Failure(message: "Cannot write the file") }
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            var done: Int64 = 0
            var lastReport: Int64 = 0
            var pending = Data()
            try r.readBody(chunked: chunked, length: length) { part in
                pending.append(contentsOf: part)
                done += Int64(part.count)
                if pending.count >= 256 * 1024 {
                    try out.write(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
                if let p = progress, done - lastReport >= 256 * 1024 {
                    lastReport = done
                    p(done, length ?? -1)
                }
            }
            if !pending.isEmpty { try out.write(contentsOf: pending) }
            progress?(done, length ?? -1)
            return .saved
        }
        throw Failure(message: "Too many redirects")
    }

    public enum ProbeOutcome {
        /// what the server answered (status, content type, and for an error the start of its text)
        case answer(status: Int, type: String?, text: String)
        /// the address leads to https://, which the system checks
        case https(String)
    }

    /// Asks for the first kilobyte of a stream over our own socket, straight from the home connection like the
    /// players do: tells whether the server answers, and with what. Nothing more is downloaded.
    public static func probe(_ address: String, ua: String, timeout: Double = 8) throws -> ProbeOutcome {
        var current = address
        for _ in 0..<6 {
            guard let c = components(current), let host = c.host, !host.isEmpty else { throw Failure(message: "Bad address") }
            let scheme = (c.scheme ?? "").lowercased()
            if scheme == "https" { return .https(current) }
            guard scheme == "http" else { throw Failure(message: "Not an http address") }
            let port = c.port ?? 80
            var path = c.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let q = c.percentEncodedQuery { path += "?" + q }
            let hostHeader = (host.contains(":") ? "[" + host + "]" : host) + (port == 80 ? "" : ":\(port)")
            let fd = try open(host: host, port: port, connectTimeout: timeout, readTimeout: timeout)
            defer { close(fd) }
            let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: \(ua)\r\nAccept: */*\r\nRange: bytes=0-1023\r\nConnection: close\r\n\r\n"
            try sendAll(fd, Array(req.utf8))
            let r = Reader(fd: fd)
            var (status, headers) = try r.readHead()
            while status == 100 { (status, headers) = try r.readHead() }
            if [301, 302, 303, 307, 308].contains(status), let loc = headers["location"], !loc.isEmpty {
                guard let next = URL(string: loc, relativeTo: URL(string: current))?.absoluteURL.absoluteString else {
                    throw Failure(message: "Bad redirect")
                }
                current = next
                continue
            }
            var text = ""
            if status >= 400 {
                let chunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
                let length = headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                var head: [UInt8] = []
                try? r.readBody(chunked: chunked, length: length) { part in
                    if head.count < 1024 { head.append(contentsOf: part.prefix(1024 - head.count)) }
                    if head.count >= 1024 { throw Failure(message: "enough") }
                }
                text = errorText(status, head)
            }
            return .answer(status: status, type: headers["content-type"], text: text)
        }
        throw Failure(message: "Too many redirects")
    }

    /// "HTTP 512" plus the start of the text the server sent along (tags and extra spaces removed).
    public static func errorText(_ status: Int, _ body: [UInt8]) -> String {
        var s = String(decoding: body, as: UTF8.self)
        s = s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if s.count > 120 { s = String(s.prefix(117)) + "..." }
        return s.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(s)"
    }

    static func components(_ s: String) -> URLComponents? {
        URLComponents(string: s) ?? URLComponents(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }

    // MARK: socket

    /// Connects to the first address that answers, IPv4 before IPv6 (the address an IPTV account usually knows).
    static func open(host: String, port: Int, connectTimeout: Double, readTimeout: Double) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else { throw Failure(message: "Server not found (DNS)") }
        defer { freeaddrinfo(first) }
        var addrs: [UnsafeMutablePointer<addrinfo>] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p { addrs.append(a); p = a.pointee.ai_next }
        addrs.sort { ($0.pointee.ai_family == AF_INET ? 0 : 1) < ($1.pointee.ai_family == AF_INET ? 0 : 1) }

        var why = "no address"
        for a in addrs {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { why = String(cString: strerror(errno)); continue }
            var one: Int32 = 1
            #if canImport(Darwin)
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = false
            if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                ok = true
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(connectTimeout * 1000)) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { ok = true } else { why = String(cString: strerror(err)) }
                } else {
                    why = "no answer within \(Int(connectTimeout)) s"
                }
            } else {
                why = String(cString: strerror(errno))
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags)
                var tv = timeval()
                tv.tv_sec = Int(readTimeout)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                return fd
            }
            close(fd)
        }
        throw Failure(message: "Cannot connect (\(why))")
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { b in send(fd, b.baseAddress! + off, b.count - off, 0) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw Failure(message: "Sending the request failed") }
            off += n
        }
    }

    /// Reads an HTTP answer from a socket: the head, then the body as it comes (plain, chunked or until closed).
    final class Reader {
        let fd: Int32
        private var buf = [UInt8](repeating: 0, count: 65536)
        private var data: [UInt8] = []
        private var pos = 0

        init(fd: Int32) { self.fd = fd }

        var available: Int { data.count - pos }

        /// More bytes from the socket; false when the server closed the connection.
        func fill() throws -> Bool {
            if pos > 0 { data.removeFirst(pos); pos = 0 }
            while true {
                let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n > 0 { data.append(contentsOf: buf[0..<n]); return true }
                if n == 0 { return false }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure(message: "The server stopped sending (timeout)") }
                throw Failure(message: "Reading failed (" + String(cString: strerror(errno)) + ")")
            }
        }

        private func find(_ pattern: [UInt8]) -> Int? {
            guard data.count - pos >= pattern.count else { return nil }
            var i = pos
            let last = data.count - pattern.count
            while i <= last {
                if data[i] == pattern[0] {
                    var j = 1
                    while j < pattern.count && data[i + j] == pattern[j] { j += 1 }
                    if j == pattern.count { return i }
                }
                i += 1
            }
            return nil
        }

        func readLine() throws -> String {
            while true {
                if let i = find([13, 10]) {
                    let line = String(decoding: data[pos..<i], as: UTF8.self)
                    pos = i + 2
                    return line
                }
                if available > 16384 { throw Failure(message: "Line too long") }
                if try !fill() { throw Failure(message: "The connection closed early") }
            }
        }

        /// Status and headers (names in lower case).
        func readHead() throws -> (Int, [String: String]) {
            var end: Int?
            while true {
                end = find([13, 10, 13, 10])
                if end != nil { break }
                if available > 65536 { throw Failure(message: "Answer head too long") }
                if try !fill() { throw Failure(message: available == 0 ? "The server closed the connection without an answer" : "The connection closed early") }
            }
            let text = String(decoding: data[pos..<end!], as: UTF8.self)
            pos = end! + 4
            var lines = text.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, let status = Int(parts[1]) else { throw Failure(message: "No HTTP answer") }
            var headers: [String: String] = [:]
            for l in lines {
                guard let colon = l.firstIndex(of: ":") else { continue }
                let k = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = headers[k].map { $0 + ", " + v } ?? v
            }
            return (status, headers)
        }

        /// Hands the body over in pieces as it arrives.
        func readBody(chunked: Bool, length: Int64?, _ sink: (ArraySlice<UInt8>) throws -> Void) throws {
            if chunked {
                while true {
                    let line = try readLine()
                    let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard let size = Int(hex, radix: 16) else { throw Failure(message: "Bad chunk in the answer") }
                    if size == 0 { return }
                    var left = size
                    while left > 0 {
                        if available == 0, try !fill() { throw Failure(message: "The connection closed in the middle") }
                        let n = min(left, available)
                        try sink(data[pos..<(pos + n)])
                        pos += n
                        left -= n
                    }
                    _ = try readLine()
                }
            } else if let total = length {
                var left = total
                while left > 0 {
                    if available == 0, try !fill() {
                        throw Failure(message: "The connection closed after \(total - left) of \(total) bytes")
                    }
                    let n = Int(min(Int64(available), left))
                    try sink(data[pos..<(pos + n)])
                    pos += n
                    left -= Int64(n)
                }
            } else {
                while true {
                    if available > 0 {
                        try sink(data[pos..<data.count])
                        pos = data.count
                    }
                    if try !fill() { return }
                }
            }
        }
    }
}
