import Foundation
import XCTest
@testable import Codenotch

final class UsageShareScopeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Paris")!
        return value
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func tokens(_ input: Int, provider: UsageTranscriptFormat = .claude,
                        complete: Bool = true) -> UsageTokenTotals {
        UsageTokenTotals(
            input: input, output: 0, measurements: 1,
            inputMeasurements: 1, outputMeasurements: complete ? 1 : 0,
            cacheCreationMeasurements: provider == .claude && complete ? 1 : 0,
            cacheReadMeasurements: provider == .claude && complete ? 1 : 0,
            claudeMeasurements: provider == .claude ? 1 : 0,
            codexMeasurements: provider == .codex ? 1 : 0)
    }

    private func day(_ value: String, _ input: Int, provider: UsageTranscriptFormat = .claude,
                     complete: Bool = true) -> UsageDaySlice {
        UsageDaySlice(day: value, weight: Double(input), sharePercent: 0,
            tokens: tokens(input, provider: provider, complete: complete), messages: input > 0 ? 1 : 0)
    }

    private func project(path: String, name: String? = nil, days: [UsageDaySlice]) -> UsageProjectSlice {
        let total = days.reduce(UsageTokenTotals()) { $0 + $1.tokens }
        return UsageProjectSlice(path: path, name: name ?? (path as NSString).lastPathComponent,
            weight: Double(total.total), sharePercent: 0, overallSharePercent: 0, tokens: total,
            messages: 0, sessionCount: 0, firstActivity: nil, lastActivity: nil,
            topics: [], sessions: [], days: days)
    }

    private func account(_ provider: UsageTranscriptFormat, key: String,
                         projects: [UsageProjectSlice], days: [UsageDaySlice]) -> AccountUsageShare {
        let total = days.reduce(UsageTokenTotals()) { $0 + $1.tokens }
        return AccountUsageShare(accountKey: key, managedAccountID: key, vendorAccountID: key,
            attribution: .explicit, provider: provider, weight: Double(total.total), sharePercent: 0,
            tokens: total, messages: 0, sessionCount: 0, firstActivity: nil, lastActivity: nil,
            projects: projects, days: days)
    }

    private func report(now: Date, days: Int, timeline: [UsageDaySlice],
                        accounts: [AccountUsageShare] = [], scan: UsageScanSummary = UsageScanSummary())
        -> UsageLedgerReport {
        let start = calendar.date(byAdding: .day, value: -(days - 1),
            to: calendar.startOfDay(for: now))!
        var result = UsageLedgerReport(generatedAt: now, windowStart: start, windowEnd: now, days: days,
            totalWeight: 0, tokens: timeline.reduce(UsageTokenTotals()) { $0 + $1.tokens },
            messages: 0, sessionCount: 0, accounts: accounts, timeline: timeline, scan: scan)
        result.calendar = calendar
        return result
    }

    func testCalendarMonthHandlesThirtyOneDaysAndLeapFebruary() {
        let august = report(now: date("2026-08-31T10:00:00Z"), days: 31,
            timeline: [day("2026-07-31", 9_000), day("2026-08-01", 100), day("2026-08-31", 200)])
        let augustSnapshot = UsageShareSnapshot(report: august, period: .month, calendar: calendar)
        XCTAssertEqual(augustSnapshot.monthTokens.total, 300)
        XCTAssertEqual(augustSnapshot.tokens.total, 300)
        XCTAssertEqual(augustSnapshot.monthAvailability, .complete)
        XCTAssertEqual(calendar.component(.day, from: augustSnapshot.monthStart), 1)

        let leap = report(now: date("2028-02-29T10:00:00Z"), days: 31,
            timeline: [day("2028-02-01", 10), day("2028-02-29", 29)])
        let leapSnapshot = UsageShareSnapshot(report: leap, period: .month, calendar: calendar)
        XCTAssertEqual(leapSnapshot.monthTokens.total, 39)
        XCTAssertEqual(leapSnapshot.monthAvailability, .complete)
    }

    func testMondayWeekCrossesMonthWithoutChangingCalendarMonth() {
        let value = report(now: date("2026-10-01T10:00:00Z"), days: 31,
            timeline: [day("2026-09-28", 10), day("2026-09-30", 20), day("2026-10-01", 30)])
        let snapshot = UsageShareSnapshot(report: value, period: .week, calendar: calendar)
        XCTAssertEqual(snapshot.days.map(\.id),
            ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"])
        XCTAssertEqual(snapshot.weekTokens.total, 60)
        XCTAssertEqual(snapshot.monthTokens.total, 30)
        XCTAssertEqual(snapshot.tokens, snapshot.weekTokens)
        XCTAssertEqual(snapshot.periodStart, snapshot.weekStart)
    }

    func testProjectScopeAggregatesAccountsAndRanksTodayWithoutRetainingIdentities() {
        let path = "/Users/private/company/important-project"
        let claudeA = project(path: path, name: "/leaked/name/important-project",
            days: [day("2026-09-14", 10), day("2026-09-15", 50)])
        let claudeB = project(path: path, days: [day("2026-09-15", 25)])
        let codex = project(path: path, days: [day("2026-09-15", 100, provider: .codex)])
        let accounts = [
            account(.claude, key: "secret-account-a", projects: [claudeA], days: claudeA.days),
            account(.claude, key: "secret-account-b", projects: [claudeB], days: claudeB.days),
            account(.codex, key: "secret-account-c", projects: [codex], days: codex.days)
        ]
        let value = report(now: date("2026-09-15T10:00:00Z"), days: 31,
            timeline: [day("2026-09-15", 50_000)], accounts: accounts)
        let snapshot = UsageShareSnapshot(report: value, period: .week, projectPath: path, calendar: calendar)

        XCTAssertTrue(snapshot.isProject)
        XCTAssertEqual(snapshot.projectName, "important-project")
        XCTAssertEqual(snapshot.weekTokens.total, 185)
        XCTAssertEqual(snapshot.todayTokens.total, 175)
        XCTAssertEqual(snapshot.todayRanking.map(\.provider), [.codex, .claude])
        XCTAssertEqual(snapshot.todayRanking.map { $0.tokens.total }, [100, 75])
        let description = String(reflecting: snapshot)
        XCTAssertFalse(description.contains(path))
        XCTAssertFalse(description.contains("secret-account"))
    }

    func testDailyRankingUsesProviderDaysStableTiesAndScanHonesty() {
        let claudeDay = day("2026-09-15", 100, provider: .claude)
        let codexDay = day("2026-09-15", 100, provider: .codex)
        let zero = day("2026-09-15", 0, provider: .codex)
        var partialScan = UsageScanSummary()
        partialScan.malformedLines = 1
        let accounts = [
            account(.codex, key: "c", projects: [], days: [codexDay, zero]),
            account(.claude, key: "a", projects: [], days: [claudeDay])
        ]
        let value = report(now: date("2026-09-15T10:00:00Z"), days: 31,
            timeline: [day("2026-09-15", 999)], accounts: accounts, scan: partialScan)
        let snapshot = UsageShareSnapshot(report: value, calendar: calendar)

        XCTAssertEqual(snapshot.todayRanking.map(\.provider), [.claude, .codex])
        XCTAssertEqual(snapshot.todayRanking.count, 2)
        XCTAssertTrue(snapshot.todayRanking.allSatisfy { $0.availability == .partial })
        XCTAssertEqual(snapshot.todayRanking.map { $0.tokens.total }, [100, 100])
        XCTAssertTrue(snapshot.isPartial)
    }

    func testKnownZeroProjectDiffersFromUnknownProjectAndNameCanBeHidden() {
        let path = "/private/known"
        let known = project(path: path, days: [])
        let value = report(now: date("2026-09-15T10:00:00Z"), days: 31, timeline: [],
            accounts: [account(.claude, key: "private", projects: [known], days: [])])
        let zero = UsageShareSnapshot(report: value, projectPath: path,
            includeProjectName: false, calendar: calendar)
        XCTAssertEqual(zero.todayTokens.total, 0)
        XCTAssertEqual(zero.todayAvailability, .complete)
        XCTAssertNil(zero.projectName)

        let unknown = UsageShareSnapshot(report: value, projectPath: "/private/missing", calendar: calendar)
        XCTAssertEqual(unknown.todayTokens.total, 0)
        XCTAssertEqual(unknown.todayAvailability, .unavailable)
        XCTAssertEqual(unknown.monthAvailability, .unavailable)
        XCTAssertTrue(unknown.isPartial)
    }

    func testReportTimezoneWinsAndShortWindowOnlyMakesSupportingPeriodsPartial() {
        let now = date("2026-09-13T22:30:00Z") // Monday in Paris, Sunday in Los Angeles.
        let value = report(now: now, days: 1, timeline: [day("2026-09-14", 42)])
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let daySnapshot = UsageShareSnapshot(report: value, period: .day, calendar: losAngeles)
        XCTAssertEqual(daySnapshot.days.map(\.id), ["2026-09-14"])
        XCTAssertEqual(daySnapshot.timeZone.identifier, "Europe/Paris")
        XCTAssertEqual(daySnapshot.availability, .complete)
        XCTAssertFalse(daySnapshot.isPartial)

        let weekSnapshot = UsageShareSnapshot(report: value, period: .week, calendar: losAngeles)
        XCTAssertEqual(weekSnapshot.weekAvailability, .complete)
        XCTAssertFalse(weekSnapshot.isPartial)
        let monthSnapshot = UsageShareSnapshot(report: value, period: .month, calendar: losAngeles)
        XCTAssertEqual(monthSnapshot.monthAvailability, .partial)
        XCTAssertTrue(monthSnapshot.isPartial)
    }
}
