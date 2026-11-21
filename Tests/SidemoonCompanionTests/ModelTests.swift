import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

/// Stand-in engine: scripted sessions and send results, records requests.
final class FakeEngine: CompanionEngine, @unchecked Sendable {
    private let lock = NSLock()
    var startOutcome: EngineStartOutcome = .running
    var list: [Session] = []
    var handlers: [@Sendable (Session) -> Void] = []
    var reply: @Sendable (SendRequest) -> SendResult = { r in
        SendResult(ok: true, sessionId: r.session, route: .channel, reply: "next: click Save", error: nil, detail: nil)
    }
    private(set) var requests: [SendRequest] = []
    /// Image bytes as they were when send was called (the model deletes the file afterwards).
    private(set) var imageExistedAtSend: [Bool] = []

    func start() throws -> EngineStartOutcome { startOutcome }
    func stop() {}
    func sessions() -> [Session] { lock.withLock { list } }
    func subscribe(_ handler: @escaping @Sendable (Session) -> Void) { lock.withLock { handlers.append(handler) } }
    func send(_ request: SendRequest) -> SendResult {
        lock.withLock {
            requests.append(request)
            imageExistedAtSend.append(request.imagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
        return reply(request)
    }
    func emit(_ s: Session) {
        lock.withLock {
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s } else { list.append(s) }
        }
        lock.withLock { handlers }.forEach { $0(s) }
    }
    var sent: [SendRequest] { lock.withLock { requests } }
    var existed: [Bool] { lock.withLock { imageExistedAtSend } }
}

struct FakeCapture: CaptureProvider {
    var cancel = false
    /// Stands in for an active-window capture that finds no window.
    var noWindow = false
    func capture(into destination: URL) async throws -> CaptureOutcome {
        if noWindow { throw CaptureError.noActiveWindow }
        if cancel { return .cancelled }
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]).write(to: destination)
        return .captured(destination)
    }
}

private let target = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

private func idleSession(_ id: String = target, reply: String? = nil) -> Session {
    var s = Session(id: id)
    s.cwd = "/tmp/proj"
    s.channelConnected = true
    s.lastEventAt = Date()
    s.lastReply = reply
    return s
}

/// A sleeper the test releases one tick at a time, so the countdown never waits on the real clock.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var sleeper: Sleeper {
        { [self] _ in await withCheckedContinuation { c in lock.withLock { waiters.append(c) } } }
    }
    var waiting: Int { lock.withLock { waiters.count } }

    func releaseAll() {
        let all = lock.withLock { let w = waiters; waiters = []; return w }
        all.forEach { $0.resume() }
    }
}

/// Returns at once: the whole grace period passes without waiting.
private let instantSleeper: Sleeper = { _ in await Task.yield() }

@MainActor
private func makeModel(_ engine: FakeEngine, capture: CaptureProvider = FakeCapture(),
                       windowCapture: CaptureProvider = FakeCapture(),
                       defaults: UserDefaults? = nil,
                       sleeper: @escaping Sleeper = instantSleeper) -> (CompanionModel, CaptureStore, UserDefaults) {
    let d = defaults ?? UserDefaults(suiteName: "sidemoon-test-\(UUID().uuidString)")!
    let store = CaptureStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("sidemoon-captures-\(UUID().uuidString)", isDirectory: true))
    return (CompanionModel(engine: engine, capture: capture, windowCapture: windowCapture, store: store, defaults: d,
                           sleeper: sleeper), store, d)
}

/// Lets queued main-actor tasks (registry callbacks) run.
@MainActor
private func settle(until condition: () -> Bool, timeout: TimeInterval = 2) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

@MainActor
@Suite struct ModelTests {
    @Test func engineConflictIsShownNotFought() {
        let engine = FakeEngine()
        engine.startOutcome = .conflict
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        #expect(model.engineState == .conflict)
        #expect(model.currentError == .engineConflict)
        #expect(model.indicator == .error)
    }

