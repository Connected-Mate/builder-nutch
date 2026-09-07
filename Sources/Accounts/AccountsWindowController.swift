import AppKit
import SwiftUI

/// Hosts account management in a normal, resizable macOS window.
@MainActor
final class AccountsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let manager: AccountManager
    private let onOpenSettings: (() -> Void)?

    init(manager: AccountManager, onOpenSettings: (() -> Void)? = nil) {
        self.manager = manager
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func show() {
        if let window {
            surface(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Builder Nutch"
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("CodenotchAccountsWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = AppTheme.windowBackground
        window.titlebarAppearsTransparent = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: AccountsView(manager: manager, onOpenSettings: onOpenSettings)
        )
        window.center()
        self.window = window
        surface(window)
    }

    private func surface(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
