import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { .landscape }
}

struct WebHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> MainViewController { MainViewController() }
    func updateUIViewController(_ vc: MainViewController, context: Context) {}
}

@main
struct TopplayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            WebHost().ignoresSafeArea().statusBarHidden(true).preferredColorScheme(.dark)
        }
    }
}
