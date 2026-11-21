import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let session = "1c9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e02"

/// Counts calls across threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@MainActor
private func makeThreadModel(_ engine: FakeEngine, sleeper: @escaping Sleeper = { _ in await Task.yield() }) -> CompanionModel {
    var s = Session(id: session)
    s.cwd = "/tmp/proj"
    s.channelConnected = true
    s.lastEventAt = Date()
    engine.list = [s]
    let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
    let store = CaptureStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("sidemoon-thread-\(UUID().uuidString)", isDirectory: true))
    let model = CompanionModel(engine: engine, capture: FakeCapture(), windowCapture: FakeCapture(), store: store,
                               defaults: defaults, sleeper: sleeper)
    model.startEngine()
    model.selectTarget(session)
    return model
}

private func temporaryFile(named name: String, contents: String = "hello") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-drop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

@MainActor
@Suite struct ThreadTests {
    @Test func typedMessageIsSentAndBothSidesJoinTheThread() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        await model.sendMessage("  which button do I press?  ")
        #expect(engine.sent.count == 1)
        #expect(engine.sent[0].text == "which button do I press?")
        #expect(engine.sent[0].imagePath == nil)
        #expect(engine.sent[0].filePaths.isEmpty)
        let thread = model.thread
        #expect(thread.map(\.role) == [.you, .session])
        #expect(thread[0].text == "which button do I press?")
        #expect(thread[0].delivery == .delivered)
        #expect(thread[1].text == "next: click Save")
    }

    @Test func emptyMessageSendsNothing() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        await model.sendMessage("   \n ")
        #expect(engine.sent.isEmpty)
        #expect(model.thread.isEmpty)
    }

    @Test func droppedFileIsSentUntouchedAfterTheGracePeriod() async throws {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        let file = try temporaryFile(named: "notes.txt")
        await model.dropFiles([file])
        #expect(engine.sent.count == 1)
        #expect(engine.sent[0].filePaths == [file.path])
        #expect(engine.sent[0].text == CompanionConstants.Messages.defaultFilesText)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(model.thread.first?.attachments == ["notes.txt"])
        #expect(model.thread.first?.text == "")
        #expect(model.heldFiles.isEmpty)
        #expect(!model.isEditingNote)
    }

    @Test func foldersAreRefusedInPlainWords() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        await model.dropFiles([FileManager.default.temporaryDirectory])
        #expect(engine.sent.isEmpty)
        #expect(model.currentError == .delivery(CompanionConstants.Messages.foldersNotSent))
    }

    @Test func failedSendIsMarkedInTheThread() async {
        let engine = FakeEngine()
        engine.reply = { r in
            var result = SendResult(ok: false, sessionId: r.session, route: nil, reply: nil, error: "busy", detail: nil)
            result.failure = .busy(r.session)
            return result
        }
        let model = makeThreadModel(engine)
        await model.sendMessage("are you there?")
        #expect(model.thread.count == 1)
        #expect(model.thread[0].delivery == .failed(CompanionError.busy.title))
        #expect(model.currentError == .busy)
    }

    @Test func messageToABusySessionWaitsAndGoesOutWhenItsTurnEnds() async {
        let engine = FakeEngine()
        let calls = Counter()
        engine.reply = { r in
            if calls.next() == 1 {
                var busy = SendResult(ok: false, sessionId: r.session, route: nil, reply: nil, error: "busy", detail: nil)
                busy.failure = .busy(r.session)
                return busy
            }
            return SendResult(ok: true, sessionId: r.session, route: .background, reply: "done", error: nil, detail: nil)
        }
        let model = makeThreadModel(engine)
        await model.sendMessage("when you are free")
        #expect(engine.sent.count == 2)
        #expect(model.currentError == nil)
        #expect(model.thread.map(\.delivery) == [.delivered, .delivered])
        #expect(model.thread.last?.text == "done")
    }

    @Test func buttonCaptureWaitsAndCanBeTakenBack() async {
        let engine = FakeEngine()
        let manual = ManualSleeper()
        let model = makeThreadModel(engine, sleeper: manual.sleeper)
        let capture = Task { await model.captureAndSend(hold: true) }
        let deadline = Date().addingTimeInterval(2)
        while !model.isHoldingCapture, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.isHoldingCapture)
        #expect(model.heldCapture != nil)
        model.cancelNote()
        manual.releaseAll()
        await capture.value
        #expect(engine.sent.isEmpty)
        #expect(model.thread.isEmpty)
        #expect(!model.isHoldingCapture)
        #expect(model.indicator == .idle)
    }

    @Test func takingBackTheLastWaitingFileCancelsTheSend() async throws {
        let engine = FakeEngine()
        let manual = ManualSleeper()
        let model = makeThreadModel(engine, sleeper: manual.sleeper)
        let one = try temporaryFile(named: "one.txt"), two = try temporaryFile(named: "two.txt")
        let drop = Task { await model.dropFiles([one, two]) }
        let deadline = Date().addingTimeInterval(2)
        while model.heldFiles.count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        model.removeHeldFile(one)
        #expect(model.heldFiles == [two])
        model.removeHeldFile(two)
        manual.releaseAll()
        await drop.value
        #expect(engine.sent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: one.path))
        #expect(FileManager.default.fileExists(atPath: two.path))
    }

    @Test func sizeSettingIsSteppedClampedAndRemembered() {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        #expect(model.zoom == Design.Zoom.standard)
        model.zoomIn()
        #expect(abs(model.zoom - (Design.Zoom.standard + Design.Zoom.step)) < 0.0001)
        model.setZoom(9)
        #expect(model.zoom == Design.Zoom.maximum)
        model.setZoom(0)
        #expect(model.zoom == Design.Zoom.minimum)
        model.resetZoom()
        #expect(model.zoom == Design.Zoom.standard)
        #expect(Design.zoom == 1)
    }

    @Test func shortRepliesAddANoteWithoutChangingTheUsersWords() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        #expect(model.shortReplies)
        await model.sendMessage("what next?")
        #expect(engine.sent[0].text == "what next?")
        #expect(engine.sent[0].styleNote == CompanionConstants.Messages.replyStyleNote)
        #expect(model.thread[0].text == "what next?")
        // After the first, messages carry only the short tag, until the full note is due again.
        for _ in 1..<CompanionConstants.Messages.replyStyleNoteEvery { await model.sendMessage("and then?") }
        #expect(engine.sent[1].styleNote == CompanionConstants.Messages.replyStyleTag)
        #expect(engine.sent[CompanionConstants.Messages.replyStyleNoteEvery - 1].styleNote == CompanionConstants.Messages.replyStyleTag)
        await model.sendMessage("still there?")
        #expect(engine.sent[CompanionConstants.Messages.replyStyleNoteEvery].styleNote == CompanionConstants.Messages.replyStyleNote)
        model.shortReplies = false
        await model.sendMessage("plain")
        #expect(engine.sent.last?.styleNote == nil)
    }

    @Test func anAnswerFromAnotherSessionIsMarkedUntilItIsOpened() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        var other = Session(id: "3e9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e04")
        other.lastReply = "finished the build"
        other.lastReplyAt = Date()
        model.apply(other)
        model.apply(other)
        #expect(model.unreadSessions == [other.id])
        #expect(model.threads.thread(for: other.id).count == 1)
        model.selectTarget(other.id)
        #expect(model.unreadSessions.isEmpty)
    }

    @Test func arrowKeysLeaveTheSessionMoveThroughTheListAndEnterAnother() {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        var older = Session(id: "4f9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e05")
        older.lastEventAt = Date().addingTimeInterval(-600)
        var oldest = Session(id: "5a9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e06")
        oldest.lastEventAt = Date().addingTimeInterval(-1200)
        model.apply(older)
        model.apply(oldest)
        model.openBubble()

        // Keys other than Left belong to the text field while the thread is showing.
        #expect(!model.navigate(.right))
        #expect(!model.navigate(.up))
        #expect(!model.navigate(.enter))

        #expect(model.navigate(.left))
        #expect(model.isPickingSession)
        #expect(model.highlightedSession == session)

        #expect(model.navigate(.down))
        #expect(model.highlightedSession == older.id)
        #expect(model.navigate(.down))
        #expect(model.navigate(.down))
        #expect(model.highlightedSession == oldest.id)
        #expect(model.navigate(.up))
        #expect(model.highlightedSession == older.id)

        #expect(model.navigate(.right))
        #expect(!model.isPickingSession)
        #expect(model.targetId == older.id)
    }

    @Test func leftArrowStaysWithTheTextWhileSomethingIsTyped() {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        model.openBubble()
        model.noteDraft = "half a sentence"
        #expect(!model.navigate(.left))
        #expect(!model.isPickingSession)
        model.noteDraft = ""
        #expect(model.navigate(.left))
        #expect(model.navigate(.escape))
        #expect(!model.isPickingSession)
        #expect(model.targetId == session)
    }

    @Test func aMessageStillTravellingDoesNotBlockAnotherSession() async {
        let engine = FakeEngine()
        let other = "6b9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e07"
        // The first session takes a long time to answer; the other answers at once.
        let slow = DispatchSemaphore(value: 0)
        engine.reply = { r in
            if r.session == session { slow.wait() }
            return SendResult(ok: true, sessionId: r.session, route: .channel, reply: "answer for \(r.text ?? "")", error: nil, detail: nil)
        }
        let model = makeThreadModel(engine)
        var second = Session(id: other)
        second.channelConnected = true
        model.apply(second)

        model.noteDraft = "first question"
        model.submitDraft()
        #expect(model.noteDraft.isEmpty)
        model.selectTarget(other)
        await model.sendMessage("second question")

        // The second session got its message and answered while the first is still waiting.
        #expect(model.thread.map(\.text) == ["second question", "answer for second question"])
        #expect(engine.sent.map(\.session).contains(other))
        slow.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.threads.thread(for: session).count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.threads.thread(for: session).map(\.text) == ["first question", "answer for first question"])
        #expect(model.unreadSessions.contains(session))
    }

    @Test func aDraftThatCannotBeSentStaysInTheField() {
        let engine = FakeEngine()
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
        let model = CompanionModel(engine: engine, capture: FakeCapture(), defaults: defaults)
        model.startEngine()
        model.noteDraft = "nobody to send this to"
        model.submitDraft()
        #expect(model.noteDraft == "nobody to send this to")
        #expect(model.currentError == .noTarget)
        #expect(engine.sent.isEmpty)
    }

    @Test func conversationsSurviveARestartAndCanBeCleared() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = ThreadArchive(url: folder.appendingPathComponent("threads.json"))
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!

        // Nothing saved yet: a first run starts empty and does not fail.
        #expect(archive.load() == nil)

        var saved = Threads()
        saved.append(ThreadEntry(role: .you, text: "what next?"), to: "s1")
        saved.appendReply("Open the DNS page.", to: "s1")
        let waiting = saved.append(ThreadEntry(role: .you, text: "and then?", delivery: .queued), to: "s1")
        archive.save(saved)
        let mode = (try? FileManager.default.attributesOfItem(atPath: archive.url.path))?[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        // A new run shows the same conversation; what had not gone out is marked, not left "sending" for ever.
        let model = CompanionModel(engine: FakeEngine(), capture: FakeCapture(), defaults: defaults, archive: archive)
        let restored = model.threads.thread(for: "s1")
        #expect(restored.map(\.text) == ["what next?", "Open the DNS page.", "and then?"])
        #expect(restored.first { $0.id == waiting }?.delivery == .failed(Design.Copy.interruptedByRestart))

        // Clearing empties the screen and the file.
        model.clearThreads()
        #expect(model.threads.isEmpty)
        #expect(archive.load()?.isEmpty == true)
    }

    @Test func aMessageThatDidNotGoOutCanBeSentAgain() async {
        let engine = FakeEngine()
        let session = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = ThreadArchive(url: folder.appendingPathComponent("threads.json"))
        var saved = Threads()
        let stuck = saved.append(ThreadEntry(role: .you, text: "post only this one", delivery: .queued), to: session)
        let shot = saved.append(ThreadEntry(role: .you, text: "", attachments: ["Screen capture"], delivery: .queued), to: session)
        archive.save(saved)
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
        defaults.set(session, forKey: CompanionConstants.Defaults.targetSession)

        let model = CompanionModel(engine: engine, capture: FakeCapture(), defaults: defaults, archive: archive)
        model.startEngine()
        let restored = model.threads.thread(for: session)
        // The typed message can be retried; the screenshot is gone from disk, so it cannot.
        #expect(restored.first { $0.id == stuck }?.canRetry == true)
        #expect(restored.first { $0.id == shot }?.canRetry == false)

        await model.retry(shot)
        #expect(engine.sent.isEmpty)
        await model.retry(stuck)
        #expect(engine.sent.map(\.text) == ["post only this one"])
        // The failed copy is replaced, not left beside the new one.
        let after = model.threads.thread(for: session).filter { $0.text == "post only this one" }
        #expect(after.count == 1)
        #expect(after.first?.canRetry == false)
    }

    @Test func onlyTheMostRecentSessionsAreKeptOnDisk() {
        var threads = Threads()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<5 {
            threads.append(ThreadEntry(role: .you, text: "m\(index)", date: start.addingTimeInterval(Double(index))), to: "s\(index)")
        }
        threads.keepMostRecent(2)
        #expect(threads.thread(for: "s4").count == 1)
        #expect(threads.thread(for: "s3").count == 1)
        #expect(threads.thread(for: "s0").isEmpty)
    }

    @Test func openAtLoginFollowsTheSystemAndIsHiddenWithoutIt() {
        final class FakeLoginItem: LoginItem {
            var isEnabled = false
            var refuses = false
            func setEnabled(_ enabled: Bool) throws {
                if refuses { throw CocoaError(.featureUnsupported) }
                isEnabled = enabled
            }
        }
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
        let model = CompanionModel(engine: FakeEngine(), capture: FakeCapture(), defaults: defaults)
        // A bare executable has nothing to register, so the setting is not offered.
        #expect(!model.canOpenAtLogin)
        model.setOpensAtLogin(true)
        #expect(!model.opensAtLogin)

        let item = FakeLoginItem()
        model.loginItem = item
        #expect(model.canOpenAtLogin)
        model.setOpensAtLogin(true)
        #expect(item.isEnabled)
        #expect(model.opensAtLogin)
        // Turned off in System Settings: the switch shows what is really set.
        item.isEnabled = false
        model.refreshOpensAtLogin()
        #expect(!model.opensAtLogin)
        // A refusal leaves the switch where the system has it.
        item.refuses = true
        model.setOpensAtLogin(true)
        #expect(!model.opensAtLogin)
    }

    @Test func updatesFollowTheUpdaterAndAreHiddenWithoutIt() {
        final class FakeUpdater: Updater {
            var automaticallyChecks = true
            var checks = 0
            func setAutomaticallyChecks(_ on: Bool) { automaticallyChecks = on }
            func checkForUpdates() { checks += 1 }
        }
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
        let model = CompanionModel(engine: FakeEngine(), capture: FakeCapture(), defaults: defaults)
        // No public key yet: no updater, so nothing is offered and nothing happens.
        #expect(!model.canUpdate)
        model.checkForUpdates()
        model.setChecksForUpdates(true)
        #expect(!model.checksForUpdates)

        let updater = FakeUpdater()
        model.updater = updater
        #expect(model.canUpdate)
        #expect(model.checksForUpdates)
        model.setChecksForUpdates(false)
        #expect(!updater.automaticallyChecks)
        #expect(!model.checksForUpdates)
        model.checkForUpdates()
        #expect(updater.checks == 1)
    }

    @Test func themeAndWindowChoiceAreRememberedAndSettingsYieldToTheList() {
        let engine = FakeEngine()
        let defaults = UserDefaults(suiteName: "sidemoon-thread-\(UUID().uuidString)")!
        let model = CompanionModel(engine: engine, capture: FakeCapture(), defaults: defaults)
        #expect(model.theme == .paper)
        #expect(!model.isLarge)
        model.setTheme(.terminal)
        model.setLarge(true)
        #expect(Design.Bubble.width > 400)
        let again = CompanionModel(engine: engine, capture: FakeCapture(), defaults: defaults)
        #expect(again.theme == .terminal)
        #expect(again.isLarge)

        again.toggleSettings()
        #expect(again.isShowingSettings)
        again.openSessionList()
        #expect(!again.isShowingSettings)
        again.toggleSettings()
        #expect(!again.isPickingSession)
        #expect(again.navigate(.escape))
        #expect(!again.isShowingSettings)

        // Leave the shared tokens as other tests expect them.
        again.setTheme(.paper)
        again.setLarge(false)
    }

    @Test func captureAppearsInTheThreadAsAnAttachment() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        await model.captureAndSend()
        #expect(model.thread.first?.attachments == [CompanionConstants.Messages.captureAttachmentName])
        #expect(model.thread.first?.text == "")
        #expect(model.thread.last?.role == .session)
    }

    @Test func repliesFromOtherSessionsWaitInTheirOwnThread() async {
        let engine = FakeEngine()
        let model = makeThreadModel(engine)
        var other = Session(id: "2d9e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e03")
        other.lastReply = "from the other one"
        model.apply(other)
        #expect(model.thread.isEmpty)
        model.selectTarget(other.id)
        #expect(model.thread.map(\.text) == ["from the other one"])
    }
}

