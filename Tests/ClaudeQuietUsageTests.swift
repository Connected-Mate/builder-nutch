import XCTest
import Security
@testable import Codenotch

final class ClaudeQuietUsageTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var reads = 0
        var error: Error?
        var expiry = Date().addingTimeInterval(3600)
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            reads += 1
            if let error { throw error }
            return ClaudeCredentialSnapshot(reference: Data([1]), data: try JSONSerialization.data(withJSONObject:
                ["claudeAiOauth": ["accessToken": "FAKE-TEST-ONLY", "expiresAt": expiry.timeIntervalSince1970 * 1000,
                                  "subscriptionType": "max"]]))
        }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            XCTFail("A usage read must never update credentials"); throw ManagedAccountError.unavailable
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            XCTFail("A usage read must never write credentials")
        }
    }

    private final class Transport: URLProtocol {
        static var requests = 0
        static var status = 200
        static var payload = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer FAKE-TEST-ONLY")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Retry-After": "120"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func fixture() throws -> (ClaudeQuietUsageReader, ClaudeCredentialLocation, Keychain) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("quiet-usage-\(UUID())")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let location = ClaudeCredentialLocation(directory: root, isDefault: false)
        try AccountStorage.write(JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": "A",
            "organizationUuid": "O", "emailAddress": "test@example.test"]]), to: location.configURL)
        let keychain = Keychain()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Transport.self]
        Transport.requests = 0; Transport.status = 200
        Transport.payload = Data(#"{"five_hour":{"utilization":23},"seven_day":{"utilization":60}}"#.utf8)
        return (ClaudeQuietUsageReader(credentials: ClaudeSystemCredentials(keychain: keychain),
            session: URLSession(configuration: configuration)), location, keychain)
    }

    func testReadsRealShapeWithoutWritingOrLaunchingCLI() async throws {
        let (reader, location, keychain) = try fixture()
        let state = try await reader.read(location, cancellation: AccountCancellation())
        XCTAssertEqual(state.email, "test@example.test")
        XCTAssertEqual(state.remainingPercent, 40)
        XCTAssertTrue(state.isFresh())
        XCTAssertEqual(keychain.reads, 1)
        XCTAssertEqual(Transport.requests, 1)
    }

    func testDeniedAccessAndExpiredLoginNeverReachNetwork() async throws {
        let (reader, location, keychain) = try fixture()
        keychain.error = ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed)
        do { _ = try await reader.read(location, cancellation: AccountCancellation()); XCTFail() }
        catch { XCTAssertTrue((error as? ClaudeSystemCredentialError)?.requiresAccess == true) }
        keychain.error = nil; keychain.expiry = .distantPast
        do { _ = try await reader.read(location, cancellation: AccountCancellation()); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ClaudeSystemCredentialError.expiredLogin.localizedDescription) }
        XCTAssertEqual(Transport.requests, 0)
    }

    func testRateLimitBackoffDoesNotReadKeychainOrRepeatNetwork() async throws {
        let (reader, location, keychain) = try fixture()
        Transport.status = 429
        for _ in 0..<3 {
            do { _ = try await reader.read(location, cancellation: AccountCancellation()); XCTFail() } catch {}
        }
        XCTAssertEqual(Transport.requests, 1)
        XCTAssertEqual(keychain.reads, 1)
    }

    func testMissingLimitsNeverBecomeZeroUsage() async throws {
        let (reader, location, _) = try fixture()
        Transport.payload = Data("{}".utf8)
        do { _ = try await reader.read(location, cancellation: AccountCancellation()); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.invalidResponse.localizedDescription) }
    }

    func testCancellationNeverTouchesKeychain() async throws {
        let (reader, location, keychain) = try fixture()
        let cancellation = AccountCancellation(); cancellation.cancel()
        do { _ = try await reader.read(location, cancellation: cancellation); XCTFail() } catch {}
        XCTAssertEqual(keychain.reads, 0)
    }

    func testLegacyGateNeverEnablesUIForBackgroundWork() throws {
        var flags: [Bool] = []
        let gate = KeychainInteraction { flags.append($0); return errSecSuccess }
        XCTAssertEqual(try gate.perform { 42 }, 42)
        XCTAssertEqual(flags, [false])
        XCTAssertThrowsError(try gate.perform(allowPrompt: true) { throw ManagedAccountError.cancelled })
        XCTAssertEqual(flags, [false, true, false])
    }

    func testGateFailureDoesNotExecuteKeychainOperation() {
        var executed = false
        let gate = KeychainInteraction { _ in errSecInteractionNotAllowed }
        XCTAssertThrowsError(try gate.perform { executed = true })
        XCTAssertFalse(executed)
    }

    @MainActor
    func testDeniedDiscoveryCreatesAnActionablePausedAccount() async throws {
        let (_, location, keychain) = try fixture()
        struct Denied: ClaudeAccountReading {
            func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
                throw ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed)
            }
        }
        struct NoCLI: AccountCommandRunning {
            func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
                XCTFail("Discovery must not spawn Claude"); throw ManagedAccountError.unavailable
            }
        }
        let manager = AccountManager(rootURL: location.directory.appendingPathComponent("catalog"), runner: NoCLI(),
            executable: { _ in URL(fileURLWithPath: "/fake/claude") },
            systemCredentials: ClaudeSystemCredentials(keychain: keychain),
            systemClaudeDirectory: location.directory.appendingPathComponent("default"), claudeReader: Denied())
        let candidate = ExistingAccountCandidate(provider: .claude, label: "Claude on this Mac",
            source: ExistingAccountProfile(directory: location.directory.standardizedFileURL.path, usesDefaultClaudeHome: false))
        await manager.discoverExistingAccounts(candidates: [candidate])
        let account = try XCTUnwrap(manager.accounts.first)
        XCTAssertTrue(manager.state(for: account).requiresKeychainAccess)
        XCTAssertFalse(manager.state(for: account).isConnected)
        XCTAssertEqual(manager.state(for: account).email, "test@example.test")
        XCTAssertEqual(keychain.reads, 0)
    }

    @MainActor
    func testStartupAndDeniedRefreshNeverLaunchCLIOrRepeatedlyAsk() async throws {
        let (_, location, keychain) = try fixture()
        let credentials = ClaudeSystemCredentials(keychain: keychain)
        final class Reader: ClaudeAccountReading {
            var reads = 0
            var denied = true
            func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
                reads += 1
                if denied { throw ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed) }
                return ManagedAccountState(isConnected: true, windows: [LimitWindow(id: "five_hour", label: "5h", usedFraction: 0.2)], refreshedAt: Date())
            }
        }
        struct NoCLI: AccountCommandRunning {
            func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
                XCTFail("Background Claude refresh must not spawn a CLI"); throw ManagedAccountError.unavailable
            }
        }
        let reader = Reader()
        let manager = AccountManager(rootURL: location.directory.appendingPathComponent("catalog"), runner: NoCLI(),
            executable: { _ in nil }, systemCredentials: credentials,
            systemClaudeDirectory: location.directory.appendingPathComponent("default"), claudeReader: reader)
        XCTAssertEqual(keychain.reads, 0, "Starting the manager must not repair or read secret data")
        let account = try manager.add(provider: .claude, label: "Claude", emailHint: nil)
        for _ in 0..<4 { await manager.refreshAll() }
        XCTAssertEqual(reader.reads, 1)
        XCTAssertTrue(manager.state(for: account).requiresKeychainAccess)
        reader.denied = false
        await manager.refresh(account)
        XCTAssertTrue(manager.state(for: account).isFresh())
        await manager.refreshAll()
        XCTAssertEqual(reader.reads, 3)
        manager.shutdown()
        await manager.refresh(account)
        await manager.refreshAll()
        XCTAssertEqual(reader.reads, 3)
    }
}
