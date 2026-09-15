import XCTest
@testable import Codenotch

@MainActor
final class UsageHistoryCaptureTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-capture-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeReading(home: URL, path: String = ".claude/projects/project/thread.jsonl", id: String = "response-one") throws -> URL {
        let file = home.appendingPathComponent(path)
        try AccountStorage.privateDirectory(file.deletingLastPathComponent())
        let row: [String: Any] = ["type": "assistant", "sessionId": "session-\(id)", "uuid": id,
            "cwd": "/fixture-project", "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)),
            "message": ["id": id, "model": "claude-sonnet-5", "usage": ["input_tokens": 12, "output_tokens": 3]]]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0a)
        try data.write(to: file)
        return file
    }

    func testBackgroundCaptureSurvivesSourceAndCacheRemovalWithoutOpeningAView() async throws {
        let home = try temporary()
        let source = try writeReading(home: home)
        let model = UsageInsightsModel(home: home)
        model.captureInBackground()
        for _ in 0..<200 where model.report == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.report?.tokens.total, 15)
        XCTAssertEqual(model.report?.persistence.state, .saved)
        await model.shutdownAndWait()

        try FileManager.default.removeItem(at: source)
        let catalog = home.appendingPathComponent("Library/Application Support/Codenotch Accounts")
        let cache = UsageLedger.defaultCacheURL(catalogRoot: catalog)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        let reopened = UsageInsightsModel(home: home)
        await reopened.refresh()
        XCTAssertEqual(reopened.report?.tokens.total, 15)
        XCTAssertEqual(reopened.report?.persistence.state, .saved)
        XCTAssertNil(reopened.failure)
        await reopened.shutdownAndWait()
    }

    func testNextCaptureDiscoversAProfileAddedAfterModelCreation() async throws {
        let home = try temporary()
        let model = UsageInsightsModel(home: home)
        await model.refresh()
        XCTAssertEqual(model.report?.tokens.total, 0)
        let profile = UUID().uuidString
        _ = try writeReading(home: home,
            path: "Library/Application Support/Codenotch Accounts/profiles/\(profile)/projects/project/thread.jsonl")
        await model.refresh()
        XCTAssertEqual(model.report?.tokens.total, 15)
        await model.shutdownAndWait()
    }

    func testStoppedCollectorDoesNotReadLaterSessions() async throws {
        let home = try temporary()
        let model = UsageInsightsModel(home: home)
        await model.refresh()
        await model.shutdownAndWait()
        _ = try writeReading(home: home)
        model.captureInBackground()
        await model.refresh()
        XCTAssertEqual(model.report?.tokens.total, 0)
        XCTAssertFalse(model.isLoading)
    }
}
