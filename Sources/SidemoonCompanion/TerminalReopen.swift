import Foundation
import SidemoonCore

/// Checks on paths the companion needs before it offers or does something. Injected so tests decide what exists.
public struct PathChecks: Sendable {
    public var folderExists: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool

    public init(folderExists: @escaping @Sendable (String) -> Bool, isExecutable: @escaping @Sendable (String) -> Bool) {
        self.folderExists = folderExists
        self.isExecutable = isExecutable
    }

    /// The real file system.
    public static let system = PathChecks(
        folderExists: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })

    /// Everything exists: for code that is not about the file system.
    public static let everythingExists = PathChecks(folderExists: { _ in true }, isExecutable: { _ in true })
}

/// "Open in Terminal": what it does for one session, decided before anything is opened.
public enum TerminalReopen {
    public enum Plan: Equatable, Sendable {
        /// Write this script and hand it to Terminal.
        case open(script: String)
        /// The session's folder is gone, so reopening cannot work: nothing is opened.
        case folderGone(String)
        /// The launcher is not installed: the way forward is installing it.
        case installLauncher
    }

    public static func plan(sessionId: String?, folder: String?, launcher: String, checks: PathChecks) -> Plan {
        guard checks.isExecutable(launcher) else { return .installLauncher }
        if let folder, !folder.isEmpty, !checks.folderExists(folder) { return .folderGone(folder) }
        return .open(script: script(sessionId: sessionId, folder: folder, launcher: launcher))
    }

    /// A background session (`claude --bg`) is opened with `claude attach <short id>`, Claude Code's own way to show
    /// one in a terminal: it keeps running in the background either way, and no launcher is involved. A folder that
    /// is gone is explained instead, as for the other kinds.
    public static func attachPlan(shortId: String, folder: String?, claude: String, checks: PathChecks) -> Plan {
        if let folder, !folder.isEmpty, !checks.folderExists(folder) { return .folderGone(folder) }
        return .open(script: attachScript(shortId: shortId, claude: claude))
    }

    /// The script for `attachPlan`. An id with anything but hex digits is left out, and Claude Code then says what
    /// it takes.
    public static func attachScript(shortId: String, claude: String) -> String {
        let c = CompanionConstants.TerminalOpen.self
        var command = "exec \(ShellQuote.single(claude)) \(Constants.ClaudeCLI.attachCommand)"
        if !shortId.isEmpty, shortId.allSatisfy({ $0.isHexDigit }) { command += " \(ShellQuote.single(shortId))" }
        return [c.shebang, command].joined(separator: "\n") + "\n"
    }

    /// The script: go to the session's folder (or stop with one readable line if that fails), then reopen the
    /// session through the launcher. A session id with anything but hex digits and dashes is left out, and
    /// Claude Code then lists the sessions to pick from.
    public static func script(sessionId: String?, folder: String?, launcher: String) -> String {
        let c = CompanionConstants.TerminalOpen.self
        var lines = [c.shebang]
        if let folder, !folder.isEmpty {
            let q = ShellQuote.single(folder)
            let message = ShellQuote.single(Design.Copy.Unreachable.scriptFolderFailed)
            lines.append("cd \(q) 2>/dev/null || { printf '%s %s\\n' \(message) \(q); exit 1; }")
        }
        var command = "exec \(ShellQuote.single(launcher)) \(Constants.ClaudeCLI.resumeFlag)"
        if let sessionId, !sessionId.isEmpty, sessionId.allSatisfy({ c.sessionIdCharacters.contains($0) }) {
            command += " \(ShellQuote.single(sessionId))"
        }
        lines.append(command)
        return lines.joined(separator: "\n") + "\n"
    }
}
