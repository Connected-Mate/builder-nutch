import Foundation
import Darwin

/// New sessions use Claude's ordinary Mac login and its own overload fallback.
enum ClaudeModelLauncher {
    enum Failure: Error { case invalidModel, unsafePath, invalidEnvironment }
    private static let settingsLimit = 65_536

    private static func validModel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        if ["sonnet", "opus", "haiku", "sonnet[1m]", "opus[1m]", "opusplan"].contains(value) { return true }
        return value.range(of: "^claude-(?:sonnet|opus|haiku)-[0-9]+(?:-[0-9]+)*(?:\\[1m\\])?$", options: .regularExpression) != nil
            || value.range(of: "^claude-[0-9]+(?:-[0-9]+)*-(?:sonnet|opus|haiku)(?:-[0-9]{8})?(?:\\[1m\\])?$", options: .regularExpression) != nil
    }

    /// Read only settings.json; no credential discovery and no settings mutation.
    static func readPreference(directory: URL) -> String? {
        guard directory.isFileURL else { return nil }
        let file = directory.appendingPathComponent("settings.json")
        guard (try? AccountStorage.rejectSymlink(file)) != nil else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= settingsLimit else { return nil }
        var bytes = [UInt8](repeating: 0, count: settingsLimit + 1)
        var count = 0
        while count < bytes.count {
            let size = bytes.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if size < 0 { if errno == EINTR { continue }; return nil }
            if size == 0 { break }
            count += size
        }
        guard count <= settingsLimit,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
              let model = object["model"] as? String, validModel(model) else { return nil }
        return model
    }

    static func script(executable: URL, project: URL, model: String, fallbackModels: [String],
                       inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard validModel(model), fallbackModels.count <= 8, fallbackModels.allSatisfy(validModel) else { throw Failure.invalidModel }
        for url in [executable, project] {
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
                  !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.unsafePath }
        }
        let profile = ExistingAccountProfile(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path,
                                             usesDefaultClaudeHome: true)
        let environment = profile.environment(provider: .claude, inherited: inherited)
        guard environment.values.allSatisfy({ $0.utf8.count <= 32_768 && !$0.utf8.contains(0) }) else { throw Failure.invalidEnvironment }
        let quote = AccountEnvironment.quote
        let assignments = environment.keys.sorted().map { quote("\($0)=\(environment[$0]!)") }.joined(separator: " ")
        let fallback = fallbackModels.isEmpty ? "" : " --fallback-model " + quote(fallbackModels.joined(separator: ","))
        return "#!/bin/sh\ncd \(quote(project.path)) || exit 1\nexec /usr/bin/env -i \(assignments) \(quote(executable.path)) --model \(quote(model))\(fallback)\n"
    }
}
