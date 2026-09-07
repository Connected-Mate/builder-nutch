import AppKit
import SwiftUI

/// What changed in this version, shown once when you first run it.
struct WhatsNewView: View {
    let note: ReleaseNote
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            // Scrolled rather than sized to fit. The window cannot grow, and a
            // release with a dozen entries would otherwise run off the bottom
            // of it — where the Continue button is.
            ScrollView { WhatsNewChanges(changes: note.changes) }
                .scrollBounceBehavior(.basedOnSize)

            Rectangle().fill(AppTheme.line).frame(height: 1).accessibilityHidden(true)
            HStack {
                Text("Ready when you are.")
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.muted)
                Spacer(minLength: 0)
                Button("Continue", action: onContinue)
                    .buttonStyle(AppButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(AppTheme.surface)
        }
        .frame(width: WhatsNewView.width, height: WhatsNewView.height)
        .background(AppTheme.paper)
        .foregroundStyle(AppTheme.ink)
        .font(AppTheme.font(.body))
        .tint(AppTheme.ink)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Builder Nutch")
                        .font(AppTheme.font(.callout, weight: .semibold))
                    Text("Version \(note.version)")
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            Text("What's new")
                .font(AppTheme.font(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(note.headline)
                .font(AppTheme.font(.callout))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background {
            AppDotBackground()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Narrow enough to read as a dialogue rather than a window, wide enough
    /// that a sentence of detail does not wrap every other word.
    static let width: CGFloat = 520
    /// Fixed, with the list scrolling inside it: a window that resizes itself
    /// to its content jumps between releases of different lengths.
    static let height: CGFloat = 540
}

/// The list of changes, on its own.
///
/// Separate from the dialogue because the dialogue scrolls it, and a
/// `ScrollView` draws nothing under `ImageRenderer` — so this is the piece a
/// test can actually look at.
struct WhatsNewChanges: View {
    let changes: [ReleaseNote.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(AppTheme.ink)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(change.title)
                            .font(AppTheme.font(.callout, weight: .semibold))
                            .foregroundStyle(AppTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                        // Absent rather than blank: a small fix is one line,
                        // not a line padded out to match its neighbours.
                        if !change.detail.isEmpty {
                            Text(change.detail)
                                .font(AppTheme.font(.callout))
                                .foregroundStyle(AppTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
