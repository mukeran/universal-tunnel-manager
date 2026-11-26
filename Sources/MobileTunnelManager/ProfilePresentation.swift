import SwiftUI

struct ProfileGroupSection: Identifiable {
    let group: ProfileGroup?
    let profiles: [TunnelRule]

    var id: UUID? { group?.id }
    var displayName: String { group?.displayName ?? L10n.text("Ungrouped") }
    var icon: String { group == nil ? "tray" : "folder" }
}

extension TunnelStore {
    var profileSections: [ProfileGroupSection] {
        let ungrouped = self.ungrouped
        var sections = configuration.groups.map {
            ProfileGroupSection(group: $0, profiles: profiles(in: $0))
        }
        if !ungrouped.isEmpty {
            sections.insert(ProfileGroupSection(group: nil, profiles: ungrouped), at: 0)
        }
        return sections
    }
}

struct ProfileStatus {
    let title: Text
    let color: Color
    var detail: String? = nil
}

@MainActor
extension TunnelController {
    func status(_ profile: TunnelRule) -> ProfileStatus {
        switch profile {
        case .device(let tunnel, _):
            let state = devices.state(for: tunnel)
            if let error = devices.hookErrors[tunnel.id] {
                let title = devices.enabled(tunnel) ? Text(state.title) : Text("Forwarding Failed")
                return ProfileStatus(title: title, color: devices.enabled(tunnel) ? state.statusColor : .red,
                                     detail: error)
            }
            return ProfileStatus(title: Text(state.title), color: state.statusColor, detail: state.detail)
        case .ssh(let tunnel):
            let connection = ssh.status(for: tunnel)
            let error = ssh.lastError(for: tunnel)
            if connection != .connected, let error {
                return ProfileStatus(title: Text("Failed"), color: .red, detail: error)
            }
            switch connection {
            case .disconnected: return ProfileStatus(title: Text("Disconnected"), color: .secondary)
            case .connecting: return ProfileStatus(title: Text("Connecting..."), color: .orange)
            case .connected: return ProfileStatus(title: Text("Connected"), color: .green, detail: error)
            }
        case .socat(let session):
            let hookError = socat.hookErrors[session.id]
            if socat.isStopping(session) { return ProfileStatus(title: Text("Stopping"), color: .orange, detail: hookError) }
            let state = socat.status(session)
            switch state {
            case .failed(let reason):
                return ProfileStatus(title: Text("Forwarding Failed"), color: .red,
                                     detail: hookError.map { reason + "\n" + $0 } ?? reason)
            case .retrying:
                return ProfileStatus(title: Text("Waiting to Retry"), color: .orange, detail: hookError ?? state.title)
            case .stopped, .starting, .running, .finished:
                return ProfileStatus(title: Text(state.title), color: state.indicator.statusColor, detail: hookError)
            }
        }
    }

    func active(_ profiles: [TunnelRule]) -> Bool {
        !profiles.isEmpty && profiles.allSatisfy(isEnabled)
    }

    func profileBinding(_ profile: TunnelRule) -> Binding<Bool> {
        Binding(get: { self.isEnabled(profile) }, set: { self.setEnabled(profile, $0) })
    }

    func groupBinding(_ profiles: [TunnelRule]) -> Binding<Bool> {
        Binding(get: { self.active(profiles) }, set: { enabled in
            for profile in profiles { self.setEnabled(profile, enabled) }
        })
    }
}

extension TunnelState {
    var statusColor: Color {
        switch self {
        case .active: Color(nsColor: .systemGreen)
        case .failed, .conflict: .red
        case .waiting, .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }
}
