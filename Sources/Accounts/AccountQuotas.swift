import Foundation
import CoreFoundation

enum AccountQuotas {
    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= 524_288,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ManagedAccountError.invalidResponse }
        return object
    }

    static func percentage(_ object: [String: Any], key: String) -> Double? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? min(value, 100) / 100 : nil
    }

    static func date(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let value = raw as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        return nil
    }

    static func claude(status: Data, quota: Data?, now: Date = Date()) throws -> ManagedAccountState {
        let object = try json(status)
        guard let connected = object["loggedIn"] as? Bool else { throw ManagedAccountError.invalidResponse }
        var state = ManagedAccountState(isConnected: connected,
                                        email: object["email"] as? String, plan: object["subscriptionType"] as? String)
        guard connected else { state.message = "Connect this account."; return state }
        guard let quota, let payload = try? json(quota), let recorded = date(payload["recordedAt"]),
              recorded <= now.addingTimeInterval(5), let rates = payload["rate_limits"] as? [String: Any] else {
            state.message = "Usage appears after the first Claude Code session launched here."
            return state
        }
        state.refreshedAt = recorded
        state.windows = [("five_hour", "5h limit"), ("seven_day", "Weekly limit")].compactMap { key, label in
            guard let window = rates[key] as? [String: Any] else { return nil }
            let fraction = percentage(window, key: "used_percentage")
            return LimitWindow(id: key, label: label, usedFraction: fraction, resetsAt: date(window["resets_at"]))
        }
        if state.windows.isEmpty { state.message = "Usage appears after the first Claude Code session launched here." }
        else if !state.isFresh(at: now) { state.message = "Usage is older than five minutes. Use this Claude Code session to update it." }
        return state
    }

    static func codex(_ data: Data, now: Date = Date()) throws -> ManagedAccountState {
        let object = try json(data)
        guard let account = object["account"] as? [String: Any] else {
            return ManagedAccountState(message: "Connect this account.")
        }
        guard account["type"] as? String == "chatgpt" else {
            return ManagedAccountState(message: "Connect a ChatGPT subscription account through the browser.")
        }
        var state = ManagedAccountState(isConnected: true, email: account["email"] as? String,
                                        plan: account["planType"] as? String)
        guard let limits = object["limits"] as? [String: Any] else {
            state.message = "Connected. Usage is temporarily unavailable; refresh to try again."
            return state
        }
        var buckets: [(String, [String: Any])] = []
        if let byID = limits["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
            buckets = byID.keys.sorted().map { ($0, byID[$0]!) }
        } else if let legacy = limits["rateLimits"] as? [String: Any] { buckets = [("codex", legacy)] }
        for (bucketID, bucket) in buckets {
            if let reached = bucket["rateLimitReachedType"] as? String, !reached.isEmpty {
                state.message = "Codex reports an account or workspace limit. This account is unavailable for automatic selection."
            }
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any] else { continue }
                let fraction = percentage(window, key: "usedPercent")
                let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
                let duration = minutes == 10080 ? "Weekly limit" : minutes == 300 ? "5h limit" : minutes.map { $0 < 60 || $0 % 60 != 0 ? "\($0) min limit" : "\($0 / 60)h limit" } ?? (key == "primary" ? "Session limit" : "Longer limit")
                let title = bucketID == "codex" ? duration : "\(bucket["limitName"] as? String ?? bucketID) · \(duration)"
                state.windows.append(LimitWindow(id: bucketID == "codex" ? key : "\(bucketID).\(key)", label: title, usedFraction: fraction, resetsAt: date(window["resetsAt"])))
            }
        }
        if state.windows.isEmpty && state.message == nil { state.message = "Connected. No usage limits were reported by Codex." }
        else { state.refreshedAt = now }
        return state
    }
}

enum ClaudeAccountStatusLine {
    /// JXA is part of macOS. Only two numerical quota windows are persisted;
    /// transcripts, tokens, workspace paths and the rest of stdin are discarded.
    static let helper = #"""
    ObjC.import('Foundation');
    ObjC.bindFunction('rename', ['int', ['char *', 'char *']]);
    function run(argv) {
      try {
        const profile = argv[0];
        if (!profile) return '';
        const raw = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        if (Number(raw.length) > 1048576) return '';
        const input = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(raw, $.NSUTF8StringEncoding)));
        const source = input.rate_limits || {};
        const rates = {};
        ['five_hour', 'seven_day'].forEach(function(key) {
          const item = source[key];
          if (!item || typeof item !== 'object') return;
          const value = {};
          if (typeof item.used_percentage === 'number' && Number.isFinite(item.used_percentage) && item.used_percentage >= 0) value.used_percentage = Math.min(item.used_percentage, 100);
          if (typeof item.resets_at === 'number' && Number.isFinite(item.resets_at) && item.resets_at > 0) value.resets_at = item.resets_at;
          if (typeof item.resets_at === 'string' && item.resets_at.length < 50 && Number.isFinite(Date.parse(item.resets_at))) value.resets_at = item.resets_at;
          rates[key] = value;
        });
        if (!Object.keys(rates).length) return '';
        const fm = $.NSFileManager.defaultManager;
        const destination = profile + '/quota.json';
        if (fm.fileExistsAtPath($(destination))) {
          const attrs = ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(destination), null));
          if (attrs.NSFileType === 'NSFileTypeSymbolicLink') return '';
        }
        const text = $(JSON.stringify({recordedAt: Date.now() / 1000, rate_limits: rates}));
        const temporary = profile + '/.quota-' + ObjC.unwrap($.NSUUID.UUID.UUIDString);
        const permissions = $.NSDictionary.dictionaryWithObjectForKey($(384), $.NSFilePosixPermissions);
        if (!fm.createFileAtPathContentsAttributes($(temporary), text.dataUsingEncoding($.NSUTF8StringEncoding), permissions)) return '';
        if ($.rename(temporary, destination) !== 0) { fm.removeItemAtPathError($(temporary), null); return ''; }
        return Object.keys(rates).map(function(key) { return (key === 'five_hour' ? '5h ' : 'Week ') + Math.round(100 - rates[key].used_percentage) + '% left'; }).join(' · ');
      } catch (_) { return ''; }
    }
    """#

    static func configure(profile: URL) throws {
        let helperURL = profile.appendingPathComponent("account-statusline.js")
        try AccountStorage.write(Data(helper.utf8), to: helperURL)
        let settingsURL = profile.appendingPathComponent("settings.json")
        try AccountStorage.rejectSymlink(settingsURL)
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            settings = try AccountQuotas.json(Data(contentsOf: settingsURL))
        }
        settings["statusLine"] = ["type": "command", "command": "/usr/bin/osascript -l JavaScript \(AccountEnvironment.quote(helperURL.path)) \(AccountEnvironment.quote(profile.path))"]
        try AccountStorage.write(JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
    }
}
