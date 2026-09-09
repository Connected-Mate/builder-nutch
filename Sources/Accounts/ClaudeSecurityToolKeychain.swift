import Foundation
import Security
import Darwin

/// Reads and writes a Claude Code login through Apple's own `/usr/bin/security`
/// helper, the same path the official CLI uses.
///
/// Why this exists: macOS guards a legacy Keychain item with two separate
/// checks. The trusted-application list decides which apps may decrypt it, and
/// a partition list decides which *signing identities* may. Claude Code creates
/// and rewrites its item through `security`, whose partition is `apple-tool:`
/// only. This app's Developer ID partition can be lost whenever the CLI
/// rewrites the item (`SecItemUpdate` then fails with `errSecAuthFailed`,
/// -25293, even though the app is still in the trusted list) and it cannot be
/// added back without the login Keychain password. Going through `security`
/// keeps the app working across CLI updates with no prompt and no password.
///
/// Secrets never appear on a command line: the write uses `security -i`, which
/// reads its command from standard input, so `argv` is `["security", "-i"]`.
/// Nothing the helper prints is logged or retained beyond the returned bytes.
struct ClaudeSecurityToolKeychain: ClaudeCredentialKeychain {
    typealias Runner = (_ arguments: [String], _ input: Data?) throws -> (status: Int32, output: Data)

    static let executable = "/usr/bin/security"
    static let timeout: TimeInterval = 30

    private let run: Runner
    private let lock = NSLock()

    init(run: @escaping Runner = ClaudeSecurityToolKeychain.runHelper) {
        self.run = run
    }

    static func reference(service: String, account: String) -> Data {
        Data("security-tool:\(service):\(account)".utf8)
    }

    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return try readUnlocked(service: service, account: account)
    }

    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard try readUnlocked(service: service, account: account) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
        return try writeUnlocked(service: service, account: account, data: data, update: expected != nil)
    }

    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        lock.lock(); defer { lock.unlock() }
        guard try readUnlocked(service: service, account: account) == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
        if let previous {
            _ = try writeUnlocked(service: service, account: account, data: previous.data, update: true)
        } else {
            // Only the item this failed transaction created is removed.
            let result = try run(["delete-generic-password", "-s", service, "-a", account], nil)
            guard result.status == 0 || Self.status(fromExit: result.status) == errSecItemNotFound else {
                throw ClaudeSystemCredentialError.keychain(Self.status(fromExit: result.status))
            }
        }
    }

    // MARK: - Helpers

    private func readUnlocked(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        try Self.validateSelector(service); try Self.validateSelector(account)
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"], nil)
        let status = Self.status(fromExit: result.status)
        if status == errSecItemNotFound { return nil }
        guard result.status == 0 else { throw ClaudeSystemCredentialError.keychain(status) }
        let bytes = try Self.decodePassword(result.output)
        guard bytes.count <= ClaudeSystemCredentials.maximumBytes else { throw ClaudeSystemCredentialError.malformedData }
        return ClaudeCredentialSnapshot(reference: Self.reference(service: service, account: account), data: bytes)
    }

    private func writeUnlocked(service: String, account: String, data: Data, update: Bool) throws -> ClaudeCredentialSnapshot {
        let command = try Self.addCommand(service: service, account: account, data: data, update: update)
        let result = try run(["-i"], command)
        guard result.status == 0 else { throw ClaudeSystemCredentialError.keychain(Self.status(fromExit: result.status)) }
        // `-U` updates an existing item in place, so Claude Code's own access
        // list survives; a plain add creates a fresh item whose partition is the
        // helper's own, which is exactly what lets Claude Code read it later.
        // Read back so a silent helper failure cannot pass as a write.
        guard let stored = try readUnlocked(service: service, account: account), stored.data == data else {
            throw ClaudeSystemCredentialError.changedDuringCopy
        }
        return stored
    }

    /// One `security -i` line. The payload must be single-line text: control
    /// characters would end the command early or corrupt the stored JSON.
    static func addCommand(service: String, account: String, data: Data, update: Bool = true) throws -> Data {
        try validateSelector(service); try validateSelector(account)
        guard data.count <= ClaudeSystemCredentials.maximumBytes, !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ClaudeSystemCredentialError.malformedData
        }
        let line = "add-generic-password \(update ? "-U " : "")-s \(quote(service)) -a \(quote(account)) -w \(quote(text))\n"
        return Data(line.utf8)
    }

    /// `security -i` tokenizes like a shell: inside double quotes only `\` and `"` are special.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func validateSelector(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ClaudeSystemCredentialError.unsafePath
        }
    }

    /// `security find-generic-password -w` prints printable passwords as-is and
    /// anything else as hexadecimal. Both come back as the stored bytes.
    static func decodePassword(_ output: Data) throws -> Data {
        var bytes = output
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        if (try? JSONSerialization.jsonObject(with: bytes)) != nil { return bytes }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ClaudeSystemCredentialError.malformedData }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexDigits = Array(trimmed.utf8)
        guard !hexDigits.isEmpty, hexDigits.count.isMultiple(of: 2),
              hexDigits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return bytes
        }
        var decoded = Data(capacity: hexDigits.count / 2)
        for index in stride(from: 0, to: hexDigits.count, by: 2) {
            guard let value = UInt8(String(decoding: hexDigits[index...index + 1], as: UTF8.self), radix: 16) else {
                throw ClaudeSystemCredentialError.malformedData
            }
            decoded.append(value)
        }
        return decoded
    }

    /// The helper exits with the low byte of the Security OSStatus it hit.
    static func status(fromExit code: Int32) -> OSStatus {
        switch code {
        case 0: return errSecSuccess
        case 44: return errSecItemNotFound
        case 45: return errSecDuplicateItem
        case 51: return errSecAuthFailed
        case 36: return errSecInteractionNotAllowed
        case 128: return errSecUserCanceled
        default: return errSecIO
        }
    }

    /// Runs the system helper with a scrubbed environment, no terminal, and a
    /// hard timeout. Output is returned to the caller only; stderr is discarded.
    static func runHelper(arguments: [String], input: Data?) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = ["PATH": "/usr/bin:/bin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = inherited[key] { environment[key] = value }
        }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let writer = DispatchQueue(label: "codenotch.security-helper.stdin")
        writer.async {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
            try? stdin.fileHandleForWriting.close()
        }
        let reader = DispatchQueue(label: "codenotch.security-helper.stdout")
        var output = Data()
        let finished = DispatchSemaphore(value: 0)
        reader.async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        let deadline = DispatchTime.now() + timeout
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 2)
            process.waitUntilExit()
            throw ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw ClaudeSystemCredentialError.keychain(errSecIO) }
        return (process.terminationStatus, output)
    }
}

