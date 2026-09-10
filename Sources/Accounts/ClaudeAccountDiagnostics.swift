import Foundation
import Security
import CoreFoundation
import Darwin

/// Explicit command-line diagnostics only. Never constructs an account manager,
/// repairs credentials, launches a CLI, or returns credential/identity payloads.
struct ClaudeAccountDiagnostics {
    struct Entry: Codable {
        let id: String
        let label: String
        let matchesMac: Bool?
        let identityStatus: String
        var credentialStatus: String
        var format: String?
        var expired: Bool?
        var hasAccess: Bool?
        var hasRefresh: Bool?
        var keychainStatus: Int32?
        var access: String?
        var readableByClaude: Bool?
        /// With `--verify-owners`: whether the service says the saved token
        /// belongs to the account the config names, and whether it belongs to
        /// the same account as the Mac's token. Never who that is.
        var tokenOwnerStatus: String?
        var tokenMatchesName: Bool?
        var tokenMatchesMac: Bool?
    }
    struct Report: Codable {
        let version: Int
        let catalogStatus: String
        let entries: [Entry]
    }

    var keychain: any ClaudeCredentialKeychain = ClaudeResilientCredentialKeychain()
    var interaction = KeychainInteraction.shared
    var readFile: (URL) throws -> Data? = Self.readFileSafely
    var now: () -> Date = Date.init
    var keychainAccount = ClaudeSystemCredentials.keychainAccount()
    /// Asks the service who each saved token belongs to. Off by default: the
    /// plain diagnostic never touches the network.
    var verifyOwners: ((String) throws -> ClaudeCredentialIdentity)?

