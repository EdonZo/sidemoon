import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

// MARK: Fakes

private struct FakeFinder: ClaudeFinder {
    var result: ClaudeLookup
    func lookup() -> ClaudeLookup { result }
}

/// In-memory files. Executables are listed separately.
private final class FakeFiles: SetupFiles {
    var contents: [String: Data] = [:]
    var permissions: [String: Int] = [:]
    var directories: Set<String> = []
    var executables: Set<String> = []
    var writes: [String] = []

    func exists(_ path: String) -> Bool { contents[path] != nil || directories.contains(path) }
    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func read(_ path: String) -> Data? { contents[path] }
    func createDirectory(_ path: String, permissions: Int) throws { directories.insert(path) }
    func write(_ data: Data, to path: String, permissions: Int) throws {
        contents[path] = data
        self.permissions[path] = permissions
        writes.append(path)
    }
    func text(_ path: String) -> String? { contents[path].map { String(decoding: $0, as: UTF8.self) } }
}

/// Scripted hook status; installs and uninstalls are recorded.
private final class FakeHooks: HooksService {
    let settingsPath = "/fake/home/.claude/settings.json"
    var current = HooksInstaller.Status(installed: [], missing: Constants.Hooks.events, commands: [])
    var failure: Error?
    var installs: [String] = []
    var uninstalls = 0

    func status() throws -> HooksInstaller.Status {
        if let failure { throw failure }
        return current
    }
    func install(helper: String) throws -> HooksInstaller.Outcome {
        installs.append(helper)
        current = HooksInstaller.Status(installed: Constants.Hooks.events, missing: [], commands: [command(for: helper)])
        return HooksInstaller.Outcome(changed: true, backupPath: "/fake/home/.claude/settings.json.sidemoon-backup-1")
    }
    func uninstall() throws -> HooksInstaller.Outcome {
        uninstalls += 1
        current = HooksInstaller.Status(installed: [], missing: Constants.Hooks.events, commands: [])
        return HooksInstaller.Outcome(changed: true, backupPath: "/fake/home/.claude/settings.json.sidemoon-backup-2")
    }
    func command(for helper: String) -> String { HooksInstaller(settingsPath: settingsPath, executablePath: helper).hookCommand }
}

@MainActor
private final class FakePermission: ScreenCapturePermission {
    var granted = false
    var requests = 0
    var opens = 0
    func isGranted() -> Bool { granted }
    func request() { requests += 1 }
    func openSettings() { opens += 1 }
}

@MainActor
private final class FakeRelauncher: AppRelauncher {
    var canRelaunch = true
    var relaunches = 0
    func relaunch() { relaunches += 1 }
}

private struct ShapeError: Error, CustomStringConvertible { var description: String { "not JSON" } }

private let home = "/fake/home"
private let helper = "/Applications/Sidemoon.app/Contents/Helpers/sidemoon"
private let legacy = "/fake/home/.local/bin/sidemoon"
private let paths = SetupPaths(home: home, channelConfig: "\(home)/Library/Application Support/Sidemoon/channel-mcp.json",
                               launcher: "\(home)/.local/bin/sidemoon-claude")
/// The launcher Sidemoon 1.0.3 wrote.
private let legacyLauncher = """
    #!/bin/sh
    # Starts Claude Code with the Sidemoon channel loaded, so captures can be sent into this session.
    exec claude --mcp-config "$HOME/Library/Application Support/Sidemoon/channel-mcp.json" --dangerously-load-development-channels server:sidemoon "$@"

    """
private let usualLookup = ClaudeLookup(enginePath: "\(home)/.local/bin/claude", loginShellPath: "\(home)/.local/bin/claude",
                                       pathEntries: ["\(home)/.local/bin/", "/usr/bin"])

@MainActor
private struct Rig {
    let files = FakeFiles()
    let hooks = FakeHooks()
    let permission = FakePermission()
    let relauncher = FakeRelauncher()
    let defaults = UserDefaults(suiteName: "sidemoon-setup-test-\(UUID().uuidString)")!

    func model(helper location: HelperLocation = .found(helper), lookup: ClaudeLookup = usualLookup) -> SetupModel {
        SetupModel(helper: location, paths: paths, finder: FakeFinder(result: lookup), hooks: hooks, files: files,
                   permission: permission, relauncher: relauncher, defaults: defaults)
    }
}

