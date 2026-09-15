import Foundation

enum UsageTranscriptFormat: String, Codable, Equatable {
    case claude
    case codex
}

/// How sure the ledger is about which account paid for a session.
///
/// The difference matters on screen: a transcript that sits inside an account's
/// own home is a fact, and a transcript in the shared home that merely happened
/// while that account was logged in is a deduction. Showing both as the same
/// thing would be the app inventing certainty it does not have.
enum UsageAttribution: String, Codable, Equatable {
    /// The transcript lives in this account's own profile, or names the vendor
    /// account that owned the session.
    case explicit
    /// Nothing in the file names an account; the app knows which account the
    /// Mac was logged in to at that moment.
    case deduced
    /// Neither is available.
    case unknown

    /// Explicit beats deduced beats unknown when two readings of the same
    /// session disagree.
    var rank: Int {
        switch self {
        case .explicit: return 2
        case .deduced: return 1
        case .unknown: return 0
        }
    }
}

enum UsageMeasurementAvailability: String, Codable, Equatable {
    case unavailable
    case partial
    case complete
}

/// How much of an aggregate was actually present in local telemetry. A missing
/// field is not a measured zero, especially for older reasoning/cache formats.
struct UsageTokenCoverage: Codable, Equatable {
    let records: Int
    let input: UsageMeasurementAvailability
    let output: UsageMeasurementAvailability
    let cacheCreation: UsageMeasurementAvailability
    let cacheRead: UsageMeasurementAvailability
    let reasoning: UsageMeasurementAvailability
    let claudeRecords: Int
    let codexRecords: Int
}

/// Raw token counts, exactly as Claude Code or Codex recorded them. No estimate
/// here: these are the numbers, and every weighting happens elsewhere.
struct UsageTokenTotals: Codable, Equatable {
    /// Uncached, non-cache-write input. Anthropic supplies this directly;
    /// OpenAI supplies inclusive input, which the Codex scanner normalises.
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    /// A subset of `output`, reported separately by the API. Never added to the
    /// weight on its own — doing so would count thinking twice.
    var thinking = 0

    var measurements = 0
    var inputMeasurements = 0
    var outputMeasurements = 0
    var cacheCreationMeasurements = 0
    var cacheReadMeasurements = 0
    var thinkingMeasurements = 0
    var claudeMeasurements = 0
    var codexMeasurements = 0

    var totalInput: Int { input + cacheCreation + cacheRead }
    /// Reasoning is already inside output and is deliberately not added again.
    var total: Int { totalInput + output }
    var measuredReasoning: Int? { thinkingMeasurements > 0 ? thinking : nil }

    var coverage: UsageTokenCoverage {
        func availability(_ measured: Int) -> UsageMeasurementAvailability {
            guard measurements > 0, measured > 0 else { return .unavailable }
            return measured >= measurements ? .complete : .partial
        }
        return UsageTokenCoverage(records: measurements,
                                  input: availability(inputMeasurements),
                                  output: availability(outputMeasurements),
                                  cacheCreation: availability(cacheCreationMeasurements),
                                  cacheRead: availability(cacheReadMeasurements),
                                  reasoning: availability(thinkingMeasurements),
                                  claudeRecords: claudeMeasurements,
                                  codexRecords: codexMeasurements)
    }

    var reasoningAvailability: UsageMeasurementAvailability { coverage.reasoning }

    static func + (lhs: UsageTokenTotals, rhs: UsageTokenTotals) -> UsageTokenTotals {
        UsageTokenTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                         cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                         cacheRead: lhs.cacheRead + rhs.cacheRead, thinking: lhs.thinking + rhs.thinking,
                         measurements: lhs.measurements + rhs.measurements,
                         inputMeasurements: lhs.inputMeasurements + rhs.inputMeasurements,
                         outputMeasurements: lhs.outputMeasurements + rhs.outputMeasurements,
                         cacheCreationMeasurements: lhs.cacheCreationMeasurements + rhs.cacheCreationMeasurements,
                         cacheReadMeasurements: lhs.cacheReadMeasurements + rhs.cacheReadMeasurements,
                         thinkingMeasurements: lhs.thinkingMeasurements + rhs.thinkingMeasurements,
                         claudeMeasurements: lhs.claudeMeasurements + rhs.claudeMeasurements,
                         codexMeasurements: lhs.codexMeasurements + rhs.codexMeasurements)
    }

    static func += (lhs: inout UsageTokenTotals, rhs: UsageTokenTotals) { lhs = lhs + rhs }

    /// The same totals scaled down to a fraction of themselves, for the part of
    /// a session that falls inside a report window. Rounded, never negative.
    func scaled(by factor: Double) -> UsageTokenTotals {
        guard factor.isFinite, factor > 0 else { return UsageTokenTotals() }
        let clamped = min(1, factor)
        func part(_ value: Int) -> Int { max(0, Int((Double(value) * clamped).rounded())) }
        return UsageTokenTotals(input: part(input), output: part(output), cacheCreation: part(cacheCreation),
                                cacheRead: part(cacheRead), thinking: part(thinking),
                                measurements: part(measurements), inputMeasurements: part(inputMeasurements),
                                outputMeasurements: part(outputMeasurements),
                                cacheCreationMeasurements: part(cacheCreationMeasurements),
                                cacheReadMeasurements: part(cacheReadMeasurements),
                                thinkingMeasurements: part(thinkingMeasurements),
                                claudeMeasurements: part(claudeMeasurements),
                                codexMeasurements: part(codexMeasurements))
    }
}

