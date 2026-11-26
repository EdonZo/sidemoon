import CoreGraphics
import Foundation
import SidemoonCore

// MARK: - Errors in plain words

/// Everything that can go wrong, phrased for the person using the companion.
public enum CompanionError: Equatable, Sendable {
    case noTarget
    case engineConflict
    case engineFailed(String)
    case busy
    case noRoute
    case noScratchpad
    case unknownSession
    case replyTimeout
    case forked
    case captureFailed(String)
    case noActiveWindow
    case delivery(String)
    /// Claude Code will not reopen the session. `stoppedFirst`: Sidemoon had already stopped it when Claude Code
    /// refused. `detail` is the technical reason, kept for bug reports.
    case cannotReach(ResumeBlocker, messageSaved: Bool, stoppedFirst: Bool = false, detail: String?)
    /// A terminal session started with plain `claude`, without Sidemoon's channel: nothing can reach it.
    case needsLauncher
    /// Claude Code did not pass on what Sidemoon's connection sent: the session runs in a process that does not
    /// load it. `fallback`: the route Retry will take, nil when there is none.
    case notPickedUp(fallback: Route?)
    /// The session's folder was moved or deleted, so Claude Code cannot reopen the session there.
    case folderGone(String)
    /// A screenshot to send was no longer there. `detail` (with its path) is only for a bug report.
    case captureMissing(detail: String?)
    /// A file to send was no longer there, or could not be read. `detail` (with its path) is only for a bug report.
    case fileMissing(detail: String?)

    /// What stays under a message that failed, in the thread. A failure with no words of its own keeps the
    /// engine's reason there, shortened: the error card is replaced by the next thing that happens, and without
    /// this "Sending failed" would be all that is left to go on.
    public var threadNote: String {
        guard case let .delivery(reason) = self else { return title }
        let limit = CompanionConstants.Messages.threadReasonCharacters
        let short = reason.count > limit ? String(reason.prefix(limit)) + "…" : reason
        return "\(title): \(short)"
    }

    public var title: String {
        switch self {
        case .notPickedUp: return Design.Copy.Unreachable.notPickedUpTitle
        case let .cannotReach(blocker, _, _, _): return Design.Copy.Unreachable.title(blocker)
        case .needsLauncher: return Design.Copy.Unreachable.noChannelTitle
        case .folderGone: return Design.Copy.Unreachable.folderGoneTitle
        case .captureMissing: return Design.Copy.Captures.missingTitle
        case .fileMissing: return Design.Copy.Captures.fileMissingTitle
        case .noTarget: return "No session chosen"
        case .engineConflict: return "Another Sidemoon engine is running"
        case .engineFailed: return "The Sidemoon engine could not start"
        case .busy: return "The session is busy"
        case .noRoute: return "This session cannot be reached right now"
        case .noScratchpad: return "The session is not ready for images yet"
        case .unknownSession: return "The session is gone"
        case .replyTimeout: return "Still no reply"
        case .forked: return "Nothing was delivered"
        case .captureFailed: return "The screenshot failed"
        case .noActiveWindow: return "No active window to capture"
        case .delivery: return "Sending failed"
        }
    }

    public var advice: String {
        switch self {
        case let .cannotReach(blocker, saved, stopped, _):
            return Design.Copy.Unreachable.advice(blocker, messageSaved: saved, stoppedFirst: stopped)
        case .needsLauncher: return Design.Copy.Unreachable.noChannelAdvice
        case let .folderGone(folder): return Design.Copy.Unreachable.folderGoneAdvice(folder)
        case .captureMissing: return Design.Copy.Captures.missingAdvice
        case .fileMissing: return Design.Copy.Captures.fileMissingAdvice
        case let .notPickedUp(fallback): return Design.Copy.Unreachable.notPickedUpAdvice(retryGoesInBackground: fallback == .background)
        case .noTarget:
            return "Open the menu and choose which Claude Code session should get your screenshots."
        case .engineConflict:
            return "Something else, probably `sidemoon serve` in a terminal, already owns the engine socket. "
                + "Quit it, then choose Retry Engine from the menu."
        case let .engineFailed(m):
            return "\(m). Choose Retry Engine from the menu; if it keeps failing, restart Sidemoon."
        case .busy:
            return "It is in the middle of a turn and Sidemoon will not interrupt it. Wait until it finishes, then send again."
        case .noRoute:
            return "Sidemoon can only reach an open session that was started with the Sidemoon channel, "
                + "an idle background session, or a session that has ended. Pick another session or start this one with the channel."
        case .noScratchpad:
            return "Type anything in that session once so it reports where it can read files, then send again."
        case .unknownSession:
            return "It no longer appears in the session list. Choose another session from the menu."
        case .replyTimeout:
            return "Your screenshot was delivered but the session has not answered yet. Its reply will show up here when it finishes."
        case .forked:
            return "Claude Code started a copy of the session instead of continuing it, so Sidemoon stopped the copy. Try again in a moment."
        case let .captureFailed(m):
            return "\(m). Check that Sidemoon is allowed to record the screen in System Settings, Privacy and Security."
        case .noActiveWindow:
            return "Nothing was sent. Click the window you want to send, then press "
                + "\(CompanionConstants.HotKeys.captureActiveWindow.displayName) again."
        case let .delivery(m):
            return m
        }
    }