/// What a native backend can say about an item's access list without reading
/// the secret, and how it removes items it is allowed to remove.
protocol ClaudeCredentialKeychainSharing {
    /// nil when there is no item; true when at least one item under the
    /// service lacks the `apple-tool:` partition that Apple's `security` helper
    /// (and therefore Claude Code) needs to read it without a password prompt.
    func needsHelperSharing(service: String, account: String) throws -> Bool?
    /// Removes every item under the service this process may delete. Returns the count.
    func removeAll(service: String, account: String) throws -> Int
}

extension ClaudeNativeCredentialKeychain: ClaudeCredentialKeychainSharing {
    static let helperPartition = "apple-tool:"

    func needsHelperSharing(service: String, account: String) throws -> Bool? {
        try KeychainInteraction.shared.perform {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll
            ] as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
            let refs = (result as? [AnyObject]) ?? (result as AnyObject?).map { [$0] } ?? []
            var missing = false
            for ref in refs {
                guard CFGetTypeID(ref) == SecKeychainItemGetTypeID() else { continue }
                var access: SecAccess?
                let accessStatus = SecKeychainItemCopyAccess(ref as! SecKeychainItem, &access)
                guard accessStatus == errSecSuccess, let access else { throw ClaudeSystemCredentialError.keychain(accessStatus) }
                if !Self.partitions(of: access).contains(Self.helperPartition) { missing = true }
            }
            return refs.isEmpty ? nil : missing
        }
    }

    /// The partition list is stored as a property list inside the description
    /// of the `ACLAuthorizationPartitionID` entry.
    static func partitions(of access: SecAccess) -> [String] {
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return [] }
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String],
                  authorizations.contains(kSecACLAuthorizationPartitionID as String) else { continue }
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &selector) == errSecSuccess,
                  let hex = description as String?, let bytes = Data(hexEncoded: hex),
                  let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let partitions = plist["Partitions"] as? [String] else { continue }
            return partitions
        }
        return []
    }

    func removeAll(service: String, account: String) throws -> Int {
        try KeychainInteraction.shared.perform {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                kSecReturnPersistentRef: true, kSecMatchLimit: kSecMatchLimitAll
            ] as CFDictionary, &result)
            if status == errSecItemNotFound { return 0 }
            guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
            let refs = (result as? [Data]) ?? (result as? Data).map { [$0] } ?? []
            var removed = 0
            for ref in refs {
                let deleteStatus = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: ref] as CFDictionary)
                guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw ClaudeSystemCredentialError.keychain(deleteStatus) }
                removed += 1
            }
            return removed
        }
    }
}

