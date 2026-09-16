import Foundation

/// A stamp records a consumption threshold, never a measure of skill or cost.
struct UsageMilestoneStamp: Codable, Equatable, Identifiable {
    let level: Int
    let threshold: Int
    let reached: Bool
    /// Absent when older aggregate history cannot establish the crossing date.
    let reachedAt: Date?
    var id: Int { level }
}

/// A derived recognition inside AI Podium. It is never a skill, cost or
/// productivity claim, and it deliberately carries no date when saved history
/// can prove the threshold but not when it was crossed.
struct UsageGenGenAchievement: Equatable {
    let reached: Bool
    let reachedAt: Date?

    static let locked = UsageGenGenAchievement(reached: false, reachedAt: nil)
}

/// Derived from the saved archive, independently of the selected chart period.
/// Keeping one source of truth makes stamps survive session/cache cleanup and
/// avoids a second store that could drift from corrected usage readings.
struct UsageMilestoneProgress: Codable, Equatable {
    static let thresholds = [100_000, 1_000_000, 10_000_000, 100_000_000,
                             1_000_000_000, 10_000_000_000, 100_000_000_000, 1_000_000_000_000]

    let totalTokens: Int
    let stamps: [UsageMilestoneStamp]
    /// Optional for decoding reports written before GenGen existed.
    private let evaluatedAt: Date?
    private let evaluationCalendar: Calendar?

    var level: Int { stamps.last(where: \.reached)?.level ?? 0 }
    /// No recorded consumption must not look like an earned White badge.
    var podiumTier: UsagePodiumTier? { totalTokens > 0 ? UsagePodiumTier(rawValue: level) : nil }
    var nextPodiumTier: UsagePodiumTier? { UsagePodiumTier(rawValue: (podiumTier?.rawValue ?? -1) + 1) }
    var next: UsageMilestoneStamp? { stamps.first { !$0.reached } }
    var genGen: UsageGenGenAchievement {
        guard let evaluatedAt, let evaluationCalendar else {
            return podiumTier.map({ $0.rawValue >= UsagePodiumTier.obsidian.rawValue }) == true
                ? UsageGenGenAchievement(reached: true, reachedAt: nil) : .locked
        }
        return genGen(at: evaluatedAt, calendar: evaluationCalendar)
    }
    var fractionToNext: Double {
        guard let next else { return 1 }
        let previous = stamps.last(where: \.reached)?.threshold ?? 0
        return min(1, max(0, Double(totalTokens - previous) / Double(next.threshold - previous)))
    }

    init(sessions: [UsageSessionDigest], now: Date, calendar: Calendar = .current) {
        var total = 0
        var byMinute: [Int: Int] = [:]
        var timelineIsComplete = true
        var didOverflow = false

        func adding(_ lhs: Int, _ rhs: Int) -> Int {
            let sum = lhs.addingReportingOverflow(rhs)
            if sum.overflow { didOverflow = true; return .max }
            return sum.partialValue
        }
        func count(_ tokens: UsageTokenTotals) -> Int {
            // Cache is part of input. Reasoning is already part of output.
            [tokens.input, tokens.cacheCreation, tokens.cacheRead, tokens.output]
                .reduce(0) { adding($0, max(0, $1)) }
        }

        for session in sessions {
            let sessionTotal = count(session.tokens)
            total = adding(total, sessionTotal)
            var datedTotal = 0
            for (key, bucket) in session.activityMinutes {
                let tokens = count(bucket.tokens)
                guard tokens > 0 else { continue }
                guard let minute = Int(key) else { timelineIsComplete = false; continue }
                let date = Date(timeIntervalSince1970: Double(minute) * 60)
                guard date <= now else { timelineIsComplete = false; continue }
                datedTotal = adding(datedTotal, tokens)
                byMinute[minute] = adding(byMinute[minute, default: 0], tokens)
            }
            // A preserved legacy total without full timing is still counted,
            // but it must not create an invented achievement date.
            if datedTotal != sessionTotal { timelineIsComplete = false }
        }

        var dates: [Int: Date] = [:]
        if timelineIsComplete && !didOverflow {
            var cumulative = 0
            var thresholdIndex = 0
            for minute in byMinute.keys.sorted() {
                cumulative = adding(cumulative, byMinute[minute, default: 0])
                while thresholdIndex < Self.thresholds.count,
                      cumulative >= Self.thresholds[thresholdIndex] {
                    dates[thresholdIndex] = Date(timeIntervalSince1970: Double(minute) * 60)
                    thresholdIndex += 1
                }
            }
        }

        totalTokens = total
        stamps = Self.thresholds.enumerated().map { index, threshold in
            UsageMilestoneStamp(level: index + 1, threshold: threshold,
                                reached: total >= threshold, reachedAt: dates[index])
        }
        evaluatedAt = now
        evaluationCalendar = calendar
    }

    /// GenGen is reached at Obsidian, or after two whole calendar months at
    /// Graphite. Calendar arithmetic preserves month-end and daylight-saving
    /// behavior; a missing Graphite date never starts an invented timer.
    func genGen(at date: Date, calendar: Calendar) -> UsageGenGenAchievement {
        let graphite = stamps.first { $0.level == UsagePodiumTier.graphite.rawValue }
        let obsidian = stamps.first { $0.level == UsagePodiumTier.obsidian.rawValue }
        let durationDate = graphite?.reachedAt.flatMap {
            calendar.date(byAdding: .month, value: 2, to: $0)
        }.flatMap { $0 <= date ? $0 : nil }
        let thresholdReached = (obsidian?.reached == true) || totalTokens >= UsagePodiumTier.obsidian.threshold
        guard thresholdReached || durationDate != nil else { return .locked }
        let thresholdDate = thresholdReached ? obsidian?.reachedAt : nil
        return UsageGenGenAchievement(reached: true,
                                      reachedAt: [thresholdDate, durationDate].compactMap { $0 }.min())
    }
}
