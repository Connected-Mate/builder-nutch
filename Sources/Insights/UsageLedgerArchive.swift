import Foundation
import CryptoKit
import Darwin

struct UsagePersistenceStatus: Codable, Equatable {
    enum State: String, Codable { case notCaptured, saved, failed }
    var state: State
    var savedAt: Date?
    var message: String?
    static let notCaptured = UsagePersistenceStatus(state: .notCaptured)
}

struct UsageCaptureResult: Equatable {
    var scan: UsageScanSummary
    var persistence: UsagePersistenceStatus
}

/// One numeric measurement, without messages, titles, credentials or raw JSON.
struct UsageRecordedEvent: Codable, Equatable {
    var tokens: UsageTokenTotals
    var weight: Double
    var date: Date?
    var projectPath: String?
    var model: String?
    var sidechain: Bool

    /// Provider IDs identify requests across renames and duplicate homes. For
    /// older telemetry without IDs, hash only its numeric/time metadata.
    func identity(sessionID: String, provider: UsageTranscriptFormat, requestID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = requestID.map { Data($0.utf8) } ?? (try! encoder.encode(self))
        return Self.hash(Data("\(provider.rawValue)|\(sessionID)|".utf8) + payload)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func add(to digest: inout UsageSessionDigest) {
        digest.tokens += tokens
        digest.weight += weight
        digest.messages += 1
        if let date {
            digest.firstActivity = min(digest.firstActivity ?? date, date)
            digest.lastActivity = max(digest.lastActivity ?? date, date)
            let key = String(Int(date.timeIntervalSince1970 / 60))
            digest.activityMinutes[key] = (digest.activityMinutes[key] ?? UsageTimeBucket())
                + UsageTimeBucket(tokens: tokens, weight: weight, messages: 1)
        }
        if let model { digest.modelWeights[model, default: 0] += weight }
        if let projectPath {
            if sidechain { digest.fallbackProjectWeights[projectPath, default: 0] += weight }
            else { digest.projectWeights[projectPath, default: 0] += weight }
        }
    }
}

enum UsageArchiveError: LocalizedError {
    case corrupt, unsupportedVersion, unavailable, busy
    var errorDescription: String? {
        switch self {
        case .corrupt: return "Saved token history is unreadable. The existing archive was preserved."
        case .unsupportedVersion: return "Saved token history uses a newer format. The existing archive was preserved."
        case .unavailable: return "Token history could not be saved."
        case .busy: return "Token history is being saved by another process. Please retry."
        }
    }
}

/// A permanent numeric archive, deliberately unrelated to the cache version.
/// Legacy aggregates are retained until their individual records are recovered.
struct UsageLedgerArchive: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var savedAt: Date?
    var sessions: [String: Session] = [:]

    struct Legacy: Codable, Equatable {
        var remaining: UsageSessionDigest
        var originalFingerprint: String
        /// Full digests already reconciled, so a later cache cannot consume
        /// the legacy floor for the same event a second time.
        var seenEvents: Set<String> = []
    }

    struct Session: Codable, Equatable {
        var metadata: UsageSessionDigest
        var events: [String: UsageRecordedEvent] = [:]
        var legacy: [String: Legacy] = [:]
    }

    private static func sessionKey(_ digest: UsageSessionDigest) -> String {
        "\(digest.provider.rawValue)|\(digest.sessionID)"
    }

    /// Timestamps survive moves/renames and distinguish the separate subagent
    /// streams that share their parent's Claude session identifier.
    private static func streamKey(_ digest: UsageSessionDigest) -> String {
        "\(digest.firstActivity?.timeIntervalSince1970 ?? -1)|\(digest.transcriptComponentID ?? "main")"
    }

