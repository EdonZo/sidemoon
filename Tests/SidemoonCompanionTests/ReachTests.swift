import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let first = "11111111-1111-4111-8111-111111111111"
private let second = "22222222-2222-4222-8222-222222222222"
private let third = "33333333-3333-4333-8333-333333333333"

private func session(_ id: String, age: TimeInterval, blocker: ResumeBlocker? = nil, channel: Bool = false,
                     kind: SessionKind = .background, reply: String? = nil) -> Session {
    var s = Session(id: id)
    s.cwd = "/Users/someone/api-server"
    s.kind = kind
    s.channelConnected = channel
    s.blocker = blocker
    s.lastEventAt = Date().addingTimeInterval(-age)
    s.lastReply = reply
    return s
}

private let quickSleeper: Sleeper = { _ in await Task.yield() }

@MainActor
private func model(_ engine: FakeEngine, defaults: UserDefaults? = nil) -> (CompanionModel, UserDefaults) {
    let d = defaults ?? UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
    let store = CaptureStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("sidemoon-reach-\(UUID().uuidString)", isDirectory: true))
    return (CompanionModel(engine: engine, capture: FakeCapture(), windowCapture: FakeCapture(), store: store, defaults: d,
                           sleeper: quickSleeper), d)
}

private func refused(_ blocker: ResumeBlocker, saved: Bool = false) -> @Sendable (SendRequest) -> SendResult {
    { r in
        var result = SendResult.failure(.cannotResume(blocker, messageSaved: saved), sessionId: r.session, route: .background)
        result.detail = "resume exited 1: Claude Code's own words"
        return result
    }
}

@Suite struct UnreachableWordsTests {
    @Test func refusalsBecomePlainErrorsWithDetailsKept() {
        var result = SendResult.failure(.cannotResume(.homeFolder, messageSaved: true), sessionId: first, route: .background)
        result.detail = "resume exited 1: Workspace not trusted."
        let error = CompanionError.from(result)
        guard case let .cannotReach(blocker, saved, _, detail) = error else { Issue.record("expected cannotReach"); return }
        #expect(blocker == .homeFolder)
        #expect(saved)
        #expect(detail?.contains("Workspace not trusted") == true)
        #expect(error.advice.contains(Design.Copy.Unreachable.savedNote))
    }

    @Test func everyCaseIsPlainAndOffersANextStep() {
        for blocker in ResumeBlocker.allCases {
            for saved in [false, true] {
                let e = CompanionError.cannotReach(blocker, messageSaved: saved, detail: "raw")
                #expect(!e.title.isEmpty && !e.advice.isEmpty)
                // No technical words and no raw output in what is shown by default.
                for word in ["background route", "resume", "exited", "transcript", "raw", "cwd"] {
                    #expect(!e.advice.lowercased().contains(word), "\(blocker): \(word)")
                    #expect(!e.title.lowercased().contains(word), "\(blocker): \(word)")
                }
                #expect(e.advice.contains(Design.Copy.Unreachable.savedNote) == saved)
                #expect(e.remedies.contains(.chooseAnotherSession))
                #expect(!e.canRetry)
                #expect(e.detail == "raw")
                #expect(!Design.Copy.Unreachable.reason(blocker).isEmpty)
            }
        }
        #expect(CompanionError.cannotReach(.homeFolder, messageSaved: false, detail: nil).remedies == [.copyResumeCommand, .chooseAnotherSession])
        #expect(CompanionError.cannotReach(.loginNeeded, messageSaved: false, detail: nil).remedies
            == [.runLogin, .copyResumeCommand, .chooseAnotherSession])
        #expect(CompanionError.cannotReach(.noTranscript, messageSaved: false, detail: nil).remedies == [.chooseAnotherSession])
        // Errors from before keep their behaviour: no remedies, and Retry where it was offered.
        #expect(CompanionError.busy.remedies.isEmpty)
        #expect(CompanionError.busy.canRetry)
        #expect(CompanionError.delivery("x").detail == nil)
    }

    @Test func greyedReasonsAreTheShortOnes() {
        #expect(Design.Copy.Unreachable.reason(.homeFolder) == "Started in your home folder")
        #expect(Design.Copy.Unreachable.reason(.loginNeeded) == "Needs a login")
        #expect(Design.Copy.Unreachable.reason(.noTranscript) == "Never answered")
    }
}

