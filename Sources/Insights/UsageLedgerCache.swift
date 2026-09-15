import Foundation
import Compression

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
    static let currentVersion = 6
    /// Bumped when `UsageWeight` changes, because every cached weight was
    /// computed with the old formula and mixing the two would be nonsense.
    static let currentFormula = 1
    /// Ordinary indices remain readable JSON; larger ones are losslessly
    /// compressed rather than losing their progress checkpoints.
    static let maximumBytes = 40_000_000
    static let maximumExpandedBytes = 512_000_000
    private static let compressedMagic = Data("BNLC1".utf8)

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
              let data = try? Data(contentsOf: url),
              let cache = try? decode(data),
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
        guard let cache = try? decode(data) else {
            throw UsageArchiveError.corrupt
        }
        guard cache.version >= 5 else { return UsageLedgerCache() }
        return identifyingComponents(cache)
    }

    private static func decode(_ data: Data) throws -> UsageLedgerCache {
        let json: Data
        if data.starts(with: compressedMagic) {
            guard data.count > compressedMagic.count + 8 else { throw UsageArchiveError.corrupt }
            let sizeBytes = data.dropFirst(compressedMagic.count).prefix(8)
            let size = sizeBytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            guard size > 0, size <= UInt64(maximumExpandedBytes), data.count <= maximumExpandedBytes else {
                throw UsageArchiveError.corrupt
            }
            let compressed = data.dropFirst(compressedMagic.count + 8)
            var decoded = Data(count: Int(size))
            let count = decoded.withUnsafeMutableBytes { output in
                compressed.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, Int(size),
                                              input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                              nil, COMPRESSION_LZFSE)
                }
            }
            guard count == Int(size) else { throw UsageArchiveError.corrupt }
            json = decoded
        } else {
            guard data.count <= maximumExpandedBytes else { throw UsageArchiveError.corrupt }
            json = data
        }
        return try JSONDecoder().decode(UsageLedgerCache.self, from: json)
    }

    /// Atomic, private and truthful: callers can keep the prior in-memory
    /// checkpoint when disk persistence fails, and surface that failure.
    @discardableResult
    func save(to url: URL) -> Bool {
        do {
            let json = try JSONEncoder().encode(self)
            guard json.count <= Self.maximumExpandedBytes else { return false }
            var data = json
            if json.count > Self.maximumBytes {
                let compressed = try (json as NSData).compressed(using: .lzfse)
                var size = UInt64(json.count).littleEndian
                data = Self.compressedMagic
                withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
                data.append(compressed as Data)
            }
            try AccountStorage.privateDirectory(url.deletingLastPathComponent())
            try AccountStorage.write(data, to: url)
            return true
        } catch { return false }
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
