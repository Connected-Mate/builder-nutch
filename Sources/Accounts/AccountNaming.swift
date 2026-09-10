import Foundation

/// Names an account after the person, from the one thing every login carries:
/// the address. The part before the first dot is usually a first name or a
/// role — `alex.something@` is Alex, `staff.1.team@` is Staff — and it is a
/// far better row title than "Claude 4". Only rows still wearing the name the
/// app gave them are renamed; a name the person typed is theirs.
enum AccountNaming {
    /// The name the app gives a new row: the provider, then the provider and a
    /// number. Anything else was chosen by the person.
    static func isDefault(_ label: String, provider: AccountProvider) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(provider.title) else { return false }
        let rest = trimmed.dropFirst(provider.title.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || (rest.allSatisfy(\.isNumber) && rest.count <= 4)
    }

    /// The pieces of the address before the @, split on dots, with any `+tag`
    /// dropped: `staff.1.iaetinno.tgv@…` gives `["staff", "1", "iaetinno", "tgv"]`.
    static func segments(of email: String) -> [String] {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return [] }
        var local = String(email[..<at])
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        return local.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 40 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }

    /// A name from the address that is not already in use. Starts with the
    /// first segment and adds the next only when the shorter name is taken —
    /// `Staff` for one staff address, `Staff 1` and `Staff 2` for two.
    static func suggested(email: String, taken: Set<String>) -> String? {
        let parts = segments(of: email)
        guard !parts.isEmpty else { return nil }
        let used = Set(taken.map { $0.lowercased() })
        for count in 1...parts.count {
            let name = parts.prefix(count).map(capitalised).joined(separator: " ")
            if !used.contains(name.lowercased()) { return name }
        }
        return nil
    }

    private static func capitalised(_ part: String) -> String {
        guard let first = part.first else { return part }
        return first.uppercased() + part.dropFirst()
    }
}
