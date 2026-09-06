import Foundation
import Darwin
import CoreFoundation

struct AccountCommand {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var directory: URL
    var timeout: TimeInterval = 25
    var readsCodexAccount = false
}

final class AccountCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

protocol AccountCommandRunning {
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data
}

struct OfficialAccountProcess: AccountCommandRunning {
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try Self.execute(command, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
        var overflow = false
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count + data.count > 524_288 { overflow = true; return }
            bytes.append(data)
        }
        func drain() -> (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            let value = bytes; bytes.removeAll(keepingCapacity: true)
            return (value, overflow)
        }
    }

    private static func execute(_ command: AccountCommand, cancellation: AccountCancellation) throws -> Data {
        if cancellation.isCancelled { throw ManagedAccountError.cancelled }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        // A CLI can exit between two JSONL requests. EPIPE must be a thrown
        // write error, never a SIGPIPE that terminates the menu-bar app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let collector = Output()
        output.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
        // Drain diagnostics but never store vendor output: it can include browser URLs or tokens.
        errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let process: AccountChildProcess
        do { process = try AccountChildProcess(command, input: input, output: output, errors: errors) }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        defer {
            process.terminateOwnedGroup()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        if command.readsCodexAccount {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codenotch_accounts", "version": "1.0.0"]]])
        } else { try input.fileHandleForWriting.close() }

        let deadline = Date().addingTimeInterval(command.timeout)
        var pending = Data(), all = Data(), account: [String: Any]?
        var accountRequested = false, limitsRequested = false
        while true {
            if cancellation.isCancelled { throw ManagedAccountError.cancelled }
            if Date() >= deadline { throw ManagedAccountError.timedOut }
            let (bytes, overflow) = collector.drain()
            guard !overflow, all.count + bytes.count <= 524_288 else { throw ManagedAccountError.invalidResponse }
            if command.readsCodexAccount {
                pending.append(bytes)
                guard pending.count <= 524_288 else { throw ManagedAccountError.invalidResponse }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let id = message["id"] as? Int else { continue }
                    if id == 1 && !accountRequested {
                        guard message["error"] == nil else { throw ManagedAccountError.invalidResponse }
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                        accountRequested = true
                    } else if id == 2 && accountRequested && !limitsRequested {
                        guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw ManagedAccountError.invalidResponse }
                        account = result
                        if !(result["account"] is [String: Any]) {
                            return try JSONSerialization.data(withJSONObject: ["account": NSNull()])
                        }
                        try send(["id": 3, "method": "account/rateLimits/read", "params": [:]])
                        limitsRequested = true
                    } else if id == 3 && limitsRequested {
                        var result = account ?? [:]
                        if let limits = message["result"] as? [String: Any] { result["limits"] = limits }
                        else { result["quotaUnavailable"] = true }
                        return try JSONSerialization.data(withJSONObject: result)
                    }
                }
            } else { all.append(bytes) }
            if !process.isRunning {
                // Readability handlers deliver before EOF; collect the last scheduled bytes.
                Thread.sleep(forTimeInterval: 0.02)
                let (tail, excess) = collector.drain()
                guard !excess else { throw ManagedAccountError.invalidResponse }
                all.append(tail)
                // Claude auth status intentionally exits 1 when signed out.
                // Accept only that exact command and its explicit logged-out
                // JSON response; every other nonzero exit remains an error.
                let statusJSON = try? JSONSerialization.jsonObject(with: all) as? [String: Any]
                let loginValue = statusJSON?["loggedIn"] as? NSNumber
                let loggedOut = process.terminationStatus == 1
                    && command.arguments == ["auth", "status", "--json"]
                    && loginValue.map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } == true
                guard process.terminationStatus == 0 || loggedOut else { throw ManagedAccountError.commandFailed(process.terminationStatus) }
                if command.readsCodexAccount { throw ManagedAccountError.invalidResponse }
                return all
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// A dedicated POSIX process group makes cancellation cover the CLI's children
/// without signalling another Terminal session or the user's default CLI.
private final class AccountChildProcess {
    private var pid: pid_t = 0
    private var exited = false
    private var status: Int32 = 0

    init(_ command: AccountCommand, input: Pipe, output: Pipe, errors: Pipe) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw ManagedAccountError.invalidResponse
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                       output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
            posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor)
        }
        let changed = command.directory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard changed == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ([command.executable.path] + command.arguments).map { strdup($0) }
        let environment = command.environment.keys.sorted().map { strdup("\($0)=\(command.environment[$0]!)") }
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var argv = arguments + [nil], envp = environment + [nil]
        let result = command.executable.path.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argv in
                envp.withUnsafeMutableBufferPointer { envp in
                    posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
                }
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    var isRunning: Bool {
        if !exited {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { exited = true }
        }
        return !exited
    }

    var terminationStatus: Int32 { (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f) }

    func terminateOwnedGroup() {
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(0.2)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        // A child may outlive its parent; the group ID still identifies only our spawn.
        kill(-pid, SIGKILL)
        if !exited { _ = waitpid(pid, &status, 0); exited = true }
    }
}
