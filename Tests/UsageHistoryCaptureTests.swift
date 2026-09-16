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

    private func writeReading(home: URL, path: String = ".claude/projects/project/thread.jsonl", id: String = "response-one",
                              timestamp: Date = Date().addingTimeInterval(-5)) throws -> URL {
        let file = home.appendingPathComponent(path)
        try AccountStorage.privateDirectory(file.deletingLastPathComponent())
        let row: [String: Any] = ["type": "assistant", "sessionId": "session-\(id)", "uuid": id,
            "cwd": "/fixture-project", "timestamp": ISO8601DateFormatter().string(from: timestamp),
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
    func testPeriodChangeUsesSavedSnapshotUntilExplicitRefresh() async throws {
        let home = try temporary()
        _ = try writeReading(home: home)
        let model = UsageInsightsModel(home: home)
        await model.refresh()
        let first = try XCTUnwrap(model.report)
        let catalog = home.appendingPathComponent("Library/Application Support/Codenotch Accounts")
        let archiveURL = UsageLedger.defaultArchiveURL(catalogRoot: catalog)
        let savedBytes = try Data(contentsOf: archiveURL)
        _ = try writeReading(home: home, path: ".claude/projects/project/later.jsonl", id: "later-response")
        model.days = 30
        model.days = 7
        model.days = 30
        for _ in 0..<200 where model.report?.days != 30 || model.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.report?.days, 30)
        XCTAssertEqual(model.report?.tokens.total, 15, "A picker change must not capture the newly written response")
        XCTAssertEqual(model.report?.milestones, first.milestones)
        XCTAssertEqual(model.report?.scan, first.scan)
        XCTAssertEqual(model.report?.persistence, first.persistence)
        XCTAssertEqual(try Data(contentsOf: archiveURL), savedBytes)
        await model.refresh()
        XCTAssertEqual(model.report?.tokens.total, 30)
        await model.shutdownAndWait()
        model.days = 7
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.report?.days, 30, "A stopped model cannot publish a late period result")
        XCTAssertFalse(model.isLoading)
    }

    func testPeriodChangePreservesLastCaptureFailure() async throws {
        let home = try temporary()
        _ = try writeReading(home: home)
        let model = UsageInsightsModel(home: home)
        await model.refresh()
        let catalog = home.appendingPathComponent("Library/Application Support/Codenotch Accounts")
        let archiveURL = UsageLedger.defaultArchiveURL(catalogRoot: catalog)
        let savedBytes = try Data(contentsOf: archiveURL)
        try Data("invalid archive fixture".utf8).write(to: archiveURL)
        await model.refresh()
        let failed = try XCTUnwrap(model.report)
        XCTAssertEqual(failed.persistence.state, .failed)
        // Restoring the file would allow a fresh capture to succeed. Merely
        // changing the period must retain the previous capture's failed status.
        try savedBytes.write(to: archiveURL)
        model.days = 30
        for _ in 0..<200 where model.report?.days != 30 || model.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.report?.days, 30)
        XCTAssertEqual(model.report?.persistence, failed.persistence)
        XCTAssertEqual(model.report?.scan, failed.scan)
        XCTAssertEqual(model.report?.milestones, failed.milestones)
        XCTAssertNotNil(model.failure)
        await model.shutdownAndWait()
    }

    func testShareIncludesThirtyFirstDayWithoutMovingChartOrReadingNewFiles() async throws {
        let home = try temporary()
        let firstDay = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z")!
        _ = try writeReading(home: home, timestamp: firstDay)
        let model = UsageInsightsModel(home: home)
        await model.refresh(now: now)
        let chart = try XCTUnwrap(model.report)
        XCTAssertEqual(chart.days, 1, "Usage starts on the current calendar day")
        XCTAssertEqual(chart.tokens.total, 0)
        _ = try writeReading(home: home, path: ".claude/projects/project/later.jsonl", id: "later", timestamp: now.addingTimeInterval(-10))
        let exported = await model.reportForSharing()
        XCTAssertEqual(exported?.days, 31)
        XCTAssertEqual(exported?.tokens.total, 15, "Export uses captured history, including the first day of a 31-day month")
        XCTAssertEqual(model.days, 1, "Sharing a full month must preserve the Today selection")
        XCTAssertEqual(model.report, chart, "Export must not change the visible chart or capture new files")
        await model.shutdownAndWait()
        let stoppedExport = await model.reportForSharing()
        XCTAssertNil(stoppedExport)
    }

}
