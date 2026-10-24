import Foundation

/// Small HTTP helpers (blocking, call them from a background queue): redirects, gzip, custom user agent.
public enum Net {
    public static let defaultUA = "VLC/3.0.20 LibVLC/3.0.20"

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
        let req = try request(url, ua: ua)
        let sem = DispatchSemaphore(value: 0)
        let box = Box<Data>()
        session.dataTask(with: req) { data, resp, err in
            if let err = err { box.error = err }
            else if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { box.error = DbError(message: "HTTP \(h.statusCode)") }
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
                error = DbError(message: "HTTP \(h.statusCode)")
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
