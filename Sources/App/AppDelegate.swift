import AppKit
import Combine
import SwiftUI

/// Codenotch's native notch and placement, backed by explicit managed accounts.
/// No legacy provider is started implicitly: each login belongs to its vendor CLI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var accountManager: AccountManager?
    private var accountsWindow: AccountsWindowController?
    private var settings: SettingsWindowController?
    private var preferences: Preferences?
    private var statusItem: StatusItemController?
    private var updater: Updater?
    private var monitors: [String: ClaudeSessionMonitor] = [:]
    private var monitorSubscriptions: [String: AnyCancellable] = [:]
    private var monitorDirectories: [String: URL] = [:]
    private var profileSessions: [String: [AgentSession]] = [:]
    private var defaultClaudeMonitor: ClaudeSessionMonitor?
    private var defaultClaudeSubscription: AnyCancellable?
    private var defaultClaudeSessions: [AgentSession] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// The macOS notification centre, and the two things that use it.
    private var notifier: SystemNotifier?
    private var escalator: AttentionEscalator?
    private var usageThresholds: UsageThresholdNotifier?
    private var terminating = false
    private var terminationReplied = false

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppTheme.registerFonts()
        // Launch Services can keep an older Dock tile after an in-place update.
        // Setting the bundled icon explicitly makes the current release visible immediately.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        guard !isRunningTests else { return }
        // Never let an unattended native Keychain call interrupt the desktop.
        try? KeychainInteraction.shared.perform {}
        let preferences = Preferences()
        let manager = AccountManager()
        let controller = NotchWindowController()
        let updater = Updater()
        let appearance = SettingsWindowController(
            preferences: preferences, providers: { [] }, updater: updater,
            signOut: { _ in }, signIn: { _ in false },
            switchAccount: { _ in false }, retry: { _ in }, managedAccounts: true
        )
        let accounts = AccountsWindowController(manager: manager, preferences: preferences, onOpenSettings: { [weak appearance] in
            appearance?.show()
        })
        self.accountManager = manager
        self.accountsWindow = accounts
        self.preferences = preferences
        self.notchController = controller
        self.settings = appearance
        self.updater = updater
        // The notification centre, and the two things that speak through it.
        // Both are given the same notifier so a single authorisation covers
        // them, and both are built here rather than lazily: an escalation that
        // only exists once something has already gone wrong is an escalation
        // with nothing to measure the hour from.
        let notifier = SystemNotifier()
        let escalator = AttentionEscalator(notifier: notifier)
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.isEnabled = preferences.usageAlerts
        // A notification about a broken account is only useful if clicking it
        // lands on the account.
        notifier.onActivate = { [weak self] in self?.openAccounts() }
        self.notifier = notifier
        self.escalator = escalator
        self.usageThresholds = thresholds

        controller.model.edge = preferences.notchEdge
        controller.model.usageDisplayMode = preferences.usageDisplayMode
        controller.onOpenSettings = { [weak self] in self?.openAccounts() }
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onRefreshProvider = { [weak manager] id in
            guard let manager, let account = manager.accounts.first(where: { $0.id.uuidString == id }) else { return }
            Task { await manager.refresh(account) }
        }
        controller.onAccountPicker = { [weak self] id in self?.accountPicker(for: id) }
        controller.model.onMoveAccount = { [weak self, weak manager, weak controller] source, target in
            do { try manager?.moveInRotation(accountID: source, to: target) }
            catch { manager?.notice = error.localizedDescription }
            if let provider = manager?.accounts.first(where: { $0.id == source })?.provider {
                controller?.model.accountPicker = self?.accountPicker(for: provider)
            }
        }
        controller.model.onChooseNextAccount = { [weak self, weak manager, weak controller] id in
            guard let account = manager?.accounts.first(where: { $0.id == id }) else { return }
            do { try manager?.setNext(account) }
            catch { manager?.notice = error.localizedDescription }
            controller?.model.accountPicker = self?.accountPicker(for: account.provider)
        }
        let item = StatusItemController { [weak self] in self?.openAccounts() }
        self.statusItem = item
        preferences.$appPresence.receive(on: RunLoop.main).sink { presence in
            NSApp.setActivationPolicy(presence.activationPolicy)
            if presence.wantsStatusItem { item.show() } else { item.hide() }
        }.store(in: &cancellables)
        preferences.$notchVisibility.receive(on: RunLoop.main).sink { [weak controller] in
            controller?.apply($0)
        }.store(in: &cancellables)
        preferences.$notchEdge.receive(on: RunLoop.main).sink { [weak controller] in
            controller?.apply(edge: $0)
        }.store(in: &cancellables)
        preferences.$usageDisplayMode.receive(on: RunLoop.main).sink { [weak controller] in
            controller?.model.usageDisplayMode = $0
        }.store(in: &cancellables)
        preferences.$usageAlerts.receive(on: RunLoop.main).sink { [weak thresholds] in
            thresholds?.isEnabled = $0
        }.store(in: &cancellables)
        manager.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateNotch()
        }.store(in: &cancellables)
        manager.$automaticSwitch.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] event in
            self?.updateNotch()
            self?.notchController?.presentAutomaticSwitch(event)
        }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        updateNotch()
        startDefaultClaudeMonitor()
        controller.show()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        if preferences.isFirstLaunch || manager.accounts.isEmpty || !preferences.hasChosenUsageDisplay {
            openAccounts()
        }
    }

    /// Every route into the accounts window goes through here.
    ///
    /// Opening that window is what counts as having seen a problem, so a second
    /// door that did not say so would leave the escalation shouting at somebody
    /// who had just looked at it. There are four of these doors — the notch, the
    /// menu bar item, a first launch, and clicking the Dock icon — and the
    /// bookkeeping belongs to none of them individually.
    private func openAccounts() {
        escalator?.accountsWindowOpened()
        accountsWindow?.show()
    }

    private func refresh() {
        guard !terminating, refreshTask == nil, let manager = accountManager else { return }
        refreshTask = Task { [weak self] in
            await manager.refreshAll()
            self?.refreshTask = nil
        }
    }

    private func updateNotch() {
        guard let manager = accountManager, let controller = notchController else { return }
        controller.model.sessions = profileSessions
        if let id = manager.systemClaudeAccountID?.uuidString {
            let merged = (profileSessions[id] ?? []) + defaultClaudeSessions
            controller.model.sessions[id] = Array(Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        }
        // NOW follows the actual system login; selecting NEXT does not pretend
        // that an already-running client has switched subscriptions.
        controller.model.snapshots = AccountProvider.allCases.compactMap { provider in
            guard let selected = manager.selectedAccount(for: provider) else { return nil }
            let displayed: ManagedAccount
            if provider == .claude,
               let id = manager.systemClaudeAccountID ?? AccountActivitySelection.currentID(
                    accounts: manager.accounts.filter { $0.provider == provider },
                    selectedID: selected.id,
                    sessions: controller.model.sessions),
               let active = manager.accounts.first(where: { $0.id == id }) {
                displayed = active
            } else {
                displayed = selected
            }
            return manager.snapshot(for: displayed)
        }
        controller.model.refreshing = Set(manager.busyIDs.map(\.uuidString))
        controller.model.now = Date()

        // The red edge and the notification an hour later read the same
        // published value, so they can never disagree about which problem they
        // are talking about.
        let alert = manager.attention.map(NotchAlert.init)
        controller.model.attention = alert
        escalator?.update(alert)
        // Thresholds are asked of the snapshots the notch is showing rather
        // than of the manager directly: the notch shows the account that is
        // actually in use, and it is that account's limit somebody is spending.
        usageThresholds?.evaluate(snapshots: controller.model.snapshots, now: controller.model.now)
        let claudeAccounts = manager.accounts.filter { $0.provider == .claude }
        let expected = Set(claudeAccounts.map { $0.id.uuidString })
        for id in Array(monitors.keys) where !expected.contains(id) {
            monitors.removeValue(forKey: id)?.stop()
            monitorSubscriptions.removeValue(forKey: id)?.cancel()
            monitorDirectories.removeValue(forKey: id)
            profileSessions.removeValue(forKey: id)
            controller.model.sessions.removeValue(forKey: id)
        }
        for account in claudeAccounts {
            let id = account.id.uuidString
            let directory = manager.configurationDirectory(for: account).appendingPathComponent("sessions")
            guard monitors[id] == nil || monitorDirectories[id] != directory else { continue }
            monitors.removeValue(forKey: id)?.stop()
            monitorSubscriptions.removeValue(forKey: id)?.cancel()
            profileSessions.removeValue(forKey: id)
            monitorDirectories[id] = directory
            let monitor = ClaudeSessionMonitor(directory: directory)
            monitorSubscriptions[id] = monitor.sessionsPublisher.receive(on: RunLoop.main).sink { [weak self] sessions in
                self?.profileSessions[id] = sessions
                self?.notchController?.model.now = Date()
                self?.updateNotch()
            }
            monitors[id] = monitor
            monitor.start()
        }
    }

    private func startDefaultClaudeMonitor() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let monitor = ClaudeSessionMonitor(directory: directory)
        defaultClaudeSubscription = monitor.sessionsPublisher.receive(on: RunLoop.main).sink { [weak self] sessions in
            self?.defaultClaudeSessions = sessions
            self?.updateNotch()
        }
        defaultClaudeMonitor = monitor
        monitor.start()
    }

    private func accountPicker(for snapshotID: String) -> NotchAccountPicker? {
        guard let manager = accountManager,
              let account = manager.accounts.first(where: { $0.id.uuidString == snapshotID })
        else { return nil }
        return accountPicker(for: account.provider)
    }

    private func accountPicker(for provider: AccountProvider) -> NotchAccountPicker? {
        guard let manager = accountManager, provider.supportsAutomaticSelection else { return nil }
        let hideDetails = UserDefaults.standard.bool(forKey: "accounts.hidePersonalDetails")
        let mode = preferences?.usageDisplayMode ?? .remaining
        let ordered = manager.rotationAccounts(for: provider)
        let selectedID = manager.selectedAccount(for: provider)?.id
        let currentID = provider == .claude
            ? manager.systemClaudeAccountID ?? AccountActivitySelection.currentID(accounts: ordered, selectedID: selectedID,
                sessions: notchController?.model.sessions ?? [:])
            : selectedID
        let displayed = AccountActivitySelection.queue(accounts: ordered,
            currentID: currentID, selectedID: selectedID)
        let accounts = displayed.enumerated().map { index, account in
            let state = manager.state(for: account)
            let usage: String
            if let remaining = state.remainingPercent {
                let value = mode == .remaining ? remaining : 100 - remaining
                usage = "\(Int(value.rounded()))% \(mode.unit)"
            } else {
                usage = "—"
            }
            return NotchAccountItem(
                id: account.id,
                name: account.emoji.map { "\($0) \(account.label)" } ?? account.label,
                subtitle: hideDetails ? nil : (state.email ?? account.emailHint),
                usage: usage,
                usedFraction: state.windows.first?.usedFraction,
                isCurrent: index == 0,
                isNext: index == 1
            )
        }
        let title = String(format: NSLocalizedString("%@ accounts", comment: "Account picker title"), provider.title)
        guard let snapshotID = (currentID ?? selectedID)?.uuidString else { return nil }
        return NotchAccountPicker(provider: provider, snapshotID: snapshotID, title: title, accounts: accounts)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningTests else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        refreshTimer?.invalidate()
        OfficialAccountProcess.shutdownAll()
        accountManager?.shutdown()
        refreshTask?.cancel()
        Task {
            await accountManager?.shutdownAndWait()
            self.replyToTermination(sender)
        }
        // macOS is owed this reply. While it was owed, `osascript … quit` failed
        // with "User canceled (-128)". A credential transaction gets a few
        // seconds; after that the app quits regardless of what is still blocked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.replyToTermination(sender)
        }
        return .terminateLater
    }

    private func replyToTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openAccounts()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        accountManager?.shutdown()
        refreshTask?.cancel()
        refreshTimer?.invalidate()
        OfficialAccountProcess.shutdownAll()
        monitors.values.forEach { $0.stop() }
        defaultClaudeMonitor?.stop()
        notchController?.stop()
        escalator?.stop()
    }
}

