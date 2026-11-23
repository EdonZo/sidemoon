import Foundation
import Observation
import SidemoonCore

public enum EngineState: Equatable, Sendable {
    case stopped
    case running
    case conflict
    case failed(String)
}

/// Everything the mascot and bubble display, and every action they can take. UI-framework free.
@MainActor
@Observable
public final class CompanionModel {
    public private(set) var engineState: EngineState = .stopped
    public private(set) var sessions: [Session] = []
    public private(set) var targetId: String?
    public private(set) var status = CompanionStatus()
    /// The latest reply from the target session, whoever triggered the turn.
    public private(set) var latestReply: String?
    public private(set) var latestReplyAt: Date?
    public var isExpanded = false
    /// The Claude Code hooks are not installed: answers cannot come back. Set by the app from the setup's checks.
    public var needsConnection = false
    /// Goes up each time the composer should take the text cursor again (after a message is sent).
    public private(set) var composerFocusRequests = 0
    public func requestComposerFocus() { composerFocusRequests += 1 }

    /// Opening at login, when the app can register itself for it (nil for a bare executable).
    @ObservationIgnored public var loginItem: LoginItem? { didSet { refreshOpensAtLogin() } }
    public private(set) var opensAtLogin = false
    public var canOpenAtLogin: Bool { loginItem != nil }

    /// Reads the real state: the user can also change it in System Settings.
    public func refreshOpensAtLogin() {
        let now = loginItem?.isEnabled ?? false
        if opensAtLogin != now { opensAtLogin = now }
    }

    public func setOpensAtLogin(_ on: Bool) {
        try? loginItem?.setEnabled(on)
        refreshOpensAtLogin()
    }

    /// Automatic updates, when this build has an updater (nil until the release is signed for updates).
    @ObservationIgnored public var updater: Updater? { didSet { refreshAutomaticUpdates() } }
    public private(set) var checksForUpdates = false
    public var canUpdate: Bool { updater != nil }

    public func refreshAutomaticUpdates() {
        let now = updater?.automaticallyChecks ?? false
        if checksForUpdates != now { checksForUpdates = now }
    }

    public func setChecksForUpdates(_ on: Bool) {
        updater?.setAutomaticallyChecks(on)
        refreshAutomaticUpdates()
    }

    public func checkForUpdates() { updater?.checkForUpdates() }
    /// The user has not pressed Start in Setup yet. Set by the app.
    public var setupPending = false
    /// The `sidemoon-claude` command from Setup's terminal step is installed. Set by the app.
    public var terminalCommandInstalled = true
    /// Setup's "Connect every claude" is on, or cannot be offered here. Set by the app; while it is false, a session
    /// started with plain `claude` offers turning it on.
    public var connectsEveryClaude = true
    /// What exists on disk: session folders, the launcher. The app passes the real checks.
    @ObservationIgnored public let pathChecks: PathChecks
    /// The launcher "Open in Terminal" runs.
    @ObservationIgnored public var launcherPath = SetupPaths.standard.launcher
    /// The session the shown error is about when the user picked it from the list without it becoming the target.
    @ObservationIgnored private var errorSessionId: String?

    /// The `claude` command "Open in Terminal" runs for a background session. The app passes where it found it.
    @ObservationIgnored public var claudePath = Constants.Paths.claudeExecutableName

    /// "Open in Terminal" on a session's row: a background session is attached to (`claude attach <short id>`),
    /// Claude Code's own way to show one in a terminal; any other kind is reopened through the launcher as before.
    public func terminalPlan(for id: String) -> TerminalReopen.Plan {
        let session = sessions.first { $0.id == id }
        if let session, session.kind == .background {
            return TerminalReopen.attachPlan(shortId: session.agentId ?? SessionID.short(id), folder: session.cwd,
                                             claude: claudePath, checks: pathChecks)
        }
        return TerminalReopen.plan(sessionId: id, folder: session?.cwd, launcher: launcherPath, checks: pathChecks)
    }

    /// What reopens a session in a terminal through Sidemoon's channel, ready to paste.
    public var resumeCommand: String {
        let paths = SetupPaths.standard
        return "\(paths.display(paths.launcher)) \(Constants.ClaudeCLI.resumeFlag)"
    }

    /// The next steps offered with an error. The resume command is only offered once it is installed;
    /// before that, the way to install it is.
    public func remedies(for error: CompanionError) -> [Remedy] {
        var remedies = error.remedies.map { $0 == .copyResumeCommand && !terminalCommandInstalled ? .installTerminalCommand : $0 }
        if error == .needsLauncher, !connectsEveryClaude, let last = remedies.indices.last {
            // Before "Choose another session", which stays the last way out.
            remedies.insert(.connectEveryClaude, at: last)
        }
        return remedies
    }

    /// "Open in Terminal" for the session the error is about: the script to open, or why not. A gone folder is
    /// explained in place of the error; nothing is opened then.
    public func reopenInTerminal() -> TerminalReopen.Plan {
        let id = errorSessionId ?? targetId
        let session = sessions.first { $0.id == id }
        let plan = TerminalReopen.plan(sessionId: id, folder: session?.cwd, launcher: launcherPath, checks: pathChecks)
        if case let .folderGone(folder) = plan { status.handle(.failed(.folderGone(folder))) }
        return plan
    }

    // MARK: Guide

    /// The "Try it" guide's three steps, ticked as the user does them.
    public private(set) var guide = GuideProgress()
    /// The guide is open: not yet finished or hidden, or asked for again from the settings.
    public private(set) var isGuideOpen: Bool
    /// Asked for from the settings, so it shows even while Setup is unfinished.
    @ObservationIgnored private var guideRequested = false

    /// Shown once Setup is finished, and whenever asked for.
    public var showsGuide: Bool { isGuideOpen && (guideRequested || (!setupPending && !needsConnection)) }

    /// Opens the guide again from the settings, with its steps to do again.
    public func showGuide() {
        guide = GuideProgress(pickedSession: targetId != nil && !targetIsAutomatic)
        isGuideOpen = true
        guideRequested = true
        closeSettings()
        closeSessionList()
    }

