import Foundation
import Security
import Darwin

struct ClaudeCredentialLocation: Equatable {
    let directory: URL
    let isDefault: Bool

    var configURL: URL {
        (isDefault ? directory.deletingLastPathComponent() : directory)
            .appendingPathComponent(".claude.json")
    }

    var service: String {
        ClaudeProfile.defaultKeychainService + (isDefault ? "" : "-" + ClaudeProfile.keychainSuffix(forPath: directory.path))
    }
}

struct ClaudeCredentialIdentity: Equatable {
    let accountID: String
    let organizationID: String
    let email: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID == rhs.accountID && lhs.organizationID == rhs.organizationID
    }
}

enum ClaudeSystemCredentialError: LocalizedError {
    case unsafePath, malformedData, missingLogin, identityMismatch, expiredLogin
    case changedDuringCopy, fallbackCredentials, keychain(OSStatus), rollbackFailed, storageBusy

    var requiresAccess: Bool {
        guard case .keychain(let status) = self else { return false }
        return [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status)
    }

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The Claude settings path is not a safe file owned by your Mac account."
        case .malformedData: return "Claude’s saved login or settings cannot be read safely."
        case .missingLogin: return "This Claude account has no saved subscription login."
        case .identityMismatch: return "The saved Claude login no longer matches the selected account."
        case .expiredLogin: return "This saved Claude login has expired. Sign in to that account again."
        case .storageBusy: return "Claude is updating its login. Try the switch again in a moment."
        case .changedDuringCopy: return "Claude changed its login or settings during the switch. Try again."
        case .fallbackCredentials: return "Claude has a separate credentials file. Switching is unavailable until this ambiguous login is resolved."
        case .keychain(let status): return requiresAccess
            ? NSLocalizedString("Access is paused. Choose Allow access for this account.", comment: "")
            : "macOS could not access the Claude login (OSStatus \(status))."
        case .rollbackFailed: return "The switch failed and the previous login could not be restored safely. Check the active Claude account before continuing."
        }
    }
}

/// A snapshot identifies one exact item, including its bytes. No secret is logged.
struct ClaudeCredentialSnapshot: Equatable {
    let reference: Data
    let data: Data
}

protocol ClaudeCredentialKeychain {
    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot?
    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot
    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws
}

struct ClaudeNativeCredentialKeychain: ClaudeCredentialKeychain {
    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        try KeychainInteraction.shared.perform { try readUnlocked(service: service, account: account) }
    }

    /// Explicit user action only. The returned secret is discarded, not stored or logged.
    func authorize(service: String, account: String) throws {
        try KeychainInteraction.shared.perform(allowPrompt: true) {
            guard try readUnlocked(service: service, account: account) != nil else { throw ClaudeSystemCredentialError.missingLogin }
        }
    }

    private func readUnlocked(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        // Unlike KeychainItem.newest, preserve query errors: denied access is not absence.
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnAttributes: true,
            kSecReturnPersistentRef: true, kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        guard let winner = KeychainItem.winner(among: items) else { throw ClaudeSystemCredentialError.malformedData }
        var secret: CFTypeRef?
        let readStatus = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &secret)
        guard readStatus == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(readStatus) }
        guard let bytes = secret as? Data, bytes.count <= ClaudeSystemCredentials.maximumBytes else {
            throw ClaudeSystemCredentialError.malformedData
        }
        return ClaudeCredentialSnapshot(reference: winner.persistentRef, data: bytes)
    }

    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        try KeychainInteraction.shared.perform { try replaceUnlocked(service: service, account: account, expected: expected, data: data) }
    }

    private func replaceUnlocked(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        guard try read(service: service, account: account) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
        let reference: Data
        if let expected {
            let status = SecItemUpdate([
                kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: expected.reference
            ] as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
            reference = expected.reference // Update leaves the existing item's ACL intact.
        } else {
            // The official CLI reads through Apple's /usr/bin/security helper.
            // Trust precisely that system binary and this signed app, not all apps.
            var currentApp: SecTrustedApplication?
            var cliHelper: SecTrustedApplication?
            for (path, output) in [(nil as String?, "app"), ("/usr/bin/security", "helper")] {
                var trusted: SecTrustedApplication?
                let status = path.map { SecTrustedApplicationCreateFromPath($0, &trusted) }
                    ?? SecTrustedApplicationCreateFromPath(nil, &trusted)
                guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
                if output == "app" { currentApp = trusted } else { cliHelper = trusted }
            }
            guard let currentApp, let cliHelper else { throw ClaudeSystemCredentialError.malformedData }
            var access: SecAccess?
            let accessStatus = SecAccessCreate("Claude Code subscription" as CFString, [currentApp, cliHelper] as CFArray, &access)
            guard accessStatus == errSecSuccess, let access else { throw ClaudeSystemCredentialError.keychain(accessStatus) }
            var result: CFTypeRef?
            let status = SecItemAdd([
                kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: account, kSecValueData: data, kSecReturnPersistentRef: true,
                kSecAttrAccess: access
            ] as CFDictionary, &result)
            guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
            guard let ref = result as? Data else { throw ClaudeSystemCredentialError.malformedData }
            reference = ref
        }
        return ClaudeCredentialSnapshot(reference: reference, data: data)
    }

    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        try KeychainInteraction.shared.perform { try restoreUnlocked(service: service, account: account, written: written, previous: previous) }
    }

    private func restoreUnlocked(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        guard try read(service: service, account: account) == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
        let query = [kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: written.reference] as CFDictionary
        let status: OSStatus
        if let previous {
            status = SecItemUpdate(query, [kSecValueData: previous.data] as CFDictionary)
        } else {
            // Only remove the exact item created by this failed transaction.
            status = SecItemDelete(query)
        }
        guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
    }
}

