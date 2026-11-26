import SwiftUI
import TunnelUI

@MainActor
struct SSHTunnelEditor: View {
    let onSave: (SSHTunnel) -> String?
    @Environment(SSHTunnelManager.self) private var tunnelManager
    @FocusState private var focusedField: Field?
    @State private var editedTunnel: SSHTunnel
    @State private var showJumpHost: Bool
    @State private var showExtraOptions: Bool
    @State private var showCustomCommand: Bool
    @State private var showControlPath: Bool
    @State private var showAdvanced = false
    @State private var isAliasPickerPresented = false

    enum Field: Hashable {
        case name, host, port, identityFile, alias
        case mappingLocalHost(UUID), mappingLocalPort(UUID)
        case mappingRemoteHost(UUID), mappingRemotePort(UUID)
        case connectTimeout, aliveInterval, aliveCountMax
        case proxyJump, extraOptions
        case customCommand
        case controlPath
    }

    init(tunnel: SSHTunnel, onSave: @escaping (SSHTunnel) -> String?) {
        self.onSave = onSave
        self._editedTunnel = State(initialValue: tunnel)
        self._showJumpHost = State(initialValue: !(tunnel.proxyJump ?? "").isEmpty)
        self._showExtraOptions = State(initialValue: !(tunnel.extraOptions ?? "").isEmpty)
        self._showCustomCommand = State(initialValue: !(tunnel.customCommand ?? "").isEmpty)
        self._showControlPath = State(initialValue: !(tunnel.controlPath ?? "").isEmpty)
    }

    private var portConflicts: [(port: Int, names: [String])] {
        tunnelManager.localPortConflicts(for: editedTunnel)
            .sorted { $0.key < $1.key }
            .map { (port: $0.key, names: $0.value) }
    }

    private var canSave: Bool {
        let host = editedTunnel.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !editedTunnel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.isEmpty && !host.hasPrefix("-") && !host.contains(where: \.isWhitespace)
            && (editedTunnel.useAlias || (1...65535).contains(editedTunnel.port))
            && !editedTunnel.portMappings.isEmpty
            && editedTunnel.portMappings.allSatisfy {
                (1...65535).contains($0.localPort)
                    && ($0.forward == .dynamic || (1...65535).contains($0.remotePort))
            }
    }

