import AppKit
import SwiftUI
import UserNotifications

@main
enum UniversalTunnelMain {
    @MainActor
    static func main() {
        if SocatAskPass.isRequested {
            SocatAskPass.prompt()
        } else {
            UniversalTunnelApp.main()
        }
    }
}

struct UniversalTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: TunnelSelection?
    @State private var newRequest = 0

    var body: some Scene {
        Window("Universal Tunnel Manager", id: "manager") {
            UnifiedManagerView(controller: app.controller, selection: $selection, newRequest: newRequest)
                .frame(minWidth: 720, minHeight: 440)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(ManagerWindowAttachment(app: app, openWindow: openWindow))
                .environment(\.locale, L10n.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 550)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New Forward")) { newRequest += 1 }.keyboardShortcut("n")
            }
        }

        MenuBarExtra {
            UniversalMenu(controller: app.controller) {
                app.showManager(using: openWindow)
            }
            .background(MenuBarPanelSizer())
            .environment(\.locale, L10n.locale)
        } label: {
            Image(nsImage: TunnelIcon.menuBar)
                .accessibilityLabel("Universal Tunnel Manager")
        }
        .menuBarExtraStyle(.window)
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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let controller = TunnelController()
    var openManagerWindow: OpenWindowAction?
    private weak var managerWindow: NSWindow?
    private var isExiting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        controller.start()
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
            let remaining = await controller.shutdown()
            if !remaining.isEmpty {
                let alert = NSAlert()
                alert.messageText = L10n.text("Some ADB forwards could not be stopped")
                let rules = remaining.joined(separator: ", ")
                alert.informativeText = L10n.text("When the devices reconnect, use adb to inspect and remove the remaining rules.\n\n\(rules)")
                alert.addButton(withTitle: L10n.text("Quit"))
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
