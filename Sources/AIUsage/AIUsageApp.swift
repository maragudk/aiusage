import AIUsageKit
import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("AIUsage", systemImage: "gauge.with.dots.needle.33percent") {
            PanelView(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the store, so polling starts at launch rather than when the panel first opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(providers: [
        ClaudeProvider(),
        CodexProvider(version: AppDelegate.version),
    ])

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launched version=\(Self.version, privacy: .public)")
        store.start()
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
