import Foundation

/// Reads one Claude Code or Codex transcript and turns it into a digest.
///
/// Everything in these files was written by another program and, through it, by
/// whatever the person and the models typed. It is **data**: values are read,
/// bounded and counted, and no field is ever interpreted as an instruction,
/// a path to open, or a command to run. Only titles, directories, model names,
/// identifiers and numbers leave this type — never message content.
///
/// The reader is a stream, not a `String(contentsOf:)`: transcripts here reach
/// several megabytes, there are hundreds of them, and the app must stay small
/// while it reads them.
struct UsageTranscriptScanner {
    var limits: UsageLedgerLimits = .default

    struct Outcome {
        var digest: UsageSessionDigest
        /// Where the next refresh should resume: the end of the last *complete*
        /// line. A transcript being written to right now always has a partial
        /// last line, and resuming mid-line would corrupt every later read.
        var consumed: UInt64
        var malformedLines = 0
        var oversizedLines = 0
        var bytesRead = 0
        var truncated = false
        var checkpoint = UsageTranscriptCheckpoint()
    }

    /// Reads `file` from `offset` and returns what it found after that point.
    func scan(file: URL, from offset: UInt64, sessionIDHint: String, managedAccountID: String?,
              format: UsageTranscriptFormat = .claude,
              checkpoint: UsageTranscriptCheckpoint = UsageTranscriptCheckpoint()) throws -> Outcome {
        var digest = UsageSessionDigest(sessionID: sessionIDHint)
        digest.managedAccountID = managedAccountID
        var outcome = Outcome(digest: digest, consumed: offset)
        var codex = CodexState(sessionIDHint: sessionIDHint, managedAccountID: managedAccountID,
                               checkpoint: checkpoint)

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }

        var position = offset
        var line = Data()
        var skippingLongLine = false
        let allowance = UInt64(max(0, limits.maxFileBytes))
        let ceiling = offset > UInt64.max - allowance ? UInt64.max : offset + allowance

        while true {
            guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            outcome.bytesRead += chunk.count

            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                let slice = chunk[start..<newline]
                position += UInt64(slice.count + 1)
                if skippingLongLine {
                    skippingLongLine = false
                    line.removeAll(keepingCapacity: true)
                } else if line.count + slice.count > limits.maxLineBytes {
                    // Never buffer it, never parse it: an unbounded line is
                    // dropped whole, whether it ends inside this chunk or not.
                    outcome.oversizedLines += 1
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(contentsOf: slice)
                    consume(line: line, format: format, into: &outcome, codex: &codex)
                    line.removeAll(keepingCapacity: true)
                }
                outcome.consumed = position
                start = chunk.index(after: newline)
            }

            if start < chunk.endIndex {
                if skippingLongLine {
                    position += UInt64(chunk.distance(from: start, to: chunk.endIndex))
                } else {
                    line.append(contentsOf: chunk[start...])
                    if line.count > limits.maxLineBytes {
                        // One unbounded line must not become one unbounded
                        // allocation. Drop it and pick the stream back up at the
                        // next newline.
                        outcome.oversizedLines += 1
                        position += UInt64(line.count)
                        line.removeAll(keepingCapacity: true)
                        skippingLongLine = true
                    }
                }
            }

