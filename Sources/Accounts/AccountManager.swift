import AppKit
import Combine
import Foundation

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var accounts: [ManagedAccount] = []
    @Published private(set) var states: [UUID: ManagedAccountState] = [:]
    @Published private(set) var selected: [AccountProvider: UUID] = [:]
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published private(set) var loginAccountID: UUID?
    @Published private(set) var authorizationAccountID: UUID?
    var authenticationInProgress: Bool { loginAccountID != nil || authorizationAccountID != nil }
    @Published var notice: String?
    @Published private(set) var discoveryNotice: String?
    @Published private(set) var automaticSwitch: AutomaticAccountSwitch?
    /// The login actually installed for ordinary Claude Code sessions on this Mac.
    @Published private(set) var systemClaudeAccountID: UUID?
    private let systemCredentials: ClaudeSystemCredentials?
    private let systemClaudeLocation: ClaudeCredentialLocation
    private let claudeReader: (any ClaudeAccountReading)?
    private var pausedRefreshIDs: Set<UUID> = []
    private var systemSwitchPaused = false
    private var isSwitchingClaude = false
    private var hasShutDown = false
    private var discoveryCancellation: AccountCancellation?
    private var markerRecoveryTask: Task<Void, Never>?
    private var ignoredExistingProfiles: Set<String> = []
    private var discoveryAttempts: [String: Date] = [:]
    private var externalRetryAfter: [UUID: Date] = [:]
    private var discovering = false
    private let automaticDiscovery: Bool
    @Published var automaticSelection = false {
        didSet {
            guard loaded else { return }
            if automaticSelection {
                systemSwitchPaused = false
                reconcileAutomaticSelection()
                Task { await reconcileSystemClaudeSelection() }
            }
            updateHealth()
            do { try persist(accounts: accounts, selected: selected) }
            catch { notice = error.localizedDescription }
        }
    }
    @Published private(set) var rotationOrder: [AccountProvider: [UUID]] = [:]
    @Published private(set) var switchThresholdPercent: Double = 15
    /// How far ahead of a predicted exhaustion the Mac login moves on.
    @Published private(set) var switchAheadMinutes: Double = 20
    /// The single thing the person has to act on right now, or nil when nothing
    /// needs them. Never more than one: a list of problems is a list nobody reads.
    @Published private(set) var attention: AccountAttention?
    /// What is true right now, whether or not anything needs fixing.
    @Published private(set) var health = AccountHealth()
    /// The last thing that stopped being a problem. Set only when something was
    /// actually fixed, never when a row simply went away.
    @Published private(set) var resolvedAttention: AccountResolution?
    /// Burn-rate history per account. In memory only; never persisted.
    private(set) var usageForecasts: [UUID: UsageForecast] = [:]
    /// The login this app last saw on the Mac. Not the same question as which
    /// account is queued next, and conflating the two would let a manual "Set
    /// next" look identical to someone running `claude /login` behind our back.
    private var lastKnownSystemClaude: UUID?
    private var lastQueueAudit: Date?
    /// A queued account that quietly expired has to be found long before a
    /// rotation needs it, so the whole queue is rechecked on this cadence.
    static let queueAuditInterval: TimeInterval = 1800

    private let storage: AccountStorage?
    private let runner: any AccountCommandRunning
    private let resolveExecutable: (AccountProvider) -> URL?
    private let openTerminal: (URL) -> Bool
    private let openBrowser: (URL, URL, String?) async throws -> String
    private let readKimi: (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState
    private let readExistingKimi: (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState
    /// Reads the Cursor desktop editor's own login. Takes only a directory:
    /// nothing is launched, nothing is written, and no environment is prepared,
    /// because Cursor owns its session and this only ever looks at it.
    private let readCursor: (URL, AccountCancellation) async throws -> ManagedAccountState
    private var browserOpenedIDs: Set<UUID> = []
    private var operations: [UUID: AccountCancellation] = [:]
    private var loaded = false
    private var catalogError: Error?

    convenience init(rootURL: URL? = nil) {
        self.init(rootURL: rootURL, runner: OfficialAccountProcess(),
                  executable: AccountEnvironment.executable,
                  openTerminal: { NSWorkspace.shared.openFile($0.path, withApplication: "Terminal") })
    }

    init(rootURL: URL?, runner: any AccountCommandRunning,
         executable: @escaping (AccountProvider) -> URL?, openTerminal: @escaping (URL) -> Bool = { _ in false },
         openBrowser: @escaping (URL, URL, String?) async throws -> String = AccountBrowser.open,
         readKimi: @escaping (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState = KimiAccountIntegration.read,
         readExistingKimi: @escaping (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState = KimiAccountIntegration.readExisting,
         readCursor: @escaping (URL, AccountCancellation) async throws -> ManagedAccountState = CursorAccountIntegration.read,
         systemCredentials: ClaudeSystemCredentials? = nil,
         systemClaudeDirectory: URL? = nil,
         claudeReader: (any ClaudeAccountReading)? = nil) {
        self.automaticDiscovery = rootURL == nil
        self.systemCredentials = systemCredentials ?? (rootURL == nil ? ClaudeSystemCredentials() : nil)
        self.claudeReader = claudeReader ?? self.systemCredentials.map { ClaudeQuietUsageReader(credentials: $0) }
        self.systemClaudeLocation = ClaudeCredentialLocation(directory: systemClaudeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"), isDefault: true)
        self.runner = runner; self.resolveExecutable = executable; self.openTerminal = openTerminal
        self.openBrowser = openBrowser; self.readKimi = readKimi; self.readExistingKimi = readExistingKimi
        self.readCursor = readCursor
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codenotch Accounts", isDirectory: true)
        do {
            let storage = try AccountStorage(root: root)
            let catalog = try storage.load()
            self.storage = storage
            ignoredExistingProfiles = catalog.ignoredExistingProfiles ?? []
            accounts = catalog.accounts; selected = catalog.selected; automaticSelection = catalog.automaticSelection
            rotationOrder = catalog.rotationOrder ?? [:]
            switchThresholdPercent = catalog.switchThresholdPercent ?? 15
            switchAheadMinutes = catalog.switchAheadMinutes ?? 20
            // No record yet means this catalog predates the field. Assume the
            // Mac was on the queued account, so only a real divergence adopts.
            lastKnownSystemClaude = catalog.systemClaudeAccountID ?? catalog.selected[.claude]
            normalizeRotationOrder()
            states = Dictionary(uniqueKeysWithValues: accounts.map {
                ($0.id, $0.isBrowserOnly ? Self.browserState($0) : ManagedAccountState(message: "Refresh to check this account."))
            })
        } catch {
            self.storage = nil; catalogError = error; notice = error.localizedDescription
        }
        loaded = true
        recoverClaudeCacheMarkers()
        shareSavedClaudeLogins()
        updateHealth()
    }

    /// Saved logins this app created natively are moved to Apple's helper once,
    /// so a sign-in or session launched for that profile never asks for the
    /// Keychain password. Runs in the background; failures stay silent because
    /// the app itself can still read the item either way.
    private func shareSavedClaudeLogins() {
        guard let credentials = systemCredentials else { return }
        let locations = accounts.filter { $0.provider == .claude && $0.existingProfile == nil }.map(credentialLocation)
        Task.detached(priority: .utility) {
            for location in locations { _ = try? credentials.shareLoginWithClaude(at: location) }
        }
    }

    private func shareClaudeLogin(_ account: ManagedAccount) async {
        guard let credentials = systemCredentials, account.provider == .claude, account.existingProfile == nil else { return }
        let location = credentialLocation(for: account)
        _ = try? await Task.detached(priority: .userInitiated) { try credentials.shareLoginWithClaude(at: location) }.value
    }

    private func recoverClaudeCacheMarkers() {
        guard systemCredentials != nil, markerRecoveryTask == nil else { return }
        let locations = [systemClaudeLocation] + accounts.filter { $0.provider == .claude }.map(credentialLocation)
        markerRecoveryTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                for location in locations {
                    try? ClaudeSystemCredentials.cleanupStaleCacheMarker(at: location)
                }
            }.value
            self?.markerRecoveryTask = nil
        }
    }

    private func usableStorage() throws -> AccountStorage {
        if let catalogError { throw catalogError }
        guard let storage else { throw ManagedAccountError.unsafePath }
        return storage
    }

    private func persist(accounts: [ManagedAccount], selected: [AccountProvider: UUID]) throws {
        try usableStorage().save(AccountCatalog(accounts: accounts, selected: selected,
            automaticSelection: automaticSelection, ignoredExistingProfiles: ignoredExistingProfiles,
            rotationOrder: rotationOrder, switchThresholdPercent: switchThresholdPercent,
            switchAheadMinutes: switchAheadMinutes, systemClaudeAccountID: lastKnownSystemClaude))
    }

    @discardableResult
    func add(provider: AccountProvider, label: String, emailHint: String?) throws -> ManagedAccount {
        let account = ManagedAccount(id: UUID(), provider: provider, label: try AccountStorage.validLabel(label),
                                     emailHint: try AccountStorage.validEmail(emailHint), createdAt: Date())
        _ = try usableStorage().profile(account)
        var selection = selected
        if selection[provider] == nil { selection[provider] = account.id }
        try persist(accounts: accounts + [account], selected: selection)
        accounts.append(account); selected = selection; states[account.id] = ManagedAccountState()
        normalizeRotationOrder()
        try persist(accounts: accounts, selected: selected)
        updateHealth()
        return account
    }

    func rename(_ account: ManagedAccount, to label: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { throw ManagedAccountError.unavailable }
        var updated = accounts; updated[index].label = try AccountStorage.validLabel(label)
        try persist(accounts: updated, selected: selected); accounts = updated
    }

    func personalize(_ account: ManagedAccount, label: String, emoji: String?) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { throw ManagedAccountError.unavailable }
        var updated = accounts
        updated[index].label = try AccountStorage.validLabel(label)
        updated[index].emoji = try AccountStorage.validEmoji(emoji)
        try persist(accounts: updated, selected: selected)
        accounts = updated
    }

    private static func browserState(_ account: ManagedAccount) -> ManagedAccountState {
        ManagedAccountState(isConnected: account.browserConfirmedAt != nil,
                            plan: "Browser profile", message: account.browserConfirmedAt == nil ? "Sign in on the official website, then confirm here." : nil)
    }

    func canConfirmBrowserConnection(_ account: ManagedAccount) -> Bool {
        account.isBrowserOnly && browserOpenedIDs.contains(account.id) && !busyIDs.contains(account.id)
    }

    func confirmBrowserConnection(_ account: ManagedAccount) throws {
        guard account.isBrowserOnly, browserOpenedIDs.contains(account.id),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { throw ManagedAccountError.notConnected }
        var updated = accounts
        updated[index].browserConfirmedAt = Date()
        try persist(accounts: updated, selected: selected)
        accounts = updated
        states[account.id] = Self.browserState(updated[index])
        browserOpenedIDs.remove(account.id)
        updateHealth()
        notice = "Browser profile saved. Your sign-in stays in its browser; usage is shown on the website."
    }

    private func showBrowser(_ account: ManagedAccount, signingIn: Bool = false) async throws {
        guard let current = accounts.first(where: { $0.id == account.id && $0.provider == account.provider }),
              current.isBrowserOnly, current.existingProfile == nil else { throw ManagedAccountError.unavailable }
        // Never an existing profile: the browser directory is *created* below,
        // and a vendor's own folder is read-only to this app in every case.
        let profile = try usableStorage().profile(current).appendingPathComponent("browser", isDirectory: true)
        try AccountStorage.privateDirectory(profile)
        let identifier = try await openBrowser(profile, signingIn ? current.provider.signInWebsite : current.provider.website, current.browserBundleIdentifier)
        guard let index = accounts.firstIndex(where: { $0.id == current.id }) else { throw ManagedAccountError.unavailable }
        var updated = accounts
        updated[index].browserBundleIdentifier = identifier
        try persist(accounts: updated, selected: selected)
        accounts = updated
        browserOpenedIDs.insert(current.id)
    }

    func select(_ account: ManagedAccount) throws {
        guard accounts.contains(where: { $0.id == account.id && $0.provider == account.provider }) else { throw ManagedAccountError.unavailable }
        var updated = selected; updated[account.provider] = account.id
        try persist(accounts: accounts, selected: updated); selected = updated
        updateHealth()
        notice = account.isBrowserOnly ? "\(account.label) is selected. Open it to use its separate browser profile." : "\(account.label) is selected for future sessions. Existing sessions keep their account."
    }

    func rotationAccounts(for provider: AccountProvider) -> [ManagedAccount] {
        let ids = rotationOrder[provider] ?? []
        let byID = Dictionary(uniqueKeysWithValues: accounts.filter { $0.provider == provider }.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] } + byID.values.filter { !ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    func moveInRotation(_ account: ManagedAccount, offset: Int) throws {
        normalizeRotationOrder()
        guard var ids = rotationOrder[account.provider], let index = ids.firstIndex(of: account.id) else { return }
        let destination = min(max(index + offset, 0), ids.count - 1)
        guard destination != index else { return }
        ids.remove(at: index); ids.insert(account.id, at: destination)
        rotationOrder[account.provider] = ids
        try persist(accounts: accounts, selected: selected)
        updateHealth()
    }

    /// Moves one account directly onto another account's position. This is the
    /// operation used by the notch's drag-and-drop list.
    func moveInRotation(accountID: UUID, to targetID: UUID) throws {
        normalizeRotationOrder()
        guard let account = accounts.first(where: { $0.id == accountID }),
              let target = accounts.first(where: { $0.id == targetID }),
              account.provider == target.provider,
              var ids = rotationOrder[account.provider],
              accountID != targetID,
              ids.contains(accountID), ids.contains(targetID)
        else { return }
        guard let destination = ids.firstIndex(of: targetID) else { return }
        ids.removeAll { $0 == accountID }
        ids.insert(accountID, at: min(destination, ids.count))
        rotationOrder[account.provider] = ids
        try persist(accounts: accounts, selected: selected)
        updateHealth()
    }

    func setNext(_ account: ManagedAccount) throws {
        try select(account)
        notice = "\(account.label) will be used for the next \(account.provider.title) session."
    }

    func setSwitchThreshold(_ percent: Double) throws {
        switchThresholdPercent = min(max(percent.rounded(), 0), 100)
        reconcileAutomaticSelection()
        updateHealth()
        Task { await reconcileSystemClaudeSelection() }
        try persist(accounts: accounts, selected: selected)
    }

    /// How much notice an automatic switch takes when the burn rate says the
    /// current account is about to run out. Zero disables forecast switching.
    func setSwitchAheadMinutes(_ minutes: Double) throws {
        switchAheadMinutes = min(max(minutes.rounded(), 0), 240)
        updateHealth()
        Task { await reconcileSystemClaudeSelection() }
        try persist(accounts: accounts, selected: selected)
    }

    func remove(_ account: ManagedAccount) throws {
        guard !busyIDs.contains(account.id) else { throw ManagedAccountError.busy }
        let updated = accounts.filter { $0.id != account.id }
        var selection = selected
        if selection[account.provider] == account.id { selection[account.provider] = updated.first { $0.provider == account.provider }?.id }
        let previousIgnored = ignoredExistingProfiles
        if let source = account.existingProfile { ignoredExistingProfiles.insert(source.key(provider: account.provider)) }
        do { try persist(accounts: updated, selected: selection) }
        catch { ignoredExistingProfiles = previousIgnored; throw error }
        accounts = updated; selected = selection; states.removeValue(forKey: account.id)
        usageForecasts.removeValue(forKey: account.id)
        normalizeRotationOrder()
        try persist(accounts: accounts, selected: selected)
        browserOpenedIDs.remove(account.id)
        updateHealth()
        notice = "Account removed from the list. Its private profile and official app credentials were retained; existing sessions continue."
    }

    func configurationDirectory(for account: ManagedAccount) -> URL {
        if let source = account.existingProfile { return URL(fileURLWithPath: source.directory, isDirectory: true) }
        let base = storage?.root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codenotch Accounts")
        return base.appendingPathComponent("profiles/\(account.id.uuidString.lowercased())", isDirectory: true)
    }

    func state(for account: ManagedAccount) -> ManagedAccountState { states[account.id] ?? ManagedAccountState() }
    func isSelected(_ account: ManagedAccount) -> Bool { selected[account.provider] == account.id }
    func selectedAccount(for provider: AccountProvider) -> ManagedAccount? { accounts.first { $0.id == selected[provider] } }

    private func credentialLocation(for account: ManagedAccount) -> ClaudeCredentialLocation {
        ClaudeCredentialLocation(directory: configurationDirectory(for: account),
            isDefault: account.existingProfile?.usesDefaultClaudeHome == true)
    }

    /// Identify by both provider account and organization, never a nickname or email hint.
    private func updateSystemClaudeIdentity() {
        guard let credentials = systemCredentials else { return }
        let identity = try? credentials.identity(at: systemClaudeLocation)
        systemClaudeAccountID = identity.flatMap { current in
            accounts.first { account in
                account.provider == .claude && (try? credentials.identity(at: credentialLocation(for: account))) == current
            }?.id
        }
        adoptSystemClaudeLogin()
    }

    /// The Mac's login is the truth; the catalog is only this app's record of it.
    /// Someone can run `claude /login` themselves, and this app used to follow
    /// that in `systemClaudeAccountID` while leaving `selected` pointing at an
    /// account that had not been in use for hours. Everything downstream — which
    /// account is "next", what the notch calls current, where a rotation starts —
    /// reads one or the other, so the two must never disagree.
    private func adoptSystemClaudeLogin() {
        guard !isSwitchingClaude, let currentID = systemClaudeAccountID,
              currentID != lastKnownSystemClaude,
              let account = accounts.first(where: { $0.id == currentID }) else { return }
        // Nothing to compare a first sighting against. Record it rather than
        // announce a change nobody made, which is what a brand-new catalog and
        // an app that has just been given its first account both look like.
        let firstSighting = lastKnownSystemClaude == nil
        lastKnownSystemClaude = currentID
        guard !firstSighting, selected[.claude] != currentID else {
            try? persist(accounts: accounts, selected: selected)
            return
        }
        var updated = selected
        updated[.claude] = currentID
        do { try persist(accounts: accounts, selected: updated) } catch { return }
        selected = updated
        notice = String(format: NSLocalizedString("Claude now uses %@ on this Mac. That change was made outside Builder Nutch.", comment: "External login adopted"), account.label)
        resolvedAttention = AccountResolution(kind: .switched, accountID: currentID,
            title: String(format: NSLocalizedString("Claude now uses %@ (changed outside the app)", comment: "External login adopted"), account.label),
            resolvedAt: Date())
    }

    /// Preserve the outgoing subscription before replacing the shared login.
    /// A discovered default profile becomes a saved profile so its row never
    /// changes identity when the Mac moves to another subscription.
    private func saveSystemClaudeLogin(_ current: ManagedAccount, identity: ClaudeCredentialIdentity) async throws -> ManagedAccount {
        guard systemCredentials != nil else { throw ManagedAccountError.unavailable }
        if current.existingProfile?.usesDefaultClaudeHome == true {
            var saved = current
            saved.existingProfile = nil
            let destination = try usableStorage().profile(saved)
            try await copyClaudeLogin(from: systemClaudeLocation,
                to: ClaudeCredentialLocation(directory: destination, isDefault: false), identity: identity, allowExpired: true)
            var updated = accounts
            guard let index = updated.firstIndex(where: { $0.id == current.id }) else { throw ManagedAccountError.unavailable }
            updated[index] = saved
            try persist(accounts: updated, selected: selected)
            accounts = updated
            return saved
        }
        try await copyClaudeLogin(from: systemClaudeLocation, to: credentialLocation(for: current), identity: identity, allowExpired: true)
        return current
    }

    /// Switch credentials in place. No process is restarted, no transcript is
    /// copied and no Terminal window is created by an automatic rotation.
    /// Says, in one sentence, what made the app move the Mac's login. The window
    /// that ran out is named because it is usually not the one being watched: a
    /// weekly limit can be spent while today's five-hour usage looks fine.
    private func switchReason(_ cause: AccountSelection.SystemClaudeDecision.Cause,
                              from account: ManagedAccount) -> String {
        switch cause {
        case .spent(let remaining):
            let window = states[account.id]?.bindingWindow?.label
                ?? NSLocalizedString("usage limit", comment: "Generic limit name")
            return String(format: NSLocalizedString("%1$@ had %2$d%% left on its %3$@.", comment: "Switch reason"),
                          account.label, Int(remaining.rounded()), window)
        case .runningOut(let minutes):
            let headroom = UsageForecast.headroom(minutes: minutes) ?? ""
            return String(format: NSLocalizedString("%1$@ was about %2$@ from running out at its current pace.", comment: "Switch reason"),
                          account.label, headroom)
        case .preferredReturned:
            return String(format: NSLocalizedString("The account you chose is available again, so %1$@ handed back.", comment: "Switch reason"),
                          account.label)
        }
    }

    private func activateSystemClaude(_ target: ManagedAccount, automatic: Bool,
                                      cause: AccountSelection.SystemClaudeDecision.Cause? = nil) async throws {
        guard let credentials = systemCredentials, target.provider == .claude,
              !hasShutDown, !isSwitchingClaude, !busyIDs.contains(target.id), !authenticationInProgress else { throw ManagedAccountError.busy }
        updateSystemClaudeIdentity()
        guard let currentID = systemClaudeAccountID,
              let current = accounts.first(where: { $0.id == currentID }),
              !busyIDs.contains(currentID),
              let currentIdentity = try credentials.identity(at: systemClaudeLocation),
              let targetIdentity = try credentials.identity(at: credentialLocation(for: target))
        else { throw ManagedAccountError.notConnected }
        guard currentID != target.id else { return }
        isSwitchingClaude = true
        var switchedTo: ManagedAccount?
        defer {
            isSwitchingClaude = false; finish(current.id); finish(target.id)
            updateHealth()
            if let switchedTo {
                resolvedAttention = AccountResolution(kind: .switched, accountID: switchedTo.id,
                    title: String(format: NSLocalizedString("Switched to %@", comment: "Resolution"), switchedTo.label),
                    resolvedAt: Date())
            }
        }
        markBusy(current.id, cancellation: AccountCancellation())
        markBusy(target.id, cancellation: AccountCancellation())
        let saved = try await saveSystemClaudeLogin(current, identity: currentIdentity)
        try await copyClaudeLogin(from: credentialLocation(for: target), to: systemClaudeLocation, identity: targetIdentity)
        var updated = selected
        updated[.claude] = target.id
        do { try persist(accounts: accounts, selected: updated) }
        catch {
            // Restore the previous login if the catalog cannot record the change.
            try await copyClaudeLogin(from: credentialLocation(for: saved), to: systemClaudeLocation, identity: currentIdentity, allowExpired: true, completingTransaction: true)
            throw error
        }
        selected = updated
        systemClaudeAccountID = target.id
        // Record that this app made the change, so the next launch does not read
        // its own switch as someone signing in behind its back.
        lastKnownSystemClaude = target.id
        try? persist(accounts: accounts, selected: selected)
        guard !hasShutDown else { return }
        ClaudeCredentials.forgetCached()
        // The switch itself is the good news, whether the person asked for it or
        // the app did it for them. Recomputing attention here is what stops a red
        // banner outliving the problem it was describing, and the handoff is
        // announced after that so it wins over the generic "something improved".
        switchedTo = target
        let reason = cause.map { switchReason($0, from: current) } ?? ""
        notice = "Claude now uses \(target.label) on this Mac. Sessions using the Mac login pick up this account on their next request."
        if !reason.isEmpty { notice = reason + " " + (notice ?? "") }
        if automatic {
            automaticSwitch = AutomaticAccountSwitch(provider: .claude, fromID: current.id,
                fromName: current.label, toID: target.id, toName: target.label, reason: reason)
        }
    }

    private func copyClaudeLogin(from source: ClaudeCredentialLocation, to target: ClaudeCredentialLocation,
                                 identity: ClaudeCredentialIdentity, allowExpired: Bool = false, completingTransaction: Bool = false) async throws {
        guard !hasShutDown || completingTransaction, let credentials = systemCredentials else { throw ManagedAccountError.cancelled }
        try await Task.detached(priority: .utility) {
            try credentials.copyLogin(from: source, to: target, expectedIdentity: identity,
                allowExpired: allowExpired, completingTransaction: completingTransaction)
        }.value
    }

    private func reconcileSystemClaudeSelection() async {
        defer { updateHealth() }
        guard systemCredentials != nil, !systemSwitchPaused, !isSwitchingClaude, !hasShutDown else { return }
        updateSystemClaudeIdentity()
        guard automaticSelection, !authenticationInProgress,
              let currentID = systemClaudeAccountID,
              let decision = AccountSelection.systemClaudeDecision(accounts: accounts, states: states,
                order: rotationOrder[.claude] ?? [], currentID: currentID,
                preferredID: selected[.claude], thresholdPercent: switchThresholdPercent,
                forecasts: usageForecasts, switchAheadMinutes: switchAheadMinutes),
              !busyIDs.contains(currentID), !busyIDs.contains(decision.target.id) else { return }
        let candidate = decision.target
        do { try await activateSystemClaude(candidate, automatic: true, cause: decision.cause) }
        catch {
            guard !hasShutDown else { return }
            systemSwitchPaused = true
            notice = NSLocalizedString("Automatic Claude switching is paused. Use account to retry when ready.", comment: "") + " " + error.localizedDescription
        }
    }

    /// True while automatic switching has stopped and will not resume on its own.
    var isSystemSwitchPaused: Bool { systemSwitchPaused }

    /// Clears a pause and gives the switch another go. This is the Retry action
    /// behind the accounts banner; it never opens a browser or a Terminal.
    func retrySystemSwitch() async {
        guard !hasShutDown else { return }
        systemSwitchPaused = false
        notice = nil
        updateHealth()
        await refreshAll()
    }

    private func prepare(_ account: ManagedAccount) throws -> (URL, URL, [String: String]) {
        guard accounts.contains(where: { $0.id == account.id && $0.provider == account.provider }) else { throw ManagedAccountError.unavailable }
        guard !account.provider.isBrowserProfile else { throw ManagedAccountError.unavailable }
        guard let executable = resolveExecutable(account.provider) else { throw ManagedAccountError.missingCLI(account.provider) }
        let profile = try usableStorage().profile(account)
        if let source = account.existingProfile {
            return (executable, profile, source.environment(provider: account.provider, inherited: ProcessInfo.processInfo.environment))
        }
        if account.provider == .kimi { try AccountStorage.privateDirectory(profile.appendingPathComponent("home", isDirectory: true)) }
        if account.provider == .claude { try ClaudeAccountStatusLine.configure(profile: profile) }
        else if account.provider == .codex {
            let config = profile.appendingPathComponent("config.toml")
            try AccountStorage.rejectSymlink(config)
            if !FileManager.default.fileExists(atPath: config.path) {
                try AccountStorage.write(Data("cli_auth_credentials_store = \"keyring\"\n".utf8), to: config)
            }
        }
        return (executable, profile, AccountEnvironment.isolated(profile: profile, provider: account.provider))
    }

    private func markBusy(_ id: UUID, cancellation: AccountCancellation) {
        busyIDs.insert(id); operations[id] = cancellation
        var state = states[id] ?? ManagedAccountState(); state.isBusy = true; states[id] = state
    }

    private func finish(_ id: UUID) {
        busyIDs.remove(id); operations.removeValue(forKey: id)
        if var state = states[id] { state.isBusy = false; states[id] = state }
    }

    func connect(_ account: ManagedAccount) async {
        guard !hasShutDown else { return }
        if account.existingProfile != nil {
            await refresh(account)
            notice = "This account belongs to the official app. Reconnect there if needed, then refresh here."
            return
        }
        guard !authenticationInProgress, !busyIDs.contains(account.id) else { notice = ManagedAccountError.busy.localizedDescription; return }
        let cancellation = AccountCancellation()
        loginAccountID = account.id; markBusy(account.id, cancellation: cancellation)
        states[account.id]?.message = "Complete sign-in in your browser. Only this profile will be connected."
        defer { loginAccountID = nil; finish(account.id); updateHealth() }
        do {
            if account.isBrowserOnly {
                try await showBrowser(account, signingIn: true)
                states[account.id]?.message = "Finish signing in on the website, then choose ‘I’ve signed in’ here."
                notice = "\(account.provider.title) opened in its own browser profile."
                return
            }
            let (executable, profile, environment) = try prepare(account)
            await shareClaudeLogin(account)
            var args: [String]
            switch account.provider {
            case .claude: args = ["auth", "login", "--claudeai"]
            case .codex: args = ["--config", "cli_auth_credentials_store=\"keyring\"", "login"]
            case .kimi: args = ["login"]
            default: throw ManagedAccountError.unavailable
            }
            if account.provider == .claude, let hint = account.emailHint { args += ["--email", hint] }
            _ = try await runner.run(AccountCommand(executable: executable, arguments: args, environment: environment,
                                                    directory: profile, timeout: 180), cancellation: cancellation)
            if cancellation.isCancelled { throw ManagedAccountError.cancelled }
            let result = try await read(account, cancellation: cancellation)
            guard result.isConnected else { throw ManagedAccountError.notConnected }
            states[account.id] = result
            notice = "\(account.label) connected. Existing sessions keep their account."
        } catch {
            states[account.id]?.message = error.localizedDescription
            notice = error.localizedDescription
        }
    }

    func cancelLogin() {
        guard let id = loginAccountID else { return }
        operations[id]?.cancel()
        states[id]?.message = "Cancelling connection…"
    }

    /// A single user-requested authorization. No automatic path calls this.
    @discardableResult
    func allowClaudeAccess(_ account: ManagedAccount) async -> Bool {
        guard !hasShutDown, account.provider == .claude, let credentials = systemCredentials,
              !authenticationInProgress, !isSwitchingClaude, busyIDs.isEmpty else { return false }
        let location = systemClaudeAccountID == account.id ? systemClaudeLocation : credentialLocation(for: account)
        authorizationAccountID = account.id
        defer { authorizationAccountID = nil; updateHealth() }
        do {
            try await Task.detached(priority: .userInitiated) { try credentials.authorize(at: location) }.value
            guard !hasShutDown else { return false }
            await refresh(account)
            return states[account.id]?.requiresKeychainAccess != true
        } catch {
            pausedRefreshIDs.insert(account.id)
            states[account.id]?.requiresKeychainAccess = true
            states[account.id]?.message = error.localizedDescription
            return false
        }
    }

    func shutdown() {
        hasShutDown = true
        systemCredentials?.requestStop()
        operations.values.forEach { $0.cancel() }
        discoveryCancellation?.cancel()
    }

    /// Gives an already-committing switch time to persist its matching catalog,
    /// then returns — always. Waiting without a deadline is what made
    /// `osascript … quit` fail with "User canceled (-128)": the reply to
    /// `applicationShouldTerminate` was owed to macOS while this hung on a
    /// credential lock held by a blocked background thread. A credential
    /// transaction is worth a few seconds of patience, never a refusal to quit.
    func shutdownAndWait(within seconds: TimeInterval = 4) async {
        shutdown()
        let deadline = Date().addingTimeInterval(max(seconds, 0.5))
        while isSwitchingClaude && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard let credentials = systemCredentials else { return }
        // Detached and polled rather than awaited: under a starved thread pool an
        // awaited detached task may never even start, and quitting would hang.
        let idle = ShutdownSignal()
        Task.detached(priority: .userInitiated) {
            credentials.waitUntilIdle(timeout: max(0.5, deadline.timeIntervalSinceNow))
            idle.signal()
        }
        while !idle.isSignalled && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func read(_ account: ManagedAccount, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        guard !hasShutDown else { throw ManagedAccountError.cancelled }
        // Cursor's editor owns its login, so this row is a reading and nothing
        // else: no executable to resolve, no profile to prepare, no environment.
        if account.readsDesktopUsage, let source = account.existingProfile {
            return try await readCursor(try source.validatedDirectory(), cancellation)
        }
        if account.isBrowserOnly {
            guard let current = accounts.first(where: { $0.id == account.id }) else { throw ManagedAccountError.unavailable }
            return Self.browserState(current)
        }
        if account.provider == .claude, let claudeReader {
            let location = systemClaudeAccountID == account.id ? systemClaudeLocation : credentialLocation(for: account)
            return try await claudeReader.read(location, cancellation: cancellation)
        }
        let (executable, profile, environment): (URL, URL, [String: String])
        if account.provider == .claude, systemCredentials != nil, systemClaudeAccountID == account.id {
            guard let command = resolveExecutable(.claude) else { throw ManagedAccountError.missingCLI(.claude) }
            let source = ExistingAccountProfile(directory: systemClaudeLocation.directory.path, usesDefaultClaudeHome: true)
            executable = command; profile = try source.validatedDirectory()
            environment = source.environment(provider: .claude, inherited: ProcessInfo.processInfo.environment)
        } else {
            (executable, profile, environment) = try prepare(account)
        }
        if account.provider == .kimi {
            let state = account.existingProfile != nil
                ? try await readExistingKimi(executable, profile, environment, cancellation)
                : try await readKimi(executable, profile, environment, cancellation)
            return Self.stampKimiIdentity(state, profile: profile)
        }
        let codex = account.provider == .codex
        let arguments = codex ? (account.existingProfile == nil ? ["--config", "cli_auth_credentials_store=\"keyring\"", "app-server"] : ["app-server"]) : ["auth", "status", "--json"]
        let data = try await runner.run(AccountCommand(executable: executable, arguments: arguments, environment: environment,
                                                       directory: profile, readsCodexAccount: codex), cancellation: cancellation)
        if cancellation.isCancelled { throw ManagedAccountError.cancelled }
        if codex { return try AccountQuotas.codex(data) }
        return try await readClaudeUsage(status: data, executable: executable, profile: profile, environment: environment, cancellation: cancellation)
    }

    private func readClaudeUsage(status: Data, executable: URL, profile: URL, environment: [String: String], cancellation: AccountCancellation) async throws -> ManagedAccountState {
        let quotaURL = profile.appendingPathComponent("quota.json")
        try AccountStorage.rejectSymlink(quotaURL)
        var fallback = try AccountQuotas.claude(status: status, quota: try? Data(contentsOf: quotaURL))
        guard fallback.isConnected else { return fallback }
        if fallback.windows.isEmpty { fallback.message = ClaudeAccountUsage.unavailable }
        do {
            let usage = try await runner.run(ClaudeAccountUsage.command(executable: executable, profile: profile, environment: environment), cancellation: cancellation)
            let live = try ClaudeAccountUsage.state(status: fallback, usage: usage)
            if !live.windows.isEmpty { return live }
        } catch {
            if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
            // Older CLIs may not implement this experimental read-only control.
            // Keep their last status-line reading visible, but a failed live check
            // cannot authorize automatic selection.
        }
        fallback.refreshedAt = nil
        fallback.message = ClaudeAccountUsage.unavailable
        return fallback
    }

    func refresh(_ account: ManagedAccount) async {
        guard !hasShutDown, !busyIDs.contains(account.id),
              loginAccountID == nil || loginAccountID == account.id,
              authorizationAccountID == nil || authorizationAccountID == account.id else { return }
        let cancellation = AccountCancellation(); markBusy(account.id, cancellation: cancellation)
        defer { finish(account.id); updateHealth() }
        do {
            states[account.id] = try await read(account, cancellation: cancellation)
            guard !hasShutDown, !cancellation.isCancelled else { return }
            if states[account.id]?.isFresh() == true || account.isBrowserOnly {
                externalRetryAfter.removeValue(forKey: account.id)
                pausedRefreshIDs.remove(account.id)
            } else { pausedRefreshIDs.insert(account.id) }
            recordUsage(for: account)
        }
        catch {
            guard !hasShutDown, !cancellation.isCancelled else { return }
            var state = states[account.id] ?? ManagedAccountState()
            state.message = error.localizedDescription
            // Retain the last displayed quotas, but never use a failed refresh for automation.
            state.refreshedAt = nil
            state.requiresKeychainAccess = (error as? ClaudeSystemCredentialError)?.requiresAccess == true
            // A revoked or expired saved login is not a transient failure. Say so
            // now, so the person signs in before a rotation needs this account.
            state.requiresSignIn = lostItsSignIn(account, error: error)
            if account.provider == .claude, claudeReader != nil, !state.requiresKeychainAccess {
                externalRetryAfter[account.id] = Date().addingTimeInterval(60)
            } else { pausedRefreshIDs.insert(account.id) }
            if account.existingProfile != nil {
                state.isConnected = false
                externalRetryAfter[account.id] = Date().addingTimeInterval(900)
            }
            states[account.id] = state
        }
    }

    func refreshAll() async {
        guard !hasShutDown, !authenticationInProgress else { return }
        recoverClaudeCacheMarkers()
        updateSystemClaudeIdentity()
        auditQueueIfDue()
        await refreshAccounts(accounts.filter { !pausedRefreshIDs.contains($0.id) && externalRetryAfter[$0.id].map { $0 > Date() } != true })
        guard !hasShutDown, !Task.isCancelled else { return }
        if automaticDiscovery { await discoverExistingAccounts() }
        mergeDuplicateAccounts()
        reconcileAutomaticSelection()
        await reconcileSystemClaudeSelection()
    }

    /// Rechecks the whole rotation queue, not just the account in use. Yesterday's
    /// failure mode was a queued account whose login had been revoked weeks
    /// earlier: it was only discovered at the moment of the switch, when it was
    /// too late to do anything about it. Runs once at launch and every 30 minutes.
    /// Accounts waiting for the person's Keychain permission are left alone —
    /// retrying those would be a prompt they did not ask for.
    private func auditQueueIfDue(now: Date = Date()) {
        guard lastQueueAudit.map({ now.timeIntervalSince($0) >= Self.queueAuditInterval }) ?? true else { return }
        lastQueueAudit = now
        // Cursor never rotates, but it does go quiet when the editor is signed
        // out, and it has to be able to come back on its own once it is not.
        for account in accounts where account.provider.supportsAutomaticSelection || account.readsDesktopUsage {
            guard states[account.id]?.requiresKeychainAccess != true else { continue }
            pausedRefreshIDs.remove(account.id)
            externalRetryAfter.removeValue(forKey: account.id)
        }
    }

    /// Keeps a short burn-rate history for the window closest to running out.
    private func recordUsage(for account: ManagedAccount, now: Date = Date()) {
        guard account.provider.supportsAutomaticSelection, let state = states[account.id],
              state.isConnected, state.isFresh(at: now),
              let used = state.windows.compactMap(\.usedFraction).max() else { return }
        var forecast = usageForecasts[account.id] ?? UsageForecast()
        forecast.record(usedFraction: used, at: state.refreshedAt ?? now)
        usageForecasts[account.id] = forecast
    }

    /// Failed probes are quiet and bounded; manual refresh of an existing row can retry immediately.
    func discoverExistingAccounts(candidates: [ExistingAccountCandidate]? = nil, now: Date = Date()) async {
        guard !hasShutDown, !authenticationInProgress, !discovering, catalogError == nil else { return }
        discovering = true
        defer { discovering = false }
        pruneSignedOutExistingProfiles()
        var found = 0
        for candidate in candidates ?? ExistingAccountDiscovery.candidates() {
            guard !hasShutDown, !Task.isCancelled else { break }
            let key = candidate.source.key(provider: candidate.provider)
            guard !candidate.provider.isBrowserProfile || candidate.provider.readsDesktopUsage,
                  !ignoredExistingProfiles.contains(key),
                  !accounts.contains(where: { configurationDirectory(for: $0).standardizedFileURL.path == candidate.source.directory }),
                  storage.map({ !candidate.source.directory.hasPrefix($0.root.path + "/") }) ?? false,
                  !accounts.contains(where: { $0.existingProfile?.key(provider: $0.provider) == key }),
                  discoveryAttempts[key].map({ now.timeIntervalSince($0) >= 900 }) ?? true,
                  let directory = try? candidate.source.validatedDirectory() else { continue }
            // Cursor is read straight from the editor's own store; every other
            // provider still needs its official command-line app present.
            guard candidate.provider.readsDesktopUsage || resolveExecutable(candidate.provider) != nil else { continue }
            discoveryAttempts[key] = now
            let environment = candidate.source.environment(provider: candidate.provider, inherited: ProcessInfo.processInfo.environment)
            let cancellation = AccountCancellation()
            discoveryCancellation = cancellation
            do {
                let state: ManagedAccountState
                if candidate.provider == .claude, let claudeReader {
                    let location = ClaudeCredentialLocation(directory: directory, isDefault: candidate.source.usesDefaultClaudeHome)
                    do { state = try await claudeReader.read(location, cancellation: cancellation) }
                    catch let error as ClaudeSystemCredentialError where error.requiresAccess {
                        guard let identity = try systemCredentials?.identity(at: location) else { continue }
                        state = ManagedAccountState(email: identity.email, message: error.localizedDescription, requiresKeychainAccess: true)
                    }
                } else if candidate.provider.readsDesktopUsage {
                    state = try await readCursor(directory, cancellation)
                } else if candidate.provider == .kimi {
                    guard let executable = resolveExecutable(candidate.provider) else { continue }
                    state = Self.stampKimiIdentity(try await readExistingKimi(executable, directory, environment, cancellation), profile: directory)
                } else {
                    guard let executable = resolveExecutable(candidate.provider) else { continue }
                    let codex = candidate.provider == .codex
                    let data = try await runner.run(AccountCommand(executable: executable,
                        arguments: codex ? ["app-server"] : ["auth", "status", "--json"],
                        environment: environment, directory: directory, readsCodexAccount: codex), cancellation: cancellation)
                    if !codex {
                        let status = try AccountQuotas.json(data)
                        if let method = status["authMethod"] as? String, method != "claude.ai" { continue }
                    }
                    if codex { state = try AccountQuotas.codex(data) }
                    else { state = try await readClaudeUsage(status: data, executable: executable, profile: directory, environment: environment, cancellation: cancellation) }
                }
                guard !hasShutDown, !Task.isCancelled, !cancellation.isCancelled,
                      state.isConnected || state.requiresKeychainAccess else { continue }
                // Only verified identities count. User-entered hints never suppress a real account.
                // The address is the readable signal; the opaque fingerprint covers
                // vendors that publish no address at all, which is how one Kimi
                // subscription came to occupy two rows. An unverifiable identity
                // falls through and the row is added: hiding a real subscription
                // is the worse mistake.
                let alreadyListed = accounts.contains { existing in
                    guard existing.provider == candidate.provider, states[existing.id]?.isConnected == true else { return false }
                    if let email = state.email?.lowercased(), !email.isEmpty,
                       states[existing.id]?.email?.lowercased() == email { return true }
                    if let identity = state.identity, !identity.isEmpty,
                       states[existing.id]?.identity == identity { return true }
                    return false
                }
                if alreadyListed { continue }
                let account = ManagedAccount(id: UUID(), provider: candidate.provider,
                    label: try AccountStorage.validLabel(candidate.label), createdAt: now, existingProfile: candidate.source)
                var selection = selected
                if selection[account.provider] == nil { selection[account.provider] = account.id }
                try persist(accounts: accounts + [account], selected: selection)
                accounts.append(account); selected = selection; states[account.id] = state
                if state.requiresKeychainAccess { pausedRefreshIDs.insert(account.id) }
                found += 1
            } catch { continue }
        }
        if found > 0 { discoveryNotice = "Found \(found) signed-in account\(found == 1 ? "" : "s") on this Mac. Their original app keeps each sign-in and configuration." }
    }

    // MARK: - Duplicate rows

    /// Kimi has no address and no userinfo route, so the subscription behind a
    /// profile is only knowable from the account claim in its own saved token.
    static func stampKimiIdentity(_ state: ManagedAccountState, profile: URL) -> ManagedAccountState {
        guard state.isConnected, state.identity == nil else { return state }
        var stamped = state
        stamped.identity = ExistingAccountProfile(directory: profile.standardizedFileURL.path, usesDefaultClaudeHome: false)
            .kimiSubscriptionFingerprint()
        return stamped
    }

    /// What identifies the subscription behind a row, when the vendor told us.
    /// A nickname or a typed email hint never counts: only something the
    /// provider itself confirmed can merge two rows into one.
    private func identityKey(for account: ManagedAccount) -> String? {
        if account.provider == .claude, let credentials = systemCredentials {
            let location = systemClaudeAccountID == account.id ? systemClaudeLocation : credentialLocation(for: account)
            if let identity = try? credentials.identity(at: location) {
                return "claude:\(identity.accountID):\(identity.organizationID)"
            }
        }
        if let identity = states[account.id]?.identity, !identity.isEmpty {
            return "\(account.provider.rawValue):\(identity)"
        }
        guard let email = states[account.id]?.email?.lowercased(), !email.isEmpty else { return nil }
        return "\(account.provider.rawValue):\(email)"
    }

    /// True for one of this app's own profiles that has never held a sign-in:
    /// no credential file, no identity, and not connected now. Only the app's
    /// own directory is examined, and nothing inside it is ever deleted.
    private func isEmptyIsolatedProfile(_ account: ManagedAccount) -> Bool {
        guard account.existingProfile == nil, !account.provider.isBrowserProfile,
              let state = states[account.id], !state.isConnected, !state.isBusy,
              state.email == nil, state.windows.isEmpty, !state.requiresKeychainAccess else { return false }
        let directory = configurationDirectory(for: account)
        switch account.provider {
        case .kimi:
            return ExistingAccountProfile(directory: directory.path, usesDefaultClaudeHome: false)
                .kimiAuthenticationStatus() != .present
        case .claude:
            guard let credentials = systemCredentials else { return false }
            let location = ClaudeCredentialLocation(directory: directory, isDefault: false)
            return (try? credentials.identity(at: location)) == nil
        case .codex:
            return !FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path)
        default:
            return false
        }
    }

    /// Which of two rows for the same subscription the person should keep.
    private func survivor(_ left: ManagedAccount, _ right: ManagedAccount) -> ManagedAccount {
        func rank(_ account: ManagedAccount) -> (Int, Int, Int) {
            // The account this Mac is actually running can never be the one removed.
            (account.id == systemClaudeAccountID ? 1 : 0,
             states[account.id]?.isConnected == true ? 1 : 0,
             // The vendor's own profile outlives a copy this app made.
             account.existingProfile != nil ? 1 : 0)
        }
        if rank(left) != rank(right) { return rank(left) > rank(right) ? left : right }
        return left.createdAt <= right.createdAt ? left : right
    }

    /// One subscription shown twice is the same bug either way round: a profile
    /// this app created and the vendor profile it later found are the same
    /// account. Removing a row never touches the vendor's files or its sign-in.
    @discardableResult
    func mergeDuplicateAccounts() -> [ManagedAccount] {
        guard loaded, catalogError == nil, busyIDs.isEmpty, !authenticationInProgress, !isSwitchingClaude else { return [] }
        var survivors = accounts
        var dropped: [ManagedAccount] = []

        // (a) Two rows the provider itself says are the same subscription.
        var byIdentity: [String: ManagedAccount] = [:]
        for account in accounts where !account.provider.isBrowserProfile {
            guard let key = identityKey(for: account) else { continue }
            guard let rival = byIdentity[key] else { byIdentity[key] = account; continue }
            let keep = survivor(rival, account)
            let drop = keep.id == rival.id ? account : rival
            byIdentity[key] = keep
            survivors.removeAll { $0.id == drop.id }
            dropped.append(drop)
        }

        // (b) An empty profile of ours sitting next to the real, connected one.
        for account in survivors where account.existingProfile == nil {
            guard isEmptyIsolatedProfile(account),
                  survivors.contains(where: { $0.id != account.id && $0.provider == account.provider
                      && $0.existingProfile != nil && states[$0.id]?.isConnected == true }) else { continue }
            survivors.removeAll { $0.id == account.id }
            dropped.append(account)
        }

        guard !dropped.isEmpty else { return [] }
        var selection = selected
        for account in dropped where selection[account.provider] == account.id {
            selection[account.provider] = survivors.first { $0.provider == account.provider }?.id
        }
        // A discovered row that loses must not come straight back on the next sweep.
        let previousIgnored = ignoredExistingProfiles
        for account in dropped {
            if let source = account.existingProfile { ignoredExistingProfiles.insert(source.key(provider: account.provider)) }
        }
        do { try persist(accounts: survivors, selected: selection) }
        catch { ignoredExistingProfiles = previousIgnored; return [] }
        accounts = survivors
        selected = selection
        for account in dropped {
            states.removeValue(forKey: account.id)
            usageForecasts.removeValue(forKey: account.id)
            externalRetryAfter.removeValue(forKey: account.id)
            pausedRefreshIDs.remove(account.id)
            browserOpenedIDs.remove(account.id)
        }
        normalizeRotationOrder()
        try? persist(accounts: accounts, selected: selected)
        let names = dropped.map { $0.label }.joined(separator: ", ")
        notice = String(format: NSLocalizedString("Merged duplicate rows for the same subscription: %@. Its sign-in and files were left untouched.", comment: "Duplicate merge notice"), names)
        updateHealth()
        return dropped
    }

    /// A discovered row whose vendor app has since been signed out.
    ///
    /// Kimi leaves its profile directory behind after logout, and older builds
    /// could save that empty shell as an account. Cursor is the same shape: the
    /// editor keeps its state store and simply drops the token. Either way the
    /// row can never say anything again, so it goes — without ignoring the path,
    /// so a later real sign-in is discovered normally.
    private func pruneSignedOutExistingProfiles() {
        let stale = Set(accounts.compactMap { account -> UUID? in
            guard let source = account.existingProfile else { return nil }
            if account.provider == .kimi, source.kimiAuthenticationStatus() == .signedOut { return account.id }
            if account.readsDesktopUsage,
               !CursorAccountIntegration.isSignedIn(directory: URL(fileURLWithPath: source.directory, isDirectory: true)) {
                return account.id
            }
            return nil
        })
        guard !stale.isEmpty else { return }
        let updatedAccounts = accounts.filter { !stale.contains($0.id) }
        var updatedSelected = selected
        for (provider, id) in selected where stale.contains(id) {
            updatedSelected[provider] = updatedAccounts.first { $0.provider == provider }?.id
        }
        let previousOrder = rotationOrder
        var updatedOrder = rotationOrder
        for provider in updatedOrder.keys {
            updatedOrder[provider] = (updatedOrder[provider] ?? []).filter { !stale.contains($0) }
        }
        rotationOrder = updatedOrder
        do { try persist(accounts: updatedAccounts, selected: updatedSelected) }
        catch { rotationOrder = previousOrder; notice = error.localizedDescription; return }
        accounts = updatedAccounts
        selected = updatedSelected
        for id in stale { states.removeValue(forKey: id); externalRetryAfter.removeValue(forKey: id) }
    }

    private func refreshAccounts(_ snapshot: [ManagedAccount]) async {
        for start in stride(from: 0, to: snapshot.count, by: 2) {
            guard !hasShutDown, !Task.isCancelled else { return }
            async let first: Void = refresh(snapshot[start])
            if start + 1 < snapshot.count { async let second: Void = refresh(snapshot[start + 1]); _ = await (first, second) }
            else { await first }
        }
    }

    func launch(_ account: ManagedAccount, project: URL) async {
        guard !hasShutDown, !authenticationInProgress else { return }
        defer { updateHealth() }
        do {
            if account.provider == .claude, systemCredentials != nil {
                updateSystemClaudeIdentity()
                await refresh(account)
                guard state(for: account).isConnected else { throw ManagedAccountError.notConnected }
                try await activateSystemClaude(account, automatic: false)
                systemSwitchPaused = false
                return
            }
            if account.readsDesktopUsage {
                await refresh(account)
                notice = "The Cursor app keeps this sign-in. Open Cursor to use it — Builder Nutch only reads its usage."
                return
            }
            if account.isBrowserOnly {
                try await showBrowser(account)
                try select(account)
                notice = "Opened \(account.label). Your other browser accounts stay separate."
                return
            }
            var directory: ObjCBool = false
            guard project.isFileURL, FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileReadNoSuchFile) }
            var chosen = account
            if automaticSelection {
                await refreshAccounts(accounts.filter { $0.provider == account.provider })
                reconcileAutomaticSelection(provider: account.provider)
                guard let candidate = selectedAccount(for: account.provider) else { throw ManagedAccountError.unavailable }
                chosen = candidate
            } else { await refresh(chosen) }
            guard !busyIDs.contains(chosen.id), state(for: chosen).isConnected else { throw ManagedAccountError.notConnected }
            await shareClaudeLogin(chosen)
            let (executable, profile, _) = try prepare(chosen)
            let scripts = try usableStorage().root.appendingPathComponent("launchers", isDirectory: true)
            try AccountStorage.privateDirectory(scripts)
            let script = scripts.appendingPathComponent("\(UUID().uuidString).command")
            let text = AccountEnvironment.launchScript(executable: executable, account: chosen, profile: profile, project: project)
            try AccountStorage.write(Data(text.utf8), to: script, mode: 0o700)
            guard openTerminal(script) else { throw CocoaError(.executableLoad) }
            try select(chosen)
            notice = "Opened \(chosen.label) in Terminal. Existing sessions keep their account."
        } catch { notice = error.localizedDescription }
    }

    /// Which window the ring means. Declared per provider rather than left to
    /// position, so a window dropping out of a response blanks the cell instead
    /// of quietly promoting a different one into the headline's place.
    static func headlineID(for account: ManagedAccount) -> String {
        if account.provider == .claude { return "five_hour" }
        // Cursor's dashboard leads with "Your included usage · N% used", and so
        // does this. `CursorUsage` names that window "included".
        if account.readsDesktopUsage { return "included" }
        return "primary"
    }

    func snapshot(for account: ManagedAccount) -> ProviderSnapshot {
        let provider = account.provider
        let state = state(for: account)
        let status: ProviderStatus
        if !state.isConnected { status = .needsAuth }
        else if account.isBrowserOnly { status = .unsupported("Open \(provider.title) to see usage. Browser sign-in is kept by the website.") }
        else if !state.windows.isEmpty && !state.isFresh() { status = .stale(since: state.refreshedAt ?? .distantPast) }
        else if let message = state.message { status = .unsupported(message) }
        else { status = .ok }
        let exhausted = state.windows.first { ($0.usedFraction ?? 0) >= 1 }
        let email = UserDefaults.standard.bool(forKey: "accounts.hidePersonalDetails")
            ? nil : (state.email ?? account.emailHint)
        return ProviderSnapshot(id: account.id.uuidString, displayName: account.emoji.map { "\($0) \(account.label)" } ?? account.label,
                                accountEmail: email,
                                glyph: provider.glyph, fidelity: account.isBrowserOnly ? .manual : .official,
                                status: status, windows: state.windows,
                                headlineID: Self.headlineID(for: account),
                                block: exhausted.map { UsageBlock(reason: "\($0.label) reached", resetsAt: $0.resetsAt) })
    }

    var snapshots: [ProviderSnapshot] {
        AccountProvider.allCases.compactMap { provider in
            selectedAccount(for: provider).map(snapshot(for:))
        }
    }

    private func normalizeRotationOrder() {
        for provider in AccountProvider.allCases where provider.supportsAutomaticSelection {
            let valid = accounts.filter { $0.provider == provider }.map(\.id)
            let retained = (rotationOrder[provider] ?? []).filter { valid.contains($0) }
            rotationOrder[provider] = retained + valid.filter { !retained.contains($0) }
        }
    }

    func reconcileAutomaticSelection(provider: AccountProvider? = nil) {
        guard automaticSelection else { return }
        normalizeRotationOrder()
        let providers = provider.map { [$0] } ?? AccountProvider.allCases.filter(\.supportsAutomaticSelection)
        var changed = false
        var switches: [AutomaticAccountSwitch] = []
        for provider in providers {
            // Claude's selection only becomes a switch after the system login
            // was actually updated. Other providers keep their existing flow.
            if provider == .claude && systemCredentials != nil { continue }
            guard let candidate = AccountSelection.rotating(provider: provider, accounts: accounts, states: states,
                order: rotationOrder[provider] ?? [], currentID: selected[provider],
                thresholdPercent: switchThresholdPercent) else { continue }
            if selected[provider] != candidate.id {
                if let previousID = selected[provider],
                   let previous = accounts.first(where: { $0.id == previousID }) {
                    switches.append(AutomaticAccountSwitch(
                        provider: provider,
                        fromID: previousID,
                        fromName: previous.label,
                        toID: candidate.id,
                        toName: candidate.label
                    ))
                }
                selected[provider] = candidate.id
                changed = true
            }
        }
        if changed, loaded { try? persist(accounts: accounts, selected: selected) }
        switches.forEach { automaticSwitch = $0 }
        updateHealth()
    }

    // MARK: - Health

    /// Recomputes `attention` and `health` together. Called after everything that
    /// can change the answer, so the app never silently keeps a stale one.
    func updateHealth(now: Date = Date()) {
        health = computeHealth(now: now)
        let next = computeAttention(now: now)
        // Keep the original timestamp while the same problem persists: the notch
        // escalates on age, and a recomputation is not a new incident.
        guard next?.id != attention?.id else { return }
        if let previous = attention, let resolution = resolution(for: previous, now: now) {
            resolvedAttention = resolution
        }
        attention = next
    }

    /// Whether the problem behind `previous` was actually solved. An account that
    /// was removed did not get fixed, and saying so would be a lie the person
    /// would notice; that case deliberately returns nil.
    private func resolution(for previous: AccountAttention, now: Date) -> AccountResolution? {
        let account = previous.accountID.flatMap { id in accounts.first { $0.id == id } }
        if previous.accountID != nil && account == nil { return nil }
        let name = account.map(label)
        switch previous.kind {
        case .keychainAccess:
            guard let account, states[account.id]?.requiresKeychainAccess != true else { return nil }
            return AccountResolution(kind: .accessAllowed, accountID: account.id,
                title: String(format: NSLocalizedString("Access allowed for %@", comment: "Resolution"), name ?? ""),
                resolvedAt: now)
        case .reconnect:
            guard let account, !needsSignIn(account) else { return nil }
            return AccountResolution(kind: .reconnected, accountID: account.id,
                title: String(format: NSLocalizedString("%@ is signed in again", comment: "Resolution"), name ?? ""),
                resolvedAt: now)
        case .switchPaused:
            guard !systemSwitchPaused else { return nil }
            return AccountResolution(kind: .switchResumed, accountID: previous.accountID,
                title: NSLocalizedString("Automatic switching resumed", comment: "Resolution"), resolvedAt: now)
        case .queueEmpty:
            guard let current = claudeQueue().first, !claudeCandidateIsBusy(excluding: current.id),
                  AccountSelection.rotating(provider: .claude, accounts: accounts, states: states,
                    order: rotationOrder[.claude] ?? [], currentID: current.id,
                    thresholdPercent: switchThresholdPercent, keepCurrent: false, now: now) != nil else { return nil }
            return AccountResolution(kind: .switchResumed, accountID: current.id,
                title: NSLocalizedString("An account is available again", comment: "Resolution"), resolvedAt: now)
        }
    }

    private func label(_ account: ManagedAccount) -> String {
        account.emoji.map { "\($0) \(account.label)" } ?? account.label
    }

    /// A profile that carries an identity has been signed in at least once. That
    /// is the only thing that separates "you never set this up" from "your
    /// sign-in is gone": the account name survives in the profile long after the
    /// credential behind it stops working.
    private func hasSavedIdentity(_ account: ManagedAccount) -> Bool {
        guard account.provider == .claude, let credentials = systemCredentials else { return false }
        let location = systemClaudeAccountID == account.id ? systemClaudeLocation : credentialLocation(for: account)
        return ((try? credentials.identity(at: location)) ?? nil) != nil
    }

    /// Whether this failure means the person has to sign in again.
    ///
    /// Expired or revoked says so outright. Missing or unreadable is the harder
    /// case: it is a lost sign-in on a profile that has an identity, and merely
    /// an empty profile on one that does not. Reading the second as a fault is
    /// what kept a dormant account red; reading the first as empty is what let a
    /// revoked account sit silent until a rotation needed it.
    private func lostItsSignIn(_ account: ManagedAccount, error: Error) -> Bool {
        guard let failure = error as? ClaudeSystemCredentialError, !failure.requiresAccess else { return false }
        switch failure {
        case .expiredLogin: return true
        case .missingLogin, .malformedData, .fallbackCredentials: return hasSavedIdentity(account)
        default: return false
        }
    }

    /// True while another Claude account is mid-refresh. A reading in flight is
    /// not an empty queue: without this, an ordinary refresh flashed "no account
    /// left to switch to" and then announced its own recovery a second later.
    private func claudeCandidateIsBusy(excluding currentID: UUID) -> Bool {
        accounts.contains { $0.provider == .claude && $0.id != currentID && states[$0.id]?.isBusy == true }
    }

    private func needsSignIn(_ account: ManagedAccount) -> Bool {
        guard let state = states[account.id], !account.isBrowserOnly else { return false }
        return state.requiresSignIn || (!state.isConnected && !state.isBusy)
    }

    private func claudeQueue() -> [ManagedAccount] {
        let ordered = rotationAccounts(for: .claude)
        guard !ordered.isEmpty else { return [] }
        return AccountActivitySelection.queue(accounts: ordered,
            currentID: systemClaudeAccountID ?? selected[.claude], selectedID: selected[.claude])
    }

    private func computeAttention(now: Date) -> AccountAttention? {
        let queue = claudeQueue()
        let current = queue.first
        let next = queue.count > 1 ? queue[1] : nil
        // Ordered by what actually stops the Mac from working, not by severity in
        // the abstract: a blocked Keychain stops everything, a paused switch stops
        // rotation, a dead queue entry stops the *next* switch.
        let blocked = [current, next].compactMap { $0 }
            + accounts.filter { $0.provider == .claude }
        if let account = blocked.first(where: { states[$0.id]?.requiresKeychainAccess == true }) {
            return AccountAttention(kind: .keychainAccess, accountID: account.id,
                title: String(format: NSLocalizedString("macOS is blocking %@", comment: "Attention title"), label(account)),
                detail: NSLocalizedString("Builder Nutch cannot read this saved login, so it cannot switch to it. Allow access once and switching resumes.", comment: "Attention detail"),
                raisedAt: now)
        }
        if systemSwitchPaused, automaticSelection {
            return AccountAttention(kind: .switchPaused, accountID: current?.id,
                title: NSLocalizedString("Automatic switching is paused", comment: "Attention title"),
                detail: NSLocalizedString("The last account change did not finish, so Builder Nutch stopped instead of retrying in a loop. Retry when you are ready.", comment: "Attention detail"),
                raisedAt: now)
        }
        if let next, needsSignIn(next) {
            return AccountAttention(kind: .reconnect, accountID: next.id,
                title: String(format: NSLocalizedString("%@ needs a new sign-in", comment: "Attention title"), label(next)),
                detail: NSLocalizedString("This is the next account in your queue. Its saved sign-in expired, so the switch would fail. Sign in now and it will be ready.", comment: "Attention detail"),
                raisedAt: now)
        }
        // Only a login that *lost* its sign-in is an incident. An account that
        // has simply never been connected is a setup task the person can do when
        // they like, and treating it as a fault pinned the banner red for good:
        // one dormant row meant nothing they did to the running account could
        // ever clear it.
        if let stale = accounts.first(where: { $0.provider.supportsAutomaticSelection && states[$0.id]?.requiresSignIn == true }) {
            return AccountAttention(kind: .reconnect, accountID: stale.id,
                title: String(format: NSLocalizedString("%@ needs a new sign-in", comment: "Attention title"), label(stale)),
                detail: NSLocalizedString("Its saved sign-in expired. Sign in again to put this account back in the rotation.", comment: "Attention detail"),
                raisedAt: now)
        }
        if automaticSelection, systemCredentials != nil, let current,
           !claudeCandidateIsBusy(excluding: current.id),
           AccountSelection.rotating(provider: .claude, accounts: accounts, states: states,
                order: rotationOrder[.claude] ?? [], currentID: current.id,
                thresholdPercent: switchThresholdPercent, keepCurrent: false, now: now) == nil {
            return AccountAttention(kind: .queueEmpty, accountID: current.id,
                title: NSLocalizedString("No account left to switch to", comment: "Attention title"),
                detail: String(format: NSLocalizedString("When %@ runs out there is nothing to move to. Add another subscription to keep working.", comment: "Attention detail"), label(current)),
                raisedAt: now)
        }
        return nil
    }

    private func computeHealth(now: Date) -> AccountHealth {
        var health = AccountHealth()
        let queue = claudeQueue()
        guard let current = queue.first else {
            health.reason = NSLocalizedString("Add a Claude account to switch between subscriptions.", comment: "Health reason")
            return health
        }
        let next = queue.count > 1 ? queue[1] : nil
        health.currentID = current.id
        health.currentName = label(current)
        health.currentRemainingPercent = states[current.id]?.remainingPercent
        health.currentMinutesRemaining = usageForecasts[current.id]?.minutesUntilExhausted(at: now)
        health.nextID = next?.id
        health.nextName = next.map(label)
        health.nextRemainingPercent = next.flatMap { states[$0.id]?.remainingPercent }
        health.nextMinutesRemaining = next.flatMap { usageForecasts[$0.id]?.minutesUntilExhausted(at: now) }
        let ready = AccountSelection.rotating(provider: .claude, accounts: accounts, states: states,
            order: rotationOrder[.claude] ?? [], currentID: current.id,
            thresholdPercent: switchThresholdPercent, keepCurrent: false, now: now)
        if systemCredentials == nil {
            health.reason = NSLocalizedString("Switching is unavailable in this build.", comment: "Health reason")
        } else if !automaticSelection {
            health.reason = NSLocalizedString("Automatic switching is off.", comment: "Health reason")
        } else if systemSwitchPaused {
            health.reason = NSLocalizedString("Automatic switching is paused.", comment: "Health reason")
        } else if let next, states[next.id]?.requiresKeychainAccess == true {
            health.reason = String(format: NSLocalizedString("%@ is waiting for your permission.", comment: "Health reason"), label(next))
        } else if let next, needsSignIn(next) {
            health.reason = String(format: NSLocalizedString("%@ needs a new sign-in.", comment: "Health reason"), label(next))
        } else if ready == nil, !claudeCandidateIsBusy(excluding: current.id) {
            health.reason = NSLocalizedString("No other account has usage left.", comment: "Health reason")
        } else if ready == nil {
            health.reason = NSLocalizedString("Checking the other accounts…", comment: "Health reason")
        } else {
            health.isSwitchReady = true
        }
        return health
    }

    /// One line for the accounts window: state, the account in use, and what is
    /// queued behind it with how long it should last.
    var healthSummary: String {
        guard let current = health.currentName else {
            return health.reason ?? NSLocalizedString("Add a Claude account to switch between subscriptions.", comment: "Health reason")
        }
        var parts = [health.isSwitchReady
            ? NSLocalizedString("Switch ready", comment: "Health status")
            : (health.reason ?? NSLocalizedString("Switching unavailable", comment: "Health status"))]
        parts.append(String(format: NSLocalizedString("%@ now", comment: "Account in use"), current))
        if let next = health.nextName {
            let headroom = health.nextMinutesRemaining.flatMap(UsageForecast.headroom(minutes:))
                ?? health.nextRemainingPercent.map { String(format: NSLocalizedString("%d%% left", comment: "Remaining quota"), Int($0.rounded())) }
            if let headroom {
                parts.append(String(format: NSLocalizedString("next: %1$@ (≈ %2$@ left)", comment: "Next account with headroom"), next, headroom))
            } else {
                parts.append(String(format: NSLocalizedString("next: %@", comment: "Next account"), next))
            }
        }
        return parts.joined(separator: " · ")
    }

    #if DEBUG
    /// Test seam: stands in for a row that discovery found on this Mac.
    func adoptForTesting(_ account: ManagedAccount, state: ManagedAccountState) {
        var selection = selected
        if selection[account.provider] == nil { selection[account.provider] = account.id }
        try? persist(accounts: accounts + [account], selected: selection)
        accounts.append(account)
        selected = selection
        states[account.id] = state
        normalizeRotationOrder()
        try? persist(accounts: accounts, selected: selected)
        updateHealth()
    }

    /// Test seam. Production state only ever comes from a refresh.
    func applyState(_ change: (inout ManagedAccountState) -> Void, to id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        var state = states[id] ?? ManagedAccountState()
        change(&state)
        states[id] = state
        updateHealth()
    }
    #endif

    /// Performs the one action the current attention asks for. Returns false when
    /// the person has to do something the app cannot do for them, such as adding
    /// a subscription.
    @discardableResult
    func repairAttention() async -> Bool {
        guard let attention, !hasShutDown else { return false }
        let account = attention.accountID.flatMap { id in accounts.first { $0.id == id } }
        defer { updateHealth() }
        switch attention.kind {
        case .keychainAccess:
            guard let account else { return false }
            return await allowClaudeAccess(account)
        case .reconnect:
            guard let account else { return false }
            await connect(account)
            return states[account.id]?.isConnected == true
        case .switchPaused:
            await retrySystemSwitch()
            return !systemSwitchPaused
        case .queueEmpty:
            return false
        }
    }
}

/// A one-way flag a blocking background thread can raise for the main actor.
/// Deliberately not an actor: shutdown must observe it without awaiting anything.
final class ShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func signal() { lock.lock(); raised = true; lock.unlock() }
    var isSignalled: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