@Suite struct ThreadsTests {
    @Test func aReplyIsOnlyDroppedWhenItIsAlreadyTheNewestEntry() {
        var threads = Threads()
        threads.appendReply("Done.", to: "s")
        threads.appendReply("Done.", to: "s")
        #expect(threads.thread(for: "s").count == 1)
        threads.append(ThreadEntry(role: .you, text: "again"), to: "s")
        threads.appendReply("Done.", to: "s")
        #expect(threads.thread(for: "s").map(\.text) == ["Done.", "again", "Done."])
    }

    @Test func anOldReplySeenAgainIsNotRepeatedUnderANewMessage() {
        var threads = Threads()
        let first = Date(timeIntervalSince1970: 100), second = Date(timeIntervalSince1970: 200), third = Date(timeIntervalSince1970: 300)
        threads.appendReply("first answer", to: "s", stamp: first)
        threads.append(ThreadEntry(role: .you, text: "my reply"), to: "s")
        // A stopped and resumed session announces its previous reply again.
        threads.appendReply("first answer", to: "s", stamp: first)
        #expect(threads.thread(for: "s").map(\.text) == ["first answer", "my reply"])
        threads.appendReply("second answer", to: "s", stamp: second)
        #expect(threads.thread(for: "s").map(\.text) == ["first answer", "my reply", "second answer"])
        // The same words in a later turn are a new reply.
        threads.append(ThreadEntry(role: .you, text: "again"), to: "s")
        threads.appendReply("second answer", to: "s", stamp: third)
        #expect(threads.thread(for: "s").count == 5)
    }

