import SwiftUI

/// Fixed, opaque export artwork. Preview and PNG use this identical composition.
struct UsageShareCard: View {
    static let width: CGFloat = 1200
    static let height: CGFloat = 630

    let snapshot: UsageShareSnapshot
    @Environment(\.locale) private var locale
    private var accent: Color { UsageSharePalette.accent(for: snapshot.todayRanking.first?.provider) }
    private var statisticsInk: Color { snapshot.podiumTier?.foreground ?? UsageSharePalette.ink }

    var body: some View {
        ZStack(alignment: .topLeading) {
            UsageShareBackdrop(provider: snapshot.todayRanking.first?.provider)
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
                        .background(tier.surface, in: Capsule())
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
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(tier.surface)
                    .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .fill(LinearGradient(stops: [
                            .init(color: .white.opacity(tier.rawValue <= 4 ? 0.22 : 0.05), location: 0),
                            .init(color: .clear, location: 0.48),
                            .init(color: .black.opacity(0.08), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .strokeBorder(tier.foreground.opacity(0.22), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.8), radius: 5, x: 0, y: 9)
                    .shadow(color: .black.opacity(0.7), radius: 24, x: 0, y: 24)
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
            Text("Today’s AI podium")
                .font(AppTheme.font(size: 20, weightValue: 650))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 316, alignment: .leading).offset(x: 32, y: 30)
            if snapshot.todayRanking.isEmpty {
                VStack(spacing: 10) {
                    Text("No recorded data")
                        .font(AppTheme.font(size: 23, weightValue: 550))
                    Text("Today")
                        .font(AppTheme.font(size: 16, weightValue: 450))
                        .foregroundStyle(UsageSharePalette.muted)
                }
                .multilineTextAlignment(.center)
                .frame(width: 300, height: 250).offset(x: 40, y: 96)
            } else {
                podiumMarks
                    .frame(width: 380, height: 212).offset(y: 64)
                VStack(spacing: 10) {
                    ForEach(Array(snapshot.todayRanking.prefix(3).enumerated()), id: \.offset) { index, entry in
                        rankingReading(entry, rank: index + 1)
                    }
                }
                .frame(width: 316, alignment: .leading).offset(x: 32, y: 292)
            }
        }
    }

    private var podiumMarks: some View {
        ZStack {
            // Lower ranks sit behind #1; their marks remain authentic and legible.
            ForEach(Array(snapshot.todayRanking.prefix(3).enumerated()), id: \.offset) { index, entry in
                medallion(entry, rank: index + 1, size: index == 0 ? 160 : 106)
                    .position(x: index == 0 ? 190 : (index == 1 ? 92 : 288),
                              y: index == 0 ? 100 : 157)
                    .zIndex(index == 0 ? 3 : 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func medallion(_ entry: UsageShareProviderTotal, rank: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(UsageSharePalette.black)
            Circle().fill(RadialGradient(colors: [accent.opacity(rank == 1 ? 0.42 : 0.17), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: size))
            Circle().strokeBorder(LinearGradient(colors: [accent.opacity(0.95), UsageSharePalette.edge.opacity(0.25),
                                                           accent.opacity(0.65)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            Circle().strokeBorder(accent.opacity(0.20), lineWidth: 1).padding(7)
            ProviderGlyphView(glyph: entry.provider == .claude ? .claude : .openai, size: size * 0.51)
                .foregroundStyle(entry.provider == .claude ? UsageSharePalette.claude : UsageSharePalette.ink)
            Text(verbatim: "\(rank)")
                .font(AppTheme.font(size: rank == 1 ? 23 : 17, weightValue: 700))
                .frame(width: rank == 1 ? 38 : 28, height: rank == 1 ? 38 : 28)
                .background(UsageSharePalette.black, in: Circle())
                .overlay(Circle().strokeBorder(accent.opacity(0.65), lineWidth: 1))
                .offset(x: size * 0.32, y: size * 0.34)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(rank == 1 ? 0.2 : 0.06), radius: rank == 1 ? 20 : 8)
        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 10)
    }

    private func rankingReading(_ entry: UsageShareProviderTotal, rank: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "0\(rank)")
                .font(AppTheme.font(size: 14, weightValue: 500))
                .foregroundStyle(UsageSharePalette.muted)
            Text(verbatim: entry.provider == .claude ? "Claude" : "Codex")
                .font(AppTheme.font(size: 18, weightValue: rank == 1 ? 650 : 500))
            Spacer(minLength: 8)
            Text(count(entry.tokens.total, availability: entry.availability))
                .font(AppTheme.font(size: 16, weightValue: 550))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
        }
        .frame(height: 25)
    }

    private func plateSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(UsageSharePalette.black)
            shape.fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                              .init(color: .black.opacity(0), location: 0.6),
                                              .init(color: accent.opacity(0.13), location: 1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(stops: [.init(color: accent.opacity(0.75), location: 0),
                                                       .init(color: UsageSharePalette.edge.opacity(0.38), location: 0.3),
                                                       .init(color: UsageSharePalette.edge.opacity(0.12), location: 0.6),
                                                       .init(color: accent.opacity(0.45), location: 1)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.8), radius: 5, x: 0, y: 9)
        .shadow(color: .black.opacity(0.7), radius: 24, x: 0, y: 24)
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
