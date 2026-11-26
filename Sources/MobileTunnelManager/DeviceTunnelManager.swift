import Foundation
import Observation

@Observable
@MainActor
final class DeviceTunnelManager {
    var tunnels: [DeviceTunnel] { store.deviceTunnels }
    private(set) var devices: [Device] = []
    private(set) var discoveryErrors: [Platform: String] = [:]
    private(set) var states: [UUID: TunnelState] = [:]
    private(set) var isRefreshing = false

    private let store: TunnelStore
    private var enabledIDs: Set<UUID> = []
    private var establishedIDs: Set<UUID> = []
    private var preparedIDs: Set<UUID> = []
    private var beforeConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var afterConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var afterDisconnectTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var hookErrors: [UUID: String] = [:]
    private var proxies: [UUID: ToolProcess] = [:]
    private var androidOwners: [UUID: Device] = [:]
    private var iosWiFiPresence = IOSWiFiPresence()
    private var retryAfter: [UUID: ContinuousClock.Instant] = [:]
    private var monitor: Task<Void, Never>?
    private var shuttingDown = false

    init(store: TunnelStore) {
        self.store = store
    }

    var offlineDevices: [Device] {
        var listed = Set(devices.map(\.id))
        var result: [Device] = []
        for tunnel in tunnels where listed.insert(tunnel.device).inserted {
            let connection = tunnel.device.isAndroidEndpoint ? L10n.text("Legacy ADB Address") : L10n.text("Disconnected")
            result.append(Device(id: tunnel.device, name: tunnel.deviceName, connection: connection, ready: false))
        }
        return result
    }

    var listedDevices: [Device] { devices + offlineDevices }

    func tunnels(for device: DeviceID) -> [DeviceTunnel] {
        tunnels.filter { $0.device == device }
    }

    func displayName(for device: Device) -> String {
        if listedDevices.contains(where: { $0.id != device.id && $0.name == device.name }) {
            return "\(device.name) · \(device.id.serial.suffix(6))"
        }
        return device.name
    }

    func state(for tunnel: DeviceTunnel) -> TunnelState { states[tunnel.id] ?? .stopped }
    func enabled(_ tunnel: DeviceTunnel) -> Bool { enabledIDs.contains(tunnel.id) }

    private func setState(_ state: TunnelState, for tunnel: DeviceTunnel) {
        states[tunnel.id] = state
        let event: TunnelFeedback.Event
        switch state {
        case .starting, .stopping:
            return
        case .active:
            guard establishedIDs.insert(tunnel.id).inserted else { return }
            event = .connected
            hookErrors.removeValue(forKey: tunnel.id)
            if !shuttingDown, tunnel.hooks?.local?.command(.afterConnect) != nil {
                afterConnectTasks[tunnel.id] = Task {
                    defer { afterConnectTasks.removeValue(forKey: tunnel.id) }
                    do { try await TunnelHookRunner.run(tunnel.hooks, phase: .afterConnect) }
                    catch {
                        if !Task.isCancelled { hookErrors[tunnel.id] = error.localizedDescription }
                    }
                }
            }
        default:
            guard establishedIDs.remove(tunnel.id) != nil else { return }
            event = .disconnected(retrying: enabled(tunnel))
            let connect = afterConnectTasks[tunnel.id]
            connect?.cancel()
            if connect != nil || tunnel.hooks?.local?.command(.afterDisconnect) != nil {
                afterDisconnectTasks[tunnel.id] = Task {
                    defer { afterDisconnectTasks.removeValue(forKey: tunnel.id) }
                    await connect?.value
                    do { try await TunnelHookRunner.run(tunnel.hooks, phase: .afterDisconnect) }
                    catch { hookErrors[tunnel.id] = error.localizedDescription }
                }
            }
        }
        if !shuttingDown { TunnelFeedback.announce(event, name: tunnel.name, using: store) }
    }

    func canEdit(_ tunnel: DeviceTunnel) -> Bool {
        !enabled(tunnel) && proxies[tunnel.id] == nil && androidOwners[tunnel.id] == nil
            && !isChanging(tunnel) && beforeConnectTasks[tunnel.id] == nil && afterDisconnectTasks[tunnel.id] == nil
    }

    private func isChanging(_ tunnel: DeviceTunnel) -> Bool {
        switch state(for: tunnel) {
        case .starting, .stopping: true
        default: false
        }
    }

    func addOrUpdate(_ tunnel: DeviceTunnel, in groupID: UUID? = nil, after previous: TunnelRule.Key? = nil) -> Bool {
        guard store.canEdit, tunnel.valid else { return false }
        if let original = tunnels.first(where: { $0.id == tunnel.id }) {
            guard original.device == tunnel.device, canEdit(tunnel) else { return false }
        } else {
            guard !tunnel.device.isAndroidEndpoint else { return false }
        }
        return store.save(.device(tunnel, enabled: enabled(tunnel)), in: groupID, after: previous)
    }

