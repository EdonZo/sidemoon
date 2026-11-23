import Foundation
import Testing
@testable import SidemoonCore

private let newId = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
private let otherId = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

/// A stand-in for `claude` that answers `--bg` as scripted and lists the new session once it was started.
private final class StartRunner: ClaudeRunner, @unchecked Sendable {
    private let lock = NSLock()
    let output: String
    let status: Int32
    let timedOut: Bool
    let installed: Bool
    let folder: String
    private var started = false
    private(set) var calls: [(args: [String], cwd: String?)] = []

    init(output: String = "backgrounded · 1a2b3c4d · fresh\n  claude agents             list sessions\n", status: Int32 = 0,
         timedOut: Bool = false, installed: Bool = true, folder: String) {
        self.output = output
        self.status = status
        self.timedOut = timedOut
        self.installed = installed
        self.folder = folder
    }

    var isInstalled: Bool { installed }

    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        lock.withLock { calls.append((args, cwd)) }
        if args.first == "agents" {
            let other = #"{"id":"0b8e8a52","sessionId":"\#(otherId)","kind":"background","name":"theirs","cwd":"/tmp/x"}"#
            let mine = #"{"id":"1a2b3c4d","pid":2147483001,"sessionId":"\#(newId)","kind":"background","cwd":"\#(folder)","status":"busy","state":"working"}"#
            let list = lock.withLock { started } ? [other, mine] : [other]
            return ProcessResult(status: 0, stdout: Data("[\(list.joined(separator: ","))]".utf8), stderr: Data(), timedOut: false)
        }
        lock.withLock { started = status == 0 && !timedOut }
        return ProcessResult(status: timedOut ? -1 : status, stdout: Data(), stderr: Data(output.utf8), timedOut: timedOut)
    }

    var recorded: [(args: [String], cwd: String?)] { lock.withLock { calls } }
}

private func scratchFolder() -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-new-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func engine(_ runner: StartRunner, home: String = "/Users/nobody", refused: Bool = false,
                    arguments: [String] = []) -> Engine {
    let memory = HomeFolderMemory.inMemory()
    memory.set(refused: refused)
    return Engine(socketPath: "/tmp/smt-unused-\(UUID().uuidString.prefix(8)).sock", runner: runner,
                  registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }, home: home,
                                            homeFolderMemory: memory),
                  newSessionArguments: arguments)
}

@Suite struct NewSessionTests {
    @Test func startsInTheFolderWithTheMessageLastAndLearnsTheFullId() throws {
        let folder = scratchFolder()
        let runner = StartRunner(folder: folder)
        let e = engine(runner, arguments: ["--model", "haiku"])
        let r = e.startSession(NewSessionRequest(folder: folder, text: "  -do this first  ", styleNote: "[note]", name: "mine"))
        #expect(r.ok, "\(String(describing: r.failure))")
        #expect(r.sessionId == newId)
        let start = try #require(runner.recorded.first)
        // The message goes after `--`, so one that starts with a dash is not read as a flag.
        #expect(start.args == ["--bg", "--model", "haiku", "-n", "mine", "--", "-do this first\n\n[note]"])
        #expect(start.cwd == folder)
        // Known as a background session in its folder at once, so it can be sent to.
        let s = try #require(e.registry.session(newId))
        #expect(s.kind == .background && s.cwd == folder)
        // Nothing but starting it and reading the list: no other session is touched.
        #expect(runner.recorded.dropFirst().allSatisfy { $0.args == Constants.ClaudeCLI.agentsArgs })
        #expect(NewSessionResult(sessionId: newId, failure: nil, detail: nil).dictionary["sessionId"] as? String == newId)
    }

    @Test func checksComeBeforeAnythingRuns() {
        let folder = scratchFolder()
        let runner = StartRunner(folder: folder)
        let e = engine(runner, home: folder, refused: true)
        #expect(e.startSession(NewSessionRequest(folder: folder, text: "   ")).failure == .emptyMessage)
        #expect(e.startSession(NewSessionRequest(folder: folder + "/gone", text: "hi")).failure == .folderMissing(folder + "/gone"))
        #expect(e.startSession(NewSessionRequest(folder: "relative/path", text: "hi")).failure == .folderMissing("relative/path"))
        // The home folder, on a Mac whose Claude Code refuses to reopen sessions there.
        #expect(e.startSession(NewSessionRequest(folder: folder + "/", text: "hi")).failure == .homeFolderRefused)
        let missing = StartRunner(installed: false, folder: folder)
        #expect(engine(missing).startSession(NewSessionRequest(folder: folder, text: "hi")).failure == .claudeNotFound)
        #expect(runner.recorded.isEmpty && missing.recorded.isEmpty)
        // Where no refusal is remembered, the home folder is allowed.
        let fine = StartRunner(folder: folder)
        #expect(engine(fine, home: folder, refused: false).startSession(NewSessionRequest(folder: folder, text: "hi")).ok)
    }

    @Test func refusalsAreReadInClaudeCodesWords() {
        let folder = scratchFolder()
        func start(_ output: String, status: Int32 = 1, timedOut: Bool = false, e: Engine? = nil) -> NewSessionResult {
            let runner = StartRunner(output: output, status: status, timedOut: timedOut, folder: folder)
            return (e ?? engine(runner)).startSession(NewSessionRequest(folder: folder, text: "hi"))
        }
        #expect(start("Error: Workspace not trusted. Run claude here first.").failure == .refused(.untrustedFolder))
        #expect(start("Not signed in. Please run /login").failure == .refused(.loginNeeded))
        #expect(start("oops: something else").failure == .failed(status: 1))
        #expect(start("oops: something else").detail == "oops: something else")
        #expect(start("", status: -1, timedOut: true).failure == .timedOut)
        // It worked, by its exit status, but named no session.
        #expect(start("started", status: 0).failure == .notConfirmed)
        // A home-folder refusal is remembered, like one from a resume.
        let runner = StartRunner(output: "Workspace not trusted: the home directory is trusted one session at a time", status: 1,
                                 folder: folder)
        let e = engine(runner)
        #expect(e.startSession(NewSessionRequest(folder: folder, text: "hi")).failure == .refused(.homeFolder))
        #expect(e.registry.homeFolderMemory.refused)
    }

    @Test func theSocketTakesANewSessionRequest() throws {
        let folder = scratchFolder()
        let dir = "/tmp/smt-\(UUID().uuidString.prefix(8))"
        let runner = StartRunner(folder: folder)
        let e = Engine(socketPath: "\(dir)/e.sock", runner: runner,
                       registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }))
        try e.start()
        defer {
            e.stop()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let fd = try #require(try UnixSocket.connect(path: e.socketPath, timeout: Constants.Timeouts.socketSend))
        let conn = LineConnection(fd: fd)
        defer { conn.close() }
        _ = conn.writeJSON(["op": Constants.Ops.newSession, "folder": folder, "text": "hi"])
        let reply = try #require(conn.readJSON())
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["sessionId"] as? String == newId)
    }
}
