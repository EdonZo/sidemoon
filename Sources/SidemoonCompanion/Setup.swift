import CoreGraphics
import Foundation
import Observation
import SidemoonCore

// MARK: Side effects, each behind a protocol so tests never touch the real system

/// Where `claude` is, seen two ways.
public struct ClaudeLookup: Sendable, Equatable {
    /// Where the engine would run `claude` from; nil when the engine would not find it.
    public var enginePath: String?
    /// Where the login shell's PATH finds it; nil when it does not.
    public var loginShellPath: String?
    /// The login shell's PATH, one directory per entry.
    public var pathEntries: [String]

    public init(enginePath: String?, loginShellPath: String?, pathEntries: [String]) {
        self.enginePath = enginePath
        self.loginShellPath = loginShellPath
        self.pathEntries = pathEntries
    }
}

/// Finds `claude`. May be slow the first time (it reads the login shell's environment), so it is called off
/// the main thread.
public protocol ClaudeFinder: Sendable {
    func lookup() -> ClaudeLookup
}

/// The Claude Code hooks, in one settings file.
public protocol HooksService {
    var settingsPath: String { get }
    func status() throws -> HooksInstaller.Status
    func install(helper: String) throws -> HooksInstaller.Outcome
    func uninstall() throws -> HooksInstaller.Outcome
    /// The exact hook command installed for a helper at this path.
    func command(for helper: String) -> String
}

/// The few file operations the setup needs.
public protocol SetupFiles {
    /// True for anything at the path, including a broken symbolic link.
    func exists(_ path: String) -> Bool
    func isExecutable(_ path: String) -> Bool
    func read(_ path: String) -> Data?
    func createDirectory(_ path: String, permissions: Int) throws
    /// Writes the whole file atomically and sets its permissions.
    func write(_ data: Data, to path: String, permissions: Int) throws
}

/// macOS's Screen Recording permission for this app.
@MainActor
public protocol ScreenCapturePermission {
    func isGranted() -> Bool
    /// Shows the system prompt (macOS only shows it once per app).
    func request()
    func openSettings()
}

/// Registers the app to open when the user logs in.
@MainActor
public protocol LoginItem {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Checks for and installs new versions of the app.
@MainActor
public protocol Updater {
    /// Whether the updater checks on its own, every day or so.
    var automaticallyChecks: Bool { get }
    func setAutomaticallyChecks(_ on: Bool)
    /// Checks now and shows the result.
    func checkForUpdates()
}

/// Quits and opens the app again.
@MainActor
public protocol AppRelauncher {
    /// False when not running from an app bundle (swift run, tests).
    var canRelaunch: Bool { get }
    func relaunch()
}

// MARK: The bundled helper

/// Where the `sidemoon` CLI the hooks and the channel should run is.
public enum HelperLocation: Equatable, Sendable {
    case found(String)
    /// It should be at this path and is not.
    case missing(String)
    /// macOS runs the app from a temporary copy; a path into it would stop working.
    case translocated

    public var path: String? {
        if case let .found(p) = self { return p }
        return nil
    }
}

public enum HelperLocator {
    /// From an app bundle: only the helper inside it. Otherwise (swift run, tests): a `sidemoon` next to the running
    /// executable, else the copy installed by hand at `legacyPath`.
    public static func locate(bundlePath: String, executablePath: String?, legacyPath: String,
                              isExecutable: (String) -> Bool) -> HelperLocation {
        let bundle = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath()
        if bundle.pathExtension == CompanionConstants.App.bundleExtension {
            if bundle.path.contains(CompanionConstants.App.translocationMarker) { return .translocated }
            let helper = bundle.appendingPathComponent(CompanionConstants.App.helperPathInBundle).path
            return isExecutable(helper) ? .found(helper) : .missing(helper)
        }
        if let executablePath {
            let sibling = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent(Constants.Paths.cliExecutableName).path
            if isExecutable(sibling) { return .found(sibling) }
        }
        if isExecutable(legacyPath) { return .found(legacyPath) }
        return .missing(executablePath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(Constants.Paths.cliExecutableName).path
        } ?? legacyPath)
    }
}

// MARK: Where the app runs from

