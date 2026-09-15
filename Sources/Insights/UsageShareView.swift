import SwiftUI

/// All choices use one frozen report: capture can continue without changing an
/// image while the person reviews it or chooses where to save it.
struct UsageShareView: View {
    let report: UsageLedgerReport
    let hidePersonalDetails: Bool
    let onClose: () -> Void
    let onSavingChange: (Bool) -> Void
    @FocusState private var closeFocused: Bool
    @Environment(\.locale) private var locale
    @State private var period: UsageSharePeriod = .day
    @State private var projectPath: String?
    @State private var status: String?
    @State private var error: String?
    @State private var saving = false

    init(report: UsageLedgerReport, initialProjectPath: String? = nil,
         hidePersonalDetails: Bool = false, onSavingChange: @escaping (Bool) -> Void = { _ in },
         onClose: @escaping () -> Void) {
        self.report = report
        self.hidePersonalDetails = hidePersonalDetails
        self.onClose = onClose
        self.onSavingChange = onSavingChange
        _projectPath = State(initialValue: initialProjectPath)
    }

    private var snapshot: UsageShareSnapshot {
        UsageShareSnapshot(report: report, period: period, projectPath: projectPath,
                           includeProjectName: !hidePersonalDetails)
    }

    var body: some View {
        GeometryReader { available in
            let ratio = UsageShareCard.width / UsageShareCard.height
            let previewWidth = min(960, max(240, available.size.width - 48),
                                   max(240, (available.size.height - 184) * ratio))
            VStack(spacing: 12) {
                HStack {
                    Text(verbatim: "AI Podium").font(AppTheme.font(size: 18, weightValue: 550))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(AppTheme.soft, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(saving)
                    .accessibilityLabel(Text("Close"))
                    .keyboardShortcut(.cancelAction)
                    .focused($closeFocused)
                }
                HStack(spacing: 12) {
                    Picker("Period", selection: $period) {
                        Text("Today").tag(UsageSharePeriod.day)
                        Text("This week").tag(UsageSharePeriod.week)
                        Text("This month").tag(UsageSharePeriod.month)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 300)
                    Picker("Project", selection: $projectPath) {
                        Text("All projects").tag(String?.none)
                        ForEach(Array(projects.enumerated()), id: \.element.path) { index, project in
                            Text(hidePersonalDetails
                                 ? String(format: NSLocalizedString("Project %d", comment: "Private project choice"), index + 1)
                                 : project.displayName)
                                .tag(Optional(project.path))
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .disabled(saving)

                UsageShareCard(snapshot: snapshot)
                    .scaleEffect(previewWidth / UsageShareCard.width, anchor: .topLeading)
                    .frame(width: previewWidth, height: previewWidth / ratio, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.muted.opacity(0.22)))
                    .shadow(color: .black.opacity(0.65), radius: 24, y: 12)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Token consumption image preview"))
                    .accessibilityValue(Text(accessibleSummary))

                HStack(spacing: 8) {
                    Text("PNG · 2400 × 1260").font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                    Spacer(minLength: 0)
                    Button { copy() } label: { Label("Copy image", systemImage: "doc.on.doc") }
                        .buttonStyle(AppButtonStyle(compact: true))
                    Button { save() } label: { Label("Save image…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(AppButtonStyle(primary: true, compact: true))
                }
                .disabled(saving)
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                    } else if let status {
                        Label(status, systemImage: "checkmark")
                    } else if snapshot.projectName != nil {
                        Text("The selected project name appears on the image. Accounts stay private.")
                    } else {
                        Text("Ready for LinkedIn or your favorite network. Accounts and projects stay private.")
                    }
                }
                .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: min(960, max(0, available.size.width - 48)))
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            .onTapGesture { }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(AppTheme.ink)
        .onAppear { closeFocused = true }
        .onChange(of: period) { _, _ in status = nil; error = nil }
        .onChange(of: projectPath) { _, _ in status = nil; error = nil }
    }

    private var projects: [UsageShareProjectChoice] {
        UsageShareProjectChoice.make(report: report)
    }

    private var accessibleSummary: String {
        let snapshot = snapshot
        let count = snapshot.availability == .unavailable ? "—"
            : (snapshot.availability == .partial ? "≥ " : "") + snapshot.tokens.total.formatted(.number.locale(locale))
        let periodKey: String
        switch period {
        case .day: periodKey = "Today"
        case .week: periodKey = "This week"
        case .month: periodKey = "This month"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = snapshot.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let scope = snapshot.projectName ?? (snapshot.isProject ? NSLocalizedString("Project", comment: "Share scope") : NSLocalizedString("All projects", comment: "Share scope"))
        let ranking = snapshot.todayRanking.enumerated().map { index, entry in
            "\(index + 1). \(entry.provider == .claude ? "Claude" : "Codex")"
        }.joined(separator: ", ")
        let tierSummary = snapshot.podiumTier.map { tier in
            " " + String(format: UsagePodiumTier.localized("Lifetime level: %d · %@", locale: locale),
                         tier.rawValue, tier.name(locale: locale))
        } ?? ""
        return String(format: NSLocalizedString("%@ · %@: %@ tokens. Recorded %@.", comment: "Accessible scoped token export"),
                      scope, NSLocalizedString(periodKey, comment: "Share period"), count, formatter.string(from: snapshot.generatedAt))
            + (ranking.isEmpty ? "" : " " + NSLocalizedString("Today’s AI podium", comment: "Daily provider ranking") + ": " + ranking)
            + tierSummary
    }

    private func copy() {
        error = nil; status = nil
        do {
            try UsageShareExporter.copy(UsageShareExporter.pngData(snapshot: snapshot, locale: locale))
            status = NSLocalizedString("Image copied. Paste it into your post.", comment: "Usage export success")
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        error = nil; status = nil
        let frozen = snapshot
        do {
            let data = try UsageShareExporter.pngData(snapshot: frozen, locale: locale)
            saving = true
            onSavingChange(true)
            UsageShareExporter.save(data, snapshot: frozen) { result in
                saving = false
                onSavingChange(false)
                switch result {
                case .success(let url):
                    if url != nil { status = NSLocalizedString("Image saved. Ready to share.", comment: "Usage export success") }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
