import AppKit
import SwiftUI
import TunnelUI

struct UniversalMenu: View {
    let controller: TunnelController
    let openManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .vertical) {
                entries.fixedSize(horizontal: false, vertical: true)
                ScrollView { entries }
            }
            .frame(maxHeight: 360)
            Divider().padding(.horizontal, 10)
            menuAction("Open Tunnel Manager", icon: "macwindow", action: openManager)
            menuAction("Quit Universal Tunnel Manager", icon: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuHoverTracking())
    }

    private var entries: some View {
        let sections = controller.store.profileSections
        return VStack(alignment: .leading, spacing: 8) {
            if sections.isEmpty {
                Text("No profiles yet").foregroundStyle(.secondary).padding(12)
            }
            ForEach(sections) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: group.icon).frame(width: 16).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(group.displayName)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                        Toggle(group.displayName, isOn: controller.groupBinding(group.profiles))
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                            .disabled(group.profiles.isEmpty)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    rows(group.profiles)
                }
            }
        }
    }

    private func rows(_ profiles: [TunnelRule]) -> some View {
        ForEach(profiles, id: \.key) { profile in
            let status = controller.status(profile)
            TunnelMenuRow(profile.name, route: "\(profile.kind.title) · \(profile.route)",
                          status: status.title, color: status.color, detail: status.detail,
                          enabled: controller.profileBinding(profile),
                          disabled: !controller.canToggle(profile))
        }
    }

    private func menuAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16).accessibilityHidden(true)
                Text(title)
            }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .modifier(MenuRowHover())
        }
        .buttonStyle(.plain)
    }
}
