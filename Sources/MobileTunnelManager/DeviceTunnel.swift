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

    var label: String {
        if platform == .ios { return "UDID" }
        if kind == .androidAVD { return L10n.text("AVD Name") }
        return isAndroidEndpoint ? L10n.text("ADB Address") : L10n.text("Serial Number")
    }

    var abbreviated: String {
        serial.count > 14 ? "…\(serial.suffix(8))" : serial
    }
}

enum IOSConnection: String {
    case usb = "(USB)"
    case wifi = "(Network)"

    var title: String { self == .usb ? "USB" : "Wi-Fi" }
}

enum AndroidConnection {
    case usb, wifi, network, emulator

    var title: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        case .network: L10n.text("Network ADB")
        case .emulator: L10n.text("Emulator")
        }
    }
}

struct Device: Identifiable, Equatable {
    let id: DeviceID
    let name: String
    let connection: String
    let ready: Bool
    var transport: String? = nil
    var adbSerial: String? = nil
    var iosConnection: IOSConnection? = nil
    var androidConnection: AndroidConnection? = nil

    var connectionType: String? { iosConnection?.title ?? androidConnection?.title }
    var connectionSummary: String {
        guard let connectionType else { return connection }
        return ready ? connectionType : "\(connectionType) · \(connection)"
    }

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
    var title: String { self == .forward ? L10n.text("Mac → Device") : L10n.text("Device → Mac") }
    var command: String { self == .forward ? "forward" : "reverse" }
}

struct DeviceTunnel: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    let device: DeviceID
    let deviceName: String
    var direction: Direction
    var macPort: Int
    var devicePort: Int
    var hooks: TunnelHooks? = nil

    var listener: String { "tcp:\(direction == .forward ? macPort : devicePort)" }
    var destination: String { "tcp:\(direction == .forward ? devicePort : macPort)" }

    var route: String {
        switch direction {
        case .forward: return L10n.text("Mac :\(String(macPort)) → Device :\(String(devicePort))")
        case .reverse: return L10n.text("Device :\(String(devicePort)) → Mac :\(String(macPort))")
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
        case .stopped: L10n.text("Stopped")
        case .starting: L10n.text("Starting")
        case .active: L10n.text("Active")
        case .waiting: L10n.text("Waiting for Device")
        case .stopping: L10n.text("Stopping")
        case .conflict: L10n.text("Port Conflict")
        case .failed: L10n.text("Forwarding Failed")
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .waiting(let message), .conflict(let message): message
        default: nil
        }
    }
}

struct LegacyDeviceSettings: Decodable {
    var tunnels: [DeviceTunnel] = []
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
