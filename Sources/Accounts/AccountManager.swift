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
    @Published var notice: String?
    @Published private(set) var discoveryNotice: String?
    @Published private(set) var automaticSwitch: AutomaticAccountSwitch?
    private var ignoredExistingProfiles: Set<String> = []
    private var discoveryAttempts: [String: Date] = [:]
    private var externalRetryAfter: [UUID: Date] = [:]
    private var discovering = false
    private let automaticDiscovery: Bool
    @Published var automaticSelection = false {
        didSet {
            guard loaded else { return }
            if automaticSelection { reconcileAutomaticSelection() }
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
         readExistingKimi: @escaping (URL, URL, [String: String], AccountCancellation) async throws -> ManagedAccountState = KimiAccountIntegration.readExisting) {
        self.automaticDiscovery = rootURL == nil
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
        ids.removeAll { $0 == accountID }
        guard let destination = ids.firstIndex(of: targetID) else { return }
        ids.insert(accountID, at: destination)
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
        if account.existingProfile != nil {
            await refresh(account)
            notice = "This account belongs to the official app. Reconnect there if needed, then refresh here."
            return
        }
        guard loginAccountID == nil, !busyIDs.contains(account.id) else { notice = ManagedAccountError.busy.localizedDescription; return }
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

    private func read(_ account: ManagedAccount, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        if account.provider.isBrowserProfile {
            guard let current = accounts.first(where: { $0.id == account.id }) else { throw ManagedAccountError.unavailable }
            return Self.browserState(current)
        }
        let (executable, profile, environment) = try prepare(account)
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
        guard !busyIDs.contains(account.id) else { return }
        let cancellation = AccountCancellation(); markBusy(account.id, cancellation: cancellation)
        defer { finish(account.id) }
        do {
            states[account.id] = try await read(account, cancellation: cancellation)
            externalRetryAfter.removeValue(forKey: account.id)
        }
        catch {
            var state = states[account.id] ?? ManagedAccountState()
            state.message = error.localizedDescription
            // Retain the last displayed quotas, but never use a failed refresh for automation.
            state.refreshedAt = nil
            if account.existingProfile != nil {
                state.isConnected = false
                externalRetryAfter[account.id] = Date().addingTimeInterval(900)
            }
            states[account.id] = state
        }
    }

    func refreshAll() async {
        await refreshAccounts(accounts.filter { externalRetryAfter[$0.id].map { $0 > Date() } != true })
        if automaticDiscovery { await discoverExistingAccounts() }
        reconcileAutomaticSelection()
    }

    /// Failed probes are quiet and bounded; manual refresh of an existing row can retry immediately.
    func discoverExistingAccounts(candidates: [ExistingAccountCandidate]? = nil, now: Date = Date()) async {
        guard !discovering, catalogError == nil else { return }
        discovering = true
        defer { discovering = false }
        var found = 0
        for candidate in candidates ?? ExistingAccountDiscovery.candidates() {
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
            do {
                let state: ManagedAccountState
                if candidate.provider == .kimi {
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
                guard !Task.isCancelled, state.isConnected else { continue }
                // Only verified identities count. User-entered hints never suppress a real account.
                if let email = state.email?.lowercased(), !email.isEmpty,
                   accounts.contains(where: { $0.provider == candidate.provider && states[$0.id]?.isConnected == true && states[$0.id]?.email?.lowercased() == email }) { continue }
                let account = ManagedAccount(id: UUID(), provider: candidate.provider,
                    label: try AccountStorage.validLabel(candidate.label), createdAt: now, existingProfile: candidate.source)
                var selection = selected
                if selection[account.provider] == nil { selection[account.provider] = account.id }
                try persist(accounts: accounts + [account], selected: selection)
                accounts.append(account); selected = selection; states[account.id] = state
                found += 1
            } catch { continue }
        }
        if found > 0 { discoveryNotice = "Found \(found) signed-in account\(found == 1 ? "" : "s") on this Mac. Their original app keeps each sign-in and configuration." }
    }

    private func refreshAccounts(_ snapshot: [ManagedAccount]) async {
        for start in stride(from: 0, to: snapshot.count, by: 2) {
            async let first: Void = refresh(snapshot[start])
            if start + 1 < snapshot.count { async let second: Void = refresh(snapshot[start + 1]); _ = await (first, second) }
            else { await first }
        }
    }

    func launch(_ account: ManagedAccount, project: URL) async {
        do {
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

    var snapshots: [ProviderSnapshot] {
        AccountProvider.allCases.compactMap { provider in
            guard let account = selectedAccount(for: provider) else { return nil }
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
