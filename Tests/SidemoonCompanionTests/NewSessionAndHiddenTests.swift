import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let first = "11111111-1111-4111-8111-111111111111"
private let second = "22222222-2222-4222-8222-222222222222"
private let third = "33333333-3333-4333-8333-333333333333"
private let fresh = "44444444-4444-4444-8444-444444444444"
private let home = "/Users/someone"

private func session(_ id: String, age: TimeInterval, cwd: String = "/Users/someone/api-server",
                     kind: SessionKind = .background, state: SessionState = .idle, reply: String? = nil) -> Session {
    var s = Session(id: id)
    s.cwd = cwd
    s.kind = kind
    s.state = state
    s.lastEventAt = Date().addingTimeInterval(-age)
    s.lastReply = reply
    return s
}

private let quickSleeper: Sleeper = { _ in await Task.yield() }

@MainActor
private func model(_ engine: FakeEngine, defaults: UserDefaults? = nil, sleeper: @escaping Sleeper = quickSleeper,
                   checks: PathChecks = .everythingExists) -> (CompanionModel, UserDefaults) {
    let d = defaults ?? UserDefaults(suiteName: "sidemoon-new-\(UUID().uuidString)")!
    let store = CaptureStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("sidemoon-new-\(UUID().uuidString)", isDirectory: true))
    let m = CompanionModel(engine: engine, capture: FakeCapture(), windowCapture: FakeCapture(), store: store, defaults: d,
                           sleeper: sleeper, pathChecks: checks)
    m.homeFolder = home
    return (m, d)
}

@MainActor
private func settle(until condition: () -> Bool, timeout: TimeInterval = 2) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

// MARK: - Pure logic

@Suite struct RecentFoldersTests {
    @Test func mostRecentFirstOnceEachExistingAndNeverHome() {
        let sessions = [
            session(first, age: 30, cwd: "/p/old"),
            session(second, age: 1, cwd: "/p/new/"),
            session(third, age: 5, cwd: home),
            session(fresh, age: 10, cwd: "/p/new"),
            session("55555555-5555-4555-8555-555555555555", age: 2, cwd: "/p/gone"),
        ]
        let checks = PathChecks(folderExists: { $0 != "/p/gone" }, isExecutable: { _ in true })
        #expect(RecentFolders.list(sessions: sessions, lastUsed: nil, home: home, checks: checks) == ["/p/new/", "/p/old"])
        // The folder used last goes first; a gone or home one is never offered.
        #expect(RecentFolders.list(sessions: sessions, lastUsed: "/p/old", home: home, checks: checks) == ["/p/old", "/p/new/"])
        #expect(RecentFolders.list(sessions: sessions, lastUsed: "/p/gone", home: home, checks: checks) == ["/p/new/", "/p/old"])
        #expect(RecentFolders.list(sessions: sessions, lastUsed: home + "/", home: home, checks: checks) == ["/p/new/", "/p/old"])
        #expect(RecentFolders.list(sessions: sessions, lastUsed: nil, home: home, checks: checks, limit: 1) == ["/p/new/"])
        let many = (0..<20).map { session(String(format: "%08d-0000-4000-8000-000000000000", $0), age: Double($0), cwd: "/p/\($0)") }
        #expect(RecentFolders.list(sessions: many, lastUsed: nil, home: home, checks: .everythingExists).count
                == CompanionConstants.NewSession.recentFolders)
    }

    @Test func theHomeFolderIsAllowedWithACautionUnlessThisMacRefusedIt() {
        let checks = PathChecks(folderExists: { $0 != "/p/gone" }, isExecutable: { _ in true })
        #expect(FolderNote.of(nil, home: home, homeRefused: true, checks: checks) == nil)
        #expect(FolderNote.of("/p/a", home: home, homeRefused: true, checks: checks) == nil)
        #expect(FolderNote.of(home, home: home, homeRefused: false, checks: checks) == .homeCaution)
        #expect(FolderNote.of(home + "/", home: home, homeRefused: true, checks: checks) == .homeRefused)
        #expect(FolderNote.of("/p/gone", home: home, homeRefused: false, checks: checks) == .missing)
        #expect(!FolderNote.homeCaution.blocksStart && FolderNote.homeRefused.blocksStart && FolderNote.missing.blocksStart)
    }
}