// MARK: Tests

@MainActor
@Suite struct SetupTests {

    // MARK: Step 1: Claude Code

    @Test func claudeIsCheckingUntilTheLookupFinishes() async {
        let model = Rig().model()
        #expect(model.claudeState == .checking)
        #expect(model.pathWarning == nil)
        await model.refresh()
        #expect(model.claude == .found("\(home)/.local/bin/claude"))
        #expect(model.claudeState == .done)
        #expect(model.claudeDetail.contains("~/.local/bin/claude"))
        // A trailing slash on the PATH entry still counts.
        #expect(model.launcherOnPath)
        #expect(model.launcherCommand == "sidemoon-claude")
    }

    @Test func claudeOnlyFoundByTheLoginShellIsAProblem() async {
        let model = Rig().model(lookup: ClaudeLookup(enginePath: nil, loginShellPath: "/opt/node/bin/claude", pathEntries: ["/opt/node/bin"]))
        await model.refresh()
        #expect(model.claude == .outsideEngineReach("/opt/node/bin/claude"))
        #expect(model.claudeState == .problem)
        // ~/.local/bin is not on PATH: the full path is the command, and the warning names it.
        #expect(!model.launcherOnPath)
        #expect(model.launcherCommand == "~/.local/bin/sidemoon-claude")
        #expect(model.pathWarning?.contains("~/.local/bin/sidemoon-claude") == true)
    }

    @Test func missingClaudeLeavesTheOtherStepsUsable() async {
        let rig = Rig()
        let model = rig.model(lookup: ClaudeLookup(enginePath: nil, loginShellPath: nil, pathEntries: []))
        await model.refresh()
        #expect(model.claude == .missing)
        #expect(model.claudeState == .problem)
        #expect(model.canConnect)
        #expect(model.canInstallLauncher)
        model.connect()
        #expect(model.connection == .connected)
    }

    // MARK: Step 2: hooks

