import XCTest
@testable import Codenotch

final class UsageMilestoneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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
}