/// Turns token counts into one comparable number.
///
/// The subscription weights Anthropic actually applies are not published, so
/// this is deliberately an *estimate* used only to rank one session against
/// another. It never produces a percentage on its own: the authoritative
/// percentage comes from the usage API, and the ledger only says how to split
/// it. Every number derived from here must be presented as approximate.
enum UsageWeight {
    /// Output costs several times what input costs on every published price
    /// list; five is the round number that ordering is not sensitive to.
    static let outputFactor = 5.0
    /// Writing a cache entry costs a little more than a plain input token.
    static let cacheCreationFactor = 1.25
    /// Reading one costs about a tenth. This is what stops a long agent session
    /// from looking ten times more expensive than it was.
    static let cacheReadFactor = 0.1

    /// How much more a model's tokens count against a subscription window.
    /// Only the ratios matter: the report normalises everything afterwards.
    static func modelFactor(_ model: String?) -> Double {
        guard let model = model?.lowercased(), !model.isEmpty else { return 1 }
        if model.contains("haiku") { return 0.25 }
        if model.contains("sonnet") { return 1 }
        if model.contains("opus") { return 5 }
        // Fable and Mythos sit above Opus in capability and are metered at
        // least as heavily; an unknown premium model must not look cheap.
        if model.contains("fable") || model.contains("mythos") { return 5 }
        return 1
    }

    /// The weight of one assistant turn.
    static func weight(_ tokens: UsageTokenTotals, model: String?) -> Double {
        let base = Double(tokens.input)
            + Double(tokens.output) * outputFactor
            + Double(tokens.cacheCreation) * cacheCreationFactor
            + Double(tokens.cacheRead) * cacheReadFactor
        let weighted = base * modelFactor(model)
        return weighted.isFinite && weighted > 0 ? weighted : 0
    }
}

/// One UTC minute of one session. Minute precision preserves calendar-day
/// boundaries in time zones whose offset is not a whole hour.
struct UsageTimeBucket: Codable, Equatable {
    var tokens = UsageTokenTotals()
    var weight = 0.0
    var messages = 0

    static func + (lhs: UsageTimeBucket, rhs: UsageTimeBucket) -> UsageTimeBucket {
        UsageTimeBucket(tokens: lhs.tokens + rhs.tokens, weight: lhs.weight + rhs.weight,
                        messages: lhs.messages + rhs.messages)
    }
}

/// Everything the ledger knows about one Claude Code session.
///
/// A digest is *mergeable*: the same session is written across several files
/// (the main transcript plus one per subagent), and may exist in more than one
/// home. Merging is addition for the numbers and "best available" for the
/// labels, so the order files are read in never changes the result.
struct UsageSessionDigest: Codable, Equatable {
    var sessionID: String
    var provider: UsageTranscriptFormat
    /// Working directories of the main conversation, by how much was spent in
    /// each. A session that moved between directories is filed where the tokens
    /// actually went, not where it happened to start — and two readings of the
    /// same session can never disagree about it.
    var projectWeights: [String: Double] = [:]
    /// Directories seen only in subagent turns. Subagents run in throwaway
    /// worktrees, so these are used only when a session has no main transcript.
    var fallbackProjectWeights: [String: Double] = [:]
    /// The title Claude Code already wrote for this session. Free, in the
    /// person's own language, and the reason this feature needs no AI call.
    var title: String?
    var firstActivity: Date?
    var lastActivity: Date?
    var tokens = UsageTokenTotals()
    var weight = 0.0
    var messages = 0
    /// Minutes since 1970, as strings so the cache stays plain JSON.
    var activityMinutes: [String: UsageTimeBucket] = [:]
    /// Which model did the work, by weight, so a project can say "mostly Opus".
    var modelWeights: [String: Double] = [:]
    /// The vendor's own account identifier, when the transcript names it.
    var vendorAccountID: String?
    /// The Builder Nutch account whose profile directory holds this file.
    var managedAccountID: String?
    /// Numeric observations only. Optional for migration from the v5 cache.
    var transcriptComponentID: String?
    var recordedEvents: [String: UsageRecordedEvent]?
    /// False when an old aggregate cache supplied the prefix of this digest.
    var recordedEventsComplete: Bool?
    /// Freeze deductions when captured so deleting login history cannot
    /// silently move saved consumption to a different account.
    var archivedAccountID: String?
    var archivedAttribution: UsageAttribution?

