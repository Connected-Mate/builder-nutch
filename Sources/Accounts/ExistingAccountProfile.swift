import Foundation
import Darwin

/// Stable source reference, never a copied login. Discovery only examines conventional
/// CLI directories and file metadata; authentication remains the official CLI's job.
struct ExistingAccountProfile: Codable, Equatable {
    enum KimiAuthenticationStatus { case present, signedOut, unknown }

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

    /// Kimi leaves its profile directory behind after logout. Distinguish that
    /// empty shell from an account without retaining or exposing credential data.
    func kimiAuthenticationStatus() -> KimiAuthenticationStatus {
        guard let root = try? validatedDirectory() else { return .unknown }
        let credentials = root.appendingPathComponent("credentials/kimi-code.json")
        let legacy = root.appendingPathComponent("oauth/kimi-code")
        for item in [credentials, legacy] {
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            do {
                try AccountStorage.rejectSymlink(item)
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
                guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else { return .unknown }
            } catch { return .unknown }
        }
        if let data = try? Data(contentsOf: legacy, options: .mappedIfSafe), !data.isEmpty { return .present }
        guard let data = try? Data(contentsOf: credentials, options: .mappedIfSafe), data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String else { return .unknown }
        return access.isEmpty && refresh.isEmpty ? .signedOut : .present
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
        // No recursion, browser-cookie scanning or shell evaluation. For Kimi,
        // the known credential file is checked only for empty login fields so a
        // logged-out profile is not presented as a second subscription.
        for profile in ClaudeProfile.discover(home: home) {
            append(.claude, profile.configDirectory, defaultClaude: profile.slug == nil)
        }
        append(.codex, home.appendingPathComponent(".codex"))
        let kimi = home.appendingPathComponent(".kimi-code")
        let kimiSource = ExistingAccountProfile(directory: kimi.standardizedFileURL.path, usesDefaultClaudeHome: false)
        if kimiSource.kimiAuthenticationStatus() != .signedOut { append(.kimi, kimi) }
        for (provider, variable) in [(AccountProvider.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME"), (.kimi, "KIMI_CODE_HOME")] {
            if let path = environment[variable], path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path)
                let source = ExistingAccountProfile(directory: url.standardizedFileURL.path, usesDefaultClaudeHome: false)
                if provider != .kimi || source.kimiAuthenticationStatus() != .signedOut { append(provider, url) }
            }
        }
        return result
    }
}