/// Where this copy of Sidemoon is running from, which decides whether it may change anything outside itself.
public enum AppLocation: Equatable, Sendable {
    /// Inside /Applications or ~/Applications: where it belongs.
    case applications
    /// A build of the source (a bare executable, or a bundle in a build folder): never offered a move.
    case development
    /// Straight from a mounted disk image, which goes away when it is ejected.
    case diskImage(String)
    /// macOS runs it from a temporary, read-only copy of where it was downloaded.
    case translocated
    /// Anywhere else: Downloads, the desktop, a folder of its own.
    case elsewhere(String)

    /// The move to the Applications folder is offered.
    public var offersMove: Bool {
        switch self {
        case .diskImage, .translocated, .elsewhere: return true
        case .applications, .development: return false
        }
    }

    /// Whether this copy may write Claude Code's settings, the terminal command, or a login item: all of them would
    /// point at this copy, and a copy outside the Applications folder is likely to disappear.
    public var maySetUp: Bool { !offersMove }
}

public enum AppLocator {
    /// Decides from the bundle's path alone. Symbolic links are followed first, so a link into /Applications is
    /// judged by where it really points.
    public static func locate(bundlePath: String, home: String) -> AppLocation {
        let a = CompanionConstants.App.self
        let path = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().standardizedFileURL.path
        guard (path as NSString).pathExtension == a.bundleExtension else { return .development }
        if path.contains(a.translocationMarker) { return .translocated }
        let components = (path as NSString).pathComponents
        if components.contains(where: a.developmentFolders.contains) { return .development }
        let folders = MoveToApplications.destinations(home: home).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if folders.contains(where: { path.hasPrefix($0 + "/") }) { return .applications }
        if path.hasPrefix(a.volumesFolder + "/") { return .diskImage(path) }
        return .elsewhere(path)
    }
}

/// Copies and relaunches the app in its new place. A protocol so the decision around it is tested without either.
@MainActor
public protocol AppMover {
    func isWritable(_ folder: String) -> Bool
    /// Copies the bundle to `destination`, replacing what is there, and returns the new bundle's path.
    func copy(bundle: String, to destination: String) throws -> String
    /// Opens the copy at `path` once this process has quit, then quits.
    func relaunch(at path: String)
}

public enum MoveToApplications {
    /// Tried in this order: the shared Applications folder, then the user's own.
    public static func destinations(home: String) -> [String] {
        [CompanionConstants.App.applicationsFolder, (home as NSString).appendingPathComponent(CompanionConstants.App.applicationsFolderName)]
    }

    /// Where the bundle goes: the first Applications folder that can be written to, under the bundle's own name, so
    /// an older Sidemoon already there is replaced. Nil when neither folder can be written to.
    @MainActor
    public static func destination(bundlePath: String, home: String, mover: AppMover) -> String? {
        let name = (bundlePath as NSString).lastPathComponent
        guard let folder = destinations(home: home).first(where: mover.isWritable) else { return nil }
        return (folder as NSString).appendingPathComponent(name)
    }

    public enum Outcome: Equatable, Sendable {
        case relaunching(String)
        case failed(String)
    }

    /// Copies the bundle into Applications and relaunches it from there. On failure nothing is relaunched and the
    /// reason is returned in plain words.
    @MainActor
    @discardableResult
    public static func move(bundlePath: String, home: String, mover: AppMover) -> Outcome {
        guard let target = destination(bundlePath: bundlePath, home: home, mover: mover) else {
            return .failed(Design.Copy.Move.noWritableFolder)
        }
        do {
            let copied = try mover.copy(bundle: bundlePath, to: target)
            mover.relaunch(at: copied)
            return .relaunching(copied)
        } catch {
            return .failed(Design.Copy.Move.failed("\(error)"))
        }
    }
}

// MARK: The launcher

