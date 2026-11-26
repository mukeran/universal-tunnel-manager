import Foundation
import Observation

@Observable
@MainActor
final class TunnelManager {
    private(set) var settings = SavedSettings()
    private(set) var devices: [Device] = []
    private(set) var discoveryErrors: [Platform: String] = [:]
    private(set) var states: [UUID: TunnelState] = [:]
    private(set) var persistenceError: String?
    private(set) var isRefreshing = false

    private let settingsURL: URL
    private var maySave = true
    private var proxies: [UUID: ToolProcess] = [:]
    private var androidOwners: [UUID: Device] = [:]
    private var iosWiFiPresence = IOSWiFiPresence()
    private var retryAfter: [UUID: ContinuousClock.Instant] = [:]
    private var monitor: Task<Void, Never>?
    private var shuttingDown = false

    init(settingsURL: URL? = nil) {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("MobileTunnelManager", isDirectory: true)
        self.settingsURL = settingsURL ?? directory.appendingPathComponent("tunnels.json")
        do {
            let stored = try Data(contentsOf: self.settingsURL)
            settings = try JSONDecoder().decode(SavedSettings.self, from: stored)
            if !settings.restoreOnLaunch { settings.enabled = [] }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        } catch {
            maySave = false
            persistenceError = "无法读取已保存的配置，已保留原文件。\(error.localizedDescription)"
        }
    }

    var offlineDevices: [Device] {
        var listed = Set(devices.map(\.id))
        var result: [Device] = []
        for tunnel in settings.tunnels where listed.insert(tunnel.device).inserted {
            let connection = tunnel.device.isAndroidEndpoint ? "旧版 ADB 地址" : "未连接"
            result.append(Device(id: tunnel.device, name: tunnel.deviceName, connection: connection, ready: false))
        }
        return result
    }

    var listedDevices: [Device] { devices + offlineDevices }

    func tunnels(for device: DeviceID) -> [Tunnel] {
        settings.tunnels.filter { $0.device == device }
    }

    func displayName(for device: Device) -> String {
        if listedDevices.contains(where: { $0.id != device.id && $0.name == device.name }) {
            return "\(device.name) · \(device.id.serial.suffix(6))"
        }
        return device.name
    }

    func state(for tunnel: Tunnel) -> TunnelState { states[tunnel.id] ?? .stopped }
    func enabled(_ tunnel: Tunnel) -> Bool { settings.enabled.contains(tunnel.id) }

    func canEdit(_ tunnel: Tunnel) -> Bool {
        !enabled(tunnel) && proxies[tunnel.id] == nil && androidOwners[tunnel.id] == nil
            && !isChanging(tunnel)
    }

    private func isChanging(_ tunnel: Tunnel) -> Bool {
        switch state(for: tunnel) {
        case .starting, .stopping: true
        default: false
        }
    }

