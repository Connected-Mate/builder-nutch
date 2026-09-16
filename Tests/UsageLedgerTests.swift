import XCTest
@testable import Codenotch

final class UsageLedgerTests: XCTestCase {
    private var root: URL!
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func assistant(session: String, cwd: String, at date: Date, model: String = "claude-sonnet-5",
                           input: Int = 100, output: Int = 200, cacheRead: Int = 0, cacheCreation: Int = 0,
                           sidechain: Bool = false) -> String {
        """
        {"type":"assistant","sessionId":"\(session)","cwd":"\(cwd)","isSidechain":\(sidechain),\
        "timestamp":"\(Self.stamp.string(from: date))","message":{"model":"\(model)","usage":\
        {"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheCreation),"output_tokens_details":{"thinking_tokens":10}}}}
        """
    }

    private func title(session: String, _ text: String) -> String {
        "{\"type\":\"ai-title\",\"aiTitle\":\"\(text)\",\"sessionId\":\"\(session)\"}"
    }

    private func bridge(session: String, owner: String) -> String {
        "{\"type\":\"bridge-session\",\"sessionId\":\"\(session)\",\"ownerAccountUuid\":\"\(owner)\"}"
    }

    private func codexMeta(session: String, cwd: String) -> String {
        "{\"timestamp\":\"\(Self.stamp.string(from: epoch))\",\"type\":\"session_meta\",\"payload\":{" +
            "\"id\":\"\(session)\",\"cwd\":\"\(cwd)\"}}"
    }

    private func codexRecord(response: String, at date: Date, input: Int, cached: Int, cacheWrite: Int,
                             output: Int, reasoning: Int, thread: String? = nil) -> String {
        let owner = thread.map { "\"thread_id\":\"\($0)\"," } ?? ""
        return "{\"timestamp\":\"\(Self.stamp.string(from: date))\",\"type\":\"token_usage_record\",\"payload\":{" +
            owner + "\"response_id\":\"\(response)\",\"usage\":{" +
            "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)," +
            "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)}," +
            "\"thread_token_usage\":{\"input_tokens\":999999},\"turn_token_usage\":{\"input_tokens\":999999}}}"
    }

    private func codexSnapshot(at date: Date, input: Int, cached: Int, output: Int, reasoning: Int,
                               cacheWrite: Int? = nil) -> String {
        let write = cacheWrite.map { ",\"cache_write_input_tokens\":\($0)" } ?? ""
        return "{\"timestamp\":\"\(Self.stamp.string(from: date))\",\"type\":\"event_msg\",\"payload\":{" +
            "\"type\":\"token_count\",\"info\":{\"total_token_usage\":{" +
            "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)\(write)," +
            "\"output_tokens\":\(output),\"reasoning_output_tokens\":\(reasoning)," +
            "\"total_tokens\":\(input + output)},\"last_token_usage\":{\"input_tokens\":999999}}}}"
    }

    @discardableResult
    private func write(_ lines: [String], to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        try handle.close()
        // A same-second append can leave the modification date untouched, and the
        // cache would then keep serving a stale digest.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    }

    private func engine(_ sources: [UsageLedgerSource], limits: UsageLedgerLimits = .default,
                        timeline: UsageAccountTimeline = UsageAccountTimeline()) -> UsageLedgerEngine {
        UsageLedgerEngine(sources: sources, limits: limits, calendar: utc, timeline: timeline)
    }

    private func digest(session: String, project: String, title: String? = nil, weightPerHour: Double,
                        hours: [Date], managedAccountID: String? = nil, vendorAccountID: String? = nil) -> UsageSessionDigest {
        var digest = UsageSessionDigest(sessionID: session)
        digest.projectWeights[project] = 1
        digest.title = title
        digest.managedAccountID = managedAccountID
        digest.vendorAccountID = vendorAccountID
        for date in hours {
            let minuteKey = String(Int(date.timeIntervalSince1970 / 60))
            var bucket = digest.activityMinutes[minuteKey] ?? UsageTimeBucket()
            bucket.weight += weightPerHour
            bucket.tokens += UsageTokenTotals(input: 10, output: 20, cacheCreation: 0, cacheRead: 0, thinking: 0)
            bucket.messages += 1
            digest.activityMinutes[minuteKey] = bucket
            digest.weight += weightPerHour
            digest.tokens += UsageTokenTotals(input: 10, output: 20, cacheCreation: 0, cacheRead: 0, thinking: 0)
            digest.messages += 1
            digest.firstActivity = min(digest.firstActivity ?? date, date)
            digest.lastActivity = max(digest.lastActivity ?? date, date)
        }
        return digest
    }

    // MARK: - Weighting

    func testOutputAndModelDominateTheWeightWhileCacheReadsBarelyCount() {
        let tokens = UsageTokenTotals(input: 1_000, output: 1_000, cacheCreation: 1_000, cacheRead: 1_000, thinking: 500)
        let sonnet = UsageWeight.weight(tokens, model: "claude-sonnet-5")
        XCTAssertEqual(sonnet, 1_000 + 5_000 + 1_250 + 100, accuracy: 0.001,
                       "Thinking tokens are part of output and must not be counted twice")
        XCTAssertEqual(UsageWeight.weight(tokens, model: "claude-opus-5"), sonnet * 5, accuracy: 0.001)
        XCTAssertEqual(UsageWeight.weight(tokens, model: "claude-haiku-4-5"), sonnet * 0.25, accuracy: 0.001)
        XCTAssertEqual(UsageWeight.weight(tokens, model: "claude-fable-5-1"), sonnet * 5, accuracy: 0.001,
                       "A premium model the app does not recognise must never look cheap")
        XCTAssertEqual(UsageWeight.weight(tokens, model: nil), sonnet, accuracy: 0.001)
        XCTAssertEqual(UsageWeight.weight(UsageTokenTotals(), model: "claude-opus-5"), 0)
    }

    func testTokenCountsRejectAnythingThatIsNotACount() {
        XCTAssertEqual(UsageTranscriptScanner.count(NSNumber(value: 42)), 42)
        XCTAssertEqual(UsageTranscriptScanner.count(NSNumber(value: true)), 0, "A bool is not a token count")
        XCTAssertEqual(UsageTranscriptScanner.count(NSNumber(value: -5)), 0)
        XCTAssertEqual(UsageTranscriptScanner.count("900"), 0)
        XCTAssertEqual(UsageTranscriptScanner.count(nil), 0)
        XCTAssertEqual(UsageTranscriptScanner.count(NSNumber(value: Double.infinity)), 0)
    }

    // MARK: - Scanning

    func testScannerReadsUsageTitleAndVendorAccountFromOneTranscript() throws {
        let session = "11111111-1111-1111-1111-111111111111"
        let file = try write([
            bridge(session: session, owner: "vendor-abc"),
            title(session: session, "Balaye tri des fichiers"),
            assistant(session: session, cwd: "/Users/x/Projects/Balaye", at: epoch, input: 100, output: 200),
            assistant(session: session, cwd: "/Users/x/Projects/Balaye", at: epoch.addingTimeInterval(120), input: 50, output: 10)
        ], to: "projects/-Users-x-Projects-Balaye/\(session).jsonl")

        let outcome = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: session, managedAccountID: nil)
        XCTAssertEqual(outcome.digest.sessionID, session)
        XCTAssertEqual(outcome.digest.title, "Balaye tri des fichiers")
        XCTAssertEqual(outcome.digest.vendorAccountID, "vendor-abc")
        XCTAssertEqual(outcome.digest.projectPath, "/Users/x/Projects/Balaye")
        XCTAssertEqual(outcome.digest.messages, 2)
        XCTAssertEqual(outcome.digest.tokens.input, 150)
        XCTAssertEqual(outcome.digest.tokens.output, 210)
        XCTAssertEqual(outcome.digest.tokens.thinking, 20)
        XCTAssertEqual(outcome.digest.firstActivity, epoch)
        XCTAssertEqual(outcome.digest.lastActivity, epoch.addingTimeInterval(120))
        XCTAssertEqual(outcome.digest.activityMinutes.count, 2)
        XCTAssertEqual(outcome.consumed, UInt64(try Data(contentsOf: file).count))
        XCTAssertEqual(outcome.malformedLines, 0)
        XCTAssertEqual(outcome.digest.tokens.reasoningAvailability, .complete)
        XCTAssertEqual(outcome.digest.tokens.measuredReasoning, 20)
        XCTAssertEqual(outcome.digest.tokens.coverage.claudeRecords, 2)
    }