/// Copies only subscription login fields. MCP secrets and all unrelated settings stay in place.
/// Security.framework and filesystem APIs have no shared transaction: optimistic checks detect
/// intervening changes; rollback never deliberately overwrites a newer credential.
final class ClaudeSystemCredentials {
    static let maximumBytes = 8 * 1024 * 1024
    private let keychain: any ClaudeCredentialKeychain
    private let account: String
    private let now: () -> Date
    private let writeConfig: (Data, URL, Data?) throws -> Void
    private let invalidateCache: (ClaudeCredentialLocation) throws -> Void
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var stopping = false

    func requestStop() { lifecycleLock.lock(); stopping = true; lifecycleLock.unlock() }
    func waitUntilIdle() { lock.lock(); lock.unlock() }
    private func checkRunning() throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        if stopping { throw ManagedAccountError.cancelled }
    }

    init(keychain: any ClaudeCredentialKeychain = ClaudeNativeCredentialKeychain(),
         account: String = ClaudeSystemCredentials.keychainAccount(),
         now: @escaping () -> Date = Date.init,
         writeConfig: @escaping (Data, URL, Data?) throws -> Void = ClaudeSystemCredentials.writeConfigSafely,
         invalidateCache: @escaping (ClaudeCredentialLocation) throws -> Void = ClaudeSystemCredentials.invalidateLoginCache) {
        self.keychain = keychain
        self.account = account
        self.now = now
        self.writeConfig = writeConfig
        self.invalidateCache = invalidateCache
    }

    static func keychainAccount(environment: [String: String] = ProcessInfo.processInfo.environment,
                                username: String = NSUserName()) -> String {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        }
        if let user = environment["USER"], valid(user) { return user }
        return valid(username) ? username : "claude-code-user"
    }

    func identity(at location: ClaudeCredentialLocation) throws -> ClaudeCredentialIdentity? {
        try Self.validateLocation(location)
        guard let data = try Self.readConfig(location.configURL) else { return nil }
        return try Self.identity(in: Self.object(data))
    }

    struct SubscriptionLogin {
        let identity: ClaudeCredentialIdentity
        let accessToken: String
        let plan: String?
    }

    /// Read-only and noninteractive. The official app owns token refresh.
    func subscriptionLogin(at location: ClaudeCredentialLocation) throws -> SubscriptionLogin {
        lock.lock()
        defer { lock.unlock() }
        try checkRunning()
        guard let identity = try identity(at: location),
              let secret = try keychain.read(service: location.service, account: account),
              let oauth = try Self.object(secret.data)["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              let expiry = oauth["expiresAt"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite
        else { throw ClaudeSystemCredentialError.missingLogin }
        guard expiry.doubleValue / 1000 > now().timeIntervalSince1970 else { throw ClaudeSystemCredentialError.expiredLogin }
        return SubscriptionLogin(identity: identity, accessToken: token, plan: oauth["subscriptionType"] as? String)
    }

    func authorize(at location: ClaudeCredentialLocation) throws {
        try Self.validateLocation(location)
        try ClaudeNativeCredentialKeychain().authorize(service: location.service, account: account)
    }

    /// Recover the same login if an older build wrote pretty-printed password
    /// JSON, which Apple's command-line helper returns as hexadecimal text.
    func repairEncoding(at location: ClaudeCredentialLocation) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateLocation(location)
        let storageLock = try ClaudeStorageWriteLock(directory: location.directory)
        defer { storageLock.release() }
        guard let previous = try keychain.read(service: location.service, account: account) else { return }
        let payload = try Self.object(previous.data)
        guard payload["claudeAiOauth"] is [String: Any] else { return }
        let compact = try Self.encodeKeychainPayload(payload)
        guard compact != previous.data else { return }
        try storageLock.check()
        let written = try keychain.replace(service: location.service, account: account, expected: previous, data: compact)
        do { try invalidateCache(location) }
        catch {
            try keychain.restore(service: location.service, account: account, written: written, previous: previous)
            throw error
        }
    }

    func copyLogin(from source: ClaudeCredentialLocation, to target: ClaudeCredentialLocation,
                   expectedIdentity: ClaudeCredentialIdentity, allowExpired: Bool = false,
                   completingTransaction: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        func checkCancellation() throws { if !completingTransaction { try checkRunning() } }
        try checkCancellation()
        try Self.validateLocation(source)
        try Self.validateLocation(target)
        guard source != target else { return }
        // Distinct locations must never accidentally share a credentials namespace.
        guard source.service != target.service, source.configURL != target.configURL else {
            throw ClaudeSystemCredentialError.unsafePath
        }
        // Match Claude Code's own secure-storage mutex, including its 15-second
        // stale window. Stable ordering also prevents two app switches deadlocking.
        var storageLocks: [ClaudeStorageWriteLock] = []
        defer { storageLocks.reversed().forEach { $0.release() } }
        for location in [source, target].sorted(by: { $0.directory.path < $1.directory.path }) {
            try checkCancellation()
            storageLocks.append(try ClaudeStorageWriteLock(directory: location.directory, checkCancellation: checkCancellation))
        }
        // Claude's settings writer has its own proper-lockfile mutex. Hold both
        // configs from their initial read through commit/rollback to preserve
        // concurrent project/settings updates as well as the login identity.
        for location in [source, target].sorted(by: { $0.configURL.path < $1.configURL.path }) {
            try checkCancellation()
            storageLocks.append(try ClaudeStorageWriteLock(lockURL: URL(fileURLWithPath: location.configURL.path + ".lock"), staleAfter: 10, checkCancellation: checkCancellation))
        }
        let sourceConfig = try Self.readConfig(source.configURL)
        guard let sourceConfig else { throw ClaudeSystemCredentialError.missingLogin }
        let sourceObject = try Self.object(sourceConfig)
        guard try Self.identity(in: sourceObject) == expectedIdentity else { throw ClaudeSystemCredentialError.identityMismatch }
        guard let sourceSecret = try keychain.read(service: source.service, account: account) else { throw ClaudeSystemCredentialError.missingLogin }
        let sourcePayload = try Self.object(sourceSecret.data)
        guard let oauth = sourcePayload["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiry = oauth["expiresAt"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite else {
            throw ClaudeSystemCredentialError.malformedData
        }
        guard allowExpired || expiry.doubleValue / 1000 > now().timeIntervalSince1970 else { throw ClaudeSystemCredentialError.expiredLogin }
        let oldConfig = try Self.readConfig(target.configURL)
        var newConfig = try oldConfig.map(Self.object) ?? [:]
        let oldSecret = try keychain.read(service: target.service, account: account)
        var newSecret = try oldSecret.map { try Self.object($0.data) } ?? [:]
        newSecret["claudeAiOauth"] = oauth
        newConfig["oauthAccount"] = sourceObject["oauthAccount"]
        let secretBytes = try Self.encodeKeychainPayload(newSecret)
        let configBytes = try Self.encode(newConfig)
        try Self.validateLocation(source)
        try Self.validateLocation(target)
        guard try Self.readConfig(source.configURL) == sourceConfig,
              try Self.readConfig(target.configURL) == oldConfig,
              try keychain.read(service: source.service, account: account) == sourceSecret else {
            throw ClaudeSystemCredentialError.changedDuringCopy
        }
        try storageLocks.forEach { try $0.check() }
        var configCommitted = false
        // After the first write, finish commit/rollback under the lock. Shutdown
        // waits for this transaction, rather than abandoning a half-written login.
        try checkCancellation()
        let written = try keychain.replace(service: target.service, account: account, expected: oldSecret, data: secretBytes)
        do {
            try Self.validateLocation(source)
            try Self.validateLocation(target)
            guard try Self.readConfig(source.configURL) == sourceConfig,
                  try keychain.read(service: source.service, account: account) == sourceSecret,
                  try keychain.read(service: target.service, account: account) == written else {
                throw ClaudeSystemCredentialError.changedDuringCopy
            }
            try storageLocks.forEach { try $0.check() }
            try writeConfig(configBytes, target.configURL, oldConfig)
            configCommitted = true
            try invalidateCache(target)
        } catch {
            let originalError = error
            var rollbackFailed = false
            if configCommitted {
                do {
                    if let oldConfig {
                        try Self.writeConfigSafely(oldConfig, target.configURL, configBytes)
                    } else {
                        try Self.validateDirectory(target.configURL.deletingLastPathComponent())
                        guard try Self.readConfig(target.configURL) == configBytes,
                              unlink(target.configURL.path) == 0 else { throw ClaudeSystemCredentialError.changedDuringCopy }
                    }
                } catch { rollbackFailed = true }
            }
            do { try keychain.restore(service: target.service, account: account, written: written, previous: oldSecret) }
            catch { rollbackFailed = true }
            if rollbackFailed { throw ClaudeSystemCredentialError.rollbackFailed }
            throw originalError
        }
    }

    private static func identity(in object: [String: Any]) throws -> ClaudeCredentialIdentity? {
        guard let value = object["oauthAccount"] else { return nil }
        guard let oauth = value as? [String: Any],
              let id = oauth["accountUuid"] as? String, !id.isEmpty,
              let org = oauth["organizationUuid"] as? String, !org.isEmpty,
              let email = oauth["emailAddress"] as? String, !email.isEmpty else { throw ClaudeSystemCredentialError.malformedData }
        return ClaudeCredentialIdentity(accountID: id, organizationID: org, email: email)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeSystemCredentialError.malformedData }
        return value
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        let result = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard result.count <= maximumBytes else { throw ClaudeSystemCredentialError.malformedData }
        return result
    }

    /// `security find-generic-password -w`, used by Claude, renders non-printable
    /// password data as hexadecimal. Keep the complete JSON on one ASCII line
    /// so the official CLI receives JSON, including when other secrets use Unicode.
    static func encodeKeychainPayload(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let ascii = String(decoding: json, as: UTF8.self).utf16.map { unit -> String in
            if unit >= 0x7f { return String(format: "\\u%04x", unit) }
            return String(UnicodeScalar(unit)!)
        }.joined()
        let result = Data(ascii.utf8)
        guard result.count <= maximumBytes else { throw ClaudeSystemCredentialError.malformedData }
        return result
    }

    private static func validateLocation(_ location: ClaudeCredentialLocation) throws {
        try validateDirectory(location.directory)
        try validateDirectory(location.configURL.deletingLastPathComponent())
        let fallback = location.directory.appendingPathComponent(".credentials.json")
        if let bytes = try readConfig(fallback) {
            guard try object(bytes).isEmpty else { throw ClaudeSystemCredentialError.fallbackCredentials }
        }
    }

    /// Claude watches this file's modification date even when the actual secrets are
    /// stored in Keychain. An empty object invalidates the running process's OAuth
    /// memo without putting tokens on disk or terminating its conversation.
    static func invalidateLoginCache(at location: ClaudeCredentialLocation) throws {
        try validateLocation(location)
        let marker = location.directory.appendingPathComponent(".credentials.json")
        if let existing = try readConfig(marker) {
            guard try object(existing).isEmpty else { throw ClaudeSystemCredentialError.fallbackCredentials }
            // Replace the empty marker atomically so the modification timestamp changes.
            try writeConfigSafely(existing, marker, existing)
        } else {
            let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw ClaudeSystemCredentialError.changedDuringCopy }
            defer { close(fd) }
            let empty: [UInt8] = [123, 125]
            guard Darwin.write(fd, empty, empty.count) == empty.count, fsync(fd) == 0 else {
                // Failed creation belongs to this transaction; remove only our inode.
                var opened = stat(), current = stat()
                if fstat(fd, &opened) == 0, lstat(marker.path, &current) == 0,
                   opened.st_ino == current.st_ino, opened.st_dev == current.st_dev {
                    unlink(marker.path)
                }
                throw ClaudeSystemCredentialError.unsafePath
            }
        }
        // A permanent empty marker hides future native Keychain rotations from Claude.
        // Remove only this exact empty file after running processes have observed it.
        if let snapshot = try? markerSnapshot(marker) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 35) {
                try? removeMarker(marker, matching: snapshot)
            }
        }
    }

    private struct MarkerSnapshot: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int
        let contents: Data
    }

    private static func markerSnapshot(_ url: URL) throws -> MarkerSnapshot? {
        try validateDirectory(url.deletingLastPathComponent())
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            if errno == ENOENT { return nil }
            throw ClaudeSystemCredentialError.unsafePath
        }
        guard let contents = try readConfig(url), try object(contents).isEmpty else {
            throw ClaudeSystemCredentialError.fallbackCredentials
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ClaudeSystemCredentialError.changedDuringCopy
        }
        return MarkerSnapshot(device: after.st_dev, inode: after.st_ino,
                              seconds: after.st_mtimespec.tv_sec, nanoseconds: after.st_mtimespec.tv_nsec,
                              contents: contents)
    }

    private static func removeMarker(_ url: URL, matching snapshot: MarkerSnapshot) throws {
        try validateDirectory(url.deletingLastPathComponent())
        let storageLock = try ClaudeStorageWriteLock(directory: url.deletingLastPathComponent())
        defer { storageLock.release() }
        guard try markerSnapshot(url) == snapshot else { return }
        try storageLock.check()
        guard unlink(url.path) == 0 || errno == ENOENT else { throw ClaudeSystemCredentialError.unsafePath }
    }

    /// Startup recovery for a secret-free marker left behind if the app quit during
    /// its 35-second invalidation window. Real fallback credentials are never removed.
    static func cleanupStaleCacheMarker(at location: ClaudeCredentialLocation, now: Date = Date()) throws {
        let url = location.directory.appendingPathComponent(".credentials.json")
        guard let snapshot = try markerSnapshot(url) else { return }
        let age = now.timeIntervalSince1970 - Double(snapshot.seconds) - Double(snapshot.nanoseconds) / 1_000_000_000
        if age >= 35 {
            try removeMarker(url, matching: snapshot)
        } else {
            // A quick quit/reopen loses the original process's timer. Re-arm it
            // even while the marker is fresh so it cannot pin credentials forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, 35 - age)) {
                try? removeMarker(url, matching: snapshot)
            }
        }
    }

    private static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL, !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else { throw ClaudeSystemCredentialError.unsafePath }
        var current = directory
        var first = true
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0 else { throw ClaudeSystemCredentialError.unsafePath }
            // Foundation standardizes /private/var and /private/tmp through these
            // root-owned macOS aliases. Do not change the textual Keychain hash.
            if !first, info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK,
               current.path == "/var" || current.path == "/tmp" {
                var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = readlink(current.path, &buffer, buffer.count)
                let destination = count > 0 ? String(bytes: buffer.prefix(count), encoding: .utf8) : nil
                let expected = "private" + current.path
                guard destination == expected || destination == "/" + expected else { throw ClaudeSystemCredentialError.unsafePath }
                current = URL(fileURLWithPath: "/" + expected)
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() || (!first && info.st_uid == 0) else { throw ClaudeSystemCredentialError.unsafePath }
            // Root-owned sticky temporary ancestors are safe; writable profile parents are not.
            let writable = info.st_mode & (S_IWGRP | S_IWOTH) != 0
            let stickyAncestor = !first && info.st_uid == 0 && info.st_mode & S_ISVTX != 0
            guard !writable || stickyAncestor else { throw ClaudeSystemCredentialError.unsafePath }
            if current.path == "/" { break }
            first = false
            current.deleteLastPathComponent()
        }
    }

    private static func readConfig(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ClaudeSystemCredentialError.unsafePath
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw ClaudeSystemCredentialError.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClaudeSystemCredentialError.unsafePath
            }
            guard data.count + count <= maximumBytes else { throw ClaudeSystemCredentialError.malformedData }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writeConfigSafely(_ data: Data, _ url: URL, _ expected: Data?) throws {
        try validateDirectory(url.deletingLastPathComponent())
        guard try readConfig(url) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".codenotch-login-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ClaudeSystemCredentialError.unsafePath }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClaudeSystemCredentialError.unsafePath }
                offset += count
            }
        }
        var oldInfo = stat(), newInfo = stat()
        if lstat(url.path, &oldInfo) == 0, fstat(fd, &newInfo) == 0,
           oldInfo.st_mtimespec.tv_sec == newInfo.st_mtimespec.tv_sec,
           oldInfo.st_mtimespec.tv_nsec / 1_000_000 == newInfo.st_mtimespec.tv_nsec / 1_000_000 {
            let millis = oldInfo.st_mtimespec.tv_nsec / 1_000_000 + 1
            let next = timespec(tv_sec: oldInfo.st_mtimespec.tv_sec + millis / 1000,
                                tv_nsec: (millis % 1000) * 1_000_000)
            var times = [newInfo.st_atimespec, next]
            guard futimens(fd, &times) == 0 else { throw ClaudeSystemCredentialError.unsafePath }
        }
        guard fsync(fd) == 0 else { throw ClaudeSystemCredentialError.unsafePath }
        try validateDirectory(url.deletingLastPathComponent())
        guard try readConfig(url) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
        guard rename(temporary.path, url.path) == 0 else { throw ClaudeSystemCredentialError.unsafePath }
    }
}


