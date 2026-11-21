import Foundation

/// The environment a terminal would give `claude`: a GUI app starts with a bare PATH, so a session
/// Sidemoon resumes could not find node, bun or npx and would lose its MCP servers.
public enum LoginEnvironment {
    /// Loaded once from the user's login shell, else this process's environment; session markers removed.
    public static let shared: [String: String] = sanitized(load() ?? ProcessInfo.processInfo.environment)

    /// Drops the variables that would make `claude` think it runs inside another Claude Code session.
    public static func sanitized(_ env: [String: String]) -> [String: String] {
        env.filter { !Constants.LoginShell.strippedVariables.contains($0.key) }
    }

    /// The user's login shell from the account database, else the fallback shell.
    public static func userShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return Constants.LoginShell.fallbackShell
    }

    /// The shell command: marker, NUL-separated environment, marker.
    static var command: String {
        let s = Constants.LoginShell.self
        let printMarker = "\(s.printCommand) \(s.marker)"
        return [printMarker, "\(s.envTool) \(s.envToolFlag)", printMarker].joined(separator: s.commandSeparator)
    }

    /// Runs the login shell and parses its environment. Nil on failure, timeout, or a result without PATH.
    public static func load(timeout: TimeInterval = Constants.Timeouts.loginEnvironment) -> [String: String]? {
        let fm = FileManager.default
        // Output goes to a private temp file: a daemon started by the user's rc files could hold a pipe open.
        let outURL = fm.temporaryDirectory.appendingPathComponent("sidemoon-env-\(UUID().uuidString).out")
        defer { try? fm.removeItem(at: outURL) }
        guard fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: Constants.Permissions.imageFile]),
              let out = try? FileHandle(forWritingTo: outURL)
        else { return nil }
        defer { try? out.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: userShell())
        p.arguments = Constants.LoginShell.flags + [command]
        p.environment = sanitized(ProcessInfo.processInfo.environment)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + Constants.Timeouts.loginEnvironmentTerminateGrace)
            return nil
        }
        guard let data = fm.contents(atPath: outURL.path) else { return nil }
        return parse(data)
    }

    /// Parses `marker env -0 marker` output. Text outside the markers is ignored. Nil when either marker
    /// is missing or the result has no PATH.
    public static func parse(_ data: Data) -> [String: String]? {
        let marker = Data(Constants.LoginShell.marker.utf8)
        guard let start = data.range(of: marker),
              let end = data.range(of: marker, options: .backwards, in: start.upperBound..<data.endIndex)
        else { return nil }
        var env: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")), eq > entry.startIndex else { continue }
            let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
            env[key] = String(decoding: entry[entry.index(after: eq)...], as: UTF8.self)
        }
        guard let path = env[Constants.LoginShell.pathVariable], !path.isEmpty else { return nil }
        return env
    }
}