@Suite struct ReachabilityTests {
    @Test func blockedBackgroundSessionsAreNotReachable() {
        let rows = SessionList.rows([
            session(first, age: 1, blocker: .homeFolder),
            session(second, age: 2, blocker: .loginNeeded, channel: true),
            session(third, age: 3, kind: .interactive),
        ], showEnded: false)
        #expect(rows.map(\.reachability) == [.blocked(.homeFolder), .reachable, .needsChannel])
        #expect(rows[0].blocker == .homeFolder && !rows[0].reachable)
        // Through the channel it is reached wherever it was started.
        #expect(rows[1].blocker == nil)
    }

    /// A session whose Sidemoon connection Claude Code does not pass on: a background one keeps its background
    /// route and is listed normally; any other is greyed with that reason, not "started without sidemoon-claude".
    @Test func droppedChannelIsDescribedTruthfully() {
        var background = session(first, age: 1)
        background.channelDropped = true
        var terminal = session(second, age: 2, kind: .interactive)
        terminal.channelDropped = true
        let rows = SessionList.rows([background, terminal, session(third, age: 3, kind: .interactive)], showEnded: false)
        #expect(rows.map(\.reachability) == [.reachable, .channelDropped, .needsChannel])
        #expect(background.routes == [.background])
        #expect(Design.Copy.Unreachable.notPickedUpReason != Design.Copy.Unreachable.noChannelReason)
    }

    @Test func messageNotPickedUpIsTypedAndRetried() {
        var result = SendResult.failure(.channelIgnored(fallback: .background), sessionId: first, route: .channel)
        result.detail = "raw"
        let e = CompanionError.from(result)
        #expect(e == .notPickedUp(fallback: .background))
        #expect(e.canRetry)
        #expect(e.remedies.isEmpty)
        #expect(e.title == Design.Copy.Unreachable.notPickedUpTitle)
        #expect(e.advice.hasPrefix(Design.Copy.Unreachable.notPickedUpWhy))
        #expect(e.advice.contains("Retry"))
        // Nothing else reaches it: Retry is still offered, and so is reopening it.
        let stuck = CompanionError.from(SendResult.failure(.channelIgnored(fallback: nil), sessionId: first, route: .channel))
        #expect(stuck == .notPickedUp(fallback: nil) && stuck.canRetry)
        #expect(stuck.remedies == [.copyResumeCommand, .chooseAnotherSession])
        #expect(stuck.advice != e.advice)
        for text in [e.title, e.advice, stuck.advice] {
            for word in ["channel", "mcp", "route", "pid"] { #expect(!text.lowercased().contains(word), "\(text): \(word)") }
        }
    }

    @Test func defaultTargetIsTheMostRecentReachableOne() {
        #expect(SessionList.defaultTarget([
            session(first, age: 1, blocker: .noTranscript),
            session(second, age: 5),
            session(third, age: 2, kind: .interactive),
        ]) == second)
        #expect(SessionList.defaultTarget([session(first, age: 1, blocker: .homeFolder)]) == nil)
        #expect(SessionList.defaultTarget([]) == nil)
    }
}

