import Foundation

struct SocatLaunch {
    let executable: URL
    let arguments: [String]
    let superviseRemote: Bool
    let usesLocalSudo: Bool
    let environment: [String: String]?

    init(profile: SocatProfile, override: [String]? = nil, allowPasswordPrompt: Bool = false,
         readyMarker: String? = nil) throws {
        let arguments = try override ?? profile.argumentsForLaunch()
        guard !arguments.isEmpty else { throw CommandError(message: L10n.text("Enter socat arguments. Use -hhh to view help.")) }
        let custom = profile.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.contains("\0"), !custom.hasPrefix("-") else {
            throw CommandError(message: L10n.text("Invalid socat executable."))
        }

        let useSudo = profile.runsWithSudo && override == nil
        usesLocalSudo = useSudo && profile.destination == .local
        switch profile.destination {
        case .local:
            guard let url = custom.isEmpty ? DeviceTools.locate("socat") : Self.localExecutable(custom) else {
                throw CommandError(message: L10n.text("No executable socat was found. Install it with brew install socat or enter an absolute path."))
            }
            superviseRemote = false
            if useSudo {
                executable = URL(fileURLWithPath: "/usr/bin/sudo")
                let option = allowPasswordPrompt ? "-A" : "-n"
                self.arguments = [option, "--", url.path] + arguments
                environment = allowPasswordPrompt ? try SocatAskPass.environment() : nil
            } else {
                executable = url
                self.arguments = arguments
                environment = nil
            }
        case .ssh:
            let useTTY = profile.sshTTY && override == nil
            superviseRemote = profile.input == .closed && !useTTY && override == nil
            environment = nil
            let socat = [custom.isEmpty ? "socat" : custom] + arguments
            let command = useSudo ? ["sudo", "-n", "--"] + socat : socat
            var remote = superviseRemote
                ? ShellArguments.command(["sh", "-c", Self.supervisor, "socat-session"] + command)
                : "exec " + ShellArguments.command(command)
            var readiness: [String] = []
            if let readyMarker {
                if useTTY {
                    // A PTY merges remote stderr with data. Report readiness on local stderr instead.
                    readiness = ["-o", "PermitLocalCommand=yes",
                                 "-o", "LocalCommand=/usr/bin/echo \(readyMarker) >&2"]
                } else {
                    remote = "printf '%s\\n' \(ShellArguments.quote(readyMarker)) >&2; " + remote
                }
            }
            let invocation = try Self.ssh(profile, command: remote, useTTY: useTTY, isHook: false,
                                          prefixOptions: readiness)
            executable = URL(fileURLWithPath: invocation.executable)
            self.arguments = invocation.arguments
        }
    }

    static func hook(_ profile: SocatProfile, command: String) throws -> SSHInvocation {
        try ssh(profile, command: SSHInvocation.hookCommand(command), useTTY: false, isHook: true)
    }

    private static func ssh(_ profile: SocatProfile, command: String,
                            useTTY: Bool, isHook: Bool, prefixOptions: [String] = []) throws -> SSHInvocation {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: \.isWhitespace),
              !host.contains("\0") else {
            throw CommandError(message: L10n.text("Enter a valid SSH host or configuration alias."))
        }
        let options = try ShellArguments.parse(profile.sshOptions)
        var arguments = isHook ? ["-o", "PermitLocalCommand=no", "-o", "ClearAllForwardings=yes",
                                  "-o", "BatchMode=yes", "-o", "RemoteCommand=none", "-o", "RequestTTY=no"] : []
        arguments += prefixOptions + options + [useTTY ? "-tt" : "-T", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none", "--", host, command]
        return SSHInvocation(executable: "/usr/bin/ssh", arguments: arguments)
    }

    private static func localExecutable(_ value: String) -> URL? {
        let path = (value as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let supervisor = #"""
    exec 3<&0
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null 3<&- &
        worker=$!
        target=-$worker
    else
        "$@" </dev/null 3<&- &
        worker=$!
        target=$worker
    fi
    (
        trap 'exit 0' TERM HUP INT
        while IFS= read -r line <&3; do :; done
        kill -TERM -- "$target" 2>/dev/null || kill -TERM "$worker" 2>/dev/null
    ) >/dev/null 2>&1 &
    watcher=$!
    trap 'kill -TERM -- "$target" 2>/dev/null || kill -TERM "$worker" 2>/dev/null; kill "$watcher" 2>/dev/null; exit 143' HUP INT TERM
    wait "$worker"
    status=$?
    kill "$watcher" 2>/dev/null
    exit "$status"
    """#
}
