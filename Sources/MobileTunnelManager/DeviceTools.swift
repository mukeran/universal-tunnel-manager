import Darwin
import Foundation

struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ToolProcess {
    private let process = Process()
    private let output: FileHandle
    private let completion = DispatchSemaphore(value: 0)

    init(_ executable: URL, _ args: [String]) throws {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-tunnel.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw CommandError(message: L10n.text("Could not create the command output file.")) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        unlink(template)
        process.executableURL = executable
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let completion = self.completion
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func diagnostics(limit: UInt64 = 4096) -> String {
        let end = (try? output.seekToEnd()) ?? 0
        try? output.seek(toOffset: end > limit ? end - limit : 0)
        let data = (try? output.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func result(emptyResultExitCode: Int32?) throws -> String {
        let command = process.executableURL?.lastPathComponent ?? L10n.text("Command")
        if completion.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CommandError(message: L10n.text("\(command) timed out. Check the device or connection."))
        }
        let message = diagnostics()
        if process.terminationStatus == emptyResultExitCode, message.isEmpty { return "" }
        guard process.terminationStatus == 0 else {
            throw CommandError(message: message.isEmpty ? L10n.text("\(command) exited with status \(process.terminationStatus).") : message)
        }
        return diagnostics(limit: 256 * 1024)
    }

    static func run(_ executable: URL, _ args: [String], emptyResultExitCode: Int32? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try ToolProcess(executable, args).result(emptyResultExitCode: emptyResultExitCode)
                })
            }
        }
    }
}

struct DeviceTools {
    let adb = Self.locate("adb")
    let iproxy = Self.locate("iproxy")
    let ideviceID = Self.locate("idevice_id")
    private let ideviceInfo = Self.locate("ideviceinfo")
    private let irecovery = Self.locate("irecovery")

