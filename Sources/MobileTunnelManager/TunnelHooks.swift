import Darwin
import Foundation

struct TunnelHooks: Codable, Hashable {
    struct Commands: Codable, Hashable {
        var beforeConnect: String?
        var afterConnect: String?
        var afterDisconnect: String?

        func command(_ phase: TunnelHookPhase) -> String? {
            let value = switch phase {
            case .beforeConnect: beforeConnect
            case .afterConnect: afterConnect
            case .afterDisconnect: afterDisconnect
            }
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
    }

    var local: Commands?
    var remote: Commands?

    func hasCommand(_ phase: TunnelHookPhase, supportsRemote: Bool) -> Bool {
        local?.command(phase) != nil || (supportsRemote && remote?.command(phase) != nil)
    }
}

enum TunnelHookPhase {
    case beforeConnect, afterConnect, afterDisconnect

    var title: String {
        switch self {
        case .beforeConnect: L10n.text("Before Connect")
        case .afterConnect: L10n.text("After Connect")
        case .afterDisconnect: L10n.text("After Disconnect")
        }
    }
}

@MainActor
enum TunnelHookRunner {
    static let timeoutSeconds = 30

    static func run(_ hooks: TunnelHooks?, phase: TunnelHookPhase,
                    remoteInvocation: ((String) throws -> SSHInvocation)? = nil) async throws {
        try Task.checkCancellation()
        var failure: Error?
        if let command = hooks?.local?.command(phase) {
            do {
                try await run(executable: "/bin/sh", arguments: ["-c", command],
                              label: L10n.text("Local · \(phase.title)"))
            } catch {
                if phase == .beforeConnect || Task.isCancelled { throw error }
                failure = error
            }
        }
        if let remoteInvocation, let command = hooks?.remote?.command(phase) {
            let label = L10n.text("Remote · \(phase.title)")
            do {
                let invocation: SSHInvocation
                do { invocation = try remoteInvocation(command) }
                catch { throw CommandError(message: "\(label): \(error.localizedDescription)") }
                try await run(executable: invocation.executable, arguments: invocation.arguments, label: label)
            } catch {
                if let failure {
                    throw CommandError(message: failure.localizedDescription + "\n" + error.localizedDescription)
                }
                throw error
            }
        }
        if let failure { throw failure }
    }

    private static func run(executable: String, arguments: [String], label: String) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = Pipe()
        let diagnostics = TunnelProcessLog()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { stream in
            let chunk = stream.availableData
            if chunk.isEmpty { stream.readabilityHandler = nil }
            else { diagnostics.append(chunk) }
        }
        defer { stderr.fileHandleForReading.readabilityHandler = nil }

        var timedOut = false
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
            catch { return }
            guard process.isRunning else { return }
            timedOut = true
            await stop(process)
        }
        defer { deadline.cancel() }

        let code: Int32
        do {
            code = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { child in
                        continuation.resume(returning: child.terminationStatus)
                    }
                    do { try process.run() }
                    catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { @MainActor in await stop(process) }
            }
        } catch {
            throw CommandError(message: L10n.text("\(label) command could not start: \(error.localizedDescription)"))
        }
        try Task.checkCancellation()
        if timedOut {
            throw CommandError(message: L10n.text("\(label) command timed out after \(timeoutSeconds) seconds."))
        }
        guard code == 0 else {
            let message = L10n.text("\(label) command exited with status \(code).")
            let detail = diagnostics.read(after: -1)?.1
                .split(whereSeparator: \.isNewline).last.map { String($0.prefix(300)) }
            throw CommandError(message: detail.map { "\(message) \($0)" } ?? message)
        }
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning, process.processIdentifier > 1 else { return }
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        try? await Task.sleep(for: .milliseconds(300))
        if process.isRunning { kill(target, SIGKILL) }
    }
}

final class TunnelProcessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var revision = 0

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 131_072 { data = Data(data.suffix(131_072)) }
            revision += 1
        }
    }

    func removeLine(containing marker: String) -> Bool {
        lock.withLock {
            let markerLine = Data((marker + "\n").utf8)
            guard let range = data.range(of: markerLine) else { return false }
            data.removeSubrange(range)
            revision += 1
            return true
        }
    }

    func read(after version: Int) -> (Int, String)? {
        lock.withLock { revision == version ? nil : (revision, String(decoding: data, as: UTF8.self)) }
    }
}
