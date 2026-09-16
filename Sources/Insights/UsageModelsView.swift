import SwiftUI

/// Real token leaders, with the model and the app that recorded it kept distinct.
struct UsageModelsView: View {
    let entries: [UsageModelTotal]
    @Environment(\.locale) private var locale
    @State private var expanded = false

    private var identified: [UsageModelTotal] { entries.filter { $0.modelID != nil } }
    private var unassigned: Int { entries.filter { $0.modelID == nil }.reduce(0) { $0 + $1.tokens.total } }
    private var unassignedAvailability: UsageMeasurementAvailability {
        entries.contains { $0.modelID == nil && $0.availability != .complete } ? .partial : .complete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Most-used models").font(AppTheme.font(size: 12, weightValue: 550))
                Spacer()
                Text("By recorded tokens").font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
            }
            ForEach(Array(identified.prefix(expanded ? identified.count : 3).enumerated()), id: \.element.id) { index, entry in
                row(entry, rank: index + 1)
            }
            if identified.isEmpty && unassigned == 0 {
                Text(entries.isEmpty ? "No recorded data" : "Model not recorded")
                    .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            }
            if unassigned > 0 {
                HStack(spacing: 8) {
                    Text("Model not recorded")
                    Spacer()
                    Text(UsageModelPresentation.count(unassigned, availability: unassignedAvailability, locale: locale))
                        .monospacedDigit()
                }
                .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                .help("These tokens remain in your totals, but the history does not identify their model.")
            }
            if identified.count > 3 {
                Button(expanded ? "Show fewer models" : "Show all models") { expanded.toggle() }
                    .buttonStyle(.plain).font(AppTheme.font(size: 11, weightValue: 550))
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func row(_ entry: UsageModelTotal, rank: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(AppTheme.font(size: 11, weightValue: 550))
                .foregroundStyle(AppTheme.muted).frame(width: 16)
            Group {
                if let glyph = UsageModelPresentation.glyph(entry.modelID) {
                    ProviderGlyphView(glyph: glyph, size: 23)
                } else {
                    Image(systemName: "cpu").font(.system(size: 18))
                }
            }
            .frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: UsageModelPresentation.name(entry.modelID, locale: locale))
                    .font(AppTheme.font(size: 12, weightValue: 550)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: UsageModelPresentation.context(modelID: entry.modelID, provider: entry.provider, sources: entry.sources))
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
            }
            .help(entry.modelID ?? "")
            Spacer(minLength: 8)
            Text(UsageModelPresentation.count(entry.tokens.total, availability: entry.availability, locale: locale))
                .font(AppTheme.font(size: 12, weightValue: 550)).monospacedDigit()
                .help(entry.tokens.total.formatted(.number.locale(locale)))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
