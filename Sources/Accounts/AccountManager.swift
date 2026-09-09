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
            do { try persist(accounts: accounts, selected: selected) }
            catch { notice = error.localizedDescription }
        }
    }
    @Published private(set) var rotationOrder: [AccountProvider: [UUID]] = [:]
    @Published private(set) var switchThresholdPercent: Double = 15

    private let storage: AccountStorage?
    private let runner: any AccountCommandRunning
    private let resolveExecutable: (AccountProvider) -> URL?
    private let openTerminal: (URL) -> Bool
    private let openBrowser: (URL, URL, String?) async throws -> String
    private let readKimi: (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState
    private let readExistingKimi: (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState
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
         systemCredentials: ClaudeSystemCredentials? = nil,
         systemClaudeDirectory: URL? = nil,
         claudeReader: (any ClaudeAccountReading)? = nil) {
        self.automaticDiscovery = rootURL == nil
        self.systemCredentials = systemCredentials ?? (rootURL == nil ? ClaudeSystemCredentials() : nil)
        self.claudeReader = claudeReader ?? self.systemCredentials.map { ClaudeQuietUsageReader(credentials: $0) }
        self.systemClaudeLocation = ClaudeCredentialLocation(directory: systemClaudeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"), isDefault: true)
        self.runner = runner; self.resolveExecutable = executable; self.openTerminal = openTerminal
        self.openBrowser = openBrowser; self.readKimi = readKimi; self.readExistingKimi = readExistingKimi
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
            normalizeRotationOrder()
            states = Dictionary(uniqueKeysWithValues: accounts.map {
                ($0.id, $0.provider.isBrowserProfile ? Self.browserState($0) : ManagedAccountState(message: "Refresh to check this account."))
            })
        } catch {
            self.storage = nil; catalogError = error; notice = error.localizedDescription
        }
        loaded = true
        recoverClaudeCacheMarkers()
        shareSavedClaudeLogins()
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
            rotationOrder: rotationOrder, switchThresholdPercent: switchThresholdPercent))
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
        account.provider.isBrowserProfile && browserOpenedIDs.contains(account.id) && !busyIDs.contains(account.id)
    }

    func confirmBrowserConnection(_ account: ManagedAccount) throws {
        guard account.provider.isBrowserProfile, browserOpenedIDs.contains(account.id),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { throw ManagedAccountError.notConnected }
        var updated = accounts
        updated[index].browserConfirmedAt = Date()
        try persist(accounts: updated, selected: selected)
        accounts = updated
        states[account.id] = Self.browserState(updated[index])
        browserOpenedIDs.remove(account.id)
        notice = "Browser profile saved. Your sign-in stays in its browser; usage is shown on the website."
    }

    private func showBrowser(_ account: ManagedAccount, signingIn: Bool = false) async throws {
        guard let current = accounts.first(where: { $0.id == account.id && $0.provider == account.provider }),
              current.provider.isBrowserProfile else { throw ManagedAccountError.unavailable }
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
        notice = account.provider.isBrowserProfile ? "\(account.label) is selected. Open it to use its separate browser profile." : "\(account.label) is selected for future sessions. Existing sessions keep their account."
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
    }

    func setNext(_ account: ManagedAccount) throws {
        try select(account)
        notice = "\(account.label) will be used for the next \(account.provider.title) session."
    }

    func setSwitchThreshold(_ percent: Double) throws {
        switchThresholdPercent = min(max(percent.rounded(), 0), 100)
        reconcileAutomaticSelection()
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
        normalizeRotationOrder()
        try persist(accounts: accounts, selected: selected)
        browserOpenedIDs.remove(account.id)
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
    private func activateSystemClaude(_ target: ManagedAccount, automatic: Bool) async throws {
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
        defer { isSwitchingClaude = false; finish(current.id); finish(target.id) }
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
        guard !hasShutDown else { return }
        ClaudeCredentials.forgetCached()
        notice = "Claude now uses \(target.label) on this Mac. Sessions using the Mac login pick up this account on their next request."
        if automatic {
            automaticSwitch = AutomaticAccountSwitch(provider: .claude, fromID: current.id,
                fromName: current.label, toID: target.id, toName: target.label)
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
        guard systemCredentials != nil, !systemSwitchPaused, !isSwitchingClaude, !hasShutDown else { return }
        updateSystemClaudeIdentity()
        guard automaticSelection, !authenticationInProgress,
              let currentID = systemClaudeAccountID,
              let candidate = AccountSelection.systemClaude(accounts: accounts, states: states,
                order: rotationOrder[.claude] ?? [], currentID: currentID,
                preferredID: selected[.claude], thresholdPercent: switchThresholdPercent),
              !busyIDs.contains(currentID), !busyIDs.contains(candidate.id) else { return }
        do { try await activateSystemClaude(candidate, automatic: true) }
        catch {
            guard !hasShutDown else { return }
            systemSwitchPaused = true
            notice = NSLocalizedString("Automatic Claude switching is paused. Use account to retry when ready.", comment: "") + " " + error.localizedDescription
        }
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
        defer { loginAccountID = nil; finish(account.id) }
        do {
            if account.provider.isBrowserProfile {
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
    func allowClaudeAccess(_ account: ManagedAccount) async {
        guard !hasShutDown, account.provider == .claude, let credentials = systemCredentials,
              !authenticationInProgress, !isSwitchingClaude, busyIDs.isEmpty else { return }
        let location = systemClaudeAccountID == account.id ? systemClaudeLocation : credentialLocation(for: account)
        authorizationAccountID = account.id
        defer { authorizationAccountID = nil }
        do {
            try await Task.detached(priority: .userInitiated) { try credentials.authorize(at: location) }.value
            guard !hasShutDown else { return }
            await refresh(account)
        } catch {
            pausedRefreshIDs.insert(account.id)
            states[account.id]?.requiresKeychainAccess = true
            states[account.id]?.message = error.localizedDescription
        }
    }

    func shutdown() {
        hasShutDown = true
        systemCredentials?.requestStop()
        operations.values.forEach { $0.cancel() }
        discoveryCancellation?.cancel()
    }

    func shutdownAndWait() async {
        shutdown()
        // Give an already-committing switch time to persist its matching catalog.
        // The UI run loop remains free while the transaction finishes or cancels.
        while isSwitchingClaude { try? await Task.sleep(nanoseconds: 10_000_000) }
        if let credentials = systemCredentials {
            await Task.detached(priority: .utility) { credentials.waitUntilIdle() }.value
        }
    }

    private func read(_ account: ManagedAccount, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        guard !hasShutDown else { throw ManagedAccountError.cancelled }
        if account.provider.isBrowserProfile {
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
            if account.existingProfile != nil { return try await readExistingKimi(executable, profile, environment, cancellation) }
            return try await readKimi(executable, profile, environment, cancellation)
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
        defer { finish(account.id) }
        do {
            states[account.id] = try await read(account, cancellation: cancellation)
            guard !hasShutDown, !cancellation.isCancelled else { return }
            if states[account.id]?.isFresh() == true || account.provider.isBrowserProfile {
                externalRetryAfter.removeValue(forKey: account.id)
                pausedRefreshIDs.remove(account.id)
            } else { pausedRefreshIDs.insert(account.id) }
        }
        catch {
            guard !hasShutDown, !cancellation.isCancelled else { return }
            var state = states[account.id] ?? ManagedAccountState()
            state.message = error.localizedDescription
            // Retain the last displayed quotas, but never use a failed refresh for automation.
            state.refreshedAt = nil
            state.requiresKeychainAccess = (error as? ClaudeSystemCredentialError)?.requiresAccess == true
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
        await refreshAccounts(accounts.filter { !pausedRefreshIDs.contains($0.id) && externalRetryAfter[$0.id].map { $0 > Date() } != true })
        guard !hasShutDown, !Task.isCancelled else { return }
        if automaticDiscovery { await discoverExistingAccounts() }
        reconcileAutomaticSelection()
        await reconcileSystemClaudeSelection()
    }

    /// Failed probes are quiet and bounded; manual refresh of an existing row can retry immediately.
    func discoverExistingAccounts(candidates: [ExistingAccountCandidate]? = nil, now: Date = Date()) async {
        guard !hasShutDown, !authenticationInProgress, !discovering, catalogError == nil else { return }
        discovering = true
        defer { discovering = false }
        pruneSignedOutKimiProfiles()
        var found = 0
        for candidate in candidates ?? ExistingAccountDiscovery.candidates() {
            guard !hasShutDown, !Task.isCancelled else { break }
            let key = candidate.source.key(provider: candidate.provider)
            guard !candidate.provider.isBrowserProfile,
                  !ignoredExistingProfiles.contains(key),
                  !accounts.contains(where: { configurationDirectory(for: $0).standardizedFileURL.path == candidate.source.directory }),
                  storage.map({ !candidate.source.directory.hasPrefix($0.root.path + "/") }) ?? false,
                  !accounts.contains(where: { $0.existingProfile?.key(provider: $0.provider) == key }),
                  discoveryAttempts[key].map({ now.timeIntervalSince($0) >= 900 }) ?? true,
                  let executable = resolveExecutable(candidate.provider),
                  let directory = try? candidate.source.validatedDirectory() else { continue }
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
                } else if candidate.provider == .kimi {
                    state = try await readExistingKimi(executable, directory, environment, cancellation)
                } else {
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
                if let email = state.email?.lowercased(), !email.isEmpty,
                   accounts.contains(where: { $0.provider == candidate.provider && states[$0.id]?.isConnected == true && states[$0.id]?.email?.lowercased() == email }) { continue }
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

    /// Older builds could save Kimi's logged-out default profile as an account.
    /// Remove that stale row without ignoring the path, so a later real login is
    /// discovered normally.
    private func pruneSignedOutKimiProfiles() {
        let stale = Set(accounts.compactMap { account -> UUID? in
            guard account.provider == .kimi, let source = account.existingProfile,
                  source.kimiAuthenticationStatus() == .signedOut else { return nil }
            return account.id
        })
        guard !stale.isEmpty else { return }
        let updatedAccounts = accounts.filter { !stale.contains($0.id) }
        var updatedSelected = selected
        if let id = selected[.kimi], stale.contains(id) {
            updatedSelected[.kimi] = updatedAccounts.first { $0.provider == .kimi }?.id
        }
        let previousOrder = rotationOrder
        var updatedOrder = rotationOrder
        updatedOrder[.kimi] = (updatedOrder[.kimi] ?? []).filter { !stale.contains($0) }
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
        do {
            if account.provider == .claude, systemCredentials != nil {
                updateSystemClaudeIdentity()
                await refresh(account)
                guard state(for: account).isConnected else { throw ManagedAccountError.notConnected }
                try await activateSystemClaude(account, automatic: false)
                systemSwitchPaused = false
                return
            }
            if account.provider.isBrowserProfile {
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

    func snapshot(for account: ManagedAccount) -> ProviderSnapshot {
        let provider = account.provider
        let state = state(for: account)
        let status: ProviderStatus
        if !state.isConnected { status = .needsAuth }
        else if provider.isBrowserProfile { status = .unsupported("Open \(provider.title) to see usage. Browser sign-in is kept by the website.") }
        else if !state.windows.isEmpty && !state.isFresh() { status = .stale(since: state.refreshedAt ?? .distantPast) }
        else if let message = state.message { status = .unsupported(message) }
        else { status = .ok }
        let exhausted = state.windows.first { ($0.usedFraction ?? 0) >= 1 }
        let email = UserDefaults.standard.bool(forKey: "accounts.hidePersonalDetails")
            ? nil : (state.email ?? account.emailHint)
        return ProviderSnapshot(id: account.id.uuidString, displayName: account.emoji.map { "\($0) \(account.label)" } ?? account.label,
                                accountEmail: email,
                                glyph: provider.glyph, fidelity: provider.isBrowserProfile ? .manual : .official,
                                status: status, windows: state.windows,
                                headlineID: provider == .claude ? "five_hour" : "primary",
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
    }
}
