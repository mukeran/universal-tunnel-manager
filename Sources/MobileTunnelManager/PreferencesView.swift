import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    let manager: TunnelManager
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("登录时自动启动", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setLaunchAtLogin
            ))
            if loginStatus == .requiresApproval {
                Text("请在系统设置中允许此登录项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Divider()
            Toggle("启动应用时恢复上次启用的转发", isOn: Binding(
                get: { manager.settings.restoreOnLaunch },
                set: manager.setRestoreOnLaunch
            ))
        }
        .padding(16)
        .frame(width: 315, alignment: .leading)
        .onAppear(perform: refreshLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            if !enabled || service.status != .requiresApproval {
                loginError = error.localizedDescription
            }
        }
        refreshLoginStatus()
    }
}
