import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

/// Real end-to-end scenarios through the app's view model, against real, throwaway Claude Code sessions.
/// Run them with `scripts/e2e.sh` (which sets up the scratch folders, the isolated engine socket and the
/// cleanup); `swift test` alone skips them. Each scenario creates its own sessions, sends only to those
/// (`GuardedEngine` refuses anything else) and stops them when it ends. The one exception is the session in
/// the home folder, which the runner starts once for the scenarios that need it and stops at the end.
@MainActor
@Suite(.serialized, .enabled(if: E2E.enabled)) struct EndToEndTests {

    /// Sets up, runs, and always cleans up one scenario; a thrown failure is recorded with what was observed.
    private func scenario(_ name: String, image: URL? = nil, _ body: (Fixture) async throws -> Void) async {
        let fixture: Fixture
        do { fixture = try Fixture(name, image: image) } catch {
            Issue.record("[\(name)] setup failed: \(error)")
            return
        }
        do { try await body(fixture) } catch { Issue.record("[\(name)] \(error)") }
        await fixture.cleanup()
    }

    /// The runner's session in the home folder, as the test engine lists it.
    private func homeSession(_ fx: Fixture) async throws -> AgentInfo {
        guard let short = E2E.homeSession else {
            throw E2EFailure("\(E2E.Variable.homeSession) is not set: the runner starts that session (scripts/e2e.sh)")
        }
        guard let a = await Task.detached(operation: { ClaudeCLI.agent(short: short) }).value else {
            throw E2EFailure("the home-folder session \(short) is not listed by claude agents")
        }
        guard ResumeCheck.isHomeFolder(a.cwd ?? "", home: FileManager.default.homeDirectoryForCurrentUser.path) else {
            throw E2EFailure("session \(short) does not run in the home folder (\(a.cwd ?? "-"))")
        }
        try await waitForBlocking("the home-folder session to finish its first answer", timeout: E2E.Timeout.firstAnswer,
                                  observed: { ClaudeCLI.describe(ClaudeCLI.agent(short: short)) }) {
            guard let now = ClaudeCLI.agent(short: short) else { return false }
            return now.status != Constants.ClaudeCLI.busyStatus && TranscriptReader.sessionHasAnswered(now.sessionId, hint: now.transcriptPath) == true
        }
        fx.guarded.allow(a.sessionId)
        return a
    }

    // MARK: 1

    /// An idle background session gets a typed message, answers into the thread, and is the same session after.
    @Test func idleBackgroundSession() async {
        await scenario("idle") { fx in
            let (sid, short) = try await fx.startBackground("idle", prompt: E2E.Words.readyPrompt)
            try await fx.waitUntilIdle(sid, short: short, reply: E2E.Words.ready)
            try fx.select(sid)
            try await fx.send(E2E.Words.reply("PEAR"), to: sid)
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[idle] reply \(reply.prefix(80)); error \(String(describing: fx.model.currentError))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError)); \(fx.describeThread(sid))")
            #expect(fx.lastEntry(role: .you, of: sid)?.delivery == .delivered, "\(fx.describeThread(sid))")
            #expect(reply.uppercased().contains("PEAR"), "reply was: \(reply)")
            // The same session continued: still one session in the folder, the same id, the message in its transcript.
            let listed = await Task.detached { ClaudeCLI.agents() }.value.filter { $0.cwd == fx.project }
            #expect(listed.map(\.sessionId) == [sid], "sessions in the project: \(listed.map { ClaudeCLI.describe($0) })")
            let transcript = listed.first?.transcriptPath ?? ""
            #expect(TranscriptReader.contains(transcript, "PEAR"), "PEAR is not in \(transcript)")
            let folder = (transcript as NSString).deletingLastPathComponent
            let transcripts = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".jsonl") } ?? []
            #expect(transcripts == ["\(sid).jsonl"], "transcripts in \(folder): \(transcripts)")
        }
    }

    // MARK: 2

    /// A message to a session in the middle of a long turn waits its turn and goes once the turn ends.
    @Test func busyBackgroundSession() async {
        await scenario("busy") { fx in
            let prompt = "Run the shell command `\(E2E.longTurnCommand)` with the Bash tool in the foreground, "
                + "then reply with only the word SLEPT."
            let (sid, short) = try await fx.startBackground("busy", prompt: prompt)
            try await waitFor("the session to be working on its long turn", timeout: E2E.Timeout.firstAnswer,
                              observed: { fx.describe(sid) }) { fx.session(sid)?.state == .working }
            try fx.select(sid)
            let started = Date()
            let model = fx.model
            let sending = Task { await model.sendMessage(E2E.Words.reply("PLUM")) }
            try await waitFor("the message to show as waiting its turn", timeout: E2E.Timeout.hook,
                              observed: { fx.describeThread(sid) }) { fx.lastEntry(role: .you, of: sid)?.delivery == .queued }
            e2eLog("[busy] queued after \(Int(Date().timeIntervalSince(started)))s while \(fx.describe(sid))")
            await sending.value
            let thread = fx.model.threads.thread(for: sid)
            e2eLog("[busy] delivered after \(Int(Date().timeIntervalSince(started)))s: \(fx.describeThread(sid))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError))")
            #expect(fx.lastEntry(role: .you, of: sid)?.delivery == .delivered, "\(fx.describeThread(sid))")
            let replies = thread.filter { $0.role == .session }.map { $0.text.uppercased() }
            e2eLog("[busy] replies: \(replies)")
            // It really was a long turn the message had to wait for.
            #expect(Date().timeIntervalSince(started) >= TimeInterval(E2E.longTurnSeconds) / 2,
                    "the long turn was over too soon to have run the command: \(replies)")
            // The long turn finished first, then the waiting message was answered.
            let slept = replies.firstIndex { $0.contains("SLEPT") }, plum = replies.lastIndex { $0.contains("PLUM") }
            #expect(slept != nil && plum != nil && slept! < plum!, "replies in order: \(replies)")
            let agent = await Task.detached { ClaudeCLI.agent(short: short) }.value
            #expect(agent?.sessionId == sid, "after: \(ClaudeCLI.describe(agent))")
        }
    }

    // MARK: 3

    /// A background session in the home folder. Claude Code on this Mac reopens one (seen with 2.1.330), so it is
    /// listed as reachable and a message is answered. Where Claude Code has refused one before (remembered by the
    /// engine; seen on a user's MacBook), a running one is greyed and refused before anything is done to it.
    @Test func homeFolderSession() async {
        await scenario("home") { fx in
            let home = try await homeSession(fx)
            let sid = home.sessionId
            let pidBefore = home.pid
            let registry = SharedEngine.engine.engine.registry
            #expect(!registry.homeFolderMemory.refused, "a fresh support folder remembers no refusal")

            // 1. Nothing remembered: reachable, and the message is delivered and answered by the same session.
            try await waitFor("the home-folder session to be listed as reachable", timeout: E2E.Timeout.listing,
                              observed: { fx.describe(sid) }) {
                fx.session(sid)?.kind == .background && fx.model.rows.first { $0.id == sid }?.reachability == .reachable
            }
            try fx.select(sid)
            // A session in the home folder reads ~/.claude/settings.json as its project settings, so its hooks report
            // to the installed app, never to the test engine. The runner stands in for its Stop hook: once the
            // transcript holds the finished answer to this message, the test engine is told, as the hook would.
            let prompt = E2E.Words.reply("HOMEWARD")
            let transcript = home.transcriptPath ?? ""
            let sentAt = Date()
            let stopHook = Task.detached { () -> Bool in
                let deadline = Date().addingTimeInterval(E2E.Timeout.firstAnswer)
                while Date() < deadline, !Task.isCancelled {
                    if TranscriptReader.turnIsOpen(transcriptPath: transcript) == false,
                       TranscriptReader.finalTurnText(transcriptPath: transcript, promptId: nil, marker: prompt) != nil,
                       let modified = (try? FileManager.default.attributesOfItem(atPath: transcript))?[.modificationDate] as? Date,
                       modified > sentAt {
                        let o: [String: Any] = ["session_id": sid, "hook_event_name": Constants.HookEvents.stop,
                                                "transcript_path": transcript, "cwd": home.cwd ?? ""]
                        guard let data = try? JSONSerialization.data(withJSONObject: o),
                              let event = HookEvent(json: data, claudePid: nil) else { return false }
                        SharedEngine.engine.engine.registry.apply(event)
                        return true
                    }
                    try? await Task.sleep(for: .seconds(E2E.Timeout.poll))
                }
                return false
            }
            try await fx.send(prompt, to: sid)
            stopHook.cancel()
            e2eLog("[home] stood in for the Stop hook: \(await stopHook.value)")
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[home] send: \(String(describing: fx.model.currentError)); reply \(reply.prefix(80)); "
                + "refusal remembered: \(registry.homeFolderMemory.refused)")
            if case let .cannotReach(blocker, _, _, detail)? = fx.model.currentError {
                // Claude Code here has started refusing: the refusal must be remembered and the row greyed.
                #expect(registry.homeFolderMemory.refused)
                Issue.record("Claude Code on this Mac refused the home-folder session (\(blocker)): \(detail ?? "-")")
                return
            }
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError)); \(fx.describeThread(sid))")
            #expect(fx.lastEntry(role: .you, of: sid)?.delivery == .delivered, "\(fx.describeThread(sid))")
            #expect(reply.uppercased().contains("HOMEWARD"), "reply was: \(reply)")
            #expect(!registry.homeFolderMemory.refused)
            let resumed = await Task.detached { ClaudeCLI.agent(short: home.agentId) }.value
            #expect(resumed?.sessionId == sid, "after: \(ClaudeCLI.describe(resumed))")
            fx.model.dismissError()

            // 2. A refusal remembered from before: greyed, explained, and refused before any stop.
            try await waitForBlocking("the resumed home-folder session to finish its answer", timeout: E2E.Timeout.firstAnswer,
                                      observed: { ClaudeCLI.describe(ClaudeCLI.agent(short: home.agentId)) }) {
                ClaudeCLI.agent(short: home.agentId).map { $0.isRunning && $0.status != Constants.ClaudeCLI.busyStatus } ?? false
            }
            let pidRunning = await Task.detached { ClaudeCLI.agent(short: home.agentId) }.value?.pid
            e2eLog("[home] running again as pid \(pidRunning.map(String.init) ?? "-") (was \(pidBefore.map(String.init) ?? "-"))")
            fx.rememberHomeFolderRefusal()
            try await waitFor("the home-folder session to be greyed in the list", timeout: E2E.Timeout.listing,
                              observed: { fx.describe(sid) }) {
                fx.model.rows.first { $0.id == sid }?.reachability == .blocked(.homeFolder)
            }
            // Picking it explains instead of switching.
            let before = fx.model.targetId
            fx.model.pickSession(sid)
            #expect(fx.model.targetId == before)
            #expect(fx.model.currentError == .cannotReach(.homeFolder, messageSaved: false, detail: nil))
            fx.model.dismissError()
            // Sending anyway is refused by the engine's own check, before any stop.
            try fx.select(sid)
            try await fx.send(E2E.Words.reply("NO"), to: sid)
            guard case let .cannotReach(blocker, _, stopped, detail)? = fx.model.currentError else {
                throw E2EFailure("expected the home-folder refusal, got \(String(describing: fx.model.currentError)); \(fx.describeThread(sid))")
            }
            #expect(blocker == .homeFolder)
            #expect(!stopped)
            #expect(detail?.contains("checked before stopping") == true, "detail: \(detail ?? "-")")
            let entry = fx.lastEntry(role: .you, of: sid)
            #expect(entry?.delivery == .refused(Design.Copy.Unreachable.title(.homeFolder)), "\(fx.describeThread(sid))")
            #expect(entry?.canRetry == false)
            let after = await Task.detached { ClaudeCLI.agent(short: home.agentId) }.value
            e2eLog("[home] after the refused send: \(ClaudeCLI.describe(after))")
            #expect(after?.isRunning == true, "the home-folder session is no longer running: \(ClaudeCLI.describe(after))")
            #expect(after?.pid == pidRunning, "its process changed: \(pidRunning.map(String.init) ?? "-") -> \(ClaudeCLI.describe(after))")
            #expect(fx.model.rows.first { $0.id == sid }?.reachable == false)
        }
    }

    // MARK: 4

    /// A background session started and stopped at once, before its first answer: its id, its transcript path
    /// and whether that transcript holds a finished answer.
    private func stoppedEarly(_ fx: Fixture, _ label: String) async throws -> (sid: String, short: String, transcript: String) {
        let (sid, short) = try await fx.startBackground(label, prompt: "Write a 400-word story about a lighthouse keeper.")
        await ClaudeCLI.run([Constants.ClaudeCLI.stopCommand, short], cwd: nil)
        try await waitForBlocking("\(short) to stop", timeout: E2E.Timeout.stop,
                                  observed: { ClaudeCLI.describe(ClaudeCLI.agent(short: short)) }) {
            ClaudeCLI.agent(short: short)?.isRunning == false
        }
        guard let transcript = await Task.detached(operation: { ClaudeCLI.agent(short: short) }).value?.transcriptPath else {
            throw E2EFailure("no transcript path for \(short)")
        }
        let answered = TranscriptReader.sessionHasAnswered(sid, hint: transcript)
        e2eLog("[never-answered] \(short) stopped early; finished answer in its transcript: \(answered.map(String.init) ?? "unknown")")
        guard answered == false else {
            throw E2EFailure("could not produce a session that never answered: \(short) finished (or hid) its answer before `claude stop` landed")
        }
        return (sid, short, transcript)
    }

    /// Asks Claude Code itself to reopen a session (the judge of whether Sidemoon was right to refuse it).
    private func claudeCodeReopens(_ fx: Fixture, _ sid: String) async -> (accepted: Bool, said: String) {
        let r = await ClaudeCLI.run([Constants.ClaudeCLI.resumeFlag, sid, Constants.ClaudeCLI.backgroundFlag, E2E.Words.reply("CHECK")],
                                    cwd: fx.project)
        let said = (r.stdoutText + r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        e2eLog("[never-answered] claude --resume \(SessionID.short(sid)) --bg itself exited \(r.status): \(said.prefix(400))")
        return (r.status == 0, said)
    }

    /// Sessions stopped before their first answer finished. Claude Code decides whether such a session can be
    /// reopened; Sidemoon must refuse, without touching the session, exactly when Claude Code would.
    @Test func neverAnsweredSession() async {
        await scenario("never-answered") { fx in
            // 1. A session stopped before its first answer, with its transcript gone.
            let gone = try await stoppedEarly(fx, "never-answered-gone")
            let ownFolder = "\(Constants.Paths.claudeProjectsDirectory)/\(fx.project.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined())/"
            guard gone.transcript.hasPrefix(ownFolder) else { throw E2EFailure("\(gone.transcript) is not in this run's project folder \(ownFolder)") }
            try? FileManager.default.removeItem(atPath: gone.transcript)
            try await waitFor("the test engine to list it", timeout: E2E.Timeout.listing, observed: { fx.describe(gone.sid) }) {
                fx.session(gone.sid)?.kind == .background && fx.session(gone.sid)?.state != .working
            }
            // Sidemoon does not stop a session that is already stopped, so it leaves the decision to Claude Code,
            // which reopens it: the message goes through and is answered.
            try fx.select(gone.sid)
            try await fx.send(E2E.Words.reply("NO"), to: gone.sid)
            let goneReply = fx.lastEntry(role: .session, of: gone.sid)?.text ?? ""
            e2eLog("[never-answered] no transcript: \(String(describing: fx.model.currentError)); reply \(goneReply.prefix(80))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError)); \(fx.describeThread(gone.sid))")
            #expect(goneReply.uppercased().contains("NO"), "reply was: \(goneReply)")
            #expect(SessionList.rows(fx.model.sessions, showEnded: true).first { $0.id == gone.sid }?.blocker == nil,
                    "\(fx.describe(gone.sid))")

            // 2. Its transcript is there but holds no finished answer yet.
            let kept = try await stoppedEarly(fx, "never-answered-kept")
            let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: kept.transcript))?[.size] as? Int
            try await waitFor("the test engine to list it", timeout: E2E.Timeout.listing, observed: { fx.describe(kept.sid) }) {
                fx.session(kept.sid)?.kind == .background && fx.session(kept.sid)?.state != .working
            }
            fx.model.dismissError()
            try fx.select(kept.sid)
            try await fx.send(E2E.Words.reply("KEPT"), to: kept.sid)
            if case let .cannotReach(blocker, _, _, detail)? = fx.model.currentError {
                e2eLog("[never-answered] transcript without an answer: refused (\(blocker)); detail: \(detail ?? "-")")
                let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: kept.transcript))?[.size] as? Int
                #expect(sizeAfter == sizeBefore, "refused, yet its transcript changed")
                let judge = await claudeCodeReopens(fx, kept.sid)
                let said = judge.said.prefix(200)
                #expect(!judge.accepted, "Sidemoon refused a session Claude Code reopens: its transcript has no finished answer, but Claude Code resumed it (\(said))")
            } else {
                let reply = fx.lastEntry(role: .session, of: kept.sid)?.text ?? ""
                e2eLog("[never-answered] transcript without an answer: \(String(describing: fx.model.currentError)); reply \(reply.prefix(80))")
                #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError))")
                #expect(reply.uppercased().contains("KEPT"), "reply was: \(reply)")
            }
        }
    }

    // MARK: 5

    /// An ended session is resumed headlessly and answers; a turn Sidemoon did not start also shows up.
    @Test func endedSession() async {
        await scenario("ended") { fx in
            // A terminal session that answered once and was then closed.
            let sid = UUID().uuidString.lowercased()
            let pty = try fx.startTerminal("ended", sessionId: sid, extraArgs: [], prompt: E2E.Words.readyPrompt)
            try await waitFor("its first answer", timeout: E2E.Timeout.firstAnswer, observed: { "\(fx.describe(sid)); screen: \(pty.tail)" }) {
                fx.session(sid)?.lastReply?.uppercased().contains(E2E.Words.ready) == true
            }
            await pty.end()
            try await waitFor("hooks to report the session ending", timeout: E2E.Timeout.hook, observed: { fx.describe(sid) }) {
                fx.session(sid)?.state == .ended
            }
            #expect(!fx.model.rows.contains { $0.id == sid }, "ended sessions are hidden by default")
            try fx.select(sid)
            #expect(fx.model.target?.routes == [.headless], "\(fx.describe(sid))")
            try await fx.send(E2E.Words.reply("KIWI"), to: sid)
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError))")
            #expect(reply.uppercased().contains("KIWI"), "reply was: \(reply); \(fx.describeThread(sid))")
            // A turn started outside Sidemoon still lands in the thread.
            let ext = await ClaudeCLI.run([Constants.ClaudeCLI.printFlag, Constants.ClaudeCLI.resumeFlag, sid] + E2E.settingSources
                + ["--model", E2E.model, E2E.Words.reply("BANANA")], cwd: fx.project)
            #expect(ext.status == 0, "external turn exited \(ext.status)")
            try await waitFor("the outside turn's answer to show", timeout: E2E.Timeout.hook, observed: { fx.describeThread(sid) }) {
                fx.model.latestReply?.uppercased().contains("BANANA") == true
            }
            #expect(fx.model.indicator == .replyReady)

            // A `claude -p` session ends a moment after its answer; it must be listed as ended too, so that
            // the headless route can reach it.
            let quick = UUID().uuidString.lowercased()
            ClaudeCLI.appendToLedger(E2E.Ledger.headless, quick)
            let printed = await ClaudeCLI.run([Constants.ClaudeCLI.printFlag] + E2E.settingSources
                + ["--model", E2E.model, "-n", "\(E2E.namePrefix)-ended-print", "--session-id", quick, E2E.Words.readyPrompt], cwd: fx.project)
            #expect(printed.status == 0, "claude -p exited \(printed.status)")
            do {
                try await waitFor("the claude -p session to be listed as ended", timeout: E2E.Timeout.hook,
                                  observed: { fx.describe(quick) }) { fx.session(quick)?.state == .ended }
            } catch {
                let why = "With lastEvent=Stop, its Stop hook was applied after its SessionEnd hook and put it back to idle, "
                    + "so nothing can reach it."
                Issue.record("[ended] \(error). \(why)")
            }
        }
    }

    // MARK: 6

    /// An MCP config that loads the Sidemoon helper (by default the test build, run directly) on the test socket.
    private func channelConfig(_ name: String, command: String = E2E.helper, args: [String] = [Constants.Channel.subcommand],
                               env extra: [String: String] = [:]) throws -> String {
        var env = [Constants.Paths.supportDirectoryOverrideVariable: Constants.Paths.supportDirectoryOverride ?? ""]
        env.merge(extra) { $1 }
        let config: [String: Any] = ["mcpServers": [Constants.Channel.serverName: ["command": command, "args": args, "env": env]]]
        let path = "\(E2E.run)/\(name)-mcp.json"
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// A terminal session started with the channel gets the message through the channel; it is never restarted.
    /// It also records what showed the engine that Claude Code picked the message up.
    @Test func terminalChannelSession() async {
        await scenario("channel") { fx in
            let configPath = try channelConfig("channel")
            let sid = UUID().uuidString.lowercased()
            let events = HookLog(fx.guarded, sessionId: sid)
            let pty = try fx.startTerminal("channel", sessionId: sid, extraArgs: [
                Constants.ClaudeCLI.channelLaunchFlags[0], configPath,
                Constants.ClaudeCLI.channelLaunchFlags[1], Constants.ClaudeCLI.channelLaunchValue])
            let pid = pty.pid
            try await waitFor("the channel to connect", timeout: E2E.Timeout.terminalStart,
                              observed: { "\(fx.describe(sid)); screen: \(pty.tail)" }) {
                fx.session(sid)?.channelConnected == true
            }
            e2eLog("[channel] connected; development-channels question answered: \(pty.asked(E2E.Terminal.developmentChannelsChoice))")
            #expect(fx.model.rows.first { $0.id == sid }?.reachable == true)
            #expect(fx.session(sid)?.channelDropped == false)
            try fx.select(sid)
            #expect(fx.model.target?.routes.first == .channel)
            // Watch the transcript for the delivery marker while the message travels.
            let transcript = fx.session(sid)?.transcriptPath ?? ""
            let sentAt = Date()
            let marker = Task.detached { () -> TimeInterval? in
                let deadline = Date().addingTimeInterval(Constants.Timeouts.replyWait)
                while Date() < deadline, !Task.isCancelled {
                    if TranscriptReader.contains(transcript, Constants.Channel.deliveryIdMetaKey) { return Date().timeIntervalSince(sentAt) }
                    try? await Task.sleep(for: .seconds(E2E.Timeout.poll))
                }
                return nil
            }
            try await fx.send(E2E.Words.reply("LEMON"), to: sid)
            let took = Date().timeIntervalSince(sentAt)
            marker.cancel()
            let markerAfter = await marker.value
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[channel] answered after \(String(format: "%.1f", took))s; delivery marker in the transcript after "
                + "\(markerAfter.map { String(format: "%.1f", $0) + "s" } ?? "never"); hooks after the send: \(events.since(sentAt))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError)); screen: \(pty.tail)")
            #expect(reply.uppercased().contains("LEMON"), "reply was: \(reply); screen: \(pty.tail)")
            // The sign the engine waits for: the marker shows up well within the pick-up wait.
            #expect(markerAfter.map { $0 < Constants.Timeouts.channelPickupWait } == true, "marker after \(String(describing: markerAfter))")
            // Never restarted: the same process, still running, still this session, still on the channel.
            #expect(pty.isRunning && pty.pid == pid, "the terminal session's process ended or changed")
            #expect(fx.session(sid)?.channelConnected == true, "\(fx.describe(sid))")
            #expect(fx.session(sid)?.pid == pid, "hooks report pid \(fx.session(sid)?.pid.map(String.init) ?? "-"), started \(pid)")
        }
    }

    // MARK: 6a

    /// "Connect every claude": plain `claude` typed in zsh goes through the block and the launcher, gets the channel
    /// (the flags in their one-word form, followed by the session's own arguments), and a message is delivered over it.
    @Test func wrappedPlainClaude() async {
        await scenario("wrapped") { fx in
            let configPath = try channelConfig("wrapped")
            // The launcher and a zsh startup folder in the scratch run folder, as Setup would write them.
            let launcher = "\(E2E.run)/wrapped-bin/\(Constants.Paths.launcherName)"
            let zdotdir = "\(E2E.run)/wrapped-zsh"
            try FileManager.default.createDirectory(atPath: (launcher as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            try LauncherScript.content(configPath: configPath, helper: E2E.helper, home: home)
                .write(toFile: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: CompanionConstants.Setup.launcherPermissions)],
                                                  ofItemAtPath: launcher)
            let shell = ShellIntegration(home: zdotdir, loginShell: E2E.Terminal.zsh, launcher: launcher, fileSystem: SystemShellFileSystem())
            let report = shell.enable()
            #expect(report.changed == ["\(zdotdir)/\(CompanionConstants.ShellIntegration.zshFile)"], "\(report)")

            let sid = UUID().uuidString.lowercased()
            let pty = try fx.startWrappedTerminal("wrapped", sessionId: sid, zdotdir: zdotdir)
            defer {
                // The session runs under zsh: end it directly too.
                if let pid = fx.session(sid)?.pid { kill(pid, SIGTERM) }
            }
            try await waitFor("the channel to connect", timeout: E2E.Timeout.terminalStart,
                              observed: { "\(fx.describe(sid)); screen: \(pty.tail)" }) {
                fx.session(sid)?.channelConnected == true
            }
            if let pid = fx.session(sid)?.pid { ClaudeCLI.appendToLedger(E2E.Ledger.process, "\(pid) \(E2E.namePrefix)-wrapped") }
            let confirmed = pty.asked(E2E.Terminal.developmentChannelsChoice)
            let warned = pty.text.contains(E2E.Terminal.noServerWarning)
            e2eLog("[wrapped] connected; development-channels question asked: \(confirmed); "
                + "\"no MCP server configured\" shown: \(warned)")
            #expect(confirmed, "the per-launch question was expected; screen: \(pty.tail)")
            try fx.select(sid)
            #expect(fx.model.target?.routes.first == .channel)
            try await fx.send(E2E.Words.reply("PLUM"), to: sid)
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError)); screen: \(pty.tail)")
            #expect(reply.uppercased().contains("PLUM"), "reply was: \(reply); screen: \(pty.tail)")
        }
    }

    // MARK: 6b

    /// A terminal session started with only `--mcp-config`, as Claude Code starts the process that hosts a session
    /// it moved to the background (seen on a user's MacBook). The helper runs and connects, but Claude Code ignores
    /// what it pushes. Sidemoon must not claim the channel, and a send must never wait the full reply timeout.
    /// Then the same with a helper that is misled into claiming a channel (its parent is a shell whose command
    /// line names the channel flag): the pick-up check must catch it within the short wait.
    @Test func mcpWithoutChannel() async {
        await scenario("mcp-without-channel") { fx in
            let mcpOnly = Constants.ClaudeCLI.channelLaunchFlags[0]
            let replyWait = Constants.Timeouts.replyWait

            // 1. The helper's parent is that process itself: it says it is not a channel.
            let plain = UUID().uuidString.lowercased()
            let plainPty = try fx.startTerminal("mcp-only", sessionId: plain, extraArgs: [mcpOnly, try channelConfig("mcp-only")])
            try await waitFor("the helper to connect for the session", timeout: E2E.Timeout.terminalStart,
                              observed: { "\(fx.describe(plain)); screen: \(plainPty.tail)" }) {
                fx.session(plain)?.channelDropped == true
            }
            #expect(fx.session(plain)?.channelConnected == false, "\(fx.describe(plain))")
            #expect(fx.model.rows.first { $0.id == plain }?.reachability == .channelDropped, "\(fx.describe(plain))")
            try fx.select(plain)
            let plainStart = Date()
            try await fx.send(E2E.Words.reply("FIG"), to: plain)
            let plainTook = Date().timeIntervalSince(plainStart)
            e2eLog("[mcp-without-channel] not a channel: \(String(describing: fx.model.currentError)) after \(String(format: "%.1f", plainTook))s; "
                + "\(fx.describeThread(plain))")
            #expect(plainTook < replyWait / 10, "took \(plainTook)s")
            if fx.lastEntry(role: .you, of: plain)?.delivery != .delivered {
                #expect(fx.model.currentError == .notPickedUp(fallback: nil), "error: \(String(describing: fx.model.currentError))")
            }
            fx.model.dismissError()

            // 2. A helper misled into claiming a channel; its session id comes from its environment, as the real
            //    helper's does until a hook binds it.
            let misled = UUID().uuidString.lowercased()
            let wrapper = try channelConfig("mcp-misled", command: E2E.shell,
                                            args: [E2E.shellCommandFlag, E2E.runHelperThenExit, E2E.helper,
                                                   Constants.ClaudeCLI.channelLaunchFlags[1], Constants.ClaudeCLI.channelLaunchValue],
                                            env: [Constants.Channel.sessionIdEnv: misled])
            let misledPty = try fx.startTerminal("mcp-misled", sessionId: misled, extraArgs: [mcpOnly, wrapper])
            try await waitFor("the misled helper to claim the session", timeout: E2E.Timeout.terminalStart,
                              observed: { "\(fx.describe(misled)); screen: \(misledPty.tail)" }) {
                fx.session(misled)?.channelConnected == true && fx.session(misled)?.lastEventName != nil
            }
            try fx.select(misled)
            let misledStart = Date()
            try await fx.send(E2E.Words.reply("DATE"), to: misled)
            let misledTook = Date().timeIntervalSince(misledStart)
            let failed = fx.lastEntry(role: .you, of: misled)
            e2eLog("[mcp-without-channel] misled helper: \(String(describing: fx.model.currentError)) after "
                + "\(String(format: "%.1f", misledTook))s; \(fx.describe(misled)); \(fx.describeThread(misled))")
            #expect(misledTook < Constants.Timeouts.channelPickupWait + replyWait / 10, "took \(misledTook)s")
            if failed?.delivery == .delivered {
                // Claude Code took the push from a server it did not load as a channel: then it must be answered.
                let reply = fx.lastEntry(role: .session, of: misled)?.text ?? ""
                Issue.record("Claude Code picked up a push from a non-channel server; reply: \(reply)")
                return
            }
            #expect(fx.model.currentError == .notPickedUp(fallback: nil), "error: \(String(describing: fx.model.currentError))")
            #expect(failed?.canRetry == true, "\(fx.describeThread(misled))")
            #expect(fx.session(misled)?.channelConnected == false && fx.session(misled)?.channelDropped == true, "\(fx.describe(misled))")
            // Retry does not wait on that connection again.
            let retryStart = Date()
            if let id = failed?.id { await fx.model.retry(id) }
            let retryTook = Date().timeIntervalSince(retryStart)
            e2eLog("[mcp-without-channel] Retry: \(String(describing: fx.model.currentError)) after \(String(format: "%.1f", retryTook))s")
            #expect(retryTook < Constants.Timeouts.channelPickupWait / 2, "Retry took \(retryTook)s")
            #expect(fx.model.currentError == .notPickedUp(fallback: nil))
            // Both sessions are still the processes the scenario started.
            #expect(plainPty.isRunning && misledPty.isRunning)
        }
    }

    // MARK: 7

    /// A capture showing one word, then a dropped text file, each reach the session and are answered from.
    @Test func imageAndFile() async throws {
        let word = "ZEBRA", phrase = "PURPLE-HORIZON-42"
        let files = "\(E2E.run)/files"
        try FileManager.default.createDirectory(atPath: files, withIntermediateDirectories: true)
        let image = URL(fileURLWithPath: "\(files)/word.png")
        try TestImage.write(word: word, to: image)
        await scenario("attachments", image: image) { fx in
            let (sid, short) = try await fx.startBackground("attachments", prompt: E2E.Words.readyPrompt)
            try await fx.waitUntilIdle(sid, short: short, reply: E2E.Words.ready)
            try fx.select(sid)
            // The capture: the injected image stands in for the region the user would drag.
            await fx.model.captureAndSend(note: "What single word is written in this image? Reply with only that word.")
            let seen = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[attachments] image reply: \(seen.prefix(80))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError))")
            #expect(seen.uppercased().contains(word), "reply was: \(seen)")
            #expect(fx.store.files().isEmpty, "the capture file should be deleted after delivery")
            // The dropped file waits for a note, then goes with it.
            let note = URL(fileURLWithPath: "\(files)/notes.txt")
            try Data("The secret phrase is \(phrase).\n".utf8).write(to: note)
            let model = fx.model
            guard model.targetId == sid else { throw E2EFailure("target moved before the drop") }
            let dropping = Task { await model.dropFiles([note]) }
            try await waitFor("the dropped file to wait for a note", timeout: E2E.Timeout.hook,
                              observed: { "holding=\(model.isHoldingCapture) activity=\(model.status.activity)" }) { model.heldFiles == [note] }
            model.noteDraft = "Quote the secret phrase from this file exactly, and nothing else."
            model.submitHeldCapture()
            await dropping.value
            let quoted = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[attachments] file reply: \(quoted.prefix(80))")
            #expect(fx.model.currentError == nil, "error: \(String(describing: fx.model.currentError))")
            #expect(quoted.contains(phrase), "reply was: \(quoted)")
            #expect(FileManager.default.fileExists(atPath: note.path), "the dropped file must never be moved or deleted")
        }
    }

    // MARK: 8

    /// A send that fails can be sent again with Retry once the session can be reached; a refusal offers no Retry.
    @Test func retryAfterFailure() async {
        await scenario("retry") { fx in
            // A terminal session started with plain `claude` (the target from before, say): nothing reaches it
            // while it is open, and the headless route does once it is closed.
            let sid = UUID().uuidString.lowercased()
            let pty = try fx.startTerminal("retry", sessionId: sid, extraArgs: [], prompt: E2E.Words.readyPrompt)
            try await waitFor("its first answer", timeout: E2E.Timeout.firstAnswer, observed: { "\(fx.describe(sid)); screen: \(pty.tail)" }) {
                fx.session(sid)?.lastReply?.uppercased().contains(E2E.Words.ready) == true
            }
            try fx.select(sid)
            try await fx.send(E2E.Words.reply("AGAIN"), to: sid)
            let failed = fx.lastEntry(role: .you, of: sid)
            e2eLog("[retry] first send: \(String(describing: fx.model.currentError)); \(fx.describeThread(sid))")
            #expect(fx.model.currentError == .noRoute, "error: \(String(describing: fx.model.currentError))")
            #expect(failed?.canRetry == true, "\(fx.describeThread(sid))")
            await pty.end()
            try await waitFor("the session to end", timeout: E2E.Timeout.hook, observed: { fx.describe(sid) }) { fx.session(sid)?.state == .ended }
            guard let failedId = failed?.id else { throw E2EFailure("no failed entry to retry") }
            await fx.model.retry(failedId)
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[retry] after Retry: \(String(describing: fx.model.currentError)); reply \(reply.prefix(80))")
            #expect(fx.model.currentError == nil)
            #expect(reply.uppercased().contains("AGAIN"), "reply was: \(reply); \(fx.describeThread(sid))")
            #expect(!fx.model.threads.thread(for: sid).contains { $0.id == failedId }, "the failed entry is replaced")
            #expect(fx.model.threads.thread(for: sid).filter { $0.role == .you }.last?.delivery == .delivered)

            // A refusal: no Retry, and asking for one sends nothing. Claude Code on this Mac reopens home-folder
            // sessions, so the refusal is the one remembered where it does not.
            let home = try await homeSession(fx)
            fx.rememberHomeFolderRefusal()
            try fx.select(home.sessionId)
            try await fx.send(E2E.Words.reply("NO"), to: home.sessionId)
            let refused = fx.lastEntry(role: .you, of: home.sessionId)
            #expect(refused?.canRetry == false, "\(fx.describeThread(home.sessionId))")
            let sends = fx.guarded.sendCount
            if let id = refused?.id { await fx.model.retry(id) }
            #expect(fx.guarded.sendCount == sends, "Retry sent a refused message again")
        }
    }

    // MARK: 9

    /// The session list says what can really be reached, and why not when it cannot.
    @Test func sessionListTruth() async {
        await scenario("session-list") { fx in
            let home = try await homeSession(fx)
            // As where Claude Code refuses home-folder sessions (this Mac's Claude Code reopens them).
            fx.rememberHomeFolderRefusal()
            let (sid, short) = try await fx.startBackground("session-list", prompt: E2E.Words.readyPrompt)
            // A terminal session started with plain `claude`: no prompt is given, so it costs nothing.
            let plain = UUID().uuidString.lowercased()
            let pty = try fx.startTerminal("plain", sessionId: plain, extraArgs: [])
            try await fx.waitUntilIdle(sid, short: short)
            try await waitFor("the plain terminal session's first hook", timeout: E2E.Timeout.terminalStart,
                              observed: { "\(fx.describe(plain)); screen: \(pty.tail)" }) { fx.session(plain) != nil }
            try await waitFor("the home-folder row to be greyed", timeout: E2E.Timeout.listing, observed: { fx.describe(home.sessionId) }) {
                fx.model.rows.first { $0.id == home.sessionId }?.reachability == .blocked(.homeFolder)
            }
            let rows = Dictionary(fx.model.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in [home.sessionId, sid, plain] { e2eLog("[session-list] \(SessionID.short(id)): \(fx.describe(id))") }
            // The truth, from Claude Code: the home session runs; the project session runs or can be reopened.
            let listing = await Task.detached { ClaudeCLI.agents() }.value
            let homeNow = listing.first { $0.sessionId == home.sessionId }
            #expect(homeNow?.isRunning == true, "home: \(ClaudeCLI.describe(homeNow))")
            #expect(rows[home.sessionId]?.reachable == false)
            #expect(rows[home.sessionId]?.blocker == .homeFolder)
            #expect(Design.Copy.Unreachable.reason(.homeFolder) == "Started in your home folder")
            #expect(listing.contains { $0.sessionId == sid }, "project session not listed")
            #expect(rows[sid]?.reachability == .reachable, "project: \(fx.describe(sid))")
            #expect(rows[plain]?.reachability == .needsChannel, "plain terminal: \(fx.describe(plain))")
            // Picking the plain terminal session explains what to do instead.
            let before = fx.model.targetId
            fx.model.pickSession(plain)
            #expect(fx.model.targetId == before)
            #expect(fx.model.currentError == .needsLauncher)
            #expect(fx.model.remedies(for: .needsLauncher).first == .copyResumeCommand
                    || fx.model.remedies(for: .needsLauncher).first == .installTerminalCommand)
            fx.model.dismissError()
            fx.model.pickSession(sid)
            #expect(fx.model.targetId == sid && fx.model.currentError == nil)
        }
    }

    // MARK: 10

    /// A session started from the companion: the form's Start runs `claude --bg` in a fresh project folder, the new
    /// session becomes the target with the first message in its thread, its answer arrives through the hooks, and a
    /// second message reaches the same session.
    @Test func createSession() async {
        await scenario("create") { fx in
            let model = fx.model
            model.openNewSession()
            model.chooseNewSessionFolder(fx.project)
            model.newSessionMessage = E2E.Words.reply("FIG")
            #expect(model.canStartNewSession, "note: \(String(describing: model.newSessionFolderNote))")
            let started = Date()
            await model.startNewSession()
            let took = Date().timeIntervalSince(started)
            guard let sid = model.targetId, model.newSession.problem == nil else {
                throw E2EFailure("not started: \(String(describing: model.newSession.problem)) \(model.newSession.problemDetail ?? "")")
            }
            let short = SessionID.short(sid)
            fx.adoptBackground(short)
            e2eLog("[create] started \(short) (\(sid)) in \(String(format: "%.1f", took))s; \(fx.describe(sid)); "
                + "awaiting=\(model.isAwaitingReply)")
            #expect(!model.isCreatingSession)
            #expect(fx.session(sid)?.kind == .background, "\(fx.describe(sid))")
            #expect(fx.session(sid)?.cwd == fx.project, "\(fx.describe(sid))")
            let first = model.threads.thread(for: sid).first
            #expect(first?.role == .you && first?.text == E2E.Words.reply("FIG") && first?.delivery == .delivered,
                    "\(fx.describeThread(sid))")
            // The first answer comes through the Stop hook, like any other.
            try await waitFor("the first answer in the thread", timeout: E2E.Timeout.firstAnswer,
                              observed: { "\(fx.describeThread(sid)); \(fx.describe(sid))" }) {
                fx.lastEntry(role: .session, of: sid)?.text.uppercased().contains("FIG") == true
            }
            e2eLog("[create] first answer after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(fx.describeThread(sid))")
            #expect(model.currentError == nil, "error: \(String(describing: model.currentError))")
            // The second message goes to the same session.
            try await fx.waitUntilIdle(sid, short: short)
            try await fx.send(E2E.Words.reply("KIWI"), to: sid)
            let reply = fx.lastEntry(role: .session, of: sid)?.text ?? ""
            e2eLog("[create] second reply \(reply.prefix(80)); \(fx.describeThread(sid))")
            #expect(model.currentError == nil, "error: \(String(describing: model.currentError))")
            #expect(fx.lastEntry(role: .you, of: sid)?.delivery == .delivered, "\(fx.describeThread(sid))")
            #expect(reply.uppercased().contains("KIWI"), "reply was: \(reply)")
            let listed = await Task.detached { ClaudeCLI.agents() }.value.filter { $0.cwd == fx.project }
            #expect(listed.map(\.sessionId) == [sid], "sessions in the project: \(listed.map { ClaudeCLI.describe($0) })")
            #expect(listed.first?.name == "\(E2E.namePrefix)-\(E2E.createdName)", "\(listed.map { $0.name ?? "-" })")
            #expect(TranscriptReader.contains(listed.first?.transcriptPath ?? "", "KIWI"), "KIWI is not in the transcript")
        }
    }
}
