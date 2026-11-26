import AppKit
import SwiftUI

struct TunnelMenuView: View {
    let manager: TunnelManager
    let openManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manager.settings.tunnels.isEmpty {
                Text("还没有转发规则")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ViewThatFits(in: .vertical) {
                    tunnelGroups.fixedSize(horizontal: false, vertical: true)
                    ScrollView { tunnelGroups }
                }
                .frame(maxHeight: 360)
            }

            Divider().padding(.horizontal, 10)

            menuAction("打开转发管理", icon: "gearshape", action: openManager)
            menuAction("退出 Mobile Tunnel Manager", icon: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tunnelGroups: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(manager.listedDevices) { device in
                let tunnels = manager.settings.tunnels.filter { $0.device == device.id }
                if !tunnels.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(device.name, systemImage: device.id.platform.icon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                        ForEach(tunnels) { tunnel in
                            tunnelRow(tunnel)
                        }
                    }
                }
            }
        }
    }

    private func tunnelRow(_ tunnel: Tunnel) -> some View {
        let state = manager.state(for: tunnel)
        return HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(state.statusColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel(state.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: tunnel.route)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(state.statusColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Toggle("启用 \(tunnel.name)", isOn: Binding(
                get: { manager.enabled(tunnel) },
                set: { _ in manager.toggle(tunnel) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("启用 \(tunnel.name)")
        }
        .padding(.vertical, 5)
        .modifier(MenuRowHover())
        .help(state.detail ?? state.title)
    }

    private func menuAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .modifier(MenuRowHover())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuRowHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(isHovered ? 0.09 : 0))
            }
            .background(MenuRowTracking { isHovered = $0 })
            .padding(.horizontal, 5)
            .onDisappear { isHovered = false }
    }
}

private struct MenuRowTracking: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
