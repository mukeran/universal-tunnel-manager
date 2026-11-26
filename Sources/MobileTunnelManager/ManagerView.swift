import SwiftUI

struct ManagerView: View {
    let manager: TunnelManager
    @State private var selection: DeviceID?
    @State private var editor: EditorRequest?
    @State private var pendingDelete: Tunnel?
    @State private var showSettings = false
    @State private var showDeviceInfo = false

    private var device: Device? { manager.listedDevices.first { $0.id == selection } }
    private var dividerColor: Color { Color(nsColor: .separatorColor).opacity(0.55) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("当前设备") {
                    ForEach(manager.devices) { device in
                        deviceRow(device)
                    }
                    if manager.devices.isEmpty && manager.discoveryErrors.isEmpty {
                        Text("无设备").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Platform.allCases, id: \.self) { platform in
                        if let error = manager.discoveryErrors[platform] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if !manager.offlineDevices.isEmpty {
                    Section("离线配置") {
                        ForEach(manager.offlineDevices) { device in
                            deviceRow(device)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { showSettings.toggle() } label: {
                        Label("偏好设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showSettings, arrowEdge: .top) {
                        PreferencesView(manager: manager)
                    }
                    Spacer(minLength: 0)
                    Button(action: manager.checkNow) {
                        Label("刷新设备", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("刷新设备")
                    .keyboardShortcut("r")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.bar)
                .overlay(alignment: .top) { Rectangle().fill(dividerColor).frame(height: 1) }
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = manager.persistenceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12))
                }
                if let device {
                    deviceDetail(device).id(device.id)
                } else {
                    ContentUnavailableView("选择一台设备", systemImage: "iphone",
                                           description: Text("连接 iPhone、iPad 或已开启调试的 Android 设备。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: DeviceSelection(devices: manager.listedDevices), initial: true) { before, after in
            selection = after.selected(selection, after: before)
        }
        .sheet(item: $editor) { request in
            TunnelEditor(request: request, onSave: manager.addOrUpdate)
        }
        .alert("删除转发规则？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { tunnel in
            Button("删除", role: .destructive) { manager.delete(tunnel) }
            Button("取消", role: .cancel) {}
        } message: { tunnel in
            Text(tunnel.name)
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.displayName(for: device))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(device.id.platform.title) · \(device.connection)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: device.id.platform.icon)
                .foregroundStyle(.secondary)
                .frame(width: 19)
        }
        .tag(device.id)
        .padding(.vertical, 5)
    }

    private func deviceDetail(_ device: Device) -> some View {
        let tunnels = manager.tunnels(for: device.id)
        return VStack(alignment: .leading, spacing: 0) {
            deviceHeader(device)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)

            Rectangle().fill(dividerColor).frame(height: 1)
                .padding(.horizontal, 24)

            HStack {
                Text("转发规则").font(.headline)
                Spacer()
                Button {
                    editor = EditorRequest(device: device)
                } label: {
                    Label("添加转发", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(device.id.isAndroidEndpoint)
                .keyboardShortcut("n")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if device.id.isAndroidEndpoint {
                Text(device.adbSerial == nil
                     ? "这组旧规则只记录了 ADB 地址。请在确认身份的设备下重新添加。"
                     : "确认设备身份后可添加转发。请检查设备授权和连接状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            if tunnels.isEmpty {
                ContentUnavailableView("还没有转发规则", systemImage: "arrow.left.arrow.right",
                                       description: Text("添加规则，设置 Mac 和设备的 TCP 端口。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tunnels) { tunnel in
                            tunnelRow(tunnel, device: device)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 1)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func deviceHeader(_ device: Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.id.platform.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.displayName(for: device))
                    .font(.system(size: 25, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(device.id.platform.title)
                    Circle().frame(width: 3, height: 3).accessibilityHidden(true)
                    Text(device.connection)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showDeviceInfo.toggle()
            } label: {
                Label("设备标识", systemImage: "info.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("查看设备标识")
            .popover(isPresented: $showDeviceInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.id.platform == .ios ? "UDID" : "设备标识").font(.headline)
                    Text(device.id.serial)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(14)
                .fixedSize()
            }
        }
    }

    private func tunnelRow(_ tunnel: Tunnel, device: Device) -> some View {
        let state = manager.state(for: tunnel)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(tunnel.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .help(tunnel.name)
                Spacer(minLength: 6)
                Text(state.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(state.statusColor.opacity(0.11), in: Capsule())
                    .fixedSize()
                Toggle("启用 \(tunnel.name)", isOn: Binding(
                    get: { manager.enabled(tunnel) },
                    set: { _ in manager.toggle(tunnel) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Menu {
                    Button("编辑") { editor = EditorRequest(device: device, tunnel: tunnel) }
                        .disabled(!manager.canEdit(tunnel))
                    Button("删除", role: .destructive) { pendingDelete = tunnel }
                        .disabled(!manager.canEdit(tunnel))
                } label: {
                    Label("转发操作", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            portRoute(tunnel)
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if case .conflict = state, tunnel.direction == .forward {
                MacPortOwnersButton(port: tunnel.macPort) { manager.retry(tunnel) }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(dividerColor) }
    }

    private func portRoute(_ tunnel: Tunnel) -> some View {
        let isForward = tunnel.direction == .forward
        return HStack(spacing: 7) {
            endpoint(isForward ? "Mac" : "设备", port: isForward ? tunnel.macPort : tunnel.devicePort)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            endpoint(isForward ? "设备" : "Mac", port: isForward ? tunnel.devicePort : tunnel.macPort)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tunnel.route)
    }

    private func endpoint(_ title: String, port: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: ":\(port)").monospacedDigit().textSelection(.enabled)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }

}

private struct EditorRequest: Identifiable {
    let id = UUID()
    let device: Device
    var tunnel: Tunnel? = nil
}

private struct TunnelEditor: View {
    let request: EditorRequest
    let onSave: (Tunnel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var direction: Direction
    @State private var macPort: String
    @State private var devicePort: String
    @State private var macPortWarning: (port: Int, error: Error)?

    init(request: EditorRequest, onSave: @escaping (Tunnel) -> Void) {
        self.request = request
        self.onSave = onSave
        _name = State(initialValue: request.tunnel?.name ?? "")
        _direction = State(initialValue: request.tunnel?.direction ?? .forward)
        _macPort = State(initialValue: request.tunnel.map { String($0.macPort) } ?? "")
        _devicePort = State(initialValue: request.tunnel.map { String($0.devicePort) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.tunnel == nil ? "添加转发" : "编辑转发")
                    .font(.title2.weight(.semibold))
                Label(request.device.name, systemImage: request.device.id.platform.icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.callout.weight(.medium)).accessibilityHidden(true)
                TextField("名称", text: $name, prompt: Text("可选"))
                    .labelsHidden()
                    .accessibilityLabel("名称")
            }
            if request.device.id.platform == .android {
                Picker("转发方向", selection: $direction) {
                    ForEach(Direction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if direction == .forward {
                    portField("Mac 监听端口", value: $macPort)
                    routeArrow
                    portField("设备目标端口", value: $devicePort)
                } else {
                    portField("设备监听端口", value: $devicePort)
                    routeArrow
                    portField("Mac 目标端口", value: $macPort)
                }
            }
            if let macPortWarning {
                Label(macPortWarning.error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if macPortWarning.error is PortConflict {
                    MacPortOwnersButton(port: macPortWarning.port) { checkMacPort(macPortWarning.port) }
                }
            }
            Divider()
            HStack {
                Text("TCP 端口范围 1–65535")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let tunnel { onSave(tunnel) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(tunnel == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .task(id: direction == .forward ? macPort : "") {
            macPortWarning = nil
            guard direction == .forward,
                  let port = Int(macPort.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(port) else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            checkMacPort(port)
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

    private var routeArrow: some View {
        Image(systemName: "arrow.right")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .accessibilityHidden(true)
    }

    private func portField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium)).accessibilityHidden(true)
            TextField(title, text: value, prompt: Text("8100"))
                .labelsHidden()
                .accessibilityLabel(title)
                .monospacedDigit()
        }
    }

    private var tunnel: Tunnel? {
        guard let mac = Int(macPort.trimmingCharacters(in: .whitespaces)),
              let target = Int(devicePort.trimmingCharacters(in: .whitespaces)) else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnel = Tunnel(id: request.tunnel?.id ?? UUID(),
                            name: title.isEmpty ? "\(request.device.name) · \(mac) / \(target)" : title,
                            device: request.device.id, deviceName: request.device.name,
                            direction: direction, macPort: mac, devicePort: target)
        return tunnel.valid ? tunnel : nil
    }
}
