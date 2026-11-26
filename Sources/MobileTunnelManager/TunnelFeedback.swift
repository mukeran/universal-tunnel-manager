import AppKit
import UserNotifications
import os

@MainActor
enum TunnelFeedback {
    enum Event: Equatable {
        case connected
        case disconnected(retrying: Bool)

        var notificationBody: String {
            switch self {
            case .connected: L10n.text("Forwarding started")
            case .disconnected(retrying: true): L10n.text("Forwarding disconnected. Waiting to retry.")
            case .disconnected(retrying: false): L10n.text("Forwarding stopped")
            }
        }
    }

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "UniversalTunnelManager",
        category: "TunnelFeedback"
    )

    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func announce(_ event: Event, name: String, using store: TunnelStore) {
        let preferences = store.configuration.preferences
        if preferences.connectionSounds {
            NSSound(named: event == .connected ? "Pop" : "Basso")?.play()
        }
        guard preferences.connectionNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = event.notificationBody
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