public enum LauncherScript {
    /// The `sidemoon-claude` script: starts `claude` with the channel config loaded. It is the one place that decides
    /// which invocations get the channel: everything that does not start an interactive session here, and every
    /// launch while the helper or the config is missing, runs plain `claude` with the arguments unchanged. So
    /// `sidemoon-claude <anything>` is always safe, and the shell integration only has to call it.
    ///
    /// A config under the home directory is named after `$HOME`. The flags are written in their `--flag=value` form:
    /// both take several values, and in the two-word form Claude Code would read a prompt that follows as one more
    /// config or channel name ("entries must be tagged").
    public static func content(configPath: String, helper: String, home: String) -> String {
        let s = CompanionConstants.Setup.self
        let l = CompanionConstants.Launcher.self
        let claude = Constants.Paths.claudeExecutableName
        let plain = "exec \(claude) \"$@\""
        let config = homeRelative(configPath, home: home)
        let flags = Constants.ClaudeCLI.channelLaunchFlags
        // channelLaunchFlags is [mcp-config flag, channel flag].
        let mcpFlag = flags.first ?? "", channelFlag = flags.last ?? ""
        let separator = String(Constants.ClaudeCLI.flagValueSeparator)
        let flagPatterns = l.passThroughFlags + l.passThroughValueFlags.map { $0 + separator + "*" }
        let lines = [
            s.launcherShebang,
            s.launcherComment,
            s.launcherPassThroughComment,
            "\(l.helperVariable)=\(ShellQuote.single(helper))",
            "\(l.configVariable)=\"\(config)\"",
            "[ -x \"$\(l.helperVariable)\" ] && [ -r \"$\(l.configVariable)\" ] || \(plain)",
            "case \"${1-}\" in",
            "    \(l.passThroughSubcommands.joined(separator: "|"))) \(plain) ;;",
            "esac",
            "for arg in \"$@\"; do",
            "    case \"$arg\" in",
            "        \(l.endOfOptions)) break ;;",
            "        \(flagPatterns.joined(separator: "|"))) \(plain) ;;",
            "    esac",
            "done",
            "exec \(claude) \(mcpFlag)\(separator)\"$\(l.configVariable)\" "
                + "\(channelFlag)\(separator)\(Constants.ClaudeCLI.channelLaunchValue) \"$@\"",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A path for inside double quotes in sh, under the home directory written from `$HOME`.
    static func homeRelative(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/")
            ? CompanionConstants.Setup.homeVariable + escaped(String(path.dropFirst(home.count)))
            : escaped(path)
    }

    /// Escapes what is special inside double quotes in sh.
    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\\"`$".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The same script, ignoring whitespace at either end (a hand-written copy may lack the final newline).
    public static func matches(_ data: Data?, expected: String) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A launcher Sidemoon wrote, this version's or an earlier one: it starts with the shebang and the comment every
    /// Sidemoon launcher has had. Anything else at the launcher's path is the user's and is never replaced.
    public static func isSidemoons(_ data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        let s = CompanionConstants.Setup.self
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        return lines.count >= 2 && lines[0] == s.launcherShebang && lines[1] == s.launcherComment
    }

    /// The `command` the channel config runs, or nil when it is not a Sidemoon channel config.
    public static func configuredCommand(_ data: Data?) -> String? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let server = servers[Constants.Channel.serverName] as? [String: Any]
        else { return nil }
        return server["command"] as? String
    }
}

// MARK: Paths

/// The files the setup reads and writes. Tests pass temporary ones.
public struct SetupPaths: Sendable, Equatable {
    public var home: String
    public var channelConfig: String
    public var launcher: String
    public var launcherDirectory: String { (launcher as NSString).deletingLastPathComponent }
    public var channelConfigDirectory: String { (channelConfig as NSString).deletingLastPathComponent }

    public init(home: String, channelConfig: String, launcher: String) {
        self.home = home
        self.channelConfig = channelConfig
        self.launcher = launcher
    }

    public static var standard: SetupPaths {
        SetupPaths(home: FileManager.default.homeDirectoryForCurrentUser.path,
                   channelConfig: Constants.Paths.channelConfigPath, launcher: Constants.Paths.launcherPath)
    }

