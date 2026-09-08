import Foundation
import Security

/// Legacy login-Keychain prompts are controlled per process, not per query.
/// All native Keychain calls share this gate. Only a user's Allow access action
/// may enable a prompt, for one synchronous read, never across an await.
final class KeychainInteraction {
    static let shared = KeychainInteraction()
    private let lock = NSRecursiveLock()
    private let setInteraction: (Bool) -> OSStatus

    init(setInteraction: @escaping (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }) {
        self.setInteraction = setInteraction
    }

    func perform<T>(allowPrompt: Bool = false, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let status = setInteraction(allowPrompt)
        guard status == errSecSuccess else { throw ClaudeSystemCredentialError.keychain(status) }
        defer { if allowPrompt { _ = setInteraction(false) } }
        return try operation()
    }
}
