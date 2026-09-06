import XCTest
@testable import Codenotch

final class BrowserAccountTests: XCTestCase {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("browser-account-test-\(UUID())")
        try AccountStorage.privateDirectory(path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    @MainActor
    func testWebsiteAccountsKeepSeparateProfilesAndRequireExplicitConfirmation() async throws {
        let storage = try root()
        var opened: [(URL, URL, String?)] = []
        let manager = AccountManager(rootURL: storage, runner: NoBrowserCommands(), executable: { _ in nil },
            openBrowser: { profile, website, previous in
                opened.append((profile, website, previous)); return "com.google.Chrome"
            })
        let first = try manager.add(provider: .grok, label: "Grok", emailHint: nil)
        let second = try manager.add(provider: .grok, label: "Grok 2", emailHint: nil)
        XCTAssertThrowsError(try manager.confirmBrowserConnection(first))
        await manager.connect(first)
        XCTAssertFalse(manager.state(for: first).isConnected)
        try manager.confirmBrowserConnection(first)
        try manager.personalize(first, label: "Research", emoji: "🧑‍🚒")
        await manager.connect(second)
        XCTAssertFalse(manager.state(for: second).isConnected)
        XCTAssertNotEqual(opened[0].0, opened[1].0)
        XCTAssertEqual(opened[0].1, AccountProvider.grok.website)
        XCTAssertTrue(opened[0].0.path.hasSuffix("\(first.id.uuidString.lowercased())/browser"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: opened[0].0.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let restored = AccountManager(rootURL: storage, runner: NoBrowserCommands(), executable: { _ in nil },
            openBrowser: { profile, website, previous in
                opened.append((profile, website, previous)); return "com.google.Chrome"
            })
        let saved = try XCTUnwrap(restored.accounts.first)
        XCTAssertEqual(saved.id, first.id)
        XCTAssertEqual(saved.emoji, "🧑‍🚒")
        XCTAssertEqual(saved.label, "Research")
        XCTAssertNotNil(saved.browserConfirmedAt)
        XCTAssertTrue(restored.state(for: saved).isConnected)
        XCTAssertNil(restored.state(for: saved).refreshedAt)
        restored.automaticSelection = true
        // A browser launch neither needs a project folder nor runs CLI selection.
        await restored.launch(saved, project: URL(fileURLWithPath: "/does-not-exist"))
        XCTAssertEqual(opened.last?.0, opened.first?.0)
        XCTAssertEqual(opened.last?.2, "com.google.Chrome")
        await restored.refreshAll()
        XCTAssertTrue(restored.state(for: saved).windows.isEmpty)
        XCTAssertNil(AccountSelection.best(provider: .grok, accounts: restored.accounts, states: restored.states))
    }

    @MainActor
    func testFailedBrowserLaunchCannotBecomeConnected() async throws {
        let manager = AccountManager(rootURL: try root(), runner: NoBrowserCommands(), executable: { _ in nil },
            openBrowser: { _, _, _ in throw ManagedAccountError.missingBrowser })
        let account = try manager.add(provider: .kimi, label: "Kimi", emailHint: nil)
        await manager.connect(account)
        XCTAssertFalse(manager.state(for: account).isConnected)
        XCTAssertThrowsError(try manager.confirmBrowserConnection(account))
        XCTAssertEqual(manager.notice, ManagedAccountError.missingBrowser.localizedDescription)
        XCTAssertTrue(manager.busyIDs.isEmpty)
        XCTAssertNil(manager.loginAccountID)
    }

    func testOlderCatalogLoadsWithoutPersonalizationFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"provider\":\"claude\",\"label\":\"Original\",\"createdAt\":12345}".utf8)
        let account = try JSONDecoder().decode(ManagedAccount.self, from: data)
        XCTAssertEqual(account.id, id)
        XCTAssertNil(account.emoji)
        XCTAssertNil(account.browserConfirmedAt)
        XCTAssertNil(account.browserBundleIdentifier)
        XCTAssertEqual(try AccountStorage.validEmoji("🚀"), "🚀")
        XCTAssertEqual(try AccountStorage.validEmoji("🌊"), "🌊")
        XCTAssertNil(try AccountStorage.validEmoji(""))
        XCTAssertThrowsError(try AccountStorage.validEmoji("plain text"))
        XCTAssertThrowsError(try AccountStorage.validEmoji("🚀🚀"))
    }

    @MainActor
    func testBrowserArgumentsRejectUnsafePathsAndPolicies() throws {
        let directory = try root()
        let args = try AccountBrowser.arguments(profile: directory, website: AccountProvider.gemini.website)
        XCTAssertEqual(args.first, "--user-data-dir=\(directory.path)")
        XCTAssertEqual(args.last, "https://gemini.google.com/")
        XCTAssertFalse(args.contains(where: { $0.contains("remote-debugging") || $0.contains("no-sandbox") }))
        XCTAssertThrowsError(try AccountBrowser.arguments(profile: directory, website: URL(string: "http://example.test")!))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try AccountBrowser.arguments(profile: link, website: AccountProvider.grok.website))
        XCTAssertTrue(AccountBrowser.hasDirectoryPolicy(identifier: "com.google.Chrome", read: { _, _ in "/company/profile" }))
        XCTAssertFalse(AccountBrowser.hasDirectoryPolicy(identifier: "com.google.Chrome", read: { _, _ in nil }))
        for provider in AccountProvider.allCases where provider.isBrowserProfile {
            XCTAssertNil(AccountEnvironment.executable(for: provider))
            let env = AccountEnvironment.isolated(profile: directory, provider: provider, inherited: ["CODEX_HOME": "secret", "CURSOR_API_KEY": "secret"])
            XCTAssertNil(env["CODEX_HOME"])
            XCTAssertNil(env["CURSOR_API_KEY"])
        }
    }
}

private struct NoBrowserCommands: AccountCommandRunning {
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        XCTFail("Browser accounts must never execute a vendor CLI")
        throw ManagedAccountError.invalidResponse
    }
}
