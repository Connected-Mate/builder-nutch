import Foundation

/// A vendor restriction reported separately from its numerical quota windows.
/// No inference request is sent to obtain this evidence.
struct AccountProviderRestriction: Equatable {
    var label: String
    var modelName: String? = nil
    var observedAt: Date
}

struct AccountRateLimitStatus: Equatable {
    enum Kind { case quotaExhausted, modelRestricted, providerRestricted, usageCheckPaused, refreshRequired, notReported }
    var kind: Kind
    var affectedLabels: [String] = []
    /// A reset of the observed constraint, never a guarantee that requests resume.
    var retryAt: Date? = nil
    var isResetDerived = false
    var observedAt: Date? = nil

    var title: String {
        switch kind {
        case .quotaExhausted: return NSLocalizedString("Usage limit reached", comment: "Confirmed quota block")
        case .modelRestricted: return NSLocalizedString("Model limit reached", comment: "Confirmed model block")
        case .providerRestricted: return NSLocalizedString("Provider restriction", comment: "Explicit provider block")
        case .usageCheckPaused: return NSLocalizedString("Usage check paused", comment: "Usage endpoint backoff, not inference")
        case .refreshRequired: return NSLocalizedString("Refresh needed", comment: "Restriction evidence expired")
        case .notReported: return NSLocalizedString("Request limits not reported", comment: "No inference rate evidence")
        }
    }
}

extension ManagedAccountState {
    /// Subscription percentages cannot establish RPM, TPM or concurrency headroom.
    /// This projection reports only observed restrictions and labels polling
    /// backoff separately. A passed reset requires a fresh measurement.
    func rateLimitStatus(at now: Date = Date()) -> AccountRateLimitStatus {
        if usageCheckFailedAt != nil {
            return AccountRateLimitStatus(kind: usageCheckRetryAt.map { $0 > now } == true ? .usageCheckPaused : .refreshRequired,
                retryAt: usageCheckRetryAt.flatMap { $0 > now ? $0 : nil }, observedAt: usageCheckFailedAt)
        }
        guard isConnected else { return AccountRateLimitStatus(kind: .notReported) }
        let spent = windows.filter { ($0.usedFraction ?? 0) >= 1 || $0.isBlocked }
        if !spent.isEmpty {
            let shared = spent.filter { !$0.isModelSpecific }
            let applicable = (shared.isEmpty ? spent : shared).filter { $0.resetsAt.map { $0 > now } ?? true }
            guard isFresh(at: now), !applicable.isEmpty else {
                return AccountRateLimitStatus(kind: .refreshRequired, affectedLabels: spent.map(\.label), observedAt: refreshedAt)
            }
            // A short reset cannot clear an exhausted weekly allowance. Unknown
            // reset on any blocker means there is no known overall resume time.
            let reset = applicable.allSatisfy { $0.resetsAt != nil } ? applicable.compactMap(\.resetsAt).max() : nil
            // A separately reported restriction has no declared reset; do not
            // borrow one from an unrelated spent quota window.
            let independentRestriction = providerRestriction != nil
            let kind: AccountRateLimitStatus.Kind = providerRestriction?.modelName == nil && independentRestriction ? .providerRestricted
                : shared.isEmpty ? .modelRestricted
                : applicable.contains(where: { ($0.usedFraction ?? 0) >= 1 }) ? .quotaExhausted : .providerRestricted
            return AccountRateLimitStatus(kind: kind,
                affectedLabels: spent.map(\.label) + (providerRestriction.map { [$0.label] } ?? []), retryAt: independentRestriction ? nil : reset,
                isResetDerived: reset != nil && applicable.contains(where: \.isResetDerived), observedAt: refreshedAt)
        }
        if let restriction = providerRestriction {
            let age = now.timeIntervalSince(restriction.observedAt)
            return AccountRateLimitStatus(kind: age >= -5 && age <= 300
                ? (restriction.modelName == nil ? .providerRestricted : .modelRestricted) : .refreshRequired,
                affectedLabels: [restriction.label], observedAt: restriction.observedAt)
        }
        return AccountRateLimitStatus(kind: .notReported, observedAt: refreshedAt)
    }
}
