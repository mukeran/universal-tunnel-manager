import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    struct LoginItemIssue {
        let requestedEnabled: Bool
        let systemError: String
    }

    let controller: TunnelController
    @Binding var loginItemIssue: LoginItemIssue?
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferences").font(.headline)
            Picker("Language", selection: $language) {
                Text("Follow System").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
            }
            if language != L10n.launchPreference {
                Text("Reopen Universal Tunnel Manager to apply the language change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setLaunchAtLogin
            ))
            if let loginItemIssue {
                let app = Bundle.main.bundleURL.lastPathComponent
                if loginItemIssue.requestedEnabled {
                    Text("Under Open at Login, click + and select \(app).")
                        .font(.caption)
                } else {
                    Text("Under Open at Login, select this app and click − to remove it.")
                        .font(.caption)
                }
                Text(loginItemIssue.systemError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if loginStatus == .requiresApproval {
                Text("Allow this app to launch at login in Login Items & Extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if loginItemIssue != nil || loginStatus == .requiresApproval {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            Toggle("Restore previously enabled forwards on launch", isOn: preference(\.restoreOnLaunch))
                .disabled(!controller.store.canEdit)
            Toggle("Play a sound when a forward connects or disconnects", isOn: preference(\.connectionSounds))
                .disabled(!controller.store.canEdit)
            Toggle("Show notifications when a forward connects or disconnects", isOn: Binding(
                get: { controller.store.configuration.preferences.connectionNotifications },
                set: { enabled in
                    if controller.store.setPreference(\.connectionNotifications, enabled), enabled {
                        TunnelFeedback.requestNotificationAuthorization()
                    }
                }
            ))
            .disabled(!controller.store.canEdit)
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 350, alignment: .leading)
        .onAppear(perform: refreshLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func preference(_ keyPath: WritableKeyPath<TunnelConfiguration.Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { controller.store.configuration.preferences[keyPath: keyPath] },
                set: { controller.store.setPreference(keyPath, $0) })
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        if let loginItemIssue, loginRequestSucceeded(loginItemIssue.requestedEnabled) {
            self.loginItemIssue = nil
        }
    }

    private func loginRequestSucceeded(_ enabled: Bool) -> Bool {
        enabled ? loginStatus == .enabled : loginStatus == .notRegistered
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemIssue = nil
        let service = SMAppService.mainApp
        let systemError: String?
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            systemError = nil
        } catch {
            systemError = error.localizedDescription
        }
        refreshLoginStatus()
        guard !loginRequestSucceeded(enabled) else { return }
        if !(enabled && loginStatus == .requiresApproval) {
            guard let systemError else { return }
            loginItemIssue = LoginItemIssue(requestedEnabled: enabled, systemError: systemError)
        }
        SMAppService.openSystemSettingsLoginItems()
    }
}
