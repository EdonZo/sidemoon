import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let project = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"
private let other = "7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"

private func session(_ id: String) -> Session {
    var s = Session(id: id)
    s.cwd = "/tmp/proj"
    s.kind = .background
    s.lastEventAt = Date()
    return s
}

/// Holds sends to one session until released, as a session busy with a long answer would.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var arrived = 0
    func pass() {
        lock.withLock { arrived += 1 }
        while !lock.withLock({ open }) { Thread.sleep(forTimeInterval: 0.005) }
    }
    func release() { lock.withLock { open = true } }
    var waiting: Int { lock.withLock { arrived } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@MainActor
@Suite struct StopModelTests {
    private func setup(_ list: [Session] = [session(project), session(other)]) -> (CompanionModel, FakeEngine, CaptureStore) {
        let engine = FakeEngine()
        engine.list = list
        let (m, store, _) = commandModel(engine)
        m.selectTarget(project)
        return (m, engine, store)
    }

    /// A message waiting its turn behind one on its way is cancelled and never sent; the one already handed over
    /// stays delivered; the session itself is never stopped.
    @Test func waitingMessagesAreCancelled() async {
        let (m, engine, _) = setup()
        let gate = Gate()
        engine.reply = { r in
            gate.pass()
            return SendResult(ok: true, sessionId: r.session, route: .background, reply: "done", error: nil, detail: nil)
        }
        let firstSend = Task { await m.sendMessage("great, lets release the new version") }
        await waitUntil { gate.waiting == 1 }
        let secondSend = Task { await m.sendMessage("/model opus") }
        await waitUntil { m.thread.contains { $0.text == "/model opus" && $0.delivery == .queued } }
        #expect(m.canStop)
        await m.interrupt()
        #expect(engine.stopped.isEmpty)
        gate.release()
        await firstSend.value
        await secondSend.value
        #expect(engine.sent.map(\.text) == ["great, lets release the new version"])
        #expect(m.thread.first { $0.text == "/model opus" }?.delivery == .cancelled)
        #expect(m.thread.first { $0.text == "great, lets release the new version" }?.delivery == .delivered)
        #expect(m.status.activity == .idle)
    }

    /// A message in the busy loop (the session was at work) is cancelled; no loop sends it later.
    @Test func aMessageWaitingForABusySessionIsCancelled() async {
        var working = session(project)
        working.state = .working
        let (m, engine, _) = setup([working])
        engine.reply = { r in .failure(.busy(r.session), sessionId: r.session, route: .background) }
        let send = Task { await m.sendMessage("are you done?") }
        await waitUntil { m.thread.first?.delivery == .queued }
        await m.interrupt()
        await send.value
        let tries = engine.sent.count
        #expect(m.thread.first?.delivery == .cancelled)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(engine.sent.count == tries)
        #expect(engine.stopped.isEmpty)
    }

    /// Captures waiting to go are cancelled and deleted; the user's dropped files are not touched.
    @Test func heldCapturesAreCancelledAndDeleted() async throws {
        let (m, engine, store) = setup()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-stop-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hold = Task { await m.captureActiveWindowAndSend() }
        await waitUntil { m.isHoldingCapture }
        await m.dropFiles([file])
        #expect(store.files().count == 1 && m.canStop)
        await m.interrupt()
        await hold.value
        #expect(store.files().isEmpty && engine.sent.isEmpty && !m.isHoldingCapture)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Nothing was going on in the session itself: it is not stopped.
        #expect(engine.stopped.isEmpty)
    }

    /// Nothing waiting: Control-C clears what is typed, like a terminal prompt, and never stops the session, even
    /// one that is at work.
    @Test func anIdlePressClearsTheTextOnly() async {
        let (m, engine, _) = setup()
        m.noteDraft = "half a thought"
        #expect(!m.canStop)
        await m.interrupt()
        #expect(m.noteDraft.isEmpty && engine.stopped.isEmpty)

        var working = session(project)
        working.state = .working
        let (busy, busyEngine, _) = setup([working])
        busy.noteDraft = "next question"
        #expect(!busy.canStop)
        await busy.interrupt()
        #expect(busyEngine.stopped.isEmpty && busy.noteDraft.isEmpty)
    }

    /// A session at work, of any kind, is never stopped or signalled: only what waits in Sidemoon is cancelled.
    @Test func aWorkingSessionIsNeverStopped() async {
        for kind in [SessionKind.background, .interactive, .chat] {
            var working = session(project)
            working.state = .working
            working.kind = kind
            let (m, engine, _) = setup([working])
            await m.interrupt()
            await m.interrupt()
            #expect(engine.stopped.isEmpty)
            #expect(m.currentError == nil)
        }
    }

    /// Another session's waiting message is not touched.
    @Test func anotherSessionsQueueIsUntouched() async {
        let (m, engine, _) = setup()
        let gate = Gate()
        engine.reply = { r in
            if r.session == other { gate.pass() }
            return SendResult(ok: true, sessionId: r.session, route: .background, reply: "ok", error: nil, detail: nil)
        }
        m.selectTarget(other)
        let one = Task { await m.sendMessage("first to other") }
        await waitUntil { gate.waiting == 1 }
        let two = Task { await m.sendMessage("second to other") }
        await waitUntil { m.thread.contains { $0.delivery == .queued } }
        m.selectTarget(project)
        await m.interrupt()
        gate.release()
        await one.value
        await two.value
        #expect(engine.sent.map(\.text) == ["first to other", "second to other"])
        #expect(engine.stopped.isEmpty)
    }

    /// The answer under way was stopped: the message stays delivered, what was said stays, and it says Stopped.
    @Test func aStoppedAnswerIsMarked() async {
        let (m, engine, _) = setup()
        engine.reply = { r in
            var stopped = SendResult.failure(.stopped, sessionId: r.session, route: .headless)
            stopped.reply = "Half an ans"
            return stopped
        }
        await m.sendMessage("a long question")
        #expect(m.thread.map(\.text) == ["a long question", "Half an ans", Design.Copy.Stop.stopped])
        #expect(m.thread.first?.delivery == .delivered && m.currentError == nil && m.status.activity == .idle)
    }

    @Test func controlCAndOnlyControlC() {
        let c = CompanionConstants.InterruptKey.self
        #expect(c.matches(keyCode: c.keyCode, modifiers: [.control]))
        #expect(!c.matches(keyCode: c.keyCode, modifiers: [.command]))
        #expect(!c.matches(keyCode: c.keyCode, modifiers: [.control, .shift]))
        #expect(!c.matches(keyCode: c.keyCode, modifiers: []))
        #expect(!c.matches(keyCode: 0x09, modifiers: [.control]))
    }
}
