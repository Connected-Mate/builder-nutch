import XCTest
import SwiftUI
@testable import Codenotch

final class UsageModelShareTests: XCTestCase {
    static func fixture() -> UsageLedgerReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-09-16T13:00:00Z")!
        let rows: [(String, UsageTranscriptFormat, String?, Int, String)] = [
            ("2026-09-01", .claude, "claude-sonnet-4-5", 2_000_000_000, "/private/Alpha"),
            ("2026-09-15", .claude, "claude-fable-5", 800_000_000, "/private/Alpha"),
            ("2026-09-16", .claude, "claude-opus-4-8", 190_000_000, "/private/Alpha"),
            ("2026-09-16", .codex, "gpt-6-astra", 170_000_000, "/private/Alpha"),
            ("2026-09-16", .claude, "gpt-6-astra", 40_000_000, "/private/Alpha"),
            ("2026-09-16", .claude, "claude-fable-5", 30_000_000, "/private/Alpha"),
            ("2026-09-16", .claude, nil, 10_000_000, "/private/Alpha"),
            ("2026-09-16", .codex, "gpt-6-astra", 5_000_000, "/private/Beta")
        ]
        let sessions = rows.enumerated().map { index, row -> UsageSessionDigest in
            let timestamp = ISO8601DateFormatter().date(from: row.0 + "T10:00:00Z")!
            let tokens = UsageTokenTotals(input: row.3, measurements: 1, inputMeasurements: 1,
                outputMeasurements: 1, cacheCreationMeasurements: 1, cacheReadMeasurements: 1,
                thinkingMeasurements: 1, claudeMeasurements: row.1 == .claude ? 1 : 0,
                codexMeasurements: row.1 == .codex ? 1 : 0)
            var session = UsageSessionDigest(sessionID: "fixture-\(index)", provider: row.1)
            session.tokens = tokens; session.weight = Double(row.3); session.messages = 1
            session.firstActivity = timestamp; session.lastActivity = timestamp
            session.projectWeights = [row.4: session.weight]
            session.activityMinutes = [String(Int(timestamp.timeIntervalSince1970 / 60)):
                UsageTimeBucket(tokens: tokens, weight: session.weight, messages: 1)]
            session.recordedEvents = ["event-\(index)": UsageRecordedEvent(tokens: tokens,
                weight: session.weight, date: timestamp, projectPath: row.4, model: row.2, sidechain: false)]
            return session
        }
        return UsageLedgerEngine.report(sessions: sessions, summary: UsageScanSummary(), days: 31,
            now: now, calendar: calendar, timeline: UsageAccountTimeline())
    }

    func testExportRanksActualModelsForSelectedPeriodAndKeepsTokensReconciled() {
        let report = Self.fixture()
        let expected = ["gpt-6-astra", "claude-fable-5", "claude-sonnet-4-5"]
        for (index, period) in UsageSharePeriod.allCases.enumerated() {
            let snapshot = UsageShareSnapshot(report: report, period: period)
            XCTAssertEqual(snapshot.modelRanking.first { $0.modelID != nil }?.modelID, expected[index])
            XCTAssertEqual(snapshot.modelRanking.reduce(0) { $0 + $1.tokens.total }, snapshot.tokens.total)
            XCTAssertFalse(String(reflecting: snapshot).contains("/private/"))
            XCTAssertFalse(String(reflecting: snapshot).contains("fixture-"))
        }
    }

    func testProjectScopeAndRelayKeepTheRealModelAndToolProvenance() throws {
        let report = Self.fixture()
        let alpha = UsageShareSnapshot(report: report, projectPath: "/private/Alpha")
        let gpt = try XCTUnwrap(alpha.modelRanking.first { $0.modelID == "gpt-6-astra" })
        XCTAssertEqual(gpt.tokens.total, 210_000_000)
        XCTAssertEqual(Set(gpt.sources.map(\.rawValue)), ["claude", "codex"])
        XCTAssertEqual(UsageModelPresentation.glyph(gpt.modelID), .openai)
        XCTAssertEqual(alpha.modelRanking.filter { $0.modelID == nil }.reduce(0) { $0 + $1.tokens.total }, 10_000_000)
        let beta = UsageShareSnapshot(report: report, projectPath: "/private/Beta")
        XCTAssertEqual(beta.modelRanking.count, 1)
        XCTAssertEqual(beta.modelRanking.first?.tokens.total, 5_000_000)
        XCTAssertTrue(UsageShareSnapshot(report: report, projectPath: "/private/missing").modelRanking.isEmpty)
    }

    func testUnknownNamesAreNotConvertedIntoProviderDefaults() {
        XCTAssertEqual(UsageModelPresentation.name("claude-opus-4-8"), "Claude Opus 4.8")
        XCTAssertEqual(UsageModelPresentation.name("gpt-6-astra"), "GPT-6 Astra")
        XCTAssertEqual(UsageModelPresentation.name("private/model@custom"), "private/model@custom")
        XCTAssertNil(UsageModelPresentation.glyph("private/model@custom"))
        XCTAssertNil(UsageModelPresentation.glyph(nil))
    }

    func testPartialModelCountsNeverRoundTheirLowerBoundUp() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(UsageModelPresentation.count(10_999, availability: .partial, locale: locale), "≥ 10.9K")
        XCTAssertEqual(UsageModelPresentation.count(10_999, availability: .complete, locale: locale), "11K")
    }
}

@MainActor
final class UsageModelArtworkTests: XCTestCase {
    func testModelArtworkInBothLanguagesAndEveryPeriod() throws {
        let report = UsageModelShareTests.fixture()
        for language in ["en", "fr"] {
            for period in UsageSharePeriod.allCases {
                let snapshot = UsageShareSnapshot(report: report, period: period)
                let data = try UsageShareExporter.pngData(snapshot: snapshot, locale: Locale(identifier: language))
                let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertEqual(rep.pixelsWide, 2400)
                XCTAssertEqual(rep.pixelsHigh, 1260)
                let path = URL(fileURLWithPath: "/tmp/builder-nutch-models-\(language)-\(period.rawValue).png")
                try data.write(to: path)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Models \(language) \(period.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