    /// Setup's Start was pressed: open beside the mascot with the guide showing, and draw the eye to the mascot.
    public func presentAfterSetup() {
        isGuideOpen = true
        guideRequested = true
        closeSettings()
        closeSessionList()
        openBubble()
        requestAttention()
    }

    /// Goes up each time the mascot should pulse so the eye finds it.
    public private(set) var attentionRequests = 0
    public func requestAttention() { attentionRequests += 1 }

    /// The panels show up in screen recordings and screen sharing. Off by default, so the companion never ends up
    /// in the captures it sends.
    public var visibleInRecordings: Bool {
        didSet { defaults.set(visibleInRecordings, forKey: CompanionConstants.Defaults.visibleInRecordings) }
    }

    /// Hides the guide; it stays hidden until asked for.
    public func dismissGuide() {
        isGuideOpen = false
        guideRequested = false
        defaults.set(true, forKey: CompanionConstants.Defaults.guideClosed)
    }

    private func tickGuide(_ change: (inout GuideProgress) -> Void) {
        var next = guide
        change(&next)
        guard next != guide else { return }
        guide = next
        // Finished: it stays on screen to show so, and does not open by itself again.
        if guide.isComplete { defaults.set(true, forKey: CompanionConstants.Defaults.guideClosed) }
    }

