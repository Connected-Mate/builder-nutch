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
                        .accessibilityLabel(Text("Progress to next stamp"))
                }

                VStack(spacing: 0) {
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
                Text("Stamps")
                    .font(AppTheme.font(size: 12, weightValue: 550))
                Text(levelLabel(progress.level))
                    .foregroundStyle(AppTheme.muted)
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
            return NSLocalizedString("All stamps collected", comment: "Final usage milestone reached")
        }
        return String(format: NSLocalizedString("Next: %@ tokens", comment: "Next usage milestone threshold"),
                      compact(next.threshold))
    }

    private func stampRow(_ stamp: UsageMilestoneStamp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stamp.reached ? "checkmark.seal.fill" : "seal")
                .font(AppTheme.font(size: 18))
                .foregroundStyle(stamp.reached ? AppTheme.ink : AppTheme.muted)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(levelLabel(stamp.level))
                        .font(AppTheme.font(size: 12, weightValue: 550))
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

    private func levelLabel(_ level: Int) -> String {
        String(format: NSLocalizedString("Level %d", comment: "Usage milestone level"), level)
    }

    private func stampStatus(_ stamp: UsageMilestoneStamp) -> LocalizedStringKey {
        if stamp.reached { return "Reached" }
        return stamp.id == progress.next?.id ? "Next stamp" : "Locked"
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
