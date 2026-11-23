import Foundation
import Testing
@testable import SidemoonCore

private let sid = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"
private let claudePid: Int32 = 4242

@Suite struct ChannelRoleTests {
    private let mcp = Constants.ClaudeCLI.channelLaunchFlags[0]
    private let dev = Constants.ClaudeCLI.channelLaunchFlags[1]
    private let value = Constants.ClaudeCLI.channelLaunchValue

    @Test func readsTheChannelFlagInEachForm() {
        // The launcher's own command line, and the host process seen on a user's Mac (no channel flag).
        #expect(ChannelRole.of(arguments: [mcp, "/x/channel-mcp.json", dev, value]) == .channel)
        #expect(ChannelRole.of(arguments: ["--session-id", sid, mcp, "/x/channel-mcp.json", "--agent", "claude",
                                           "--inherit-permission-mode", "auto"]) == .notChannel)
        #expect(ChannelRole.of(arguments: ["\(dev)=\(value)"]) == .channel)
        #expect(ChannelRole.of(arguments: [dev, "server:other", value, "--model", "haiku"]) == .channel)
        #expect(ChannelRole.of(arguments: [dev, "server:other,\(value)"]) == .channel)
        #expect(ChannelRole.of(arguments: [Constants.ClaudeCLI.channelsFlag, value]) == .channel)
        // Another channel only, the value somewhere else, or after a different flag: not a channel.
        #expect(ChannelRole.of(arguments: [dev, "server:other"]) == .notChannel)
        #expect(ChannelRole.of(arguments: [dev, "--model", value]) == .notChannel)
        #expect(ChannelRole.of(arguments: ["-n", value]) == .notChannel)
        #expect(ChannelRole.of(arguments: ["say \(dev) \(value)"]) == .notChannel)
        #expect(ChannelRole.of(arguments: []) == .notChannel)
        // Unreadable arguments: unknown.
        #expect(ChannelRole.of(arguments: nil) == .unknown)
    }

    @Test func parsesTheKernelArgumentBuffer() {
        func buffer(_ argv: [String], exec: String = "/bin/claude") -> [UInt8] {
            var argc = Int32(argv.count)
            var b = withUnsafeBytes(of: &argc) { Array($0) }
            b += Array(exec.utf8) + [0, 0, 0, 0]
            for a in argv { b += Array(a.utf8) + [0] }
            b += Array("HOME=/Users/someone".utf8) + [0]
            return b
        }
        #expect(ProcessArguments.parse(buffer(["claude", mcp, "/x.json", dev, value])) == [mcp, "/x.json", dev, value])
        #expect(ProcessArguments.parse(buffer(["claude"])) == [])
        #expect(ProcessArguments.parse([1, 0]) == nil)
        // Fewer arguments than it says: unreadable.
        #expect(ProcessArguments.parse(Array(buffer(["claude", "a", "b"]).prefix(20))) == nil)
    }

    @Test func readsARealProcess() {
        #expect(ProcessArguments.read(pid: getpid()) == Array(CommandLine.arguments.dropFirst()))
        #expect(ProcessArguments.read(pid: 0) == nil)
        #expect(ProcessArguments.read(pid: 1) == nil)
    }
}

/// A stand-in for `sidemoon channel`: says hello with a role, confirms every delivery, and runs `onDeliver`.
private final class FakeHelper: @unchecked Sendable {
    private let conn: LineConnection
    private let lock = NSLock()
    private var delivered: [String] = []
    var deliveries: [String] { lock.withLock { delivered } }

