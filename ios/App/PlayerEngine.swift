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

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
        av = AVEngine(emit: emit)
        vlc = VLCEngine(emit: emit)
        super.init()
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
        show(.vlc)
        vlc.play(lastArgs)
        return true
    }

    // MARK: control

    func play(_ a: [String: Any]) {
        lastArgs = a
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // stop the other engine without telling the page that playback ended
        if prefersApple(a) {
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
        av.stop()
        vlc.stop()
        lastArgs = [:]
        show(.none)
    }

    func pause() { active == .vlc ? vlc.pause() : av.pause() }
    func resume() { active == .vlc ? vlc.resume() : av.resume() }
    func toggle() { active == .vlc ? vlc.toggle() : av.toggle() }
    func seekTo(_ ms: Int64) { active == .vlc ? vlc.seekTo(ms) : av.seekTo(ms) }
    func seekBy(_ ms: Int64) { active == .vlc ? vlc.seekBy(ms) : av.seekBy(ms) }
    func setSpeed(_ s: Float) { active == .vlc ? vlc.setSpeed(s) : av.setSpeed(s) }
    func setAspect(_ mode: String, zoom: Float) { active == .vlc ? vlc.setAspect(mode, zoom: zoom) : av.setAspect(mode, zoom: zoom) }
    func configure(_ a: [String: Any]) { av.configure(a); vlc.configure(a) }
    func tracks() -> [String: Any] { active == .vlc ? vlc.tracks() : av.tracks() }
    func selectTrack(type: String, id: String) { active == .vlc ? vlc.selectTrack(type: type, id: id) : av.selectTrack(type: type, id: id) }
    func togglePictureInPicture() { if active == .av { av.togglePictureInPicture() } }

    func setRect(x: Double, y: Double, w: Double, h: Double, visible: Bool) { view.isHidden = active == .none }
}