    /// What the user can do about it, shown as buttons under the advice. Empty for most errors.
    public var remedies: [Remedy] {
        if self == .needsLauncher || self == .notPickedUp(fallback: nil) { return [.copyResumeCommand, .chooseAnotherSession] }
        if case .folderGone = self { return [.chooseAnotherSession] }
        guard case let .cannotReach(blocker, _, _, _) = self else { return [] }
        switch blocker {
        case .homeFolder, .untrustedFolder: return [.copyResumeCommand, .chooseAnotherSession]
        case .loginNeeded: return [.runLogin, .copyResumeCommand, .chooseAnotherSession]
        case .noTranscript: return [.chooseAnotherSession]
        case .waitingInTerminal: return [.attachInTerminal, .chooseAnotherSession]
        }
    }

    /// Whether sending the same message again could work. Not when Claude Code refused the session: it
    /// would refuse again until the user does something about it.
    public var canRetry: Bool {
        if case .cannotReach = self { return false }
        if self == .needsLauncher { return false }
        if case .folderGone = self { return false }
        // Sending again cannot bring back what is gone.
        if case .captureMissing = self { return false }
        if case .fileMissing = self { return false }
        return true
    }

    /// The technical reason behind the plain words, for a bug report; nil when there is nothing more to say.
    public var detail: String? {
        switch self {
        case let .cannotReach(_, _, _, detail), let .captureMissing(detail), let .fileMissing(detail): return detail
        default: return nil
        }
    }

    /// Maps an engine result to a companion error. Only called for failed results.
    public static func from(_ result: SendResult) -> CompanionError {
        switch result.failure {
        case let .cannotResume(blocker, saved, stopped)?:
            return .cannotReach(blocker, messageSaved: saved, stoppedFirst: stopped,
                                detail: [result.error, result.detail].compactMap { $0 }.joined(separator: "\n"))
        case .busy?: return .busy
        case .noRoute?: return .noRoute
        case .noScratchpad?: return .noScratchpad
        case .unknownSession?: return .unknownSession
        case .replyTimeout?: return .replyTimeout
        case .forked?: return .forked
        case let .channelIgnored(fallback)?: return .notPickedUp(fallback: fallback)
        // Never the path: plain words, the technical text for a bug report.
        case .imageMissing?: return .captureMissing(detail: [result.error, result.detail].compactMap { $0 }.joined(separator: "\n"))
        case .fileMissing?: return .fileMissing(detail: [result.error, result.detail].compactMap { $0 }.joined(separator: "\n"))
        default: return .delivery(result.error ?? "The engine did not say why.")
        }
    }
}

/// A next step offered with an error.
public enum Remedy: Equatable, Sendable, Hashable {
    /// Copy the command that reopens a session in a terminal, through Sidemoon's channel.
    case copyResumeCommand
    /// That command is not installed yet: open Setup, whose terminal step installs it.
    case installTerminalCommand
    case chooseAnotherSession
    /// Words only: sign in again from the session's terminal.
    case runLogin
    /// Turn on Setup's "Connect every claude", so the next plain `claude` typed in a terminal can be reached.
    case connectEveryClaude
    /// Show the background session itself in Terminal (`claude attach <short id>`), where it waits on a question.
    case attachInTerminal
}

