import Foundation

/// A deliberately identity-free snapshot: only recorded counters and dates
/// reach the exported image. Changing the chart period never changes its week.
struct UsageShareSnapshot: Equatable {
    let generatedAt: Date
    let weekStart: Date
    let today: Date
    let timeZone: TimeZone
    let weekTokens: UsageTokenTotals
    let todayTokens: UsageTokenTotals
    let weekAvailability: UsageMeasurementAvailability
    let todayAvailability: UsageMeasurementAvailability
    let days: [UsageShareDay]

    var isPartial: Bool { weekAvailability != .complete || todayAvailability != .complete }

    init(report: UsageLedgerReport, calendar fallbackCalendar: Calendar = .current) {
        let calendar = report.calendar ?? fallbackCalendar
        // Use the report's clock, including for cached reports spanning midnight.
        generatedAt = report.generatedAt
        timeZone = calendar.timeZone
        today = calendar.startOfDay(for: report.generatedAt)
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        weekStart = start
        let formatter = UsageLedgerEngine.dayFormatter(calendar: calendar)
        let byDay = Dictionary(report.timeline.map { ($0.day, $0.tokens) }, uniquingKeysWith: { first, _ in first })
        let scanIsPartial = report.scan.hitLimit || report.scan.filesSkipped > 0
            || report.scan.malformedLines > 0 || report.scan.oversizedLines > 0
        days = (0...daysSinceMonday).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = formatter.string(from: date)
            let tokens = byDay[key] ?? UsageTokenTotals()
            let outsideReport = date < report.windowStart || date > report.windowEnd || report.days < 1
            return UsageShareDay(id: key, date: date, tokens: tokens,
                                 availability: UsageChartDay.totalAvailability(tokens, partialHistory: scanIsPartial || outsideReport))
        }
        weekTokens = days.reduce(UsageTokenTotals()) { $0 + $1.tokens }
        todayTokens = days.last?.tokens ?? UsageTokenTotals()
        weekAvailability = days.contains { $0.availability != .complete } ? .partial : .complete
        todayAvailability = days.last?.availability ?? .unavailable
    }
}

struct UsageShareDay: Identifiable, Equatable {
    let id: String
    let date: Date
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability
}
