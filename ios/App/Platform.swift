#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// What the bridge asks of the screen around the web page: the iPhone's view controller or the Mac's window.
protocol AppHost: AnyObject {
    func setBackground(hex: String)
    func setVideoRect(x: Double, y: Double, w: Double, h: Double, visible: Bool)
    func shareBackup(_ json: Data)
    func pickBackup()
    func showAirPlayPicker()
    func requestOrientation(landscape: Bool)
    /// "Close the app" from the page (double back on Home, the sleep timer)
    func exitApp()
    /// the sleep timer's "go to the background"
    func moveToBackground()
    func toggleFullScreen()
}

extension PlatformView {
    /// Grows and shrinks with the view it sits in.
    func followParentSize() {
        #if os(macOS)
        autoresizingMask = [.width, .height]
        #else
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
    }
}
