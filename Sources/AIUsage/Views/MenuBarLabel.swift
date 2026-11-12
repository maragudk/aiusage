import AIUsageKit
import AppKit
import SwiftUI

/// The menu bar item: Claude's weekly percentage as a number, or the gauge icon when there is no current value.
///
/// The number is a template image, not a `Text`. A `MenuBarExtra` label turns text into a plain button title and
/// drops its font, so `monospacedDigit()` would have no effect and the width would jitter. A template image
/// is tinted by the system, so it follows light and dark menu bars like the icon.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        if let percent = store.menuBarPercent {
            Image(nsImage: Self.image(number: percent))
        } else {
            Label("AIUsage", systemImage: "gauge.with.dots.needle.33percent")
        }
    }

    static func image(number: Int) -> NSImage {
        let text = String(number)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let width = ceil((text as NSString).size(withAttributes: attributes).width)
        // 18 pt like the icon, or taller if the menu bar font is large enough to need it.
        let height = max(18, ceil(font.ascender - font.descender))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            // Centre the digits themselves, which sit between the baseline and the cap height.
            let baseline = (rect.height - font.capHeight) / 2
            (text as NSString).draw(at: NSPoint(x: 0, y: baseline + font.descender), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude weekly usage \(UsageFormat.percent(Double(number)))"
        return image
    }
}
