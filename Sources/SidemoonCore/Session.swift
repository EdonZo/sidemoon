import Foundation

public enum SessionState: String, Sendable, Codable {
    case working, idle
    case needsInput = "needs-input"
    case ended
}

public enum SessionKind: String, Sendable, Codable {
    case interactive, background, unknown
    /// A conversation Sidemoon owns (General, or a chat started with "+"): one `claude -p` run per message.
    case chat
}

/// Delivery routes, in the order the engine prefers them.
public enum Route: String, Sendable, Codable, CaseIterable {
    case channel, background, headless
}

public struct Session: Sendable, Equatable, Codable {
    public var id: String
    public var kind: SessionKind = .unknown
    public var cwd: String?
    public var transcriptPath: String?
    public var scratchpadDir: String?
    public var name: String?
    public var state: SessionState = .idle
    public var lastReply: String?
    /// When the turn that produced `lastReply` ended. Tells a new reply from the same one seen again;
    /// kept in memory only.
    public var lastReplyAt: Date?
    public var lastEventName: String?
    public var lastEventAt: Date?
    /// When the session was last active according to its transcript file or its start time. Used for
    /// sessions that have sent no hook event since the companion started; kept in memory only.
    public var transcriptActivityAt: Date?
    /// The most recent sign of life, from hooks or from the transcript. Sessions are listed by it.
    public var activityAt: Date? {
        switch (lastEventAt, transcriptActivityAt) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b): return b
        }
    }
    /// Claude Code process id, when known (from hooks or `claude agents`).
    public var pid: Int32?
    /// Short id that `claude stop` takes (background sessions only).
    public var agentId: String?
    public var channelConnected = false
    /// Sidemoon's helper runs in the process that hosts this session, but Claude Code does not pass on what it
    /// sends: it was not loaded as a channel, or a delivery through it was not picked up. Never set together with
    /// `channelConnected`.
    public var channelDropped = false
    /// What would make Claude Code refuse to reopen this background session, when something is known to:
    /// seen before sending (its folder, its transcript) or learned from a refused resume. Nil when nothing is.
    public var blocker: ResumeBlocker?
    /// The model id its last answer came from (`claude-opus-5-5`), read from its transcript; nil before any answer.
    public var model: String?
    /// Routes that are available right now, in preference order.
    public var routes: [Route] {
        var r: [Route] = []
        if channelConnected { r.append(.channel) }
        if kind == .background, state != .working { r.append(.background) }
        if kind != .background, kind != .chat, state == .ended { r.append(.headless) }
        if kind == .chat, state != .working { r.append(.headless) }
        return r
    }

    public init(id: String) { self.id = id }

    enum CodingKeys: String, CodingKey {
        case id, kind, cwd, transcriptPath, scratchpadDir, name, state, lastReply, lastEventName, lastEventAt, pid, agentId,
             channelConnected, channelDropped, routes, blocker, model
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try c.encodeIfPresent(scratchpadDir, forKey: .scratchpadDir)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(lastReply, forKey: .lastReply)
        try c.encodeIfPresent(lastEventName, forKey: .lastEventName)
        try c.encodeIfPresent(lastEventAt, forKey: .lastEventAt)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(agentId, forKey: .agentId)
        try c.encode(channelConnected, forKey: .channelConnected)
        try c.encode(channelDropped, forKey: .channelDropped)
        try c.encode(routes, forKey: .routes)
        try c.encodeIfPresent(blocker, forKey: .blocker)
        try c.encodeIfPresent(model, forKey: .model)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .unknown
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        scratchpadDir = try c.decodeIfPresent(String.self, forKey: .scratchpadDir)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        state = try c.decodeIfPresent(SessionState.self, forKey: .state) ?? .idle
        lastReply = try c.decodeIfPresent(String.self, forKey: .lastReply)
        lastEventName = try c.decodeIfPresent(String.self, forKey: .lastEventName)
        lastEventAt = try c.decodeIfPresent(Date.self, forKey: .lastEventAt)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        channelConnected = try c.decodeIfPresent(Bool.self, forKey: .channelConnected) ?? false
        channelDropped = try c.decodeIfPresent(Bool.self, forKey: .channelDropped) ?? false
        blocker = try c.decodeIfPresent(ResumeBlocker.self, forKey: .blocker)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// One entry of `claude agents --json --all`.
public struct AgentInfo: Sendable, Equatable {
    public var agentId: String
    public var sessionId: String
    public var pid: Int32?
    public var status: String?
    public var state: String?
    public var name: String?
    public var kind: String?
    public var cwd: String?
    public var startedAt: Date?

    public var isRunning: Bool { pid != nil }

    /// Where Claude Code keeps this session's transcript: under a folder named after its working directory.
    public var transcriptPath: String? {
        guard let cwd else { return nil }
        let folder = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        return "\(Constants.Paths.claudeProjectsDirectory)/\(folder)/\(sessionId).\(Constants.Paths.transcriptExtension)"
    }

    /// When the session's transcript was last written, else when the session started.
    public var lastActivity: Date? {
        if let path = transcriptPath,
           let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date { return modified }
        return startedAt
    }

    /// Whether the session is in the middle of a turn, which is when a message must wait.
    ///
    /// The listing's own fields cannot say: a session at its prompt with a background shell still running
    /// has been seen as busy and working, exactly like one mid-turn. So a busy process only counts as
    /// mid-turn when the session's transcript shows a turn that has not ended. `turnIsOpen` reads that;
    /// when it cannot (nil), the listing's `state` is the fallback.
    public func isMidTurn(turnIsOpen: (AgentInfo) -> Bool?) -> Bool {
        // No status means no running process, and a process that is not busy is at its prompt.
        guard status == Constants.ClaudeCLI.busyStatus else { return false }
        if let open = turnIsOpen(self) { return open }
        return state.map { $0 == Constants.ClaudeCLI.workingState } ?? true
    }

    public static func parseList(_ data: Data) -> [AgentInfo]? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let sid = o["sessionId"] as? String, SessionID.isValid(sid) else { return nil }
            return AgentInfo(
                agentId: (o["id"] as? String) ?? SessionID.short(sid),
                sessionId: sid.lowercased(),
                pid: (o["pid"] as? NSNumber).map { $0.int32Value },
                status: o["status"] as? String,
                state: o["state"] as? String,
                name: o["name"] as? String,
                kind: o["kind"] as? String,
                cwd: (o["cwd"] as? String).flatMap(PathPolicy.absolute),
                // Milliseconds since 1970.
                startedAt: (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
    }
}