            if position >= ceiling {
                outcome.truncated = true
                break
            }
        }
        if format == .codex {
            outcome.digest = codex.digest
            outcome.checkpoint = codex.checkpoint
        }
        return outcome
    }

    /// One JSON line. Unparseable lines are counted and skipped: a transcript
    /// written by a newer Claude Code, or half-flushed to disk, must cost us the
    /// line and nothing more.
    private func consume(line: Data, format: UsageTranscriptFormat, into outcome: inout Outcome,
                         codex: inout CodexState) {
        guard line.count > 2, Self.mayCarryUsage(line) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            outcome.malformedLines += 1
            return
        }
        guard let type = object["type"] as? String else { return }

        if format == .codex {
            consumeCodex(object: object, type: type, state: &codex)
            return
        }

        if let session = UsageText.identifier(object["sessionId"]) { outcome.digest.sessionID = session }

        switch type {
        case "ai-title":
            if let title = UsageText.clean(object["aiTitle"], limit: limits.maxTitleCharacters) {
                // Later lines describe the session as it ended up being about.
                outcome.digest.title = title
            }
        case "bridge-session":
            if let owner = UsageText.identifier(object["ownerAccountUuid"]) { outcome.digest.vendorAccountID = owner }
        case "assistant":
            record(assistant: object, into: &outcome)
        default:
            break
        }
    }

    private func record(assistant object: [String: Any], into outcome: inout Outcome) {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        var tokens = UsageTokenTotals()
        tokens.measurements = 1
        tokens.claudeMeasurements = 1
        if let value = Self.countIfPresent(usage["input_tokens"]) {
            tokens.input = value
            tokens.inputMeasurements = 1
        }
        if let value = Self.countIfPresent(usage["output_tokens"]) {
            tokens.output = value
            tokens.outputMeasurements = 1
        }
        if let value = Self.countIfPresent(usage["cache_creation_input_tokens"]) {
            tokens.cacheCreation = value
            tokens.cacheCreationMeasurements = 1
        }
        if let value = Self.countIfPresent(usage["cache_read_input_tokens"]) {
            tokens.cacheRead = value
            tokens.cacheReadMeasurements = 1
        }
        if let details = usage["output_tokens_details"] as? [String: Any] {
            if let value = Self.countIfPresent(details["thinking_tokens"]) {
                tokens.thinking = min(tokens.output, value)
                tokens.thinkingMeasurements = 1
            }
        }
        guard tokens.total > 0 else { return }

        let model = UsageText.clean(message["model"], limit: 80)
        let weight = UsageWeight.weight(tokens, model: model)
        let date = UsageText.date(object["timestamp"])
        let isSidechain = (object["isSidechain"] as? NSNumber)?.boolValue ?? false

        var digest = outcome.digest
        digest.tokens += tokens
        digest.weight += weight
        digest.messages += 1
        if let model { digest.modelWeights[model, default: 0] += weight }

        // A subagent runs in a throwaway worktree. Its tokens belong to the
        // session, but its directory must never be mistaken for the project the
        // person is working on.
        if let raw = UsageText.clean(object["cwd"], limit: limits.maxPathCharacters) {
            let cwd = UsageProjectPath.normalize(raw)
            if isSidechain { digest.fallbackProjectWeights[cwd, default: 0] += weight }
            else { digest.projectWeights[cwd, default: 0] += weight }
        }

        if let date {
            digest.firstActivity = min(digest.firstActivity ?? date, date)
            digest.lastActivity = max(digest.lastActivity ?? date, date)
            let minute = Int(date.timeIntervalSince1970 / 60)
            let key = String(minute)
            if digest.activityMinutes[key] != nil || digest.activityMinutes.count < limits.maxTimeBucketsPerSession {
                var bucket = digest.activityMinutes[key] ?? UsageTimeBucket()
                bucket.tokens += tokens
                bucket.weight += weight
                bucket.messages += 1
                digest.activityMinutes[key] = bucket
            }
        }
        outcome.digest = digest
    }

    // MARK: - Codex

    /// New Codex rollouts persist one exact record per completed model request.
    /// Older cumulative snapshots become monotonic deltas until the first exact
    /// record; later overlapping aggregates are ignored.
    private struct CodexState {
        var digest: UsageSessionDigest
        var previousCumulative: CodexCounters?
        var responseIDs: Set<String> = []
        var projectPath: String?
        var model: String?
        var threadID: String?
        var sawExactRecord = false

        init(sessionIDHint: String, managedAccountID: String?, checkpoint: UsageTranscriptCheckpoint) {
            let resumedID = checkpoint.codexThreadID ?? sessionIDHint
            digest = UsageSessionDigest(sessionID: "codex:\(resumedID)", provider: .codex)
            digest.managedAccountID = managedAccountID
            previousCumulative = checkpoint.codexPreviousCumulative
            responseIDs = checkpoint.codexResponseIDs
            projectPath = checkpoint.codexProjectPath
            model = checkpoint.codexModel
            threadID = checkpoint.codexThreadID
            sawExactRecord = checkpoint.codexSawExactRecord
        }

        mutating func setSessionID(_ raw: Any?) {
            guard let id = UsageText.identifier(raw) else { return }
            threadID = id
            digest.sessionID = "codex:\(id)"
        }

        var checkpoint: UsageTranscriptCheckpoint {
            UsageTranscriptCheckpoint(codexPreviousCumulative: previousCumulative,
                                      codexResponseIDs: responseIDs,
                                      codexProjectPath: projectPath,
                                      codexModel: model,
                                      codexThreadID: threadID,
                                      codexSawExactRecord: sawExactRecord)
        }
    }

    struct CodexCounters: Codable, Equatable {
        var inclusiveInput: Int
        var cachedInput: Int
        var cacheWriteInput: Int
        var output: Int
        var reasoningOutput: Int
        var hasCachedInput: Bool
        var hasCacheWriteInput: Bool
        var hasReasoningOutput: Bool

        init?(_ usage: [String: Any]) {
            guard let input = UsageTranscriptScanner.countIfPresent(usage["input_tokens"]),
                  let output = UsageTranscriptScanner.countIfPresent(usage["output_tokens"]) else { return nil }
            inclusiveInput = input
            cachedInput = UsageTranscriptScanner.countIfPresent(usage["cached_input_tokens"]) ?? 0
            cacheWriteInput = UsageTranscriptScanner.countIfPresent(usage["cache_write_input_tokens"]) ?? 0
            reasoningOutput = UsageTranscriptScanner.countIfPresent(usage["reasoning_output_tokens"]) ?? 0
            self.output = output
            hasCachedInput = UsageTranscriptScanner.countIfPresent(usage["cached_input_tokens"]) != nil
            hasCacheWriteInput = UsageTranscriptScanner.countIfPresent(usage["cache_write_input_tokens"]) != nil
            hasReasoningOutput = UsageTranscriptScanner.countIfPresent(usage["reasoning_output_tokens"]) != nil
        }

        func delta(after previous: CodexCounters?) -> CodexCounters {
            guard let previous,
                  inclusiveInput >= previous.inclusiveInput,
                  cachedInput >= previous.cachedInput,
                  cacheWriteInput >= previous.cacheWriteInput,
                  output >= previous.output,
                  reasoningOutput >= previous.reasoningOutput else { return self }
            return CodexCounters(inclusiveInput: inclusiveInput - previous.inclusiveInput,
                                 cachedInput: cachedInput - previous.cachedInput,
                                 cacheWriteInput: cacheWriteInput - previous.cacheWriteInput,
                                 output: output - previous.output,
                                 reasoningOutput: reasoningOutput - previous.reasoningOutput,
                                 hasCachedInput: hasCachedInput,
                                 hasCacheWriteInput: hasCacheWriteInput,
                                 hasReasoningOutput: hasReasoningOutput)
        }

        private init(inclusiveInput: Int, cachedInput: Int, cacheWriteInput: Int, output: Int,
                     reasoningOutput: Int, hasCachedInput: Bool, hasCacheWriteInput: Bool,
                     hasReasoningOutput: Bool) {
            self.inclusiveInput = inclusiveInput
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput
            self.output = output
            self.reasoningOutput = reasoningOutput
            self.hasCachedInput = hasCachedInput
            self.hasCacheWriteInput = hasCacheWriteInput
            self.hasReasoningOutput = hasReasoningOutput
        }

        func totals() -> UsageTokenTotals {
            // OpenAI input is inclusive. Official cache accounting subtracts
            // both cache reads and writes to obtain ordinary input.
            let read = min(inclusiveInput, cachedInput)
            let write = min(max(0, inclusiveInput - read), cacheWriteInput)
            return UsageTokenTotals(
                input: max(0, inclusiveInput - read - write), output: output,
                cacheCreation: write, cacheRead: read, thinking: min(output, reasoningOutput),
                measurements: 1, inputMeasurements: 1, outputMeasurements: 1,
                cacheCreationMeasurements: hasCacheWriteInput ? 1 : 0,
                cacheReadMeasurements: hasCachedInput ? 1 : 0,
                thinkingMeasurements: hasReasoningOutput ? 1 : 0,
                claudeMeasurements: 0, codexMeasurements: 1)
        }
    }

    private func consumeCodex(object: [String: Any], type: String, state: inout CodexState) {
        switch type {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any] else { return }
            state.setSessionID(payload["id"] ?? payload["session_id"])
            if let raw = UsageText.clean(payload["cwd"], limit: limits.maxPathCharacters) {
                state.projectPath = UsageProjectPath.normalize(raw)
            }
        case "turn_context":
            guard let payload = object["payload"] as? [String: Any] else { return }
            state.model = UsageText.clean(payload["model"], limit: 80) ?? state.model
        case "token_usage_record":
            guard let payload = object["payload"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let counters = CodexCounters(usage) else { return }
            // A parent rollout can mention child-thread aggregate usage. The
            // child's own rollout is scanned separately, so only records owned
            // by this file's thread are accepted here.
            if let owner = UsageText.identifier(payload["thread_id"]),
               let threadID = state.threadID, owner != threadID { return }
            if let responseID = UsageText.identifier(payload["response_id"]),
               !state.responseIDs.insert(responseID).inserted { return }
            state.sawExactRecord = true
            recordCodex(counters.totals(), at: UsageText.date(object["timestamp"]), into: &state.digest,
                        projectPath: state.projectPath, model: state.model)
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let cumulative = CodexCounters(usage) else { return }
            // Once exact per-request telemetry starts, later cumulative
            // snapshots overlap it. Earlier cumulative history remains valid.
            guard !state.sawExactRecord else { return }
            let delta = cumulative.delta(after: state.previousCumulative)
            state.previousCumulative = cumulative
            guard delta.inclusiveInput > 0 || delta.output > 0 else { return }
            recordCodex(delta.totals(), at: UsageText.date(object["timestamp"]), into: &state.digest,
                        projectPath: state.projectPath, model: state.model)
        default:
            break
        }
    }

    private func recordCodex(_ tokens: UsageTokenTotals, at date: Date?, into digest: inout UsageSessionDigest,
                             projectPath: String?, model: String?) {
        guard tokens.total > 0 else { return }
        let weight = UsageWeight.weight(tokens, model: model)
        digest.tokens += tokens
        digest.weight += weight
        digest.messages += 1
        if let model { digest.modelWeights[model, default: 0] += weight }
        if let projectPath { digest.projectWeights[projectPath, default: 0] += weight }
        guard let date else { return }
        digest.firstActivity = min(digest.firstActivity ?? date, date)
        digest.lastActivity = max(digest.lastActivity ?? date, date)
        let key = String(Int(date.timeIntervalSince1970 / 60))
        if digest.activityMinutes[key] != nil || digest.activityMinutes.count < limits.maxTimeBucketsPerSession {
            var bucket = digest.activityMinutes[key] ?? UsageTimeBucket()
            bucket.tokens += tokens
            bucket.weight += weight
            bucket.messages += 1
            digest.activityMinutes[key] = bucket
        }
    }

    /// A cheap byte test that skips the attachments and tool results, which are
    /// most of the bytes on disk and none of the usage.
    static func mayCarryUsage(_ line: Data) -> Bool {
        for marker in markers where line.range(of: marker) != nil { return true }
        return false
    }

    private static let markers: [Data] = ["\"usage\"", "\"ai-title\"", "\"bridge-session\"",
                                         "\"token_count\"", "\"session_meta\"", "\"turn_context\""]
        .compactMap { $0.data(using: .utf8) }

    /// Token counts arrive as JSON numbers. Anything else — a string, a bool, a
    /// negative, a float — is not a count and is read as zero rather than
    /// throwing away the whole turn.
    static func count(_ raw: Any?) -> Int {
        countIfPresent(raw) ?? 0
    }

    static func countIfPresent(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < 1e12, value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}

