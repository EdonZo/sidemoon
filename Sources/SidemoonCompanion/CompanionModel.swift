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
        // A chat has no terminal to reopen it in.
        if target?.kind == .chat {
            remedies.removeAll { [.copyResumeCommand, .installTerminalCommand, .attachInTerminal].contains($0) }
        }
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

    /// "Open in Terminal" for a background session the error is about that waits on a question: Claude Code's own
    /// `claude attach`, which shows the session with its question. A gone folder is explained in place of the error.
    public func attachInTerminal() -> TerminalReopen.Plan {
        let plan = terminalPlan(for: errorSessionId ?? targetId ?? "")
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
        await deliver(to: targetId, text: text, shown: text, imagePaths: [], files: [], attachments: [])
    }
    /// True while the note field is showing (the second hotkey).
    public private(set) var isEditingNote = false
    public var noteDraft = "" {
        // Typing anything while a held capture counts down stops the countdown for good.
        didSet {
            if !noteDraft.isEmpty, noteCountdown != nil { stopCountdown() }
            if holdNotice != nil, noteDraft != oldValue { holdNotice = nil }
        }
    }
    /// A word under the composer about what waits there: why Return did not send it. Gone once the note changes.
    public private(set) var holdNotice: String?
    /// The captures waiting for an optional note, in the order taken; empty when none is held. A capture shortcut
    /// pressed while they wait adds another one to the same message.
    public private(set) var heldCaptures = PendingCaptures()
    /// Counts down to sending the held capture without a note; nil once the user typed or nothing is held.
    public private(set) var noteCountdown: NoteCountdown?
    /// Dropped files waiting for an optional note; empty when none are held. Never moved or deleted.
    public private(set) var heldFiles: [URL] = []
    /// True while a capture or dropped files wait in the note window.
    public var isHoldingCapture: Bool { !heldCaptures.isEmpty || !heldFiles.isEmpty }
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
        discardKeptCaptures()
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

    /// The model General and the other chats run with. Sessions in a folder keep their own.
    public private(set) var chatModel: ChatModel

    public func setChatModel(_ model: ChatModel) {
        chatModel = model
        defaults.set(model.saved, forKey: CompanionConstants.Defaults.chatModel)
    }

    /// `/model` typed in a chat: the setting changes (or is shown) here, and nothing goes to Claude Code. Shown in the
    /// thread as the user's line and a short answer.
    private func handleModelCommand(_ command: ChatModelCommand, typed: String, in session: String) {
        threads.append(ThreadEntry(role: .you, text: typed, delivery: .delivered), to: session)
        let answer: String
        switch command {
        case let .set(model):
            setChatModel(model)
            answer = Design.Copy.ChatModels.nowUsing(model.spokenName)
        case .show:
            answer = Design.Copy.ChatModels.current(chatModel.spokenName, choices: ChatModel.all.map(\.saved))
        }
        threads.append(ThreadEntry(role: .session, text: answer), to: session)
    }

    // MARK: Cancel (Control-C)

    /// Goes up for a session each time the user cancels what is waiting: a message still waiting that sees it
    /// change is not sent.
    @ObservationIgnored private var stopCounts: [String: Int] = [:]
    /// Kept for the views; nothing is ever stopped in a session, so it stays false.
    public private(set) var isStopping = false

    /// Whether there is something for Control-C to cancel: a message waiting its turn, or captures waiting to go.
    /// A session at work is not something Sidemoon stops.
    public var canStop: Bool {
        guard let id = targetId else { return false }
        return heldDecision != nil || threads.thread(for: id).contains { $0.delivery == .queued }
    }

    /// Control-C, or the Cancel button, for the selected session only: what has not been handed to Claude Code yet
    /// is cancelled (messages waiting their turn, captures waiting to be sent). It never stops the session or the
    /// answer it is working on, and a message already on its way is left alone. With nothing to cancel it clears
    /// what is typed, like a terminal prompt.
    public func interrupt() async {
        guard let id = targetId else { return }
        var acted = false
        if heldDecision != nil {
            discardHeldCapture()
            acted = true
        }
        if threads.thread(for: id).contains(where: { $0.delivery == .queued }) {
            stopCounts[id, default: 0] += 1
            // Shown at once; each one's own loop then ends without sending it.
            threads.cancelWaiting(in: id)
            acted = true
        }
        if !acted { noteDraft = "" }
    }

    /// Whether the user stopped the session since `count` was read: a message waiting then is not sent.
    private func stoppedSince(_ count: Int, _ session: String) -> Bool { stopCounts[session, default: 0] != count }

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
    /// The captures that were held when the last hold was resolved, in order.
    @ObservationIgnored private var resolvedCaptures: [URL] = []
    /// A capture is being added to the held ones right now.
    @ObservationIgnored private var isAddingCapture = false
    /// The session the user chose, as saved. The target can differ from it while Sidemoon picks one by itself.
    @ObservationIgnored private var savedTarget: String?
    /// The target was picked by Sidemoon, not by the user, and is not saved.
    @ObservationIgnored private var targetIsAutomatic = false
    /// The user chose a session or sent something in this run, so Sidemoon no longer picks one by itself.
    @ObservationIgnored private var userHasActed = false

    public init(engine: CompanionEngine, capture: CaptureProvider, windowCapture: CaptureProvider? = nil,
                store: CaptureStore, defaults: UserDefaults = .standard,
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
        // The user's choice, whatever has become of it; General only when nothing was ever chosen (`TargetRule`).
        self.targetId = TargetRule.initial(saved: savedChoice)
        self.targetIsAutomatic = savedChoice == nil
        self.savedTarget = savedChoice
        self.hidden = HiddenSessions(data: defaults.data(forKey: CompanionConstants.Defaults.hiddenSessions))
        self.isGuideOpen = !defaults.bool(forKey: CompanionConstants.Defaults.guideClosed)
        self.visibleInRecordings = defaults.bool(forKey: CompanionConstants.Defaults.visibleInRecordings)
        self.guide = GuideProgress(pickedSession: savedChoice != nil)
        self.showEnded = defaults.object(forKey: CompanionConstants.Defaults.showEndedSessions) as? Bool
            ?? CompanionConstants.Defaults.showEndedByDefault
        self.shortReplies = defaults.object(forKey: CompanionConstants.Defaults.shortReplies) as? Bool
            ?? CompanionConstants.Defaults.shortRepliesByDefault
        self.chatModel = ChatModel(saved: defaults.string(forKey: CompanionConstants.Defaults.chatModel)) ?? .standard
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
        SessionList.rows(sessions, showEnded: showEnded, hidden: hidden.ids, showHidden: showHidden, checks: pathChecks,
                         chatModel: chatModel)
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
    /// The model the target answers with, for the header; nil when not known yet.
    public var targetModel: String? { target.flatMap { SessionList.modelLabel($0, chatModel: chatModel) } }
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
        // Or it never got going: Claude Code asks something in its terminal first. Waiting for its answer would be
        // waiting forever, so the user is told, with the way to answer it.
        if awaitingFirstAnswer.contains(session.id), session.blocker == .waitingInTerminal {
            awaitingFirstAnswer.remove(session.id)
            if session.id == targetId { status.handle(.failed(.cannotReach(.waitingInTerminal, messageSaved: false, detail: nil))) }
        }
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

    /// Hides a session from the list. The target stays what it is even when it is the one hidden: messages only
    /// ever go where the header says, and that changes only when the user picks another. General cannot be hidden.
    /// "Undo" shows for `Hidden.undoSeconds`.
    public func hideSession(_ id: String) {
        guard !hidden.contains(id), TargetRule.canHide(id) else { return }
        let wasTarget = id == targetId
        let rowIds = rows.map(\.id)
        recentlyHidden = HiddenUndo(sessionId: id, wasTarget: wasTarget, targetWasAutomatic: targetIsAutomatic)
        hidden.hide(id)
        saveHidden()
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

    public var canStartNewSession: Bool { newSession.canStart(note: newSession.inFolder ? newSessionFolderNote : nil) }

    /// "Work in a folder…", or back to a chat.
    public func setNewSessionInFolder(_ on: Bool) { newSession.setInFolder(on) }

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
        guard newSession.inFolder else { await startNewChat(); return }
        guard newSession.begin(note: newSessionFolderNote), let folder = newSession.folder else { return }
        userHasActed = true
        let text = newSession.trimmedMessage
        let request = NewSessionRequest(folder: folder, text: text,
                                        styleNote: shortReplies ? CompanionConstants.Messages.replyStyleNote : nil,
                                        name: NewSessionForm.defaultName(for: folder))
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

    /// The "+" without a folder: a new chat, named after its first message, becomes the target, and the message is
    /// sent to it like any other.
    private func startNewChat() async {
        guard newSession.canStart(note: nil) else { return }
        let text = newSession.trimmedMessage
        let id = engine.newChat(name: ChatNaming.name(from: text))
        sessions = engine.sessions()
        isCreatingSession = false
        newSession = NewSessionForm()
        closeSessionList()
        selectTarget(id)
        requestComposerFocus()
        await deliverTyped(to: id, text)
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
        // Something waits to be sent: this capture joins it.
        if heldDecision != nil { await addCapture(with: captureProvider); return }
        if hold, isEditingNote { isExpanded = true; return }
        await capture(with: captureProvider, note: note, holdForNote: hold)
    }

    /// Takes one waiting file back out; removing the last thing waiting cancels the send.
    public func removeHeldFile(_ url: URL) {
        guard heldFiles.contains(url) else { return }
        if heldFiles.count + heldCaptures.count == 1 { discardHeldCapture(); return }
        heldFiles.removeAll { $0 == url }
    }

    /// Takes one waiting capture back out (its file is deleted); removing the last thing waiting cancels the send.
    public func removeHeldCapture(_ url: URL) {
        guard heldCaptures.urls.contains(url) else { return }
        if heldFiles.count + heldCaptures.count == 1 { discardHeldCapture(); return }
        heldCaptures.remove(url)
        store.remove(url)
    }

    /// Captures the front-most window of the user's app first (while it is still front-most), then holds it
    /// with the note field open for the grace period: typing stops the countdown until Return or Escape,
    /// Return sends at once, Escape discards, and an untouched field sends it with the default message.
    /// Sends nothing when there is no such window. Returns once the capture is sent or discarded.
    public func captureActiveWindowAndSend() async {
        // Something waits to be sent: this capture joins it (scrolling a long page and pressing again).
        if heldDecision != nil, let windowCaptureProvider { await addCapture(with: windowCaptureProvider); return }
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
        // A command is sent exactly as typed and alone: the screenshots and files stay, and the user is told.
        if SlashCommand.isCommand(note), heldDecision != nil {
            stopCountdown()
            holdNotice = Design.Copy.Commands.notWithAttachments
            return
        }
        resolveHeldCapture(.send(note: note.isEmpty ? nil : note))
    }

    /// Discards a held capture: nothing is sent and its file is deleted at once (safe to call on quit).
    public func discardHeldCapture() {
        resolveHeldCapture(.discard)
    }

    /// Holds captures and files for a note. `countsDown`: an untouched field sends them when the grace period is
    /// over (a shortcut or a drop). A paste does not: what is typed so far stays, and Return sends.
    private func hold(captures: [URL], files: [URL], countsDown: Bool = true) async -> HeldCaptureDecision {
        status.handle(.captureHeld)
        heldCaptures = PendingCaptures()
        captures.forEach { heldCaptures.add($0) }
        heldFiles = files
        // What is waiting to be sent takes the place of the session list and the settings.
        closeSessionList()
        closeSettings()
        if countsDown { noteDraft = "" }
        noteCountdown = countsDown ? NoteCountdown() : nil
        isEditingNote = true
        openBubble()
        return await withCheckedContinuation { continuation in
            heldDecision = continuation
            if noteCountdown != nil { startCountdown() }
        }
    }

    /// Another capture while some wait: it joins the same message, after the others. The countdown pauses while it
    /// is taken (a region takes a moment to pick) and then starts again from the full time, so there is time to
    /// scroll and capture again. Full, or already taking one: nothing happens, and nothing is sent early. A capture
    /// that fails or is cancelled here leaves what waits as it was.
    private func addCapture(with provider: CaptureProvider) async {
        isExpanded = true
        guard !heldCaptures.isFull, !isAddingCapture else { return }
        isAddingCapture = true
        defer { isAddingCapture = false }
        let wasCounting = noteCountdown != nil
        stopCountdown()
        let file = store.newFileURL()
        var added = false
        do {
            try store.prepare()
            // Sent or discarded meanwhile: this capture is not part of anything any more.
            if case let .captured(url) = try await provider.capture(into: file), heldDecision != nil {
                added = heldCaptures.add(url)
            }
        } catch {}
        if !added { store.remove(file) }
        if heldDecision != nil, wasCounting, noteDraft.isEmpty { restartCountdown() }
    }

    private func restartCountdown() {
        noteCountdown = NoteCountdown()
        startCountdown()
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
        let captures = heldCaptures.urls
        heldDecision = nil
        heldCaptures.removeAll()
        resolvedCaptures = captures
        resolvedFiles = heldFiles
        heldFiles = []
        stopCountdown()
        isEditingNote = false
        noteDraft = ""
        holdNotice = nil
        if decision == .discard {
            // Only the temporary captures are deleted; dropped files belong to the user.
            captures.forEach(store.remove)
            status.handle(.heldCaptureDiscarded)
        }
        continuation.resume(returning: decision)
    }

    private func capture(with provider: CaptureProvider, note: String?, holdForNote hold: Bool = false) async {
        if heldDecision != nil { await addCapture(with: provider); return }
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
                guard hold else { await sendCaptures([url], files: [], note: note); return }
                // Discarding deletes every held capture; sending takes whatever waited by then.
                if case let .send(typed) = await self.hold(captures: [url], files: []) { await sendResolved(note: typed) }
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
        await sendCaptures([url], files: [], note: note)
    }

    /// Sends what was held when the hold was resolved: every capture in the order taken, the files, the note.
    private func sendResolved(note: String?) async {
        let captures = resolvedCaptures, files = resolvedFiles
        resolvedCaptures = []
        resolvedFiles = []
        await sendCaptures(captures, files: files, note: note)
    }

    /// One message with captures and files (never touched). Without a note the default words go along; the thread
    /// then shows only the attachments. The captures are deleted once the message is delivered, or when it failed in a
    /// way sending again cannot fix. A failure that Retry can fix keeps them with the failed entry (`kept`), so Retry
    /// sends the same message again.
    private func sendCaptures(_ captures: [URL], files: [URL], note: String?) async {
        let typed = note.flatMap { $0.isEmpty ? nil : $0 }
        let fallback = captures.isEmpty ? CompanionConstants.Messages.defaultFilesText
            : CompanionConstants.Messages.defaultCaptureText(count: captures.count)
        let names = captures.indices.map { CompanionConstants.Messages.captureAttachmentName(number: $0 + 1, of: captures.count) }
        let session = targetId
        let outcome = await deliver(to: session, text: typed ?? fallback, shown: typed ?? "", imagePaths: captures.map(\.path),
                                    files: files, attachments: names + files.map(\.lastPathComponent))
        if outcome.delivered, !captures.isEmpty { tickGuide { $0.sentCapture = true } }
        if !outcome.delivered, !captures.isEmpty, outcome.error?.canRetry == true, let entry = outcome.entry, let session {
            keep(KeptMessage(session: session, captures: captures, files: files, note: typed), for: entry)
        } else {
            captures.forEach(store.remove)
        }
    }

    // MARK: Captures kept for Retry

    /// A message with captures that failed in a way Retry can fix: what it carried, so Retry sends it again as it was.
    struct KeptMessage: Equatable {
        let session: String
        /// In the order taken. In this run's capture folder; deleted with the message.
        let captures: [URL]
        /// The user's own files, never touched.
        let files: [URL]
        /// What the user typed; nil when only the default words went along.
        let note: String?
    }

    /// The failed messages whose captures are kept, by thread entry, oldest first. In memory only: after a restart
    /// the entries show as failed without Retry, and the next launch's cleanup removes the files.
    @ObservationIgnored private var kept: [(entry: UUID, message: KeptMessage)] = []
    /// The thread entries whose captures are kept, for the view's Retry.
    public private(set) var keptEntries: Set<UUID> = []

    private func keep(_ message: KeptMessage, for entry: UUID) {
        kept.append((entry, message))
        keptEntries.insert(entry)
        // Screenshots must not pile up: the oldest beyond the limit lose theirs.
        while kept.count > CompanionConstants.Capture.maxKeptMessages { dropKept(kept[0].entry) }
    }

    /// Forgets a failed message's kept captures and deletes them.
    private func dropKept(_ entry: UUID) {
        guard let index = kept.firstIndex(where: { $0.entry == entry }) else { return }
        kept[index].message.captures.forEach(store.remove)
        kept.remove(at: index)
        keptEntries.remove(entry)
    }

    /// Deletes every kept capture: the conversations are cleared, or the app quits.
    public func discardKeptCaptures() {
        for item in kept { item.message.captures.forEach(store.remove) }
        kept = []
        keptEntries = []
    }

    /// Whether a thread entry offers Retry: a typed message, or a message whose captures are kept.
    public func canRetry(_ entry: ThreadEntry) -> Bool {
        if entry.canRetry { return true }
        guard entry.role == .you, case .failed = entry.delivery else { return false }
        return keptEntries.contains(entry.id)
    }

    /// A typed message to a session that has answered before is a reply: the guide's last step.
    private func deliverTyped(to session: String?, _ text: String) async {
        // In a chat, /model is Sidemoon's setting: each message is a separate run, so Claude Code could not keep it.
        if let session, sessions.first(where: { $0.id == session })?.kind == .chat, let command = ChatModelCommand.parse(text) {
            handleModelCommand(command, typed: text, in: session)
            return
        }
        let isReply = threads.thread(for: session).contains { $0.role == .session }
        let sent = await deliver(to: session, text: text, shown: text, imagePaths: [], files: [], attachments: [])
        if sent.delivered, isReply { tickGuide { $0.replied = true } }
    }

    /// Sends a message that was not delivered once more, in place of the failed one: the same text, and when its
    /// captures were kept, the same captures in the same order and the same files. Captures that are gone are never
    /// referred to: the typed words go alone with a note saying so, and with no words nothing is sent.
    public func retry(_ id: UUID) async {
        guard let session = targetId, let entry = threads.thread(for: session).first(where: { $0.id == id }),
              canRetry(entry), preflight() else { return }
        guard let index = kept.firstIndex(where: { $0.entry == id }) else {
            threads.remove(entry: id, in: session)
            await deliverTyped(to: session, entry.text)
            return
        }
        let message = kept.remove(at: index).message
        keptEntries.remove(id)
        let present = message.captures.filter(store.exists)
        if present.count == message.captures.count {
            threads.remove(entry: id, in: session)
            await sendCaptures(message.captures, files: message.files, note: message.note)
            return
        }
        present.forEach(store.remove)
        guard let note = message.note else {
            // Nothing typed: there is nothing left to send. Said where the message is, and Retry is gone.
            threads.setDelivery(.refused(Design.Copy.Captures.goneNothingSent), entry: id, in: session)
            status.handle(.failed(.captureMissing(detail: nil)))
            return
        }
        threads.remove(entry: id, in: session)
        let files = message.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        let outcome = await deliver(to: session, text: note, shown: note, imagePaths: [], files: files,
                                    attachments: files.map(\.lastPathComponent))
        if let sent = outcome.entry {
            threads.insert(ThreadEntry(role: .session, text: Design.Copy.Captures.goneSentWords), after: sent, in: session)
        }
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
        await holdFiles(urls, countsDown: true)
    }

    /// Command-V in the composer with files on the clipboard: they join what waits, or wait with what is typed so
    /// far until Return sends them. Never moved or deleted.
    public func pasteFiles(_ urls: [URL]) async {
        await holdFiles(urls, countsDown: false)
    }

    /// Command-V in the composer with an image on the clipboard, already written to a file in the capture store
    /// (`newCaptureFile`): it is a capture like any other from here, deleted once sent or discarded. It joins what
    /// waits, or waits with what is typed so far until Return sends it.
    public func pasteImage(at url: URL) async {
        if heldDecision != nil {
            if !heldCaptures.add(url) { store.remove(url) }
            isExpanded = true
            return
        }
        // A note written for a region capture (the note shortcut) keeps its turn.
        guard !isEditingNote, preflight() else { store.remove(url); return }
        status.handle(.captureBegan)
        if case let .send(note) = await hold(captures: [url], files: [], countsDown: false) { await sendResolved(note: note) }
    }

    /// Where a pasted image is written before `pasteImage(at:)`: the capture store, so it is cleaned up like a capture.
    public func newCaptureFile() throws -> URL {
        try store.prepare()
        return store.newFileURL()
    }

    private func holdFiles(_ urls: [URL], countsDown: Bool) async {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else {
            if !urls.isEmpty { status.handle(.failed(.delivery(CompanionConstants.Messages.foldersNotSent))) }
            return
        }
        if heldDecision != nil {
            // More files while something is waiting: add them and start the wait again.
            heldFiles += files.filter { !heldFiles.contains($0) }
            if noteCountdown != nil { restartCountdown() }
            isExpanded = true
            return
        }
        // One thing at a time: a capture or a note already in progress keeps its turn.
        if isEditingNote { isExpanded = true; return }
        guard preflight() else { return }
        status.handle(.captureBegan)
        if case let .send(note) = await hold(captures: [], files: files, countsDown: countsDown) { await sendResolved(note: note) }
    }

    /// What rides along with the next message to a session: the full note the first time and every so
    /// often after that, otherwise just the short tag, so the session's input is not filled with it.
    private func nextStyleNote(for session: String) -> String {
        let count = styleNotesSent[session, default: 0]
        styleNotesSent[session] = count + 1
        return count % CompanionConstants.Messages.replyStyleNoteEvery == 0
            ? CompanionConstants.Messages.replyStyleNote : CompanionConstants.Messages.replyStyleTag
    }

    /// What became of one send: whether it was delivered (a late reply counts), the thread entry it made, and why
    /// it failed.
    struct DeliveryOutcome {
        var delivered: Bool
        var entry: UUID?
        var error: CompanionError?
        /// The user stopped it before it was handed over.
        var cancelled = false
    }

    /// A message the user stopped before it went: marked so, never sent. Called before it took its turn.
    private func cancelled(_ entry: UUID, in session: String) -> DeliveryOutcome {
        inFlight[session, default: 1] -= 1
        return cancelledAfterStart(entry, in: session)
    }

    /// `stillCounted`: this message is still in `inFlight`, and is taken out of it right after.
    private func cancelledAfterStart(_ entry: UUID, in session: String, stillCounted: Bool = false) -> DeliveryOutcome {
        threads.setDelivery(.cancelled, entry: entry, in: session)
        let others = (inFlight[session] ?? 0) - (stillCounted ? 1 : 0)
        if session == targetId, others <= 0, !status.activity.isFailure { status.activity = .idle }
        return DeliveryOutcome(delivered: false, entry: entry, error: nil, cancelled: true)
    }

    /// One send to the target: recorded in the thread, delivered off the main thread, reply awaited.
    /// `shown` is what the thread displays, which is empty when only the default message went along.
    @discardableResult
    private func deliver(to session: String?, text: String, shown: String, imagePaths: [String], files: [URL],
                         attachments: [String]) async -> DeliveryOutcome {
        // The session this message is for was fixed by the caller: the user may switch to another one
        // while it travels, or even before this runs.
        guard let targetId = session else { status.handle(.failed(.noTarget)); return DeliveryOutcome(delivered: false, error: .noTarget) }
        // From here on an error is about this session.
        errorSessionId = nil
        status.handle(.sendBegan)
        let entry = threads.append(ThreadEntry(role: .you, text: shown, attachments: attachments, delivery: .sending), to: targetId)
        inFlight[targetId, default: 0] += 1
        let stopCount = stopCounts[targetId, default: 0]
        // One message at a time per session; other sessions are not held up.
        while activeSends.contains(targetId) {
            threads.setDelivery(.queued, entry: entry, in: targetId)
            await sleeper(CompanionConstants.Timing.busyRetryInterval)
            if stoppedSince(stopCount, targetId) { return cancelled(entry, in: targetId) }
        }
        if stoppedSince(stopCount, targetId) { return cancelled(entry, in: targetId) }
        activeSends.insert(targetId)
        threads.setDelivery(.sending, entry: entry, in: targetId)
        defer {
            activeSends.remove(targetId)
            inFlight[targetId, default: 1] -= 1
        }
        let request = SendRequest(session: targetId, imagePaths: imagePaths, text: text, wait: true, filePaths: files.map(\.path),
                                  styleNote: shortReplies && !SlashCommand.isCommand(text) ? nextStyleNote(for: targetId) : nil,
                                  model: sessions.first { $0.id == targetId }?.kind == .chat ? chatModel.alias : nil)
        let engine = self.engine
        var result = await Task.detached { engine.send(request) }.value
        // A busy session is not an error: the message waits and goes out when its turn is over.
        var waited: TimeInterval = 0
        var checks = 0
        while !result.ok, CompanionError.from(result) == .busy, waited < CompanionConstants.Timing.busyWaitLimit {
            threads.setDelivery(.queued, entry: entry, in: targetId)
            await sleeper(CompanionConstants.Timing.busyRetryInterval)
            // Stopped while it waited for the busy session: it is never sent.
            // (Its turn is given back by the defer above.)
            if stoppedSince(stopCount, targetId) { return cancelledAfterStart(entry, in: targetId, stillCounted: true) }
            waited += CompanionConstants.Timing.busyRetryInterval
            checks += 1
            // Retry once the session is seen to have stopped working, and now and then regardless.
            let stillWorking = sessions.first { $0.id == targetId }?.state == .working
            if stillWorking, checks % CompanionConstants.Timing.busyRetryEvery != 0 { continue }
            threads.setDelivery(.sending, entry: entry, in: targetId)
            result = await Task.detached { engine.send(request) }.value
        }
        // Stopped after it was handed over: it was delivered; what was said before the stop stays, and it is marked.
        if result.failure == .stopped {
            threads.setDelivery(.delivered, entry: entry, in: targetId)
            if let partial = result.reply, !partial.isEmpty { threads.appendReply(partial, to: targetId) }
            threads.append(ThreadEntry(role: .session, text: Design.Copy.Stop.stopped), to: targetId)
            sessions = engine.sessions()
            if targetId == self.targetId, case .failed = status.activity {} else if targetId == self.targetId { status.activity = .idle }
            return DeliveryOutcome(delivered: true, entry: entry, error: nil)
        }
        if result.ok {
            threads.setDelivery(.delivered, entry: entry, in: targetId)
            // Said before its answer, which may be in already.
            if result.startedOver {
                threads.insert(ThreadEntry(role: .session, text: Design.Copy.Chat.startedOver), after: entry, in: targetId)
            }
            if let reply = result.reply { threads.appendReply(reply, to: targetId) }
        } else {
            // A reply that is merely late still means the message arrived.
            let error = CompanionError.from(result)
            let failed: ThreadEntry.Delivery = error.canRetry ? .failed(error.threadNote) : .refused(error.threadNote)
            threads.setDelivery(error == .replyTimeout ? .delivered : failed, entry: entry, in: targetId)
        }
        sessions = engine.sessions()
        // The user moved to another session meanwhile: its thread has the outcome, and it is marked.
        let delivered = result.ok || CompanionError.from(result) == .replyTimeout
        let outcome = DeliveryOutcome(delivered: delivered, entry: entry, error: result.ok ? nil : CompanionError.from(result))
        guard targetId == self.targetId else {
            unreadSessions.insert(targetId)
            return outcome
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
        return outcome
    }
}