/// The "Try it" guide: three things to do once, each ticked when the user has really done it.
public struct GuideProgress: Equatable, Sendable {
    /// Chose the session to talk to.
    public var pickedSession: Bool
    /// Sent a screenshot that was delivered.
    public var sentCapture: Bool
    /// Typed a reply to a session that had answered, and it was delivered.
    public var replied: Bool

    public init(pickedSession: Bool = false, sentCapture: Bool = false, replied: Bool = false) {
        self.pickedSession = pickedSession
        self.sentCapture = sentCapture
        self.replied = replied
    }

    public var isComplete: Bool { pickedSession && sentCapture && replied }
    public var doneCount: Int { [pickedSession, sentCapture, replied].filter { $0 }.count }
}

// MARK: - Status state machine

/// What the companion is doing. The mascot's indicator is derived from this plus `unseenReply`.
public enum Activity: Equatable, Sendable {
    case idle
    case capturing
    /// A capture is taken and held while the user may add a note (the active-window hotkey).
    case holding
    case sending
    case waiting
    case failed(CompanionError)

    public var isBusy: Bool {
        switch self {
        case .capturing, .holding, .sending, .waiting: return true
        case .idle, .failed: return false
        }
    }
}

/// The five states the mascot shows.
public enum Indicator: String, Equatable, Sendable, CaseIterable {
    case idle, sending, waiting, replyReady, error

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .sending: return "Sending"
        case .waiting: return "Waiting for reply"
        case .replyReady: return "Reply ready"
        case .error: return "Problem"
        }
    }
}

public enum StatusEvent: Equatable, Sendable {
    case captureBegan
    case captureCancelled
    /// The capture is taken and held for a note before sending.
    case captureHeld
    /// The held capture was discarded without sending.
    case heldCaptureDiscarded
    case sendBegan
    /// The target session started its turn while we were sending.
    case targetStartedWorking
    /// Our own send finished. `hasReply` is false when it was delivered without a reply to show.
    case sendSucceeded(hasReply: Bool)
    /// The target finished a turn Sidemoon may not have triggered, with new reply text.
    case replyArrived
    case failed(CompanionError)
    case bubbleOpened
    case errorDismissed
}

public struct CompanionStatus: Equatable, Sendable {
    public var activity: Activity = .idle
    public var unseenReply = false

    public init(activity: Activity = .idle, unseenReply: Bool = false) {
        self.activity = activity
        self.unseenReply = unseenReply
    }

    public var indicator: Indicator {
        switch activity {
        case .failed: return .error
        case .capturing, .holding, .sending: return .sending
        case .waiting: return .waiting
        case .idle: return unseenReply ? .replyReady : .idle
        }
    }

    /// Applies an event. Returns false when the event does not apply in the current state (it is then ignored).
    @discardableResult
    public mutating func handle(_ event: StatusEvent) -> Bool {
        switch event {
        case .captureBegan:
            // Only another capture holds this up; a message on its way to some session does not.
            guard activity != .capturing, activity != .holding else { return false }
            activity = .capturing
        case .captureCancelled:
            guard activity == .capturing else { return false }
            activity = .idle
        case .captureHeld:
            guard activity == .capturing else { return false }
            activity = .holding
        case .heldCaptureDiscarded:
            guard activity == .holding else { return false }
            activity = .idle
        case .sendBegan:
            // Always allowed: messages to different sessions travel side by side.
            activity = .sending
        case .targetStartedWorking:
            guard activity == .sending else { return false }
            activity = .waiting
        case let .sendSucceeded(hasReply):
            guard activity == .sending || activity == .waiting else { return false }
            activity = .idle
            if hasReply { unseenReply = true }
        case .replyArrived:
            unseenReply = true
            // A fresh instruction replaces an old error; an in-flight send keeps its own state.
            if case .failed = activity { activity = .idle }
        case let .failed(error):
            activity = .failed(error)
        case .bubbleOpened:
            unseenReply = false
        case .errorDismissed:
            guard case .failed = activity else { return false }
            activity = .idle
        }
        return true
    }
}

// MARK: - Paste

/// What Command-V in the composer does with what is on the clipboard.
public enum PasteContent: Equatable, Sendable {
    /// Pasted into the text field as usual.
    case text
    /// Files copied in the Finder: added to the message like dropped files.
    case files([URL])
    /// Image data (a screenshot copied to the clipboard): written to a file and added like a capture. `type` is the
    /// clipboard type to read it from.
    case image(type: String)

