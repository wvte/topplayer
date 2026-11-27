import Foundation

/// Small HTTP helpers (blocking, call them from a background queue): redirects, gzip, custom user agent.
/// Plain http:// goes over a socket of our own first (DirectHTTP: straight from the home connection, also when iCloud
/// Private Relay is on); https:// and anything the socket cannot do go through URLSession.
public enum Net {
    public static let defaultUA = "VLC/3.0.20 LibVLC/3.0.20"
    /// Off only in tests that check the URLSession path.
    public static var directHTTP = true
    /// Where to note what happened (the app's log). Addresses are written without their query (no passwords).
    public static var log: ((String) -> Void)?

    /// "http://host:port/path", without the query that may hold a user name and password.
    public static func redact(_ url: String) -> String {
        guard let c = DirectHTTP.components(url), let h = c.host else { return "?" }
        return (c.scheme ?? "http") + "://" + h + (c.port.map { ":\($0)" } ?? "") + c.percentEncodedPath
    }

    private static func isPlainHTTP(_ url: String) -> Bool { directHTTP && url.lowercased().hasPrefix("http://") }

    /// "host:port", the part of an address that tells whether the server was typed right (no user name or password).
    public static func hostPort(_ url: String) -> String {
        guard let c = DirectHTTP.components(url), let h = c.host else { return "?" }
        return h + ":" + String(c.port ?? ((c.scheme ?? "").lowercased() == "https" ? 443 : 80))
    }

    private static func text(_ e: Error) -> String {
        (e as? DirectHTTP.ServerAnswer)?.message ?? (e as? DirectHTTP.Failure)?.message ?? (e as? DbError)?.message ?? e.localizedDescription
    }

    /// Tries the socket of our own. nil when the file is there, otherwise the reason. Only a busy server (502, 503,
    /// 504) gets one more try: a server that refuses is not asked again and again.
    private static func viaSocket(_ url: String, ua: String?, to target: URL, progress: ((Int64, Int64) -> Void)?) -> Error? {
        let agent = (ua ?? "").isEmpty ? defaultUA : ua!
        let t0 = Date()
        var attempt = 0
        while true {
            attempt += 1
            do {
                switch try DirectHTTP.fetch(url, ua: agent, to: target, progress: progress) {
                case .saved:
                    try Gzip.inflateInPlace(target)
                    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                    if size == 0 {
                        log?("net: \(redact(url)): leeg antwoord")
                        return DbError(message: "Empty response")
                    }
                    log?(String(format: "net: %@ ok, %.1f MB in %.1f s", redact(url), Double(size) / 1_000_000, Date().timeIntervalSince(t0)))
                    return nil
                case .https:
                    return DirectHTTP.Failure(message: "redirect to https")
                }
            } catch let e as DirectHTTP.ServerAnswer {
                if [502, 503, 504].contains(e.status) && attempt < 2 {
                    log?("net: \(redact(url)): \(e.message), over 2 s nog een keer")
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                log?("net: \(redact(url)): \(e.message)")
                return e
            } catch {
                log?("net: \(redact(url)): eigen verbinding lukte niet (\(text(error)))")
                return error
            }
        }
    }

    /// URLSession gets a turn when our connection itself failed, or when the server did not understand our request
    /// (400, 505). Not when the server clearly refused: asking again the other way only adds to its count.
    private static func systemMayHelp(_ e: Error) -> Bool {
        guard let a = e as? DirectHTTP.ServerAnswer else { return true }
        return a.status == 400 || a.status == 505
    }

    /// The message to show: which server and port, what our connection got and what the system got.
    private static func failure(_ url: String, own: Error?, system: Error?) -> Error {
        var parts: [String] = []
        if let o = own { parts.append(text(o)) }
        if let s = system {
            log?("net: \(redact(url)): via het systeem: \(text(s))")
            parts.append((own == nil ? "" : "via systeem: ") + text(s))
        }
        return DbError(message: hostPort(url) + ": " + parts.joined(separator: " · "))
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 60 * 60
        c.httpAdditionalHeaders = ["Accept": "*/*"]
        return URLSession(configuration: c)
    }()

    private static func request(_ url: String, ua: String?) throws -> URLRequest {
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            throw DbError(message: "Bad address")
        }
        var r = URLRequest(url: u)
        r.setValue((ua ?? "").isEmpty ? defaultUA : ua, forHTTPHeaderField: "User-Agent")
        return r
    }

