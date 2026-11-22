import AppKit
import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

/// Everything the end-to-end scenarios share: the settings `scripts/e2e.sh` passes in, throwaway sessions,
/// waiting with a timeout, and a pseudo-terminal for interactive `claude`.
///
/// The scenarios only run when `scripts/e2e.sh` (or someone by hand) sets the variables below, and only
/// with the support directory overridden, so the engine they start has its own socket and never talks to
/// the engine inside the running Sidemoon app.
enum E2E {
    static let env = ProcessInfo.processInfo.environment

    enum Variable {
        /// The scratch folder of this run; everything a scenario creates goes under it.
        static let run = "SIDEMOON_E2E_RUN"
        /// The freshly built `sidemoon` helper the scratch projects' hooks and the channel run.
        static let helper = "SIDEMOON_E2E_HELPER"
        /// A file every throwaway session is written to as soon as it exists, so the runner can stop it.
        static let ledger = "SIDEMOON_E2E_LEDGER"
        /// The short id of the background session the runner started in the home folder.
        static let homeSession = "SIDEMOON_E2E_HOME_SESSION"
    }

    static var enabled: Bool { env[Variable.run] != nil }
    static var run: String { env[Variable.run] ?? "" }
    static var helper: String { env[Variable.helper] ?? "" }
    static var homeSession: String? { env[Variable.homeSession].flatMap { $0.isEmpty ? nil : $0 } }

    /// The smallest model, and one-line prompts, keep a full run cheap.
    static let model = "haiku"
    /// Every throwaway session's name starts with this, so it is easy to tell apart from real ones.
    static let namePrefix = "sidemoon-e2e"
    /// Only the scratch project's settings: the user's own hooks (which report to the installed app and to
    /// anything else hooked up) stay out of the sessions this suite starts. Claude Code keeps it on resume.
    static let settingSources = ["--setting-sources", "project"]
    /// What a scratch project lets a session run without asking: the busy scenario's long turn. (Claude Code
    /// blocks a long foreground `sleep`, so the long turn pings the loopback address instead.)
    static let allowedTools = ["Bash(ping:*)", "Bash(ping *)"]
    static let longTurnSeconds = 40
    static var longTurnCommand: String { "ping -c \(longTurnSeconds) -i 1 127.0.0.1" }

    enum Timeout {
        static let cli: TimeInterval = 120
        static let firstAnswer: TimeInterval = 120
        static let hook: TimeInterval = 60
        /// `claude agents` is read every `Constants.Timeouts.agentsRefreshInterval`.
        static let listing: TimeInterval = 40
        static let stop: TimeInterval = 30
        static let terminalStart: TimeInterval = 60
        static let poll: TimeInterval = 0.25
    }

    enum Ledger {
        static let background = "bg"
        static let process = "pid"
        static let headless = "headless"
    }

    enum Words {
        static let ready = "READY"
        static let readyPrompt = "Reply with only the word READY."
        static func reply(_ word: String) -> String { "Reply with only the word \(word)." }
    }

    enum Terminal {
        /// What Claude Code asks once per launch with the development-channels flag; Enter takes the first choice.
        static let developmentChannelsChoice = "I am using this for local development"
        /// The folder trust dialog, in case the scratch folder is not trusted yet; Enter takes "yes".
        static let trustPrompts = ["Yes, I trust this folder", "Do you trust the files in this folder"]
        static let enter = "\r"
        static let columns: UInt16 = 160
        static let rows: UInt16 = 50
        static let termVariable = "TERM"
        static let termValue = "xterm-256color"
        static let exitGrace: TimeInterval = 10
    }
}

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func e2eLog(_ message: String) {
    print("e2e: \(message)")
    fflush(stdout)
}

/// Waits for a condition, failing with what was observed when it does not come true in time.
@MainActor
func waitFor(_ what: String, timeout: TimeInterval, observed: () -> String,
             _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw E2EFailure("timed out after \(Int(timeout))s waiting for \(what); observed: \(observed())")
        }
        try? await Task.sleep(for: .seconds(E2E.Timeout.poll))
    }
}

/// The same, for conditions that need a blocking call (the `claude` CLI) to check.
func waitForBlocking(_ what: String, timeout: TimeInterval, observed: @escaping @Sendable () -> String,
                     _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await Task.detached { condition() }.value) {
        guard Date() < deadline else {
            let seen = await Task.detached { observed() }.value
            throw E2EFailure("timed out after \(Int(timeout))s waiting for \(what); observed: \(seen)")
        }
        try? await Task.sleep(for: .seconds(Constants.Timeouts.pollInterval))
    }
}

// MARK: - The claude CLI

