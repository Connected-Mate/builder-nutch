import AppKit
import SwiftUI

/// The settings sheet, reached from the orb below the notch.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let providers: () -> [ProviderSummary]
    /// Re-read whenever the sheet comes forward. Switching account happens in
    /// another app, so the user is always coming *back* here to see it — which
    /// makes returning focus the exact moment the old value is wrong.
    @State private var accounts: [ProviderSummary] = []
    /// Switching off has to reach the store's archive, not just the preference
    /// — see `UsageStore.signOut(providerID:)`.
    let signOut: (String) -> Void
    /// Switching on takes the user to wherever that account is signed in.
    /// Returns false when there was nothing to open.
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    /// Re-reads a provider's credential. For a declined keychain prompt that is
    /// the whole remedy: asking again is what puts the prompt back on screen.
    let retry: (String) -> Void
    @ObservedObject var updater: Updater
    var managedAccounts = false
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            introduction
            if !managedAccounts { settingsSection("Integrations") {
                if needsSetup { setupNote }
                ForEach(accounts) {
                    AccountRow(provider: $0, preferences: preferences,
                               signOut: signOut, signIn: signIn,
                               switchAccount: switchAccount, retry: retry)
                }
                // Beside the switches it explains, not stranded at the end of
                // the page.
                Text("Builder Nutch never signs in — each reading is borrowed from the "
                     + "tool that already holds the account. Signing out here stops "
                     + "the credential being read and forgets the numbers, but leaves "
                     + "you signed in to that tool. macOS asks once per tool the "
                     + "first time, and again whenever you sign in to a different "
                     + "account; Always Allow keeps it quiet.")
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } }

            // One section, because they are one question: what Codenotch
            // looks like and where it turns up. Split across three headers it
            // read as three unrelated settings, and "Where Codenotch appears"
            // was a header long enough to look like a warning.
            settingsSection("Appearance") {
                SettingsChoices(label: "Usage display", choices: UsageDisplayMode.allCases,
                                selection: Binding(
                                    get: { preferences.usageDisplayMode },
                                    set: { preferences.chooseUsageDisplay($0) }
                                ), title: { $0.title })

                Text(LocalizedStringKey(preferences.usageDisplayMode.explanation))
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsChoices(label: "Show", choices: NotchVisibility.allCases,
                                selection: $preferences.notchVisibility, title: { $0.title })

                Text(LocalizedStringKey(preferences.notchVisibility.explanation))
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsChoices(label: "Edge", choices: NotchEdge.allCases,
                                selection: $preferences.notchEdge, title: { $0.title })

                Text(LocalizedStringKey(preferences.notchEdge.explanation))
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // "App icon", not "Icon": the two rows above it are about the
                // notch, and on its own the word would read as another of them.
                SettingsChoices(label: "App icon", choices: AppPresence.allCases,
                                selection: $preferences.appPresence, title: { $0.title })

                Text(LocalizedStringKey(preferences.appPresence.explanation))
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Startup and updates together: both are about what Codenotch does
            // without being asked, and one switch under its own header looked
            // like an oversight rather than a section.
            settingsSection("General") {
                SettingsChoices(label: "Language", choices: AppLanguage.allCases,
                                selection: Binding(
                                    get: { AppLanguage(rawValue: appLanguage) ?? .system },
                                    set: { appLanguage = $0.rawValue }
                                ), title: { $0.title })
                Toggle("Open Builder Nutch at login", isOn: $preferences.launchAtLogin)
                if let problem = preferences.launchAtLoginProblem {
                    Text(problem)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if updater.isAvailable {
                Toggle("Install updates automatically", isOn: Binding(
                    get: { updater.automatic },
                    set: { updater.automatic = $0 }
                ))

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Disclosed rather than merely silent. An app that updates
                    // itself unprompted *and* reads other apps' credentials is
                    // exactly the shape security tooling flags; saying so, with
                    // a way to switch it off, is the difference between a
                    // background updater and something that looks like it is
                    // hiding.
                    Text("Version \(updater.currentVersion). Updates install in the "
                         + "background and apply next time Builder Nutch starts.")
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Check now") { updater.checkNow() }
                        .controlSize(.small)
                }

                // Says what happened, where the user is already looking.
                // Sparkle's own answer to a failed check is a modal reading
                // "an error occurred in retrieving update information", which
                // names no cause and offers nothing to do about it.
                if let message = updater.outcome.message {
                    Text(message)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                } else {
                    HStack {
                        Text("Builder Nutch · \(updater.currentVersion)")
                        Spacer()
                        Link("Releases", destination: URL(string: "https://github.com/Connected-Mate/builder-nutch/releases")!)
                    }
                    Text("This community build checks no external update feed. Install new releases from the project page.")
                        .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.muted)
                }
            }
          }
          .padding(32)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Outside the form, so it stays put at the foot of the window rather
        // than scrolling away below the last section — a credit that has to be
        // hunted for is not really a credit.
        .safeAreaInset(edge: .bottom, spacing: 0) { credit }
        .frame(width: SettingsView.width, height: SettingsView.height)
        .background(AppTheme.paper)
        .foregroundStyle(AppTheme.ink)
        .font(AppTheme.font(.body))
        .buttonStyle(AppButtonStyle(compact: true))
        .toggleStyle(.switch)
        .tint(AppTheme.ink)
        .preferredColorScheme(.light)
        .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
        .onAppear { accounts = providers() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in accounts = providers() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make room for your work.")
                .font(AppTheme.font(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Choose where Builder Nutch lives, and when it appears.")
                .font(AppTheme.font(.callout))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(AppTheme.line).frame(height: 1).accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(AppTheme.font(.title3, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var credit: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AppTheme.line).frame(height: 1).accessibilityHidden(true)
            HStack(spacing: 16) {
                SupportLink()
                    .buttonStyle(AppButtonStyle(compact: true))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(managedAccounts ? "Based on Codenotch by" : "App designed and developed by")
                    Link("@hivinz_", destination: SettingsView.authorURL)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                }
                .font(AppTheme.font(.caption))
                .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.surface)
    }

    static let authorURL = URL(string: "https://x.com/hivinz_")!

    /// Room for all four visibility choices without shrinking their labels.
    static let width: CGFloat = 640
    /// The page scrolls while credits remain visible at the foot of the window.
    static let height: CGFloat = 680

    /// Nothing to read from anywhere. On a first launch that is the normal
    /// state, and it is the only moment the sheet has something to explain.
    private var needsSetup: Bool {
        !accounts.isEmpty && accounts.allSatisfy { $0.account == nil }
    }

    /// Names the tools rather than saying "tools already signed in on this
    /// Mac". Someone who uses Claude in a browser reads that sentence, installs
    /// this, sees four blank rings and concludes it is broken — and the
    /// distinction that catches them out is Claude *Code*, not the Claude app.
    static let setupCopy =
        "Builder Nutch reads usage from tools already signed in on this Mac — it "
        + "never asks for your password. Install and sign in to any of Claude "
        + "Code (the terminal tool, not the Claude app), Cursor, Codex or "
        + "Antigravity, and its ring appears in the notch."

    /// Said before it happens rather than after. A system dialogue asking to
    /// read a *credential*, from an app installed a minute ago, looks alarming
    /// unless it was expected — and choosing Allow instead of Always Allow makes
    /// it return on every read, which is what "it asks every time" turns out to
    /// be.
    static let keychainCopy =
        "macOS will ask once for permission to read Claude Code's and "
        + "Antigravity's saved logins. Choose Always Allow — plain Allow makes "
        + "it ask again every time."

    private var setupNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(AppTheme.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect an assistant to get started")
                    .font(AppTheme.font(.callout, weight: .medium))
                Text(SettingsView.setupCopy)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SettingsView.keychainCopy)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
    }


}

