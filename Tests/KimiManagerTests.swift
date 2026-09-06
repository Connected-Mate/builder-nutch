import XCTest
@testable import Codenotch

final class KimiManagerTests: XCTestCase {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-manager-test-\(UUID())")
        try AccountStorage.privateDirectory(path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    @MainActor
    func testKimiLoginRefreshAndLaunchShareThePrivateHome() async throws {
        let directory = try root(), runner = KimiLoginRecorder()
        var environments: [[String: String]] = [], launch = ""
        let manager = AccountManager(rootURL: directory, runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/kimi") },
            openTerminal: { launch = (try? String(contentsOf: $0, encoding: .utf8)) ?? ""; return true },
            readKimi: { _, profile, environment, _ in
                environments.append(environment)
                XCTAssertEqual(environment["KIMI_CODE_HOME"], profile.path)
                XCTAssertEqual(environment["HOME"], profile.appendingPathComponent("home").path)
                return ManagedAccountState(isConnected: true,
                    windows: [LimitWindow(id: "primary", label: "Weekly", usedFraction: 0.2)], refreshedAt: Date())
            })
        let account = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        await manager.connect(account)
        XCTAssertEqual(runner.commands.first?.arguments, ["login"])
        XCTAssertEqual(runner.commands.first?.environment["HOME"], manager.configurationDirectory(for: account).appendingPathComponent("home").path)
        XCTAssertTrue(manager.state(for: account).isConnected)
        manager.automaticSelection = true
        await manager.launch(account, project: directory)
        XCTAssertTrue(launch.contains("KIMI_CODE_HOME="))
        XCTAssertTrue(launch.contains("/home'"))
        XCTAssertFalse(launch.contains("CODEX_HOME="))
        XCTAssertFalse(launch.contains("cli_auth_credentials_store"))
        XCTAssertEqual(environments.count, 2)
        XCTAssertEqual(manager.snapshots.first?.glyph, .kimi)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: manager.configurationDirectory(for: account).appendingPathComponent("home").path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// Explicit opt-in: only a fresh, empty HOME/profile, no login or model call.
    @MainActor
    func testInstalledKimiEmptyProfileSmoke() async throws {
        guard ProcessInfo.processInfo.environment["BUILDER_NUTCH_KIMI_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in installed Kimi smoke test")
        }
        let executable = try XCTUnwrap(KimiAccountIntegration.executable())
        let profile = try root()
        let environment = KimiAccountIntegration.isolatedEnvironment(profile: profile, inherited: ProcessInfo.processInfo.environment)
        let state = try await KimiAccountIntegration.read(executable: executable, profile: profile, environment: environment, cancellation: AccountCancellation())
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertNil(state.refreshedAt)
        XCTAssertNotNil(state.message)
    }
}

private final class KimiLoginRecorder: AccountCommandRunning, @unchecked Sendable {
    var commands: [AccountCommand] = []
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        commands.append(command)
        return Data()
    }
}