    /// A path with the home directory written as ~, for display.
    public func display(_ path: String) -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}

// MARK: Status of each step

public enum SetupStepState: Equatable, Sendable {
    case checking, done, notDone, problem
}

public enum ClaudeStatus: Equatable, Sendable {
    case checking
    case found(String)
    /// The login shell finds it, but the engine only looks in fixed places and would not.
    case outsideEngineReach(String)
    case missing
}

public enum ConnectionStatus: Equatable, Sendable {
    case notConnected
    case connected
    /// Some events have Sidemoon's hook and some do not.
    case incomplete
    /// The hooks run another copy of Sidemoon that still exists (for example one installed by hand).
    case otherCopy(String)
    /// The hooks run a copy that is gone (the app was moved or deleted).
    case missingCopy(String)
    /// The settings file could not be read; nothing will be written to it.
    case unreadable(String)
    case helperUnavailable(HelperLocation)
}

public enum CaptureStatus: Equatable, Sendable {
    case granted
    case notGranted
    /// Asked for, not yet in effect: macOS usually needs the app restarted after the switch is turned on.
    case pendingRelaunch
}

public enum TerminalStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// The launcher is one an earlier version of Sidemoon wrote; Setup replaces it with this version's.
    case launcherOutdated
    /// The launcher is there, but the channel config is missing or runs another copy of Sidemoon.
    case configOutdated
    /// Something else is already at the launcher's path.
    case foreignLauncher
    case helperUnavailable(HelperLocation)
}

/// What the last button press did, shown under its step.
public struct SetupFeedback: Equatable, Sendable {
    public let text: String
    public let isProblem: Bool
    public init(_ text: String, isProblem: Bool = false) {
        self.text = text
        self.isProblem = isProblem
    }
}

// MARK: Model

/// Everything the setup window shows and does. UI-framework free.
@MainActor
@Observable
public final class SetupModel {
    public private(set) var claude: ClaudeStatus = .checking
    public private(set) var connection: ConnectionStatus = .notConnected
    /// Sidemoon's hooks are in the settings file, wherever they point (Disconnect is offered).
    public private(set) var hasHooks = false
    public private(set) var capture: CaptureStatus = .notGranted
    public private(set) var terminal: TerminalStatus = .notInstalled
    /// The launcher's directory is on the login shell's PATH (only known once the lookup finished).
    public private(set) var launcherOnPath = true
    public private(set) var connectionFeedback: SetupFeedback?
    public private(set) var terminalFeedback: SetupFeedback?
    /// "Connect every claude": the shell startup files, or nil when this setup does not offer it.
    public private(set) var shell: ShellIntegrationStatus?
    public private(set) var shellFeedback: SetupFeedback?
    /// The lines to add by hand to a file Sidemoon would not change (a link, a read-only file); nil when none.
    public private(set) var shellLinesToCopy: String?
    public private(set) var requestedCapture = false
    /// The Ready section's "open at login" tick, applied when Start is pressed. Shown only when offered.
    public var openAtLoginChoice = true
    public var offersOpenAtLogin = false

    public let helper: HelperLocation
    public let paths: SetupPaths
    /// Where this copy runs from. Outside the Applications folder nothing is changed outside the app; the steps that
    /// would change something point to the move instead.
    public let location: AppLocation
    public var needsMove: Bool { location.offersMove }

    @ObservationIgnored private let finder: ClaudeFinder
    @ObservationIgnored private let hooks: HooksService
    @ObservationIgnored private let files: SetupFiles
    @ObservationIgnored private let permission: ScreenCapturePermission
    @ObservationIgnored private let relauncher: AppRelauncher
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shellIntegration: ShellIntegration?
    @ObservationIgnored private var lookupInFlight = false

    public init(helper: HelperLocation, paths: SetupPaths, finder: ClaudeFinder, hooks: HooksService, files: SetupFiles,
                permission: ScreenCapturePermission, relauncher: AppRelauncher, defaults: UserDefaults = .standard,
                location: AppLocation = .applications, shell: ShellIntegration? = nil) {
        self.shellIntegration = shell
        self.helper = helper
        self.paths = paths
        self.location = location
        self.finder = finder
        self.hooks = hooks
        self.files = files
        self.permission = permission
        self.relauncher = relauncher
        self.defaults = defaults
        refreshLocal()
    }

    // MARK: First run

    /// True until the user pressed Start once.
    public var shouldShowOnLaunch: Bool { !defaults.bool(forKey: CompanionConstants.Defaults.setupSeen) }

    /// Start: setup is not shown on launch again (it stays in the menu and the settings).
    public func finish() { defaults.set(true, forKey: CompanionConstants.Defaults.setupSeen) }

    // MARK: Checking

