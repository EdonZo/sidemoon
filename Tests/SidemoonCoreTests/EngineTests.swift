import Foundation
import Testing
@testable import SidemoonCore

private let sid = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"
private let other = "7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"

private func hook(_ name: String, _ id: String = sid, pid: Int32? = 4242, extra: [String: Any] = [:]) -> HookEvent {
    var o: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": "/tmp/proj"]
    o.merge(extra) { $1 }
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: o), claudePid: pid)!
}

/// Scripted stand-in for the `claude` CLI that records every call.
final class FakeRunner: ClaudeRunner, @unchecked Sendable {
    private let lock = NSLock()
    var agentsJSON: String
    var resumeOutput: String
    /// The exit status of `claude --resume`; Claude Code exits 1 when it refuses.
    var resumeStatus: Int32
    private(set) var calls: [[String]] = []

    init(agentsJSON: String, resumeOutput: String = "", resumeStatus: Int32 = 0) {
        self.agentsJSON = agentsJSON
        self.resumeOutput = resumeOutput
        self.resumeStatus = resumeStatus
    }

    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        lock.withLock { calls.append(args) }
        let out: String
        switch args.first {
        case "agents": out = lock.withLock { agentsJSON }
        case Constants.ClaudeCLI.stopCommand:
            lock.withLock { agentsJSON = agentsJSON.replacingOccurrences(of: "\"pid\":2147483000,", with: "") }
            out = ""
        case Constants.ClaudeCLI.resumeFlag: out = resumeOutput
        default: out = ""
        }
        let status = args.first == Constants.ClaudeCLI.resumeFlag ? resumeStatus : 0
        return ProcessResult(status: status, stdout: Data(out.utf8), stderr: Data(), timedOut: false)
    }
    var recorded: [[String]] { lock.withLock { calls } }
}

func agents(status: String, state: String, running: Bool = true, cwd: String = "/tmp/proj") -> String {
    #"[{"id":"0b8e8a52",\#(running ? #""pid":2147483000,"# : "")"sessionId":"\#(sid)","kind":"background","name":"t","cwd":"\#(cwd)","status":"\#(status)","state":"\#(state)"}]"#
}

@Suite struct HookEventTests {
    @Test func rejectsBadIdsAndUntrustedPaths() {
        #expect(HookEvent(json: Data(#"{"session_id":"../../etc","hook_event_name":"Stop"}"#.utf8), claudePid: nil) == nil)
        #expect(HookEvent(json: Data("not json".utf8), claudePid: nil) == nil)
        let e = HookEvent(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"Stop","transcript_path":"/etc/passwd","scratchpad_dir":"/Users/x/project","cwd":"relative"}"#.utf8), claudePid: 1)!
        #expect(e.transcriptPath == nil)
        #expect(e.scratchpadDir == nil)
        #expect(e.cwd == nil)
        #expect(e.claudePid == nil)
        let ok = HookEvent(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"Stop","scratchpad_dir":"/private/tmp/claude-\#(getuid())/p/\#(sid)/scratchpad"}"#.utf8), claudePid: 77)!
        #expect(ok.scratchpadDir != nil)
        #expect(ok.claudePid == 77)
    }
}

@Suite struct RegistryTests {
    @Test func stateFollowsHooks() {
        let r = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true })
        r.apply(hook("SessionStart"))
        #expect(r.session(sid)?.state == .idle)
        r.apply(hook("UserPromptSubmit"))
        #expect(r.session(sid)?.state == .working)
        r.apply(hook("Notification", extra: ["notification_type": "permission_prompt"]))
        #expect(r.session(sid)?.state == .needsInput)
        r.apply(hook("Stop", extra: ["last_assistant_message": "done"]))
        #expect(r.session(sid)?.state == .idle)
        #expect(r.session(sid)?.lastReply == "done")
        r.apply(hook("SessionEnd"))
        #expect(r.session(sid)?.state == .ended)
        #expect(r.session(sid)?.routes == [.headless])
        #expect(r.sessionId(forPid: 4242) == nil)
    }

    @Test func pidBindingFollowsClearInSameProcess() {
        let r = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true })
        r.apply(hook("SessionStart", sid, pid: 10))
        r.apply(hook("SessionStart", other, pid: 11))
        #expect(r.sessionId(forPid: 10) == sid)
        #expect(r.sessionId(forPid: 11) == other)
        r.apply(hook("SessionStart", other.replacingOccurrences(of: "7c1d", with: "8c1d"), pid: 10, extra: ["source": "clear"]))
        #expect(r.sessionId(forPid: 10)?.hasPrefix("8c1d") == true)
    }

    @Test func stopWaiterSeesLaterStopOnlyAndEmitsChanges() {
        let r = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true })
        let seen = LockedCount()
        r.subscribe { _ in seen.add() }
        let token = r.expectStop(sessionId: sid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            r.apply(hook("Stop", other))
            r.apply(hook("Stop", sid, extra: ["last_assistant_message": "hello"]))
        }
        let e = r.wait(token, timeout: 5)
        #expect(e?.sessionId == sid)
        #expect(e?.lastAssistantMessage == "hello")
        #expect(seen.value == 2)
    }

    @Test func agentsSeedBackgroundSessions() throws {
        let r = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true })
        r.applyAgents(try #require(AgentInfo.parseList(Data(agents(status: "busy", state: "working").utf8))))
        #expect(r.session(sid)?.kind == .background)
        #expect(r.session(sid)?.state == .working)
        #expect(r.session(sid)?.routes == [])
        r.applyAgents(try #require(AgentInfo.parseList(Data(agents(status: "idle", state: "done").utf8))))
        #expect(r.session(sid)?.routes == [.background])
        #expect(r.resolve("0b8e8a52")?.id == sid)
    }
}

