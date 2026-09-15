import SwiftUI

/// A glimpse of the actual image makes sharing discoverable without adding
/// another dashboard section. Colors and totals come from the saved reading.
struct UsageShareButton: View {
    let snapshot: UsageShareSnapshot?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let snapshot {
                        UsageShareCard(snapshot: snapshot)
                            .scaleEffect(80 / UsageShareCard.width, anchor: .topLeading)
                            .frame(width: 80, height: 42, alignment: .topLeading)
                    } else {
                        AppTheme.soft.frame(width: 80, height: 42)
                            .overlay { ProgressView().controlSize(.mini) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.muted.opacity(0.3)))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
                    Text("Share").font(AppTheme.font(size: 11, weightValue: 550))
                }
                .fixedSize()
            }
            .padding(6)
            .background(hovered ? AppTheme.selected : AppTheme.soft, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.muted.opacity(hovered ? 0.45 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Share your activity"))
        .help("Share your activity")
        .onHover { value in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { hovered = value } }
    }
}
