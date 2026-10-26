import AVFoundation
import UIKit

/// Chooses the engine per stream: Apple's player for HLS, mp4 and mov (picture in picture, AirPlay), VLC for the rest
/// (mkv, avi, raw MPEG-TS ...). If Apple's player fails on a stream, VLC takes over by itself.
final class PlayerEngine: NSObject {
    let view = UIView()
    private let av: AVEngine
    private let vlc: VLCEngine
    private enum Active { case none, av, vlc }
    private var active: Active = .none
    private var lastArgs: [String: Any] = [:]
    private let emit: (String, [String: Any]) -> Void
    private let relay = Relay()

    /// Sees every event of the engines on its way to the page (for the watchdog).
    private final class Relay {
        weak var hub: PlayerEngine?
        var out: ((String, [String: Any]) -> Void)?
        func send(_ n: String, _ d: [String: Any]) {
            guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.send(n, d) }; return }
            hub?.observe(n, d)
            if n == "player.error", let h = hub, h.swallowEngineError(d) { return }
            out?(n, d)
        }
    }

    // MARK: watchdog
    // A stream that never shows a picture used to leave the page waiting forever. Now: no progress within a few seconds
    // on Apple's player means VLC gets a go; nothing on VLC either (or a stall that lasts) ends with an error the page
    // shows with a code, after a quick look at what the server answers.

    private var timer: Timer?
    private var startedAt = Date()
    private var lastProgress = Date()
    private var lastPos: Int64 = -1
    private var started = false
    private var userPaused = false
    private var triedVLC = false
    private var failed = false
    private var vlcError: String?
    private static let startAV: TimeInterval = 12
    private static let startVLC: TimeInterval = 25
    private static let stall: TimeInterval = 45

    private func armWatchdog() {
        timer?.invalidate()
        startedAt = Date(); lastProgress = Date(); lastPos = -1
        started = false; userPaused = false; failed = false; vlcError = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    fileprivate func observe(_ n: String, _ d: [String: Any]) {
        guard n == "player.time", let pos = (d["pos"] as? NSNumber)?.int64Value ?? (d["pos"] as? Int64) else { return }
        // started = the clock moved forward (a resume position alone is not a picture)
        if lastPos >= 0, pos > lastPos { started = true; lastProgress = Date() }
        lastPos = pos
    }

    /// VLC's own "cannot play" ends the attempt here, so the page gets one error with a code instead of two.
    fileprivate func swallowEngineError(_ d: [String: Any]) -> Bool {
        guard active == .vlc, !started, !lastArgs.isEmpty, (d["retry"] as? Bool) != true else { return false }
        vlcError = d["msg"] as? String
        fail(reason: "VLC")
        return true
    }

    private func tick() {
        guard !lastArgs.isEmpty, !failed else { return }
        let live = lastArgs["live"] as? Bool ?? false
        let now = Date()
        if !started {
            let waited = now.timeIntervalSince(startedAt)
            if active == .av, waited > Self.startAV, !live || waited > Self.startAV * 2 {
                _ = switchToVLC()
            } else if active == .vlc, waited > Self.startVLC, !live {
                fail(reason: "START")
            }
        } else if !live, !userPaused, UIApplication.shared.applicationState == .active, now.timeIntervalSince(lastProgress) > Self.stall {
            fail(reason: "STALL")
        }
    }

    private func fail(reason: String) {
        guard !failed else { return }
        failed = true
        timer?.invalidate()
        let args = lastArgs
        let engine = active == .vlc ? "vlc" : "av"
        let urlString = args["url"] as? String ?? ""
        let ua = (args["ua"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "VLC/3.0.20 LibVLC/3.0.20"
        Self.probe(urlString, ua: ua) { [weak self] status, type, netErr in
            guard let self = self, !self.lastArgs.isEmpty, (self.lastArgs["url"] as? String) == urlString else { return }
            let u = URL(string: urlString)
            let ext = (u?.pathExtension ?? "").lowercased()
            let code: String
            var msg: String
            if let e = netErr {
                code = "TP-NET\(abs(e))"
                msg = e == NSURLErrorTimedOut ? "De server reageert niet" : "Geen verbinding met de server"
            } else if let st = status, st >= 400 {
                code = "TP-\(st)"
                switch st {
                case 401, 403: msg = "De server weigert deze aflevering (te veel verbindingen of geen toegang)"
                case 404, 410: msg = "Deze aflevering bestaat niet (meer) op de server"
                case 429: msg = "De server heeft het te druk"
                default: msg = st >= 500 ? "Fout op de server" : "De server geeft een fout"
                }
            } else {
                code = reason == "STALL" ? "TP-STALL" : reason == "VLC" ? "TP-VLC" : "TP-START"
                msg = reason == "STALL" ? "Het beeld bleef te lang stilstaan" : "De server stuurt wel iets, maar het beeld start niet"
                if let ve = self.vlcError, !ve.isEmpty, reason == "VLC" { msg = ve }
            }
            var detail = [engine == "vlc" ? "VLC" : "Apple"]
            if self.triedVLC && engine == "vlc" { detail.insert("Apple", at: 0) }
            var info = detail.joined(separator: " + ")
            if !ext.isEmpty { info += " · ." + ext }
            if let st = status { info += " · HTTP \(st)" }
            if let t = type, !t.isEmpty { info += " · " + t }
            if let h = u?.host { info += " · " + h }
            self.av.stop(); self.vlc.stop(); self.lastArgs = [:]; self.show(.none)
            self.emit("player.error", ["code": code, "name": code, "msg": msg, "info": info, "engine": engine, "fatal": true, "retry": false, "attempt": 0])
        }
    }

    /// Asks the server for the first bytes: says whether it answers, with which status and type.
    private static func probe(_ s: String, ua: String, done: @escaping (Int?, String?, Int?) -> Void) {
        guard let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { DispatchQueue.main.async { done(nil, nil, nil) }; return }
        var r = URLRequest(url: u, timeoutInterval: 8)
        r.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { _, resp, err in
            let h = resp as? HTTPURLResponse
            let ne = (err as NSError?).map { $0.code }
            DispatchQueue.main.async { done(h?.statusCode, h?.value(forHTTPHeaderField: "Content-Type"), h == nil ? ne : nil) }
        }.resume()
    }

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
        relay.out = emit
        let r = relay
        av = AVEngine(emit: { r.send($0, $1) })
        vlc = VLCEngine(emit: { r.send($0, $1) })
        super.init()
        relay.hub = self
        view.backgroundColor = .black
        view.isHidden = true
        for v in [av.view, vlc.view] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.isHidden = true
            view.addSubview(v)
        }
        av.fallback = { [weak self] in self?.switchToVLC() ?? false }
    }

    private static let appleFormats: Set<String> = ["m3u8", "m3u", "mp4", "m4v", "mov", "mp3", "m4a", "aac"]

    private func prefersApple(_ a: [String: Any]) -> Bool {
        let u = (a["url"] as? String ?? "").lowercased()
        let path = u.split(separator: "?").first.map(String.init) ?? u
        let ext = path.split(separator: ".").last.map(String.init) ?? ""
        return PlayerEngine.appleFormats.contains(ext)
    }

    private func show(_ which: Active) {
        active = which
        av.view.isHidden = which != .av
        vlc.view.isHidden = which != .vlc
        view.isHidden = which == .none
    }

    private func switchToVLC() -> Bool {
        guard active == .av, !lastArgs.isEmpty else { return false }
        av.stop()
        triedVLC = true
        startedAt = Date(); lastProgress = Date(); lastPos = -1
        show(.vlc)
        vlc.play(lastArgs)
        return true
    }

    // MARK: control

    func play(_ a: [String: Any]) {
        lastArgs = a
        triedVLC = false
        armWatchdog()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // stop the other engine without telling the page that playback ended
        let forced = a["engine"] as? String
        if forced == "av" || (forced != "vlc" && prefersApple(a)) {
            vlc.stop()
            show(.av)
            av.play(a)
        } else {
            av.stop()
            show(.vlc)
            vlc.play(a)
        }
    }

    func stop() {
        timer?.invalidate()
        av.stop()
        vlc.stop()
        lastArgs = [:]
        show(.none)
    }

    func pause() { userPaused = true; active == .vlc ? vlc.pause() : av.pause() }
    func resume() { userPaused = false; lastProgress = Date(); active == .vlc ? vlc.resume() : av.resume() }
    func toggle() { userPaused.toggle(); lastProgress = Date(); active == .vlc ? vlc.toggle() : av.toggle() }
    func seekTo(_ ms: Int64) { lastProgress = Date(); active == .vlc ? vlc.seekTo(ms) : av.seekTo(ms) }
    func seekBy(_ ms: Int64) { lastProgress = Date(); active == .vlc ? vlc.seekBy(ms) : av.seekBy(ms) }
    func setSpeed(_ s: Float) { active == .vlc ? vlc.setSpeed(s) : av.setSpeed(s) }
    func setAspect(_ mode: String, zoom: Float) { active == .vlc ? vlc.setAspect(mode, zoom: zoom) : av.setAspect(mode, zoom: zoom) }
    func configure(_ a: [String: Any]) { av.configure(a); vlc.configure(a) }
    func tracks() -> [String: Any] { active == .vlc ? vlc.tracks() : av.tracks() }
    func selectTrack(type: String, id: String) { active == .vlc ? vlc.selectTrack(type: type, id: id) : av.selectTrack(type: type, id: id) }
    func togglePictureInPicture() { if active == .av { av.togglePictureInPicture() } }

    func setRect(x: Double, y: Double, w: Double, h: Double, visible: Bool) { view.isHidden = active == .none }
}
