import AppKit
import SwiftUI

private extension AccountProvider {
    var workspaceTitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .kimi: return "Kimi Code"
        default: return title
        }
    }
}

@MainActor
final class AccountsNavigation: ObservableObject {
    @Published var showingSettings = false
}

/// The native account manager. Public screenshots are captured from this live view.
struct AccountsView: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var preferences: Preferences
    let onOpenSettings: (() -> Void)?
    @ObservedObject var navigation: AccountsNavigation
    let settingsContent: (() -> AnyView)?
    @State private var showingCustom = false
    @State private var catalogSearch = ""
    @State private var addingDesktopAssistant = false
    @State private var desktopSetupMessage: String?
    @State private var noticeTask: Task<Void, Never>?

    @State private var filter: AccountProvider?
    @State private var showingAdd = false
    @State private var showingUsage = false
    @StateObject private var usage = UsageInsightsModel()
    @State private var connecting: ManagedAccount?
    @State private var personalizing: ManagedAccount?
    @State private var showingRotation = false
    @State private var showingOpenAIRelay = false
    @State private var removing: ManagedAccount?
    @State private var localError: String?
    @State private var repairing = false
    @State private var projectURL: URL
    @AppStorage("accounts.hidePersonalDetails") private var hidePersonalDetails = false
    @AppStorage("accounts.projectFolder") private var savedProjectPath = ""
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue

    init(manager: AccountManager, preferences: Preferences, onOpenSettings: (() -> Void)? = nil, projectFolder: URL? = nil,
         navigation: AccountsNavigation? = nil, settingsContent: (() -> AnyView)? = nil) {
        self.navigation = navigation ?? AccountsNavigation()
        self.settingsContent = settingsContent
        self.manager = manager
        self.preferences = preferences
        self.onOpenSettings = onOpenSettings
        _filter = State(initialValue: manager.accounts.first?.provider)
        if let projectFolder {
            _projectURL = State(initialValue: projectFolder)
        } else {
            let saved = UserDefaults.standard.string(forKey: "accounts.projectFolder") ?? ""
            _projectURL = State(initialValue: URL(fileURLWithPath: saved.isEmpty ? NSHomeDirectory() : saved,
                                                   isDirectory: true))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if navigation.showingSettings, let settingsContent {
                    settingsContent()
                } else if showingCustom {
                    CustomAssistantSetupView()
                } else if showingAdd {
                    providerCatalog
                } else if showingUsage {
                    UsageInsightsView(manager: manager, model: usage, hidePersonalDetails: hidePersonalDetails)
                } else {
                    // A single contextual status, only where the affected accounts live.
                    if manager.loginAccountID != nil {
                        loginBanner
                    } else if filter == .claude, let attention = manager.attention {
                        attentionBanner(attention)
                    } else if let notice = manager.notice, !hidePersonalDetails {
                        noticeBanner(notice)
                    }
                    assistantList
                    if !manager.accounts.isEmpty { nextSessionBar }
                }
            }
            .background(AppTheme.surface)
        }
        .frame(minWidth: 700, minHeight: 450)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).tint(AppTheme.ink)
        .preferredColorScheme(.dark)
        .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
        .sheet(item: $connecting) { account in
            AddAssistantFlow(manager: manager, initialAccount: account) { localError = $0 }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: Binding(
            get: { !preferences.hasChosenUsageDisplay },
            set: { _ in }
        )) {
            UsageDisplayOnboarding(preferences: preferences)
                .interactiveDismissDisabled()
                .preferredColorScheme(.dark)
                .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
        }
        .sheet(item: $personalizing) { account in
            PersonalizeAssistantView(account: account, manager: manager) { localError = $0 }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingOpenAIRelay) {
            ClaudeOpenAIRelayView(manager: manager, project: $projectURL, hidePersonalDetails: hidePersonalDetails)
                .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
        }
        .sheet(isPresented: $showingRotation) {
            RotationSettingsView(manager: manager, provider: filter) { localError = $0 }
                .preferredColorScheme(.dark)
                .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
        }
        .confirmationDialog(
            "Remove \(removing.map { displayName(for: $0) } ?? "assistant")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { account in
            Button("Remove from Builder Nutch", role: .destructive) {
                do { try manager.remove(account) } catch { localError = error.localizedDescription }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { account in
            Text("This removes \(displayName(for: account)) from the list. The official service keeps its saved sign-in.")
        }
        .alert("Builder Nutch", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
        .onAppear { manager.notice = nil }
        .onChange(of: manager.notice) { _, notice in
            noticeTask?.cancel()
            guard notice != nil else { return }
            noticeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                manager.notice = nil
            }
        }
        .onChange(of: navigation.showingSettings) { _, _ in manager.notice = nil }
        .onDisappear { noticeTask?.cancel() }
        .onChange(of: providerIDs) { _, _ in
            if filter == nil || !providers.contains(where: { $0 == filter }) { self.filter = providers.first }
        }
    }

    private var providerIDs: [String] { manager.accounts.map(\.provider.rawValue).sorted() }
    private var providers: [AccountProvider] {
        AccountProvider.allCases.filter { provider in manager.accounts.contains { $0.provider == provider } }
    }
    private var visibleAccounts: [ManagedAccount] {
        guard let filter, providers.contains(filter) else { return manager.accounts }
        return manager.accounts.filter { $0.provider == filter }
    }
    private var selectedAccount: ManagedAccount? {
        if let filter { return manager.selectedAccount(for: filter) }
        return nil
    }

    private func showAccounts() {
        navigation.showingSettings = false
        showingCustom = false
        showingUsage = false
        showingAdd = false
        manager.notice = nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assistants")
                .font(AppTheme.font(size: 11, weightValue: 550)).foregroundStyle(AppTheme.muted)
                .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(providers) { filterButton($0) }
                    Button {
                        showAccounts(); showingCustom = true
                    } label: {
                        Label("Custom assistants", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle())
                    .background(showingCustom && !navigation.showingSettings ? AppTheme.selected : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        showAccounts(); showingAdd = true
                    } label: {
                        Label("Add assistant", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle()).padding(.top, 4)
                    .disabled(manager.loginAccountID != nil)
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            Spacer(minLength: 8)
            usageButton
            Button {
                if settingsContent != nil {
                    navigation.showingSettings = true
                } else { onOpenSettings?() }
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(WorkspaceQuietButtonStyle())
            .background(navigation.showingSettings ? AppTheme.selected : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityAddTraits(navigation.showingSettings ? .isSelected : [])
        }
        .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
        .padding(.horizontal, 8).padding(.bottom, 12)
        .frame(width: 174)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.line).frame(width: 1) }
    }

    /// Where the week went, beside the assistants it was spent with.
    private var usageButton: some View {
        let active = showingUsage && !showingAdd && !showingCustom && !navigation.showingSettings
        return Button { showAccounts(); showingUsage = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 24)
                Text("Usage")
                    .font(AppTheme.font(size: 13, weightValue: active ? 600 : 400)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(active ? AppTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? AppTheme.line : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceQuietButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func filterButton(_ provider: AccountProvider) -> some View {
        let active = filter == provider && !showingAdd && !showingUsage && !showingCustom && !navigation.showingSettings
        let count = manager.accounts.filter { $0.provider == provider }.count
        return Button { showAccounts(); filter = provider } label: {
            HStack(spacing: 8) {
                ProviderGlyphView(glyph: provider.glyph, size: 20).frame(width: 24, height: 24)
                Text(provider.title)
                    .font(AppTheme.font(size: 13, weightValue: active ? 600 : 400)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(active ? AppTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? AppTheme.line : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceQuietButtonStyle())
        .accessibilityLabel("\(provider.workspaceTitle), \(count) account\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(navigation.showingSettings ? "Settings" : showingCustom ? "Custom assistants" :
                    showingAdd ? "Add an assistant" : showingUsage ? "Usage" : filter?.workspaceTitle ?? "Accounts"))
                .font(AppTheme.font(size: 19, weightValue: 650)).tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !navigation.showingSettings && !showingCustom {
                Button { hidePersonalDetails.toggle() } label: {
                    Image(systemName: hidePersonalDetails ? "eye.slash" : "eye").frame(width: 28, height: 32)
                }
                .buttonStyle(WorkspaceQuietButtonStyle())
                .help(hidePersonalDetails ? "Show personal details" : "Hide personal details")
                .accessibilityLabel(hidePersonalDetails ? "Show personal details" : "Hide personal details")
                if !showingAdd {
                    Button {
                        Task {
                            if showingUsage { await usage.refresh() } else { await manager.refreshAll() }
                        }
                    } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 32) }
                    .buttonStyle(WorkspaceQuietButtonStyle()).help("Refresh")
                    .accessibilityLabel("Refresh")
                    .disabled(showingUsage ? usage.isLoading : !manager.busyIDs.isEmpty)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    @ViewBuilder private var assistantList: some View {
        if manager.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("All your AI. Room to build.")
                    .font(AppTheme.font(size: 30, weightValue: 550)).tracking(-1)
                Text("Add your first assistant, then sign in with its official service.")
                    .font(AppTheme.font(size: 14)).foregroundStyle(AppTheme.muted)
                Button { showingAdd = true } label: { Label("Add assistant", systemImage: "plus") }
                    .buttonStyle(AppButtonStyle(primary: true))
                    .disabled(manager.loginAccountID != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(30)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Account").frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 3) {
                        Text(LocalizedStringKey(preferences.usageDisplayMode.columnTitle))
                    }.frame(width: 78)
                    Text("Selection").frame(width: 100)
                }
                .font(AppTheme.font(size: 10, weightValue: 500)).foregroundStyle(AppTheme.muted)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleAccounts) { account in
                            AssistantRow(account: account, state: manager.state(for: account),
                                         isSelected: manager.isSelected(account),
                                         isLoginPending: manager.loginAccountID == account.id,
                                         loginInProgress: manager.authenticationInProgress,
                                         displayMode: preferences.usageDisplayMode,
                                         projectURL: projectURL, manager: manager,
                                         connect: {
                                             if account.provider == .antigravity { Task { await manager.connect(account) } }
                                             else { connecting = account }
                                         },
                                         personalize: { personalizing = account },
                                         remove: { removing = account },
                                         reportError: { localError = $0 })
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var providerCatalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your assistant.")
                .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
            if let desktopSetupMessage {
                Label(desktopSetupMessage, systemImage: "info.circle")
                    .font(AppTheme.font(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            TextField("Find an assistant", text: $catalogSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find an assistant")
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(AccountProvider.allCases.filter {
                        catalogSearch.isEmpty || $0.workspaceTitle.localizedCaseInsensitiveContains(catalogSearch)
                    }) { provider in
                        Button { createAndConnect(provider) } label: {
                            HStack(spacing: 12) {
                                ProviderGlyphView(glyph: provider.glyph, size: 24).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.workspaceTitle).font(AppTheme.font(size: 13, weightValue: 550))
                                    Text(LocalizedStringKey(provider.connectionSummary)).font(AppTheme.font(size: 11))
                                        .foregroundStyle(AppTheme.muted).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "plus").font(.system(size: 12))
                            }
                            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(WorkspaceQuietButtonStyle()).disabled(manager.authenticationInProgress || addingDesktopAssistant)
                        .accessibilityLabel("Add \(provider.workspaceTitle). \(provider.connectionDetail)")
                    }
                }
            }
            Button {
                showingAdd = false; showingCustom = true
            } label: {
                Label("Add a custom assistant", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(AppButtonStyle(compact: true))
        }
        .padding(24)
    }

    private func createAndConnect(_ provider: AccountProvider) {
        guard !manager.authenticationInProgress, !addingDesktopAssistant else { return }
        desktopSetupMessage = nil
        if provider == .antigravity {
            addingDesktopAssistant = true
            Task {
                defer { addingDesktopAssistant = false }
                do {
                    if try await manager.attachAntigravity() != nil {
                        filter = provider; showingAdd = false
                    } else { desktopSetupMessage = manager.notice }
                } catch { localError = error.localizedDescription }
            }
            return
        }
        do {
            let count = manager.accounts.filter { $0.provider == provider }.count
            let account = try manager.add(provider: provider,
                                          label: count == 0 ? provider.title : "\(provider.title) \(count + 1)",
                                          emailHint: nil)
            filter = provider; showingAdd = false; connecting = account
        } catch { localError = error.localizedDescription }
    }

    private var nextSessionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if filter?.supportsAutomaticSelection == true {
                    Toggle("Automatic rotation", isOn: $manager.automaticSelection)
                        .font(AppTheme.font(size: 11)).toggleStyle(.switch).controlSize(.mini)
                    Button { showingRotation = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle()).help("Order & threshold…")
                    .accessibilityLabel("Order & threshold…")
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Choose project folder…", action: chooseProjectFolder)
                    if filter == .claude || filter == .codex {
                        Button(filter == .claude ? "Use OpenAI…" : "Open Claude Code…") { showingOpenAIRelay = true }
                            .disabled(manager.authenticationInProgress)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Session options")
            }
            if let selectedAccount {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedAccount.readsDesktopUsage ? "On this Mac" : selectedAccount.isBrowserOnly ? "Selected profile" : "For your next session")
                            .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                        Text(displayName(for: selectedAccount)).font(AppTheme.font(size: 12, weightValue: 550)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await manager.launch(selectedAccount, project: projectURL) }
                    } label: {
                        Label(selectedAccount.isBrowserOnly ? "Open profile" : "Open \(selectedAccount.provider.workspaceTitle)",
                              systemImage: "arrow.up.right")
                    }
                    .buttonStyle(AppButtonStyle(primary: true, compact: true))
                    .disabled((!manager.state(for: selectedAccount).isConnected && selectedAccount.provider != .antigravity) || manager.state(for: selectedAccount).isBusy || manager.authenticationInProgress)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(AppTheme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func displayName(for account: ManagedAccount) -> String {
        guard hidePersonalDetails else { return account.label }
        let position = manager.accounts.filter { $0.provider == account.provider }.firstIndex { $0.id == account.id } ?? 0
        return "\(account.provider.title) \(position + 1)"
    }

    private var loginBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finish the official sign-in in your browser.").font(AppTheme.font(size: 12))
            Spacer()
            Button("Cancel") { manager.cancelLogin() }.buttonStyle(WorkspaceSelectionStyle())
        }
        .padding(.horizontal, 24).padding(.vertical, 10).background(AppTheme.soft)
    }

    /// One problem, one sentence, one button. The colour separates "macOS is
    /// stopping us" from "you will run out soon"; nothing else on this screen
    /// uses it, so a coloured band always means something is waiting on you.
    private func attentionBanner(_ attention: AccountAttention) -> some View {
        let tint = Self.attentionTint(attention.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: attention.symbolName)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(attention.title).font(AppTheme.font(size: 12, weightValue: 600)).foregroundStyle(AppTheme.ink)
                Text(attention.detail).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button(attention.actionTitle) { repair(attention) }
                .buttonStyle(WorkspaceSelectionStyle(primary: true))
                .disabled(repairing || manager.loginAccountID != nil)
        }
        .padding(.leading, 27).padding(.trailing, 30).padding(.vertical, 12)
        .background(tint.opacity(0.06))
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attention.title). \(attention.detail)")
    }

    private static func attentionTint(_ kind: AccountAttention.Kind) -> Color {
        switch kind {
        case .keychainAccess, .reconnect: return Palette.alert
        case .switchPaused, .queueEmpty: return AppTheme.muted
        }
    }

    private func repair(_ attention: AccountAttention) {
        guard !repairing else { return }
        // Nothing the app can do for them: open the flow that can.
        guard attention.kind != .queueEmpty else { showingAdd = true; return }
        repairing = true
        Task {
            await manager.repairAttention()
            repairing = false
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(notice).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { manager.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }
        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
        .padding(.horizontal, 24).padding(.vertical, 10).background(AppTheme.paper)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"; panel.prompt = "Choose"; panel.directoryURL = projectURL
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url; savedProjectPath = url.path(percentEncoded: false)
    }
}

private struct WorkspaceQuietButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered ? AppTheme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

private struct WorkspaceSelectionStyle: ButtonStyle {
    var primary = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(size: 11, weightValue: 500))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(primary ? AppTheme.surface : AppTheme.ink)
            .background(primary ? AppTheme.ink : hovered ? AppTheme.soft : AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(primary ? AppTheme.ink : AppTheme.line))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { hovered = $0 }
    }
}

private struct CodexUsageGroup: Identifiable {
    let id: String
    let title: String
    var windows: [(window: LimitWindow, duration: String)]

    var remainingPercent: Int? {
        windows.compactMap(\.window.usedFraction).map { max(0, 100 - Int(($0 * 100).rounded())) }.min()
    }
}

enum AccountUsageNotice {
    static func modelLimit(_ state: ManagedAccountState) -> String? {
        guard state.isConnected, state.isFresh(), (state.accountRemainingPercent ?? 0) > 0,
              state.accountWindows.allSatisfy({ !$0.isBlocked && ($0.usedFraction ?? 1) < 1 }),
              let limit = state.windows.first(where: { $0.isModelSpecific && ($0.isBlocked || ($0.usedFraction ?? 0) >= 1) }),
              let name = limit.modelName else { return nil }
        return String(format: NSLocalizedString("%@ is at its limit. Choose another model with /model.", comment: "Model-only limit"), name)
    }
}

private struct AssistantRow: View {
    let account: ManagedAccount
    let state: ManagedAccountState
    let isSelected: Bool
    let isLoginPending: Bool
    let loginInProgress: Bool
    let displayMode: UsageDisplayMode
    let projectURL: URL
    @ObservedObject var manager: AccountManager
    let connect: () -> Void
    let personalize: () -> Void
    let remove: () -> Void
    let reportError: (String) -> Void
    @State private var showingUsage = false
    @AppStorage("accounts.hidePersonalDetails") private var hidePersonalDetails = false

    private var displayLabel: String {
        guard hidePersonalDetails else { return account.label }
        let position = manager.accounts.filter { $0.provider == account.provider }.firstIndex { $0.id == account.id } ?? 0
        return "\(account.provider.title) \(position + 1)"
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(AppTheme.soft)
                    RoundedRectangle(cornerRadius: 8).stroke(AppTheme.line)
                    if let emoji = account.emoji, !emoji.isEmpty, !hidePersonalDetails {
                        Text(emoji).font(.system(size: 17))
                    } else {
                        Text(String(displayLabel.prefix(1)).uppercased())
                            .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                    }
                }
                .frame(width: 32, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Button(action: personalize) {
                        HStack(spacing: 5) {
                            Text(displayLabel).font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                            if !hidePersonalDetails { Image(systemName: "pencil").font(.system(size: 9)) }
                        }
                    }
                    .buttonStyle(.plain).help("Rename \(displayLabel)")
                    .disabled(state.isBusy || isLoginPending || hidePersonalDetails)
                    if let email = state.email ?? account.emailHint, !email.isEmpty {
                        Text(hidePersonalDetails ? "Personal details hidden" : email).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                            .lineLimit(1).truncationMode(.middle).help(hidePersonalDetails ? "Personal details hidden" : email)
                    }
                    Text(LocalizedStringKey(statusDescription)).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .lineLimit(1).help(statusDescription)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Usage details") { showingUsage = true }
                    if state.isConnected {
                        Button(account.isBrowserOnly ? "Open profile" : "Open with this account") {
                            Task { await manager.launch(account, project: projectURL) }
                        }.disabled(state.isBusy || loginInProgress)
                    }
                    if !account.isBrowserOnly {
                        Button("Refresh usage") { Task { await manager.refresh(account) } }.disabled(state.isBusy)
                    }
                    Button(hidePersonalDetails ? "Show personal details to rename…" : "Rename & emoji…", action: personalize)
                        .disabled(state.isBusy || isLoginPending || hidePersonalDetails)
                    Divider()
                    Button("Remove…", role: .destructive, action: remove).disabled(state.isBusy || isLoginPending)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 30)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for \(displayLabel)")
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { showingUsage = true } label: {
                VStack(spacing: 0) {
                    quotaRing
                    if let period = state.headlinePeriodText(for: account.provider) {
                        Text(period).font(AppTheme.font(size: 9)).foregroundStyle(AppTheme.muted)
                    }
                }
            }
                .buttonStyle(.plain).frame(width: 78)
                .accessibilityLabel("Usage details for \(displayLabel): \(quotaDescription)")
                .popover(isPresented: $showingUsage) { usageDetails }
            selectionControl.frame(width: 100)
        }
        .padding(.vertical, 8).frame(minHeight: 76)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayLabel), \(account.provider.workspaceTitle), \(statusDescription)")
    }

    private var quotaDescription: String {
        if account.isBrowserOnly { return "Check usage on the official website" }
        guard let remaining = state.headlineRemainingPercent(for: account.provider), state.isConnected else { return "Usage unavailable" }
        let value = displayMode == .remaining ? remaining : 100 - remaining
        return "\(Int(value.rounded())) percent \(displayMode.unit) · \(state.headlinePeriodText(for: account.provider) ?? "")\(state.isFresh() ? "" : ", last known; refresh needed")"
    }

    private var quotaRing: some View {
        ZStack {
            Circle().stroke(AppTheme.track, lineWidth: 3)
            if let remaining = state.headlineRemainingPercent(for: account.provider), state.isConnected, !account.isBrowserOnly {
                let shown = displayMode == .remaining ? remaining : 100 - remaining
                Circle().trim(from: 0, to: min(max(shown / 100, 0), 1))
                    .stroke(AppTheme.ink.opacity(state.isFresh() ? 1 : 0.45),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(shown.rounded()))").font(AppTheme.font(size: 11, weightValue: 600))
                    Text("%").font(AppTheme.font(size: 8, weightValue: 450))
                }
            } else {
                Text("—").font(AppTheme.font(size: 13)).foregroundStyle(AppTheme.muted)
            }
        }
        .frame(width: 43, height: 43).padding(6).help(quotaDescription)
    }

    @ViewBuilder private var selectionControl: some View {
        if state.requiresKeychainAccess {
            Button("Allow access") { Task { await manager.allowClaudeAccess(account) } }
                .buttonStyle(WorkspaceSelectionStyle())
                .disabled(state.isBusy || loginInProgress || !manager.busyIDs.isEmpty)
                .help("Only this click may ask macOS for access. Cancelling leaves the account paused.")
        } else if !state.isConnected {
            Button(isLoginPending ? "Signing in…" : "Connect", action: connect)
                .buttonStyle(WorkspaceSelectionStyle()).disabled(state.isBusy || loginInProgress)
        } else {
            Button {
                do { try manager.setNext(account) } catch { reportError(error.localizedDescription) }
            } label: {
                HStack(spacing: 5) {
                    if isSelected { Image(systemName: "checkmark").font(.system(size: 9)) }
                    if isSelected {
                        Text("Selected")
                    } else {
                        Text("Select")
                    }
                }
                .frame(width: 70)
            }
            .buttonStyle(WorkspaceSelectionStyle(primary: isSelected))
            .disabled(state.isBusy || isLoginPending)
            .accessibilityLabel("\(isSelected ? "Selected" : "Select") \(displayLabel) for \(account.provider.workspaceTitle)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var statusDescription: String {
        if isLoginPending { return "Sign-in in progress" }
        if state.isBusy { return "Checking…" }
        if !state.isConnected { return state.message ?? "Connect this account." }
        if account.isBrowserOnly { return "Browser profile ready" }
        let rateLimit = state.rateLimitStatus()
        if rateLimit.kind != .notReported { return rateLimit.title }
        if !state.windows.isEmpty && !state.isFresh() { return "Last known usage · refresh to update" }
        if AccountUsageNotice.modelLimit(state) != nil { return "Model limit · See usage details" }
        if account.provider == .claude && manager.systemClaudeAccountID == account.id { return "Current account on this Mac" }
        if let message = state.message {
            if account.provider == .claude && state.needsFirstUsage &&
                message == "Usage appears after the first Claude Code session launched here." {
                return "Usage appears after your first session"
            }
            return message
        }
        if let limit = state.headlineWindow(for: account.provider), let reset = limit.resetsAt {
            return "\(limit.label) · Resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return "Connected"
    }

    private var usageDetails: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(displayLabel) · Usage").font(AppTheme.font(size: 16, weightValue: 650))
            if !account.isBrowserOnly { rateLimitDetails }
            if account.isBrowserOnly {
                Text("Usage stays on \(account.provider.title)’s website.")
            } else if state.windows.isEmpty {
                Text(LocalizedStringKey(statusDescription))
            } else if account.provider == .codex {
                ForEach(codexUsageGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(LocalizedStringKey(group.title)).font(AppTheme.font(size: 13, weightValue: 650))
                            Spacer()
                            if let remaining = group.remainingPercent {
                                let value = displayMode == .remaining ? remaining : 100 - remaining
                                Text("\(value)% \(displayMode.unit)").font(AppTheme.font(size: 12, weightValue: 600)).monospacedDigit()
                            }
                        }
                        ForEach(group.windows, id: \.window.id) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(entry.duration)).font(AppTheme.font(size: 11, weightValue: 600))
                                Text(entry.window.summary(for: displayMode)).monospacedDigit()
                                if let reset = entry.window.resetsAt {
                                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                        .foregroundStyle(AppTheme.muted)
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
                usageFooter
            } else {
                ForEach(state.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        if let model = window.modelName {
                            Text("Model limit: \(model)").font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        } else {
                            Text("All models").font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        }
                        Text(window.label).font(AppTheme.font(size: 12, weightValue: 600))
                        Text(window.summary(for: displayMode)).monospacedDigit()
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                }
                usageFooter
            }
        }
        .font(AppTheme.font(size: 12)).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 390, height: min(460, CGFloat(max(state.windows.count, 1)) * 94 + 180))
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).preferredColorScheme(.dark)
    }

    private var rateLimitDetails: some View {
        let limit = state.rateLimitStatus()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Limits and availability").font(AppTheme.font(size: 12, weightValue: 600))
            Text(limit.title).fixedSize(horizontal: false, vertical: true)
            if !limit.affectedLabels.isEmpty {
                Text(limit.affectedLabels.joined(separator: " · "))
                    .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let retry = limit.retryAt {
                if limit.kind == .usageCheckPaused {
                    Text("Next usage check: \(retry.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(AppTheme.muted)
                } else if limit.isResetDerived {
                    Text("Estimated reset: \(retry.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(AppTheme.muted)
                } else {
                    Text("Limit resets: \(retry.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(AppTheme.muted)
                }
            }
            if limit.kind == .usageCheckPaused {
                Text("Only the usage check is paused. This does not mean your AI is blocked.")
                    .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            } else if limit.kind == .notReported {
                Text("This service does not report requests or tokens per minute here. Subscription limits are listed below.")
                    .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(AppTheme.line).padding(.top, 4)
        }
    }

    @ViewBuilder private var usageFooter: some View {
        if let modelLimit = AccountUsageNotice.modelLimit(state) {
            Text(modelLimit).fixedSize(horizontal: false, vertical: true)
        }
        if let date = state.refreshedAt {
            Text("\(state.isFresh() ? "Updated" : "Last known") \(date.formatted(.relative(presentation: .named)))")
                .foregroundStyle(AppTheme.muted)
        }
        if let message = state.message { Text(message).foregroundStyle(AppTheme.muted) }
    }

    private var codexUsageGroups: [CodexUsageGroup] {
        var groups: [CodexUsageGroup] = []
        for window in state.windows {
            let pieces = window.label.components(separatedBy: " · ")
            let title = pieces.count > 1 ? pieces.dropLast().joined(separator: " · ") : "All Codex models"
            let duration = pieces.last ?? window.label
            let idPieces = window.id.split(separator: ".")
            let groupID = idPieces.count > 1 ? idPieces.dropLast().joined(separator: ".") : "codex"
            if let index = groups.firstIndex(where: { $0.id == groupID }) {
                groups[index].windows.append((window, duration))
            } else {
                groups.append(CodexUsageGroup(id: groupID, title: title, windows: [(window, duration)]))
            }
        }
        return groups
    }
}

private struct RotationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: AccountManager
    let provider: AccountProvider?
    let reportError: (String) -> Void

    private var activeProvider: AccountProvider? {
        if let provider, provider.supportsAutomaticSelection { return provider }
        return AccountProvider.allCases.first { candidate in
            candidate.supportsAutomaticSelection && manager.accounts.contains { $0.provider == candidate }
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automatic rotation")
                    .font(AppTheme.font(size: 20, weightValue: 650))
                Text("The current account stays active until it reaches your threshold. Builder Nutch then picks the fullest available account in this loop. When none is fuller, each account is used down to 2% before the next takes over, round and round.")
                    .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Switch when remaining quota reaches")
                    Spacer()
                    Text("\(Int(manager.switchThresholdPercent))%")
                        .font(AppTheme.font(size: 12, weightValue: 650)).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { manager.switchThresholdPercent },
                    set: { value in
                        do { try manager.setSwitchThreshold(value) }
                        catch { reportError(error.localizedDescription) }
                    }
                ), in: 0...100, step: 5)
                Text("The change applies to the next session. Sessions already open keep their account.")
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
            }
            .padding(16).background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Switch before the cut")
                    Spacer()
                    Text("\(Int(manager.switchAheadMinutes)) min")
                        .font(AppTheme.font(size: 12, weightValue: 650)).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { manager.switchAheadMinutes },
                    set: { value in
                        do { try manager.setSwitchAheadMinutes(value) }
                        catch { reportError(error.localizedDescription) }
                    }
                ), in: 5...60, step: 5)
                .accessibilityLabel(String(format: NSLocalizedString("Switch %d min before the cut", comment: "Switch-ahead control"),
                                           Int(manager.switchAheadMinutes)))
                Text("Builder Nutch watches how fast the account is being used and moves on this long before it would stop working.")
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 8))

            if let activeProvider {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(activeProvider.workspaceTitle) loop")
                            .font(AppTheme.font(size: 12, weightValue: 600))
                        Spacer()
                        Text("NEXT").font(AppTheme.font(size: 9, weightValue: 550))
                            .tracking(0.7).foregroundStyle(AppTheme.muted)
                    }
                    .padding(.bottom, 10)
                    ForEach(Array(manager.rotationAccounts(for: activeProvider).enumerated()), id: \.element.id) { index, account in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(AppTheme.font(size: 11, weightValue: 600))
                                .foregroundStyle(AppTheme.muted).frame(width: 20)
                            Text(account.emoji ?? String(account.label.prefix(1)).uppercased()).frame(width: 22)
                            Text(account.label).font(AppTheme.font(size: 12, weightValue: 550)).lineLimit(1)
                            Spacer()
                            if manager.isSelected(account) {
                                Label("Next", systemImage: "arrow.right.circle.fill")
                                    .font(AppTheme.font(size: 10, weightValue: 600))
                            } else {
                                Button("Set next") {
                                    do { try manager.setNext(account) }
                                    catch { reportError(error.localizedDescription) }
                                }.buttonStyle(WorkspaceSelectionStyle())
                            }
                            Button { move(account, -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(WorkspaceQuietButtonStyle()).disabled(index == 0)
                                .accessibilityLabel("Move \(account.label) earlier")
                            Button { move(account, 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(WorkspaceQuietButtonStyle())
                                .disabled(index == manager.rotationAccounts(for: activeProvider).count - 1)
                                .accessibilityLabel("Move \(account.label) later")
                        }
                        .frame(minHeight: 48)
                        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                    }
                }
            } else {
                Text("Add at least one Claude Code, Codex, or Kimi Code account to create a loop.")
                    .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
            }

            Spacer(minLength: 0)
            HStack {
                Toggle("Automatic rotation", isOn: $manager.automaticSelection)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()

            }
        }
        .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(WorkspaceSelectionStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }.padding(16).background(AppTheme.surface)
        }
        .frame(width: 560, height: 480)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).tint(AppTheme.ink)
    }

    private func move(_ account: ManagedAccount, _ offset: Int) {
        do { try manager.moveInRotation(account, offset: offset) }
        catch { reportError(error.localizedDescription) }
    }
}

