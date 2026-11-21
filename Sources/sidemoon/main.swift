import Foundation
import SidemoonCore

let usage = """
    usage:
      sidemoon serve
      sidemoon sessions [--json]
      sidemoon send --session <id> [--image <path>] [--text <text>] [--wait]
      sidemoon hooks install|uninstall|status [--settings <path>]
      sidemoon channel-config          print the MCP config that loads the Sidemoon channel
      sidemoon hook                    (run by Claude Code hooks)
      sidemoon channel                 (run by Claude Code as an MCP server)
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("sidemoon: \(message)\n".utf8))
    exit(code)
}

/// Parses `--name value` and bare `--flag` options after the subcommand.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: ArraySlice<String>, valued: Set<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if valued.contains(a) {
                guard let v = it.next() else { fail("\(a) needs a value") }
                values[a] = v
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }
}

var executablePath: String {
    let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
}

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { fail(usage, code: 2) }
let rest = args.dropFirst()

switch command {
case Constants.Hooks.subcommand:
    HookForwarder.run()

case Constants.Channel.subcommand:
    ChannelServer().run()

case "channel-config":
    print(ChannelServer.mcpConfig(executablePath: executablePath))

case "serve":
    let engine = Engine()
    do { try engine.start() } catch { fail("\(error)") }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { engine.stop(); exit(0) }
        s.resume()
        return s
    }
    engine.registry.subscribe { change in
        guard case let .updated(s) = change else { return }
        let routes = s.routes.map(\.rawValue).joined(separator: ",")
        print("[\(ISO8601DateFormatter().string(from: Date()))] \(s.id) \(s.state.rawValue) \(s.lastEventName ?? "-") routes=\(routes)")
        fflush(stdout)
    }
    print("sidemoon engine listening on \(engine.socketPath)")
    fflush(stdout)
    withExtendedLifetime(sources) { dispatchMain() }

case "sessions":
    let o = Options(rest, valued: [])
    do {
        let list = try EngineClient().sessions(refresh: true)
        if o.flags.contains("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            print(String(decoding: try enc.encode(list), as: UTF8.self))
        } else {
            for s in list {
                let routes = s.routes.isEmpty ? "-" : s.routes.map(\.rawValue).joined(separator: ",")
                let name = s.name.map { "\"\($0)\"" } ?? "-"
                print([s.id, s.kind.rawValue, s.state.rawValue, "routes=\(routes)", name, s.cwd ?? "-"].joined(separator: "  "))
            }
        }
    } catch { fail("\(error)") }

case "send":
    let o = Options(rest, valued: ["--session", "--image", "--text"])
    guard let session = o.values["--session"] else { fail("send needs --session <id>\n\(usage)", code: 2) }
    let req = SendRequest(session: session, imagePath: o.values["--image"].map(absolute), text: o.values["--text"],
                          wait: o.flags.contains("--wait"))
    do {
        let r = try EngineClient().send(req)
        guard r.ok else {
            fail("send failed\(r.route.map { " (route \($0.rawValue))" } ?? ""): \(r.error ?? "unknown error")"
                + (r.detail.map { "\n  \($0)" } ?? ""))
        }
        FileHandle.standardError.write(Data("delivered to \(r.sessionId ?? session) via route \(r.route?.rawValue ?? "?")\(r.detail.map { " (\($0))" } ?? "")\n".utf8))
        if req.wait { print(r.reply ?? "") }
    } catch { fail("\(error)") }

case "hooks":
    let o = Options(rest, valued: ["--settings"])
    let settings = o.values["--settings"].map(absolute) ?? Constants.Paths.defaultClaudeSettings
    let installer = HooksInstaller(settingsPath: settings, executablePath: executablePath)
    do {
        switch o.positional.first {
        case "install":
            let r = try installer.install()
            print(r.changed ? "installed Sidemoon hooks in \(settings)" : "already installed in \(settings); nothing changed")
            if let b = r.backupPath { print("backup: \(b)") }
        case "uninstall":
            let r = try installer.uninstall()
            print(r.changed ? "removed Sidemoon hooks from \(settings)" : "no Sidemoon hooks in \(settings); nothing changed")
            if let b = r.backupPath { print("backup: \(b)") }
        case "status":
            let s = try installer.status()
            print("settings: \(settings)")
            print("installed: \(s.installed.isEmpty ? "none" : s.installed.joined(separator: ", "))")
            print("missing: \(s.missing.isEmpty ? "none" : s.missing.joined(separator: ", "))")
            s.commands.forEach { print("command: \($0)") }
        default:
            fail("hooks needs install, uninstall or status", code: 2)
        }
    } catch { fail("\(error)") }

default:
    fail(usage, code: 2)
}
