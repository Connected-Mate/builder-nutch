import SwiftUI

/// Fixed, opaque export artwork. Preview and PNG use this identical composition.
struct UsageShareCard: View {
    static let width: CGFloat = 1200
    static let height: CGFloat = 630

    let snapshot: UsageShareSnapshot
    @Environment(\.locale) private var locale
    private var rankedModels: [UsageModelTotal] { Array(snapshot.modelRanking.filter { $0.modelID != nil }.prefix(3)) }
    private var unassignedTokens: Int { snapshot.modelRanking.filter { $0.modelID == nil }.reduce(0) { $0 + $1.tokens.total } }
    private var unassignedAvailability: UsageMeasurementAvailability {
        snapshot.modelRanking.contains { $0.modelID == nil && $0.availability != .complete } ? .partial : .complete
    }
    private var leadingVisualProvider: UsageTranscriptFormat? {
        guard let first = rankedModels.first else { return snapshot.ranking.first?.provider }
        switch UsageModelPresentation.glyph(first.modelID) {
        case .claude: return .claude
        case .openai: return .codex
        default: return nil
        }
    }
    private var accent: Color { UsageSharePalette.accent(for: leadingVisualProvider) }
    private var statisticsInk: Color { snapshot.podiumTier?.foreground ?? UsageSharePalette.ink }

    var body: some View {
        ZStack(alignment: .topLeading) {
            UsageShareBackdrop(provider: leadingVisualProvider)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "AI Podium")
                    .font(AppTheme.font(size: 25, weightValue: 650)).tracking(-0.5)
                if let tier = snapshot.podiumTier {
                    Text("Lifetime level")
                        .font(AppTheme.font(size: 15, weightValue: 450))
                        .foregroundStyle(UsageSharePalette.muted)
                        .padding(.leading, 12)
                    Text(verbatim: "\(tier.rawValue) · \(tier.name(locale: locale))")
                        .font(AppTheme.font(size: 16, weightValue: 650))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .foregroundStyle(tier.foreground)
                        .background(UsagePodiumFinish(tier: tier, radius: 100))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
                }
                if snapshot.genGen.reached {
                    UsageGenGenBadge(prominent: true).padding(.leading, 4)
                }
                Spacer()
                Text(date(snapshot.today, template: "d MMM yyyy"))
                    .font(AppTheme.font(size: 17, weightValue: 450))
                    .foregroundStyle(UsageSharePalette.muted)
            }
            .frame(width: 1088).offset(x: 56, y: 47)