    init(socket: String, role: ChannelRole?, onDeliver: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard let fd = try UnixSocket.connect(path: socket, timeout: Constants.Timeouts.socketSend) else {
            throw SocketError(message: "could not connect to \(socket)")
        }
        conn = LineConnection(fd: fd)
        var hello: [String: Any] = ["op": Constants.Ops.channelHello, "claudePid": Int(claudePid), "envSessionId": sid]
        if let role { hello[Constants.Channel.roleKey] = role.rawValue }
        _ = conn.writeJSON(hello)
        Thread.detachNewThread { [self] in
            while let msg = conn.readJSON() {
                guard msg["op"] as? String == Constants.Ops.channelDeliver, let id = msg["id"] as? String else { continue }
                lock.withLock { delivered.append(id) }
                _ = conn.writeJSON(["op": Constants.Ops.channelAck, "id": id])
                onDeliver(id)
            }
        }
    }

    func close() { conn.shutdownBoth() }
}

private func hook(_ name: String, extra: [String: Any] = [:]) -> HookEvent {
    var o: [String: Any] = ["session_id": sid, "hook_event_name": name, "cwd": "/tmp/proj"]
    o.merge(extra) { $1 }
    return HookEvent(json: try! JSONSerialization.data(withJSONObject: o), claudePid: claudePid)!
}

/// A real engine on a scratch socket, with the session already reporting hooks from `claudePid`.
private func startEngine(agentsJSON: String = "[]", pickupWait: TimeInterval = 1) throws -> (Engine, FakeRunner, String) {
    let dir = "/tmp/smt-\(UUID().uuidString.prefix(8))"
    let socket = "\(dir)/e.sock"
    let runner = FakeRunner(agentsJSON: agentsJSON, resumeOutput: "backgrounded · 0b8e8a52 · t\n")
    let e = Engine(socketPath: socket, runner: runner,
                   registry: SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true }), pickupWait: pickupWait)
    try e.start()
    e.refreshAgents()
    e.registry.apply(hook(Constants.HookEvents.sessionStart))
    return (e, runner, dir)
}

private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

extension Engine {
    /// `send` blocks for seconds here; on a thread of its own it holds up none of the pool other tests share
    /// (some of them wait on `DispatchQueue.global()`).
    func sending(_ request: SendRequest) async -> SendResult {
        await timedSending(request).result
    }

    /// The same, with how long `send` itself took, measured on the thread that ran it. Measured around the `await`
    /// instead, it also counts the wait for a free thread to carry on the test, which was seen to take almost 4 s
    /// while the shell tests filled the pool with processes they wait for.
    func timedSending(_ request: SendRequest) async -> (result: SendResult, seconds: TimeInterval) {
        await withCheckedContinuation { done in
            Thread.detachNewThread {
                let started = Date()
                let result = self.send(request)
                done.resume(returning: (result, Date().timeIntervalSince(started)))
            }
        }
    }
}

