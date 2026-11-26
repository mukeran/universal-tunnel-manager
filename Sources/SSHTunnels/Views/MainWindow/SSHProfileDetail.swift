import SwiftUI
import TunnelUI

struct SSHProfileDetail: View {
    let tunnel: SSHTunnel
    let connection: ConnectionStatus
    @State private var activeNetworkService: String?
    @State private var showCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TunnelDetailSection("Port Forwarding") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tunnel.portMappings) { mapping in
                            if mapping.id != tunnel.portMappings.first?.id { Divider() }
                            mappingSummary(mapping)
                        }
                    }
                }
                if connection == .connected || hasSOCKS {
                    TunnelDetailSection("Usage") {
                        VStack(alignment: .leading, spacing: 8) { usage }
                    }
                }
                DisclosureGroup("SSH Command", isExpanded: $showCommand) {
                    UsageRow(label: "SSH", value: sshCommand(for: tunnel)).padding(.top, 8)
                }
            }
            .padding(TunnelDetailLayout.insets)
        }
        .task(id: hasSOCKS) {
            guard hasSOCKS else { return }
            activeNetworkService = await Task.detached { NetworkServiceDetector.activeService() }.value
        }
    }

    private var hasSOCKS: Bool { tunnel.portMappings.contains { $0.forward == .dynamic } }

    private func mappingSummary(_ mapping: PortMapping) -> some View {
        let local = "\(mapping.localHost):\(mapping.localPort)"
        let remote = "\(mapping.remoteHost):\(mapping.remotePort)"
        let type: LocalizedStringKey
        let source: String
        let target: String?
        switch mapping.forward {
        case .local:
            type = "Local Forward"
            source = "Mac \(local)"
            target = "SSH \(remote)"
        case .remote:
            type = "Remote Forward"
            source = "SSH \(remote)"
            target = "Mac \(local)"
        case .dynamic:
            type = "SOCKS Proxy"
            source = local
            target = nil
        }
        return VStack(alignment: .leading, spacing: 7) {
            Text(type).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TunnelRoute(source, to: target)
        }
    }

    @ViewBuilder private var usage: some View {
        let service = activeNetworkService ?? "Wi-Fi"
        if connection == .connected {
            ForEach(tunnel.portMappings) { mapping in
                switch mapping.forward {
                case .dynamic:
                    let address = "\(mapping.localHost):\(mapping.localPort)"
                    UsageRow(label: L10n.text("Proxy"), value: address)
                    UsageRow(label: "socks5h", value: "socks5h://\(address)")
                    UsageRow(label: "socks5", value: "socks5://\(address)")
                    let setup = SSHInvocation.shellCommand(["/usr/sbin/networksetup", "-setsocksfirewallproxy",
                                                            service, mapping.localHost, String(mapping.localPort)])
                    UsageRow(label: L10n.text("Sys on"), value: "\(setup) && \(proxyCommand(service, enabled: true))")
                    UsageRow(label: L10n.text("Sys off"), value: proxyCommand(service, enabled: false))
                    Text("Sys on routes all of this Mac's traffic through the proxy (\(service) is your current network service); Sys off restores it. Run them in a terminal; needs an admin account. Sys off stays shown here while the tunnel is down.")
                        .font(.caption).foregroundStyle(.secondary)
                case .remote:
                    let remotePort = String(mapping.remotePort)
                    let localPort = String(mapping.localPort)
                    let route = L10n.text("Server listens on \(mapping.remoteHost):\(remotePort) → \(mapping.localHost):\(localPort) on this Mac")
                    UsageRow(label: "R :\(remotePort)", value: route)
                case .local:
                    UsageRow(label: ":\(mapping.localPort)", value: "http://\(mapping.localHost):\(mapping.localPort)")
                }
            }
        } else {
            UsageRow(label: L10n.text("Sys off"), value: proxyCommand(service, enabled: false))
            Text("If you enabled the system-level SOCKS proxy while the tunnel was up, this restores direct internet access.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func proxyCommand(_ service: String, enabled: Bool) -> String {
        SSHInvocation.shellCommand(["/usr/sbin/networksetup", "-setsocksfirewallproxystate", service, enabled ? "on" : "off"])
    }
}