    /// The guide's button: a short, harmless message to the chosen session, to see an answer come back.
    public func sendTestMessage() async {
        guard preflight() else { return }
        let text = CompanionConstants.Guide.testMessage
        await deliver(to: targetId, text: text, shown: text, imagePath: nil, files: [], attachments: [])
    }
    /// True while the note field is showing (the second hotkey).
    public private(set) var isEditingNote = false
    public var noteDraft = "" {
        // Typing anything while a held capture counts down stops the countdown for good.
        didSet { if !noteDraft.isEmpty, noteCountdown != nil { stopCountdown() } }
    }
    /// The active-window capture waiting for an optional note; nil when nothing is held.
    public private(set) var heldCapture: URL?
    /// Counts down to sending the held capture without a note; nil once the user typed or nothing is held.
    public private(set) var noteCountdown: NoteCountdown?
    /// Dropped files waiting for an optional note; empty when none are held. Never moved or deleted.
    public private(set) var heldFiles: [URL] = []
    /// True while a capture or dropped files wait in the note window.
    public var isHoldingCapture: Bool { heldCapture != nil || !heldFiles.isEmpty }
    /// The running conversation with each session.
    public private(set) var threads = Threads() {
        didSet { if archive != nil { scheduleSave() } }
    }
    @ObservationIgnored private let archive: ThreadArchive?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Saves a little after the last change, off the main thread: one message changes the conversation
    /// several times over (sending, delivered, the answer), and writing the whole file each time made
    /// the window stutter.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CompanionConstants.Thread.saveDelay))
            guard !Task.isCancelled, let self, let archive = self.archive else { return }
            let snapshot = self.threads
            await Task.detached(priority: .utility) { archive.save(snapshot) }.value
        }
    }

    /// Writes the conversations now. Called before the app quits, so the last moments are not lost.
    public func flushThreads() {
        pendingSave?.cancel()
        pendingSave = nil
        archive?.save(threads)
    }

    /// Empties every conversation, on screen and on disk.
    public func clearThreads() {
        threads = Threads()
        unreadSessions = []
        flushThreads()
    }
    /// The conversation with the target session, oldest first.
    public var thread: [ThreadEntry] { threads.thread(for: targetId) }
    /// True while the target session is working on an answer, whoever asked.
    public var isAwaitingReply: Bool {
        switch status.activity {
        case .sending, .waiting: return true
        default: return targetIsWorking
        }
    }
    /// The target is working on an answer: it says so, or it is a session Sidemoon just started whose first answer
    /// has not come yet.
    public var targetIsWorking: Bool {
        guard let targetId else { return false }
        return target?.state == .working || awaitingFirstAnswer.contains(targetId)
    }
    public var showEnded: Bool {
        didSet { defaults.set(showEnded, forKey: CompanionConstants.Defaults.showEndedSessions) }
    }
    /// The look of the companion.
    public private(set) var theme: Design.Theme
    /// True when the larger window is chosen.
    public private(set) var isLarge: Bool
    /// True while the settings are showing in place of the thread.
    public private(set) var isShowingSettings = false

    public func setTheme(_ value: Design.Theme) {
        theme = value
        Design.theme = value
        defaults.set(value.rawValue, forKey: CompanionConstants.Defaults.theme)
    }

    /// The bubble has the keyboard: typing goes to its composer.
    public var hasKeyboard = false

    /// A size the user dragged the window to; nil while it sizes itself.
    public private(set) var bubbleSize: CGSize?
    /// What the panel is showing right now, and which way it grows from the mascot. Set by the panel.
    @ObservationIgnored public var shownBubbleSize: CGSize = .zero
    public var bubbleGrowsLeft = false
    public var bubbleGrowsUp = false

    /// Sets a window size chosen by dragging, kept within sensible limits and remembered.
    public func resizeBubble(to size: CGSize) {
        let low = Design.Bubble.customMinimum, high = Design.Bubble.customMaximum
        let clamped = CGSize(width: min(high.width, max(low.width, size.width.rounded())),
                             height: min(high.height, max(low.height, size.height.rounded())))
        guard clamped != bubbleSize else { return }
        bubbleSize = clamped
        Design.customBubbleSize = clamped
        defaults.set(Double(clamped.width), forKey: CompanionConstants.Defaults.bubbleWidth)
        defaults.set(Double(clamped.height), forKey: CompanionConstants.Defaults.bubbleHeight)
    }

    /// Back to the automatic size: as wide as the regular or large setting, as tall as its content.
    public func resetBubbleSize() {
        guard bubbleSize != nil else { return }
        bubbleSize = nil
        Design.customBubbleSize = nil
        defaults.removeObject(forKey: CompanionConstants.Defaults.bubbleWidth)
        defaults.removeObject(forKey: CompanionConstants.Defaults.bubbleHeight)
    }

    public func setLarge(_ value: Bool) {
        resetBubbleSize()
        isLarge = value
        Design.isLarge = value
        defaults.set(value, forKey: CompanionConstants.Defaults.largeWindow)
    }

    public func toggleLarge() { setLarge(!isLarge) }

    public func toggleSettings() {
        guard closeNewSession() else { return }
        isShowingSettings.toggle()
        if isShowingSettings { closeSessionList() }
    }

    public func closeSettings() { isShowingSettings = false }

    /// True while the session list is showing in place of the thread.
    public private(set) var isPickingSession = false
    /// The row the arrow keys are on while the list is showing.
    public private(set) var highlightedSession: String?

    public func openSessionList() {
        guard closeNewSession() else { return }
        isShowingSettings = false
        isPickingSession = true
        let ids = rows.map(\.id)
        highlightedSession = ids.first { $0 == targetId } ?? ids.first
    }

    public func closeSessionList() {
        isPickingSession = false
        highlightedSession = nil
    }

    public func toggleSessionList() { isPickingSession ? closeSessionList() : openSessionList() }

    /// Moves the highlight up (negative) or down the list, stopping at its ends.
    public func moveHighlight(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = highlightedSession.flatMap({ ids.firstIndex(of: $0) }) else {
            highlightedSession = step > 0 ? ids.first : ids.last
            return
        }
        highlightedSession = ids[min(ids.count - 1, max(0, current + step))]
    }

    /// Enters the highlighted session: it becomes the target and its thread comes back.
    public func enterHighlightedSession() {
        if let id = highlightedSession { pickSession(id) }
        closeSessionList()
    }

    /// Arrow-key navigation, as in Claude Code's own session view: Left leaves the session for the list,
    /// Up and Down move through it, Right or Return enters the highlighted one, Escape closes the list.
    /// Returns true when the key was used; otherwise it goes on to the text field as usual.
    public func navigate(_ key: NavigationKey) -> Bool {
        if isCreatingSession {
            // The form's fields take every other key; Escape leaves it (not while the session is starting).
            if key == .escape { closeNewSession() }
            return key == .escape
        }
        // Delete is for text, except on the session list while nothing is typed.
        if key == .delete, !isPickingSession || !noteDraft.isEmpty { return false }
        if isShowingSettings {
            // Escape or Left leaves the settings; other keys do nothing there.
            if key == .escape || key == .left { closeSettings() }
            return true
        }
        if isPickingSession {
            switch key {
            case .up: moveHighlight(by: -1)
            case .down: moveHighlight(by: 1)
            case .right, .enter: enterHighlightedSession()
            case .escape: closeSessionList()
            case .left: break
            case .delete:
                if let id = highlightedSession, !hidden.contains(id) { hideSession(id) }
            }
            return true
        }
        // Left only leaves when there is no text for the arrow to move through and nothing is waiting.
        if key == .left, noteDraft.isEmpty, !isEditingNote, isExpanded {
            openSessionList()
            return true
        }
        return false
    }

    /// When on, each message asks the session for a short, conversational answer to that message only.
    public var shortReplies: Bool {
        didSet { defaults.set(shortReplies, forKey: CompanionConstants.Defaults.shortReplies) }
    }
    /// Sessions other than the target that have answered since they were last looked at.
    public private(set) var unreadSessions: Set<String> = []

    /// How many sessions have something for the user: an answer not yet read, or a prompt waiting on them.
    public var waitingCount: Int {
        var ids = unreadSessions
        if status.unseenReply, let targetId { ids.insert(targetId) }
        for row in rows where row.state == .needsInput { ids.insert(row.id) }
        // A hidden session does not count until it comes back by itself.
        return ids.subtracting(hidden.ids).count
    }
    /// The user's size setting: 1 is the standard size.
    public private(set) var zoom: Double

    public func setZoom(_ value: Double) {
        let stepped = (value / Design.Zoom.step).rounded() * Design.Zoom.step
        zoom = min(Design.Zoom.maximum, max(Design.Zoom.minimum, stepped))
        Design.zoom = zoom
        defaults.set(zoom, forKey: CompanionConstants.Defaults.zoom)
    }

    public func zoomIn() { setZoom(zoom + Design.Zoom.step) }
    public func zoomOut() { setZoom(zoom - Design.Zoom.step) }
    public func resetZoom() { setZoom(Design.Zoom.standard) }

    @ObservationIgnored private let engine: CompanionEngine
    @ObservationIgnored private let captureProvider: CaptureProvider
    /// Captures the active window with no selection step (the third hotkey).
    @ObservationIgnored private let windowCaptureProvider: CaptureProvider?
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var subscribed = false
    /// The registry's reply for the target as last seen, to tell new replies from repeats.
    @ObservationIgnored private var knownTargetReply: String?
    @ObservationIgnored private var knownTargetState: SessionState?
    @ObservationIgnored private let sleeper: Sleeper
    /// Resumed exactly once with what to do with the held capture.
    @ObservationIgnored private var heldDecision: CheckedContinuation<HeldCaptureDecision, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// How many tagged messages each session has been sent, to pace the full style note.
    @ObservationIgnored private var styleNotesSent: [String: Int] = [:]
    /// Messages on their way, per session, including ones waiting their turn.
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    /// Sessions that have a message being delivered right now.
    @ObservationIgnored private var activeSends: Set<String> = []
    /// The files that were held when the last hold was resolved.
    @ObservationIgnored private var resolvedFiles: [URL] = []
    /// The session the user chose, as saved. The target can differ from it while Sidemoon picks one by itself.
    @ObservationIgnored private var savedTarget: String?
    /// The target was picked by Sidemoon, not by the user, and is not saved.
    @ObservationIgnored private var targetIsAutomatic = false
    /// The user chose a session or sent something in this run, so Sidemoon no longer picks one by itself.
    @ObservationIgnored private var userHasActed = false

    public init(engine: CompanionEngine, capture: CaptureProvider, windowCapture: CaptureProvider? = nil,
                store: CaptureStore = CaptureStore(), defaults: UserDefaults = .standard,
                archive: ThreadArchive? = nil, sleeper: @escaping Sleeper = Sleepers.system,
                pathChecks: PathChecks = .everythingExists) {
        self.engine = engine
        self.pathChecks = pathChecks
        self.archive = archive
        if var saved = archive?.load() {
            saved.settleInterrupted(reason: Design.Copy.interruptedByRestart)
            self.threads = saved
        }
        self.captureProvider = capture
        self.windowCaptureProvider = windowCapture
        self.store = store
        self.defaults = defaults
        self.sleeper = sleeper
        let savedChoice = defaults.string(forKey: CompanionConstants.Defaults.targetSession)
        self.targetId = savedChoice
        self.savedTarget = savedChoice
        self.hidden = HiddenSessions(data: defaults.data(forKey: CompanionConstants.Defaults.hiddenSessions))
        self.isGuideOpen = !defaults.bool(forKey: CompanionConstants.Defaults.guideClosed)
        self.visibleInRecordings = defaults.bool(forKey: CompanionConstants.Defaults.visibleInRecordings)
        self.guide = GuideProgress(pickedSession: savedChoice != nil)
        self.showEnded = defaults.object(forKey: CompanionConstants.Defaults.showEndedSessions) as? Bool
            ?? CompanionConstants.Defaults.showEndedByDefault
        self.shortReplies = defaults.object(forKey: CompanionConstants.Defaults.shortReplies) as? Bool
            ?? CompanionConstants.Defaults.shortRepliesByDefault
        let savedTheme = defaults.string(forKey: CompanionConstants.Defaults.theme).flatMap(Design.Theme.init(rawValue:)) ?? .paper
        let savedLarge = defaults.bool(forKey: CompanionConstants.Defaults.largeWindow)
        self.theme = savedTheme
        self.isLarge = savedLarge
        Design.theme = savedTheme
        Design.isLarge = savedLarge
        var savedSize: CGSize?
        if let width = defaults.object(forKey: CompanionConstants.Defaults.bubbleWidth) as? Double,
           let height = defaults.object(forKey: CompanionConstants.Defaults.bubbleHeight) as? Double {
            savedSize = CGSize(width: width, height: height)
        }
        self.bubbleSize = savedSize
        Design.customBubbleSize = savedSize
        let saved = defaults.object(forKey: CompanionConstants.Defaults.zoom) as? Double ?? Design.Zoom.standard
        self.zoom = min(Design.Zoom.maximum, max(Design.Zoom.minimum, saved))
        Design.zoom = zoom
    }

    // MARK: Derived

    public var rows: [SessionRow] {
        SessionList.rows(sessions, showEnded: showEnded, hidden: hidden.ids, showHidden: showHidden, checks: pathChecks)
    }
    public var target: Session? { targetId.flatMap { id in sessions.first { $0.id == id } } }
    public var targetTitle: String {
        if let target { return SessionList.displayName(target) }
        if let targetId { return SessionID.short(targetId) }
        return "No session chosen"
    }
    public var targetDetail: String {
        guard let target else { return targetId == nil ? "Choose one from the menu" : "not seen yet" }
        var parts = [SessionList.stateText(target.state)]
        if let folder = SessionList.folderName(target), folder != SessionList.displayName(target) { parts.insert(folder, at: 0) }
        return parts.joined(separator: "  ·  ")
    }
    public var indicator: Indicator { status.indicator }
    public var currentError: CompanionError? {
        if case let .failed(e) = status.activity { return e }
        return nil
    }

    // MARK: Engine

    /// Starts the in-process engine, or reports that another one owns the socket.
    public func startEngine() {
        if !subscribed {
            subscribed = true
            engine.subscribe { [weak self] session in
                Task { @MainActor in self?.apply(session) }
            }
        }
        do {
            switch try engine.start() {
            case .running:
                engineState = .running
                if case .failed(.engineConflict) = status.activity { status.handle(.errorDismissed) }
                if case .failed(.engineFailed) = status.activity { status.handle(.errorDismissed) }
            case .conflict:
                engineState = .conflict
                status.handle(.failed(.engineConflict))
            }
        } catch {
            engineState = .failed("\(error)")
            status.handle(.failed(.engineFailed("\(error)")))
        }
        try? store.prepare()
        store.purge()
        reloadSessions()
    }

    public func stopEngine() {
        engine.stop()
        engineState = .stopped
    }

    private func reloadSessions() {
        sessions = engine.sessions()
        pruneHidden()
        chooseDefaultTarget()
        for s in sessions { if let r = s.lastReply { threads.appendReply(r, to: s.id, stamp: s.lastReplyAt) } }
        if let t = target {
            knownTargetReply = t.lastReply
            knownTargetState = t.state
            if latestReply == nil, let r = t.lastReply { latestReply = r }
        }
    }

    /// One registry change, already on the main actor.
    func apply(_ session: Session) {
        let previous = sessions.first { $0.id == session.id }
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.append(session) }
        chooseDefaultTarget()
        // Every session's replies are kept, so its thread is there when the user switches to it.
        var newAnswer = false
        if let reply = session.lastReply {
            let before = threads.thread(for: session.id).count
            threads.appendReply(reply, to: session.id, stamp: session.lastReplyAt)
            newAnswer = threads.thread(for: session.id).count > before
            // A fresh answer from a session the user is not looking at is marked for them.
            if session.id != targetId, newAnswer { unreadSessions.insert(session.id) }
        }
        if hidden.contains(session.id) {
            if HiddenSessions.revealsItself(before: previous, after: session, newAnswer: newAnswer) {
                unhideSession(session.id)
            } else {
                pruneHidden()
            }
        }
        // A session Sidemoon started: from here its own state, or its answer, says whether it is working.
        if awaitingFirstAnswer.contains(session.id), newAnswer || session.state != .idle { awaitingFirstAnswer.remove(session.id) }
        guard session.id == targetId else { return }
        if session.state == .working, knownTargetState != .working { status.handle(.targetStartedWorking) }
        knownTargetState = session.state
        if let reply = session.lastReply, reply != knownTargetReply {
            knownTargetReply = reply
            showReply(reply)
        }
    }

    private func showReply(_ text: String) {
        guard text != latestReply else { return }
        latestReply = text
        latestReplyAt = Date()
        status.handle(.replyArrived)
        // With the bubble open the reply is in front of the user already.
        if isExpanded { status.handle(.bubbleOpened) }
    }

    // MARK: Target

    /// Until the user chooses or sends, the target is the saved choice when it can be reached, else the most
    /// recently active session that can. A pick of Sidemoon's own is not saved, so the user's choice comes
    /// back as soon as that session shows up again.
    private func chooseDefaultTarget() {
        guard !userHasActed else { return }
        let all = SessionList.rows(sessions, showEnded: true, hidden: hidden.ids, checks: pathChecks)
        // A hidden session is not in `all`, so it never counts as reachable here.
        func reachable(_ id: String?) -> Bool { all.contains { $0.id == id && $0.reachable } }
        if let saved = savedTarget, reachable(saved) {
            if targetId != saved { switchTarget(to: saved, automatic: false) }
            return
        }
        // Nothing listed yet, or already on a session that can be reached.
        guard !all.isEmpty, !reachable(targetId),
              let pick = SessionList.defaultTarget(sessions, hidden: hidden.ids, checks: pathChecks), pick != targetId else { return }
        switchTarget(to: pick, automatic: true)
    }

    /// The user's choice from the session list. A session Claude Code would refuse, or a terminal session started
    /// without sidemoon-claude, does not become the target: the reason and what to do about it are shown instead.
    public func pickSession(_ id: String) {
        // Choosing a hidden session (listed while "Show hidden" is on) puts it back.
        if hidden.contains(id) { unhideSession(id) }
        let reachability = SessionList.rows(sessions, showEnded: true, checks: pathChecks).first(where: { $0.id == id })?.reachability
        errorSessionId = reachability == .reachable || reachability == nil ? nil : id
        switch reachability {
        case .folderGone?:
            closeSessionList()
            status.handle(.failed(.folderGone(sessions.first { $0.id == id }?.cwd ?? "")))
        case let .blocked(blocker)?:
            closeSessionList()
            status.handle(.failed(.cannotReach(blocker, messageSaved: false, detail: nil)))
        case .needsChannel?:
            closeSessionList()
            status.handle(.failed(.needsLauncher))
        case .channelDropped?:
            closeSessionList()
            status.handle(.failed(.notPickedUp(fallback: nil)))
        case .reachable?, nil:
            selectTarget(id)
        }
    }

    public func selectTarget(_ id: String) {
        userHasActed = true
        tickGuide { $0.pickedSession = true }
        if id == targetId, targetIsAutomatic {
            // Choosing the session Sidemoon picked makes it the user's choice.
            targetIsAutomatic = false
            savedTarget = id
            defaults.set(id, forKey: CompanionConstants.Defaults.targetSession)
        }
        guard id != targetId else { return }
        switchTarget(to: id, automatic: false)
    }

    private func switchTarget(to id: String, automatic: Bool) {
        // A capture held for the old target is never sent to the new one.
        discardHeldCapture()
        targetId = id
        targetIsAutomatic = automatic
        unreadSessions.remove(id)
        if !automatic {
            savedTarget = id
            defaults.set(id, forKey: CompanionConstants.Defaults.targetSession)
        }
        let s = target
        knownTargetReply = s?.lastReply
        knownTargetState = s?.state
        latestReply = s?.lastReply
        latestReplyAt = nil
        status.unseenReply = false
        if case .failed(let e) = status.activity, e != .engineConflict { status.handle(.errorDismissed) }
        // The state shown is the new session's: sending only if a message is on its way to it.
        switch status.activity {
        case .idle, .sending, .waiting: status.activity = (inFlight[id] ?? 0) > 0 ? .sending : .idle
        case .capturing, .holding, .failed: break
        }
    }

    /// No target: nothing is chosen, and nothing waits for one.
    private func clearTarget() {
        discardHeldCapture()
        targetId = nil
        targetIsAutomatic = true
        knownTargetReply = nil
        knownTargetState = nil
        latestReply = nil
        latestReplyAt = nil
        status.unseenReply = false
    }

    // MARK: Hidden sessions

    /// Sessions hidden from the list. Only Sidemoon's list changes: nothing is run against the session.
    public private(set) var hidden: HiddenSessions
    /// Hidden sessions are listed too, dimmed, each with Unhide. Not saved: hiding is the lasting choice.
    public var showHidden = false
    /// The session just hidden, while its Undo shows.
    public private(set) var recentlyHidden: HiddenUndo?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    public var hiddenCount: Int { hidden.count }

    private func saveHidden() {
        if hidden.isEmpty {
            defaults.removeObject(forKey: CompanionConstants.Defaults.hiddenSessions)
        } else if let data = hidden.data {
            defaults.set(data, forKey: CompanionConstants.Defaults.hiddenSessions)
        }
    }

    /// Notes the hidden sessions Sidemoon still knows and forgets the long-gone ones; saved only when that changed.
    private func pruneHidden() {
        guard !hidden.isEmpty, hidden.prune(known: Set(sessions.map(\.id))) else { return }
        saveHidden()
    }

    /// Hides a session from the list. Hiding the target moves the target to the default choice. "Undo" shows for
    /// `Hidden.undoSeconds`.
    public func hideSession(_ id: String) {
        guard !hidden.contains(id) else { return }
        let wasTarget = id == targetId
        let rowIds = rows.map(\.id)
        recentlyHidden = HiddenUndo(sessionId: id, wasTarget: wasTarget, targetWasAutomatic: targetIsAutomatic)
        hidden.hide(id)
        saveHidden()
        if wasTarget {
            if savedTarget == id {
                savedTarget = nil
                defaults.removeObject(forKey: CompanionConstants.Defaults.targetSession)
            }
            if let pick = SessionList.defaultTarget(sessions, hidden: hidden.ids, checks: pathChecks) {
                switchTarget(to: pick, automatic: true)
            } else {
                clearTarget()
            }
        }
        // The arrow keys stay on the row that took its place.
        if highlightedSession == id, let index = rowIds.firstIndex(of: id) {
            let remaining = rows.map(\.id)
            highlightedSession = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        undoTask?.cancel()
        let sleeper = self.sleeper
        undoTask = Task { [weak self] in
            await sleeper(CompanionConstants.Hidden.undoSeconds)
            guard !Task.isCancelled, let self, self.recentlyHidden?.sessionId == id else { return }
            self.recentlyHidden = nil
        }
    }

    /// Puts back the session just hidden, as the target again if it was.
    public func undoHide() {
        guard let undo = recentlyHidden else { return }
        undoTask?.cancel()
        recentlyHidden = nil
        hidden.unhide(undo.sessionId)
        saveHidden()
        if undo.wasTarget, sessions.contains(where: { $0.id == undo.sessionId }) {
            switchTarget(to: undo.sessionId, automatic: undo.targetWasAutomatic)
        }
    }

    /// Puts a hidden session back in the list (the Unhide button, or the session coming back by itself).
    public func unhideSession(_ id: String) {
        guard hidden.unhide(id) else { return }
        saveHidden()
        if recentlyHidden?.sessionId == id {
            undoTask?.cancel()
            recentlyHidden = nil
        }
    }

    // MARK: New session

    /// The new-session form is showing in place of the list.
    public private(set) var isCreatingSession = false
    public private(set) var newSession = NewSessionForm()
    /// Picks a folder with the system's panel; set by the app.
    @ObservationIgnored public var folderChooser: FolderChooser?
    /// The user's home folder, where a new session gets a caution, or is not allowed (`FolderNote`).
    @ObservationIgnored public var homeFolder = FileManager.default.homeDirectoryForCurrentUser.path
    /// Claude Code on this Mac refuses to reopen home-folder sessions; read when the form opens.
    public private(set) var homeFolderRefused = false
    /// Sessions Sidemoon started whose first answer has not come yet: the working row shows for them until their
    /// own state takes over.
    public private(set) var awaitingFirstAnswer: Set<String> = []

    /// The first message as typed. Fixed while the session starts.
    public var newSessionMessage: String {
        get { newSession.message }
        set { if !newSession.isStarting { newSession.message = newValue } }
    }

    /// Folders to offer first: those of the sessions Sidemoon knows, the last one used first.
    public var recentFolders: [String] {
        RecentFolders.list(sessions: sessions, lastUsed: defaults.string(forKey: CompanionConstants.Defaults.newSessionFolder),
                           home: homeFolder, checks: pathChecks)
    }

    /// What the form says about the chosen folder, if anything.
    public var newSessionFolderNote: FolderNote? {
        FolderNote.of(newSession.folder, home: homeFolder, homeRefused: homeFolderRefused, checks: pathChecks)
    }

    public var canStartNewSession: Bool { newSession.canStart(note: newSessionFolderNote) }

    /// Opens the form, with the last folder used (or the most recent one) chosen.
    public func openNewSession() {
        guard !isCreatingSession else { return }
        homeFolderRefused = engine.homeFolderRefused()
        newSession = NewSessionForm(folder: recentFolders.first)
        isShowingSettings = false
        isPickingSession = false
        highlightedSession = nil
        isCreatingSession = true
        openBubble()
    }

    /// Closes the form. Not while the session is starting: returns false then.
    @discardableResult
    public func closeNewSession() -> Bool {
        guard isCreatingSession else { return true }
        guard !newSession.isStarting else { return false }
        isCreatingSession = false
        newSession = NewSessionForm()
        return true
    }

    public func chooseNewSessionFolder(_ folder: String) { newSession.choose(folder) }

    /// "Choose folder…": the system's folder panel, opening where the chosen folder is.
    public func pickNewSessionFolder() async {
        guard let folderChooser, !newSession.isStarting else { return }
        if let folder = await folderChooser.chooseFolder(startingAt: newSession.folder) { newSession.choose(folder) }
    }

    /// Starts the session: `claude --bg` in the folder with the first message (and the short-replies note, as on any
    /// message). On success it becomes the target, the message shows as sent in its thread, and its answer arrives
    /// like any other. On failure the form says why and keeps what was typed.
    public func startNewSession() async {
        guard engineState == .running else { preflight(); return }
        guard newSession.begin(note: newSessionFolderNote), let folder = newSession.folder else { return }
        userHasActed = true
        let text = newSession.trimmedMessage
        let request = NewSessionRequest(folder: folder, text: text,
                                        styleNote: shortReplies ? CompanionConstants.Messages.replyStyleNote : nil)
        let engine = self.engine
        let result = await Task.detached { engine.startSession(request) }.value
        guard result.ok, let id = result.sessionId else {
            let problem = result.failure.map(NewSessionProblem.from) ?? .failed
            let detail = [result.failure?.description, result.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            newSession.fail(problem, detail: detail.isEmpty ? nil : detail)
            return
        }
        defaults.set(folder, forKey: CompanionConstants.Defaults.newSessionFolder)
        // The full note went with this first message; the next ones carry the tag until it is due again.
        if shortReplies { styleNotesSent[id] = 1 }
        sessions = engine.sessions()
        // Before its answer, which may already be in.
        threads.prepend(ThreadEntry(role: .you, text: text, delivery: .delivered), to: id)
        if !threads.thread(for: id).contains(where: { $0.role == .session }) { awaitFirstAnswer(id) }
        isCreatingSession = false
        newSession = NewSessionForm()
        closeSessionList()
        selectTarget(id)
        requestComposerFocus()
    }

    /// Shows the session as working until its own state or its answer takes over, at most the reply timeout.
    private func awaitFirstAnswer(_ id: String) {
        awaitingFirstAnswer.insert(id)
        let sleeper = self.sleeper
        Task { [weak self] in
            await sleeper(Constants.Timeouts.replyWait)
            self?.awaitingFirstAnswer.remove(id)
        }
    }

    // MARK: Bubble

    public func toggleBubble(){ isExpanded ? closeBubble() : openBubble() }

    public func openBubble() {
        isExpanded = true
        status.handle(.bubbleOpened)
    }

    public func closeBubble() {
        isExpanded = false
        if isEditingNote { cancelNote() }
    }

    public func dismissError() { status.handle(.errorDismissed) }

    // MARK: Note (second hotkey)

    public func beginNote() {
        guard preflight() else { return }
        noteDraft = ""
        isEditingNote = true
        openBubble()
    }

    /// Escape (or collapsing the bubble). With a held capture, it is discarded and nothing is sent.
    public func cancelNote() {
        if isHoldingCapture { discardHeldCapture(); return }
        isEditingNote = false
        noteDraft = ""
    }

    /// Ends note editing and returns the note to send with the next capture.
    public func finishNote() -> String {
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingNote = false
        noteDraft = ""
        return note
    }

    // MARK: Capture and send

    /// Checks that a send could go anywhere before asking the user to drag a region.
    @discardableResult
    func preflight() -> Bool {
        // Whatever happens next, the user is at work with the target they see: Sidemoon stops picking one.
        userHasActed = true
        // One screenshot at a time: show what is in flight instead of starting another.
        // A capture being taken or waiting for its note keeps its turn. A message still on its way to
        // some session does not block anything: every session has its own lane.
        if status.activity == .capturing || status.activity == .holding { isExpanded = true; return false }
        switch engineState {
        case .conflict: status.handle(.failed(.engineConflict)); return false
        case let .failed(m): status.handle(.failed(.engineFailed(m))); return false
        case .stopped: status.handle(.failed(.engineFailed("the engine is not running"))); return false
        case .running: break
        }
        guard targetId != nil else { status.handle(.failed(.noTarget)); return false }
        // Its folder went away after it was chosen: say so before asking for a capture that cannot go anywhere.
        if let target, SessionList.reachability(target, checks: pathChecks) == .folderGone {
            status.handle(.failed(.folderGone(target.cwd ?? "")))
            return false
        }
        return true
    }

    /// Region capture, then send to the target and wait for its reply. Escape sends nothing.
    /// With `hold`, the capture waits in the note window first, so it can still be undone.
    public func captureAndSend(note: String? = nil, hold: Bool = false) async {
        if hold, isEditingNote { isExpanded = true; return }
        await capture(with: captureProvider, note: note, holdForNote: hold)
    }

    /// Takes one waiting file back out; removing the last one cancels the send.
    public func removeHeldFile(_ url: URL) {
        guard heldFiles.contains(url) else { return }
        if heldFiles.count == 1 { discardHeldCapture(); return }
        heldFiles.removeAll { $0 == url }
    }

    /// Captures the front-most window of the user's app first (while it is still front-most), then holds it
    /// with the note field open for the grace period: typing stops the countdown until Return or Escape,
    /// Return sends at once, Escape discards, and an untouched field sends it with the default message.
    /// Sends nothing when there is no such window. Returns once the capture is sent or discarded.
    public func captureActiveWindowAndSend() async {
        // One capture at a time, including a region note being written.
        if isEditingNote { isExpanded = true; return }
        guard let windowCaptureProvider else {
            if preflight() { status.handle(.failed(.captureFailed("active window capture is not available"))) }
            return
        }
        await capture(with: windowCaptureProvider, note: nil, holdForNote: true)
    }

    /// Return in the note field while a capture is held: sends it now, with the note if one was typed.
    public func submitHeldCapture() {
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        resolveHeldCapture(.send(note: note.isEmpty ? nil : note))
    }

    /// Discards a held capture: nothing is sent and its file is deleted at once (safe to call on quit).
    public func discardHeldCapture() {
        resolveHeldCapture(.discard)
    }

    private func hold(capture: URL?, files: [URL]) async -> HeldCaptureDecision {
        status.handle(.captureHeld)
        heldCapture = capture
        heldFiles = files
        // What is waiting to be sent takes the place of the session list and the settings.
        closeSessionList()
        closeSettings()
        noteDraft = ""
        noteCountdown = NoteCountdown()
        isEditingNote = true
        openBubble()
        return await withCheckedContinuation { continuation in
            heldDecision = continuation
            startCountdown()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        let sleeper = self.sleeper
        countdownTask = Task { [weak self] in
            while true {
                guard let interval = self?.noteCountdown?.tickInterval else { return }
                await sleeper(interval)
                guard !Task.isCancelled, let model = self, model.noteCountdown != nil else { return }
                if model.advanceCountdown() { return }
            }
        }
    }

    /// One countdown tick. Returns true when the countdown is over; an untouched field then sends.
    private func advanceCountdown() -> Bool {
        noteCountdown?.tick()
        guard noteCountdown?.isExpired == true else { return false }
        if noteDraft.isEmpty { resolveHeldCapture(.send(note: nil)) } else { stopCountdown() }
        return true
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        noteCountdown = nil
    }

    private func resolveHeldCapture(_ decision: HeldCaptureDecision) {
        guard let continuation = heldDecision else { return }
        let capture = heldCapture
        heldDecision = nil
        heldCapture = nil
        resolvedFiles = heldFiles
        heldFiles = []
        stopCountdown()
        isEditingNote = false
        noteDraft = ""
        if decision == .discard {
            // Only the temporary capture is deleted; dropped files belong to the user.
            if let capture { store.remove(capture) }
            status.handle(.heldCaptureDiscarded)
        }
        continuation.resume(returning: decision)
    }

    private func capture(with provider: CaptureProvider, note: String?, holdForNote hold: Bool = false) async {
        guard preflight() else { return }
        status.handle(.captureBegan)
        let file = store.newFileURL()
        do {
            try store.prepare()
            switch try await provider.capture(into: file) {
            case .cancelled:
                store.remove(file)
                status.handle(.captureCancelled)
            case let .captured(url):
                guard hold else { await send(imageAt: url, note: note); return }
                switch await self.hold(capture: url, files: []) {
                case let .send(typed): await send(imageAt: url, note: typed)
                case .discard: store.remove(url)
                }
            }
        } catch let error as CaptureError where error == .noActiveWindow {
            store.remove(file)
            status.handle(.failed(.noActiveWindow))
        } catch {
            store.remove(file)
            status.handle(.failed(.captureFailed("\(error)")))
        }
    }

    /// Sends an image file to the target and waits for the reply off the main thread.
    /// The file is deleted afterwards, whatever the outcome.
    public func send(imageAt url: URL, note: String?) async {
        defer { store.remove(url) }
        let typed = note.flatMap { $0.isEmpty ? nil : $0 }
        let sent = await deliver(to: targetId, text: typed ?? CompanionConstants.Messages.defaultCaptureText, shown: typed ?? "",
                                 imagePath: url.path, files: [], attachments: [CompanionConstants.Messages.captureAttachmentName])
        if sent { tickGuide { $0.sentCapture = true } }
    }

    /// A typed message to a session that has answered before is a reply: the guide's last step.
    private func deliverTyped(to session: String?, _ text: String) async {
        let isReply = threads.thread(for: session).contains { $0.role == .session }
        let sent = await deliver(to: session, text: text, shown: text, imagePath: nil, files: [], attachments: [])
        if sent, isReply { tickGuide { $0.replied = true } }
    }

    /// Sends a typed question or reply to the target and waits for its answer.
    /// Sends a message that was not delivered once more, in place of the failed one.
    public func retry(_ id: UUID) async {
        guard let session = targetId, let entry = threads.thread(for: session).first(where: { $0.id == id }),
              entry.canRetry, preflight() else { return }
        threads.remove(entry: id, in: session)
        await deliverTyped(to: session, entry.text)
    }

    public func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, preflight() else { return }
        await deliverTyped(to: targetId, trimmed)
    }

    /// Sends what is typed in the composer. The text is only cleared once the send has started, so a
    /// message that cannot go (no session chosen, engine down) stays in the field instead of vanishing.
    public func submitDraft() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, preflight() else { return }
        noteDraft = ""
        let session = targetId
        Task { await deliverTyped(to: session, text) }
    }

    /// Files dropped on the companion. They wait in the note window like an active-window capture:
    /// type to add a question, or they are sent on their own. The files are never moved or deleted.
    public func dropFiles(_ urls: [URL]) async {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else {
            if !urls.isEmpty { status.handle(.failed(.delivery(CompanionConstants.Messages.foldersNotSent))) }
            return
        }
        if !heldFiles.isEmpty {
            // More files while some are waiting: add them and start the wait again.
            heldFiles += files.filter { !heldFiles.contains($0) }
            if noteCountdown != nil {
                noteCountdown = NoteCountdown()
                startCountdown()
            }
            return
        }
        // One thing at a time: a capture or a note already in progress keeps its turn.
        if isEditingNote { isExpanded = true; return }
        guard preflight() else { return }
        status.handle(.captureBegan)
        switch await hold(capture: nil, files: files) {
        case let .send(note):
            let sent = resolvedFiles
            await deliver(to: targetId, text: note ?? CompanionConstants.Messages.defaultFilesText, shown: note ?? "", imagePath: nil,
                          files: sent, attachments: sent.map(\.lastPathComponent))
        case .discard:
            break
        }
    }

    /// What rides along with the next message to a session: the full note the first time and every so
    /// often after that, otherwise just the short tag, so the session's input is not filled with it.
    private func nextStyleNote(for session: String) -> String {
        let count = styleNotesSent[session, default: 0]
        styleNotesSent[session] = count + 1
        return count % CompanionConstants.Messages.replyStyleNoteEvery == 0
            ? CompanionConstants.Messages.replyStyleNote : CompanionConstants.Messages.replyStyleTag
    }

    /// One send to the target: recorded in the thread, delivered off the main thread, reply awaited.
    /// `shown` is what the thread displays, which is empty when only the default message went along.
    /// Returns whether the message was delivered.
    @discardableResult
    private func deliver(to session: String?, text: String, shown: String, imagePath: String?, files: [URL],
                         attachments: [String]) async -> Bool {
        // The session this message is for was fixed by the caller: the user may switch to another one
        // while it travels, or even before this runs.
        guard let targetId = session else { status.handle(.failed(.noTarget)); return false }
        // From here on an error is about this session.
        errorSessionId = nil
        status.handle(.sendBegan)
        let entry = threads.append(ThreadEntry(role: .you, text: shown, attachments: attachments, delivery: .sending), to: targetId)
        inFlight[targetId, default: 0] += 1
        // One message at a time per session; other sessions are not held up.
        while activeSends.contains(targetId) {
            threads.setDelivery(.queued, entry: entry, in: targetId)
            await sleeper(CompanionConstants.Timing.busyRetryInterval)
        }
        activeSends.insert(targetId)
        threads.setDelivery(.sending, entry: entry, in: targetId)
        defer {
            activeSends.remove(targetId)
            inFlight[targetId, default: 1] -= 1
        }
        let request = SendRequest(session: targetId, imagePath: imagePath, text: text, wait: true, filePaths: files.map(\.path),
                                  styleNote: shortReplies ? nextStyleNote(for: targetId) : nil)
        let engine = self.engine
        var result = await Task.detached { engine.send(request) }.value
        // A busy session is not an error: the message waits and goes out when its turn is over.
        var waited: TimeInterval = 0
        var checks = 0
        while !result.ok, CompanionError.from(result) == .busy, waited < CompanionConstants.Timing.busyWaitLimit {
            threads.setDelivery(.queued, entry: entry, in: targetId)
            await sleeper(CompanionConstants.Timing.busyRetryInterval)
            waited += CompanionConstants.Timing.busyRetryInterval
            checks += 1
            // Retry once the session is seen to have stopped working, and now and then regardless.
            let stillWorking = sessions.first { $0.id == targetId }?.state == .working
            if stillWorking, checks % CompanionConstants.Timing.busyRetryEvery != 0 { continue }
            threads.setDelivery(.sending, entry: entry, in: targetId)
            result = await Task.detached { engine.send(request) }.value
        }
        if result.ok {
            threads.setDelivery(.delivered, entry: entry, in: targetId)
            if let reply = result.reply { threads.appendReply(reply, to: targetId) }
        } else {
            // A reply that is merely late still means the message arrived.
            let error = CompanionError.from(result)
            let failed: ThreadEntry.Delivery = error.canRetry ? .failed(error.title) : .refused(error.title)
            threads.setDelivery(error == .replyTimeout ? .delivered : failed, entry: entry, in: targetId)
        }
        sessions = engine.sessions()
        // The user moved to another session meanwhile: its thread has the outcome, and it is marked.
        let delivered = result.ok || CompanionError.from(result) == .replyTimeout
        guard targetId == self.targetId else {
            unreadSessions.insert(targetId)
            return delivered
        }
        if result.ok {
            if let reply = result.reply {
                knownTargetReply = reply
                latestReply = reply
                latestReplyAt = Date()
            }
            status.handle(.sendSucceeded(hasReply: result.reply != nil))
            if isExpanded { status.handle(.bubbleOpened) }
        } else {
            status.handle(.failed(CompanionError.from(result)))
        }
        // Another message to this session is still on its way.
        if (inFlight[targetId] ?? 0) > 1, !status.activity.isBusy, currentError == nil { status.activity = .sending }
        return delivered
    }
}
