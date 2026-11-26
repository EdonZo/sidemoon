import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let target = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

private func idle() -> Session {
    var s = Session(id: target)
    s.cwd = "/tmp/proj"
    s.channelConnected = true
    s.lastEventAt = Date()
    return s
}

/// Fails every send while `failing` is set, the way it is told; succeeds otherwise.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeliveryError?
    var failure: DeliveryError? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
private func setup(failing: DeliveryError?, defaults: UserDefaults? = nil, archive: ThreadArchive? = nil)
    -> (CompanionModel, FakeEngine, CaptureStore, Switch) {
    let engine = FakeEngine()
    engine.list = [idle()]
    let flip = Switch()
    flip.failure = failing
    engine.reply = { r in
        if let e = flip.failure { return .failure(e, sessionId: r.session, route: .channel) }
        return SendResult(ok: true, sessionId: r.session, route: .channel, reply: "Got it.", error: nil, detail: nil)
    }
    let store = scratchStore()
    let model = CompanionModel(engine: engine, capture: FakeCapture(), windowCapture: FakeCapture(), store: store,
                               defaults: defaults ?? UserDefaults(suiteName: "sidemoon-kept-\(UUID().uuidString)")!,
                               archive: archive, sleeper: { _ in await Task.yield() })
    model.startEngine()
    model.selectTarget(target)
    return (model, engine, store, flip)
}

/// Takes `count` captures into one held message, with a dropped file and a note, then sends it.
@MainActor
private func sendThree(_ model: CompanionModel, note: String? = "which is cheaper?", file: URL? = nil) async {
    let task = Task { await model.captureActiveWindowAndSend() }
    while !model.isHoldingCapture { await Task.yield() }
    await model.captureActiveWindowAndSend()
    await model.captureActiveWindowAndSend()
    if let file { await model.dropFiles([file]) }
    if let note { model.noteDraft = note }
    model.submitHeldCapture()
    await task.value
}

private func attachment() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-kept-\(UUID().uuidString).txt")
    try Data("terms".utf8).write(to: url)
    return url
}

@MainActor
@Suite struct KeptCapturesTests {
    /// A failure Retry can fix keeps the captures; Retry sends the same message: the same captures in the same
    /// order, the same file, the same words. Delivered, they are deleted.
    @Test func retrySendsTheSameMessageAgain() async throws {
        let (model, engine, store, flip) = setup(failing: .channel("the channel server did not confirm delivery"))
        let file = try attachment()
        defer { try? FileManager.default.removeItem(at: file) }
        await sendThree(model, file: file)
        let failed = try #require(engine.sent.last)
        #expect(failed.allImagePaths.count == 3)
        #expect(store.files().count == 3)
        let entry = try #require(model.thread.last { $0.role == .you })
        #expect(model.canRetry(entry))
        flip.failure = nil
        await model.retry(entry.id)
        let again = try #require(engine.sent.last)
        #expect(again.allImagePaths == failed.allImagePaths)
        #expect(again.filePaths == [file.path] && again.text == failed.text)
        #expect(store.files().isEmpty)
        #expect(model.thread.filter { $0.role == .you }.count == 1)
        #expect(model.thread.last { $0.role == .you }?.delivery == .delivered)
        #expect(FileManager.default.fileExists(atPath: file.path), "the user's file is never deleted")
    }

    /// Refused in a way sending again cannot fix: deleted at once, no Retry.
    @Test func aRefusalDeletesThemAtOnce() async throws {
        let (model, _, store, _) = setup(failing: .cannotResume(.loginNeeded, messageSaved: false))
        await sendThree(model)
        #expect(store.files().isEmpty)
        let entry = try #require(model.thread.last { $0.role == .you })
        #expect(!model.canRetry(entry))
    }

    /// A reply that is late still means it arrived: deleted.
    @Test func aLateReplyCountsAsDelivered() async {
        let (model, _, store, _) = setup(failing: .replyTimeout)
        await sendThree(model)
        #expect(store.files().isEmpty && model.keptEntries.isEmpty)
    }

