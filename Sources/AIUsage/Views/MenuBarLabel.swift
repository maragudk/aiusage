import AIUsageKit
import AppKit
import SwiftUI

/// The menu bar item: the weekly percentages of Claude, Codex and Gemini as three two-character slots, like
/// `86 42 17`, with `--` for a slot without a number.
///
/// The text is a template image, not a `Text`. A `MenuBarExtra` label turns text into a plain button title and
/// drops its font and accessibility label, so `monospacedDigit()` would have no effect and the width would jitter.
/// A template image is tinted by the system, so it follows light and dark menu bars.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        Image(nsImage: Self.image(slots: store.menuBarSlots))
    }

    static func image(slots: [MenuBarUsage.Slot]) -> NSImage {
        let labels = MenuBarUsage.labels(for: slots)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // Each slot is drawn centred in a cell two digits wide, whatever its text, so the item never changes width.
        // Digits share one width in this font, but `X` is about 1.3 pt wider than two digits at 13 pt, and `--` is
        // about 4 pt narrower. The figure dash and minus sign are digit-wide, but two of them run into one line.
        let cellWidth = ceil(("00" as NSString).size(withAttributes: attributes).width)
        let gap = ceil((" " as NSString).size(withAttributes: attributes).width)
        let count = CGFloat(labels.count)
        let width = count * cellWidth + max(count - 1, 0) * gap
        // 18 pt like a menu bar icon, or taller if the menu bar font is large enough to need it.
        let height = max(18, ceil(font.ascender - font.descender))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            // Centre the text itself, which sits between the baseline and the cap height.
            let baseline = (rect.height - font.capHeight) / 2
            for (index, label) in labels.enumerated() {
                let textWidth = (label as NSString).size(withAttributes: attributes).width
                let x = CGFloat(index) * (cellWidth + gap) + (cellWidth - textWidth) / 2
                (label as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        // VoiceOver gets the real numbers, not the padded, `XX` or `--` text.
        image.accessibilityDescription = MenuBarUsage.accessibilityDescription(for: slots)
        return image
    }
}