/// Native buttons retain keyboard activation and VoiceOver selection while
/// making the selected option use the product's charcoal instead of blue.
private struct SettingsChoices<Value: Hashable>: View {
    let label: String
    let choices: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label)).font(AppTheme.font(.callout, weight: .medium))
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { value in
                    Button { selection = value } label: {
                        Text(LocalizedStringKey(title(value)))
                            .font(AppTheme.font(.caption, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(AppButtonStyle(primary: selection == value, compact: true))
                    .accessibilityLabel(Text(LocalizedStringKey("\(label): \(title(value))")))
                    .accessibilityAddTraits(selection == value ? [.isSelected] : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One provider: whether Codenotch reads it, whose account that is, and where
/// to go if there is nothing to read.
private struct AccountRow: View {
    let provider: ProviderSummary
    @ObservedObject var preferences: Preferences
    let signOut: (String) -> Void
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    let retry: (String) -> Void

    private var isConnected: Bool { preferences.isConnected(provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centred, not baseline-aligned. A glyph is a `Shape` and has no
            // text baseline, so `.firstTextBaseline` lines its *bottom edge* up
            // with the text's baseline and lifts every icon above its own name.
            // Everything on this row is a single line, so centring is what makes
            // the mark, the name, the button and the switch sit on one axis.
            HStack(alignment: .center, spacing: 10) {
                ProviderGlyphView(glyph: provider.glyph, size: 16)
                    .foregroundStyle(isConnected ? AppTheme.ink : AppTheme.muted)

                Text(provider.name)
                    .foregroundStyle(isConnected ? AppTheme.ink : AppTheme.muted)

                Spacer(minLength: 8)

                // Prefers the app that owns the account, and falls back to the
                // web page only when there is no app to open.
                //
                // The reading is borrowed from an app on this Mac, so that app
                // is where the account actually lives — and the website is a
                // different session entirely, which will bounce you to a login
                // if the browser is not signed in. Sending someone to a login
                // screen from a row that says "connected" is the wrong answer
                // whenever the real thing is one launch away.
                // The way back from a declined keychain prompt, and the only
                // one: declining is easy to do by reflex, and nothing else on
                // screen will ask macOS again.
                //
                // Shown only while macOS is actually refusing. It used to be
                // permanent for any keychain-backed provider, which meant it sat
                // there next to a working account offering to fix nothing — and
                // when it *was* needed there was no way to tell the two apart.
                if isConnected, provider.wasRefusedAccess {
                    Button("Allow access…") { retry(provider.id) }
                        .controlSize(.small)
                        .help("Asks macOS for \(provider.name)'s saved login again. "
                              + "Choose Always Allow and it will stop asking.")
                }

                if isConnected, let destination {
                    Button(destination.title) { open(destination) }
                        .controlSize(.small)
                        .help(destination.help)
                }

                Toggle("", isOn: binding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Read \(provider.name) usage")
                    .help(isConnected
                          ? "Switch off to stop reading \(provider.name) and forget its "
                            + "readings. " + provider.signIn.signOutCaveat
                          : "Switch on to sign in and read \(provider.name) again.")
            }

            detail
                .font(AppTheme.font(.caption))
                .padding(.leading, 26)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !isConnected {
            Text("Signed out — nothing is read, and no readings are kept.")
                .foregroundStyle(AppTheme.muted)
        } else if let account = provider.account {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.summary)
                        .foregroundStyle(AppTheme.muted)
                        .textSelection(.enabled)
                    if canOpenSignIn {
                        Button("Switch…") { _ = switchAccount(provider.id) }
                            .buttonStyle(AppButtonStyle(compact: true))
                            .help(provider.signIn.switchHint)
                    }
                }
                // Says where the account actually lives, which is the whole
                // answer to "how do I change it" — not here.
                Text(provider.signIn.switchHint)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if provider.wasRefusedAccess {
            // Not a sign-in problem, so do not send them off to sign in. The
            // credential is right there and macOS is the one saying no — the
            // remedy is the button on this same row.
            Text("macOS is not letting Builder Nutch read \(provider.name)'s saved "
                 + "login. Choose Allow access… above, then Always Allow.")
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Text(provider.signIn.explanation)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = provider.signIn.actionTitle, canOpenSignIn {
                    Button(title) { _ = signIn(provider.id) }
                        .controlSize(.small)
                }

            }
        }
    }

    /// Where this row's "Open" button goes.
    enum Destination {
        case app(URL, name: String)
        case website(URL, host: String)

        var title: String {
            switch self {
            case .app(_, let name):     return "Open \(name)"
            case .website(_, let host): return "Open \(host)"
            }
        }

        var help: String {
            switch self {
            case .app(_, let name):
                return "Opens \(name), which is where this account is signed in."
            case .website(_, let host):
                return "Opens \(host) in your browser. That site has its own sign-in, "
                     + "separate from the credential read here."
            }
        }
    }

    /// The owning app when it is installed, the vendor's page otherwise.
    private var destination: Destination? {
        if case .openApp(let bundleID, let name) = provider.signIn,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return .app(app, name: name)
        }
        // Claude Code is a command with no app to open, so its row is always a
        // link — and claude.ai is genuinely where its usage can be checked.
        if let url = provider.account?.manageURL, let host = url.host {
            return .website(url, host: host)
        }
        return nil
    }

    private func open(_ destination: Destination) {
        switch destination {
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website(let url, _):
            NSWorkspace.shared.open(url)
        }
    }

    /// Offering to open an app that isn't installed gives a button that does
    /// nothing — worse than no button.
    private var canOpenSignIn: Bool {
        switch provider.signIn {
        case .modal:
            return true
        case .openApp(let bundleID, _):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .guidance:
            return false
        }
    }

    /// One control for both directions: on signs in, off signs out.
    ///
    /// Switching on does more than set a flag — if there is no credential to
    /// read it opens the sign-in there and then, which is the point of managing
    /// this from one place. Switching off is a real sign-out: it forgets the
    /// readings as well as stopping the next one.
    private var binding: Binding<Bool> {
        Binding(
            get: { preferences.isConnected(provider.id) },
            set: { wantsOn in
                if wantsOn {
                    preferences.setConnected(true, for: provider.id)
                    // Nothing to open for Claude Code — but then there is no
                    // account either, so `detail` is already showing what to do.
                    _ = signIn(provider.id)
                } else {
                    signOut(provider.id)
                    preferences.setConnected(false, for: provider.id)
                }
            }
        )
    }

}
