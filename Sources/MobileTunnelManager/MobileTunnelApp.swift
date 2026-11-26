import AppKit
import SwiftUI

@main
struct MobileTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Mobile Tunnel Manager", id: "manager") {
            ManagerView(manager: app.manager)
                .frame(minWidth: 720, minHeight: 440)
                .background(ManagerWindowAttachment(app: app, openWindow: openWindow))
        }
        .defaultSize(width: 840, height: 520)

        MenuBarExtra {
            TunnelMenuView(manager: app.manager) {
                app.showManager(using: openWindow)
            }
        } label: {
            Image(nsImage: MobileTunnelIcon.menuBar)
                .accessibilityLabel("Mobile Tunnel Manager")
        }
        .menuBarExtraStyle(.window)
    }
}

private enum MobileTunnelIcon {
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            drawGlyph(color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func drawGlyph(color: NSColor) {
        let phone = NSBezierPath(roundedRect: NSRect(x: 2.25, y: 1.75, width: 9, height: 14.5),
                                 xRadius: 2, yRadius: 2)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 6.5, y: 9))
        arrow.line(to: NSPoint(x: 17, y: 9))
        arrow.move(to: NSPoint(x: 14, y: 12))
        arrow.line(to: NSPoint(x: 17, y: 9))
        arrow.line(to: NSPoint(x: 14, y: 6))
        let home = NSBezierPath(ovalIn: NSRect(x: 6, y: 4, width: 1.5, height: 1.5))
        color.set()
        for path in [phone, arrow] {
            path.lineWidth = 1.45
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        home.fill()
    }
}

private struct ManagerWindowAttachment: NSViewRepresentable {
    let app: AppDelegate
    let openWindow: OpenWindowAction

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.app = app
        app.openManagerWindow = openWindow
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        weak var app: AppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { app?.attachManagerWindow(window) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = TunnelManager()
    var openManagerWindow: OpenWindowAction?
    private weak var managerWindow: NSWindow?
    private var isExiting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.startMonitoring()
    }

    func attachManagerWindow(_ window: NSWindow) {
        if managerWindow === window { return }
        let center = NotificationCenter.default
        if let previous = managerWindow {
            center.removeObserver(self, name: nil, object: previous)
        }
        managerWindow = window
        center.addObserver(self, selector: #selector(managerWindowShown),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(managerWindowShown),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(managerWindowWillClose),
                           name: NSWindow.willCloseNotification, object: window)
        if window.isVisible { showDockIcon() }
    }

    func showManager(using openWindow: OpenWindowAction) {
        showDockIcon()
        if managerWindow?.isMiniaturized == true { managerWindow?.deminiaturize(nil) }
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let openManagerWindow else { return true }
        showManager(using: openManagerWindow)
        return false
    }

    private func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func managerWindowShown(_ notification: Notification) {
        if managerWindow?.isVisible == true { showDockIcon() }
    }

    @objc private func managerWindowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.managerWindow?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isExiting else { return .terminateLater }
        isExiting = true
        Task {
            let remaining = await manager.shutdown()
            if !remaining.isEmpty {
                let alert = NSAlert()
                alert.messageText = "部分 ADB 转发未能关闭"
                alert.informativeText = remaining.joined(separator: "、") + "。可以在设备恢复连接后通过 adb 检查并移除剩余规则。"
                alert.addButton(withTitle: "退出")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
