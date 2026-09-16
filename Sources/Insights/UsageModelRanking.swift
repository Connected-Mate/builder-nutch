import Foundation

/// Numeric model attribution preserved at the same local-day/project grain as
/// the ledger. A missing identifier is explicit; it is never guessed from a tool.
struct UsageModelDaySlice: Codable, Equatable {
    let provider: UsageTranscriptFormat
    let modelID: String?
    let day: String
    let projectPath: String
    let tokens: UsageTokenTotals
}

struct UsageModelTotal: Identifiable, Equatable {
    /// Tools that recorded this exact model identifier, in stable order.
    let sources: [UsageTranscriptFormat]
    let modelID: String?
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability

    var provider: UsageTranscriptFormat? { sources.count == 1 ? sources.first : nil }
    var id: String { modelID.map { "model:\($0)" } ?? "unknown:\(provider?.rawValue ?? "unknown")" }

    init(provider: UsageTranscriptFormat?, modelID: String?, tokens: UsageTokenTotals,
         availability: UsageMeasurementAvailability, sources: [UsageTranscriptFormat] = []) {
        let allSources = sources + [provider].compactMap { $0 }
        self.sources = Set(allSources.map(\.rawValue)).sorted().compactMap(UsageTranscriptFormat.init(rawValue:))
        self.modelID = modelID
        self.tokens = tokens
        self.availability = availability
    }
}

/// Model ranking is raw token consumption, never quota weighting or a session's
/// lifetime dominant model. Dates select inclusive local calendar days.
enum UsageModelRanking {
    private struct BucketKey: Hashable {
        let provider: String?
        let day: String
    }
    private struct ModelKey: Hashable {
        let provider: String?
        let modelID: String?
    }

    static func entries(in report: UsageLedgerReport, from start: Date? = nil, through end: Date? = nil,
                        projectPath: String? = nil) -> [UsageModelTotal] {
        let calendar = report.calendar ?? .current
        let formatter = UsageLedgerEngine.dayFormatter(calendar: calendar)
        let startDate = start ?? report.windowStart
        let endDate = end ?? report.windowEnd
        guard startDate <= endDate else { return [] }
        let first = formatter.string(from: max(startDate, report.windowStart))
        let last = formatter.string(from: min(endDate, report.windowEnd))
        guard first <= last else { return [] }
        func selected(_ day: String) -> Bool { day >= first && day <= last }

        var budgets: [BucketKey: UsageTokenTotals] = [:]
        for account in report.accounts {
            let days = projectPath.map { path in account.projects.filter { $0.path == path }.flatMap(\.days) }
                ?? account.days
            for day in days where selected(day.day) {
                budgets[BucketKey(provider: account.provider.rawValue, day: day.day), default: UsageTokenTotals()] += day.tokens
            }
        }

        var attributed: [BucketKey: [ModelKey: UsageTokenTotals]] = [:]
        for day in report.modelDays where selected(day.day) && (projectPath == nil || day.projectPath == projectPath) {
            let bucket = BucketKey(provider: day.provider.rawValue, day: day.day)
            let model = ModelKey(provider: day.provider.rawValue, modelID: day.modelID)
            attributed[bucket, default: [:]][model, default: UsageTokenTotals()] += day.tokens
        }
        // A report loaded without account metadata must still conserve every
        // timeline token. Only explicit source observations can name its tool.
        if projectPath == nil {
            var timeline: [String: UsageTokenTotals] = [:]
            for day in report.timeline where selected(day.day) {
                timeline[day.day, default: UsageTokenTotals()] += day.tokens
            }
            for (day, expected) in timeline {
                var remaining = expected
                for (key, budget) in budgets where key.day == day { _ = take(budget, from: &remaining) }
                let observed = attributed.filter { $0.key.day == day && budgets[$0.key] == nil }
                    .sorted { ($0.key.provider ?? "") < ($1.key.provider ?? "") }
                for (key, models) in observed {
                    let requested = models.values.reduce(UsageTokenTotals(), +)
                    let accepted = take(requested, from: &remaining)
                    if accepted.total > 0 { budgets[key] = accepted }
                }
                if remaining.total > 0 {
                    let source: String?
                    if remaining.measurements > 0 && remaining.claudeMeasurements == remaining.measurements {
                        source = UsageTranscriptFormat.claude.rawValue
                    } else if remaining.measurements > 0 && remaining.codexMeasurements == remaining.measurements {
                        source = UsageTranscriptFormat.codex.rawValue
                    } else { source = nil }
                    budgets[BucketKey(provider: source, day: day), default: UsageTokenTotals()] += remaining
                }
            }
        }
        var totals: [ModelKey: UsageTokenTotals] = [:]
        var partial = report.scan.hitLimit || report.scan.filesSkipped > 0
            || report.scan.malformedLines > 0 || report.scan.oversizedLines > 0
            || calendar.startOfDay(for: startDate) < calendar.startOfDay(for: report.windowStart)
            || calendar.startOfDay(for: endDate) > calendar.startOfDay(for: report.windowEnd)
        for (bucket, budget) in budgets {
            var remaining = budget
            // Known identities claim only counters actually present in the
            // ledger. Unknown entries receive the exact remaining counters.
            let known = (attributed[bucket] ?? [:]).filter { $0.key.modelID != nil }
                .sorted { ($0.key.modelID ?? "") < ($1.key.modelID ?? "") }
            for (model, observed) in known {
                let accepted = take(observed, from: &remaining)
                if accepted.total != observed.total { partial = true }
                if accepted.total > 0 { totals[model, default: UsageTokenTotals()] += accepted }
            }
            if remaining.total > 0 {
                partial = true
                totals[ModelKey(provider: bucket.provider, modelID: nil), default: UsageTokenTotals()] += remaining
            }
        }
        var grouped: [String: UsageModelTotal] = [:]
        for (key, tokens) in totals {
            let provider = key.provider.flatMap(UsageTranscriptFormat.init(rawValue:))
            let next = UsageModelTotal(provider: provider, modelID: key.modelID, tokens: tokens,
                availability: UsageChartDay.totalAvailability(tokens, partialHistory: partial))
            if let existing = grouped[next.id] {
                let combined = existing.tokens + next.tokens
                grouped[next.id] = UsageModelTotal(provider: nil, modelID: next.modelID, tokens: combined,
                    availability: existing.availability == .complete && next.availability == .complete ? .complete : .partial,
                    sources: existing.sources + next.sources)
            } else { grouped[next.id] = next }
        }
        return grouped.values.sorted { left, right in
            if left.tokens.total != right.tokens.total { return left.tokens.total > right.tokens.total }
            return left.id < right.id
        }
    }

    /// Counter-wise subtraction retains coverage and never adds reasoning twice.
    private static func take(_ requested: UsageTokenTotals, from remaining: inout UsageTokenTotals) -> UsageTokenTotals {
        var result = UsageTokenTotals()
        let fields: [WritableKeyPath<UsageTokenTotals, Int>] = [\.input, \.output, \.cacheCreation, \.cacheRead,
            \.thinking, \.measurements, \.inputMeasurements, \.outputMeasurements, \.cacheCreationMeasurements,
            \.cacheReadMeasurements, \.thinkingMeasurements, \.claudeMeasurements, \.codexMeasurements]
        for field in fields {
            let value = min(max(0, requested[keyPath: field]), max(0, remaining[keyPath: field]))
            result[keyPath: field] = value
            remaining[keyPath: field] -= value
        }
        return result
    }
}
