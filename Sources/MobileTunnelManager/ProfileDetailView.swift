import SwiftUI
import TunnelUI

struct ProfileDetail: View {
    let controller: TunnelController
    let profile: TunnelRule
    let edit: () -> Void
    let delete: () -> Void

    private var subtitle: String {
        switch profile {
        case .device(let tunnel, _):
            let device = controller.devices.listedDevices.first { $0.id == tunnel.device }
            return "\(tunnel.device.platform.title) · \(device.map(controller.devices.displayName) ?? tunnel.deviceName)"
        case .ssh(let tunnel): return "SSH · \(tunnel.host)"
        case .socat(let session): return "socat · \(session.displayLocation)"
        }
    }

    var body: some View {
        let status = controller.status(profile)
        TunnelDetailPane(profile.name, subtitle: subtitle, icon: profile.kind.icon) {
            status.title
                .font(.caption.weight(.medium)).foregroundStyle(status.color).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(status.color.opacity(0.10), in: Capsule())
            Toggle(profile.name, isOn: controller.profileBinding(profile))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!controller.canToggle(profile))
            Button("Edit", action: edit).disabled(!controller.canEdit(profile))
            Menu {
                Button("Delete Profile…", role: .destructive, action: delete).disabled(!controller.canEdit(profile))
            } label: {
                Label("Profile Actions", systemImage: "ellipsis").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let detail = status.detail {
                    Label(detail, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(status.color).textSelection(.enabled)
                        .padding(.horizontal, TunnelDetailLayout.insets.leading)
                        .padding(.top, TunnelDetailLayout.insets.top)
                }
                switch profile {
                case .device(let tunnel, _):
                    DeviceProfileDetail(manager: controller.devices, tunnel: tunnel)
                case .ssh(let tunnel):
                    SSHProfileDetail(tunnel: tunnel, connection: controller.ssh.status(for: tunnel))
                case .socat(let session):
                    SocatDetail(profile: session, manager: controller.socat)
                }
            }
        }
    }
}

struct ProfileGroupDetail: View {
    let controller: TunnelController
    let section: ProfileGroupSection
    let select: (TunnelRule.Key) -> Void
    let edit: (ProfileGroup) -> Void
    let delete: (ProfileGroup) -> Void
    let add: () -> Void

    var body: some View {
        let profiles = section.profiles
        TunnelDetailPane(section.displayName, subtitle: L10n.text("Profiles: \(profiles.count)"), icon: section.icon) {
            Toggle("Enable Group", isOn: controller.groupBinding(profiles))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(profiles.isEmpty)
            Button("Add", action: add)
            if let group = section.group {
                Menu {
                    Button("Rename…") { edit(group) }
                    Button("Delete Group…", role: .destructive) { delete(group) }
                } label: {
                    Label("Group Actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        } content: {
            if profiles.isEmpty {
                ContentUnavailableView("Empty Group", systemImage: "folder",
                                       description: Text("Create a profile or move an existing profile into this group."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(profiles, id: \.key) { profile in
                            let status = controller.status(profile)
                            HStack {
                                Button { select(profile.key) } label: {
                                    TunnelSidebarLabel(profile.name, subtitle: "\(profile.kind.title) · \(profile.route)") {
                                        Circle().fill(status.color).frame(width: 8, height: 8)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Toggle(profile.name, isOn: controller.profileBinding(profile))
                                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                                    .disabled(!controller.canToggle(profile))
                            }
                            .tunnelDetailCard()
                        }
                    }
                    .padding(TunnelDetailLayout.insets)
                }
            }
        }
    }
}

struct ProfileGroupEditor: View {
    @State var group: ProfileGroup
    let onSave: (ProfileGroup) -> String?

    var body: some View {
        let title = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        TunnelProfileEditor(title.isEmpty ? L10n.text("New Group") : title, subtitle: L10n.text("Profile Group"), icon: "folder",
                            width: 400, canSave: !title.isEmpty, onSave: save) {
            TunnelEditorField("Name") { TextField("Name", text: $group.title) }
        }
    }

    private func save() -> String? {
        var updated = group
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return L10n.text("Enter a group name.") }
        return onSave(updated)
    }
}
