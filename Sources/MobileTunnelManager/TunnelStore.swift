import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class TunnelStore {
    private(set) var configuration = TunnelConfiguration()
    private(set) var error: String?
    private(set) var canEdit = true

    let directory: URL
    private let url: URL
    private let lockURL: URL
    private var lastSaved: Data?

    init(appSupport: URL = .applicationSupportDirectory, defaults: UserDefaults = .standard) {
        directory = appSupport.appendingPathComponent("UniversalTunnelManager", isDirectory: true)
        url = directory.appendingPathComponent("tunnels.json")
        lockURL = directory.appendingPathComponent("tunnels.lock")
        do {
            try withLock {
                if let existing = try Self.readIfPresent(url) {
                    configuration = try JSONDecoder().decode(TunnelConfiguration.self, from: existing)
                    lastSaved = existing
                    if Self.containsLegacySSHCommand(in: existing) {
                        do { try write(configuration) }
                        catch {
                            self.error = L10n.text("Could not save the tunnel configuration: \(error.localizedDescription)")
                        }
                    }
                } else {
                    let migrated = try migrate(appSupport: appSupport, defaults: defaults)
                    try migrated.configuration.verify()
                    if migrated.hasLegacyData { try write(migrated.configuration) }
                    configuration = migrated.configuration
                }
            }
        } catch {
            self.error = L10n.text("Could not read the tunnel configuration: \(error.localizedDescription)")
            canEdit = false
        }
    }

    var deviceTunnels: [DeviceTunnel] {
        configuration.rules.compactMap {
            if case .device(let tunnel, _) = $0 { return tunnel }
            return nil
        }
    }

    var sshTunnels: [SSHTunnel] {
        configuration.rules.compactMap {
            if case .ssh(let tunnel) = $0 { return tunnel }
            return nil
        }
    }

    var socatProfiles: [SocatProfile] {
        configuration.rules.compactMap {
            if case .socat(let profile) = $0 { return profile }
            return nil
        }
    }

    var ungrouped: [TunnelRule] {
        let members = Set(configuration.groups.flatMap(\.profiles))
        return configuration.rules.filter { !members.contains($0.key) }
    }

    func profiles(in group: ProfileGroup) -> [TunnelRule] {
        let rules = Dictionary(uniqueKeysWithValues: configuration.rules.map { ($0.key, $0) })
        return group.profiles.compactMap { rules[$0] }
    }

    func group(for key: TunnelRule.Key) -> ProfileGroup? {
        configuration.groups.first { $0.profiles.contains(key) }
    }

    @discardableResult
    func save(_ profile: TunnelRule, in groupID: UUID? = nil, after previous: TunnelRule.Key? = nil) -> Bool {
        update { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.key == profile.key }) {
                configuration.rules[index] = profile
                return
            }
            if let previous, let index = configuration.rules.firstIndex(where: { $0.key == previous }) {
                configuration.rules.insert(profile, at: index + 1)
            } else {
                configuration.rules.append(profile)
            }
            guard let index = configuration.groups.firstIndex(where: { $0.id == groupID }) else { return }
            if let previous, let position = configuration.groups[index].profiles.firstIndex(of: previous) {
                configuration.groups[index].profiles.insert(profile.key, at: position + 1)
            } else {
                configuration.groups[index].profiles.append(profile.key)
            }
        }
    }

    @discardableResult
    func delete(_ key: TunnelRule.Key) -> Bool {
        update { configuration in
            configuration.rules.removeAll { $0.key == key }
            configuration.lastEnabledProfiles?.removeAll { $0 == key }
            for index in configuration.groups.indices {
                configuration.groups[index].profiles.removeAll { $0 == key }
            }
        }
    }

    func saveGroup(_ group: ProfileGroup) -> Bool {
        update { configuration in
            if let index = configuration.groups.firstIndex(where: { $0.id == group.id }) {
                configuration.groups[index].title = group.title
            } else {
                configuration.groups.append(group)
            }
        }
    }

    func deleteGroup(_ id: UUID) {
        update { $0.groups.removeAll { $0.id == id } }
    }

    @discardableResult
    func move(_ key: TunnelRule.Key, to groupID: UUID?, before next: TunnelRule.Key? = nil) -> Bool {
        let destination = configuration.groups.firstIndex { $0.id == groupID }
        guard let ruleIndex = configuration.rules.firstIndex(where: { $0.key == key }),
              groupID == nil || destination != nil, next != key else { return false }
        let original = destination.map { configuration.groups[$0].profiles } ?? ungrouped.map(\.key)
        guard next == nil || original.contains(where: { $0 == next }) else { return false }
        var ordered = original.filter { $0 != key }
        let insertion = next.flatMap { ordered.firstIndex(of: $0) } ?? ordered.endIndex
        ordered.insert(key, at: insertion)
        guard ordered != original else { return false }
        return update { configuration in
            if let source = configuration.groups.firstIndex(where: { $0.profiles.contains(key) }) {
                configuration.groups[source].profiles.removeAll { $0 == key }
            }
            if let destination {
                configuration.groups[destination].profiles = ordered
            } else {
                let rule = configuration.rules.remove(at: ruleIndex)
                let index = next.flatMap { target in configuration.rules.firstIndex { $0.key == target } }
                    ?? configuration.rules.endIndex
                configuration.rules.insert(rule, at: index)
            }
        }
    }

    func moveGroup(_ id: UUID, offset: Int) {
        let groups = configuration.groups
        guard let source = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = source + offset
        guard groups.indices.contains(target), target != source else { return }
        let next = groups.dropFirst(target > source ? target + 1 : target).first?.id
        moveGroup(id, before: next)
    }

    func moveGroup(_ id: UUID, before next: UUID?) {
        var groups = configuration.groups
        guard id != next, let source = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: source)
        let destination: Int
        if let next {
            guard let index = groups.firstIndex(where: { $0.id == next }) else { return }
            destination = index
        } else {
            destination = groups.endIndex
        }
        guard destination != source else { return }
        groups.insert(group, at: destination)
        update { $0.groups = groups }
    }

    func reorder(_ keys: [TunnelRule.Key], in groupID: UUID?) {
        update { configuration in
            if let index = configuration.groups.firstIndex(where: { $0.id == groupID }) {
                configuration.groups[index].profiles = keys
            } else {
                let ungrouped = Set(keys)
                let profiles = Dictionary(uniqueKeysWithValues: configuration.rules.map { ($0.key, $0) })
                configuration.rules.removeAll { ungrouped.contains($0.key) }
                configuration.rules.append(contentsOf: keys.compactMap { profiles[$0] })
            }
        }
    }

    @discardableResult
    func setPreference(_ keyPath: WritableKeyPath<TunnelConfiguration.Preferences, Bool>, _ value: Bool) -> Bool {
        update { $0.preferences[keyPath: keyPath] = value }
    }

    func rememberEnabledProfiles(_ enabled: Set<TunnelRule.Key>) {
        guard enabled != configuration.rememberedEnabledProfiles else { return }
        update { configuration in
            configuration.lastEnabledProfiles = configuration.rules.map(\.key).filter(enabled.contains)
            configuration.rules = configuration.rules.map { rule in
                if case .device(let tunnel, _) = rule { return .device(tunnel, enabled: enabled.contains(rule.key)) }
                return rule
            }
        }
    }

    func forgetEnabledProfile(_ key: TunnelRule.Key) {
        rememberEnabledProfiles(configuration.rememberedEnabledProfiles.subtracting([key]))
    }

    func importRules(from url: URL) throws -> Int {
        guard canEdit else { throw CommandError(message: error ?? L10n.text("Could not change the tunnel configuration.")) }
        let incoming = try Self.readImport(Data(contentsOf: url))
        var existing = Set(configuration.rules.map(\.key))
        let added = incoming.rules.compactMap { rule -> TunnelRule? in
            guard existing.insert(rule.key).inserted else { return nil }
            switch rule {
            case .device(let tunnel, _): return .device(tunnel, enabled: false)
            case .ssh(var tunnel):
                tunnel.autoConnect = false
                return .ssh(tunnel)
            case .socat(var profile):
                profile.autoStart = false
                return .socat(profile)
            }
        }
        let newKeys = Set(added.map(\.key))
        let groupIDs = Set(configuration.groups.map(\.id))
        let addedGroupCount = incoming.groups.filter { !groupIDs.contains($0.id) }.count
        guard !added.isEmpty || addedGroupCount > 0 else { return 0 }
        let saved = update { configuration in
            configuration.rules.append(contentsOf: added)
            for var group in incoming.groups {
                group.profiles = group.profiles.filter(newKeys.contains)
                if let index = configuration.groups.firstIndex(where: { $0.id == group.id }) {
                    configuration.groups[index].profiles.append(contentsOf: group.profiles)
                } else {
                    configuration.groups.append(group)
                }
            }
        }
        if !saved {
            throw CommandError(message: error ?? L10n.text("Could not save the imported configuration."))
        }
        return added.count + addedGroupCount
    }

    func exportData() throws -> Data {
        guard canEdit else { throw CommandError(message: error ?? L10n.text("Could not read the tunnel configuration.")) }
        return try Self.encode(configuration)
    }

    @discardableResult
    private func update(_ edit: (inout TunnelConfiguration) -> Void) -> Bool {
        guard canEdit else { return false }
        var updated = configuration
        edit(&updated)
        do {
            try updated.verify()
            try withLock {
                guard try Self.readIfPresent(url) == lastSaved else {
                    throw CommandError(message: L10n.text("Another instance changed the configuration file. Reopen the app to load the latest configuration."))
                }
                try write(updated)
            }
            configuration = updated
            error = nil
            return true
        } catch {
            self.error = L10n.text("Could not save the tunnel configuration: \(error.localizedDescription)")
            return false
        }
    }

    private func write(_ configuration: TunnelConfiguration) throws {
        let data = try Self.encode(configuration)
        let temporary = directory.appendingPathComponent(".tunnels-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        lastSaved = data
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func withLock(_ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try body()
    }

    private func migrate(appSupport: URL, defaults: UserDefaults) throws
        -> (configuration: TunnelConfiguration, hasLegacyData: Bool) {
        var result = TunnelConfiguration()
        var found = false
        let decoder = JSONDecoder()
        func readLegacy(_ path: URL, decode: (Data) throws -> Void) throws {
            do {
                guard let data = try Self.readIfPresent(path) else { return }
                try decode(data)
                found = true
            } catch {
                throw CommandError(message: L10n.text("Could not migrate \(path.path): \(error.localizedDescription)"))
            }
        }
        try readLegacy(appSupport.appendingPathComponent("MobileTunnelManager/tunnels.json")) { data in
            let saved = try decoder.decode(LegacyDeviceSettings.self, from: data)
            result.preferences.restoreOnLaunch = saved.restoreOnLaunch
            result.rules += saved.tunnels.map { .device($0, enabled: saved.enabled.contains($0.id)) }
        }
        try readLegacy(directory.appendingPathComponent("ssh-tunnels.json")) { data in
            result.appendLegacy(try Self.readLegacySSH(data).map(LegacyTunnelEntry.init(sshItem:)))
        }
        try readLegacy(directory.appendingPathComponent("socat.json")) { data in
            result.rules += try decoder.decode([SocatProfile].self, from: data).map(TunnelRule.socat)
        }
        if let value = defaults.object(forKey: "tunnelSoundsEnabled") as? Bool {
            result.preferences.connectionSounds = value
            found = true
        }
        if let value = defaults.object(forKey: "tunnelNotificationsEnabled") as? Bool {
            result.preferences.connectionNotifications = value
            found = true
        }
        return (result, found)
    }

    private static func readImport(_ data: Data) throws -> TunnelConfiguration {
        let decoder = JSONDecoder()
        let object = try JSONSerialization.jsonObject(with: data)
        var result = TunnelConfiguration()
        if let object = object as? [String: Any] {
            if object["version"] != nil || object["rules"] != nil {
                return try decoder.decode(TunnelConfiguration.self, from: data)
            }
            result.rules = try decoder.decode(LegacyDeviceSettings.self, from: data).tunnels.map { .device($0, enabled: false) }
        } else if let profiles = try? decoder.decode([SocatProfile].self, from: data) {
            result.rules = profiles.map(TunnelRule.socat)
        } else {
            result.appendLegacy(try readLegacySSH(data).map(LegacyTunnelEntry.init(sshItem:)))
        }
        try result.verify()
        return result
    }

    private static func containsLegacySSHCommand(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = object["rules"] as? [[String: Any]] else { return false }
        return rules.contains { rule in
            rule["type"] as? String == "ssh" && (rule["settings"] as? [String: Any])?["localCommand"] != nil
        }
    }

    private static func readLegacySSH(_ data: Data) throws -> [SidebarItem] {
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([SidebarItem].self, from: data) { return items }
        return try decoder.decode([SSHTunnel].self, from: data).map(SidebarItem.tunnel)
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}