@Suite struct NewSessionFormTests {
    @Test func startsOnlyWithAFolderAndAMessageAndOnlyOnce() {
        var form = NewSessionForm()
        form.inFolder = true
        #expect(!form.canStart(note: nil))
        form.message = "  look at the tests  "
        #expect(!form.canStart(note: nil))
        form.choose("/p/a")
        #expect(form.canStart(note: nil) && form.canStart(note: .homeCaution))
        #expect(!form.canStart(note: .homeRefused) && !form.canStart(note: .missing))
        let refusedStart = form.begin(note: .homeRefused)
        let firstStart = form.begin(note: nil)
        let secondStart = form.begin(note: nil)
        #expect(!refusedStart && firstStart && !secondStart)
        #expect(form.isStarting && !form.canStart(note: nil))
        // The folder cannot change while it starts.
        form.choose("/p/b")
        #expect(form.folder == "/p/a")
        form.fail(.untrustedFolder, detail: "Workspace not trusted")
        #expect(form.problem == .untrustedFolder && form.problemDetail == "Workspace not trusted")
        #expect(form.trimmedMessage == "look at the tests")
        // Another folder: the old error no longer applies.
        form.choose("/p/b")
        #expect(form.problem == nil && form.phase == .editing)
    }

    /// Without a name Claude Code names the session after its whole first prompt, Sidemoon's note included.
    @Test func aNewSessionIsNamedAfterItsFolder() {
        #expect(NewSessionForm.defaultName(for: "/Users/me/Projects/reading-notes") == "reading-notes")
        #expect(NewSessionForm.defaultName(for: "/Users/me/Projects/reading-notes/") == "reading-notes")
        #expect(NewSessionForm.defaultName(for: "/p/my folder") == "my folder")
        #expect(NewSessionForm.defaultName(for: "/") == nil)
        #expect(NewSessionForm.defaultName(for: "") == nil)
    }

    @Test func engineErrorsBecomePlainProblems() {
        #expect(NewSessionProblem.from(.refused(.untrustedFolder)) == .untrustedFolder)
        #expect(NewSessionProblem.from(.refused(.loginNeeded)) == .loginNeeded)
        #expect(NewSessionProblem.from(.refused(.homeFolder)) == .homeFolderRefused)
        #expect(NewSessionProblem.from(.homeFolderRefused) == .homeFolderRefused)
        #expect(NewSessionProblem.from(.claudeNotFound) == .claudeNotFound)
        #expect(NewSessionProblem.from(.folderMissing("/x")) == .folderMissing)
        #expect(NewSessionProblem.from(.timedOut) == .timedOut)
        #expect(NewSessionProblem.from(.notConfirmed) == .notConfirmed)
        #expect(NewSessionProblem.from(.failed(status: 3)) == .failed)
        let all: [NewSessionProblem] = [.folderMissing, .homeFolderRefused, .claudeNotFound, .untrustedFolder, .loginNeeded,
                                        .timedOut, .notConfirmed, .failed]
        for p in all {
            #expect(!p.title.isEmpty && !p.advice.isEmpty)
            for word in ["--bg", "exited", "stderr", "cwd", "status"] { #expect(!p.advice.lowercased().contains(word), "\(p): \(word)") }
        }
    }
}

@Suite struct HiddenSessionsTests {
    @Test func boundedAndForgottenOnlyAfterTheGracePeriod() {
        var hidden = HiddenSessions()
        let start = Date(timeIntervalSince1970: 1_000_000)
        hidden.hide(first, at: start)
        hidden.hide(second, at: start)
        let c = CompanionConstants.Hidden.self
        // Unknown for a while: kept.
        let early = hidden.prune(known: [], now: start.addingTimeInterval(c.forgetAfter / 2))
        #expect(!early)
        // Seen again: its time is written down, so it is kept for another whole period.
        let seen = hidden.prune(known: [first], now: start.addingTimeInterval(c.forgetAfter - 1))
        let late = hidden.prune(known: [], now: start.addingTimeInterval(c.forgetAfter + 1))
        #expect(seen && late)
        #expect(hidden.ids == [first])
        var many = HiddenSessions()
        for i in 0..<(c.maxEntries + 5) { many.hide("id-\(i)", at: start.addingTimeInterval(Double(i))) }
        #expect(many.count == c.maxEntries && !many.contains("id-0") && many.contains("id-\(c.maxEntries + 4)"))
        // Saved and read back.
        #expect(HiddenSessions(data: hidden.data) == hidden)
        #expect(HiddenSessions(data: Data("junk".utf8)).isEmpty)
    }