private extension Data {
    init?(hexEncoded text: String) {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let value = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(value)
        }
        self = bytes
    }
}

/// Native Security.framework access first, Apple's helper when macOS refuses the
/// native path. The choice is remembered per service so every snapshot compared
/// within one transaction comes from the same backend.
final class ClaudeResilientCredentialKeychain: ClaudeCredentialKeychain, @unchecked Sendable {
    enum Backend: String { case native, securityTool = "security_tool" }

    private let native: any ClaudeCredentialKeychain
    private let tool: any ClaudeCredentialKeychain
    private let lock = NSLock()
    private var backends: [String: Backend] = [:]

    init(native: any ClaudeCredentialKeychain = ClaudeNativeCredentialKeychain(),
         tool: any ClaudeCredentialKeychain = ClaudeSecurityToolKeychain()) {
        self.native = native
        self.tool = tool
    }

    func backend(for service: String) -> Backend {
        lock.lock(); defer { lock.unlock() }
        return backends[service] ?? .native
    }

    private static func isDenied(_ error: Error) -> Bool {
        guard case ClaudeSystemCredentialError.keychain(let status) = error else { return false }
        return status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    private func useTool(for service: String) {
        lock.lock(); backends[service] = .securityTool; lock.unlock()
    }

    private func translated(_ snapshot: ClaudeCredentialSnapshot?, service: String, account: String) -> ClaudeCredentialSnapshot? {
        snapshot.map { ClaudeCredentialSnapshot(reference: ClaudeSecurityToolKeychain.reference(service: service, account: account), data: $0.data) }
    }

    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        if backend(for: service) == .securityTool { return try tool.read(service: service, account: account) }
        do { return try native.read(service: service, account: account) }
        catch where Self.isDenied(error) {
            let result = try tool.read(service: service, account: account)
            useTool(for: service)
            return result
        }
    }

    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        if backend(for: service) == .securityTool || expected == nil {
            // A new item is always created by Apple's helper: an item created
            // natively carries only this app's partition, and Claude Code's own
            // `security` calls would then ask for the Keychain password.
            let result = try tool.replace(service: service, account: account, expected: translated(expected, service: service, account: account), data: data)
            useTool(for: service)
            return result
        }
        do { return try native.replace(service: service, account: account, expected: expected, data: data) }
        catch where Self.isDenied(error) {
            let result = try tool.replace(service: service, account: account, expected: translated(expected, service: service, account: account), data: data)
            useTool(for: service)
            return result
        }
    }

    /// Moves an item this app created natively to one Apple's helper owns, so
    /// Claude Code reads it silently. The secret is re-added before the native
    /// path is forgotten; if the helper cannot store it, the native item is
    /// put back and the error surfaces. Returns true when a move happened.
    func shareWithHelper(service: String, account: String) throws -> Bool {
        guard backend(for: service) == .native, let sharing = native as? ClaudeCredentialKeychainSharing,
              try sharing.needsHelperSharing(service: service, account: account) == true,
              let current = try native.read(service: service, account: account) else { return false }
        do {
            _ = try sharing.removeAll(service: service, account: account)
            let stored = try tool.replace(service: service, account: account, expected: nil, data: current.data)
            guard stored.data == current.data else { throw ClaudeSystemCredentialError.changedDuringCopy }
        } catch {
            // Put the secret back natively so nothing is lost; the next attempt retries.
            if (try? native.read(service: service, account: account)) == nil {
                _ = try? native.replace(service: service, account: account, expected: nil, data: current.data)
            }
            throw error
        }
        useTool(for: service)
        return true
    }

    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        if backend(for: service) == .securityTool {
            guard let writtenViaTool = translated(written, service: service, account: account) else { return }
            return try tool.restore(service: service, account: account, written: writtenViaTool, previous: translated(previous, service: service, account: account))
        }
        do { try native.restore(service: service, account: account, written: written, previous: previous) }
        catch where Self.isDenied(error) {
            guard let writtenViaTool = translated(written, service: service, account: account) else { return }
            try tool.restore(service: service, account: account, written: writtenViaTool, previous: translated(previous, service: service, account: account))
            useTool(for: service)
        }
    }
}
