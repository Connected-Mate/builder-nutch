import SwiftUI

/// The transcript source is an app, not necessarily the model's vendor:
/// Claude Code can record an OpenAI model when a relay is used.
enum UsageModelPresentation {
    static func count(_ value: Int, availability: UsageMeasurementAvailability,
                      locale: Locale = .current) -> String {
        guard availability != .unavailable else { return "—" }
        let style = IntegerFormatStyle<Int>.number.notation(.compactName)
            .precision(.fractionLength(0...1)).locale(locale)
        return availability == .partial
            ? "≥ " + value.formatted(style.rounded(rule: .down)) : value.formatted(style)
    }

    static func name(_ modelID: String?, locale: Locale = .current) -> String {
        guard let modelID, !modelID.isEmpty else {
            return localized("Model not recorded", locale: locale)
        }
        // Only format known naming structures. Opaque and custom IDs remain exact.
        if let match = modelID.range(of: #"^claude-(opus|sonnet|haiku|fable|mythos)-[0-9]+(?:-[0-9]+)?(?:-[0-9]{8})?$"#,
                                     options: .regularExpression), match == modelID.startIndex..<modelID.endIndex {
            var parts = modelID.split(separator: "-").map(String.init)
            parts.removeFirst()
            let family = parts.removeFirst().capitalized
            let revision = parts.last?.count == 8 ? parts.removeLast() : nil
            return "Claude \(family) \(parts.joined(separator: "."))" + (revision.map { " · \($0)" } ?? "")
        }
        if modelID.hasPrefix("gpt-") {
            let parts = modelID.dropFirst(4).split(separator: "-").map(String.init)
            guard let version = parts.first else { return modelID }
            return "GPT-\(version)" + (parts.count > 1 ? " " + parts.dropFirst().map { $0.capitalized }.joined(separator: " ") : "")
        }
        return modelID
    }

    static func source(_ provider: UsageTranscriptFormat?) -> String? {
        switch provider {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case nil: return nil
        }
    }

    static func glyph(_ modelID: String?) -> ProviderGlyph? {
        guard let id = modelID?.lowercased() else { return nil }
        if id.hasPrefix("claude-") { return .claude }
        if id.hasPrefix("gpt-") || id.range(of: #"^o[134](?:-|$)"#, options: .regularExpression) != nil { return .openai }
        return nil
    }

    static func context(modelID: String?, provider: UsageTranscriptFormat?, sources: [UsageTranscriptFormat] = []) -> String {
        let vendor: String?
        switch glyph(modelID) {
        case .claude: vendor = "Anthropic"
        case .openai: vendor = "OpenAI"
        default: vendor = nil
        }
        let tools = sources.isEmpty ? source(provider) : sources.compactMap { source($0) }.joined(separator: " + ")
        return [vendor, tools].compactMap { $0 }.joined(separator: " · ")
    }

    static func localized(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