    @Test func comesBackOnlyForAnAnswerOrANeedForInput() {
        let idle = session(first, age: 1)
        var asking = idle
        asking.state = .needsInput
        var working = idle
        working.state = .working
        #expect(HiddenSessions.revealsItself(before: idle, after: idle, newAnswer: true))
        #expect(HiddenSessions.revealsItself(before: idle, after: asking, newAnswer: false))
        #expect(HiddenSessions.revealsItself(before: nil, after: asking, newAnswer: false))
        // Still asking, as it was when it was hidden; or just listed again, working or not.
        #expect(!HiddenSessions.revealsItself(before: asking, after: asking, newAnswer: false))
        #expect(!HiddenSessions.revealsItself(before: idle, after: working, newAnswer: false))
        #expect(!HiddenSessions.revealsItself(before: idle, after: idle, newAnswer: false))
    }

    @Test func rowsLeaveHiddenOutUnlessAskedAndTheDefaultNeverPicksOne() {
        let list = [session(first, age: 1), session(second, age: 5)]
        #expect(SessionList.rows(list, showEnded: false, hidden: [first]).map(\.id) == [second])
        let shown = SessionList.rows(list, showEnded: false, hidden: [first], showHidden: true)
        #expect(shown.map(\.id) == [first, second] && shown[0].hidden && !shown[1].hidden && shown[0].isBackground)
        #expect(SessionList.defaultTarget(list, hidden: [first]) == second)
        #expect(SessionList.defaultTarget(list, hidden: [first, second]) == nil)
    }
}

@Suite struct AttachTests {
    @Test func aBackgroundSessionIsAttachedToNotResumed() {
        let script = TerminalReopen.attachScript(shortId: "1a2b3c4d", claude: "/Users/me/.local/bin/claude")
        #expect(script == "#!/bin/sh\nexec '/Users/me/.local/bin/claude' 'attach' '1a2b3c4d'\n"
                || script == "#!/bin/sh\nexec '/Users/me/.local/bin/claude' attach '1a2b3c4d'\n")
        #expect(!TerminalReopen.attachScript(shortId: "x; rm -rf ~", claude: "claude").contains("rm"))
        let checks = PathChecks(folderExists: { $0 != "/gone" }, isExecutable: { _ in false })
        // No launcher needed; a gone folder is still explained.
        #expect(TerminalReopen.attachPlan(shortId: "1a2b3c4d", folder: "/here", claude: "claude", checks: checks)
                == .open(script: TerminalReopen.attachScript(shortId: "1a2b3c4d", claude: "claude")))
        #expect(TerminalReopen.attachPlan(shortId: "1a2b3c4d", folder: "/gone", claude: "claude", checks: checks) == .folderGone("/gone"))
    }
}

// MARK: - The model

@MainActor
@Suite struct NewSessionModelTests {
    private func started(_ id: String = fresh) -> @Sendable (NewSessionRequest) -> NewSessionResult {
        { _ in NewSessionResult(sessionId: id, failure: nil, detail: "backgrounded · 44444444 · x") }
    }