    var body: some View {
        TunnelProfileEditor(L10n.text("SSH Settings"), subtitle: editedTunnel.name, icon: "terminal",
                            height: 510, preview: canSave ? sshCommand(for: editedTunnel) : nil,
                            canSave: canSave, onSave: { onSave(editedTunnel) }) {
            connectionFields
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Port Forwarding").font(.headline)
                    Spacer()
                    Button {
                        let port = nextLocalPort()
                        editedTunnel.portMappings.append(PortMapping(localPort: port, remotePort: port))
                    } label: {
                        Label("Add Port Mapping", systemImage: "plus")
                    }
                }
                ForEach($editedTunnel.portMappings) { $mapping in
                    PortMappingEditor(
                        mapping: $mapping,
                        focusedField: $focusedField,
                        canRemove: editedTunnel.portMappings.count > 1,
                        onRemove: { removeMapping(mapping.id) }
                    )
                    .tunnelDetailCard()
                }

                ForEach(portConflicts, id: \.port) { conflict in
                    Label(
                        "Local port \(String(conflict.port)) is also used by \(conflict.names.joined(separator: ", ")). Only one tunnel can bind a port at a time.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }
            TunnelHookFields(hooks: $editedTunnel.hooks, supportsRemote: true)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advancedSettings.padding(.top, 8) }
        }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TunnelEditorField("Name") {
                    TextField("Name", text: $editedTunnel.name).focused($focusedField, equals: .name)
                }
                TunnelEditorField("Mode") {
                    Picker("Mode", selection: $editedTunnel.useAlias) {
                        Text("Host").tag(false)
                        Text("SSH Alias").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                .frame(width: 187)
            }
            if editedTunnel.useAlias {
                TunnelEditorField("Alias") {
                    HStack(spacing: 6) {
                        TextField("Alias", text: $editedTunnel.host, prompt: Text("my-server"))
                            .focused($focusedField, equals: .alias)
                        Button { isAliasPickerPresented = true } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .help("Choose an alias from ~/.ssh/config")
                        .popover(isPresented: $isAliasPickerPresented) {
                            SSHConfigAliasPicker(selectedAlias: $editedTunnel.host, isPresented: $isAliasPickerPresented)
                                .environment(\.locale, L10n.locale)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    TunnelEditorField("Host") {
                        TextField("Host", text: $editedTunnel.host, prompt: Text("user@server.com"))
                            .focused($focusedField, equals: .host)
                    }
                    TunnelEditorField("Port") {
                        TextField("SSH Port", value: $editedTunnel.port, format: .number.grouping(.never))
                            .monospacedDigit().focused($focusedField, equals: .port)
                    }
                    .frame(width: 74)
                }
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auto-connect on launch", isOn: $editedTunnel.autoConnect)
            if !editedTunnel.useAlias {
                TunnelEditorField("Identity File (optional)") {
                    TextField("Identity File (optional)", text: Binding(
                        get: { editedTunnel.identityFile ?? "" },
                        set: { editedTunnel.identityFile = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("~/.ssh/id_rsa"))
                    .focused($focusedField, equals: .identityFile)
                }
            }
            DisclosureGroup(isExpanded: $showExtraOptions) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. -o ConnectTimeout=5", text: Binding(
                        get: { editedTunnel.extraOptions ?? "" },
                        set: { editedTunnel.extraOptions = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .extraOptions)
                    .help("Appended to the ssh command as-is, before the host. Split on spaces, so quoted values containing spaces won't survive.")

                    Text("ssh flags the UI doesn't cover, space-separated, e.g. -o ConnectTimeout=5 -o Foo=bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } label: {
                Text("Extra SSH options")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showExtraOptions.toggle() } }
            }

            DisclosureGroup(isExpanded: $showJumpHost) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. bastion.example.com", text: Binding(
                        get: { editedTunnel.proxyJump ?? "" },
                        set: { editedTunnel.proxyJump = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .proxyJump)
                    .help("Adds -J <value>. Reaches the host through one or more bastion hosts, replacing a manual multi-hop ssh.")

                    Text("Optional — routes the login through a bastion to reach the host. Only a login path, not the data flow; -L/-R targets still resolve from the final host. A jump-host-specific key/user goes in ~/.ssh/config. Format: user@host[:port][,user@host2…]")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } label: {
                // Make the whole label row toggle, not just the chevron —
                // DisclosureGroup only wires the triangle up by default on macOS.
                Text("Jump host")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showJumpHost.toggle() } }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection Resilience").font(.headline)
                LabeledContent("Connect Timeout") {
                    HStack(spacing: 4) {
                        TextField("Connect Timeout", text: Binding(
                            get: { editedTunnel.connectTimeout.map(String.init) ?? "" },
                            set: { editedTunnel.connectTimeout = Int($0) }
                        ), prompt: Text("off"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .connectTimeout)
                        .help("Seconds ssh waits to establish the connection before giving up. Blank = wait indefinitely.")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Interval") {
                    HStack(spacing: 4) {
                        TextField("Alive Interval", text: Binding(
                            get: { editedTunnel.serverAliveInterval.map(String.init) ?? "" },
                            set: { editedTunnel.serverAliveInterval = Int($0) }
                        ), prompt: Text("\(SSHTunnel.defaultServerAliveInterval)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .aliveInterval)
                        .help("Seconds between keepalive probes that detect a dead connection. Blank uses the default (\(SSHTunnel.defaultServerAliveInterval)).")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Count Max") {
                    TextField("Alive Count Max", text: Binding(
                        get: { editedTunnel.serverAliveCountMax.map(String.init) ?? "" },
                        set: { editedTunnel.serverAliveCountMax = Int($0) }
                    ), prompt: Text("\(SSHTunnel.defaultServerAliveCountMax)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .focused($focusedField, equals: .aliveCountMax)
                    .help("Drop the connection after this many missed keepalive probes. Blank uses the default (\(SSHTunnel.defaultServerAliveCountMax)).")
                }
                Text("A blank field uses its placeholder default; hover a field for what it does. Connect Timeout is off unless set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tunnelDetailCard()
            Toggle("Compression", isOn: $editedTunnel.compression)
                .help("Compress the data stream (-C). Can help on slow links; costs CPU.")

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Survive brief network drops", isOn: $editedTunnel.disableTCPKeepAlive)
                    .help("Sets TCPKeepAlive=no, so a short outage doesn't tear the connection down at the TCP layer; the Alive Interval probes above handle liveness instead.")
                Text("Keeps the tunnel up through short outages instead of dropping immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Skip host key check", isOn: $editedTunnel.skipHostKeyCheck)
                    .help("Sets StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null.")
                Text("For hosts recreated on the same address. Disables protection against a changed/spoofed host — use only on trusted networks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showControlPath) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. ~/.ssh/master-myhost.sock", text: Binding(
                        get: { editedTunnel.controlPath ?? "" },
                        set: { editedTunnel.controlPath = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .controlPath)
                    .help("Sets -o ControlPath=<value>. The forward attaches to the master connection behind this socket instead of authenticating itself. The app never creates a master; without a live one, connecting fails with a visible reason.")

                    Text("For servers needing an interactive login (password, TOTP, Duo) the app can't answer: log in once in a terminal with  ssh -M -S <this path> -fN <host>  and answer the prompts there. While that master lives, this tunnel connects and auto-reconnects through it with no prompts; when it dies, reconnect it in the terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } label: {
                Text("Reuse existing SSH connection")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showControlPath.toggle() } }
            }

            DisclosureGroup(isExpanded: $showCustomCommand) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. /opt/homebrew/bin/tsh ssh", text: Binding(
                        get: { editedTunnel.customCommand ?? "" },
                        set: { editedTunnel.customCommand = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .customCommand)
                    .help("Replaces /usr/bin/ssh. First word is the executable, the rest lead the arguments. Only -N, the port forwards, Extra SSH options, and the host are passed — identity, port, and the app's OpenSSH -o options are skipped, since a non-OpenSSH client may reject them.")

                    Text("Runs this instead of /usr/bin/ssh — any client that accepts OpenSSH-style -N/-L/-R/-D flags works (Teleport's tsh ssh, cloud CLI ssh wrappers, …). Passes only -N, the forwards, Extra SSH options, and the host — add anything else your command supports to Extra SSH options. Auth prompts can't be answered here, so log in (e.g. tsh login) in a terminal first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } label: {
                Text("Custom SSH command")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showCustomCommand.toggle() } }
            }

        }
    }

    private func removeMapping(_ id: UUID) {
        editedTunnel.portMappings.removeAll { $0.id == id }
    }

    private func nextLocalPort() -> Int {
        let used = Set(editedTunnel.portMappings.map(\.localPort))
        return (8080...65535).first { !used.contains($0) } ?? 8080
    }
}

func sshCommand(for tunnel: SSHTunnel) -> String {
    SSHInvocation(tunnel: tunnel, host: tunnel.host.trimmingCharacters(in: .whitespacesAndNewlines)).shellCommand
}

/// Read-only lookup of the network service that currently holds the default
/// route, used only to fill in the service name in the copy-paste system-proxy
/// commands. Never modifies any setting.
enum NetworkServiceDetector {
    static func activeService() -> String? {
        guard let route = run("/sbin/route", ["-n", "get", "default"]),
              let interfaceLine = route.components(separatedBy: "\n")
                  .first(where: { $0.contains("interface:") }),
              let device = interfaceLine.split(separator: ":").last
                  .map({ $0.trimmingCharacters(in: .whitespaces) }),
              !device.isEmpty,
              let order = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        else { return nil }

        // networksetup pairs a name line "(1) Wi-Fi" with a device line
        // "(Hardware Port: Wi-Fi, Device: en0)" — take the name line above
        // the line matching the default route's device.
        let lines = order.components(separatedBy: "\n")
        for (index, line) in lines.enumerated()
        where index > 0 && line.contains("Device: \(device))") {
            let nameLine = lines[index - 1]
            if let parenEnd = nameLine.range(of: ") ") {
                return String(nameLine[parenEnd.upperBound...])
            }
        }
        // Default route on a non-service interface, e.g. a VPN's utun.
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct SSHConfigAliasPicker: View {
    @Binding var selectedAlias: String
    @Binding var isPresented: Bool
    @State private var aliases: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aliases in ~/.ssh/config")
                    .font(.headline)

                Spacer()

                Button {
                    refreshAliases()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh aliases")
            }

            if aliases.isEmpty {
                Text("No aliases found in ~/.ssh/config")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(aliases, id: \.self) { alias in
                            Button(alias) {
                                selectedAlias = alias
                                isPresented = false
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear(perform: refreshAliases)
    }

    private func refreshAliases() {
        aliases = SSHConfigAliasScanner.aliases()
    }

    private var listHeight: CGFloat {
        min(max(CGFloat(aliases.count) * 30, 30), 240)
    }
}

struct PortMappingEditor: View {
    @Binding var mapping: PortMapping
    @FocusState.Binding var focusedField: SSHTunnelEditor.Field?
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Type", selection: $mapping.forward) {
                Text("Local Forward").tag(ForwardType.local)
                Text("Remote Forward").tag(ForwardType.remote)
                Text("SOCKS Proxy").tag(ForwardType.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .bottom, spacing: 10) {
                switch mapping.forward {
                case .local:
                    localAddress("Mac Listen")
                    arrow
                    remoteAddress("SSH Target")
                case .remote:
                    remoteAddress("SSH Listen")
                    arrow
                    localAddress("Mac Target")
                case .dynamic:
                    localAddress("SOCKS Listen")
                }
            }

            if mapping.forward == .remote {
                Text("Reverse of a local forward: the server listens on the Remote address and sends connections back to the Local port on this Mac. Set the Remote host to 0.0.0.0 (and enable GatewayPorts on the server) to accept connections from beyond the server itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if canRemove {
                Button("Remove", role: .destructive, action: onRemove)
                    .font(.caption)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.caption.weight(.medium))
            .foregroundStyle(.secondary).frame(height: 22).accessibilityHidden(true)
    }

    private func localAddress(_ title: LocalizedStringKey) -> some View {
        address(title, host: $mapping.localHost, port: $mapping.localPort,
                hostField: .mappingLocalHost(mapping.id), portField: .mappingLocalPort(mapping.id))
    }

    private func remoteAddress(_ title: LocalizedStringKey) -> some View {
        address(title, host: $mapping.remoteHost, port: $mapping.remotePort,
                hostField: .mappingRemoteHost(mapping.id), portField: .mappingRemotePort(mapping.id))
    }

    private func address(_ title: LocalizedStringKey, host: Binding<String>, port: Binding<Int>,
                         hostField: SSHTunnelEditor.Field, portField: SSHTunnelEditor.Field) -> some View {
        TunnelEditorField(title) {
            HStack(spacing: 5) {
                TextField("Host", text: host).focused($focusedField, equals: hostField)
                TextField("Port", value: port, format: .number.grouping(.never))
                    .monospacedDigit().frame(width: 60).focused($focusedField, equals: portField)
            }
        }
    }
}

struct UsageRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
            .help("Copy to clipboard")
        }
    }
}
