import Foundation

struct SocatForm: Codable, Equatable {
    enum Direction: String, CaseIterable, Codable, Identifiable {
        case bidirectional, leftToRight, rightToLeft

        var id: Self { self }
        var title: String {
            switch self {
            case .bidirectional: L10n.text("Bidirectional")
            case .leftToRight: L10n.text("Address 1 → Address 2")
            case .rightToLeft: L10n.text("Address 2 → Address 1")
            }
        }
        var flag: String? {
            switch self {
            case .bidirectional: nil
            case .leftToRight: "-u"
            case .rightToLeft: "-U"
            }
        }
        var arrow: String {
            switch self {
            case .bidirectional: "↔"
            case .leftToRight: "→"
            case .rightToLeft: "←"
            }
        }
    }

    var left = SocatAddress(kind: .tcpListen)
    var right = SocatAddress(kind: .tcpConnect)
    var direction = Direction.bidirectional
    var flags = ""
    struct ImportedDirection: Codable, Equatable {
        let indices: [Int]
        let flags: String
    }

    var importedDirection: ImportedDirection? = nil

    var route: String { "\(left.summary) \(direction.arrow) \(right.summary)" }
    var loopbackTCPPorts: [Int] {
        Set([left, right].compactMap(\.loopbackTCPPort)).sorted()
    }

    func argumentsForLaunch() throws -> [String] {
        var arguments = try ShellArguments.parse(flags)
        if let flag = direction.flag {
            let indices = importedDirection.flatMap { $0.flags == flags ? $0.indices : nil }
            for index in indices ?? [0] {
                arguments.insert(flag, at: min(max(index, 0), arguments.count))
            }
        }
        return arguments + [try left.argument(), try right.argument()]
    }
}

struct SocatAddress: Codable, Equatable {
    private enum OptionField: String, Codable {
        case bind, ipFamily, reuseAddress = "reuseaddr", fork
        case certificate = "cert", key, caFile = "cafile", additional
    }

    enum Kind: String, CaseIterable, Codable, Identifiable {
        case tcpListen = "TCP-LISTEN"
        case tcpConnect = "TCP"
        case udpReceive = "UDP-RECVFROM"
        case udpConnect = "UDP"
        case unixListen = "UNIX-LISTEN"
        case unixConnect = "UNIX-CONNECT"
        case tlsListen = "OPENSSL-LISTEN"
        case tlsConnect = "OPENSSL"
        case file = "OPEN"
        case stdio = "STDIO"
        case custom

        var id: Self { self }
        var title: String {
            switch self {
            case .tcpListen: L10n.text("TCP Listen")
            case .tcpConnect: L10n.text("TCP Connect")
            case .udpReceive: L10n.text("UDP Receive and Reply")
            case .udpConnect: L10n.text("UDP Connect")
            case .unixListen: L10n.text("Unix Socket Listen")
            case .unixConnect: L10n.text("Unix Socket Connect")
            case .tlsListen: L10n.text("TLS Listen")
            case .tlsConnect: L10n.text("TLS Connect")
            case .file: L10n.text("File")
            case .stdio: L10n.text("Standard Input / Output")
            case .custom: L10n.text("Custom Address")
            }
        }

        var bindsPort: Bool { self == .tcpListen || self == .udpReceive || self == .tlsListen }
        var connectsToHost: Bool { self == .tcpConnect || self == .udpConnect || self == .tlsConnect }
        var usesPort: Bool { bindsPort || connectsToHost }
        var usesPath: Bool { self == .unixListen || self == .unixConnect || self == .file }
        var usesTLS: Bool { self == .tlsConnect || self == .tlsListen }
        var acceptsFork: Bool { bindsPort || self == .unixListen }
        var acceptsReuseAddress: Bool { bindsPort }
    }

    var kind: Kind
    var host = "127.0.0.1"
    var port = ""
    var bind = "127.0.0.1"
    var path = ""
    var fork = true
    var reuseAddress = true
    var certificate = ""
    var key = ""
    var caFile = ""
    var custom = ""
    var options = ""
    private var importedKeyword: String? = nil
    private var importedOptionOrder: [OptionField]? = nil

    init(kind: Kind) {
        self.kind = kind
    }

