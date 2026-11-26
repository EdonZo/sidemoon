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
            let images = request.allImagePaths
            imageExistedAtSend.append(!images.isEmpty && images.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        }
        return reply(request)
    }
    /// What starting a new session does; by default it fails as not confirmed.
    var onStart: @Sendable (NewSessionRequest) -> NewSessionResult = { _ in
        NewSessionResult(sessionId: nil, failure: .notConfirmed, detail: nil)
    }
    var homeRefused = false
    private(set) var startRequests: [NewSessionRequest] = []
    func startSession(_ request: NewSessionRequest) -> NewSessionResult {
        lock.withLock { startRequests.append(request) }
        return onStart(request)
    }
    func homeFolderRefused() -> Bool { homeRefused }
    private(set) var chatNames: [String] = []
    /// What a stop does here, and the sessions stopped.
    var stopOutcome: Engine.StopOutcome = .stopped
    private(set) var stops: [String] = []
    /// Runs inside `stop`, before it returns (a test holds a stop under way with it).
    var stopHook: @Sendable () -> Void = {}
    func stop(_ sessionId: String) -> Engine.StopOutcome {
        lock.withLock { stops.append(sessionId) }
        stopHook()
        return stopOutcome
    }
    var stopped: [String] { lock.withLock { stops } }
    func newChat(name: String) -> String {
        var s = Session(id: UUID().uuidString.lowercased())
        s.kind = .chat
        s.name = name
        lock.withLock {
            chatNames.append(name)
            list.append(s)
        }
        return s.id
    }
    var started: [NewSessionRequest] { lock.withLock { startRequests } }

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