    mutating func absorb(_ digests: [UsageSessionDigest], timeline: UsageAccountTimeline) {
        // Migrate aggregate-only prefixes before importing their new suffixes.
        for digest in digests.sorted(by: { $0.tokens.total > $1.tokens.total }) where digest.recordedEventsComplete != true {
            let key = Self.sessionKey(digest)
            var session = sessions[key] ?? Session(metadata: Self.metadata(digest, timeline: timeline))
            let stream = Self.streamKey(digest)
            if session.legacy[stream] == nil {
                var baseline = digest
                baseline.title = nil
                baseline.recordedEvents = nil
                // New events appended to a v5 digest are not part of its floor.
                for event in (digest.recordedEvents ?? [:]).values { Self.subtract(event, from: &baseline) }
                var fingerprintDigest = baseline
                fingerprintDigest.transcriptComponentID = nil
                fingerprintDigest.managedAccountID = nil
                fingerprintDigest.vendorAccountID = nil
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let fingerprint = UsageRecordedEvent.hash((try? encoder.encode(fingerprintDigest)) ?? Data())
                if !session.legacy.values.contains(where: { $0.originalFingerprint == fingerprint }) {
                    session.legacy[stream] = Legacy(remaining: baseline, originalFingerprint: fingerprint)
                }
            }
            sessions[key] = session
        }
        for digest in digests {
            let key = Self.sessionKey(digest)
            var session = sessions[key] ?? Session(metadata: Self.metadata(digest, timeline: timeline))
            Self.improveMetadata(&session.metadata, from: digest, timeline: timeline)
            let stream = Self.streamKey(digest)
            for (id, event) in digest.recordedEvents ?? [:] {
                guard session.events[id] == nil else { continue }
                // A complete replay can recover IDs for an old aggregate.
                // Suffix-only reads cannot overlap that aggregate and add whole.
                let legacyKey = session.legacy[stream] != nil ? stream : session.legacy.keys.sorted().first {
                    session.legacy[$0]?.remaining.firstActivity == digest.firstActivity
                        && session.legacy[$0]?.remaining.tokens.total ?? 0 > 0
                }
                if digest.recordedEventsComplete == true, let legacyKey, var legacy = session.legacy[legacyKey],
                   !legacy.seenEvents.contains(id) {
                    Self.subtract(event, from: &legacy.remaining)
                    legacy.seenEvents.insert(id)
                    session.legacy[legacyKey] = legacy
                }
                session.events[id] = event
            }
            sessions[key] = session
        }
    }

    var digests: [UsageSessionDigest] {
        sessions.values.map { session in
            var digest = session.metadata
            for legacy in session.legacy.values { digest.merge(legacy.remaining) }
            for event in session.events.values { event.add(to: &digest) }
            digest.recordedEvents = nil
            return digest
        }
    }

    private static func metadata(_ source: UsageSessionDigest, timeline: UsageAccountTimeline) -> UsageSessionDigest {
        var result = UsageSessionDigest(sessionID: source.sessionID, provider: source.provider)
        result.recordedEvents = nil
        improveMetadata(&result, from: source, timeline: timeline)
        return result
    }

    private static func improveMetadata(_ target: inout UsageSessionDigest, from source: UsageSessionDigest,
                                        timeline: UsageAccountTimeline) {
        target.vendorAccountID = target.vendorAccountID ?? source.vendorAccountID
        target.managedAccountID = target.managedAccountID ?? source.managedAccountID
        if target.archivedAttribution == nil || target.archivedAttribution == .unknown {
            let account = UsageLedgerEngine.accountKey(for: source, activeAt: source.lastActivity, timeline: timeline)
            target.archivedAccountID = account.managedAccountID
            target.archivedAttribution = account.attribution
        }
    }

