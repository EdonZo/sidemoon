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
    private let answerProbe: @Sendable (_ sessionId: String, _ transcriptHint: String?) -> Bool?
    /// Whether a session surely has no transcript at all, given the transcript paths of the other listed sessions as
    /// evidence of where Claude Code keeps them (`TranscriptReader.isAbsent`).
    private let absenceProbe: @Sendable (_ sessionId: String, _ evidence: [String]) -> Bool
    /// The model of a transcript's last answer (`TranscriptReader.lastModel`).
    private let modelProbe: @Sendable (_ transcriptPath: String) -> String?
    /// What was last read for each session's model, with the transcript's size and date then: read again only when
    /// the file changed.
    private var modelCache: [String: (path: String, size: UInt64, modified: Date, model: String?)] = [:]
    /// Sessions known to have finished an answer. A transcript only grows, so this never has to be undone.
    private var answered: Set<String> = []
    /// When each session last reported a UserPromptSubmit hook.
    private var promptSubmittedAt: [String: Date] = [:]
    /// Where Sidemoon's chats run (normalized). The Claude Code sessions of those runs report through the hooks like
    /// any other; they are the chats' own business, so they are kept out of the list and out of the changes.
    private var chatFolder: String?
    /// The user's home folder, where Claude Code on some Macs will not reopen a background session.
    public let home: String
    /// Whether this Mac's Claude Code has been seen refusing that.
    public let homeFolderMemory: HomeFolderMemory

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

    /// - Parameters:
    ///   - turnProbe: whether a session's last turn is still going, read from its transcript.
    ///   - answerProbe: whether a session has finished an answer yet, read from its transcript (nil: cannot tell).
    ///   - absenceProbe: whether a session surely has no transcript anywhere (only asked about blocked sessions).
    public init(replyReader: @escaping @Sendable (HookEvent) -> String? = { TranscriptReader.reply(for: $0) },
                turnProbe: @escaping @Sendable (AgentInfo) -> Bool? = { agent in
                    agent.transcriptPath.flatMap(TranscriptReader.turnIsOpen(transcriptPath:))
                },
                answerProbe: @escaping @Sendable (String, String?) -> Bool? = { TranscriptReader.sessionHasAnswered($0, hint: $1) },
                absenceProbe: @escaping @Sendable (String, [String]) -> Bool = { TranscriptReader.isAbsent($0, evidence: $1) },
                modelProbe: @escaping @Sendable (String) -> String? = { TranscriptReader.lastModel(transcriptPath: $0) },
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                homeFolderMemory: HomeFolderMemory = .inMemory()) {
        self.replyReader = replyReader
        self.turnProbe = turnProbe
        self.answerProbe = answerProbe
        self.absenceProbe = absenceProbe
        self.modelProbe = modelProbe
        self.home = home
        self.homeFolderMemory = homeFolderMemory
    }

    /// Records whether Claude Code just refused (true) or reopened (false) a background session in the home
    /// folder. Forgetting a refusal frees the home-folder sessions at once; a new refusal greys the other running
    /// ones at the next listing (the refused session itself is marked by the engine).
    public func homeFolderResume(refused: Bool) {
        guard homeFolderMemory.set(refused: refused), !refused else { return }
        let changed: [Session] = lock.withLock {
            var changed: [Session] = []
            for (id, s) in sessions where s.blocker == .homeFolder {
                sessions[id]?.blocker = nil
                changed.append(sessions[id] ?? s)
            }
            return changed
        }
        changed.forEach(emit)
    }

    /// Whether this session is in the middle of a turn right now.
    public func isMidTurn(_ agent: AgentInfo) -> Bool { agent.isMidTurn(turnIsOpen: turnProbe) }

    /// The model of the session's last answer, read from its transcript only when the file changed since last time.
    public func model(_ sessionId: String, transcriptPath: String?) -> String? {
        guard let path = transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, let modified = attrs[.modificationDate] as? Date else {
            return lock.withLock { modelCache[sessionId]?.model }
        }
        if let known = lock.withLock({ modelCache[sessionId] }), known.path == path, known.size == size, known.modified == modified {
            return known.model
        }
        let model = modelProbe(path)
        lock.withLock { modelCache[sessionId] = (path, size, modified, model) }
        return model
    }

    /// Whether the session has finished an answer: remembered once it has, else read from its transcript.
    public func hasAnswered(_ sessionId: String, transcriptHint: String?) -> Bool? {
        if lock.withLock({ answered.contains(sessionId) }) { return true }
        let result = answerProbe(sessionId, transcriptHint)
        if result == true { lock.withLock { _ = answered.insert(sessionId) } }
        return result
    }

    // MARK: Reading

    public func snapshot() -> [Session] {
        lock.withLock { Array(sessions.values) }.filter { !isChatRun($0) }.sorted { ($0.activityAt ?? .distantPast) > ($1.activityAt ?? .distantPast) }
    }

    public func session(_ id: String) -> Session? { lock.withLock { sessions[id.lowercased()] } }

    /// When the session last reported a submitted prompt (its UserPromptSubmit hook).
    public func lastPromptSubmit(_ sessionId: String) -> Date? { lock.withLock { promptSubmittedAt[sessionId.lowercased()] } }

    /// The session a Claude Code process currently hosts, according to its hooks.
    public func sessionId(forPid pid: Int32) -> String? { lock.withLock { pidToSession[pid] } }

    /// Resolves a full id or a unique prefix (e.g. the 8-character agent id).
    public func resolve(_ idOrPrefix: String) -> Session? {
        let key = idOrPrefix.lowercased()
        let found: Session? = lock.withLock {
            if let s = sessions[key] { return s }
            let matches = sessions.values.filter { $0.id.hasPrefix(key) }
            return matches.count == 1 ? matches[0] : nil
        }
        return found.flatMap { isChatRun($0) ? nil : $0 }
    }

    // MARK: Chats

    /// Keeps the Claude Code sessions run in this folder (the chats' runs) out of the list and the changes.
    public func hideRuns(in folder: String) {
        let normal = ChatFolder.normal(folder)
        lock.withLock { chatFolder = normal }
    }

    /// Whether this is the Claude Code session of a chat's run, not a session of its own.
    public func isChatRun(_ s: Session) -> Bool {
        guard s.kind != .chat, let folder = lock.withLock({ chatFolder }) else { return false }
        return ChatFolder.contains(s.cwd, folder: folder)
    }

    /// Adds or replaces a chat as the list shows it.
    public func setChat(_ chat: Session) {
        var s = chat
        s.kind = .chat
        let changed: Bool = lock.withLock {
            guard sessions[s.id] != s else { return false }
            sessions[s.id] = s
            return true
        }
        if changed { emit(s) }
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
        guard !isChatRun(s) else { return }
        let handlers = lock.withLock { Array(observers.values) }
        handlers.forEach { $0(.updated(s)) }
    }

    // MARK: Writing

    /// Applies a hook event. Returns the updated session.
    @discardableResult
    public func apply(_ e: HookEvent) -> Session {
        // Parse the transcript outside the lock: it is file IO.
        let fullReply = e.eventName == Constants.HookEvents.stop ? (replyReader(e) ?? e.lastAssistantMessage) : nil
        let answeredWith = e.eventName == Constants.HookEvents.stop ? model(e.sessionId, transcriptPath: e.transcriptPath) : nil
        var waitersToFire: [StopWaiter] = []
        let s: Session = lock.withLock {
            var s = sessions[e.sessionId] ?? Session(id: e.sessionId)
            s.cwd = e.cwd ?? s.cwd
            s.transcriptPath = e.transcriptPath ?? s.transcriptPath
            s.scratchpadDir = e.scratchpadDir ?? s.scratchpadDir
            s.lastEventName = e.eventName
            s.lastEventAt = e.receivedAt
            // The session ran somewhere just now, so what a refused resume taught no longer holds. The home
            // folder is a fact about the session and is checked again on the next listing.
            if s.blocker != .homeFolder { s.blocker = nil }
            if let pid = e.claudePid {
                s.pid = pid
                if e.eventName == Constants.HookEvents.sessionEnd {
                    if pidToSession[pid] == e.sessionId { pidToSession[pid] = nil }
                } else {
                    // A /clear or resume inside the same process moves the binding to the new session.
                    if let old = pidToSession[pid], old != e.sessionId {
                        sessions[old]?.channelConnected = false
                        sessions[old]?.channelDropped = false
                    }
                    pidToSession[pid] = e.sessionId
                }
            }
            switch e.eventName {
            case Constants.HookEvents.sessionStart: s.state = .idle
            case Constants.HookEvents.userPromptSubmit:
                s.state = .working
                promptSubmittedAt[e.sessionId] = e.receivedAt
            case Constants.HookEvents.stop:
                // A session that ends right after its answer sends Stop and SessionEnd together, and the end
                // can be applied first (reading the reply for Stop takes a moment). Ended stays ended; a
                // session that is resumed says so with SessionStart before its next Stop.
                if s.state != .ended { s.state = .idle }
                s.lastReply = fullReply
                s.lastReplyAt = e.receivedAt
                if let answeredWith { s.model = answeredWith }
            case Constants.HookEvents.notification:
                if e.notificationType == Constants.HookEvents.notificationPermission { s.state = .needsInput }
                if e.notificationType == Constants.HookEvents.notificationIdle { s.state = .idle }
            case Constants.HookEvents.sessionEnd:
                s.state = .ended
                s.channelConnected = false
                s.channelDropped = false
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
        let hints = lock.withLock { agents.map { sessions[$0.sessionId]?.transcriptPath } }
        var answeredNow: [String: Bool] = [:]
        let evidence = agents.compactMap(\.transcriptPath)
        for (a, hint) in zip(agents, hints) where a.kind == SessionKind.background.rawValue && !midTurn.contains(a.sessionId) {
            var answered = hasAnswered(a.sessionId, transcriptHint: hint ?? a.transcriptPath)
            // A session that never ran a turn has no folder for its working directory yet, so the transcript
            // check cannot be sure. For a blocked one, no transcript anywhere where Claude Code keeps them is enough.
            if answered == nil, ResumeCheck.isBlocked(a), absenceProbe(a.sessionId, evidence) { answered = false }
            answeredNow[a.sessionId] = answered
        }
        // The models, read only from transcripts that changed.
        var models: [String: String] = [:]
        for (a, hint) in zip(agents, hints) {
            if let model = model(a.sessionId, transcriptPath: hint ?? a.transcriptPath) { models[a.sessionId] = model }
        }
        lock.withLock {
            for a in agents {
                var s = sessions[a.sessionId] ?? Session(id: a.sessionId)
                let before = s
                if let model = models[a.sessionId] { s.model = model }
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
                if s.kind == .background {
                    // A session still on its first turn has not answered yet, and is not blocked for that.
                    // Only a running session is stopped before it is resumed, so only there does a missing
                    // answer matter beforehand: Claude Code reopens a stopped session that never answered.
                    // A blocked one that never answered is the exception, running or not: it waits on a question in
                    // its terminal, and resuming it makes Claude Code start a new session instead.
                    let blocked = ResumeCheck.isBlocked(a)
                    let answered = s.state == .working || (!a.isRunning && !blocked) ? nil : answeredNow[a.sessionId] ?? nil
                    // The same goes for the home folder: a stopped one is left for Claude Code to judge, and
                    // its answer is what keeps or clears the memory of a refusal.
                    let homeRefused = a.isRunning && homeFolderMemory.refused
                    if let seen = ResumeCheck.blocker(cwd: s.cwd ?? a.cwd, home: home, answered: answered, homeFolderRefused: homeRefused,
                                                      blockedInTerminal: blocked) {
                        s.blocker = seen
                    } else if s.blocker == .homeFolder || s.blocker == .noTranscript || s.blocker == .waitingInTerminal {
                        s.blocker = nil
                    }
                }
                if s != before {
                    sessions[a.sessionId] = s
                    changed.append(s)
                }
            }
        }
        changed.forEach(emit)
    }

    /// `dropped`: a helper is bound to the session but Claude Code does not pass on what it sends (only when not
    /// `connected`).
    public func setChannel(sessionId: String, connected: Bool, dropped: Bool = false) {
        let dropped = dropped && !connected
        let s: Session? = lock.withLock {
            guard var s = sessions[sessionId] else {
                guard connected || dropped else { return nil }
                var fresh = Session(id: sessionId)
                fresh.channelConnected = connected
                fresh.channelDropped = dropped
                fresh.kind = .interactive
                sessions[sessionId] = fresh
                return fresh
            }
            guard s.channelConnected != connected || s.channelDropped != dropped else { return nil }
            s.channelConnected = connected
            s.channelDropped = dropped
            if connected || dropped, s.kind == .unknown { s.kind = .interactive }
            sessions[sessionId] = s
            return s
        }
        if let s { emit(s) }
    }

    /// Records what a refused resume said about the session, so the session list can show it.
    public func setBlocker(sessionId: String, _ blocker: ResumeBlocker?) {
        let s: Session? = lock.withLock {
            guard var s = sessions[sessionId], s.blocker != blocker else { return nil }
            s.blocker = blocker
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

    /// Ends every wait for this session's next answer at once, with none: the user stopped it.
    public func releaseWaits(sessionId: String) {
        let waiting = lock.withLock { stopWaiters.values.filter { $0.sessionId == sessionId } }
        waiting.forEach { $0.semaphore.signal() }
    }
}
