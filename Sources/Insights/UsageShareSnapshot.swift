import Foundation

enum UsageSharePeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }
}

struct UsageShareProviderTotal: Equatable, Identifiable {
    let provider: UsageTranscriptFormat
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability

    var id: String { provider.rawValue }
}

/// An identity-free export value. Account identifiers and full project paths
/// are used only while aggregating and are never retained by the snapshot.
struct UsageShareSnapshot: Equatable {
    let generatedAt: Date
    let weekStart: Date
    let monthStart: Date
    let today: Date
    let timeZone: TimeZone
    let weekTokens: UsageTokenTotals
    let monthTokens: UsageTokenTotals
    let todayTokens: UsageTokenTotals
    let weekAvailability: UsageMeasurementAvailability
    let monthAvailability: UsageMeasurementAvailability
    let todayAvailability: UsageMeasurementAvailability
    let days: [UsageShareDay]
    let period: UsageSharePeriod
    let periodStart: Date
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability
    let todayRanking: [UsageShareProviderTotal]
    let projectName: String?
    let isProject: Bool
    /// Frozen lifetime level, never recomputed from a period or project scope.
    let podiumTier: UsagePodiumTier?

    var isPartial: Bool {
        availability != .complete || todayAvailability != .complete
            || todayRanking.contains { $0.availability != .complete }
    }

    init(report: UsageLedgerReport, period: UsageSharePeriod = .day, projectPath: String? = nil,
         includeProjectName: Bool = true, calendar fallbackCalendar: Calendar = .current) {
        let calendar = report.calendar ?? fallbackCalendar
        let today = calendar.startOfDay(for: report.generatedAt)
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let formatter = UsageLedgerEngine.dayFormatter(calendar: calendar)
        let todayKey = formatter.string(from: today)
        let scanIsPartial = report.scan.hitLimit || report.scan.filesSkipped > 0
            || report.scan.malformedLines > 0 || report.scan.oversizedLines > 0

        let matchingProjects = projectPath.map { selectedPath in
            report.accounts.flatMap(\.projects).filter { $0.path == selectedPath }
        } ?? []
        let projectWasFound = projectPath == nil || !matchingProjects.isEmpty
        let sourceTimeline = projectPath == nil ? report.timeline : matchingProjects.flatMap(\.days)
        let byDay = Self.tokensByDay(sourceTimeline)

        func shareDays(from start: Date) -> [UsageShareDay] {
            var result: [UsageShareDay] = []
            var date = start
            while date <= today {
                let key = formatter.string(from: date)
                let tokens = byDay[key] ?? UsageTokenTotals()
                let availability: UsageMeasurementAvailability
                if !projectWasFound {
                    availability = .unavailable
                } else {
                    let reportStart = calendar.startOfDay(for: report.windowStart)
                    let reportEnd = calendar.startOfDay(for: report.windowEnd)
                    let outsideReport = report.days < 1 || date < reportStart || date > reportEnd
                    availability = UsageChartDay.totalAvailability(
                        tokens, partialHistory: scanIsPartial || outsideReport)
                }
                result.append(UsageShareDay(id: key, date: date, tokens: tokens, availability: availability))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
                date = next
            }
            return result
        }

        let weekDays = shareDays(from: weekStart)
        let monthDays = shareDays(from: monthStart)
        let todayDay = weekDays.last ?? UsageShareDay(
            id: todayKey, date: today, tokens: UsageTokenTotals(), availability: .unavailable)
        let weekSummary = Self.summary(of: weekDays)
        let monthSummary = Self.summary(of: monthDays)

        var providerTokens: [String: (provider: UsageTranscriptFormat, tokens: UsageTokenTotals)] = [:]
        if projectWasFound {
            for account in report.accounts {
                let providerDays: [UsageDaySlice]
                if let projectPath {
                    providerDays = account.projects.filter { $0.path == projectPath }.flatMap(\.days)
                } else {
                    providerDays = account.days
                }
                for day in providerDays where day.day == todayKey {
                    let key = account.provider.rawValue
                    var total = providerTokens[key] ?? (account.provider, UsageTokenTotals())
                    total.tokens += day.tokens
                    providerTokens[key] = total
                }
            }
        }
        let todayOutsideReport = report.days < 1
            || today < calendar.startOfDay(for: report.windowStart)
            || today > calendar.startOfDay(for: report.windowEnd)
        let rankingPartial = scanIsPartial || todayOutsideReport
        let todayRanking = providerTokens.values.compactMap { entry -> UsageShareProviderTotal? in
            guard entry.tokens.measurements > 0, entry.tokens.total > 0 else { return nil }
            return UsageShareProviderTotal(
                provider: entry.provider, tokens: entry.tokens,
                availability: UsageChartDay.totalAvailability(entry.tokens, partialHistory: rankingPartial))
        }.sorted {
            if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
            return $0.provider.rawValue < $1.provider.rawValue
        }

        let selected: (start: Date, tokens: UsageTokenTotals, availability: UsageMeasurementAvailability)
        switch period {
        case .day:
            selected = (today, todayDay.tokens, todayDay.availability)
        case .week:
            selected = (weekStart, weekSummary.tokens, weekSummary.availability)
        case .month:
            selected = (monthStart, monthSummary.tokens, monthSummary.availability)
        }

        self.generatedAt = report.generatedAt
        self.podiumTier = report.milestones?.podiumTier
        self.weekStart = weekStart
        self.monthStart = monthStart
        self.today = today
        self.timeZone = calendar.timeZone
        self.weekTokens = weekSummary.tokens
        self.monthTokens = monthSummary.tokens
        self.todayTokens = todayDay.tokens
        self.weekAvailability = weekSummary.availability
        self.monthAvailability = monthSummary.availability
        self.todayAvailability = todayDay.availability
        self.days = weekDays
        self.period = period
        self.periodStart = selected.start
        self.tokens = selected.tokens
        self.availability = selected.availability
        self.todayRanking = todayRanking
        self.isProject = projectPath != nil
        if includeProjectName, let name = matchingProjects.first?.name {
            let basename = (name as NSString).lastPathComponent
            self.projectName = basename.isEmpty ? nil : basename
        } else {
            self.projectName = nil
        }
    }

    private static func tokensByDay(_ timeline: [UsageDaySlice]) -> [String: UsageTokenTotals] {
        timeline.reduce(into: [:]) { result, day in
            result[day.day, default: UsageTokenTotals()] += day.tokens
        }
    }

    private static func summary(of days: [UsageShareDay])
        -> (tokens: UsageTokenTotals, availability: UsageMeasurementAvailability) {
        let tokens = days.reduce(UsageTokenTotals()) { $0 + $1.tokens }
        if days.allSatisfy({ $0.availability == .unavailable }) { return (tokens, .unavailable) }
        if days.contains(where: { $0.availability != .complete }) { return (tokens, .partial) }
        return (tokens, .complete)
    }
}

struct UsageShareDay: Identifiable, Equatable {
    let id: String
    let date: Date
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability
}
