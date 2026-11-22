import AppKit
import SidemoonCompanion
import SidemoonCore

/// Reopens a session in the Terminal app with one click: writes a small script that starts the launcher
/// with that session, and opens it. The Finder hands `.command` files to Terminal, so no permission is asked.
@MainActor
enum TerminalOpener {
    static func open(sessionId: String?, folder: String?) {
        let c = CompanionConstants.TerminalOpen.self
        let directory = Constants.Paths.supportDirectory
        let script = directory.appendingPathComponent(c.scriptName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text(sessionId: sessionId, folder: folder).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: c.scriptPermissions)], ofItemAtPath: script.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(script)
    }

    /// The script: go to the session's folder, then reopen it through the launcher.
    static func text(sessionId: String?, folder: String?) -> String {
        let c = CompanionConstants.TerminalOpen.self
        var lines = [c.shebang]
        if let folder, !folder.isEmpty { lines.append("cd \(quoted(folder)) 2>/dev/null") }
        var command = "exec \(quoted(SetupPaths.standard.launcher)) \(Constants.ClaudeCLI.resumeFlag)"
        if let sessionId, !sessionId.isEmpty, sessionId.allSatisfy({ c.sessionIdCharacters.contains($0) }) {
            command += " \(quoted(sessionId))"
        }
        lines.append(command)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Single quotes for sh: nothing inside is expanded.
    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
