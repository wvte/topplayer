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

    /// Tries the socket of our own, with one more try after a server error (5xx). nil when the file is there;
    /// otherwise the reason, and URLSession gets a turn.
    private static func viaSocket(_ url: String, ua: String?, to target: URL, progress: ((Int64, Int64) -> Void)?) -> Error? {
        let agent = (ua ?? "").isEmpty ? defaultUA : ua!
        var attempt = 0
        while true {
            attempt += 1
            do {
                switch try DirectHTTP.fetch(url, ua: agent, to: target, progress: progress) {
                case .saved:
                    try Gzip.inflateInPlace(target)
                    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                    if size == 0 { return DbError(message: "Empty response") }
                    return nil
                case .https:
                    return DirectHTTP.Failure(message: "redirect to https")
                }
            } catch let e as DirectHTTP.ServerAnswer {
                if e.status >= 500 && attempt < 2 {
                    log?("net: \(e.message) van \(redact(url)), nog een keer")
                    Thread.sleep(forTimeInterval: 1.5)
                    continue
                }
                log?("net: \(e.message) van \(redact(url))")
                return e
            } catch {
                let why = (error as? DirectHTTP.Failure)?.message ?? error.localizedDescription
                log?("net: eigen verbinding lukte niet (\(why)) voor \(redact(url)), via het systeem")
                return error
            }
        }
    }

    /// The error to show when both ways failed: the server's own answer over our socket says the most.
    private static func pick(_ socket: Error?, _ system: Error) -> Error {
        if let a = socket as? DirectHTTP.ServerAnswer { return DbError(message: a.message) }
        return system
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
        }
        do { return try getDataSystem(url, ua: ua) } catch { throw pick(socketError, error) }
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
        }
        do { try downloadSystem(url, ua: ua, to: target, progress: progress) } catch { throw pick(socketError, error) }
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
