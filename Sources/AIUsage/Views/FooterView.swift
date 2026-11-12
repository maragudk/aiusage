import AIUsageKit
import AppKit
import SwiftUI

/// Last update time, Launch at login and Quit.
struct FooterView: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Updating…")
                } else if let lastUpdated {
                    Text(UsageFormat.updated(lastUpdated, now: now))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                LaunchAtLoginToggle()
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
    }
}
