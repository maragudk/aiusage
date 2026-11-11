import SwiftUI

/// A thin capsule bar filled to `fraction` in `color`.
///
/// Drawn by hand because the linear `ProgressView` on macOS doesn't reliably honour `tint`,
/// and the colour is the point of the bar.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                LeadingFraction(fraction: min(max(fraction, 0), 1)) {
                    Capsule()
                        .fill(color)
                }
            }
            .frame(height: 6)
    }
}

/// Places its content at the leading edge, as wide as `fraction` of the available width.
private struct LeadingFraction: Layout {
    let fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Anything above zero shows at least a dot, so a small percentage is still visible.
        let width = fraction > 0 ? max(bounds.width * fraction, bounds.height) : 0
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}
