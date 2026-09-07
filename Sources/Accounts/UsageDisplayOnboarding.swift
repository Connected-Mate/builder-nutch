import SwiftUI

struct UsageDisplayOnboarding: View {
    @ObservedObject var preferences: Preferences
    @State private var selection: UsageDisplayMode

    init(preferences: Preferences) {
        self.preferences = preferences
        _selection = State(initialValue: preferences.usageDisplayMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should your quota show?")
                    .font(AppTheme.font(size: 27, weightValue: 650)).tracking(-0.8)
                Text("Choose the number you want to see at a glance. You can change this anytime in Settings.")
                    .font(AppTheme.font(size: 13)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                choice(.remaining, value: 7)
                choice(.used, value: 93)
            }

            HStack {
                Text("One quota, your preferred point of view.")
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                Spacer()
                Button("Continue") { preferences.chooseUsageDisplay(selection) }
                    .buttonStyle(AppButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 570)
        .background(AppTheme.surface).foregroundStyle(AppTheme.ink).tint(AppTheme.ink)
    }

    private func choice(_ mode: UsageDisplayMode, value: Int) -> some View {
        Button { selection = mode } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(LocalizedStringKey(mode.title))
                        .font(AppTheme.font(size: 14, weightValue: 600))
                    Spacer()
                    Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                }
                HStack(spacing: 13) {
                    ZStack {
                        Circle().stroke(AppTheme.track, lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(value) / 100)
                            .stroke(AppTheme.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(value)%").font(AppTheme.font(size: 12, weightValue: 650))
                    }.frame(width: 54, height: 54)
                    Text(LocalizedStringKey(mode.explanation))
                        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(17).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(selection == mode ? AppTheme.soft : AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selection == mode ? AppTheme.ink : AppTheme.line, lineWidth: selection == mode ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title): \(value) percent \(mode.unit). \(mode.explanation)")
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}
