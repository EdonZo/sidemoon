import Foundation

/// `sidemoon channel`: an MCP server over stdio, spawned by Claude Code, that connects back to the
/// engine and turns each delivery into a `notifications/claude/channel` message for its session.
///
/// Binding: the engine identifies this instance by its parent pid (the Claude Code process that
/// spawned it), which hooks from the same process also report. CLAUDE_CODE_SESSION_ID from the
/// environment is passed along as a hint for the time before the first hook arrives.
public final class ChannelServer: @unchecked Sendable {
    private let stdout = LineConnection(fd: STDOUT_FILENO)
    private let socketPath: String

    public init(socketPath: String = Constants.Paths.socketPath) {
        self.socketPath = socketPath
    }

    /// Runs until Claude Code closes stdin.
    public func run() -> Never {
        Thread.detachNewThread { [self] in engineLoop() }
        let stdin = LineConnection(fd: STDIN_FILENO)
        while let line = stdin.readLine() {
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handleRPC(m)
        }
        exit(0)
    }

    private func reply(_ object: [String: Any]) {
        var o = object
        o["jsonrpc"] = "2.0"
        _ = stdout.writeJSON(o)
    }

    private func handleRPC(_ m: [String: Any]) {
        let method = m["method"] as? String
        guard let id = m["id"] else { return }  // notifications need no answer
        switch method {
        case "initialize":
            let params = m["params"] as? [String: Any]
            reply(["id": id, "result": [
                "protocolVersion": params?["protocolVersion"] as? String ?? Constants.Channel.defaultProtocolVersion,
                "capabilities": ["experimental": [Constants.Channel.capability: [String: Any]()]],
                "serverInfo": ["name": Constants.Channel.serverName, "version": Constants.Channel.serverVersion],
                "instructions": Constants.Channel.instructions,
            ] as [String: Any]])
        case "ping":
            reply(["id": id, "result": [String: Any]()])
        default:
            reply(["id": id, "error": ["code": -32601, "message": "method not found"] as [String: Any]])
        }
    }

    private func engineLoop() {
        let env = ProcessInfo.processInfo.environment
        while true {
            if let fd = try? UnixSocket.connect(path: socketPath, timeout: Constants.Timeouts.socketSend) {
                let conn = LineConnection(fd: fd)
                var hello: [String: Any] = ["op": Constants.Ops.channelHello, "claudePid": Int(getppid()),
                                            "cwd": FileManager.default.currentDirectoryPath]
                if let sid = env[Constants.Channel.sessionIdEnv] { hello["envSessionId"] = sid }
                if conn.writeJSON(hello) {
                    while let msg = conn.readJSON() {
                        guard msg["op"] as? String == Constants.Ops.channelDeliver,
                              let id = msg["id"] as? String, let content = msg["content"] as? String else { continue }
                        let meta = msg["meta"] as? [String: String] ?? [:]
                        reply(["method": Constants.Channel.notificationMethod,
                               "params": ["content": content, "meta": meta] as [String: Any]])
                        _ = conn.writeJSON(["op": Constants.Ops.channelAck, "id": id])
                    }
                }
                conn.close()
            }
            if getppid() == 1 { exit(0) }  // Claude Code is gone
            Thread.sleep(forTimeInterval: Constants.Timeouts.channelReconnect)
        }
    }

    /// The MCP config a user passes to `claude --mcp-config` to load this channel.
    public static func mcpConfig(executablePath: String) -> String {
        let cfg: [String: Any] = ["mcpServers": [Constants.Channel.serverName: [
            "command": executablePath, "args": [Constants.Channel.subcommand]]]]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
