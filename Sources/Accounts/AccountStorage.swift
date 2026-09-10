import Foundation

struct AccountCatalog: Codable {
    var version = 1
    var accounts: [ManagedAccount] = []
    var selected: [AccountProvider: UUID] = [:]
    var automaticSelection = false
    var ignoredExistingProfiles: Set<String>? = nil
    /// Optional so catalogs written by older releases decode without migration.
    var rotationOrder: [AccountProvider: [UUID]]? = nil
    var switchThresholdPercent: Double? = nil
    /// How much notice a forecast switch takes, in minutes. Optional for the
    /// same reason as the fields above: older catalogs must decode untouched.
    var switchAheadMinutes: Double? = nil
    /// The account this app last saw the Mac actually logged in to. Kept apart
    /// from `selected`, which is the account queued *next* and is allowed to
    /// differ. Comparing the two is how a login changed outside the app is told
    /// from a next-account the person queued on purpose.
    var systemClaudeAccountID: UUID? = nil
    /// The last handoff this app made on its own, so it can still be explained
    /// after a relaunch.
    var lastAutomaticSwitch: RecordedAccountSwitch? = nil
}

struct AccountStorage {
    let root: URL
    private var catalogURL: URL { root.appendingPathComponent("accounts.json") }

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.privateDirectory(self.root)
    }

    static func rejectSymlink(_ url: URL) throws {
        var current = url.standardizedFileURL
        // /tmp and /var are system symlinks on macOS; reject below their canonical base.
        while current.path != "/" {
            if current.path != "/tmp" && current.path != "/var",
               (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ManagedAccountError.unsafePath
            }
            current.deleteLastPathComponent()
        }
    }

    static func privateDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        try rejectSymlink(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // POSIX rename is atomic and preserves private permissions from the staging file.
        if rename(temporary.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func load() throws -> AccountCatalog {
        try Self.rejectSymlink(catalogURL)
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return AccountCatalog() }
        do {
            let data = try Data(contentsOf: catalogURL)
            guard data.count <= 2_000_000 else { throw ManagedAccountError.corruptCatalog }
            let catalog = try JSONDecoder().decode(AccountCatalog.self, from: data)
            guard catalog.version == 1, Set(catalog.accounts.map(\.id)).count == catalog.accounts.count,
                  catalog.accounts.allSatisfy({ account in
                      // A browser-profile row never references a vendor directory.
                      // Cursor is the exception: its discovered row points at the
                      // editor's own state store and reads usage from it.
                      if account.existingProfile != nil && account.provider.isBrowserProfile
                          && !account.provider.readsDesktopUsage { return false }
                      do { _ = try Self.validLabel(account.label); _ = try Self.validEmail(account.emailHint); _ = try Self.validEmoji(account.emoji); return true }
                      catch { return false }
                  }),
                  catalog.selected.allSatisfy({ provider, id in catalog.accounts.contains { $0.id == id && $0.provider == provider } }) else {
                throw ManagedAccountError.corruptCatalog
            }
            return catalog
        } catch { throw ManagedAccountError.corruptCatalog }
    }

    func save(_ catalog: AccountCatalog) throws {
        try Self.write(JSONEncoder().encode(catalog), to: catalogURL)
    }

    func profile(_ account: ManagedAccount) throws -> URL {
        if let source = account.existingProfile { return try source.validatedDirectory() }
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        try Self.privateDirectory(profiles)
        let url = profiles.appendingPathComponent(account.id.uuidString.lowercased(), isDirectory: true)
        try Self.privateDirectory(url)
        return url
    }

    static func validLabel(_ value: String) throws -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ManagedAccountError.invalidLabel
        }
        return label
    }

    static func validEmoji(_ value: String?) throws -> String? {
        guard let emoji = value?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty else { return nil }
        guard emoji.count == 1, emoji.utf8.count <= 64,
              emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }),
              !emoji.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D && !(0xE0020...0xE007F).contains($0.value) }) else {
            throw ManagedAccountError.invalidEmoji
        }
        return emoji
    }

    static func validEmail(_ value: String?) throws -> String? {
        guard let hint = value?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else { return nil }
        guard hint.count <= 254, hint.contains("@"), !hint.hasPrefix("-"),
              !hint.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw ManagedAccountError.invalidEmail
        }
        return hint
    }
}
