import Foundation

struct TunnelConfiguration: Codable {
    static let currentVersion = 2

    struct Preferences: Codable {
        var restoreOnLaunch = false
        var connectionSounds = true
        var connectionNotifications = false

        private enum CodingKeys: String, CodingKey {
            // Keep the existing keys so previous configurations retain their preferences.
            case restoreOnLaunch = "restoreDeviceRulesOnLaunch"
            case connectionSounds = "sshSounds"
            case connectionNotifications = "sshNotifications"
        }
    }

    var version = Self.currentVersion
    var preferences = Preferences()
    var rules: [TunnelRule] = []
    var groups: [ProfileGroup] = []
    var lastEnabledProfiles: [TunnelRule.Key]?

    var rememberedEnabledProfiles: Set<TunnelRule.Key> {
        if let lastEnabledProfiles { return Set(lastEnabledProfiles) }
        return Set(rules.compactMap {
            if case .device(_, true) = $0 { return $0.key }
            return nil
        })
    }

    private enum CodingKeys: String, CodingKey {
        case version, preferences, rules, groups, lastEnabledProfiles
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == Self.currentVersion else {
            throw CommandError(message: L10n.text("This version of the app cannot read configuration version \(storedVersion)."))
        }
        preferences = try container.decode(Preferences.self, forKey: .preferences)
        if storedVersion == 1 {
            appendLegacy(try container.decode([LegacyTunnelEntry].self, forKey: .rules))
        } else {
            rules = try container.decode([TunnelRule].self, forKey: .rules)
            groups = try container.decodeIfPresent([ProfileGroup].self, forKey: .groups) ?? []
        }
        if let saved = try container.decodeIfPresent([TunnelRule.Key].self, forKey: .lastEnabledProfiles) {
            let profileKeys = Set(rules.map(\.key))
            lastEnabledProfiles = saved.filter(profileKeys.contains)
        }
        try verify()
    }

    mutating func appendLegacy(_ entries: [LegacyTunnelEntry]) {
        var current: Int?
        for entry in entries {
            switch entry {
            case .group(let group):
                groups.append(group)
                current = groups.indices.last
            case .profile(let profile):
                rules.append(profile)
                if let current, profile.kind == .ssh { groups[current].profiles.append(profile.key) }
            }
        }
    }

    func verify() throws {
        let keys = Set(rules.map(\.key))
        let members = groups.flatMap(\.profiles)
        guard keys.count == rules.count, Set(groups.map(\.id)).count == groups.count,
              Set(members).count == members.count, members.allSatisfy(keys.contains) else {
            throw CommandError(message: L10n.text("The configuration contains duplicate profiles or invalid group members."))
        }
    }
}

struct ProfileGroup: Identifiable, Codable {
    var id = UUID()
    var title: String
    var profiles: [TunnelRule.Key] = []

    var displayName: String { title.isEmpty ? L10n.text("Unnamed Group") : title }
}

enum LegacyTunnelEntry: Decodable {
    case group(ProfileGroup)
    case profile(TunnelRule)

    private enum CodingKeys: String, CodingKey { case type, settings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "sshGroup" {
            let group = try container.decode(GroupDivider.self, forKey: .settings)
            self = .group(ProfileGroup(id: group.id, title: group.title))
        } else {
            self = .profile(try TunnelRule(from: decoder))
        }
    }

    init(sshItem: SidebarItem) {
        switch sshItem {
        case .tunnel(let tunnel): self = .profile(.ssh(tunnel))
        case .divider(let group): self = .group(ProfileGroup(id: group.id, title: group.title))
        }
    }
}

enum TunnelRule: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case device, ssh, socat

        var id: Self { self }
        var title: String {
            switch self {
            case .device: L10n.text("Device")
            case .ssh: "SSH"
            case .socat: "socat"
            }
        }
        var icon: String {
            switch self {
            case .device: "iphone"
            case .ssh: "terminal"
            case .socat: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    struct Key: Hashable, Codable {
        var type: Kind
        var id: UUID
    }

    case device(DeviceTunnel, enabled: Bool)
    case ssh(SSHTunnel)
    case socat(SocatProfile)

    var kind: Kind {
        switch self {
        case .device: .device
        case .ssh: .ssh
        case .socat: .socat
        }
    }

    var id: UUID {
        switch self {
        case .device(let tunnel, _): tunnel.id
        case .ssh(let tunnel): tunnel.id
        case .socat(let profile): profile.id
        }
    }

    var key: Key { Key(type: kind, id: id) }

    var startsOnLaunch: Bool {
        switch self {
        case .device: false
        case .ssh(let tunnel): tunnel.autoConnect
        case .socat(let profile): profile.autoStart
        }
    }

    var name: String {
        switch self {
        case .device(let tunnel, _): tunnel.name
        case .ssh(let tunnel): tunnel.name
        case .socat(let profile): profile.name
        }
    }

    var route: String {
        switch self {
        case .device(let tunnel, _): tunnel.route
        case .ssh(let tunnel): tunnel.mappingsSummary
        case .socat(let profile): profile.routeSummary
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, settings, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .device:
            self = .device(try container.decode(DeviceTunnel.self, forKey: .settings),
                           enabled: try container.decode(Bool.self, forKey: .enabled))
        case .ssh:
            self = .ssh(try container.decode(SSHTunnel.self, forKey: .settings))
        case .socat:
            self = .socat(try container.decode(SocatProfile.self, forKey: .settings))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .device(let tunnel, let enabled):
            try container.encode(tunnel, forKey: .settings)
            try container.encode(enabled, forKey: .enabled)
        case .ssh(let tunnel):
            try container.encode(tunnel, forKey: .settings)
        case .socat(let profile):
            try container.encode(profile, forKey: .settings)
        }
    }

}
