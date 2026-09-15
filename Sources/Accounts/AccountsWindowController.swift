import AppKit
import SwiftUI

/// Hosts account management in a normal, resizable macOS window.
@MainActor
final class AccountsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let manager: AccountManager
    private let preferences: Preferences
    private let usage: UsageInsightsModel
    private let navigation = AccountsNavigation()
    private let settingsContent: (() -> AnyView)?
    private let onOpenSettings: (() -> Void)?

    init(manager: AccountManager, preferences: Preferences, usage: UsageInsightsModel, onOpenSettings: (() -> Void)? = nil,
         settingsContent: (() -> AnyView)? = nil) {
        self.usage = usage
        self.settingsContent = settingsContent
        self.manager = manager
        self.preferences = preferences
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func show() {
        if let window {
            surface(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Builder Nutch"
        window.minSize = NSSize(width: 700, height: 480)
        window.setFrameAutosaveName("BuilderNutchCompactWindowV2")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.windowBackground
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: AccountsView(manager: manager, preferences: preferences, onOpenSettings: onOpenSettings,
                                   navigation: navigation, settingsContent: settingsContent, usage: usage)
        )
        window.center()
        self.window = window
        surface(window)
    }

    func showSettings() {
        navigation.showingSettings = true
        show()
    }

    func showDailyUsageShare() {
        navigation.dailyShareRequest = UUID()
        show()
    }

    private func surface(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