            statisticsPlate
                .frame(width: 682, height: 418).offset(x: 56, y: 108)
            podiumPlate
                .frame(width: 380, height: 418).offset(x: 766, y: 108)
            footer
                .frame(width: 1088, height: 48).offset(x: 56, y: 558)
        }
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(UsageSharePalette.ink)
        .environment(\.colorScheme, .dark)
    }

    private var statisticsPlate: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if snapshot.isProject, let projectName = snapshot.projectName {
                    Text("Project")
                        .font(AppTheme.font(size: 16, weightValue: 500))
                        .foregroundStyle(statisticsInk)
                    Text(verbatim: projectName)
                        .font(AppTheme.font(size: 30, weightValue: 650))
                        .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.7)
                } else {
                    Text(snapshot.isProject ? "Project" : periodTitle(snapshot.period))
                        .font(AppTheme.font(size: 30, weightValue: 650))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 39, alignment: .leading)
            HStack(spacing: 10) {
                if snapshot.isProject {
                    Text(periodTitle(snapshot.period))
                }
                Text(periodDateLabel)
            }
            .font(AppTheme.font(size: 16, weightValue: 450))
            .foregroundStyle(statisticsInk)
            .lineLimit(1).minimumScaleFactor(0.65)
            .padding(.top, 5)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(count(snapshot.tokens.total, availability: snapshot.availability, compact: true))
                    .font(AppTheme.font(size: 92, weightValue: 700))
                    .tracking(-3).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.40).layoutPriority(1)
                if snapshot.availability != .unavailable {
                    Text("tokens")
                        .font(AppTheme.font(size: 29, weightValue: 400))
                        .foregroundStyle(statisticsInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 112, alignment: .leading)
            .padding(.top, 22)
            exactReading(snapshot.tokens.total, availability: snapshot.availability)
                .font(AppTheme.font(size: 18, weightValue: 450))
                .foregroundStyle(statisticsInk)

            Spacer(minLength: 20)
            Rectangle().fill(statisticsInk.opacity(0.25)).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                supportingMetric(.month, tokens: snapshot.monthTokens, availability: snapshot.monthAvailability)
                supportingMetric(.week, tokens: snapshot.weekTokens, availability: snapshot.weekAvailability)
                supportingMetric(.day, tokens: snapshot.todayTokens, availability: snapshot.todayAvailability)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 38).padding(.vertical, 32)
        .foregroundStyle(statisticsInk)
        .background {
            if let tier = snapshot.podiumTier {
                UsagePodiumFinish(tier: tier)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 5)
                    .shadow(color: .black.opacity(0.75), radius: 12, x: 0, y: 16)
                    .shadow(color: .black.opacity(0.65), radius: 32, x: 0, y: 30)
            } else {
                plateSurface(radius: 44)
            }
        }
    }

    private func supportingMetric(_ period: UsageSharePeriod, tokens: UsageTokenTotals,
                                  availability: UsageMeasurementAvailability) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(periodTitle(period))
                .font(AppTheme.font(size: 15, weightValue: 500))
                .foregroundStyle(statisticsInk)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(count(tokens.total, availability: availability, compact: true))
                .font(AppTheme.font(size: 27, weightValue: 650))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var podiumPlate: some View {
        ZStack(alignment: .topLeading) {
            plateSurface(radius: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(rankedModels.isEmpty ? "Tools used" : "Most-used models")
                    .font(AppTheme.font(size: 20, weightValue: 650))
                Text(periodTitle(snapshot.period))
                    .font(AppTheme.font(size: 14, weightValue: 450))
                    .foregroundStyle(UsageSharePalette.muted)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 324, alignment: .leading).offset(x: 28, y: 26)
            if rankedModels.isEmpty && snapshot.ranking.isEmpty {
                Text("No recorded data")
                    .font(AppTheme.font(size: 23, weightValue: 550))
                    .multilineTextAlignment(.center)
                    .frame(width: 300, height: 250).offset(x: 40, y: 96)
            } else {
                podiumMarks.frame(width: 380, height: 172).offset(y: 76)
                VStack(spacing: 5) {
                    if rankedModels.isEmpty {
                        ForEach(Array(snapshot.ranking.prefix(3).enumerated()), id: \.offset) { index, entry in
                            podiumReading(name: UsageModelPresentation.source(entry.provider) ?? "",
                                context: UsageModelPresentation.localized("Model not recorded", locale: locale),
                                tokens: entry.tokens.total, availability: entry.availability, rank: index + 1)
                        }
                    } else {
                        ForEach(Array(rankedModels.enumerated()), id: \.offset) { index, entry in
                            podiumReading(name: UsageModelPresentation.name(entry.modelID, locale: locale),
                                context: UsageModelPresentation.context(modelID: entry.modelID, provider: entry.provider, sources: entry.sources),
                                tokens: entry.tokens.total, availability: entry.availability, rank: index + 1)
                        }
                    }
                }
                .frame(width: 324, alignment: .leading).offset(x: 28, y: 250)
                if !rankedModels.isEmpty && unassignedTokens > 0 {
                    HStack(spacing: 5) {
                        Text("Model not recorded")
                        Spacer(minLength: 4)
                        Text(count(unassignedTokens, availability: unassignedAvailability, compact: true)).monospacedDigit()
                    }
                    .font(AppTheme.font(size: 12, weightValue: 450))
                    .foregroundStyle(UsageSharePalette.muted).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 324).offset(x: 28, y: 388)
                }
            }
        }
    }

    private var podiumMarks: some View {
        let glyphs: [ProviderGlyph?] = rankedModels.isEmpty
            ? snapshot.ranking.prefix(3).map { $0.provider == .claude ? .claude : .openai }
            : rankedModels.map { UsageModelPresentation.glyph($0.modelID) }
        return ZStack {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                medallion(glyph, rank: index + 1, size: index == 0 ? 128 : 86)
                    .position(x: index == 0 ? 190 : (index == 1 ? 100 : 280),
                              y: index == 0 ? 70 : 122)
                    .zIndex(index == 0 ? 3 : 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func medallion(_ glyph: ProviderGlyph?, rank: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(UsageSharePalette.black)
            Circle().fill(RadialGradient(colors: [accent.opacity(rank == 1 ? 0.75 : 0.28), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: size))
            Circle().fill(LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                          startPoint: .center, endPoint: .bottom))
            Circle().strokeBorder(LinearGradient(colors: [accent.opacity(0.95), UsageSharePalette.edge.opacity(0.25),
                                                           accent.opacity(0.65)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            Circle().strokeBorder(LinearGradient(colors: [accent.opacity(0.65), .clear, accent.opacity(0.22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5).padding(7)
            if let glyph {
                ProviderGlyphView(glyph: glyph, size: size * 0.51)
                    .foregroundStyle(glyph == .claude ? UsageSharePalette.claude : UsageSharePalette.ink)
            } else {
                Image(systemName: "cpu").font(.system(size: size * 0.4))
            }
            Text(verbatim: "\(rank)")
                .font(AppTheme.font(size: rank == 1 ? 23 : 17, weightValue: 700))
                .frame(width: rank == 1 ? 38 : 28, height: rank == 1 ? 38 : 28)
                .background(UsageSharePalette.black, in: Circle())
                .overlay(Circle().strokeBorder(accent.opacity(0.65), lineWidth: 1))
                .offset(x: size * 0.32, y: size * 0.34)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(rank == 1 ? 0.35 : 0.10), radius: rank == 1 ? 24 : 10)
        .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 7)
        .shadow(color: .black.opacity(0.75), radius: 12, x: 0, y: 17)
    }

    private func podiumReading(name: String, context: String, tokens: Int,
                               availability: UsageMeasurementAvailability, rank: Int) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Text(verbatim: "0\(rank)")
                .font(AppTheme.font(size: 13, weightValue: 500))
                .foregroundStyle(UsageSharePalette.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .font(AppTheme.font(size: 17, weightValue: rank == 1 ? 650 : 550))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(verbatim: context)
                    .font(AppTheme.font(size: 11, weightValue: 450))
                    .foregroundStyle(UsageSharePalette.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Text(count(tokens, availability: availability, compact: true))
                .font(AppTheme.font(size: 15, weightValue: 550))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 40)
    }

    private func plateSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(UsageSharePalette.black)
            shape.fill(RadialGradient(colors: [accent.opacity(0.24), .clear],
                                      center: .topLeading, startRadius: 0, endRadius: 340))
            shape.fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                              .init(color: .black.opacity(0), location: 0.6),
                                              .init(color: accent.opacity(0.20), location: 1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(stops: [.init(color: accent.opacity(0.75), location: 0),
                                                       .init(color: UsageSharePalette.edge.opacity(0.38), location: 0.3),
                                                       .init(color: UsageSharePalette.edge.opacity(0.12), location: 0.6),
                                                       .init(color: accent.opacity(0.45), location: 1)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 7)
        .shadow(color: .black.opacity(0.8), radius: 14, x: 0, y: 20)
        .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 30)
    }

    private func exactReading(_ value: Int, availability: UsageMeasurementAvailability) -> some View {
        Group {
            if availability == .unavailable {
                Text("No recorded data")
            } else {
                HStack(spacing: 5) {
                    Text(verbatim: count(value, availability: availability))
                    Text("Recorded tokens")
                }
            }
        }
        .lineLimit(1).minimumScaleFactor(0.65).monospacedDigit()
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 24) {
            Text(verbatim: "Builder Nutch")
            Group {
                if snapshot.isPartial || snapshot.weekAvailability != .complete || snapshot.monthAvailability != .complete {
                    Text("Partial history · ≥ means at least")
                } else if snapshot.modelRanking.contains(where: { $0.availability != .complete }) {
                    Text("Models partly identified · ≥ means at least")
                } else {
                    Text("Local history · Input, cache & output")
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text("\(date(snapshot.generatedAt, template: "d MMM yyyy HHmm")) · \(snapshot.timeZone.identifier)")
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(AppTheme.font(size: 15, weightValue: 500))
        .foregroundStyle(UsageSharePalette.muted)
    }

    private func periodTitle(_ period: UsageSharePeriod) -> LocalizedStringKey {
        switch period {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }

    private var periodDateLabel: String {
        let end = date(snapshot.today, template: "d MMM yyyy")
        return snapshot.period == .day ? end : "\(date(snapshot.periodStart, template: "d MMM yyyy")) – \(end)"
    }

    private func date(_ value: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = snapshot.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: value)
    }

    private func count(_ value: Int, availability: UsageMeasurementAvailability, compact: Bool = false) -> String {
        guard availability != .unavailable else { return "—" }
        let number: String
        if compact {
            let style = IntegerFormatStyle<Int>.number.notation(.compactName)
                .precision(.fractionLength(0...2)).locale(locale)
            // A partial count is a lower bound: never round it upward.
            number = availability == .partial
                ? value.formatted(style.rounded(rule: .down)) : value.formatted(style)
        } else {
            number = value.formatted(.number.grouping(.automatic).locale(locale))
        }
        return availability == .partial ? "≥\u{202F}\(number)" : number
    }
}
