import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class SocatManager {
    enum Status: Equatable {
        case stopped, starting, running, finished, retrying(Int32), failed(String)

        var title: String {
            switch self {
            case .stopped: L10n.text("Stopped")
            case .starting: L10n.text("Starting")
            case .running: L10n.text("Running")
            case .finished: L10n.text("Completed")
            case .retrying(let code): L10n.text("Exit code \(code). Waiting to retry.")
            case .failed(let message): message
            }
        }

        var indicator: TunnelState {
            switch self {
            case .stopped, .finished: .stopped
            case .starting: .starting
            case .running: .active
            case .retrying(let code): .waiting(L10n.text("Exit code \(code). Waiting to retry."))
            case .failed(let message): .failed(message)
            }
        }
    }

    private struct Session {
        let process: Process
        let input: FileHandle?
        let superviseRemote: Bool
        let isHelp: Bool
        let usesLocalSudo: Bool
        var connected = false
    }

    var profiles: [SocatProfile] { store.socatProfiles }
    private(set) var statuses: [UUID: Status] = [:]
    private(set) var logs: [UUID: TunnelProcessLog] = [:]
    private(set) var hookErrors: [UUID: String] = [:]
    private var beforeConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var afterConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var afterDisconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var retryAfterCleanup: Set<UUID> = []
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var sessions: [UUID: Session] = [:]
    private var stopping: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private let store: TunnelStore

    init(store: TunnelStore) {
        self.store = store
    }

    func status(_ profile: SocatProfile) -> Status { statuses[profile.id] ?? .stopped }
    func isEnabled(_ profile: SocatProfile) -> Bool {
        let id = profile.id
        return (sessions[id] != nil && stopping[id] == nil)
            || retryTasks[id] != nil || retryAfterCleanup.contains(id)
            || (beforeConnectTasks[id]?.isCancelled == false)
    }

    func isEnabledForRestore(_ profile: SocatProfile) -> Bool {
        sessions[profile.id]?.isHelp != true && isEnabled(profile)
    }

    func isStopping(_ profile: SocatProfile) -> Bool {
        let id = profile.id
        return stopping[id] != nil || afterDisconnectTasks[id] != nil || beforeConnectTasks[id]?.isCancelled == true
    }

    func canToggle(_ profile: SocatProfile) -> Bool {
        !isStopping(profile) || retryAfterCleanup.contains(profile.id)
    }

    func save(_ profile: SocatProfile, in groupID: UUID? = nil, after previous: TunnelRule.Key? = nil) -> Bool {
        guard store.canEdit, !isEnabled(profile), !isStopping(profile) else { return false }
        return store.save(.socat(profile), in: groupID, after: previous)
    }

    func delete(_ profile: SocatProfile) {
        guard store.canEdit, !isEnabled(profile), !isStopping(profile) else { return }
        guard store.delete(TunnelRule.socat(profile).key) else { return }
        statuses.removeValue(forKey: profile.id)
        logs.removeValue(forKey: profile.id)
        hookErrors.removeValue(forKey: profile.id)
    }

    func start(_ profile: SocatProfile, help: Bool = false, allowPasswordPrompt: Bool = true) {
        let id = profile.id
        guard !shuttingDown, sessions[id] == nil, retryTasks[id] == nil,
              beforeConnectTasks[id] == nil, afterDisconnectTasks[id] == nil else { return }
        let log = TunnelProcessLog()
        logs[id] = log
        hookErrors.removeValue(forKey: id)
        let tracksConnection = !help && profile.destination == .ssh &&
            profile.hooks?.hasCommand(.afterConnect, supportsRemote: true) == true
        let marker = tracksConnection ? "UTM_SOCAT_CONNECTED_" + UUID().uuidString : nil
        let launch: SocatLaunch
        do {
            launch = try SocatLaunch(profile: profile, override: help ? ["-hhh"] : nil,
                                    allowPasswordPrompt: allowPasswordPrompt, readyMarker: marker)
        } catch {
            failStart(profile, error: error, isHelp: help)
            return
        }
        guard !help, profile.hooks?.hasCommand(.beforeConnect, supportsRemote: profile.destination == .ssh) == true else {
            launchProcess(profile, launch: launch, help: help, log: log, marker: marker)
            return
        }
        statuses[id] = .starting
        beforeConnectTasks[id] = Task {
            defer { beforeConnectTasks.removeValue(forKey: id) }
            do {
                try await runHook(profile, phase: .beforeConnect)
                guard !Task.isCancelled, !shuttingDown else { return }
                launchProcess(profile, launch: launch, help: false, log: log, marker: marker)
            } catch {
                if !Task.isCancelled { failStart(profile, error: error, isHelp: false) }
            }
        }
    }

    private func launchProcess(_ profile: SocatProfile, launch: SocatLaunch, help: Bool,
                               log: TunnelProcessLog, marker: String?) {
        let id = profile.id
        let process = Process()
        let pipe = Pipe()
        do {
            process.executableURL = launch.executable
            process.arguments = launch.arguments
            process.environment = launch.environment
            var inputWriter: FileHandle?
            if help || (profile.input == .closed && !launch.superviseRemote) {
                process.standardInput = FileHandle.nullDevice
            } else if profile.input == .file {
                process.standardInput = try FileHandle(forReadingFrom: localFile(profile.inputFile))
            } else {
                let input = Pipe()
                process.standardInput = input
                inputWriter = input.fileHandleForWriting
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            }
            process.standardError = pipe
            if help || profile.outputFile.isEmpty {
                process.standardOutput = pipe
            } else {
                let url = try localFile(profile.outputFile)
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600))
                guard descriptor >= 0 else {
                    throw CommandError(message: L10n.text("Could not open the output file: \(String(cString: strerror(errno)))"))
                }
                process.standardOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }
            pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] stream in
                let chunk = stream.availableData
                if chunk.isEmpty { stream.readabilityHandler = nil }
                else {
                    log.append(chunk)
                    if let marker, log.removeLine(containing: marker) {
                        Task { @MainActor [weak self] in
                            guard let self, let process, self.sessions[id]?.process === process else { return }
                            self.markConnected(profile)
                        }
                    }
                }
            }
            process.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.sessions[id]?.process === child else { return }
                    if marker != nil && status == 0 { self.markConnected(profile) }
                    self.finished(profile, code: status, isHelp: help)
                }
            }
            try process.run()
            sessions[id] = Session(process: process, input: inputWriter, superviseRemote: launch.superviseRemote,
                                   isHelp: help, usesLocalSudo: launch.usesLocalSudo)
            if help {
                statuses[id] = .running
            } else if marker != nil {
                statuses[id] = .starting
            } else {
                markConnected(profile)
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            failStart(profile, error: error, isHelp: help)
        }
    }

    private func failStart(_ profile: SocatProfile, error: Error, isHelp: Bool) {
        statuses[profile.id] = .failed(error.localizedDescription)
        if !isHelp && !shuttingDown { store.forgetEnabledProfile(TunnelRule.socat(profile).key) }
    }

    private func runHook(_ profile: SocatProfile, phase: TunnelHookPhase) async throws {
        let remote: ((String) throws -> SSHInvocation)? = profile.destination == .ssh
            ? { try SocatLaunch.hook(profile, command: $0) } : nil
        try await TunnelHookRunner.run(profile.hooks, phase: phase, remoteInvocation: remote)
    }

    private func markConnected(_ profile: SocatProfile) {
        let id = profile.id
        guard !shuttingDown, stopping[id] == nil, sessions[id]?.connected == false else { return }
        sessions[id]?.connected = true
        statuses[id] = .running
        TunnelFeedback.announce(.connected, name: profile.name, using: store)
        if profile.hooks?.hasCommand(.afterConnect, supportsRemote: profile.destination == .ssh) == true {
            afterConnectTasks[id] = Task {
                defer { afterConnectTasks.removeValue(forKey: id) }
                do { try await runHook(profile, phase: .afterConnect) }
                catch {
                    if !Task.isCancelled { hookErrors[id] = error.localizedDescription }
                }
            }
        }
    }

    func stop(_ profile: SocatProfile) {
        let id = profile.id
        retryTasks.removeValue(forKey: id)?.cancel()
        retryAfterCleanup.remove(id)
        beforeConnectTasks[id]?.cancel()
        afterConnectTasks[id]?.cancel()
        guard let session = sessions[id], stopping[id] == nil else {
            if sessions[id] == nil { statuses[id] = .stopped }
            return
        }
        statuses[id] = .stopped
        if !session.superviseRemote { signal(session.process, SIGTERM) }
        try? session.input?.close()
        stopping[id] = Task {
            if session.superviseRemote {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                signal(session.process, SIGTERM)
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // sudo can relay TERM to its child. Killing sudo itself can orphan an elevated child.
            signal(session.process, session.usesLocalSudo ? SIGTERM : SIGKILL)
        }
    }

    func send(_ text: String, to profile: SocatProfile) {
        guard let session = sessions[profile.id], !session.superviseRemote, let input = session.input else { return }
        let log = logs[profile.id]
        DispatchQueue.global().async {
            do { try input.write(contentsOf: Data((text + "\n").utf8)) }
            catch { log?.append(Data("\nstdin: \(error.localizedDescription)\n".utf8)) }
        }
    }

    func closeInput(_ profile: SocatProfile) {
        guard let session = sessions[profile.id], !session.superviseRemote else { return }
        try? session.input?.close()
    }

    func shutdown() async {
        shuttingDown = true
        for profile in profiles { stop(profile) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !sessions.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for session in sessions.values {
            signal(session.process, session.usesLocalSudo ? SIGTERM : SIGKILL)
        }
        let grace = ContinuousClock.now.advanced(by: .milliseconds(500))
        while !sessions.isEmpty && ContinuousClock.now < grace {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for task in Array(beforeConnectTasks.values) + Array(afterDisconnectTasks.values) { await task.value }
    }

    private func finished(_ profile: SocatProfile, code: Int32, isHelp: Bool) {
        let id = profile.id
        guard let session = sessions.removeValue(forKey: id) else { return }
        try? session.input?.close()
        let stoppedByUser = stopping[id] != nil
        stopping.removeValue(forKey: id)?.cancel()
        let retry = !stoppedByUser && !isHelp && code != 0 && profile.restartOnFailure && !shuttingDown
        let connectedHook = afterConnectTasks[id]
        if stoppedByUser || shuttingDown { connectedHook?.cancel() }
        guard !isHelp && (connectedHook != nil ||
            profile.hooks?.hasCommand(.afterDisconnect, supportsRemote: profile.destination == .ssh) == true) else {
            complete(profile, code: code, isHelp: isHelp, stoppedByUser: stoppedByUser,
                     wasConnected: session.connected, retry: retry)
            return
        }
        if retry { retryAfterCleanup.insert(id) }
        afterDisconnectTasks[id] = Task {
            await connectedHook?.value
            do { try await runHook(profile, phase: .afterDisconnect) }
            catch { hookErrors[id] = error.localizedDescription }
            afterDisconnectTasks.removeValue(forKey: id)
            let retry = retryAfterCleanup.remove(id) != nil && !shuttingDown
            complete(profile, code: code, isHelp: false, stoppedByUser: stoppedByUser || statuses[id] == .stopped,
                     wasConnected: session.connected, retry: retry)
        }
    }

    private func complete(_ profile: SocatProfile, code: Int32, isHelp: Bool, stoppedByUser: Bool,
                          wasConnected: Bool, retry: Bool) {
        let id = profile.id
        if stoppedByUser {
            statuses[id] = .stopped
        } else if retry {
            statuses[id] = .retrying(code)
            retryTasks[id] = Task {
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                retryTasks.removeValue(forKey: id)
                start(profile, allowPasswordPrompt: false)
            }
        } else if code == 0 {
            statuses[id] = .finished
        } else {
            statuses[id] = .failed(L10n.text("Process exited (\(code))"))
        }
        guard !isHelp, !shuttingDown else { return }
        if !retry { store.forgetEnabledProfile(TunnelRule.socat(profile).key) }
        if wasConnected { TunnelFeedback.announce(.disconnected(retrying: retry), name: profile.name, using: store) }
    }

    private func signal(_ process: Process, _ signal: Int32) {
        guard process.isRunning, process.processIdentifier > 1 else { return }
        let pid = process.processIdentifier
        kill(getpgid(pid) == pid ? -pid : pid, signal)
    }

    private func localFile(_ value: String) throws -> URL {
        let path = (value as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw CommandError(message: L10n.text("Enter an absolute path on this Mac."))
        }
        return URL(fileURLWithPath: path)
    }

}
