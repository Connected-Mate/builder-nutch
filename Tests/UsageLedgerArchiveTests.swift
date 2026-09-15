import XCTest
import Darwin
@testable import Codenotch

final class UsageLedgerArchiveTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_300)
    private var source: URL { root.appendingPathComponent("transcripts") }
    private var cacheURL: URL { root.appendingPathComponent("cache/usage.json") }
    private var archiveURL: URL { root.appendingPathComponent("history/usage.json") }
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func ledger(limits: UsageLedgerLimits = .default, timeline: UsageAccountTimeline = .init()) -> UsageLedger {
        UsageLedger(sources: [.init(projectsRoot: source, managedAccountID: nil)], cacheURL: cacheURL,
                    limits: limits, calendar: calendar, timeline: timeline, archiveURL: archiveURL)
    }

    private func line(_ id: String, input: Int = 100, secondsAgo: TimeInterval = 300, session: String = "session-a") -> String {
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
        return """
        {"type":"assistant","uuid":"\(id)","sessionId":"\(session)","cwd":"/projects/saved","timestamp":"\(timestamp)","message":{"model":"claude-sonnet-5","content":"SECRET_CONVERSATION_MUST_NOT_PERSIST","usage":{"input_tokens":\(input),"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":40,"output_tokens_details":{"thinking_tokens":8}}}}
        """
    }

    @discardableResult
    private func write(_ lines: [String], name: String = "original.jsonl") throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func clearCache() throws {
        if FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }
    }

    func testDeletionCacheClearingRestartAndRenamedCopiesPreserveEveryTokenAndDay() async throws {
        let lines = [line("a", secondsAgo: 86_700), line("b")]
        let original = try write(lines)
        let first = await ledger().report(days: 7, now: now)
        XCTAssertEqual(first.persistence.state, .saved)
        XCTAssertEqual(first.tokens.total, 326)
        XCTAssertEqual(first.tokens.thinking, 16)
        XCTAssertEqual(first.timeline.count, 2)
        try FileManager.default.removeItem(at: original)
        try clearCache()
        let restarted = await ledger().report(days: 7, now: now)
        XCTAssertEqual(restarted.tokens, first.tokens)
        XCTAssertEqual(restarted.timeline, first.timeline)
        XCTAssertEqual(restarted.accounts, first.accounts)
        try write(lines, name: "renamed-copy.jsonl")
        try write(lines, name: "second-copy.jsonl")
        let restored = await ledger().report(days: 7, now: now)
        XCTAssertEqual(restored.tokens, first.tokens)
        XCTAssertEqual(restored.timeline, first.timeline)
        try write(lines + [line("c", input: 17, secondsAgo: 299)], name: "second-copy.jsonl")
        let appended = await ledger().report(days: 7, now: now)
        XCTAssertEqual(appended.tokens.total, first.tokens.total + 80)
        let repeated = await ledger().report(days: 7, now: now)
        XCTAssertEqual(repeated.tokens, appended.tokens)
        let archive = try UsageLedgerArchiveStore.read(from: archiveURL)
        let json = String(data: try JSONEncoder().encode(archive), encoding: .utf8)!
        XCTAssertFalse(json.contains("SECRET_CONVERSATION"))
        XCTAssertFalse(json.contains("\"title\":"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTruncatedReplacementEvenWhenLargerAddsNewIDsExactlyOnce() async throws {
        try write([line("a"), line("b")])
        let collector = ledger()
        let first = await collector.report(now: now)
        // Replacement exceeds the old byte length but contains no old prefix.
        try write([line("c"), line("d"), line("e")])
        let second = await collector.report(now: now)
        XCTAssertEqual(second.tokens.total, first.tokens.total + 489)
        try clearCache()
        let restarted = await ledger().report(now: now)
        XCTAssertEqual(restarted.tokens, second.tokens)
    }

    func testV5CacheMigratesBeforeMissingPathsArePrunedThenReconcilesReplayAndSuffix() async throws {
        let lines = [line("a"), line("b", secondsAgo: 299)]
        let original = try write(lines)
        var cache = UsageLedgerCache()
        let engine = UsageLedgerEngine(sources: [.init(projectsRoot: source, managedAccountID: nil)])
        let before = engine.scan(cache: &cache)
        for path in cache.entries.keys {
            cache.entries[path]?.digest.recordedEvents = nil
            cache.entries[path]?.digest.recordedEventsComplete = nil
            cache.entries[path]?.resumeFingerprint = nil
        }
        cache.save(to: cacheURL)
        try FileManager.default.removeItem(at: original)
        let migrated = await ledger().report(now: now)
        XCTAssertEqual(migrated.tokens, before.sessions[0].tokens)
        try clearCache()
        try write(lines + [line("c", input: 19, secondsAgo: 298)], name: "restored-elsewhere.jsonl")
        let restored = await ledger().report(now: now)
        XCTAssertEqual(restored.tokens.total, migrated.tokens.total + 82)
        XCTAssertEqual(restored.tokens.thinking, 24)
        let repeated = await ledger().report(now: now)
        XCTAssertEqual(repeated.tokens, restored.tokens)
    }

    func testLegacyMigrationSurvivesCacheFormulaChange() async throws {
        try write([line("a")])
        var cache = UsageLedgerCache()
        _ = UsageLedgerEngine(sources: [.init(projectsRoot: source, managedAccountID: nil)]).scan(cache: &cache)
        cache.formula = 999
        cache.version = 6
        for path in cache.entries.keys {
            cache.entries[path]?.digest.recordedEvents = nil
            cache.entries[path]?.digest.recordedEventsComplete = nil
        }
        cache.save(to: cacheURL)
        try FileManager.default.removeItem(at: source.appendingPathComponent("original.jsonl"))
        let result = await ledger().report(now: now)
        XCTAssertEqual(result.tokens.total, 163)
        XCTAssertEqual(result.persistence.state, .saved)
    }

    func testCorruptionBlocksOverwriteAndCachePruning() async throws {
        try write([line("a")])
        let collector = ledger()
        let first = await collector.report(now: now)
        let cacheBefore = try Data(contentsOf: cacheURL)
        let corrupt = Data("broken durable history".utf8)
        try corrupt.write(to: archiveURL)
        try write([line("a"), line("b")])
        let failed = await collector.report(now: now)
        XCTAssertEqual(failed.persistence.state, .failed)
        XCTAssertNotNil(failed.persistence.message)
        XCTAssertEqual(failed.tokens, first.tokens)
        XCTAssertEqual(try Data(contentsOf: archiveURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: cacheURL), cacheBefore)
        let restarted = await ledger().capture(now: now)
        XCTAssertEqual(restarted.persistence.state, .failed)
        XCTAssertEqual(try Data(contentsOf: archiveURL), corrupt)
    }

    func testWriteFailureIsNotReportedAsSavedAndDoesNotReplaceCache() async throws {
        try write([line("a")])
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Existing directory at destination makes any commit impossible.
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        let result = await ledger().capture(now: now)
        XCTAssertEqual(result.persistence.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path, isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
    }

    func testSavedAttributionSurvivesLoginTimelineRemoval() async throws {
        try write([line("a")])
        let timeline = UsageAccountTimeline(entries: [.init(start: now.addingTimeInterval(-1_000), accountID: "account-a")])
        let first = await ledger(timeline: timeline).report(now: now)
        XCTAssertEqual(first.accounts.first?.attribution, .deduced)
        try FileManager.default.removeItem(at: source.appendingPathComponent("original.jsonl"))
        try clearCache()
        let second = await ledger().report(now: now)
        XCTAssertEqual(second.accounts, first.accounts)
    }

    func testBoundedScanMakesProgressAndEventuallyPersistsAllRecords() async throws {
        try write((0..<900).map { line("request-\($0)", secondsAgo: TimeInterval(300 + $0)) })
        var limits = UsageLedgerLimits.default
        limits.maxFileBytes = 600
        let collector = ledger(limits: limits)
        let first = await collector.report(now: now)
        XCTAssertTrue(first.scan.hitLimit)
        var result = first
        for _ in 0..<5 where result.scan.hitLimit { result = await collector.report(now: now) }
        XCTAssertEqual(result.tokens.total, 900 * 163)
        XCTAssertFalse(result.scan.hitLimit)
        try FileManager.default.removeItem(at: source.appendingPathComponent("original.jsonl"))
        try clearCache()
        let restarted = await ledger().report(now: now)
        XCTAssertEqual(restarted.tokens, result.tokens)
    }
    func testCodexCanonicalIDCopyAppendAndCumulativeHistorySurviveRestart() async throws {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"cwd\":\"/projects/codex\"}}"
        let cumulative = "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":30,\"reasoning_output_tokens\":10}}}}"
        func record(_ id: String) -> String {
            "{\"timestamp\":\"\(stamp)\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"\(id)\",\"thread_id\":\"thread-a\",\"usage\":{\"input_tokens\":50,\"cached_input_tokens\":10,\"cache_write_input_tokens\":4,\"output_tokens\":20,\"reasoning_output_tokens\":7}}}"
        }
        func codexLedger() -> UsageLedger {
            UsageLedger(sources: [.init(projectsRoot: source, managedAccountID: nil, format: .codex)],
                        cacheURL: cacheURL, calendar: calendar, archiveURL: archiveURL)
        }
        let original = try write([meta, cumulative, record("response-a")])
        let first = await codexLedger().report(now: now)
        XCTAssertEqual(first.tokens.total, 200)
        XCTAssertEqual(first.tokens.thinking, 17)
        XCTAssertEqual(first.tokens.cacheCreation, 4)
        XCTAssertEqual(first.tokens.coverage.cacheCreation, .partial)
        try FileManager.default.removeItem(at: original)
        try clearCache()
        let restored = await codexLedger().report(now: now)
        XCTAssertEqual(restored.tokens, first.tokens)
        try write([meta, cumulative, record("response-a"), record("response-b")], name: "copied-rollout.jsonl")
        let appended = await codexLedger().report(now: now)
        XCTAssertEqual(appended.tokens.total, 270)
        XCTAssertEqual(appended.tokens.thinking, 24)
        let repeated = await codexLedger().report(now: now)
        XCTAssertEqual(repeated.tokens, appended.tokens)
    }

    func testArchiveLockAndUnsupportedVersionProtectExistingBytes() async throws {
        try write([line("a")])
        let initial = await ledger().capture(now: now)
        XCTAssertEqual(initial.persistence.state, .saved)
        let before = try Data(contentsOf: archiveURL)
        let descriptor = open(archiveURL.appendingPathExtension("lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let blocked = await ledger().capture(now: now)
        XCTAssertEqual(blocked.persistence.state, .failed)
        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        archive["version"] = 999
        let newerPayload = try JSONSerialization.data(withJSONObject: archive)
        envelope["payload"] = newerPayload.base64EncodedString()
        envelope["checksum"] = UsageRecordedEvent.hash(newerPayload)
        let newer = try JSONSerialization.data(withJSONObject: envelope)
        try newer.write(to: archiveURL)
        let incompatible = await ledger().capture(now: now)
        XCTAssertEqual(incompatible.persistence.state, .failed)
        XCTAssertEqual(try Data(contentsOf: archiveURL), newer)
    }

    func testUpdatedSourcesAreCapturedAndOldDatesAreNotFilteredByReportWindow() async throws {
        let collector = ledger()
        _ = await collector.capture(now: now)
        let old = try write([line("old", secondsAgo: 40 * 86_400)])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        let newRoot = root.appendingPathComponent("new-profile")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try Data((line("new", session: "new-session") + "\n").utf8).write(to: newRoot.appendingPathComponent("new.jsonl"))
        await collector.updateSources([.init(projectsRoot: source, managedAccountID: nil),
                                       .init(projectsRoot: newRoot, managedAccountID: "new-account")], timeline: .init())
        let week = await collector.report(now: now)
        XCTAssertEqual(week.tokens.total, 163)
        XCTAssertEqual(week.accounts.first?.managedAccountID, "new-account")
        let all = await collector.report(days: 90, now: now)
        XCTAssertEqual(all.tokens.total, 326)
    }

    func testV5SimultaneousSubagentStreamsAreAllMigrated() async throws {
        let first = try write([line("agent-a", input: 100)], name: "session-a/subagents/agent-a.jsonl")
        let second = try write([line("agent-b", input: 200)], name: "session-a/subagents/agent-b.jsonl")
        var cache = UsageLedgerCache()
        _ = UsageLedgerEngine(sources: [.init(projectsRoot: source, managedAccountID: nil)]).scan(cache: &cache)
        for path in cache.entries.keys {
            cache.entries[path]?.digest.recordedEvents = nil
            cache.entries[path]?.digest.recordedEventsComplete = nil
            cache.entries[path]?.digest.transcriptComponentID = nil
        }
        cache.save(to: cacheURL)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        let captured = await ledger().report(now: now)
        XCTAssertEqual(captured.tokens.total, 426)
        try clearCache()
        try write([line("agent-a", input: 100)], name: "session-a/subagents/agent-a.jsonl")
        try write([line("agent-b", input: 200)], name: "session-a/subagents/agent-b.jsonl")
        let replayed = await ledger().report(now: now)
        XCTAssertEqual(replayed.tokens, captured.tokens)
    }

    func testFileBudgetProgressesAcrossSourcesAndPersistsCursorAcrossRestarts() async throws {
        for index in 0..<3 { try write([line("a-\(index)", session: "session-\(index)")], name: "first/a-\(index).jsonl") }
        try write([line("b", session: "session-b")], name: "second/b.jsonl")
        var limits = UsageLedgerLimits.default
        limits.maxFiles = 3
        func boundedLedger() -> UsageLedger {
            UsageLedger(sources: [.init(projectsRoot: source.appendingPathComponent("first"), managedAccountID: nil),
                                   .init(projectsRoot: source.appendingPathComponent("second"), managedAccountID: nil)],
                        cacheURL: cacheURL, limits: limits, calendar: calendar, archiveURL: archiveURL)
        }
        let first = await boundedLedger().report(now: now)
        XCTAssertEqual(first.tokens.total, 3 * 163)
        XCTAssertTrue(first.scan.hitLimit)
        XCTAssertLessThanOrEqual(first.scan.filesSeen, 3)
        let second = await boundedLedger().report(now: now)
        XCTAssertEqual(second.tokens.total, 4 * 163)
        XCTAssertFalse(second.scan.hitLimit)
        XCTAssertLessThanOrEqual(second.scan.filesSeen, 3)
        for _ in 0..<4 {
            let repeated = await boundedLedger().report(now: now)
            XCTAssertEqual(repeated.tokens.total, 4 * 163)
            XCTAssertLessThanOrEqual(repeated.scan.filesSeen, 3)
        }
    }

    func testFileBudgetProgressesWithinOneSourceAndSurvivesDeletedCursor() async throws {
        for index in 0..<8 { try write([line("request-\(index)", session: "session-\(index)")], name: "\(index).jsonl") }
        var limits = UsageLedgerLimits.default
        limits.maxFiles = 2
        let collector = ledger(limits: limits)
        let first = await collector.report(now: now)
        XCTAssertEqual(first.tokens.total, 2 * 163)
        let cursor = try XCTUnwrap(UsageLedgerCache.load(from: cacheURL).scanCursor)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: cursor.filePath))
        var last = first
        for _ in 0..<8 {
            last = await collector.report(now: now)
            XCTAssertLessThanOrEqual(last.scan.filesSeen, 2)
        }
        // The deleted cursor's consumption was already saved, and all other
        // sources eventually join it even though enumeration had to restart.
        XCTAssertEqual(last.tokens.total, 8 * 163)
    }

    func testSameClaudeRequestEnrichmentNeverDoubleCountsOrRegresses() async throws {
        let early = line("same-id", input: 12).replacingOccurrences(of: "\"output_tokens\":20", with: "\"output_tokens\":3")
        let final = line("same-id", input: 12).replacingOccurrences(of: "\"output_tokens\":20", with: "\"output_tokens\":30")
        try write([early])
        let collector = ledger()
        let first = await collector.report(now: now)
        XCTAssertEqual(first.tokens.output, 3)
        try write([final])
        let enriched = await collector.report(now: now)
        XCTAssertEqual(enriched.tokens.output, 30)
        XCTAssertEqual(enriched.tokens.measurements, 1)
        XCTAssertEqual(enriched.messages, 1)
        try clearCache()
        try write([early], name: "old-copy.jsonl")
        let restored = await ledger().report(now: now)
        XCTAssertEqual(restored.tokens, enriched.tokens)
        XCTAssertEqual(restored.timeline, enriched.timeline)
        let later = final.replacingOccurrences(of: "\"output_tokens\":30", with: "\"output_tokens\":50")
        try write([final, later])
        let appended = await ledger().report(now: now)
        XCTAssertEqual(appended.tokens.output, 50)
        XCTAssertEqual(appended.messages, 1)
    }

    func testSameCodexRequestCanGainCacheAndReasoningDetailsOnAppend() async throws {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-enriched\",\"cwd\":\"/projects/codex\"}}"
        let early = "{\"timestamp\":\"\(stamp)\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"same-response\",\"usage\":{\"input_tokens\":50,\"output_tokens\":3}}}"
        let final = "{\"timestamp\":\"\(stamp)\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"same-response\",\"usage\":{\"input_tokens\":50,\"cached_input_tokens\":10,\"output_tokens\":30,\"reasoning_output_tokens\":12}}}"
        let collector = UsageLedger(sources: [.init(projectsRoot: source, managedAccountID: nil, format: .codex)],
                                    cacheURL: cacheURL, calendar: calendar, archiveURL: archiveURL)
        try write([meta, early])
        let first = await collector.report(now: now)
        XCTAssertEqual(first.tokens.total, 53)
        XCTAssertEqual(first.tokens.coverage.cacheRead, .unavailable)
        try write([meta, early, final])
        let enriched = await collector.report(now: now)
        XCTAssertEqual(enriched.tokens.input, 40)
        XCTAssertEqual(enriched.tokens.totalInput, 50)
        XCTAssertEqual(enriched.tokens.output, 30)
        XCTAssertEqual(enriched.tokens.thinking, 12)
        XCTAssertEqual(enriched.tokens.coverage.cacheRead, .complete)
        XCTAssertEqual(enriched.tokens.coverage.reasoning, .complete)
        XCTAssertEqual(enriched.messages, 1)
        try write([meta, early], name: "older.jsonl")
        let replayed = await collector.report(now: now)
        XCTAssertEqual(replayed.tokens, enriched.tokens)
    }

}
