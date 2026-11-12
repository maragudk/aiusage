import CoreGraphics
import Testing

@testable import AIUsageKit

/// Frames are in AppKit screen coordinates, where y grows upwards. Values come from a real
/// menu bar panel on a two-display Mac: the icon's status item window and the panel under it.
struct PanelPlacementTests {
    private let statusItem = CGRect(x: 4288, y: 2126, width: 32, height: 39)
    private let otherDisplayItem = CGRect(x: 6920, y: 1130, width: 32, height: 39)

    @Test
    func `a panel already under the icon stays put`() {
        let panel = CGRect(x: 4288, y: 1912, width: 300, height: 212)
        #expect(PanelPlacement.pinnedFrame(for: panel, statusItems: [statusItem, otherDisplayItem]) == panel)
    }

    @Test
    func `a panel that dropped away from the menu bar moves back up and keeps its size`() {
        let panel = CGRect(x: 4288, y: 1812, width: 300, height: 212)
        let pinned = PanelPlacement.pinnedFrame(for: panel, statusItems: [otherDisplayItem, statusItem])
        #expect(pinned == CGRect(x: 4288, y: 1912, width: 300, height: 212))
    }

    @Test
    func `a panel that reaches into the menu bar moves down`() {
        let panel = CGRect(x: 4288, y: 2000, width: 300, height: 212)
        let pinned = PanelPlacement.pinnedFrame(for: panel, statusItems: [statusItem])
        #expect(pinned == CGRect(x: 4288, y: 1912, width: 300, height: 212))
    }

    @Test
    func `a few points off is left to the system`() {
        let panel = CGRect(x: 4288, y: 1915, width: 300, height: 212)
        #expect(PanelPlacement.pinnedFrame(for: panel, statusItems: [statusItem]) == panel)
    }

    @Test
    func `a panel right-aligned to an icon near the screen edge uses that icon`() {
        let panel = CGRect(x: 4020, y: 1800, width: 300, height: 212)
        let pinned = PanelPlacement.pinnedFrame(for: panel, statusItems: [otherDisplayItem, statusItem])
        #expect(pinned.maxY == statusItem.minY - PanelPlacement.gap)
    }

    @Test
    func `without a status item the panel stays put`() {
        let panel = CGRect(x: 4288, y: 1812, width: 300, height: 212)
        #expect(PanelPlacement.pinnedFrame(for: panel, statusItems: []) == panel)
    }

    @Test
    func `a status item on another display is ignored`() {
        let panel = CGRect(x: 100, y: 500, width: 300, height: 212)
        #expect(PanelPlacement.pinnedFrame(for: panel, statusItems: [statusItem, otherDisplayItem]) == panel)
    }
}
