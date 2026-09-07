import Foundation
import Darwin

/// Stable source reference, never a copied login. Discovery only examines conventional
/// CLI directories and file metadata; authentication remains the official CLI's job.
struct ExistingAccountProfile: Codable, Equatable {
    let directory: String
    let usesDefaultClaudeHome: Bool

    func key(provider: AccountProvider) -> String { provider.rawValue + ":" + directory }

    func validatedDirectory() throws -> URL {
        guard directory.hasPrefix("/"), !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ManagedAccountError.unsafePath
        }
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        guard url.path == directory, directory != "/" else { throw ManagedAccountError.unsafePath }
        try AccountStorage.rejectSymlink(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else {
            throw ManagedAccountError.unsafePath
        }
        for name in ["config.toml", "settings.json", ".claude.json", "auth.json", ".credentials.json", "oauth", "credentials"] {
            let item = url.appendingPathComponent(name)
            try AccountStorage.rejectSymlink(item)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: item.path) {
                guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else {
                    throw ManagedAccountError.unsafePath
                }
            }
        }
        return url
    }

    func environment(provider: AccountProvider, inherited: [String: String]) -> [String: String] {
        var result = AccountEnvironment.isolated(profile: URL(fileURLWithPath: directory), provider: provider, inherited: inherited)
        // An explicitly set CLAUDE_CONFIG_DIR changes Claude's keychain service,
        // even when it happens to point at ~/.claude.
        if provider == .claude && usesDefaultClaudeHome { result.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        if provider == .kimi { result["HOME"] = inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path }
        return result
    }
}

struct ExistingAccountCandidate {
    let provider: AccountProvider
    let label: String
    let source: ExistingAccountProfile
}

enum ExistingAccountDiscovery {
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> [ExistingAccountCandidate] {
        var result: [ExistingAccountCandidate] = []
        func append(_ provider: AccountProvider, _ path: URL, defaultClaude: Bool = false) {
            let source = ExistingAccountProfile(directory: path.standardizedFileURL.path, usesDefaultClaudeHome: defaultClaude)
            guard (try? source.validatedDirectory()) != nil,
                  !result.contains(where: { $0.source.key(provider: $0.provider) == source.key(provider: provider) }) else { return }
            let base = provider == .kimi ? ".kimi-code" : "." + provider.rawValue
            let suffix = path.lastPathComponent == base ? "on this Mac" : path.lastPathComponent
            result.append(ExistingAccountCandidate(provider: provider, label: "\(provider.title) · \(suffix)", source: source))
        }
        // No recursion, browser-cookie scanning, shell evaluation or credential reads.
        for profile in ClaudeProfile.discover(home: home) {
            append(.claude, profile.configDirectory, defaultClaude: profile.slug == nil)
        }
        append(.codex, home.appendingPathComponent(".codex"))
        append(.kimi, home.appendingPathComponent(".kimi-code"))
        for (provider, variable) in [(AccountProvider.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME"), (.kimi, "KIMI_CODE_HOME")] {
            if let path = environment[variable], path.hasPrefix("/") { append(provider, URL(fileURLWithPath: path)) }
        }
        return result
    }
}
