import AppKit
import SwiftUI

struct ClaudeOpenAIRelayView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: AccountManager
    @Binding var project: URL
    var hidePersonalDetails = false
    @State private var codexID: UUID?
    @State private var claudeID: UUID?
    @State private var models: [ClaudeOpenAIRelay.Model] = []
    @State private var modelID = ""
    @State private var mode: ClaudeOpenAIRelay.Mode = .openai
    @State private var history: ClaudeOpenAIRelay.History = .resume
    @State private var loading = false
    @State private var launching = false
    @State private var error: String?
    @State private var probeRevision = 0
    @State private var launchCancellation: AccountCancellation?

    private var codexAccounts: [ManagedAccount] {
        manager.accounts.filter { $0.provider == .codex && manager.state(for: $0).isConnected }
    }
    private var claudeAccounts: [ManagedAccount] {
        manager.accounts.filter { $0.provider == .claude && $0.existingProfile?.usesDefaultClaudeHome != true }
    }
    private var selectedCodex: ManagedAccount? { codexAccounts.first { $0.id == codexID } }
    private var probeKey: String { "\(codexID?.uuidString ?? "none")-\(probeRevision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code with OpenAI").font(AppTheme.font(size: 22, weightValue: 650))
                Text("Keep Claude Code and its tools. Your chosen Codex account supplies the model.")
                    .font(AppTheme.font(size: 13)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.paper)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if codexAccounts.isEmpty {
                        Label("Connect a Codex account in Your assistants, then come back here.", systemImage: "person.crop.circle.badge.plus")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("OpenAI account", selection: $codexID) {
                            Text("Choose an account").tag(Optional<UUID>.none)
                            ForEach(codexAccounts) { account in
                                Text(name(account)).tag(Optional(account.id))
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Picker("OpenAI model", selection: $modelID) {
                                    if models.isEmpty { Text("Choose a model").tag("") }
                                    ForEach(models) { Text($0.displayName).tag($0.id) }
                                }
                                .disabled(loading || models.isEmpty)
                                if loading { ProgressView().controlSize(.small).accessibilityLabel("Checking available models") }
                                Button("Retry") { probeRevision += 1 }.buttonStyle(AppButtonStyle(compact: true))
                                    .disabled(loading || selectedCodex == nil)
                            }
                            Text("Only models returned by this account are listed. Astra is selected when available.")
                                .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Use OpenAI", selection: $mode) {
                                Text("From the start").tag(ClaudeOpenAIRelay.Mode.openai)
                                Text("When Claude reaches its limit").tag(ClaudeOpenAIRelay.Mode.auto)
                            }
                            .pickerStyle(.segmented)
                            Text(mode == .openai
                                 ? "Messages use your OpenAI model as soon as the session opens."
                                 : "Start with your Claude login. If Claude reports a usage limit, this session continues with your OpenAI model.")
                                .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        Picker("Claude history & login", selection: $claudeID) {
                            Text("Current Mac profile").tag(Optional<UUID>.none)
                            ForEach(claudeAccounts) { Text(name($0)).tag(Optional($0.id)) }
                        }
                        Picker("Conversation", selection: $history) {
                            Text("Choose an existing conversation").tag(ClaudeOpenAIRelay.History.resume)
                            Text("Start a new conversation").tag(ClaudeOpenAIRelay.History.newSession)
                        }
                        HStack(spacing: 12) {
                            Text("Project folder")
                            Spacer()
                            Button(action: chooseProject) {
                                Label {
                                    if hidePersonalDetails { Text("Choose folder…") }
                                    else { Text(verbatim: project.lastPathComponent) }
                                } icon: { Image(systemName: "folder") }
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(AppButtonStyle(compact: true))
                            .help(hidePersonalDetails ? "Choose project folder" : project.path)
                            .accessibilityLabel("Choose project folder")
                        }
                        Text("Already open? Resume your conversation once from this window to enable routing. Your history stays with the chosen Claude profile.")
                            .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(AppTheme.font(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .font(AppTheme.font(size: 13)).padding(28).disabled(launching)
            }
            Divider()
            HStack {
                Button("Cancel") { launchCancellation?.cancel(); dismiss() }
                    .buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if launching { ProgressView().controlSize(.small) }
                Button("Open in Terminal", action: launch)
                    .buttonStyle(AppButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(selectedCodex == nil || loading || launching || !models.contains { $0.id == modelID })
            }
            .padding(28)
        }
        .frame(width: 640, height: 700)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).tint(AppTheme.ink)
        .preferredColorScheme(.light)
        .onAppear {
            let selected = manager.selectedAccount(for: .codex)
            codexID = codexAccounts.first { $0.id == selected?.id }?.id ?? codexAccounts.first?.id
        }
        .task(id: probeKey) { await probe() }
        .onDisappear { launchCancellation?.cancel() }
    }

    private func name(_ account: ManagedAccount) -> String {
        guard hidePersonalDetails else { return account.label }
        let index = manager.accounts.filter { $0.provider == account.provider }.firstIndex { $0.id == account.id } ?? 0
        return "\(account.provider.title) \(index + 1)"
    }

    private func probe() async {
        models = []; modelID = ""; error = nil
        guard let account = selectedCodex else { loading = false; return }
        loading = true
        let cancellation = AccountCancellation()
        do {
            let result = try await manager.probeClaudeOpenAIModels(account, cancellation: cancellation)
            guard !Task.isCancelled, selectedCodex?.id == account.id else { return }
            models = result; modelID = ClaudeOpenAIRelay.preferredModel(in: result) ?? ""
        } catch {
            guard !Task.isCancelled, selectedCodex?.id == account.id else { return }
            self.error = error.localizedDescription
        }
        if !Task.isCancelled { loading = false }
    }

    private func launch() {
        guard let account = selectedCodex, !launching else { return }
        launching = true; error = nil
        let cancellation = AccountCancellation(); launchCancellation = cancellation
        Task {
            do {
                try await manager.launchClaudeOpenAI(codex: account,
                    claudeAccount: claudeAccounts.first { $0.id == claudeID }, project: project,
                    model: modelID, mode: mode, history: history, cancellation: cancellation)
                if !cancellation.isCancelled { dismiss() }
            } catch {
                if !cancellation.isCancelled { self.error = error.localizedDescription }
            }
            launching = false
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = project
        panel.begin { response in
            if response == .OK, let url = panel.url { project = url }
        }
    }
}
