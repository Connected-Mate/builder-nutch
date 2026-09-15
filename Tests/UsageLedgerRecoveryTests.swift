import XCTest
@testable import Codenotch

final class UsageLedgerRecoveryTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_500)
    private var source: URL { root.appendingPathComponent("source") }
    private var cacheURL: URL { root.appendingPathComponent("cache/usage.json") }
    private var archiveURL: URL { root.appendingPathComponent("history/usage.json") }
    private let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"recovery-session\",\"cwd\":\"/projects/recovered\"}}"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func snapshot(input: Int, output: Int, cached: Int, reasoning: Int, seconds: Int,
                          lastInput: Int? = nil, lastOutput: Int? = nil) -> String {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(seconds - 400)))
        let last = lastInput.map { ",\"last_token_usage\":{\"input_tokens\":\($0),\"output_tokens\":\(lastOutput ?? 0)}" } ?? ""
        return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cached_input_tokens\":\(cached),\"reasoning_output_tokens\":\(reasoning)}\(last)}}}"
    }

    @discardableResult
    private func write(_ lines: [String], to url: URL? = nil) throws -> URL {
        let url = url ?? source.appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func ledger() -> UsageLedger {
        UsageLedger(sources: [.init(projectsRoot: source, managedAccountID: nil, format: .codex)],
                    cacheURL: cacheURL, archiveURL: archiveURL)
    }

    private func scan(_ file: URL) throws -> UsageSessionDigest {
        try UsageTranscriptScanner().scan(file: file, from: 0, sessionIDHint: "history", managedAccountID: nil, format: .codex).digest
    }

    private func oldDigest(from digest: UsageSessionDigest, events: Bool) -> UsageSessionDigest {
        var old = UsageSessionDigest(sessionID: digest.sessionID, provider: digest.provider)
        old.recordedEvents = events ? [:] : nil
        old.recordedEventsComplete = events ? true : nil
        for (id, event) in digest.recordedEvents ?? [:] {
            var former = event
            if let derivation = event.cumulative {
                former.tokens = derivation.legacyTokens
                former.weight = UsageWeight.weight(former.tokens, model: former.model)
            }
            former.cumulative = nil
            former.add(to: &old)
            if events { old.recordedEvents?[id] = former }
        }
        return old
    }

    func testCrossChunkOffsetsEqualBytesConsumedAndAppendRemainsExact() throws {
        let huge = "{\"type\":\"user\",\"padding\":\"" + String(repeating: "x", count: 262_200) + "\"}"
        let first = snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0)
        let file = try write([meta, huge, first])
        let scanner = UsageTranscriptScanner()
        let initial = try scanner.scan(file: file, from: 0, sessionIDHint: "history", managedAccountID: nil, format: .codex)
        XCTAssertEqual(initial.consumed, UInt64(try Data(contentsOf: file).count))
        try write([meta, huge, first, snapshot(input: 110, output: 25, cached: 80, reasoning: 12, seconds: 60)])
        let suffix = try scanner.scan(file: file, from: initial.consumed, sessionIDHint: "history", managedAccountID: nil,
                                      format: .codex, checkpoint: initial.checkpoint)
        XCTAssertEqual(suffix.digest.tokens.total, 15)
        XCTAssertEqual(suffix.consumed, UInt64(try Data(contentsOf: file).count))
    }

    func testDetailOnlyDropRepairsSavedEventsAndKeepsOriginalBackup() async throws {
        let first = snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0)
        let second = snapshot(input: 110, output: 25, cached: 70, reasoning: 9, seconds: 60)
        let file = try write([meta, first, second])
        let corrected = try scan(file)
        XCTAssertEqual(corrected.tokens.total, 135)
        let old = oldDigest(from: corrected, events: true)
        XCTAssertEqual(old.tokens.total, 255)
        _ = try UsageLedgerArchiveStore.update(at: archiveURL, now: now) { $0.absorb([old], timeline: .init()) }
        let original = try Data(contentsOf: archiveURL)
        let repaired = await ledger().report(now: now)
        XCTAssertEqual(repaired.tokens.total, 135)
        XCTAssertEqual(repaired.persistence.state, .saved)
        XCTAssertEqual(try Data(contentsOf: UsageLedgerArchiveStore.correctionBackupURL(for: archiveURL)), original)
        // A stale cache/import may not inflate the repaired snapshot again.
        let restored = try UsageLedgerArchiveStore.update(at: archiveURL, now: now) { $0.absorb([old], timeline: .init()) }
        XCTAssertEqual(restored.digests.reduce(0) { $0 + $1.tokens.total }, 135)
        try write([meta, second])
        try FileManager.default.removeItem(at: cacheURL)
        let suffixOnly = await ledger().report(now: now)
        XCTAssertEqual(suffixOnly.tokens.total, 135)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: cacheURL)
        let restarted = await ledger().report(now: now)
        XCTAssertEqual(restarted.tokens.total, 135)
    }

    func testCompleteReplayRepairsMatchingInflatedLegacyFloorOnly() async throws {
        let file = try write([meta,
            snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0),
            snapshot(input: 110, output: 25, cached: 70, reasoning: 9, seconds: 60)])
        let corrected = try scan(file)
        let old = oldDigest(from: corrected, events: false)
        var unrelated = old
        unrelated.sessionID = "deleted-session"
        _ = try UsageLedgerArchiveStore.update(at: archiveURL, now: now) { $0.absorb([old, unrelated], timeline: .init()) }
        let original = try Data(contentsOf: archiveURL)
        let repaired = await ledger().report(now: now)
        XCTAssertEqual(repaired.tokens.total, 135 + 255, "Only the replay-proven source is corrected; deleted-only history survives")
        XCTAssertEqual(try Data(contentsOf: UsageLedgerArchiveStore.correctionBackupURL(for: archiveURL)), original)
    }

    func testBackwardsSnapshotThatStillIncludesEarlierRequestsIsNotAReset() throws {
        let file = try write([meta,
            snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0, lastInput: 100, lastOutput: 20),
            snapshot(input: 95, output: 19, cached: 75, reasoning: 9, seconds: 60, lastInput: 5, lastOutput: 1),
            snapshot(input: 110, output: 25, cached: 85, reasoning: 12, seconds: 120, lastInput: 15, lastOutput: 6)])
        let digest = try scan(file)
        XCTAssertEqual(digest.tokens.total, 135)
        XCTAssertEqual(digest.tokens.thinking, 12)
        XCTAssertEqual(digest.messages, 2)
    }

    func testArchivedCodexSourcesAreIncludedAndCopiedSessionsCountOnce() async throws {
        let active = root.appendingPathComponent(".codex/sessions/active.jsonl")
        let archived = root.appendingPathComponent(".codex/archived_sessions/archived.jsonl")
        let lines = [meta, snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0)]
        try write(lines, to: active)
        try write(lines, to: archived)
        try write(lines.map { $0.replacingOccurrences(of: "recovery-session", with: "unique-archived-session") },
                  to: root.appendingPathComponent(".codex/archived_sessions/unique.jsonl"))
        let sources = UsageLedger.defaultSources(home: root, catalogRoot: root.appendingPathComponent("catalog"))
        let collector = UsageLedger(sources: sources, cacheURL: cacheURL, archiveURL: archiveURL)
        let report = await collector.report(now: now)
        XCTAssertEqual(report.tokens.total, 240)
        XCTAssertEqual(report.sessionCount, 2)
    }

    func testV5CompletedCacheCheckpointIsReplayedUnderNewParser() async throws {
        let file = try write([meta, snapshot(input: 100, output: 20, cached: 80, reasoning: 10, seconds: 0)])
        var cache = UsageLedgerCache()
        _ = UsageLedgerEngine(sources: [.init(projectsRoot: source, managedAccountID: nil, format: .codex)]).scan(cache: &cache)
        cache.version = 5
        for path in cache.entries.keys { cache.entries[path]?.offset = 1 }
        cache.save(to: cacheURL)
        let report = await ledger().report(now: now)
        XCTAssertEqual(report.scan.filesParsed, 1)
        XCTAssertEqual(report.tokens.total, 120)
        XCTAssertEqual(UsageLedgerCache.load(from: cacheURL).entries.values.first?.offset, UInt64(try Data(contentsOf: file).count))
    }
    func testOversizedCachePreservesCheckpointAndCursorWithBoundedCompressedDecode() throws {
        var cache = UsageLedgerCache()
        var digest = UsageSessionDigest(sessionID: "large-index")
        digest.title = String(repeating: "x", count: UsageLedgerCache.maximumBytes + 1)
        cache.entries["/synthetic.jsonl"] = UsageLedgerCacheEntry(size: 1234, modified: now, offset: 900, digest: digest, truncated: true)
        cache.scanCursor = UsageLedgerScanCursor(sourceRoot: "/source", filePath: "/synthetic.jsonl")
        cache.scanSeenPaths = ["/synthetic.jsonl"]
        XCTAssertTrue(cache.save(to: cacheURL))
        let stored = try Data(contentsOf: cacheURL)
        XCTAssertTrue(stored.starts(with: Data("BNLC1".utf8)))
        XCTAssertLessThan(stored.count, UsageLedgerCache.maximumBytes)
        XCTAssertEqual(UsageLedgerCache.load(from: cacheURL), cache)
        XCTAssertEqual(try UsageLedgerCache.loadForArchive(from: cacheURL), cache)
        // A forged expanded length is rejected before allocating its buffer.
        var oversized = Data("BNLC1".utf8)
        var size = UInt64(UsageLedgerCache.maximumExpandedBytes + 1).littleEndian
        withUnsafeBytes(of: &size) { oversized.append(contentsOf: $0) }
        oversized.append(0)
        try oversized.write(to: cacheURL)
        XCTAssertThrowsError(try UsageLedgerCache.loadForArchive(from: cacheURL))
    }

    func testSweepCannotReportCompleteWhilePreviouslyVisitedFileIsStillPartial() throws {
        let largeRoot = root.appendingPathComponent("large")
        let smallRoot = root.appendingPathComponent("small")
        let large = [meta] + (0..<2_000).map { snapshot(input: $0 + 1, output: $0 + 1, cached: 0, reasoning: 0, seconds: $0) }
        try write(large, to: largeRoot.appendingPathComponent("large.jsonl"))
        try write([meta, snapshot(input: 10, output: 2, cached: 0, reasoning: 0, seconds: 0)],
                  to: smallRoot.appendingPathComponent("small.jsonl"))
        var limits = UsageLedgerLimits.default
        limits.maxFiles = 1
        limits.maxFileBytes = 1_000
        let engine = UsageLedgerEngine(sources: [.init(projectsRoot: largeRoot, managedAccountID: nil, format: .codex),
                                                .init(projectsRoot: smallRoot, managedAccountID: nil, format: .codex)], limits: limits)
        var cache = UsageLedgerCache()
        XCTAssertTrue(engine.scan(cache: &cache).summary.hitLimit)
        let second = engine.scan(cache: &cache)
        XCTAssertTrue(cache.entries.values.contains(where: \.truncated))
        XCTAssertTrue(second.summary.hitLimit)
        XCTAssertEqual(second.summary.filesSeen, 1)
    }

}
