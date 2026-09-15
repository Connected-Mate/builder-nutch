import SwiftUI

/// Tokens recorded by the assistants on this Mac. Subscription limits stay in
/// the account view; this ledger shows the measured activity behind them.
@MainActor
final class UsageInsightsModel: ObservableObject {
    @Published private(set) var report: UsageLedgerReport?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    @Published var days = 7 { didSet { if days != oldValue { Task { await updatePeriod() } } } }

    private let ledger: UsageLedger
    private let home: URL
    private let catalogRoot: URL
    private var lastRefresh: Date?
    private var refreshTask: Task<UsageLedgerReport, Never>?
    private var periodTask: Task<UsageLedgerReport, Never>?
    private var reportGeneration = 0
    private var backgroundTask: Task<Void, Never>?
    private var stopped = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let catalogRoot = home.appendingPathComponent("Library/Application Support/Codenotch Accounts", isDirectory: true)
        self.catalogRoot = catalogRoot
        ledger = UsageLedger(sources: [], cacheURL: UsageLedger.defaultCacheURL(catalogRoot: catalogRoot),
                             archiveURL: UsageLedger.defaultArchiveURL(catalogRoot: catalogRoot))
    }

    /// App-owned, so capture continues with the accounts window closed. All
    /// routes share the same task and ledger; a view cannot start a second writer.
    func captureInBackground() {
        guard !stopped, backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            await self?.refresh()
            self?.backgroundTask = nil
        }
    }

    func refreshIfStale(now: Date = Date()) async {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < 60, report != nil { return }
        await refresh(now: now)
    }

    func refresh(now: Date = Date()) async {
        guard !stopped else { return }
        if let refreshTask { _ = await refreshTask.value; return }
        isLoading = true
        reportGeneration += 1
        let generation = reportGeneration
        let days = self.days, ledger = self.ledger, home = self.home, catalogRoot = self.catalogRoot
        let task = Task {
            // Discovery is cheap but still file I/O. Read fresh homes and login
            // context every pass, including accounts added after app launch.
            let context = await Task.detached(priority: .utility) {
                let catalog = (try? AccountStorage(root: catalogRoot)).flatMap { try? $0.load() }
                return (UsageLedger.defaultSources(home: home, catalogRoot: catalogRoot),
                        UsageLedgerDump.timeline(from: catalog))
            }.value
            await ledger.updateSources(context.0, timeline: context.1)
            return await ledger.report(days: days, now: now)
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        isLoading = periodTask != nil
        guard !stopped, generation == reportGeneration else { return }
        apply(result)
        lastRefresh = now
        if self.days != days { await updatePeriod() }
    }

    /// Coalesce rapid picker changes without rediscovering homes or rereading
    /// source/archive files. A capture already in flight applies the latest
    /// requested period after it has delivered its saved snapshot.
    private func updatePeriod() async {
        guard !stopped, refreshTask == nil, periodTask == nil else { return }
        guard let report else { await refresh(); return }
        let requestedDays = days, now = report.generatedAt
        reportGeneration += 1
        let generation = reportGeneration
        isLoading = true
        let ledger = self.ledger
        let task = Task { await ledger.cachedReport(days: requestedDays, now: now) }
        periodTask = task
        let result = await task.value
        periodTask = nil
        isLoading = refreshTask != nil
        guard !stopped else { return }
        guard generation == reportGeneration else {
            if refreshTask == nil, self.report?.days != days { await updatePeriod() }
            return
        }
        if days == requestedDays { apply(result) }
        else { await updatePeriod() }
    }

    private func apply(_ result: UsageLedgerReport) {
        report = result
        failure = result.persistence.state == .failed
            ? NSLocalizedString("This reading could not be saved. Previously saved history is kept. Try refreshing.", comment: "Durable usage write failure")
            : nil
    }

    func stop() {
        stopped = true
        refreshTask?.cancel()
        periodTask?.cancel()
        backgroundTask?.cancel()
    }

    func shutdownAndWait() async {
        stop()
        if let refreshTask { _ = await refreshTask.value }
        if let periodTask { _ = await periodTask.value }
    }

}

