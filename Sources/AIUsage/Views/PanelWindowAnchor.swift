import AIUsageKit
import AppKit
import SwiftUI

/// Keeps the panel window's top edge just under the menu bar icon, whatever the content height.
///
/// The `.window` style `MenuBarExtra` can leave its window where it was when the content shrinks or grows,
/// so the panel drifts away from the menu bar. This re-pins it whenever the window resizes or opens.
struct PanelWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observers: [any NSObjectProtocol] = []
        /// Moving the window posts a move notification, which would re-enter `pinTop`.
        private var isPinning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            guard let window else {
                return
            }
            // Moves count too: the menu bar item changes width when its label changes between icon and number,
            // and the system may then put an open panel back where it was.
            let names = [
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.pinTop()
                    }
                }
            }
            pinTop()
        }

        private func pinTop() {
            guard let window, !isPinning else {
                return
            }
            // The app's own status item windows; macOS keeps one per display.
            let statusItems = NSApp.windows
                .filter { $0 !== window && $0.className.contains("StatusBarWindow") }
                .map(\.frame)
            let frame = window.frame
            let pinned = PanelPlacement.pinnedFrame(for: frame, statusItems: statusItems)
            guard pinned != frame else {
                return
            }
            Log.app.notice("panel repinned top=\(Int(frame.maxY), privacy: .public) to=\(Int(pinned.maxY), privacy: .public) height=\(Int(frame.height), privacy: .public)")
            isPinning = true
            defer { isPinning = false }
            window.setFrameOrigin(pinned.origin)
        }
    }
}