    @Test func aReplyRecordedBySendIsNotRepeatedWhenItsHookArrives() {
        var threads = Threads()
        let stamp = Date(timeIntervalSince1970: 100)
        threads.append(ThreadEntry(role: .you, text: "question"), to: "s")
        threads.appendReply("answer", to: "s")
        threads.append(ThreadEntry(role: .you, text: "next question"), to: "s")
        // The hook for the first answer arrives late, after the user already sent something else.
        threads.appendReply("answer", to: "s", stamp: stamp)
        threads.appendReply("answer", to: "s", stamp: stamp)
        #expect(threads.thread(for: "s").map(\.text) == ["question", "answer", "next question"])
    }

    @Test func fullerTextForTheSameTurnReplacesTheShorterOne() {
        var threads = Threads()
        let stamp = Date(timeIntervalSince1970: 100)
        threads.appendReply("last line", to: "s", stamp: stamp)
        threads.appendReply("first line\n\nlast line", to: "s", stamp: stamp)
        #expect(threads.thread(for: "s").map(\.text) == ["first line\n\nlast line"])
    }

    @Test func oldEntriesFallOffPastTheLimit() {
        var threads = Threads()
        for i in 0..<(CompanionConstants.Thread.maxEntries + 5) { threads.append(ThreadEntry(role: .you, text: "\(i)"), to: "s") }
        let thread = threads.thread(for: "s")
        #expect(thread.count == CompanionConstants.Thread.maxEntries)
        #expect(thread.first?.text == "5")
    }

    @Test func messageTextNamesEveryFile() {
        let text = ImageFile.messageText(text: "look", imagePath: nil, filePaths: ["/a/one.txt", "/a/two.pdf"])
        #expect(text.contains("look"))
        #expect(text.contains("/a/one.txt"))
        #expect(text.contains("/a/two.pdf"))
    }
}