    @Test func startingMakesItTheTargetWithTheMessageSentAndWorking() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 5, cwd: "/p/api")]
        let (m, d) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        #expect(m.isCreatingSession && m.newSession.folder == "/p/api")
        #expect(!m.canStartNewSession)
        m.newSessionMessage = "Fix the failing test"
        #expect(m.canStartNewSession)
        engine.onStart = { [engine] r in
            var s = session(fresh, age: 0, cwd: r.folder)
            s.state = .idle
            engine.emit(s)
            return NewSessionResult(sessionId: fresh, failure: nil, detail: nil)
        }
        await m.startNewSession()
        #expect(!m.isCreatingSession)
        #expect(m.targetId == fresh)
        let thread = m.threads.thread(for: fresh)
        #expect(thread.count == 1 && thread[0].role == .you && thread[0].text == "Fix the failing test" && thread[0].delivery == .delivered)
        #expect(m.isAwaitingReply && m.targetIsWorking)
        // The first message carries the short-replies note, as any message does; the next one the tag.
        let request = engine.started.first
        #expect(request?.folder == "/p/api" && request?.text == "Fix the failing test")
        #expect(request?.name == "api")
        #expect(request?.styleNote == CompanionConstants.Messages.replyStyleNote)
        await m.sendMessage("and then?")
        #expect(engine.sent.last?.styleNote == CompanionConstants.Messages.replyStyleTag)
        #expect(d.string(forKey: CompanionConstants.Defaults.newSessionFolder) == "/p/api")
        // The answer arrives like any other, after the message.
        var answered = session(fresh, age: 0, cwd: "/p/api", reply: "It is fixed.")
        answered.lastReplyAt = Date()
        engine.emit(answered)
        await settle { m.threads.thread(for: fresh).contains { $0.text == "It is fixed." } }
        #expect(m.threads.thread(for: fresh).first?.role == .you)
        #expect(!m.awaitingFirstAnswer.contains(fresh))
    }

    @Test func anAnswerThatCameFirstStaysAfterTheMessage() async {
        let engine = FakeEngine()
        let (m, _) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.chooseNewSessionFolder("/p/new")
        m.newSessionMessage = "hello"
        engine.onStart = { [engine] _ in
            var s = session(fresh, age: 0, cwd: "/p/new", reply: "Hi there.")
            s.lastReplyAt = Date()
            engine.emit(s)
            return NewSessionResult(sessionId: fresh, failure: nil, detail: nil)
        }
        await m.startNewSession()
        await settle { m.threads.thread(for: fresh).count == 2 }
        #expect(m.threads.thread(for: fresh).map(\.role) == [.you, .session])
        #expect(!m.awaitingFirstAnswer.contains(fresh))
    }

    /// Started, but Claude Code holds it on a question in its terminal: the user is told, with Open in Terminal,
    /// instead of waiting for an answer that cannot come.
    @Test func aNewSessionWaitingInTerminalSaysSo() async {
        let engine = FakeEngine()
        let (m, _) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.chooseNewSessionFolder("/p/new")
        m.newSessionMessage = "hello"
        engine.onStart = { [engine] _ in
            engine.emit(session(fresh, age: 0, cwd: "/p/new"))
            return NewSessionResult(sessionId: fresh, failure: nil, detail: nil)
        }
        await m.startNewSession()
        #expect(m.awaitingFirstAnswer.contains(fresh) && m.currentError == nil)
        // The next refresh of the session list sees it blocked before its first answer.
        var waiting = session(fresh, age: 0, cwd: "/p/new")
        waiting.blocker = .waitingInTerminal
        engine.emit(waiting)
        await settle { m.currentError != nil }
        #expect(m.currentError == .cannotReach(.waitingInTerminal, messageSaved: false, detail: nil))
        #expect(!m.awaitingFirstAnswer.contains(fresh) && !m.targetIsWorking)
        #expect(m.remedies(for: m.currentError!) == [.attachInTerminal, .chooseAnotherSession])
        m.claudePath = "claude"
        #expect(m.attachInTerminal() == .open(script: TerminalReopen.attachScript(shortId: SessionID.short(fresh), claude: "claude")))
    }

    @Test func aFailureKeepsTheFormAndChangesNothingElse() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 5, cwd: "/p/api")]
        let (m, _) = model(engine)
        m.startEngine()
        let before = m.targetId
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.newSessionMessage = "hi"
        engine.onStart = { _ in NewSessionResult(sessionId: nil, failure: .refused(.untrustedFolder), detail: "Workspace not trusted") }
        await m.startNewSession()
        #expect(m.isCreatingSession && m.newSession.problem == .untrustedFolder)
        #expect(m.newSession.problemDetail?.contains("Workspace not trusted") == true)
        #expect(m.targetId == before && m.threads.thread(for: fresh).isEmpty)
        #expect(m.currentError == nil)
        #expect(m.newSessionMessage == "hi")
    }

    @Test func theHomeFolderIsRefusedWhereThisMacRefusesIt() {
        let engine = FakeEngine()
        engine.homeRefused = true
        let (m, _) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.chooseNewSessionFolder(home)
        m.newSessionMessage = "hi"
        #expect(m.newSessionFolderNote == .homeRefused && !m.canStartNewSession)
        engine.homeRefused = false
        m.closeNewSession()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.chooseNewSessionFolder(home)
        m.newSessionMessage = "hi"
        #expect(m.newSessionFolderNote == .homeCaution && m.canStartNewSession)
    }

    @Test func whileItStartsTheFormStaysAndKeysGoToItsField() async {
        let engine = FakeEngine()
        let gate = DispatchSemaphore(value: 0)
        engine.onStart = { _ in
            gate.wait()
            return NewSessionResult(sessionId: nil, failure: .timedOut, detail: nil)
        }
        let (m, _) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        #expect(!m.navigate(.enter) && !m.navigate(.left) && !m.navigate(.delete))
        m.chooseNewSessionFolder("/p/a")
        m.newSessionMessage = "hi"
        let task = Task { await m.startNewSession() }
        await settle { m.newSession.isStarting }
        #expect(m.newSession.isStarting)
        // Not cancellable: Escape, the list and the settings leave it showing.
        #expect(m.navigate(.escape))
        m.openSessionList()
        m.toggleSettings()
        #expect(m.isCreatingSession && !m.isPickingSession && !m.isShowingSettings)
        m.newSessionMessage = "changed"
        #expect(m.newSessionMessage == "hi")
        gate.signal()
        await task.value
        #expect(m.newSession.problem == .timedOut)
        #expect(m.navigate(.escape) && !m.isCreatingSession)
    }

    @Test func picksTheFolderWithTheInjectedChooser() async {
        final class Chooser: FolderChooser {
            var asked: String??
            func chooseFolder(startingAt: String?) async -> String? {
                asked = .some(startingAt)
                return "/p/chosen"
            }
        }
        let engine = FakeEngine()
        let (m, _) = model(engine)
        let chooser = Chooser()
        m.folderChooser = chooser
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.chooseNewSessionFolder("/p/a")
        await m.pickNewSessionFolder()
        #expect(chooser.asked == .some("/p/a"))
        #expect(m.newSession.folder == "/p/chosen")
    }

    @Test func noSessionsAtAllStillOffersStarting() {
        let (m, _) = model(FakeEngine())
        m.startEngine()
        #expect(m.rows.isEmpty && m.sessions.isEmpty)
        m.openSessionList()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        #expect(m.isCreatingSession && !m.isPickingSession && m.isExpanded)
        #expect(m.newSession.folder == nil)
    }

    @Test func openInTerminalAttachesToBackgroundSessionsOnly() {
        let engine = FakeEngine()
        var bg = session(first, age: 1)
        bg.agentId = "11111111"
        engine.list = [bg, session(second, age: 2, kind: .interactive)]
        let (m, _) = model(engine)
        m.claudePath = "/bin/claude"
        m.launcherPath = "/bin/sidemoon-claude"
        m.startEngine()
        guard case let .open(attach) = m.terminalPlan(for: first) else { Issue.record("expected a script"); return }
        #expect(attach.contains("'/bin/claude'") && attach.contains("attach") && attach.contains("'11111111'"))
        guard case let .open(resume) = m.terminalPlan(for: second) else { Issue.record("expected a script"); return }
        #expect(resume.contains("sidemoon-claude") && resume.contains("--resume"))
    }
}