/// Parser state required to resume a bounded transcript read without counting
/// cumulative Codex telemetry again. Contains identifiers and counters only.
struct UsageTranscriptCheckpoint: Codable, Equatable {
    var codexPreviousCumulative: UsageTranscriptScanner.CodexCounters?
    var codexResponseIDs: Set<String> = []
    var codexProjectPath: String?
    var codexModel: String?
    var codexThreadID: String?
    var codexSawExactRecord = false
}

/// Bounds on every string that comes out of a transcript.
enum UsageText {
    /// Free text from a file this app does not own: control characters removed,
    /// length capped, never trusted as anything but a label.
    static func clean(_ raw: Any?, limit: Int) -> String? {
        guard let value = raw as? String else { return nil }
        let stripped = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var text = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > limit { text = String(text.prefix(limit)) }
        return text
    }

    /// Identifiers are matched and grouped on, so they are held to a stricter
    /// shape than free text: hex, dashes and underscores only.
    static func identifier(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.count <= 128 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `2026-09-10T10:15:55.762Z`, with or without the fraction. A timestamp
    /// outside a sane range is treated as absent: a session dated in 1970 would
    /// silently widen every window it touches.
    static func date(_ raw: Any?) -> Date? {
        guard let value = raw as? String, value.count <= 40 else { return nil }
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else { return nil }
        guard date.timeIntervalSince1970 > 1_000_000_000, date.timeIntervalSince1970 < 4_000_000_000 else { return nil }
        return date
    }
}
