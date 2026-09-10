import Foundation

/// Reads one Claude Code transcript and turns it into a digest.
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
    }

    /// Reads `file` from `offset` and returns what it found after that point.
    func scan(file: URL, from offset: UInt64, sessionIDHint: String, managedAccountID: String?) throws -> Outcome {
        var digest = UsageSessionDigest(sessionID: sessionIDHint)
        digest.managedAccountID = managedAccountID
        var outcome = Outcome(digest: digest, consumed: offset)

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }

        var position = offset
        var line = Data()
        var skippingLongLine = false
        let ceiling = UInt64(limits.maxFileBytes)

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
                    consume(line: line, into: &outcome)
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
        return outcome
    }

    /// One JSON line. Unparseable lines are counted and skipped: a transcript
    /// written by a newer Claude Code, or half-flushed to disk, must cost us the
    /// line and nothing more.
    private func consume(line: Data, into outcome: inout Outcome) {
        guard line.count > 2, Self.mayCarryUsage(line) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            outcome.malformedLines += 1
            return
        }
        guard let type = object["type"] as? String else { return }

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
        tokens.input = Self.count(usage["input_tokens"])
        tokens.output = Self.count(usage["output_tokens"])
        tokens.cacheCreation = Self.count(usage["cache_creation_input_tokens"])
        tokens.cacheRead = Self.count(usage["cache_read_input_tokens"])
        if let details = usage["output_tokens_details"] as? [String: Any] {
            tokens.thinking = min(tokens.output, Self.count(details["thinking_tokens"]))
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
            let hour = Int(date.timeIntervalSince1970 / 3600)
            let key = String(hour)
            if digest.hours[key] != nil || digest.hours.count < limits.maxHoursPerSession {
                var bucket = digest.hours[key] ?? UsageHourBucket()
                bucket.tokens += tokens
                bucket.weight += weight
                bucket.messages += 1
                digest.hours[key] = bucket
            }
        }
        outcome.digest = digest
    }

    /// A cheap byte test that skips the attachments and tool results, which are
    /// most of the bytes on disk and none of the usage.
    static func mayCarryUsage(_ line: Data) -> Bool {
        for marker in markers where line.range(of: marker) != nil { return true }
        return false
    }

    private static let markers: [Data] = ["\"usage\"", "\"ai-title\"", "\"bridge-session\""]
        .compactMap { $0.data(using: .utf8) }

    /// Token counts arrive as JSON numbers. Anything else — a string, a bool, a
    /// negative, a float — is not a count and is read as zero rather than
    /// throwing away the whole turn.
    static func count(_ raw: Any?) -> Int {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < 1e12 else { return 0 }
        return Int(value)
    }
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
