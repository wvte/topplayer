import UIKit

/// Small taps under the finger, like the system apps.
enum Haptics {
    static func tap(_ style: String) {
        let s: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "medium": s = .medium
        case "heavy": s = .heavy
        case "rigid": s = .rigid
        case "soft": s = .soft
        default: s = .light
        }
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
}
