import XCTest
@testable import Codenotch

final class UsageMilestoneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPodiumTiersUseExactExistingLifetimeBoundaries() {
        XCTAssertNil(UsageMilestoneProgress(sessions: [], now: now).podiumTier)
        XCTAssertEqual(UsageMilestoneProgress(sessions: [session("white", input: 1)], now: now).podiumTier, .white)
        for tier in UsagePodiumTier.allCases.dropFirst() {
            let before = UsageMilestoneProgress(sessions: [session("before", input: tier.threshold - 1)], now: now)
            let reached = UsageMilestoneProgress(sessions: [session("at", input: tier.threshold)], now: now)
            XCTAssertEqual(before.podiumTier?.rawValue, tier.rawValue - 1)
            XCTAssertEqual(reached.podiumTier, tier)
        }
        XCTAssertEqual(UsagePodiumTier.allCases.dropFirst().map(\.threshold), UsageMilestoneProgress.thresholds)
    }

    func testPodiumNamesColorsDarkenMonotonicallyAndMeetTextContrast() {
        XCTAssertEqual(UsagePodiumTier.allCases.map(\.nameKey),
                       ["White", "Pearl", "Silver", "Gold", "Platinum", "Titanium", "Graphite", "Obsidian", "Black"])
        XCTAssertEqual(UsagePodiumTier.allCases.map(\.surfaceHex),
                       [0xFAFAFA, 0xE7E7E7, 0xCDCDCD, 0xB9AD8C, 0xA2A6AA, 0x636970, 0x484B50, 0x24262A, 0x070808])
        func luminance(_ hex: UInt32) -> Double {
            let linear = [16, 8, 0].map { shift -> Double in
                let component = Double((hex >> shift) & 255) / 255
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        var previous = Double.infinity
        for tier in UsagePodiumTier.allCases {
            let surface = luminance(tier.surfaceHex), text = luminance(tier.foregroundHex)
            XCTAssertLessThan(surface, previous)
            XCTAssertGreaterThanOrEqual((max(surface, text) + 0.05) / (min(surface, text) + 0.05), 4.5)
            previous = surface
        }
        XCTAssertEqual(UsagePodiumTier.allCases.map { $0.name(locale: Locale(identifier: "fr")) },
                       ["Blanc", "Perle", "Argent", "Or", "Platine", "Titane", "Graphite", "Obsidienne", "Noir"])
    }

    private func session(_ id: String, input: Int, output: Int = 0, cache: Int = 0,
                         reasoning: Int = 0, minute: Int? = nil) -> UsageSessionDigest {
        var result = UsageSessionDigest(sessionID: id)
        result.tokens = UsageTokenTotals(input: input, output: output, cacheRead: cache, thinking: reasoning)
        if let minute {
            result.activityMinutes[String(minute)] = UsageTimeBucket(tokens: result.tokens, messages: 1)
        }
        return result
    }

    func testFirstStampUnlocksAtExactThresholdAndNextProgressStartsAtZero() {
        let before = UsageMilestoneProgress(sessions: [session("a", input: 99_999)], now: now)
        XCTAssertEqual(before.level, 0)
        XCTAssertEqual(before.next?.threshold, 100_000)
        XCTAssertLessThan(before.fractionToNext, 1)
        let reached = UsageMilestoneProgress(sessions: [session("a", input: 100_000)], now: now)
        XCTAssertEqual(reached.level, 1)
        XCTAssertEqual(reached.next?.threshold, 1_000_000)
        XCTAssertEqual(reached.fractionToNext, 0)
    }

    func testSavedCacheCountsOnceAndReasoningIsNotAddedAgain() {
        let progress = UsageMilestoneProgress(sessions: [session("a", input: 40_000, output: 20_000,
                                                               cache: 40_000, reasoning: 15_000)], now: now)
        XCTAssertEqual(progress.totalTokens, 100_000)
        XCTAssertEqual(progress.level, 1)
    }

    func testCrossingDateUsesChronologicalHistoryAcrossSessions() {
        let first = 20_000_000, second = first + 60
        let progress = UsageMilestoneProgress(sessions: [session("later", input: 50_000, minute: second),
                                                         session("earlier", input: 60_000, minute: first)], now: now)
        XCTAssertEqual(progress.stamps.first?.reachedAt, Date(timeIntervalSince1970: Double(second) * 60))
        XCTAssertTrue(progress.stamps.dropFirst().allSatisfy { $0.reachedAt == nil })
    }

    func testOldSavedHistoryCountsBeyondChartPeriods() {
        let oldMinute = Int(now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970 / 60)
        let progress = UsageMilestoneProgress(sessions: [session("old", input: 10_000_000, minute: oldMinute)], now: now)
        XCTAssertEqual(progress.level, 3)
        XCTAssertNotNil(progress.stamps[2].reachedAt)
    }

    func testLegacyTotalsRetainStampsWithoutInventingDates() {
        let progress = UsageMilestoneProgress(sessions: [session("legacy", input: 1_000_000),
                                                         session("dated", input: 100_000, minute: 20_000_000)], now: now)
        XCTAssertEqual(progress.level, 2)
        XCTAssertTrue(progress.stamps.allSatisfy { $0.reachedAt == nil })
    }

    func testInconsistentOrFutureTimingNeverInventsCrossingDate() {
        var inconsistent = session("partial", input: 100_000, minute: 20_000_000)
        inconsistent.tokens.input = 120_000
        for digest in [inconsistent, session("future", input: 100_000, minute: 40_000_000)] {
            let progress = UsageMilestoneProgress(sessions: [digest], now: now)
            XCTAssertEqual(progress.level, 1)
            XCTAssertNil(progress.stamps.first?.reachedAt)
        }
    }

    func testEmptyAndUpperBoundRemainFinite() {
        let empty = UsageMilestoneProgress(sessions: [], now: now)
        XCTAssertEqual(empty.totalTokens, 0)
        XCTAssertEqual(empty.level, 0)
        XCTAssertEqual(empty.fractionToNext, 0)
        let large = UsageMilestoneProgress(sessions: [session("a", input: .max), session("b", input: .max)], now: now)
        XCTAssertEqual(large.totalTokens, .max)
        XCTAssertEqual(large.level, 8)
        XCTAssertNil(large.next)
        XCTAssertEqual(large.fractionToNext, 1)
    }

    func testSavedProgressSurvivesPeriodChangesSourceDeletionAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("milestone-history-\(UUID().uuidString)")
        let source = root.appendingPathComponent("sessions")
        let cache = root.appendingPathComponent("cache/usage.json")
        let archive = root.appendingPathComponent("history/usage.json")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("old.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-400 * 86_400))
        let record: [String: Any] = ["type": "assistant", "uuid": "milestone-old-request", "sessionId": "milestone-old-session",
                                     "timestamp": timestamp, "cwd": "/projects/history",
                                     "message": ["model": "claude-sonnet-5", "usage": ["input_tokens": 1_000_000, "output_tokens": 0]]]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0A)
        try data.write(to: file)
        func collector() -> UsageLedger {
            UsageLedger(sources: [.init(projectsRoot: source, managedAccountID: nil)],
                        cacheURL: cache, archiveURL: archive)
        }
        let ledger = collector()
        let week = await ledger.report(days: 7, now: now)
        XCTAssertEqual(week.sessionCount, 0)
        XCTAssertEqual(week.milestones?.level, 2)
        XCTAssertEqual(week.milestones?.totalTokens, 1_000_000)
        let month = await ledger.report(days: 30, now: now)
        XCTAssertEqual(month.milestones, week.milestones)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: cache)
        let restarted = await collector().report(days: 7, now: now)
        XCTAssertEqual(restarted.milestones, week.milestones)
        XCTAssertEqual(restarted.persistence.state, .saved)
    }

    func testUnreadableHistoryDoesNotPretendNoStampsHaveBeenReached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("milestone-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("history.json")
        try Data("invalid archive".utf8).write(to: archive)
        let ledger = UsageLedger(sources: [], cacheURL: root.appendingPathComponent("cache/usage.json"), archiveURL: archive)
        let report = await ledger.report(now: now)
        XCTAssertEqual(report.persistence.state, .failed)
        XCTAssertNil(report.milestones)
    }
}
