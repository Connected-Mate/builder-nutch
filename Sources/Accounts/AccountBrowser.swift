import AppKit

/// Browser-owned authentication. Never reads cookies, passwords or session tokens.
@MainActor
enum AccountBrowser {
    static let supportedBundles = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]

    static func application(preferred: String? = nil) -> URL? {
        // Stick to the first browser used for this account: changing browsers can
        // change cookie encryption and must never silently replace its session.
        let identifiers = preferred.map { [$0] } ?? supportedBundles
        for identifier in identifiers where supportedBundles.contains(identifier) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        return nil
    }

    static func arguments(profile: URL, website: URL) throws -> [String] {
        guard profile.isFileURL, website.scheme == "https", website.host != nil,
              website.user == nil, website.password == nil else { throw ManagedAccountError.unsafePath }
        try AccountStorage.rejectSymlink(profile)
        return ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                "--new-window", website.absoluteString]
    }

    static func hasDirectoryPolicy(identifier: String, read: (String, String) -> Any? = { key, domain in
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }) -> Bool {
        read("UserDataDir", identifier) != nil
    }

    enum BrowserError: LocalizedError {
        case managedDirectory
        var errorDescription: String? {
            "Your browser is managed with a fixed account folder. Separate accounts cannot be opened safely with this browser."
        }
    }

    static func open(profile: URL, website: URL, preferred: String?) async throws -> String {
        guard let app = application(preferred: preferred), let identifier = Bundle(url: app)?.bundleIdentifier,
              supportedBundles.contains(identifier) else { throw ManagedAccountError.missingBrowser }
        // Managed UserDataDir policy takes precedence over command-line isolation.
        // Refuse rather than accidentally opening a shared company profile.
        guard !hasDirectoryPolicy(identifier: identifier) else { throw BrowserError.managedDirectory }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = try arguments(profile: profile, website: website)
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        return identifier
    }
}
