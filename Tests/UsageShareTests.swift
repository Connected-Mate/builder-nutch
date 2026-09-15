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
        XCTAssertEqual(week, month)
        XCTAssertEqual(week.days.map(\.id), ["2026-09-14", "2026-09-15"])
        XCTAssertEqual(week.weekTokens.total, 340)
        XCTAssertEqual(week.todayTokens.total, 220)
        XCTAssertEqual(week.weekTokens.thinking, 20)
        XCTAssertFalse(week.isPartial)
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
    func testArtworkKeepsLuminousBackgroundAndContrastingCards() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-09-15T10:00:00Z")!
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let slices = [3_000, 1_000].enumerated().map { index, value in
            UsageDaySlice(day: "2026-09-\(14 + index)", weight: 1, sharePercent: 0,
                tokens: UsageTokenTotals(input: value, measurements: 1, inputMeasurements: 1,
                    outputMeasurements: 1, codexMeasurements: 1), messages: 1)
        }
        let report = UsageLedgerReport(generatedAt: now, windowStart: start, windowEnd: now, days: 7,
            totalWeight: 2, tokens: UsageTokenTotals(), messages: 2, sessionCount: 2,
            accounts: [], timeline: slices, scan: UsageScanSummary())
        let data = try UsageShareExporter.pngData(snapshot: UsageShareSnapshot(report: report, calendar: calendar))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        // The previous export lost the reference's colored light entirely.
        // Inspect open background above the plates, not text or effects inside them.
        var colorful = 0, sampled = 0
        for y in stride(from: 30, to: 160, by: 20) {
            for x in stride(from: 40, to: 2360, by: 60) {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if components.max()! - components.min()! > 0.1 { colorful += 1 }
                sampled += 1
            }
        }
        XCTAssertGreaterThan(Double(colorful) / Double(sampled), 0.4)
        let weekly = try XCTUnwrap(rep.colorAt(x: 1480, y: 900)?.usingColorSpace(.deviceRGB))
        let today = try XCTUnwrap(rep.colorAt(x: 2180, y: 900)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(max(weekly.redComponent, weekly.greenComponent, weekly.blueComponent), 0.35)
        XCTAssertGreaterThan(min(today.redComponent, today.greenComponent, today.blueComponent), 0.8)

    }

    func testSevenDayArtworkRendersInEnglishAndFrenchWithLargePartialCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-09-20T10:45:00Z")!
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let tokens = UsageTokenTotals(input: 2_000_000_000, output: 45_678_901,
            measurements: 1, inputMeasurements: 1, outputMeasurements: 1, codexMeasurements: 1)
        let formatter = UsageLedgerEngine.dayFormatter(calendar: calendar)
        let slices = (0..<7).map { day in
            UsageDaySlice(day: formatter.string(from: calendar.date(byAdding: .day, value: day, to: start)!),
                weight: 1, sharePercent: 0, tokens: tokens, messages: 1)
        }
        var scan = UsageScanSummary(); scan.hitLimit = true
        let report = UsageLedgerReport(generatedAt: now, windowStart: start, windowEnd: now, days: 7,
            totalWeight: 7, tokens: tokens, messages: 7, sessionCount: 7, accounts: [], timeline: slices, scan: scan)
        let snapshot = UsageShareSnapshot(report: report, calendar: calendar)
        for language in ["en", "fr"] {
            let data = try UsageShareExporter.pngData(snapshot: snapshot, locale: Locale(identifier: language))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(rep.pixelsWide, 2400)
            XCTAssertEqual(rep.pixelsHigh, 1260)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Consumption export \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
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
        XCTAssertEqual(UsageShareExporter.filename(for: snapshot), "Builder-Nutch-tokens-2026-09-15.png")
    }
}
