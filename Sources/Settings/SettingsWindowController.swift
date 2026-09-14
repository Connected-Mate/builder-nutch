import AppKit
import SwiftUI

/// Supplies settings content to the single account-manager window.
@MainActor
final class SettingsWindowController {
    /// All settings entry points route to the existing account manager.
    var onShowInAccounts: (() -> Void)?
    private let preferences: Preferences
    /// A closure, not a snapshot. Read once at launch, the account shown here
    /// went stale the moment someone switched account in Cursor — and stayed
    /// stale until the app was restarted.
    private let providers: () -> [ProviderSummary]
    private let signOut: (String) -> Void
    private let signIn: (String) -> Bool
    private let switchAccount: (String) -> Bool
    private let retry: (String) -> Void
    private let updater: Updater
    private let managedAccounts: Bool

    init(preferences: Preferences,
         providers: @escaping () -> [ProviderSummary],
         updater: Updater,
         signOut: @escaping (String) -> Void,
         signIn: @escaping (String) -> Bool,
         switchAccount: @escaping (String) -> Bool,
         retry: @escaping (String) -> Void,
         managedAccounts: Bool = false) {
        self.managedAccounts = managedAccounts
        self.switchAccount = switchAccount
        self.retry = retry
        self.updater = updater
        self.preferences = preferences
        self.providers = providers
        self.signOut = signOut
        self.signIn = signIn
    }

    func makeView() -> AnyView {
        AnyView(SettingsView(preferences: preferences, providers: providers,
                             signOut: signOut, signIn: signIn,
                             switchAccount: switchAccount, retry: retry,
                             updater: updater, managedAccounts: managedAccounts))
    }

    func show() {
        onShowInAccounts?()
    }
}
