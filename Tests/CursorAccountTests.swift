import XCTest
import SQLite3
@testable import Codenotch

/// Cursor as a real usage row: the editor's own login, read-only, with no
/// rotation and no browser profile involved.
///
/// Every fixture here is synthetic. The tokens are strings shaped like a JWT,
/// signed by nobody, and the store is one this test wrote itself — no real
/// Cursor installation is touched, and nothing runs against the network.
final class CursorAccountTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-tests-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A `state.vscdb` with the same one-table shape Cursor inherits from VS Code.
    @discardableResult
    private func writeStore(in directory: URL, rows: [String: String]) throws -> URL {
        let url = CursorAccountIntegration.store(in: directory)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil), SQLITE_OK)
        for (key, value) in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }

    /// Header-payload-signature, base64url, unsigned. Only the payload is ever read.
    private func token(subject: String) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return segment(["alg": "none"]) + "." + segment(["sub": subject]) + ".signature"
    }

    private func signedIn(in directory: URL, email: String = "person@example.com",
                          plan: String = "pro", authID: String? = "user_ABC") throws {
        var rows = ["cursorAuth/accessToken": token(subject: "auth0|user_ABC"),
                    "cursorAuth/cachedEmail": email,
                    "cursorAuth/stripeMembershipType": plan]
        if let authID { rows["cursorAuth/stripeMembershipAuthId"] = authID }
        try writeStore(in: directory, rows: rows)
    }

    /// Verbatim from a live free account, and the same recording `CursorUsageTests` pins.
    private let recorded = """
    {"billingCycleStart":"2026-08-24T03:32:15.933Z",
     "billingCycleEnd":"2026-09-24T03:32:15.933Z",
     "membershipType":"free","limitType":"user","isUnlimited":false,
     "individualUsage":{
       "plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
               "breakdown":{"included":0,"bonus":19,"total":19},
               "autoPercentUsed":0,"apiPercentUsed":19,"totalPercentUsed":9.5},
       "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
     "teamUsage":{}}
    """

    // MARK: - Reading the editor's login

    func testReadsTheEditorsOwnSessionPair() throws {
        let directory = try temporary()
        try signedIn(in: directory)
        let credentials = try CursorCredentials.load(from: CursorAccountIntegration.store(in: directory))
        XCTAssertEqual(credentials.accountID, "user_ABC")
        XCTAssertEqual(credentials.sessionCookie, "WorkosCursorSessionToken=user_ABC::\(credentials.accessToken)")
        let identity = try XCTUnwrap(CursorCredentials.account(from: CursorAccountIntegration.store(in: directory)))
        XCTAssertEqual(identity.label, "person@example.com")
        XCTAssertEqual(identity.plan, "pro")
    }

    /// Current community readers no longer look for `stripeMembershipAuthId` and
    /// take the id from the token's own `sub` claim, minus the provider prefix.
    func testFallsBackToTheTokensOwnSubjectClaim() throws {
        let directory = try temporary()
        try signedIn(in: directory, authID: nil)
        let credentials = try CursorCredentials.load(from: CursorAccountIntegration.store(in: directory))
        XCTAssertEqual(credentials.accountID, "user_ABC")
        XCTAssertNil(CursorCredentials.accountID(fromAccessToken: "not-a-jwt"))
    }

    /// The state this Mac is actually in today: the store exists, and the only
    /// `cursorAuth` row in it is the membership type. That must be a quiet "no",
    /// not an error, and it must never reach the network.
    @MainActor
    func testSignedOutEditorYieldsNoRowAndNoRequest() async throws {
        let directory = try temporary()
        try writeStore(in: directory, rows: ["cursorAuth/stripeMembershipType": "free"])
        XCTAssertFalse(CursorAccountIntegration.isSignedIn(directory: directory))
        let http = CursorHTTPStub(result: .success((Data(), 200)))
        let state = try await CursorAccountIntegration.read(directory: directory,
                                                           cancellation: AccountCancellation(), http: http)
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.message, CursorAccountIntegration.signedOutMessage)
        XCTAssertEqual(http.requests.count, 0, "a signed-out editor must not be asked about on the network")
    }

    @MainActor
    func testAMissingStoreIsSignedOutRatherThanAFailure() async throws {
        let directory = try temporary()
        XCTAssertFalse(CursorAccountIntegration.isSignedIn(directory: directory))
        let state = try await CursorAccountIntegration.read(directory: directory,
                                                            cancellation: AccountCancellation(),
                                                            http: CursorHTTPStub(result: .success((Data(), 200))))
        XCTAssertEqual(state.message, CursorAccountIntegration.signedOutMessage)
    }

    // MARK: - The request and the row

    @MainActor
    func testSendsTheSessionCookieToCursorAndBuildsTheRow() async throws {
        let directory = try temporary()
        try signedIn(in: directory)
        let http = CursorHTTPStub(result: .success((Data(recorded.utf8), 200)))
        let now = Date()
        let state = try await CursorAccountIntegration.read(directory: directory,
                                                           cancellation: AccountCancellation(), http: http, now: now)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://cursor.com/api/usage-summary"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_ABC::"), true)
        XCTAssertEqual(request.httpShouldHandleCookies, false)
        XCTAssertEqual(request.timeoutInterval, 15)

        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.email, "person@example.com")
        XCTAssertEqual(state.plan, "Pro")
        XCTAssertEqual(state.refreshedAt, now)
        XCTAssertEqual(state.windows.map(\.id), ["included", "api"])
        XCTAssertEqual(state.windows[0].usedFraction ?? -1, 0.095, accuracy: 0.0001)
        XCTAssertNotNil(state.windows[0].resetsAt)
        XCTAssertNil(state.windows[0].derivedReset, "billingCycleEnd is Cursor's own timestamp, not a derivation")
        // The ring means the window Cursor's own dashboard leads with.
        let account = ManagedAccount(id: UUID(), provider: .cursor, label: "Cursor · on this Mac",
                                     createdAt: now, existingProfile: ExistingAccountProfile(directory: directory.path, usesDefaultClaudeHome: false))
        XCTAssertEqual(AccountManager.headlineID(for: account), "included")
    }

    @MainActor
    func testARefusedSessionAsksForASignInRatherThanReportingAFailure() async throws {
        let directory = try temporary()
        try signedIn(in: directory)
        let state = try await CursorAccountIntegration.read(directory: directory, cancellation: AccountCancellation(),
                                                           http: CursorHTTPStub(result: .success((Data("{}".utf8), 401))))
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.requiresSignIn)
        XCTAssertEqual(state.email, "person@example.com")
    }

    @MainActor
    func testAServerErrorIsAnErrorAndNotAnEmptyReading() async throws {
        let directory = try temporary()
        try signedIn(in: directory)
        let http = CursorHTTPStub(result: .success((Data("nope".utf8), 500)))
        do {
            _ = try await CursorAccountIntegration.read(directory: directory, cancellation: AccountCancellation(), http: http)
            XCTFail("expected the read to fail")
        } catch { XCTAssertNotNil((error as? LocalizedError)?.errorDescription) }
    }

    /// A plan with no metered allowance is a fact about the plan. It stays
    /// connected, says so in words, and takes no timestamp — so nothing
    /// downstream can mistake it for a fresh zero.
    func testNothingMeteredStaysConnectedWithoutAFreshReading() throws {
        let body = #"{"membershipType":"free","individualUsage":{"plan":{}}}"#
        let state = try CursorAccountIntegration.state(
            usage: Data(body.utf8),
            identity: ProviderAccount(label: "person@example.com", plan: "free", source: "Cursor", manageURL: nil))
        XCTAssertTrue(state.isConnected)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertNil(state.refreshedAt)
        XCTAssertEqual(state.plan, "Free")
        XCTAssertEqual(state.message, "The free plan has nothing for Cursor to meter yet.")
    }

    /// Buckets named by the current community reader but never seen live here.
    /// An unexpected shape must produce no row at all.
    func testUnverifiedTeamBucketsFailClosed() throws {
        let vague = """
        {"individualUsage":{"plan":{"totalPercentUsed":5},"overall":{"percentUsed":80}},
         "teamUsage":{"pooled":{"percentUsed":90}}}
        """
        XCTAssertEqual(try CursorUsage.windows(fromJSON: vague).map(\.id), ["included"])

        let stated = """
        {"individualUsage":{"plan":{"totalPercentUsed":5},
                            "overall":{"enabled":true,"used":10,"limit":40}},
         "teamUsage":{"pooled":{"enabled":true,"used":25,"limit":100},
                      "onDemand":{"enabled":false,"used":0,"limit":null}}}
        """
        let windows = try CursorUsage.windows(fromJSON: stated)
        XCTAssertEqual(windows.map(\.id), ["included", "personal_cap", "team_pool"])
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0.25, accuracy: 0.0001)
    }

    // MARK: - Discovery

    @MainActor
    func testDiscoveryAddsTheEditorsAccountAndNeverRotatesIt() async throws {
        let root = try temporary(), store = try temporary()
        try signedIn(in: store)
        let manager = AccountManager(rootURL: root, runner: CursorNoRunner(),
                                     executable: { _ in nil },
                                     readCursor: { directory, cancellation in
                                         try await CursorAccountIntegration.read(
                                            directory: directory, cancellation: cancellation,
                                            http: CursorHTTPStub(result: .success((Data(self.recorded.utf8), 200))))
                                     })
        let candidate = ExistingAccountCandidate(provider: .cursor, label: "Cursor · on this Mac",
            source: ExistingAccountProfile(directory: store.path, usesDefaultClaudeHome: false))
        await manager.discoverExistingAccounts(candidates: [candidate])

        let account = try XCTUnwrap(manager.accounts.first)
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(account.provider, .cursor)
        XCTAssertEqual(account.label, "Cursor · on this Mac")
        XCTAssertTrue(account.readsDesktopUsage)
        XCTAssertFalse(account.isBrowserOnly, "the discovered row is a reading, not a browser profile")
        XCTAssertTrue(manager.state(for: account).isConnected)
        XCTAssertEqual(manager.state(for: account).windows.map(\.id), ["included", "api"])

        // No executable was resolved, and no process was ever launched.
        XCTAssertEqual(manager.snapshot(for: account).fidelity, .official)
        XCTAssertEqual(manager.snapshot(for: account).headlineID, "included")

        // Cursor is read, never rotated: the editor owns its own login.
        XCTAssertFalse(AccountProvider.cursor.supportsAutomaticSelection)
        XCTAssertNil(AccountSelection.rotating(provider: .cursor, accounts: manager.accounts,
                                               states: [account.id: manager.state(for: account)],
                                               order: [], currentID: nil, thresholdPercent: 15))
        XCTAssertNil(manager.rotationOrder[.cursor])

        // A row this app created for the Cursor dashboard stays a browser profile.
        let browserRow = try manager.add(provider: .cursor, label: "Cursor dashboard", emailHint: nil)
        XCTAssertTrue(browserRow.isBrowserOnly)
        XCTAssertFalse(browserRow.readsDesktopUsage)

        // And it survives a reload: the catalog accepts a Cursor row with a
        // vendor directory, which it refuses for every other browser provider.
        let restored = AccountManager(rootURL: root, runner: CursorNoRunner(), executable: { _ in nil })
        XCTAssertEqual(restored.accounts.count, 2)
        XCTAssertEqual(restored.accounts.first?.existingProfile?.directory, store.path)
    }

    /// Signing out of the editor removes the row, exactly as it does for Kimi.
    @MainActor
    func testSigningOutOfTheEditorRemovesTheRow() async throws {
        let root = try temporary(), store = try temporary()
        try signedIn(in: store)
        let manager = AccountManager(rootURL: root, runner: CursorNoRunner(), executable: { _ in nil },
                                     readCursor: { directory, cancellation in
                                         try await CursorAccountIntegration.read(
                                            directory: directory, cancellation: cancellation,
                                            http: CursorHTTPStub(result: .success((Data(self.recorded.utf8), 200))))
                                     })
        let candidate = ExistingAccountCandidate(provider: .cursor, label: "Cursor · on this Mac",
            source: ExistingAccountProfile(directory: store.path, usesDefaultClaudeHome: false))
        await manager.discoverExistingAccounts(candidates: [candidate])
        XCTAssertEqual(manager.accounts.count, 1)

        try writeStore(in: store, rows: ["cursorAuth/accessToken": ""])
        await manager.discoverExistingAccounts(candidates: [], now: Date().addingTimeInterval(2000))
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CursorAccountIntegration.store(in: store).path),
                      "Cursor's own files are never touched")
    }

    /// The candidate list is where a dormant provider would get wired in by
    /// accident. Only these four ever appear, and Cursor only while signed in.
    func testOnlySignedInDesktopAppsBecomeCandidates() throws {
        let home = try temporary()
        XCTAssertTrue(ExistingAccountDiscovery.candidates(home: home, environment: [:]).isEmpty)

        let globalStorage = CursorAccountIntegration.globalStorage(home: home)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try writeStore(in: globalStorage, rows: ["cursorAuth/stripeMembershipType": "free"])
        XCTAssertTrue(ExistingAccountDiscovery.candidates(home: home, environment: [:]).isEmpty,
                      "a signed-out editor is not an account")

        try signedIn(in: globalStorage)
        let candidates = ExistingAccountDiscovery.candidates(home: home, environment: [:])
        XCTAssertEqual(candidates.map(\.provider), [.cursor])
        XCTAssertEqual(candidates.first?.label, "Cursor · on this Mac")

        // Antigravity/Gemini and the other dormant adapters stay dormant: nothing
        // discovers them, and nothing marks them as readable on the desktop.
        for provider in AccountProvider.allCases where provider != .cursor {
            XCTAssertFalse(provider.readsDesktopUsage, "\(provider.rawValue) must not be wired in")
        }
    }
}

/// Records what was asked, answers what the test decided. No network.
private final class CursorHTTPStub: CursorHTTPFetching, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let result: Result<(Data, Int), Error>
    init(result: Result<(Data, Int), Error>) { self.result = result }
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status) = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

/// Fails every command, so a test that accidentally launches a process fails loudly.
private struct CursorNoRunner: AccountCommandRunning {
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        throw ManagedAccountError.unavailable
    }
}