@Suite(.serialized) struct ChannelPickupTests {
    private func cleanup(_ e: Engine, _ helper: FakeHelper, _ dir: String) {
        helper.close()
        e.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// The host process seen on a user's Mac: the helper runs and connects, but its parent did not load it as a
    /// channel. The session is not channel-connected, and a send fails at once instead of waiting for a reply.
    @Test func helperThatIsNotAChannelIsNotClaimed() async throws {
        let (e, _, dir) = try startEngine()
        let helper = try FakeHelper(socket: e.socketPath, role: .notChannel)
        defer { cleanup(e, helper, dir) }
        #expect(await waitUntil { e.registry.session(sid)?.channelDropped == true })
        #expect(e.registry.session(sid)?.channelConnected == false)
        #expect(e.registry.session(sid)?.routes == [])
        let (r, took) = await e.timedSending(SendRequest(session: sid, text: "hi", wait: true))
        #expect(r.failure == .channelIgnored(fallback: nil))
        #expect(took < 1, "took \(took)s")
        #expect(helper.deliveries.isEmpty)
    }

    /// A helper that cannot tell (an older one, or unreadable arguments), whose message Claude Code ignores: the
    /// send fails after the short pick-up wait, not the reply timeout, and the link is not used again.
    @Test func deliveryThatIsNotPickedUpFailsFastAndIsNotRetriedThere() async throws {
        let (e, _, dir) = try startEngine()
        let helper = try FakeHelper(socket: e.socketPath, role: nil)
        defer { cleanup(e, helper, dir) }
        #expect(await waitUntil { e.registry.session(sid)?.channelConnected == true })
        let (r, took) = await e.timedSending(SendRequest(session: sid, text: "hi", wait: true))
        #expect(r.failure == .channelIgnored(fallback: nil))
        #expect(took >= e.pickupWait && took < e.pickupWait + 5, "took \(took)s")
        #expect(helper.deliveries.count == 1)
        #expect(e.registry.session(sid)?.channelConnected == false)
        #expect(e.registry.session(sid)?.channelDropped == true)
        // The next send does not go through that link again.
        #expect(await e.sending(SendRequest(session: sid, text: "again", wait: true)).failure == .channelIgnored(fallback: nil))
        #expect(helper.deliveries.count == 1)
    }

    /// The same for a background session: it keeps its background route, which the next attempt (Retry) uses.
    @Test func backgroundSessionFallsBackToTheBackgroundRoute() async throws {
        let listed = agents(status: "idle", state: "done", running: false)
        let (e, runner, dir) = try startEngine(agentsJSON: listed)
        let helper = try FakeHelper(socket: e.socketPath, role: .unknown)
        defer { cleanup(e, helper, dir) }
        #expect(await waitUntil { e.registry.session(sid)?.routes == [.channel, .background] })
        let r = await e.sending(SendRequest(session: sid, text: "hi", wait: false))
        #expect(r.failure == .channelIgnored(fallback: .background))
        #expect(e.registry.session(sid)?.routes == [.background])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.agentsJSON = agents(status: "busy", state: "working") }
        let retry = await e.sending(SendRequest(session: sid, text: "hi", wait: false))
        #expect(retry.ok && retry.route == .background)
        #expect(runner.recorded.contains { $0.first == Constants.ClaudeCLI.resumeFlag })
    }

    /// A channel that works: the session takes the message in (its prompt hook), answers, and the reply arrives.
    @Test func deliveryThatIsPickedUpIsAnswered() async throws {
        let (e, _, dir) = try startEngine()
        let registry = e.registry
        let helper = try FakeHelper(socket: e.socketPath, role: .channel) { _ in
            registry.apply(hook(Constants.HookEvents.userPromptSubmit))
            Thread.sleep(forTimeInterval: 0.2)
            registry.apply(hook(Constants.HookEvents.stop, extra: ["last_assistant_message": "PEAR"]))
        }
        defer { cleanup(e, helper, dir) }
        #expect(await waitUntil { e.registry.session(sid)?.channelConnected == true })
        let r = await e.sending(SendRequest(session: sid, text: "hi", wait: true))
        #expect(r.ok && r.route == .channel && r.reply == "PEAR", "\(r.error ?? "-")")
        #expect(e.registry.session(sid)?.channelConnected == true)
    }

    /// A session in the middle of a long turn takes the message only when the turn is over, after more than the
    /// pick-up wait: it is not failed for that.
    @Test func busySessionThatPicksUpLaterKeepsWaiting() async throws {
        let busyTurn: TimeInterval = 3
        let (e, _, dir) = try startEngine()
        #expect(busyTurn > e.pickupWait)
        let registry = e.registry
        let helper = try FakeHelper(socket: e.socketPath, role: .channel) { _ in
            Thread.sleep(forTimeInterval: busyTurn)
            registry.apply(hook(Constants.HookEvents.stop, extra: ["last_assistant_message": "old turn"]))
            registry.apply(hook(Constants.HookEvents.userPromptSubmit))
        }
        defer { cleanup(e, helper, dir) }
        #expect(await waitUntil { e.registry.session(sid)?.channelConnected == true })
        e.registry.apply(hook(Constants.HookEvents.userPromptSubmit))
        let started = Date()
        let r = await e.sending(SendRequest(session: sid, text: "hi", wait: false))
        #expect(r.ok, "\(r.error ?? "-")")
        #expect(Date().timeIntervalSince(started) >= busyTurn)
    }
}