    /// Re-checks every step. The `claude` lookup runs off the main thread; one at a time.
    public func refresh() async {
        refreshLocal()
        // A launcher an earlier version wrote is brought up to date whenever Setup checks.
        if terminal == .launcherOutdated, !needsMove { installLauncher() }
        guard !lookupInFlight else { return }
        lookupInFlight = true
        let finder = self.finder
        let found = await Task.detached { finder.lookup() }.value
        lookupInFlight = false
        apply(found)
    }

    /// The quick checks: files, settings and the permission.
    public func refreshLocal() {
        let status = Result { try hooks.status() }
        hasHooks = (try? status.get())?.commands.isEmpty == false
        connection = SetupModel.connection(status, helper: helper, expected: helper.path.map(hooks.command(for:)),
                                           isExecutable: files.isExecutable)
        let granted = permission.isGranted()
        capture = granted ? .granted : (requestedCapture ? .pendingRelaunch : .notGranted)
        let launcher = files.read(paths.launcher)
        terminal = SetupModel.terminal(helper: helper, launcherExists: files.exists(paths.launcher),
                                       launcherIsOurs: LauncherScript.isSidemoons(launcher),
                                       launcherIsCurrent: LauncherScript.matches(launcher, expected: launcherContent),
                                       configuredCommand: LauncherScript.configuredCommand(files.read(paths.channelConfig)))
        let next = shellIntegration?.status()
        if next != shell { shell = next }
    }

    func apply(_ found: ClaudeLookup) {
        claude = SetupModel.claude(found)
        let wanted = SetupModel.normalized(paths.launcherDirectory)
        launcherOnPath = found.pathEntries.contains { SetupModel.normalized($0) == wanted }
    }

    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Derivation (pure, unit tested)

    static func claude(_ found: ClaudeLookup) -> ClaudeStatus {
        if let path = found.enginePath { return .found(path) }
        if let path = found.loginShellPath { return .outsideEngineReach(path) }
        return .missing
    }

    static func connection(_ status: Result<HooksInstaller.Status, Error>, helper: HelperLocation, expected: String?,
                           isExecutable: (String) -> Bool) -> ConnectionStatus {
        let s: HooksInstaller.Status
        switch status {
        case let .failure(error): return .unreadable("\(error)")
        case let .success(value): s = value
        }
        guard let helperPath = helper.path, let expected else { return .helperUnavailable(helper) }
        if s.commands.isEmpty { return .notConnected }
        if s.commands == [expected] { return s.isComplete ? .connected : .incomplete }
        // Some or all of the hooks run another copy.
        let others = s.commands.compactMap(HooksInstaller.executablePath(inCommand:)).filter { $0 != helperPath }
        guard let other = others.first else { return .incomplete }
        return isExecutable(other) ? .otherCopy(other) : .missingCopy(other)
    }

    /// `launcherIsOurs`: written by some version of Sidemoon. `launcherIsCurrent`: exactly this version's script.
    static func terminal(helper: HelperLocation, launcherExists: Bool, launcherIsOurs: Bool, launcherIsCurrent: Bool,
                         configuredCommand: String?) -> TerminalStatus {
        if launcherExists, !launcherIsOurs, !launcherIsCurrent { return .foreignLauncher }
        guard let helperPath = helper.path else { return .helperUnavailable(helper) }
        guard launcherExists else { return .notInstalled }
        guard launcherIsCurrent else { return .launcherOutdated }
        return configuredCommand == helperPath ? .installed : .configOutdated
    }

    // MARK: Step states

    public var claudeState: SetupStepState {
        switch claude {
        case .checking: return .checking
        case .found: return .done
        case .outsideEngineReach, .missing: return .problem
        }
    }

    public var connectionState: SetupStepState {
        switch connection {
        case .connected: return .done
        case .notConnected: return .notDone
        default: return .problem
        }
    }

    public var captureState: SetupStepState { capture == .granted ? .done : .notDone }

    public var terminalState: SetupStepState {
        switch terminal {
        case .installed: return .done
        case .notInstalled: return .notDone
        default: return .problem
        }
    }

    /// Connect, Repair or nothing: what the main button of step 2 does.
    public var canConnect: Bool {
        guard !needsMove else { return false }
        switch connection {
        case .notConnected, .incomplete, .otherCopy, .missingCopy: return true
        default: return false
        }
    }

