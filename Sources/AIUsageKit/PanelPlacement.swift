import CoreGraphics

/// Where the menu bar panel belongs: with its top edge just under the menu bar icon.
///
/// The panel's window can drift away from the menu bar when its content height changes, because
/// a window keeps its bottom-left origin when it resizes. All frames are in AppKit screen coordinates,
/// where y grows upwards.
public enum PanelPlacement {
    /// The space between the icon's status item window and the panel's top edge, as macOS places it.
    public static let gap: CGFloat = 2
    /// Drift up to this is left alone, so the app never fights the system's own placement.
    static let tolerance: CGFloat = 4

    /// `panel` moved vertically so its top edge sits `gap` under its status item, with its size and x unchanged.
    /// Returns `panel` unchanged if it is already there, or if none of `statusItems` belongs to it.
    ///
    /// The panel's status item is one that overlaps it horizontally and isn't below it. macOS has a status
    /// item window per display, so the others are ignored.
    public static func pinnedFrame(for panel: CGRect, statusItems: [CGRect]) -> CGRect {
        let candidates = statusItems.filter { item in
            item.maxX > panel.minX && item.minX < panel.maxX && item.minY >= panel.minY
        }
        guard let item = candidates.min(by: { distance(panel, $0) < distance(panel, $1) }) else {
            return panel
        }
        let top = item.minY - gap
        guard abs(panel.maxY - top) > tolerance else {
            return panel
        }
        return CGRect(x: panel.minX, y: top - panel.height, width: panel.width, height: panel.height)
    }

    private static func distance(_ panel: CGRect, _ item: CGRect) -> CGFloat {
        abs(item.minY - gap - panel.maxY)
    }
}
