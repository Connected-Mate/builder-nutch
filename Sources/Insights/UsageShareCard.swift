import SwiftUI

/// A self-contained, opaque print surface. Keep the artwork independent of
/// window appearance and avoid effects that ImageRenderer cannot export.
struct UsageShareCard: View {
    static let width: CGFloat = 1200
    static let height: CGFloat = 630

    let snapshot: UsageShareSnapshot
    @Environment(\.locale) private var locale

    var body: some View {
        ZStack {
            AppTheme.surface

            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [AppTheme.line, AppTheme.surface, AppTheme.soft],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [AppTheme.muted.opacity(0.5),
                                                              AppTheme.muted.opacity(0.08),
                                                              AppTheme.muted.opacity(0.22)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 12)
                .overlay { content.padding(.horizontal, 48).padding(.vertical, 40) }
                .padding(24)
        }
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(AppTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 24)
            readings
            Spacer(minLength: 24)
            dailyChart
            Spacer(minLength: 24)
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(verbatim: "Builder Nutch")
                .font(AppTheme.font(size: 24, weightValue: 650))
                .tracking(-0.6)
            Spacer()
            Text("AI consumption")
                .font(AppTheme.font(size: 15, weightValue: 550))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(AppTheme.surface.opacity(0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.muted.opacity(0.3), lineWidth: 1))
        }
        .frame(height: 36)
    }

    private var readings: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                Text("This week")
                    .font(AppTheme.font(size: 24, weightValue: 550))
                Text(weekDateLabel)
                    .font(AppTheme.font(size: 17))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.top, 6)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(count(snapshot.weekTokens.total, availability: snapshot.weekAvailability))
                    .font(AppTheme.font(size: 104, weightValue: 650))
                    .tracking(-4)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.30)
                    .frame(height: 112, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                measurementLabel(snapshot.weekAvailability)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(AppTheme.muted.opacity(0.24))
                .frame(width: 1, height: 176)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                Text("Today")
                    .font(AppTheme.font(size: 24, weightValue: 550))
                Text(date(snapshot.today, template: "d MMM yyyy"))
                    .font(AppTheme.font(size: 17))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.top, 6)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(count(snapshot.todayTokens.total, availability: snapshot.todayAvailability))
                    .font(AppTheme.font(size: 56, weightValue: 550))
                    .tracking(-1.8)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.35)
                    .frame(height: 112, alignment: .leading)
                    .padding(.top, 4)
                measurementLabel(snapshot.todayAvailability)
            }
            .frame(width: 280, alignment: .leading)
        }
        .frame(height: 194, alignment: .top)
    }

    private func measurementLabel(_ availability: UsageMeasurementAvailability) -> some View {
        Group {
            if availability == .unavailable { Text("No recorded data") }
            else { Text("Recorded tokens") }
        }
        .font(AppTheme.font(size: 17))
        .foregroundStyle(AppTheme.muted)
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    private var dailyChart: some View {
        let peak = snapshot.days.filter { $0.availability != .unavailable }
            .map { $0.tokens.total }.max() ?? 0
        return HStack(alignment: .bottom, spacing: 20) {
            ForEach(snapshot.days) { day in
                dayColumn(day, peak: peak)
            }
        }
        .frame(height: 104)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Daily activity"))
    }

    private func dayColumn(_ day: UsageShareDay, peak: Int) -> some View {
        let current = day.date == snapshot.today
        let barHeight = peak > 0 ? 40 * CGFloat(max(0, day.tokens.total)) / CGFloat(peak) : 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(count(day.tokens.total, availability: day.availability, compact: true))
                .font(AppTheme.font(size: 17, weightValue: current ? 650 : 550))
                .monospacedDigit()
                .foregroundStyle(current ? AppTheme.ink : AppTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.6)
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(AppTheme.muted.opacity(0.25)).frame(height: 1)
                if day.availability != .unavailable, day.tokens.total > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(current ? AppTheme.ink : AppTheme.muted.opacity(0.7))
                        .frame(height: max(1, barHeight))
                }
            }
            .frame(height: 40, alignment: .bottom)
            .accessibilityHidden(true)
            Text(date(day.date, template: "EEE d"))
                .font(AppTheme.font(size: 15, weightValue: current ? 650 : 400))
                .foregroundStyle(current ? AppTheme.ink : AppTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
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
        .font(AppTheme.font(size: 14))
        .foregroundStyle(AppTheme.muted)
        .frame(height: 20)
    }

    private var weekDateLabel: String {
        // Both endpoints include the year: a calendar week can cross New Year.
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
            number = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        } else {
            number = value.formatted(.number.grouping(.automatic).locale(locale))
        }
        return availability == .partial ? "≥\u{202F}\(number)" : number
    }
}