/// A capture store in a fresh temporary folder. Every model in the tests gets one: `CompanionModel` has no default
/// store, and the support folder under a test runner is never the real one (`Constants.TestRunner`).
func scratchStore() -> CaptureStore {
    CaptureStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-captures-\(UUID().uuidString)", isDirectory: true))
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

    /// Nothing ever chosen: a capture goes to General, which needs no setup.
    @Test func withNothingChosenACaptureGoesToGeneral() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        await model.captureAndSend()
        #expect(engine.sent.map(\.session) == [Constants.Chat.generalId])
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
        // A failure Retry can fix keeps the capture for it.
        #expect(store.files().count == 1)
        #expect(model.thread.last.map(model.canRetry) == true)
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

    @Test func activeWindowGoesToGeneralWhenNothingWasChosen() async {
        let engine = FakeEngine()
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        await model.captureActiveWindowAndSend()
        #expect(engine.sent.map(\.session) == [Constants.Chat.generalId])
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

    /// The note shortcut while a capture waits does nothing: the capture keeps its turn.
    @Test func noteHotkeyWhileHoldingIsIgnored() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        let held = model.heldCaptures
        model.beginNote()
        #expect(engine.sent.isEmpty)
        #expect(model.heldCaptures == held)
        #expect(store.files().count == 1)
        #expect(model.status.activity == .holding)
        #expect(model.noteCountdown != nil)
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.count == 1)
        #expect(store.files().isEmpty)
    }

    // MARK: Several captures in one message

    /// Pressing a capture shortcut again while a capture waits adds one to the same message, in order; the
    /// countdown starts again from the full time; one message goes with every image and the numbered names.
    @Test func moreCapturesWhileHoldingGoInOneMessageInOrder() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        let first = model.heldCaptures.urls
        // Part of the grace period passes, then the user scrolls and presses again.
        await settle { clock.waiting > 0 }
        clock.releaseAll()
        await settle { (model.noteCountdown?.elapsedTicks ?? 0) > 0 }
        #expect((model.noteCountdown?.elapsedTicks ?? 0) > 0)
        await model.captureActiveWindowAndSend()
        #expect(model.noteCountdown?.elapsedTicks == 0)
        await model.captureAndSend()
        #expect(model.heldCaptures.count == 3)
        #expect(model.heldCaptures.urls.first == first.first)
        #expect(model.heldCaptures.names == ["Capture 1", "Capture 2", "Capture 3"])
        #expect(store.files().count == 3)
        #expect(engine.sent.isEmpty && model.status.activity == .holding)
        let order = model.heldCaptures.urls.map(\.path)
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.allImagePaths == order)
        #expect(engine.sent.first?.text == CompanionConstants.Messages.defaultCapturesText)
        #expect(engine.existed == [true])
        #expect(model.thread.last { $0.role == .you }?.attachments == ["Capture 1", "Capture 2", "Capture 3"])
        #expect(store.files().isEmpty)
    }

    /// Typing a note while captures wait: another press still adds one, and the note goes with all of them.
    /// A typed note keeps the countdown stopped.
    @Test func captureAddedWhileTypingANoteKeepsTheNote() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, _, task) = await holdActiveWindow(engine, sleeper: clock)
        model.noteDraft = "these two pages"
        await model.captureActiveWindowAndSend()
        #expect(model.heldCaptures.count == 2)
        #expect(model.noteCountdown == nil)
        #expect(model.noteDraft == "these two pages")
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.first?.text == "these two pages")
        #expect(engine.sent.first?.allImagePaths.count == 2)
    }

    /// Each chip's cross takes that capture back (its file deleted); the others keep their order and still go.
    @Test func removingOneCaptureKeepsTheOthers() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        await model.captureActiveWindowAndSend()
        await model.captureActiveWindowAndSend()
        let urls = model.heldCaptures.urls
        model.removeHeldCapture(urls[1])
        #expect(model.heldCaptures.urls == [urls[0], urls[2]])
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(model.heldCaptures.names == ["Capture 1", "Capture 2"])
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.first?.allImagePaths == [urls[0].path, urls[2].path])
        #expect(store.files().isEmpty)
    }

    /// Removing the only capture is the same as Escape: nothing is sent.
    @Test func removingTheLastCaptureCancels() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        model.removeHeldCapture(model.heldCaptures.urls[0])
        await task.value
        clock.releaseAll()
        #expect(engine.sent.isEmpty && store.files().isEmpty && !model.isHoldingCapture)
    }

    /// At the limit a further press keeps what waits and sends nothing early.
    @Test func atTheLimitAnotherPressDoesNothing() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        let limit = CompanionConstants.Capture.maxPerMessage
        for _ in 1..<limit { await model.captureActiveWindowAndSend() }
        #expect(model.heldCaptures.count == limit && model.heldCaptures.isFull)
        await model.captureActiveWindowAndSend()
        await model.captureAndSend()
        #expect(model.heldCaptures.count == limit)
        #expect(store.files().count == limit)
        #expect(engine.sent.isEmpty && model.status.activity == .holding)
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.first?.allImagePaths.count == limit)
        #expect(store.files().isEmpty)
    }

    /// Escape with several captures waiting deletes every one of them.
    @Test func escapeDiscardsEveryHeldCapture() async {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        let (model, store, task) = await holdActiveWindow(engine, sleeper: clock)
        await model.captureActiveWindowAndSend()
        model.cancelNote()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.isEmpty && store.files().isEmpty)
    }

    /// A press whose capture is cancelled (Escape on the region) leaves what waits as it was.
    @Test func aCancelledExtraCaptureChangesNothing() async {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let clock = ManualSleeper()
        let (model, store, _) = makeModel(engine, capture: FakeCapture(cancel: true), sleeper: clock.sleeper)
        model.startEngine()
        model.selectTarget(target)
        let task = Task { await model.captureActiveWindowAndSend() }
        await settle { model.isHoldingCapture && clock.waiting > 0 }
        await model.captureAndSend()
        #expect(model.heldCaptures.count == 1 && store.files().count == 1)
        #expect(model.noteCountdown != nil)
        model.submitHeldCapture()
        await task.value
        clock.releaseAll()
        #expect(engine.sent.first?.allImagePaths.count == 1)
        #expect(engine.sent.first?.text == CompanionConstants.Messages.defaultCaptureText)
    }

    // MARK: Paste

    /// An image pasted into the composer waits with what is typed, never counts down, and goes on Return.
    @Test func pastedImageWaitsWithTheTypedTextUntilReturn() async throws {
        let engine = FakeEngine()
        let clock = ManualSleeper()
        engine.list = [idleSession()]
        let (model, store, _) = makeModel(engine, sleeper: clock.sleeper)
        model.startEngine()
        model.selectTarget(target)
        model.noteDraft = "what is this error?"
        let file = try model.newCaptureFile()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        #expect(file.deletingLastPathComponent().path == store.directory.path)
        let task = Task { await model.pasteImage(at: file) }
        await settle { model.isHoldingCapture }
        #expect(model.noteDraft == "what is this error?")
        #expect(model.noteCountdown == nil)
        #expect(model.heldCaptures.urls == [file])
        // A second paste joins it.
        let second = try model.newCaptureFile()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: second)
        await model.pasteImage(at: second)
        #expect(model.heldCaptures.urls == [file, second])
        model.submitHeldCapture()
        await task.value
        #expect(engine.sent.count == 1)
        #expect(engine.sent.first?.text == "what is this error?")
        #expect(engine.sent.first?.allImagePaths == [file.path, second.path])
        #expect(store.files().isEmpty)
    }

    /// Pasted files wait like dropped ones but without the countdown, and are never deleted.
    @Test func pastedFilesWaitAndAreKept() async throws {
        let engine = FakeEngine()
        engine.list = [idleSession()]
        let (model, _, _) = makeModel(engine)
        model.startEngine()
        model.selectTarget(target)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-paste-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task { await model.pasteFiles([file]) }
        await settle { model.isHoldingCapture }
        #expect(model.heldFiles == [file] && model.noteCountdown == nil)
        model.submitHeldCapture()
        await task.value
        #expect(engine.sent.first?.filePaths == [file.path])
        #expect(FileManager.default.fileExists(atPath: file.path))
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
