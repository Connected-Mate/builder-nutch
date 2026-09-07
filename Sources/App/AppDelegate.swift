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
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

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
        controller.model.edge = preferences.notchEdge
        controller.model.usageDisplayMode = preferences.usageDisplayMode
        controller.onOpenSettings = { [weak accounts] in accounts?.show() }
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
        let item = StatusItemController { [weak accounts] in accounts?.show() }
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
        controller.show()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        if preferences.isFirstLaunch || manager.accounts.isEmpty || !preferences.hasChosenUsageDisplay {
            accounts.show()
        }
    }

    private func refresh() {
        guard refreshTask == nil, let manager = accountManager else { return }
        refreshTask = Task { [weak self] in
            await manager.refreshAll()
            self?.refreshTask = nil
        }
    }

    private func updateNotch() {
        guard let manager = accountManager, let controller = notchController else { return }
        // A running Claude session is what NOW means. The selected account can
        // differ because it is already prepared as NEXT after a quota handoff.
        controller.model.snapshots = AccountProvider.allCases.compactMap { provider in
            guard let selected = manager.selectedAccount(for: provider) else { return nil }
            let displayed: ManagedAccount
            if provider == .claude,
               let id = AccountActivitySelection.currentID(
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
        let claudeAccounts = manager.accounts.filter { $0.provider == .claude }
        let expected = Set(claudeAccounts.map { $0.id.uuidString })
        for id in Array(monitors.keys) where !expected.contains(id) {
            monitors.removeValue(forKey: id)?.stop()
            monitorSubscriptions.removeValue(forKey: id)?.cancel()
            controller.model.sessions.removeValue(forKey: id)
        }
        for account in claudeAccounts where monitors[account.id.uuidString] == nil {
            let id = account.id.uuidString
            let directory = manager.configurationDirectory(for: account).appendingPathComponent("sessions")
            let monitor = ClaudeSessionMonitor(directory: directory)
            monitorSubscriptions[id] = monitor.sessionsPublisher.receive(on: RunLoop.main).sink { [weak self] sessions in
                self?.notchController?.model.sessions[id] = sessions
                self?.notchController?.model.now = Date()
                self?.updateNotch()
            }
            monitors[id] = monitor
            monitor.start()
        }
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
            ? AccountActivitySelection.currentID(accounts: ordered, selectedID: selectedID,
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
        guard let snapshotID = manager.selectedAccount(for: provider)?.id.uuidString else { return nil }
        return NotchAccountPicker(provider: provider, snapshotID: snapshotID, title: title, accounts: accounts)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        accountsWindow?.show()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        accountManager?.cancelLogin()
        refreshTask?.cancel()
        refreshTimer?.invalidate()
        monitors.values.forEach { $0.stop() }
        notchController?.stop()
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
