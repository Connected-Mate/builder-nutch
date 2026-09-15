import Foundation

/// One calendar day of consumption, in the person's own time zone.
struct UsageDaySlice: Codable, Equatable {
    /// `2026-09-10`, local. Stable enough to key a chart on.
    let day: String
    let weight: Double
    let sharePercent: Double
    let tokens: UsageTokenTotals
    let messages: Int
}

/// One session, as the person would recognise it: a title, a time, a size.
struct UsageSessionSlice: Codable, Equatable {
    let sessionID: String
    /// The title Claude Code wrote. Absent for sessions old enough to predate it.
    let title: String?
    let weight: Double
    let sharePercent: Double
    let tokens: UsageTokenTotals
    let messages: Int
    let firstActivity: Date?
    let lastActivity: Date?
    /// Which model did most of the work here.
    let dominantModel: String?
}

/// A subject inside a project — sessions that share a title. This is the second
/// grouping level, and it costs nothing: the titles already exist on disk.
struct UsageTopicSlice: Codable, Equatable {
    let title: String
    let weight: Double
    let sharePercent: Double
    let tokens: UsageTokenTotals
    let sessionCount: Int
    let lastActivity: Date?
    let sessionIDs: [String]
}

struct UsageProjectSlice: Codable, Equatable {
    /// The working directory. Shown on hover, never opened by this code.
    let path: String
    /// Its last component — what the person calls the project.
    let name: String
    let weight: Double
    /// Share of this account's consumption over the window.
    let sharePercent: Double
    /// Share of everything the report covers, across all accounts.
    let overallSharePercent: Double
    let tokens: UsageTokenTotals
    let messages: Int
    let sessionCount: Int
    let firstActivity: Date?
    let lastActivity: Date?
    let topics: [UsageTopicSlice]
    let sessions: [UsageSessionSlice]
    let days: [UsageDaySlice]
}

/// Everything one account consumed over the window, and where it went.
struct AccountUsageShare: Codable, Equatable {
    /// A stable grouping key: `profile:<uuid>`, `vendor:<uuid>` or `unknown`.
    let accountKey: String
    /// The Builder Nutch account row, when the ledger can name one.
    let managedAccountID: String?
    /// The vendor's own account identifier, when a transcript named it.
    let vendorAccountID: String?
    let attribution: UsageAttribution
    let provider: UsageTranscriptFormat
    let weight: Double
    let sharePercent: Double
    let tokens: UsageTokenTotals
    let messages: Int
    let sessionCount: Int
    let firstActivity: Date?
    let lastActivity: Date?
    let projects: [UsageProjectSlice]
    let days: [UsageDaySlice]
}

/// The whole answer to "where did my quota go", with the honesty attached.
///
/// `weight` is an estimate and is never a percentage of a subscription window
/// on its own — the authoritative percentage comes from the usage API, and this
/// report only says how to divide it up.
struct UsageLedgerReport: Codable, Equatable {
    let generatedAt: Date
    let windowStart: Date
    let windowEnd: Date
    let days: Int
    let totalWeight: Double
    let tokens: UsageTokenTotals
    let messages: Int
    let sessionCount: Int
    let accounts: [AccountUsageShare]
    /// Every day in the window, across all accounts.
    let timeline: [UsageDaySlice]
    let scan: UsageScanSummary
    var persistence: UsagePersistenceStatus = .notCaptured
    /// Lifetime progress uses saved history, never the selected 7/30-day total.
    var milestones: UsageMilestoneProgress? = nil
    /// Calendar that produced the day keys. Keep exports aligned when the Mac's
    /// timezone changes while an existing ledger is still running.
    var calendar: Calendar? = nil

    static let empty = UsageLedgerReport(
        generatedAt: .distantPast, windowStart: .distantPast, windowEnd: .distantPast, days: 0,
        totalWeight: 0, tokens: UsageTokenTotals(), messages: 0, sessionCount: 0,
        accounts: [], timeline: [], scan: UsageScanSummary())
}

/// Which Builder Nutch account the Mac was logged in to, and since when.
///
/// This is what makes an answer possible for the shared Claude home, where the
/// transcript names no account at all. It is a deduction and is labelled as one
/// everywhere it is used.
struct UsageAccountTimeline: Equatable {
    struct Entry: Equatable {
        let start: Date
        let accountID: String
    }

    /// Sorted oldest first on construction, so lookup is a simple walk back.
    private let entries: [Entry]

    init(entries: [Entry] = []) { self.entries = entries.sorted { $0.start < $1.start } }

    var isEmpty: Bool { entries.isEmpty }

    /// The account logged in at `date`, or nil for anything before the first
    /// entry — history the app was not running for and cannot honestly claim.
    func accountID(at date: Date) -> String? {
        var match: String?
        for entry in entries {
            if entry.start <= date { match = entry.accountID } else { break }
        }
        return match
    }
}
