import XCTest
import Security
@testable import Codenotch

final class ClaudeAccountDiagnosticsTests: XCTestCase {
    func testSerializedReportNeverContainsSecretsEmailOrPersistentReference() throws {
        let home = URL(fileURLWithPath: "/fixture-home"), root = home.appendingPathComponent("catalog")
        let account = ManagedAccount(id: UUID(), provider: .claude, label: "private@example.invalid", emailHint: "other@example.invalid", createdAt: Date())
        let mac = ClaudeCredentialLocation(directory: home.appendingPathComponent(".claude"), isDefault: true)
        let profile = ClaudeCredentialLocation(directory: root.appendingPathComponent("profiles/\(account.id.uuidString.lowercased())"), isDefault: false)
        let config = Data(#"{"oauthAccount":{"accountUuid":"private-account-uuid","organizationUuid":"private-org-uuid","emailAddress":"hidden@example.invalid"}}"#.utf8)
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"ACCESS-MUST-NOT-LEAK","refreshToken":"REFRESH-MUST-NOT-LEAK","expiresAt":2000000}}"#.utf8)
        let keychain = DiagnosticKeychainFixture()
        keychain.values[mac.service] = payload
        keychain.values[profile.service] = Data(payload.map { String(format: "%02x", $0) }.joined().utf8)
        let files = [root.appendingPathComponent("accounts.json"): try JSONEncoder().encode(AccountCatalog(accounts: [account])), mac.configURL: config, profile.configURL: config]
        var prompts: [Bool] = []
        let diagnostic = ClaudeAccountDiagnostics(keychain: keychain,
            interaction: KeychainInteraction(setInteraction: { prompts.append($0); return errSecSuccess }),
            readFile: { files[$0] }, now: { Date(timeIntervalSince1970: 1000) }, keychainAccount: "fixture")
        let bytes = try diagnostic.serialized(home: home, catalogRoot: root)
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["ACCESS-MUST-NOT-LEAK", "REFRESH-MUST-NOT-LEAK", "PERSISTENT-REFERENCE", "@", "private-account-uuid", "private-org-uuid", "emailAddress"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let report = try JSONDecoder().decode(ClaudeAccountDiagnostics.Report.self, from: bytes)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[1].matchesMac, true)
        XCTAssertEqual(report.entries[1].format, "hex_json")
        XCTAssertEqual(report.entries[1].expired, false)
        XCTAssertEqual(report.entries[1].hasAccess, true)
        XCTAssertEqual(report.entries[1].hasRefresh, true)
        XCTAssertEqual(prompts, [false, false])
        XCTAssertEqual(keychain.writes, 0)
        var completed: [ClaudeAccountDiagnostics.Entry] = []
        let streamed = diagnostic.collect(home: home, catalogRoot: root) { completed.append($0) }
        XCTAssertEqual(completed.map(\.id), streamed.entries.map(\.id))
        let progress = String(decoding: try JSONEncoder().encode(completed), as: UTF8.self)
        XCTAssertFalse(progress.contains("MUST-NOT-LEAK"))
        XCTAssertFalse(progress.contains("@"))
    }

    func testMalformedExpiredMissingAndDeniedRemainDistinct() throws {
        let home = URL(fileURLWithPath: "/fixture-home"), root = home.appendingPathComponent("catalog")
        let mac = ClaudeCredentialLocation(directory: home.appendingPathComponent(".claude"), isDefault: true)
        let keychain = DiagnosticKeychainFixture()
        var diagnostics = ClaudeAccountDiagnostics(keychain: keychain,
            interaction: KeychainInteraction(setInteraction: { XCTAssertFalse($0); return errSecSuccess }),
            readFile: { _ in nil }, now: { Date(timeIntervalSince1970: 1000) }, keychainAccount: "fixture")
        XCTAssertEqual(diagnostics.collect(home: home, catalogRoot: root).entries[0].credentialStatus, "missing")
        keychain.values[mac.service] = Data("not-json-secret".utf8)
        XCTAssertEqual(diagnostics.collect(home: home, catalogRoot: root).entries[0].format, "unknown")
        keychain.values[mac.service] = Data(#"{"claudeAiOauth":{"accessToken":"secret","refreshToken":"refresh","expiresAt":1}}"#.utf8)
        XCTAssertEqual(diagnostics.collect(home: home, catalogRoot: root).entries[0].expired, true)
        keychain.values[mac.service] = Data(#"{"claudeAiOauth":{"accessToken":"secret","expiresAt":true}}"#.utf8)
        let invalid = diagnostics.collect(home: home, catalogRoot: root).entries[0]
        XCTAssertEqual(invalid.credentialStatus, "invalid_expiry")
        XCTAssertNil(invalid.expired)
        XCTAssertEqual(invalid.hasRefresh, false)
        keychain.error = ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed)
        let denied = diagnostics.collect(home: home, catalogRoot: root).entries[0]
        XCTAssertEqual(denied.credentialStatus, "denied")
        XCTAssertNil(denied.hasAccess)
        XCTAssertEqual(denied.keychainStatus, errSecInteractionNotAllowed)
        diagnostics.readFile = { _ in Data("malformed-catalog".utf8) }
        XCTAssertEqual(diagnostics.collect(home: home, catalogRoot: root).catalogStatus, "invalid")
        XCTAssertEqual(keychain.writes, 0)
    }
}

private final class DiagnosticKeychainFixture: ClaudeCredentialKeychain {
    var values: [String: Data] = [:]
    var error: Error?
    var writes = 0
    func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
        if let error { throw error }
        return values[service].map { ClaudeCredentialSnapshot(reference: Data("PERSISTENT-REFERENCE".utf8), data: $0) }
    }
    func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
        writes += 1; XCTFail("Diagnostics must never mutate credentials"); throw ManagedAccountError.unavailable
    }
    func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
        writes += 1; XCTFail("Diagnostics must never restore credentials")
    }
}