/// Interoperates with Claude Code's proper-lockfile `.storage-write.lock` directory.
/// The heartbeat keeps a macOS authorization prompt from making a held lock stale.
private final class ClaudeStorageWriteLock: @unchecked Sendable {
    private let url: URL
    private let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    private let mutex = NSLock()
    private var released = false
    private var compromised = false
    private var timer: DispatchSourceTimer?

    convenience init(directory: URL, checkCancellation: () throws -> Void = {}) throws {
        try self.init(lockURL: directory.appendingPathComponent(".storage-write.lock"), staleAfter: 15, checkCancellation: checkCancellation)
    }

    init(lockURL: URL, staleAfter: TimeInterval, checkCancellation: () throws -> Void = {}) throws {
        url = lockURL
        var acquired = false
        for attempt in 0...10 {
            try checkCancellation()
            if mkdir(url.path, S_IRWXU) == 0 { acquired = true; break }
            guard errno == EEXIST else { throw ClaudeSystemCredentialError.unsafePath }
            var existing = stat()
            guard lstat(url.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFDIR,
                  existing.st_uid == getuid() else { throw ClaudeSystemCredentialError.unsafePath }
            let modified = Double(existing.st_mtimespec.tv_sec) + Double(existing.st_mtimespec.tv_nsec) / 1_000_000_000
            if Date().timeIntervalSince1970 - modified > staleAfter {
                // proper-lockfile's stale recovery removes only an empty lock directory.
                var checked = stat()
                if lstat(url.path, &checked) == 0, checked.st_dev == existing.st_dev, checked.st_ino == existing.st_ino,
                   checked.st_mtimespec.tv_sec == existing.st_mtimespec.tv_sec,
                   checked.st_mtimespec.tv_nsec == existing.st_mtimespec.tv_nsec {
                    if rmdir(url.path) == 0, mkdir(url.path, S_IRWXU) == 0 { acquired = true; break }
                }
            }
            if attempt < 10 {
                let deadline = Date().addingTimeInterval(min(1, 0.1 * pow(2, Double(attempt))))
                while Date() < deadline {
                    try checkCancellation()
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        guard acquired else { throw ClaudeSystemCredentialError.storageBusy }
        let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        var info = stat()
        guard opened >= 0, fstat(opened, &info) == 0, info.st_uid == getuid() else {
            if opened >= 0 { close(opened) }
            throw ClaudeSystemCredentialError.unsafePath
        }
        fd = opened
        device = info.st_dev
        inode = info.st_ino
        let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        heartbeat.schedule(deadline: .now() + 5, repeating: 5)
        heartbeat.setEventHandler { [weak self] in self?.update() }
        timer = heartbeat
        heartbeat.resume()
    }

    func check() throws {
        mutex.lock()
        defer { mutex.unlock() }
        var current = stat()
        guard !released, !compromised, lstat(url.path, &current) == 0,
              current.st_dev == device, current.st_ino == inode else {
            throw ClaudeSystemCredentialError.changedDuringCopy
        }
    }

    private func update() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_dev == device, current.st_ino == inode,
              futimens(fd, nil) == 0 else { compromised = true; return }
    }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        timer?.cancel()
        timer = nil
        var current = stat()
        if lstat(url.path, &current) == 0, current.st_dev == device, current.st_ino == inode { rmdir(url.path) }
        close(fd)
    }

    deinit { release() }
}
