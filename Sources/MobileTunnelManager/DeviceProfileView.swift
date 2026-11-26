import SwiftUI
import TunnelUI

struct DeviceProfileDetail: View {
    let manager: DeviceTunnelManager
    let tunnel: DeviceTunnel

    var body: some View {
        let device = manager.listedDevices.first { $0.id == tunnel.device }
            ?? Device(id: tunnel.device, name: tunnel.deviceName, connection: L10n.text("Disconnected"), ready: false)
        let isForward = tunnel.direction == .forward
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TunnelDetailSection("Port Forwarding") {
                    VStack(alignment: .leading, spacing: 8) {
                        TunnelRoute(isForward ? "Mac :\(tunnel.macPort)" : L10n.text("Device :\(String(tunnel.devicePort))"),
                                    to: isForward ? L10n.text("Device :\(String(tunnel.devicePort))") : "Mac :\(tunnel.macPort)")
                        if case .conflict = manager.state(for: tunnel), isForward {
                            MacPortOwnersButton(port: tunnel.macPort) { manager.retry(tunnel) }
                        }
                    }
                }
                TunnelDetailSection("Device") {
                    DeviceInfoButton(device: device)
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Connection", value: device.connectionSummary)
                        Divider()
                        LabeledContent(device.id.label) {
                            Text(device.id.serial)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(TunnelDetailLayout.insets)
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var device: Device? = nil
    var tunnel: DeviceTunnel? = nil
}

struct TunnelEditor: View {
    let request: EditorRequest
    let manager: DeviceTunnelManager
    let onSave: (DeviceTunnel) -> String?
    @State private var selectedDevice: Device?
    @State private var name: String
    @State private var direction: Direction
    @State private var macPort: String
    @State private var devicePort: String
    @State private var hooks: TunnelHooks?
    @State private var macPortWarning: (port: Int, error: Error)?

    init(request: EditorRequest, manager: DeviceTunnelManager, onSave: @escaping (DeviceTunnel) -> String?) {
        self.request = request
        self.manager = manager
        self.onSave = onSave
        _selectedDevice = State(initialValue: request.device)
        _name = State(initialValue: request.tunnel?.name ?? "")
        _direction = State(initialValue: request.tunnel?.direction ?? .forward)
        _macPort = State(initialValue: request.tunnel.map { String($0.macPort) } ?? "")
        _devicePort = State(initialValue: request.tunnel.map { String($0.devicePort) } ?? "")
        _hooks = State(initialValue: request.tunnel?.hooks)
    }

    private var choices: [Device] {
        let available = manager.listedDevices.filter { !$0.id.isAndroidEndpoint }
        if let selectedDevice, !available.contains(where: { $0.id == selectedDevice.id }) {
            return available + [currentDevice ?? selectedDevice]
        }
        return available
    }

    private var currentDevice: Device? {
        guard let selectedDevice else { return nil }
        return manager.listedDevices.first { $0.id == selectedDevice.id }
            ?? Device(id: selectedDevice.id, name: selectedDevice.name, connection: L10n.text("Disconnected"), ready: false)
    }

    var body: some View {
        TunnelProfileEditor(request.tunnel == nil ? L10n.text("Add Device Forward") : L10n.text("Edit Device Forward"),
                            subtitle: currentDevice?.name ?? L10n.text("iOS or Android"),
                            icon: currentDevice?.id.platform.icon ?? "iphone",
                            width: 440, height: 450, footerNote: "TCP port range: 1–65535", canSave: tunnel != nil, onSave: {
            guard let tunnel else { return L10n.text("Select a device and enter valid ports.") }
            return onSave(tunnel)
        }) {
            if request.tunnel == nil {
                TunnelEditorField("Device") {
                    HStack(spacing: 8) {
                        Picker("Device", selection: Binding(get: { selectedDevice?.id }, set: { id in
                            selectedDevice = choices.first { $0.id == id }
                            if selectedDevice?.id.platform != .android { direction = .forward }
                        })) {
                            Text("Select a Device").tag(nil as DeviceID?)
                            ForEach(choices) { device in
                                Text("\(manager.displayName(for: device)) · \(device.connectionSummary) · \(device.id.abbreviated)")
                                    .tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        DeviceInfoButton(device: currentDevice)
                        Button(action: manager.checkNow) {
                            Label("Refresh Devices", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                        }
                        .disabled(manager.isRefreshing)
                        .help("Refresh Devices")
                    }
                }
                if choices.isEmpty {
                    Text("Connect and authorize a device to select it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let device = currentDevice {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(device.id.platform.title) · \(device.connectionSummary)")
                        Text("\(device.id.label)  \(device.id.serial)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if request.tunnel != nil { DeviceInfoButton(device: device) }
                }
            }
            TunnelEditorField("Name") {
                TextField("Name", text: $name, prompt: Text("Optional"))
                    .accessibilityLabel("Name")
            }
            if selectedDevice?.id.platform == .android {
                Picker("Forwarding Direction", selection: $direction) {
                    ForEach(Direction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(alignment: .bottom, spacing: 10) {
                if direction == .forward {
                    portField("Mac Listen Port", value: $macPort)
                    routeArrow
                    portField("Device Target Port", value: $devicePort)
                } else {
                    portField("Device Listen Port", value: $devicePort)
                    routeArrow
                    portField("Mac Target Port", value: $macPort)
                }
            }
            TunnelHookFields(hooks: $hooks)
            if let macPortWarning {
                Label(macPortWarning.error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if macPortWarning.error is PortConflict {
                    MacPortOwnersButton(port: macPortWarning.port) { checkMacPort(macPortWarning.port) }
                }
            }
        }
        .task(id: direction == .forward && selectedDevice != nil ? macPort : "") {
            macPortWarning = nil
            guard direction == .forward, selectedDevice != nil,
                  let port = Int(macPort.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(port) else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            checkMacPort(port)
        }
    }

    private var routeArrow: some View {
        Image(systemName: "arrow.right").font(.callout.weight(.medium))
            .foregroundStyle(.secondary).frame(height: 22).accessibilityHidden(true)
    }

    private func portField(_ title: LocalizedStringKey, value: Binding<String>) -> some View {
        TunnelEditorField(title) {
            TextField(title, text: value, prompt: Text("8100")).monospacedDigit()
                .accessibilityLabel(Text(title))
        }
    }

    private func checkMacPort(_ port: Int) {
        do {
            try MacListener.checkAvailability(port: port)
            macPortWarning = nil
        } catch {
            macPortWarning = (port, error)
        }
    }

    private var tunnel: DeviceTunnel? {
        guard let selectedDevice, let mac = Int(macPort.trimmingCharacters(in: .whitespaces)),
              let target = Int(devicePort.trimmingCharacters(in: .whitespaces)) else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnel = DeviceTunnel(id: request.tunnel?.id ?? request.id,
                            name: title.isEmpty ? "\(selectedDevice.name) · \(mac) / \(target)" : title,
                            device: selectedDevice.id, deviceName: selectedDevice.name,
                            direction: direction, macPort: mac, devicePort: target, hooks: hooks)
        return tunnel.valid ? tunnel : nil
    }
}
