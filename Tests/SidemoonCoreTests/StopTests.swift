import Foundation
import Testing
@testable import SidemoonCore

private let first = "aaaaaaaa-0000-4000-8000-000000000001"
private let general = Constants.Chat.generalId
private let sid = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

/// A `claude -p` run that goes on until it is stopped, like a long answer; it has already said who it is and a
/// little of its answer. Later runs answer at once.
private final class LongRun: ClaudeRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var going = false
    var isGoing: Bool { lock.withLock { going } }

    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        run(args, cwd: cwd, stdin: stdin, timeout: timeout, handle: RunHandle())
    }

    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval, handle: RunHandle) -> ProcessResult {
        if args.first == "agents" { return ProcessResult(status: 0, stdout: Data("[]".utf8), stderr: Data(), timedOut: false) }
        let n: Int = lock.withLock { calls.append(args); return calls.count }
        let initLine = #"{"type":"system","subtype":"init","session_id":"\#(first)"}"# + "\n"
        guard n == 1 else {
            let out = initLine + #"{"type":"result","is_error":false,"result":"Again.","session_id":"\#(first)"}"# + "\n"
            return ProcessResult(status: 0, stdout: Data(out.utf8), stderr: Data(), timedOut: false)
        }
        let ended = DispatchSemaphore(value: 0)
        handle.attach { ended.signal() }
        lock.withLock { going = true }
        ended.wait()
        let out = initLine + #"{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"text","text":"Half an ans"}]}}"# + "\n"
        return ProcessResult(status: 130, stdout: Data(out.utf8), stderr: Data(), timedOut: false)
    }

    var recorded: [[String]] { lock.withLock { calls } }
}

@Suite struct StopTests {
    /// Control-C on a chat ends its run; what it said stays, the conversation stays, and the next message
    /// continues it.
    @Test func aChatRunIsStoppedAndTheNextMessageContinues() async {
        let runner = LongRun()
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner, chats: .inMemory(),
                       chatFolder: FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-stop-\(UUID().uuidString)").path)
        let running = Task.detached { e.send(SendRequest(session: general, text: "a long question", wait: true)) }
        while !runner.isGoing { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(e.stop(general) == .stopped)
        let r = await running.value
        #expect(r.failure == .stopped && r.reply == "Half an ans")
        #expect(e.chats.chat(general)?.claudeSessionId == first)
        #expect(e.registry.session(general)?.state == .idle)
        // Nothing runs now: a second stop does nothing.
        #expect(e.stop(general) == .notRunning)
        let next = e.send(SendRequest(session: general, text: "go on", wait: true))
        #expect(next.ok && next.reply == "Again.")
        #expect(runner.recorded.last?.prefix(3) == ["-p", "--resume", first])
    }

    /// A background session at work: `claude stop` with its short id. Not at work: nothing is run.
    @Test func aBackgroundSessionIsStoppedOnlyWhileWorking() {
        let busy = FakeRunner(agentsJSON: agents(status: "busy", state: "working"))
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: busy,
                       registry: SessionRegistry(replyReader: { _ in nil }, turnProbe: { _ in true }, answerProbe: { _, _ in true }),
                       chats: .inMemory())
        e.refreshAgents()
        #expect(e.stop(sid) == .stopped)
        #expect(busy.recorded.contains([Constants.ClaudeCLI.stopCommand, "0b8e8a52"]))

        let idle = FakeRunner(agentsJSON: agents(status: "idle", state: "done"))
        let quiet = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: idle,
                           registry: SessionRegistry(replyReader: { _ in nil }, turnProbe: { _ in false }, answerProbe: { _, _ in true }),
                           chats: .inMemory())
        quiet.refreshAgents()
        #expect(quiet.stop(sid) == .notRunning)
        #expect(!idle.recorded.contains { $0.first == Constants.ClaudeCLI.stopCommand })
    }

    /// A session in the user's terminal is never signalled: the user is told to stop it there.
    @Test func aTerminalSessionIsLeftAlone() throws {
        let runner = FakeRunner(agentsJSON: "[]")
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner,
                       registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }), chats: .inMemory())
        let o: [String: Any] = ["session_id": sid, "hook_event_name": Constants.HookEvents.userPromptSubmit, "cwd": "/tmp/proj"]
        e.registry.apply(try #require(HookEvent(json: try JSONSerialization.data(withJSONObject: o), claudePid: 4242)))
        e.registry.setChannel(sessionId: sid, connected: true)
        #expect(e.stop(sid) == .inTerminal)
        #expect(runner.recorded.isEmpty)
        #expect(e.stop("ffffffff-0000-4000-8000-000000000000") == .notRunning)
    }
}