    /// Subtract only the overlap in the same minute, retaining all unrecovered
    /// legacy history. Coverage counts remain counts, never invented zeroes.
    private static func subtract(_ event: UsageRecordedEvent, from digest: inout UsageSessionDigest) {
        var removed = UsageTimeBucket()
        if let date = event.date {
            let key = String(Int(date.timeIntervalSince1970 / 60))
            guard var bucket = digest.activityMinutes[key] else { return }
            removed.tokens = bucket.tokens.removing(event.tokens)
            removed.weight = min(bucket.weight, event.weight)
            removed.messages = min(bucket.messages, 1)
            bucket.weight -= removed.weight
            bucket.messages -= removed.messages
            digest.activityMinutes[key] = bucket
        } else {
            removed.tokens = digest.tokens.removing(event.tokens)
            removed.weight = min(digest.weight, event.weight)
            removed.messages = min(digest.messages, 1)
            digest.weight -= removed.weight
            digest.messages -= removed.messages
            return
        }
        _ = digest.tokens.removing(removed.tokens)
        digest.weight = max(0, digest.weight - removed.weight)
        digest.messages = max(0, digest.messages - removed.messages)
        if let model = event.model { digest.modelWeights[model] = max(0, (digest.modelWeights[model] ?? 0) - removed.weight) }
        if let path = event.projectPath {
            if event.sidechain { digest.fallbackProjectWeights[path] = max(0, (digest.fallbackProjectWeights[path] ?? 0) - removed.weight) }
            else { digest.projectWeights[path] = max(0, (digest.projectWeights[path] ?? 0) - removed.weight) }
        }
    }
}

private extension UsageTokenTotals {
    /// Returns what was actually removed, for reconciling imported aggregates.
    mutating func removing(_ other: UsageTokenTotals) -> UsageTokenTotals {
        var removed = UsageTokenTotals()
        let fields: [WritableKeyPath<UsageTokenTotals, Int>] = [\.input, \.output, \.cacheCreation, \.cacheRead,
            \.thinking, \.measurements, \.inputMeasurements, \.outputMeasurements, \.cacheCreationMeasurements,
            \.cacheReadMeasurements, \.thinkingMeasurements, \.claudeMeasurements, \.codexMeasurements]
        for field in fields {
            let amount = min(self[keyPath: field], other[keyPath: field])
            self[keyPath: field] -= amount
            removed[keyPath: field] = amount
        }
        return removed
    }
}

/// The lock covers read/merge/write across actors and app processes. A failed
/// decode, checksum, version or write never replaces the previous archive.
enum UsageLedgerArchiveStore {
    private struct Envelope: Codable {
        var checksum: String
        var payload: Data
    }

    static func read(from url: URL) throws -> UsageLedgerArchive {
        try Task.checkCancellation()
        try AccountStorage.rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return UsageLedgerArchive() }
        let data = try Data(contentsOf: url)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.checksum == UsageRecordedEvent.hash(envelope.payload),
              let archive = try? JSONDecoder().decode(UsageLedgerArchive.self, from: envelope.payload) else {
            throw UsageArchiveError.corrupt
        }
        guard archive.version == UsageLedgerArchive.currentVersion else { throw UsageArchiveError.unsupportedVersion }
        return archive
    }

    static func update(at url: URL, now: Date, _ change: (inout UsageLedgerArchive) -> Void) throws -> UsageLedgerArchive {
        try AccountStorage.privateDirectory(url.deletingLastPathComponent())
        let lockURL = url.appendingPathExtension("lock")
        try AccountStorage.rejectSymlink(lockURL)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UsageArchiveError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw UsageArchiveError.busy }
        defer { flock(descriptor, LOCK_UN) }
        var archive = try read(from: url)
        let previous = archive
        change(&archive)
        if archive == previous, archive.savedAt != nil { return archive }
        archive.savedAt = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try Task.checkCancellation()
        let payload = try encoder.encode(archive)
        let data = try encoder.encode(Envelope(checksum: UsageRecordedEvent.hash(payload), payload: payload))
        try AccountStorage.rejectSymlink(url)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UsageArchiveError.unavailable
        }
        let file = try FileHandle(forWritingTo: staged)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        try Task.checkCancellation()
        guard rename(staged.path, url.path) == 0 else { throw UsageArchiveError.unavailable }
        // Persist the directory entry as well as the already-synced contents.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw UsageArchiveError.unavailable }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw UsageArchiveError.unavailable }
        return archive
    }
}
