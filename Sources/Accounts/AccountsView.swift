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

/// The native account manager. Public screenshots are captured from this live view.
struct AccountsView: View {
    @ObservedObject var manager: AccountManager
    let onOpenSettings: (() -> Void)?
    @State private var filter: AccountProvider?
    @State private var showingAdd = false
    @State private var connecting: ManagedAccount?
    @State private var personalizing: ManagedAccount?
    @State private var removing: ManagedAccount?
    @State private var localError: String?
    @State private var projectURL: URL
    @AppStorage("accounts.hidePersonalDetails") private var hidePersonalDetails = false
    @AppStorage("accounts.projectFolder") private var savedProjectPath = ""

    init(manager: AccountManager, onOpenSettings: (() -> Void)? = nil, projectFolder: URL? = nil) {
        self.manager = manager
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
                if manager.loginAccountID != nil { loginBanner }
                if let notice = manager.notice, !hidePersonalDetails { noticeBanner(notice) }
                if let discovery = manager.discoveryNotice {
                    Label(discovery, systemImage: "checkmark.circle")
                        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30).padding(.vertical, 10).background(AppTheme.paper)
                }
                if showingAdd {
                    providerCatalog
                } else {
                    assistantList
                    if !manager.accounts.isEmpty { automaticSelectionBar }
                    nextSessionBar
                }
            }
            .background(AppTheme.surface)
        }
        .frame(minWidth: 980, minHeight: 560)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).tint(AppTheme.ink)
        .preferredColorScheme(.light)
        .sheet(item: $connecting) { account in
            AddAssistantFlow(manager: manager, initialAccount: account) { localError = $0 }
                .preferredColorScheme(.light)
        }
        .sheet(item: $personalizing) { account in
            PersonalizeAssistantView(account: account, manager: manager) { localError = $0 }
                .preferredColorScheme(.light)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your assistants")
                Spacer()
                Text("\(providers.count)")
            }
            .font(AppTheme.font(size: 11, weightValue: 500)).foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 27).padding(.top, 26).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(providers) { filterButton($0) }
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add assistant", systemImage: "plus")
                            .font(AppTheme.font(size: 12))
                            .foregroundStyle(AppTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle()).padding(.top, 7)
                    .disabled(manager.loginAccountID != nil)
                    .keyboardShortcut("n", modifiers: .command)
                }
                .padding(.horizontal, 15)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: chooseProjectFolder) {
                    Label(hidePersonalDetails || projectURL.lastPathComponent.isEmpty ? "Project folder" : projectURL.lastPathComponent,
                          systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
                .buttonStyle(WorkspaceQuietButtonStyle())
                .help(hidePersonalDetails ? "Choose project folder" : "Project folder: \(projectURL.path(percentEncoded: false))")
                .accessibilityLabel("Choose project folder")
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Label("Settings", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle())
                    .keyboardShortcut(",", modifiers: .command)
                }
                SupportLink()
                    .buttonStyle(WorkspaceQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                Label("On your Mac. In your control.", systemImage: "checkmark.shield")
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                    .padding(.top, 20).padding(.bottom, 20)
            }
            .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 21)
        }
        .frame(width: 222).background(AppTheme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.line).frame(width: 1) }
    }

    private func filterButton(_ provider: AccountProvider) -> some View {
        let active = filter == provider && !showingAdd
        let count = manager.accounts.filter { $0.provider == provider }.count
        return Button { filter = provider; showingAdd = false } label: {
            HStack(spacing: 12) {
                ProviderGlyphView(glyph: provider.glyph, size: 24).frame(width: 24, height: 24)
                Text(provider.workspaceTitle)
                    .font(AppTheme.font(size: 13, weightValue: active ? 600 : 400)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(active ? AppTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? AppTheme.line : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceQuietButtonStyle())
        .accessibilityLabel("\(provider.workspaceTitle), \(count) account\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if !showingAdd, let filter {
                        ProviderGlyphView(glyph: filter.glyph, size: 25).accessibilityHidden(true)
                    }
                    Text(showingAdd ? "Add an assistant" : filter?.workspaceTitle ?? "All accounts")
                        .font(AppTheme.font(size: 19, weightValue: 650)).tracking(-0.55)
                }
                Text(showingAdd ? "Choose a service. Sign in on its official page." :
                        visibleAccounts.isEmpty ? "Your next idea starts with an assistant." :
                        "Your accounts. For your next session.")
                    .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 12)
            Button { hidePersonalDetails.toggle() } label: {
                Image(systemName: hidePersonalDetails ? "eye.slash" : "eye")
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(WorkspaceQuietButtonStyle())
            .help(hidePersonalDetails ? "Show personal details" : "Hide personal details")
            .accessibilityLabel(hidePersonalDetails ? "Show personal details" : "Hide personal details")
            if showingAdd {
                Button("Back") { showingAdd = false }.buttonStyle(WorkspaceSelectionStyle())
            } else {
                Text("\(visibleAccounts.count) account\(visibleAccounts.count == 1 ? "" : "s")")
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.line))
                Button { Task { await manager.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 32)
                }
                .buttonStyle(WorkspaceQuietButtonStyle()).help("Refresh accounts")
                .accessibilityLabel("Refresh accounts")
                .disabled(manager.accounts.isEmpty || !manager.busyIDs.isEmpty)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 23)
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
                    Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("REMAINING").frame(width: 110)
                    Text("NEXT SESSION").frame(width: 110)
                }
                .font(AppTheme.font(size: 9, weightValue: 500)).tracking(0.8).foregroundStyle(AppTheme.muted)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleAccounts) { account in
                            AssistantRow(account: account, state: manager.state(for: account),
                                         isSelected: manager.isSelected(account),
                                         isLoginPending: manager.loginAccountID == account.id,
                                         loginInProgress: manager.loginAccountID != nil,
                                         projectURL: projectURL, manager: manager,
                                         connect: { connecting = account },
                                         personalize: { personalizing = account },
                                         remove: { removing = account },
                                         reportError: { localError = $0 })
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
        }
    }

    private var providerCatalog: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 0) {
                ForEach(AccountProvider.allCases) { provider in
                    Button { createAndConnect(provider) } label: {
                        HStack(spacing: 12) {
                            ProviderGlyphView(glyph: provider.glyph, size: 24).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.workspaceTitle).font(AppTheme.font(size: 13, weightValue: 550))
                                Text(provider.connectionSummary).font(AppTheme.font(size: 11))
                                    .foregroundStyle(AppTheme.muted).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.right").font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(WorkspaceQuietButtonStyle()).disabled(manager.loginAccountID != nil)
                    .accessibilityLabel("Add \(provider.workspaceTitle). \(provider.connectionDetail)")
                }
            }
            Text("Choose your service, complete its official sign-in, then add a nickname or emoji.")
                .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
        }
        .padding(.horizontal, 30)
    }

    private func createAndConnect(_ provider: AccountProvider) {
        guard manager.loginAccountID == nil else { return }
        do {
            let count = manager.accounts.filter { $0.provider == provider }.count
            let account = try manager.add(provider: provider,
                                          label: count == 0 ? provider.title : "\(provider.title) \(count + 1)",
                                          emailHint: nil)
            filter = provider; showingAdd = false; connecting = account
        } catch { localError = error.localizedDescription }
    }

    private var automaticSelectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Put available quota to work.").font(AppTheme.font(size: 11, weightValue: 550))
                Text("Choose the account with the most room for the next session.")
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 12)
            Toggle("Auto-select", isOn: $manager.automaticSelection)
                .font(AppTheme.font(size: 11)).toggleStyle(.switch).controlSize(.small)
                .disabled(!manager.accounts.contains { $0.provider.supportsAutomaticSelection })
                .help("New coding sessions use fresh, verified quota. Browser profiles are excluded.")
        }
        .padding(.vertical, 18).padding(.horizontal, 30)
    }

    private var nextSessionBar: some View {
        HStack(spacing: 6) {
            Circle().fill(AppTheme.ink).frame(width: 4, height: 4).accessibilityHidden(true)
            if let selectedAccount {
                Text(selectedAccount.provider.isBrowserProfile ? "Selected profile:" :
                        "Next \(selectedAccount.provider.workspaceTitle) session:")
                Text(displayName(for: selectedAccount)).font(AppTheme.font(size: 10, weightValue: 600)).lineLimit(1)
                if manager.automaticSelection && selectedAccount.provider.supportsAutomaticSelection {
                    Text("· Auto-select on").foregroundStyle(AppTheme.muted)
                        .help("At launch, a different eligible account may be chosen using fresh verified quota.")
                }
                Spacer(minLength: 8)
                Button(selectedAccount.provider.isBrowserProfile ? "Open profile" : "Launch session") {
                    Task { await manager.launch(selectedAccount, project: projectURL) }
                }
                .buttonStyle(WorkspaceSelectionStyle(primary: true))
                .disabled(!manager.state(for: selectedAccount).isConnected || manager.state(for: selectedAccount).isBusy)
            } else {
                Text("Choose an assistant to prepare your next session.")
                Spacer()
            }
        }
        .font(AppTheme.font(size: 10))
        .padding(.horizontal, 30).padding(.vertical, 10).frame(minHeight: 48)
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
        .padding(.horizontal, 30).padding(.vertical, 10).background(AppTheme.soft)
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
        .padding(.horizontal, 30).padding(.vertical, 10).background(AppTheme.paper)
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

private struct AssistantRow: View {
    let account: ManagedAccount
    let state: ManagedAccountState
    let isSelected: Bool
    let isLoginPending: Bool
    let loginInProgress: Bool
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
                    Text(displayLabel).font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                        .help(displayLabel)
                    if let email = state.email ?? account.emailHint, !email.isEmpty {
                        Text(hidePersonalDetails ? "Personal details hidden" : email).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                            .lineLimit(1).truncationMode(.middle).help(hidePersonalDetails ? "Personal details hidden" : email)
                    }
                    Text(statusDescription).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .lineLimit(1).help(statusDescription)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Usage details") { showingUsage = true }
                    if state.isConnected {
                        Button(account.provider.isBrowserProfile ? "Open profile" : "Launch session") {
                            Task { await manager.launch(account, project: projectURL) }
                        }.disabled(state.isBusy)
                    }
                    if !account.provider.isBrowserProfile {
                        Button("Refresh usage") { Task { await manager.refresh(account) } }.disabled(state.isBusy)
                    }
                    Button(hidePersonalDetails ? "Show personal details to edit nickname…" : "Nickname & emoji…", action: personalize)
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
            Button { showingUsage = true } label: { quotaRing }
                .buttonStyle(.plain).frame(width: 110)
                .accessibilityLabel("Usage details for \(displayLabel): \(quotaDescription)")
                .popover(isPresented: $showingUsage) { usageDetails }
            selectionControl.frame(width: 110)
        }
        .padding(.vertical, 8).frame(minHeight: 76)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayLabel), \(account.provider.workspaceTitle), \(statusDescription)")
    }

    private var quotaDescription: String {
        if account.provider.isBrowserProfile { return "Check usage on the official website" }
        guard let remaining = state.remainingPercent, state.isConnected else { return "Usage unavailable" }
        return "\(Int(remaining.rounded())) percent remaining\(state.isFresh() ? "" : ", last known; refresh needed")"
    }

    private var quotaRing: some View {
        ZStack {
            Circle().stroke(AppTheme.track, lineWidth: 3)
            if let remaining = state.remainingPercent, state.isConnected, !account.provider.isBrowserProfile {
                Circle().trim(from: 0, to: min(max(remaining / 100, 0), 1))
                    .stroke(AppTheme.ink.opacity(state.isFresh() ? 1 : 0.45),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(remaining.rounded()))").font(AppTheme.font(size: 11, weightValue: 600))
                    Text("%").font(AppTheme.font(size: 8, weightValue: 450))
                }
            } else {
                Text("—").font(AppTheme.font(size: 13)).foregroundStyle(AppTheme.muted)
            }
        }
        .frame(width: 43, height: 43).padding(6).help(quotaDescription)
    }

    @ViewBuilder private var selectionControl: some View {
        if !state.isConnected {
            Button(isLoginPending ? "Signing in…" : "Connect", action: connect)
                .buttonStyle(WorkspaceSelectionStyle()).disabled(state.isBusy || loginInProgress)
        } else {
            Button {
                do { try manager.select(account) } catch { reportError(error.localizedDescription) }
            } label: {
                HStack(spacing: 5) {
                    if isSelected { Image(systemName: "checkmark") }
                    Text(isSelected ? "Selected" : "Use account")
                    if !isSelected { Image(systemName: "arrow.right") }
                }
                .frame(width: 86)
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
        if account.provider.isBrowserProfile { return "Browser profile ready" }
        if let message = state.message {
            if account.provider == .claude && state.needsFirstUsage &&
                message == "Usage appears after the first Claude Code session launched here." {
                return "Usage appears after your first session"
            }
            return message
        }
        if !state.windows.isEmpty && !state.isFresh() { return "Last known usage · refresh to update" }
        if let limit = state.windows.filter({ $0.usedFraction != nil }).max(by: {
            ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0)
        }), let reset = limit.resetsAt {
            return "\(limit.label) · Resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return "Connected"
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(displayLabel) · Usage").font(AppTheme.font(size: 16, weightValue: 650))
            if account.provider.isBrowserProfile {
                Text("Usage stays on \(account.provider.title)’s website.")
            } else if state.windows.isEmpty {
                Text(statusDescription)
            } else {
                ForEach(state.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(window.label).font(AppTheme.font(size: 12, weightValue: 600))
                        Text(window.summary).monospacedDigit()
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                }
                if let date = state.refreshedAt {
                    Text("\(state.isFresh() ? "Updated" : "Last known") \(date.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(AppTheme.muted)
                }
                if let message = state.message { Text(message).foregroundStyle(AppTheme.muted) }
            }
        }
        .font(AppTheme.font(size: 12)).padding(24).frame(width: 340, alignment: .leading)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).preferredColorScheme(.light)
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
        .frame(width: 720, height: 570).background(AppTheme.surface).foregroundStyle(AppTheme.ink)
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
                if account.provider.isBrowserProfile, state.message?.contains("Install Google Chrome") == true {
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
                if account.provider.isBrowserProfile {
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
        if account.provider.isBrowserProfile && connected { prefix = "Browser profile ready for \(account.provider.title)." }
        else if connected { prefix = "Connected to \(account.provider.title)." }
        else { prefix = "Customize this \(account.provider.title) account." }
        return prefix + " A nickname and emoji are optional and only help you recognise it."
    }
}
