import Foundation

/// Presentation only: preserve empty calendar days and the certainty of each
/// reading. Neither drawing nor selection alters the ledger's token arithmetic.
struct UsageChartDay: Identifiable, Equatable {
    let id: String
    let tokens: UsageTokenTotals
    let availability: UsageMeasurementAvailability

    static func make(keys: [String], timeline: [UsageDaySlice], partialHistory: Bool) -> [UsageChartDay] {
        let byDay = Dictionary(timeline.map { ($0.day, $0.tokens) }, uniquingKeysWith: { first, _ in first })
        return keys.map { key in
            let tokens = byDay[key] ?? UsageTokenTotals()
            return UsageChartDay(id: key, tokens: tokens,
                                 availability: totalAvailability(tokens, partialHistory: partialHistory))
        }
    }

    static func totalAvailability(_ tokens: UsageTokenTotals, partialHistory: Bool) -> UsageMeasurementAvailability {
        // No recorded activity is a zero day. Missing fields in actual activity
        // are a lower bound, not a falsely complete total.
        if partialHistory { return .partial }
        if tokens.measurements > 0,
           inputAvailability(tokens) != .complete || tokens.coverage.output != .complete { return .partial }
        return .complete
    }

    static func inputAvailability(_ tokens: UsageTokenTotals) -> UsageMeasurementAvailability {
        let coverage = tokens.coverage
        // Codex's input count is already inclusive: missing cache breakdowns
        // do not make that known total incomplete. Claude adds separate fields.
        let onlyCodex = tokens.measurements > 0 && tokens.codexMeasurements == tokens.measurements
        if coverage.input == .complete,
           onlyCodex || (coverage.cacheCreation == .complete && coverage.cacheRead == .complete) { return .complete }
        if coverage.input != .unavailable || coverage.cacheCreation != .unavailable || coverage.cacheRead != .unavailable { return .partial }
        return .unavailable
    }

    static func availability(_ measured: UsageMeasurementAvailability, partialHistory: Bool) -> UsageMeasurementAvailability {
        partialHistory && measured == .complete ? .partial : measured
    }

    func fraction(of peak: Int) -> Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, Double(tokens.total) / Double(peak)))
    }
}
