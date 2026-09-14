import Foundation
import Darwin

struct CustomAssistantConfiguration: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var website: URL
    var instructions: String
    /// User-supplied explanatory text, never an automatically measured quota.
    var usageNote: String
    var updatedAt: Date
    var usage: CustomAssistantUsage?

    static func validated(id: UUID = UUID(), name: String, website: String,
                          instructions: String = "", usageNote: String = "") throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CustomAssistantError.invalid("Use an assistant name between 1 and 80 characters.")
        }
        guard instructions.count <= 8_000, usageNote.count <= 500 else {
            throw CustomAssistantError.invalid("Instructions are limited to 8000 characters and usage notes to 500.")
        }
        guard let parts = URLComponents(string: website), parts.scheme?.lowercased() == "https",
              let host = parts.host, host.contains("."), !host.hasSuffix(".local"),
              host.split(separator: ".").last?.allSatisfy({ $0.isLetter }) == true,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let url = parts.url else {
            throw CustomAssistantError.invalid("Use a public HTTPS website without credentials, query parameters or fragments.")
        }
        return Self(id: id, name: name, website: url, instructions: instructions,
                    usageNote: usageNote, updatedAt: Date(), usage: nil)
    }
}

enum CustomAssistantError: LocalizedError {
    case invalid(String)
    case storage
    case corrupt
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .storage: return "The private assistant folder could not be accessed safely."
        case .corrupt: return "Saved assistants could not be read. The existing file has been preserved."
        }
    }
}

/// A separate, private catalog. This never opens provider accounts, credentials, or scripts.
/// The root override is for in-process tests only; the MCP transport cannot select a path.
struct CustomAssistantRepository {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Builder Nutch Assistants", isDirectory: true)
    let root: URL
    init(root: URL = Self.defaultRoot) { self.root = root }

    func list() throws -> [CustomAssistantConfiguration] {
        try transaction { directory in try read(directory: directory) }
    }

    @discardableResult
    func configure(id: UUID?, name: String, website: String, instructions: String? = nil,
                   usageNote: String? = nil) throws -> CustomAssistantConfiguration {
        var entry = try CustomAssistantConfiguration.validated(name: name, website: website,
                                                               instructions: instructions ?? "", usageNote: usageNote ?? "")
        return try transaction { directory in
            var entries = try read(directory: directory)
            let index: Int?
            if let id {
                guard let existing = entries.firstIndex(where: { $0.id == id }) else {
                    throw CustomAssistantError.invalid("Assistant not found. List assistants before updating one.")
                }
                index = existing
            } else {
                index = entries.firstIndex { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            }
            if let index {
                guard !entries.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(entry.name) == .orderedSame }) else {
                    throw CustomAssistantError.invalid("Another assistant already uses this name.")
                }
                entry.id = entries[index].id
                entry.usage = entries[index].usage
                if instructions == nil { entry.instructions = entries[index].instructions }
                if usageNote == nil { entry.usageNote = entries[index].usageNote }
                entries[index] = entry
            } else {
                guard entries.count < 100 else { throw CustomAssistantError.invalid("The catalog is limited to 100 assistants.") }
                entries.append(entry)
            }
            try write(entries, directory: directory)
            return entry
        }
    }

    @discardableResult
    func reportUsage(id: UUID, usage: CustomAssistantUsage) throws -> CustomAssistantConfiguration {
        try usage.validate()
        return try transaction { directory in
            var entries = try read(directory: directory)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw CustomAssistantError.invalid("Assistant not found. Configure it before reporting usage.")
            }
            if let previous = entries[index].usage, usage.observedAt < previous.observedAt {
                throw CustomAssistantError.invalid("This reading is older than the saved reading.")
            }
            entries[index].usage = usage
            entries[index].updatedAt = Date()
            try write(entries, directory: directory)
            return entries[index]
        }
    }

    func remove(id: UUID) throws {
        try transaction { directory in
            var entries = try read(directory: directory)
            entries.removeAll { $0.id == id }
            try write(entries, directory: directory)
        }
    }

    private func transaction<T>(_ body: (Int32) throws -> T) throws -> T {
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw CustomAssistantError.storage }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CustomAssistantError.storage }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(),
              fchmod(directory, 0o700) == 0 else { throw CustomAssistantError.storage }
        let lock = openat(directory, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CustomAssistantError.storage }
        defer { close(lock) }
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX) == 0 else { throw CustomAssistantError.storage }
        defer { flock(lock, LOCK_UN) }
        return try body(directory)
    }

    private func read(directory: Int32) throws -> [CustomAssistantConfiguration] {
        let file = openat(directory, "assistants.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return [] }
        guard file >= 0 else { throw CustomAssistantError.storage }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 4_000_000 else {
            throw CustomAssistantError.storage
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([CustomAssistantConfiguration].self, from: data),
              entries.count <= 100, Set(entries.map(\.id)).count == entries.count else {
            throw CustomAssistantError.corrupt
        }
        for entry in entries {
            try entry.usage?.validate()
            _ = try CustomAssistantConfiguration.validated(id: entry.id, name: entry.name,
                website: entry.website.absoluteString, instructions: entry.instructions, usageNote: entry.usageNote)
        }
        return entries
    }

    private func write(_ entries: [CustomAssistantConfiguration], directory: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        guard data.count <= 4_000_000 else {
            throw CustomAssistantError.invalid("The assistant catalog is full. Shorten saved instructions before adding more.")
        }
        let temporary = ".assistants-\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CustomAssistantError.storage }
        defer { close(file); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(file) == 0, renameat(directory, temporary, directory, "assistants.json") == 0 else {
            throw CustomAssistantError.storage
        }
        _ = fsync(directory)
    }
}
