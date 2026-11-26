import Foundation
import Testing
@testable import SidemoonCore

/// Answers `claude -p` runs from a script, one response per run, and records what each run was given.
private final class ChatRunner: ClaudeRunner, @unchecked Sendable {
    struct Call { let args: [String]; let cwd: String?; let stdin: Data? }
    private let lock = NSLock()
    private var responses: [(status: Int32, out: String, err: String)]
    private var calls: [Call] = []
    /// Held while a run is going, so a test can send a second message meanwhile.
    let gate: DispatchSemaphore?

    init(_ responses: [(Int32, String, String)], gate: DispatchSemaphore? = nil) {
        self.responses = responses.map { (status: $0.0, out: $0.1, err: $0.2) }
        self.gate = gate
    }

    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        if args.first == "agents" { return ProcessResult(status: 0, stdout: Data("[]".utf8), stderr: Data(), timedOut: false) }
        let next: (status: Int32, out: String, err: String) = lock.withLock {
            calls.append(Call(args: args, cwd: cwd, stdin: stdin))
            return responses.isEmpty ? (0, "", "") : responses.removeFirst()
        }
        gate?.wait()
        return ProcessResult(status: next.status, stdout: Data(next.out.utf8), stderr: Data(next.err.utf8), timedOut: false)
    }

    var recorded: [Call] { lock.withLock { calls } }
}

private func answered(_ text: String, session: String) -> String {
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        + #"{"type":"result","is_error":false,"result":"\#(text)","session_id":"\#(session)"}"# + "\n"
}

private let first = "aaaaaaaa-0000-4000-8000-000000000001"
private let fresh = "bbbbbbbb-0000-4000-8000-000000000002"
private let general = Constants.Chat.generalId

private func scratch() -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-chat-\(UUID().uuidString)").path
    return path
}

private func engine(_ runner: ChatRunner, folder: String = scratch(), book: ChatBook = .inMemory()) -> Engine {
    Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner,
           registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }, home: "/Users/someone"),
           chats: book, chatFolder: folder)
}

@Suite struct ChatTests {
    @Test func generalIsAlwaysListed() {
        let e = engine(ChatRunner([]))
        let listed = e.registry.snapshot().first { $0.id == general }
        #expect(listed?.kind == .chat)
        #expect(listed?.routes == [.headless])
        #expect(ChatBook.inMemory().all.map(\.id) == [general])
    }