    static func locate(_ tool: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sdkTools = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], home.appendingPathComponent("Library/Android/sdk").path]
            .compactMap { $0 }.map { $0 + "/platform-tools" }
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + sdkTools + path
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func android(_ arguments: [String]) async throws -> String {
        guard let adb else { throw CommandError(message: L10n.text("adb was not found. Install Android SDK Platform-Tools.")) }
        return try await ToolProcess.run(adb, arguments)
    }

    func androidDevices(known: [Device]) async throws -> [Device] {
        let output = try await android(["devices", "-l"])
        let connections: [Device] = output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, let state = columns.dropFirst().first,
                  ["device", "offline", "unauthorized", "authorizing", "recovery", "sideload", "bootloader", "no"].contains(state)
            else { return nil }
            let serial = String(columns[0])
            let model = columns.first { $0.hasPrefix("model:") }
                .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") }
            let transport = columns.first { $0.hasPrefix("transport_id:") }
                .map { String($0.dropFirst("transport_id:".count)) }
            let id = DeviceID(platform: .android, serial: serial)
            let type: AndroidConnection?
            if serial.hasPrefix("emulator-") {
                type = .emulator
            } else if serial.contains("._adb-tls-connect._tcp") {
                type = .wifi
            } else if id.isAndroidEndpoint {
                type = .network
            } else if columns.dropFirst(2).contains(where: { $0.hasPrefix("usb:") || $0 == serial }) {
                type = .usb
            } else {
                type = nil
            }
            let connection: String
            switch state {
            case "device": connection = type?.title ?? L10n.text("Connected")
            case "unauthorized": connection = L10n.text("Authorize USB debugging on the device")
            case "offline": connection = L10n.text("Offline")
            default: connection = String(state)
            }
            return Device(id: id, name: model ?? serial, connection: connection, ready: state == "device",
                          transport: transport, androidConnection: type)
        }
        let resolved = await withTaskGroup(of: (Int, Device).self) { group in
            for (index, device) in connections.enumerated() {
                group.addTask { (index, await resolveAndroidIdentity(device)) }
            }
            var detected: [(Int, Device)] = []
            for await result in group { detected.append(result) }
            return detected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var devices: [Device] = []
        for device in resolved {
            guard let index = devices.firstIndex(where: { $0.id == device.id }) else {
                devices.append(device)
                continue
            }
            let previouslySelected = known.contains { $0.usesSameADBConnection(as: device) }
            if device.ready && (!devices[index].ready || previouslySelected) {
                devices[index] = device
            }
        }
        return devices
    }

    private func resolveAndroidIdentity(_ device: Device) async -> Device {
        guard device.id.isAndroidEndpoint else { return device }
        let endpoint = device.adbAddress
        if device.ready, let stableID = await androidStableID(for: device) {
            return Device(id: stableID, name: device.name, connection: device.connection, ready: true,
                          transport: device.transport, adbSerial: endpoint, androidConnection: device.androidConnection)
        }
        return Device(id: DeviceID(platform: .android, serial: "pending:\(endpoint)"),
                      name: device.name,
                      connection: device.ready ? L10n.text("Could not verify device identity") : device.connection, ready: false,
                      transport: device.transport, adbSerial: endpoint, androidConnection: device.androidConnection)
    }

    private func androidStableID(for device: Device) async -> DeviceID? {
        if device.adbAddress.hasPrefix("emulator-") {
            let keys = ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"]
            for key in keys {
                if let name = await androidProperty(key, device: device) {
                    return DeviceID(platform: .android, serial: name, kind: .androidAVD)
                }
            }
            return nil
        }
        guard let serial = await androidProperty("ro.serialno", device: device) else { return nil }
        let id = DeviceID(platform: .android, serial: serial)
        return id.isAndroidEndpoint ? nil : id
    }

    private func androidProperty(_ key: String, device: Device) async -> String? {
        guard let value = try? await android(device.adbTarget + ["shell", "getprop", key]),
              !value.isEmpty, !value.contains(where: \.isNewline),
              !["unknown", "null", "none"].contains(value.lowercased()) else { return nil }
        return value
    }

    func deviceDetails(for device: Device) async -> (model: String?, version: String?) {
        guard device.ready else { return (nil, nil) }
        switch device.id.platform {
        case .ios:
            guard let connection = device.iosConnection else { return (nil, nil) }
            async let model = iosValue("ProductType", serial: device.id.serial, isUSB: connection == .usb)
            async let version = iosValue("ProductVersion", serial: device.id.serial, isUSB: connection == .usb)
            return await (model, version)
        case .android:
            async let model = androidProperty("ro.product.model", device: device)
            async let version = androidProperty("ro.build.version.release", device: device)
            return await (model, version)
        }
    }

    func iosDevices(known: [Device]) async throws -> [Device] {
        guard let ideviceID, iproxy != nil else {
            throw CommandError(message: L10n.text("idevice_id or iproxy was not found. Install libimobiledevice and libusbmuxd."))
        }
        let output = try await ToolProcess.run(ideviceID, [])
        let connections = Self.iosConnections(output)
        var devices: [Device] = []
        var modelNames: [String: String]?
        for (serial, connection) in connections.sorted(by: { $0.key < $1.key }) {
            let id = DeviceID(platform: .ios, serial: serial)
            let isUSB = connection == .usb
            let name: String
            if let previous = known.first(where: { $0.id == id }) {
                name = previous.name
            } else {
                let reported = await iosValue("DeviceName", serial: serial, isUSB: isUSB)
                var deviceName = reported
                if deviceName == nil && isUSB {
                    deviceName = try? await ToolProcess.run(ideviceID, [serial])
                }
                if let deviceName, !deviceName.isEmpty,
                   !["iphone", "ipad", "ipod", "ipod touch"].contains(deviceName.lowercased()) {
                    name = deviceName
                } else if let product = await iosValue("ProductType", serial: serial, isUSB: isUSB) {
                    if modelNames == nil { modelNames = await iosModelNames() }
                    name = modelNames?[product] ?? "\(product) · \(serial.suffix(6))"
                } else {
                    let family = deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone / iPad"
                    name = "\(family) · \(serial.suffix(6))"
                }
            }
            devices.append(Device(id: id, name: name, connection: connection.title, ready: true,
                                  iosConnection: connection))
        }
        return devices
    }

    private func iosValue(_ key: String, serial: String, isUSB: Bool) async -> String? {
        guard let ideviceInfo else { return nil }
        let transport = isUSB ? [] : ["-n"]
        guard let value = try? await ToolProcess.run(ideviceInfo, transport + ["-s", "-u", serial, "-k", key]),
              !value.isEmpty else { return nil }
        return value
    }

    private func iosModelNames() async -> [String: String] {
        guard let irecovery, let catalog = try? await ToolProcess.run(irecovery, ["--devices"]) else { return [:] }
        var names: [String: String] = [:]
        for line in catalog.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5 else { continue }
            names[String(fields[0])] = String(fields[4])
        }
        return names
    }

    private static func iosConnections(_ output: String) -> [String: IOSConnection] {
        var connections: [String: IOSConnection] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let connection = IOSConnection(rawValue: String(fields[1])),
                  fields[0].count >= 20,
                  fields[0].allSatisfy({ $0.isHexDigit || $0 == "-" }) else { continue }
            let serial = String(fields[0])
            if connections[serial] != .usb { connections[serial] = connection }
        }
        return connections
    }

    func startProxy(_ tunnel: DeviceTunnel) throws -> ToolProcess {
        guard let iproxy else { throw CommandError(message: L10n.text("iproxy was not found.")) }
        return try ToolProcess(iproxy, ["-l", "-n", "-u", tunnel.device.serial, "-s", "127.0.0.1",
                                       "\(tunnel.macPort):\(tunnel.devicePort)"])
    }
}
