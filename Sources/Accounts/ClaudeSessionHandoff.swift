import Foundation

/// Moves only Claude's conversation record between two local profiles. Login
/// credentials stay in their original Keychain entries.
enum ClaudeSessionHandoff {
    static func copyConversation(id: String, project: URL, from source: URL, to destination: URL,
                                 fileManager: FileManager = .default) throws {
        guard UUID(uuidString: id) != nil, project.isFileURL else { throw ManagedAccountError.invalidResponse }
        let sourceProjects = source.appendingPathComponent("projects", isDirectory: true)
        let destinationProjects = destination.appendingPathComponent("projects", isDirectory: true)
        guard let transcript = transcript(id: id, under: sourceProjects, fileManager: fileManager) else {
            throw ManagedAccountError.unavailable
        }
        let relativeFolder = transcript.deletingLastPathComponent().lastPathComponent
        guard !relativeFolder.isEmpty, relativeFolder != ".", relativeFolder != "..",
              !relativeFolder.contains("/"),
              !relativeFolder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ManagedAccountError.unsafePath }
        let targetFolder = destinationProjects.appendingPathComponent(relativeFolder, isDirectory: true)
        try AccountStorage.privateDirectory(targetFolder)
        try copyIfNeeded(transcript, to: targetFolder.appendingPathComponent("\(id).jsonl"), fileManager: fileManager)
        let actualCompanion = transcript.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: actualCompanion.path) {
            try copyIfNeeded(actualCompanion, to: targetFolder.appendingPathComponent(id, isDirectory: true), fileManager: fileManager)
        }
    }

    private static func transcript(id: String, under root: URL, fileManager: FileManager) -> URL? {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let expected = "\(id).jsonl"
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == expected { return item }
        }
        return nil
    }

    private static func copyIfNeeded(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ManagedAccountError.unsafePath
        }
        if fileManager.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ManagedAccountError.unsafePath
        }
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.copyItem(at: source, to: destination)
    }
}
