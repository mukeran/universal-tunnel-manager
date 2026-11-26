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
        guard descriptor >= 0 else { throw CommandError(message: "无法创建命令输出文件。") }
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
        let command = process.executableURL?.lastPathComponent ?? "命令"
        if completion.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CommandError(message: "\(command) 超时，请检查设备或连接。")
        }
        let message = diagnostics()
        if process.terminationStatus == emptyResultExitCode, message.isEmpty { return "" }
        guard process.terminationStatus == 0 else {
            throw CommandError(message: message.isEmpty ? "\(command) 退出，状态 \(process.terminationStatus)。" : message)
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

    private static func locate(_ tool: String) -> URL? {
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
        guard let adb else { throw CommandError(message: "找不到 adb，请安装 Android SDK Platform-Tools。") }
        return try await ToolProcess.run(adb, arguments)
    }

    func androidDevices() async throws -> [Device] {
        let output = try await android(["devices", "-l"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, let state = columns.dropFirst().first,
                  ["device", "offline", "unauthorized", "authorizing", "recovery", "sideload", "bootloader", "no"].contains(state)
            else { return nil }
            let serial = String(columns[0])
            let model = columns.first { $0.hasPrefix("model:") }
                .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") }
            let transport = columns.first { $0.hasPrefix("transport_id:") }
                .map { String($0.dropFirst("transport_id:".count)) }
            let connection: String
            switch state {
            case "device":
                if serial.hasPrefix("emulator-") { connection = "模拟器" }
                else if serial.contains(":") || serial.hasSuffix("._adb-tls-connect._tcp") { connection = "Wi-Fi" }
                else { connection = "已连接" }
            case "unauthorized": connection = "请在设备上授权 USB 调试"
            case "offline": connection = "离线"
            default: connection = String(state)
            }
            return Device(id: DeviceID(platform: .android, serial: serial), name: model ?? serial,
                          connection: connection, ready: state == "device", transport: transport)
        }
    }

    func iosDevices(known: [Device]) async throws -> [Device] {
        guard let ideviceID, iproxy != nil else {
            throw CommandError(message: "找不到 idevice_id 或 iproxy，请安装 libimobiledevice 和 libusbmuxd。")
        }
        async let usbList = ToolProcess.run(ideviceID, ["-l"])
        async let networkList = ToolProcess.run(ideviceID, ["-n"])
        let (usbOutput, networkOutput) = try await (usbList, networkList)
        let usb = Self.serials(usbOutput)
        let network = Self.serials(networkOutput)
        var devices: [Device] = []
        var modelNames: [String: String]?
        for serial in usb.union(network).sorted() {
            let id = DeviceID(platform: .ios, serial: serial)
            let isUSB = usb.contains(serial)
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
            devices.append(Device(id: id, name: name, connection: isUSB ? "USB" : "Wi-Fi", ready: true))
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

    private static func serials(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.count >= 20 && $0.allSatisfy { $0.isHexDigit || $0 == "-" }
        })
    }

    func startProxy(_ tunnel: Tunnel) throws -> ToolProcess {
        guard let iproxy else { throw CommandError(message: "找不到 iproxy。") }
        return try ToolProcess(iproxy, ["-l", "-n", "-u", tunnel.device.serial, "-s", "127.0.0.1",
                                       "\(tunnel.macPort):\(tunnel.devicePort)"])
    }
}
