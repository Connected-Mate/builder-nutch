import SwiftUI

/// Covers the whole workspace, including its sidebar. The underlying page
/// remains in place; it cannot receive clicks or VoiceOver focus until closed.
struct UsageShareOverlay: View {
    @ObservedObject var presentation: UsageSharePresentation
    let hidePersonalDetails: Bool
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { presentation.close() }
                .accessibilityHidden(true)
            if let report = presentation.report {
                UsageShareView(report: report, initialProjectPath: presentation.projectPath,
                               hidePersonalDetails: hidePersonalDetails,
                               onSavingChange: { presentation.isSaving = $0 },
                               onClose: presentation.close)
                    // A notification resets period/project even if its cached
                    // load finishes before SwiftUI renders the loading state.
                    .id(presentation.requestID)
            } else {
                VStack(spacing: 16) {
                    if presentation.failed {
                        Text("The image could not be created. Try again.")
                            .font(AppTheme.font(size: 13))
                        Button("Try again", action: onRetry).buttonStyle(AppButtonStyle(primary: true))
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Preparing your image…").font(AppTheme.font(size: 12))
                    }
                    Button("Close", action: presentation.close).buttonStyle(AppButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            }
        }
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.ink)
        .onExitCommand { presentation.close() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