    /// The first message starts a conversation; the next one continues it with --resume. Each is one `claude -p`
    /// run in the chat folder, allowed only to read, with the message on stdin.
    @Test func firstMessageStartsAndTheNextContinues() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let runner = ChatRunner([(0, answered("Hello.", session: first), ""), (0, answered("Again.", session: first), "")])
        let e = engine(runner, folder: folder)
        let one = e.send(SendRequest(session: general, text: "hi", wait: true))
        #expect(one.ok && one.reply == "Hello." && !one.startedOver)
        let two = e.send(SendRequest(session: general, text: "and?", wait: true))
        #expect(two.ok && two.reply == "Again.")
        let calls = runner.recorded
        #expect(calls.count == 2)
        #expect(calls[0].args.first == "-p" && !calls[0].args.contains("--resume"))
        #expect(calls[1].args.prefix(3) == ["-p", "--resume", first])
        for call in calls {
            #expect(call.cwd == folder)
            #expect(call.args.contains("--allowedTools"))
            let tools = call.args.drop { $0 != "--allowedTools" }.dropFirst().prefix(Constants.Chat.allowedTools.count)
            #expect(Array(tools) == Constants.Chat.allowedTools)
            #expect(!call.args.contains("--dangerously-skip-permissions") && !call.args.contains("--model"))
        }
        #expect(String(decoding: calls[0].stdin ?? Data(), as: UTF8.self).contains("hi"))
        #expect(e.chats.chat(general)?.claudeSessionId == first)
        let listed = e.registry.session(general)
        #expect(listed?.lastReply == "Again." && listed?.state == .idle)
    }

    /// A gone conversation is started over in the same send, and the result says so.
    @Test func aGoneConversationStartsOver() {
        let book = ChatBook.inMemory()
        book.update(general, claudeSessionId: first, reply: nil, at: Date())
        let runner = ChatRunner([(1, "", "No conversation found with session ID: \(first)"), (0, answered("Fresh.", session: fresh), "")])
        let e = engine(runner, book: book)
        let r = e.send(SendRequest(session: general, text: "hi", wait: true))
        #expect(r.ok && r.startedOver && r.reply == "Fresh.")
        #expect(runner.recorded.count == 2 && !runner.recorded[1].args.contains("--resume"))
        #expect(e.chats.chat(general)?.claudeSessionId == fresh)
    }

    @Test func aLoginProblemIsTyped() {
        let runner = ChatRunner([(1, #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#, "")])
        let r = engine(runner).send(SendRequest(session: general, text: "hi", wait: true))
        #expect(r.failure == .cannotResume(.loginNeeded, messageSaved: false))
        let missing = Engine(socketPath: "/tmp/unused.sock", runner: MissingRunner(), chats: .inMemory(), chatFolder: scratch())
        guard case .headless? = missing.send(SendRequest(session: general, text: "hi")).failure else {
            Issue.record("expected the claude-not-found failure"); return
        }
    }

    /// While a run is going, a second message to the same chat is busy (the companion sends it afterwards).
    @Test func aSecondMessageWhileRunningIsBusy() async {
        let gate = DispatchSemaphore(value: 0)
        let runner = ChatRunner([(0, answered("One.", session: first), "")], gate: gate)
        let e = engine(runner)
        let running = Task.detached { e.send(SendRequest(session: general, text: "one", wait: true)) }
        while runner.recorded.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(e.registry.session(general)?.state == .working)
        #expect(e.send(SendRequest(session: general, text: "two", wait: true)).failure == .busy(general))
        gate.signal()
        #expect(await running.value.ok)
        #expect(e.registry.session(general)?.state == .idle)
    }

    /// Files are copied into the chat folder, where the run may read them; images go inline.
    @Test func filesAreCopiedIntoTheChatFolder() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-chat-note-\(UUID().uuidString).txt")
        try Data("note".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-chat-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let runner = ChatRunner([(0, answered("Seen.", session: first), "")])
        let r = engine(runner, folder: folder).send(SendRequest(session: general, imagePaths: [image.path], text: "look",
                                                               wait: true, filePaths: [file.path]))
        #expect(r.ok)
        let input = String(decoding: runner.recorded.first?.stdin ?? Data(), as: UTF8.self)
        #expect(input.contains("\"type\":\"image\""))
        let attachments = "\(folder)/\(Constants.Chat.attachmentsFolderName)"
        let copied = try FileManager.default.contentsOfDirectory(atPath: attachments)
        #expect(copied.count == 1 && copied[0].hasSuffix(file.lastPathComponent))
        #expect(input.replacingOccurrences(of: "\\/", with: "/").contains(attachments))
    }

    /// The chat's own Claude Code session reports through the hooks like any other: it is never listed, and its
    /// changes never reach the companion. Other sessions are unaffected.
    @Test func theRunsOwnSessionIsNotListed() throws {
        let folder = scratch()
        let e = engine(ChatRunner([]), folder: folder)
        let seen = LockedSessions()
        e.registry.subscribe { if case let .updated(s) = $0 { seen.add(s.id) } }
        func hook(_ id: String, _ name: String, cwd: String) throws -> HookEvent {
            let o: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": cwd, "last_assistant_message": "x"]
            return try #require(HookEvent(json: try JSONSerialization.data(withJSONObject: o), claudePid: nil))
        }
        for name in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] { e.registry.apply(try hook(first, name, cwd: folder)) }
        e.registry.apply(try hook(fresh, "SessionStart", cwd: "/tmp/proj"))
        let ids = e.registry.snapshot().map(\.id)
        #expect(!ids.contains(first) && ids.contains(fresh) && ids.contains(general))
        #expect(e.registry.resolve(first) == nil)
        #expect(!seen.ids.contains(first) && seen.ids.contains(fresh))
    }

    /// A screenshot or file that is not there is its own typed failure, so the companion never shows the path.
    @Test func aMissingAttachmentIsTyped() {
        let e = engine(ChatRunner([]))
        #expect(e.send(SendRequest(session: general, imagePaths: ["/nonexistent/capture.png"], text: "x")).failure
                == .imageMissing("/nonexistent/capture.png"))
        #expect(e.send(SendRequest(session: general, text: "x", filePaths: ["/nonexistent/notes.txt"])).failure
                == .fileMissing("/nonexistent/notes.txt"))
    }

    @Test func newChatsAreListedAndKept() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-chats-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let e = engine(ChatRunner([(0, answered("Ok.", session: first), "")]), book: ChatBook(path: path))
        let id = e.newChat(name: "reddit post")
        #expect(e.registry.session(id)?.kind == .chat && e.registry.session(id)?.name == "reddit post")
        #expect(e.send(SendRequest(session: id, text: "hi", wait: true)).ok)
        // After a restart: the same chats, the same conversation.
        let again = ChatBook(path: path)
        #expect(again.all.map(\.id) == [general, id])
        #expect(again.chat(id)?.claudeSessionId == first && again.chat(id)?.lastReply == "Ok.")
    }
}

private struct MissingRunner: ClaudeRunner {
    var isInstalled: Bool { false }
    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        ProcessResult(status: 0, stdout: Data("[]".utf8), stderr: Data(), timedOut: false)
    }
}

private final class LockedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ id: String) { lock.withLock { stored.append(id) } }
    var ids: [String] { lock.withLock { stored } }
}