@MainActor
@Suite struct HiddenModelTests {
    /// Hiding the target hides its row only: the target stays (`TargetRule`), and Undo puts the row back.
    @Test func hidingTheTargetKeepsItAndUndoPutsItBack() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 5)]
        let sleeper = ManualSleeper()
        let (m, d) = model(engine, sleeper: sleeper.sleeper)
        m.startEngine()
        m.selectTarget(first)
        m.openSessionList()
        m.hideSession(first)
        #expect(m.rows.map(\.id) == [second])
        #expect(m.targetId == first)
        #expect(m.recentlyHidden?.sessionId == first)
        #expect(d.data(forKey: CompanionConstants.Defaults.hiddenSessions) != nil)
        #expect(d.string(forKey: CompanionConstants.Defaults.targetSession) == first)
        m.undoHide()
        #expect(m.rows.map(\.id) == [first, second] && m.targetId == first && m.recentlyHidden == nil)
        #expect(d.string(forKey: CompanionConstants.Defaults.targetSession) == first)
        // Undo goes away by itself after a while.
        m.hideSession(second)
        await settle { sleeper.waiting > 0 }
        sleeper.releaseAll()
        await settle { m.recentlyHidden == nil }
        #expect(m.recentlyHidden == nil && m.hiddenCount == 1)
    }

    @Test func theCounterAndTheDefaultIgnoreHiddenSessions() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1, state: .needsInput), session(second, age: 5)]
        let (m, d) = model(engine)
        m.startEngine()
        m.selectTarget(second)
        // Asking for permission, and with an answer not yet read: counted twice over as one session.
        var answered = session(first, age: 0, state: .needsInput, reply: "Done.")
        answered.lastReplyAt = Date()
        engine.emit(answered)
        await settle { m.unreadSessions.contains(first) }
        #expect(m.waitingCount == 1)
        m.hideSession(first)
        #expect(m.waitingCount == 0)
        // A fresh model on the same settings: still hidden, and the choice kept.
        let (again, _) = model(engine, defaults: d)
        again.startEngine()
        #expect(again.hidden.contains(first) && again.targetId == second && again.waitingCount == 0)
    }

    @Test func comesBackForAnAnswerOrANeedButNotForAListing() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 5)]
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(second)
        m.hideSession(first)
        // Listed again, working: stays hidden.
        engine.emit(session(first, age: 0, state: .working))
        await settle { m.sessions.first { $0.id == first }?.state == .working }
        #expect(m.hidden.contains(first))
        // An answer: back, and counted.
        var answered = session(first, age: 0, reply: "Done.")
        answered.lastReplyAt = Date()
        engine.emit(answered)
        await settle { !m.hidden.contains(first) }
        #expect(!m.hidden.contains(first) && m.waitingCount == 1)
        // Hidden again, then it asks for permission: back.
        m.hideSession(first)
        var asking = answered
        asking.state = .needsInput
        engine.emit(asking)
        await settle { !m.hidden.contains(first) }
        #expect(!m.hidden.contains(first))
        // Hidden while it asks: the same prompt, seen again, keeps it hidden.
        m.hideSession(first)
        engine.emit(asking)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(m.hidden.contains(first))
    }

    @Test func showHiddenListsThemAndPickingOneUnhidesIt() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 5)]
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(second)
        m.hideSession(first)
        m.showHidden = true
        #expect(m.rows.map(\.id) == [first, second] && m.rows[0].hidden)
        m.pickSession(first)
        #expect(!m.hidden.contains(first) && m.targetId == first)
        m.hideSession(second)
        m.unhideSession(second)
        #expect(m.hiddenCount == 0 && m.recentlyHidden == nil)
    }

    @Test func deleteHidesTheHighlightedRowOnlyWhenNothingIsTyped() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1), session(second, age: 5), session(third, age: 9)]
        let (m, _) = model(engine)
        m.startEngine()
        m.selectTarget(first)
        // Not on the list: the key is the text field's.
        #expect(!m.navigate(.delete))
        m.openSessionList()
        m.moveHighlight(by: 1)
        #expect(m.highlightedSession == second)
        m.noteDraft = "typing"
        #expect(!m.navigate(.delete))
        m.noteDraft = ""
        #expect(m.navigate(.delete))
        #expect(m.hidden.contains(second) && m.highlightedSession == third)
        m.isExpanded = true
        m.closeSessionList()
        m.toggleSettings()
        #expect(!m.navigate(.delete))
    }

    @Test func longGoneHiddenSessionsAreForgotten() {
        let engine = FakeEngine()
        engine.list = [session(first, age: 1)]
        let d = UserDefaults(suiteName: "sidemoon-hidden-\(UUID().uuidString)")!
        var saved = HiddenSessions()
        saved.hide(first, at: Date(timeIntervalSinceNow: -2 * CompanionConstants.Hidden.forgetAfter))
        saved.hide(second, at: Date(timeIntervalSinceNow: -2 * CompanionConstants.Hidden.forgetAfter))
        d.set(saved.data, forKey: CompanionConstants.Defaults.hiddenSessions)
        let (m, _) = model(engine, defaults: d)
        m.startEngine()
        // Still known: kept, and seen now. Not known for longer than the grace period: forgotten.
        #expect(m.hidden.ids == [first])
        #expect(HiddenSessions(data: d.data(forKey: CompanionConstants.Defaults.hiddenSessions)).ids == [first])
    }
}

