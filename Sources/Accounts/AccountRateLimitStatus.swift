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
        let checkPause = usageCheckFailedAt.map { failedAt in
            AccountRateLimitStatus(kind: usageCheckRetryAt.map { $0 > now } == true ? .usageCheckPaused : .refreshRequired,
                retryAt: usageCheckRetryAt.flatMap { $0 > now ? $0 : nil }, observedAt: failedAt)
        }
        guard isConnected else { return checkPause ?? AccountRateLimitStatus(kind: .notReported) }
        let spent = windows.filter { ($0.usedFraction ?? 0) >= 1 || $0.isBlocked }
        let freshRestriction = providerRestriction.flatMap { restriction -> AccountProviderRestriction? in
            let age = now.timeIntervalSince(restriction.observedAt)
            return age >= -5 && age <= 300 ? restriction : nil
        }
        // Expired shared windows cannot hide a still-active model restriction.
        // Each independent evidence source expires on its own timestamp.
        let recentObservation = refreshedAt.map {
            let age = now.timeIntervalSince($0)
            return age >= -5 && age <= 300
        } == true
        let active = spent.filter { window in
            // A failed quota poll invalidates percentage-based availability,
            // but does not revoke an explicit vendor lock already observed.
            // Keep that lock only until its original observation/reset expires.
            (isFresh(at: now) || (window.isBlocked && recentObservation))
                && (window.resetsAt.map { $0 > now } ?? true)
        }
        let shared = active.filter { !$0.isModelSpecific }
        let applicable = shared.isEmpty ? active : shared
        if !applicable.isEmpty {
            // A short reset cannot clear an exhausted weekly allowance. Unknown
            // reset on any blocker means there is no known overall resume time.
            let reset = applicable.allSatisfy { $0.resetsAt != nil } ? applicable.compactMap(\.resetsAt).max() : nil
            // A separately reported restriction has no declared reset; do not
            // borrow one from an unrelated spent quota window.
            let independentRestriction = freshRestriction != nil
            let kind: AccountRateLimitStatus.Kind = freshRestriction?.modelName == nil && independentRestriction ? .providerRestricted
                : shared.isEmpty ? .modelRestricted
                : applicable.contains(where: { ($0.usedFraction ?? 0) >= 1 }) ? .quotaExhausted : .providerRestricted
            return AccountRateLimitStatus(kind: kind,
                affectedLabels: active.map(\.label) + (freshRestriction.map { [$0.label] } ?? []), retryAt: independentRestriction ? nil : reset,
                isResetDerived: !independentRestriction && reset != nil && applicable.contains(where: \.isResetDerived), observedAt: refreshedAt)
        }
        if let restriction = freshRestriction {
            return AccountRateLimitStatus(kind: restriction.modelName == nil ? .providerRestricted : .modelRestricted,
                affectedLabels: [restriction.label], observedAt: restriction.observedAt)
        }
        if let checkPause { return checkPause }
        if !spent.isEmpty || providerRestriction != nil {
            return AccountRateLimitStatus(kind: .refreshRequired,
                affectedLabels: spent.map(\.label) + (providerRestriction.map { [$0.label] } ?? []),
                observedAt: refreshedAt ?? providerRestriction?.observedAt)
        }
        return AccountRateLimitStatus(kind: .notReported, observedAt: refreshedAt)
    }
}
