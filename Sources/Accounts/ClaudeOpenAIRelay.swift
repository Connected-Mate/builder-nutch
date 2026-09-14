import Foundation

/// Only the official Codex model catalogue can make a model selectable.
enum ClaudeOpenAIRelay {
    struct Model: Decodable, Identifiable, Equatable {
        let id: String
        let displayName: String
    }
    struct Probe: Decodable {
        let authenticated: Bool
        let models: [Model]?
        let errorCode: String?
    }
    enum Mode: String, CaseIterable { case openai, auto }
    enum History: String, CaseIterable { case resume, newSession }

    enum Failure: LocalizedError {
        case missingNode, missingRelay, probeFailed, noModels, invalidModel, unsupportedCodex, notAuthenticated
        var errorDescription: String? {
            switch self {
            case .missingNode: return NSLocalizedString("Install Node.js 22 or newer, then reopen this window.", comment: "Relay error")
            case .missingRelay: return NSLocalizedString("The relay is missing. Reinstall Builder Nutch, then try again.", comment: "Relay error")
            case .probeFailed: return NSLocalizedString("Couldn't check OpenAI models. Check your connection and reconnect this Codex account, then retry.", comment: "Relay error")
            case .noModels: return NSLocalizedString("This Codex account returned no available models. Reconnect it, then retry.", comment: "Relay error")
            case .invalidModel: return NSLocalizedString("Choose a model available to the selected Codex account.", comment: "Relay error")
            case .unsupportedCodex: return NSLocalizedString("This Codex version isn't supported by the relay. Install Codex 0.154.0 or update Builder Nutch.", comment: "Relay error")
            case .notAuthenticated: return NSLocalizedString("Reconnect the selected Codex account, then retry.", comment: "Relay error")
            }
        }
    }

    static func nodeExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appendingPathComponent(".local/bin/node").path,
                          "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        candidates += (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/node" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func bundledScript() throws -> URL {
        guard let url = Bundle.main.url(forResource: "claude-openai-relay", withExtension: "mjs") else { throw Failure.missingRelay }
        return url
    }

    static func models(from data: Data) throws -> [Model] {
        guard let response = try? JSONDecoder().decode(Probe.self, from: data) else { throw Failure.probeFailed }
        switch response.errorCode {
        case "unsupported_codex_version": throw Failure.unsupportedCodex
        case "unsupported_node_version": throw Failure.missingNode
        case "not_authenticated": throw Failure.notAuthenticated
        case .some: throw Failure.probeFailed
        case .none: break
        }
        guard response.authenticated else { throw Failure.notAuthenticated }
        var seen = Set<String>()
        let models = (response.models ?? []).filter {
            !$0.id.isEmpty && $0.id.count <= 200 && !$0.id.hasPrefix("-") &&
            !$0.id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) &&
            !$0.displayName.isEmpty && $0.displayName.count <= 200 && seen.insert($0.id).inserted
        }
        guard !models.isEmpty else { throw Failure.noModels }
        return models
    }

    static func preferredModel(in models: [Model]) -> String? {
        models.first { $0.id == "gpt-6-astra" }?.id ?? models.first?.id
    }

    static func launchScript(node: URL, relay: URL, codex: URL, claude: URL, project: URL,
                             model: String, mode: Mode, history: History, environment: [String: String]) -> String {
        let quote = AccountEnvironment.quote
        let assignments = environment.keys.sorted().map { quote("\($0)=\(environment[$0]!)") }.joined(separator: " ")
        var arguments = [node.path, relay.path, "launch", "--codex", codex.path, "--claude", claude.path,
                         "--model", model, "--cwd", project.path, "--mode", mode.rawValue, "--"]
        if history == .resume { arguments.append("--resume") }
        return "#!/bin/sh\ncd \(quote(project.path)) || exit 1\nexec /usr/bin/env -i \(assignments) \(arguments.map(quote).joined(separator: " "))\n"
    }
}
