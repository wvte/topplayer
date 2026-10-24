import MobileVLCKit
import UIKit

/// Playback with VLC for everything Apple's player cannot open: mkv, avi, raw MPEG-TS streams and so on.
/// Speaks the same events as the other engines (player.state, player.time, ...).
final class VLCEngine: NSObject, VLCMediaPlayerDelegate {
    let view = UIView()
    private let emit: (String, [String: Any]) -> Void
    private var mp: VLCMediaPlayer?
    private var timer: Timer?
    private var url = ""
    private var live = false
    private var startMs: Int64 = 0
    private var pendingStart = false
    private var speed: Float = 1
    private var aspect = "fit"
    private var retries = 0
    private var sentVideoSize = false
    private var audioLang = ""
    private var subLang = ""
    private var subsOn = false
    private var opts: [String: Any] = [:]

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
        super.init()
        view.backgroundColor = .black
    }

    // MARK: control

    func play(_ a: [String: Any]) {
        opts = a
        url = a["url"] as? String ?? ""
        live = a["live"] as? Bool ?? false
        startMs = (a["start"] as? NSNumber)?.int64Value ?? 0
        retries = 0
        configure(a)
        setAspect(a["aspect"] as? String ?? aspect, zoom: 1)
        start()
    }

    private func start() {
        teardown()
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            emit("player.error", ["code": -1, "name": "BAD_URL", "msg": "Bad address", "retry": false, "attempt": 0])
            return
        }
        let ua = (opts["ua"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "VLC/3.0.20 LibVLC/3.0.20"
        let player = VLCMediaPlayer()
        player.drawable = view
        player.delegate = self
        let media = VLCMedia(url: u)
        media.addOption(":network-caching=2000")
        media.addOption(":http-user-agent=" + ua)
        if let r = opts["ref"] as? String, !r.isEmpty { media.addOption(":http-referrer=" + r) }
        player.media = media
        mp = player
        sentVideoSize = false
        pendingStart = startMs > 0 && !live
        player.play()
        player.rate = speed
        startTicks()
        emit("player.state", ["state": "buffering", "playing": false, "live": live])
    }

    private func teardown() {
        stopTicks()
        if let p = mp {
            p.delegate = nil
            p.stop()
            p.drawable = nil
        }
        mp = nil
    }

    func stop() {
        teardown()
        url = ""
        emit("player.state", ["state": "idle", "playing": false, "live": live])
    }

    func pause() { mp?.pause() }
    func resume() { if let p = mp, !p.isPlaying { p.play() } }
    func toggle() { if let p = mp { p.isPlaying ? p.pause() : p.play() } }

    func seekTo(_ ms: Int64) {
        guard let p = mp else { return }
        p.time = VLCTime(int: Int32(max(0, min(ms, Int64(Int32.max)))))
    }

    func seekBy(_ ms: Int64) {
        guard let p = mp else { return }
        seekTo(Int64(p.time.intValue) + ms)
    }

    func setSpeed(_ s: Float) {
        speed = s
        mp?.rate = s
    }

    func setAspect(_ mode: String, zoom: Float) {
        aspect = mode
        guard let p = mp else { return }
        let size = p.videoSize
        switch mode {
        case "fill", "zoom":
            if size.width > 0, size.height > 0 {
                let sc = UIScreen.main.scale
                let f = max(view.bounds.width * sc / size.width, view.bounds.height * sc / size.height)
                p.scaleFactor = Float(f) * (mode == "zoom" ? zoom : 1)
            }
        case "stretch":
            let r = String(format: "%d:%d", Int(view.bounds.width), Int(view.bounds.height))
            p.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (r as NSString).utf8String)
        default:
            p.scaleFactor = 0
            p.videoAspectRatio = nil
        }
    }

    func configure(_ a: [String: Any]) {
        audioLang = a["audioLang"] as? String ?? audioLang
        subLang = a["subLang"] as? String ?? subLang
        subsOn = a["subsOn"] as? Bool ?? subsOn
    }

    // MARK: tracks

    private func names(_ any: [Any]?) -> [String] { (any ?? []).map { String(describing: $0) } }
    private func indexes(_ any: [Any]?) -> [Int] { (any ?? []).compactMap { ($0 as? NSNumber)?.intValue } }

    private func lang(of name: String) -> String {
        // names look like "Track 1 - [English]" or "English"
        if let a = name.range(of: "["), let b = name.range(of: "]"), a.upperBound <= b.lowerBound { return String(name[a.upperBound..<b.lowerBound]) }
        return name
    }

    func tracks() -> [String: Any] {
        var audio: [[String: Any]] = []
        var text: [[String: Any]] = []
        var textOff = true
        if let p = mp {
            let an = names(p.audioTrackNames), ai = indexes(p.audioTrackIndexes)
            let curA = Int(p.currentAudioTrackIndex)
            for (i, idx) in ai.enumerated() where idx >= 0 && i < an.count {
                audio.append(["id": "0:\(idx)", "lang": lang(of: an[i]), "label": an[i], "channels": 2, "selected": idx == curA])
            }
            let tn = names(p.videoSubTitlesNames), ti = indexes(p.videoSubTitlesIndexes)
            let curT = Int(p.currentVideoSubTitleIndex)
            textOff = curT < 0
            for (i, idx) in ti.enumerated() where idx >= 0 && i < tn.count {
                text.append(["id": "1:\(idx)", "lang": lang(of: tn[i]), "label": tn[i], "selected": idx == curT])
            }
        }
        return ["audio": audio, "text": text, "video": [], "videoAuto": true, "textOff": textOff]
    }

    func selectTrack(type: String, id: String) {
        guard let p = mp else { return }
        if type == "text" && id == "off" { p.currentVideoSubTitleIndex = -1; emit("player.tracks", tracks()); return }
        let parts = id.split(separator: ":")
        guard parts.count == 2, let idx = Int32(parts[1]) else { return }
        if type == "audio" { p.currentAudioTrackIndex = idx }
        else if type == "text" { p.currentVideoSubTitleIndex = idx }
        emit("player.tracks", tracks())
    }

    private func applyPreferredTracks() {
        guard let p = mp else { return }
        let an = names(p.audioTrackNames), ai = indexes(p.audioTrackIndexes)
        if !audioLang.isEmpty, let i = an.firstIndex(where: { $0.lowercased().contains(audioLang.lowercased()) || lang(of: $0).lowercased().hasPrefix(audioLang.lowercased()) }), i < ai.count, ai[i] >= 0 {
            p.currentAudioTrackIndex = Int32(ai[i])
        }
        let tn = names(p.videoSubTitlesNames), ti = indexes(p.videoSubTitlesIndexes)
        if subsOn, !subLang.isEmpty, let i = tn.firstIndex(where: { $0.lowercased().contains(subLang.lowercased()) || lang(of: $0).lowercased().hasPrefix(subLang.lowercased()) }), i < ti.count, ti[i] >= 0 {
            p.currentVideoSubTitleIndex = Int32(ti[i])
        } else if !subsOn {
            p.currentVideoSubTitleIndex = -1
        }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let p = mp else { return }
        switch p.state {
        case .opening, .buffering:
            emit("player.state", ["state": "buffering", "playing": false, "live": live])
        case .playing:
            retries = 0
            if pendingStart { pendingStart = false; seekTo(startMs) }
            emit("player.state", ["state": "ready", "playing": true, "live": live])
            applyPreferredTracks()
            emit("player.tracks", tracks())
        case .paused:
            emit("player.state", ["state": "ready", "playing": false, "live": live])
        case .ended:
            emit("player.state", ["state": "ended", "playing": false, "live": live])
            if live { retryLater() } else { emit("player.ended", [:]) }
        case .error:
            if live && retries < 3 { retryLater() } else {
                emit("player.error", ["code": -1, "name": "VLC", "msg": "Deze stream kan niet worden afgespeeld", "retry": false, "attempt": retries])
            }
        default:
            break
        }
    }

    private func retryLater() {
        retries += 1
        emit("player.error", ["code": -1, "name": "RETRY", "msg": "", "retry": true, "attempt": retries])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let s = self, !s.url.isEmpty, s.mp != nil else { return }
            s.start()
        }
    }

    // MARK: ticks

    private func startTicks() {
        stopTicks()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stopTicks() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let p = mp else { return }
        let len = Int(p.media?.length.intValue ?? 0)
        let pos = Int(max(0, p.time.intValue))
        emit("player.time", ["pos": pos, "dur": live ? 0 : max(0, len), "buf": pos + 3000, "playing": p.isPlaying, "live": live || len <= 0])
        let s = p.videoSize
        if !sentVideoSize, s.width > 0, s.height > 0 {
            sentVideoSize = true
            emit("player.video", ["w": Int(s.width), "h": Int(s.height)])
            setAspect(aspect, zoom: 1)
        }
    }
}
