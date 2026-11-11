import AIUsageKit
import AppKit
import SwiftUI

/// Last update time, Refresh, Launch at login and Quit.
struct FooterView: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let now: Date
    let refresh: () -> Void

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
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.body)
                    .keyboardShortcut("r")
                    .help("Refresh now (⌘R)")
                    .disabled(isRefreshing)
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
