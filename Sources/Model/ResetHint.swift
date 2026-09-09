import Foundation

/// Turns a vendor's written reset hint into a real instant.
///
/// Kimi's local server never sends `reset_at`; it sends a sentence such as
/// "resets in 2d 6h 36m". Reading that as `now + duration` is a derivation, not
/// an invention, so it is allowed — but only when the whole string is
/// understood. Anything ambiguous returns nil and the window keeps no reset
/// time at all, which is the honest answer.
enum ResetHint {
    /// Nothing sensible resets more than three months out. A hint that claims
    /// otherwise is a parse gone wrong, not a real window.
    static let maximum: TimeInterval = 90 * 24 * 3600

    static func date(from raw: Any?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let text = raw as? String, text.count <= 120,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let hint = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hint.isEmpty else { return nil }
        if let absolute = isoDate(hint) { return within(absolute, now: now) }
        if let clock = clockTime(hint, now: now, calendar: calendar) { return within(clock, now: now) }
        if let seconds = duration(hint), seconds > 0 { return within(now.addingTimeInterval(seconds), now: now) }
        return nil
    }

    private static func within(_ date: Date, now: Date) -> Date? {
        let ahead = date.timeIntervalSince(now)
        return ahead > 0 && ahead <= maximum ? date : nil
    }

    /// "2026-09-12T14:00:00Z", with or without fractional seconds.
    private static func isoDate(_ hint: String) -> Date? {
        guard let range = hint.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}[t ][0-9]{2}:[0-9]{2}(:[0-9]{2})?([.][0-9]+)?(z|[+-][0-9]{2}:?[0-9]{2})?",
                                     options: .regularExpression) else { return nil }
        let stamp = String(hint[range]).replacingOccurrences(of: " ", with: "T").uppercased()
        let formatter = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options] {
            formatter.formatOptions = options
            if let date = formatter.date(from: stamp) { return date }
        }
        // A stamp without a zone designator is local time, as the vendor wrote it.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: stamp) { return date }
        }
        return nil
    }

    /// "resets at 14:00" or "resets at 2:30 pm" — the next time that clock reads so.
    private static func clockTime(_ hint: String, now: Date, calendar: Calendar) -> Date? {
        guard hint.contains(" at ") || hint.hasPrefix("at ") else { return nil }
        guard let range = hint.range(of: "\\b([0-9]{1,2}):([0-9]{2})\\s*(am|pm)?", options: .regularExpression) else { return nil }
        let piece = String(hint[range])
        let digits = piece.split(whereSeparator: { !$0.isNumber })
        guard digits.count == 2, var hour = Int(digits[0]), let minute = Int(digits[1]),
              hour <= 23, minute <= 59 else { return nil }
        if piece.contains("pm"), hour < 12 { hour += 12 }
        if piece.contains("am"), hour == 12 { hour = 0 }
        guard piece.contains("am") || piece.contains("pm") || hour <= 23 else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour; components.minute = minute; components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// "2d 6h 36m", "in 3 hours", "1 week 2 days". Every component must be a
    /// number followed by a unit this app recognises, and at least one must
    /// appear, so an unrecognised sentence never becomes a silent zero.
    private static func duration(_ hint: String) -> TimeInterval? {
        let units: [String: TimeInterval] = [
            "weeks": 604_800, "week": 604_800, "w": 604_800,
            "days": 86_400, "day": 86_400, "d": 86_400,
            "hours": 3_600, "hour": 3_600, "hrs": 3_600, "hr": 3_600, "h": 3_600,
            "minutes": 60, "minute": 60, "mins": 60, "min": 60, "m": 60,
            "seconds": 1, "second": 1, "secs": 1, "sec": 1, "s": 1
        ]
        // Words that carry no meaning of their own. Every other word has to be a
        // unit this app knows, which is what stops "in 2 days and a bit" from
        // quietly becoming exactly two days.
        let filler: Set<String> = ["resets", "reset", "resetting", "in", "and", "about", "approx",
                                   "approximately", "around", "~", "≈", "left", "remaining"]
        var total: TimeInterval = 0
        var matched = false
        var pending: Double?
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for raw in hint.components(separatedBy: separators) where !raw.isEmpty {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!:"))
            if token.isEmpty || filler.contains(token) { continue }
            var rest = Substring(token)
            while !rest.isEmpty {
                let digits = rest.prefix { $0.isNumber || $0 == "." }
                if digits.isEmpty {
                    // A bare unit belongs to the number in the token before it.
                    let word = rest.prefix { $0.isLetter }
                    guard !word.isEmpty, let amount = pending, let unit = units[String(word)] else { return nil }
                    total += amount * unit
                    pending = nil
                    matched = true
                    rest = rest.dropFirst(word.count)
                    continue
                }
                guard let amount = Double(digits), amount.isFinite, amount >= 0, amount < 100_000 else { return nil }
                rest = rest.dropFirst(digits.count)
                let word = rest.prefix { $0.isLetter }
                if word.isEmpty {
                    // "3 hours": the unit is the next token along.
                    guard pending == nil else { return nil }
                    pending = amount
                } else {
                    guard let unit = units[String(word)] else { return nil }
                    total += amount * unit
                    matched = true
                    rest = rest.dropFirst(word.count)
                }
            }
        }
        // A number with no unit is half a sentence, not a duration.
        guard matched, pending == nil else { return nil }
        return total
    }
}