private struct AddAssistantFlow: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: AccountManager
    let reportError: (String) -> Void
    @State private var createdAccountID: UUID?
    @State private var startedInitialConnection = false
    @State private var localError: String?
    private let startsConnectionOnAppear: Bool
    private var account: ManagedAccount? { manager.accounts.first { $0.id == createdAccountID } }

    init(manager: AccountManager, initialAccount: ManagedAccount? = nil,
         reportError: @escaping (String) -> Void) {
        self.manager = manager; self.reportError = reportError
        _createdAccountID = State(initialValue: initialAccount?.id)
        startsConnectionOnAppear = initialAccount != nil
    }

    var body: some View {
        Group {
            if let account {
                let state = manager.state(for: account)
                if state.isConnected {
                    PersonalizeAssistantView(account: account, manager: manager,
                                             completionTitle: "Finish", reportError: reportError)
                } else { connectionStep(account, state) }
            } else { providerStep }
        }
        .frame(width: 560, height: 470).background(AppTheme.surface).foregroundStyle(AppTheme.ink)
        .alert("Couldn't continue", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
        .task {
            guard startsConnectionOnAppear, !startedInitialConnection, let account else { return }
            startedInitialConnection = true
            await manager.connect(account)
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            flowHeader("Add assistant", "Choose a service. Sign in with its official page first; naming comes after.")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    providerGrid("DEVELOPER TOOLS", AccountProvider.allCases.filter { !$0.isBrowserProfile })
                    providerGrid("BROWSER ASSISTANTS", AccountProvider.allCases.filter(\.isBrowserProfile))
                }
                .padding(.horizontal, 28).padding(.bottom, 26)
            }
        }
    }

    private func providerGrid(_ title: String, _ providers: [AccountProvider]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppTheme.font(size: 11, weight: .bold)).tracking(1.15).foregroundStyle(AppTheme.muted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(providers) { provider in
                    Button { createAndConnect(provider) } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9).fill(AppTheme.soft)
                                ProviderGlyphView(glyph: provider.glyph, size: 23)
                            }
                            .frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.title).font(AppTheme.font(.body, weight: .bold)).foregroundStyle(AppTheme.ink)
                                Text(provider.connectionSummary).font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.muted)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.line))
                    }
                    .buttonStyle(.plain).disabled(manager.loginAccountID != nil || createdAccountID != nil)
                    .accessibilityLabel("Add \(provider.title). \(provider.connectionDetail)")
                }
            }
        }
    }

    private func connectionStep(_ account: ManagedAccount, _ state: ManagedAccountState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            flowHeader("Connect \(account.provider.title)", account.provider.connectionDetail)
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Circle().fill(AppTheme.soft); Circle().stroke(AppTheme.line)
                    ProviderGlyphView(glyph: account.provider.glyph, size: 36)
                }
                .frame(width: 76, height: 76)
                Text(state.message ?? "Continue sign-in in the browser window opened by Builder Nutch.")
                    .font(AppTheme.font(.title3, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if account.isBrowserOnly, state.message?.contains("Install Google Chrome") == true {
                    Link("Install Google Chrome", destination: URL(string: "https://www.google.com/chrome/")!)
                        .font(AppTheme.font(.body, weight: .semibold))
                }
                Label("Builder Nutch never asks for or copies your password or tokens.", systemImage: "lock")
                    .font(AppTheme.font(.body)).foregroundStyle(AppTheme.muted)
            }
            .frame(maxWidth: 540, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 28)
            HStack {
                Button("Close") { dismiss() }.buttonStyle(AppButtonStyle())
                Spacer()
                if account.isBrowserOnly {
                    Button("Open sign-in again") { Task { await manager.connect(account) } }
                        .buttonStyle(AppButtonStyle()).disabled(state.isBusy || manager.loginAccountID != nil)
                    Button("I've finished signing in") { confirmBrowser(account) }
                        .buttonStyle(AppButtonStyle(primary: true))
                        .disabled(state.isBusy || !manager.canConfirmBrowserConnection(account))
                } else if state.isBusy {
                    ProgressView().controlSize(.small).tint(AppTheme.ink)
                    Button("Cancel") { manager.cancelLogin() }.buttonStyle(AppButtonStyle())
                } else {
                    Button("Try again") { Task { await manager.connect(account) } }
                        .buttonStyle(AppButtonStyle(primary: true))
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    private func flowHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(AppTheme.font(.title2, weight: .bold)); Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(AppButtonStyle(compact: true)).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
            }
            Text(detail).font(AppTheme.font(.body)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).background { ZStack { AppTheme.paper; AppDotBackground().opacity(0.5) } }
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func createAndConnect(_ provider: AccountProvider) {
        guard manager.loginAccountID == nil, createdAccountID == nil else { return }
        do {
            let count = manager.accounts.filter { $0.provider == provider }.count
            let account = try manager.add(provider: provider,
                                          label: count == 0 ? provider.title : "\(provider.title) \(count + 1)",
                                          emailHint: nil)
            createdAccountID = account.id
            Task { await manager.connect(account) }
        } catch { localError = error.localizedDescription }
    }

    private func confirmBrowser(_ account: ManagedAccount) {
        do { try manager.confirmBrowserConnection(account) }
        catch { localError = error.localizedDescription }
    }
}

private struct PersonalizeAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    let account: ManagedAccount
    @ObservedObject var manager: AccountManager
    var completionTitle = "Save"
    let reportError: (String) -> Void
    @State private var nickname: String
    @State private var selectedEmoji: String?
    @State private var localError: String?
    @FocusState private var nicknameFocused: Bool
    private let emojis = ["⚡️", "🧠", "🛠️", "🚀", "🔬", "🧭", "🎯", "🧪", "💻", "🤖"]

    init(account: ManagedAccount, manager: AccountManager, completionTitle: String = "Save",
         reportError: @escaping (String) -> Void) {
        self.account = account; self.manager = manager; self.completionTitle = completionTitle
        self.reportError = reportError
        let suffix = account.label.dropFirst(account.provider.title.count).trimmingCharacters(in: .whitespaces)
        _nickname = State(initialValue: account.label == account.provider.title || Int(suffix) != nil ? "" : account.label)
        _selectedEmoji = State(initialValue: account.emoji)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Make it yours").font(AppTheme.font(.title2, weight: .bold)); Spacer()
                    ProviderGlyphView(glyph: account.provider.glyph, size: 24)
                }
                Text(detail).font(AppTheme.font(.body)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28).background { ZStack { AppTheme.paper; AppDotBackground().opacity(0.5) } }
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("NICKNAME")
                    TextField("Optional — e.g. Work or Personal", text: $nickname)
                        .textFieldStyle(.roundedBorder).focused($nicknameFocused).font(AppTheme.font(.body))
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("EMOJI")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)], spacing: 8) {
                        emojiButton(nil, "None")
                        ForEach(emojis, id: \.self) { emojiButton($0, $0) }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 22)
            Spacer()
            HStack {
                Text("Sign-in and account identity stay unchanged.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                Spacer()
                Button(completionTitle == "Finish" ? "Skip" : "Cancel") { dismiss() }
                    .buttonStyle(AppButtonStyle())
                Button(completionTitle, action: save).buttonStyle(AppButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(28)
        }
        .frame(width: 620, height: 390).background(AppTheme.surface).foregroundStyle(AppTheme.ink)
        .onAppear { nicknameFocused = true }
        .alert("Couldn't save", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(AppTheme.font(size: 11, weight: .bold)).tracking(1.1).foregroundStyle(AppTheme.muted)
    }

    private func emojiButton(_ emoji: String?, _ title: String) -> some View {
        let active = selectedEmoji == emoji
        return Button { selectedEmoji = emoji } label: {
            Text(title).font(emoji == nil ? AppTheme.font(.caption, weight: .semibold) : .system(size: 20))
                .foregroundStyle(active ? AppTheme.surface : AppTheme.ink).frame(minWidth: 38, minHeight: 34)
                .background(active ? AppTheme.ink : AppTheme.soft, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? AppTheme.ink : AppTheme.line))
        }
        .buttonStyle(.plain).accessibilityLabel(emoji == nil ? "No emoji" : "Use \(emoji!)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func save() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try manager.personalize(account, label: trimmed.isEmpty ? account.label : trimmed, emoji: selectedEmoji)
            dismiss()
        } catch { localError = error.localizedDescription }
    }

    private var detail: String {
        let connected = manager.state(for: account).isConnected
        let prefix: String
        if account.isBrowserOnly && connected { prefix = "Browser profile ready for \(account.provider.title)." }
        else if connected { prefix = "Connected to \(account.provider.title)." }
        else { prefix = "Customize this \(account.provider.title) account." }
        return prefix + " A nickname and emoji are optional and only help you recognise it."
    }
}