final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Suite struct TranscriptTests {
    let path = Bundle.module.url(forResource: "transcript", withExtension: "jsonl", subdirectory: "Fixtures")!.path

    @Test func selectsTurnByPromptIdMarkerOrFallback() {
        #expect(TranscriptReader.finalTurnText(transcriptPath: path, promptId: "p1") == "first answer")
        #expect(TranscriptReader.finalTurnText(transcriptPath: path, promptId: "p2") == "Let me read it.\n\nThe page shows a login form.")
        #expect(TranscriptReader.finalTurnText(transcriptPath: path, promptId: nil, marker: "abc-123") == "Click Save.")
        #expect(TranscriptReader.finalTurnText(transcriptPath: path, promptId: "missing") == nil)
        #expect(TranscriptReader.finalTurnText(transcriptPath: "/nonexistent.jsonl", promptId: "p1") == nil)
        #expect(TranscriptReader.contains(path, "abc-123"))
    }
}

@Suite struct DeliveryTests {
    private func engine(_ runner: FakeRunner, state: String) -> Engine {
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner,
                       registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }))
        e.refreshAgents()
        if state == "working" { e.registry.apply(hook("UserPromptSubmit")) }
        return e
    }

    @Test func backgroundRouteRefusesBusySession() {
        let runner = FakeRunner(agentsJSON: agents(status: "busy", state: "working"))
        let r = engine(runner, state: "idle").send(SendRequest(session: sid, text: "hi"))
        #expect(!r.ok)
        #expect(r.route == .background)
        #expect(r.error?.hasPrefix("busy") == true)
        #expect(!runner.recorded.contains { $0.first == Constants.ClaudeCLI.stopCommand || $0.first == Constants.ClaudeCLI.resumeFlag })
    }

    /// A finished turn with a background shell still running reads busy/done: it is not mid-turn.
    @Test func backgroundRouteSendsToFinishedTurnWithBackgroundWork() {
        let runner = FakeRunner(agentsJSON: agents(status: "busy", state: "done"),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = engine(runner, state: "idle")
        #expect(e.registry.session(sid)?.state == .idle)
        #expect(e.registry.session(sid)?.routes == [.background])
        // The resumed process shows up running again.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        #expect(e.send(SendRequest(session: sid, text: "hi")).ok)
        let calls = runner.recorded.filter { $0.first != "agents" }
        // Stopped, then resumed with the message and a note that its background work was stopped.
        #expect(calls.first == ["stop", "0b8e8a52"])
        #expect(calls.dropFirst().first == ["--resume", sid, "--bg", "hi\n\n" + Constants.ClaudeCLI.backgroundWorkNote])
    }

    /// The other disagreement: the turn has ended and the process is idle, but `state` still reads working.
    @Test func backgroundRouteSendsWhenOnlyTheStaleStateSaysWorking() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "working"),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = engine(runner, state: "idle")
        #expect(e.registry.session(sid)?.state == .idle)
        #expect(e.registry.session(sid)?.routes == [.background])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        #expect(e.send(SendRequest(session: sid, text: "hi")).ok)
        // Nothing was left running, so the message goes as written.
        let calls = runner.recorded.filter { $0.first != "agents" }
        #expect(calls.dropFirst().first == ["--resume", sid, "--bg", "hi"])
    }

    @Test func midTurnNeedsABusyProcessAndAnOpenTurn() throws {
        func midTurn(_ json: String, transcript: Bool?) throws -> Bool {
            try #require(AgentInfo.parseList(Data(json.utf8))?.first).isMidTurn { _ in transcript }
        }
        // The transcript settles it for a busy process, whatever the listing's state says.
        #expect(try midTurn(agents(status: "busy", state: "working"), transcript: true))
        #expect(try !midTurn(agents(status: "busy", state: "working"), transcript: false))
        #expect(try midTurn(agents(status: "busy", state: "done"), transcript: true))
        // A process that is not busy is at its prompt, even with a stale state or an open-looking transcript.
        #expect(try !midTurn(agents(status: "idle", state: "working"), transcript: true))
        #expect(try !midTurn(agents(status: "idle", state: "blocked"), transcript: nil))
        // Without a readable transcript the listing's state is the fallback.
        #expect(try midTurn(agents(status: "busy", state: "working"), transcript: nil))
        #expect(try !midTurn(agents(status: "busy", state: "done"), transcript: nil))
        // Not running at all: there is no status, and nothing can be mid-turn.
        let stopped = agents(status: "idle", state: "working", running: false).replacingOccurrences(of: #""status":"idle","#, with: "")
        #expect(try !midTurn(stopped, transcript: true))
    }

    /// The case that held messages back: the turn ended, a background shell runs on, and the listing
    /// says busy and working. The transcript shows the turn is over, so the message goes.
    @Test func backgroundRouteSendsWhenTheTranscriptShowsTheTurnEnded() {
        let runner = FakeRunner(agentsJSON: agents(status: "busy", state: "working"),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner,
                       registry: SessionRegistry(replyReader: { _ in nil }, turnProbe: { _ in false }, answerProbe: { _, _ in true }))
        e.refreshAgents()
        #expect(e.registry.session(sid)?.state == .idle)
        // The resumed process shows up running again.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        #expect(e.send(SendRequest(session: sid, text: "hi")).ok)
        let calls = runner.recorded.filter { $0.first != "agents" }
        #expect(calls.first == ["stop", "0b8e8a52"])
        #expect(calls.dropFirst().first == ["--resume", sid, "--bg", "hi\n\n" + Constants.ClaudeCLI.backgroundWorkNote])
    }

    @Test func transcriptTellsWhetherTheLastTurnEnded() throws {
        func open(_ lines: [String]) throws -> Bool? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-turn-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
            return TranscriptReader.turnIsOpen(transcriptPath: url.path)
        }
        let prompt = #"{"type":"user","message":{"role":"user","content":"go"}}"#
        let toolCall = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"#
        let ended = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
        let bookkeeping = #"{"type":"last-prompt"}"#
        let subagent = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[]}}"#

        #expect(try open([prompt]) == true)
        #expect(try open([prompt, toolCall]) == true)
        #expect(try open([prompt, toolCall, toolResult]) == true)
        #expect(try open([prompt, toolCall, toolResult, ended]) == false)
        // Bookkeeping written after the answer, and a subagent still working, do not reopen the turn.
        #expect(try open([prompt, ended, bookkeeping, bookkeeping, subagent]) == false)
        // A new prompt after an ended turn opens the next one.
        #expect(try open([prompt, ended, prompt]) == true)
        #expect(try open([bookkeeping]) == nil)
        #expect(TranscriptReader.turnIsOpen(transcriptPath: "/nonexistent/none.jsonl") == nil)
    }

    @Test func backgroundRouteRefusesWhenHooksSayWorking() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done"))
        let r = engine(runner, state: "working").send(SendRequest(session: sid, text: "hi"))
        #expect(r.error?.hasPrefix("busy") == true)
    }

    @Test func backgroundRouteReportsForkAsError() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done"),
                                resumeOutput: "backgrounded · 9f9f9f9f · t\n")
        let r = engine(runner, state: "idle").send(SendRequest(session: sid, text: "hi"))
        #expect(!r.ok)
        #expect(r.error?.contains("forked a copy (9f9f9f9f)") == true)
        // Stopped first, resumed with no other flags, then the copy was stopped.
        let calls = runner.recorded.filter { $0.first != "agents" }
        #expect(calls == [["stop", "0b8e8a52"], ["--resume", sid, "--bg", "hi"], ["stop", "9f9f9f9f"]])
    }

    @Test func backgroundRouteSucceedsWhenSameIdContinues() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done", running: false),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = engine(runner, state: "idle")
        // The resumed process shows up running again.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        let r = e.send(SendRequest(session: sid, text: "hi"))
        #expect(r.ok)
        #expect(r.route == .background)
        #expect(!runner.recorded.contains { $0.first == "stop" })
    }

    @Test func interactiveWithoutChannelHasNoRoute() {
        let runner = FakeRunner(agentsJSON: "[]")
        let e = engine(runner, state: "idle")
        e.registry.apply(hook("SessionStart", other))
        let r = e.send(SendRequest(session: other, text: "hi"))
        #expect(!r.ok)
        #expect(r.error?.hasPrefix("no delivery route") == true)
        #expect(e.send(SendRequest(session: "ffffffff-0000-4000-8000-000000000000", text: "x")).error?.hasPrefix("unknown session") == true)
        #expect(e.send(SendRequest(session: other)).error?.hasPrefix("nothing to send") == true)
    }

    @Test func parsesBackgroundedLineAndStream() {
        #expect(Engine.backgroundedId(in: "backgrounded · d8281a34 · spikeB\n  claude agents") == "d8281a34")
        #expect(Engine.backgroundedId(in: "nothing") == nil)
        let stream = """
            {"type":"system","subtype":"init","session_id":"\(sid)"}
            {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"WORD"}]}}
            {"type":"result","session_id":"\(sid)","result":"WORD","is_error":false}
            """
        let o = Engine.parseStream(Data(stream.utf8))
        #expect(o.text == "WORD")
        #expect(o.sessionId == sid)
    }
}
