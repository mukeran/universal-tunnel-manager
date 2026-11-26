import Foundation

@MainActor
final class TunnelController {
    let store: TunnelStore
    let devices: DeviceTunnelManager
    let ssh: SSHTunnelManager
    let socat: SocatManager
    private var hasStarted = false
    private var shuttingDown = false

    init(appSupport: URL = .applicationSupportDirectory) {
        let store = TunnelStore(appSupport: appSupport)
        self.store = store
        devices = DeviceTunnelManager(store: store)
        ssh = SSHTunnelManager(store: store)
        socat = SocatManager(store: store)
    }

    func start() {
        guard !hasStarted, !shuttingDown else { return }
        hasStarted = true
        let configuration = store.configuration
        let restore = configuration.preferences.restoreOnLaunch ? configuration.rememberedEnabledProfiles : []
        if configuration.preferences.connectionNotifications {
            TunnelFeedback.requestNotificationAuthorization()
        }
        devices.startMonitoring()
        ssh.start()
        for profile in configuration.rules where restore.contains(profile.key) || profile.startsOnLaunch {
            applyEnabled(true, to: profile, allowPasswordPrompt: false)
        }
        rememberEnabledProfiles()
    }

    func isEnabled(_ profile: TunnelRule) -> Bool {
        switch profile {
        case .device(let tunnel, _): devices.enabled(tunnel)
        case .ssh(let tunnel): ssh.isEnabled(tunnel)
        case .socat(let session): socat.isEnabled(session)
        }
    }

    func canToggle(_ profile: TunnelRule) -> Bool {
        if case .socat(let session) = profile { return socat.canToggle(session) }
        return true
    }

    func setEnabled(_ reference: TunnelRule, _ enabled: Bool) {
        guard !shuttingDown,
              let profile = store.configuration.rules.first(where: { $0.key == reference.key }),
              canToggle(profile), isEnabled(profile) != enabled else { return }
        applyEnabled(enabled, to: profile)
        rememberEnabledProfiles()
    }

    private func applyEnabled(_ enabled: Bool, to profile: TunnelRule, allowPasswordPrompt: Bool = true) {
        switch profile {
        case .device(let tunnel, _): devices.setEnabled(enabled, for: tunnel)
        case .ssh(let tunnel):
            if enabled { ssh.connect(tunnel: tunnel) } else { ssh.disconnect(tunnel: tunnel) }
        case .socat(let session):
            if enabled { socat.start(session, allowPasswordPrompt: allowPasswordPrompt) }
            else { socat.stop(session) }
        }
    }

    private func rememberEnabledProfiles() {
        let enabled = store.configuration.rules.filter { profile in
            if case .socat(let session) = profile { return socat.isEnabledForRestore(session) }
            return isEnabled(profile)
        }
        store.rememberEnabledProfiles(Set(enabled.map(\.key)))
    }

    func canEdit(_ profile: TunnelRule) -> Bool {
        guard store.canEdit else { return false }
        switch profile {
        case .device(let tunnel, _): return devices.canEdit(tunnel)
        case .ssh: return true
        case .socat(let session): return !socat.isEnabled(session) && !socat.isStopping(session)
        }
    }

    func delete(_ profile: TunnelRule) {
        guard canEdit(profile) else { return }
        switch profile {
        case .device(let tunnel, _): devices.delete(tunnel)
        case .ssh(let tunnel): ssh.deleteTunnel(tunnel)
        case .socat(let session): socat.delete(session)
        }
    }

    func duplicate(_ original: TunnelRule) -> TunnelRule.Key? {
        let groupID = store.group(for: original.key)?.id
        let copy: TunnelRule
        let saved: Bool
        switch original {
        case .device(var tunnel, _):
            tunnel.id = UUID()
            tunnel.name = L10n.text("\(tunnel.name) Copy")
            copy = .device(tunnel, enabled: false)
            saved = devices.addOrUpdate(tunnel, in: groupID, after: original.key)
        case .ssh(var tunnel):
            tunnel.id = UUID()
            tunnel.name = L10n.text("\(tunnel.name) Copy")
            tunnel.autoConnect = false
            copy = .ssh(tunnel)
            saved = ssh.save(tunnel, in: groupID, after: original.key)
        case .socat(var session):
            session.id = UUID()
            session.name = L10n.text("\(session.name) Copy")
            session.autoStart = false
            copy = .socat(session)
            saved = socat.save(session, in: groupID, after: original.key)
        }
        return saved ? copy.key : nil
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        if hasStarted { rememberEnabledProfiles() }
        async let sshShutdown: Void = ssh.shutdown()
        async let socatShutdown: Void = socat.shutdown()
        let remaining = await devices.shutdown()
        _ = await (sshShutdown, socatShutdown)
        return remaining
    }
}
