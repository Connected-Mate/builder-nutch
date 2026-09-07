import AppKit
import SwiftUI

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
    @AppStorage("accounts.projectFolder") private var savedProjectPath = ""

    init(manager: AccountManager, onOpenSettings: (() -> Void)? = nil) {
        self.manager = manager
        self.onOpenSettings = onOpenSettings
        let saved = UserDefaults.standard.string(forKey: "accounts.projectFolder") ?? ""
        _projectURL = State(initialValue: URL(fileURLWithPath: saved.isEmpty ? NSHomeDirectory() : saved,
                                               isDirectory: true))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if manager.loginAccountID != nil { loginBanner }
                if let notice = manager.notice { noticeBanner(notice) }
                assistantList
                sessionBar
            }
            .background(AppTheme.surface)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(AppTheme.paper)
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.ink)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingAdd) {
            AddAssistantFlow(manager: manager) { localError = $0 }.preferredColorScheme(.light)
        }
        .sheet(item: $connecting) { account in
            AddAssistantFlow(manager: manager, initialAccount: account) { localError = $0 }
                .preferredColorScheme(.light)
        }
        .sheet(item: $personalizing) { account in
            PersonalizeAssistantView(account: account, manager: manager) { localError = $0 }
                .preferredColorScheme(.light)
        }
        .confirmationDialog(
            "Remove \(removing?.label ?? "assistant")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { account in
            Button("Remove from Builder Nutch", role: .destructive) {
                do { try manager.remove(account) } catch { localError = error.localizedDescription }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { account in
            Text("This removes \(account.label) from the list. The official service keeps its saved sign-in.")
        }
        .alert("Builder Nutch", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
        .onChange(of: providerIDs) { _ in
            if let filter, !providers.contains(filter) { self.filter = nil }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BUILDER NUTCH").font(AppTheme.font(size: 12, weight: .bold)).tracking(1.4)
                Text("Your assistants").font(AppTheme.font(.title2, weight: .bold))
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
            ScrollView {
                VStack(spacing: 5) {
                    filterButton(nil)
                    ForEach(providers) { filterButton($0) }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: .infinity)
            Button {
                guard manager.loginAccountID == nil else { return }
                showingAdd = true
            } label: {
                Label("Add assistant", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(primary: true))
            .disabled(manager.loginAccountID != nil)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 16).padding(.top, 18)
            VStack(alignment: .leading, spacing: 6) {
                Label("Private by design", systemImage: "lock")
                    .font(AppTheme.font(.callout, weight: .semibold))
                Text("Passwords and tokens stay with each official service.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 228)
        .background(AppTheme.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.line).frame(width: 1) }
    }

    private func filterButton(_ provider: AccountProvider?) -> some View {
        let active = filter == provider
        let count = provider.map { candidate in manager.accounts.filter { $0.provider == candidate }.count }
            ?? manager.accounts.count
        return Button { filter = provider } label: {
            HStack(spacing: 10) {
                if let provider {
                    ProviderGlyphView(glyph: provider.glyph, size: 17).frame(width: 22, height: 22)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium)).frame(width: 22, height: 22)
                }
                Text(provider?.title ?? "All assistants")
                    .font(AppTheme.font(.body, weight: active ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)").font(AppTheme.font(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 10).frame(height: 38)
            .background(active ? AppTheme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider?.title ?? "All assistants"), \(count) account\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if let filter { ProviderGlyphView(glyph: filter.glyph, size: 24).accessibilityHidden(true) }
                    Text(filter?.title ?? "All assistants").font(AppTheme.font(.largeTitle, weight: .bold))
                }
                Text(visibleAccounts.isEmpty ? "No accounts here yet." :
                        "\(visibleAccounts.count) account\(visibleAccounts.count == 1 ? "" : "s") for your next build.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 24)
            Button { Task { await manager.refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AppButtonStyle(compact: true))
            .disabled(manager.accounts.isEmpty || !manager.busyIDs.isEmpty)
            .keyboardShortcut("r", modifiers: .command)
            if let onOpenSettings {
                Button(action: onOpenSettings) { Image(systemName: "gearshape").frame(width: 18, height: 18) }
                    .buttonStyle(AppButtonStyle(compact: true))
                    .help("Appearance and app settings")
                    .accessibilityLabel("Open Builder Nutch settings")
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 21)
        .background { ZStack { AppTheme.paper; AppDotBackground().opacity(0.55) } }
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    @ViewBuilder private var assistantList: some View {
        if manager.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    Circle().fill(AppTheme.soft)
                    Image(systemName: "plus").font(.system(size: 26, weight: .medium))
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Put your AI subscriptions to work").font(AppTheme.font(.title2, weight: .bold))
                    Text("Add an assistant, sign in with its official service, then add a nickname or emoji if you want.")
                        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 540, alignment: .leading)
                }
                Button { showingAdd = true } label: { Label("Add your first assistant", systemImage: "plus") }
                    .buttonStyle(AppButtonStyle(primary: true)).disabled(manager.loginAccountID != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(48)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("USAGE").frame(width: 200, alignment: .leading)
                    Text("ACTIONS").frame(width: 180, alignment: .trailing)
                }
                .font(AppTheme.font(size: 11, weight: .bold)).tracking(1.15).foregroundStyle(AppTheme.muted)
                .padding(.horizontal, 28).frame(height: 38).background(AppTheme.paper)
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
                            if account.id != visibleAccounts.last?.id {
                                Rectangle().fill(AppTheme.line).frame(height: 1).padding(.leading, 94)
                            }
                        }
                    }
                }
                .background(AppTheme.surface)
            }
        }
    }

    private var loginBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(AppTheme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for official sign-in").font(AppTheme.font(.callout, weight: .semibold))
                Text("Finish in the browser window. Builder Nutch never asks for your password or token.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
            }
            Spacer()
            Button("Cancel") { manager.cancelLogin() }.buttonStyle(AppButtonStyle(compact: true))
        }
        .padding(.horizontal, 28).padding(.vertical, 12).background(AppTheme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
            Text(notice).font(AppTheme.font(.callout)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppTheme.muted).padding(.horizontal, 28).padding(.vertical, 10)
        .background(AppTheme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private var sessionBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PROJECT FOLDER").font(AppTheme.font(size: 11, weight: .bold)).tracking(1)
                Text(projectURL.path(percentEncoded: false)).font(AppTheme.font(.callout))
                    .foregroundStyle(AppTheme.muted).lineLimit(1).truncationMode(.middle)
                    .help(projectURL.path(percentEncoded: false))
            }
            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            Button("Choose…", action: chooseProjectFolder).buttonStyle(AppButtonStyle(compact: true))
            Rectangle().fill(AppTheme.line).frame(width: 1, height: 42)
            Toggle(isOn: $manager.automaticSelection) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose the best account automatically").font(AppTheme.font(.callout, weight: .semibold))
                    Text("Uses fresh verified limits for future sessions. Web profiles are excluded.")
                        .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                }
            }
            .toggleStyle(.switch).tint(AppTheme.ink).frame(maxWidth: 405, alignment: .leading)
            .disabled(!manager.accounts.contains { $0.provider.supportsAutomaticSelection })
        }
        .padding(.horizontal, 28).padding(.vertical, 15).background(AppTheme.paper)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"; panel.prompt = "Choose"; panel.directoryURL = projectURL
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url; savedProjectPath = url.path(percentEncoded: false)
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

    var body: some View {
        HStack(spacing: 18) {
            identityMark
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(account.label).font(AppTheme.font(.body, weight: .bold)).lineLimit(1)
                    if isSelected, state.isConnected, account.provider.supportsAutomaticSelection {
                        Text("NEXT").font(AppTheme.font(size: 10, weight: .bold)).tracking(0.8)
                            .foregroundStyle(AppTheme.surface).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(AppTheme.ink, in: Capsule())
                            .accessibilityLabel("Selected for the next session")
                    }
                }
                HStack(spacing: 6) {
                    ProviderGlyphView(glyph: account.provider.glyph, size: 13).accessibilityHidden(true)
                    Text(account.provider.title)
                    if let email = state.email ?? account.emailHint, !email.isEmpty { Text("·"); Text(email).lineLimit(1) }
                }
                .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                statusLine.font(AppTheme.font(.callout))
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            usageSummary.frame(width: 200, alignment: .leading)
            actions.frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, 28).padding(.vertical, 16).contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.label), \(account.provider.title), \(statusDescription)")
    }

    private var identityMark: some View {
        ZStack {
            Circle().stroke(AppTheme.line, lineWidth: 4).background(Circle().fill(AppTheme.surface))
            if let remaining = state.remainingPercent, !account.provider.isBrowserProfile {
                Circle().trim(from: 0, to: min(max(remaining / 100, 0), 1))
                    .stroke(AppTheme.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let emoji = account.emoji, !emoji.isEmpty { Text(emoji).font(.system(size: 23)) }
            else { ProviderGlyphView(glyph: account.provider.glyph, size: 20)
                    .foregroundStyle(state.isConnected ? AppTheme.ink : AppTheme.muted) }
        }
        .frame(width: 48, height: 48).accessibilityHidden(true)
    }

    private var awaitingFirstUsage: Bool {
        account.provider == .claude && state.needsFirstUsage
            && state.message == "Usage appears after the first Claude Code session launched here."
    }

    @ViewBuilder private var statusLine: some View {
        if isLoginPending {
            Label("Sign-in in progress", systemImage: "clock").foregroundStyle(AppTheme.ink)
        } else if state.isBusy {
            Label("Checking…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(AppTheme.muted)
        } else if !state.isConnected {
            Label(state.message ?? "Not connected", systemImage: state.message == nil ? "circle" : "exclamationmark.circle")
                .foregroundStyle(AppTheme.muted).lineLimit(2)
        } else if awaitingFirstUsage {
            Label("Usage appears after your first session", systemImage: "info.circle").foregroundStyle(AppTheme.muted)
        } else if let message = state.message {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.muted).lineLimit(2)
        } else {
            Label(account.provider.isBrowserProfile ? "Browser ready" : "Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.ink)
        }
    }

    @ViewBuilder private var usageSummary: some View {
        if account.provider.isBrowserProfile {
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser profile").font(AppTheme.font(.callout, weight: .semibold))
                Text("Usage stays on \(account.provider.title)’s website.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
            }
        } else if awaitingFirstUsage {
            Text("No usage yet").font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
        } else if state.windows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage unavailable").font(AppTheme.font(.callout, weight: .semibold))
                Text(state.isConnected ? "Refresh to check available limits." : "Connect to read official limits.")
                    .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(state.windows.prefix(2)) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(window.label).lineLimit(1); Spacer(minLength: 8)
                            Text(window.summary).monospacedDigit().lineLimit(1)
                        }
                        .font(AppTheme.font(.caption))
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.muted)
                        }
                    }
                }
                if let refreshedAt = state.refreshedAt {
                    Text(state.isFresh() ? "Updated \(refreshedAt.formatted(.relative(presentation: .named)))"
                         : "Stale · Updated \(refreshedAt.formatted(.relative(presentation: .named)))")
                        .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.muted)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !state.isConnected {
                Button("Connect", action: connect).buttonStyle(AppButtonStyle(primary: true, compact: true))
                    .disabled(state.isBusy || loginInProgress)
            } else if account.provider.supportsAutomaticSelection && !isSelected {
                Button("Use next", action: selectAccount).buttonStyle(AppButtonStyle(compact: true))
            }
            if state.isConnected {
                Button(account.provider.isBrowserProfile ? "Open" : "Launch") {
                    Task { await manager.launch(account, project: projectURL) }
                }
                .buttonStyle(AppButtonStyle(primary: true, compact: true)).disabled(state.isBusy)
                .help(account.provider.isBrowserProfile ? "Open this separate \(account.provider.title) browser profile"
                      : "Start a new \(account.provider.title) session in the project folder")
            }
            Menu {
                if !account.provider.isBrowserProfile {
                    Button("Refresh usage") { Task { await manager.refresh(account) } }.disabled(state.isBusy)
                }
                Button("Nickname & emoji…", action: personalize).disabled(state.isBusy || isLoginPending)
                Divider()
                Button("Remove…", role: .destructive, action: remove).disabled(state.isBusy || isLoginPending)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24).accessibilityLabel("More actions for \(account.label)")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func selectAccount() {
        do { try manager.select(account) } catch { reportError(error.localizedDescription) }
    }
    private var statusDescription: String {
        if isLoginPending { return "sign-in in progress" }
        if state.isBusy { return "checking" }
        if !state.isConnected { return state.message ?? "not connected" }
        return account.provider.isBrowserProfile ? "browser ready" : "connected"
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
