import Foundation

enum AccountEnvironment {
    /// An allowlist also excludes future vendor auth/provider override variables.
    static func isolated(profile: URL, provider: AccountProvider, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM", "SSH_AUTH_SOCK", "SYSTEMROOT"]
        var result = inherited.filter { allowed.contains($0.key) }
        result["PATH"] = result["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = profile.path
        return result
    }

    static func executable(for provider: AccountProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let name = provider == .claude ? "claude" : "codex"
        var candidates = [home.appendingPathComponent(".local/bin/\(name)").path,
                          "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if provider == .codex {
            candidates += [home.appendingPathComponent(".agentation/bin/codex").path,
                           "/Applications/Codex.app/Contents/Resources/codex",
                           "/Applications/ChatGPT.app/Contents/Resources/codex",
                           home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path]
        }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/\(name)" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func launchScript(executable: URL, account: ManagedAccount, profile: URL, project: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let env = isolated(profile: profile, provider: account.provider, inherited: inherited)
        let assignments = env.keys.sorted().map { quote("\($0)=\(env[$0]!)") }.joined(separator: " ")
        let config = account.provider == .codex ? " --config " + quote("cli_auth_credentials_store=\"keyring\"") : ""
        // env -i also removes secrets injected by Terminal's own environment.
        return "#!/bin/sh\ncd \(quote(project.path)) || exit 1\nexec /usr/bin/env -i \(assignments) \(quote(executable.path))\(config)\n"
    }
}
