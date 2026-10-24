import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled web UI (and the demo artwork) under topplayer://app/..., like the virtual host on Android.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "topplayer"
    private let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // no way out of the bundle folder
        let clean = path.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        let file = root.appendingPathComponent(clean)
        guard let data = try? Data(contentsOf: file) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(r)
            task.didFinish()
            return
        }
        let headers = ["Content-Type": mime(file.pathExtension), "Content-Length": String(data.count), "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
