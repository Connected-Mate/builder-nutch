import Foundation

/// One reading of how much of a rolling window has been spent.
struct UsageSample: Equatable {
    let date: Date
    /// 0...1, where 1 means the window is spent.
    let usedFraction: Double
}

/// A short, in-memory burn-rate estimate for one account's rolling window.
///
/// Nothing is written to disk and nothing leaves the process: a forecast is a
/// hint that lets rotation move *before* an account runs dry, never a record of
/// what the person did. History is deliberately tiny — twelve readings at the
/// app's one-minute refresh is about ten minutes of trend, which is all that is
/// needed to answer "will this account last another twenty minutes?".
struct UsageForecast: Equatable {
    /// Enough history to smooth a minute-by-minute refresh without keeping a log.
    static let capacity = 12
    /// Below this span two readings are noise, not a trend.
    static let minimumSpan: TimeInterval = 300
    /// One reading cannot describe a rate, and two are easily a fluke.
    static let minimumSamples = 3
    /// A window that was this close to spent and then dropped really did roll over.
    static let spentMark = 0.9

    private(set) var samples: [UsageSample] = []
    /// When the window last rolled over after having been spent. This is what
    /// makes "the account the person actually asked for is available again" a
    /// fact rather than a guess.
    private(set) var recoveredAt: Date?

    init() {}

    /// Records a reading. Out-of-order and non-finite readings are ignored; a
    /// reading lower than the previous one means the window rolled over, so the
    /// old samples are dropped rather than averaged into an impossible rate.
    mutating func record(usedFraction: Double, at date: Date) {
        guard usedFraction.isFinite else { return }
        let fraction = min(max(usedFraction, 0), 1)
        if let last = samples.last {
            guard date > last.date else { return }
            if fraction + 0.001 < last.usedFraction {
                if last.usedFraction >= Self.spentMark { recoveredAt = date }
                samples.removeAll()
            }
        }
        samples.append(UsageSample(date: date, usedFraction: fraction))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// True only when there is enough history to claim a rate at all: three
    /// readings spanning five minutes. A forecast is allowed to move the Mac's
    /// login, so the bar for having one is stated here rather than left implied.
    var hasReliableTrend: Bool { burnRate != nil }

    /// Fraction of the window spent per minute, or nil while the trend is unknown.
    /// A least-squares slope, so one noisy reading cannot fake an emergency.
    var burnRate: Double? {
        guard samples.count >= Self.minimumSamples, let first = samples.first, let last = samples.last,
              last.date.timeIntervalSince(first.date) >= Self.minimumSpan else { return nil }
        let minutes = samples.map { $0.date.timeIntervalSince(first.date) / 60 }
        let meanMinutes = minutes.reduce(0, +) / Double(minutes.count)
        let meanUsed = samples.map(\.usedFraction).reduce(0, +) / Double(samples.count)
        var covariance = 0.0, variance = 0.0
        for (minute, sample) in zip(minutes, samples) {
            covariance += (minute - meanMinutes) * (sample.usedFraction - meanUsed)
            variance += (minute - meanMinutes) * (minute - meanMinutes)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        guard slope.isFinite, slope > 0 else { return nil }
        return slope
    }

    /// Minutes before the window is spent at the observed rate, or nil when
    /// nothing measurable is being spent. Zero means it is already gone.
    func minutesUntilExhausted(at now: Date) -> Double? {
        guard let rate = burnRate, let last = samples.last else { return nil }
        let elapsed = max(0, now.timeIntervalSince(last.date) / 60)
        let remaining = 1 - (last.usedFraction + rate * elapsed)
        guard remaining > 0 else { return 0 }
        let minutes = remaining / rate
        return minutes.isFinite ? minutes : nil
    }

    /// "3 h 10" or "45 min". Rounded the way a person reads a clock, never to a
    /// precision the estimate does not have.
    static func headroom(minutes: Double) -> String? {
        guard minutes.isFinite, minutes >= 0 else { return nil }
        let whole = Int(minutes.rounded())
        if whole < 60 { return String(format: NSLocalizedString("%d min", comment: "Minutes of usage left"), max(1, whole)) }
        let hours = whole / 60, rest = whole % 60
        if rest == 0 { return String(format: NSLocalizedString("%d h", comment: "Hours of usage left"), hours) }
        return String(format: NSLocalizedString("%d h %02d", comment: "Hours and minutes of usage left"), hours, rest)
    }
}
