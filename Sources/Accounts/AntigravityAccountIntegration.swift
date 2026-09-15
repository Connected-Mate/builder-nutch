import Foundation

/// Reads the one account owned by Google's official Antigravity desktop app.
///
/// Antigravity is a development platform, not the Gemini chat website. Google
/// documents time-bound, model-specific Antigravity quotas and exposes their
/// current consumption in the app's Models selector. The local language server
/// is the same read-only route that selector uses; Builder Nutch never creates,
/// copies, refreshes or replaces the Google login.
enum AntigravityAccountIntegration {
    static let bundleIdentifier = "com.google.antigravity"
    static let closedMessage = "Open Antigravity to read its live model quotas and reset times."
    static let noReadingMessage = "Antigravity is open, but it returned no readable model quota. Check Models & Usage in Antigravity."
    static let signedOutMessage = "Sign in to the Antigravity app on this Mac, then refresh."
    static let missingMessage = "Install the official Antigravity app on this Mac, then open it and sign in."

    static func dataDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    /// One attachable vendor-owned row, or none. Add-assistant uses this exact
    /// candidate instead of creating an isolated browser profile; repeated
    /// calls therefore resolve to the same provider/path key.
    static func existingCandidate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  installed: Bool? = nil) -> ExistingAccountCandidate? {
        guard installed ?? isInstalled(home: home) else { return nil }
        let directory = dataDirectory(home: home).standardizedFileURL
        let source = ExistingAccountProfile(directory: directory.path, usesDefaultClaudeHome: false)
        guard (try? source.validatedDirectory()) != nil else { return nil }
        return ExistingAccountCandidate(provider: .antigravity,
                                        label: "Antigravity · on this Mac",
                                        source: source)
    }

    /// Refuses a caller-supplied directory even when it is otherwise a safe,
    /// user-owned folder. Antigravity has one canonical store; accepting any
    /// directory here would let a forged discovery candidate gain meaning.
    static func validatedDataDirectory(_ directory: URL,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let canonical = dataDirectory(home: home).standardizedFileURL
        guard directory.standardizedFileURL.path == canonical.path else {
            throw ManagedAccountError.unsafePath
        }
        return try ExistingAccountProfile(directory: canonical.path, usesDefaultClaudeHome: false)
            .validatedDirectory()
    }

    /// Checks only known application locations and the vendor bundle id. A
    /// same-named folder is not enough to claim the official app is installed.
    static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            applications: [URL]? = nil) -> Bool {
        let candidates = applications ?? [
            URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Antigravity 2.0.app", isDirectory: true),
            home.appendingPathComponent("Applications/Antigravity.app", isDirectory: true),
            home.appendingPathComponent("Applications/Antigravity 2.0.app", isDirectory: true)
        ]
        return candidates.contains { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier }
    }

    static func read(directory: URL, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        guard isInstalled() else { return ManagedAccountState(message: missingMessage) }
        _ = try validatedDataDirectory(directory)
        if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }

        let endpoint = AntigravityBridge.discover()
        if let endpoint {
            let session = URLSession(configuration: .ephemeral,
                                     delegate: LocalhostTrust(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let windows = try await AntigravityBridge.quota(from: endpoint, session: session)
                if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
                if !windows.isEmpty { return state(windows: windows) }
                return ManagedAccountState(isConnected: true, message: noReadingMessage)
            } catch ManagedAccountError.cancelled {
                throw ManagedAccountError.cancelled
            } catch {
                if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
                // The process can restart between discovery and the request.
                // A saved login below distinguishes that ordinary race from a
                // signed-out app without turning failure into a quota value.
            }
        }

        do {
            let credentials = try AntigravityCredentials.load()
            if credentials.isExpired {
                return ManagedAccountState(isConnected: true,
                    message: "Open Antigravity to renew its saved sign-in and read usage.")
            }
            return ManagedAccountState(isConnected: true, message: closedMessage)
        } catch UsageProviderError.accessDenied {
            // Background discovery disables Keychain interaction globally, so
            // this can never raise an unsolicited prompt. There is no managed
            // account "Allow access" action for this vendor; opening its owner
            // lets Antigravity renew the login and serve quota without copying it.
            return ManagedAccountState(isConnected: true,
                message: "Open Antigravity to read this saved login without a macOS access prompt.")
        } catch {
            return ManagedAccountState(message: signedOutMessage, requiresSignIn: true)
        }
    }

    /// Pure mapping used by both production and fixture tests. Every window is
    /// an exact fraction/reset returned by Antigravity; an empty response stays
    /// an admitted absence rather than becoming zero.
    static func state(windows: [LimitWindow], now: Date = Date()) -> ManagedAccountState {
        guard !windows.isEmpty else {
            return ManagedAccountState(isConnected: true, message: noReadingMessage)
        }
        return ManagedAccountState(isConnected: true, windows: windows, refreshedAt: now)
    }
}
