import Foundation
import XCTest
@testable import Codenotch

@MainActor
final class KimiAccountIntegrationTests: XCTestCase {
    private let auth: [String: Any] = ["ready": true, "providers_count": 1,
        "default_model": "kimi", "managed_provider": ["name": "managed:kimi-code", "status": "authenticated"]]

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-fake-tests-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testInstalledUsageSchemaAndNoInventedReset() throws {
        let usage: [String: Any] = ["kind": "ok", "summary": ["label": "Weekly", "used": 80, "limit": 100, "reset_hint": "in 2 days"],
            "limits": [["label": "Weekly", "used": 80, "limit": 100], ["label": "5h", "used": 25, "limit": 100]],
            "extra_usage": ["balance_cents": 999_999, "total_cents": 999_999]]
        let now = Date()
        let state = try KimiAccountIntegration.state(auth: auth, usage: usage, now: now)
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.windows.count, 2, "Summary duplicate must not become a second window")
        XCTAssertEqual(state.windows.first?.id, "primary")
        XCTAssertEqual(state.remainingPercent ?? -1, 20, accuracy: 0.001)
        XCTAssertNil(state.windows.first?.resetsAt, "reset_hint must never manufacture a date")
        XCTAssertEqual(state.refreshedAt, now)
    }

    func testCurrentUsageAndAuthSchema() throws {
        let currentAuth: [String: Any] = ["models_ready": true, "managed_provider": ["name": "managed:kimi-code", "status": "authenticated"]]
        let usage: [String: Any] = ["kind": "ok", "summary": NSNull(), "limits": [
            ["name": "Weekly", "used": 110, "limit": 100, "reset_at": "2026-10-01T10:00:00Z"],
            ["window": ["duration": 15, "unit": "minute"], "used": 2, "limit": 10]]]
        let state = try KimiAccountIntegration.state(auth: currentAuth, usage: usage)
        XCTAssertEqual(state.remainingPercent, 0)
        XCTAssertNotNil(state.windows.first?.resetsAt)
        XCTAssertEqual(state.windows.last?.label, "15 minute limit")
        XCTAssertEqual(state.windows.first?.usedFraction, 1)
    }

    func testAPIKeyAndExpiredAuthNeverCountAsSubscription() throws {
        let apiKey: [String: Any] = ["ready": true, "providers_count": 1, "managed_provider": NSNull()]
        XCTAssertFalse(try KimiAccountIntegration.isSubscriptionAuthenticated(apiKey))
        for status in ["expired", "revoked", "unauthenticated"] {
            let auth: [String: Any] = ["ready": true, "managed_provider": ["name": "managed:kimi-code", "status": status]]
            XCTAssertFalse(try KimiAccountIntegration.isSubscriptionAuthenticated(auth))
        }
        XCTAssertThrowsError(try KimiAccountIntegration.isSubscriptionAuthenticated(["ready": 1]))
    }

    func testQuotaFailuresUnknownAndBoosterWalletCannotCreateAllowance() throws {
        let unavailable = try KimiAccountIntegration.state(auth: auth, usage: ["kind": "error", "message": "PRIVATE-UPSTREAM-DIAGNOSTIC"])
        XCTAssertTrue(unavailable.isConnected)
        XCTAssertNil(unavailable.refreshedAt)
        XCTAssertFalse(unavailable.message?.contains("PRIVATE") ?? true)
        let unknown = try KimiAccountIntegration.state(auth: auth, usage: ["kind": "ok", "summary": NSNull(),
            "limits": [["label": "Unknown", "used": 0, "limit": 0]], "extra_usage": ["balance_cents": 100_000]])
        XCTAssertNil(unknown.remainingPercent)
        for bad in [true as Any, -1, "50"] {
            XCTAssertThrowsError(try KimiAccountIntegration.state(auth: auth, usage: ["kind": "ok", "limits": [["used": bad, "limit": 100]]]))
        }
        XCTAssertThrowsError(try KimiAccountIntegration.state(auth: auth, usage: ["kind": "ok", "limits": [["used": 1, "limit": 100, "reset_at": "tomorrow"]]]))
    }

    func testReadUsesPrivateServerAndAlwaysAwaitsCleanup() async throws {
        let root = try temporary(), runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: auth)
        let state = try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi's cli"), profile: root,
            environment: ["PATH": "/usr/bin:/bin", "KIMI_API_KEY": "PRIVATE", "KIMI_CODE_HOME": "/wrong", "KIMI_CODE_PASSWORD": "old", "OPENAI_API_KEY": "PRIVATE"],
            cancellation: AccountCancellation(), runner: runner, http: http, port: { 51234 })
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.cleaned, 1)
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.executable.path, "/bin/sh")
        XCTAssertEqual(command.arguments[1], "exec \"$@\" >/dev/null 2>&1")
        XCTAssertEqual(command.arguments[3], "/fake/kimi's cli")
        XCTAssertEqual(command.arguments.suffix(6), ["web", "--no-open", "--host", "127.0.0.1", "--port", "51234"])
        XCTAssertNil(command.environment["KIMI_API_KEY"])
        XCTAssertNil(command.environment["OPENAI_API_KEY"])
        XCTAssertEqual(command.environment["KIMI_CODE_HOME"], root.path)
        let password = try XCTUnwrap(command.environment["KIMI_CODE_PASSWORD"])
        XCTAssertGreaterThan(password.count, 60)
        XCTAssertEqual(http.requests.map { $0.url?.path }, ["/api/v1/meta", "/api/v1/auth", "/api/v1/oauth/usage"])
        XCTAssertTrue(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(password)" })
    }

    func testExistingProfileKeepsOriginalHomeAndConfiguration() async throws {
        let root = try temporary(), runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: auth)
        let config = root.appendingPathComponent("config.toml"), original = Data("original = true\n".utf8)
        try original.write(to: config)
        _ = try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi"), profile: root,
            environment: ["HOME": "/Users/fixture", "KIMI_CODE_HOME": root.path, "KIMI_API_KEY": "discard"],
            cancellation: AccountCancellation(), runner: runner, http: http, port: { 51238 }, preserveExistingProfile: true)
        XCTAssertEqual(runner.commands.first?.environment["HOME"], "/Users/fixture")
        XCTAssertEqual(runner.commands.first?.environment["KIMI_CODE_HOME"], root.path)
        XCTAssertNil(runner.commands.first?.environment["KIMI_API_KEY"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("home").path))
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(runner.cleaned, 1)
    }

    func testPlainAPIKeySkipsSubscriptionUsageEndpoint() async throws {
        let runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: ["ready": true, "managed_provider": NSNull()])
        let state = try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi"), profile: try temporary(),
            environment: [:], cancellation: AccountCancellation(), runner: runner, http: http, port: { 51235 })
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(runner.cleaned, 1)
    }

    func testEnvelopeFailureCleansUpAndNeverAcceptsNonzeroCode() async throws {
        let runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: auth)
        http.usageCode = 40101
        do {
            _ = try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi"), profile: try temporary(),
                environment: [:], cancellation: AccountCancellation(), runner: runner, http: http, port: { 51236 })
            XCTFail("A nonzero envelope must fail")
        } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.invalidResponse.localizedDescription) }
        XCTAssertEqual(runner.cleaned, 1)
    }

    func testPortConflictRetriesFreshPortAndPasswordThenFailsClosed() async throws {
        let runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: auth)
        http.status = 401
        var port: UInt16 = 51240
        do {
            _ = try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi"), profile: try temporary(),
                environment: [:], cancellation: AccountCancellation(), runner: runner, http: http,
                port: { defer { port += 10 }; return port }, startupTimeout: 0.03, pollInterval: 0.005)
            XCTFail("Another listener must never be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("private local server")) }
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(runner.cleaned, 2)
        XCTAssertNotEqual(runner.commands[0].environment["KIMI_CODE_PASSWORD"], runner.commands[1].environment["KIMI_CODE_PASSWORD"])
        XCTAssertEqual(Set(http.requests.compactMap { $0.url?.port }), [51240, 51250], "Never follow the CLI's implicit port increment")
    }

    func testCancellationStopsOwnedServerAndDoesNotRetry() async throws {
        let root = try temporary(), runner = KimiFakeRunner(), http = KimiFakeHTTP(auth: auth), cancellation = AccountCancellation()
        http.status = 503
        let task = Task {
            try await KimiAccountIntegration.read(executable: URL(fileURLWithPath: "/fake/kimi"), profile: root,
                environment: [:], cancellation: cancellation, runner: runner, http: http,
                port: { 51245 }, startupTimeout: 5, pollInterval: 0.01)
        }
        while runner.commands.isEmpty { await Task.yield() }
        cancellation.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
        XCTAssertEqual(runner.cleaned, 1)
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testInjectedFakeServerActuallyDiesAfterSuccessfulRead() async throws {
        let root = try temporary(), script = root.appendingPathComponent("fake-kimi"), pidFile = root.appendingPathComponent("pid")
        // Executed by the real process supervisor, but only writes its own PID
        // and waits. No Kimi executable or credentials are ever touched.
        let text = "#!/bin/sh\nprintf '%s' $$ > \(AccountEnvironment.quote(pidFile.path))\nexec /bin/sleep 20\n"
        try AccountStorage.write(Data(text.utf8), to: script, mode: 0o700)
        let http = KimiFakeHTTP(auth: auth)
        http.waitForFile = pidFile
        _ = try await KimiAccountIntegration.read(executable: script, profile: root, environment: [:],
            cancellation: AccountCancellation(), runner: OfficialAccountProcess(), http: http, port: { 51247 }, startupTimeout: 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testPortAllocatorAndLoopbackValidation() async throws {
        XCTAssertGreaterThan(try KimiAccountIntegration.availablePort(), 0)
        do {
            _ = try await KimiLoopbackHTTP().fetch(URLRequest(url: URL(string: "https://example.invalid/private")!), cancellation: AccountCancellation())
            XCTFail("External address must fail before networking")
        } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.invalidResponse.localizedDescription) }
    }
}

@MainActor
private final class KimiFakeRunner: AccountCommandRunning {
    var commands: [AccountCommand] = []
    var cleaned = 0
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        commands.append(command)
        while !cancellation.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
        cleaned += 1
        throw ManagedAccountError.cancelled
    }
}

@MainActor
private final class KimiFakeHTTP: KimiHTTPFetching {
    let auth: [String: Any]
    var requests: [URLRequest] = []
    var status = 200
    var usageCode = 0
    var waitForFile: URL?
    init(auth: [String: Any]) { self.auth = auth }
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let waitForFile, !FileManager.default.fileExists(atPath: waitForFile.path) { throw URLError(.cannotConnectToHost) }
        let path = request.url!.path
        let payload: [String: Any] = path.hasSuffix("/auth") ? auth : path.hasSuffix("/usage")
            ? ["kind": "ok", "summary": ["label": "Weekly", "used": 30, "limit": 100], "limits": []]
            : ["server_id": "fake", "server_version": "test"]
        let data = try JSONSerialization.data(withJSONObject: ["code": path.hasSuffix("/usage") ? usageCode : 0, "data": payload])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