extension NotchAlert {
    /// The account layer's problem, in the shape the notch draws.
    ///
    /// The translation lives here rather than in either of the two layers it
    /// joins: the notch is drawn entirely from its own view model, and the
    /// account layer has no business knowing a notch exists. `AppDelegate` is
    /// already where snapshots are assembled from managed accounts, and this is
    /// the same journey.
    init(_ attention: AccountAttention) {
        self.init(id: attention.id,
                  title: attention.title,
                  detail: attention.detail,
                  raisedAt: attention.raisedAt,
                  accountID: attention.accountID)
    }
}

enum AccountActivitySelection {
    /// Most recently changing live session wins when several profiles are open.
    /// Without a live session, the prepared account remains the visible current.
    static func currentID(accounts: [ManagedAccount], selectedID: UUID?,
                          sessions: [String: [AgentSession]]) -> UUID? {
        accounts.compactMap { account -> (UUID, Date)? in
            guard let latest = sessions[account.id.uuidString]?.map(\.since).max() else { return nil }
            return (account.id, latest)
        }.max { $0.1 < $1.1 }?.0 ?? selectedID
    }

    /// NOW is first. When automatic rotation already chose another account,
    /// that prepared account is NEXT; otherwise NEXT follows the user's order.
    static func queue(accounts: [ManagedAccount], currentID: UUID?, selectedID: UUID?) -> [ManagedAccount] {
        guard !accounts.isEmpty else { return [] }
        let current = accounts.first { $0.id == currentID } ?? accounts[0]
        let next: ManagedAccount?
        if selectedID != current.id {
            next = accounts.first { $0.id == selectedID }
        } else if let index = accounts.firstIndex(where: { $0.id == current.id }), accounts.count > 1 {
            next = accounts[(index + 1) % accounts.count]
        } else {
            next = nil
        }
        let leading = [current] + (next.map { [$0] } ?? [])
        let leadingIDs = Set(leading.map(\.id))
        return leading + accounts.filter { !leadingIDs.contains($0.id) }
    }
}