@MainActor
@Suite struct DefaultTargetTests {
    @Test func picksTheMostRecentReachableSessionWhenNoneIsSaved() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1, blocker: .homeFolder), session(second, age: 9)]
        let (m, d) = model(engine)
        m.startEngine()
        #expect(m.targetId == second)
        // Sidemoon's own pick is not saved as the user's choice.
        #expect(d.string(forKey: CompanionConstants.Defaults.targetSession) == nil)
    }

    @Test func aSavedUnreachableChoiceGivesWayWithoutBeingForgotten() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1, blocker: .loginNeeded), session(second, age: 9)]
        let d = UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
        d.set(first, forKey: CompanionConstants.Defaults.targetSession)
        let (m, _) = model(engine, defaults: d)
        m.startEngine()
        #expect(m.targetId == second)
        #expect(d.string(forKey: CompanionConstants.Defaults.targetSession) == first)
        // The saved one can be reached again: it comes back.
        engine.emit(session(first, age: 0))
        let deadline = Date().addingTimeInterval(2)
        while m.targetId != first, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(m.targetId == first)
    }

    @Test func aSavedReachableChoiceIsKept() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 9)]
        let d = UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
        d.set(second, forKey: CompanionConstants.Defaults.targetSession)
        let (m, _) = model(engine, defaults: d)
        m.startEngine()
        #expect(m.targetId == second)
    }

    @Test func noPickingOnceTheUserHasChosen() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 9)]
        let (m, d) = model(engine)
        m.startEngine()
        m.selectTarget(second)
        #expect(d.string(forKey: CompanionConstants.Defaults.targetSession) == second)
        engine.emit(session(second, age: 0, blocker: .loginNeeded))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(m.targetId == second)
    }

    @Test func choosingAnUnreachableSessionExplainsInsteadOfSwitching() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 9, blocker: .homeFolder)]
        let (m, _) = model(engine)
        m.startEngine()
        m.openSessionList()
        m.pickSession(second)
        #expect(m.targetId == first)
        #expect(m.currentError == .cannotReach(.homeFolder, messageSaved: false, detail: nil))
        #expect(!m.isPickingSession)
        // A reachable one is chosen as before.
        m.dismissError()
        m.pickSession(first)
        #expect(m.currentError == nil)
    }

    @Test func choosingASessionWhoseConnectionIsDroppedExplainsThat() {
        let engine = FakeEngine()
        var dropped = session(second, age: 9, kind: .interactive)
        dropped.channelDropped = true
        engine.list = [session(first, age: 1), dropped]
        let (m, _) = model(engine)
        m.startEngine()
        m.openSessionList()
        m.pickSession(second)
        #expect(m.targetId == first)
        #expect(m.currentError == .notPickedUp(fallback: nil))
    }

    /// A terminal session started with plain `claude` is known only from its hooks: no kind, no channel.
    @Test func aTerminalSessionWithoutTheChannelIsGreyedAndExplained() {
        let engine = FakeEngine()
        var plain = session(second, age: 0, kind: .unknown)
        plain.state = .idle
        var ended = session(third, age: 2, kind: .unknown)
        ended.state = .ended
        engine.list = [session(first, age: 1), plain, ended]
        let (m, _) = model(engine)
        m.showEnded = true
        m.startEngine()
        let rows = Dictionary(uniqueKeysWithValues: m.rows.map { ($0.id, $0) })
        #expect(rows[second]?.reachability == .needsChannel)
        #expect(rows[second]?.reachable == false)
        // Not Sidemoon's automatic pick either.
        #expect(m.targetId == first)
        m.openSessionList()
        m.pickSession(second)
        #expect(m.targetId == first)
        #expect(m.currentError == .needsLauncher)
        #expect(!m.isPickingSession)
        #expect(m.remedies(for: .needsLauncher) == [.copyResumeCommand, .chooseAnotherSession])
        m.terminalCommandInstalled = false
        #expect(m.remedies(for: .needsLauncher) == [.installTerminalCommand, .chooseAnotherSession])
        #expect(CompanionError.needsLauncher.canRetry == false)
        #expect(Design.Copy.Unreachable.noChannelReason == "Started without sidemoon-claude")
        // An ended one is still reached, headless.
        #expect(rows[third]?.reachable == true)
        m.dismissError()
        m.pickSession(third)
        #expect(m.targetId == third)
        #expect(m.currentError == nil)
    }

    @Test func aRefusalAfterSidemoonStoppedTheSessionSaysSo() {
        var result = SendResult.failure(.cannotResume(.untrustedFolder, messageSaved: false, stoppedFirst: true),
                                        sessionId: first, route: .background)
        result.detail = "resume exited 1: Workspace not trusted."
        let error = CompanionError.from(result)
        guard case let .cannotReach(blocker, _, stopped, _) = error else { Issue.record("expected cannotReach"); return }
        #expect(blocker == .untrustedFolder)
        #expect(stopped)
        #expect(error.advice.contains(Design.Copy.Unreachable.stoppedNote))
        #expect(error.detail?.contains("stopped") == true)
        // Refused before anything was stopped: not said.
        let before = CompanionError.from(SendResult.failure(.cannotResume(.homeFolder, messageSaved: false), sessionId: first))
        #expect(!before.advice.contains(Design.Copy.Unreachable.stoppedNote))
    }

    @Test func installIsOfferedUntilTheCommandIsThere() {
        let (m, _) = model(FakeEngine())
        let e = CompanionError.cannotReach(.homeFolder, messageSaved: false, detail: nil)
        #expect(m.remedies(for: e) == [.copyResumeCommand, .chooseAnotherSession])
        m.terminalCommandInstalled = false
        #expect(m.remedies(for: e) == [.installTerminalCommand, .chooseAnotherSession])
        // The command is the installed launcher's path, as the user would type it.
        let paths = SetupPaths.standard
        #expect(m.resumeCommand == "\(paths.display(paths.launcher)) \(Constants.ClaudeCLI.resumeFlag)")
        #expect(m.resumeCommand.hasSuffix("\(Constants.Paths.launcherName) --resume"))
    }
}

