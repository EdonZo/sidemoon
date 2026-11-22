import Foundation
import Testing
@testable import SidemoonCore

/// The session `agents(...)` in EngineTests lists.
private let listed = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

/// Claude Code's words from the two refusals seen on a real Mac (1.0.0), and others it prints.
private enum Said {
    static let homeFolder = "Workspace not trusted. The home directory is trusted one session at a time — start this from an "
        + "interactive terminal there, or from a project directory. Your message is saved and will be delivered when session "
        + "a2772618 next starts."
    static let noTranscript = "This session has no saved transcript — it was stopped before its first response finished. If it "
        + "was backgrounded from another conversation, that one is still intact; `claude respawn e73d914a` starts this one fresh. "
        + "Your message is saved and will be delivered when session e73d914a next starts."
    static let untrusted = "Workspace not trusted. Run `claude` in ~/Projects/api-server once and accept the trust prompt, then retry."
    static let loginExpired = "Failed to authenticate: your claude.ai login expired. Run /login to sign in again."
    static let loginRequired = "login required — run /login"
    static let notSignedIn = "this computer is not signed in to claude.ai (run claude /login), or its login expired."
}

private func refusedOrStopped(_ runner: FakeRunner) -> Bool {
    runner.recorded.contains { $0.first == Constants.ClaudeCLI.stopCommand || $0.first == Constants.ClaudeCLI.resumeFlag }
}

private func engine(_ runner: FakeRunner, home: String = "/Users/someone", answered: Bool? = true) -> Engine {
    let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner,
                   registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in answered }, home: home))
    e.refreshAgents()
    return e
}

@Suite struct ResumePreflightTests {
    @Test func homeFolderSessionIsRefusedWithoutStopping() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done", cwd: "/Users/someone"))
        let e = engine(runner)
        // The session list already knows, before anything is sent.
        #expect(e.registry.session(listed)?.blocker == .homeFolder)
        let r = e.send(SendRequest(session: listed, text: "hi"))
        #expect(!r.ok)
        #expect(r.failure == .cannotResume(.homeFolder, messageSaved: false))
        #expect(r.route == .background)
        #expect(!refusedOrStopped(runner))
    }

    @Test func homeFolderIsComparedAsAPath() {
        #expect(ResumeCheck.isHomeFolder("/Users/someone/", home: "/Users/someone"))
        #expect(ResumeCheck.isHomeFolder("/Users/someone/projects/..", home: "/Users/someone"))
        #expect(!ResumeCheck.isHomeFolder("/Users/someone/projects", home: "/Users/someone"))
        #expect(!ResumeCheck.isHomeFolder("/Users/someoneelse", home: "/Users/someone"))
    }

    @Test func sessionThatNeverAnsweredIsRefusedWithoutStopping() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "blocked"))
        let e = engine(runner, answered: false)
        #expect(e.registry.session(listed)?.blocker == .noTranscript)
        let r = e.send(SendRequest(session: listed, text: "hi"))
        #expect(r.failure == .cannotResume(.noTranscript, messageSaved: false))
        #expect(!refusedOrStopped(runner))
    }

    /// Claude Code reopens a stopped session that never answered (seen in the end-to-end runs), and Sidemoon
    /// stops nothing there, so it is neither greyed out nor refused beforehand.
    @Test func stoppedSessionThatNeverAnsweredIsStillSentTo() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done", running: false),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = engine(runner, answered: false)
        #expect(e.registry.session(listed)?.blocker == nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        #expect(e.send(SendRequest(session: listed, text: "hi")).ok)
    }

    /// `claude -p` sends Stop and SessionEnd together and the end can be applied first: ended stays ended,
    /// and a session that starts again is live again.
    @Test func stopArrivingAfterTheEndDoesNotReviveTheSession() throws {
        let registry = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }, home: "/Users/someone")
        func event(_ name: String) throws -> HookEvent {
            let o: [String: Any] = ["session_id": listed, "hook_event_name": name, "cwd": "/tmp/proj"]
            return try #require(HookEvent(json: try JSONSerialization.data(withJSONObject: o), claudePid: 4242))
        }
        registry.apply(try event(Constants.HookEvents.sessionStart))
        registry.apply(try event(Constants.HookEvents.sessionEnd))
        registry.apply(try event(Constants.HookEvents.stop))
        #expect(registry.session(listed)?.state == .ended)
        registry.apply(try event(Constants.HookEvents.sessionStart))
        registry.apply(try event(Constants.HookEvents.stop))
        #expect(registry.session(listed)?.state == .idle)
    }

    /// A session on its first turn is busy, not blocked: its message waits and goes once it has answered.
    @Test func sessionOnItsFirstTurnIsBusyNotBlocked() {
        let runner = FakeRunner(agentsJSON: agents(status: "busy", state: "working"))
        let e = engine(runner, answered: false)
        #expect(e.registry.session(listed)?.blocker == nil)
        let r = e.send(SendRequest(session: listed, text: "hi"))
        #expect(r.failure == .busy(listed))
        #expect(!refusedOrStopped(runner))
    }

    /// When the transcript cannot be read, nothing is assumed: the session is sent to as before.
    @Test func unknownTranscriptDoesNotBlock() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done", running: false),
                                resumeOutput: "backgrounded · 0b8e8a52 · t\n")
        let e = engine(runner, answered: nil)
        #expect(e.registry.session(listed)?.blocker == nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        #expect(e.send(SendRequest(session: listed, text: "hi")).ok)
    }

    @Test func refusedResumeIsTypedAndRemembered() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done"), resumeOutput: Said.loginExpired, resumeStatus: 1)
        let e = engine(runner)
        let r = e.send(SendRequest(session: listed, text: "hi"))
        // The session was running, so Sidemoon had stopped it before Claude Code refused: the error says so.
        #expect(r.failure == .cannotResume(.loginNeeded, messageSaved: false, stoppedFirst: true))
        #expect(r.error?.contains("stopped") == true)
        // Claude Code's words stay with the result for the Details a bug report can quote.
        #expect(r.detail?.contains("login expired") == true)
        #expect(e.registry.session(listed)?.blocker == .loginNeeded)
        // A later listing does not forget it; the session running again does.
        e.refreshAgents()
        #expect(e.registry.session(listed)?.blocker == .loginNeeded)
        let o: [String: Any] = ["session_id": listed, "hook_event_name": "SessionStart", "cwd": "/tmp/proj"]
        e.registry.apply(HookEvent(json: try! JSONSerialization.data(withJSONObject: o), claudePid: 4242)!)
        #expect(e.registry.session(listed)?.blocker == nil)
    }

    @Test func refusalThatSavedTheMessageSaysSo() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done", running: false),
                                resumeOutput: Said.noTranscript, resumeStatus: 1)
        let r = engine(runner).send(SendRequest(session: listed, text: "hi"))
        // It was not running, so nothing was stopped.
        #expect(r.failure == .cannotResume(.noTranscript, messageSaved: true, stoppedFirst: false))
    }

    @Test func unknownRefusalKeepsTheOldPath() {
        let runner = FakeRunner(agentsJSON: agents(status: "idle", state: "done"), resumeOutput: "something new went wrong", resumeStatus: 1)
        let r = engine(runner).send(SendRequest(session: listed, text: "hi"))
        guard case let .background(m)? = r.failure else { Issue.record("expected the untyped background failure"); return }
        #expect(m.contains("something new went wrong"))
    }
}

