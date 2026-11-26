import Foundation

/// The engine: listens on the socket, keeps the registry, and delivers messages.
public final class Engine: @unchecked Sendable {
    public let registry: SessionRegistry
    public let socketPath: String
    let runner: ClaudeRunner
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var channels: [Int32: ChannelLink] = [:]

    /// How long an idle session has to show it picked up a channel delivery (`Constants.Timeouts.channelPickupWait`).
    let pickupWait: TimeInterval
    /// Arguments added to every `claude --bg` that starts a new session. Empty in the app; the end-to-end tests
    /// pass their own (project settings only, a small model, a name).
    let newSessionArguments: [String]
    /// General and the chats started with "+".
    public let chats: ChatBook
    /// Where the chats run.
    public let chatFolder: String
    /// Arguments added to every chat run. Empty in the app (the user's default model); the end-to-end tests pass
    /// their own (project settings only, a small model).
    let chatArguments: [String]

    final class ChannelLink: @unchecked Sendable {
        let conn: LineConnection
        let claudePid: Int32
        let envSessionId: String?
        /// What the helper read from its parent's command line.
        let role: ChannelRole
        /// A delivery the helper confirmed was then not picked up: Claude Code ignores this helper.
        var pickupFailed = false
        var boundSession: String?
        var pendingAcks: [String: DispatchSemaphore] = [:]
        /// Whether a message sent through it can reach the session. Unknown counts, guarded by the pick-up check.
        var usable: Bool { role != .notChannel && !pickupFailed }
        init(conn: LineConnection, claudePid: Int32, envSessionId: String?, role: ChannelRole) {
            self.conn = conn
            self.claudePid = claudePid
            self.envSessionId = envSessionId
            self.role = role
        }
    }

    public init(socketPath: String = Constants.Paths.socketPath, runner: ClaudeRunner = SystemClaudeRunner(),
                registry: SessionRegistry = SessionRegistry(homeFolderMemory: .supportFolder()),
                pickupWait: TimeInterval = Constants.Timeouts.channelPickupWait, newSessionArguments: [String] = [],
                chats: ChatBook = .supportFolder(), chatFolder: String = Constants.Paths.chatFolder, chatArguments: [String] = []) {
        self.socketPath = socketPath
        self.runner = runner
        self.registry = registry
        self.pickupWait = pickupWait
        self.newSessionArguments = newSessionArguments
        self.chats = chats
        self.chatFolder = chatFolder
        self.chatArguments = chatArguments
        registry.hideRuns(in: chatFolder)
        chats.all.forEach { registry.setChat($0.session) }
    }

