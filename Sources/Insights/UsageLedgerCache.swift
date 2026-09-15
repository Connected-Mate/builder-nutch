import Foundation

/// What the ledger already knows about one transcript file.
///
/// Keyed on the file's own facts — size and modification date — because that is
/// what a cheap `stat` gives us. A transcript only ever grows, so an unchanged
/// size and date means an unchanged digest, and a larger file means the new
/// bytes can be read from `offset` alone. Anything else (a rewrite, a rollback,
/// a copy) falls back to reading the file again.
struct UsageLedgerCacheEntry: Codable, Equatable {
    var size: UInt64
    var modified: Date
    /// The end of the last complete line read, so a refresh resumes exactly
    /// where the previous one stopped.
    var offset: UInt64
    var digest: UsageSessionDigest
    /// True means this digest is a measured floor. The next refresh resumes it
    /// even when the file itself has not changed.
    var truncated = false
    var checkpoint = UsageTranscriptCheckpoint()
    var resumeFingerprint: String?
}

/// The on-disk index. Plain JSON, private to the user, and disposable: deleting
/// it costs one slower refresh and nothing else.
///
/// It holds titles, directories, identifiers and numbers. It never holds a line
/// of conversation, and nothing in it is sent anywhere.
struct UsageLedgerCache: Codable, Equatable {
    /// Bumped when the file layout changes.
    static let currentVersion = 5
    /// Bumped when `UsageWeight` changes, because every cached weight was
    /// computed with the old formula and mixing the two would be nonsense.
    static let currentFormula = 1
    /// A cache far bigger than this is not a cache any more.
    static let maximumBytes = 40_000_000

    var version = UsageLedgerCache.currentVersion
    var formula = UsageLedgerCache.currentFormula
    var entries: [String: UsageLedgerCacheEntry] = [:]
    /// The next bounded pass continues the sweep instead of revisiting its
    /// first files forever. Optional fields keep v5 cache migration compatible.
    var scanCursor: UsageLedgerScanCursor?
    var scanSeenPaths: Set<String>?


    /// Reads the cache, treating every failure as "no cache". A corrupt index
    /// must cost a slow refresh, never an error the person has to understand.
    static func load(from url: URL) -> UsageLedgerCache {
        guard (try? AccountStorage.rejectSymlink(url)) != nil,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let cache = try? JSONDecoder().decode(UsageLedgerCache.self, from: data),
              cache.version == currentVersion, cache.formula == currentFormula else {
            return UsageLedgerCache()
        }
        return identifyingComponents(cache)
    }

    static func componentID(for file: URL) -> String? {
        guard file.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        return UsageRecordedEvent.hash(Data(file.deletingPathExtension().lastPathComponent.utf8))
    }

    private static func identifyingComponents(_ cache: UsageLedgerCache) -> UsageLedgerCache {
        var result = cache
        for path in result.entries.keys {
            result.entries[path]?.digest.transcriptComponentID = componentID(for: URL(fileURLWithPath: path))
        }
        return result
    }

    /// Verify both ends of the consumed prefix before trusting an append.
    /// This catches a replaced/truncated transcript even if its new size grew.
    static func resumeFingerprint(for url: URL, offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let count = Int(min(offset, 256))
            let first = try handle.read(upToCount: count) ?? Data()
            try handle.seek(toOffset: offset - UInt64(count))
            let last = try handle.read(upToCount: count) ?? Data()
            guard first.count == count, last.count == count else { return nil }
            return UsageRecordedEvent.hash(first + last)
        } catch { return nil }
    }

    /// Decode the known v5 numeric schema before applying disposable-cache
    /// compatibility checks. Failure blocks replacement, preserving evidence
    /// that may no longer exist in the original transcript files.
    static func loadForArchive(from url: URL) throws -> UsageLedgerCache {
        try AccountStorage.rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return UsageLedgerCache() }
        let data = try Data(contentsOf: url)
        guard let cache = try? JSONDecoder().decode(UsageLedgerCache.self, from: data) else {
            throw UsageArchiveError.corrupt
        }
        guard cache.version >= 5 else { return UsageLedgerCache() }
        return identifyingComponents(cache)
    }

    /// Writes atomically and privately, reusing the same guards as the account
    /// catalog. A cache that cannot be written is not an error either.
    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return }
        try? AccountStorage.privateDirectory(url.deletingLastPathComponent())
        try? AccountStorage.write(data, to: url)
    }

    /// Drops files that no longer exist, so a deleted project does not haunt the
    /// index forever.
    mutating func prune(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}

struct UsageLedgerScanCursor: Codable, Equatable {
    var sourceRoot: String
    var filePath: String
}
