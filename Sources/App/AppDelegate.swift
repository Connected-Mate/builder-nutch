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
        let activeIDs = Set(manager.selected.values.map(\.uuidString))
        // The full list lives in the manager; each selected assistant has its own ring.
        controller.model.snapshots = manager.snapshots.filter { activeIDs.contains($0.id) }
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
            monitorSubscriptions[id] = monitor.sessionsPublisher.receive(on: RunLoop.main).sink { [weak controller] sessions in
                controller?.model.sessions[id] = sessions
                controller?.model.now = Date()
            }
            monitors[id] = monitor
            monitor.start()
        }
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
