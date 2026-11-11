import AIUsageKit
import SwiftUI

/// One limit: name and percentage, a bar coloured by severity, and when it resets.
struct LimitRowView: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                Spacer()
                Text(UsageFormat.percent(limit.percentUsed))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            UsageBar(fraction: limit.percentUsed / 100, color: limit.displaySeverity.color)
                .accessibilityHidden(true)
            if let resetsAt = limit.resetsAt {
                Text("Resets \(UsageFormat.relative(to: resetsAt, now: now)) · \(UsageFormat.absolute(resetsAt, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}