    /// A new, empty chat, listed at once; its conversation starts with its first message. Returns its id.
    public func newChat(name: String) -> String {
        let record = chats.create(name: name)
        registry.setChat(record.session)
        return record.id
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
            let role = (msg[Constants.Channel.roleKey] as? String).flatMap(ChannelRole.init(rawValue:)) ?? .unknown
            serveChannel(ChannelLink(conn: conn, claudePid: pid, envSessionId: env, role: role))
        case Constants.Ops.sessions:
            if msg["refresh"] as? Bool == true { refreshAgents() }
            _ = conn.writeJSON(["ok": true, "sessions": encodeSessions(registry.snapshot())])
        case Constants.Ops.send:
            let req = SendRequest(session: msg["session"] as? String ?? "",
                                  imagePath: msg["image"] as? String,
                                  imagePaths: msg["images"] as? [String] ?? [],
                                  text: msg["text"] as? String,
                                  wait: msg["wait"] as? Bool ?? false,
                                  filePaths: msg["files"] as? [String] ?? [])
            _ = conn.writeJSON(send(req).dictionary)
        case Constants.Ops.newSession:
            let req = NewSessionRequest(folder: msg["folder"] as? String ?? "", text: msg["text"] as? String ?? "",
                                        name: msg["name"] as? String)
            _ = conn.writeJSON(startSession(req).dictionary)
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
    /// A session counts as channel-connected only through a link that can reach it (`ChannelLink.usable`); one
    /// with only links Claude Code ignores is marked as having its channel dropped instead.
    func syncChannels() {
        // Session id -> whether any link bound to it is usable.
        let bound: [String: Bool] = lock.withLock {
            var bound: [String: Bool] = [:]
            for link in channels.values {
                let now = registry.sessionId(forPid: link.claudePid) ?? link.envSessionId
                link.boundSession = now
                if let now { bound[now] = (bound[now] ?? false) || link.usable }
            }
            return bound
        }
        for (id, usable) in bound { registry.setChannel(sessionId: id, connected: usable, dropped: !usable) }
        for s in registry.snapshot() where (s.channelConnected || s.channelDropped) && bound[s.id] == nil {
            registry.setChannel(sessionId: s.id, connected: false)
        }
    }

    /// A usable link bound to the session; one the hooks bind by its process id comes before one bound by the
    /// helper's environment alone.
    private func channelLink(for sessionId: String) -> ChannelLink? {
        lock.withLock {
            let candidates = channels.values.filter { $0.boundSession == sessionId && $0.usable }
            return candidates.first { registry.sessionId(forPid: $0.claudePid) == sessionId } ?? candidates.first
        }
    }

    // MARK: Sending

    /// Delivers an image and/or text to one session. Never falls back to a different session.
    public func send(_ req: SendRequest) -> SendResult {
        guard var session = registry.resolve(req.session) ?? { refreshAgents(); return registry.resolve(req.session) }() else {
            return .failure(.unknownSession(req.session))
        }
        let text = req.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = req.filePaths
        guard !req.allImagePaths.isEmpty || !(text ?? "").isEmpty || !files.isEmpty else {
            return .failure(.emptyMessage, sessionId: session.id)
        }
        let images: [ImageFile.Loaded]
        do {
            images = try req.allImagePaths.map(ImageFile.load)
            try files.forEach(ImageFile.checkFile)
        } catch let e as DeliveryError {
            return .failure(e, sessionId: session.id)
        } catch { return .failure(.image("\(error)"), sessionId: session.id) }
        // A style note rides along with the message; it is never a message on its own.
        let words = [text, req.styleNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let outgoing: String? = words.isEmpty ? nil : words

        if session.kind == .chat {
            return sendToChat(session, images: images, files: files, text: outgoing, wait: req.wait)
        }
        if channelLink(for: session.id) != nil {
            return sendViaChannel(session, images: images, files: files, text: outgoing, wait: req.wait)
        }
        if session.kind == .background {
            return sendViaBackground(session, images: images, files: files, text: outgoing, wait: req.wait)
        }
        if session.state == .ended {
            return sendHeadless(session, images: images, files: files, text: outgoing, wait: req.wait)
        }
        if session.kind == .unknown, refreshAgents() != nil, let fresh = registry.session(session.id), fresh.kind == .background {
            session = fresh
            return sendViaBackground(session, images: images, files: files, text: outgoing, wait: req.wait)
        }
        // Sidemoon's helper is there, but Claude Code does not pass on what it sends.
        if registry.session(session.id)?.channelDropped == true {
            var r = SendResult.failure(.channelIgnored(fallback: nil), sessionId: session.id, route: .channel)
            r.detail = "a sidemoon helper is connected for this session, but its claude code process does not load it as a channel"
            return r
        }
        return .failure(.noRoute("session is \(session.state.rawValue) and has no Sidemoon channel connected; "
            + "the background route needs a `claude --bg` session and the headless route needs an ended session"),
            sessionId: session.id)
    }

    // MARK: Route a: channel

    /// Copies the image and files to where the session can read them without a permission prompt.
    private func stage(_ images: [ImageFile.Loaded], _ files: [String], for s: Session) -> Result<(images: [String], files: [String]), DeliveryError> {
        guard !images.isEmpty || !files.isEmpty else { return .success(([], [])) }
        guard let dir = ImageFile.scratchpad(for: s) else { return .failure(.noScratchpad) }
        do {
            let imagePaths = try images.map { try ImageFile.place($0, inScratchpad: dir) }
            return .success((imagePaths, try files.map { try ImageFile.placeFile($0, inScratchpad: dir) }))
        } catch let e as DeliveryError {
            return .failure(e)
        } catch {
            return .failure(.image("\(error)"))
        }
    }

    private func sendViaChannel(_ s: Session, images: [ImageFile.Loaded], files: [String], text: String?, wait: Bool) -> SendResult {
        guard let link = channelLink(for: s.id) else { return .failure(.channel("channel disconnected"), sessionId: s.id, route: .channel) }
        let imagePaths: [String], filePaths: [String]
        switch stage(images, files, for: s) {
        case let .success(staged): (imagePaths, filePaths) = staged
        case let .failure(e): return .failure(e, sessionId: s.id, route: .channel)
        }
        let deliveryId = UUID().uuidString.lowercased()
        let content = ImageFile.messageText(text: text, imagePaths: imagePaths, filePaths: filePaths)
        let token = registry.expectStop(sessionId: s.id) { e in
            // Skip the Stop of a turn that was already running when the message arrived.
            guard let path = e.transcriptPath, TranscriptReader.contains(path, deliveryId) else { return true }
            return TranscriptReader.finalTurnText(transcriptPath: path, promptId: nil, marker: deliveryId) != nil
        }
        let ack = DispatchSemaphore(value: 0)
        lock.withLock { link.pendingAcks[deliveryId] = ack }
        let sentAt = Date()
        let sent = link.conn.writeJSON(["op": Constants.Ops.channelDeliver, "id": deliveryId, "content": content,
                                        "meta": [Constants.Channel.deliveryIdMetaKey: deliveryId]])
        guard sent, ack.wait(timeout: .now() + Constants.Timeouts.channelDeliveryAck) == .success else {
            lock.withLock { _ = link.pendingAcks.removeValue(forKey: deliveryId) }
            registry.cancelWait(token)
            return .failure(.channel("the channel server did not confirm delivery"), sessionId: s.id, route: .channel)
        }
        // The helper only says it passed the message on; Claude Code may still ignore it (a process that did not
        // load the helper as a channel). Waiting for a Stop would then take the whole reply timeout.
        guard pickedUp(s.id, marker: deliveryId, since: sentAt) else {
            registry.cancelWait(token)
            lock.withLock { link.pickupFailed = true }
            syncChannels()
            let now = registry.session(s.id) ?? s
            let fallback: Route? = now.kind == .background ? .background : now.routes.first
            var r = SendResult.failure(.channelIgnored(fallback: fallback), sessionId: s.id, route: .channel)
            r.detail = "the helper under claude pid \(link.claudePid) (channel role \(link.role.rawValue)) confirmed delivery \(deliveryId), "
                + "but the session showed no sign of it within \(Int(pickupWait))s of being idle"
            return r
        }
        return finish(s.id, route: .channel, token: token, wait: wait, marker: deliveryId, detail: Engine.imageDetail(imagePaths))
    }

    /// Whether the session took in a channel delivery: its marker in the session's transcript, or a prompt
    /// submitted to the session after the send. Seen with Claude Code 2.1.330: a channel message runs the
    /// UserPromptSubmit hook at once and its marker is in the transcript within half a second. A
    /// session that is mid-turn or waiting on a prompt takes the message only when that is over, so the wait
    /// starts again while it is busy, up to the reply timeout.
    private func pickedUp(_ sessionId: String, marker: String, since: Date) -> Bool {
        let giveUp = since.addingTimeInterval(Constants.Timeouts.replyWait)
        var idleSince = Date()
        while Date() < giveUp {
            let s = registry.session(sessionId)
            if let path = s?.transcriptPath, TranscriptReader.contains(path, marker) { return true }
            if let prompted = registry.lastPromptSubmit(sessionId), prompted >= since { return true }
            if let state = s?.state, state == .working || state == .needsInput {
                idleSince = Date()
            } else if Date().timeIntervalSince(idleSince) >= pickupWait {
                return false
            }
            Thread.sleep(forTimeInterval: Constants.Timeouts.pollInterval)
        }
        return false
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

    private func sendViaBackground(_ s: Session, images: [ImageFile.Loaded], files: [String], text: String?, wait: Bool) -> SendResult {
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
        // Claude Code would refuse to reopen it once stopped, and the session would be left stopped: leave it be.
        // A session that is already stopped is not stopped here, so Claude Code's own answer is safe to wait for;
        // it reopens a stopped session that never answered.
        let answered = a.isRunning ? registry.hasAnswered(s.id, transcriptHint: current.transcriptPath ?? a.transcriptPath) : nil
        // Blocked before its first answer: it waits on a question in its terminal (the listing just read said so, and
        // the registry judged its transcript). Resuming it would only start a new session.
        let blocked = ResumeCheck.isBlocked(a)
        if blocked, current.blocker == .waitingInTerminal {
            var r = SendResult.failure(.cannotResume(.waitingInTerminal, messageSaved: false), sessionId: s.id, route: .background)
            r.detail = "checked before resuming: \(ResumeBlocker.waitingInTerminal.description) (\(cwd))"
            return r
        }
        // The home folder only blocks where Claude Code has refused it before, and only a running session.
        let inHome = ResumeCheck.isHomeFolder(cwd, home: registry.home)
        let homeRefused = a.isRunning && registry.homeFolderMemory.refused
        if let blocker = ResumeCheck.blocker(cwd: cwd, home: registry.home, answered: answered, homeFolderRefused: homeRefused,
                                             blockedInTerminal: blocked) {
            registry.setBlocker(sessionId: s.id, blocker)
            var r = SendResult.failure(.cannotResume(blocker, messageSaved: false), sessionId: s.id, route: .background)
            r.detail = "checked before stopping the session: \(blocker.description) (\(cwd))"
            return r
        }

        let imagePaths: [String], filePaths: [String]
        switch stage(images, files, for: current) {
        case let .success(staged): (imagePaths, filePaths) = staged
        case let .failure(e): return .failure(e, sessionId: s.id, route: .background)
        }
        var prompt = ImageFile.messageText(text: text, imagePaths: imagePaths, filePaths: filePaths)
        // The stop below ends whatever the finished turn left running, so the session is told.
        if a.isRunning, a.status == Constants.ClaudeCLI.busyStatus { prompt += "\n\n" + Constants.ClaudeCLI.backgroundWorkNote }

        // 1. Stop it: resuming a running session forks a copy instead of continuing it.
        let stoppedFirst = a.isRunning
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
            let said = "resume exited \(r.status): \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Constants.Limits.failureDetailCharacters))"
            // Claude Code's own reason, for the cases the checks above cannot see.
            if let refusal = ResumeCheck.classify(output) {
                // Remembered for this Mac, so the next home-folder session is not stopped for nothing.
                if refusal.blocker == .homeFolder { registry.homeFolderResume(refused: true) }
                registry.setBlocker(sessionId: s.id, refusal.blocker)
                var failed = SendResult.failure(.cannotResume(refusal.blocker, messageSaved: refusal.messageSaved,
                                                              stoppedFirst: stoppedFirst),
                                                sessionId: s.id, route: .background)
                failed.detail = said
                return failed
            }
            return fail(said)
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
        // Claude Code reopened a home-folder session here: a refusal remembered from before no longer holds.
        if inHome { registry.homeFolderResume(refused: false) }
        return finish(s.id, route: .background, token: token, wait: wait, marker: nil, detail: Engine.imageDetail(imagePaths))
    }

    /// Where the images were put, for the result's detail.
    static func imageDetail(_ paths: [String]) -> String? {
        paths.isEmpty ? nil : (paths.count == 1 ? "image at " : "images at ") + paths.joined(separator: ", ")
    }

    /// The short id in `backgrounded · <id> · <name>`.
    static func backgroundedId(in output: String) -> String? {
        for line in output.split(separator: "\n") where line.lowercased().contains(Constants.ClaudeCLI.backgroundedMarker) {
            let tokens = line.split { !$0.isHexDigit }.map(String.init)
            if let id = tokens.first(where: { $0.count == Constants.ClaudeCLI.shortIdLength }) { return id.lowercased() }
        }
        return nil
    }

    // MARK: New session

    /// Starts a new background session with its first message: `claude --bg -- "<message>"` in the folder. Returns
    /// once Claude Code lists the session, with its full id; the answer arrives through the hooks like any other.
    /// Touches no other session. Seen with Claude Code 2.1.330: it prints `backgrounded · <short id> · <name>` within
    /// about a second, `--session-id` is ignored with `--bg`, the short id is the start of the full one, and
    /// `claude agents` lists the session at once.
    public func startSession(_ req: NewSessionRequest) -> NewSessionResult {
        let text = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed(.emptyMessage) }
        var isDirectory: ObjCBool = false
        guard let folder = PathPolicy.absolute(req.folder),
              FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(.folderMissing(req.folder))
        }
        // It would start, but no message could reach it again on this Mac.
        if ResumeCheck.isHomeFolder(folder, home: registry.home), registry.homeFolderMemory.refused { return .failed(.homeFolderRefused) }
        guard runner.isInstalled else { return .failed(.claudeNotFound) }

        let prompt = [text, req.styleNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let cli = Constants.ClaudeCLI.self
        // Arguments given to the engine that name the session already (the end-to-end tests) keep their name.
        let named = newSessionArguments.contains(cli.nameFlag)
        let args = [cli.backgroundFlag] + newSessionArguments + (named ? [] : req.name.map { [cli.nameFlag, $0] } ?? [])
            + [cli.endOfOptions, prompt]
        let r = runner.run(args, cwd: folder, stdin: nil, timeout: Constants.Timeouts.newSessionStart)
        let output = (r.stdoutText + r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        let said = String(output.prefix(Constants.Limits.failureDetailCharacters))
        if r.timedOut { return .failed(.timedOut, detail: said) }
        guard r.status == 0 else {
            if let refusal = ResumeCheck.classify(output) {
                if refusal.blocker == .homeFolder { registry.homeFolderResume(refused: true) }
                return .failed(.refused(refusal.blocker), detail: said)
            }
            // The process could not be launched at all: no claude where the runner looked.
            if r.status < 0 && !runner.isInstalled { return .failed(.claudeNotFound, detail: said) }
            return .failed(.failed(status: r.status), detail: said)
        }
        guard let short = Engine.backgroundedId(in: output) else { return .failed(.notConfirmed, detail: said) }
        // Listed: the registry then knows it as a background session in its folder, so it is reachable at once.
        let deadline = Date().addingTimeInterval(Constants.Timeouts.newSessionVerify)
        while Date() < deadline {
            if let listed = refreshAgents()?.first(where: { $0.agentId == short }) {
                return NewSessionResult(sessionId: listed.sessionId, failure: nil, detail: said)
            }
            Thread.sleep(forTimeInterval: Constants.Timeouts.pollInterval)
        }
        return .failed(.notConfirmed, detail: "\(said)\n`claude agents` did not list \(short) within \(Int(Constants.Timeouts.newSessionVerify))s")
    }

    // MARK: Route c: headless

    /// One user message for `--input-format stream-json`: the images inline, then the words, which name the files
    /// by path.
    static func headlessInput(images: [ImageFile.Loaded], text: String?, files: [String]) -> Data? {
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType,
                                                        "data": image.data.base64EncodedString()]])
        }
        let words = ImageFile.messageText(text: text, imagePaths: [], filePaths: files)
        if !words.isEmpty { content.append(["type": "text", "text": words]) }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var encoded = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        encoded.append(UInt8(ascii: "\n"))
        return encoded
    }

    private func sendHeadless(_ s: Session, images: [ImageFile.Loaded], files: [String], text: String?, wait: Bool) -> SendResult {
        @Sendable func fail(_ m: String) -> SendResult { .failure(.headless(m), sessionId: s.id, route: .headless) }
        if let a = agent(s.id), a.isRunning { return fail("`claude agents` shows this session running; it may be open elsewhere") }
        guard registry.session(s.id)?.state == .ended else { return fail("the session is no longer known to have ended") }
        guard let cwd = s.cwd else { return fail("the session's working directory is unknown") }

        // The image goes inline; files are referenced where they are, since an ended session has no live scratchpad.
        guard let input = Engine.headlessInput(images: images, text: text, files: files) else { return fail("could not encode the message") }
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

    // MARK: Route d: a chat

    /// Chats with a run under way. One run at a time per chat: a second message is refused as busy, and the
    /// companion sends it once the first has answered, as for any busy session.
    private var runningChats: Set<String> = []

    /// One `claude -p` run in the chat folder that continues the chat's conversation (`--resume`), or starts it,
    /// with the images inline and the files copied into the chat folder where the run may read them. Only reading
    /// is allowed (`Constants.Chat.allowedTools`). When Claude Code no longer has the conversation, a fresh one starts
    /// and the result says so. Nothing is left running afterwards.
    private func sendToChat(_ s: Session, images: [ImageFile.Loaded], files: [String], text: String?, wait: Bool) -> SendResult {
        @Sendable func fail(_ m: String) -> SendResult { .failure(.headless(m), sessionId: s.id, route: .headless) }
        guard let record = chats.chat(s.id) else { return .failure(.unknownSession(s.id)) }
        guard runner.isInstalled else { return fail("the claude command was not found") }
        let started = lock.withLock { runningChats.insert(s.id).inserted }
        guard started else { return .failure(.busy(s.id), sessionId: s.id, route: .headless) }
        let placed: [String]
        do {
            try ChatFolder.prepare(chatFolder)
            placed = try files.map { try placeInChatFolder($0) }
        } catch {
            lock.withLock { _ = runningChats.remove(s.id) }
            return fail("could not prepare the chat folder: \(error)")
        }
        guard let input = Engine.headlessInput(images: images, text: text, files: placed) else {
            lock.withLock { _ = runningChats.remove(s.id) }
            return fail("could not encode the message")
        }
        var working = registry.session(s.id) ?? record.session
        working.state = .working
        registry.setChat(working)

        let run: @Sendable () -> SendResult = { [self] in
            defer { lock.withLock { _ = runningChats.remove(s.id) } }
            var (r, parsed) = runChat(resume: record.claudeSessionId, input: input)
            var startedOver = false
            if record.claudeSessionId != nil, Engine.conversationGone(r, parsed) {
                (r, parsed) = runChat(resume: nil, input: input)
                startedOver = true
            }
            let output = (r.stdoutText + r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            let now = Date()
            var after = registry.session(s.id) ?? record.session
            after.state = .idle
            guard r.status == 0, !parsed.isError, let reply = parsed.text ?? parsed.result else {
                registry.setChat(after)
                let said = "claude exited \(r.status)\(r.timedOut ? " (timed out)" : ""): "
                    + String((parsed.result ?? output).prefix(Constants.Limits.failureDetailCharacters))
                if let refusal = ResumeCheck.classify(parsed.result ?? output), refusal.blocker == .loginNeeded {
                    var failed = SendResult.failure(.cannotResume(.loginNeeded, messageSaved: false), sessionId: s.id, route: .headless)
                    failed.detail = said
                    return failed
                }
                return fail(said)
            }
            chats.update(s.id, claudeSessionId: parsed.sessionId ?? (startedOver ? nil : record.claudeSessionId), reply: reply, at: now)
            after.lastReply = reply
            after.lastReplyAt = now
            after.lastEventAt = now
            registry.setChat(after)
            var result = SendResult(ok: true, sessionId: s.id, route: .headless, reply: reply, error: nil,
                                    detail: parsed.sessionId.map { "claude session \($0)" })
            result.startedOver = startedOver
            return result
        }
        guard wait else {
            DispatchQueue.global().async { _ = run() }
            return SendResult(ok: true, sessionId: s.id, route: .headless, reply: nil, error: nil, detail: "running")
        }
        return run()
    }

    private func runChat(resume: String?, input: Data) -> (ProcessResult, StreamOutcome) {
        let c = Constants.ClaudeCLI.self
        let args = [c.printFlag] + (resume.map { [c.resumeFlag, $0] } ?? []) + c.headlessFlags
            + [Constants.Chat.allowedToolsFlag] + Constants.Chat.allowedTools + chatArguments
        let r = runner.run(args, cwd: chatFolder, stdin: input, timeout: Constants.Timeouts.headlessRun)
        return (r, Engine.parseStream(r.stdout))
    }

    /// Claude Code no longer has the conversation a chat continues.
    static func conversationGone(_ r: ProcessResult, _ parsed: StreamOutcome) -> Bool {
        guard r.status != 0 || parsed.isError else { return false }
        let said = (r.stdoutText + r.stderrText + (parsed.result ?? "")).lowercased()
        return Constants.Chat.conversationGonePhrases.contains { said.contains($0) }
    }

    /// Copies a file sent to a chat into the chat folder (owner only), keeping a readable version of its name.
    private func placeInChatFolder(_ path: String) throws -> String {
        try ImageFile.checkFile(path)
        let dir = (chatFolder as NSString).appendingPathComponent(Constants.Chat.attachmentsFolderName)
        try ChatFolder.prepare(dir)
        guard let data = FileManager.default.contents(atPath: path) else { throw DeliveryError.file("cannot read \(path)") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = String((path as NSString).lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let target = (dir as NSString).appendingPathComponent("\(UUID().uuidString.lowercased().prefix(Constants.Limits.fileIdLength))-\(name)")
        guard FileManager.default.createFile(atPath: target, contents: data,
                                             attributes: [.posixPermissions: Constants.Permissions.imageFile]) else {
            throw DeliveryError.file("cannot copy \(path) into the chat folder")
        }
        return target
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
