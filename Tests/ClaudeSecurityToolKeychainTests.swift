import XCTest
import Security
@testable import Codenotch

final class ClaudeSecurityToolKeychainTests: XCTestCase {
    /// Simulates `/usr/bin/security`: `find-generic-password -w` prints the stored
    /// bytes, `-i` executes one `add-generic-password -U` line from stdin.
    private final class FakeHelper {
        var items: [String: Data] = [:]
        var calls: [(arguments: [String], input: Data?)] = []
        var renderHex = false
        var failWith: Int32?

        func run(_ arguments: [String], _ input: Data?) throws -> (status: Int32, output: Data) {
            calls.append((arguments, input))
            if let failWith { return (failWith, Data()) }
            switch arguments.first {
            case "find-generic-password":
                let key = arguments[2] + ":" + arguments[4]
                guard let data = items[key] else { return (44, Data()) }
                if renderHex { return (0, Data((data.map { String(format: "%02x", $0) }.joined() + "\n").utf8)) }
                return (0, data + Data([10]))
            case "delete-generic-password":
                let key = arguments[2] + ":" + arguments[4]
                guard items.removeValue(forKey: key) != nil else { return (44, Data()) }
                return (0, Data())
            case "-i":
                guard let input, let line = String(data: input, encoding: .utf8) else { return (1, Data()) }
                var tokens = Self.tokenize(line)
                guard tokens.first == "add-generic-password" else { return (1, Data()) }
                let update = tokens.count > 1 && tokens[1] == "-U"
                if update { tokens.remove(at: 1) }
                guard tokens.count == 7, tokens[1] == "-s", tokens[3] == "-a", tokens[5] == "-w" else { return (1, Data()) }
                let key = tokens[2] + ":" + tokens[4]
                if !update, items[key] != nil { return (45, Data()) }
                items[key] = Data(tokens[6].utf8)
                return (0, Data())
            default:
                return (1, Data())
            }
        }

        /// The helper's own quoting rules: double quotes group, `\` escapes the next character.
        static func tokenize(_ line: String) -> [String] {
            var tokens: [String] = [], current = "", quoted = false, escaped = false, started = false
            for character in line {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" && quoted { escaped = true; continue }
                if character == "\"" { quoted.toggle(); started = true; continue }
                if (character == " " || character == "\n") && !quoted {
                    if started || !current.isEmpty { tokens.append(current); current = ""; started = false }
                    continue
                }
                current.append(character)
            }
            if started || !current.isEmpty { tokens.append(current) }
            return tokens
        }
    }

    private final class DenyingNative: ClaudeCredentialKeychain {
        var status: OSStatus = errSecAuthFailed
        var reads = 0
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { reads += 1; throw ClaudeSystemCredentialError.keychain(status) }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot { throw ClaudeSystemCredentialError.keychain(status) }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws { throw ClaudeSystemCredentialError.keychain(status) }
    }

    private let service = "Claude Code-credentials"
    private let account = "tester"
    private let payload = Data(#"{"claudeAiOauth":{"accessToken":"TEST-ONLY \\ \"quoted\" \/ é","refreshToken":"r"}}"#.utf8)

    func testReadReturnsStoredJSONAndNilWhenMissing() throws {
        let helper = FakeHelper()
        let keychain = ClaudeSecurityToolKeychain(run: helper.run)
        XCTAssertNil(try keychain.read(service: service, account: account))
        helper.items[service + ":" + account] = payload
        let snapshot = try XCTUnwrap(keychain.read(service: service, account: account))
        XCTAssertEqual(snapshot.data, payload)
        XCTAssertEqual(snapshot.reference, ClaudeSecurityToolKeychain.reference(service: service, account: account))
        XCTAssertEqual(helper.calls.last?.arguments, ["find-generic-password", "-s", service, "-a", account, "-w"])
    }

    func testReadDecodesHexadecimalRendering() throws {
        let helper = FakeHelper()
        helper.renderHex = true
        helper.items[service + ":" + account] = payload
        let snapshot = try XCTUnwrap(ClaudeSecurityToolKeychain(run: helper.run).read(service: service, account: account))
        XCTAssertEqual(snapshot.data, payload)
    }

    func testDeniedHelperMapsToKeychainAuthFailure() {
        let helper = FakeHelper()
        helper.failWith = 51
        XCTAssertThrowsError(try ClaudeSecurityToolKeychain(run: helper.run).read(service: service, account: account)) { error in
            guard case ClaudeSystemCredentialError.keychain(let status) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, errSecAuthFailed)
            XCTAssertTrue((error as? ClaudeSystemCredentialError)?.requiresAccess == true)
        }
    }

