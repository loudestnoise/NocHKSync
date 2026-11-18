import SwiftUI

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Both must happen before launch finishes so background wakes reach the app.
        BackgroundSync.registerTask()
        Task { await SyncEngine.shared.startBackgroundSyncIfEnabled() }
        return true
    }
}

@main
struct NocHKSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = SyncEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
        }
    }
}