    public var needsRepair: Bool {
        switch connection {
        case .incomplete, .otherCopy, .missingCopy: return true
        default: return false
        }
    }

    /// Connect and screen capture are what the companion needs; terminal sessions are optional.
    public var requiredStepsDone: Bool { connectionState == .done && captureState == .done }

    public var canInstallLauncher: Bool {
        !needsMove && (terminal == .notInstalled || terminal == .configOutdated || terminal == .launcherOutdated)
    }
    public var canRelaunch: Bool { relauncher.canRelaunch }

    // MARK: Words for the current state

    public var settingsDisplayPath: String { paths.display(hooks.settingsPath) }
    public var launcherDisplayPath: String { paths.display(paths.launcher) }
    public var configDisplayPath: String { paths.display(paths.channelConfig) }

    /// What to type in a terminal: the bare name when its directory is on PATH, else the full path.
    public var launcherCommand: String {
        launcherOnPath ? (paths.launcher as NSString).lastPathComponent : launcherDisplayPath
    }

    /// The same command, picking an existing session to reopen.
    public var launcherResumeCommand: String { "\(launcherCommand) \(Constants.ClaudeCLI.resumeFlag)" }

    public var claudeDetail: String {
        let c = Design.Copy.Setup.self
        switch claude {
        case .checking: return c.claudeChecking
        case let .found(path): return c.claudeFound(paths.display(path))
        case let .outsideEngineReach(path):
            let places = Constants.Paths.claudeExecutableCandidates.map(paths.display)
            return c.claudeOutsideReach(paths.display(path), places: places)
        case .missing: return c.claudeMissing
        }
    }

    public var connectionDetail: String {
        let c = Design.Copy.Setup.self
        if needsMove, connection != .connected { return c.moveFirst }
        switch connection {
        case .notConnected: return c.connectExplain(settingsDisplayPath)
        case .connected: return c.connected(settingsDisplayPath)
        case .incomplete: return c.connectIncomplete
        case let .otherCopy(path): return c.connectOtherCopy(paths.display(path))
        case let .missingCopy(path): return c.connectMissingCopy(paths.display(path))
        case let .unreadable(reason): return c.connectUnreadable(settingsDisplayPath, reason: reason)
        case let .helperUnavailable(location): return helperProblem(location)
        }
    }

    public var captureDetail: String {
        let c = Design.Copy.Setup.self
        switch capture {
        case .granted: return c.captureGranted
        case .notGranted: return c.captureExplain
        case .pendingRelaunch: return canRelaunch ? c.capturePending : c.capturePendingQuit
        }
    }

    public var terminalDetail: String {
        let c = Design.Copy.Setup.self
        if needsMove, terminal != .installed { return c.moveFirst }
        switch terminal {
        case .notInstalled: return c.terminalChanges(launcherDisplayPath, config: configDisplayPath)
        case .installed: return c.terminalInstalled
        case .configOutdated: return c.terminalConfigOutdated
        case .launcherOutdated: return c.terminalLauncherOutdated
        case .foreignLauncher: return c.terminalForeign(launcherDisplayPath)
        case let .helperUnavailable(location): return helperProblem(location)
        }
    }

    /// Shown under step 4 when the launcher's folder is not on PATH (and the launcher is, or can be, Sidemoon's).
    public var pathWarning: String? {
        guard !launcherOnPath, claude != .checking, terminal != .foreignLauncher else { return nil }
        return Design.Copy.Setup.notOnPath(paths.display(paths.launcherDirectory), launcher: launcherDisplayPath)
    }

    private func helperProblem(_ location: HelperLocation) -> String {
        switch location {
        case .translocated: return Design.Copy.Setup.helperTranslocated
        case let .missing(path): return Design.Copy.Setup.helperMissing(paths.display(path))
        case .found: return ""
        }
    }

    // MARK: Actions