    var summary: String {
        if kind.bindsPort { return "\(kind.title) :\(port)" }
        if kind.connectsToHost { return "\(networkHost(host)):\(port)" }
        if kind.usesPath && !path.isEmpty { return (path as NSString).lastPathComponent }
        return kind.title
    }

    func argument() throws -> String {
        if kind == .custom {
            let address = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isAddressArgument(address) else {
                throw CommandError(message: L10n.text("Enter a valid socat address."))
            }
            return address
        }

        let values = [host, port, bind, path, certificate, key, caFile, options]
        guard values.allSatisfy({ !$0.contains("\0") }) else {
            throw CommandError(message: L10n.text("The address cannot contain NUL."))
        }
        let keyword = importedKeyword.flatMap { Kind.importKind($0) == kind ? $0 : nil }
        var address = keyword ?? kind.rawValue
        var parts: [(OptionField, String)] = []
        if kind.usesPort {
            guard let number = portNumber else {
                throw CommandError(message: L10n.text("The port must be between 1 and 65535."))
            }
            if kind.connectsToHost {
                let name = host.trimmingCharacters(in: .whitespaces)
                guard Self.isNetworkHost(name) else {
                    throw CommandError(message: L10n.text("Enter a host name or IP address."))
                }
                address += ":\(networkHost(name))"
                if name.contains(":"), importedOptionOrder == nil { parts.append((.ipFamily, "pf=ip6")) }
            }
            address += ":\(number)"
        } else if kind.usesPath {
            guard !path.isEmpty else { throw CommandError(message: L10n.text("Enter a file or socket path.")) }
            address += ":" + Self.escape(path)
        }

        if kind.bindsPort {
            let name = bind.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                guard Self.isNetworkHost(name) else {
                    throw CommandError(message: L10n.text("Enter a valid bind address."))
                }
                parts.append((.bind, "bind=" + networkHost(name)))
                if name.contains(":"), importedOptionOrder == nil { parts.append((.ipFamily, "pf=ip6")) }
            }
        }
        if kind.acceptsReuseAddress && reuseAddress { parts.append((.reuseAddress, "reuseaddr")) }
        if kind.acceptsFork && fork { parts.append((.fork, "fork")) }
        if kind.usesTLS {
            if !certificate.isEmpty { parts.append((.certificate, "cert=" + Self.escape(certificate))) }
            if !key.isEmpty { parts.append((.key, "key=" + Self.escape(key))) }
            if !caFile.isEmpty { parts.append((.caFile, "cafile=" + Self.escape(caFile))) }
        }
        let extra = options.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([address] + orderedOptions(parts, extra: extra)).joined(separator: ",")
    }

    private func orderedOptions(_ fields: [(OptionField, String)], extra: String) -> [String] {
        guard let importedOptionOrder else {
            return fields.map(\.1) + (extra.isEmpty ? [] : [extra])
        }
        var pending = Dictionary(uniqueKeysWithValues: fields)
        var extraOptions = ArraySlice(extra.isEmpty ? [] : SocatAddressSyntax.split(extra, at: [","]) ?? [extra])
        let original = importedOptionOrder.compactMap { field in
            field == .additional ? extraOptions.popFirst() : pending.removeValue(forKey: field)
        }
        return original + fields.compactMap { pending[$0.0] } + Array(extraOptions)
    }

    private func networkHost(_ value: String) -> String {
        value.contains(":") && !value.hasPrefix("[") ? "[\(value)]" : value
    }

    var loopbackTCPPort: Int? {
        guard (kind == .tcpListen || kind == .tlsListen), options.isEmpty,
              bind.trimmingCharacters(in: .whitespaces) == "127.0.0.1" else { return nil }
        return portNumber
    }

    private var portNumber: Int? {
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(number) else { return nil }
        return number
    }

    private static func isNetworkHost(_ value: String) -> Bool {
        let bracketed = value.hasPrefix("[") && value.hasSuffix("]")
        let name = bracketed ? value.dropFirst().dropLast() : value[...]
        if bracketed && !name.contains(":") { return false }
        return !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-:%".unicodeScalars.contains($0)
        }
    }

    private static func escape(_ value: String) -> String {
        // These delimiters belong to Socat's address grammar, independently of shell quoting.
        value.map { "\\\"'`!,:[](){}".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

extension SocatAddress {
    static func isAddressArgument(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else { return false }
        return !value.hasPrefix("-") || value == "-" || [",", ":", "!", "%"].contains(value.dropFirst().first)
    }

    static func importing(_ argument: String) -> Self {
        if let parsed = structuredAddress(argument), (try? parsed.argument()) == argument { return parsed }
        var address = Self(kind: .custom)
        address.custom = argument
        return address
    }

    private static func structuredAddress(_ argument: String) -> Self? {
        guard SocatAddressSyntax.split(argument, at: ["!", "%", "|"])?.count == 1,
              let tokens = SocatAddressSyntax.split(argument, at: [","]),
              let head = tokens.first,
              let parameters = SocatAddressSyntax.split(head, at: [":"]),
              let keyword = parameters.first,
              let kind = Kind.importKind(keyword) else { return nil }

        var address = Self(kind: kind)
        address.importedKeyword = keyword == kind.rawValue ? nil : keyword
        address.bind = ""
        address.fork = false
        address.reuseAddress = false
        if kind.connectsToHost {
            guard parameters.count == 3 else { return nil }
            address.host = parameters[1]
            address.port = parameters[2]
        } else if kind.bindsPort {
            guard parameters.count == 2 else { return nil }
            address.port = parameters[1]
        } else if kind.usesPath {
            guard parameters.count == 2, let path = unescape(parameters[1]) else { return nil }
            address.path = path
        } else if parameters.count != 1 {
            return nil
        }

        let optionTokens = tokens.dropFirst()
        let occurrences = Dictionary(grouping: optionTokens) { $0.prefix(while: { $0 != "=" }).lowercased() }
        var order: [OptionField] = []
        var extra: [String] = []
        for token in optionTokens {
            let name = String(token.prefix(while: { $0 != "=" }))
            let field = occurrences[name.lowercased()]?.count == 1 ? address.importOption(token, name: name) : nil
            order.append(field ?? .additional)
            if field == nil { extra.append(token) }
        }
        address.importedOptionOrder = order
        address.options = extra.joined(separator: ",")
        return address
    }

    private mutating func importOption(_ token: String, name: String) -> OptionField? {
        guard let field = OptionField(rawValue: name) else { return nil }
        let value = String(token.dropFirst(name.count + 1))
        switch field {
        case .bind where kind.bindsPort:
            guard token != name, Self.isNetworkHost(value), networkHost(value) == value else { return nil }
            bind = value
        case .fork where kind.acceptsFork && token == name:
            fork = true
        case .reuseAddress where kind.acceptsReuseAddress && token == name:
            reuseAddress = true
        case .certificate, .key, .caFile:
            guard kind.usesTLS, token != name, let path = Self.unescape(value), !path.isEmpty else { return nil }
            switch field {
            case .certificate: certificate = path
            case .key: key = path
            default: caFile = path
            }
        default: return nil
        }
        return field
    }

    private static func unescape(_ text: String) -> String? {
        var value = ""
        var escaped = false
        for character in text {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                value.append(character)
            }
        }
        return !escaped && escape(value) == text ? value : nil
    }
}

private extension SocatAddress.Kind {
    static func importKind(_ keyword: String) -> Self? {
        switch keyword.uppercased() {
        case "-": .stdio
        case "TCP-CONNECT": .tcpConnect
        case "UDP-CONNECT": .udpConnect
        case "OPENSSL-CONNECT": .tlsConnect
        default: Self(rawValue: keyword.uppercased())
        }
    }
}

private enum SocatAddressSyntax {
    // Split only at socat delimiters outside quoted, escaped, or nested values.
    static func split(_ input: String, at separators: Set<Character>) -> [String]? {
        let closing: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        var parts = [""]
        for character in input {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if let delimiter = closing[character] {
                stack.append(delimiter)
            } else if closing.values.contains(character) {
                guard stack.popLast() == character else { return nil }
            } else if stack.isEmpty && separators.contains(character) {
                parts.append("")
                continue
            }
            parts[parts.count - 1].append(character)
        }
        return !escaped && quote == nil && stack.isEmpty ? parts : nil
    }
}
