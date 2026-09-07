import Foundation
import CoreFoundation

/// Claude Code's official read-only SDK control protocol. No user message is
/// ever sent: get_usage reads subscription limits before the first paid prompt.
struct ClaudeUsageControlProtocol {
    enum Event { case none, send([String: Any]), complete([String: Any]) }
    private var requested = false
    var initialize: [String: Any] {
        ["type": "control_request", "request_id": "builder-nutch-init",
         "request": ["subtype": "initialize", "hooks": [:]]]
    }
    mutating func receive(_ data: Data) throws -> Event {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["type"] as? String == "control_response", let response = message["response"] as? [String: Any],
              let id = response["request_id"] as? String else { return .none }
        if id == "builder-nutch-init" && !requested {
            guard response["subtype"] as? String == "success" else { throw ManagedAccountError.invalidResponse }
            requested = true
            return .send(["type": "control_request", "request_id": "builder-nutch-usage",
                          "request": ["subtype": "get_usage", "skip_behaviors": true]])
        }
        if id == "builder-nutch-usage" && requested {
            guard response["subtype"] as? String == "success", let payload = response["response"] as? [String: Any] else {
                throw ManagedAccountError.invalidResponse
            }
            // Session history, diagnostics and behavioral data never leave this reader.
            return .complete(payload.filter { ["subscription_type", "rate_limits_available", "rate_limits"].contains($0.key) })
        }
        return .none
    }
}

enum ClaudeAccountUsage {
    static let unavailable = "Claude is connected. Subscription usage is temporarily unavailable; refresh to try again."

    static func command(executable: URL, profile: URL, environment: [String: String]) -> AccountCommand {
        var safe = environment
        safe["CLAUDE_CODE_SAFE_MODE"] = "1"
        return AccountCommand(executable: executable,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--tools", ""],
            environment: safe, directory: profile, timeout: 20, readsClaudeUsage: true)
    }

    static func state(status: ManagedAccountState, usage: Data, now: Date = Date()) throws -> ManagedAccountState {
        var state = status
        state.windows = []; state.refreshedAt = nil; state.message = unavailable
        guard status.isConnected else { return state }
        let object = try AccountQuotas.json(usage)
        guard let available = boolean(object["rate_limits_available"]) else { throw ManagedAccountError.invalidResponse }
        guard available, let rates = object["rate_limits"] as? [String: Any] else { return state }
        if let plan = text(object["subscription_type"]) { state.plan = plan }
        for (key, label) in [("five_hour", "5h limit"), ("seven_day", "Weekly limit"),
                             ("seven_day_oauth_apps", "OAuth apps weekly limit"), ("seven_day_opus", "Opus weekly limit"),
                             ("seven_day_sonnet", "Sonnet weekly limit")] {
            guard let value = rates[key], !(value is NSNull) else { continue }
            guard let row = value as? [String: Any] else { throw ManagedAccountError.invalidResponse }
            state.windows.append(try window(row, id: key, label: label, percentage: "utilization"))
        }
        if let raw = rates["model_scoped"], !(raw is NSNull) {
            guard let models = raw as? [[String: Any]], models.count <= 50 else { throw ManagedAccountError.invalidResponse }
            for (index, row) in models.enumerated() {
                guard let name = text(row["display_name"]) else { throw ManagedAccountError.invalidResponse }
                state.windows.append(try window(row, id: "model-\(index)", label: "\(name) weekly limit", percentage: "utilization"))
            }
        }
        let knownKeys: Set<String> = ["five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet", "model_scoped", "limits", "extra_usage"]
        // New server buckets must not disappear merely because this client
        // predates their names. Unknown numeric subscription windows constrain selection.
        for key in rates.keys.sorted() where !knownKeys.contains(key) {
            if let row = rates[key] as? [String: Any], row["utilization"] != nil {
                state.windows.append(try window(row, id: "additional-\(state.windows.count)", label: "Additional subscription limit", percentage: "utilization"))
            }
        }
        var blocking = false
        if let raw = rates["limits"], !(raw is NSNull) {
            guard let limits = raw as? [[String: Any]], limits.count <= 50 else { throw ManagedAccountError.invalidResponse }
            for (index, row) in limits.enumerated() {
                guard let kind = text(row["kind"]) else { throw ManagedAccountError.invalidResponse }
                let scope = row["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any]).flatMap { text($0["display_name"]) }
                let label = kind == "session" ? "5h limit" : kind == "weekly_all" ? "Weekly limit" : model.map { "\($0) weekly limit" } ?? "Additional subscription limit"
                let item = try window(row, id: "limit-\(index)", label: label, percentage: "percent")
                // is_active describes applicability to a selected model, not the
                // existence of a limit. All subscription constraints remain visible.
                if !state.windows.contains(where: { $0.label == item.label && $0.usedFraction == item.usedFraction }) { state.windows.append(item) }
                if let severity = text(row["severity"]), !["normal", "warning"].contains(severity) { blocking = true }
                if boolean(row["blocking"]) == true || boolean(row["is_blocking"]) == true { blocking = true }
            }
        }
        // Paid extra_usage is never added to subscription allowance.
        guard !state.windows.isEmpty else { return state }
        let known = state.windows.allSatisfy { $0.usedFraction != nil }
        state.refreshedAt = known ? now : nil
        state.message = !known ? unavailable : blocking ? "Claude reports a subscription restriction. Choose an account manually or refresh its usage." : nil
        return state
    }

    private static func window(_ row: [String: Any], id: String, label: String, percentage: String) throws -> LimitWindow {
        let fraction: Double?
        if let raw = row[percentage], !(raw is NSNull) {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { throw ManagedAccountError.invalidResponse }
            fraction = min(1, value.doubleValue / 100)
        } else { fraction = nil }
        let reset = AccountQuotas.date(row["resets_at"])
        if let raw = row["resets_at"], !(raw is NSNull), reset == nil { throw ManagedAccountError.invalidResponse }
        return LimitWindow(id: id, label: label, usedFraction: fraction, resetsAt: reset)
    }
    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.count <= 120,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}
