import XCTest
@testable import Codenotch

final class ExistingAccountProfileTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("existing-profile-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func candidate(_ directory: URL, provider: AccountProvider = .codex) -> ExistingAccountCandidate {
        ExistingAccountCandidate(provider: provider, label: "Existing", source: ExistingAccountProfile(directory: directory.path, usesDefaultClaudeHome: provider == .claude))
    }

    @MainActor
    func testDiscoveryPreservesCatalogAndExternalConfigAndRemoval() async throws {
        let root = try temporary(), external = try temporary(), runner = ExistingProfileRunner()
        let config = external.appendingPathComponent("config.toml"), original = Data("cli_auth_credentials_store = \"file\"\n".utf8)
        try original.write(to: config)
        let manager = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        for index in 0..<7 { try manager.add(provider: .claude, label: "Original \(index)", emailHint: nil) }
        let originalIDs = Set(manager.accounts.map(\.id))
        let item = candidate(external)
        await manager.discoverExistingAccounts(candidates: [item])
        XCTAssertEqual(manager.accounts.count, 8)
        XCTAssertTrue(originalIDs.isSubset(of: Set(manager.accounts.map(\.id))))
        let account = try XCTUnwrap(manager.accounts.last)
        XCTAssertEqual(manager.configurationDirectory(for: account).path, external.path)
        await manager.refresh(account)
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(runner.commands.last?.arguments, ["app-server"])
        XCTAssertEqual(runner.commands.last?.environment["CODEX_HOME"], external.path)
        let restored = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        XCTAssertEqual(restored.accounts.last?.existingProfile, item.source)
        try restored.remove(account)
        let removed = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        await removed.discoverExistingAccounts(candidates: [item], now: Date().addingTimeInterval(2000))
        XCTAssertEqual(removed.accounts.count, 7)
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    @MainActor
    func testVerifiedDuplicateAndFailedProbeCooldown() async throws {
        let runner = ExistingProfileRunner(), root = try temporary(), external = try temporary()
        let manager = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        let managed = try manager.add(provider: .codex, label: "Known", emailHint: nil)
        await manager.refresh(managed)
        await manager.discoverExistingAccounts(candidates: [candidate(external)])
        XCTAssertEqual(manager.accounts.count, 1)
        runner.fail = true
        let another = candidate(try temporary()), now = Date()
        await manager.discoverExistingAccounts(candidates: [another], now: now)
        let attempts = runner.commands.count
        await manager.discoverExistingAccounts(candidates: [another], now: now.addingTimeInterval(60))
        XCTAssertEqual(runner.commands.count, attempts)
        await manager.discoverExistingAccounts(candidates: [another], now: now.addingTimeInterval(901))
        XCTAssertEqual(runner.commands.count, attempts + 1)
    }

    @MainActor
    func testMissingLinkedDirectoryDisconnectsAndNeverRecreatesIt() async throws {
        let external = try temporary(), root = try temporary(), runner = ExistingProfileRunner()
        let manager = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        await manager.discoverExistingAccounts(candidates: [candidate(external)])
        let account = try XCTUnwrap(manager.accounts.first)
        try FileManager.default.removeItem(at: external)
        await manager.refresh(account)
        XCTAssertFalse(manager.state(for: account).isConnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

    func testOriginalLaunchEnvironmentAndUnsafeSources() throws {
        let external = try temporary(), source = candidate(external, provider: .claude).source
        let inherited = ["HOME": "/Users/example", "CLAUDE_CODE_OAUTH_TOKEN": "never", "CODEX_HOME": "/wrong", "OPENAI_API_KEY": "never"]
        let env = source.environment(provider: .claude, inherited: inherited)
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(source.environment(provider: .kimi, inherited: inherited)["HOME"], "/Users/example")
        let account = ManagedAccount(id: UUID(), provider: .codex, label: "Original", createdAt: Date(), existingProfile: source)
        let script = AccountEnvironment.launchScript(executable: URL(fileURLWithPath: "/cli"), account: account, profile: external, project: external, inherited: inherited)
        XCTAssertFalse(script.contains("cli_auth_credentials_store"))
        let link = try temporary().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertThrowsError(try candidate(link).source.validatedDirectory())
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: external.path)
        XCTAssertThrowsError(try source.validatedDirectory())
    }

    func testDiscoveryIsShallowAndLegacyCatalogDecodes() throws {
        let home = try temporary()
        try AccountStorage.privateDirectory(home.appendingPathComponent(".codex"))
        try AccountStorage.privateDirectory(home.appendingPathComponent("unrelated/.claude"))
        let found = ExistingAccountDiscovery.candidates(home: home, environment: [:])
        XCTAssertEqual(found.map(\.provider), [.codex])
        let legacy = try JSONDecoder().decode(AccountCatalog.self, from: Data(#"{"version":1,"accounts":[],"selected":[],"automaticSelection":false}"#.utf8))
        XCTAssertNil(legacy.ignoredExistingProfiles)
    }

    func testLoggedOutKimiProfileIsNotDiscovered() throws {
        let home = try temporary()
        let credentials = home.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        try AccountStorage.privateDirectory(credentials)
        let file = credentials.appendingPathComponent("kimi-code.json")
        try Data(#"{"access_token":"","refresh_token":""}"#.utf8).write(to: file)
        XCTAssertFalse(ExistingAccountDiscovery.candidates(home: home, environment: [:]).contains { $0.provider == .kimi })

        try Data(#"{"access_token":"connected","refresh_token":""}"#.utf8).write(to: file)
        XCTAssertTrue(ExistingAccountDiscovery.candidates(home: home, environment: [:]).contains { $0.provider == .kimi })
    }

    @MainActor
    func testPreviouslySavedLoggedOutKimiProfileIsPruned() async throws {
        let root = try temporary(), external = try temporary(), runner = ExistingProfileRunner()
        let credentials = external.appendingPathComponent("credentials", isDirectory: true)
        try AccountStorage.privateDirectory(credentials)
        let file = credentials.appendingPathComponent("kimi-code.json")
        try Data(#"{"access_token":"connected","refresh_token":""}"#.utf8).write(to: file)
        let manager = AccountManager(rootURL: root, runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/cli") },
            readExistingKimi: { _, _, _, _ in ManagedAccountState(isConnected: true) })
        _ = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        await manager.discoverExistingAccounts(candidates: [candidate(external, provider: .kimi)])
        XCTAssertEqual(manager.accounts.filter { $0.provider == .kimi }.count, 2)

        try Data(#"{"access_token":"","refresh_token":""}"#.utf8).write(to: file)
        await manager.discoverExistingAccounts(candidates: [])
        XCTAssertEqual(manager.accounts.filter { $0.provider == .kimi }.count, 1)
        XCTAssertNil(manager.accounts.first { $0.provider == .kimi }?.existingProfile)
    }
}

private final class ExistingProfileRunner: AccountCommandRunning {
    var commands: [AccountCommand] = []
    var fail = false
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        commands.append(command)
        if fail { throw ManagedAccountError.timedOut }
        return Data(#"{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"plus"},"limits":{"rateLimits":{"primary":{"usedPercent":20}}}}"#.utf8)
    }
}
