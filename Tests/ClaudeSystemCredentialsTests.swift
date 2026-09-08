import XCTest
import Darwin
@testable import Codenotch

final class ClaudeSystemCredentialsTests: XCTestCase {
    private final class MemoryKeychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        var reads = 0
        var beforeRead: ((Int) -> Void)?
        var writes = 0

        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            reads += 1
            beforeRead?(reads)
            return items[service + ":" + account]
        }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            let key = service + ":" + account
            guard items[key] == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let item = ClaudeCredentialSnapshot(reference: expected?.reference ?? Data(UUID().uuidString.utf8), data: data)
            items[key] = item
            writes += 1
            return item
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            let key = service + ":" + account
            guard items[key] == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
            items[key] = previous
        }
    }

    private let expected = ClaudeCredentialIdentity(accountID: "account-A", organizationID: "org-A", email: "a@example.test")
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    private func fixture() throws -> (ClaudeCredentialLocation, ClaudeCredentialLocation, MemoryKeychain) {
        let resolved = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("ClaudeSystemCredentialsTests-\(UUID().uuidString)")
        let source = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude-saved"), isDefault: false)
        let target = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        for directory in [source.directory, target.directory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try json(["oauthAccount": ["accountUuid": expected.accountID, "organizationUuid": expected.organizationID, "emailAddress": expected.email, "displayName": "Saved"], "sourceOnly": true]).write(to: source.configURL)
        try json(["oauthAccount": ["accountUuid": "old", "organizationUuid": "old-org", "emailAddress": "old@example.test"], "projects": ["/my-project": ["trusted": true]], "theme": "dark"]).write(to: target.configURL)
        let keychain = MemoryKeychain()
        keychain.items[source.service + ":tester"] = ClaudeCredentialSnapshot(reference: Data("source".utf8), data: try json(["claudeAiOauth": ["accessToken": "fake-source-access", "refreshToken": "fake-source-refresh", "expiresAt": (fixedNow.timeIntervalSince1970 + 3600) * 1000], "mcpOAuth": ["source": "must-not-copy"]]))
        keychain.items[target.service + ":tester"] = ClaudeCredentialSnapshot(reference: Data("target".utf8), data: try json(["claudeAiOauth": ["accessToken": "fake-old-access"], "mcpOAuth": ["target": "preserved"], "otherSecret": "preserved"]))
        return (source, target, keychain)
    }

    func testCopyPreservesTargetSettingsAndOtherSecretsAndDoesNotChangeSource() throws {
        let (source, target, keychain) = try fixture()
        let oldSourceFile = try Data(contentsOf: source.configURL)
        let oldSourceSecret = keychain.items[source.service + ":tester"]
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        try manager.copyLogin(from: source, to: target, expectedIdentity: expected)
        XCTAssertEqual(try manager.identity(at: target), expected)
        let config = try object(Data(contentsOf: target.configURL))
        XCTAssertEqual(config["theme"] as? String, "dark")
        XCTAssertNotNil(config["projects"])
        XCTAssertNil(config["sourceOnly"])
        let payload = try object(XCTUnwrap(keychain.items[target.service + ":tester"]).data)
        XCTAssertEqual((payload["mcpOAuth"] as? [String: String])?["target"], "preserved")
        XCTAssertEqual(payload["otherSecret"] as? String, "preserved")
        XCTAssertEqual((payload["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "fake-source-access")
        XCTAssertEqual(try Data(contentsOf: source.configURL), oldSourceFile)
        XCTAssertEqual(keychain.items[source.service + ":tester"], oldSourceSecret)
    }

    func testShutdownCancelsCopyBeforeCommitButAllowsTransactionRecovery() throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        let oldFile = try Data(contentsOf: target.configURL)
        manager.requestStop()
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(try Data(contentsOf: target.configURL), oldFile)
        try manager.copyLogin(from: source, to: target, expectedIdentity: expected, completingTransaction: true)
        XCTAssertEqual(try manager.identity(at: target), expected)
        manager.waitUntilIdle()
    }

    func testShutdownCancelsContendedStorageLockPromptly() async throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        let lock = target.directory.appendingPathComponent(".storage-write.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let copying = Task.detached { try manager.copyLogin(from: source, to: target, expectedIdentity: self.expected) }
        try await Task.sleep(nanoseconds: 80_000_000)
        let start = Date()
        manager.requestStop()
        do { try await copying.value; XCTFail("The pending switch must cancel") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(keychain.writes, 0)
    }

    func testConfigFailureRestoresOldCredential() throws {
        let (source, target, keychain) = try fixture()
        let before = keychain.items
        let oldFile = try Data(contentsOf: target.configURL)
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow }, writeConfig: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.items, before)
        XCTAssertEqual(try Data(contentsOf: target.configURL), oldFile)
    }

    func testConfigFailureRemovesOnlyNewlyCreatedCredential() throws {
        let (source, target, keychain) = try fixture()
        keychain.items[target.service + ":tester"] = nil
        let before = keychain.items
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow }, writeConfig: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.items, before)
    }

    func testRollbackDoesNotOverwriteConcurrentLogin() throws {
        let (source, target, keychain) = try fixture()
        let newer = ClaudeCredentialSnapshot(reference: Data("newer".utf8), data: Data("newer-login".utf8))
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow }, writeConfig: { _, _, _ in
            keychain.items[target.service + ":tester"] = newer
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected)) { error in
            guard case ClaudeSystemCredentialError.rollbackFailed = error else { return XCTFail("Expected rollback conflict") }
        }
        XCTAssertEqual(keychain.items[target.service + ":tester"], newer)
    }

    func testExpectedIdentityMismatchNeverWrites() throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: .init(accountID: "wrong", organizationID: "org-A", email: expected.email)))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testKeychainPayloadRemainsPrintableJSONForOfficialSecurityHelper() throws {
        let payload: [String: Any] = ["claudeAiOauth": ["accessToken": "fake-token"], "otherSecret": "café 🌍\nline"]
        let data = try ClaudeSystemCredentials.encodeKeychainPayload(payload)
        XCTAssertTrue(data.allSatisfy { (0x20...0x7e).contains($0) })
        XCTAssertEqual(try object(data)["otherSecret"] as? String, "café 🌍\nline")
        let (source, target, keychain) = try fixture()
        try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected)
        XCTAssertTrue(try XCTUnwrap(keychain.items[target.service + ":tester"]).data.allSatisfy { (0x20...0x7e).contains($0) })
    }

    func testPrettyPrintedLoginRecoveryKeepsSameCredentialAndIdentity() throws {
        let (source, _, keychain) = try fixture()
        let before = try XCTUnwrap(keychain.items[source.service + ":tester"])
        let payload = try object(before.data)
        keychain.items[source.service + ":tester"] = ClaudeCredentialSnapshot(reference: before.reference,
            data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]))
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        try manager.repairEncoding(at: source)
        let recovered = try XCTUnwrap(keychain.items[source.service + ":tester"])
        XCTAssertTrue(recovered.data.allSatisfy { (0x20...0x7e).contains($0) })
        XCTAssertEqual(try object(recovered.data) as NSDictionary, payload as NSDictionary)
        XCTAssertEqual(try manager.identity(at: source), expected)
    }

    func testExpiredSourceNeverWrites() throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow.addingTimeInterval(7200) })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected)) { error in
            guard case ClaudeSystemCredentialError.expiredLogin = error else { return XCTFail("Expected expiry") }
        }
        XCTAssertEqual(keychain.writes, 0)
    }

    func testExpiredOutgoingLoginCanBePreservedBeforeSwitching() throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow.addingTimeInterval(7200) })
        try manager.copyLogin(from: source, to: target, expectedIdentity: expected, allowExpired: true)
        XCTAssertEqual(try manager.identity(at: target), expected)
        XCTAssertEqual(keychain.writes, 1)
    }

    func testSymlinkConfigIsRefused() throws {
        let (source, target, keychain) = try fixture()
        let elsewhere = target.directory.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: target.configURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: target.configURL, withDestinationURL: elsewhere)
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testFallbackCredentialsAreRefused() throws {
        let (source, target, keychain) = try fixture()
        try Data("{\"claudeAiOauth\": {}}".utf8).write(to: target.directory.appendingPathComponent(".credentials.json"))
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testSourceChangedDuringCopyNeverWrites() throws {
        let (source, target, keychain) = try fixture()
        keychain.beforeRead = { count in
            if count == 3 { keychain.items[source.service + ":tester"] = nil }
        }
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testDefaultLoginCanBeSavedIntoPrivateProfile() throws {
        let (source, target, keychain) = try fixture()
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
        try manager.copyLogin(from: source, to: target, expectedIdentity: expected)
        let defaultBefore = try Data(contentsOf: target.configURL)
        try manager.copyLogin(from: target, to: source, expectedIdentity: expected)
        XCTAssertEqual(try manager.identity(at: source), expected)
        XCTAssertEqual(try Data(contentsOf: target.configURL), defaultBefore)
    }

    func testSameLocationDoesNotWrite() throws {
        let (source, _, keychain) = try fixture()
        try ClaudeSystemCredentials(keychain: keychain, account: "tester").copyLogin(from: source, to: source, expectedIdentity: expected)
        XCTAssertEqual(keychain.writes, 0)
    }

    func testMarkerFailureRestoresConfigAndCredential() throws {
        let (source, target, keychain) = try fixture()
        let beforeSecret = keychain.items
        let beforeConfig = try Data(contentsOf: target.configURL)
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow },
            invalidateCache: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.items, beforeSecret)
        XCTAssertEqual(try Data(contentsOf: target.configURL), beforeConfig)
    }

    func testMarkerFailureDoesNotOverwriteConcurrentConfig() throws {
        let (source, target, keychain) = try fixture()
        let beforeSecret = keychain.items
        let newerConfig = Data("{\"newer\": true}".utf8)
        let manager = ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow },
            invalidateCache: { _ in
                try newerConfig.write(to: target.configURL)
                throw CocoaError(.fileWriteNoPermission)
            })
        XCTAssertThrowsError(try manager.copyLogin(from: source, to: target, expectedIdentity: expected)) { error in
            guard case ClaudeSystemCredentialError.rollbackFailed = error else { return XCTFail("Expected rollback conflict") }
        }
        XCTAssertEqual(keychain.items, beforeSecret)
        XCTAssertEqual(try Data(contentsOf: target.configURL), newerConfig)
    }

    func testCopyCreatesSecretlessPrivateCacheMarker() throws {
        let (source, target, keychain) = try fixture()
        try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected)
        let marker = target.directory.appendingPathComponent(".credentials.json")
        XCTAssertTrue(try object(Data(contentsOf: marker)).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.directory.appendingPathComponent(".credentials.json").path))
    }

    func testExistingEmptyMarkerIsInvalidatedAndPreserved() throws {
        let (source, target, keychain) = try fixture()
        let marker = target.directory.appendingPathComponent(".credentials.json")
        try Data("{}\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: marker.path)
        try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected)
        XCTAssertEqual(try Data(contentsOf: marker), Data("{}\n".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertNotEqual(attributes[.modificationDate] as? Date, fixedNow)
    }

    func testIdentityUsesStableIDsInsteadOfEmailCase() {
        XCTAssertEqual(expected, .init(accountID: expected.accountID, organizationID: expected.organizationID, email: "A@EXAMPLE.TEST"))
    }

    func testStaleEmptyMarkerIsRecoveredButFreshMarkerStays() throws {
        let (_, target, _) = try fixture()
        let marker = target.directory.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: marker.path)
        try ClaudeSystemCredentials.cleanupStaleCacheMarker(at: target, now: fixedNow.addingTimeInterval(10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try ClaudeSystemCredentials.cleanupStaleCacheMarker(at: target, now: fixedNow.addingTimeInterval(36))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCleanupNeverRemovesRealFallbackCredentials() throws {
        let (_, target, _) = try fixture()
        let marker = target.directory.appendingPathComponent(".credentials.json")
        let content = Data("{\"claudeAiOauth\": {\"accessToken\": \"fake\"}}".utf8)
        try content.write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: marker.path)
        XCTAssertThrowsError(try ClaudeSystemCredentials.cleanupStaleCacheMarker(at: target, now: fixedNow.addingTimeInterval(36)))
        XCTAssertEqual(try Data(contentsOf: marker), content)
    }

    func testStaleClaudeStorageLockIsRecoveredAndReleased() throws {
        let (source, target, keychain) = try fixture()
        let lock = target.directory.appendingPathComponent(".storage-write.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20)], ofItemAtPath: lock.path)
        try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.directory.appendingPathComponent(".storage-write.lock").path))
    }

    func testSymlinkStorageLockIsRefusedWithoutWriting() throws {
        let (source, target, keychain) = try fixture()
        let lock = target.directory.appendingPathComponent(".storage-write.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: source.directory)
        XCTAssertThrowsError(try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected))
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.directory.path))
    }

    func testFailureReleasesStorageLocks() throws {
        let (source, target, keychain) = try fixture()
        XCTAssertThrowsError(try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: .init(accountID: "wrong", organizationID: "wrong", email: "wrong")))
        for location in [source, target] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.appendingPathComponent(".storage-write.lock").path))
        }
    }

    func testCopyWaitsForOfficialConfigWriterAndPreservesItsChange() throws {
        let (source, target, keychain) = try fixture()
        let configLock = URL(fileURLWithPath: target.configURL.path + ".lock")
        try FileManager.default.createDirectory(at: configLock, withIntermediateDirectories: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            var config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: target.configURL))) as? [String: Any] ?? [:]
            config["concurrentSetting"] = "keep"
            if let bytes = try? JSONSerialization.data(withJSONObject: config) { try? bytes.write(to: target.configURL) }
            try? FileManager.default.removeItem(at: configLock)
        }
        try ClaudeSystemCredentials(keychain: keychain, account: "tester", now: { self.fixedNow })
            .copyLogin(from: source, to: target, expectedIdentity: expected)
        XCTAssertEqual(try object(Data(contentsOf: target.configURL))["concurrentSetting"] as? String, "keep")
    }

    func testRestartRearmsFreshMarkerCleanup() async throws {
        let (_, target, _) = try fixture()
        let marker = target.directory.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: marker)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date)
        try ClaudeSystemCredentials.cleanupStaleCacheMarker(at: target, now: modified.addingTimeInterval(34.99))
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMarkerCleanupWaitsForStorageWriterAndRetainsNewFallbackCredentials() throws {
        let (_, target, _) = try fixture()
        let marker = target.directory.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: marker)
        let storageLock = target.directory.appendingPathComponent(".storage-write.lock")
        try FileManager.default.createDirectory(at: storageLock, withIntermediateDirectories: false)
        let fallback = Data(#"{"claudeAiOauth":{"accessToken":"fake-fallback"}}"#.utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            try? fallback.write(to: marker, options: .atomic)
            try? FileManager.default.removeItem(at: storageLock)
        }
        XCTAssertThrowsError(try ClaudeSystemCredentials.cleanupStaleCacheMarker(at: target, now: Date().addingTimeInterval(60)))
        XCTAssertEqual(try Data(contentsOf: marker), fallback)
    }

    func testUsernameMatchesClaudeRules() {
        XCTAssertEqual(ClaudeSystemCredentials.keychainAccount(environment: ["USER": "a.user-2_"], username: "fallback"), "a.user-2_")
        XCTAssertEqual(ClaudeSystemCredentials.keychainAccount(environment: ["USER": "bad user"], username: "fallback"), "fallback")
        XCTAssertEqual(ClaudeSystemCredentials.keychainAccount(environment: [:], username: ""), "claude-code-user")
    }
}
