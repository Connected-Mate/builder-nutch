import Foundation

enum AccountProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

struct ManagedAccount: Identifiable, Codable, Equatable {
    let id: UUID
    let provider: AccountProvider
    var label: String
    var emailHint: String?
    let createdAt: Date
}

struct ManagedAccountState {
    var isConnected = false
    var email: String? = nil
    var plan: String? = nil
    var windows: [LimitWindow] = []
    var refreshedAt: Date? = nil
    var message: String? = nil
    var isBusy = false
    var remainingPercent: Double? {
        let fractions = windows.compactMap(\.usedFraction)
        guard !fractions.isEmpty else { return nil }
        return max(0, 100 * (1 - (fractions.max() ?? 1)))
    }
    var needsFirstUsage: Bool { isConnected && windows.isEmpty }
    func isFresh(at now: Date = Date()) -> Bool {
        guard let refreshedAt else { return false }
        return now.timeIntervalSince(refreshedAt) >= -5 && now.timeIntervalSince(refreshedAt) <= 300
    }
}

enum ManagedAccountError: LocalizedError {
    case invalidLabel, invalidEmail, unsafePath, corruptCatalog, missingCLI(AccountProvider)
    case busy, cancelled, timedOut, commandFailed(Int32), invalidResponse, notConnected, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidLabel: return "Choose a name between 1 and 80 characters."
        case .invalidEmail: return "Enter a valid email hint, or leave it empty."
        case .unsafePath: return "The account folder is not safe to use. Choose a private local folder."
        case .corruptCatalog: return "The account catalog could not be read. It was preserved; restore it before adding accounts."
        case .missingCLI(let provider): return "Install the official \(provider.title) command-line app, then try again."
        case .busy: return "Finish or cancel the current account operation first."
        case .cancelled: return "Connection cancelled."
        case .timedOut: return "The official app did not finish in time. Try again."
        case .commandFailed(let code): return "The official app could not complete this action (exit \(code)). Try again."
        case .invalidResponse: return "The official app returned an unreadable account response. Update it and try again."
        case .notConnected: return "Connect this account before launching a session."
        case .unavailable: return "No connected account has fresh, available usage. Refresh or choose an account manually."
        }
    }
}

enum AccountSelection {
    static func best(provider: AccountProvider, accounts: [ManagedAccount], states: [UUID: ManagedAccountState], now: Date = Date()) -> ManagedAccount? {
        accounts.filter { account in
            guard account.provider == provider, let state = states[account.id], state.isConnected,
                  !state.isBusy, state.message == nil, state.isFresh(at: now), !state.windows.isEmpty else { return false }
            return state.windows.allSatisfy { window in
                guard let fraction = window.usedFraction, fraction.isFinite, fraction >= 0, fraction < 1 else { return false }
                return window.resetsAt.map { $0 > now } ?? true
            }
        }.sorted {
            let left = states[$0.id]?.remainingPercent ?? 0
            let right = states[$1.id]?.remainingPercent ?? 0
            if left != right { return left > right }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }
}
