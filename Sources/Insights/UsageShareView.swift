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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: onClose) { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(AppButtonStyle(compact: true))
                    Spacer()
                    Text("Share your activity").font(AppTheme.font(size: 13, weightValue: 550))
                }
                GeometryReader { geometry in
                    UsageShareCard(snapshot: snapshot)
                        .scaleEffect(geometry.size.width / UsageShareCard.width, anchor: .topLeading)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .aspectRatio(UsageShareCard.width / UsageShareCard.height, contentMode: .fit)
                .accessibilityLabel(Text("Token consumption image preview"))

                Text("Ready for LinkedIn or your favorite network. Accounts and projects stay private.")
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { copy() } label: { Label("Copy image", systemImage: "doc.on.doc") }
                        .buttonStyle(AppButtonStyle(compact: true))
                    Button { save() } label: { Label("Save image…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(AppButtonStyle(primary: true, compact: true))
                    Spacer(minLength: 0)
                    Text("PNG · 2400 × 1260").font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                }
                .disabled(saving)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AppTheme.font(size: 11)).fixedSize(horizontal: false, vertical: true)
                } else if let status {
                    Label(status, systemImage: "checkmark")
                        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                }
            }
            .padding(24)
        }
        .foregroundStyle(AppTheme.ink)
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