    /// Decided from a description of the clipboard, so it can be tested without one. `types`: its type identifiers;
    /// `fileURLs`: the file URLs it holds. Files come first (the Finder adds their names as text); then text, which
    /// is pasted exactly as before; an image only when no text comes with it.
    public static func of(types: [String], fileURLs: [URL]) -> PasteContent {
        let p = CompanionConstants.Paste.self
        if !fileURLs.isEmpty { return .files(fileURLs) }
        if types.contains(where: p.textTypes.contains) { return .text }
        if let image = p.imageTypes.first(where: types.contains) { return .image(type: image) }
        return .text
    }
}

// MARK: - Held capture (note grace period)

/// Waits for a duration. Injected so tests drive the countdown without real waiting.
public typealias Sleeper = @Sendable (TimeInterval) async -> Void

public enum Sleepers {
    /// Real time; returns early when the task is cancelled.
    public static let system: Sleeper = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
}

/// The grace period before a held capture is sent without a note.
/// Counted in whole ticks so floating-point drift never adds an extra tick.
public struct NoteCountdown: Equatable, Sendable {
    public let tickInterval: TimeInterval
    public let totalTicks: Int
    public private(set) var elapsedTicks = 0

    public init(total: TimeInterval = CompanionConstants.Timing.noteGracePeriod,
                tick: TimeInterval = CompanionConstants.Timing.noteCountdownTick) {
        tickInterval = tick
        totalTicks = tick > 0 ? max(0, Int((total / tick).rounded(.up))) : 0
    }

    public var isExpired: Bool { elapsedTicks >= totalTicks }
    private var remainingTicks: Int { max(0, totalTicks - elapsedTicks) }
    /// 1 at the start, 0 when the grace period is over.
    public var fractionRemaining: Double { totalTicks > 0 ? Double(remainingTicks) / Double(totalTicks) : 0 }
    /// Whole seconds left, rounded up, for the label (integer arithmetic, so 3 s shows as 3, not 4).
    public var secondsLeft: Int {
        let ticksPerSecond = tickInterval > 0 ? max(1, Int((1 / tickInterval).rounded())) : 1
        return (remainingTicks + ticksPerSecond - 1) / ticksPerSecond
    }

    public mutating func tick() { elapsedTicks = min(totalTicks, elapsedTicks + 1) }
}

/// The captures waiting to go out in one message, in the order they were taken. Each press of a capture shortcut
/// while they wait adds one, up to `limit`.
public struct PendingCaptures: Equatable, Sendable {
    public private(set) var urls: [URL] = []
    public let limit: Int

    public init(limit: Int = CompanionConstants.Capture.maxPerMessage) { self.limit = limit }

    public var isEmpty: Bool { urls.isEmpty }
    public var count: Int { urls.count }
    public var isFull: Bool { urls.count >= limit }

    /// Adds a capture at the end. False (nothing changes) when full or already there.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        guard !isFull, !urls.contains(url) else { return false }
        urls.append(url)
        return true
    }

    /// Takes one out, keeping the order of the others. False when it was not there.
    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        guard let index = urls.firstIndex(of: url) else { return false }
        urls.remove(at: index)
        return true
    }

    public mutating func removeAll() { urls = [] }

    /// How each capture is named on its chip and in the thread, in order.
    public var names: [String] {
        urls.indices.map { CompanionConstants.Messages.captureAttachmentName(number: $0 + 1, of: urls.count) }
    }

    /// The text that goes with them when nothing is typed.
    public var defaultText: String { CompanionConstants.Messages.defaultCaptureText(count: urls.count) }
}

/// What happens to a held capture.
public enum HeldCaptureDecision: Equatable, Sendable {
    /// Send it; nil or empty note means the default message.
    case send(note: String?)
    case discard
}

/// The keys that move between the thread and the session list.
/// `delete` hides the highlighted session while the list shows (and the composer is empty).
public enum NavigationKey: Equatable, Sendable { case left, right, up, down, enter, escape, delete }

// MARK: - Session list