    @Test func connectionDerivation() {
        let expected = FakeHooks().command(for: helper)
        let all = Constants.Hooks.events
        func status(_ commands: [String], missing: [String] = []) -> Result<HooksInstaller.Status, Error> {
            .success(HooksInstaller.Status(installed: all.filter { !missing.contains($0) }, missing: missing, commands: commands))
        }
        let other = FakeHooks().command(for: legacy)
        let exists: (String) -> Bool = { $0 == legacy }
        let none: (String) -> Bool = { _ in false }

        #expect(SetupModel.connection(status([]), helper: .found(helper), expected: expected, isExecutable: none) == .notConnected)
        #expect(SetupModel.connection(status([expected]), helper: .found(helper), expected: expected, isExecutable: none) == .connected)
        #expect(SetupModel.connection(status([expected], missing: ["Stop"]), helper: .found(helper), expected: expected,
                                      isExecutable: none) == .incomplete)
        #expect(SetupModel.connection(status([other]), helper: .found(helper), expected: expected, isExecutable: exists)
                == .otherCopy(legacy))
        #expect(SetupModel.connection(status([other]), helper: .found(helper), expected: expected, isExecutable: none)
                == .missingCopy(legacy))
        // Mixed: some events on this app, some on another copy.
        #expect(SetupModel.connection(status([expected, other]), helper: .found(helper), expected: expected, isExecutable: exists)
                == .otherCopy(legacy))
        #expect(SetupModel.connection(.failure(ShapeError()), helper: .found(helper), expected: expected, isExecutable: none)
                == .unreadable("not JSON"))
        #expect(SetupModel.connection(status([other]), helper: .translocated, expected: nil, isExecutable: exists)
                == .helperUnavailable(.translocated))
    }

    @Test func connectInstallsForTheBundledHelperAndReportsTheBackup() {
        let rig = Rig()
        let model = rig.model()
        #expect(model.connection == .notConnected)
        #expect(model.connectionState == .notDone)
        #expect(model.canConnect && !model.needsRepair && !model.hasHooks)
        #expect(model.connectionDetail.contains("~/.claude/settings.json"))
        model.connect()
        #expect(rig.hooks.installs == [helper])
        #expect(model.connection == .connected)
        #expect(model.connectionState == .done)
        #expect(model.hasHooks && !model.canConnect)
        #expect(model.connectionFeedback?.text.contains("~/.claude/settings.json.sidemoon-backup-1") == true)
        #expect(model.connectionFeedback?.isProblem == false)
    }

    @Test func hooksOnAnOldCopyAreRepairedToThisApp() {
        let rig = Rig()
        rig.files.executables = [legacy]
        rig.hooks.current = HooksInstaller.Status(installed: Constants.Hooks.events, missing: [],
                                                  commands: [rig.hooks.command(for: legacy)])
        let model = rig.model()
        #expect(model.connection == .otherCopy(legacy))
        #expect(model.connectionState == .problem)
        #expect(model.needsRepair && model.canConnect && model.hasHooks)
        #expect(model.connectionDetail.contains("~/.local/bin/sidemoon"))
        model.connect()
        #expect(rig.hooks.installs == [helper])
        #expect(model.connection == .connected)
    }

    @Test func disconnectRemovesTheHooks() {
        let rig = Rig()
        let model = rig.model()
        model.connect()
        model.disconnect()
        #expect(rig.hooks.uninstalls == 1)
        #expect(model.connection == .notConnected)
        #expect(!model.hasHooks)
        #expect(model.connectionFeedback?.text.contains("backup-2") == true)
    }

    @Test func unreadableSettingsAreLeftAlone() {
        let rig = Rig()
        rig.hooks.failure = ShapeError()
        let model = rig.model()
        #expect(model.connection == .unreadable("not JSON"))
        #expect(model.connectionState == .problem)
        #expect(!model.canConnect)
        model.connect()
        #expect(rig.hooks.installs.isEmpty)
    }

    @Test func noHelperMeansNoConnectButDisconnectStays() {
        let rig = Rig()
        rig.hooks.current = HooksInstaller.Status(installed: Constants.Hooks.events, missing: [],
                                                  commands: [rig.hooks.command(for: legacy)])
        let model = rig.model(helper: .missing("/Applications/Sidemoon.app/Contents/Helpers/sidemoon"))
        #expect(model.connection == .helperUnavailable(.missing("/Applications/Sidemoon.app/Contents/Helpers/sidemoon")))
        #expect(!model.canConnect)
        #expect(model.hasHooks)
        model.connect()
        #expect(rig.hooks.installs.isEmpty)
        model.disconnect()
        #expect(rig.hooks.uninstalls == 1)
    }

    /// The real installer on a temporary settings file: hooks written for ~/.local/bin/sidemoon by hand are
    /// moved over to the bundled helper, and only Sidemoon's entries change.
    @Test func realInstallerRepairsALegacyInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json").path
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
            .write(toFile: settings, atomically: true, encoding: .utf8)
        let oldHelper = dir.appendingPathComponent("old-sidemoon").path
        _ = try HooksInstaller(settingsPath: settings, executablePath: oldHelper).install()

        let rig = Rig()
        let model = SetupModel(helper: .found(helper), paths: paths, finder: FakeFinder(result: usualLookup),
                               hooks: SystemHooksService(settingsPath: settings), files: rig.files,
                               permission: rig.permission, relauncher: rig.relauncher, defaults: rig.defaults)
        #expect(model.connection == .missingCopy(oldHelper))
        model.connect()
        #expect(model.connection == .connected)
        let after = try JSONValue.parse(try String(contentsOfFile: settings, encoding: .utf8))
        #expect(after["model"] == .string("opus"))
        #expect(after["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"] == .string("say done"))
        model.disconnect()
        #expect(model.connection == .notConnected)
    }

    // MARK: Step 3: screen capture

    @Test func captureAskOnceThenSettingsAndRelaunch() {
        let rig = Rig()
        let model = rig.model()
        #expect(model.capture == .notGranted)
        #expect(model.captureState == .notDone)
        model.requestCapture()
        #expect(rig.permission.requests == 1)
        #expect(model.capture == .pendingRelaunch)
        // macOS shows its prompt only once; the next press opens System Settings.
        model.requestCapture()
        #expect(rig.permission.requests == 1)
        #expect(rig.permission.opens == 1)
        model.relaunch()
        #expect(rig.relauncher.relaunches == 1)
        rig.permission.granted = true
        model.refreshLocal()
        #expect(model.capture == .granted)
        #expect(model.captureState == .done)
    }

    @Test func noRelaunchOutsideABundle() {
        let rig = Rig()
        rig.relauncher.canRelaunch = false
        let model = rig.model()
        model.openCaptureSettings()
        #expect(model.capture == .pendingRelaunch)
        #expect(!model.canRelaunch)
        model.relaunch()
        #expect(rig.relauncher.relaunches == 0)
        #expect(model.captureDetail == Design.Copy.Setup.capturePendingQuit)
    }

    // MARK: Step 4: launcher

    @Test func launcherScriptMatchesTheHandWrittenOne() {
        let script = LauncherScript.content(configPath: "\(home)/Library/Application Support/Sidemoon/channel-mcp.json",
                                            helper: helper, home: home)
        let byHand = """
            #!/bin/sh
            # Starts Claude Code with the Sidemoon channel loaded, so captures can be sent into this session.
            # Anything that does not start a session here (a subcommand, -p, --bg, --version, --help) runs plain claude, and so does every launch while Sidemoon or its settings file is missing.
            helper='/Applications/Sidemoon.app/Contents/Helpers/sidemoon'
            config="$HOME/Library/Application Support/Sidemoon/channel-mcp.json"
            [ -x "$helper" ] && [ -r "$config" ] || exec claude "$@"
            case "${1-}" in
                agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade) exec claude "$@" ;;
            esac
            for arg in "$@"; do
                case "$arg" in
                    --) break ;;
                    -p|--print|--bg|--background|-v|--version|-h|--help|--desktop|--cloud|--environment|--cloud=*|--environment=*) exec claude "$@" ;;
                esac
            done
            exec claude --mcp-config="$config" --dangerously-load-development-channels=server:sidemoon "$@"
            """
        #expect(script == byHand + "\n")
        // Without its final newline it is still the same script.
        #expect(LauncherScript.matches(Data(byHand.utf8), expected: script))
        // Outside the home directory the path is written out, with sh's special characters escaped.
        #expect(LauncherScript.content(configPath: "/tmp/a\"$b/c.json", helper: helper, home: home).contains(#""/tmp/a\"\$b/c.json""#))
        #expect(LauncherScript.content(configPath: "/x.json", helper: "/A B/it's", home: home).contains(#"helper='/A B/it'\''s'"#))
        // This version's script and the 1.0.3 one are both Sidemoon's; anything else is not.
        #expect(LauncherScript.isSidemoons(Data(script.utf8)))
        #expect(LauncherScript.isSidemoons(Data(legacyLauncher.utf8)))
        #expect(!LauncherScript.isSidemoons(Data("#!/bin/sh\nexec claude \"$@\"\n".utf8)))
        #expect(!LauncherScript.isSidemoons(nil))
    }

    @Test func aLauncherFromAnEarlierVersionIsReplacedWhenSetupChecks() async {
        let rig = Rig()
        rig.files.contents[paths.launcher] = Data(legacyLauncher.utf8)
        rig.files.contents[paths.channelConfig] = Data(ChannelServer.mcpConfig(executablePath: helper).utf8)
        let model = rig.model()
        #expect(model.terminal == .launcherOutdated)
        #expect(model.canInstallLauncher)
        #expect(model.terminalDetail == Design.Copy.Setup.terminalLauncherOutdated)
        await model.refresh()
        #expect(model.terminal == .installed)
        #expect(rig.files.text(paths.launcher) == model.launcherContent)
        // Not outside Applications: nothing outside the app is changed from there.
        let moved = Rig()
        moved.files.contents[paths.launcher] = Data(legacyLauncher.utf8)
        let away = SetupModel(helper: .found(helper), paths: paths, finder: FakeFinder(result: usualLookup), hooks: moved.hooks,
                              files: moved.files, permission: moved.permission, relauncher: moved.relauncher,
                              defaults: moved.defaults, location: .elsewhere("/Users/me/Downloads/Sidemoon.app"))
        await away.refresh()
        #expect(moved.files.writes.isEmpty)
    }

    @Test func installWritesConfigAndLauncher() {
        let rig = Rig()
        let model = rig.model()
        #expect(model.terminal == .notInstalled)
        #expect(model.terminalState == .notDone)
        #expect(model.terminalDetail.contains("~/.local/bin/sidemoon-claude"))
        model.installLauncher()
        #expect(model.terminal == .installed)
        #expect(model.terminalState == .done)
        #expect(LauncherScript.configuredCommand(rig.files.contents[paths.channelConfig]) == helper)
        #expect(rig.files.text(paths.launcher) == model.launcherContent)
        #expect(rig.files.permissions[paths.launcher] == Int(CompanionConstants.Setup.launcherPermissions))
        #expect(rig.files.permissions[paths.channelConfig] == Int(Constants.Permissions.imageFile))
        #expect(rig.files.directories.contains(paths.launcherDirectory))
        #expect(model.terminalFeedback == nil)
    }

    @Test func launcherNeverOverwritesAForeignFile() {
        let rig = Rig()
        let foreign = Data("#!/bin/sh\necho mine\n".utf8)
        rig.files.contents[paths.launcher] = foreign
        let model = rig.model()
        #expect(model.terminal == .foreignLauncher)
        #expect(model.terminalState == .problem)
        #expect(!model.canInstallLauncher)
        model.installLauncher()
        #expect(rig.files.contents[paths.launcher] == foreign)
        #expect(rig.files.writes.isEmpty)
        #expect(model.terminalFeedback?.isProblem == true)
        #expect(model.pathWarning == nil)
    }

    @Test func outdatedConfigIsRepairedAndTheLauncherKept() {
        let rig = Rig()
        // A hand-made install: the same launcher (no final newline), a config naming ~/.local/bin/sidemoon.
        let byHand = LauncherScript.content(configPath: paths.channelConfig, helper: helper, home: home)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rig.files.contents[paths.launcher] = Data(byHand.utf8)
        rig.files.contents[paths.channelConfig] = Data(ChannelServer.mcpConfig(executablePath: legacy).utf8)
        let model = rig.model()
        #expect(model.terminal == .configOutdated)
        #expect(model.canInstallLauncher)
        model.installLauncher()
        #expect(model.terminal == .installed)
        #expect(rig.files.writes == [paths.channelConfig])
        #expect(rig.files.text(paths.launcher) == byHand)
    }

    @Test func terminalDerivation() {
        func derive(_ location: HelperLocation = .found(helper), exists: Bool, ours: Bool, current: Bool, config: String?) -> TerminalStatus {
            SetupModel.terminal(helper: location, launcherExists: exists, launcherIsOurs: ours, launcherIsCurrent: current,
                                configuredCommand: config)
        }
        #expect(derive(exists: false, ours: false, current: false, config: nil) == .notInstalled)
        #expect(derive(exists: true, ours: true, current: true, config: helper) == .installed)
        #expect(derive(exists: true, ours: true, current: true, config: nil) == .configOutdated)
        #expect(derive(exists: true, ours: true, current: false, config: helper) == .launcherOutdated)
        // A hand-written copy of this version's script counts as current even without the comment lines.
        #expect(derive(exists: true, ours: false, current: true, config: helper) == .installed)
        #expect(derive(exists: true, ours: false, current: false, config: helper) == .foreignLauncher)
        #expect(derive(.translocated, exists: false, ours: false, current: false, config: nil) == .helperUnavailable(.translocated))
    }

    // MARK: First run

    @Test func setupShowsOnLaunchUntilStartIsPressed() {
        let rig = Rig()
        #expect(rig.model().shouldShowOnLaunch)
        rig.model().finish()
        #expect(!rig.model().shouldShowOnLaunch)
        #expect(rig.defaults.bool(forKey: CompanionConstants.Defaults.setupSeen))
    }

    // MARK: Helper location

    @Test func helperLocation() {
        let app = "/Applications/Sidemoon.app"
        let inside = "\(app)/\(CompanionConstants.App.helperPathInBundle)"
        let exe = "/work/.build/debug/SidemoonApp"
        func locate(_ bundle: String, _ executable: String?, _ executables: Set<String>) -> HelperLocation {
            HelperLocator.locate(bundlePath: bundle, executablePath: executable, legacyPath: legacy, isExecutable: executables.contains)
        }
        #expect(locate(app, "\(app)/Contents/MacOS/Sidemoon", [inside, legacy]) == .found(inside))
        // A bundle without its helper never falls back to a copy elsewhere.
        #expect(locate(app, "\(app)/Contents/MacOS/Sidemoon", [legacy]) == .missing(inside))
        #expect(locate("/private/var/folders/x/AppTranslocation/ABC/d/Sidemoon.app", nil, []) == .translocated)
        // swift run: the CLI built next to the app binary, else the hand-installed one.
        #expect(locate("/work/.build/debug", exe, ["/work/.build/debug/sidemoon", legacy]) == .found("/work/.build/debug/sidemoon"))
        #expect(locate("/work/.build/debug", exe, [legacy]) == .found(legacy))
        #expect(locate("/work/.build/debug", exe, []) == .missing("/work/.build/debug/sidemoon"))
        #expect(CompanionConstants.App.helperPathInBundle.hasPrefix("Contents/Helpers/"))
    }

    // MARK: Connect every claude

    /// A setup whose shell files are in a temporary home folder (the launcher and config stay in the fakes).
    private func shellSetup(_ rig: Rig, home: String, location: AppLocation = .applications) -> SetupModel {
        let shell = ShellIntegration(home: home, loginShell: "/bin/zsh", launcher: paths.launcher, fileSystem: SystemShellFileSystem())
        return SetupModel(helper: .found(helper), paths: paths, finder: FakeFinder(result: usualLookup), hooks: rig.hooks,
                          files: rig.files, permission: rig.permission, relauncher: rig.relauncher, defaults: rig.defaults,
                          location: location, shell: shell)
    }

    private func temporaryHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-setup-shell-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func connectEveryClaudeIsOneClickOnAndOneClickOff() throws {
        let rig = Rig()
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "export A=1\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let model = shellSetup(rig, home: home)
        #expect(model.canChangeShell)
        #expect(!model.connectsEveryClaude)
        #expect(model.shell?.state == .off)
        #expect(model.shellDetail.contains("/.zshrc"))
        // On installs the launcher it calls, then adds the lines (after a backup).
        model.setConnectsEveryClaude(true)
        #expect(model.terminal == .installed)
        #expect(rig.files.text(paths.launcher) == model.launcherContent)
        #expect(model.connectsEveryClaude)
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8).contains(CompanionConstants.ShellIntegration.startMarker))
        #expect(model.shellFeedback?.text.contains(Constants.Paths.backupSuffix) == true)
        #expect(model.shellFeedback?.isProblem == false)
        model.setConnectsEveryClaude(false)
        #expect(!model.connectsEveryClaude)
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8) == "export A=1\n")
    }

    @Test func disconnectAlsoTakesTheLinesOut() throws {
        let rig = Rig()
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = shellSetup(rig, home: home)
        model.connect()
        model.setConnectsEveryClaude(true)
        #expect(FileManager.default.fileExists(atPath: home + "/.zshrc"))
        model.disconnect()
        #expect(model.connection == .notConnected)
        #expect(model.shell?.state == .off)
        // Sidemoon made the file, so it is gone again.
        #expect(!FileManager.default.fileExists(atPath: home + "/.zshrc"))
    }

    @Test func connectEveryClaudeIsNotOfferedWhereItCannotWork() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Someone else's file at the launcher's path: the lines would call it, so nothing is written.
        let rig = Rig()
        rig.files.contents[paths.launcher] = Data("#!/bin/sh\necho mine\n".utf8)
        let foreign = shellSetup(rig, home: home)
        #expect(!foreign.canChangeShell)
        foreign.setConnectsEveryClaude(true)
        #expect(!FileManager.default.fileExists(atPath: home + "/.zshrc"))
        // Outside Applications.
        let away = shellSetup(Rig(), home: home, location: .elsewhere("/Users/me/Downloads/Sidemoon.app"))
        #expect(!away.canChangeShell)
        #expect(away.shellDetail == Design.Copy.Setup.moveFirst)
        // Without a shell integration (tests, previews): nothing is shown.
        #expect(Rig().model().shell == nil)
    }

    @Test func aLinkedStartupFileIsExplainedAndItsLinesOffered() throws {
        let rig = Rig()
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "export A=1\n".write(toFile: home + "/zshrc-real", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: home + "/zshrc-real")
        let model = shellSetup(rig, home: home)
        model.setConnectsEveryClaude(true)
        #expect(model.shellFeedback?.isProblem == true)
        #expect(model.shellFeedback?.text.contains("is a link to another file") == true)
        #expect(model.shellLinesToCopy?.contains(CompanionConstants.ShellIntegration.startMarker) == true)
        #expect(try String(contentsOfFile: home + "/zshrc-real", encoding: .utf8) == "export A=1\n")
        #expect(!model.connectsEveryClaude)
    }
}

