import SwiftUI

/// Where the week went. The ledger's report, drawn: a strip of days, the
/// projects that used the quota, and which subscription paid for each.
///
/// Every figure here is a share, never a cost: the ledger ranks sessions by an
/// estimated weight and says what fraction of the window each took. The only
/// authoritative percentage is the one on the account rows, and this screen
/// says how it was spent, not how much is left.
@MainActor
final class UsageInsightsModel: ObservableObject {
    @Published private(set) var report: UsageLedgerReport?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    @Published var days = 7 { didSet { if days != oldValue { Task { await refresh() } } } }

    private let ledger: UsageLedger
    private var lastRefresh: Date?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let catalogRoot = home.appendingPathComponent("Library/Application Support/Codenotch Accounts", isDirectory: true)
        let catalog = (try? AccountStorage(root: catalogRoot)).flatMap { try? $0.load() }
        ledger = UsageLedger(sources: UsageLedger.defaultSources(home: home, catalogRoot: catalogRoot),
                             cacheURL: UsageLedger.defaultCacheURL(catalogRoot: catalogRoot),
                             timeline: UsageLedgerDump.timeline(from: catalog))
    }

    /// Reads again only when the last reading is older than a minute, unless
    /// asked outright. The cache makes a refresh cheap, not free.
    func refreshIfStale(now: Date = Date()) async {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < 60, report != nil { return }
        await refresh(now: now)
    }

    func refresh(now: Date = Date()) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let days = self.days
        let ledger = self.ledger
        report = await ledger.report(days: days, now: now)
        failure = nil
        lastRefresh = now
    }
}

