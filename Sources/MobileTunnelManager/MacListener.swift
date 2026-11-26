import Darwin
import Foundation

struct PortConflict: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MacPortOwner: Identifiable {
    let id: pid_t
    let name: String
    fileprivate let identity: ProcessIdentity?
    fileprivate var listeners: [Int32: String] = [:]
    fileprivate var addresses: Set<String> = []

    var endpoints: String { addresses.sorted().joined(separator: ", ") }

    var canForceKill: Bool {
        id > 1 && id != getpid() && identity?.user == geteuid() && !listeners.isEmpty
    }
}

private struct ProcessIdentity: Equatable {
    let user: uid_t
    let seconds: UInt64
    let microseconds: UInt64

    static func read(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(user: info.pbi_uid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

enum MacListener {
    static func checkAvailability(port: Int) throws {
        guard let validPort = UInt16(exactly: port), validPort != 0 else {
            throw CommandError(message: L10n.text("The Mac listen port must be between 1 and 65535."))
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemError(port: port, code: errno) }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = validPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EADDRINUSE {
                throw PortConflict(message: L10n.text("Mac listen port \(String(port)) is in use. Choose another port or wait for the process to release it."))
            }
            throw systemError(port: port, code: code)
        }
    }

    static func owners(of port: Int) async throws -> [MacPortOwner] {
        guard (1...65535).contains(port) else {
            throw CommandError(message: L10n.text("The Mac listen port must be between 1 and 65535."))
        }
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        let output = try await ToolProcess.run(lsof, [
            "-nP", "-w", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "+c", "0", "-F0pcfn"
        ], emptyResultExitCode: 1)

        var owners: [pid_t: MacPortOwner] = [:]
        var process: pid_t?
        var command = ""
        var descriptor: Int32?
        for raw in output.split(separator: "\0") {
            let field = raw.drop(while: \.isNewline)
            let value = field.dropFirst()
            switch field.first {
            case "p":
                process = pid_t(value)
                command = ""
                descriptor = nil
            case "c":
                command = String(value)
            case "f":
                descriptor = Int32(value)
            case "n":
                guard let process, let descriptor else { continue }
                let matches = isListening(pid: process, descriptor: descriptor, port: port)
                let plausibleAddress = ["*:\(port)", "127.0.0.1:\(port)"].contains(String(value))
                guard matches == true || (matches == nil && plausibleAddress) else { continue }
                var owner = owners[process] ?? MacPortOwner(id: process, name: command.isEmpty ? L10n.text("Unknown process") : command,
                                                           identity: ProcessIdentity.read(process))
                let address = String(value)
                owner.addresses.insert(address)
                if matches == true { owner.listeners[descriptor] = address }
                owners[process] = owner
            default:
                break
            }
        }
        return owners.values.sorted { $0.id < $1.id }
    }

    static func forceKill(_ owner: MacPortOwner, port: Int) throws {
        guard owner.canForceKill else {
            throw CommandError(message: L10n.text("You can only force quit other processes you own that are confirmed to be listening on this port."))
        }
        do {
            try checkAvailability(port: port)
            throw CommandError(message: L10n.text("The port is now available."))
        } catch is PortConflict {
            guard owner.listeners.keys.contains(where: { isListening(pid: owner.id, descriptor: $0, port: port) == true }),
                  ProcessIdentity.read(owner.id) == owner.identity else {
                throw CommandError(message: L10n.text("The process or listener changed. Refresh the list and select it again."))
            }
            guard kill(owner.id, SIGKILL) == 0 else {
                let code = errno
                throw CommandError(message: L10n.text("Could not force quit \(owner.name): \(String(cString: strerror(code)))"))
            }
        }
    }

    private static func isListening(pid: pid_t, descriptor: Int32, port: Int) -> Bool? {
        var socketInfo = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &socketInfo, size) == size else { return nil }
        guard socketInfo.psi.soi_kind == SOCKINFO_TCP else { return false }
        let tcp = socketInfo.psi.soi_proto.pri_tcp
        let address = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        return tcp.tcpsi_state == TSI_S_LISTEN && localPort == port
            && Int32(tcp.tcpsi_ini.insi_vflag) & INI_IPV4 != 0
            && (address == INADDR_ANY || address == inet_addr("127.0.0.1"))
    }

    private static func systemError(port: Int, code: Int32) -> CommandError {
        CommandError(message: L10n.text("Could not check Mac listen port \(String(port)): \(String(cString: strerror(code)))"))
    }
}
