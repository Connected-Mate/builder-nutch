import Foundation

/// A request-context projection. The original evidence remains intact for details.
enum ClaudeModelPolicy {
    enum Family: String, CaseIterable {
        case fable = "Fable", opus = "Opus", sonnet = "Sonnet", haiku = "Haiku"
        var alias: String { rawValue.lowercased() }
        var fallbacks: [Family] {
            switch self {
            case .fable: return [.opus, .sonnet, .haiku]
            case .opus: return [.sonnet, .haiku]
            case .sonnet: return [.haiku]
            case .haiku: return []
            }
        }
    }

    struct Choice: Equatable {
        let accountID: UUID
        let model: String
        let family: Family
        let isFallback: Bool
    }

    /// Anchored grammar prevents incidental family words in unknown scopes from
    /// turning a restriction into permission. Versions and context suffixes are
    /// accepted; custom routes, compound model aliases and unknown names are not.
    static func family(for model: String?) -> Family? {
        guard let model, model.utf8.count <= 160 else { return nil }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:claude[- ](?:[0-9]+(?:[.\-][0-9]+)*[- ])?)?(fable|opus|sonnet|haiku)(?:[- ][0-9]+(?:[.\-][0-9]+)*)?(?:\[[0-9]+[km]\]| \([0-9]+[km](?: context)?\))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range(at: 1), in: normalized) else { return nil }
        return Family.allCases.first { $0.alias == normalized[range] }
    }

    static func project(_ state: ManagedAccountState, model: String?, now: Date = Date()) -> ManagedAccountState {
        guard let selected = family(for: model) else { return state }
        var result = state
        result.windows = state.windows.filter { window in
            guard let used = window.usedFraction, used.isFinite, used >= 0 else { return true }
            guard let scope = family(for: window.modelName) else { return true }
            return scope == selected
        }
        if let restriction = state.providerRestriction,
           let scope = family(for: restriction.modelName), scope != selected {
            result.providerRestriction = nil
        }
        // Clear only the parser's exact generated restriction, and only after
        // every restriction was conclusively excluded. Arbitrary failures survive.
        let originallyBlocked = state.windows.contains { $0.isBlocked || ($0.usedFraction ?? 0) >= 1 }
            || state.providerRestriction != nil
        let stillBlocked = result.windows.contains { $0.isBlocked || ($0.usedFraction ?? 0) >= 1 }
            || result.providerRestriction != nil
        if originallyBlocked, !stillBlocked, state.isConnected, !state.needsAttention,
           state.isFresh(at: now), !result.windows.isEmpty,
           result.windows.allSatisfy({ $0.usedFraction.map { $0.isFinite && $0 >= 0 } == true }),
           state.message == ClaudeAccountUsage.restriction(state, now: state.refreshedAt ?? now) {
            result.message = nil
        }
        if stillBlocked, result.message == nil {
            result.message = ClaudeAccountUsage.restriction(result, now: now)
        }
        return result
    }

    /// Preserve the requested model whenever an account can serve it. A downgrade
    /// needs positive, fresh subscription evidence for both shared and model pools.
    static func fallbackChoice(preferredModel: String, accounts: [ManagedAccount],
                               states: [UUID: ManagedAccountState], order: [UUID],
                               currentID: UUID? = nil, now: Date = Date()) -> Choice? {
        guard let preferred = family(for: preferredModel) else { return nil }
        let preferredStates = states.mapValues { project($0, model: preferredModel, now: now) }
            .filter { _, state in available(state, now: now) }
        if let account = AccountSelection.rotating(provider: .claude, accounts: accounts, states: preferredStates,
            order: order, currentID: currentID, thresholdPercent: 0, now: now) {
            return Choice(accountID: account.id, model: preferredModel, family: preferred, isFallback: false)
        }
        // Missing, stale, busy or failed evidence is not proof that the preferred
        // model is exhausted. Wait for a definitive queue reading before downgrading.
        for account in accounts where account.provider == .claude {
            guard let state = states[account.id] else { return nil }
            if !state.isConnected { continue }
            guard state.isFresh(at: now), !state.isBusy, !state.needsAttention,
                  !state.windows.isEmpty,
                  state.windows.allSatisfy({ $0.usedFraction.map { $0.isFinite && $0 >= 0 } == true
                      && ($0.resetsAt.map { $0 > now } ?? true) }),
                  state.message == nil || state.message == ClaudeAccountUsage.restriction(state, now: state.refreshedAt ?? now)
            else { return nil }
        }
        for fallback in preferred.fallbacks {
            let verified = states.filter { _, state in
                guard state.isFresh(at: now), !state.accountWindows.isEmpty else { return false }
                let specific = state.windows.filter { family(for: $0.modelName) == fallback }
                guard !specific.isEmpty else { return false }
                return (state.accountWindows + specific).allSatisfy { window in
                    guard !window.isBlocked, let used = window.usedFraction,
                          used.isFinite, used >= 0, used < 1 else { return false }
                    return window.resetsAt.map { $0 > now } ?? true
                }
            }.mapValues { project($0, model: fallback.alias, now: now) }
                .filter { _, state in available(state, now: now) }
            if let account = AccountSelection.rotating(provider: .claude, accounts: accounts, states: verified,
                order: order, currentID: currentID, thresholdPercent: 0, now: now) {
                return Choice(accountID: account.id, model: fallback.alias, family: fallback, isFallback: true)
            }
        }
        return nil
    }

    private static func available(_ state: ManagedAccountState, now: Date) -> Bool {
        state.isConnected && !state.needsAttention && !state.isBusy && state.isFresh(at: now)
            && state.message == nil && state.providerRestriction == nil && !state.windows.isEmpty
            && state.windows.allSatisfy { window in
                guard !window.isBlocked, let used = window.usedFraction,
                      used.isFinite, used >= 0, used < 1 else { return false }
                return window.resetsAt.map { $0 > now } ?? true
            }
    }
}
