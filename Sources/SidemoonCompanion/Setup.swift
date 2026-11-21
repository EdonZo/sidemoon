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

// MARK: The launcher

public enum LauncherScript {
    /// The `sidemoon-claude` script: starts `claude` with the channel config loaded. A config under the home directory
    /// is named after `$HOME`, so the script reads the same for every user.
    public static func content(configPath: String, home: String) -> String {
        let s = CompanionConstants.Setup.self
        let config: String
        if configPath.hasPrefix(home + "/") {
            config = s.homeVariable + escaped(String(configPath.dropFirst(home.count)))
        } else {
            config = escaped(configPath)
        }
        let flags = Constants.ClaudeCLI.channelLaunchFlags
        // channelLaunchFlags is [mcp-config flag, channel flag].
        let mcpFlag = flags.first ?? "", channelFlag = flags.last ?? ""
        let exec = "exec \(Constants.Paths.claudeExecutableName) \(mcpFlag) \"\(config)\" \(channelFlag) "
            + "\(Constants.ClaudeCLI.channelLaunchValue) \"$@\""
        return [s.launcherShebang, s.launcherComment, exec].joined(separator: "\n") + "\n"
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
    public private(set) var requestedCapture = false
    /// The Ready section's "open at login" tick, applied when Start is pressed. Shown only when offered.
    public var openAtLoginChoice = true
    public var offersOpenAtLogin = false

    public let helper: HelperLocation
    public let paths: SetupPaths

    @ObservationIgnored private let finder: ClaudeFinder
    @ObservationIgnored private let hooks: HooksService
    @ObservationIgnored private let files: SetupFiles
    @ObservationIgnored private let permission: ScreenCapturePermission
    @ObservationIgnored private let relauncher: AppRelauncher
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lookupInFlight = false

    public init(helper: HelperLocation, paths: SetupPaths, finder: ClaudeFinder, hooks: HooksService, files: SetupFiles,
                permission: ScreenCapturePermission, relauncher: AppRelauncher, defaults: UserDefaults = .standard) {
        self.helper = helper
        self.paths = paths
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
        terminal = SetupModel.terminal(helper: helper, launcherExists: files.exists(paths.launcher),
                                       launcherIsOurs: LauncherScript.matches(files.read(paths.launcher), expected: launcherContent),
                                       configuredCommand: LauncherScript.configuredCommand(files.read(paths.channelConfig)))
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

    static func terminal(helper: HelperLocation, launcherExists: Bool, launcherIsOurs: Bool,
                         configuredCommand: String?) -> TerminalStatus {
        if launcherExists, !launcherIsOurs { return .foreignLauncher }
        guard let helperPath = helper.path else { return .helperUnavailable(helper) }
        guard launcherExists else { return .notInstalled }
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

    public var canInstallLauncher: Bool { terminal == .notInstalled || terminal == .configOutdated }
    public var canRelaunch: Bool { relauncher.canRelaunch }

    // MARK: Words for the current state

    public var settingsDisplayPath: String { paths.display(hooks.settingsPath) }
    public var launcherDisplayPath: String { paths.display(paths.launcher) }
    public var configDisplayPath: String { paths.display(paths.channelConfig) }

    /// What to type in a terminal: the bare name when its directory is on PATH, else the full path.
    public var launcherCommand: String {
        launcherOnPath ? (paths.launcher as NSString).lastPathComponent : launcherDisplayPath
    }

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
        switch terminal {
        case .notInstalled: return c.terminalChanges(launcherDisplayPath, config: configDisplayPath)
        case .installed: return c.terminalInstalled
        case .configOutdated: return c.terminalConfigOutdated
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
        guard canConnect, let helperPath = helper.path else { return }
        do {
            let outcome = try hooks.install(helper: helperPath)
            connectionFeedback = outcome.backupPath.map { SetupFeedback(Design.Copy.Setup.backupSaved(paths.display($0))) }
        } catch {
            connectionFeedback = SetupFeedback(Design.Copy.Setup.failed("\(error)"), isProblem: true)
        }
        refreshLocal()
    }

    /// Removes Sidemoon's hooks (and only those), after a backup.
    public func disconnect() {
        do {
            let outcome = try hooks.uninstall()
            connectionFeedback = outcome.backupPath.map { SetupFeedback(Design.Copy.Setup.backupSaved(paths.display($0))) }
        } catch {
            connectionFeedback = SetupFeedback(Design.Copy.Setup.failed("\(error)"), isProblem: true)
        }
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
    public var launcherContent: String { LauncherScript.content(configPath: paths.channelConfig, home: paths.home) }

    /// Writes the channel config (Sidemoon's own file, always brought up to date) and the launcher. A different
    /// file already at the launcher's path is never replaced.
    public func installLauncher() {
        guard let helperPath = helper.path else { return }
        if files.exists(paths.launcher), !LauncherScript.matches(files.read(paths.launcher), expected: launcherContent) {
            terminalFeedback = SetupFeedback(Design.Copy.Setup.terminalForeign(launcherDisplayPath), isProblem: true)
            refreshLocal()
            return
        }
        do {
            try files.createDirectory(paths.channelConfigDirectory, permissions: Int(Constants.Permissions.directory))
            let config = ChannelServer.mcpConfig(executablePath: helperPath) + "\n"
            try files.write(Data(config.utf8), to: paths.channelConfig, permissions: Int(Constants.Permissions.imageFile))
            if !files.exists(paths.launcher) {
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