@Suite struct ResumeClassificationTests {
    @Test func eachKnownPhraseMapsToItsCase() {
        func check(_ text: String, _ blocker: ResumeBlocker, saved: Bool) {
            let c = ResumeCheck.classify(text)
            #expect(c?.blocker == blocker, "\(text)")
            #expect(c?.messageSaved == saved, "\(text)")
        }
        check(Said.homeFolder, .homeFolder, saved: true)
        check(Said.noTranscript, .noTranscript, saved: true)
        check(Said.untrusted, .untrustedFolder, saved: false)
        check(Said.loginExpired, .loginNeeded, saved: false)
        check(Said.loginRequired, .loginNeeded, saved: false)
        check(Said.notSignedIn, .loginNeeded, saved: false)
        // Case does not matter.
        check(Said.homeFolder.uppercased(), .homeFolder, saved: true)
        #expect(ResumeCheck.classify("resume exited 1: network down") == nil)
        #expect(ResumeCheck.classify("") == nil)
    }

    @Test func descriptionNamesTheCase() {
        #expect(DeliveryError.cannotResume(.homeFolder, messageSaved: true).description.contains("home folder"))
        #expect(DeliveryError.cannotResume(.homeFolder, messageSaved: true).description.contains("saved"))
        #expect(!DeliveryError.cannotResume(.loginNeeded, messageSaved: false).description.contains("saved"))
    }

    @Test func sessionCarriesItsBlockerOverTheSocket() throws {
        var s = Session(id: listed)
        s.blocker = .loginNeeded
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        #expect(back.blocker == .loginNeeded)
        #expect(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(Session(id: listed))).blocker == nil)
    }
}

@Suite struct TranscriptAnswerTests {
    private func file(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-answer-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url.path
    }

