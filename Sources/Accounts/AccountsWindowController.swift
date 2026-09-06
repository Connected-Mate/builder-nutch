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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Builder Nutch"
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("CodenotchAccountsWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
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