// MARK: - Chats

private func chat(_ id: String, name: String?, age: TimeInterval) -> Session {
    var s = Session(id: id)
    s.kind = .chat
    s.name = name
    s.lastEventAt = Date().addingTimeInterval(-age)
    return s
}

@Suite struct ChatLogicTests {
    @Test func aChatIsNamedAfterTheStartOfItsFirstMessage() {
        #expect(ChatNaming.name(from: "  what does this   reddit\npost mean? ") == "what does this reddit post mean?")
        let long = ChatNaming.name(from: "please read this long comment thread and tell me who is right about it")
        #expect(long == "please read this long comment" + CompanionConstants.Chat.nameEllipsis)
        #expect(long.count <= CompanionConstants.Chat.nameCharacters + CompanionConstants.Chat.nameEllipsis.count)
        #expect(ChatNaming.name(from: String(repeating: "x", count: 50)).hasPrefix(String(repeating: "x", count: CompanionConstants.Chat.nameCharacters)))
        #expect(ChatNaming.name(from: "   ") == Design.Copy.NewSession.chatHeading)
    }

    /// General first whatever its activity, named by Sidemoon, reachable, never hideable; chats follow by activity.
    @Test func generalIsFirstAndChatsAreListedLikeSessions() {
        let general = chat(TargetRule.general, name: nil, age: 9999)
        let rows = SessionList.rows([session(first, age: 1), chat(second, name: "reddit post", age: 5), general], showEnded: false)
        #expect(rows.map(\.id) == [TargetRule.general, first, second])
        #expect(rows[0].title == Design.Copy.Chat.general && rows[0].reachable && rows[0].isChat && !rows[0].canHide)
        #expect(rows[2].title == "reddit post" && rows[2].canHide && rows[2].folder == nil)
        #expect(rows[2].stateText == Design.Copy.Chat.kind)
        // Working, it is still reachable (the message waits its turn).
        var busy = general
        busy.state = .working
        #expect(SessionList.reachability(busy) == .reachable)
    }

