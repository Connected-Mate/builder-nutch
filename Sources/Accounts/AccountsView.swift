import AppKit
import SwiftUI

/// Account profiles for future Claude Code and Codex sessions.
struct AccountsView: View {
    @ObservedObject var manager: AccountManager
    let onOpenSettings: (() -> Void)?

    @State private var provider: AccountProvider = .claude
    @State private var presentingAdd = false
    @State private var editingAccount: ManagedAccount?
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

    private var accounts: [ManagedAccount] {
        manager.accounts.filter { $0.provider == provider }
    }

    var body: some View {
        NavigationSplitView {
            providerSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if manager.loginAccountID != nil { loginBanner }
                if let notice = manager.notice { noticeBanner(notice) }
                accountList
                Divider()
                launchBar
            }
            .frame(minWidth: 500, minHeight: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        .sheet(isPresented: $presentingAdd) {
            AccountForm(mode: .add(provider)) { label, email in
                do {
                    _ = try manager.add(provider: provider, label: label, emailHint: email)
                    presentingAdd = false
                } catch { localError = error.localizedDescription }
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountForm(mode: .rename(account)) { label, _ in
                do {
                    try manager.rename(account, to: label)
                    editingAccount = nil
                } catch { localError = error.localizedDescription }
            }
        }
        .confirmationDialog(
            "Remove \(removingAccount?.label ?? "account")?",
            isPresented: Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }),
            titleVisibility: .visible,
            presenting: removingAccount
        ) { account in
            Button("Remove account", role: .destructive) {
                do { try manager.remove(account) }
                catch { localError = error.localizedDescription }
                removingAccount = nil
            }
            Button("Cancel", role: .cancel) { removingAccount = nil }
        } message: { _ in
            Text("Only this profile is removed from Codenotch Accounts. The official tool keeps its saved sign-in.")
        }
        .alert("Codenotch Accounts", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    private var providerSidebar: some View {
        List(selection: $provider) {
            Section("Assistants") {
                ForEach(AccountProvider.allCases) { item in
                    Label {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text("\(manager.accounts.filter { $0.provider == item }.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: item == .claude ? "sparkles" : "terminal")
                    }
                    .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    Label("Codenotch Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.title)
                    .font(.title2.weight(.semibold))
                Text("Choose the profile used by new sessions. Running sessions stay on their current account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Button {
                Task { await manager.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!manager.busyIDs.isEmpty)
            .keyboardShortcut("r", modifiers: .command)

            Button {
                presentingAdd = true
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var accountList: some View {
        if accounts.isEmpty {
            ContentUnavailableView {
                Label("No \(provider.title) accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add a profile, then sign in through the official \(provider.title) browser flow. Passwords and tokens never appear here.")
            } actions: {
                Button("Add account") { presentingAdd = true }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(accounts) { account in
                        AccountRow(
                            account: account,
                            state: manager.state(for: account),
                            isSelected: manager.isSelected(account),
                            isLoginPending: manager.loginAccountID == account.id,
                            loginInProgress: manager.loginAccountID != nil,
                            select: { select(account) },
                            connect: { Task { await manager.connect(account) } },
                            refresh: { Task { await manager.refresh(account) } },
                            launch: { Task { await manager.launch(account, project: projectURL) } },
                            rename: { editingAccount = account },
                            remove: { removingAccount = account }
                        )
                        if account.id != accounts.last?.id { Divider().padding(.leading, 72) }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var loginBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for browser sign-in")
                    .font(.callout.weight(.medium))
                Text("Finish in the official browser window, or cancel this connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { manager.cancelLogin() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(notice)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }

    private var launchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $manager.automaticSelection) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically choose an available account")
                    Text("For each new session, use the connected \(provider.title) profile with the most fresh, verified quota. Unknown, stale, blocked and disconnected profiles are skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project folder")
                        .font(.callout.weight(.medium))
                    Text(projectURL.path(percentEncoded: false))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(projectURL.path(percentEncoded: false))
                }
                Spacer(minLength: 16)
                Button("Choose…", action: chooseProjectFolder)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func select(_ account: ManagedAccount) {
        do { try manager.select(account) }
        catch { localError = error.localizedDescription }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Choose"
        panel.directoryURL = projectURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        savedProjectPath = url.path(percentEncoded: false)
    }
}

private struct AccountRow: View {
    let account: ManagedAccount
    let state: ManagedAccountState
    let isSelected: Bool
    let isLoginPending: Bool
    let loginInProgress: Bool
    let select: () -> Void
    let connect: () -> Void
    let refresh: () -> Void
    let launch: () -> Void
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            quotaRing
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(account.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if isSelected {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .accessibilityLabel("Active account")
                    }
                    if let plan = state.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(identityLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)

            usageWindows
                .frame(minWidth: 155, idealWidth: 210, maxWidth: 250, alignment: .leading)

            actionButtons
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.label), \(statusDescription)")
    }

    private var identityLine: String {
        state.email ?? account.emailHint ?? "No email hint"
    }

    @ViewBuilder
    private var statusLine: some View {
        if isLoginPending {
            Label("Browser sign-in pending", systemImage: "clock")
                .foregroundStyle(.blue)
        } else if state.isBusy {
            Label("Working…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else if let message = state.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if !state.isConnected {
            Label("Disconnected", systemImage: "circle")
                .foregroundStyle(.secondary)
        } else if state.needsFirstUsage {
            Label("Connected · Start one session to read usage", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if let refreshedAt = state.refreshedAt {
            Label(freshnessLabel(refreshedAt), systemImage: state.isFresh() ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(state.isFresh() ? Color.secondary : Color.orange)
        } else {
            Label("Connected · No usage reading yet", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usageWindows: some View {
        if state.windows.isEmpty {
            Text(state.isConnected ? "Usage will appear after the first session." : "Connect to read quota.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.windows.prefix(2)) { window in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(window.label).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(window.summary).monospacedDigit()
                        }
                        .font(.caption)
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if needsStatusCheck {
                Button("Check", action: refresh)
                    .disabled(state.isBusy)
                    .help("Check whether this saved profile is connected")
            } else if !state.isConnected {
                Button("Connect", action: connect)
                    .disabled(state.isBusy || loginInProgress)
            } else if !isSelected {
                Button("Use", action: select)
                    .help("Use for future \(account.provider.title) sessions")
            }

            Button("Launch", action: launch)
                .disabled(!state.isConnected || state.isBusy)
                .help("Open a new session in the chosen project folder")

            Menu {
                Button("Refresh", action: refresh)
                    .disabled(state.isBusy)
                Button("Rename…", action: rename)
                    .disabled(state.isBusy || isLoginPending)
                Divider()
                Button("Remove…", role: .destructive, action: remove)
                    .disabled(state.isBusy || isLoginPending)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More actions for \(account.label)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private var needsStatusCheck: Bool {
        !state.isConnected && state.message == "Refresh to check this account."
    }

    private var quotaRing: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 5)
            if let remaining = state.remainingPercent {
                Circle()
                    .trim(from: 0, to: min(max(remaining / 100, 0), 1))
                    .stroke(quotaColor(remaining), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
            } else {
                Text("—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.remainingPercent.map { "\(Int($0.rounded())) percent quota remaining" } ?? "Quota unknown")
    }

    private func quotaColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return Palette.critical }
        if remaining <= 30 { return Palette.watch }
        return Palette.ample
    }

    private var statusDescription: String {
        if isLoginPending { return "browser sign-in pending" }
        if let message = state.message { return message }
        if !state.isConnected { return "disconnected" }
        if state.needsFirstUsage { return "connected, no usage yet" }
        if let percent = state.remainingPercent { return "\(Int(percent.rounded())) percent remaining" }
        return "connected"
    }

    private func freshnessLabel(_ date: Date) -> String {
        state.isFresh()
            ? "Updated \(date.formatted(.relative(presentation: .named)))"
            : "Usage may be stale · Last updated \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct AccountForm: View {
    enum Mode {
        case add(AccountProvider)
        case rename(ManagedAccount)

        var title: String {
            switch self {
            case .add(let provider): return "Add \(provider.title) account"
            case .rename: return "Rename account"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let save: (String, String?) -> Void
    @State private var label: String
    @State private var email: String
    @FocusState private var focusedField: Field?

    private enum Field { case label, email }

    init(mode: Mode, save: @escaping (String, String?) -> Void) {
        self.mode = mode
        self.save = save
        switch mode {
        case .add:
            _label = State(initialValue: "")
            _email = State(initialValue: "")
        case .rename(let account):
            _label = State(initialValue: account.label)
            _email = State(initialValue: account.emailHint ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title).font(.title2.weight(.semibold))
                if case .add = mode {
                    Text("This creates a separate local profile. Sign-in continues in the official browser; no password or token is entered here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                TextField("Account name", text: $label, prompt: Text("Work, Personal, Team…"))
                    .focused($focusedField, equals: .label)
                    .textContentType(.nickname)
                if case .add = mode {
                    TextField("Email hint (optional)", text: $email, prompt: Text("Helps distinguish accounts"))
                        .focused($focusedField, equals: .email)
                        .textContentType(.emailAddress)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(modeButtonTitle) {
                    save(label.trimmingCharacters(in: .whitespacesAndNewlines),
                         email.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { focusedField = .label }
    }

    private var modeButtonTitle: String {
        switch mode { case .add: return "Add account"; case .rename: return "Save" }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