    init(sessionID: String, provider: UsageTranscriptFormat = .claude) {
        self.sessionID = sessionID
        self.provider = provider
        self.recordedEvents = [:]
        self.recordedEventsComplete = true
    }

    /// Where the main conversation did most of its work, if anywhere.
    var projectPath: String? { Self.heaviest(projectWeights) }

    /// The project this session is filed under. Never empty: a session with no
    /// usable directory is filed on its own rather than silently joining
    /// someone else's project.
    var resolvedProjectPath: String {
        projectPath ?? Self.heaviest(fallbackProjectWeights) ?? "(unknown)"
    }

    /// The heaviest path, and on a tie the first in alphabetical order so the
    /// same transcripts always produce the same report.
    private static func heaviest(_ weights: [String: Double]) -> String? {
        weights.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }

    mutating func merge(_ other: UsageSessionDigest) {
        if let events = other.recordedEvents {
            if recordedEvents == nil { recordedEvents = [:] }
            recordedEvents?.merge(events) { previous, _ in previous }
        }
        recordedEventsComplete = recordedEventsComplete == true && other.recordedEventsComplete == true
        for (path, value) in other.projectWeights { projectWeights[path, default: 0] += value }
        for (path, value) in other.fallbackProjectWeights { fallbackProjectWeights[path, default: 0] += value }
        title = title ?? other.title
        vendorAccountID = vendorAccountID ?? other.vendorAccountID
        managedAccountID = managedAccountID ?? other.managedAccountID
        firstActivity = [firstActivity, other.firstActivity].compactMap { $0 }.min()
        lastActivity = [lastActivity, other.lastActivity].compactMap { $0 }.max()
        tokens += other.tokens
        weight += other.weight
        messages += other.messages
        for (minute, bucket) in other.activityMinutes {
            activityMinutes[minute] = (activityMinutes[minute] ?? UsageTimeBucket()) + bucket
        }
        for (model, value) in other.modelWeights { modelWeights[model, default: 0] += value }
    }
}

/// Ceilings the scan is not allowed to cross, so a huge or hostile transcript
/// directory can slow the ledger down but never hang the app.
struct UsageLedgerLimits: Equatable {
    /// Files larger than this are read only up to the limit. Nothing on this Mac
    /// comes close; the cap exists so a runaway log cannot own the CPU.
    var maxFileBytes = 64 * 1024 * 1024
    /// One pass looks at this many files at most. The rest keep their cached
    /// digests and are picked up by the next refresh.
    var maxFiles = 5_000
    /// A single line longer than this is skipped rather than buffered.
    var maxLineBytes = 4 * 1024 * 1024
    /// How long a refresh may spend reading. Cached work still counts.
    var timeBudget: TimeInterval = 8
    /// The very first pass has no cache to fall back on, and stopping it early
    /// would show the person a report missing most of their week. It runs off
    /// the main thread, so it is allowed to take its time — once.
    var initialTimeBudget: TimeInterval = 90
    /// Enough sparse minute buckets for a session that ran for three months.
    var maxTimeBucketsPerSession = 24 * 90 * 60
    /// Titles and paths are attacker-controlled text; both are truncated.
    var maxTitleCharacters = 120
    var maxPathCharacters = 512

    static let `default` = UsageLedgerLimits()
}

/// What one refresh actually managed to do. Surfaced in the report because a
/// partial scan must never be presented as a complete picture.
struct UsageScanSummary: Codable, Equatable {
    var filesSeen = 0
    var filesParsed = 0
    var filesFromCache = 0
    var filesSkipped = 0
    /// Files last written before the report's window opens. They cannot hold an
    /// activity minute inside it, so they are never opened — this keeps a refresh
    /// to a few files instead of every transcript ever written.
    var filesOutsideWindow = 0
    var bytesRead = 0
    var malformedLines = 0
    var oversizedLines = 0
    var duration: TimeInterval = 0
    /// True when the pass stopped early. The report is then a floor, not a total.
    var hitLimit = false
}