/// One line of the target picker.
public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let folder: String?
    public let stateText: String
    /// Whether a message can get to it at all, and if not, why.
    public let reachability: Reachability
    public let ended: Bool
    public let state: SessionState
    /// Hidden from the list by the user; only listed while "Show hidden" is on.
    public var hidden = false
    /// A `claude --bg` session: "Open in Terminal" attaches to it.
    public var isBackground = false
    /// General or another chat: no folder, nothing to open in Terminal.
    public var isChat = false
    /// Everything but General can be hidden.
    public var canHide: Bool { TargetRule.canHide(id) }
    /// Whether a message can get to it at all. A busy session still counts: messages wait for it.
    public var reachable: Bool { reachability == .reachable }
    /// Why Claude Code would refuse it; nil when nothing is known to stand in the way.
    public var blocker: ResumeBlocker? {
        if case let .blocked(b) = reachability { return b }
        return nil
    }

    /// Single-line text for an NSMenuItem.
    public var menuTitle: String {
        var parts = [title]
        if let folder, folder != title { parts.append(folder) }
        parts.append(stateText)
        return parts.joined(separator: "  ·  ")
    }
}

/// Whether a session can be sent to.
public enum Reachability: Equatable, Sendable {
    case reachable
    /// A terminal session started without Sidemoon's channel (plain `claude`, not `sidemoon-claude`).
    case needsChannel
    /// Sidemoon's helper runs with the session, but Claude Code does not pass on what it sends, and no other
    /// route reaches it.
    case channelDropped
    /// A background session Claude Code would not reopen.
    case blocked(ResumeBlocker)
    /// Not running with the channel, and its folder no longer exists: nothing can reopen it.
    case folderGone
}

/// Where messages go. A message only ever goes to the session shown as the target, and the target changes only
/// when the user picks another session or starts one: never on its own, whatever becomes of the chosen session
/// (unreachable, ended, hidden, gone, after an error or a restart). General is chosen without the user only when
/// nothing was ever chosen.
public enum TargetRule {
    public static var general: String { Constants.Chat.generalId }

    /// The target when the companion starts: the saved choice, else General.
    public static func initial(saved: String?) -> String { saved ?? general }

    /// General is always there: it cannot be hidden.
    public static func canHide(_ id: String) -> Bool { id != general }
}

/// The name of a new chat: the start of its first message.
public enum ChatNaming {
    /// The first words of the message, on one line, cut at a word to `CompanionConstants.Chat.nameCharacters`.
    public static func name(from message: String) -> String {
        let limit = CompanionConstants.Chat.nameCharacters
        let words = message.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var name = ""
        for word in words {
            let next = name.isEmpty ? word : name + " " + word
            if next.count > limit {
                if name.isEmpty { name = String(word.prefix(limit)) }
                return name + CompanionConstants.Chat.nameEllipsis
            }
            name = next
        }
        return name.isEmpty ? Design.Copy.NewSession.chatHeading : name
    }
}

public enum SessionList {
    /// General's own name; else its name, else the folder it runs in, else its short id.
    public static func displayName(_ s: Session) -> String {
        if s.id == TargetRule.general { return Design.Copy.Chat.general }
        if let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let folder = folderName(s) { return folder }
        return SessionID.short(s.id)
    }

