import AVFoundation
import AVKit
import UIKit

/// A view whose layer is an AVPlayerLayer (sits behind the transparent web view, like the video surface on Android).
final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Playback with AVPlayer. Speaks the same events as the Android player (player.state, player.time, ...).
/// AVPlayer plays HLS (.m3u8) and mp4/mov; other containers (mkv, raw .ts) are not supported by iOS itself.
final class PlayerEngine: NSObject, AVPictureInPictureControllerDelegate {
    let view = PlayerView()
    private let emit: (String, [String: Any]) -> Void
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timer: Timer?
    private var playerObs: [NSKeyValueObservation] = []
    private var itemObs: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pip: AVPictureInPictureController?

    private var url = ""
    private var ua = ""
    private var referer = ""
    private var live = false
    private var triedHls = false
    private var retries = 0
    private var startMs: Int64 = 0
    private var speed: Float = 1
    private var aspect = "fit"
    private var audioLang = ""
    private var subLang = ""
    private var subsOn = false

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
        super.init()
        view.backgroundColor = .black
        view.isHidden = true
        view.playerLayer.videoGravity = .resizeAspect
    }

    // MARK: control

    func play(_ a: [String: Any]) {
        url = a["url"] as? String ?? ""
        ua = a["ua"] as? String ?? ""
        referer = a["ref"] as? String ?? ""
        live = a["live"] as? Bool ?? false
        startMs = (a["start"] as? NSNumber)?.int64Value ?? 0
        triedHls = false
        retries = 0
        configure(a)
        setAspect(a["aspect"] as? String ?? aspect, zoom: 1)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        load(url)
    }

    private func load(_ address: String) {
        teardownItem()
        guard let u = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            emitError(code: -1, name: "BAD_URL", msg: "Bad address", retry: false)
            return
        }
        var headers: [String: String] = ["User-Agent": ua.isEmpty ? "VLC/3.0.20 LibVLC/3.0.20" : ua]
        if !referer.isEmpty { headers["Referer"] = referer }
        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let it = AVPlayerItem(asset: asset)
        item = it
        if player == nil {
            player = AVPlayer()
            player?.automaticallyWaitsToMinimizeStalling = true
            view.playerLayer.player = player
            if AVPictureInPictureController.isPictureInPictureSupported() {
                pip = AVPictureInPictureController(playerLayer: view.playerLayer)
                pip?.delegate = self
                if #available(iOS 14.2, *) { pip?.canStartPictureInPictureAutomaticallyFromInline = true }
            }
            playerObs.append(player!.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in self?.emitState() })
        }
        itemObs.append(it.observe(\.status, options: [.new]) { [weak self] i, _ in self?.itemStatusChanged(i) })
        itemObs.append(it.observe(\.presentationSize, options: [.new]) { [weak self] i, _ in
            let s = i.presentationSize
            if s.width > 0 && s.height > 0 { self?.emit("player.video", ["w": Int(s.width), "h": Int(s.height)]) }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: it, queue: .main) { [weak self] _ in self?.itemEnded() }
        player?.replaceCurrentItem(with: it)
        if startMs > 0 && !live { it.seek(to: CMTime(value: startMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        player?.play()
        player?.rate = speed
        view.isHidden = false
        startTicks()
        emitState()
    }

    private func teardownItem() {
        itemObs.forEach { $0.invalidate() }
        itemObs = []
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
    }

    func stop() {
        stopTicks()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        item = nil
        teardownItem()
        playerObs.forEach { $0.invalidate() }
        playerObs = []
        pip = nil
        player = nil
        view.playerLayer.player = nil
        url = ""
        emit("player.state", ["state": "idle", "playing": false, "live": live])
    }

    func pause() { player?.pause() }
    func resume() { player?.play(); player?.rate = speed }
    func toggle() { if (player?.rate ?? 0) > 0 { pause() } else { resume() } }

    func seekTo(_ ms: Int64) {
        guard let it = item else { return }
        it.seek(to: CMTime(value: max(0, ms), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    func seekBy(_ ms: Int64) {
        guard let p = player else { return }
        seekTo(Int64(p.currentTime().seconds * 1000) + ms)
    }

    func setSpeed(_ s: Float) {
        speed = s
        if (player?.rate ?? 0) > 0 { player?.rate = s }
    }

    func setAspect(_ mode: String, zoom: Float) {
        aspect = mode
        switch mode {
        case "fill", "zoom": view.playerLayer.videoGravity = .resizeAspectFill
        case "stretch": view.playerLayer.videoGravity = .resize
        default: view.playerLayer.videoGravity = .resizeAspect
        }
    }

    func setRect(x: Double, y: Double, w: Double, h: Double, visible: Bool) {
        if !visible || w <= 0 || h <= 0 {
            view.isHidden = item == nil
            view.frame = view.superview?.bounds ?? view.frame
            return
        }
        view.isHidden = false
        view.frame = CGRect(x: x, y: y, width: w, height: h)
    }

    func configure(_ a: [String: Any]) {
        audioLang = a["audioLang"] as? String ?? audioLang
        subLang = a["subLang"] as? String ?? subLang
        subsOn = a["subsOn"] as? Bool ?? subsOn
        applyPreferredTracks()
    }

    // MARK: picture in picture

    func togglePictureInPicture() {
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture() }
        else if p.isPictureInPicturePossible { p.startPictureInPicture() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { emit("player.pip", ["active": true]) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { emit("player.pip", ["active": false]) }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        emit("player.pip", ["active": false, "restore": true])
        done(true)
    }

    // MARK: tracks

    private func group(_ c: AVMediaCharacteristic) -> AVMediaSelectionGroup? { item?.asset.mediaSelectionGroup(forMediaCharacteristic: c) }

    private func applyPreferredTracks() {
        guard let it = item else { return }
        if let g = group(.audible), !audioLang.isEmpty,
           let o = AVMediaSelectionGroup.mediaSelectionOptions(from: g.options, with: Locale(identifier: audioLang)).first { it.select(o, in: g) }
        if let g = group(.legible) {
            if subsOn, !subLang.isEmpty, let o = AVMediaSelectionGroup.mediaSelectionOptions(from: g.options, with: Locale(identifier: subLang)).first { it.select(o, in: g) }
            else if !subsOn { it.select(nil, in: g) }
        }
    }

    func tracks() -> [String: Any] {
        var audio: [[String: Any]] = []
        var text: [[String: Any]] = []
        var textOff = true
        if let it = item {
            if let g = group(.audible) {
                let cur = it.currentMediaSelection.selectedMediaOption(in: g)
                for (i, o) in g.options.enumerated() {
                    audio.append(["id": "0:\(i)", "lang": o.locale?.languageCode ?? "", "label": o.displayName, "channels": 2, "selected": o == cur])
                }
            }
            if let g = group(.legible) {
                let cur = it.currentMediaSelection.selectedMediaOption(in: g)
                textOff = cur == nil
                for (i, o) in g.options.enumerated() {
                    text.append(["id": "1:\(i)", "lang": o.locale?.languageCode ?? "", "label": o.displayName, "selected": o == cur])
                }
            }
        }
        return ["audio": audio, "text": text, "video": [], "videoAuto": true, "textOff": textOff]
    }

    func selectTrack(type: String, id: String) {
        guard let it = item else { return }
        if type == "text" && id == "off", let g = group(.legible) { it.select(nil, in: g); emit("player.tracks", tracks()); return }
        let parts = id.split(separator: ":")
        guard parts.count == 2, let idx = Int(parts[1]) else { return }
        let g = type == "audio" ? group(.audible) : (type == "text" ? group(.legible) : nil)
        if let g = g, idx < g.options.count { it.select(g.options[idx], in: g) }
        emit("player.tracks", tracks())
    }

    // MARK: state

    private func itemStatusChanged(_ i: AVPlayerItem) {
        switch i.status {
        case .readyToPlay:
            retries = 0
            applyPreferredTracks()
            emit("player.tracks", tracks())
            emitState()
        case .failed:
            handleFailure(i.error)
        default: break
        }
    }

    private func handleFailure(_ err: Error?) {
        // Xtream live streams usually also come as HLS; AVPlayer cannot read raw MPEG-TS.
        if !triedHls, let u = URL(string: url), u.pathExtension.lowercased() == "ts" {
            triedHls = true
            load(u.deletingPathExtension().appendingPathExtension("m3u8").absoluteString)
            return
        }
        let ns = err as NSError?
        var msg = ns?.localizedDescription ?? "Playback failed"
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        if ["mkv", "avi", "wmv", "flv", "webm", "ts"].contains(ext) { msg = "Dit bestandstype (\(ext)) speelt iOS niet af. " + msg }
        emitError(code: ns?.code ?? -1, name: ns?.domain ?? "ERROR", msg: msg, retry: false)
    }

    private func itemEnded() {
        emit("player.state", ["state": "ended", "playing": false, "live": live])
        if live {
            // a live stream that "ends" is usually a dropped connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let s = self, !s.url.isEmpty else { return }
                s.retries += 1
                s.load(s.url)
            }
        } else {
            emit("player.ended", [:])
        }
    }

    private func emitState() {
        guard let p = player else { return }
        var state = "idle"
        if let it = item {
            switch p.timeControlStatus {
            case .waitingToPlayAtSpecifiedRate: state = "buffering"
            default: state = it.status == .readyToPlay ? "ready" : "buffering"
            }
        }
        emit("player.state", ["state": state, "playing": p.timeControlStatus == .playing, "live": live])
    }

    private func emitError(code: Int, name: String, msg: String, retry: Bool) {
        emit("player.error", ["code": code, "name": name, "msg": msg, "retry": retry, "attempt": retries])
    }

    private func startTicks() {
        stopTicks()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stopTicks() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = player, let it = item else { return }
        let dur = it.duration
        let durMs: Int64 = dur.isIndefinite || !dur.isNumeric ? 0 : Int64(dur.seconds * 1000)
        var buf: Int64 = 0
        if let r = it.loadedTimeRanges.first?.timeRangeValue { buf = Int64(CMTimeRangeGetEnd(r).seconds * 1000) }
        emit("player.time", ["pos": Int64(max(0, p.currentTime().seconds) * 1000), "dur": durMs, "buf": buf,
                             "playing": p.timeControlStatus == .playing, "live": live || dur.isIndefinite])
    }
}
