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

    /// Reads the cache, treating every failure as "no cache". A corrupt index
    /// must cost a slow refresh, never an error the person has to understand.
    static func load(from url: URL) -> UsageLedgerCache {
        guard (try? AccountStorage.rejectSymlink(url)) != nil,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let cache = try? JSONDecoder().decode(UsageLedgerCache.self, from: data),
              cache.version == currentVersion, cache.formula == currentFormula else {
            return UsageLedgerCache()
        }
        return cache
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
