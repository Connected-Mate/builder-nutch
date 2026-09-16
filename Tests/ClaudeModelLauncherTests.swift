import XCTest
@testable import Codenotch

final class ClaudeModelLauncherTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("launcher ' $(ignored)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testPreferenceIsBoundedTopLevelAndDoesNotFollowSymlinks() throws {
        let root = try temporary(), settings = root.appendingPathComponent("settings.json")
        for model in ["opus", "sonnet[1m]", "claude-sonnet-4-6", "claude-3-5-haiku-20241022"] {
            let data = try JSONSerialization.data(withJSONObject: ["model": model])
            try data.write(to: settings)
            XCTAssertEqual(ClaudeModelLauncher.readPreference(directory: root), model)
            XCTAssertEqual(try Data(contentsOf: settings), data)
        }
        for text in ["{}", "{\"model\":\"default\"}", "{\"env\":{\"model\":\"opus\"}}", "{\"model\":\"opus;touch /tmp/bad\"}", String(repeating: " ", count: 65_537)] {
            try Data(text.utf8).write(to: settings)
            XCTAssertNil(ClaudeModelLauncher.readPreference(directory: root))
        }
        let target = root.appendingPathComponent("other.json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: target)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        XCTAssertNil(ClaudeModelLauncher.readPreference(directory: root))
    }

    func testGeneratedShellPreservesArgumentsAndRemovesAuthOverrides() throws {
        let root = try temporary(), fake = root.appendingPathComponent("fake ' claude")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf 'ENV\\n'\n/usr/bin/env\nprintf 'PWD=%s\\n' \"$PWD\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let script = try ClaudeModelLauncher.script(executable: fake, project: root, model: "opus[1m]", fallbackModels: ["sonnet", "haiku"], inherited: ["HOME": root.path, "ANTHROPIC_API_KEY": "secret", "CLAUDE_CONFIG_DIR": "foreign", "ANTHROPIC_BASE_URL": "foreign", "CLAUDE_CODE_OAUTH_TOKEN": "secret"])
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["ANTHROPIC_API_KEY": "terminal-secret", "CLAUDE_CONFIG_DIR": "terminal-foreign"]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.hasPrefix("--model\nopus[1m]\n--fallback-model\nsonnet,haiku\nENV\n"))
        XCTAssertTrue(text.contains("HOME=\(root.path)\n"))
        XCTAssertTrue(text.contains("PWD=\(root.path)\n") || text.contains("PWD=/private\(root.path)\n"))
        for forbidden in ["secret", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ignored").path))
    }

    func testInvalidArgumentsAreRejectedAndEmptyFallbackIsOmitted() throws {
        let path = URL(fileURLWithPath: "/tmp")
        XCTAssertThrowsError(try ClaudeModelLauncher.script(executable: path, project: path, model: "opus\n--dangerous", fallbackModels: []))
        XCTAssertThrowsError(try ClaudeModelLauncher.script(executable: path, project: path, model: "opus", fallbackModels: ["sonnet,haiku"]))
        XCTAssertThrowsError(try ClaudeModelLauncher.script(executable: URL(fileURLWithPath: "/tmp/\ncli"), project: path, model: "opus", fallbackModels: []))
        XCTAssertFalse(try ClaudeModelLauncher.script(executable: path, project: path, model: "opus", fallbackModels: []).contains("--fallback-model"))
    }
}