    public static func folderName(_ s: Session) -> String? {
        guard s.kind != .chat, let cwd = s.cwd, !cwd.isEmpty else { return nil }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    /// A chat says it is one while it is ready; working is working for any session.
    public static func stateText(_ s: Session) -> String {
        s.kind == .chat && s.state != .working ? Design.Copy.Chat.kind : stateText(s.state)
    }

    public static func stateText(_ state: SessionState) -> String {
        switch state {
        case .working: return "working"
        case .idle: return "ready"
        case .needsInput: return "needs you"
        case .ended: return "ended"
        }
    }

    /// Whether a message can get to the session at all: over a route open now, or by waiting for a
    /// background session to finish its turn. Only a terminal session started without the channel cannot.
    public static func isReachable(_ s: Session, checks: PathChecks = .everythingExists) -> Bool {
        reachability(s, checks: checks) == .reachable
    }

    /// The channel reaches a session wherever it runs; any other route reopens it in its folder, so a session whose
    /// folder is gone is out of reach, and a background session is when Claude Code would refuse to reopen it.
    public static func reachability(_ s: Session, checks: PathChecks = .everythingExists) -> Reachability {
        if s.channelConnected || s.kind == .chat { return .reachable }
        if let cwd = s.cwd, !cwd.isEmpty, !checks.folderExists(cwd) { return .folderGone }
        if s.kind == .background, let blocker = s.blocker { return .blocked(blocker) }
        if !s.routes.isEmpty || s.kind == .background { return .reachable }
        return s.channelDropped ? .channelDropped : .needsChannel
    }

    /// The session to talk to when none is chosen: the most recently active one that can be reached and is not
    /// hidden.
    public static func defaultTarget(_ sessions: [Session], hidden: Set<String> = [], checks: PathChecks = .everythingExists) -> String? {
        let all = rows(sessions, showEnded: true, hidden: hidden, checks: checks)
        return all.first { $0.reachable && !$0.ended }?.id ?? all.first { $0.reachable }?.id
    }

    /// Picker rows: ended sessions left out unless asked for, hidden ones unless "Show hidden" is on, most recently
    /// active first.
    public static func rows(_ sessions: [Session], showEnded: Bool, hidden: Set<String> = [], showHidden: Bool = false,
                            checks: PathChecks = .everythingExists) -> [SessionRow] {
        sessions
            .filter { (showEnded || $0.state != .ended) && (showHidden || !hidden.contains($0.id)) }
            // General first, then the most recently active.
            .sorted { a, b in
                if (a.id == TargetRule.general) != (b.id == TargetRule.general) { return a.id == TargetRule.general }
                let ta = a.activityAt ?? .distantPast, tb = b.activityAt ?? .distantPast
                return ta != tb ? ta > tb : a.id < b.id
            }
            .map { s in
                var row = SessionRow(id: s.id, title: displayName(s), folder: folderName(s), stateText: stateText(s),
                                     reachability: reachability(s, checks: checks), ended: s.state == .ended, state: s.state)
                row.hidden = hidden.contains(s.id)
                row.isBackground = s.kind == .background
                row.isChat = s.kind == .chat
                return row
            }
    }
}

// MARK: - Window geometry

public enum ScreenEdge: Equatable, Sendable { case left, right, top, bottom }

public enum EdgeSnap {
    /// The screen edge closest to the frame's center.
    public static func nearestEdge(of frame: CGRect, in visible: CGRect) -> ScreenEdge {
        let distances: [(ScreenEdge, CGFloat)] = [
            (.left, frame.midX - visible.minX),
            (.right, visible.maxX - frame.midX),
            (.bottom, frame.midY - visible.minY),
            (.top, visible.maxY - frame.midY),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// Keeps the frame fully inside `visible`, `margin` away from its sides.
    public static func clamped(_ frame: CGRect, in visible: CGRect, margin: CGFloat) -> CGRect {
        let inner = visible.insetBy(dx: margin, dy: margin)
        var f = frame
        f.origin.x = min(max(f.minX, inner.minX), max(inner.minX, inner.maxX - f.width))
        f.origin.y = min(max(f.minY, inner.minY), max(inner.minY, inner.maxY - f.height))
        return f
    }

    /// Moves the frame flush against the nearest edge (minus margin), staying fully on screen.
    public static func snapped(_ frame: CGRect, in visible: CGRect, margin: CGFloat) -> CGRect {
        var f = clamped(frame, in: visible, margin: margin)
        switch nearestEdge(of: frame, in: visible) {
        case .left: f.origin.x = visible.minX + margin
        case .right: f.origin.x = visible.maxX - margin - f.width
        case .bottom: f.origin.y = visible.minY + margin
        case .top: f.origin.y = visible.maxY - margin - f.height
        }
        return f
    }

    /// Index of the screen containing the point, else the one whose frame is nearest to it.
    public static func screenIndex(for point: CGPoint, in screens: [CGRect]) -> Int? {
        if let hit = screens.firstIndex(where: { $0.contains(point) }) { return hit }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// Where the bubble goes: beside the mascot on the side with more room, top-aligned with it,
    /// kept on screen.
    public static func bubbleFrame(mascot: CGRect, bubble: CGSize, visible: CGRect, gap: CGFloat, margin: CGFloat) -> CGRect {
        let roomRight = visible.maxX - mascot.maxX
        let roomLeft = mascot.minX - visible.minX
        let x = roomRight >= roomLeft ? mascot.maxX + gap : mascot.minX - gap - bubble.width
        let y = mascot.maxY - bubble.height
        return clamped(CGRect(origin: CGPoint(x: x, y: y), size: bubble), in: visible, margin: margin)
    }

    /// Default mascot spot: right edge, vertically centered.
    public static func defaultFrame(size: CGFloat, visible: CGRect, margin: CGFloat) -> CGRect {
        CGRect(x: visible.maxX - margin - size, y: visible.midY - size / 2, width: size, height: size)
    }
}
