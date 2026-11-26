import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// A run that may be stopped from another thread: the runner tells it how to end its process, and `cancel()` does
/// so, at once or as soon as the process exists.
public final class RunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var ender: (() -> Void)?
    private var wasCancelled = false

    public init() {}

    public var cancelled: Bool { lock.withLock { wasCancelled } }

    public func cancel() {
        let end: (() -> Void)? = lock.withLock {
            wasCancelled = true
            return ender
        }
        end?()
    }

    /// Called by the runner once the process runs.
    public func attach(_ end: @escaping () -> Void) {
        let now: Bool = lock.withLock {
            ender = end
            return wasCancelled
        }
        if now { end() }
    }
}

/// Runs the `claude` CLI. A protocol so delivery logic can be tested without real sessions.
public protocol ClaudeRunner: Sendable {
    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult
    /// The same, stoppable through `handle`.
    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval, handle: RunHandle) -> ProcessResult
    /// Whether the `claude` command is there to run.
    var isInstalled: Bool { get }
}

extension ClaudeRunner {
    public var isInstalled: Bool { true }
    /// Runners that cannot stop a run (test stand-ins) run it to the end.
    public func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval, handle: RunHandle) -> ProcessResult {
        run(args, cwd: cwd, stdin: stdin, timeout: timeout)
    }
}

public struct SystemClaudeRunner: ClaudeRunner {
    public let executable: String

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    public init(executable: String? = nil) {
        self.executable = executable ?? SystemClaudeRunner.locateClaude()
    }

    public static func locateClaude() -> String {
        let fm = FileManager.default
        if let hit = Constants.Paths.claudeExecutableCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        func search(_ path: String) -> String? {
            path.split(separator: ":").map { "\($0)/\(Constants.Paths.claudeExecutableName)" }
                .first { fm.isExecutableFile(atPath: $0) }
        }
        if let hit = search(ProcessInfo.processInfo.environment[Constants.LoginShell.pathVariable] ?? "") { return hit }
        // An app started from Finder has a bare PATH; installs through npm or nvm are only on the login shell's.
        if let hit = search(LoginEnvironment.shared[Constants.LoginShell.pathVariable] ?? "") { return hit }
        return Constants.Paths.claudeExecutableName
    }

    /// Output goes to private temp files rather than pipes: `claude --bg` leaves a daemon behind that
    /// would otherwise hold a pipe open. Completion is the child's exit, not end-of-output.
    public func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        run(args, cwd: cwd, stdin: stdin, timeout: timeout, handle: RunHandle())
    }

    public func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval, handle: RunHandle) -> ProcessResult {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sidemoon-run-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        let inURL = base.appendingPathExtension("in")
        defer { [outURL, errURL, inURL].forEach { try? fm.removeItem(at: $0) } }
        let privateFile: [FileAttributeKey: Any] = [.posixPermissions: Constants.Permissions.imageFile]
        guard fm.createFile(atPath: outURL.path, contents: nil, attributes: privateFile),
              fm.createFile(atPath: errURL.path, contents: nil, attributes: privateFile),
              let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL)
        else { return ProcessResult(status: -1, stdout: Data(), stderr: Data("cannot create temp files".utf8), timedOut: false) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = LoginEnvironment.shared
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            fm.createFile(atPath: inURL.path, contents: stdin, attributes: privateFile)
            p.standardInput = FileHandle(forReadingAtPath: inURL.path)
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: Data("\(error)".utf8), timedOut: false)
        }
        // SIGINT first, as Control-C in a terminal: Claude Code then ends the turn and saves what it has.
        handle.attach { [p] in
            guard p.isRunning else { return }
            p.interrupt()
            // Still there a moment later: ended for good.
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Timeouts.interruptGrace) { if p.isRunning { p.terminate() } }
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        try? out.close()
        try? err.close()
        return ProcessResult(status: timedOut ? -1 : p.terminationStatus,
                             stdout: fm.contents(atPath: outURL.path) ?? Data(),
                             stderr: fm.contents(atPath: errURL.path) ?? Data(),
                             timedOut: timedOut)
    }
}