struct UsageInsightsView: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var model: UsageInsightsModel
    let hidePersonalDetails: Bool

    var body: some View {
        Group {
            if let report = model.report {
                if report.sessionCount == 0 {
                    empty
                } else {
                    content(report)
                }
            } else if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                empty
            }
        }
        .task { await model.refreshIfStale() }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing to show yet.")
                .font(AppTheme.font(size: 22, weightValue: 550)).tracking(-0.5)
            Text("Consumption is read from the Claude Code sessions on this Mac. Once you have worked with Claude Code, the projects that used your quota appear here.")
                .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(30)
    }

    private func content(_ report: UsageLedgerReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                overview(report)
                projects(report)
                accounts(report)
                footnote(report)
            }
            .padding(.horizontal, 30).padding(.top, 4).padding(.bottom, 30)
        }
    }

    // MARK: - Overview

    private func overview(_ report: UsageLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(String(format: NSLocalizedString("%d sessions", comment: "Usage summary"), report.sessionCount))
                    .font(AppTheme.font(size: 22, weightValue: 550)).tracking(-0.5)
                Text(String(format: NSLocalizedString("%@ messages · last %d days", comment: "Usage summary"),
                            Self.compact(report.messages), report.days))
                    .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                Spacer(minLength: 8)
                Picker("", selection: $model.days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150).controlSize(.small)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            dayStrip(report)
        }
    }

    /// One column per day of the window, the tallest being the busiest. Days
    /// with nothing in them are drawn empty rather than left out, so a quiet
    /// Sunday is visibly quiet.
    private func dayStrip(_ report: UsageLedgerReport) -> some View {
        let byDay = Dictionary(uniqueKeysWithValues: report.timeline.map { ($0.day, $0) })
        let days = Self.dayKeys(from: report.windowStart, to: report.windowEnd)
        let peak = max(report.timeline.map(\.weight).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(days, id: \.self) { day in
                let slice = byDay[day]
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(slice == nil ? AppTheme.track : AppTheme.ink)
                        .frame(height: max(3, CGFloat((slice?.weight ?? 0) / peak) * 56))
                        .frame(maxHeight: 56, alignment: .bottom)
                    Text(Self.dayLabel(day, wide: report.days <= 7))
                        .font(AppTheme.font(size: 9)).foregroundStyle(AppTheme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .help(slice.map { "\(Self.dayLabel(day, wide: true)): \(Int($0.sharePercent.rounded()))%" } ?? Self.dayLabel(day, wide: true))
                .accessibilityLabel("\(Self.dayLabel(day, wide: true)), \(Int((slice?.sharePercent ?? 0).rounded())) percent")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.line))
    }

    // MARK: - Projects

    private func projects(_ report: UsageLedgerReport) -> some View {
        let ranked = rankedProjects(report)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("PROJECT").frame(maxWidth: .infinity, alignment: .leading)
                Text("SHARE").frame(width: 150, alignment: .leading)
                Text("SESSIONS").frame(width: 70, alignment: .trailing)
                Text("PAID BY").frame(width: 180, alignment: .trailing)
            }
            .font(AppTheme.font(size: 9, weightValue: 500)).tracking(0.8).foregroundStyle(AppTheme.muted)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
            ForEach(ranked, id: \.path) { project in projectRow(project) }
        }
    }

    private func projectRow(_ project: RankedProject) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                if !hidePersonalDetails {
                    Text(Self.shortPath(project.path)).font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !project.topics.isEmpty {
                    Text(project.topics.joined(separator: " · "))
                        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 16)
            shareBar(project.sharePercent).frame(width: 150, alignment: .leading)
            Text("\(project.sessions)").font(AppTheme.font(size: 12)).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(project.payers.joined(separator: ", "))
                .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .frame(width: 180, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func shareBar(_ percent: Double) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.track)
                    Capsule().fill(AppTheme.ink).frame(width: max(2, proxy.size.width * min(max(percent / 100, 0), 1)))
                }
            }
            .frame(height: 5)
            Text("\(Int(percent.rounded()))%").font(AppTheme.font(size: 12, weightValue: 550)).monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.top, 5)
    }

    // MARK: - Accounts

    private func accounts(_ report: UsageLedgerReport) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                Text("SHARE").frame(width: 150, alignment: .leading)
                Text("SESSIONS").frame(width: 70, alignment: .trailing)
                Text("HOW WE KNOW").frame(width: 180, alignment: .trailing)
            }
            .font(AppTheme.font(size: 9, weightValue: 500)).tracking(0.8).foregroundStyle(AppTheme.muted)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
            ForEach(report.accounts.sorted { $0.weight > $1.weight }, id: \.accountKey) { share in
                HStack(spacing: 0) {
                    Text(label(for: share)).font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 16)
                    shareBar(share.sharePercent).frame(width: 150, alignment: .leading)
                    Text("\(share.sessionCount)").font(AppTheme.font(size: 12)).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Text(Self.attributionText(share.attribution))
                        .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
                        .frame(width: 180, alignment: .trailing)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func footnote(_ report: UsageLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Read from the Claude Code sessions on this Mac. Nothing leaves it.", systemImage: "checkmark.shield")
            Text("Shares are estimates that rank sessions against each other. The percentage left on each account comes from Claude itself.")
            if report.scan.hitLimit {
                Text("The reading stopped early to keep the app quick, so these figures are a floor.")
            }
        }
        .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    struct RankedProject {
        let path: String
        let name: String
        let sharePercent: Double
        let sessions: Int
        let topics: [String]
        let payers: [String]
    }

    /// One row per project across every account, biggest first. A project split
    /// across three subscriptions is the normal case, and three rows for it
    /// would hide how big it actually is.
    private func rankedProjects(_ report: UsageLedgerReport) -> [RankedProject] {
        var byPath: [String: (name: String, weight: Double, share: Double, sessions: Int, topics: [String: Double], payers: [(String, Double)])] = [:]
        for share in report.accounts {
            for project in share.projects {
                var row = byPath[project.path] ?? (project.name, 0, 0, 0, [:], [])
                row.weight += project.weight
                row.share += project.overallSharePercent
                row.sessions += project.sessionCount
                for topic in project.topics { row.topics[topic.title, default: 0] += topic.weight }
                row.payers.append((label(for: share), project.weight))
                byPath[project.path] = row
            }
        }
        return byPath.map { path, row in
            // Biggest payer first; the same name twice (two shares of one
            // account, explicit and deduced) reads once.
            var payers: [String] = []
            for (name, _) in row.payers.sorted(by: { $0.1 > $1.1 }) where !payers.contains(name) { payers.append(name) }
            return RankedProject(path: path, name: row.name, sharePercent: row.share, sessions: row.sessions,
                                 topics: row.topics.sorted { $0.value > $1.value }.prefix(3).map(\.key),
                                 payers: payers)
        }
        .sorted { $0.sharePercent > $1.sharePercent }
    }

    private func label(for share: AccountUsageShare) -> String {
        label(forKey: share.accountKey, managedID: share.managedAccountID, vendorID: share.vendorAccountID)
    }

    private func label(forKey key: String, managedID: String?, vendorID: String?) -> String {
        if let managedID, let account = manager.accounts.first(where: { $0.id.uuidString.lowercased() == managedID.lowercased() }) {
            return account.label
        }
        if let vendorID, let account = manager.accounts.first(where: { manager.vendorAccountID(of: $0)?.lowercased() == vendorID.lowercased() }) {
            return account.label
        }
        return NSLocalizedString("Unknown account", comment: "Usage: account not in the list")
    }

    private static func attributionText(_ attribution: UsageAttribution) -> String {
        switch attribution {
        case .explicit: return NSLocalizedString("Its own sessions", comment: "Usage attribution")
        case .deduced: return NSLocalizedString("Deduced from the time", comment: "Usage attribution")
        case .unknown: return NSLocalizedString("Not known", comment: "Usage attribution")
        }
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1f M", Double(value) / 1_000_000)
        case 10_000...: return String(format: "%.0f k", Double(value) / 1_000)
        case 1_000...: return String(format: "%.1f k", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKeys(from start: Date, to end: Date) -> [String] {
        var keys: [String] = []
        var cursor = Calendar.current.startOfDay(for: start)
        while cursor <= end, keys.count < 366 {
            keys.append(dayKeyFormatter.string(from: cursor))
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    static func dayLabel(_ key: String, wide: Bool) -> String {
        guard let date = dayKeyFormatter.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(wide ? "EEE d" : "d")
        return formatter.string(from: date)
    }
}