    func testReplaceKeepsSecretOffTheCommandLineAndVerifiesReadback() throws {
        let helper = FakeHelper()
        let keychain = ClaudeSecurityToolKeychain(run: helper.run)
        let written = try keychain.replace(service: service, account: account, expected: nil, data: payload)
        XCTAssertEqual(written.data, payload)
        XCTAssertEqual(helper.items[service + ":" + account], payload)
        let write = try XCTUnwrap(helper.calls.first { $0.arguments == ["-i"] })
        XCTAssertFalse(helper.calls.contains { $0.arguments.contains { $0.contains("TEST-ONLY") } })
        let line = try XCTUnwrap(String(data: XCTUnwrap(write.input), encoding: .utf8))
        XCTAssertTrue(line.hasPrefix("add-generic-password -s \"Claude Code-credentials\" -a \"tester\" -w \""), "A new item is created without -U so the helper owns it")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        // A second write must present the current bytes, or it is refused.
        let newer = Data(#"{"claudeAiOauth":{"accessToken":"NEWER"}}"#.utf8)
        XCTAssertThrowsError(try keychain.replace(service: service, account: account, expected: nil, data: newer)) { error in
            guard case ClaudeSystemCredentialError.changedDuringCopy = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try keychain.replace(service: service, account: account, expected: written, data: newer).data, newer)
        let update = try XCTUnwrap(String(data: XCTUnwrap(helper.calls.last { $0.arguments == ["-i"] }?.input), encoding: .utf8))
        XCTAssertTrue(update.hasPrefix("add-generic-password -U -s "), "An existing item is updated in place")
    }

    func testReplaceRejectsMultilinePayloads() {
        let helper = FakeHelper()
        XCTAssertThrowsError(try ClaudeSecurityToolKeychain(run: helper.run).replace(service: service, account: account, expected: nil, data: Data("{\n}".utf8))) { error in
            guard case ClaudeSystemCredentialError.malformedData = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(helper.calls.allSatisfy { $0.arguments.first == "find-generic-password" })
    }

    func testRestoreRewritesPreviousOrDeletesOwnItem() throws {
        let helper = FakeHelper()
        let keychain = ClaudeSecurityToolKeychain(run: helper.run)
        let previous = try keychain.replace(service: service, account: account, expected: nil, data: payload)
        let newer = Data(#"{"claudeAiOauth":{"accessToken":"NEWER"}}"#.utf8)
        let written = try keychain.replace(service: service, account: account, expected: previous, data: newer)
        try keychain.restore(service: service, account: account, written: written, previous: previous)
        XCTAssertEqual(helper.items[service + ":" + account], payload)
        let created = try keychain.replace(service: "other", account: account, expected: nil, data: payload)
        try keychain.restore(service: "other", account: account, written: created, previous: nil)
        XCTAssertNil(helper.items["other:" + account])
        XCTAssertEqual(helper.calls.last?.arguments, ["delete-generic-password", "-s", "other", "-a", account])
    }

    func testPasswordEncodingRoundTripsRealPayloadThroughHelperQuoting() throws {
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": "a/b\\c\"d é", "expiresAt": 1_800_000_000_000.0]]
        let data = try ClaudeSystemCredentials.encodeKeychainPayload(object)
        let command = try ClaudeSecurityToolKeychain.addCommand(service: service, account: account, data: data)
        let tokens = FakeHelper.tokenize(try XCTUnwrap(String(data: command, encoding: .utf8)))
        XCTAssertEqual(Data(tokens[7].utf8), data)
        XCTAssertEqual(try ClaudeSecurityToolKeychain.decodePassword(data + Data([10])), data)
    }

    func testExitCodesMapToSecurityStatuses() {
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 44), errSecItemNotFound)
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 45), errSecDuplicateItem)
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 51), errSecAuthFailed)
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 36), errSecInteractionNotAllowed)
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 0), errSecSuccess)
        XCTAssertEqual(ClaudeSecurityToolKeychain.status(fromExit: 7), errSecIO)
    }

    func testResilientKeychainFallsBackWhenNativeAccessIsDeniedAndStaysThere() throws {
        let native = DenyingNative()
        let helper = FakeHelper()
        helper.items[service + ":" + account] = payload
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: helper.run))
        XCTAssertEqual(keychain.backend(for: service), .native)
        let snapshot = try XCTUnwrap(keychain.read(service: service, account: account))
        XCTAssertEqual(snapshot.data, payload)
        XCTAssertEqual(keychain.backend(for: service), .securityTool)
        XCTAssertEqual(native.reads, 1)
        _ = try keychain.read(service: service, account: account)
        XCTAssertEqual(native.reads, 1, "Once the helper is chosen for a service the native path is not retried")
        let newer = Data(#"{"claudeAiOauth":{"accessToken":"NEWER"}}"#.utf8)
        let written = try keychain.replace(service: service, account: account, expected: snapshot, data: newer)
        XCTAssertEqual(helper.items[service + ":" + account], newer)
        try keychain.restore(service: service, account: account, written: written, previous: snapshot)
        XCTAssertEqual(helper.items[service + ":" + account], payload)
        XCTAssertEqual(keychain.backend(for: "unrelated"), .native)
    }

    func testResilientKeychainTranslatesNativeSnapshotsWhenWriteIsDenied() throws {
        final class ReadOnlyNative: ClaudeCredentialKeychain {
            let data: Data
            init(data: Data) { self.data = data }
            func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { ClaudeCredentialSnapshot(reference: Data("native-ref".utf8), data: data) }
            func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot { throw ClaudeSystemCredentialError.keychain(errSecAuthFailed) }
            func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws { throw ClaudeSystemCredentialError.keychain(errSecAuthFailed) }
        }
        let helper = FakeHelper()
        helper.items[service + ":" + account] = payload
        let keychain = ClaudeResilientCredentialKeychain(native: ReadOnlyNative(data: payload), tool: ClaudeSecurityToolKeychain(run: helper.run))
        let nativeSnapshot = try XCTUnwrap(keychain.read(service: service, account: account))
        let newer = Data(#"{"claudeAiOauth":{"accessToken":"NEWER"}}"#.utf8)
        let written = try keychain.replace(service: service, account: account, expected: nativeSnapshot, data: newer)
        XCTAssertEqual(written.data, newer)
        XCTAssertEqual(keychain.backend(for: service), .securityTool)
        XCTAssertEqual(helper.items[service + ":" + account], newer)
    }

    /// A native store whose items carry only this app's partition until moved.
    private final class SharingNative: ClaudeCredentialKeychain, ClaudeCredentialKeychainSharing {
        var items: [String: [Data]] = [:]
        var helperOwned: Set<String> = []
        var failRemoval = false
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            items[service]?.last.map { ClaudeCredentialSnapshot(reference: Data("native:\(service)".utf8), data: $0) }
        }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            guard try read(service: service, account: account) == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            if expected == nil { items[service, default: []].append(data) } else { items[service]![items[service]!.count - 1] = data }
            return ClaudeCredentialSnapshot(reference: Data("native:\(service)".utf8), data: data)
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {}
        func needsHelperSharing(service: String, account: String) throws -> Bool? {
            guard let list = items[service], !list.isEmpty else { return nil }
            return !helperOwned.contains(service)
        }
        func removeAll(service: String, account: String) throws -> Int {
            if failRemoval { throw ClaudeSystemCredentialError.keychain(errSecAuthFailed) }
            let count = items[service]?.count ?? 0
            items[service] = nil
            return count
        }
    }

    func testNewItemsAreCreatedByTheHelperNotNatively() throws {
        let native = SharingNative()
        let helper = FakeHelper()
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: helper.run))
        XCTAssertNil(try keychain.read(service: service, account: account))
        _ = try keychain.replace(service: service, account: account, expected: nil, data: payload)
        XCTAssertEqual(helper.items[service + ":" + account], payload)
        XCTAssertTrue(native.items.isEmpty, "The native store must not receive new items")
        XCTAssertEqual(keychain.backend(for: service), .securityTool)
    }

    func testShareWithHelperMovesNativeItemsIncludingDuplicates() throws {
        let native = SharingNative()
        native.items[service] = [Data("{\"old\":1}".utf8), payload]
        let helper = FakeHelper()
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: helper.run))
        XCTAssertTrue(try keychain.shareWithHelper(service: service, account: account))
        XCTAssertNil(native.items[service], "Every app-created duplicate is removed")
        XCTAssertEqual(helper.items[service + ":" + account], payload, "The newest secret is what the helper stores")
        XCTAssertEqual(keychain.backend(for: service), .securityTool)
        XCTAssertFalse(try keychain.shareWithHelper(service: service, account: account), "Already shared: nothing to do")
        let created = try XCTUnwrap(helper.calls.first { $0.arguments == ["-i"] }?.input)
        XCTAssertTrue(String(decoding: created, as: UTF8.self).hasPrefix("add-generic-password -s "), "Created fresh, not updated")
    }

    func testShareWithHelperLeavesHelperOwnedAndMissingItemsAlone() throws {
        let native = SharingNative()
        let helper = FakeHelper()
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: helper.run))
        XCTAssertFalse(try keychain.shareWithHelper(service: service, account: account), "No item, nothing to move")
        native.items[service] = [payload]
        native.helperOwned.insert(service)
        XCTAssertFalse(try keychain.shareWithHelper(service: service, account: account))
        XCTAssertEqual(native.items[service], [payload])
        XCTAssertTrue(helper.calls.isEmpty, "The helper is never consulted for an item it already owns")
    }

    func testShareWithHelperRestoresTheSecretWhenTheHelperFails() throws {
        let native = SharingNative()
        native.items[service] = [payload]
        let helper = FakeHelper()
        helper.failWith = 1
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: helper.run))
        XCTAssertThrowsError(try keychain.shareWithHelper(service: service, account: account))
        XCTAssertEqual(native.items[service], [payload], "The native item is put back")
        XCTAssertEqual(keychain.backend(for: service), .native)
    }

    func testOtherNativeErrorsAreNotMasked() {
        let native = DenyingNative()
        native.status = errSecDecode
        let keychain = ClaudeResilientCredentialKeychain(native: native, tool: ClaudeSecurityToolKeychain(run: FakeHelper().run))
        XCTAssertThrowsError(try keychain.read(service: service, account: account)) { error in
            guard case ClaudeSystemCredentialError.keychain(let status) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, errSecDecode)
        }
        XCTAssertEqual(keychain.backend(for: service), .native)
    }
}
