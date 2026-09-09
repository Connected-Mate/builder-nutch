// Standalone integration fixture. Compile with the four production files listed
// in test-claude-live-rotation.sh; the credential switch and Keychain are real.
import Foundation
import Security

// This fixture never invokes app shutdown. Keep the unrelated account model out
// of this standalone binary while preserving copyLogin's cancellation signature.
enum ManagedAccountError: Error { case cancelled }
final class AccountCancellation { var isCancelled: Bool { false } }
enum UsageProviderError: Error { case rateLimited(retryAfter: TimeInterval) }
enum ClaudeOAuthProvider {
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? { nil }
}
enum FixtureFailure: Error { case message(String) }

@main
struct ClaudeLiveRotationHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw FixtureFailure.message("Expected fixture root, Python driver, Claude executable") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("claude-live-rotation-") else { throw FixtureFailure.message("Unsafe fixture root") }
        let locations = ["source-a", "source-b", "target"].map { ClaudeCredentialLocation(directory: root.appendingPathComponent($0), isDefault: false) }
        var safeToDeleteFixture = true
        let keychainURL = root.appendingPathComponent("fixture.keychain")
        let password = "TEST-ONLY-KEYCHAIN-PASSWORD"
        var beforeSearch: CFArray?, afterSearch: CFArray?
        try fixtureCheck(SecKeychainCopySearchList(&beforeSearch))
        var keychainRef: SecKeychain?
        try fixtureCheck(SecKeychainSetUserInteractionAllowed(false))
        try password.withCString { try fixtureCheck(SecKeychainCreate(keychainURL.path, UInt32(password.utf8.count), $0, false, nil, &keychainRef)) }
        guard let keychainRef else { throw FixtureFailure.message("Missing fixture keychain") }
        defer {
            if safeToDeleteFixture { _ = SecKeychainDelete(keychainRef) }
            else { fputs("Fixture retained: subprocess cleanup was not acknowledged.\n", stderr) }
            _ = SecKeychainCopySearchList(&afterSearch)
            if !CFEqual(beforeSearch, afterSearch) { fputs("ERROR: Keychain search list changed\n", stderr) }
        }
        let keychain = FixtureKeychain(keychain: keychainRef)
        let account = ClaudeSystemCredentials.keychainAccount()
        var created: [ClaudeCredentialLocation] = []
        defer {
            // Only this fixture's uniquely named items; compare exact snapshots.
            for location in safeToDeleteFixture ? created : [] {
                do {
                    if let item = try keychain.read(service: location.service, account: account) {
                        try keychain.restore(service: location.service, account: account, written: item, previous: nil)
                    }
                } catch { fputs("Fixture Keychain cleanup failed: \(error)\n", stderr) }
            }
        }
        let identity: (String) -> ClaudeCredentialIdentity = { label in .init(accountID: "TEST-ONLY-\(label)", organizationID: "TEST-ONLY-ORG", email: "\(label.lowercased())@example.test") }
        for (index, location) in locations.enumerated() {
            let label = index == 1 ? "B" : "A"
            try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let who = identity(label)
            let config: [String: Any] = ["hasCompletedOnboarding": true, "oauthAccount": ["accountUuid": who.accountID, "organizationUuid": who.organizationID, "emailAddress": who.email]]
            try JSONSerialization.data(withJSONObject: config).write(to: location.configURL)
            let payload: [String: Any] = ["claudeAiOauth": ["accessToken": "TEST-ONLY-\(label)", "refreshToken": "TEST-ONLY-REFRESH-\(label)", "expiresAt": (Date().timeIntervalSince1970 + 3600) * 1000, "scopes": ["user:inference", "user:profile"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"]]
            // Unique service in a freshly created, explicit disposable keychain.
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            try fixtureSecurity(["add-generic-password", "-a", account, "-s", location.service, "-w", String(decoding: bytes, as: UTF8.self), "-T", "/usr/bin/security", "-T", CommandLine.arguments[0], keychainURL.path])
            try fixtureSecurity(["set-generic-password-partition-list", "-a", account, "-s", location.service, "-S", "teamid:523L8BHNF8,apple-tool:", "-k", password, keychainURL.path])
            try verifyFixtureACL(keychain: keychainRef, keychainURL: keychainURL, service: location.service, account: account)
            created.append(location)
        }
        try fixtureCheck(SecKeychainCopySearchList(&afterSearch))
        guard CFEqual(beforeSearch, afterSearch) else { throw FixtureFailure.message("Search list changed; refusing CLI") }
        try JSONSerialization.data(withJSONObject: ["keychain": keychainURL.path, "services": locations.map(\.service), "account": account]).write(to: root.appendingPathComponent("fixture-keychain.json"))
        let driver = Process()
        driver.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        driver.arguments = [CommandLine.arguments[2], root.path, locations[2].directory.path, CommandLine.arguments[3]]
        try driver.run()
        safeToDeleteFixture = false
        defer {
            if driver.isRunning { driver.terminate() }
            driver.waitUntilExit()
            safeToDeleteFixture = FileManager.default.fileExists(atPath: root.appendingPathComponent("driver-cleanup.done").path)
        }
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: account, renew: { _, _ in throw FixtureFailure.message("Fixture renewal is forbidden") })
        let deadline = Date().addingTimeInterval(150)
        var completed = Set<String>()
        while driver.isRunning, Date() < deadline {
            for (action, source, label) in [("copy-b", locations[1], "B"), ("copy-a", locations[0], "A")] {
                let request = root.appendingPathComponent(action + ".request")
                if !completed.contains(action), FileManager.default.fileExists(atPath: request.path) {
                    try credentials.copyLogin(from: source, to: locations[2], expectedIdentity: identity(label))
                    guard try credentials.identity(at: locations[2]) == identity(label) else { throw FixtureFailure.message("Copied identity mismatch") }
                    try Data("done".utf8).write(to: root.appendingPathComponent(action + ".done"))
                    completed.insert(action)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !driver.isRunning else { throw FixtureFailure.message("Live rotation proof timed out") }
        guard driver.terminationStatus == 0 else { throw NSError(domain: "ClaudeLiveRotation", code: Int(driver.terminationStatus)) }
    }
}

func fixtureCheck(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw NSError(domain: "FixtureKeychain", code: Int(status)) }
}
func fixtureSecurity(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "FixtureSecurity", code: Int(process.terminationStatus)) }
}
func verifyFixtureACL(keychain: SecKeychain, keychainURL: URL, service: String, account: String) throws {
    var result: CFTypeRef?
    try fixtureCheck(SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecMatchSearchList: [keychain], kSecReturnRef: true] as CFDictionary, &result))
    var access: SecAccess?, list: CFArray?
    try fixtureCheck(SecKeychainItemCopyAccess(result as! SecKeychainItem, &access))
    try fixtureCheck(SecAccessCopyACLList(access!, &list))
    var partitionEntries = 0
    var decryptEntries = 0
    for acl in list as! [SecACL] {
        let auths = SecACLCopyAuthorizations(acl) as! [String]
        var apps: CFArray?, desc: CFString?, prompt = SecKeychainPromptSelector(rawValue: 0)
        try fixtureCheck(SecACLCopyContents(acl, &apps, &desc, &prompt))
        if auths.contains(kSecACLAuthorizationPartitionID as String) {
            partitionEntries += 1
            let hex = desc! as String; var bytes = Data(); var i = hex.startIndex
            while i < hex.endIndex { let end = hex.index(i, offsetBy: 2); guard let b = UInt8(hex[i..<end], radix: 16) else { throw FixtureFailure.message("Invalid partition encoding") }; bytes.append(b); i = end }
            let object = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as! [String: Any]
            guard Set(object["Partitions"] as! [String]) == Set(["teamid:523L8BHNF8", "apple-tool:"]) else { throw FixtureFailure.message("Unsafe fixture partition") }
        }
        if auths.contains(kSecACLAuthorizationDecrypt as String) {
            decryptEntries += 1
            var paths = Set<String>()
            for app in apps as? [SecTrustedApplication] ?? [] {
                var data: CFData?; try fixtureCheck(SecTrustedApplicationCopyData(app, &data))
                let path = String(decoding: data! as Data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
            guard paths == Set(["/usr/bin/security", URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path]) else { throw FixtureFailure.message("Unsafe fixture trusted apps") }
        }
    }
    if partitionEntries == 0 {
        let probe = Process(); let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        probe.arguments = ["dump-keychain", "-a", keychainURL.path]
        probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
        try probe.run()
        let metadata = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let versions = metadata.components(separatedBy: "\n").filter { $0.hasPrefix("version:") }
        guard probe.terminationStatus == 0, !versions.isEmpty, versions.allSatisfy({ $0 == "version: 256" }) else { throw FixtureFailure.message("Unverified legacy fixture format") }
    }
    guard partitionEntries <= 1, decryptEntries == 1 else { throw FixtureFailure.message("Ambiguous fixture ACL") }
}

// The only injected boundary: native Security calls are pinned to the disposable
// keychain, while the complete production copyLogin transaction remains unchanged.
struct FixtureKeychain: ClaudeCredentialKeychain {
    let keychain: SecKeychain
    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        try KeychainInteraction.shared.perform {
            var attributes: CFTypeRef?
            let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecMatchSearchList: [keychain], kSecReturnAttributes: true, kSecReturnPersistentRef: true] as CFDictionary, &attributes)
            if status == errSecItemNotFound { return nil }; try fixtureCheck(status)
            guard let object = attributes as? [CFString: Any], let reference = object[kSecValuePersistentRef] as? Data else { throw ClaudeSystemCredentialError.malformedData }
            var bytes: CFTypeRef?
            try fixtureCheck(SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecMatchSearchList: [keychain], kSecValuePersistentRef: reference, kSecReturnData: true] as CFDictionary, &bytes))
            return ClaudeCredentialSnapshot(reference: reference, data: bytes as! Data)
        }
    }
    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        try KeychainInteraction.shared.perform {
            guard let expected, try read(service: service, account: account) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            try fixtureCheck(SecItemUpdate([kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: expected.reference] as CFDictionary, [kSecValueData: data] as CFDictionary))
            return ClaudeCredentialSnapshot(reference: expected.reference, data: data)
        }
    }
    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        try KeychainInteraction.shared.perform {
            guard try read(service: service, account: account) == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let query = [kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: written.reference] as CFDictionary
            if let previous { try fixtureCheck(SecItemUpdate(query, [kSecValueData: previous.data] as CFDictionary)) }
            else { try fixtureCheck(SecItemDelete(query)) }
        }
    }
}
