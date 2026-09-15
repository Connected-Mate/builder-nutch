import SwiftUI

/// A quiet collection tied to saved token history, independent of the period
/// selected above. The native disclosure keeps the ledger useful at small sizes.
struct UsageMilestonesView: View {
    let progress: UsageMilestoneProgress
    @Environment(\.locale) private var locale
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: UsagePodiumTier.localized("Saved history · %@ tokens", locale: locale),
                            progress.totalTokens.formatted(.number.locale(locale))))
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if progress.podiumTier != nil && progress.next != nil {
                    ProgressView(value: progress.fractionToNext)
                        .tint(AppTheme.ink)
                        .accessibilityLabel(Text("Progress to next level"))
                }

                VStack(spacing: 0) {
                    stampRow(UsageMilestoneStamp(level: 0, threshold: 0,
                                                reached: progress.podiumTier != nil, reachedAt: nil))
                    Rectangle().fill(AppTheme.line).frame(height: 1).accessibilityHidden(true)
                    ForEach(progress.stamps) { stamp in
                        stampRow(stamp)
                        if stamp.id != progress.stamps.last?.id {
                            Rectangle().fill(AppTheme.line).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "seal")
                    .foregroundStyle(AppTheme.muted).accessibilityHidden(true)
                Text(verbatim: "AI Podium")
                    .font(AppTheme.font(size: 12, weightValue: 550))
                if let tier = progress.podiumTier {
                    UsagePodiumBadge(tier: tier)
                } else {
                    Text("No recorded data").foregroundStyle(AppTheme.muted)
                }
                Spacer(minLength: 4)
                Text(nextLabel)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 32)
        }
        .font(AppTheme.font(size: 11))
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.muted)
    }

    private var nextLabel: String {
        guard let next = progress.nextPodiumTier else {
            return UsagePodiumTier.localized("All levels reached", locale: locale)
        }
        let name = next.name(locale: locale)
        if next == .white {
            return String(format: UsagePodiumTier.localized("Next: %@", locale: locale), name)
        }
        return String(format: UsagePodiumTier.localized("Next: %@ · %@ tokens", locale: locale),
                      name, compact(next.threshold))
    }

    private func stampRow(_ stamp: UsageMilestoneStamp) -> some View {
        HStack(spacing: 12) {
            if let tier = UsagePodiumTier(rawValue: stamp.level) {
                UsagePodiumBadge(tier: tier).frame(width: 110, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(format: UsagePodiumTier.localized("%@ tokens", locale: locale),
                                compact(stamp.threshold)))
                        .foregroundStyle(AppTheme.muted)
                        .help(stamp.threshold.formatted())
                }
                if stamp.reached, let date = stamp.reachedAt {
                    Text(String(format: UsagePodiumTier.localized("Reached on %@", locale: locale),
                                date.formatted(.dateTime.locale(locale).day().month(.abbreviated).year())))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(stampStatus(stamp))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func stampStatus(_ stamp: UsageMilestoneStamp) -> LocalizedStringKey {
        if stamp.reached { return "Reached" }
        return stamp.id == progress.nextPodiumTier?.rawValue ? "Next level" : "Locked"
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.locale(locale).notation(.compactName).precision(.fractionLength(0...1)))
    }
}
