import XCTest
import Darwin
@testable import TopplayerCore

/// A tiny HTTP server on 127.0.0.1 that answers each connection once and closes it.
final class TinyServer {
    let fd: Int32
    let port: UInt16
    private let handler: (String, [String: String]) -> [UInt8]

    init(_ handler: @escaping (_ path: String, _ headers: [String: String]) -> [UInt8]) {
        self.handler = handler
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, size) } }
        precondition(rc == 0, "bind failed")
        listen(s, 16)
        var len = size
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        let me = self
        Thread.detachNewThread { me.loop() }
    }

    var base: String { "http://127.0.0.1:\(port)" }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

    private func loop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var req: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            while !TinyServer.hasEnd(req) {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                req += buf[0..<n]
            }
            let text = String(decoding: req, as: UTF8.self)
            var lines = text.components(separatedBy: "\r\n")
            let first = lines.isEmpty ? "" : lines.removeFirst()
            let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for l in lines {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let resp = handler(path, headers)
            resp.withUnsafeBufferPointer { b in
                var off = 0
                while off < b.count {
                    let n = send(c, b.baseAddress! + off, b.count - off, 0)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(c)
        }
    }

    static func hasEnd(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return true }
        return false
    }

    static func answer(_ status: String, _ headers: [String], _ body: [UInt8]) -> [UInt8] {
        Array(("HTTP/1.1 " + status + "\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n").utf8) + body
    }
}

final class NetTests: XCTestCase {
    static var server: TinyServer!
    static var hits: [String: Int] = [:]
    static let lock = NSLock()

    override class func setUp() {
        super.setUp()
        let gz = [UInt8](Data(base64Encoded: "H4sIAAAAAAAC/8tIzcnJV0ivyiwAABlq0t8KAAAA")!)
        let big = [UInt8](repeating: 65, count: 1_500_000)
        server = TinyServer { path, headers in
            NetTests.lock.lock(); NetTests.hits[path, default: 0] += 1; NetTests.lock.unlock()
            switch path {
            case "/plain": return TinyServer.answer("200 OK", ["Content-Length: 5"], Array("hello".utf8))
            case "/chunked": return TinyServer.answer("200 OK", ["Transfer-Encoding: chunked"], Array("3\r\nhel\r\n8;x=y\r\nlo world\r\n0\r\n\r\n".utf8))
            case "/gzip": return TinyServer.answer("200 OK", ["Content-Length: \(gz.count)", "Content-Encoding: gzip"], gz)
            case "/redirect": return TinyServer.answer("302 Found", ["Location: /plain", "Content-Length: 0"], [])
            case "/close": return TinyServer.answer("200 OK", [], Array("until the end".utf8))
            case "/ua": let v = Array((headers["user-agent"] ?? "").utf8); return TinyServer.answer("200 OK", ["Content-Length: \(v.count)"], v)
            case "/big": return TinyServer.answer("200 OK", ["Content-Length: \(big.count)"], big)
            case "/q?username=a%20b&password=c": return TinyServer.answer("200 OK", ["Content-Length: 2"], Array("ok".utf8))
            case "/blocked":
                let b = Array("<html><body><h1>Access denied</h1> IP not allowed</body></html>".utf8)
                return TinyServer.answer("512 Blocked", ["Content-Length: \(b.count)"], b)
            default: return TinyServer.answer("404 Not Found", ["Content-Length: 0"], [])
            }
        }
    }

    override class func tearDown() {
        server.stop()
        super.tearDown()
    }

    var base: String { NetTests.server.base }

    func testPlainContentLength() throws {
        XCTAssertEqual(try Net.getString(base + "/plain"), "hello")
    }

    func testChunked() throws {
        XCTAssertEqual(try Net.getString(base + "/chunked"), "hello world")
    }

    func testGzipIsUnpacked() throws {
        XCTAssertEqual(try Net.getString(base + "/gzip"), "hello gzip")
    }

    func testRedirect() throws {
        XCTAssertEqual(try Net.getString(base + "/redirect"), "hello")
    }

    func testBodyUntilClose() throws {
        XCTAssertEqual(try Net.getString(base + "/close"), "until the end")
    }

    func testUserAgent() throws {
        XCTAssertEqual(try Net.getString(base + "/ua", ua: "TestAgent/1.0"), "TestAgent/1.0")
        XCTAssertEqual(try Net.getString(base + "/ua"), Net.defaultUA)
    }

    func testQueryStaysEncoded() throws {
        XCTAssertEqual(try Net.getString(base + "/q?username=a%20b&password=c"), "ok")
    }

    func testDownloadWithProgress() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("tp-big-test")
        defer { try? FileManager.default.removeItem(at: f) }
        var last: Int64 = 0
        try Net.download(base + "/big", to: f) { d, t in last = d; XCTAssertEqual(t, 1_500_000) }
        let size = try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int64
        XCTAssertEqual(size, 1_500_000)
        XCTAssertEqual(last, 1_500_000)
    }

    /// A refusal shows the server's own words, and a server error (5xx) gets one more try.
    func testServerErrorMessage() {
        NetTests.lock.lock(); NetTests.hits["/blocked"] = 0; NetTests.lock.unlock()
        XCTAssertThrowsError(try Net.getData(base + "/blocked")) { e in
            XCTAssertEqual((e as? DbError)?.message, "HTTP 512: Access denied IP not allowed")
        }
        NetTests.lock.lock(); let n = NetTests.hits["/blocked"] ?? 0; NetTests.lock.unlock()
        XCTAssertEqual(n, 3, "two tries over the socket, one through URLSession")
    }

    func testRedactHidesThePassword() {
        XCTAssertEqual(Net.redact("http://host.tv:8080/get.php?username=u&password=secret"), "http://host.tv:8080/get.php")
    }

    func testUnreachableFallsBackAndFails() {
        // nothing listens on port 1: the socket fails, URLSession fails too, and the error comes back
        XCTAssertThrowsError(try Net.getData("http://127.0.0.1:1/x"))
    }
}
