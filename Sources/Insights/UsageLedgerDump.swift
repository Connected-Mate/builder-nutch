import Foundation

/// `Builder Nutch --dump-usage-ledger [--days N]`.
///
/// The ledger has no interface yet, and a number nobody can check is a number
/// nobody should trust. This prints the whole report as JSON so the figures can
/// be read against `~/.claude/projects` before a single pixel is drawn.
///
/// It prints titles, directories, identifiers and counts. It never prints a line
/// of conversation. Numeric history is committed through the same archive as the app.
enum UsageLedgerDump {
    static let flag = "--dump-usage-ledger"

    static func run(arguments: [String] = CommandLine.arguments,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    now: Date = Date()) -> Int32 {
        let days = self.days(in: arguments)
        let catalogRoot = home.appendingPathComponent("Library/Application Support/Codenotch Accounts", isDirectory: true)
        let catalog = (try? AccountStorage(root: catalogRoot))
            .flatMap { try? $0.load() }

        let report = UsageLedger.persistentReport(
            sources: UsageLedger.defaultSources(home: home, catalogRoot: catalogRoot),
            cacheURL: UsageLedger.defaultCacheURL(catalogRoot: catalogRoot), days: days, now: now,
            timeline: timeline(from: catalog))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Dump(report: report, labels: labels(from: catalog))) else {
            FileHandle.standardError.write(Data("Could not encode the usage ledger.\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if report.persistence.state == .failed {
            FileHandle.standardError.write(Data(((report.persistence.message ?? "Could not save token history.") + "\n").utf8))
            return 1
        }
        return 0
    }

    /// `--days 30`, clamped to a useful local-calendar range.
    static func days(in arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "--days"), index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return 7 }
        return min(365, max(1, value))
    }

    /// The account names, so a UUID in the output can be read by a person.
    static func labels(from catalog: AccountCatalog?) -> [String: String] {
        var labels: [String: String] = [:]
        for account in catalog?.accounts ?? [] where account.provider == .claude {
            labels[account.id.uuidString.lowercased()] = account.label
        }
        return labels
    }

    /// What the app can honestly say about which account was logged in when.
    /// Today that is one fact: the last handoff it made itself. Slice 3 turns
    /// this into a real journal; until then the deduction stays small and dated.
    static func timeline(from catalog: AccountCatalog?) -> UsageAccountTimeline {
        guard let last = catalog?.lastAutomaticSwitch, let to = last.toID else { return UsageAccountTimeline() }
        return UsageAccountTimeline(entries: [.init(start: last.date, accountID: to.uuidString.lowercased())])
    }

    /// The report plus the two things only the app can add: readable account
    /// names, and a flat ranking so the numbers can be eyeballed at a glance.
    struct Dump: Encodable {
        let report: UsageLedgerReport
        let labels: [String: String]

        struct Ranked: Encodable {
            let project: String
            let path: String
            let sharePercent: Double
            let tokens: Int
            let sessions: Int
            let lastActivity: Date?
            /// Which accounts paid for this one project. A project split across
            /// three subscriptions is the normal case here, and reading it three
            /// times in a ranking hides how big it actually is.
            let accounts: [String]
        }

        var topProjects: [Ranked] { Self.ranking(report: report, labels: labels) }

        /// The flat answer to "what ate the week", with each project counted
        /// once however many accounts it was spread over.
        static func ranking(report: UsageLedgerReport, labels: [String: String], limit: Int = 20) -> [Ranked] {
            struct Total {
                var name = ""
                var weight = 0.0
                var tokens = 0
                var sessions = 0
                var lastActivity: Date?
                var accounts: [String] = []
            }
            var totals: [String: Total] = [:]
            for account in report.accounts {
                let name = labels[account.managedAccountID ?? ""] ?? account.accountKey
                for project in account.projects {
                    var total = totals[project.path] ?? Total()
                    total.name = project.name
                    total.weight += project.weight
                    total.tokens += project.tokens.total
                    total.sessions += project.sessionCount
                    if let last = project.lastActivity { total.lastActivity = max(total.lastActivity ?? last, last) }
                    if !total.accounts.contains(name) { total.accounts.append(name) }
                    totals[project.path] = total
                }
            }
            return totals
                .map { Ranked(project: $0.value.name, path: $0.key,
                              sharePercent: UsageLedgerEngine.percent($0.value.weight, of: report.totalWeight),
                              tokens: $0.value.tokens, sessions: $0.value.sessions,
                              lastActivity: $0.value.lastActivity, accounts: $0.value.accounts) }
                .sorted { ($0.sharePercent, $0.tokens) > ($1.sharePercent, $1.tokens) }
                .prefix(limit)
                .map { $0 }
        }

        enum CodingKeys: String, CodingKey { case report, accountLabels, topProjects }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(report, forKey: .report)
            try container.encode(labels, forKey: .accountLabels)
            try container.encode(topProjects, forKey: .topProjects)
        }
    }
}
