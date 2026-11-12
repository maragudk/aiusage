import SwiftUI

/// The panel that opens from the menu bar icon.
struct PanelView: View {
    let store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.visibleSections) { section in
                    ProviderSectionView(section: section, now: context.date) {
                        store.repairLogin(for: section.id)
                    }
                    Divider()
                }
                FooterView(
                    lastUpdated: store.lastUpdated,
                    isRefreshing: store.isRefreshing,
                    now: context.date
                )
            }
            .padding(14)
            .frame(width: 300)
            .background(PanelWindowAnchor())
        }
    }
}