@MainActor
@Suite struct RefusedRetryTests {
    @Test func aRefusedMessageIsNotOfferedAgain() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1)]
        engine.reply = refused(.loginNeeded, saved: true)
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(first)
        await m.sendMessage("are you there?")
        let entry = m.thread.last
        #expect(entry?.delivery == .refused(CompanionError.cannotReach(.loginNeeded, messageSaved: true, detail: nil).title))
        #expect(entry?.canRetry == false)
        #expect(m.currentError?.detail?.contains("own words") == true)
        // Even asked for, it does not go again.
        if let id = entry?.id { await m.retry(id) }
        #expect(engine.sent.count == 1)
    }

    @Test func otherFailuresKeepTheirRetry() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1)]
        engine.reply = { r in SendResult.failure(.headless("boom"), sessionId: r.session, route: .headless) }
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(first)
        await m.sendMessage("are you there?")
        #expect(m.thread.last?.canRetry == true)
    }

    @Test func refusedSurvivesASaveAndLoad() throws {
        var threads = Threads()
        threads.append(ThreadEntry(role: .you, text: "hi", delivery: .refused("no")), to: first)
        let back = try JSONDecoder().decode(Threads.self, from: JSONEncoder().encode(threads))
        #expect(back.thread(for: first).first?.delivery == .refused("no"))
        #expect(back.thread(for: first).first?.delivery.failureReason == "no")
    }
}

@MainActor
@Suite struct FirstRunTests {
    @Test func startOpensTheBubbleWithTheGuideAndAsksForAttention() {
        let d = UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
        d.set(true, forKey: CompanionConstants.Defaults.guideClosed)
        let (m, _) = model(FakeEngine(), defaults: d)
        m.toggleSettings()
        let before = m.attentionRequests
        m.presentAfterSetup()
        #expect(m.isExpanded)
        #expect(m.showsGuide)
        #expect(!m.isShowingSettings)
        #expect(m.attentionRequests == before + 1)
    }

    @Test func recordingVisibilityIsOffByDefaultAndRemembered() {
        let d = UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
        let (m, _) = model(FakeEngine(), defaults: d)
        #expect(!m.visibleInRecordings)
        m.visibleInRecordings = true
        let (again, _) = model(FakeEngine(), defaults: d)
        #expect(again.visibleInRecordings)
        #expect(CompanionConstants.Defaults.savedKeys.contains(CompanionConstants.Defaults.visibleInRecordings))
    }
}

@MainActor
@Suite struct GuideTests {
    @Test func showsOnceSetupIsFinishedAndTicksAsTheUserGoes() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1, channel: true)]
        let (m, d) = model(engine)
        m.setupPending = true
        #expect(m.isGuideOpen)
        #expect(!m.showsGuide)
        m.setupPending = false
        #expect(m.showsGuide)
        m.startEngine()
        // Sidemoon's own pick does not count as the user's.
        #expect(m.guide == GuideProgress())
        m.selectTarget(first)
        #expect(m.guide.pickedSession)

        // The test message is not the user's reply.
        await m.sendTestMessage()
        #expect(engine.sent.last?.text?.hasPrefix(CompanionConstants.Guide.testMessage) == true)
        #expect(!m.guide.replied)

        await m.captureActiveWindowAndSend()
        #expect(m.guide.sentCapture)
        #expect(!m.guide.isComplete)
        #expect(!d.bool(forKey: CompanionConstants.Defaults.guideClosed))

        await m.sendMessage("thanks, and the next step?")
        #expect(m.guide.replied)
        #expect(m.guide.isComplete)
        // Finished: remembered, though it stays on screen to show so until closed.
        #expect(d.bool(forKey: CompanionConstants.Defaults.guideClosed))
        #expect(m.showsGuide)
        m.dismissGuide()
        #expect(!m.showsGuide)
    }

    @Test func aFailedCaptureDoesNotTick() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1, channel: true)]
        engine.reply = { r in SendResult.failure(.headless("boom"), sessionId: r.session, route: .headless) }
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(first)
        await m.captureActiveWindowAndSend()
        #expect(!m.guide.sentCapture)
    }

    @Test func dismissingIsRememberedAndSettingsBringItBack() {
        let d = UserDefaults(suiteName: "sidemoon-reach-\(UUID().uuidString)")!
        let (m, _) = model(FakeEngine(), defaults: d)
        m.dismissGuide()
        #expect(d.bool(forKey: CompanionConstants.Defaults.guideClosed))
        let (again, _) = model(FakeEngine(), defaults: d)
        #expect(!again.isGuideOpen)
        #expect(!again.showsGuide)
        again.setupPending = true
        again.showGuide()
        // Asked for, it shows even while Setup is unfinished.
        #expect(again.showsGuide)
        #expect(CompanionConstants.Defaults.savedKeys.contains(CompanionConstants.Defaults.guideClosed))
    }
}
