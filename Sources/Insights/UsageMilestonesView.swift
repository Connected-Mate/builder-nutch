import SwiftUI

/// A quiet collection tied to saved token history, independent of the period
/// selected above. The native disclosure keeps the ledger useful at small sizes.
struct UsageMilestonesView: View {
    let progress: UsageMilestoneProgress
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: NSLocalizedString("Saved history · %@ tokens", comment: "Cumulative milestone total"),
                            progress.totalTokens.formatted()))
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if progress.next != nil {
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
        guard let next = progress.next else {
            return NSLocalizedString("All levels reached", comment: "Final usage milestone reached")
        }
        let name = UsagePodiumTier(rawValue: next.level)?.name(locale: .current) ?? ""
        return String(format: NSLocalizedString("Next: %@ · %@ tokens", comment: "Next lifetime level and threshold"),
                      name, compact(next.threshold))
    }

    private func stampRow(_ stamp: UsageMilestoneStamp) -> some View {
        HStack(spacing: 12) {
            if let tier = UsagePodiumTier(rawValue: stamp.level) {
                UsagePodiumBadge(tier: tier).frame(width: 110, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(format: NSLocalizedString("%@ tokens", comment: "Usage milestone threshold"),
                                compact(stamp.threshold)))
                        .foregroundStyle(AppTheme.muted)
                        .help(stamp.threshold.formatted())
                }
                if stamp.reached, let date = stamp.reachedAt {
                    Text(String(format: NSLocalizedString("Reached on %@", comment: "Known milestone crossing date"),
                                date.formatted(date: .abbreviated, time: .omitted)))
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
        return stamp.id == progress.next?.id || stamp.level == 0 ? "Next level" : "Locked"
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
