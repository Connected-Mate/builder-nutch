import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

final class UsageShareSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Paris")!
        value.firstWeekday = 1 // Export week deliberately remains Monday-based.
        return value
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func report(now: Date, days: Int = 30, slices: [UsageDaySlice], partial: Bool = false) -> UsageLedgerReport {
        var scan = UsageScanSummary(); scan.hitLimit = partial
        return UsageLedgerReport(generatedAt: now,
            windowStart: calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!,
            windowEnd: now, days: days, totalWeight: 0,
            tokens: slices.reduce(UsageTokenTotals()) { $0 + $1.tokens }, messages: 0, sessionCount: 1,
            accounts: [], timeline: slices, scan: scan)
    }

    private func slice(_ day: String, input: Int, output: Int = 20, reasoning: Int = 10) -> UsageDaySlice {
        UsageDaySlice(day: day, weight: 1, sharePercent: 0,
            tokens: UsageTokenTotals(input: input, output: output, thinking: reasoning,
                measurements: 1, inputMeasurements: 1, outputMeasurements: 1,
                thinkingMeasurements: 1, codexMeasurements: 1), messages: 1)
    }

    func testCalendarWeekIgnoresPreviousWeekAndChartPeriodAndDoesNotAddReasoningTwice() {
        let now = date("2026-09-15T10:00:00Z")
        let slices = [slice("2026-09-13", input: 90_000), slice("2026-09-14", input: 100),
                      slice("2026-09-15", input: 200), slice("2026-09-16", input: 80_000)]
        let week = UsageShareSnapshot(report: report(now: now, days: 7, slices: slices), calendar: calendar)
        let month = UsageShareSnapshot(report: report(now: now, slices: slices), calendar: calendar)
        XCTAssertEqual(week.weekTokens, month.weekTokens)
        XCTAssertEqual(week.todayTokens, month.todayTokens)
        XCTAssertEqual(week.weekAvailability, month.weekAvailability)
        XCTAssertEqual(week.days.map(\.id), ["2026-09-14", "2026-09-15"])
        XCTAssertEqual(week.weekTokens.total, 340)
        XCTAssertEqual(week.todayTokens.total, 220)
        XCTAssertEqual(week.weekTokens.thinking, 20)
        XCTAssertFalse(week.isPartial)
    }

    func testLifetimePodiumTierIsFrozenAcrossPeriodsAndProjectScopes() {
        let now = date("2026-09-15T10:00:00Z")
        var value = report(now: now, slices: [slice("2026-09-15", input: 1)])
        var lifetime = UsageSessionDigest(sessionID: "private-lifetime")
        lifetime.tokens = UsageTokenTotals(input: 100_000_000)
        value.milestones = UsageMilestoneProgress(sessions: [lifetime], now: now)
        for period in UsageSharePeriod.allCases {
            for path: String? in [nil, "/private/missing-project"] {
                let snapshot = UsageShareSnapshot(report: value, period: period, projectPath: path)
                XCTAssertEqual(snapshot.podiumTier, .platinum)
            }
        }
        value.milestones = nil
        XCTAssertNil(UsageShareSnapshot(report: value).podiumTier, "Never infer lifetime level from selected usage")
        value.milestones = UsageMilestoneProgress(sessions: [], now: now)
        XCTAssertNil(UsageShareSnapshot(report: value).podiumTier, "No earned badge without recorded consumption")
    }

    func testMondayAndLocalMidnightUseReportTimeNotCurrentClock() {
        let now = date("2026-09-13T22:30:00Z") // Monday in Paris, Sunday in UTC.
        let snapshot = UsageShareSnapshot(report: report(now: now, slices: [slice("2026-09-14", input: 100)]), calendar: calendar)
        XCTAssertEqual(snapshot.days.map(\.id), ["2026-09-14"])
        XCTAssertEqual(snapshot.weekTokens, snapshot.todayTokens)
        XCTAssertEqual(snapshot.generatedAt, now)
    }

    func testDaylightSavingSundayStillHasSevenCalendarDaysAndRealZeroDays() {
        let snapshot = UsageShareSnapshot(report: report(now: date("2026-03-29T21:00:00Z"), slices: []), calendar: calendar)
        XCTAssertEqual(snapshot.days.map(\.id), ["2026-03-23", "2026-03-24", "2026-03-25", "2026-03-26", "2026-03-27", "2026-03-28", "2026-03-29"])
        XCTAssertEqual(snapshot.weekTokens.total, 0)
        XCTAssertFalse(snapshot.isPartial)
    }

    func testExportKeepsLedgerCalendarWhenTheMacTimezoneChanges() throws {
        let now = date("2026-09-13T22:30:00Z") // Monday in ledger's Paris zone.
        var recorded = report(now: now, slices: [slice("2026-09-14", input: 100)])
        recorded.calendar = calendar
        var changedMacCalendar = calendar
        changedMacCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let snapshot = UsageShareSnapshot(report: recorded, calendar: changedMacCalendar)
        XCTAssertEqual(snapshot.days.map(\.id), ["2026-09-14"])
        XCTAssertEqual(snapshot.todayTokens.total, 120)
        XCTAssertEqual(snapshot.timeZone.identifier, "Europe/Paris")
        let decoded = try JSONDecoder().decode(UsageLedgerReport.self, from: JSONEncoder().encode(recorded))
        XCTAssertEqual(decoded.calendar?.timeZone, calendar.timeZone)
        let live = UsageLedgerEngine.report(sessions: [], summary: UsageScanSummary(), days: 7,
            now: now, calendar: calendar, timeline: UsageAccountTimeline())
        XCTAssertEqual(live.calendar, calendar)
    }

    func testMissingFieldsAndIncompleteReadingRemainLowerBounds() {
        let incomplete = UsageDaySlice(day: "2026-09-15", weight: 1, sharePercent: 0,
            tokens: UsageTokenTotals(input: 100, measurements: 1, inputMeasurements: 1), messages: 1)
        let now = date("2026-09-15T10:00:00Z")
        let fields = UsageShareSnapshot(report: report(now: now, slices: [incomplete]), calendar: calendar)
        XCTAssertEqual(fields.todayAvailability, .partial)
        XCTAssertEqual(fields.weekAvailability, .partial)
        XCTAssertEqual(fields.weekTokens.total, 100)
        let partial = UsageShareSnapshot(report: report(now: now, slices: [], partial: true), calendar: calendar)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.todayAvailability, .partial)
    }

    func testWindowNotCoveringMondayMarksWeekPartialButKeepsKnownDayExact() {
        let snapshot = UsageShareSnapshot(report: report(now: date("2026-09-15T10:00:00Z"), days: 1,
            slices: [slice("2026-09-15", input: 100)]), calendar: calendar)
        XCTAssertEqual(snapshot.weekAvailability, .partial)
        XCTAssertEqual(snapshot.todayAvailability, .complete)
    }
}

