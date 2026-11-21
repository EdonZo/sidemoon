import Foundation

public enum RegistryChange: Sendable {
    case updated(Session)
}

/// In-memory model of known sessions, keyed by session id. Thread safe.
public final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    /// Claude Code process id -> the session id it most recently reported through a hook.
    private var pidToSession: [Int32: String] = [:]
    private var observers: [UUID: @Sendable (RegistryChange) -> Void] = [:]
    private var stopWaiters: [UUID: StopWaiter] = [:]
    private let replyReader: @Sendable (HookEvent) -> String?
    private let turnProbe: @Sendable (AgentInfo) -> Bool?

    private final class StopWaiter: @unchecked Sendable {
        let sessionId: String
        let accept: @Sendable (HookEvent) -> Bool
        let semaphore = DispatchSemaphore(value: 0)
        var event: HookEvent?
        init(sessionId: String, accept: @escaping @Sendable (HookEvent) -> Bool) {
            self.sessionId = sessionId
            self.accept = accept
        }
    }

    /// - Parameter turnProbe: whether a session's last turn is still going, read from its transcript.
    public init(replyReader: @escaping @Sendable (HookEvent) -> String? = { TranscriptReader.reply(for: $0) },
                turnProbe: @escaping @Sendable (AgentInfo) -> Bool? = { agent in
                    agent.transcriptPath.flatMap(TranscriptReader.turnIsOpen(transcriptPath:))
                }) {
        self.replyReader = replyReader
        self.turnProbe = turnProbe
    }

    /// Whether this session is in the middle of a turn right now.
    public func isMidTurn(_ agent: AgentInfo) -> Bool { agent.isMidTurn(turnIsOpen: turnProbe) }

    // MARK: Reading

    public func snapshot() -> [Session] {
        lock.withLock { Array(sessions.values) }.sorted { ($0.activityAt ?? .distantPast) > ($1.activityAt ?? .distantPast) }
    }

    public func session(_ id: String) -> Session? { lock.withLock { sessions[id.lowercased()] } }

    /// The session a Claude Code process currently hosts, according to its hooks.
    public func sessionId(forPid pid: Int32) -> String? { lock.withLock { pidToSession[pid] } }

    /// Resolves a full id or a unique prefix (e.g. the 8-character agent id).
    public func resolve(_ idOrPrefix: String) -> Session? {
        let key = idOrPrefix.lowercased()
        return lock.withLock {
            if let s = sessions[key] { return s }
            let matches = sessions.values.filter { $0.id.hasPrefix(key) }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    // MARK: Observing

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (RegistryChange) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func unsubscribe(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    public func changes() -> AsyncStream<RegistryChange> {
        AsyncStream { continuation in
            let id = subscribe { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        }
    }

    private func emit(_ s: Session) {
        let handlers = lock.withLock { Array(observers.values) }
        handlers.forEach { $0(.updated(s)) }
    }

    // MARK: Writing

    /// Applies a hook event. Returns the updated session.
    @discardableResult
    public func apply(_ e: HookEvent) -> Session {
        // Parse the transcript outside the lock: it is file IO.
        let fullReply = e.eventName == Constants.HookEvents.stop ? (replyReader(e) ?? e.lastAssistantMessage) : nil
        var waitersToFire: [StopWaiter] = []
        let s: Session = lock.withLock {
            var s = sessions[e.sessionId] ?? Session(id: e.sessionId)
            s.cwd = e.cwd ?? s.cwd
            s.transcriptPath = e.transcriptPath ?? s.transcriptPath
            s.scratchpadDir = e.scratchpadDir ?? s.scratchpadDir
            s.lastEventName = e.eventName
            s.lastEventAt = e.receivedAt
            if let pid = e.claudePid {
                s.pid = pid
                if e.eventName == Constants.HookEvents.sessionEnd {
                    if pidToSession[pid] == e.sessionId { pidToSession[pid] = nil }
                } else {
                    // A /clear or resume inside the same process moves the binding to the new session.
                    if let old = pidToSession[pid], old != e.sessionId { sessions[old]?.channelConnected = false }
                    pidToSession[pid] = e.sessionId
                }
            }
            switch e.eventName {
            case Constants.HookEvents.sessionStart: s.state = .idle
            case Constants.HookEvents.userPromptSubmit: s.state = .working
            case Constants.HookEvents.stop:
                s.state = .idle
                s.lastReply = fullReply
                s.lastReplyAt = e.receivedAt
            case Constants.HookEvents.notification:
                if e.notificationType == Constants.HookEvents.notificationPermission { s.state = .needsInput }
                if e.notificationType == Constants.HookEvents.notificationIdle { s.state = .idle }
            case Constants.HookEvents.sessionEnd:
                s.state = .ended
                s.channelConnected = false
            default: break
            }
            sessions[e.sessionId] = s
            if e.eventName == Constants.HookEvents.stop {
                waitersToFire = stopWaiters.values.filter { $0.sessionId == e.sessionId && $0.event == nil }
            }
            return s
        }
        for w in waitersToFire where w.accept(e) {
            let first: Bool = lock.withLock {
                guard w.event == nil else { return false }
                w.event = e
                return true
            }
            if first { w.semaphore.signal() }
        }
        emit(s)
        return s
    }

    /// Seeds and refreshes sessions from `claude agents --json --all`.
    public func applyAgents(_ agents: [AgentInfo]) {
        var changed: [Session] = []
        // Read from the transcripts before taking the lock: it is file work.
        let midTurn = Set(agents.filter(isMidTurn).map(\.sessionId))
        lock.withLock {
            for a in agents {
                var s = sessions[a.sessionId] ?? Session(id: a.sessionId)
                let before = s
                s.kind = a.kind == SessionKind.background.rawValue ? .background : (a.kind == nil ? s.kind : .interactive)
                s.name = a.name ?? s.name
                s.cwd = s.cwd ?? a.cwd
                s.agentId = a.agentId
                // Whole seconds, so a transcript being written does not report a change on every refresh.
                if let active = a.lastActivity {
                    s.transcriptActivityAt = Date(timeIntervalSince1970: active.timeIntervalSince1970.rounded(.down))
                }
                if let pid = a.pid {
                    s.pid = pid
                    if midTurn.contains(a.sessionId) { s.state = .working }
                    // `claude agents` says "blocked" when a finished turn is waiting for the user's reply:
                    // that is idle, and the moment a capture is wanted. Only a permission prompt
                    // reported by a hook counts as needs-input, and it is kept until the next hook.
                    else if s.state != .ended && s.state != .needsInput { s.state = .idle }
                } else if s.state == .working || s.state == .needsInput {
                    s.state = .idle
                }
                if s != before {
                    sessions[a.sessionId] = s
                    changed.append(s)
                }
            }
        }
        changed.forEach(emit)
    }

    public func setChannel(sessionId: String, connected: Bool) {
        let s: Session? = lock.withLock {
            guard var s = sessions[sessionId] else {
                guard connected else { return nil }
                var fresh = Session(id: sessionId)
                fresh.channelConnected = true
                fresh.kind = .interactive
                sessions[sessionId] = fresh
                return fresh
            }
            guard s.channelConnected != connected else { return nil }
            s.channelConnected = connected
            if connected, s.kind == .unknown { s.kind = .interactive }
            sessions[sessionId] = s
            return s
        }
        if let s { emit(s) }
    }

    public func setReply(sessionId: String, text: String) {
        let s: Session? = lock.withLock {
            guard var s = sessions[sessionId] else { return nil }
            s.lastReply = text
            sessions[sessionId] = s
            return s
        }
        if let s { emit(s) }
    }

    // MARK: Waiting for replies

    /// Registers interest in the next accepted Stop event of a session. Call before delivering,
    /// then `wait(_:timeout:)` after.
    public func expectStop(sessionId: String, accept: @escaping @Sendable (HookEvent) -> Bool = { _ in true }) -> UUID {
        let id = UUID()
        lock.withLock { stopWaiters[id] = StopWaiter(sessionId: sessionId, accept: accept) }
        return id
    }

    public func wait(_ token: UUID, timeout: TimeInterval) -> HookEvent? {
        guard let w = lock.withLock({ stopWaiters[token] }) else { return nil }
        _ = w.semaphore.wait(timeout: .now() + timeout)
        return lock.withLock {
            stopWaiters[token] = nil
            return w.event
        }
    }

    public func cancelWait(_ token: UUID) { _ = lock.withLock { stopWaiters.removeValue(forKey: token) } }
}