enum ClaudeCLI {
    static let runner = SystemClaudeRunner()

    @discardableResult
    static func run(_ args: [String], cwd: String?, timeout: TimeInterval = E2E.Timeout.cli) async -> ProcessResult {
        await Task.detached { runner.run(args, cwd: cwd, stdin: Data(), timeout: timeout) }.value
    }

    /// Read-only: every session Claude Code lists, the owner's included.
    static func agents() -> [AgentInfo] {
        let r = runner.run(Constants.ClaudeCLI.agentsArgs, cwd: nil, stdin: nil, timeout: E2E.Timeout.cli)
        return AgentInfo.parseList(r.stdout) ?? []
    }

    static func agent(short: String) -> AgentInfo? { agents().first { $0.agentId == short } }

    static func describe(_ a: AgentInfo?) -> String {
        guard let a else { return "not listed by claude agents" }
        return "id=\(a.agentId) pid=\(a.pid.map(String.init) ?? "none") status=\(a.status ?? "-") state=\(a.state ?? "-")"
    }

    static func appendToLedger(_ kind: String, _ value: String) {
        guard let path = E2E.env[E2E.Variable.ledger] else { return }
        let line = Data("\(kind) \(value)\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}

/// The scenarios may only ever send to sessions they created: anything else is refused here, before the engine.
final class GuardedEngine: CompanionEngine, @unchecked Sendable {
    let inner: InProcessEngine
    private let lock = NSLock()
    private var allowed: Set<String> = []
    private var count = 0

    init(_ inner: InProcessEngine) { self.inner = inner }

    func allow(_ sessionId: String) { lock.withLock { _ = allowed.insert(sessionId.lowercased()) } }
    var sendCount: Int { lock.withLock { count } }

    func start() throws -> EngineStartOutcome { try inner.start() }
    func stop() {}
    func sessions() -> [Session] { inner.sessions() }
    func subscribe(_ handler: @escaping @Sendable (Session) -> Void) { inner.subscribe(handler) }
    func send(_ request: SendRequest) -> SendResult {
        let ok = lock.withLock { () -> Bool in
            count += 1
            return allowed.contains(request.session.lowercased())
        }
        guard ok else {
            return SendResult(ok: false, sessionId: request.session, route: nil, reply: nil,
                              error: "e2e guard: refusing to send to a session this run did not create", detail: nil)
        }
        return inner.send(request)
    }
}

/// One engine per test process, on the overridden socket. It is never stopped: the process ends instead.
enum SharedEngine {
    static let engine = InProcessEngine()
}

// MARK: - One scenario's world

@MainActor
final class Fixture {
    let name: String
    let project: String
    let guarded: GuardedEngine
    let model: CompanionModel
    let store: CaptureStore
    private(set) var backgroundSessions: [String] = []
    private(set) var terminals: [PseudoTerminal] = []

    /// A scratch project with hooks that reach the test engine, and a fresh model on that engine.
    init(_ name: String, image: URL? = nil) throws {
        guard let support = Constants.Paths.supportDirectoryOverride else {
            throw E2EFailure("\(Constants.Paths.supportDirectoryOverrideVariable) is not set: refusing to run against the real engine socket")
        }
        guard FileManager.default.isExecutableFile(atPath: E2E.helper) else {
            throw E2EFailure("\(E2E.Variable.helper) does not name an executable sidemoon helper: \(E2E.helper)")
        }
        self.name = name
        project = "\(E2E.run)/projects/\(name)"
        try Fixture.writeProject(at: project, support: support)
        guarded = GuardedEngine(SharedEngine.engine)
        let defaults = UserDefaults(suiteName: "\(E2E.namePrefix)-\(name)-\(UUID().uuidString)")!
        store = CaptureStore(directory: URL(fileURLWithPath: "\(E2E.run)/captures/\(name)", isDirectory: true))
        model = CompanionModel(engine: guarded, capture: InjectedImageCapture(source: image ?? URL(fileURLWithPath: "/dev/null")),
                               store: store, defaults: defaults)
        model.startEngine()
        guard model.engineState == .running else {
            throw E2EFailure("the test engine did not start (\(model.engineState)); socket \(Constants.Paths.socketPath)")
        }
        e2eLog("[\(name)] engine on \(SharedEngine.engine.engine.socketPath), project \(project)")
    }

    /// `.claude/settings.json` with Sidemoon's hooks pointing at the test helper and the test socket.
    static func writeProject(at project: String, support: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(project)/.claude", withIntermediateDirectories: true)
        let command = "\(Constants.Paths.supportDirectoryOverrideVariable)=\(HooksInstaller.shellQuote(support)) "
            + "\(HooksInstaller.shellQuote(E2E.helper)) \(Constants.Hooks.subcommand)"
        var hooks: [String: Any] = [:]
        for event in Constants.Hooks.events {
            hooks[event] = [["hooks": [["type": Constants.Hooks.hookType, "command": command,
                                        "timeout": Constants.Hooks.timeoutSeconds]]]]
        }
        let settings: [String: Any] = ["hooks": hooks, "permissions": ["allow": E2E.allowedTools]]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: "\(project)/.claude/settings.json"))
    }

    func session(_ id: String) -> Session? { model.sessions.first { $0.id == id } }

    func describe(_ id: String) -> String {
        guard let s = session(id) else { return "session \(SessionID.short(id)) not in the model yet" }
        let row = model.rows.first { $0.id == id } ?? SessionList.rows(model.sessions, showEnded: true).first { $0.id == id }
        return "state=\(s.state.rawValue) kind=\(s.kind.rawValue) routes=\(s.routes.map(\.rawValue)) blocker=\(s.blocker?.rawValue ?? "-") "
            + "channel=\(s.channelConnected) lastEvent=\(s.lastEventName ?? "-") reachability=\(row.map { "\($0.reachability)" } ?? "-") "
            + "reply=\(s.lastReply.map { String($0.prefix(60)) } ?? "-")"
    }

    // MARK: Background sessions

    /// `claude --bg` in the scratch project. Returns the full session id; the short id goes to the ledger at once.
    func startBackground(_ label: String, prompt: String, cwd: String? = nil) async throws -> (sessionId: String, short: String) {
        let folder = cwd ?? project
        let args = ["--bg"] + E2E.settingSources + ["--model", E2E.model, "-n", "\(E2E.namePrefix)-\(label)", prompt]
        let r = await ClaudeCLI.run(args, cwd: folder)
        let output = r.stdoutText + r.stderrText
        guard r.status == 0, let short = Engine.backgroundedId(in: output) else {
            throw E2EFailure("claude --bg exited \(r.status): \(output.prefix(400))")
        }
        ClaudeCLI.appendToLedger(E2E.Ledger.background, short)
        backgroundSessions.append(short)
        var found: AgentInfo?
        try await waitForBlocking("claude agents to list \(short)", timeout: E2E.Timeout.listing,
                                  observed: { "not listed" }) { ClaudeCLI.agent(short: short) != nil }
        found = await Task.detached { ClaudeCLI.agent(short: short) }.value
        guard let a = found else { throw E2EFailure("\(short) vanished from claude agents") }
        guarded.allow(a.sessionId)
        e2eLog("[\(name)] started background session \(short) (\(a.sessionId)) in \(folder)")
        return (a.sessionId, short)
    }

    /// Waits until the session's first turn is over and the test engine knows it.
    func waitUntilIdle(_ sessionId: String, short: String, reply word: String? = nil) async throws {
        try await waitForBlocking("\(short) to finish its turn", timeout: E2E.Timeout.firstAnswer,
                                  observed: { ClaudeCLI.describe(ClaudeCLI.agent(short: short)) }) {
            guard let a = ClaudeCLI.agent(short: short) else { return false }
            return a.status != Constants.ClaudeCLI.busyStatus && TranscriptReader.sessionHasAnswered(sessionId, hint: a.transcriptPath) == true
        }
        try await waitFor("the test engine to see \(short) idle", timeout: E2E.Timeout.listing, observed: { describe(sessionId) }) {
            guard let s = session(sessionId), s.kind == .background, s.state == .idle else { return false }
            return word.map { w in s.lastReply?.uppercased().contains(w) == true } ?? true
        }
    }

    func stopBackground(_ short: String) async {
        let stop = await ClaudeCLI.run([Constants.ClaudeCLI.stopCommand, short], cwd: nil)
        let rm = await ClaudeCLI.run(["rm", short], cwd: nil)
        e2eLog("[\(name)] cleanup \(short): stop exited \(stop.status), rm exited \(rm.status)")
    }

    // MARK: Sending

    /// The target must be the session this scenario means, or nothing is sent.
    func select(_ sessionId: String) throws {
        guarded.allow(sessionId)
        model.selectTarget(sessionId)
        guard model.targetId == sessionId else { throw E2EFailure("could not make \(sessionId) the target (target is \(model.targetId ?? "none"))") }
    }

    func send(_ text: String, to sessionId: String) async throws {
        guard model.targetId == sessionId else { throw E2EFailure("target moved to \(model.targetId ?? "none") before sending") }
        await model.sendMessage(text)
    }

    func lastEntry(role: ThreadEntry.Role, of sessionId: String) -> ThreadEntry? {
        model.threads.thread(for: sessionId).last { $0.role == role }
    }

    func describeThread(_ sessionId: String) -> String {
        model.threads.thread(for: sessionId).map { "\($0.role.rawValue):\($0.delivery):\($0.text.prefix(40))" }.joined(separator: " | ")
    }

    // MARK: Terminal sessions

    /// An interactive `claude` under a pseudo-terminal in the scratch project, answering the launch questions.
    /// With a `prompt`, the session starts on it, as `claude "<prompt>"` does.
    func startTerminal(_ label: String, sessionId: String, extraArgs: [String], prompt: String? = nil) throws -> PseudoTerminal {
        let args = E2E.settingSources + extraArgs + ["--model", E2E.model, "-n", "\(E2E.namePrefix)-\(label)", "--session-id", sessionId]
            + (prompt.map { [$0] } ?? [])
        let pty = try PseudoTerminal(executable: SystemClaudeRunner.locateClaude(), arguments: args, cwd: project)
        ClaudeCLI.appendToLedger(E2E.Ledger.process, "\(pty.pid) \(E2E.namePrefix)-\(label)")
        terminals.append(pty)
        guarded.allow(sessionId)
        e2eLog("[\(name)] started terminal session \(sessionId) (pid \(pty.pid))")
        return pty
    }

    func cleanup() async {
        for short in backgroundSessions { await stopBackground(short) }
        backgroundSessions = []
        for pty in terminals { await pty.end() }
        terminals = []
    }
}

// MARK: - Pseudo-terminal

/// Runs a program on a pseudo-terminal, so Claude Code starts its interactive interface, and keeps what it
/// prints. Answers known launch questions with Enter.
final class PseudoTerminal: @unchecked Sendable {
    private let process = Process()
    private let master: Int32
    private let lock = NSLock()
    private var output = Data()
    private var answered: Set<String> = []
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], cwd: String) throws {
        var m: Int32 = -1, s: Int32 = -1
        var size = winsize(ws_row: E2E.Terminal.rows, ws_col: E2E.Terminal.columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else { throw E2EFailure("openpty failed: \(String(cString: strerror(errno)))") }
        master = m
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: true)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = LoginEnvironment.shared
        env[E2E.Terminal.termVariable] = E2E.Terminal.termValue
        process.environment = env
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        try process.run()
        try? slave.close()
        Thread.detachNewThread { [self] in readLoop() }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(master, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            lock.withLock { output.append(contentsOf: buf[0..<n]) }
            answerKnownQuestions()
        }
    }

    /// The screen as plain text: escape sequences become spaces, so phrases can be looked for.
    var text: String {
        let raw = String(decoding: lock.withLock { output }, as: UTF8.self)
        return PseudoTerminal.plain(raw)
    }

    static func plain(_ raw: String) -> String {
        let patterns = ["\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", "\u{1B}\\[[0-9;?<>=]*[ -/]*[@-~]", "\u{1B}[()][A-Za-z0-9]", "\u{1B}[=>78]"]
        var s = raw
        for p in patterns { s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        return s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    func type(_ s: String) {
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
    }

    private func answerKnownQuestions() {
        let screen = text
        for question in [E2E.Terminal.developmentChannelsChoice] + E2E.Terminal.trustPrompts where screen.contains(question) {
            let first = lock.withLock { answered.insert(question).inserted }
            guard first else { continue }
            e2eLog("terminal \(pid) asked \"\(question)\": pressing Enter")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in type(E2E.Terminal.enter) }
        }
    }

    func asked(_ question: String) -> Bool { lock.withLock { answered.contains(question) } }

    /// The last bit of the screen, for failure messages.
    var tail: String { String(text.suffix(600)) }

    /// Ends the session: SIGTERM, then SIGKILL if it does not go.
    func end() async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(E2E.Terminal.exitGrace)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .seconds(E2E.Timeout.poll)) }
        if process.isRunning { kill(pid, SIGKILL) }
        close(master)
        e2eLog("terminal \(pid) ended")
    }
}

// MARK: - Images

enum TestImage {
    static let size = NSSize(width: 640, height: 220)
    static let fontSize: CGFloat = 120
    static let origin = NSPoint(x: 40, y: 50)

    /// A PNG showing one word in large black letters on white.
    static func write(word: String, to url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw E2EFailure("could not make a bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (word as NSString).draw(at: origin, withAttributes: [.font: NSFont.boldSystemFont(ofSize: fontSize),
                                                             .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw E2EFailure("could not encode the PNG") }
        try png.write(to: url)
    }
}
