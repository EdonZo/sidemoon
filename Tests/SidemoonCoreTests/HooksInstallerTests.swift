import Foundation
import Testing
@testable import SidemoonCore

private let exe = "/Applications/Side moon/sidemoon"

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
}

/// Copies a fixture into a fresh temp directory and returns the copy's path.
private func scratchCopy(_ name: String?) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("settings.json")
    if let name { try FileManager.default.copyItem(at: try fixture(name), to: dest) }
    return dest.path
}

private func read(_ path: String) throws -> JSONValue {
    try JSONValue.parse(try String(contentsOfFile: path, encoding: .utf8))
}

private func backups(of path: String) throws -> [String] {
    let dir = (path as NSString).deletingLastPathComponent
    return try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(Constants.Paths.backupSuffix) }
}

@Suite struct HooksInstallerTests {

    @Test func installPreservesExistingKeysAndHooks() throws {
        let path = try scratchCopy("settings-existing-hooks")
        let original = try read(path)
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        let outcome = try installer.install()
        #expect(outcome.changed)
        let after = try read(path)

        // Every pre-existing top-level key keeps its value and position.
        let keys = try #require(original.objectValue).map(\.0)
        #expect(try #require(after.objectValue).map(\.0) == keys)
        for k in keys where k != "hooks" { #expect(after[k] == original[k]) }
        #expect(after["cleanupPeriodDays"] == .number("1.50"))

        // Existing hooks are untouched; ours are appended after them.
        #expect(after["hooks"]?["PreToolUse"] == original["hooks"]?["PreToolUse"])
        let stop = try #require(after["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0] == original["hooks"]?["Stop"]?.arrayValue?[0])
        for event in Constants.Hooks.events {
            #expect(HooksInstaller.managedCommands(in: after, event: event) == [installer.hookCommand])
        }
        #expect(installer.hookCommand == "[ -x '/Applications/Side moon/sidemoon' ] && '/Applications/Side moon/sidemoon' hook --sidemoon-managed || true")
    }

    @Test func backupIsWrittenFirstAndMatchesOriginal() throws {
        let path = try scratchCopy("settings-existing-hooks")
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let outcome = try HooksInstaller(settingsPath: path, executablePath: exe).install()
        let backup = try #require(outcome.backupPath)
        #expect((backup as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == originalBytes)
    }

    @Test func installIsIdempotent() throws {
        let path = try scratchCopy("settings-existing-hooks")
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        _ = try installer.install()
        let once = try Data(contentsOf: URL(fileURLWithPath: path))
        let second = try installer.install()
        #expect(!second.changed)
        #expect(second.backupPath == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == once)
        #expect(try backups(of: path).count == 1)
    }

    @Test func reinstallFromMovedBinaryReplacesOnlyOurEntries() throws {
        let path = try scratchCopy("settings-existing-hooks")
        _ = try HooksInstaller(settingsPath: path, executablePath: "/old/sidemoon").install()
        let moved = HooksInstaller(settingsPath: path, executablePath: exe)
        #expect(try moved.install().changed)
        let after = try read(path)
        for event in Constants.Hooks.events {
            #expect(HooksInstaller.managedCommands(in: after, event: event) == [moved.hookCommand])
        }
        #expect(after["hooks"]?["Stop"]?.arrayValue?.count == 2)
    }

    @Test func uninstallRemovesExactlyOurEntries() throws {
        let path = try scratchCopy("settings-existing-hooks")
        let original = try read(path)
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        _ = try installer.install()
        let outcome = try installer.uninstall()
        #expect(outcome.changed)
        #expect(outcome.backupPath != nil)
        #expect(try read(path) == original)
        #expect(!(try installer.uninstall().changed))
    }

    @Test func uninstallDropsHooksKeyItCreated() throws {
        let path = try scratchCopy("settings-no-hooks")
        let original = try read(path)
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        _ = try installer.install()
        #expect(try installer.status().isComplete)
        _ = try installer.uninstall()
        #expect(try read(path) == original)
        #expect(try installer.status().installed.isEmpty)
    }

    @Test func handlerSharedWithOtherHooksKeepsTheGroup() throws {
        let path = try scratchCopy(nil)
        let ours = HooksInstaller(settingsPath: path, executablePath: exe).hookCommand
        let mixed = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"\(ours)"}]}]}}
            """
        try mixed.write(toFile: path, atomically: true, encoding: .utf8)
        _ = try HooksInstaller(settingsPath: path, executablePath: exe).uninstall()
        let after = try read(path)
        #expect(after["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1)
        #expect(after["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"] == .string("say done"))
    }

    @Test func refusesInvalidJSONAndLeavesFileUntouched() throws {
        for name in ["settings-invalid", "settings-hooks-not-object"] {
            let path = try scratchCopy(name)
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(throws: HooksInstaller.InstallerError.self) {
                try HooksInstaller(settingsPath: path, executablePath: exe).install()
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
            #expect(try backups(of: path).isEmpty)
        }
    }

    @Test func createsMissingFile() throws {
        let path = try scratchCopy(nil)
        let outcome = try HooksInstaller(settingsPath: path, executablePath: exe).install()
        #expect(outcome.changed)
        #expect(outcome.backupPath == nil)
        #expect(try HooksInstaller(settingsPath: path, executablePath: exe).status().isComplete)
    }

    @Test func executablePathIsReadBackFromTheCommand() {
        for path in [exe, "/x/it's here/sidemoon", "/plain/sidemoon", "/a/''/b"] {
            let command = HooksInstaller(settingsPath: "/tmp/s.json", executablePath: path).hookCommand
            #expect(HooksInstaller.executablePath(inCommand: command) == path)
        }
        #expect(HooksInstaller.executablePath(inCommand: "say done") == nil)
        #expect(HooksInstaller.executablePath(inCommand: "[ -x '/unterminated") == nil)
    }

    @Test func markerMatchesWholeArgumentOnly() {
        #expect(HooksInstaller.isManaged("'/x/sidemoon' hook --sidemoon-managed"))
        #expect(!HooksInstaller.isManaged("echo --sidemoon-managed-not"))
        #expect(!HooksInstaller.isManaged("afplay x"))
        #expect(HooksInstaller.isManaged("'/x/old' hook \(Constants.Hooks.legacyMarker)"))
        #expect(!HooksInstaller.isManaged("echo \(Constants.Hooks.legacyMarker)-not"))
    }

    // MARK: Hooks written before the rename (legacy marker)

    /// A settings file as the pre-rename build left it: its hook on every event, beside an unrelated Stop hook.
    private func legacyInstall() throws -> (path: String, legacyCommand: String) {
        let path = try scratchCopy(nil)
        let legacyCommand = HooksInstaller(settingsPath: path, executablePath: legacyHelper).hookCommand
            .replacingOccurrences(of: Constants.Hooks.marker, with: Constants.Hooks.legacyMarker)
        let entry = #"{"hooks":[{"type":"command","command":"\#(legacyCommand)","timeout":5}]}"#
        var events = Constants.Hooks.events.map { #""\#($0)":[\#(entry)]"# }
        events[events.firstIndex { $0.hasPrefix(#""Stop""#) }!] = #""Stop":[{"hooks":[{"type":"command","command":"say done"}]},\#(entry)]"#
        try (#"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}],"#
            + events.joined(separator: ",") + "}}").write(toFile: path, atomically: true, encoding: .utf8)
        return (path, legacyCommand)
    }

    @Test func statusReportsLegacyEntries() throws {
        let (path, legacyCommand) = try legacyInstall()
        let status = try HooksInstaller(settingsPath: path, executablePath: exe).status()
        #expect(status.isComplete)
        #expect(status.commands == [legacyCommand])
        #expect(HooksInstaller.executablePath(inCommand: legacyCommand) == legacyHelper)
    }

    @Test func installOverLegacyLeavesOneManagedCommandPerEvent() throws {
        let (path, _) = try legacyInstall()
        let original = try read(path)
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        #expect(try installer.install().changed)
        let after = try read(path)
        for event in Constants.Hooks.events {
            #expect(HooksInstaller.managedCommands(in: after, event: event) == [installer.hookCommand])
        }
        #expect(!(try String(contentsOfFile: path, encoding: .utf8)).contains(Constants.Hooks.legacyMarker))
        // Unrelated hooks and keys are untouched.
        #expect(after["model"] == original["model"])
        #expect(after["hooks"]?["PreToolUse"] == original["hooks"]?["PreToolUse"])
        #expect(after["hooks"]?["Stop"]?.arrayValue?.count == 2)
        #expect(after["hooks"]?["Stop"]?.arrayValue?.first == original["hooks"]?["Stop"]?.arrayValue?.first)
        #expect(!(try installer.install().changed))
    }

    @Test func uninstallRemovesLegacyEntries() throws {
        let (path, _) = try legacyInstall()
        let original = try read(path)
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        #expect(try installer.uninstall().changed)
        let after = try read(path)
        for event in Constants.Hooks.events {
            #expect(HooksInstaller.managedCommands(in: after, event: event).isEmpty)
        }
        #expect(after["model"] == original["model"])
        #expect(after["hooks"]?["PreToolUse"] == original["hooks"]?["PreToolUse"])
        let stop = try #require(after["hooks"]?["Stop"]?.arrayValue)
        #expect(stop == [try #require(original["hooks"]?["Stop"]?.arrayValue?.first)])
        #expect(after["hooks"]?["SessionStart"] == nil)
    }

    @Test func uninstallRemovesBothMarkersTogether() throws {
        let (path, _) = try legacyInstall()
        let installer = HooksInstaller(settingsPath: path, executablePath: exe)
        // A half-migrated file: the new hooks appended beside the legacy ones by hand.
        var text = try String(contentsOfFile: path, encoding: .utf8)
        let ours = #"{"hooks":[{"type":"command","command":"\#(installer.hookCommand)"}]}"#
        text = text.replacingOccurrences(of: #""SessionEnd":["#, with: #""SessionEnd":[\#(ours),"#)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try installer.status().commands.count == 2)
        _ = try installer.uninstall()
        #expect(try installer.status().commands.isEmpty)
    }
}

/// Where the pre-rename build kept the helper its hooks run.
private let legacyHelper = "/Applications/Tagalong.app/Contents/Helpers/tagalong"

@Suite struct JSONValueTests {
    @Test func roundTripKeepsOrderNumbersAndEscapes() throws {
        let text = #"{"b":1,"a":[1.50,-2e3,true,null],"s":"q\"\\\n\u00e9\ud83d\ude00","e":{}}"#
        let v = try JSONValue.parse(text)
        #expect(v.objectValue?.map(\.0) == ["b", "a", "s", "e"])
        #expect(v["a"]?.arrayValue?.first == .number("1.50"))
        #expect(v["s"] == .string("q\"\\\n\u{e9}\u{1F600}"))
        #expect(try JSONValue.parse(v.serialized()) == v)
    }

    @Test func rejectsGarbage() {
        for bad in ["", "{", "{\"a\":}", "[1,]", "{} x", "\"\u{01}\""] {
            #expect(throws: JSONParseError.self) { try JSONValue.parse(bad) }
        }
    }
}