/// Saved settings carried over from the pre-rename bundle identifier's domain.
@Suite struct SettingsMigrationTests {
    private func scratchDefaults() -> UserDefaults { UserDefaults(suiteName: "sidemoon-migration-\(UUID().uuidString)")! }

    @Test func copiesLegacySettingsOnceIntoAnEmptyDomain() {
        let keys = CompanionConstants.Defaults.self
        let legacy = scratchDefaults(), current = scratchDefaults()
        legacy.set("night", forKey: keys.theme)
        legacy.set(1.25, forKey: keys.zoom)
        legacy.set(true, forKey: keys.setupSeen)
        legacy.set(false, forKey: keys.shortReplies)
        legacy.set("abc-123", forKey: keys.targetSession)
        legacy.set(40.0, forKey: keys.mascotOriginX)
        legacy.set("unrelated", forKey: "notOurs")

        let copied = SettingsMigration.migrate(from: legacy, to: current)
        #expect(Set(copied) == [keys.theme, keys.zoom, keys.setupSeen, keys.shortReplies, keys.targetSession, keys.mascotOriginX])
        #expect(current.string(forKey: keys.theme) == "night")
        #expect(current.double(forKey: keys.zoom) == 1.25)
        #expect(current.bool(forKey: keys.setupSeen))
        #expect(current.object(forKey: keys.shortReplies) as? Bool == false)
        #expect(current.string(forKey: keys.targetSession) == "abc-123")
        #expect(current.object(forKey: keys.mascotOriginY) == nil)
        #expect(current.object(forKey: "notOurs") == nil)
        // The legacy domain is left alone.
        #expect(legacy.string(forKey: keys.theme) == "night")

        // Once only: a later change in the legacy domain is not carried over again.
        legacy.set("paper", forKey: keys.theme)
        #expect(SettingsMigration.migrate(from: legacy, to: current).isEmpty)
        #expect(current.string(forKey: keys.theme) == "night")
    }

