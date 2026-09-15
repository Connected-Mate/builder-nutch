import Foundation

struct CustomAssistantUsage: Codable, Equatable {
    struct RateLimit: Codable, Equatable {
        enum Kind: String, Codable { case rateLimited, concurrencyLimited, providerOverloaded }
        var kind: Kind
        /// Account, model or workspace actually named by the observed response.
        var scope: String
        /// Only a time explicitly provided by the service, never a guessed delay.
        var retryAt: Date?
        var title: String {
            switch kind {
            case .rateLimited: return NSLocalizedString("Request limit reached", comment: "Reported inference rate limit")
            case .concurrencyLimited: return NSLocalizedString("Concurrent request limit reached", comment: "Reported concurrency limit")
            case .providerOverloaded: return NSLocalizedString("Provider overloaded", comment: "Reported provider overload")
            }
        }
    }
    struct Limit: Codable, Equatable {
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
    }
    var limits: [Limit]
    var observedAt: Date
    /// A description of where the assistant actually observed the figures.
    var source: String
    var rateLimit: RateLimit? = nil

    func validate(now: Date = Date()) throws {
        guard (!limits.isEmpty || rateLimit != nil), limits.count <= 8,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.count <= 200,
              observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 > 0,
              observedAt <= now.addingTimeInterval(300) else {
            throw CustomAssistantError.invalid("Provide 1–8 observed limits, their source and a valid observation timestamp, not a future estimate.")
        }
        for limit in limits {
            guard !limit.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  limit.label.count <= 80, limit.usedPercent.isFinite, (0...100).contains(limit.usedPercent),
                  limit.resetsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > observedAt }) ?? true else {
                throw CustomAssistantError.invalid("Each limit needs a label, 0–100 percent used, and an optional reset after the observation.")
            }
        }
        if let rateLimit {
            guard !rateLimit.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rateLimit.scope.count <= 80,
                  !rateLimit.scope.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  rateLimit.retryAt.map({ $0.timeIntervalSince1970.isFinite && $0 > observedAt }) ?? true else {
                throw CustomAssistantError.invalid("A reported request limit needs its observed scope and an optional provider retry time after the observation.")
            }
        }
    }

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) >= 3600 || limits.contains { $0.resetsAt.map { $0 <= now } ?? false }
            || rateLimit?.retryAt.map { $0 <= now } == true
    }
}