    /// Connect, or Repair: installs the hooks for this app's helper. The installer backs the file up first and
    /// replaces only Sidemoon's own entries.
    public func connect() {
        guard canConnect, !needsMove, let helperPath = helper.path else { return }
        do {
            let outcome = try hooks.install(helper: helperPath)
            connectionFeedback = outcome.backupPath.map { SetupFeedback(Design.Copy.Setup.backupSaved(paths.display($0))) }
        } catch {
            connectionFeedback = SetupFeedback(Design.Copy.Setup.failed("\(error)"), isProblem: true)
        }
        refreshLocal()
    }

    /// Removes Sidemoon's hooks (and only those), after a backup, and Sidemoon's lines from the shell startup files.
    public func disconnect() {
        do {
            let outcome = try hooks.uninstall()
            connectionFeedback = outcome.backupPath.map { SetupFeedback(Design.Copy.Setup.backupSaved(paths.display($0))) }
        } catch {
            connectionFeedback = SetupFeedback(Design.Copy.Setup.failed("\(error)"), isProblem: true)
        }
        if shell?.withBlock.isEmpty == false { setConnectsEveryClaude(false) }
        refreshLocal()
    }

    /// Asks macOS for Screen Recording. After the first ask, macOS only changes it in System Settings.
    public func requestCapture() {
        if requestedCapture {
            permission.openSettings()
        } else {
            requestedCapture = true
            permission.request()
        }
        refreshLocal()
    }

    public func openCaptureSettings() {
        requestedCapture = true
        permission.openSettings()
        refreshLocal()
    }

    public func relaunch() {
        guard relauncher.canRelaunch else { return }
        relauncher.relaunch()
    }

    /// The launcher script as it should be.
    public var launcherContent: String {
        LauncherScript.content(configPath: paths.channelConfig, helper: helper.path ?? "", home: paths.home)
    }

    /// Writes the channel config (Sidemoon's own file, always brought up to date) and the launcher, replacing a
    /// launcher an earlier version of Sidemoon wrote. A different file already at the launcher's path is never replaced.
    public func installLauncher() {
        guard !needsMove, let helperPath = helper.path else { return }
        let existing = files.read(paths.launcher)
        let current = LauncherScript.matches(existing, expected: launcherContent)
        if files.exists(paths.launcher), !current, !LauncherScript.isSidemoons(existing) {
            terminalFeedback = SetupFeedback(Design.Copy.Setup.terminalForeign(launcherDisplayPath), isProblem: true)
            refreshLocal()
            return
        }
        do {
            try files.createDirectory(paths.channelConfigDirectory, permissions: Int(Constants.Permissions.directory))
            let config = ChannelServer.mcpConfig(executablePath: helperPath) + "\n"
            try files.write(Data(config.utf8), to: paths.channelConfig, permissions: Int(Constants.Permissions.imageFile))
            if !current {
                try files.createDirectory(paths.launcherDirectory, permissions: Int(CompanionConstants.Setup.launcherPermissions))
                try files.write(Data(launcherContent.utf8), to: paths.launcher,
                                permissions: Int(CompanionConstants.Setup.launcherPermissions))
            }
            terminalFeedback = nil
        } catch {
            terminalFeedback = SetupFeedback(Design.Copy.Setup.failed("\(error)"), isProblem: true)
        }
        refreshLocal()
    }

    // MARK: Connect every claude

    /// The switch can be used: offered here, Sidemoon in Applications, and a launcher that is or can be Sidemoon's.
    public var canChangeShell: Bool {
        shell != nil && !needsMove && helper.path != nil && terminal != .foreignLauncher
    }

    /// The switch is on (every file it goes in has the current lines).
    public var connectsEveryClaude: Bool { shell?.state == .on }

    /// The files the switch changes, for display.
    public var shellFiles: [String] {
        let files = shell.map { ($0.targets + $0.withBlock).map(\.file.path) } ?? []
        var seen: Set<String> = []
        return files.filter { seen.insert($0).inserted }.map(paths.display)
    }

    public var shellDetail: String {
        let c = Design.Copy.Setup.self
        guard let shell else { return "" }
        if needsMove, shell.state != .on { return c.moveFirst }
        if shell.targets.isEmpty, shell.withBlock.isEmpty { return c.shellNoShell }
        switch shell.state {
        case .off: return c.shellExplain(shellFiles)
        case .on: return c.shellOn(shellFiles)
        case .partial: return c.shellPartial
        }
    }

