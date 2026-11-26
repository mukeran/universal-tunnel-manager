import Foundation
import Darwin
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "SSHTunnelManager",
    category: "SSHTunnelManager"
)

/// Whether something is accepting TCP connections on 127.0.0.1:port. ssh binds a
/// forward's local port only once the connection actually succeeds, so this is
/// used to detect when a tunnel is genuinely up.
private func isLocalPortOpen(_ port: Int) -> Bool {
    guard (1...65535).contains(port) else { return false }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc == 0
}

private func stopProcess(_ process: Process, signal: Int32) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    guard pid > 1 else { return }
    kill(getpgid(pid) == pid ? -pid : pid, signal)
}

private final class SSHDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) {
        lock.withLock {
            buffer.append(chunk)
            if buffer.count > 65536 { buffer = Data(buffer.suffix(65536)) }
        }
    }
    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
}

@Observable
@MainActor
final class SSHTunnelManager {
    var tunnels: [SSHTunnel] { store.sshTunnels }
    private var processes: [UUID: Process] = [:]
    private var connectionStatus: [UUID: ConnectionStatus] = [:]
    private var shouldBeConnected: Set<UUID> = [] // Tracks desired state for reconnection
    private var beforeStartTasks: [UUID: Task<Void, Never>] = [:]
    private var afterConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var afterStopTasks: [UUID: Task<Void, Never>] = [:]
    private var stopping: Set<UUID> = []
    private var establishedTunnels: Set<UUID> = [] // Connections that survived the grace period (gates feedback)
    private var lastErrors: [UUID: String] = [:] // Why each tunnel last failed/dropped — sticky until it establishes or is stopped
    private let store: TunnelStore
    private let childJournal: SSHChildJournal
    private var reconnectTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(store: TunnelStore) {
        self.store = store
        childJournal = SSHChildJournal(directory: store.directory.appendingPathComponent("ssh-tunnels-processes"))
    }

    func start() {
        guard !isShuttingDown, reconnectTask == nil else { return }
        childJournal.recover()
        guard store.canEdit else { return }
        startReconnectMonitor()
    }