struct UsageInsightsView: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var model: UsageInsightsModel
    let hidePersonalDetails: Bool
    @State private var expandedProjects: Set<String> = []
    @State private var shareSnapshot: UsageShareSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.font(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(24)
            }
            Group {
                if let shareSnapshot {
                    UsageShareView(snapshot: shareSnapshot) { self.shareSnapshot = nil }
                } else if let report = model.report {
                    if report.sessionCount == 0 && !report.scan.hitLimit && report.milestones == nil {
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
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing to show yet.")
                .font(AppTheme.font(size: 22, weightValue: 550)).tracking(-0.5)
            Text("Tokens appear here after a Claude Code or Codex session on this Mac.")
                .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
    }

    private func content(_ report: UsageLedgerReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                overview(report)
                if report.sessionCount == 0 && !report.scan.hitLimit {
                    Text("No sessions in this period.")
                        .font(AppTheme.font(size: 12)).foregroundStyle(AppTheme.muted)
                } else {
                    projects(report)
                    DisclosureGroup("By account") { accounts(report).padding(.top, 12) }
                        .font(AppTheme.font(size: 12, weightValue: 550))
                }
                footnote(report)
            }
            .padding(24)
        }
    }

    // MARK: - Overview

    private func overview(_ report: UsageLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageStatisticsView(report: report, days: $model.days, isLoading: model.isLoading) {
                shareSnapshot = UsageShareSnapshot(report: report)
            }
            if let milestones = report.milestones {
                UsageMilestonesView(progress: milestones)
            }
        }
    }

    private func tokenDetail(_ title: LocalizedStringKey, value: Int, availability: UsageMeasurementAvailability = .complete) -> some View {
        HStack {
            Text(title).foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            Text(Self.tokenDisplay(value, availability: availability)).monospacedDigit().textSelection(.enabled)
        }
    }

    private static func tokenDisplay(_ value: Int, availability: UsageMeasurementAvailability, compact: Bool = false) -> String {
        guard availability != .unavailable else { return "—" }
        return (availability == .partial ? "≥ " : "") + (compact ? Self.compact(value) : value.formatted())
    }

    // MARK: - Projects

    private func projects(_ report: UsageLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects")
                Spacer()
                Text("Tokens").foregroundStyle(AppTheme.muted)
            }
            .font(AppTheme.font(size: 11, weightValue: 550)).padding(.bottom, 8)
            ForEach(rankedProjects(report), id: \.path) { project in projectRow(project) }
        }
    }

    private func projectRow(_ project: RankedProject) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedProjects.contains(project.path) },
            set: { if $0 { expandedProjects.insert(project.path) } else { expandedProjects.remove(project.path) } }
        )) {
            VStack(alignment: .leading, spacing: 6) {
                if !hidePersonalDetails {
                    Text(Self.shortPath(project.path)).lineLimit(2).truncationMode(.middle)
                    if !project.topics.isEmpty { Text(project.topics.joined(separator: " · ")) }
                }
                Text(project.payers.joined(separator: ", "))
                tokenDetail("Input", value: project.tokens.totalInput, availability: project.tokens.coverage.input)
                tokenDetail("Output", value: project.tokens.output, availability: project.tokens.coverage.output)
            }
            .font(AppTheme.font(size: 11)).foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hidePersonalDetails ? "Project" : project.name)
                        .font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                    Text(String(format: NSLocalizedString("%d sessions", comment: "Usage summary"), project.sessions))
                        .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                tokenAmount(project.tokens.total)
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func tokenAmount(_ value: Int) -> some View {
        Text(Self.compact(value)).font(AppTheme.font(size: 13, weightValue: 550)).monospacedDigit()
            .frame(minWidth: 70, alignment: .trailing)
            .help(String(format: NSLocalizedString("%@ tokens", comment: "Exact token total"), value.formatted()))
    }

    // MARK: - Accounts

    private func accounts(_ report: UsageLedgerReport) -> some View {
        VStack(spacing: 0) {
            ForEach(report.accounts.sorted { $0.tokens.total > $1.tokens.total }, id: \.accountKey) { share in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(for: share)).font(AppTheme.font(size: 13, weightValue: 550)).lineLimit(1)
                        Text(String(format: NSLocalizedString("%d sessions", comment: "Usage summary"), share.sessionCount))
                            + Text(" · ") + Text(Self.attributionText(share.attribution))
                    }
                    .font(AppTheme.font(size: 10)).foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    tokenAmount(share.tokens.total)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func footnote(_ report: UsageLedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Read from Claude Code and Codex on this Mac. Nothing leaves it.", systemImage: "checkmark.shield")
            Text("Only recorded tokens are counted. Subscription limits are shown on each account.")
            if report.persistence.state == .saved {
                Label("History saved on this Mac", systemImage: "externaldrive.badge.checkmark")
                Text("Saved tokens stay in your timeline when session files are removed. Recording continues while Builder Nutch is open.")
            }
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
        let tokens: UsageTokenTotals
        let sessions: Int
        let topics: [String]
        let payers: [String]
    }

    /// One row per project across every account, biggest first. A project split
    /// across three subscriptions is the normal case, and three rows for it
    /// would hide how big it actually is.
    private func rankedProjects(_ report: UsageLedgerReport) -> [RankedProject] {
        var byPath: [String: (name: String, tokens: UsageTokenTotals, sessions: Int, topics: [String: Double], payers: [(String, Double)])] = [:]
        for share in report.accounts {
            for project in share.projects {
                var row = byPath[project.path] ?? (project.name, UsageTokenTotals(), 0, [:], [])
                row.tokens += project.tokens
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
            return RankedProject(path: path, name: row.name, tokens: row.tokens, sessions: row.sessions,
                                 topics: row.topics.sorted { $0.value > $1.value }.prefix(3).map(\.key),
                                 payers: payers)
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    private func label(for share: AccountUsageShare) -> String {
        if share.attribution == .unknown, share.managedAccountID == nil, share.vendorAccountID == nil {
            let provider = share.provider == .codex ? "Codex" : "Claude Code"
            return String(format: NSLocalizedString("%@ · account not identified", comment: "Unattributed local usage"), provider)
        }
        return label(forKey: share.accountKey, managedID: share.managedAccountID, vendorID: share.vendorAccountID)
    }

    private func label(forKey key: String, managedID: String?, vendorID: String?) -> String {
        if hidePersonalDetails { return NSLocalizedString("Account", comment: "Hidden account name") }
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
        case 1_000_000_000...: return String(format: NSLocalizedString("%.1f B", comment: "Compact billions of tokens"), Double(value) / 1_000_000_000)
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
