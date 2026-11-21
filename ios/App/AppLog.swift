import Foundation

/// A short log of what the app did (refreshes, slow or failed requests), shown in Settings > About.
enum AppLog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MM HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.insert(fmt.string(from: Date()) + "  " + s, at: 0)
        if lines.count > 80 { lines.removeLast(lines.count - 80) }
        NSLog("Topplayer: %@", s)
    }

    static func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
