import XCTest
@testable import Codenotch

/// One subscription must not occupy two rows. Nothing here touches a vendor's
/// files or its sign-in: only this app's own list of accounts changes.
final class DuplicateAccountMergeTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("merge-tests-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A discovered Kimi profile that a signed-in `~/.kimi-code` would produce.
    private func discoveredProfile(in root: URL, named name: String) throws -> ExistingAccountProfile {
        let directory = root.appendingPathComponent(name)
        try AccountStorage.privateDirectory(directory)
        return ExistingAccountProfile(directory: directory.path, usesDefaultClaudeHome: false)
    }

    @MainActor
    private func manager(_ root: URL) -> AccountManager {
        AccountManager(rootURL: root.appendingPathComponent("catalog"), runner: SilentRunner(),
                       executable: { _ in URL(fileURLWithPath: "/fake/kimi") })
    }

    @MainActor
    func testAnEmptyProfileWeCreatedIsMergedIntoTheConnectedOneOnThisMac() throws {
        let root = try temporary()
        let manager = self.manager(root)
        // "Kimi": added in the app, never signed in. Nothing was ever written
        // to its profile, which is exactly what makes it safe to drop.
        let empty = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        let real = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                  createdAt: Date(), existingProfile: source)
        manager.adoptForTesting(real, state: ManagedAccountState(isConnected: true, plan: "pro",
            windows: [LimitWindow(id: "primary", label: "Subscription limit", usedFraction: 0.2)], refreshedAt: Date()))

        let dropped = manager.mergeDuplicateAccounts()
        XCTAssertEqual(dropped.map(\.id), [empty.id])
        XCTAssertEqual(manager.accounts.map(\.id), [real.id])
        XCTAssertEqual(manager.selectedAccount(for: .kimi)?.id, real.id)
        XCTAssertTrue(manager.notice?.contains("Kimi") == true)
        // The person's own profile directory survives; only the row went away.
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.configurationDirectory(for: empty).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.directory))
        // Reloading the catalog must not resurrect the merged row.
        XCTAssertEqual(AccountManager(rootURL: root.appendingPathComponent("catalog")).accounts.count, 1)
    }

    @MainActor
    func testAProfileThatHasSignedInIsNeverMergedAway() throws {
        let root = try temporary()
        let manager = self.manager(root)
        let signedIn = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        // Real credentials in our own profile: this row stands on its own, even
        // while a refresh is failing and it reads as disconnected.
        let credentials = manager.configurationDirectory(for: signedIn).appendingPathComponent("credentials", isDirectory: true)
        try AccountStorage.privateDirectory(credentials)
        try AccountStorage.write(Data(#"{"access_token":"TEST-ONLY","refresh_token":"TEST-ONLY"}"#.utf8),
                                 to: credentials.appendingPathComponent("kimi-code.json"))
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        let real = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                  createdAt: Date(), existingProfile: source)
        manager.adoptForTesting(real, state: ManagedAccountState(isConnected: true, refreshedAt: Date()))

        XCTAssertTrue(manager.mergeDuplicateAccounts().isEmpty)
        XCTAssertEqual(manager.accounts.count, 2)
    }

    @MainActor
    func testTwoRowsTheProviderCallsTheSameAccountBecomeOneAndKeepTheConnectedRow() throws {
        let root = try temporary()
        let manager = self.manager(root)
        let mine = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        // A verified address from the provider, on a row that is not connected.
        manager.applyState({ $0.email = "Person@Example.Test" }, to: mine.id)
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        let real = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                  createdAt: Date(), existingProfile: source)
        manager.adoptForTesting(real, state: ManagedAccountState(isConnected: true, email: "person@example.test", refreshedAt: Date()))

        let dropped = manager.mergeDuplicateAccounts()
        XCTAssertEqual(dropped.map(\.id), [mine.id], "The connected row is the one the person keeps")
        XCTAssertEqual(manager.accounts.map(\.id), [real.id])
    }

    /// Writes a Kimi credential file whose access token carries `subject` as its
    /// account claim, the way the vendor's own sign-in does. Test-only tokens.
    private func writeKimiCredentials(in directory: URL, subject: String?) throws {
        let credentials = directory.appendingPathComponent("credentials", isDirectory: true)
        try AccountStorage.privateDirectory(credentials)
        func segment(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = subject.map { ["user_id": $0, "device_id": UUID().uuidString] } ?? ["device_id": UUID().uuidString]
        let token = try segment(["alg": "HS256", "typ": "JWT"]) + "." + segment(claims) + ".TEST-ONLY-signature"
        try AccountStorage.write(JSONSerialization.data(withJSONObject: [
            "access_token": token, "refresh_token": "TEST-ONLY-refresh"
        ]), to: credentials.appendingPathComponent("kimi-code.json"))
    }

    @MainActor
    func testOneSubscriptionSignedInOnTwoProfilesIsOneRow() throws {
        let root = try temporary()
        let manager = self.manager(root)
        // Both profiles hold real, different device registrations of the SAME
        // Moonshot subscription. No address exists anywhere to match them on.
        let mine = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        try writeKimiCredentials(in: manager.configurationDirectory(for: mine), subject: "sha1:02f9fc585189")
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        try writeKimiCredentials(in: URL(fileURLWithPath: source.directory), subject: "sha1:02f9fc585189")

        let fingerprint = try XCTUnwrap(source.kimiSubscriptionFingerprint())
        XCTAssertEqual(ExistingAccountProfile(directory: manager.configurationDirectory(for: mine).path,
                                              usesDefaultClaudeHome: false).kimiSubscriptionFingerprint(), fingerprint)
        XCTAssertFalse(fingerprint.contains("02f9fc585189"), "The account claim itself is never kept")

        manager.applyState({ $0.isConnected = true; $0.identity = fingerprint }, to: mine.id)
        let real = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                  createdAt: Date(), existingProfile: source)
        manager.adoptForTesting(real, state: ManagedAccountState(isConnected: true, identity: fingerprint, refreshedAt: Date()))

        XCTAssertEqual(manager.mergeDuplicateAccounts().map(\.id), [mine.id])
        XCTAssertEqual(manager.accounts.map(\.id), [real.id], "The vendor's own profile is the row that stays")
        // Neither sign-in was touched.
        XCTAssertEqual(ExistingAccountProfile(directory: manager.configurationDirectory(for: mine).path,
                                              usesDefaultClaudeHome: false).kimiAuthenticationStatus(), .present)
        XCTAssertEqual(source.kimiAuthenticationStatus(), .present)
    }

    @MainActor
    func testTwoDifferentSubscriptionsBothSurvive() throws {
        let root = try temporary()
        let manager = self.manager(root)
        let mine = try manager.add(provider: .kimi, label: "Kimi work", emailHint: nil)
        try writeKimiCredentials(in: manager.configurationDirectory(for: mine), subject: "sha1:aaaaaaaaaaaa")
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        try writeKimiCredentials(in: URL(fileURLWithPath: source.directory), subject: "sha1:bbbbbbbbbbbb")
        let other = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                   createdAt: Date(), existingProfile: source)
        manager.applyState({ $0.isConnected = true
            $0.identity = ExistingAccountProfile(directory: manager.configurationDirectory(for: mine).path,
                                                 usesDefaultClaudeHome: false).kimiSubscriptionFingerprint() }, to: mine.id)
        manager.adoptForTesting(other, state: ManagedAccountState(isConnected: true,
            identity: source.kimiSubscriptionFingerprint(), refreshedAt: Date()))

        XCTAssertTrue(manager.mergeDuplicateAccounts().isEmpty)
        XCTAssertEqual(manager.accounts.count, 2)
    }

    @MainActor
    func testATokenWeCannotReadNeverHidesASubscription() throws {
        let root = try temporary()
        let manager = self.manager(root)
        let mine = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        // Signed in, but the token carries no account claim we recognise.
        try writeKimiCredentials(in: manager.configurationDirectory(for: mine), subject: nil)
        let profile = ExistingAccountProfile(directory: manager.configurationDirectory(for: mine).path, usesDefaultClaudeHome: false)
        XCTAssertNil(profile.kimiSubscriptionFingerprint(), "An unverifiable identity must never merge two rows")
        XCTAssertEqual(profile.kimiAuthenticationStatus(), .present)

        manager.applyState({ $0.isConnected = true }, to: mine.id)
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        try writeKimiCredentials(in: URL(fileURLWithPath: source.directory), subject: "sha1:02f9fc585189")
        let real = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                  createdAt: Date(), existingProfile: source)
        manager.adoptForTesting(real, state: ManagedAccountState(isConnected: true,
            identity: source.kimiSubscriptionFingerprint(), refreshedAt: Date()))

        XCTAssertTrue(manager.mergeDuplicateAccounts().isEmpty)
        XCTAssertEqual(manager.accounts.count, 2)
    }

    @MainActor
    func testARowWithNoVerifiedIdentityIsNeverMergedByItsNickname() throws {
        let root = try temporary()
        let manager = self.manager(root)
        // Same nickname, same typed hint, no verified identity anywhere: two
        // separate subscriptions must survive being named alike.
        _ = try manager.add(provider: .kimi, label: "Kimi", emailHint: "person@example.test")
        let second = try manager.add(provider: .kimi, label: "Kimi", emailHint: "person@example.test")
        manager.applyState({ $0.isConnected = true }, to: second.id)
        XCTAssertTrue(manager.mergeDuplicateAccounts().isEmpty)
        XCTAssertEqual(manager.accounts.count, 2)
    }

    @MainActor
    func testAnEmptyProfileSurvivesWhenThereIsNoConnectedProfileToMergeInto() throws {
        let root = try temporary()
        let manager = self.manager(root)
        let empty = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        let source = try discoveredProfile(in: root, named: ".kimi-code")
        let other = ManagedAccount(id: UUID(), provider: .kimi, label: "Kimi · on this Mac",
                                   createdAt: Date(), existingProfile: source)
        // The discovered row is not connected either, so nothing is proven.
        manager.adoptForTesting(other, state: ManagedAccountState(message: "Refresh to check this account."))
        XCTAssertTrue(manager.mergeDuplicateAccounts().isEmpty)
        XCTAssertEqual(Set(manager.accounts.map(\.id)), [empty.id, other.id])
    }
}

private struct SilentRunner: AccountCommandRunning {
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        throw ManagedAccountError.unavailable
    }
}