    @Test func leavesADomainThatAlreadyHasSettingsAlone() {
        let keys = CompanionConstants.Defaults.self
        let legacy = scratchDefaults(), current = scratchDefaults()
        legacy.set("night", forKey: keys.theme)
        legacy.set(true, forKey: keys.setupSeen)
        current.set(true, forKey: keys.largeWindow)
        #expect(SettingsMigration.migrate(from: legacy, to: current).isEmpty)
        #expect(current.object(forKey: keys.theme) == nil)
        #expect(current.object(forKey: keys.setupSeen) == nil)
    }

    @Test func onlyRunsUnderTheRenamedBundle() {
        #expect(SettingsMigration.migrateStandardDefaults(bundleIdentifier: nil).isEmpty)
        #expect(SettingsMigration.migrateStandardDefaults(bundleIdentifier: CompanionConstants.App.legacyBundleIdentifier).isEmpty)
        #expect(CompanionConstants.App.legacyBundleIdentifier != CompanionConstants.App.bundleIdentifier)
        #expect(Set(CompanionConstants.Defaults.savedKeys).count == CompanionConstants.Defaults.savedKeys.count)
    }
}

// MARK: Where the app runs from

@MainActor
private final class FakeMover: AppMover {
    var writable: Set<String> = []
    var failure: Error?
    var copies: [(String, String)] = []
    var relaunches: [String] = []
    func isWritable(_ folder: String) -> Bool { writable.contains(folder) }
    func copy(bundle: String, to destination: String) throws -> String {
        if let failure { throw failure }
        copies.append((bundle, destination))
        return destination
    }
    func relaunch(at path: String) { relaunches.append(path) }
}

