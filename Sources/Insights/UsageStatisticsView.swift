import SwiftUI

/// A single compact reading surface. Motion explains the changing period and
/// selected day; it never animates made-up intermediate token counts.
struct UsageStatisticsView: View {
    let report: UsageLedgerReport
    @Binding var days: Int
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var selectedDay: String?
    @State private var hoveredDay: String?
    @FocusState private var focusedDay: String?
    @Namespace private var chartSelection

    private let chartDays: [UsageChartDay]

    init(report: UsageLedgerReport, days: Binding<Int>, isLoading: Bool) {
        self.report = report
        self._days = days
        self.isLoading = isLoading
        chartDays = UsageChartDay.make(keys: UsageInsightsView.dayKeys(from: report.windowStart, to: report.windowEnd),
                                      timeline: report.timeline, partialHistory: report.scan.hitLimit)
    }

    private var activeDay: UsageChartDay? {
        let key = hoveredDay ?? selectedDay
        return chartDays.first { $0.id == key } ?? chartDays.last
    }

    private var motion: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            totals
            dailyActivity
            details
        }
        .foregroundStyle(AppTheme.ink)
        .opacity(entered || reduceMotion ? 1 : 0)
        .offset(y: entered || reduceMotion ? 0 : 4)
        .onAppear { withAnimation(motion) { entered = true } }
        .onChange(of: report.days) { _, _ in
            // Retain a deliberate selection if it is still in the new window.
            hoveredDay = nil
            if !chartDays.contains(where: { $0.id == selectedDay }) { selectedDay = nil }
        }
        .onChange(of: focusedDay) { _, day in
            if let day { hoveredDay = nil; selectedDay = day }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Recorded tokens")
                .font(AppTheme.font(size: 12, weightValue: 550))
            Spacer(minLength: 4)
            Group {
                if isLoading { ProgressView().controlSize(.mini) }
                else { Color.clear.accessibilityHidden(true) }
            }
            .frame(width: 12, height: 12)
            Picker("Period", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 136).controlSize(.small)
            .disabled(isLoading)
        }
    }

    private var totals: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(display(report.tokens.total, availability: totalAvailability, compact: true))
                    .font(AppTheme.font(size: 32, weightValue: 550)).tracking(-1).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(String(format: NSLocalizedString("Last %d days", comment: "Usage period"), report.days))
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                if report.scan.hitLimit {
                    Text("Partial history")
                        .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                        .help("Some history has not been read yet. These totals are a lower bound.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(tokensText(report.tokens.total, availability: totalAvailability))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Recorded tokens"))
            .accessibilityValue(Text(tokensText(report.tokens.total, availability: totalAvailability)))

            metric("Input", value: report.tokens.totalInput, availability: UsageChartDay.inputAvailability(report.tokens),
                   note: "Includes cache")
            VStack(alignment: .leading, spacing: 8) {
                metric("Output", value: report.tokens.output, availability: report.tokens.coverage.output)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                        .accessibilityHidden(true)
                    Text("Reasoning")
                    Text(display(report.tokens.thinking, availability: coverage(report.tokens.reasoningAvailability), compact: true))
                        .monospacedDigit()
                }
                .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: true, vertical: false)
                .help(reasoningDescription)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(reasoningDescription))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: LocalizedStringKey, value: Int, availability: UsageMeasurementAvailability,
                        note: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            Text(display(value, availability: coverage(availability), compact: true))
                .font(AppTheme.font(size: 18, weightValue: 550)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            if let note { Text(note).font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(accessibleValue(value, availability: coverage(availability)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibleValue(value, availability: coverage(availability))))
    }

    private var dailyActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Daily activity").font(AppTheme.font(size: 11, weightValue: 550))
                Spacer(minLength: 4)
                if let activeDay {
                    Text(dateLabel(activeDay.id, template: "d MMM"))
                        .foregroundStyle(AppTheme.muted)
                    Text(tokensText(activeDay.tokens.total, availability: activeDay.availability, compact: true))
                        .monospacedDigit().foregroundStyle(AppTheme.ink)
                        .help(tokensText(activeDay.tokens.total, availability: activeDay.availability))
                }
            }
            .font(AppTheme.font(size: 11))
            .lineLimit(1).minimumScaleFactor(0.8)
            chart
        }
    }

    private var chart: some View {
        let entries = chartDays
        let peak = entries.map { $0.tokens.total }.max() ?? 0
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                if peak > 0 { Text(UsageInsightsView.compact(peak)) }
                Spacer()
                Text("0")
            }
            .font(AppTheme.font(size: 9)).foregroundStyle(AppTheme.muted)
            .frame(width: 36, height: 88, alignment: .trailing)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, day in
                    dayButton(day, peak: peak, count: entries.count, index: index)
                }
            }
            .frame(height: 88)
            .background {
                VStack(spacing: 0) {
                    Rectangle().fill(AppTheme.line).frame(height: 1)
                    Spacer()
                    Rectangle().fill(AppTheme.line).frame(height: 1)
                    Spacer()
                    Rectangle().fill(AppTheme.muted.opacity(0.4)).frame(height: 1)
                }
                .accessibilityHidden(true)
            }
            .onMoveCommand { direction in
                guard let index = entries.firstIndex(where: { $0.id == (focusedDay ?? selectedDay ?? entries.last?.id) }) else { return }
                let next: Int
                switch direction {
                case .left: next = max(0, index - 1)
                case .right: next = min(entries.count - 1, index + 1)
                default: return
                }
                hoveredDay = nil
                selectedDay = entries[next].id
                focusedDay = entries[next].id
            }
            .animation(motion, value: report.timeline)
            .animation(motion, value: report.days)

            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, day in
                    Text(axisLabel(day.id, index: index, count: entries.count))
                        .font(AppTheme.font(size: 9))
                        .foregroundStyle(day.id == activeDay?.id ? AppTheme.ink : AppTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 14).accessibilityHidden(true)
            }
        }
        .onHover { if !$0 { hoveredDay = nil } }
    }

    private func dayButton(_ day: UsageChartDay, peak: Int, count: Int, index: Int) -> some View {
        let active = day.id == activeDay?.id
        return Button {
            selectedDay = day.id
            focusedDay = day.id
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    if active {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.soft)
                            .matchedGeometryEffect(id: "day-selection", in: chartSelection)
                            .padding(.horizontal, 1)
                    }
                    RoundedRectangle(cornerRadius: count <= 7 ? 3 : 1.5)
                        .fill(active ? AppTheme.ink : AppTheme.muted)
                        .frame(width: min(count <= 7 ? 24 : 10, max(1, geometry.size.width - 4)),
                               height: geometry.size.height * CGFloat(day.fraction(of: peak)))
                        .scaleEffect(y: entered || reduceMotion ? 1 : 0, anchor: .bottom)
                        .animation(reduceMotion ? nil : motion?.delay(Double(index) * 0.012), value: entered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedDay, equals: day.id)
        .overlay {
            if focusedDay == day.id {
                RoundedRectangle(cornerRadius: 4).stroke(AppTheme.ink, lineWidth: 1)
                    .padding(.horizontal, 1).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                if hovered { hoveredDay = day.id }
                else if hoveredDay == day.id { hoveredDay = nil }
            }
        }
        .help(dateLabel(day.id, template: "EEEE d MMMM yyyy") + ": " + tokensText(day.tokens.total, availability: day.availability))
        .accessibilityLabel(Text(dateLabel(day.id, template: "EEEE d MMMM yyyy")))
        .accessibilityValue(Text(tokensText(day.tokens.total, availability: day.availability)))
        .accessibilityAddTraits(day.id == (selectedDay ?? chartDays.last?.id) ? .isSelected : [])
        .accessibilityHint(Text("Select a day. Use the left and right arrow keys to move between days."))
    }

    private var details: some View {
        DisclosureGroup("Token details") {
            VStack(alignment: .leading, spacing: 8) {
                detail("Input without reported cache", value: report.tokens.input, availability: report.tokens.coverage.input)
                detail("Cache written", value: report.tokens.cacheCreation, availability: report.tokens.coverage.cacheCreation)
                detail("Cache read", value: report.tokens.cacheRead, availability: report.tokens.coverage.cacheRead)
                Text("Input includes cache. Reasoning, when reported, is already included in output.")
                    .foregroundStyle(AppTheme.muted)
                Text(String(format: NSLocalizedString("%d sessions · %@ responses", comment: "Usage detail"),
                            report.sessionCount, report.messages.formatted()))
                    .foregroundStyle(AppTheme.muted)
            }
            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        .font(AppTheme.font(size: 11)).tint(AppTheme.muted)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func detail(_ title: LocalizedStringKey, value: Int, availability: UsageMeasurementAvailability) -> some View {
        HStack {
            Text(title).foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            Text(display(value, availability: coverage(availability))).monospacedDigit().textSelection(.enabled)
        }
    }

    private var totalAvailability: UsageMeasurementAvailability {
        UsageChartDay.totalAvailability(report.tokens, partialHistory: report.scan.hitLimit)
    }

    private func coverage(_ availability: UsageMeasurementAvailability) -> UsageMeasurementAvailability {
        UsageChartDay.availability(availability, partialHistory: report.scan.hitLimit)
    }

    private func display(_ value: Int, availability: UsageMeasurementAvailability, compact: Bool = false) -> String {
        guard availability != .unavailable else { return "—" }
        return (availability == .partial ? "≥ " : "") + (compact ? UsageInsightsView.compact(value) : value.formatted())
    }

    private func accessibleValue(_ value: Int, availability: UsageMeasurementAvailability) -> String {
        availability == .unavailable ? NSLocalizedString("Not reported", comment: "Unknown measurement") : display(value, availability: availability)
    }

    private func tokensText(_ value: Int, availability: UsageMeasurementAvailability, compact: Bool = false) -> String {
        String(format: NSLocalizedString("%@ tokens", comment: "Token reading"), display(value, availability: availability, compact: compact))
    }

    private var reasoningDescription: String {
        String(format: NSLocalizedString("Reasoning: %@ · Included in output", comment: "Reasoning subset detail"),
               accessibleValue(report.tokens.thinking, availability: coverage(report.tokens.reasoningAvailability)))
    }

    private func axisLabel(_ key: String, index: Int, count: Int) -> String {
        if count <= 7 { return dateLabel(key, template: "EEE") }
        // Sparse labels keep their exact day-column alignment in a 30-day view.
        return index == 0 || index == count - 1 || index % 7 == 0 ? dateLabel(key, template: "d") : ""
    }

    private func dateLabel(_ key: String, template: String) -> String {
        guard let date = Self.dayParser.date(from: key) else { return key }
        let cacheKey = Locale.current.identifier + template
        if let formatter = Self.dateFormatters[cacheKey] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        Self.dateFormatters[cacheKey] = formatter
        return formatter.string(from: date)
    }

    private static var dateFormatters: [String: DateFormatter] = [:]
    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.calendar = .current
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()
}