    func testMissingClaudeThinkingRemainsUnknownAndAggregatesAsPartialCoverage() throws {
        let session = "11111111-1111-1111-1111-111111111112"
        let withoutThinking =
            "{\"type\":\"assistant\",\"sessionId\":\"\(session)\",\"cwd\":\"/tmp/P\"," +
            "\"timestamp\":\"\(Self.stamp.string(from: epoch))\",\"message\":{\"model\":\"claude\",\"usage\":{" +
            "\"input_tokens\":4,\"output_tokens\":6,\"cache_read_input_tokens\":0," +
            "\"cache_creation_input_tokens\":0}}}"
        let file = try write([
            withoutThinking,
            assistant(session: session, cwd: "/tmp/P", at: epoch.addingTimeInterval(1), input: 5, output: 7)
        ], to: "projects/slug/\(session).jsonl")

        let tokens = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: session,
                                                       managedAccountID: nil).digest.tokens
        XCTAssertEqual(tokens.thinking, 7, "Reported thinking is capped to its containing output")
        XCTAssertEqual(tokens.measuredReasoning, 7)
        XCTAssertEqual(tokens.reasoningAvailability, .partial)
        XCTAssertEqual(tokens.coverage.records, 2)
    }

    func testCodexExactRecordsAreNormalisedDeduplicatedAndNeverMixAggregates() throws {
        let session = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let exact = codexRecord(response: "resp_one", at: epoch, input: 100, cached: 60,
                                cacheWrite: 20, output: 30, reasoning: 10, thread: session)
        let child = codexRecord(response: "resp_child", at: epoch, input: 50_000, cached: 40_000,
                                cacheWrite: 0, output: 5_000, reasoning: 2_000,
                                thread: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let file = try write([
            codexMeta(session: session, cwd: "/Users/x/Projects/CodexApp"),
            exact,
            child,
            exact,
            codexSnapshot(at: epoch, input: 8_000, cached: 7_000, output: 900, reasoning: 500)
        ], to: "codex/rollout.jsonl")

        let digest = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: "rollout",
                                                       managedAccountID: nil, format: .codex).digest
        XCTAssertEqual(digest.sessionID, "codex:\(session)")
        XCTAssertEqual(digest.projectPath, "/Users/x/Projects/CodexApp")
        XCTAssertEqual(digest.messages, 1)
        XCTAssertEqual(digest.tokens.input, 20)
        XCTAssertEqual(digest.tokens.cacheRead, 60)
        XCTAssertEqual(digest.tokens.cacheCreation, 20)
        XCTAssertEqual(digest.tokens.totalInput, 100)
        XCTAssertEqual(digest.tokens.output, 30)
        XCTAssertEqual(digest.tokens.thinking, 10)
        XCTAssertEqual(digest.tokens.total, 130)
        XCTAssertEqual(digest.tokens.reasoningAvailability, .complete)
        XCTAssertEqual(digest.tokens.coverage.codexRecords, 1)
    }

    func testCopiedCodexRolloutsUseCanonicalThreadIDAndCountOnce() throws {
        let session = "abababab-abab-abab-abab-abababababab"
        let lines = [
            codexMeta(session: session, cwd: "/tmp/Copied"),
            codexRecord(response: "resp_copy", at: epoch, input: 100, cached: 0,
                        cacheWrite: 0, output: 20, reasoning: 0, thread: session)
        ]
        try write(lines, to: "copies/rollout-original.jsonl")
        try write(lines, to: "copies/rollout-copy.jsonl")
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("copies"),
                                       managedAccountID: nil, format: .codex)
        var cache = UsageLedgerCache()

        let result = engine([source]).scan(cache: &cache)

        XCTAssertEqual(result.sessions.map(\.sessionID), ["codex:\(session)"])
        XCTAssertEqual(result.sessions.first?.messages, 1)
        XCTAssertEqual(result.sessions.first?.tokens.total, 120)
    }

    func testCodexFormatTransitionKeepsLegacyPrefixWithoutCountingLaterSnapshotsTwice() throws {
        let session = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let file = try write([
            codexMeta(session: session, cwd: "/tmp/Mixed"),
            codexSnapshot(at: epoch, input: 100, cached: 0, output: 20, reasoning: 0),
            codexRecord(response: "resp_new", at: epoch.addingTimeInterval(3_600), input: 10, cached: 0,
                        cacheWrite: 0, output: 2, reasoning: 0, thread: session),
            codexSnapshot(at: epoch.addingTimeInterval(3_601), input: 110, cached: 0, output: 22, reasoning: 0)
        ], to: "codex/mixed.jsonl")

        let digest = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: "mixed",
                                                       managedAccountID: nil, format: .codex).digest
        XCTAssertEqual(digest.tokens.total, 132)
        XCTAssertEqual(digest.messages, 2)
    }

    func testLegacyCodexCumulativeSnapshotsBecomeMonotonicDeltasWithResetHandling() throws {
        let session = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let file = try write([
            codexMeta(session: session, cwd: "/tmp/Legacy"),
            codexSnapshot(at: epoch, input: 100, cached: 80, output: 20, reasoning: 5),
            codexSnapshot(at: epoch.addingTimeInterval(60), input: 150, cached: 120, output: 30, reasoning: 8),
            codexSnapshot(at: epoch.addingTimeInterval(61), input: 150, cached: 120, output: 30, reasoning: 8),
            codexSnapshot(at: epoch.addingTimeInterval(120), input: 20, cached: 0, output: 4, reasoning: 1)
        ], to: "codex/legacy.jsonl")

        let tokens = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: "legacy",
                                                       managedAccountID: nil, format: .codex).digest.tokens
        XCTAssertEqual(tokens.totalInput, 170)
        XCTAssertEqual(tokens.input, 50)
        XCTAssertEqual(tokens.cacheRead, 120)
        XCTAssertEqual(tokens.output, 34)
        XCTAssertEqual(tokens.thinking, 9)
        XCTAssertEqual(tokens.measurements, 3, "An unchanged cumulative snapshot contributes no usage")
        XCTAssertEqual(tokens.coverage.cacheCreation, .unavailable)
        XCTAssertEqual(tokens.reasoningAvailability, .complete)
    }

    func testMalformedUnknownAndEmptyLinesCostOneLineAndNothingMore() throws {
        let session = "22222222-2222-2222-2222-222222222222"
        let file = try write([
            "{not json at all, \"usage\": yes}",
            "",
            "{\"type\":\"attachment\",\"content\":\"the word usage appears here\"}",
            "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":\"lots\"}}}",
            assistant(session: session, cwd: "/Users/x/Projects/Ok", at: epoch)
        ], to: "projects/slug/\(session).jsonl")

        let outcome = try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: session, managedAccountID: nil)
        XCTAssertEqual(outcome.digest.messages, 1, "Only the one real turn counts")
        XCTAssertEqual(outcome.malformedLines, 1)
        XCTAssertEqual(outcome.digest.tokens.input, 100)
    }

    func testAnOversizedLineIsSkippedAndTheStreamRecovers() throws {
        let session = "33333333-3333-3333-3333-333333333333"
        let huge = "{\"type\":\"attachment\",\"usage\":\"" + String(repeating: "x", count: 5_000) + "\"}"
        let file = try write([
            huge,
            assistant(session: session, cwd: "/Users/x/Projects/After", at: epoch)
        ], to: "projects/slug/\(session).jsonl")

        var limits = UsageLedgerLimits.default
        limits.maxLineBytes = 1_000
        let outcome = try UsageTranscriptScanner(limits: limits).scan(file: file, from: 0, sessionIDHint: session,
                                                                     managedAccountID: nil)
        XCTAssertEqual(outcome.oversizedLines, 1)
        XCTAssertEqual(outcome.digest.messages, 1, "The turn after the oversized line is still read")
        XCTAssertEqual(outcome.digest.projectPath, "/Users/x/Projects/After")
        XCTAssertEqual(outcome.consumed, UInt64(try Data(contentsOf: file).count),
                       "Resuming must not land inside the skipped line")
    }

    func testTitlesAndPathsAreStrippedOfControlCharactersAndCapped() {
        XCTAssertEqual(UsageText.clean("a\u{0007}b\nc", limit: 100), "abc")
        XCTAssertEqual(UsageText.clean(String(repeating: "z", count: 400), limit: 10), String(repeating: "z", count: 10))
        XCTAssertNil(UsageText.clean("   ", limit: 10))
        XCTAssertNil(UsageText.clean(42, limit: 10))
        XCTAssertNil(UsageText.identifier("../../etc/passwd"), "An identifier is matched on, so its shape is enforced")
        XCTAssertEqual(UsageText.identifier("agent-a93c58e_1"), "agent-a93c58e_1")
        XCTAssertNil(UsageText.date("1970-01-01T00:00:00Z"), "A timestamp outside a sane range widens every window")
        XCTAssertEqual(UsageText.date("2027-01-15T08:00:00.000Z"), epoch)
        XCTAssertEqual(UsageText.date("2027-01-15T08:00:00Z"), epoch, "The fraction is optional")
    }

    // MARK: - Subagents

    func testSubagentTurnsCountButNeverBecomeTheProject() throws {
        let session = "44444444-4444-4444-4444-444444444444"
        try write([
            title(session: session, "Refonte du notch"),
            assistant(session: session, cwd: "/Users/x/Projects/Notch", at: epoch, input: 100, output: 100)
        ], to: "projects/slug/\(session).jsonl")
        try write([
            assistant(session: session, cwd: "/Users/x/.claude/worktrees/agent-99", at: epoch.addingTimeInterval(300),
                      input: 1_000, output: 1_000, sidechain: true)
        ], to: "projects/slug/\(session)/subagents/agent-99.jsonl")

        var cache = UsageLedgerCache()
        let scanned = engine([UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"),
                                                managedAccountID: nil)]).scan(cache: &cache)
        XCTAssertEqual(scanned.sessions.count, 1, "A subagent is part of its session, not a session of its own")
        let session0 = try XCTUnwrap(scanned.sessions.first)
        XCTAssertEqual(session0.messages, 2, "The subagent's tokens are as real as anyone else's")
        XCTAssertEqual(session0.tokens.input, 1_100)
        XCTAssertEqual(session0.resolvedProjectPath, "/Users/x/Projects/Notch")
        XCTAssertEqual(session0.title, "Refonte du notch")
    }

    func testASessionIsFiledWhereItsTokensActuallyWentNotWhereItStarted() throws {
        let session = "88888888-8888-8888-8888-888888888888"
        try write([
            assistant(session: session, cwd: "/Users/x/Projects/Started", at: epoch, input: 10, output: 10),
            assistant(session: session, cwd: "/Users/x/Projects/Real", at: epoch.addingTimeInterval(60),
                      input: 5_000, output: 5_000),
            assistant(session: session, cwd: "/Users/x/Projects/Real", at: epoch.addingTimeInterval(120),
                      input: 5_000, output: 5_000)
        ], to: "projects/slug/\(session).jsonl")

        var cache = UsageLedgerCache()
        let scanned = engine([UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"),
                                                managedAccountID: nil)]).scan(cache: &cache)
        XCTAssertEqual(scanned.sessions.first?.resolvedProjectPath, "/Users/x/Projects/Real")
    }

    func testTwoReadingsOfTheSameSessionCannotDisagreeAboutItsProject() {
        var first = UsageSessionDigest(sessionID: "s")
        first.projectWeights = ["/p/A": 10, "/p/B": 10]
        var second = UsageSessionDigest(sessionID: "s")
        second.projectWeights = ["/p/B": 10, "/p/A": 10]
        XCTAssertEqual(first.resolvedProjectPath, second.resolvedProjectPath,
                       "A tie must break the same way every time or the report moves on its own")
        XCTAssertEqual(first.resolvedProjectPath, "/p/A")
    }

    func testAWorktreeIsFiledUnderTheProjectItWasCutFrom() {
        XCTAssertEqual(
            UsageProjectPath.normalize("/Users/x/Documents/Citizen/.claude/worktrees/agent-a266d14b"),
            "/Users/x/Documents/Citizen",
            "A person does not have a project called agent-a266d14b")
        XCTAssertEqual(UsageProjectPath.normalize("/Users/x/repo/.git/worktrees/feature"), "/Users/x/repo")
        XCTAssertEqual(UsageProjectPath.normalize("/Users/x/.ao/data/worktrees/citizen/citizen-10"),
                       "/Users/x/.ao/data/worktrees/citizen",
                       "A pool of worktrees is still named after the project")
        XCTAssertEqual(UsageProjectPath.normalize("/Users/x/.ao/data/worktrees/citizen/citizen-10/src/app"),
                       "/Users/x/.ao/data/worktrees/citizen")
        // Nothing to fold: these are already projects.
        XCTAssertEqual(UsageProjectPath.normalize("/Users/x/Projects/Balaye"), "/Users/x/Projects/Balaye")
        XCTAssertEqual(UsageProjectPath.normalize("/Users/x/worktrees"), "/Users/x/worktrees")
        XCTAssertEqual(UsageProjectPath.normalize("worktrees"), "worktrees")
        XCTAssertEqual(UsageProjectPath.normalize(""), "")
    }

    func testTwoAgentWorktreesOfOneProjectRankAsOneProject() throws {
        try write([
            title(session: "w1", "Chat IA"),
            assistant(session: "w1", cwd: "/Users/x/Documents/Citizen/.claude/worktrees/agent-1", at: epoch,
                      input: 1_000, output: 1_000)
        ], to: "projects/slug/w1.jsonl")
        try write([
            title(session: "w2", "Site anglais"),
            assistant(session: "w2", cwd: "/Users/x/Documents/Citizen/.claude/worktrees/agent-2", at: epoch,
                      input: 1_000, output: 1_000)
        ], to: "projects/slug/w2.jsonl")

        var cache = UsageLedgerCache()
        let scanned = engine([UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"),
                                                managedAccountID: nil)]).scan(cache: &cache)
        let result = UsageLedgerEngine.report(sessions: scanned.sessions, summary: scanned.summary, days: 3650,
                                              now: epoch.addingTimeInterval(3_600), calendar: utc,
                                              timeline: UsageAccountTimeline())
        let projects = try XCTUnwrap(result.accounts.first?.projects)
        XCTAssertEqual(projects.count, 1, "One project, two agents — not two projects")
        XCTAssertEqual(projects.first?.name, "Citizen")
        XCTAssertEqual(projects.first?.sessionCount, 2)
        XCTAssertEqual(Set(projects.first?.topics.map(\.title) ?? []), ["Chat IA", "Site anglais"],
                       "Folding the directories must not fold the subjects")
    }

    func testSessionIDHintFallsBackToTheOwningSessionForSubagentFiles() {
        let subagent = URL(fileURLWithPath: "/a/projects/slug/abc-123/subagents/agent-x.jsonl")
        XCTAssertEqual(UsageLedgerEngine.sessionIDHint(for: subagent), "abc-123")
        let main = URL(fileURLWithPath: "/a/projects/slug/abc-123.jsonl")
        XCTAssertEqual(UsageLedgerEngine.sessionIDHint(for: main), "abc-123")
    }

    // MARK: - Cache

    func testAnUnchangedFileIsNotReadAgainAndAnAppendedOneResumes() throws {
        let session = "55555555-5555-5555-5555-555555555555"
        let file = try write([
            assistant(session: session, cwd: "/Users/x/Projects/Cache", at: epoch, input: 100, output: 100)
        ], to: "projects/slug/\(session).jsonl")
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"), managedAccountID: nil)

        var cache = UsageLedgerCache()
        let first = engine([source]).scan(cache: &cache)
        XCTAssertEqual(first.summary.filesParsed, 1)
        XCTAssertEqual(first.summary.filesFromCache, 0)
        XCTAssertEqual(first.sessions.first?.messages, 1)

        let unchanged = engine([source]).scan(cache: &cache)
        XCTAssertEqual(unchanged.summary.filesParsed, 0, "Nothing changed, so nothing is read")
        XCTAssertEqual(unchanged.summary.filesFromCache, 1)
        XCTAssertEqual(unchanged.summary.bytesRead, 0)
        XCTAssertEqual(unchanged.sessions.first?.tokens.input, 100)

        try append([assistant(session: session, cwd: "/Users/x/Projects/Cache", at: epoch.addingTimeInterval(3_600),
                              input: 7, output: 3)], to: file)
        let resumed = engine([source]).scan(cache: &cache)
        XCTAssertEqual(resumed.summary.filesParsed, 1)
        let digest = try XCTUnwrap(resumed.sessions.first)
        XCTAssertEqual(digest.messages, 2, "The earlier turn is kept, not re-read and not lost")
        XCTAssertEqual(digest.tokens.input, 107)
        XCTAssertEqual(digest.activityMinutes.count, 2)
        XCTAssertLessThan(resumed.summary.bytesRead, first.summary.bytesRead,
                          "A resumed read only covers the new bytes")
    }

    func testAFileThatShrankIsReadFromTheStartAgain() throws {
        let session = "66666666-6666-6666-6666-666666666666"
        let file = try write([
            assistant(session: session, cwd: "/Users/x/Projects/Shrink", at: epoch, input: 100, output: 100),
            assistant(session: session, cwd: "/Users/x/Projects/Shrink", at: epoch, input: 100, output: 100)
        ], to: "projects/slug/\(session).jsonl")
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"), managedAccountID: nil)

        var cache = UsageLedgerCache()
        _ = engine([source]).scan(cache: &cache)
        try write([assistant(session: session, cwd: "/Users/x/Projects/Shrink", at: epoch, input: 1, output: 1)],
                  to: "projects/slug/\(session).jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        let rescanned = engine([source]).scan(cache: &cache)
        let digest = try XCTUnwrap(rescanned.sessions.first)
        XCTAssertEqual(digest.messages, 1, "A rewritten file must not keep the totals of the file it replaced")
        XCTAssertEqual(digest.tokens.input, 1)
    }

    func testDeletedTranscriptsLeaveTheCache() throws {
        let session = "77777777-7777-7777-7777-777777777777"
        let file = try write([assistant(session: session, cwd: "/Users/x/Projects/Gone", at: epoch)],
                             to: "projects/slug/\(session).jsonl")
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"), managedAccountID: nil)
        var cache = UsageLedgerCache()
        _ = engine([source]).scan(cache: &cache)
        XCTAssertEqual(cache.entries.count, 1)

        try FileManager.default.removeItem(at: file)
        let after = engine([source]).scan(cache: &cache)
        XCTAssertTrue(cache.entries.isEmpty, "A deleted project must not haunt the index")
        XCTAssertTrue(after.sessions.isEmpty)
    }

    func testCacheSurvivesARoundTripAndRefusesAnotherFormula() throws {
        var cache = UsageLedgerCache()
        cache.entries["/a/b.jsonl"] = UsageLedgerCacheEntry(size: 10, modified: epoch, offset: 10,
                                                            digest: digest(session: "s", project: "/p", weightPerHour: 5,
                                                                           hours: [epoch]))
        let url = root.appendingPathComponent("insights/usage-ledger.json")
        cache.save(to: url)
        XCTAssertEqual(UsageLedgerCache.load(from: url), cache)

        var stale = cache
        stale.formula = UsageLedgerCache.currentFormula + 1
        stale.save(to: url)
        XCTAssertTrue(UsageLedgerCache.load(from: url).entries.isEmpty,
                      "Weights computed by an older formula cannot be mixed with new ones")

        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(UsageLedgerCache.load(from: url).entries.isEmpty, "A corrupt cache costs a slow refresh, not an error")
    }

    func testTheFileLimitStopsTheScanAndSaysSo() throws {
        for index in 0..<5 {
            try write([assistant(session: "session-\(index)", cwd: "/Users/x/Projects/Many", at: epoch)],
                      to: "projects/slug/session-\(index).jsonl")
        }
        var limits = UsageLedgerLimits.default
        limits.maxFiles = 2
        var cache = UsageLedgerCache()
        let scanned = engine([UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"),
                                                managedAccountID: nil)], limits: limits).scan(cache: &cache)
        XCTAssertTrue(scanned.summary.hitLimit, "A partial pass must never look like a complete one")
        XCTAssertLessThanOrEqual(scanned.sessions.count, 2)
    }

    func testTranscriptsUntouchedSinceBeforeTheWindowAreNeverOpened() throws {
        let recent = try write([assistant(session: "recent", cwd: "/Users/x/Projects/Now", at: Date())],
                               to: "projects/slug/recent.jsonl")
        let old = try write([assistant(session: "old", cwd: "/Users/x/Projects/Then", at: epoch)],
                            to: "projects/slug/old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
                                              ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)

        var cache = UsageLedgerCache()
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"), managedAccountID: nil)
        let scanned = engine([source]).scan(cache: &cache, horizon: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(scanned.summary.filesParsed, 1)
        XCTAssertEqual(scanned.summary.filesOutsideWindow, 1,
                       "A transcript nobody has written to since before the window cannot be in it")
        XCTAssertEqual(scanned.sessions.map(\.sessionID), ["recent"])
        XCTAssertFalse(scanned.summary.hitLimit)

        // Asking for a longer window reads it after all.
        let wider = engine([source]).scan(cache: &cache, horizon: Date().addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(wider.summary.filesParsed, 1)
        XCTAssertEqual(Set(wider.sessions.map(\.sessionID)), ["recent", "old"])
    }

    func testAPassThatStoppedEarlyDoesNotForgetTheFilesItNeverListed() throws {
        for index in 0..<3 {
            try write([assistant(session: "session-\(index)", cwd: "/Users/x/Projects/Many", at: Date())],
                      to: "projects/slug/session-\(index).jsonl")
        }
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("projects"), managedAccountID: nil)
        var cache = UsageLedgerCache()
        _ = engine([source]).scan(cache: &cache)
        XCTAssertEqual(cache.entries.count, 3)

        var limits = UsageLedgerLimits.default
        limits.maxFiles = 1
        let partial = engine([source], limits: limits).scan(cache: &cache)
        XCTAssertTrue(partial.summary.hitLimit)
        XCTAssertEqual(cache.entries.count, 3, "A partial pass must not prune what it never looked at")
    }

    func testTheSameTranscriptInTwoHomesIsNotCountedTwice() {
        var first = digest(session: "shared", project: "/Users/x/Projects/Copy", weightPerHour: 100, hours: [epoch])
        first.managedAccountID = "profile-a"
        var second = first
        second.managedAccountID = "profile-b"
        let merged = UsageLedgerEngine.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.weight, 100, "A copied home must not double the quota it explains")
    }

    // MARK: - Reporting

    private func report(_ sessions: [UsageSessionDigest], days: Int = 7,
                        timeline: UsageAccountTimeline = UsageAccountTimeline()) -> UsageLedgerReport {
        UsageLedgerEngine.report(sessions: sessions, summary: UsageScanSummary(), days: days,
                                 now: epoch.addingTimeInterval(3_600), calendar: utc, timeline: timeline)
    }

    func testTheReportSplitsByAccountThenProjectThenTopic() throws {
        let big = digest(session: "a", project: "/Users/x/Projects/Citizen", title: "Citizen refonte",
                         weightPerHour: 600, hours: [epoch], managedAccountID: "account-1")
        let alsoBig = digest(session: "b", project: "/Users/x/Projects/Citizen", title: "Citizen refonte",
                             weightPerHour: 200, hours: [epoch.addingTimeInterval(-86_400)], managedAccountID: "account-1")
        let small = digest(session: "c", project: "/Users/x/Projects/Balaye", title: "Balaye tri",
                           weightPerHour: 200, hours: [epoch], managedAccountID: "account-1")

        let result = report([big, alsoBig, small])
        XCTAssertEqual(result.accounts.count, 1)
        let account = try XCTUnwrap(result.accounts.first)
        XCTAssertEqual(account.accountKey, "profile:account-1")
        XCTAssertEqual(account.attribution, .explicit)
        XCTAssertEqual(account.sharePercent, 100)
        XCTAssertEqual(account.sessionCount, 3)
        XCTAssertEqual(account.projects.map(\.name), ["Citizen", "Balaye"], "Ranked by what they actually cost")
        let citizen = try XCTUnwrap(account.projects.first)
        XCTAssertEqual(citizen.sharePercent, 80)
        XCTAssertEqual(citizen.overallSharePercent, 80)
        XCTAssertEqual(citizen.topics.count, 1, "Two sessions on the same subject are one subject")
        XCTAssertEqual(citizen.topics.first?.sessionCount, 2)
        XCTAssertEqual(Set(citizen.topics.first?.sessionIDs ?? []), ["a", "b"])
        XCTAssertEqual(citizen.days.count, 2, "Two days of work show as two days")
        XCTAssertEqual(result.timeline.map(\.day), ["2027-01-14", "2027-01-15"])
        XCTAssertEqual(result.totalWeight, 1_000)
    }

    func testWorkOlderThanTheWindowIsLeftOut() {
        let inside = digest(session: "in", project: "/p/A", weightPerHour: 100, hours: [epoch])
        let outside = digest(session: "out", project: "/p/B", weightPerHour: 900,
                             hours: [epoch.addingTimeInterval(-30 * 86_400)])
        let result = report([inside, outside], days: 7)
        XCTAssertEqual(result.totalWeight, 100)
        XCTAssertEqual(result.accounts.first?.projects.map(\.name), ["A"])
        XCTAssertEqual(report([inside, outside], days: 60).totalWeight, 1_000, "A longer window sees the older work")
    }

    func testOnlyTheHoursInsideTheWindowCountForASessionThatStraddlesIt() throws {
        let straddling = digest(session: "long", project: "/p/Long", weightPerHour: 500,
                                hours: [epoch.addingTimeInterval(-9 * 86_400), epoch])
        let result = report([straddling], days: 7)
        XCTAssertEqual(result.totalWeight, 500, "Last week's half of the session is not this week's quota")
        XCTAssertEqual(result.accounts.first?.projects.first?.sessions.first?.weight, 500)
    }

    func testAProfileIsProofAVendorIsProofAndTheLoginTimelineIsADeduction() throws {
        let owned = digest(session: "owned", project: "/p/A", weightPerHour: 100, hours: [epoch],
                           managedAccountID: "account-1")
        let vendor = digest(session: "vendor", project: "/p/B", weightPerHour: 100, hours: [epoch],
                            vendorAccountID: "anthropic-9")
        let orphan = digest(session: "orphan", project: "/p/C", weightPerHour: 100, hours: [epoch])
        let timeline = UsageAccountTimeline(entries: [.init(start: epoch.addingTimeInterval(-3_600), accountID: "account-2")])

        let result = report([owned, vendor, orphan], timeline: timeline)
        let byKey = Dictionary(uniqueKeysWithValues: result.accounts.map { ($0.accountKey, $0) })
        XCTAssertEqual(byKey["profile:account-1"]?.attribution, .explicit)
        XCTAssertEqual(byKey["vendor:anthropic-9"]?.attribution, .explicit)
        XCTAssertEqual(byKey["profile:account-2"]?.attribution, .deduced, "A login-time match is a deduction, not a fact")
        XCTAssertNil(byKey["unknown"], "The timeline covers this hour, so nothing is left unattributed")

        let unattributed = report([orphan])
        XCTAssertEqual(unattributed.accounts.first?.attribution, .unknown)
        XCTAssertEqual(unattributed.accounts.first?.accountKey, "unknown")
    }

    func testCodexUsageNeverBorrowsClaudeAccountTimelineAttribution() throws {
        var codex = digest(session: "codex:thread", project: "/p/Codex", weightPerHour: 100, hours: [epoch])
        codex.provider = .codex
        let timeline = UsageAccountTimeline(entries: [
            .init(start: epoch.addingTimeInterval(-3_600), accountID: "claude-account")
        ])

        let account = try XCTUnwrap(report([codex], timeline: timeline).accounts.first)
        XCTAssertEqual(account.accountKey, "codex:unknown")
        XCTAssertEqual(account.provider, .codex)
        XCTAssertEqual(account.attribution, .unknown)
        XCTAssertNil(account.managedAccountID)
    }

    func testAnAccountIsOnlyAsSureAsItsLeastSureSession() throws {
        let proven = digest(session: "proven", project: "/p/A", weightPerHour: 100, hours: [epoch],
                            managedAccountID: "account-1")
        let guessed = digest(session: "guessed", project: "/p/A", weightPerHour: 100, hours: [epoch])
        let timeline = UsageAccountTimeline(entries: [.init(start: epoch.addingTimeInterval(-3_600), accountID: "account-1")])
        let account = try XCTUnwrap(report([proven, guessed], timeline: timeline).accounts.first)
        XCTAssertEqual(account.accountKey, "profile:account-1")
        XCTAssertEqual(account.attribution, .deduced)
        XCTAssertEqual(account.weight, 200)
    }

    func testTheLoginTimelineNeverClaimsHistoryFromBeforeItStarted() {
        let timeline = UsageAccountTimeline(entries: [
            .init(start: epoch, accountID: "second"),
            .init(start: epoch.addingTimeInterval(-86_400), accountID: "first")
        ])
        XCTAssertNil(timeline.accountID(at: epoch.addingTimeInterval(-2 * 86_400)))
        XCTAssertEqual(timeline.accountID(at: epoch.addingTimeInterval(-3_600)), "first")
        XCTAssertEqual(timeline.accountID(at: epoch.addingTimeInterval(3_600)), "second")
    }

    func testCalendarWindowUsesRecordedMinuteAcrossFractionalTimeZoneBoundary() throws {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let localQuarterPastMidnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-14T18:45:00Z"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T06:30:00Z"))
        var session = UsageSessionDigest(sessionID: "minute")
        let key = String(Int(localQuarterPastMidnight.timeIntervalSince1970 / 60))
        session.activityMinutes[key] = UsageTimeBucket(
            tokens: UsageTokenTotals(input: 100, output: 20), weight: 200, messages: 1)
        session.tokens = UsageTokenTotals(input: 100, output: 20)
        session.weight = 200
        session.messages = 1
        session.projectWeights["/tmp/Minute"] = 200

        let result = UsageLedgerEngine.report(sessions: [session], summary: UsageScanSummary(), days: 1,
                                              now: now, calendar: india, timeline: UsageAccountTimeline())
        XCTAssertEqual(result.tokens.total, 120)
    }

    func testAnEmptyLedgerIsAnEmptyReportRatherThanADivisionByZero() {
        let result = report([])
        XCTAssertEqual(result.totalWeight, 0)
        XCTAssertTrue(result.accounts.isEmpty)
        XCTAssertTrue(result.timeline.isEmpty)
        XCTAssertEqual(result.sessionCount, 0)
        XCTAssertEqual(UsageLedgerEngine.percent(5, of: 0), 0)
    }

    func testTodayUsesLocalMidnightAcrossDaylightSavingAndCutsEveryTotal() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T12:00:00Z"))
        let midnight = paris.startOfDay(for: now)
        // Spring-forward day is only 23 hours: a rolling 24-hour window leaks
        // yesterday's work. Include exact midnight and exclude future minutes.
        var session = digest(session: "straddling", project: "/p/Today", weightPerHour: 100,
                             hours: [midnight.addingTimeInterval(-60), midnight,
                                     now.addingTimeInterval(-60), now.addingTimeInterval(60)])
        for key in Array(session.activityMinutes.keys) {
            session.activityMinutes[key]?.tokens.thinking = 7
        }
        session.tokens.thinking = 28
        let result = UsageLedgerEngine.report(sessions: [session], summary: UsageScanSummary(), days: 1,
                                              now: now, calendar: paris, timeline: UsageAccountTimeline())
        XCTAssertEqual(result.windowStart, midnight)
        XCTAssertEqual(result.windowEnd, now)
        XCTAssertEqual(result.days, 1)
        XCTAssertEqual(result.tokens.input, 20)
        XCTAssertEqual(result.tokens.output, 40)
        XCTAssertEqual(result.tokens.thinking, 14, "Reasoning stays a subset of today's output")
        XCTAssertEqual(result.tokens.total, 60)
        XCTAssertEqual(result.messages, 2)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.timeline.map(\.day), ["2026-03-29"])
        XCTAssertEqual(result.timeline.first?.tokens, result.tokens)
        let project = try XCTUnwrap(result.accounts.first?.projects.first)
        XCTAssertEqual(project.tokens, result.tokens)
        XCTAssertEqual(project.days.first?.tokens, result.tokens)
        XCTAssertEqual(UsageShareSnapshot(report: result, period: .day).todayTokens, result.tokens)
    }

    func testTodayEmptyDoesNotIncludeYesterdayOrChangeLongerPeriods() {
        let yesterday = utc.startOfDay(for: epoch).addingTimeInterval(-60)
        let session = digest(session: "yesterday", project: "/p/Yesterday", weightPerHour: 100,
                             hours: [yesterday])
        let today = report([session], days: 1)
        XCTAssertEqual(today.tokens.total, 0)
        XCTAssertEqual(today.sessionCount, 0)
        XCTAssertTrue(today.accounts.isEmpty)
        XCTAssertTrue(today.timeline.isEmpty)
        XCTAssertEqual(UsageShareSnapshot(report: today, period: .day).todayTokens.total, 0)
        XCTAssertEqual(report([session], days: 7).tokens.total, 30)
        XCTAssertEqual(report([session], days: 30).tokens.total, 30)
    }

    func testASessionWithNoUsableDirectoryIsFiledOnItsOwn() {
        var homeless = UsageSessionDigest(sessionID: "nowhere")
        homeless.activityMinutes["\(Int(epoch.timeIntervalSince1970 / 60))"] = UsageTimeBucket(
            tokens: UsageTokenTotals(), weight: 10, messages: 1)
        homeless.weight = 10
        XCTAssertEqual(homeless.resolvedProjectPath, "(unknown)")
        XCTAssertEqual(report([homeless]).accounts.first?.projects.first?.name, "(unknown)",
                       "An unfiled session must not silently join someone else's project")
    }

    // MARK: - End to end

    func testTheLedgerActorReadsRealFilesAndRanksTheProjects() async throws {
        let session1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let session2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let now = Date()
        try write([
            title(session: session1, "Gros projet"),
            assistant(session: session1, cwd: "/Users/x/Projects/Gros", at: now.addingTimeInterval(-3_600),
                      model: "claude-opus-5", input: 1_000, output: 5_000)
        ], to: "home/.claude/projects/slug/\(session1).jsonl")
        try write([
            title(session: session2, "Petit projet"),
            assistant(session: session2, cwd: "/Users/x/Projects/Petit", at: now.addingTimeInterval(-7_200),
                      model: "claude-haiku-4-5", input: 10, output: 10)
        ], to: "profiles/\(UUID().uuidString)/projects/slug/\(session2).jsonl")

        let profileDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("profiles"),
                                                        includingPropertiesForKeys: nil).first)
        let ledger = UsageLedger(
            sources: [UsageLedgerSource(projectsRoot: root.appendingPathComponent("home/.claude/projects"), managedAccountID: nil),
                      UsageLedgerSource(projectsRoot: profileDirectory.appendingPathComponent("projects"),
                                        managedAccountID: profileDirectory.lastPathComponent.lowercased())],
            cacheURL: root.appendingPathComponent("insights/usage-ledger.json"),
            calendar: utc)

        let result = await ledger.report(days: 7, now: now)
        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(result.accounts.count, 2, "Two homes, two accounts")
        let ranked = result.accounts.flatMap(\.projects).sorted { $0.weight > $1.weight }
        XCTAssertEqual(ranked.map(\.name), ["Gros", "Petit"])
        XCTAssertEqual(ranked.first?.topics.first?.title, "Gros projet")
        XCTAssertGreaterThan(try XCTUnwrap(ranked.first?.overallSharePercent), 99)
        XCTAssertEqual(result.scan.filesParsed, 2)

        // Second pass: nothing changed on disk, so nothing is read again.
        let again = await ledger.report(days: 7, now: now)
        XCTAssertEqual(again.scan.filesParsed, 0)
        XCTAssertEqual(again.scan.filesFromCache, 2)
        XCTAssertEqual(again.totalWeight, result.totalWeight)
    }

    func testUnchangedTruncatedTranscriptResumesAndKeepsPartialFlagUntilComplete() throws {
        let session = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        var lines = [codexMeta(session: session, cwd: "/tmp/Long")]
        lines += (0..<3_000).map {
            codexRecord(response: "resp_\($0)", at: epoch, input: 100, cached: 0,
                        cacheWrite: 0, output: 20, reasoning: 0, thread: session)
        }
        try write(lines, to: "long/rollout.jsonl")
        var limits = UsageLedgerLimits.default
        limits.maxFileBytes = 1_000
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("long"),
                                       managedAccountID: nil, format: .codex)
        var cache = UsageLedgerCache()

        let first = engine([source], limits: limits).scan(cache: &cache)
        XCTAssertTrue(first.summary.hitLimit)
        XCTAssertLessThan(first.sessions.first?.messages ?? 0, 3_000)
        XCTAssertEqual(cache.entries.values.first?.truncated, true)

        let second = engine([source], limits: limits).scan(cache: &cache)
        XCTAssertFalse(second.summary.hitLimit)
        XCTAssertEqual(second.sessions.first?.messages, 3_000)
        XCTAssertEqual(cache.entries.values.first?.truncated, false)
    }

    func testResumedClaudeTranscriptKeepsCanonicalSessionIDFromEarlierSlice() throws {
        let session = "fefefefe-fefe-fefe-fefe-fefefefefefe"
        let usage = "{\"type\":\"assistant\",\"cwd\":\"/tmp/Long\",\"timestamp\":\"\(Self.stamp.string(from: epoch))\",\"message\":{\"model\":\"claude\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}"
        var lines = [title(session: session, "Long transcript")]
        lines += Array(repeating: usage, count: 2_000)
        try write(lines, to: "long-claude/renamed.jsonl")
        var limits = UsageLedgerLimits.default
        limits.maxFileBytes = 1_000
        let source = UsageLedgerSource(projectsRoot: root.appendingPathComponent("long-claude"),
                                       managedAccountID: nil, format: .claude)
        var cache = UsageLedgerCache()

        let first = engine([source], limits: limits).scan(cache: &cache)
        let second = engine([source], limits: limits).scan(cache: &cache)

        XCTAssertTrue(first.summary.hitLimit)
        XCTAssertEqual(second.sessions.first?.sessionID, session)
        XCTAssertEqual(second.sessions.first?.messages, 2_000)
    }

    func testTheDumpRanksAProjectOnceHoweverManyAccountsPaidForIt() throws {
        let first = digest(session: "a", project: "/Users/x/Projects/Citizen", title: "Citizen",
                           weightPerHour: 300, hours: [epoch], managedAccountID: "account-1")
        let second = digest(session: "b", project: "/Users/x/Projects/Citizen", title: "Citizen",
                            weightPerHour: 300, hours: [epoch], managedAccountID: "account-2")
        let other = digest(session: "c", project: "/Users/x/Projects/Balaye", title: "Balaye",
                           weightPerHour: 400, hours: [epoch], managedAccountID: "account-1")
        let result = report([first, second, other])
        let ranked = UsageLedgerDump.Dump.ranking(report: result, labels: ["account-1": "Perso", "account-2": "Pro"])

        XCTAssertEqual(ranked.map(\.project), ["Citizen", "Balaye"],
                       "A project split over two subscriptions is still one project")
        XCTAssertEqual(ranked.first?.sharePercent, 60)
        XCTAssertEqual(ranked.first?.sessions, 2)
        XCTAssertEqual(Set(ranked.first?.accounts ?? []), ["Perso", "Pro"])
        XCTAssertEqual(ranked.last?.accounts, ["Perso"])
    }

    func testTheDumpClampsItsDayArgument() {
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--dump-usage-ledger"]), 7)
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--days", "30"]), 30)
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--days", "0"]), 1)
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--days", "9999"]), 365)
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--days", "soon"]), 7)
        XCTAssertEqual(UsageLedgerDump.days(in: ["app", "--days"]), 7)
    }
}