@MainActor
@Suite struct AppLocationTests {
    @Test func decidesFromThePath() {
        func at(_ path: String) -> AppLocation { AppLocator.locate(bundlePath: path, home: home) }
        #expect(at("/Applications/Sidemoon.app") == .applications)
        #expect(at("/Applications/Utilities/Sidemoon.app") == .applications)
        #expect(at("\(home)/Applications/Sidemoon.app") == .applications)
        #expect(at("/Volumes/Sidemoon/Sidemoon.app") == .diskImage("/Volumes/Sidemoon/Sidemoon.app"))
        #expect(at("/private/var/folders/x/AppTranslocation/123/d/Sidemoon.app") == .translocated)
        #expect(at("\(home)/Downloads/Sidemoon.app") == .elsewhere("\(home)/Downloads/Sidemoon.app"))
        // Builds of the source are never offered a move.
        #expect(at("\(home)/src/sidemoon/dist/Sidemoon.app") == .development)
        #expect(at("\(home)/src/sidemoon/.build/debug/Sidemoon.app") == .development)
        #expect(at("\(home)/src/sidemoon/.build/debug/SidemoonApp") == .development)
        // A folder that only starts like Applications is not it.
        #expect(at("/ApplicationsOld/Sidemoon.app") == .elsewhere("/ApplicationsOld/Sidemoon.app"))
    }

