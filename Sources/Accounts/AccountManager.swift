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
    @Published var automaticSelection = false {
        didSet {
            guard loaded else { return }
            do { try persist(accounts: accounts, selected: selected) }
            catch { notice = error.localizedDescription }
        }
    }

    private let storage: AccountStorage?
    private let runner: any AccountCommandRunning
    private let resolveExecutable: (AccountProvider) -> URL?
    private let openTerminal: (URL) -> Bool
    private let openBrowser: (URL, URL, String?) async throws -> String
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
         openBrowser: @escaping (URL, URL, String?) async throws -> String = AccountBrowser.open) {
        self.runner = runner; self.resolveExecutable = executable; self.openTerminal = openTerminal
        self.openBrowser = openBrowser
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codenotch Accounts", isDirectory: true)
        do {
            let storage = try AccountStorage(root: root)
            let catalog = try storage.load()
            self.storage = storage
            accounts = catalog.accounts; selected = catalog.selected; automaticSelection = catalog.automaticSelection
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
        try usableStorage().save(AccountCatalog(accounts: accounts, selected: selected, automaticSelection: automaticSelection))
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

    private func showBrowser(_ account: ManagedAccount) async throws {
        guard let current = accounts.first(where: { $0.id == account.id && $0.provider == account.provider }),
              current.provider.isBrowserProfile else { throw ManagedAccountError.unavailable }
        let profile = try usableStorage().profile(current).appendingPathComponent("browser", isDirectory: true)
        try AccountStorage.privateDirectory(profile)
        let identifier = try await openBrowser(profile, current.provider.website, current.browserBundleIdentifier)
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

    func remove(_ account: ManagedAccount) throws {
        guard !busyIDs.contains(account.id) else { throw ManagedAccountError.busy }
        let updated = accounts.filter { $0.id != account.id }
        var selection = selected
        if selection[account.provider] == account.id { selection[account.provider] = updated.first { $0.provider == account.provider }?.id }
        try persist(accounts: updated, selected: selection)
        accounts = updated; selected = selection; states.removeValue(forKey: account.id)
        browserOpenedIDs.remove(account.id)
        notice = "Account removed from the list. Its private profile and official app credentials were retained; existing sessions continue."
    }

    func configurationDirectory(for account: ManagedAccount) -> URL {
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
        guard loginAccountID == nil, !busyIDs.contains(account.id) else { notice = ManagedAccountError.busy.localizedDescription; return }
        let cancellation = AccountCancellation()
        loginAccountID = account.id; markBusy(account.id, cancellation: cancellation)
        states[account.id]?.message = "Complete sign-in in your browser. Only this profile will be connected."
        defer { loginAccountID = nil; finish(account.id) }
        do {
            if account.provider.isBrowserProfile {
                try await showBrowser(account)
                states[account.id]?.message = "Finish signing in on the website, then choose ‘I’ve signed in’ here."
                notice = "\(account.provider.title) opened in its own browser profile."
                return
            }
            let (executable, profile, environment) = try prepare(account)
            var args = account.provider == .claude ? ["auth", "login", "--claudeai"] : ["--config", "cli_auth_credentials_store=\"keyring\"", "login"]
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
        let codex = account.provider == .codex
        let arguments = codex ? ["--config", "cli_auth_credentials_store=\"keyring\"", "app-server"] : ["auth", "status", "--json"]
        let data = try await runner.run(AccountCommand(executable: executable, arguments: arguments, environment: environment,
                                                       directory: profile, readsCodexAccount: codex), cancellation: cancellation)
        if cancellation.isCancelled { throw ManagedAccountError.cancelled }
        if codex { return try AccountQuotas.codex(data) }
        let quotaURL = profile.appendingPathComponent("quota.json")
        try AccountStorage.rejectSymlink(quotaURL)
        return try AccountQuotas.claude(status: data, quota: try? Data(contentsOf: quotaURL))
    }

    func refresh(_ account: ManagedAccount) async {
        guard !busyIDs.contains(account.id) else { return }
        let cancellation = AccountCancellation(); markBusy(account.id, cancellation: cancellation)
        defer { finish(account.id) }
        do { states[account.id] = try await read(account, cancellation: cancellation) }
        catch {
            var state = states[account.id] ?? ManagedAccountState()
            state.message = error.localizedDescription
            // Retain the last displayed quotas, but never use a failed refresh for automation.
            state.refreshedAt = nil; states[account.id] = state
        }
    }

    func refreshAll() async {
        await refreshAccounts(accounts)
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
                guard let candidate = AccountSelection.best(provider: account.provider, accounts: accounts, states: states) else { throw ManagedAccountError.unavailable }
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
            return ProviderSnapshot(id: account.id.uuidString, displayName: account.emoji.map { "\($0) \(account.label)" } ?? account.label,
                                    glyph: provider.glyph, fidelity: provider.isBrowserProfile ? .manual : .official,
                                    status: status, windows: state.windows,
                                    headlineID: provider == .claude ? "five_hour" : "primary",
                                    block: exhausted.map { UsageBlock(reason: "\($0.label) reached", resetsAt: $0.resetsAt) })
        }
    }
}
