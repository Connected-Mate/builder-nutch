import SwiftUI

/// Fixed, opaque export art: every light and reflection is drawn into the image.
/// Keep this independent of native window materials and the manager's palette.
struct UsageShareCard: View {
    static let width: CGFloat = 1200
    static let height: CGFloat = 630

    let snapshot: UsageShareSnapshot
    @Environment(\.locale) private var locale

    var body: some View {
        ZStack(alignment: .topLeading) {
            UsageShareBackdrop()

            weeklyCard
                .frame(width: 724, height: 370)
                .offset(x: 56, y: 128)

            todayCard
                .frame(width: 326, height: 370)
                .offset(x: 816, y: 128)

            footer
                .frame(width: 1086, height: 44)
                .offset(x: 56, y: 548)
        }
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(UsageSharePalette.ink)
        .environment(\.colorScheme, .dark)
    }

    private var weeklyCard: some View {
        let shape = RoundedRectangle(cornerRadius: 54, style: .continuous)
        return ZStack {
            shape.fill(UsageSharePalette.black)
            shape.fill(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.38),
                .init(color: UsageSharePalette.edge.opacity(0.44), location: 0.81),
                .init(color: UsageSharePalette.edge.opacity(0.22), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            shape.fill(LinearGradient(colors: [UsageSharePalette.ink.opacity(0.055), .clear, .clear],
                                      startPoint: .topTrailing, endPoint: .bottomLeading))

            VStack(alignment: .leading, spacing: 24) {
                weeklyHeader
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(count(snapshot.weekTokens.total, availability: snapshot.weekAvailability, compact: true))
                            .font(AppTheme.font(size: 90, weightValue: 700))
                            .tracking(-4)
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.48)
                            .layoutPriority(1)
                        if snapshot.weekAvailability != .unavailable {
                            Text("tokens")
                                .font(AppTheme.font(size: 34, weightValue: 400))
                                .foregroundStyle(UsageSharePalette.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 98, alignment: .leading)

                    exactReading(snapshot.weekTokens.total, availability: snapshot.weekAvailability)
                        .font(AppTheme.font(size: 18, weightValue: 450))
                        .foregroundStyle(UsageSharePalette.muted)
                }
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 36)

            shape.strokeBorder(LinearGradient(stops: [
                .init(color: UsageSharePalette.ink.opacity(0.63), location: 0),
                .init(color: UsageSharePalette.edge, location: 0.29),
                .init(color: UsageSharePalette.ink.opacity(0.13), location: 0.55),
                .init(color: UsageSharePalette.ink.opacity(0.45), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.72), radius: 6, x: 0, y: 9)
        .shadow(color: .black.opacity(0.54), radius: 24, x: 0, y: 24)
    }

    private var weeklyHeader: some View {
        HStack(spacing: 22) {
            goldEmblem
                .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Builder Nutch")
                    .font(AppTheme.font(size: 36, weightValue: 700))
                    .tracking(-1)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("This week")
                        .font(AppTheme.font(size: 19, weightValue: 550))
                    Text(weekDateLabel)
                        .font(AppTheme.font(size: 15, weightValue: 400))
                        .foregroundStyle(UsageSharePalette.muted)
                }
                .lineLimit(1).minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .frame(height: 132)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.92), UsageSharePalette.edge.opacity(0.20)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [UsageSharePalette.ink.opacity(0.32),
                                                               UsageSharePalette.ink.opacity(0.11),
                                                               UsageSharePalette.ink.opacity(0.27)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
        }
    }

    private var goldEmblem: some View {
        ZStack {
            Circle()
                .fill(UsageSharePalette.gold.opacity(0.60))
                .blur(radius: 16)
                .padding(5)
            Circle()
                .fill(LinearGradient(colors: [UsageSharePalette.paper, UsageSharePalette.gold,
                                               UsageSharePalette.amber, UsageSharePalette.paper],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(UsageSharePalette.paper.opacity(0.9), lineWidth: 1.5))
            Circle()
                .fill(RadialGradient(colors: [UsageSharePalette.paper, UsageSharePalette.gold,
                                             UsageSharePalette.amber],
                                     center: .init(x: 0.28, y: 0.18), startRadius: 1, endRadius: 76))
                .overlay(Circle().strokeBorder(UsageSharePalette.forest.opacity(0.28), lineWidth: 1))
                .padding(5)
            Circle().strokeBorder(UsageSharePalette.paper.opacity(0.76), lineWidth: 1).padding(8)
            Image(systemName: "bolt.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(UsageSharePalette.forest)
                .shadow(color: UsageSharePalette.paper.opacity(0.92), radius: 0, x: 0, y: 1.5)
                .rotationEffect(.degrees(-8))
        }
        .accessibilityHidden(true)
    }

    private var todayCard: some View {
        let shape = RoundedRectangle(cornerRadius: 48, style: .continuous)
        return VStack(spacing: 0) {
            pastelHeader
                .frame(height: 158)
            VStack(alignment: .leading, spacing: 0) {
                Text("Today")
                    .font(AppTheme.font(size: 23, weightValue: 700))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(count(snapshot.todayTokens.total, availability: snapshot.todayAvailability, compact: true))
                        .font(AppTheme.font(size: 57, weightValue: 700))
                        .tracking(-2)
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.42)
                        .layoutPriority(1)
                    if snapshot.todayAvailability != .unavailable {
                        Text("tokens")
                            .font(AppTheme.font(size: 18, weightValue: 450))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(height: 68, alignment: .leading)
                exactReading(snapshot.todayTokens.total, availability: snapshot.todayAvailability)
                    .font(AppTheme.font(size: 15, weightValue: 450))
                    .foregroundStyle(UsageSharePalette.black.opacity(0.7))
                Rectangle()
                    .fill(UsageSharePalette.black.opacity(0.13))
                    .frame(height: 1)
                    .padding(.top, 17)
                    .padding(.bottom, 13)
                Text(date(snapshot.today, template: "d MMM yyyy"))
                    .font(AppTheme.font(size: 16, weightValue: 500))
                    .foregroundStyle(UsageSharePalette.black.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(UsageSharePalette.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
        .background(UsageSharePalette.paper)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [UsageSharePalette.paper, UsageSharePalette.paper.opacity(0.8),
                                                            UsageSharePalette.edge.opacity(0.65)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 2.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.48), radius: 5, x: 0, y: 8)
        .shadow(color: .black.opacity(0.38), radius: 23, x: 0, y: 23)
    }

    private var pastelHeader: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: UsageSharePalette.coral, location: 0),
                .init(color: UsageSharePalette.coral, location: 0.16),
                .init(color: UsageSharePalette.lavender, location: 0.73),
                .init(color: UsageSharePalette.lavender, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [UsageSharePalette.mint, UsageSharePalette.mint.opacity(0)],
                           center: .bottomTrailing, startRadius: 5, endRadius: 260)
            RadialGradient(colors: [UsageSharePalette.gold.opacity(0.72), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 185)
            todaySeal
                .frame(width: 102, height: 102)
        }
        .accessibilityHidden(true)
    }

    private var todaySeal: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [UsageSharePalette.paper, UsageSharePalette.paper.opacity(0.18),
                                               UsageSharePalette.paper.opacity(0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(UsageSharePalette.paper, lineWidth: 3))
            Circle()
                .fill(LinearGradient(stops: [
                    .init(color: UsageSharePalette.paper, location: 0),
                    .init(color: UsageSharePalette.coral, location: 0.28),
                    .init(color: UsageSharePalette.lavender, location: 0.58),
                    .init(color: UsageSharePalette.mint, location: 0.80),
                    .init(color: UsageSharePalette.paper, location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(UsageSharePalette.paper.opacity(0.86), lineWidth: 1.5))
                .padding(10)
                .shadow(color: UsageSharePalette.black.opacity(0.25), radius: 4, x: 0, y: 5)
            Circle().strokeBorder(UsageSharePalette.black.opacity(0.18), lineWidth: 1).padding(15)
            Image(systemName: "sparkles")
                .font(.system(size: 41, weight: .semibold))
                .foregroundStyle(UsageSharePalette.forest)
                .shadow(color: UsageSharePalette.paper.opacity(0.85), radius: 0, x: 0, y: 1.5)
                .rotationEffect(.degrees(-10))
        }
    }

    private func exactReading(_ value: Int, availability: UsageMeasurementAvailability) -> some View {
        Group {
            if availability == .unavailable {
                Text("No recorded data")
            } else {
                Text(count(value, availability: availability))
                    + Text(verbatim: " ") + Text("Recorded tokens")
            }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .monospacedDigit()
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 24) {
            Group {
                if snapshot.isPartial {
                    Text("Partial history · ≥ means at least")
                } else {
                    Text("Local history · Input, cache & output")
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text("\(date(snapshot.generatedAt, template: "d MMM yyyy HHmm")) · \(snapshot.timeZone.identifier)")
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(AppTheme.font(size: 15, weightValue: 500))
        .foregroundStyle(UsageSharePalette.paper.opacity(0.95))
        .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 1)
    }

    private var weekDateLabel: String {
        // Both endpoints retain the year when a calendar week crosses New Year.
        "\(date(snapshot.weekStart, template: "d MMM yyyy")) – \(date(snapshot.today, template: "d MMM yyyy"))"
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
            // A partial count is a lower bound: rounding it upward would overstate it.
            number = availability == .partial
                ? value.formatted(style.rounded(rule: .down))
                : value.formatted(style)
        } else {
            number = value.formatted(.number.grouping(.automatic).locale(locale))
        }
        return availability == .partial ? "≥\u{202F}\(number)" : number
    }
}