    @Test func onlyCopiesOutsideApplicationsAreOfferedTheMove() {
        #expect(AppLocation.diskImage("/Volumes/x").offersMove)
        #expect(AppLocation.translocated.offersMove)
        #expect(AppLocation.elsewhere("/x").offersMove)
        #expect(!AppLocation.applications.offersMove && AppLocation.applications.maySetUp)
        #expect(!AppLocation.development.offersMove && AppLocation.development.maySetUp)
        #expect(!AppLocation.diskImage("/Volumes/x").maySetUp)
    }

    @Test func movesToTheSharedFolderElseTheUsersOwn() {
        let mover = FakeMover()
        let bundle = "/Volumes/Sidemoon/Sidemoon.app"
        mover.writable = ["/Applications", "\(home)/Applications"]
        #expect(MoveToApplications.move(bundlePath: bundle, home: home, mover: mover) == .relaunching("/Applications/Sidemoon.app"))
        #expect(mover.relaunches == ["/Applications/Sidemoon.app"])
        mover.writable = ["\(home)/Applications"]
        #expect(MoveToApplications.destination(bundlePath: bundle, home: home, mover: mover) == "\(home)/Applications/Sidemoon.app")
    }

    @Test func aMoveThatCannotHappenSaysWhyAndRelaunchesNothing() {
        let mover = FakeMover()
        let bundle = "/Volumes/Sidemoon/Sidemoon.app"
        #expect(MoveToApplications.move(bundlePath: bundle, home: home, mover: mover) == .failed(Design.Copy.Move.noWritableFolder))
        mover.writable = ["/Applications"]
        mover.failure = ShapeError()
        guard case let .failed(reason) = MoveToApplications.move(bundlePath: bundle, home: home, mover: mover) else {
            Issue.record("expected a failure"); return
        }
        #expect(reason.contains("not JSON"))
        #expect(mover.relaunches.isEmpty)
    }

