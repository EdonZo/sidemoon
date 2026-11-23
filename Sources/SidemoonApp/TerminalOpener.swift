import AppKit
import SidemoonCompanion
import SidemoonCore

/// Reopens a session in the Terminal app with one click: writes the script `TerminalReopen` built, and opens it.
/// The Finder hands `.command` files to Terminal, so no permission is asked.
@MainActor
enum TerminalOpener {
    static func open(script text: String) {
        let c = CompanionConstants.TerminalOpen.self
        let directory = Constants.Paths.supportDirectory
        let script = directory.appendingPathComponent(c.scriptName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: c.scriptPermissions)], ofItemAtPath: script.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(script)
    }
}
