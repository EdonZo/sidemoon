import Foundation

/// Talks to a running engine over its socket.
public struct EngineClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = Constants.Paths.socketPath) { self.socketPath = socketPath }

    public enum ClientError: Error, CustomStringConvertible {
        case notRunning, noResponse
        public var description: String {
            switch self {
            case .notRunning: return "the Sidemoon engine is not running (start it with `sidemoon serve`)"
            case .noResponse: return "the engine closed the connection without answering"
            }
        }
    }

    public func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard let fd = try UnixSocket.connect(path: socketPath, timeout: Constants.Timeouts.socketSend) else {
            throw ClientError.notRunning
        }
        let conn = LineConnection(fd: fd)
        defer { conn.close() }
        UnixSocket.setTimeout(fd, SO_RCVTIMEO, timeout)
        guard conn.writeJSON(message), let answer = conn.readJSON() else { throw ClientError.noResponse }
        return answer
    }

    public func sessions(refresh: Bool) throws -> [Session] {
        let r = try request(["op": Constants.Ops.sessions, "refresh": refresh], timeout: Constants.Timeouts.cliCommand)
        guard let list = r["sessions"], let data = try? JSONSerialization.data(withJSONObject: list) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Session].self, from: data)) ?? []
    }

    public func send(_ req: SendRequest) throws -> SendResult {
        var m: [String: Any] = ["op": Constants.Ops.send, "session": req.session, "wait": req.wait]
        if let i = req.imagePath { m["image"] = i }
        if let t = req.text { m["text"] = t }
        let budget = req.wait ? Constants.Timeouts.replyWait + Constants.Timeouts.backgroundStopWait
            + Constants.Timeouts.backgroundResumeVerify + Constants.Timeouts.cliCommand : Constants.Timeouts.headlessRun
        return SendResult(dictionary: try request(m, timeout: budget))
    }
}

/// `sidemoon hook`: forwards one hook payload from stdin to the engine. Always fast, silent and
/// successful, so it can never slow down or break a Claude Code session.
public enum HookForwarder {
    public static func run(socketPath: String = Constants.Paths.socketPath) -> Never {
        let deadline = Date().addingTimeInterval(Constants.Timeouts.hookTotal)
        // Cheap check first: no engine, nothing to do (stdin is left unread; Claude Code tolerates that).
        guard FileManager.default.fileExists(atPath: socketPath) else { exit(0) }
        guard let payload = readStdin(until: deadline), !payload.isEmpty else { exit(0) }
        let env = ProcessInfo.processInfo.environment
        let pid = env[Constants.Hooks.claudePidEnv].flatMap(Int32.init) ?? getppid()
        guard let fd = try? UnixSocket.connect(path: socketPath, timeout: Constants.Timeouts.socketSend) else { exit(0) }
        let conn = LineConnection(fd: fd)
        _ = conn.writeJSON(["op": Constants.Ops.hook, "pid": Int(pid), "payload": String(decoding: payload, as: UTF8.self)])
        conn.close()
        exit(0)
    }

    private static func readStdin(until deadline: Date) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline, data.count <= Constants.Limits.maxHookPayloadBytes {
            var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard poll(&p, 1, ms) > 0 else { return nil }
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n == 0 { return data }
            if n < 0 { if errno == EINTR { continue }; return nil }
            data.append(contentsOf: buf[0..<n])
        }
        return nil
    }
}