    @Test func refusesToCaptureWithoutTarget() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        await model.captureAndSend()
        #expect(model.currentError == .noTarget)
        #expect(engine.sent.isEmpty)
    }

    @Test func sendDeliversImageWaitsAndDeletesCapture() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, store, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        await model.captureAndSend()
        #expect(engine.sent.count == 1)
        let req = engine.sent[0]
        #expect(req.session == target)
        #expect(req.wait)
        #expect(req.text == CompanionConstants.Messages.defaultCaptureText)
        #expect(engine.existed == [true])
        #expect(store.files().isEmpty)
        #expect(model.latestReply == "next: click Save")
        #expect(model.indicator == .replyReady)
        model.openBubble()
        #expect(model.indicator == .idle)
    }

    @Test func escapeCancelsWithNoSend() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, store, _) = makeModel(engine, capture: FakeCapture(cancel: true))
        model.startEngine()
        model.selectTarget(target)
        await model.captureAndSend()
        #expect(engine.sent.isEmpty)
        #expect(model.status.activity == .idle)
        #expect(store.files().isEmpty)
    }

    @Test func noteIsSentAsText() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        model.beginNote()
        #expect(model.isEditingNote)
        #expect(model.isExpanded)
        model.noteDraft = "  the button is greyed out  "
        let note = model.finishNote()
        #expect(!model.isEditingNote)
        await model.captureAndSend(note: note)
        #expect(engine.sent.first?.text == "the button is greyed out")
    }

    @Test func busyFailureIsExplained() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        engine.reply = { r in SendResult.failure(.busy(r.session), sessionId: r.session, route: .background) }
        let (model, store, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        await model.captureAndSend()
        #expect(model.currentError == .busy)
        #expect(store.files().isEmpty)
    }

    @Test func showsTurnsSidemoonDidNotTrigger() async {
        let engine = FakeEngine()
        engine.list = [idleSession(reply: "old instruction")]
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        #expect(model.latestReply == "old instruction")
        #expect(model.indicator == .idle)
        engine.emit(idleSession(reply: "now open Settings"))
        await settle { model.latestReply == "now open Settings" }
        #expect(model.latestReply == "now open Settings")
        #expect(model.indicator == .replyReady)
        // Other sessions' replies do not leak into the bubble.
        engine.emit(idleSession("7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f", reply: "unrelated"))
        await settle { model.sessions.count == 2 }
        #expect(model.latestReply == "now open Settings")
    }

    @Test func targetWorkingMovesToWaiting() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let gate = DispatchSemaphore(value: 0)
        engine.reply = { r in
            gate.wait()
            return SendResult(ok: true, sessionId: r.session, route: .channel, reply: "done", error: nil, detail: nil)
        }
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        let task = Task { await model.captureAndSend() }
        await settle { model.status.activity == .sending }
        #expect(model.status.activity == .sending)
        var working = idleSession()
        working.state = .working
        engine.emit(working)
        await settle { model.status.activity == .waiting }
        #expect(model.indicator == .waiting)
        gate.signal()
        await task.value
        #expect(model.latestReply == "done")
    }

    @Test func activeWindowIsSentWithDefaultTextAndDeleted() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        // The region provider would cancel; the active-window path must not use it.
        let (model, store, _) = makeModel(engine, capture: FakeCapture(cancel: true))
        model.startEngine()
        model.selectTarget(target)
        await model.captureActiveWindowAndSend()
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.session == target)
        #expect(engine.sent.first?.wait == true)
        #expect(engine.sent.first?.text == CompanionConstants.Messages.defaultCaptureText)
        #expect(engine.existed == [true])
        #expect(store.files().isEmpty)
        #expect(model.latestReply == "next: click Save")
        // The bubble opened for the note, so the reply lands in an open bubble and is already seen.
        #expect(model.isExpanded)
        #expect(model.indicator == .idle)
    }

    @Test func noActiveWindowSendsNothingAndExplains() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, store, _) = makeModel(engine, windowCapture: FakeCapture(noWindow: true))
        model.startEngine()
        model.selectTarget(target)
        await model.captureActiveWindowAndSend()
        #expect(engine.sent.isEmpty)
        #expect(model.currentError == .noActiveWindow)
        #expect(model.indicator == .error)
        #expect(store.files().isEmpty)
    }

    @Test func activeWindowNeedsTargetToo() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        await model.captureActiveWindowAndSend()
        #expect(model.currentError == .noTarget)
        #expect(engine.sent.isEmpty)
    }

    // MARK: Active window held for a note

    /// Starts the active-window hotkey with a manual clock and waits until the capture is held.
    private func holdActiveWindow(_ engine: FakeEngine, sleeper: ManualSleeper)
        async -> (CompanionModel, CaptureStore, Task<Void, Never>) {
        engine.list = engine.list.isEmpty ? [idleSession()] : engine.list
        let (model, store, _) = makeModel(engine, sleeper: sleeper.sleeper)
        model.startEngine()
        model.selectTarget(target)
        let task = Task { await model.captureActiveWindowAndSend() }
        await settle { model.isHoldingCapture && sleeper.waiting > 0 }
        return (model, store, task)
    }

    @Test func heldCaptureSendsAfterGracePeriodWhenUntouched() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        #expect(model.status.activity == .holding)
        #expect(model.isEditingNote)
        #expect(model.isExpanded)
        #expect(store.files().count == 1)
        let ticks = NoteCountdown().totalTicks
        #expect(model.noteCountdown?.secondsLeft == Int(CompanionConstants.Timing.noteGracePeriod))
        for _ in 0..<(ticks - 1) {
            await settle { clock.waiting > 0 }
            clock.releaseAll()
        }
        await settle { clock.waiting > 0 }
        #expect(engine.sent.isEmpty)
        #expect(model.isHoldingCapture)
        clock.releaseAll()
        await task.value
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.text == CompanionConstants.Messages.defaultCaptureText)
        #expect(engine.existed == [true])
        #expect(store.files().isEmpty)
        #expect(!model.isEditingNote)
        #expect(!model.isHoldingCapture)
    }

    @Test func typingStopsCountdownUntilReturn() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.noteDraft = "why is this greyed out?"
        #expect(model.noteCountdown == nil)
        // Time passing after typing sends nothing.
        for _ in 0..<NoteCountdown().totalTicks {
            clock.releaseAll()
            await Task.yield()
        }
        await settle(until: { false }, timeout: 0.1)
        #expect(engine.sent.isEmpty)
        #expect(model.isHoldingCapture)
        #expect(model.status.activity == .holding)
        #expect(store.files().count == 1)
        model.submitHeldCapture()
        await task.value
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.text == "why is this greyed out?")
        #expect(store.files().isEmpty)
        #expect(!model.isEditingNote)
    }

    @Test func returnOnEmptyFieldSendsAtOnce() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.submitHeldCapture()
        await task.value
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.text == CompanionConstants.Messages.defaultCaptureText)
        #expect(store.files().isEmpty)
        #expect(model.noteCountdown == nil)
        clock.releaseAll()
    }

    @Test func escapeDiscardsHeldCaptureAndSendsNothing() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.noteDraft = "half a thought"
        model.cancelNote()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.isEmpty)
        #expect(store.files().isEmpty)
        #expect(model.status.activity == .idle)
        #expect(!model.isEditingNote)
        #expect(!model.isHoldingCapture)
        #expect(model.noteDraft.isEmpty)
    }

    @Test func secondHotkeyWhileHoldingIsIgnored() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        let held = model.heldCapture
        await model.captureActiveWindowAndSend()
        await model.captureAndSend()
        model.beginNote()
        #expect(engine.sent.isEmpty)
        #expect(model.heldCapture == held)
        #expect(store.files().count == 1)
        #expect(model.status.activity == .holding)
        #expect(model.noteCountdown != nil)
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.count == 1)
        #expect(store.files().isEmpty)
    }

    @Test func targetChangeDiscardsHeldCapture() async {
        let engine = FakeEngine()
        let other = "7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"
        engine.list = [idleSession(), idleSession(other)]
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.selectTarget(other)
        await task.value
        clock.releaseAll()
        #expect(engine.sent.isEmpty)
        #expect(store.files().isEmpty)
        #expect(model.status.activity == .idle)
        #expect(!model.isEditingNote)
    }

    @Test func discardOnQuitDeletesHeldCaptureAtOnce() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.discardHeldCapture()
        // Deleted synchronously, before the capture task gets to run again.
        #expect(store.files().isEmpty)
        await task.value
        clock.releaseAll()
        #expect(engine.sent.isEmpty)
    }

    @Test func targetChoicePersists() {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, _, defaults) = makeModel(engine)
        model.selectTarget(target)
        let (again, _, _) = makeModel(engine, defaults: defaults)
        #expect(again.targetId == target)
    }
}

@Suite(.serialized) struct EngineHostTests {
    struct EmptyRunner: ClaudeRunner {
        func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
            ProcessResult(status: 0, stdout: Data("[]".utf8), stderr: Data(), timedOut: false)
        }
    }

    private func socketPath() -> String { "/tmp/tg-\(UUID().uuidString.prefix(8)).sock" }

    @Test func detectsAnotherEngine() throws {
        let path = socketPath()
        let other = try UnixSocket.listen(path: path)
        defer { close(other); unlink(path) }
        let host = InProcessEngine(engine: Engine(socketPath: path, runner: EmptyRunner()))
        #expect(try host.start() == .conflict)
    }

    @Test func startsAndStops() throws {
        let path = socketPath()
        let host = InProcessEngine(engine: Engine(socketPath: path, runner: EmptyRunner()))
        #expect(try host.start() == .running)
        #expect(FileManager.default.fileExists(atPath: path))
        host.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