    private final class Box<T> { var value: T?; var error: Error? }

    /// Whole answer in memory (small JSON and text answers).
    public static func getData(_ url: String, ua: String? = nil) throws -> Data {
        var socketError: Error?
        if isPlainHTTP(url) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tp-net-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            socketError = viaSocket(url, ua: ua, to: tmp, progress: nil)
            if socketError == nil { return try Data(contentsOf: tmp) }
            if !systemMayHelp(socketError!) { throw failure(url, own: socketError, system: nil) }
        }
        do { return try getDataSystem(url, ua: ua) } catch { throw failure(url, own: socketError, system: error) }
    }

    private static func getDataSystem(_ url: String, ua: String?) throws -> Data {
        let req = try request(url, ua: ua)
        let sem = DispatchSemaphore(value: 0)
        let box = Box<Data>()
        session.dataTask(with: req) { data, resp, err in
            if let err = err { box.error = err }
            else if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                box.error = DbError(message: DirectHTTP.errorText(h.statusCode, Array((data ?? Data()).prefix(2048))))
            }
            else { box.value = data ?? Data() }
            sem.signal()
        }.resume()
        sem.wait()
        if let e = box.error { throw e }
        return box.value ?? Data()
    }

    public static func getString(_ url: String, ua: String? = nil) throws -> String {
        String(decoding: try getData(url, ua: ua), as: UTF8.self)
    }

    private final class Loader: NSObject, URLSessionDownloadDelegate {
        let target: URL
        let progress: ((Int64, Int64) -> Void)?
        let sem = DispatchSemaphore(value: 0)
        var error: Error?

        init(target: URL, progress: ((Int64, Int64) -> Void)?) {
            self.target = target
            self.progress = progress
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let h = downloadTask.response as? HTTPURLResponse, h.statusCode >= 400 {
                let head = (try? FileHandle(forReadingFrom: location))?.readData(ofLength: 2048) ?? Data()
                error = DbError(message: DirectHTTP.errorText(h.statusCode, Array(head)))
                return
            }
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
            } catch { self.error = error }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
            progress?(w, t)
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if let e = e { error = e }
            sem.signal()
        }
    }

    /// Downloads to a file, reporting (bytes so far, total or -1).
    public static func download(_ url: String, ua: String? = nil, to target: URL, progress: ((Int64, Int64) -> Void)? = nil) throws {
        var socketError: Error?
        if isPlainHTTP(url) {
            socketError = viaSocket(url, ua: ua, to: target, progress: progress)
            if socketError == nil { return }
            if !systemMayHelp(socketError!) { throw failure(url, own: socketError, system: nil) }
        }
        do { try downloadSystem(url, ua: ua, to: target, progress: progress) } catch { throw failure(url, own: socketError, system: error) }
    }

    private static func downloadSystem(_ url: String, ua: String?, to target: URL, progress: ((Int64, Int64) -> Void)?) throws {
        let req = try request(url, ua: ua)
        let loader = Loader(target: target, progress: progress)
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 60 * 60
        let s = URLSession(configuration: c, delegate: loader, delegateQueue: nil)
        s.downloadTask(with: req).resume()
        loader.sem.wait()
        s.finishTasksAndInvalidate()
        if let e = loader.error { throw e }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        if size == 0 { throw DbError(message: "Empty response") }
    }
}
