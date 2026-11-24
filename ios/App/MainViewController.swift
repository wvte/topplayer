import AVKit
import UIKit
import UniformTypeIdentifiers
import WebKit
import TopplayerCore

/// One full screen web view (the UI) over a video view. The web view is see-through while video plays.
final class MainViewController: UIViewController, WKNavigationDelegate, UIDocumentPickerDelegate {
    private var web: WKWebView!
    private var bridge: Bridge!
    private var player: PlayerEngine!
    private var videoHost = UIView()
    private var rect: CGRect = .zero
    private var fullVideo = true

    override var prefersStatusBarHidden: Bool { OrientationControl.mask == .landscape }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { OrientationControl.mask }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.110, green: 0.086, blue: 0.067, alpha: 1)

        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let cache = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dbPath = support.appendingPathComponent("topplayer.db").path
        guard let db = try? Db(path: dbPath) else {
            let l = UILabel(frame: view.bounds)
            l.text = "Database kon niet worden geopend"
            l.textColor = .white
            l.textAlignment = .center
            view.addSubview(l)
            return
        }

        // video layer first, web view over it
        videoHost.frame = view.bounds
        videoHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoHost)

        let conf = WKWebViewConfiguration()
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.setURLSchemeHandler(SchemeHandler(root: Bundle.main.resourceURL!.appendingPathComponent("ui")), forURLScheme: SchemeHandler.scheme)
        bridge = Bridge(web: nil, db: db, dbPath: dbPath, cacheDir: cache)

        installBoot(conf.userContentController)
        conf.userContentController.add(bridge, name: "tp")

        web = WKWebView(frame: view.bounds, configuration: conf)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)
        bridge.web = web

        player = PlayerEngine { [weak self] name, data in self?.bridge.emit(name, data) }
        bridge.player = player
        videoHost.addSubview(player.view)
        player.view.frame = videoHost.bounds

        web.load(URLRequest(url: URL(string: "topplayer://app/index.html")!))

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.bridge.emit("app.pause", [:]) }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.bridge.emit("app.stop", [:]) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // keep the interface out of the notch; the video itself may use the whole screen
        web?.frame = view.bounds
        if player != nil && fullVideo { player.view.frame = videoHost.bounds }
    }

    /// The interface is upright on a phone; video plays in landscape. iPads follow the device.
    func requestOrientation(landscape: Bool) {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let mask: UIInterfaceOrientationMask = phone ? (landscape ? .landscape : .portrait) : .all
        OrientationControl.mask = mask
        setNeedsStatusBarAppearanceUpdate()
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        } else {
            let target: UIInterfaceOrientation = phone ? (landscape ? .landscapeRight : .portrait) : .unknown
            if target != .unknown { UIDevice.current.setValue(target.rawValue, forKey: "orientation") }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// iOS has no call to open the AirPlay list, so press the button of a route picker that is not shown.
    func showAirPlayPicker() {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.alpha = 0.01
        view.addSubview(picker)
        for sub in picker.subviews { if let b = sub as? UIButton { b.sendActions(for: .touchUpInside) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { picker.removeFromSuperview() }
    }

    func setBackground(hex: String) {
        var color = UIColor.clear
        if hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 {
            color = UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        web.backgroundColor = color
        web.scrollView.backgroundColor = color
        if hex.hasPrefix("#") { view.backgroundColor = color == .clear ? UIColor(red: 0.110, green: 0.086, blue: 0.067, alpha: 1) : color }
    }

    func setVideoRect(x: Double, y: Double, w: Double, h: Double, visible: Bool) {
        if !visible || w <= 0 || h <= 0 {
            fullVideo = true
            player.view.frame = videoHost.bounds
        } else {
            fullVideo = false
            player.view.frame = CGRect(x: x, y: y, width: w, height: h)
        }
        player.setRect(x: x, y: y, w: w, h: h, visible: visible)
    }

    /// The script every page load starts with: the bridge, and the settings and state as they are NOW (not as they
    /// were when the app started), so a reload after iOS ended the page, or after a restore, has the latest ones.
    private func installBoot(_ uc: WKUserContentController) {
        uc.removeAllUserScripts()
        let boot = """
        window.__TP_IOS = true;
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

    /// Loads the interface again with the current settings (after a restore, or when iOS ended the page).
    func reloadPage() {
        installBoot(web.configuration.userContentController)
        web.reload()
    }

    // MARK: backup

    /// Saves a backup file and opens the share sheet (Files, iCloud Drive, AirDrop, mail ...).
    func shareBackup(_ json: Data) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Topplayer-backup-" + f.string(from: Date()) + ".json")
        do { try json.write(to: url) } catch { bridge.emit("backup.done", ["ok": false, "error": error.localizedDescription]); return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        vc.completionWithItemsHandler = { [weak self] _, completed, _, err in
            self?.bridge.emit("backup.done", ["ok": completed && err == nil, "cancelled": !completed && err == nil])
        }
        present(vc, animated: true)
    }

    /// Lets you pick a backup file to restore.
    func pickBackup() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data, .text])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { bridge.emit("backup.restored", ["ok": false, "error": "Bestand niet te lezen"]); return }
        bridge.restoreBackup(data) { [weak self] ok, err in
            if ok { self?.reloadPage() } else { self?.bridge.emit("backup.restored", ["ok": false, "error": err ?? "?"]) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    /// iOS can end the web page's process while the app sits in the background; load it again instead of a blank
    /// screen (the playlists come from the database, nothing is downloaded again).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadPage()
    }
}
