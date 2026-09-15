import SwiftUI

/// Inline preview keeps the manager's navigation intact. The frozen snapshot
/// is shared by the preview, clipboard and file, even if collection continues.
struct UsageShareView: View {
    let snapshot: UsageShareSnapshot
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var status: String?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        GeometryReader { available in
            let ratio = UsageShareCard.width / UsageShareCard.height
            let previewWidth = min(max(0, available.size.width - 48), max(300, (available.size.height - 166) * ratio))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: onClose) { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(AppButtonStyle(compact: true))
                        Spacer()
                        Text("Share your activity").font(AppTheme.font(size: 13, weightValue: 550))
                    }
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
                    Text("Ready for LinkedIn or your favorite network. Accounts and projects stay private.")
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
    }

    private var accessibleSummary: String {
        func count(_ value: Int, _ availability: UsageMeasurementAvailability) -> String {
            guard availability != .unavailable else { return "—" }
            return (availability == .partial ? "≥ " : "") + value.formatted(.number.locale(locale))
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = snapshot.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return String(format: NSLocalizedString("This week: %@ tokens. Today: %@ tokens. Recorded %@.", comment: "Accessible export summary"),
                      count(snapshot.weekTokens.total, snapshot.weekAvailability),
                      count(snapshot.todayTokens.total, snapshot.todayAvailability),
                      formatter.string(from: snapshot.generatedAt))
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
        do {
            let data = try UsageShareExporter.pngData(snapshot: snapshot, locale: locale)
            saving = true
            UsageShareExporter.save(data, snapshot: snapshot) { result in
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