    /// One click on, one click off. On also installs (or updates) the launcher the lines call.
    public func setConnectsEveryClaude(_ on: Bool) {
        guard let shellIntegration else { return }
        shellLinesToCopy = nil
        if on {
            guard canChangeShell else { return }
            if terminal != .installed { installLauncher() }
            guard terminal == .installed else {
                shellFeedback = terminalFeedback ?? SetupFeedback(terminalDetail, isProblem: true)
                refreshLocal()
                return
            }
        }
        let report = on ? shellIntegration.enable() : shellIntegration.disable()
        shellFeedback = feedback(for: report)
        if let skipped = report.skipped.first(where: { $0.reason == .obstacle(.symlink) || $0.reason == .obstacle(.unwritable) }),
           let file = shellIntegration.candidates().first(where: { $0.path == skipped.path }), on {
            shellLinesToCopy = shellIntegration.block(for: file)
        }
        refreshLocal()
    }

    private func feedback(for report: ShellChangeReport) -> SetupFeedback? {
        let c = Design.Copy.Setup.self
        let problems = report.skipped.map { skip -> String in
            let file = paths.display(skip.path)
            switch skip.reason {
            case .obstacle(.symlink): return c.shellLink(file)
            case .obstacle(.unwritable): return c.shellUnwritable(file)
            case .obstacle(.unreadable): return c.shellUnreadable(file)
            case .obstacle(.notAFile): return c.shellNotAFile(file)
            case .obstacle(.foreignFunction): return c.shellForeignFunction(file)
            case .obstacle(.malformed): return c.shellMalformed(file)
            case let .failed(reason): return c.shellFailed(file, reason: reason)
            }
        }
        if !problems.isEmpty { return SetupFeedback(problems.joined(separator: " "), isProblem: true) }
        return report.backups.isEmpty ? nil : SetupFeedback(c.backupsSaved(report.backups.map(paths.display)))
    }
}

// MARK: The real system

public struct SystemClaudeFinder: ClaudeFinder {
    public init() {}

    public func lookup() -> ClaudeLookup {
        let fm = FileManager.default
        // Exactly what the engine runs.
        let engine = SystemClaudeRunner.locateClaude()
        let enginePath = engine.hasPrefix("/") && fm.isExecutableFile(atPath: engine) ? engine : nil
        let entries = (LoginEnvironment.shared[Constants.LoginShell.pathVariable] ?? "")
            .split(separator: CompanionConstants.Setup.pathSeparator).map(String.init)
        let login = entries.map { ($0 as NSString).appendingPathComponent(Constants.Paths.claudeExecutableName) }
            .first { fm.isExecutableFile(atPath: $0) }
        return ClaudeLookup(enginePath: enginePath, loginShellPath: login, pathEntries: entries)
    }
}

public struct SystemHooksService: HooksService {
    public let settingsPath: String
    public init(settingsPath: String = Constants.Paths.defaultClaudeSettings) { self.settingsPath = settingsPath }

    public func status() throws -> HooksInstaller.Status {
        // Status does not depend on the executable.
        try HooksInstaller(settingsPath: settingsPath, executablePath: "").status()
    }
    public func install(helper: String) throws -> HooksInstaller.Outcome {
        try HooksInstaller(settingsPath: settingsPath, executablePath: helper).install()
    }
    public func uninstall() throws -> HooksInstaller.Outcome {
        try HooksInstaller(settingsPath: settingsPath, executablePath: "").uninstall()
    }
    public func command(for helper: String) -> String {
        HooksInstaller(settingsPath: settingsPath, executablePath: helper).hookCommand
    }
}

public struct SystemSetupFiles: SetupFiles {
    public init() {}
    private var fm: FileManager { .default }

    public func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }
    public func isExecutable(_ path: String) -> Bool { fm.isExecutableFile(atPath: path) }
    public func read(_ path: String) -> Data? { fm.contents(atPath: path) }

    public func createDirectory(_ path: String, permissions: Int) throws {
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: permissions)])
    }

    public func write(_ data: Data, to path: String, permissions: Int) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: path)
    }
}

/// CoreGraphics' preflight check. Requesting and opening System Settings need AppKit and live in the app.
public enum ScreenCaptureAccess {
    public static func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }
}
