import Foundation
import SQLite3

/// The session Cursor's editor keeps for itself, in the SQLite global-state
/// store it inherits from VS Code.
///
/// Codenotch only ever reads it, the same bargain as Claude Code's keychain
/// token: the editor mints and refreshes it, we borrow the current value. The
/// database is opened read-only and `immutable`, so a running editor is never
/// blocked or corrupted by us looking.
struct CursorCredentials {
    let accountID: String
    let accessToken: String
    /// The web API wants the pair as one cookie.
    var sessionCookie: String { "WorkosCursorSessionToken=\(accountID)::\(accessToken)" }

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Minted by ToDesktop, who build Cursor — stable across updates, but not
    /// across Cursor leaving ToDesktop or rebranding. Kept here beside the store
    /// path so the two facts about a Cursor installation change together: the
    /// activity monitor and the sign-in route both read this one.
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    /// Identity, read from the same store as the session. Non-secret: the email
    /// and plan the editor caches for its own UI.
    static func account(from url: URL = storeURL) -> ProviderAccount? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        func value(_ key: String) -> String? {
            SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
        }
        guard let email = value("cursorAuth/cachedEmail"), !email.isEmpty else { return nil }
        return ProviderAccount(
            label: email,
            plan: value("cursorAuth/stripeMembershipType"),
            source: "Cursor",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }

    static func load(from url: URL = storeURL) throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageProviderError.needsAuth
        }

        // Read-only, but *not* `immutable`. Cursor runs the database in WAL
        // mode, and `immutable=1` tells SQLite to ignore the write-ahead log —
        // so it happily returns whatever was true at the last checkpoint. That
        // is how you end up serving a token the editor has already rotated.
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }

        guard let token = value(forKey: "cursorAuth/accessToken", in: db), !token.isEmpty
        else { throw UsageProviderError.needsAuth }

        // `stripeMembershipAuthId` is the id half where the editor still writes
        // it. Current community readers no longer look for that row at all and
        // take the id from the token's own `sub` claim instead — verified
        // 10 September 2026 against CursorAppAuth.swift (commit 30 August 2026):
        // https://raw.githubusercontent.com/steipete/CodexBar/main/Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift
        // Preferring the stored row keeps the reading the editor itself uses;
        // the claim covers an install that has stopped writing it.
        let account = value(forKey: "cursorAuth/stripeMembershipAuthId", in: db).flatMap { $0.isEmpty ? nil : $0 }
            ?? accountID(fromAccessToken: token)
        guard let account, !account.isEmpty else { throw UsageProviderError.needsAuth }

        return CursorCredentials(accountID: account, accessToken: token)
    }

    /// The `sub` claim of the editor's own access token, minus the identity
    /// provider prefix Auth0 puts in front of it (`auth0|user_ABC` → `user_ABC`).
    /// Nothing is verified: the token is this Mac's own and only the account
    /// claim is read from it. Never stored, never logged.
    static func accountID(fromAccessToken token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var text = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard text.count <= 8192 else { return nil }
        if text.count % 4 != 0 { text += String(repeating: "=", count: 4 - text.count % 4) }
        guard let data = Data(base64Encoded: text), data.count <= 65_536,
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty, subject.count <= 200,
              let last = subject.split(separator: "|").last, !last.isEmpty else { return nil }
        return String(last)
    }

    private static func value(forKey key: String, in db: OpaquePointer?) -> String? {
        SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
    }
}