    func addOrUpdate(_ tunnel: Tunnel) {
        guard tunnel.valid else { return }
        if let index = settings.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            guard settings.tunnels[index].device == tunnel.device, canEdit(tunnel) else { return }
            settings.tunnels[index] = tunnel
        } else {
            guard !tunnel.device.isAndroidEndpoint else { return }
            settings.tunnels.append(tunnel)
        }
        save()
    }

    func delete(_ tunnel: Tunnel) {
        guard canEdit(tunnel) else { return }
        settings.tunnels.removeAll { $0.id == tunnel.id }
        states.removeValue(forKey: tunnel.id)
        retryAfter.removeValue(forKey: tunnel.id)
        save()
    }

    func toggle(_ tunnel: Tunnel) {
        guard !shuttingDown, settings.tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        if enabled(tunnel) {
            settings.enabled.remove(tunnel.id)
            states[tunnel.id] = .stopping
        } else {
            settings.enabled.insert(tunnel.id)
            states[tunnel.id] = .starting
        }
        retryAfter.removeValue(forKey: tunnel.id)
        save()
        checkNow()
    }

    func setRestoreOnLaunch(_ value: Bool) {
        settings.restoreOnLaunch = value
        save()
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func checkNow() {
        Task { await refresh() }
    }

    func retry(_ tunnel: Tunnel) {
        retryAfter.removeValue(forKey: tunnel.id)
        checkNow()
    }

    func refresh() async {
        guard !isRefreshing, !shuttingDown else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let tools = DeviceTools()
        let known = devices
        async let android = Self.discover { try await tools.androidDevices(known: known) }
        async let ios = Self.discover { try await tools.iosDevices(known: known) }
        let discoveries = await [(Platform.android, android), (Platform.ios, ios)]
        var detectedDevices: [Device] = []
        for (platform, discovery) in discoveries {
            switch discovery {
            case .success(let detected):
                discoveryErrors.removeValue(forKey: platform)
                detectedDevices.append(contentsOf: detected)
            case .failure(let error):
                discoveryErrors[platform] = error.localizedDescription
            }
        }
        let detectedIOS = detectedDevices.filter { $0.id.platform == .ios }
        let missingWiFi = iosWiFiPresence.temporarilyMissing(from: detectedIOS, at: .now)
        let missingWiFiIDs = Set(missingWiFi.map(\.id))
        devices = detectedDevices.filter { $0.id.platform == .android }
            + (detectedIOS + missingWiFi).sorted { $0.id.serial < $1.id.serial }

        for tunnel in settings.tunnels {
            guard !shuttingDown else { return }
            if !enabled(tunnel) {
                await stop(tunnel, tools: tools)
                continue
            }
            guard tunnel.valid else {
                states[tunnel.id] = .failed("配置中的端口或转发方向无效。")
                continue
            }
            if tunnel.device.isAndroidEndpoint {
                states[tunnel.id] = .waiting("旧规则只保存了 ADB 地址。请在确认身份的设备下重新添加这条规则。")
                continue
            }
            if missingWiFiIDs.contains(tunnel.device) {
                if proxies[tunnel.id]?.isRunning == true {
                    states[tunnel.id] = .active
                } else {
                    proxies.removeValue(forKey: tunnel.id)
                    retryAfter.removeValue(forKey: tunnel.id)
                    states[tunnel.id] = .waiting("正在确认 Wi-Fi 连接，设备恢复后会启动转发。")
                }
                continue
            }
            guard let device = devices.first(where: { $0.id == tunnel.device }), device.ready else {
                proxies.removeValue(forKey: tunnel.id)?.terminate()
                states[tunnel.id] = .waiting(discoveryErrors[tunnel.device.platform]
                    ?? devices.first(where: { $0.id == tunnel.device })?.connection
                    ?? "设备重新接入后会恢复转发。")
                retryAfter.removeValue(forKey: tunnel.id)
                continue
            }
            if let next = retryAfter[tunnel.id], ContinuousClock.now < next { continue }
            do {
                if tunnel.device.platform == .ios {
                    try await ensureProxy(tunnel, tools: tools)
                } else {
                    try await ensureAndroid(tunnel, on: device, tools: tools)
                }
                if enabled(tunnel) {
                    states[tunnel.id] = .active
                } else {
                    await stop(tunnel, tools: tools)
                }
            } catch {
                if enabled(tunnel) {
                    if let conflict = error as? PortConflict {
                        states[tunnel.id] = .conflict(conflict.message)
                    } else {
                        states[tunnel.id] = .failed(error.localizedDescription)
                    }
                    retryAfter[tunnel.id] = .now.advanced(by: .seconds(5))
                }
            }
        }
    }

    private static func discover(_ action: () async throws -> [Device]) async -> Result<[Device], Error> {
        do { return .success(try await action()) }
        catch { return .failure(error) }
    }

    private func ensureProxy(_ tunnel: Tunnel, tools: DeviceTools) async throws {
        if let proxy = proxies[tunnel.id], proxy.isRunning { return }
        if let exited = proxies.removeValue(forKey: tunnel.id) {
            let message = exited.diagnostics()
            throw CommandError(message: message.isEmpty ? "iproxy 已退出，将自动重试。" : message)
        }
        try MacListener.checkAvailability(port: tunnel.macPort)
        let proxy = try tools.startProxy(tunnel)
        proxies[tunnel.id] = proxy
        try? await Task.sleep(for: .milliseconds(200))
        if !proxy.isRunning {
            proxies.removeValue(forKey: tunnel.id)
            let message = proxy.diagnostics()
            throw CommandError(message: message.isEmpty ? "iproxy 启动失败，请检查 Mac 端口是否被占用。" : message)
        }
    }

    private func androidRules(_ tunnel: Tunnel, _ device: Device, _ tools: DeviceTools) async throws -> [DevicePort] {
        let target = tunnel.direction == .forward ? [] : device.adbTarget
        return DevicePort.parse(try await tools.android(target + [tunnel.direction.command, "--list"]))
    }

    private func matches(_ rule: DevicePort, _ tunnel: Tunnel, _ device: Device) -> Bool {
        rule.listener == tunnel.listener && rule.destination == tunnel.destination
            && (tunnel.direction == .reverse || rule.owner == device.adbAddress)
    }

    private func ensureAndroid(_ tunnel: Tunnel, on device: Device, tools: DeviceTools) async throws {
        let rules = try await androidRules(tunnel, device, tools)
        if let owner = androidOwners[tunnel.id], owner.usesSameADBConnection(as: device),
           rules.contains(where: { matches($0, tunnel, device) }) { return }

        androidOwners.removeValue(forKey: tunnel.id)
        guard !rules.contains(where: { $0.listener == tunnel.listener }) else {
            let side = tunnel.direction == .forward ? "Mac" : "设备"
            throw PortConflict(message: "\(side) 的 \(tunnel.listener) 已被另一条 ADB 规则占用。")
        }
        guard enabled(tunnel), !shuttingDown else { return }
        if tunnel.direction == .forward {
            try MacListener.checkAvailability(port: tunnel.macPort)
        }
        _ = try await tools.android(device.adbTarget + [
            tunnel.direction.command, "--no-rebind", tunnel.listener, tunnel.destination
        ])
        androidOwners[tunnel.id] = device
    }

    private func stop(_ tunnel: Tunnel, tools: DeviceTools) async {
        if let proxy = proxies.removeValue(forKey: tunnel.id) { proxy.terminate() }
        guard let owner = androidOwners[tunnel.id] else {
            states[tunnel.id] = .stopped
            return
        }
        let device = devices.first { $0.id == owner.id && $0.ready }
        if let device, !owner.usesSameADBConnection(as: device) {
            androidOwners.removeValue(forKey: tunnel.id)
            states[tunnel.id] = .stopped
            return
        }
        if tunnel.direction == .reverse && device == nil {
            states[tunnel.id] = .waiting("设备离线，重新接入后会核对并停止这条转发。")
            return
        }
        do {
            let rules = try await androidRules(tunnel, owner, tools)
            if rules.contains(where: { matches($0, tunnel, owner) }) {
                guard let device else {
                    states[tunnel.id] = .waiting("设备离线，重新接入后会核对并停止这条转发。")
                    return
                }
                _ = try await tools.android(device.adbTarget + [tunnel.direction.command, "--remove", tunnel.listener])
            }
            androidOwners.removeValue(forKey: tunnel.id)
            states[tunnel.id] = .stopped
        } catch {
            states[tunnel.id] = .failed(error.localizedDescription)
        }
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        monitor?.cancel()
        while isRefreshing { try? await Task.sleep(for: .milliseconds(50)) }
        let tools = DeviceTools()
        for tunnel in settings.tunnels where proxies[tunnel.id] != nil || androidOwners[tunnel.id] != nil {
            await stop(tunnel, tools: tools)
        }
        return settings.tunnels.filter { androidOwners[$0.id] != nil }.map(\.name)
    }

    private func save() {
        guard maySave else { return }
        do {
            let directory = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "无法保存转发配置。\(error.localizedDescription)"
        }
    }
}
