import SwiftUI

/// All choices use one frozen report: capture can continue without changing an
/// image while the person reviews it or chooses where to save it.
struct UsageShareView: View {
    let report: UsageLedgerReport
    let hidePersonalDetails: Bool
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var period: UsageSharePeriod = .day
    @State private var projectPath: String?
    @State private var status: String?
    @State private var error: String?
    @State private var saving = false

    init(report: UsageLedgerReport, initialProjectPath: String? = nil,
         hidePersonalDetails: Bool = false, onClose: @escaping () -> Void) {
        self.report = report
        self.hidePersonalDetails = hidePersonalDetails
        self.onClose = onClose
        _projectPath = State(initialValue: initialProjectPath)
    }

    private var snapshot: UsageShareSnapshot {
        UsageShareSnapshot(report: report, period: period, projectPath: projectPath,
                           includeProjectName: !hidePersonalDetails)
    }

    var body: some View {
        GeometryReader { available in
            let ratio = UsageShareCard.width / UsageShareCard.height
            let previewWidth = min(max(0, available.size.width - 48), max(300, (available.size.height - 205) * ratio))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: onClose) { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(AppButtonStyle(compact: true))
                        Spacer()
                        Text("Share your activity").font(AppTheme.font(size: 13, weightValue: 550))
                    }
                    HStack(spacing: 12) {
                        Picker("Period", selection: $period) {
                            Text("Today").tag(UsageSharePeriod.day)
                            Text("This week").tag(UsageSharePeriod.week)
                            Text("This month").tag(UsageSharePeriod.month)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .frame(maxWidth: 280)
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
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Token consumption image preview"))
                        .accessibilityValue(Text(accessibleSummary))

                    HStack(spacing: 8) {
                        Button { copy() } label: { Label("Copy image", systemImage: "doc.on.doc") }
                            .buttonStyle(AppButtonStyle(compact: true))
                        Button { save() } label: { Label("Save image…", systemImage: "square.and.arrow.down") }
                            .buttonStyle(AppButtonStyle(primary: true, compact: true))
                        Spacer(minLength: 0)
                        Text("PNG · 2400 × 1260").font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                    }
                    .disabled(saving)
                    Group {
                        if snapshot.projectName != nil {
                            Text("The selected project name appears on the image. Accounts stay private.")
                        } else {
                            Text("Ready for LinkedIn or your favorite network. Accounts and projects stay private.")
                        }
                    }
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(AppTheme.font(size: 11)).fixedSize(horizontal: false, vertical: true)
                    } else if let status {
                        Label(status, systemImage: "checkmark")
                            .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .foregroundStyle(AppTheme.ink)
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
        return String(format: NSLocalizedString("%@ · %@: %@ tokens. Recorded %@.", comment: "Accessible scoped token export"),
                      scope, NSLocalizedString(periodKey, comment: "Share period"), count, formatter.string(from: snapshot.generatedAt))
            + (ranking.isEmpty ? "" : " " + NSLocalizedString("Today’s AI podium", comment: "Daily provider ranking") + ": " + ranking)
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
            UsageShareExporter.save(data, snapshot: frozen) { result in
                saving = false
                switch result {
                case .success(let url):
                    if url != nil { status = NSLocalizedString("Image saved. Ready to share.", comment: "Usage export success") }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
