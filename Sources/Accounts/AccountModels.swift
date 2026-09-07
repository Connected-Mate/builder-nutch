import Foundation

enum AccountProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor, kimi, grok, chatgpt, gemini, perplexity, deepseek, mistral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .kimi: return "Kimi"
        case .grok: return "Grok"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        case .perplexity: return "Perplexity"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral"
        }
    }
    var isBrowserProfile: Bool { self != .claude && self != .codex && self != .kimi }
    var supportsAutomaticSelection: Bool { !isBrowserProfile }
    var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .cursor: return "cursorarrow"
        case .kimi: return "moon.stars"
        case .grok: return "slash.circle"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .gemini: return "sparkle"
        case .perplexity: return "asterisk"
        case .deepseek: return "water.waves"
        case .mistral: return "wind"
        }
    }
    var connectionSummary: String {
        switch self {
        case .claude: return "Claude subscription · Coding"
        case .codex: return "ChatGPT subscription · Coding"
        case .kimi: return "Kimi Code subscription · Coding"
        case .cursor: return "Cursor account · Web dashboard"
        default: return "Separate web account"
        }
    }
    var connectionDetail: String {
        switch self {
        case .claude: return "Sign in with your Claude subscription. Launch Claude Code and follow its available usage."
        case .codex: return "Sign in with ChatGPT. Launch Codex and follow its available usage."
        case .kimi: return "Sign in with your Kimi Code subscription. Launch Kimi Code and follow its available usage."
        case .cursor: return "Sign in to your Cursor dashboard in a separate browser profile. This does not switch the Cursor editor account."
        default: return "Sign in on \(title)'s official website. Each account keeps its own browser profile."
        }
    }
    var website: URL {
        let address: String
        switch self {
        case .claude: address = "https://claude.ai/"
        case .codex, .chatgpt: address = "https://chatgpt.com/"
        case .cursor: address = "https://cursor.com/dashboard"
        case .kimi: address = "https://www.kimi.com/"
        case .grok: address = "https://grok.com/"
        case .gemini: address = "https://gemini.google.com/"
        case .perplexity: address = "https://www.perplexity.ai/"
        case .deepseek: address = "https://chat.deepseek.com/"
        case .mistral: address = "https://chat.mistral.ai/"
        }
        return URL(string: address)!
    }
    var signInWebsite: URL {
        // Official sign-in destination observed from Grok's own Sign in action.
        if self == .grok {
            return URL(string: "https://accounts.x.ai/sign-in?redirect=grok-com&return_to=%2F%3Fq%3D%26reasoningMode%3Dnone%26voice%3Dfalse")!
        }
        return website
    }
    var glyph: ProviderGlyph {
        switch self {
        case .claude: return .claude
        case .codex, .chatgpt: return .openai
        case .cursor: return .cursor
        case .gemini: return .geminiChat
        case .kimi: return .kimi
        case .grok: return .grok
        case .perplexity: return .perplexity
        case .deepseek: return .deepseek
        case .mistral: return .mistral
        }
    }
}

struct ManagedAccount: Identifiable, Codable, Equatable {
    let id: UUID
    let provider: AccountProvider
    var label: String
    var emailHint: String?
    let createdAt: Date
    var emoji: String? = nil
    /// A user confirmation, not a claim that the website session is still authenticated.
    var browserConfirmedAt: Date? = nil
    var browserBundleIdentifier: String? = nil
    /// Reference only; credentials and vendor configuration stay with the official app.
    var existingProfile: ExistingAccountProfile? = nil
}

/// A real automatic rotation, kept separate from manual account selection so
/// the notch only announces changes Builder Nutch made on the user's behalf.
struct AutomaticAccountSwitch: Identifiable, Equatable {
    let id = UUID()
    let provider: AccountProvider
    let fromID: UUID
    let fromName: String
    let toID: UUID
    let toName: String
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
    case invalidLabel, invalidEmail, invalidEmoji, unsafePath, corruptCatalog, missingCLI(AccountProvider), missingBrowser
    case busy, cancelled, timedOut, commandFailed(Int32), invalidResponse, notConnected, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidLabel: return "Choose a name between 1 and 80 characters."
        case .invalidEmoji: return "Choose one emoji, or leave it empty."
        case .missingBrowser: return "Install Google Chrome, Brave or Microsoft Edge to keep each web account separate, then try again."
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
        guard provider.supportsAutomaticSelection else { return nil }
        return accounts.filter { account in
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

    /// Keep the chosen account while it has room, then advance through the
    /// user's order. The order wraps, so every available subscription gets a turn.
    static func rotating(
        provider: AccountProvider,
        accounts: [ManagedAccount],
        states: [UUID: ManagedAccountState],
        order: [UUID],
        currentID: UUID?,
        thresholdPercent: Double,
        now: Date = Date()
    ) -> ManagedAccount? {
        guard provider.supportsAutomaticSelection else { return nil }
        let eligible = accounts.filter { account in
            guard account.provider == provider, let state = states[account.id], state.isConnected,
                  !state.isBusy, state.message == nil, state.isFresh(at: now), !state.windows.isEmpty else { return false }
            return state.windows.allSatisfy { window in
                guard let fraction = window.usedFraction, fraction.isFinite, fraction >= 0, fraction < 1 else { return false }
                return window.resetsAt.map { $0 > now } ?? true
            }
        }
        guard !eligible.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let known = order.compactMap { byID[$0] }
        let missing = eligible.filter { account in !order.contains(account.id) }
            .sorted { $0.createdAt < $1.createdAt }
        let cycle = known + missing
        let threshold = min(max(thresholdPercent, 0), 100)
        let clearsThreshold: (ManagedAccount) -> Bool = { account in
            (states[account.id]?.remainingPercent ?? 0) > threshold + 0.001
        }
        if let currentID, let current = byID[currentID], clearsThreshold(current) { return current }
        let currentIndex = currentID.flatMap { id in cycle.firstIndex { $0.id == id } }
        let wrapped = (0..<cycle.count).map { offset in
            cycle[((currentIndex ?? -1) + 1 + offset) % cycle.count]
        }
        return wrapped.first(where: clearsThreshold)
            ?? cycle.max { (states[$0.id]?.remainingPercent ?? 0) < (states[$1.id]?.remainingPercent ?? 0) }
    }
}
