import Foundation

struct SSHInvocation {
    let executable: String
    let arguments: [String]

    init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    init(tunnel: SSHTunnel, host: String, remoteCommand: String? = nil) {
        self = Self.make(tunnel: tunnel, host: host, remoteCommand: remoteCommand)
    }

    static func hookCommand(_ command: String) -> String {
        shellCommand(["/bin/sh", "-c", command])
    }

    var shellCommand: String { Self.shellCommand([executable] + arguments) }

    static func shellCommand(_ arguments: [String]) -> String {
        arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    private static func make(tunnel: SSHTunnel, host: String, remoteCommand: String?) -> Self {
        // One forward flag per port mapping — -L for a local forward, -R for a
        // remote forward, -D for a SOCKS proxy — all carried by a single ssh
        // process.
        var forwardArguments: [String] = []
        for mapping in tunnel.portMappings {
            switch mapping.forward {
            case .local:
                forwardArguments.append(contentsOf: [
                    "-L", "\(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
                ])
            case .remote:
                // ssh -R [bind_address:]port:host:hostport. Fields stay consistent
                // with -L/-D — Local* is always this Mac, Remote* the far side — so
                // the server binds the Remote address and forwards back to the Local
                // host:port here. (That's the reverse of -L's data direction.)
                forwardArguments.append(contentsOf: [
                    "-R", "\(mapping.remoteHost):\(mapping.remotePort):\(mapping.localHost):\(mapping.localPort)"
                ])
            case .dynamic:
                forwardArguments.append(contentsOf: [
                    "-D", "\(mapping.localHost):\(mapping.localPort)"
                ])
            }
        }


        // Custom command mode (e.g. "/opt/homebrew/bin/tsh ssh"): first token is
        // the executable, the rest lead the arguments. Pass only -N, the
        // forwards, extraOptions, and the host — the OpenSSH-specific options in
        // the default branch below can be rejected by a non-OpenSSH client (tsh
        // hard-errors on RemoteCommand=none), so anything else the client
        // supports goes through extraOptions.
        let command = remoteCommand.map { [hookCommand($0)] } ?? []
        if let custom = tunnel.customCommand?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            var tokens = custom.split(whereSeparator: \.isWhitespace).map(String.init)
            let executable = (tokens.removeFirst() as NSString).expandingTildeInPath
            var arguments = tokens + (remoteCommand == nil ? ["-N"] + forwardArguments : [])
            if let extra = tunnel.extraOptions?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
                arguments.append(contentsOf: extra.split(whereSeparator: \.isWhitespace).map(String.init))
            }
            arguments.append(host)
            arguments.append(contentsOf: command)
            return Self(executable: executable, arguments: arguments)
        }

        var arguments = remoteCommand == nil ? ["-N"] + forwardArguments : [
            "-T", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
            "-o", "RemoteCommand=none", "-o", "BatchMode=yes", "-o", "RequestTTY=no"
        ]

        // Connection options. In host mode always pass -p (and -i if set); in
        // alias mode let ~/.ssh/config supply them, overriding -p only for a
        // non-default port.
        if !tunnel.useAlias, let identityFile = tunnel.identityFile, !identityFile.isEmpty {
            arguments.append(contentsOf: ["-i", (identityFile as NSString).expandingTildeInPath])
            // Use only this key — don't also offer every key in the ssh-agent,
            // which can trip the server's auth-attempt limit ("Too many
            // authentication failures") before the right key is reached.
            arguments.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
        }
        // Only host mode passes -p, and only for a non-default port. In alias
        // mode ~/.ssh/config supplies the port — otherwise a stale port left over
        // from host mode (the field is hidden in alias mode) would silently
        // override the alias. (issue #10)
        if !tunnel.useAlias && tunnel.port != 22 {
            arguments.append(contentsOf: ["-p", "\(tunnel.port)"])
        }
        if tunnel.compression {
            arguments.append("-C")
        }
        if tunnel.disableTCPKeepAlive {
            arguments.append(contentsOf: ["-o", "TCPKeepAlive=no"])
        }
        if tunnel.skipHostKeyCheck {
            arguments.append(contentsOf: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null"
            ])
        }
        if let proxyJump = tunnel.proxyJump?.trimmingCharacters(in: .whitespaces), !proxyJump.isEmpty {
            arguments.append(contentsOf: ["-J", proxyJump])
        }
        // User-supplied extra options, split on whitespace. A power-user escape
        // hatch for flags the UI doesn't expose; goes before the destination so
        // ssh parses them as options. (issue #9)
        if let extra = tunnel.extraOptions?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
            arguments.append(contentsOf: extra.split(whereSeparator: \.isWhitespace).map(String.init))
        }

        // Set defaults before the destination. Forcing a dedicated,
        // forward-only connection (RequestTTY / RemoteCommand / ControlMaster /
        // ControlPath) stops login-oriented alias directives from allocating a
        // TTY, running a remote shell, or piggybacking on an existing master
        // socket and making ssh exit early — which the monitor would see as a
        // drop and respawn, causing the tunnel to flap.
        arguments.append(contentsOf: [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=\(tunnel.serverAliveInterval ?? SSHTunnel.defaultServerAliveInterval)",
            "-o", "ServerAliveCountMax=\(tunnel.serverAliveCountMax ?? SSHTunnel.defaultServerAliveCountMax)",
            // Retry the initial connection a couple of times before giving up,
            // and never block on an interactive prompt the GUI can't answer.
            "-o", "ConnectionAttempts=2",
            "-o", "BatchMode=yes",
            "-o", "RequestTTY=no",
            "-o", "RemoteCommand=none",
            "-o", "ControlMaster=no"
        ])
        // Attach to a user-established master socket (issue #18): the user
        // authenticates once in a terminal (password, TOTP/Duo — prompts the
        // GUI can't answer), and this forward rides that connection with no
        // auth at all. ControlMaster stays "no" so the app never creates a
        // master, and BatchMode stays on — with no live master, ssh falls back
        // to normal auth and fails fast with a visible reason instead of
        // hanging on a prompt.
        if let controlPath = tunnel.controlPath?.trimmingCharacters(in: .whitespaces), !controlPath.isEmpty {
            arguments.append(contentsOf: [
                "-o", "ControlPath=\((controlPath as NSString).expandingTildeInPath)"
            ])
        } else {
            arguments.append(contentsOf: ["-o", "ControlPath=none"])
        }
        if let connectTimeout = tunnel.connectTimeout {
            arguments.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeout)"])
        }

        arguments.append(contentsOf: ["--", host] + command)
        return Self(executable: "/usr/bin/ssh", arguments: arguments)
    }
}
