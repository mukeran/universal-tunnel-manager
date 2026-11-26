import Foundation

enum Platform: String, Codable, CaseIterable {
    case ios, android

    var title: String { self == .ios ? "iOS" : "Android" }
    var icon: String { self == .ios ? "iphone" : "candybarphone" }
}

struct DeviceID: Hashable, Codable {
    enum Kind: String, Codable { case androidAVD }

    let platform: Platform
    let serial: String
    var kind: Kind? = nil

    var isAndroidEndpoint: Bool {
        platform == .android && kind == nil
            && (serial.contains(":") || serial.hasPrefix("emulator-")
                || serial.contains("._adb-tls-connect._tcp"))
    }
}

enum IOSConnection: String {
    case usb = "(USB)"
    case wifi = "(Network)"

    var title: String { self == .usb ? "USB" : "Wi-Fi" }
}

struct Device: Identifiable {
    let id: DeviceID
    let name: String
    let connection: String
    let ready: Bool
    var transport: String? = nil
    var adbSerial: String? = nil
    var iosConnection: IOSConnection? = nil

    var adbAddress: String { adbSerial ?? id.serial }
    var adbTarget: [String] {
        transport.map { ["-t", $0] } ?? ["-s", adbAddress]
    }

    func usesSameADBConnection(as other: Device) -> Bool {
        id == other.id && transport == other.transport && adbAddress == other.adbAddress
    }
}

struct IOSWiFiPresence {
    private var lastSeen: [DeviceID: (device: Device, time: ContinuousClock.Instant)] = [:]

    mutating func temporarilyMissing(from detected: [Device], at now: ContinuousClock.Instant) -> [Device] {
        let detectedIDs = Set(detected.map(\.id))
        for device in detected {
            if device.iosConnection == .wifi {
                lastSeen[device.id] = (device, now)
            } else {
                lastSeen.removeValue(forKey: device.id)
            }
        }
        lastSeen = lastSeen.filter { $0.value.time.duration(to: now) < .seconds(12) }
        return lastSeen.values.map(\.device).filter { !detectedIDs.contains($0.id) }
    }
}

struct DeviceSelection: Equatable {
    let listed: [DeviceID]
    let ready: [DeviceID]

    init(devices: [Device]) {
        listed = devices.map(\.id)
        ready = devices.filter(\.ready).map(\.id)
    }

    func selected(_ current: DeviceID?, after previous: Self) -> DeviceID? {
        guard let current, listed.contains(current) else { return ready.first ?? listed.first }
        if ready.contains(current) { return current }
        let newlyReady = ready.filter { !previous.ready.contains($0) }
        return newlyReady.first { $0.platform == current.platform } ?? newlyReady.first ?? current
    }
}

enum Direction: String, Codable, CaseIterable, Identifiable {
    case forward, reverse

    var id: Self { self }
    var title: String { self == .forward ? "Mac → 设备" : "设备 → Mac" }
    var command: String { self == .forward ? "forward" : "reverse" }
}

struct Tunnel: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    let device: DeviceID
    let deviceName: String
    var direction: Direction
    var macPort: Int
    var devicePort: Int

    var listener: String { "tcp:\(direction == .forward ? macPort : devicePort)" }
    var destination: String { "tcp:\(direction == .forward ? devicePort : macPort)" }

    var route: String {
        switch direction {
        case .forward: return "Mac :\(macPort) → 设备 :\(devicePort)"
        case .reverse: return "设备 :\(devicePort) → Mac :\(macPort)"
        }
    }

    var valid: Bool {
        (1...65535).contains(macPort) && (1...65535).contains(devicePort)
            && (device.platform == .android || direction == .forward)
            && !device.serial.isEmpty
    }
}

enum TunnelState {
    case stopped, starting, active, waiting(String), stopping, conflict(String), failed(String)

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .active: "已建立"
        case .waiting: "等待设备"
        case .stopping: "正在停止"
        case .conflict: "端口冲突"
        case .failed: "转发失败"
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .waiting(let message), .conflict(let message): message
        default: nil
        }
    }
}

struct SavedSettings: Codable {
    var tunnels: [Tunnel] = []
    var enabled: Set<UUID> = []
    var restoreOnLaunch = false
}

struct DevicePort: Equatable {
    let owner: String
    let listener: String
    let destination: String

    static func parse(_ output: String) -> [Self] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 3, columns[1].hasPrefix("tcp:") else { return nil }
            return Self(owner: String(columns[0]), listener: String(columns[1]), destination: String(columns[2]))
        }
    }
}
