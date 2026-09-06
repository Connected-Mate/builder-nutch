import AppKit
import SwiftUI

struct AccountsView: View {
    @ObservedObject var manager: AccountManager
    let onOpenSettings: (() -> Void)?
    @State private var showingAddAssistant = false
    @State private var connectingAccount: ManagedAccount?
    @State private var personalizingAccount: ManagedAccount?
    @State private var removingAccount: ManagedAccount?
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
        VStack(spacing: 0) {
            header
            if manager.loginAccountID != nil { loginBanner }
            if let notice = manager.notice { noticeBanner(notice) }
            Divider().overlay(Palette.ringTrack)
            assistantList
            Divider().overlay(Palette.ringTrack)
            sessionBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Palette.notch)
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.ample)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingAddAssistant) {
            AddAssistantFlow(manager: manager) { localError = $0 }
                .preferredColorScheme(.dark).tint(Palette.ample)
        }
        .sheet(item: $connectingAccount) { account in
            AddAssistantFlow(manager: manager, initialAccount: account) { localError = $0 }
                .preferredColorScheme(.dark).tint(Palette.ample)
        }
        .sheet(item: $personalizingAccount) { account in
            PersonalizeAssistantView(account: account, manager: manager) { localError = $0 }
                .preferredColorScheme(.dark).tint(Palette.ample)
        }
        .confirmationDialog(
            "Remove \(removingAccount?.label ?? "assistant")?",
            isPresented: Binding(get: { removingAccount != nil },
                                 set: { if !$0 { removingAccount = nil } }),
            titleVisibility: .visible, presenting: removingAccount
        ) { account in
            Button("Remove from Builder Nutch", role: .destructive) {
                do { try manager.remove(account) } catch { localError = error.localizedDescription }
                removingAccount = nil
            }
            Button("Cancel", role: .cancel) { removingAccount = nil }
        } message: { account in
            Text("This removes \(account.label) from the list. The official service keeps its saved sign-in.")
        }
        .alert("Builder Nutch", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistants").font(.largeTitle.weight(.bold))
                Text("Your AI accounts, one focused place for the next build.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 24)
            Button { Task { await manager.refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(manager.accounts.isEmpty || !manager.busyIDs.isEmpty)
            .keyboardShortcut("r", modifiers: .command)
            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .help("Appearance and app settings")
                .accessibilityLabel("Open Builder Nutch settings")
                .keyboardShortcut(",", modifiers: .command)
            }
            Button { showingAddAssistant = true } label: {
                Label("Add assistant", systemImage: "plus").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            .disabled(manager.loginAccountID != nil)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }

    @ViewBuilder private var assistantList: some View {
        if manager.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(Palette.ample)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Put your AI subscriptions to work").font(.title2.weight(.bold))
                    Text("Add Claude, Codex, Cursor or another assistant. Sign-in happens with the official service, then you can give the account a nickname and emoji.")
                        .font(.body).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
                }
                Button { showingAddAssistant = true } label: {
                    Label("Add your first assistant", systemImage: "plus").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
                .disabled(manager.loginAccountID != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(48)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manager.accounts) { account in
                        AssistantRow(account: account, state: manager.state(for: account),
                                     isSelected: manager.isSelected(account),
                                     isLoginPending: manager.loginAccountID == account.id,
                                     loginInProgress: manager.loginAccountID != nil,
                                     projectURL: projectURL, manager: manager,
                                     connect: { connectingAccount = account },
                                     personalize: { personalizingAccount = account },
                                     remove: { removingAccount = account },
                                     reportError: { localError = $0 })
                        if account.id != manager.accounts.last?.id {
                            Divider().overlay(Palette.ringTrack).padding(.leading, 92)
                        }
                    }
                }.padding(.vertical, 8)
            }.background(Palette.card)
        }
    }

    private var loginBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Palette.ample)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for official sign-in").font(.callout.weight(.semibold))
                Text("Finish in the browser window. Builder Nutch never asks for your password or token.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Cancel") { manager.cancelLogin() }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 28).padding(.vertical, 12).background(Palette.ample.opacity(0.08))
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.ample)
            Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 10).background(Palette.ringTrack.opacity(0.45))
    }

    private var sessionBar: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Project folder").font(.callout.weight(.semibold))
                Text(projectURL.path(percentEncoded: false)).font(.callout)
                    .foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    .help(projectURL.path(percentEncoded: false))
            }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            Button("Choose…", action: chooseProjectFolder).buttonStyle(.bordered)
            Divider().frame(height: 42).overlay(Palette.ringTrack)
            Toggle(isOn: $manager.automaticSelection) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose the best account automatically").font(.callout.weight(.semibold))
                    Text("Only assistants with fresh, verified limits qualify. Browser-only profiles are never guessed.")
                        .font(.callout).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).frame(maxWidth: 430, alignment: .leading)
                .disabled(!manager.accounts.contains { $0.provider.supportsAutomaticSelection })
        }
        .padding(.horizontal, 28).padding(.vertical, 16).background(Palette.card)
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
        HStack(alignment: .center, spacing: 18) {
            identityMark
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(account.label).font(.body.weight(.bold)).lineLimit(1)
                    if isSelected, state.isConnected, account.provider.supportsAutomaticSelection {
                        Text("NEXT").font(.caption2.weight(.black)).foregroundStyle(.black)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Palette.ample, in: Capsule())
                            .accessibilityLabel("Selected for the next session")
                    }
                }
                HStack(spacing: 6) {
                    ProviderGlyphView(glyph: account.provider.glyph, size: 13).accessibilityHidden(true)
                    Text(account.provider.title)
                    if let email = state.email ?? account.emailHint, !email.isEmpty { Text("·"); Text(email).lineLimit(1) }
                }.font(.callout).foregroundStyle(Palette.textSecondary)
                statusLine
            }.frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            usageSummary.frame(minWidth: 190, idealWidth: 260, maxWidth: 300, alignment: .leading)
            actions
        }
        .padding(.horizontal, 28).padding(.vertical, 16).contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.label), \(account.provider.title), \(statusDescription)")
    }

    private var identityMark: some View {
        ZStack {
            Circle().stroke(Palette.ringTrack, lineWidth: 4).background(Circle().fill(Palette.card))
            if let remaining = state.remainingPercent, !account.provider.isBrowserProfile {
                Circle()
                    .trim(from: 0, to: min(max(remaining / 100, 0), 1))
                    .stroke(quotaColor(remaining), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let emoji = account.emoji, !emoji.isEmpty { Text(emoji).font(.system(size: 23)) }
            else { ProviderGlyphView(glyph: account.provider.glyph, size: 20)
                    .foregroundStyle(state.isConnected ? Palette.ample : Palette.textSecondary) }
        }.frame(width: 48, height: 48).accessibilityHidden(true)
    }

    private var awaitingClaudeUsage: Bool {
        account.provider == .claude && state.needsFirstUsage
            && state.message == "Usage appears after the first Claude Code session launched here."
    }

    @ViewBuilder private var statusLine: some View {
        if isLoginPending { Label("Sign-in in progress", systemImage: "clock").foregroundStyle(Palette.watch) }
        else if state.isBusy { Label("Checking…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Palette.textSecondary) }
        else if !state.isConnected {
            Label(state.message ?? "Not connected", systemImage: "circle")
                .foregroundStyle(state.message == nil ? Palette.textSecondary : Palette.watch).lineLimit(2)
        } else if awaitingClaudeUsage {
            Label("Usage appears after your first session", systemImage: "info.circle")
                .foregroundStyle(Palette.textSecondary)
        } else if let message = state.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.watch).lineLimit(2)
        } else {
            Label(account.provider.isBrowserProfile ? "Browser ready" : "Connected",
                  systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ample)
        }
    }

    @ViewBuilder private var usageSummary: some View {
        if account.provider.isBrowserProfile {
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser profile").font(.callout.weight(.semibold))
                Text(account.provider.connectionDetail).font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if awaitingClaudeUsage {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        } else if state.windows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage unavailable").font(.callout.weight(.semibold))
                Text(state.isConnected ? "Refresh to check the service’s available limits." : "Connect to read official limits.")
                    .font(.callout).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(state.windows.prefix(2)) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(window.label).lineLimit(1); Spacer(minLength: 8)
                            Text(window.summary).monospacedDigit().lineLimit(1)
                        }.font(.caption)
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                if let refreshedAt = state.refreshedAt {
                    Text(state.isFresh() ? "Updated \(refreshedAt.formatted(.relative(presentation: .named)))"
                         : "Stale · Updated \(refreshedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(state.isFresh() ? Palette.textSecondary : Palette.watch)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !state.isConnected {
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(state.isBusy || loginInProgress)
            } else if account.provider.supportsAutomaticSelection && !isSelected {
                Button("Use next", action: selectAccount).buttonStyle(.bordered)
            }
            if state.isConnected {
                Button(account.provider.isBrowserProfile ? "Open" : "Launch") {
                    Task { await manager.launch(account, project: projectURL) }
                }
                    .buttonStyle(.bordered).disabled(state.isBusy)
                    .help(account.provider.isBrowserProfile
                          ? "Open this separate \(account.provider.title) browser profile"
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
                Image(systemName: "ellipsis.circle").font(.system(size: 17))
                    .accessibilityLabel("More actions for \(account.label)")
            }.menuStyle(.borderlessButton).fixedSize()
        }.controlSize(.small)
    }

    private func selectAccount() {
        do { try manager.select(account) } catch { reportError(error.localizedDescription) }
    }
    private func quotaColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return Palette.critical }
        if remaining <= 30 { return Palette.watch }
        return Palette.ample
    }
    private var statusDescription: String {
        if isLoginPending { return "sign-in in progress" }; if state.isBusy { return "checking" }
        if !state.isConnected { return state.message ?? "not connected" }; return "connected"
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
        self.manager = manager
        self.reportError = reportError
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
                } else { connectionStep(account: account, state: state) }
            } else { providerStep }
        }
        .frame(width: 720, height: 560).background(Palette.notch).foregroundStyle(Palette.textPrimary)
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
            flowHeader(title: "Add assistant",
                       detail: "Choose a service first. You will sign in with its official page before naming the account.")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    providerGrid(title: "Developer tools",
                                 providers: AccountProvider.allCases.filter { !$0.isBrowserProfile })
                    providerGrid(title: "Browser assistants",
                                 providers: AccountProvider.allCases.filter(\.isBrowserProfile))
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
    }

    private func providerGrid(title: String, providers: [AccountProvider]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(providers) { provider in
                    Button { createAndConnect(provider) } label: {
                        HStack(spacing: 14) {
                            ProviderGlyphView(glyph: provider.glyph, size: 24)
                                .foregroundStyle(Palette.ample).frame(width: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.title).font(.body.weight(.bold)).foregroundStyle(Palette.textPrimary)
                                Text(provider.connectionSummary).font(.callout).foregroundStyle(Palette.textSecondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").foregroundStyle(Palette.textSecondary)
                        }
                        .padding(16).frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                        .background(Palette.ringTrack.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ringTrack))
                    }.buttonStyle(.plain)
                        .disabled(manager.loginAccountID != nil || createdAccountID != nil)
                        .accessibilityLabel("Add \(provider.title). \(provider.connectionDetail)")
                }
            }
        }
    }

    private func connectionStep(account: ManagedAccount, state: ManagedAccountState) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            flowHeader(title: "Connect \(account.provider.title)", detail: account.provider.connectionDetail)
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Circle().stroke(Palette.ringTrack, lineWidth: 3)
                    ProviderGlyphView(glyph: account.provider.glyph, size: 36)
                        .foregroundStyle(Palette.ample)
                }.frame(width: 76, height: 76)
                Text(state.message ?? "Continue sign-in in the browser window opened by Builder Nutch.")
                    .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if account.provider.isBrowserProfile,
                   state.message?.contains("Install Google Chrome") == true {
                    Link("Install Google Chrome", destination: URL(string: "https://www.google.com/chrome/")!)
                        .font(.body.weight(.semibold))
                }
                Text("Your password and tokens stay with the official service. Builder Nutch does not ask for or copy them.")
                    .font(.body).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 28)
            Spacer()
            HStack {
                Button("Close") { dismiss() }.buttonStyle(.bordered); Spacer()
                if account.provider.isBrowserProfile {
                    Button("Open sign-in again") { Task { await manager.connect(account) } }
                        .buttonStyle(.bordered).disabled(state.isBusy || manager.loginAccountID != nil)
                    Button("I've finished signing in") { confirmBrowserConnection(account) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                        .disabled(state.isBusy || !manager.canConfirmBrowserConnection(account))
                } else if state.isBusy {
                    ProgressView().controlSize(.small).tint(Palette.ample)
                    Button("Cancel") { manager.cancelLogin() }.buttonStyle(.bordered)
                } else {
                    Button("Try again") { Task { await manager.connect(account) } }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    private func flowHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.title2.weight(.bold)); Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.textSecondary)
                }.buttonStyle(.plain).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
            }
            Text(detail).font(.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(28)
    }

    private func createAndConnect(_ provider: AccountProvider) {
        guard manager.loginAccountID == nil, createdAccountID == nil else { return }
        do {
            let count = manager.accounts.filter { $0.provider == provider }.count
            let label = count == 0 ? provider.title : "\(provider.title) \(count + 1)"
            let account = try manager.add(provider: provider, label: label, emailHint: nil)
            createdAccountID = account.id
            Task { await manager.connect(account) }
        } catch { present(error.localizedDescription) }
    }
    private func confirmBrowserConnection(_ account: ManagedAccount) {
        do { try manager.confirmBrowserConnection(account) } catch { present(error.localizedDescription) }
    }
    private func present(_ message: String) {
        localError = message
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
    private let emojiChoices = ["⚡️", "🧠", "🛠️", "🚀", "🔬", "🧭", "🎯", "🧪", "💻", "🤖"]

    init(account: ManagedAccount, manager: AccountManager, completionTitle: String = "Save",
         reportError: @escaping (String) -> Void) {
        self.account = account; self.manager = manager; self.completionTitle = completionTitle
        self.reportError = reportError
        let generatedSuffix = account.label.dropFirst(account.provider.title.count)
            .trimmingCharacters(in: .whitespaces)
        let isGenerated = account.label == account.provider.title || Int(generatedSuffix) != nil
        _nickname = State(initialValue: isGenerated ? "" : account.label)
        _selectedEmoji = State(initialValue: account.emoji)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make it yours").font(.title2.weight(.bold))
                Text(personalizationDetail)
                    .font(.body).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Nickname").font(.callout.weight(.semibold))
                TextField("Optional — e.g. Work or Personal", text: $nickname)
                    .textFieldStyle(.roundedBorder).focused($nicknameFocused)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Emoji").font(.callout.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)], spacing: 8) {
                    emojiButton(nil, title: "None")
                    ForEach(emojiChoices, id: \.self) { emoji in emojiButton(emoji, title: emoji) }
                }
            }
            Spacer()
            HStack {
                Text("Account identity and sign-in stay unchanged.").font(.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(completionTitle == "Finish" ? "Skip" : "Cancel") { dismiss() }.buttonStyle(.bordered)
                Button(completionTitle, action: save).buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 620, height: 360).background(Palette.notch)
        .foregroundStyle(Palette.textPrimary).onAppear { nicknameFocused = true }
        .alert("Couldn't save", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private func emojiButton(_ emoji: String?, title: String) -> some View {
        Button { selectedEmoji = emoji } label: {
            Text(title).font(emoji == nil ? .caption : .system(size: 20)).frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.bordered).tint(selectedEmoji == emoji ? Palette.ample : Palette.textSecondary)
        .accessibilityLabel(emoji == nil ? "No emoji" : "Use \(emoji!)")
        .accessibilityAddTraits(selectedEmoji == emoji ? .isSelected : [])
    }

    private func save() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try manager.personalize(account, label: trimmed.isEmpty ? account.label : trimmed,
                                    emoji: selectedEmoji)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private var personalizationDetail: String {
        let connected = manager.state(for: account).isConnected
        let prefix: String
        if account.provider.isBrowserProfile && connected { prefix = "Browser profile ready for \(account.provider.title)." }
        else if connected { prefix = "Connected to \(account.provider.title)." }
        else { prefix = "Customize this \(account.provider.title) account." }
        return prefix + " A nickname and emoji are optional; they only help you recognise this account."
    }
}