    @Test func theFormStartsAChatWithoutAFolder() {
        var form = NewSessionForm()
        form.message = "hi"
        #expect(form.canStart(note: nil) && !form.inFolder)
        form.setInFolder(true)
        #expect(!form.canStart(note: nil))
        form.choose("/p/a")
        #expect(form.canStart(note: nil) && !form.canStart(note: .missing))
    }

    @Test func aNoteIsInsertedRightAfterItsMessage() {
        var threads = Threads()
        let mine = threads.append(ThreadEntry(role: .you, text: "q"), to: "s")
        threads.append(ThreadEntry(role: .session, text: "a"), to: "s")
        threads.insert(ThreadEntry(role: .session, text: "note"), after: mine, in: "s")
        #expect(threads.thread(for: "s").map(\.text) == ["q", "note", "a"])
    }
}

@MainActor
@Suite struct ChatModelTests {
    /// The "+" with no folder: a new chat named after the message, chosen, and the message sent to it.
    @Test func plusStartsANewChatAndSendsTheFirstMessage() async {
        let engine = FakeEngine()
        engine.list = [chat(TargetRule.general, name: nil, age: 100), session(first, age: 5, cwd: "/p/api")]
        let (m, d) = model(engine)
        m.startEngine()
        m.selectTarget(first)
        m.openNewSession()
        #expect(!m.newSession.inFolder)
        m.newSessionMessage = "What does this post mean?"
        #expect(m.canStartNewSession)
        await m.startNewSession()
        #expect(engine.chatNames == ["What does this post mean?"])
        #expect(engine.started.isEmpty)
        let id = try? #require(engine.sent.last?.session)
        #expect(id != nil && id != first && id != TargetRule.general)
        #expect(m.targetId == id && d.string(forKey: CompanionConstants.Defaults.targetSession) == id)
        #expect(m.threads.thread(for: id).first?.text == "What does this post mean?")
        #expect(!m.isCreatingSession)
    }