    @Test func clearingTheConversationsDeletesThem() async {
        let (model, _, store, _) = setup(failing: .channel("no"))
        await sendThree(model)
        #expect(store.files().count == 3)
        model.clearThreads()
        #expect(store.files().isEmpty && model.keptEntries.isEmpty)
        // Quitting does the same.
        await sendThree(model)
        model.discardKeptCaptures()
        #expect(store.files().isEmpty)
    }

    /// The screenshots are gone by the time Retry is pressed: the typed words go alone, and the thread says so. The
    /// message never refers to the missing images.
    @Test func goneCapturesWithWordsSendTheWordsAndSaySo() async throws {
        let (model, engine, store, flip) = setup(failing: .channel("no"))
        await sendThree(model, note: "which is cheaper?")
        store.files().forEach(store.remove)
        flip.failure = nil
        let entry = try #require(model.thread.last { $0.role == .you })
        await model.retry(entry.id)
        let sent = try #require(engine.sent.last)
        #expect(sent.allImagePaths.isEmpty && sent.text == "which is cheaper?")
        #expect(model.thread.map(\.text).contains(Design.Copy.Captures.goneSentWords))
        let words = try #require(model.thread.firstIndex { $0.text == "which is cheaper?" && $0.delivery == .delivered })
        #expect(model.thread[words + 1].text == Design.Copy.Captures.goneSentWords)
    }

    /// Gone, and no words: nothing is sent, the message says why, and Retry is gone.
    @Test func goneCapturesWithoutWordsSendNothing() async throws {
        let (model, engine, store, flip) = setup(failing: .channel("no"))
        await sendThree(model, note: nil)
        store.files().forEach(store.remove)
        flip.failure = nil
        let before = engine.sent.count
        let entry = try #require(model.thread.last { $0.role == .you })
        await model.retry(entry.id)
        #expect(engine.sent.count == before)
        let after = try #require(model.thread.first { $0.id == entry.id })
        #expect(after.delivery == .refused(Design.Copy.Captures.goneNothingSent) && !model.canRetry(after))
        #expect(model.currentError == .captureMissing(detail: nil))
    }

    /// Only the most recent failed messages keep their captures; older ones lose them and fall back to the rule
    /// for gone captures.
    @Test func onlySoManyFailedMessagesKeepTheirCaptures() async throws {
        let (model, _, store, _) = setup(failing: .channel("no"))
        let limit = CompanionConstants.Capture.maxKeptMessages
        for _ in 0...limit { await sendThree(model) }
        let mine = model.thread.filter { $0.role == .you }
        #expect(mine.count == limit + 1)
        #expect(!model.canRetry(mine[0]) && mine.dropFirst().allSatisfy(model.canRetry))
        #expect(store.files().count == limit * 3)
    }

    /// After a restart nothing is kept: a failed message with screenshots shows as failed, without Retry.
    @Test func afterARestartNoRetryIsPromised() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-kept-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = ThreadArchive(url: folder.appendingPathComponent("threads.json"))
        let defaults = UserDefaults(suiteName: "sidemoon-kept-\(UUID().uuidString)")!
        let (model, _, _, _) = setup(failing: .channel("no"), defaults: defaults, archive: archive)
        await sendThree(model)
        model.flushThreads()
        let (again, _, _, _) = setup(failing: nil, defaults: defaults, archive: archive)
        let restored = try #require(again.thread.last { $0.role == .you })
        #expect(restored.delivery.failureReason != nil && !restored.attachments.isEmpty)
        #expect(!again.canRetry(restored))
    }

    /// The failure the owner hit: an image that is not there. Plain words; the path only behind Details.
    @Test func aMissingScreenshotIsSaidInPlainWords() {
        let path = "/Users/me/Library/Application Support/Sidemoon/Captures/capture-1.png"
        let error = CompanionError.from(.failure(.imageMissing(path)))
        #expect(error.title == Design.Copy.Captures.missingTitle && error.advice == Design.Copy.Captures.missingAdvice)
        #expect(!error.threadNote.contains(path) && !error.advice.contains("/") && !error.canRetry)
        #expect(error.detail?.contains(path) == true)
        let file = CompanionError.from(.failure(.fileMissing("/tmp/gone.txt")))
        #expect(!file.threadNote.contains("/tmp") && file.detail?.contains("/tmp/gone.txt") == true)
    }
}