    @Test func aCopyOutsideApplicationsChangesNothingOutsideItself() {
        let rig = Rig()
        let model = SetupModel(helper: .found("/Volumes/Sidemoon/Sidemoon.app/Contents/Helpers/sidemoon"), paths: paths,
                               finder: FakeFinder(result: usualLookup), hooks: rig.hooks, files: rig.files,
                               permission: rig.permission, relauncher: rig.relauncher, defaults: rig.defaults,
                               location: .diskImage("/Volumes/Sidemoon/Sidemoon.app"))
        #expect(model.needsMove)
        #expect(!model.canConnect)
        #expect(!model.canInstallLauncher)
        #expect(model.connectionDetail == Design.Copy.Setup.moveFirst)
        #expect(model.terminalDetail == Design.Copy.Setup.moveFirst)
        model.connect()
        model.installLauncher()
        #expect(rig.hooks.installs.isEmpty)
        #expect(rig.files.writes.isEmpty)
    }

    @Test func theResumeCommandFollowsTheLauncherCommand() async {
        let onPath = Rig().model()
        await onPath.refresh()
        #expect(onPath.launcherResumeCommand == "sidemoon-claude --resume")
        let offPath = Rig().model(lookup: ClaudeLookup(enginePath: nil, loginShellPath: nil, pathEntries: ["/usr/bin"]))
        await offPath.refresh()
        #expect(offPath.launcherResumeCommand == "~/.local/bin/sidemoon-claude --resume")
        #expect(Design.Copy.Setup.terminalInstalled.contains("Terminal app"))
    }
}