    /// With "Work in a folder…" open it is a session in that folder, as before.
    @Test func workInAFolderStartsASessionThere() async {
        let engine = FakeEngine()
        engine.list = [session(first, age: 5, cwd: "/p/api")]
        engine.onStart = { _ in NewSessionResult(sessionId: fresh, failure: nil, detail: nil) }
        let (m, _) = model(engine)
        m.startEngine()
        m.openNewSession()
        m.setNewSessionInFolder(true)
        m.newSessionMessage = "Fix the test"
        await m.startNewSession()
        #expect(engine.started.first?.folder == "/p/api" && engine.chatNames.isEmpty)
    }

    /// Claude Code no longer had the conversation: said in the thread, before the answer.
    @Test func startingOverIsSaidInTheThread() async {
        let engine = FakeEngine()
        engine.list = [chat(TargetRule.general, name: nil, age: 100)]
        engine.reply = { r in
            var result = SendResult(ok: true, sessionId: r.session, route: .headless, reply: "Fresh answer.", error: nil, detail: nil)
            result.startedOver = true
            return result
        }
        let (m, _) = model(engine)
        m.startEngine()
        await m.sendMessage("hello again")
        #expect(m.thread.map(\.text) == ["hello again", Design.Copy.Chat.startedOver, "Fresh answer."])
    }

    /// A chat has no terminal: no Open in Terminal or resume command among the remedies.
    @Test func aChatOffersNoTerminalRemedies() {
        let engine = FakeEngine()
        engine.list = [chat(TargetRule.general, name: nil, age: 100)]
        let (m, _) = model(engine)
        m.startEngine()
        #expect(m.remedies(for: .cannotReach(.loginNeeded, messageSaved: false, detail: nil)) == [.runLogin, .chooseAnotherSession])
    }
}
