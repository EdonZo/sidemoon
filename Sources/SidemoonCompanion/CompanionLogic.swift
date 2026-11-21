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

    public var title: String {
        switch self {
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

    /// Maps an engine result to a companion error. Only called for failed results.
    public static func from(_ result: SendResult) -> CompanionError {
        switch result.failure {
        case .busy?: return .busy
        case .noRoute?: return .noRoute
        case .noScratchpad?: return .noScratchpad
        case .unknownSession?: return .unknownSession
        case .replyTimeout?: return .replyTimeout
        case .forked?: return .forked
        default: return .delivery(result.error ?? "The engine did not say why.")
        }
    }
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

/// What happens to a held capture.
public enum HeldCaptureDecision: Equatable, Sendable {
    /// Send it; nil or empty note means the default message.
    case send(note: String?)
    case discard
}

/// The keys that move between the thread and the session list.
public enum NavigationKey: Equatable, Sendable { case left, right, up, down, enter, escape }

// MARK: - Session list

/// One line of the target picker.
public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let folder: String?
    public let stateText: String
    /// Whether a message can get to it at all. A busy session still counts: messages wait for it.
    public let reachable: Bool
    public let ended: Bool
    public let state: SessionState

    /// Single-line text for an NSMenuItem.
    public var menuTitle: String {
        var parts = [title]
        if let folder, folder != title { parts.append(folder) }
        parts.append(stateText)
        return parts.joined(separator: "  ·  ")
    }
}

public enum SessionList {
    /// Name, else the folder it runs in, else its short id.
    public static func displayName(_ s: Session) -> String {
        if let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let folder = folderName(s) { return folder }
        return SessionID.short(s.id)
    }

    public static func folderName(_ s: Session) -> String? {
        guard let cwd = s.cwd, !cwd.isEmpty else { return nil }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
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
    public static func isReachable(_ s: Session) -> Bool { !s.routes.isEmpty || s.kind == .background }

    /// Picker rows: ended sessions hidden unless asked for, most recently active first.
    public static func rows(_ sessions: [Session], showEnded: Bool) -> [SessionRow] {
        sessions
            .filter { showEnded || $0.state != .ended }
            .sorted { a, b in
                let ta = a.activityAt ?? .distantPast, tb = b.activityAt ?? .distantPast
                return ta != tb ? ta > tb : a.id < b.id
            }
            .map { s in
                SessionRow(id: s.id, title: displayName(s), folder: folderName(s), stateText: stateText(s.state),
                           reachable: isReachable(s), ended: s.state == .ended, state: s.state)
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