    func collect(home: URL, catalogRoot: URL, onEntry: ((Entry) -> Void)? = nil) -> Report {
        let mac = ClaudeCredentialLocation(directory: home.appendingPathComponent(".claude"), isDefault: true)
        let macIdentity = identity(at: mac)
        var macOwner: ClaudeCredentialIdentity?
        func finished(_ built: (Entry, String?), named: ClaudeCredentialIdentity?) -> Entry {
            var entry = built.0
            guard let verifyOwners, let token = built.1 else { return entry }
            do {
                let owner = try verifyOwners(token)
                entry.tokenOwnerStatus = "read"
                entry.tokenMatchesName = named.map { $0 == owner }
                if entry.id == "mac" { macOwner = owner }
                entry.tokenMatchesMac = macOwner.map { $0 == owner }
            } catch ClaudeSystemCredentialError.expiredLogin { entry.tokenOwnerStatus = "refused" }
            catch { entry.tokenOwnerStatus = "error" }
            return entry
        }
        var entries = [finished(entry(id: "mac", label: "Mac", location: mac, identity: macIdentity, macIdentity: macIdentity), named: macIdentity.1)]
        onEntry?(entries[0])
        var catalogStatus = "missing"
        do {
            if let bytes = try readFile(catalogRoot.appendingPathComponent("accounts.json")) {
                let catalog = try JSONDecoder().decode(AccountCatalog.self, from: bytes)
                guard catalog.version == 1, Set(catalog.accounts.map(\.id)).count == catalog.accounts.count else {
                    return Report(version: 1, catalogStatus: "invalid", entries: entries)
                }
                catalogStatus = "read"
                for account in catalog.accounts where account.provider == .claude {
                    let location: ClaudeCredentialLocation
                    if let source = account.existingProfile {
                        guard source.directory.hasPrefix("/"), !source.directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                            entries.append(Entry(id: account.id.uuidString, label: Self.safeLabel(account.label), matchesMac: nil, identityStatus: "invalid", credentialStatus: "unsafe_path"))
                            onEntry?(entries[entries.count - 1])
                            continue
                        }
                        location = ClaudeCredentialLocation(directory: URL(fileURLWithPath: source.directory), isDefault: source.usesDefaultClaudeHome)
                    } else {
                        location = ClaudeCredentialLocation(directory: catalogRoot.appendingPathComponent("profiles/\(account.id.uuidString.lowercased())"), isDefault: false)
                    }
                    let named = identity(at: location)
                    entries.append(finished(entry(id: account.id.uuidString, label: Self.safeLabel(account.label), location: location, identity: named, macIdentity: macIdentity), named: named.1))
                    onEntry?(entries[entries.count - 1])
                }
            }
        } catch is DecodingError { catalogStatus = "invalid" }
        catch { catalogStatus = "read_error" }
        return Report(version: 1, catalogStatus: catalogStatus, entries: entries)
    }

    func serialized(home: URL, catalogRoot: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(collect(home: home, catalogRoot: catalogRoot))
    }

    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var diagnostics = Self()
            if arguments.contains("--verify-owners") {
                let resolver = ClaudeTokenIdentityResolver()
                diagnostics.verifyOwners = { token in
                    // A command-line report is synchronous; one bounded question per token.
                    let answer = OwnerAnswer()
                    Task {
                        do { answer.settle(.success(try await resolver.identity(forToken: token))) }
                        catch { answer.settle(.failure(error)) }
                    }
                    return try answer.wait(seconds: 25)
                }
            }
            let report = diagnostics.collect(home: home, catalogRoot: home.appendingPathComponent("Library/Application Support/Codenotch Accounts")) { entry in
                // Flush completed sanitized entries before starting another read.
                // A watchdog can then identify progress if a native read stalls.
                guard var line = try? encoder.encode(entry) else { return }
                line.append(10)
                try? FileHandle.standardError.write(contentsOf: line)
            }
            var output = try encoder.encode(report)
            output.append(10)
            try FileHandle.standardOutput.write(contentsOf: output)
            return 0
        } catch {
            // Never serialize localized errors: they can contain paths or vendor data.
            try? FileHandle.standardOutput.write(contentsOf: Data("{\"version\":1,\"error\":\"diagnostic_failed\"}\n".utf8))
            return 1
        }
    }

    private func identity(at location: ClaudeCredentialLocation) -> (String, ClaudeCredentialIdentity?) {
        do {
            guard let data = try readFile(location.configURL) else { return ("missing", nil) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("invalid", nil) }
            guard let raw = object["oauthAccount"] else { return ("missing", nil) }
            guard let account = raw as? [String: Any], let id = account["accountUuid"] as? String, !id.isEmpty,
                  let org = account["organizationUuid"] as? String, !org.isEmpty else { return ("invalid", nil) }
            return ("read", ClaudeCredentialIdentity(accountID: id, organizationID: org, email: ""))
        } catch { return ("read_error", nil) }
    }

    /// The entry, and the access token it describes — returned only so the
    /// owner check can ask about it; it is never written anywhere.
    private func entry(id: String, label: String, location: ClaudeCredentialLocation,
                       identity: (String, ClaudeCredentialIdentity?), macIdentity: (String, ClaudeCredentialIdentity?)) -> (Entry, String?) {
        let matches: Bool? = identity.1.flatMap { current in macIdentity.1.map { $0 == current } }
        var result = Entry(id: id, label: label, matchesMac: matches, identityStatus: identity.0, credentialStatus: "missing")
        var token: String?
        do {
            // The injected gate is also exercised by mock tests. The native reader
            // uses this same recursive gate; every entry explicitly prohibits UI.
            guard let item = try interaction.perform(allowPrompt: false, {
                try keychain.read(service: location.service, account: keychainAccount)
            }) else { return (result, token) }
            guard item.data.count <= ClaudeSystemCredentials.maximumBytes else { result.credentialStatus = "invalid"; return (result, token) }
            var data = item.data
            var format = data.contains(10) || data.contains(13) ? "json_multiline" : "json_compact"
            if (try? JSONSerialization.jsonObject(with: data)) == nil,
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count.isMultiple(of: 2), text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
                let chars = Array(text.utf8)
                data = Data(stride(from: 0, to: chars.count, by: 2).compactMap { UInt8(String(bytes: chars[$0...($0 + 1)], encoding: .utf8)!, radix: 16) })
                format = "hex_json"
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.credentialStatus = "invalid"; result.format = "unknown"; return (result, token)
            }
            result.format = format
            guard let oauth = object["claudeAiOauth"] as? [String: Any] else { result.credentialStatus = "missing_oauth"; return (result, token) }
            token = (oauth["accessToken"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            result.hasAccess = token != nil
            result.hasRefresh = (oauth["refreshToken"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            guard let expiry = oauth["expiresAt"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite else {
                result.credentialStatus = "invalid_expiry"; return (result, token)
            }
            result.expired = expiry.doubleValue / 1000 <= now().timeIntervalSince1970
            result.credentialStatus = result.hasAccess == true && result.hasRefresh == true ? "read" : "incomplete"
            result.access = (keychain as? ClaudeResilientCredentialKeychain)?.backend(for: location.service).rawValue
            if let missing = try? ClaudeNativeCredentialKeychain().needsHelperSharing(service: location.service, account: keychainAccount) {
                result.readableByClaude = !missing
            }
        } catch ClaudeSystemCredentialError.keychain(let status) {
            result.keychainStatus = status
            result.credentialStatus = [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) ? "denied" : "read_error"
        } catch { result.credentialStatus = "read_error" }
        return (result, token)
    }

    private static func safeLabel(_ label: String) -> String {
        guard !label.contains("@"), label.count <= 80,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "Claude account" }
        return label
    }

    private static func readFileSafely(_ url: URL) throws -> Data? {
        try AccountStorage.rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else { throw ManagedAccountError.unsafePath }
        return try Data(contentsOf: url)
    }
}

/// One answer handed from a task to the thread that is waiting on it.
private final class OwnerAnswer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<ClaudeCredentialIdentity, Error>?

    func settle(_ result: Result<ClaudeCredentialIdentity, Error>) {
        lock.lock(); outcome = result; lock.unlock()
        done.signal()
    }

    func wait(seconds: TimeInterval) throws -> ClaudeCredentialIdentity {
        guard done.wait(timeout: .now() + seconds) == .success else { throw ManagedAccountError.timedOut }
        lock.lock(); defer { lock.unlock() }
        guard let outcome else { throw ManagedAccountError.timedOut }
        return try outcome.get()
    }
}
