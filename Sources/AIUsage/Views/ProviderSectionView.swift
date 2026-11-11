import AIUsageKit
import SwiftUI

/// One provider: its name, then a row per limit, or its error.
struct ProviderSectionView: View {
    let section: ProviderSection
    let now: Date
    let repairLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.name)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let error = section.error {
                ErrorView(section: section, error: error, now: now, repairLogin: repairLogin)
            }

            ForEach(section.limits) { limit in
                LimitRowView(limit: limit, now: now)
            }
            .opacity(section.error == nil ? 1 : 0.6)

            if section.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

private struct ErrorView: View {
    let section: ProviderSection
    let error: UsageError
    let now: Date
    let repairLogin: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.message)
                    .fixedSize(horizontal: false, vertical: true)
                if !section.limits.isEmpty, let lastSuccess = section.lastSuccess {
                    Text("Showing data from \(lastSuccess, format: .dateTime.hour().minute()).")
                        .foregroundStyle(.secondary)
                }
                if let status = section.repairStatus {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                } else if section.canRepairLogin, let title = section.repairTitle {
                    Button(title, action: repairLogin)
                        .controlSize(.small)
                        .help(section.repairHelp ?? "")
                }
            }
        }
        .font(.callout)
    }
}
