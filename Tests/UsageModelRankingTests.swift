import Foundation
import XCTest
@testable import Codenotch

final class UsageModelRankingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func event(_ input: Int, model: String?, at timestamp: String,
                       path: String = "/project", sidechain: Bool = false,
                       provider: UsageTranscriptFormat = .claude, weight: Double? = nil) -> UsageRecordedEvent {
        let tokens = UsageTokenTotals(input: input, measurements: 1, inputMeasurements: 1,
            outputMeasurements: 1, cacheCreationMeasurements: provider == .claude ? 1 : 0,
            cacheReadMeasurements: 1, claudeMeasurements: provider == .claude ? 1 : 0,
            codexMeasurements: provider == .codex ? 1 : 0)
        return UsageRecordedEvent(tokens: tokens, weight: weight ?? Double(input), date: date(timestamp),
            projectPath: path, model: model, sidechain: sidechain)
    }

    private func session(_ id: String = "session", provider: UsageTranscriptFormat = .claude,
                         events: [UsageRecordedEvent]) -> UsageSessionDigest {
        var digest = UsageSessionDigest(sessionID: id, provider: provider)
        for (index, event) in events.enumerated() {
            event.add(to: &digest)
            digest.recordedEvents?["event-\(index)"] = event
        }
        return digest
    }

    private func report(_ sessions: [UsageSessionDigest], days: Int = 30,
                        now: String = "2026-09-16T12:00:00Z") -> UsageLedgerReport {
        UsageLedgerEngine.report(sessions: sessions, summary: UsageScanSummary(), days: days,
            now: date(now), calendar: calendar, timeline: UsageAccountTimeline())
    }

    func testWindowUsesActualModelTokensInsteadOfLifetimeWeight() {
        let digest = session(events: [
            event(10_000, model: "older-model", at: "2026-08-20T10:00:00Z"),
            event(100, model: "costly-model", at: "2026-09-16T10:00:00Z", weight: 10_000),
            event(900, model: "larger-model", at: "2026-09-16T11:00:00Z", weight: 1)
        ])
        let value = report([digest], days: 1)
        let ranked = UsageModelRanking.entries(in: value)
        XCTAssertEqual(ranked.map(\.modelID), ["larger-model", "costly-model"])
        XCTAssertEqual(ranked.map { $0.tokens.total }, [900, 100])
        XCTAssertEqual(value.accounts.first?.projects.first?.sessions.first?.dominantModel, "larger-model")
        XCTAssertEqual(ranked.map(\.availability), [.complete, .complete])
    }

    func testExactModelIdentifiersMergeAcrossToolsWithoutCaseFolding() {
        let value = report([
            session("a", events: [event(100, model: "GPT-5", at: "2026-09-16T10:00:00Z"),
                                  event(100, model: "gpt-5", at: "2026-09-16T10:01:00Z")]),
            session("b", provider: .codex, events: [event(100, model: "gpt-5", at: "2026-09-16T10:02:00Z", provider: .codex)])
        ])
        let ranked = UsageModelRanking.entries(in: value)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.map(\.modelID), ["gpt-5", "GPT-5"])
        XCTAssertEqual(ranked.map { $0.tokens.total }, [200, 100])
        XCTAssertEqual(ranked.first?.sources, [.claude, .codex])
        XCTAssertEqual(ranked.first?.availability, .complete)
        XCTAssertNil(ranked.first?.provider)
        XCTAssertEqual(ranked.last?.provider, .claude)
        XCTAssertEqual(Set(ranked.map(\.id)).count, 2)
    }

    func testModelAndProjectSelectionUsesReportLocalCalendar() {
        let value = report([
            session("a", events: [event(20, model: "yesterday", at: "2026-09-15T21:59:00Z"),
                                  event(30, model: "today", at: "2026-09-15T22:01:00Z")]),
            session("b", events: [event(900, model: "elsewhere", at: "2026-09-16T10:00:00Z", path: "/other")])
        ])
        let ranked = UsageModelRanking.entries(in: value, from: date("2026-09-15T22:00:00Z"),
            through: date("2026-09-16T12:00:00Z"), projectPath: "/project")
        XCTAssertEqual(ranked.map(\.modelID), ["today"])
        XCTAssertEqual(ranked.first?.tokens.total, 30)
        XCTAssertTrue(UsageModelRanking.entries(in: value, projectPath: "/missing").isEmpty)
    }

    func testSidechainModelsFollowResolvedMainProject() {
        let digest = session(events: [
            event(10, model: "main", at: "2026-09-16T10:00:00Z"),
            event(100, model: "agent", at: "2026-09-16T10:01:00Z", path: "/temporary/worktree", sidechain: true)
        ])
        let value = report([digest])
        XCTAssertEqual(Set(value.modelDays.map(\.projectPath)), ["/project"])
        XCTAssertEqual(UsageModelRanking.entries(in: value, projectPath: "/project").reduce(0) { $0 + $1.tokens.total }, 110)
        XCTAssertTrue(UsageModelRanking.entries(in: value, projectPath: "/temporary/worktree").isEmpty)
    }

    func testLegacyAndMissingModelsRemainUnknownAndConserveCounters() {
        var legacy = session("legacy", events: [event(300, model: "unprovable", at: "2026-09-16T09:00:00Z")])
        legacy.recordedEvents = nil
        legacy.recordedEventsComplete = false
        let value = report([legacy, session(events: [
            event(100, model: "known", at: "2026-09-16T10:00:00Z"),
            event(50, model: nil, at: "2026-09-16T11:00:00Z")
        ])])
        let ranked = UsageModelRanking.entries(in: value)
        XCTAssertEqual(ranked.first?.modelID, nil)
        XCTAssertEqual(ranked.first?.tokens.total, 350)
        XCTAssertEqual(ranked.last?.modelID, "known")
        XCTAssertEqual(ranked.reduce(UsageTokenTotals()) { $0 + $1.tokens }, value.tokens)
        XCTAssertTrue(ranked.allSatisfy { $0.availability == .partial })
        XCTAssertNil(value.accounts.first?.projects.first?.sessions.first { $0.sessionID == "legacy" }?.dominantModel)
    }

    func testArchiveRestartDeduplicatesModelsAndRetainsDeletedSourceHistory() throws {
        let digest = session(events: [event(100, model: "precise-id", at: "2026-09-16T10:00:00Z")])
        var archive = UsageLedgerArchive()
        archive.absorb([digest, digest], timeline: UsageAccountTimeline())
        archive.absorb([digest], timeline: UsageAccountTimeline())
        let restarted = try JSONDecoder().decode(UsageLedgerArchive.self, from: JSONEncoder().encode(archive))
        let ranked = UsageModelRanking.entries(in: report(restarted.digests))
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.modelID, "precise-id")
        XCTAssertEqual(ranked.first?.tokens.total, 100)
    }

    func testMissingAccountMetadataDoesNotInventToolOrLoseTokens() {
        let now = date("2026-09-16T12:00:00Z")
        let tokens = UsageTokenTotals(input: 500, output: 20, thinking: 10)
        let value = UsageLedgerReport(generatedAt: now, windowStart: calendar.startOfDay(for: now), windowEnd: now,
            days: 1, totalWeight: 1, tokens: tokens, messages: 1, sessionCount: 1, accounts: [],
            timeline: [UsageDaySlice(day: "2026-09-16", weight: 1, sharePercent: 100, tokens: tokens, messages: 1)],
            scan: UsageScanSummary(), calendar: calendar)
        let ranked = UsageModelRanking.entries(in: value)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertNil(ranked.first?.provider)
        XCTAssertNil(ranked.first?.modelID)
        XCTAssertEqual(ranked.first?.tokens, tokens)
        XCTAssertEqual(ranked.first?.tokens.total, 520)
        XCTAssertEqual(ranked.first?.availability, .partial)
    }

    func testLegacyEncodedReportsDecodeWithoutModelDays() throws {
        let original = report([session(events: [event(100, model: "known", at: "2026-09-16T10:00:00Z")])])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "modelDays")
        let decoded = try JSONDecoder().decode(UsageLedgerReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.modelDays.isEmpty)
        let ranked = UsageModelRanking.entries(in: decoded)
        XCTAssertEqual(ranked.first?.tokens.total, 100)
        XCTAssertNil(ranked.first?.modelID)
        XCTAssertEqual(ranked.first?.availability, .partial)
        XCTAssertEqual(try JSONDecoder().decode(UsageLedgerReport.self, from: JSONEncoder().encode(original)), original)
    }

    func testUnknownModelsStaySeparatePerSourceAndKnownDaysAggregateSessions() {
        let value = report([
            session("a", events: [event(40, model: "shared", at: "2026-09-16T10:00:00Z"),
                                  event(100, model: nil, at: "2026-09-16T10:01:00Z")]),
            session("b", events: [event(60, model: "shared", at: "2026-09-16T10:02:00Z")]),
            session("c", provider: .codex, events: [event(200, model: nil, at: "2026-09-16T10:03:00Z", provider: .codex)])
        ])
        let ranked = UsageModelRanking.entries(in: value)
        let unknown = ranked.filter { $0.modelID == nil }
        XCTAssertEqual(unknown.count, 2)
        XCTAssertEqual(Set(unknown.map(\.id)).count, 2)
        XCTAssertEqual(value.modelDays.filter { $0.modelID == "shared" }.count, 1)
        XCTAssertEqual(value.modelDays.first { $0.modelID == "shared" }?.tokens.total, 100)
        XCTAssertEqual(ranked.reduce(UsageTokenTotals()) { $0 + $1.tokens }, value.tokens)
    }

    func testPartialScanAndShortHistoryMakeKnownRankingPartial() {
        var value = report([session(events: [event(100, model: "known", at: "2026-09-16T10:00:00Z")])], days: 1)
        XCTAssertEqual(UsageModelRanking.entries(in: value, from: date("2026-09-01T00:00:00Z")).first?.availability, .partial)
        var scan = UsageScanSummary()
        scan.hitLimit = true
        value = UsageLedgerEngine.report(sessions: [session(events: [event(100, model: "known", at: "2026-09-16T10:00:00Z")])],
            summary: scan, days: 1, now: date("2026-09-16T12:00:00Z"), calendar: calendar, timeline: UsageAccountTimeline())
        XCTAssertEqual(UsageModelRanking.entries(in: value).first?.availability, .partial)
    }
}
