import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

final class ClaudeOpenAIRelayTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-tests-\(UUID())")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCatalogueNeverInventsAstraAndRejectsInvalidModels() throws {
        let models = try ClaudeOpenAIRelay.models(from: Data(#"{"authenticated":true,"models":[{"id":"gpt-other","displayName":"Other"},{"id":"gpt-other","displayName":"Duplicate"},{"id":"--bad","displayName":"Bad"}]}"#.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-other"])
        XCTAssertEqual(ClaudeOpenAIRelay.preferredModel(in: models), "gpt-other")
        XCTAssertEqual(ClaudeOpenAIRelay.preferredModel(in: models + [.init(id: "gpt-6-astra", displayName: "Astra")]), "gpt-6-astra")
        XCTAssertThrowsError(try ClaudeOpenAIRelay.models(from: Data(#"{"authenticated":false,"models":[]}"#.utf8)))
        XCTAssertThrowsError(try ClaudeOpenAIRelay.models(from: Data(#"{"authenticated":true,"models":[]}"#.utf8)))
    }

    func testVersionFailureExplainsUpdateRatherThanReconnect() {
        XCTAssertThrowsError(try ClaudeOpenAIRelay.models(from: Data(#"{"authenticated":false,"errorCode":"unsupported_codex_version"}"#.utf8))) {
            guard case ClaudeOpenAIRelay.Failure.unsupportedCodex = $0 else { return XCTFail("Wrong failure: \($0)") }
        }
    }

    func testRelayScriptIsBundled() throws {
        let url = try ClaudeOpenAIRelay.bundledScript()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("export async function main"))
    }

    func testModelLimitGuidanceCoversFullUsageWithoutExplicitBlockFlag() throws {
        let payload = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4},"seven_day":{"utilization":55},"model_scoped":[{"display_name":"Fable","utilization":100}]}}"#.utf8)
        var state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: payload)
        XCTAssertTrue(AccountUsageNotice.modelLimit(state)?.contains("/model") == true)
        XCTAssertTrue(AccountUsageNotice.modelLimit(state)?.contains("Fable") == true)
        state.usageCheckFailedAt = Date()
        XCTAssertNil(AccountUsageNotice.modelLimit(state), "A stale model limit must not override a check failure")
    }

    func testModelGuidanceNeverPromisesSharedQuotaWhenSharedLimitIsExhaustedOrUnknown() {
        let model = LimitWindow(id: "fable", label: "Fable", usedFraction: 1, modelName: "Fable")
        for shared in [LimitWindow(id: "weekly", label: "Week", usedFraction: 1),
                       LimitWindow(id: "weekly", label: "Week")] {
            let state = ManagedAccountState(isConnected: true, windows: [shared, model], refreshedAt: Date())
            XCTAssertNil(AccountUsageNotice.modelLimit(state))
        }
    }

    func testLaunchExecutesQuotedArgumentsAndIsolatesTerminalSecrets() throws {
        let root = try temporary()
        let project = root.appendingPathComponent("project's $(echo injected)")
        try AccountStorage.privateDirectory(project)
        let node = root.appendingPathComponent("node's executable")
        try AccountStorage.write(Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf 'ENV\\n'\n/usr/bin/env\n".utf8), to: node, mode: 0o700)
        let script = ClaudeOpenAIRelay.launchScript(node: node, relay: root.appendingPathComponent("relay file.mjs"),
            codex: root.appendingPathComponent("codex's cli"), claude: root.appendingPathComponent("claude cli"),
            project: project, model: "gpt-6-astra", mode: .auto, history: .resume,
            environment: AccountEnvironment.isolated(profile: root, provider: .codex,
                inherited: ["HOME": root.path, "PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "never-copy"]))
        let launcher = root.appendingPathComponent("launch.command")
        try AccountStorage.write(Data(script.utf8), to: launcher, mode: 0o700)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [launcher.path]
        process.environment = ["OPENAI_API_KEY": "terminal-secret", "ANTHROPIC_BASE_URL": "https://wrong.invalid"]
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("--cwd\n\(project.path)\n--mode\nauto\n--\n--resume\n"))
        XCTAssertTrue(output.contains("CODEX_HOME=\(root.path)"))
        XCTAssertFalse(output.contains("terminal-secret")); XCTAssertFalse(output.contains("never-copy"))
        XCTAssertFalse(output.contains("ANTHROPIC_BASE_URL")); XCTAssertFalse(output.contains("CLAUDE_CONFIG_DIR"))
    }

    @MainActor
    func testExplicitLaunchKeepsChosenCodexAccountAndClaudeHistory() async throws {
        let root = try temporary(), runner = RelayRunner()
        var opened: URL?
        let manager = AccountManager(rootURL: root, runner: runner,
            executable: { _ in URL(fileURLWithPath: "/usr/bin/true") }, openTerminal: { opened = $0; return true })
        let chosen = try manager.add(provider: .codex, label: "Chosen", emailHint: nil)
        let other = try manager.add(provider: .codex, label: "Other", emailHint: nil)
        let claude = try manager.add(provider: .claude, label: "History", emailHint: nil)
        await manager.refresh(chosen); await manager.refresh(other)
        try manager.select(other); manager.automaticSelection = true
        let node = URL(fileURLWithPath: "/usr/bin/true"), relay = root.appendingPathComponent("relay.mjs")
        try await manager.launchClaudeOpenAI(codex: chosen, claudeAccount: claude, project: root,
            model: "gpt-6-astra", mode: .auto, history: .resume, cancellation: AccountCancellation(), node: node, relay: relay)
        let text = try String(contentsOf: XCTUnwrap(opened), encoding: .utf8)
        XCTAssertTrue(text.contains("CODEX_HOME=\(manager.configurationDirectory(for: chosen).path)"))
        XCTAssertTrue(text.contains("CLAUDE_CONFIG_DIR=\(manager.configurationDirectory(for: claude).path)"))
        XCTAssertFalse(text.contains(manager.configurationDirectory(for: other).path))
        XCTAssertEqual(manager.selectedAccount(for: .codex)?.id, other.id)
        XCTAssertEqual(runner.probes.count, 1)
        XCTAssertEqual(runner.probes.first?.timeout, 30)
        XCTAssertTrue(manager.notice?.contains("starts with Claude") == true)
    }

    @MainActor
    func testMissingModelAndCancelledLaunchNeverOpenTerminal() async throws {
        let root = try temporary(), runner = RelayRunner()
        var opened = false
        let manager = AccountManager(rootURL: root, runner: runner,
            executable: { _ in URL(fileURLWithPath: "/usr/bin/true") }, openTerminal: { _ in opened = true; return true })
        let account = try manager.add(provider: .codex, label: "Test", emailHint: nil)
        await manager.refresh(account)
        for model in ["not-returned", "gpt-6-astra"] {
            let cancellation = AccountCancellation()
            if model == "gpt-6-astra" { cancellation.cancel() }
            do {
                try await manager.launchClaudeOpenAI(codex: account, claudeAccount: nil, project: root,
                    model: model, mode: .openai, history: .newSession, cancellation: cancellation,
                    node: URL(fileURLWithPath: "/usr/bin/true"), relay: root.appendingPathComponent("relay.mjs"))
                XCTFail("Must reject unavailable or cancelled launch")
            } catch { }
        }
        XCTAssertFalse(opened)
    }

    @MainActor
    func testNativeSheetRendersWithAccountAndLongFrenchLabels() async throws {
        let root = try temporary(), runner = RelayRunner()
        let manager = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        let account = try manager.add(provider: .codex, label: "Compte professionnel avec un nom particulièrement long", emailHint: nil)
        await manager.refresh(account)
        let view = NSHostingView(rootView: ClaudeOpenAIRelayView(manager: manager, project: .constant(root), hidePersonalDetails: true)
            .environment(\.locale, Locale(identifier: "fr")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        try await Task.sleep(nanoseconds: 200_000_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 600, accuracy: 1)
        XCTAssertEqual(view.fittingSize.height, 500, accuracy: 1)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/codenotch-relay-sheet-fr.png"))
        XCTAssertGreaterThan(data.count, 10_000)
    }
}

private final class RelayRunner: AccountCommandRunning {
    var probes: [AccountCommand] = []
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        if cancellation.isCancelled { throw ManagedAccountError.cancelled }
        if command.arguments.contains("probe") {
            probes.append(command)
            return Data(#"{"authenticated":true,"models":[{"id":"gpt-6-astra","displayName":"GPT-6 Astra"}]}"#.utf8)
        }
        return Data(#"{"account":{"type":"chatgpt","email":"test@example.invalid","planType":"plus"},"limits":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}"#.utf8)
    }
}
