import SwiftUI
import AppKit

@MainActor
struct CustomAssistantSetupView: View {
    @ObservedObject var store: CustomAssistantStore
    @State private var copied = ""
    @State private var removal: CustomAssistantConfiguration?

    init(store: CustomAssistantStore = .shared) { self.store = store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                introduction
                connection
                Divider().overlay(AppTheme.line)
                savedAssistants
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(AppTheme.font(.body))
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.paper)
        .onAppear { store.startMonitoring() }
        .confirmationDialog("Remove this custom assistant?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removal { store.remove(id: removal.id) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Only this saved profile and its reported usage will be removed.")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your custom assistants")
                .font(AppTheme.font(.title2, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Give your AI the request below. It can create your assistant here and report usage it has actually observed.")
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let connection = CustomAssistantConnection.current { copy(connection.prompt(), action: "request") }
            } label: {
                Label(copied == "request" ? "Request copied" : "Copy setup request",
                      systemImage: copied == "request" ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(AppButtonStyle(primary: true))
            .disabled(CustomAssistantConnection.current == nil)
            Text("Paste it into an AI app on this Mac that supports local MCP connections. Follow its connection steps, then come back here.")
                .font(AppTheme.font(.callout))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(CustomAssistantConnection.current?.configurationJSON ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copied == "connection" ? "Connection copied" : "Copy connection") {
                        if let connection = CustomAssistantConnection.current { copy(connection.configurationJSON, action: "connection") }
                    }
                    .buttonStyle(AppButtonStyle(compact: true))
                }
                .padding(.top, 8)
            }
        }
    }

    private var savedAssistants: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved assistants")
                .font(AppTheme.font(.headline, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't load saved assistants", systemImage: "exclamationmark.triangle")
                    Text(error).font(AppTheme.font(.callout)).textSelection(.enabled)
                    Button("Try again") { store.reload() }.buttonStyle(AppButtonStyle(compact: true))
                }
            }
            if store.assistants.isEmpty {
                Text("Your assistant will appear here as soon as the AI saves it.")
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.assistants) { assistant in
                assistantRow(assistant)
                Divider().overlay(AppTheme.line)
            }
        }
    }

    private func assistantRow(_ assistant: CustomAssistantConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.square")
                    .font(AppTheme.font(.title2))
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistant.name).font(AppTheme.font(.headline, weight: .semibold))
                    Text(assistant.website.host ?? assistant.website.absoluteString)
                        .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Copy customization request") {
                        if let connection = CustomAssistantConnection.current {
                            copy(connection.prompt(existing: assistant), action: assistant.id.uuidString)
                        }
                    }
                    Button("Remove", role: .destructive) { removal = assistant }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("Assistant actions") + Text(": \(assistant.name)"))
            }
            usage(assistant)
            HStack(spacing: 8) {
                Button("Open assistant") { NSWorkspace.shared.open(assistant.website) }
                    .buttonStyle(AppButtonStyle(compact: true))
                if !assistant.instructions.isEmpty {
                    Button(copied == assistant.id.uuidString ? "Copied" : "Copy instructions") {
                        copy(assistant.instructions, action: assistant.id.uuidString)
                    }
                    .buttonStyle(AppButtonStyle(compact: true))
                }
            }
            if !assistant.instructions.isEmpty || !assistant.usageNote.isEmpty {
                DisclosureGroup("Preferences and notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !assistant.instructions.isEmpty { Text(assistant.instructions) }
                        if !assistant.usageNote.isEmpty { Text(assistant.usageNote).foregroundStyle(AppTheme.muted) }
                    }
                    .textSelection(.enabled)
                    .font(AppTheme.font(.callout))
                    .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func usage(_ assistant: CustomAssistantConfiguration) -> some View {
        if let report = assistant.usage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.limits.enumerated()), id: \.offset) { _, limit in
                        HStack {
                            Text(limit.label).lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(Int(limit.usedPercent.rounded()))% used")
                                .monospacedDigit()
                        }
                    }
                    Text(report.isStale(now: context.date) ? "Reported by assistant · Out of date" : "Reported by assistant")
                        .foregroundStyle(AppTheme.muted)
                    Text(report.observedAt, format: .dateTime.day().month().hour().minute())
                        .foregroundStyle(AppTheme.muted)
                    Text(report.source).foregroundStyle(AppTheme.muted).lineLimit(2)
                }
                .font(AppTheme.font(.callout))
            }
        } else {
            Text("Usage unknown · No reading reported")
                .font(AppTheme.font(.callout)).foregroundStyle(AppTheme.muted)
        }
    }

    private func copy(_ text: String, action: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { copied = action }
    }
}