    private func startReconnectMonitor() {
        reconnectTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                reconnectDisconnectedTunnels()
            }
        }
    }

    private func reconnectDisconnectedTunnels() {
        for tunnelID in shouldBeConnected {
            guard let tunnel = tunnels.first(where: { $0.id == tunnelID }) else {
                shouldBeConnected.remove(tunnelID)
                continue
            }

            beginConnecting(tunnel: tunnel)
        }
    }

    private func beginConnecting(tunnel: SSHTunnel) {
        let id = tunnel.id
        guard !isShuttingDown, shouldBeConnected.contains(id), processes[id] == nil,
              beforeStartTasks[id] == nil, afterStopTasks[id] == nil else { return }
        connectionStatus[id] = .connecting
        startSSHProcess(tunnel: tunnel)
    }

    private func resumeConnection(_ id: UUID) {
        if let tunnel = tunnels.first(where: { $0.id == id }) {
            beginConnecting(tunnel: tunnel)
        }
    }

    func isConnected(_ tunnel: SSHTunnel) -> Bool {
        connectionStatus[tunnel.id] == .connected
    }

    func isEnabled(_ tunnel: SSHTunnel) -> Bool { shouldBeConnected.contains(tunnel.id) }

    func status(for tunnel: SSHTunnel) -> ConnectionStatus {
        connectionStatus[tunnel.id] ?? .disconnected
    }

    /// Why the tunnel last failed to connect or dropped, if it isn't currently
    /// up. nil when it's connected or was stopped cleanly. Sticky across the
    /// auto-reconnect retries, so the reason stays put instead of flickering.
    func lastError(for tunnel: SSHTunnel) -> String? {
        lastErrors[tunnel.id]
    }

    /// Local forward ports this tunnel shares with *other* configured tunnels.
    /// ssh can't bind the same local port twice, so connecting both would make
    /// the second fail to bind — this lets the UI warn before that happens.
    /// Returns each shared port mapped to the names of the other tunnels on it.
    func localPortConflicts(for tunnel: SSHTunnel) -> [Int: [String]] {
        // Only ports bound on this Mac can clash — a remote forward (-R) binds
        // on the server, so its port lives in a different namespace.
        let myPorts = Set(tunnel.locallyBoundPorts)
        guard !myPorts.isEmpty else { return [:] }
        var conflicts: [Int: [String]] = [:]
        let unnamed = L10n.text("Untitled")
        for other in tunnels where other.id != tunnel.id {
            for port in Set(other.locallyBoundPorts) where myPorts.contains(port) {
                conflicts[port, default: []].append(other.name.isEmpty ? unnamed : other.name)
            }
        }
        return conflicts
    }

    func connect(tunnel: SSHTunnel) {
        guard !isConnected(tunnel) else { return }

        // Record desired state so the monitor keeps the tunnel alive, then start.
        shouldBeConnected.insert(tunnel.id)
        beginConnecting(tunnel: tunnel)
    }

    private func startSSHProcess(tunnel: SSHTunnel) {
        // Reject hosts that would let ssh parse the destination as an option
        // (e.g. "-oProxyCommand=…") or that are empty — otherwise the reconnect
        // monitor would respawn a doomed process every few seconds.
        let host = tunnel.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: \.isWhitespace),
              !host.contains("\0") else {
            logger.error("Refusing to start tunnel \"\(tunnel.name, privacy: .public)\": invalid host \"\(host, privacy: .public)\"")
            shouldBeConnected.remove(tunnel.id)
            connectionStatus[tunnel.id] = .disconnected
            store.forgetEnabledProfile(TunnelRule.ssh(tunnel).key)
            return
        }

        let invocation = SSHInvocation(tunnel: tunnel, host: host)
        guard FileManager.default.isExecutableFile(atPath: invocation.executable) else {
            lastErrors[tunnel.id] = L10n.text("Custom SSH command isn’t an executable file: \(invocation.executable)")
            shouldBeConnected.remove(tunnel.id)
            connectionStatus[tunnel.id] = .disconnected
            store.forgetEnabledProfile(TunnelRule.ssh(tunnel).key)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        let id = tunnel.id
        guard tunnel.hooks?.hasCommand(.beforeConnect, supportsRemote: true) == true else {
            launchWhenPortAvailable(process, tunnel: tunnel)
            return
        }
        beforeStartTasks[id] = Task {
            let failure: String?
            do {
                try await runHook(tunnel, phase: .beforeConnect)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            beforeStartTasks.removeValue(forKey: id)
            if Task.isCancelled {
                resumeConnection(id)
                return
            }
            guard !isShuttingDown, shouldBeConnected.contains(id) else { return }
            if let failure {
                lastErrors[id] = failure
                connectionStatus[id] = .disconnected
                shouldBeConnected.remove(id)
                store.forgetEnabledProfile(TunnelRule.ssh(tunnel).key)
            } else {
                launchWhenPortAvailable(process, tunnel: tunnel)
            }
        }
    }

    private func launchWhenPortAvailable(_ process: Process, tunnel: SSHTunnel) {
        // Pre-flight: ssh can't bind a local port that's already taken, so don't
        // launch a doomed process — which would also fool the local-port probe
        // (the port reads as "open" because its real owner holds it) into a false
        // "connected" flap. Any previous process for this profile has already
        // exited, so an open port here means a different owner. Only
        // locally-bound forwards count — a remote forward (-R) binds on the
        // server, so its port isn't ours to check here.
        if let takenPort = tunnel.locallyBoundPorts.first(where: { isLocalPortOpen($0) }) {
            // Two whole sentences rather than one spliced from a " by …" fragment:
            // a translator can't reorder words around a pre-built fragment.
            let owners = localPortConflicts(for: tunnel)[takenPort]?.joined(separator: ", ")
            let reason: String
            if let owners {
                reason = L10n.text("Local port \(takenPort) is already in use by \(owners). Only one tunnel can bind it at a time.")
            } else {
                reason = L10n.text("Local port \(takenPort) is already in use. Only one tunnel can bind it at a time.")
            }
            lastErrors[tunnel.id] = reason
            connectionStatus[tunnel.id] = .connecting // keep retrying; self-heals once the port frees
            logger.error("SSHTunnel \"\(tunnel.name, privacy: .public)\" cannot bind local port \(takenPort) — already in use")
            return
        }

        launch(process, tunnel: tunnel)
    }

    /// Spawn a fully prepared tunnel process and wire up the establish probe,
    /// PID bookkeeping, and termination monitor. Shared by the default ssh and
    /// custom-command paths of startSSHProcess.
    private func launch(_ process: Process, tunnel: SSHTunnel) {
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let diagnostics = SSHDiagnostics()
        errorPipe.fileHandleForReading.readabilityHandler = { stream in
            let chunk = stream.availableData
            if chunk.isEmpty { stream.readabilityHandler = nil }
            else { diagnostics.append(chunk) }
        }
        let tunnelID = tunnel.id
        let journal = childJournal
        process.terminationHandler = { [weak self] child in
            let code = child.terminationStatus
            let bySignal = child.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in
                journal.remove(child)
                guard let self, self.processes[tunnelID] === child else { return }
                self.handleProcessTermination(tunnel, stderr: diagnostics.text,
                                              exitCode: code, terminatedBySignal: bySignal)
            }
        }

        do {
            try process.run()
            journal.record(process)
            processes[tunnelID] = process
            connectionStatus[tunnelID] = .connecting
            let probePort = tunnel.locallyBoundPorts.first
            Task { [weak self] in
                if let probePort {
                    for _ in 0..<150 {
                        try? await Task.sleep(for: .milliseconds(200))
                        let isUp = await Task.detached { isLocalPortOpen(probePort) }.value
                        guard let self, self.processes[tunnelID] === process, process.isRunning else { return }
                        if isUp {
                            self.markEstablished(tunnel)
                            return
                        }
                    }
                    guard let self, self.processes[tunnelID] === process, process.isRunning else { return }
                    self.markEstablished(tunnel)
                } else {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.processes[tunnelID] === process, process.isRunning else { return }
                    self.markEstablished(tunnel)
                }
            }
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lastErrors[tunnel.id] = error.localizedDescription
            connectionStatus[tunnel.id] = .connecting
        }
    }

    /// Mark a tunnel as genuinely up: clear any stale failure reason and, the
    /// first time it establishes, fire the connect cue. Shared by the local-port
    /// probe and the remote-forward survival path.
    private func markEstablished(_ tunnel: SSHTunnel) {
        let id = tunnel.id
        guard !isShuttingDown, !stopping.contains(id) else { return }
        connectionStatus[id] = .connected
        lastErrors.removeValue(forKey: id)
        guard establishedTunnels.insert(id).inserted else { return }
        TunnelFeedback.announce(.connected, name: tunnel.name, using: store)
        if tunnel.hooks?.hasCommand(.afterConnect, supportsRemote: true) == true {
            afterConnectTasks[id] = Task {
                do {
                    try await runHook(tunnel, phase: .afterConnect)
                } catch {
                    if !Task.isCancelled { lastErrors[id] = error.localizedDescription }
                }
                afterConnectTasks.removeValue(forKey: id)
            }
        }
    }

    private func runHook(_ tunnel: SSHTunnel, phase: TunnelHookPhase) async throws {
        try await TunnelHookRunner.run(tunnel.hooks, phase: phase) { command in
            SSHInvocation(tunnel: tunnel, host: tunnel.host.trimmingCharacters(in: .whitespaces),
                          remoteCommand: command)
        }
    }

    private func handleProcessTermination(_ tunnel: SSHTunnel, stderr: String, exitCode: Int32, terminatedBySignal: Bool) {
        let id = tunnel.id
        processes.removeValue(forKey: id)
        let manuallyStopped = stopping.remove(id) != nil
        let wasEstablished = establishedTunnels.remove(id) != nil
        let willReconnect = shouldBeConnected.contains(id)
        connectionStatus[id] = willReconnect ? .connecting : .disconnected
        let cleanStop = stderr.isEmpty && (exitCode == 0 || terminatedBySignal)
        if willReconnect && !manuallyStopped {
            if !cleanStop { lastErrors[id] = classifyFailure(stderr: stderr, exitCode: exitCode) }
            if wasEstablished {
                TunnelFeedback.announce(.disconnected(retrying: true), name: tunnel.name, using: store)
            }
        }

        let connectingHook = afterConnectTasks[id]
        connectingHook?.cancel()
        guard connectingHook != nil || tunnel.hooks?.hasCommand(.afterDisconnect, supportsRemote: true) == true else {
            if manuallyStopped { resumeConnection(id) }
            return
        }
        afterStopTasks[id] = Task {
            await connectingHook?.value
            do {
                try await runHook(tunnel, phase: .afterDisconnect)
            } catch {
                lastErrors[id] = error.localizedDescription
            }
            afterStopTasks.removeValue(forKey: id)
            if manuallyStopped { resumeConnection(id) }
        }
    }

    /// Best-effort mapping of ssh's stderr to a short, human-readable reason.
    /// OpenSSH wording isn't a stable API and varies by version/locale, so this
    /// degrades gracefully: a known phrase → a friendly line, otherwise the last
    /// non-empty stderr line, otherwise the exit code. It is never blank.
    private func classifyFailure(stderr: String, exitCode: Int32) -> String {
        let s = stderr.lowercased()
        if s.contains("permission denied")
            || s.contains("too many authentication failures")
            || s.contains("no more authentication methods") {
            return L10n.text("Authentication failed — check your key or identity file.")
        }
        if s.contains("connection refused") {
            return L10n.text("Connection refused — the SSH server may be down or on another port.")
        }
        if s.contains("operation timed out")
            || s.contains("connection timed out")
            || s.contains("no route to host")
            || s.contains("network is unreachable") {
            return L10n.text("Host unreachable — check the network or a firewall.")
        }
        if s.contains("could not resolve hostname")
            || s.contains("name or service not known")
            || s.contains("nodename nor servname") {
            return L10n.text("Couldn’t resolve the host name (DNS).")
        }
        if s.contains("host key verification failed")
            || s.contains("remote host identification has changed") {
            return L10n.text("Host key changed — enable “Skip host key check” if the host was recreated.")
        }
        if s.contains("address already in use") || s.contains("cannot listen to port") {
            return L10n.text("A local forward port is already in use.")
        }
        if s.contains("remote port forwarding failed") {
            return L10n.text("The server couldn’t bind the remote-forward port — it may already be in use there (or needs root for a port below 1024).")
        }
        if s.contains("administratively prohibited") || s.contains("open failed") {
            return L10n.text("The server refused the port forward.")
        }
        // Unknown wording — surface the last meaningful stderr line, else the code.
        if let line = stderr
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) {
            return line
        }
        return L10n.text("Disconnected unexpectedly (ssh exit \(exitCode)).")
    }

    func disconnect(tunnel: SSHTunnel, announce: Bool = true) {
        // Remove from auto-reconnect set and cancel any in-flight startup
        shouldBeConnected.remove(tunnel.id)
        beforeStartTasks[tunnel.id]?.cancel()
        let wasEstablished = establishedTunnels.remove(tunnel.id) != nil
        // A deliberate stop is not a failure — clear any recorded reason.
        lastErrors.removeValue(forKey: tunnel.id)

        if let process = processes[tunnel.id], stopping.insert(tunnel.id).inserted {
            stopProcess(process, signal: SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                stopProcess(process, signal: SIGKILL)
            }
        }
        connectionStatus[tunnel.id] = .disconnected
        if wasEstablished && announce {
            TunnelFeedback.announce(.disconnected(retrying: false), name: tunnel.name, using: store)
        }
    }

    func deleteTunnel(_ tunnel: SSHTunnel) {
        guard store.delete(TunnelRule.ssh(tunnel).key) else { return }
        if shouldBeConnected.contains(tunnel.id) || processes[tunnel.id] != nil {
            disconnect(tunnel: tunnel)
        }
    }

    func save(_ tunnel: SSHTunnel, in groupID: UUID? = nil, after previous: TunnelRule.Key? = nil) -> Bool {
        let existing = tunnels.first { $0.id == tunnel.id }
        guard store.save(.ssh(tunnel), in: groupID, after: previous) else { return false }
        // Reconfigure a live connection only when its settings changed.
        if let existing, !existing.hasSameConnection(as: tunnel),
           shouldBeConnected.contains(tunnel.id) || processes[tunnel.id] != nil {
            disconnect(tunnel: existing, announce: false)
            connect(tunnel: tunnel)
        }
        return true
    }

    func shutdown() async {
        isShuttingDown = true
        reconnectTask?.cancel()
        reconnectTask = nil
        shouldBeConnected.removeAll()
        establishedTunnels.removeAll()

        for task in Array(beforeStartTasks.values) + Array(afterConnectTasks.values) { task.cancel() }
        for process in processes.values { stopProcess(process, signal: SIGKILL) }
        for tunnel in tunnels { connectionStatus[tunnel.id] = .disconnected }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !processes.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for task in Array(beforeStartTasks.values) + Array(afterStopTasks.values) { await task.value }
    }
}
