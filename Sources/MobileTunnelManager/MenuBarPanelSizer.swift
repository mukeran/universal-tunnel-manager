import AppKit
import SwiftUI

struct MenuBarPanelSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> ContentSizeView { ContentSizeView() }

    func updateNSView(_ view: ContentSizeView, context: Context) {
        view.scheduleFit()
    }

    final class ContentSizeView: NSView {
        private var fitScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                    center.addObserver(self, selector: #selector(windowEnvironmentChanged), name: name, object: window)
                }
                center.addObserver(self, selector: #selector(windowEnvironmentChanged),
                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
            scheduleFit()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleFit()
        }

        override func layout() {
            super.layout()
            scheduleFit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleFit() {
            guard !fitScheduled else { return }
            fitScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fitToContent()
                self.fitScheduled = false
            }
        }

        @objc private func windowEnvironmentChanged(_ notification: Notification) {
            scheduleFit()
        }

        private func fitToContent() {
            guard let window, bounds.width > 1, bounds.height > 1 else { return }
            let frame = window.frame
            let anchor = NSPoint(x: frame.midX, y: frame.maxY - 1)
            let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? window.screen
            let scale = screen?.backingScaleFactor ?? window.backingScaleFactor
            let content = NSRect(origin: .zero, size: bounds.size)
            let windowSize = window.frameRect(forContentRect: content).size
            let fitted = MenuBarPanelSizer.fittedFrame(for: windowSize, anchoredTo: frame,
                                                      within: screen?.visibleFrame, scale: scale)
            let tolerance = 0.25 / scale
            guard abs(frame.width - fitted.width) > tolerance || abs(frame.height - fitted.height) > tolerance
                    || abs(frame.minX - fitted.minX) > tolerance || abs(frame.minY - fitted.minY) > tolerance
            else { return }
            window.setFrame(fitted, display: window.isVisible)
            window.invalidateShadow()
        }
    }

    static func fittedFrame(for size: NSSize, anchoredTo frame: NSRect,
                            within visible: NSRect?, scale: CGFloat) -> NSRect {
        func aligned(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat {
            (value * scale).rounded(rule) / scale
        }
        let width = aligned(size.width, .up)
        let height = aligned(size.height, .up)
        var left = aligned(frame.midX - width / 2, .toNearestOrAwayFromZero)
        var bottom = aligned(frame.maxY - height, .toNearestOrAwayFromZero)
        if let visible {
            let minLeft = aligned(visible.minX, .up)
            let maxLeft = aligned(visible.maxX, .down) - width
            let minBottom = aligned(visible.minY, .up)
            let maxBottom = aligned(visible.maxY, .down) - height
            left = max(minLeft, min(left, maxLeft))
            bottom = min(maxBottom, max(bottom, minBottom))
        }
        return NSRect(x: left, y: bottom, width: width, height: height)
    }
}
