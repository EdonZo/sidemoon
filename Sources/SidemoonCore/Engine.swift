import Foundation

/// The engine: listens on the socket, keeps the registry, and delivers messages.
public final class Engine: @unchecked Sendable {
    public let registry: SessionRegistry
    public let socketPath: String
    let runner: ClaudeRunner
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var channels: [Int32: ChannelLink] = [:]

    final class ChannelLink: @unchecked Sendable {
        let conn: LineConnection
        let claudePid: Int32
        let envSessionId: String?
        var boundSession: String?
        var pendingAcks: [String: DispatchSemaphore] = [:]
        init(conn: LineConnection, claudePid: Int32, envSessionId: String?) {
            self.conn = conn
            self.claudePid = claudePid
            self.envSessionId = envSessionId
        }
    }

    public init(socketPath: String = Constants.Paths.socketPath, runner: ClaudeRunner = SystemClaudeRunner(),
                registry: SessionRegistry = SessionRegistry()) {
        self.socketPath = socketPath
        self.runner = runner
        self.registry = registry
    }

    // MARK: Lifecycle

    /// Binds the socket and starts serving on background threads.
    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: Constants.Permissions.directory])
        chmod(dir, Constants.Permissions.directory)
        let fd = try UnixSocket.listen(path: socketPath)
        lock.withLock { listenFD = fd }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        Thread.detachNewThread { [self] in
            while true {
                refreshAgents()
                Thread.sleep(forTimeInterval: Constants.Timeouts.agentsRefreshInterval)
            }
        }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { close(fd); unlink(socketPath) }
    }

    @discardableResult
    public func refreshAgents() -> [AgentInfo]? {
        let r = runner.run(Constants.ClaudeCLI.agentsArgs, cwd: nil, stdin: nil, timeout: Constants.Timeouts.cliCommand)
        guard r.status == 0, let agents = AgentInfo.parseList(r.stdout) else { return nil }
        registry.applyAgents(agents)
        return agents
    }

    // MARK: Socket handling

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            guard UnixSocket.peerIsSameUser(c) else { close(c); continue }
            Thread.detachNewThread { [self] in handle(LineConnection(fd: c)) }
        }
    }

    private func handle(_ conn: LineConnection) {
        defer { conn.close() }
        guard let msg = conn.readJSON(), let op = msg["op"] as? String else { return }
        switch op {
        case Constants.Ops.hook:
            guard let payload = msg["payload"] as? String else { return }
            let pid = (msg["pid"] as? NSNumber)?.int32Value
            if let e = HookEvent(json: Data(payload.utf8), claudePid: pid) {
                registry.apply(e)
                syncChannels()
            }
        case Constants.Ops.channelHello:
            guard let pid = (msg["claudePid"] as? NSNumber)?.int32Value, pid > 1 else { return }
            let env = (msg["envSessionId"] as? String).flatMap { SessionID.isValid($0) ? $0.lowercased() : nil }
            serveChannel(ChannelLink(conn: conn, claudePid: pid, envSessionId: env))
        case Constants.Ops.sessions:
            if msg["refresh"] as? Bool == true { refreshAgents() }
            _ = conn.writeJSON(["ok": true, "sessions": encodeSessions(registry.snapshot())])
        case Constants.Ops.send:
            let req = SendRequest(session: msg["session"] as? String ?? "",
                                  imagePath: msg["image"] as? String,
                                  text: msg["text"] as? String,
                                  wait: msg["wait"] as? Bool ?? false,
                                  filePaths: msg["files"] as? [String] ?? [])
            _ = conn.writeJSON(send(req).dictionary)
        default:
            _ = conn.writeJSON(["ok": false, "error": "unknown op"])
        }
    }

    func encodeSessions(_ sessions: [Session]) -> Any {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(sessions), let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return obj
    }

    // MARK: Channel links

    private func serveChannel(_ link: ChannelLink) {
        let replaced = lock.withLock { () -> ChannelLink? in
            let old = channels[link.claudePid]
            channels[link.claudePid] = link
            return old
        }
        replaced?.conn.shutdownBoth()
        syncChannels()
        while let msg = link.conn.readJSON() {
            if msg["op"] as? String == Constants.Ops.channelAck, let id = msg["id"] as? String {
                let sem = lock.withLock { link.pendingAcks.removeValue(forKey: id) }
                sem?.signal()
            }
        }
        lock.withLock { if channels[link.claudePid] === link { channels[link.claudePid] = nil } }
        syncChannels()
    }

    /// Recomputes which session each channel serves. The binding key is the Claude Code process id:
    /// the channel reports its parent pid, hooks report CLAUDE_PID, so a /clear or resume inside the
    /// same process follows along. The env session id is only used until the first hook arrives.
    func syncChannels() {
        var updates: [(String, Bool)] = []
        lock.withLock {
            var live = Set<String>()
            for link in channels.values {
                let now = registry.sessionId(forPid: link.claudePid) ?? link.envSessionId
                if let old = link.boundSession, old != now { updates.append((old, false)) }
                link.boundSession = now
                if let now { live.insert(now) }
            }
            for s in live { updates.append((s, true)) }
            updates = updates.filter { !($0.1 == false && live.contains($0.0)) }
        }
        updates.forEach { registry.setChannel(sessionId: $0.0, connected: $0.1) }
        let connectedButUnbound = registry.snapshot().filter { s in
            s.channelConnected && !lock.withLock { channels.values.contains { $0.boundSession == s.id } }
        }
        connectedButUnbound.forEach { registry.setChannel(sessionId: $0.id, connected: false) }
    }

    private func channelLink(for sessionId: String) -> ChannelLink? {
        lock.withLock { channels.values.first { $0.boundSession == sessionId } }
    }

    // MARK: Sending

    /// Delivers an image and/or text to one session. Never falls back to a different session.
    public func send(_ req: SendRequest) -> SendResult {
        guard var session = registry.resolve(req.session) ?? { refreshAgents(); return registry.resolve(req.session) }() else {
            return .failure(.unknownSession(req.session))
        }
        let text = req.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = req.filePaths
        guard req.imagePath != nil || !(text ?? "").isEmpty || !files.isEmpty else {
            return .failure(.emptyMessage, sessionId: session.id)
        }
        let image: ImageFile.Loaded?
        do {
            image = try req.imagePath.map(ImageFile.load)
            try files.forEach(ImageFile.checkFile)
        } catch let e as DeliveryError {
            return .failure(e, sessionId: session.id)
        } catch { return .failure(.image("\(error)"), sessionId: session.id) }
        // A style note rides along with the message; it is never a message on its own.
        let words = [text, req.styleNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let outgoing: String? = words.isEmpty ? nil : words

        if channelLink(for: session.id) != nil {
            return sendViaChannel(session, image: image, files: files, text: outgoing, wait: req.wait)
        }
        if session.kind == .background {
            return sendViaBackground(session, image: image, files: files, text: outgoing, wait: req.wait)
        }
        if session.state == .ended {
            return sendHeadless(session, image: image, files: files, text: outgoing, wait: req.wait)
        }
        if session.kind == .unknown, refreshAgents() != nil, let fresh = registry.session(session.id), fresh.kind == .background {
            session = fresh
            return sendViaBackground(session, image: image, files: files, text: outgoing, wait: req.wait)
        }
        return .failure(.noRoute("session is \(session.state.rawValue) and has no Sidemoon channel connected; "
            + "the background route needs a `claude --bg` session and the headless route needs an ended session"),
            sessionId: session.id)
    }

    // MARK: Route a: channel

    /// Copies the image and files to where the session can read them without a permission prompt.
    private func stage(_ image: ImageFile.Loaded?, _ files: [String], for s: Session) -> Result<(image: String?, files: [String]), DeliveryError> {
        guard image != nil || !files.isEmpty else { return .success((nil, [])) }
        guard let dir = ImageFile.scratchpad(for: s) else { return .failure(.noScratchpad) }
        do {
            let imagePath = try image.map { try ImageFile.place($0, inScratchpad: dir) }
            return .success((imagePath, try files.map { try ImageFile.placeFile($0, inScratchpad: dir) }))
        } catch let e as DeliveryError {
            return .failure(e)
        } catch {
            return .failure(.image("\(error)"))
        }
    }

    private func sendViaChannel(_ s: Session, image: ImageFile.Loaded?, files: [String], text: String?, wait: Bool) -> SendResult {
        guard let link = channelLink(for: s.id) else { return .failure(.channel("channel disconnected"), sessionId: s.id, route: .channel) }
        let imagePath: String?, filePaths: [String]
        switch stage(image, files, for: s) {
        case let .success(staged): (imagePath, filePaths) = staged
        case let .failure(e): return .failure(e, sessionId: s.id, route: .channel)
        }
        let deliveryId = UUID().uuidString.lowercased()
        let content = ImageFile.messageText(text: text, imagePath: imagePath, filePaths: filePaths)
        let token = registry.expectStop(sessionId: s.id) { e in
            // Skip the Stop of a turn that was already running when the message arrived.
            guard let path = e.transcriptPath, TranscriptReader.contains(path, deliveryId) else { return true }
            return TranscriptReader.finalTurnText(transcriptPath: path, promptId: nil, marker: deliveryId) != nil
        }
        let ack = DispatchSemaphore(value: 0)
        lock.withLock { link.pendingAcks[deliveryId] = ack }
        let sent = link.conn.writeJSON(["op": Constants.Ops.channelDeliver, "id": deliveryId, "content": content,
                                        "meta": [Constants.Channel.deliveryIdMetaKey: deliveryId]])
        guard sent, ack.wait(timeout: .now() + Constants.Timeouts.channelDeliveryAck) == .success else {
            lock.withLock { _ = link.pendingAcks.removeValue(forKey: deliveryId) }
            registry.cancelWait(token)
            return .failure(.channel("the channel server did not confirm delivery"), sessionId: s.id, route: .channel)
        }
        return finish(s.id, route: .channel, token: token, wait: wait, marker: deliveryId, detail: imagePath.map { "image at \($0)" })
    }

    private func finish(_ sessionId: String, route: Route, token: UUID, wait: Bool, marker: String?, detail: String?) -> SendResult {
        guard wait else {
            registry.cancelWait(token)
            return SendResult(ok: true, sessionId: sessionId, route: route, reply: nil, error: nil, detail: detail)
        }
        guard let stop = registry.wait(token, timeout: Constants.Timeouts.replyWait) else {
            var r = SendResult.failure(.replyTimeout, sessionId: sessionId, route: route)
            r.detail = detail
            return r
        }
        let reply = TranscriptReader.reply(for: stop, marker: marker) ?? stop.lastAssistantMessage
        if let reply { registry.setReply(sessionId: sessionId, text: reply) }
        return SendResult(ok: true, sessionId: sessionId, route: route, reply: reply, error: nil, detail: detail)
    }

    // MARK: Route b: background

    private func agent(_ sessionId: String) -> AgentInfo? {
        refreshAgents()?.first { $0.sessionId == sessionId }
    }

    private func sendViaBackground(_ s: Session, image: ImageFile.Loaded?, files: [String], text: String?, wait: Bool) -> SendResult {
        func fail(_ m: String) -> SendResult { .failure(.background(m), sessionId: s.id, route: .background) }
        guard let a = agent(s.id), a.kind == SessionKind.background.rawValue else {
            return fail("`claude agents` no longer lists this session as a background session")
        }
        let current = registry.session(s.id) ?? s
        // Refuse if any source says it is working: the hooks seen so far, or Claude Code right now.
        guard !registry.isMidTurn(a), current.state != .working, s.state != .working else { return .failure(.busy(s.id), sessionId: s.id, route: .background) }
        // Stopping a session that is waiting on a permission prompt would discard that prompt.
        guard current.state != .needsInput else { return fail("the session is waiting on a prompt in its own window; answer it there first") }
        guard let cwd = current.cwd ?? a.cwd else { return fail("the session's working directory is unknown") }

        let imagePath: String?, filePaths: [String]
        switch stage(image, files, for: current) {
        case let .success(staged): (imagePath, filePaths) = staged
        case let .failure(e): return .failure(e, sessionId: s.id, route: .background)
        }
        var prompt = ImageFile.messageText(text: text, imagePath: imagePath, filePaths: filePaths)
        // The stop below ends whatever the finished turn left running, so the session is told.
        if a.isRunning, a.status == Constants.ClaudeCLI.busyStatus { prompt += "\n\n" + Constants.ClaudeCLI.backgroundWorkNote }

        // 1. Stop it: resuming a running session forks a copy instead of continuing it.
        if a.isRunning {
            let r = runner.run([Constants.ClaudeCLI.stopCommand, a.agentId], cwd: nil, stdin: nil, timeout: Constants.Timeouts.cliCommand)
            guard r.status == 0 else { return fail("`claude stop \(a.agentId)` failed: \(r.stderrText.prefix(300))") }
            let deadline = Date().addingTimeInterval(Constants.Timeouts.backgroundStopWait)
            // `claude agents` drops the pid before the process has exited; resuming in that window forks.
            func processAlive(_ pid: Int32?) -> Bool { pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false }
            while agent(s.id)?.isRunning == true || processAlive(a.pid) {
                guard Date() < deadline else { return fail("session did not stop within \(Int(Constants.Timeouts.backgroundStopWait))s") }
                Thread.sleep(forTimeInterval: Constants.Timeouts.pollInterval)
            }
        }

        // 2. Resume with the message and no other flags.
        let token = registry.expectStop(sessionId: s.id)
        let before = Set((refreshAgents() ?? []).map(\.sessionId))
        let resumeAt = Date()
        let r = runner.run([Constants.ClaudeCLI.resumeFlag, s.id, Constants.ClaudeCLI.backgroundFlag, prompt],
                           cwd: cwd, stdin: nil, timeout: Constants.Timeouts.cliCommand)
        let output = r.stdoutText + r.stderrText
        guard r.status == 0 else {
            registry.cancelWait(token)
            return fail("resume exited \(r.status): \(output.prefix(300))")
        }

        // 3. Verify the same session continued; a fork is an error, never a success.
        let printed = Engine.backgroundedId(in: output)
        let mentionsCopy = Constants.ClaudeCLI.forkIndicators.contains { output.lowercased().contains($0) }
        var forkId: String? = (printed != nil && printed != a.agentId) || mentionsCopy ? (printed ?? "unknown") : nil
        if forkId == nil {
            let deadline = Date().addingTimeInterval(Constants.Timeouts.backgroundResumeVerify)
            var verified = false
            while Date() < deadline {
                let list = refreshAgents() ?? []
                if let copy = list.first(where: { !before.contains($0.sessionId) && $0.agentId == printed }) {
                    forkId = copy.agentId
                    break
                }
                let resumed = list.first { $0.sessionId == s.id }
                let hooked = registry.session(s.id).map { ($0.lastEventAt ?? .distantPast) > resumeAt } ?? false
                if resumed?.isRunning == true || hooked { verified = true; break }
                Thread.sleep(forTimeInterval: Constants.Timeouts.pollInterval)
            }
            if !verified && forkId == nil {
                registry.cancelWait(token)
                return fail("could not confirm that session \(s.id) resumed (output: \(output.prefix(200)))")
            }
        }
        if let forkId {
            registry.cancelWait(token)
            if forkId != "unknown" {
                _ = runner.run([Constants.ClaudeCLI.stopCommand, forkId], cwd: nil, stdin: nil, timeout: Constants.Timeouts.cliCommand)
            }
            var r = SendResult.failure(.forked(original: s.id, copy: forkId), sessionId: s.id, route: .background)
            r.detail = "claude output: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
            return r
        }
        return finish(s.id, route: .background, token: token, wait: wait, marker: nil, detail: imagePath.map { "image at \($0)" })
    }

    /// The short id in `backgrounded · <id> · <name>`.
    static func backgroundedId(in output: String) -> String? {
        for line in output.split(separator: "\n") where line.lowercased().contains(Constants.ClaudeCLI.backgroundedMarker) {
            let tokens = line.split { !$0.isHexDigit }.map(String.init)
            if let id = tokens.first(where: { $0.count == Constants.ClaudeCLI.shortIdLength }) { return id.lowercased() }
        }
        return nil
    }

    // MARK: Route c: headless

    private func sendHeadless(_ s: Session, image: ImageFile.Loaded?, files: [String], text: String?, wait: Bool) -> SendResult {
        @Sendable func fail(_ m: String) -> SendResult { .failure(.headless(m), sessionId: s.id, route: .headless) }
        if let a = agent(s.id), a.isRunning { return fail("`claude agents` shows this session running; it may be open elsewhere") }
        guard registry.session(s.id)?.state == .ended else { return fail("the session is no longer known to have ended") }
        guard let cwd = s.cwd else { return fail("the session's working directory is unknown") }

        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType,
                                                        "data": image.data.base64EncodedString()]])
        }
        // The image goes inline; files are referenced where they are, since an ended session has no live scratchpad.
        let words = ImageFile.messageText(text: text, imagePath: nil, filePaths: files)
        if !words.isEmpty { content.append(["type": "text", "text": words]) }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var encoded = try? JSONSerialization.data(withJSONObject: message) else { return fail("could not encode the message") }
        encoded.append(UInt8(ascii: "\n"))
        let input = encoded
        let args = [Constants.ClaudeCLI.printFlag, Constants.ClaudeCLI.resumeFlag, s.id] + Constants.ClaudeCLI.headlessFlags

        let run: @Sendable () -> SendResult = { [self] in
            let r = runner.run(args, cwd: cwd, stdin: input, timeout: Constants.Timeouts.headlessRun)
            let parsed = Engine.parseStream(r.stdout)
            if let sid = parsed.sessionId, sid != s.id {
                return .failure(.forked(original: s.id, copy: sid), sessionId: s.id, route: .headless)
            }
            guard r.status == 0, !parsed.isError, let reply = parsed.text ?? parsed.result else {
                return fail("claude exited \(r.status)\(r.timedOut ? " (timed out)" : ""): \(r.stderrText.prefix(300))")
            }
            registry.setReply(sessionId: s.id, text: reply)
            return SendResult(ok: true, sessionId: s.id, route: .headless, reply: reply, error: nil, detail: nil)
        }
        guard wait else {
            DispatchQueue.global().async { _ = run() }
            return SendResult(ok: true, sessionId: s.id, route: .headless, reply: nil, error: nil, detail: "running")
        }
        return run()
    }

    struct StreamOutcome {
        var sessionId: String?
        var text: String?
        var result: String?
        var isError = false
    }

    /// Final-turn text from `--output-format stream-json`: all top-level assistant text blocks.
    static func parseStream(_ data: Data) -> StreamOutcome {
        var o = StreamOutcome()
        var parts: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let m = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch m["type"] as? String {
            case "assistant" where m["parent_tool_use_id"] == nil || m["parent_tool_use_id"] is NSNull:
                let blocks = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                parts += blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            case "result":
                o.sessionId = (m["session_id"] as? String)?.lowercased()
                o.result = m["result"] as? String
                o.isError = m["is_error"] as? Bool ?? false
            default: break
            }
        }
        o.text = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        return o
    }
}