    func delete(_ tunnel: DeviceTunnel) {
        guard store.canEdit, canEdit(tunnel), store.delete(TunnelRule.device(tunnel, enabled: false).key) else { return }
        states.removeValue(forKey: tunnel.id)
        hookErrors.removeValue(forKey: tunnel.id)
        retryAfter.removeValue(forKey: tunnel.id)
    }

    func setEnabled(_ enabled: Bool, for tunnel: DeviceTunnel) {
        guard !shuttingDown, self.enabled(tunnel) != enabled,
              tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        if enabled {
            hookErrors.removeValue(forKey: tunnel.id)
            enabledIDs.insert(tunnel.id)
            setState(.starting, for: tunnel)
        } else {
            enabledIDs.remove(tunnel.id)
            preparedIDs.remove(tunnel.id)
            beforeConnectTasks[tunnel.id]?.cancel()
            setState(.stopping, for: tunnel)
        }
        retryAfter.removeValue(forKey: tunnel.id)
        checkNow()
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

    func retry(_ tunnel: DeviceTunnel) {
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

        for tunnel in tunnels {
            guard !shuttingDown else { return }
            if !enabled(tunnel) {
                await stop(tunnel, tools: tools)
                continue
            }
            guard tunnel.valid else {
                setState(.failed(L10n.text("The configured ports or forwarding direction are invalid.")), for: tunnel)
                continue
            }
            if tunnel.device.isAndroidEndpoint {
                setState(.waiting(L10n.text("This legacy rule only contains an ADB address. Add the rule again for a verified device.")), for: tunnel)
                continue
            }
            if missingWiFiIDs.contains(tunnel.device) {
                if proxies[tunnel.id]?.isRunning == true {
                    setState(.active, for: tunnel)
                } else {
                    proxies.removeValue(forKey: tunnel.id)
                    retryAfter.removeValue(forKey: tunnel.id)
                    setState(.waiting(L10n.text("Checking the Wi-Fi connection. Forwarding will start when the device is available.")), for: tunnel)
                }
                continue
            }
            guard let device = devices.first(where: { $0.id == tunnel.device }), device.ready else {
                proxies.removeValue(forKey: tunnel.id)?.terminate()
                setState(.waiting(discoveryErrors[tunnel.device.platform]
                    ?? devices.first(where: { $0.id == tunnel.device })?.connection
                    ?? L10n.text("Forwarding will resume when the device reconnects.")), for: tunnel)
                retryAfter.removeValue(forKey: tunnel.id)
                continue
            }
            if let next = retryAfter[tunnel.id], ContinuousClock.now < next { continue }
            guard beforeConnectTasks[tunnel.id] == nil, afterDisconnectTasks[tunnel.id] == nil else { continue }
            if !establishedIDs.contains(tunnel.id), tunnel.hooks?.local?.command(.beforeConnect) != nil,
               preparedIDs.remove(tunnel.id) == nil {
                prepare(tunnel)
                continue
            }
            do {
                if tunnel.device.platform == .ios {
                    try await ensureProxy(tunnel, tools: tools)
                } else {
                    guard try await ensureAndroid(tunnel, on: device, tools: tools) else { continue }
                }
                if enabled(tunnel) {
                    setState(.active, for: tunnel)
                } else {
                    await stop(tunnel, tools: tools)
                }
            } catch {
                if enabled(tunnel) {
                    if let conflict = error as? PortConflict {
                        setState(.conflict(conflict.message), for: tunnel)
                    } else {
                        setState(.failed(error.localizedDescription), for: tunnel)
                    }
                    retryAfter[tunnel.id] = .now.advanced(by: .seconds(5))
                }
            }
        }
    }

    private func prepare(_ tunnel: DeviceTunnel) {
        let id = tunnel.id
        setState(.starting, for: tunnel)
        beforeConnectTasks[id] = Task {
            defer {
                beforeConnectTasks.removeValue(forKey: id)
                if !shuttingDown { checkNow() }
            }
            do {
                try await TunnelHookRunner.run(tunnel.hooks, phase: .beforeConnect)
                if !shuttingDown && enabled(tunnel) && !Task.isCancelled { preparedIDs.insert(id) }
            } catch {
                guard !Task.isCancelled, !shuttingDown, enabled(tunnel) else { return }
                hookErrors[id] = error.localizedDescription
                enabledIDs.remove(id)
                store.forgetEnabledProfile(TunnelRule.device(tunnel, enabled: false).key)
            }
        }
    }

    private static func discover(_ action: () async throws -> [Device]) async -> Result<[Device], Error> {
        do { return .success(try await action()) }
        catch { return .failure(error) }
    }

    private func ensureProxy(_ tunnel: DeviceTunnel, tools: DeviceTools) async throws {
        if let proxy = proxies[tunnel.id], proxy.isRunning { return }
        if let exited = proxies.removeValue(forKey: tunnel.id) {
            let message = exited.diagnostics()
            throw CommandError(message: message.isEmpty ? L10n.text("iproxy exited and will retry automatically.") : message)
        }
        try MacListener.checkAvailability(port: tunnel.macPort)
        let proxy = try tools.startProxy(tunnel)
        proxies[tunnel.id] = proxy
        try? await Task.sleep(for: .milliseconds(200))
        if !proxy.isRunning {
            proxies.removeValue(forKey: tunnel.id)
            let message = proxy.diagnostics()
            throw CommandError(message: message.isEmpty ? L10n.text("iproxy failed to start. Check whether the Mac port is already in use.") : message)
        }
    }

    private func androidRules(_ tunnel: DeviceTunnel, _ device: Device, _ tools: DeviceTools) async throws -> [DevicePort] {
        let target = tunnel.direction == .forward ? [] : device.adbTarget
        return DevicePort.parse(try await tools.android(target + [tunnel.direction.command, "--list"]))
    }

    private func matches(_ rule: DevicePort, _ tunnel: DeviceTunnel, _ device: Device) -> Bool {
        rule.listener == tunnel.listener && rule.destination == tunnel.destination
            && (tunnel.direction == .reverse || rule.owner == device.adbAddress)
    }

    private func ensureAndroid(_ tunnel: DeviceTunnel, on device: Device, tools: DeviceTools) async throws -> Bool {
        let rules = try await androidRules(tunnel, device, tools)
        if let owner = androidOwners[tunnel.id], owner.usesSameADBConnection(as: device),
           rules.contains(where: { matches($0, tunnel, device) }) { return true }

        androidOwners.removeValue(forKey: tunnel.id)
        if tunnel.hooks?.local != nil, establishedIDs.contains(tunnel.id) {
            setState(.stopped, for: tunnel)
            return false
        }
        guard !rules.contains(where: { $0.listener == tunnel.listener }) else {
            let side = tunnel.direction == .forward ? "Mac" : L10n.text("Device")
            throw PortConflict(message: L10n.text("\(side) on \(tunnel.listener) is already in use by another ADB rule."))
        }
        guard enabled(tunnel), !shuttingDown else { return false }
        if tunnel.direction == .forward {
            try MacListener.checkAvailability(port: tunnel.macPort)
        }
        _ = try await tools.android(device.adbTarget + [
            tunnel.direction.command, "--no-rebind", tunnel.listener, tunnel.destination
        ])
        androidOwners[tunnel.id] = device
        return true
    }

    private func stop(_ tunnel: DeviceTunnel, tools: DeviceTools) async {
        if let proxy = proxies.removeValue(forKey: tunnel.id) { proxy.terminate() }
        guard let owner = androidOwners[tunnel.id] else {
            setState(.stopped, for: tunnel)
            return
        }
        let device = devices.first { $0.id == owner.id && $0.ready }
        if let device, !owner.usesSameADBConnection(as: device) {
            androidOwners.removeValue(forKey: tunnel.id)
            setState(.stopped, for: tunnel)
            return
        }
        if tunnel.direction == .reverse && device == nil {
            setState(.waiting(L10n.text("The device is offline. This forward will be checked and stopped when the device reconnects.")), for: tunnel)
            return
        }
        do {
            let rules = try await androidRules(tunnel, owner, tools)
            if rules.contains(where: { matches($0, tunnel, owner) }) {
                guard let device else {
                    setState(.waiting(L10n.text("The device is offline. This forward will be checked and stopped when the device reconnects.")), for: tunnel)
                    return
                }
                _ = try await tools.android(device.adbTarget + [tunnel.direction.command, "--remove", tunnel.listener])
            }
            androidOwners.removeValue(forKey: tunnel.id)
            setState(.stopped, for: tunnel)
        } catch {
            setState(.failed(error.localizedDescription), for: tunnel)
        }
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        monitor?.cancel()
        for task in Array(beforeConnectTasks.values) + Array(afterConnectTasks.values) { task.cancel() }
        while isRefreshing { try? await Task.sleep(for: .milliseconds(50)) }
        let tools = DeviceTools()
        for tunnel in tunnels where proxies[tunnel.id] != nil || androidOwners[tunnel.id] != nil {
            await stop(tunnel, tools: tools)
        }
        for task in Array(beforeConnectTasks.values) + Array(afterDisconnectTasks.values) { await task.value }
        return tunnels.filter { androidOwners[$0.id] != nil }.map(\.name)
    }

}