@MainActor
final class UsageShareExportTests: XCTestCase {
    private func fixture(claude: Int = 2_000_000_000, codex: Int = 900_000_000, partial: Bool = false,
                         output: Int = 45_678_901, activeDays: [Int] = [1, 26, 31]) -> UsageLedgerReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z")!
        var sessions: [UsageSessionDigest] = []
        for (provider, input) in [(UsageTranscriptFormat.claude, claude), (.codex, codex)] where input > 0 {
            for day in activeDays {
                let timestamp = ISO8601DateFormatter().date(from: String(format: "2026-10-%02dT12:00:00Z", day))!
                let tokens = UsageTokenTotals(input: input, output: output, thinking: min(7_000, output),
                    measurements: 1, inputMeasurements: 1, outputMeasurements: 1,
                    cacheCreationMeasurements: 1, cacheReadMeasurements: 1, thinkingMeasurements: 1,
                    claudeMeasurements: provider == .claude ? 1 : 0,
                    codexMeasurements: provider == .codex ? 1 : 0)
                var session = UsageSessionDigest(sessionID: "\(provider.rawValue)-\(day)", provider: provider)
                session.tokens = tokens; session.weight = 1; session.messages = 1
                session.firstActivity = timestamp; session.lastActivity = timestamp
                session.projectWeights = ["/private/fixture/Projet de démonstration — une très longue réalisation internationale": 1]
                session.activityMinutes = [String(Int(timestamp.timeIntervalSince1970 / 60)): UsageTimeBucket(tokens: tokens, weight: 1, messages: 1)]
                sessions.append(session)
            }
        }
        var scan = UsageScanSummary(); scan.hitLimit = partial
        return UsageLedgerEngine.report(sessions: sessions, summary: scan, days: 31, now: now,
                                        calendar: calendar, timeline: UsageAccountTimeline())
    }

    func testBackgroundUsesOnlyTheLeadingProviderColor() throws {
        for provider in [UsageTranscriptFormat.claude, .codex] {
            let report = fixture(claude: provider == .claude ? 3_000 : 0,
                                 codex: provider == .codex ? 3_000 : 0)
            let snapshot = UsageShareSnapshot(report: report)
            XCTAssertEqual(snapshot.todayRanking.first?.provider, provider)
            let data = try UsageShareExporter.pngData(snapshot: snapshot)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            var orangeSamples = 0
            // Open area above both plates: decorative colors must follow the winner.
            for y in stride(from: 170, to: 200, by: 10) {
                for x in stride(from: 100, to: 2300, by: 60) {
                    let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let values = [color.redComponent, color.greenComponent, color.blueComponent]
                    if provider == .codex {
                        XCTAssertLessThan(values.max()! - values.min()!, 0.035)
                    } else {
                        XCTAssertGreaterThanOrEqual(color.redComponent + 0.01, color.blueComponent)
                        if color.redComponent - color.blueComponent > 0.035 { orangeSamples += 1 }
                    }
                    XCTAssertLessThan(values.max()!, 0.75, "No bright decorative white wash")
                }
            }
            if provider == .claude { XCTAssertGreaterThan(orangeSamples, 10) }
        }
    }

    func testPeriodAndProjectArtworkRendersInEnglishAndFrench() throws {
        for language in ["en", "fr"] {
            for period in UsageSharePeriod.allCases {
                let report = fixture(claude: language == "fr" ? 500_000_000 : 2_000_000_000,
                                     codex: 900_000_000, partial: true)
                let path = language == "fr" ? report.accounts.first?.projects.first?.path : nil
                let snapshot = UsageShareSnapshot(report: report, period: period, projectPath: path)
                let data = try UsageShareExporter.pngData(snapshot: snapshot, locale: Locale(identifier: language))
                let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertEqual(rep.pixelsWide, 2400); XCTAssertEqual(rep.pixelsHigh, 1260)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Podium \(language) \(period.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testAllLifetimeTierArtworkRendersInEnglishAndFrench() throws {
        for language in ["en", "fr"] {
            for tier in UsagePodiumTier.allCases {
                let total = max(1, tier.threshold)
                let codex = total / 4
                var report = fixture(claude: total - codex, codex: codex, output: 0, activeDays: [31])
                var lifetime = UsageSessionDigest(sessionID: "public-example")
                lifetime.tokens = UsageTokenTotals(input: max(1, tier.threshold))
                report.milestones = UsageMilestoneProgress(sessions: [lifetime], now: report.generatedAt)
                let snapshot = UsageShareSnapshot(report: report, period: .day)
                XCTAssertEqual(snapshot.podiumTier, tier)
                let data = try UsageShareExporter.pngData(snapshot: snapshot, locale: Locale(identifier: language))
                let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertEqual(rep.pixelsWide, 2400); XCTAssertEqual(rep.pixelsHigh, 1260)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "AI Podium level \(tier.rawValue) \(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testPNGDimensionsAndPrivateClipboardRoundTrip() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-15T10:00:00Z")!
        let report = UsageLedgerEngine.report(sessions: [], summary: UsageScanSummary(), days: 7, now: now,
            calendar: .current, timeline: UsageAccountTimeline())
        let snapshot = UsageShareSnapshot(report: report)
        let data = try UsageShareExporter.pngData(snapshot: snapshot)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 2400)
        XCTAssertEqual(rep.pixelsHigh, 1260)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try UsageShareExporter.copy(data, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertEqual(UsageShareExporter.filename(for: snapshot), "Builder-Nutch-day-tokens-2026-09-15.png")
    }
}
