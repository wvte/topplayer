#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import WebKit
import TopplayerCore

/// The Mac app: one window with the TV interface (the same web UI) over a video view, a menu bar, and the keyboard,
/// mouse and trackpad handled by the page (desktop.js).
@main
enum MacMain {
    static let delegate = MacAppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

/// The walnut background of the interface, also behind the title bar.
let walnut = NSColor(srgbRed: 0.110, green: 0.086, blue: 0.067, alpha: 1)

final class MacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var controller: MacViewController!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = buildMenu()
        controller = MacViewController()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Topplayer"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = walnut
        w.contentViewController = controller
        w.minSize = NSSize(width: 900, height: 540)
        w.collectionBehavior = [.fullScreenPrimary]
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 1280, height: 780))
        if !w.setFrameUsingName("TopplayerMain") { w.center() }
        w.setFrameAutosaveName("TopplayerMain")
        window = w
        controller.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Before quitting: the page saves where a film or episode is, and that write reaches the database.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let c = controller else { return .terminateNow }
        c.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillResignActive(_ note: Notification) { controller?.emit("app.pause") }

    func windowDidBecomeKey(_ note: Notification) { controller?.focusPage() }

    // MARK: menu bar

    @objc func openSettings() { controller?.run("window.__mac && window.__mac.settings()") }
    @objc func openSearch() { controller?.run("window.__mac && window.__mac.search()") }
    @objc func goBack() { controller?.run("window.__mac && window.__mac.back()") }
    @objc func zoomIn() { controller?.run("window.__mac && window.__mac.zoom(1)") }
    @objc func zoomOut() { controller?.run("window.__mac && window.__mac.zoom(-1)") }
    @objc func zoomReset() { controller?.run("window.__mac && window.__mac.zoom(0)") }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            item.submenu = m
            bar.addItem(item)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let t = target { i.target = t }
            return i
        }

        func hidden(_ i: NSMenuItem) -> NSMenuItem {
            i.isHidden = true
            i.allowsKeyEquivalentWhenHidden = true
            return i
        }

        _ = submenu("Topplayer", [
            item("Over Topplayer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Instellingen…", #selector(openSettings), ",", target: self),
            .separator(),
            item("Verberg Topplayer", #selector(NSApplication.hide(_:)), "h"),
            item("Verberg andere", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Toon alles", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Stop Topplayer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Wijzig", [
            item("Herstel", Selector(("undo:")), "z"),
            item("Opnieuw", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Knip", #selector(NSText.cut(_:)), "x"),
            item("Kopieer", #selector(NSText.copy(_:)), "c"),
            item("Plak", #selector(NSText.paste(_:)), "v"),
            item("Selecteer alles", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Zoek", #selector(openSearch), "f", target: self),
        ])
        _ = submenu("Weergave", [
            item("Terug", #selector(goBack), "[", target: self),
            .separator(),
            item("Groter", #selector(zoomIn), "+", target: self),
            hidden(item("Groter", #selector(zoomIn), "=", target: self)), // Cmd = is Cmd + without shift
            item("Kleiner", #selector(zoomOut), "-", target: self),
            item("Normale grootte", #selector(zoomReset), "0", target: self),
            .separator(),
            item("Volledig scherm", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let win = submenu("Venster", [
            item("Minimaliseer", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Sluit", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = win
        return bar
    }
}

/// A view whose origin is the top left, like the page's coordinates, so the video rectangle needs no flipping.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class MacViewController: NSViewController, WKNavigationDelegate, AppHost {
    weak var window: NSWindow?
    private var web: WKWebView!
    private var bridge: Bridge!
    private var player: PlayerEngine!
    private let videoHost = FlippedView()
    private var fullVideo = true

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 780))
        v.wantsLayer = true
        v.layer?.backgroundColor = walnut.cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let fm = FileManager.default
        // a Mac shares Application Support and Caches between apps: keep ours in a folder of its own
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let support = base.appendingPathComponent("Topplayer", isDirectory: true)
        let cacheBase = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let cache = cacheBase.appendingPathComponent("Topplayer", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let dbPath = support.appendingPathComponent("topplayer.db").path
        guard let db = try? Db(path: dbPath) else {
            let l = NSTextField(labelWithString: "De database kon niet worden geopend (" + dbPath + ")")
            l.textColor = .white
            l.alignment = .center
            l.frame = view.bounds
            l.followParentSize()
            view.addSubview(l)
            return
        }

        // video first, the page over it
        videoHost.frame = view.bounds
        videoHost.followParentSize()
        videoHost.wantsLayer = true
        view.addSubview(videoHost)

        let conf = WKWebViewConfiguration()
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.setURLSchemeHandler(SchemeHandler(root: Bundle.main.resourceURL!.appendingPathComponent("ui")), forURLScheme: SchemeHandler.scheme)
        bridge = Bridge(web: nil, db: db, dbPath: dbPath, cacheDir: cache)
        bridge.host = self
        installBoot(conf.userContentController)
        conf.userContentController.add(bridge, name: "tp")

        web = WKWebView(frame: view.bounds, configuration: conf)
        web.setValue(false, forKey: "drawsBackground") // see-through where video plays
        web.followParentSize()
        web.navigationDelegate = self
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { web.isInspectable = true }
        view.addSubview(web)
        bridge.web = web

        player = PlayerEngine { [weak self] name, data in self?.bridge.emit(name, data) }
        bridge.player = player
        player.view.frame = videoHost.bounds
        player.view.followParentSize()
        videoHost.addSubview(player.view)

        web.load(URLRequest(url: URL(string: "topplayer://app/index.html")!))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if player != nil && fullVideo { player.view.frame = videoHost.bounds }
    }

    func focusPage() {
        guard let w = window, let web = web else { return }
        if w.firstResponder !== web { w.makeFirstResponder(web) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { focusPage() }

    /// macOS ended the page's process (memory pressure): load it again instead of an empty window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reloadPage() }

    func run(_ js: String) { web?.evaluateJavaScript(js, completionHandler: nil) }
    func emit(_ name: String) { bridge?.emit(name, [:]) }

    /// The page saves the position of what plays; once that write is in the database the app may quit.
    func prepareToQuit(_ done: @escaping () -> Void) {
        guard let bridge = bridge else { done(); return }
        bridge.emit("app.pause", [:])
        bridge.emit("app.stop", [:])
        var finished = false
        let finish = { if !finished { finished = true; self.player?.stop(); done() } }
        // the page needs a moment to send its last save; never wait longer than two seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bridge.afterWrites(finish) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
    }

    // MARK: AppHost

    func setBackground(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return }
        let c = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        view.layer?.backgroundColor = c.cgColor
        window?.backgroundColor = c
    }

    func setVideoRect(x: Double, y: Double, w: Double, h: Double, visible: Bool) {
        if !visible || w <= 0 || h <= 0 {
            fullVideo = true
            player.view.frame = videoHost.bounds
            player.view.followParentSize()
        } else {
            fullVideo = false
            player.view.autoresizingMask = []
            player.view.frame = NSRect(x: x, y: y, width: w, height: h)
        }
        player.setRect(x: x, y: y, w: w, h: h, visible: visible)
    }

    func requestOrientation(landscape: Bool) {}
    func showAirPlayPicker() {}
    func exitApp() { NSApp.terminate(nil) }
    func moveToBackground() { NSApp.hide(nil) }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// Saves a backup where you choose (Documents, iCloud Drive, a USB stick ...).
    func shareBackup(_ json: Data) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Topplayer-backup-" + f.string(from: Date()) + ".json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self = self else { return }
            guard r == .OK, let url = panel.url else { self.bridge.emit("backup.done", ["ok": false, "cancelled": true]); return }
            do {
                try json.write(to: url, options: .atomic)
                self.bridge.emit("backup.done", ["ok": true])
            } catch {
                self.bridge.emit("backup.done", ["ok": false, "error": error.localizedDescription])
            }
            self.focusPage()
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Lets you pick a backup file to restore.
    func pickBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self = self else { return }
            self.focusPage()
            guard r == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else { self.bridge.emit("backup.restored", ["ok": false, "error": "Bestand niet te lezen"]); return }
            self.bridge.restoreBackup(data) { [weak self] ok, err in
                if ok { self?.reloadPage() } else { self?.bridge.emit("backup.restored", ["ok": false, "error": err ?? "?"]) }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    // MARK: page

    /// The script every page load starts with: the bridge, and the settings and state as they are now.
    private func installBoot(_ uc: WKUserContentController) {
        uc.removeAllUserScripts()
        let boot = """
        window.__TP_MAC = true;
        window.__TP_PREFS = \(Bridge.json(bridge.prefsJSON));
        window.__TP_STATE = \(Bridge.json(bridge.stateJSON));
        (function () {
          var post = function (m) { window.webkit.messageHandlers.tp.postMessage(m); };
          window.TPN = {
            request: function (id, m, j) { post({ t: 'req', id: id, m: m, j: j }); },
            prefsGet: function () { return window.__TP_PREFS; },
            prefsSet: function (s) { window.__TP_PREFS = s; post({ t: 'prefs', v: s }); },
            stateGet: function () { return window.__TP_STATE; },
            stateSet: function (s) { window.__TP_STATE = s; post({ t: 'state', v: s }); },
            log: function (s) { post({ t: 'log', v: String(s) }); }
          };
        })();
        """
        uc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func reloadPage() {
        installBoot(web.configuration.userContentController)
        web.reload()
    }
}
#endif