    let prompt = #"{"type":"user","message":{"role":"user","content":"go"}}"#
    let answer = #"{"type":"assistant","message":{"role":"assistant","model":"claude","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
    let toolCall = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    /// How Claude Code records a failed login in place of an answer.
    let apiError = #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"Please run /login"}]}}"#
    let syntheticOnly = #"{"type":"assistant","message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[]}}"#
    let subagent = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"#
    let bookkeeping = #"{"type":"last-prompt","note":"padding padding padding padding padding padding padding padding"}"#

    @Test func findsAFinishedAnswer() throws {
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: "/nonexistent/none.jsonl") == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, toolCall])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, apiError])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, syntheticOnly])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, subagent])) == false)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, toolCall, answer])) == true)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, apiError, prompt, answer])) == true)
    }

    /// A long transcript is only read at its ends: an answer there is found, and one only in the middle
    /// leaves it undecided rather than read as never answered.
    @Test func longTranscriptIsReadAtItsEnds() throws {
        let padding = Array(repeating: bookkeeping, count: 3 * Constants.Limits.answerProbeBytes / bookkeeping.utf8.count)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt, answer] + padding)) == true)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file(padding + [prompt, answer])) == true)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file(padding + [answer] + padding)) == nil)
        #expect(TranscriptReader.hasFinishedAnswer(transcriptPath: try file([prompt] + padding)) == nil)
    }

    @Test func locatesTheTranscriptWhereverItIsFiled() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-projects-\(UUID().uuidString)").path
        let folder = "\(projects)/-Users-someone-api-server"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projects) }
        let path = "\(folder)/\(listed).jsonl"
        try Data(answer.utf8).write(to: URL(fileURLWithPath: path))
        #expect(TranscriptReader.locate(sessionId: listed, hint: "\(projects)/wrong/\(listed).jsonl", projects: projects) == .found(path))
        #expect(TranscriptReader.locate(sessionId: listed, hint: path, projects: projects) == .found(path))
        #expect(TranscriptReader.locate(sessionId: listed, hint: nil, projects: "\(projects)/absent") == .unknown)
    }

    /// "Never answered" blocks a session, so it is only concluded when Claude Code is seen keeping that
    /// session's project in this projects folder and its transcript is not there.
    @Test func missingOnlyWhenTheProjectFolderIsHere() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-projects-\(UUID().uuidString)").path
        let folder = "\(projects)/-Users-someone-api-server"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projects) }
        let other = "ffffffff-0000-4000-8000-000000000000"
        // The folder for its working directory is here and holds no transcript for it: sure.
        #expect(TranscriptReader.locate(sessionId: other, hint: "\(folder)/\(other).jsonl", projects: projects) == .missing)
        #expect(TranscriptReader.locate(sessionId: other, hint: "\(folder)/./\(other).jsonl", projects: projects) == .missing)
        // No folder for its working directory (CLAUDE_CONFIG_DIR points elsewhere, say): unknown, never blocked.
        #expect(TranscriptReader.locate(sessionId: other, hint: "\(projects)/-Users-someone-elsewhere/\(other).jsonl",
                                        projects: projects) == .unknown)
        // No idea where it would be: unknown.
        #expect(TranscriptReader.locate(sessionId: other, hint: nil, projects: projects) == .unknown)
        // A hint outside this projects folder proves nothing about it.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-outside-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        #expect(TranscriptReader.locate(sessionId: other, hint: "\(outside)/\(other).jsonl", projects: projects) == .unknown)
        // A folder that is only a file is not a project folder.
        try Data().write(to: URL(fileURLWithPath: "\(projects)/-Users-someone-file"))
        #expect(TranscriptReader.locate(sessionId: other, hint: "\(projects)/-Users-someone-file/\(other).jsonl",
                                        projects: projects) == .unknown)
    }

    @Test func neverAnsweredIsOnlyReportedWhenSure() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-projects-\(UUID().uuidString)").path
        let folder = "\(projects)/-Users-someone-api-server"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projects) }
        let other = "ffffffff-0000-4000-8000-000000000000"
        #expect(TranscriptReader.sessionHasAnswered(other, hint: "\(folder)/\(other).jsonl", projects: projects) == false)
        #expect(TranscriptReader.sessionHasAnswered(other, hint: "\(projects)/-Users-someone-gone/\(other).jsonl",
                                                    projects: projects) == nil)
        try Data(answer.utf8).write(to: URL(fileURLWithPath: "\(folder)/\(other).jsonl"))
        #expect(TranscriptReader.sessionHasAnswered(other, hint: nil, projects: projects) == true)
    }
}
