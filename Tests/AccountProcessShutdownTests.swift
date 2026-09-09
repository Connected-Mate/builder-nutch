import XCTest
import Darwin
@testable import Codenotch

final class AccountProcessShutdownTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-process-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.sh")
        let child = directory.appendingPathComponent("child.pid")
        let text = """
        #!/bin/sh
        trap '' TERM
        (trap '' TERM; while :; do /bin/sleep 30; done) &
        printf '%s' $! > \(AccountEnvironment.quote(child.path))
        while :; do /bin/sleep 30; done
        """
        try AccountStorage.write(Data(text.utf8), to: script, mode: 0o700)
        return (directory, script, child)
    }

    private func childPID(_ file: URL) async throws -> pid_t {
        for _ in 0..<300 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ManagedAccountError.timedOut
    }

    private func assertExited(_ pid: pid_t) async throws {
        for _ in 0..<200 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned descendant survived cleanup")
    }

    func testShutdownKillsOwnedTermIgnoringGroupAndRejectsNewSpawns() async throws {
        let (directory, script, childFile) = try fixture()
        let registry = AccountProcessRegistry(), runner = OfficialAccountProcess(registry: registry)
        defer { registry.shutdownAll() }
        // A separate fixture must never be signalled by the runner's shutdown.
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let command = AccountCommand(executable: script, arguments: [], environment: [:], directory: directory)
        let waiting = Task { try await runner.run(command, cancellation: AccountCancellation()) }
        let child = try await childPID(childFile)
        let start = ProcessInfo.processInfo.systemUptime
        registry.shutdownAll()
        registry.shutdownAll()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        XCTAssertTrue(unrelated.isRunning)
        do { _ = try await waiting.value; XCTFail("Shutdown must cancel the operation") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
        try await assertExited(child)
        let forbidden = directory.appendingPathComponent("must-not-run")
        let rejected = AccountCommand(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [forbidden.path], environment: [:], directory: directory)
        do { _ = try await runner.run(rejected, cancellation: AccountCancellation()); XCTFail("Spawn after shutdown must fail") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
    }

    func testCancellationImmediatelyDrainsOwnedDescendants() async throws {
        let (directory, script, childFile) = try fixture()
        let registry = AccountProcessRegistry(), runner = OfficialAccountProcess(registry: registry)
        defer { registry.shutdownAll() }
        let cancellation = AccountCancellation()
        let command = AccountCommand(executable: script, arguments: [], environment: [:], directory: directory)
        let waiting = Task { try await runner.run(command, cancellation: cancellation) }
        let child = try await childPID(childFile)
        let start = ProcessInfo.processInfo.systemUptime
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        do { _ = try await waiting.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
        try await assertExited(child)
    }

    /// A credential transaction that cannot finish must not hold the app open.
    /// `osascript … quit` reported "User canceled (-128)" because the reply owed
    /// to macOS waited on this lock with no deadline.
    private final class BlockingKeychain: ClaudeCredentialKeychain {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            entered.signal()
            release.wait()
            return nil
        }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            throw ClaudeSystemCredentialError.changedDuringCopy
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {}
    }

    func testWaitingForABlockedCredentialTransactionGivesUpInsteadOfHanging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stuck-credentials-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let location = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(location.directory)
        try AccountStorage.write(Data(#"{"oauthAccount":{"accountUuid":"A","organizationUuid":"org","emailAddress":"a@example.test"}}"#.utf8), to: location.configURL)
        let keychain = BlockingKeychain()
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "tester")
        Thread.detachNewThread { _ = try? credentials.subscriptionLogin(at: location) }
        XCTAssertEqual(keychain.entered.wait(timeout: .now() + 5), .success)

        let started = Date()
        XCTAssertFalse(credentials.waitUntilIdle(timeout: 0.4), "A held transaction must report that it is still running")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Quitting cannot wait on a transaction forever")
        keychain.release.signal()
        XCTAssertTrue(credentials.waitUntilIdle(timeout: 5))
    }

}
