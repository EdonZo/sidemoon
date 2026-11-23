import Foundation
import SidemoonCore

// MARK: Quoting

public enum ShellQuote {
    /// Single quotes for sh: nothing inside is expanded.
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes what is special inside double quotes in fish (no backticks there, unlike sh).
    static func fishEscaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\\"$".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

// MARK: Which files, and the block in each

public enum ShellKind: String, CaseIterable, Sendable {
    case zsh, bash, fish
}

/// How the block is written in one file.
public enum ShellBlockStyle: Equatable, Sendable {
    /// zsh and bash files: a `function claude { … }` line. The `function` keyword keeps an alias named claude from
    /// being expanded while the function is defined (and an alias that runs claude then goes through it).
    case zshOrBash
    /// `~/.profile`, which other shells read too: the same function, defined only under bash.
    case bashInSharedProfile
    /// A fish function file.
    case fish
}

public struct ShellStartupFile: Equatable, Sendable, Hashable {
    public let path: String
    public let shell: ShellKind
    public let style: ShellBlockStyle
    public init(path: String, shell: ShellKind, style: ShellBlockStyle) {
        self.path = path
        self.shell = shell
        self.style = style
    }
}

public enum ShellBlock {
    /// Whether a file has Sidemoon's block, and in which form.
    public enum Presence: Equatable, Sendable {
        case absent
        /// Exactly the block this version writes.
        case current
        /// A block from another version (or edited by hand): turning the choice on replaces it.
        case outdated
        /// A start marker without its end marker, or the other way round: Sidemoon does not touch the file.
        case malformed
    }

    /// The block for one file, markers included, ending with a newline. `launcher` is the launcher's full path.
    public static func text(_ style: ShellBlockStyle, launcher: String, home: String) -> String {
        let c = CompanionConstants.ShellIntegration.self
        let name = c.functionName
        let body: [String]
        switch style {
        case .zshOrBash, .bashInSharedProfile:
            let path = "\"\(LauncherScript.homeRelative(launcher, home: home))\""
            let function = "function \(name) { if [ -x \(path) ]; then \(path) \"$@\"; else command \(name) \"$@\"; fi; }"
            body = style == .zshOrBash ? [function] : ["if [ -n \"${BASH_VERSION-}\" ]; then eval \(ShellQuote.single(function)); fi"]
        case .fish:
            let path = "\"" + (launcher.hasPrefix(home + "/")
                ? CompanionConstants.Setup.homeVariable + ShellQuote.fishEscaped(String(launcher.dropFirst(home.count)))
                : ShellQuote.fishEscaped(launcher)) + "\""
            body = [
                "function \(name) --description \(ShellQuote.single(c.fishDescription))",
                "    if test -x \(path)",
                "        \(path) $argv",
                "    else",
                "        command \(name) $argv",
                "    end",
                "end",
            ]
        }
        return ([c.startMarker, c.comment] + body + [c.endMarker]).joined(separator: "\n") + "\n"
    }

    /// Where the block is, as line indexes (start marker through end marker), or why it cannot be told.
    static func locate(_ lines: [String]) -> Result<ClosedRange<Int>?, ShellBlockError> {
        let c = CompanionConstants.ShellIntegration.self
        let starts = lines.indices.filter { lines[$0] == c.startMarker }
        let ends = lines.indices.filter { lines[$0] == c.endMarker }
        if starts.isEmpty, ends.isEmpty { return .success(nil) }
        guard starts.count == 1, ends.count == 1, let s = starts.first, let e = ends.first, s < e else {
            return .failure(.malformed)
        }
        return .success(s...e)
    }

    public static func presence(in text: String, expected: String) -> Presence {
        let lines = text.components(separatedBy: "\n")
        switch locate(lines) {
        case .failure: return .malformed
        case .success(nil): return .absent
        case let .success(range?):
            let found = lines[range].joined(separator: "\n") + "\n"
            return found == expected ? .current : .outdated
        }
    }

    /// The file with the block in it: an existing block is replaced where it is, else the block is appended after
    /// an empty line. Nothing outside the block changes (a missing final newline is added first).
    public static func adding(_ block: String, to text: String) -> Result<String, ShellBlockError> {
        var lines = text.components(separatedBy: "\n")
        let blockLines = block.components(separatedBy: "\n").dropLast()
        switch locate(lines) {
        case let .failure(error): return .failure(error)
        case let .success(range?):
            lines.replaceSubrange(range, with: blockLines)
            return .success(lines.joined(separator: "\n"))
        case .success(nil):
            var out = text
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty { out += "\n" }
            return .success(out + block)
        }
    }

    /// The file without the block. The empty line `adding` put before a block at the end goes with it, so adding
    /// and removing gives the file back as it was.
    public static func removing(from text: String) -> Result<String, ShellBlockError> {
        var lines = text.components(separatedBy: "\n")
        switch locate(lines) {
        case let .failure(error): return .failure(error)
        case .success(nil): return .success(text)
        case let .success(range?):
            // At the end: only the empty string after the final newline follows.
            let atEnd = range.upperBound == lines.count - 2 && lines.last == ""
            let start = atEnd && range.lowerBound > 0 && lines[range.lowerBound - 1].isEmpty ? range.lowerBound - 1 : range.lowerBound
            lines.removeSubrange(start...range.upperBound)
            return .success(lines == [""] ? "" : lines.joined(separator: "\n"))
        }
    }
}

public enum ShellBlockError: Error, Equatable, Sendable {
    case malformed
}

// MARK: The file system, behind a protocol

public enum ShellFileKind: Equatable, Sendable {
    case missing, file, symlink, directory, other
}

/// The file operations the shell integration needs. The real one is `SystemShellFileSystem`; tests run it on
/// temporary folders.
public protocol ShellFileSystem {
    /// What is at the path, without following a symbolic link.
    func kind(_ path: String) -> ShellFileKind
    /// An existing file can be replaced; a missing one can be created (its nearest existing folder is writable).
    func isWritable(_ path: String) -> Bool
    /// Nil when it cannot be read as UTF-8 text.
    func read(_ path: String) -> String?
    /// Replaces the whole file atomically, keeping an existing file's permissions.
    func write(_ text: String, to path: String) throws
    func createDirectory(_ path: String) throws
    func copy(_ path: String, to destination: String) throws
    func remove(_ path: String) throws
    /// The names in a folder; empty when it cannot be read.
    func names(in folder: String) -> [String]
}

public struct SystemShellFileSystem: ShellFileSystem {
    public init() {}
    private var fm: FileManager { .default }

    public func kind(_ path: String) -> ShellFileKind {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return .missing }
        switch type {
        case .typeRegular: return .file
        case .typeSymbolicLink: return .symlink
        case .typeDirectory: return .directory
        default: return .other
        }
    }

    public func isWritable(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if kind(path) != .missing { return fm.isWritableFile(atPath: path) && fm.isWritableFile(atPath: parent) }
        var folder = parent
        while kind(folder) == .missing, folder != "/" { folder = (folder as NSString).deletingLastPathComponent }
        return kind(folder) == .directory && fm.isWritableFile(atPath: folder)
    }

    public func read(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ text: String, to path: String) throws {
        let permissions = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
            ?? NSNumber(value: CompanionConstants.ShellIntegration.newFilePermissions)
        let temporary = path + CompanionConstants.ShellIntegration.temporarySuffix + "\(getpid())"
        guard fm.createFile(atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: permissions]) else {
            throw ShellFileError("could not write \(temporary)")
        }
        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: temporary)
            throw ShellFileError("could not replace \(path): \(reason)")
        }
    }

    public func createDirectory(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: CompanionConstants.ShellIntegration.newDirectoryPermissions)])
    }

    public func copy(_ path: String, to destination: String) throws { try fm.copyItem(atPath: path, toPath: destination) }
    public func remove(_ path: String) throws { try fm.removeItem(atPath: path) }
    public func names(in folder: String) -> [String] { (try? fm.contentsOfDirectory(atPath: folder)) ?? [] }
}

public struct ShellFileError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: Status and changes

/// Why Sidemoon will not write a file.
public enum ShellObstacle: Equatable, Sendable, Hashable {
    /// A symbolic link (often into a dotfiles folder): Sidemoon does not write through it.
    case symlink
    /// Something other than a plain file is at the path.
    case notAFile
    case unwritable
    case unreadable
    /// Fish already has a `claude` function of the user's own in that file.
    case foreignFunction
    /// The start and end lines of Sidemoon's block do not pair up.
    case malformed
}

public struct ShellFileStatus: Equatable, Sendable {
    public let file: ShellStartupFile
    public let presence: ShellBlock.Presence
    public let obstacle: ShellObstacle?
}

public enum ShellIntegrationState: Equatable, Sendable {
    /// No startup file has the block.
    case off
    /// Every file it goes in for the shells in use has the current block.
    case on
    /// Some files have it, or an older form of it, and some do not.
    case partial
}

public struct ShellIntegrationStatus: Equatable, Sendable {
    /// The files turning it on writes (for the shells in use).
    public let targets: [ShellFileStatus]
    /// Every file that has a block, whether its shell is in use or not.
    public let withBlock: [ShellFileStatus]

    public var state: ShellIntegrationState {
        if withBlock.isEmpty { return .off }
        if !targets.isEmpty, targets.allSatisfy({ $0.presence == .current }), withBlock.allSatisfy({ $0.presence == .current }) {
            return .on
        }
        return .partial
    }

    /// Files that block turning it on (or off) as things stand.
    public var obstacles: [ShellFileStatus] { (targets + withBlock.filter { !targets.contains($0) }).filter { $0.obstacle != nil } }
}

/// What one press did.
public struct ShellChangeReport: Equatable, Sendable {
    public var changed: [String] = []
    public var backups: [String] = []
    public var skipped: [ShellSkip] = []
    public init() {}
}

public struct ShellSkip: Equatable, Sendable, Hashable {
    public let path: String
    public let reason: Reason
    public enum Reason: Equatable, Sendable, Hashable {
        case obstacle(ShellObstacle)
        case failed(String)
    }
}

// MARK: The integration

/// Adds and removes the block that sends a plain `claude` through the launcher, in the startup files of the shells
/// the user has. Nothing outside the marked block is ever changed; a file is backed up before Sidemoon first changes it.
public struct ShellIntegration {
    public let home: String
    /// The login shell's path (only its name counts).
    public let loginShell: String
    public let launcher: String
    private let fs: ShellFileSystem
    private let now: () -> Date

    public init(home: String, loginShell: String, launcher: String, fileSystem: ShellFileSystem, now: @escaping () -> Date = Date.init) {
        self.home = home
        self.loginShell = loginShell
        self.launcher = launcher
        self.fs = fileSystem
        self.now = now
    }

    /// The user's own home folder, login shell and launcher.
    public static func system(launcher: String = Constants.Paths.launcherPath) -> ShellIntegration {
        ShellIntegration(home: FileManager.default.homeDirectoryForCurrentUser.path, loginShell: LoginEnvironment.userShell(),
                         launcher: launcher, fileSystem: SystemShellFileSystem())
    }

    private func inHome(_ name: String) -> String { (home as NSString).appendingPathComponent(name) }
    private var loginShellName: String { (loginShell as NSString).lastPathComponent }
    private var fishFolder: String {
        let c = CompanionConstants.ShellIntegration.self
        return (inHome(c.configFolder) as NSString).appendingPathComponent(c.fishFolder)
    }
    private var bashLoginFile: ShellStartupFile {
        let c = CompanionConstants.ShellIntegration.self
        // The file a bash login shell reads; a new .bash_profile only when there is none, so nothing is shadowed.
        let name = c.bashLoginFiles.first { fs.kind(inHome($0)) != .missing } ?? c.bashLoginFiles[0]
        return ShellStartupFile(path: inHome(name), shell: .bash,
                                style: name == c.sharedProfileFile ? .bashInSharedProfile : .zshOrBash)
    }

    /// The shells the user has: the login shell, and any other whose startup files (or fish's folder) exist.
    public func shellsInUse() -> [ShellKind] {
        let c = CompanionConstants.ShellIntegration.self
        func has(_ names: [String]) -> Bool { names.contains { fs.kind(inHome($0)) != .missing } }
        return ShellKind.allCases.filter { shell in
            if loginShellName == shell.rawValue { return true }
            switch shell {
            case .zsh: return has([c.zshFile])
            // .profile alone is not a sign of bash: every sh reads it.
            case .bash: return has([c.bashFile] + c.bashLoginFiles.filter { $0 != c.sharedProfileFile })
            case .fish: return fs.kind(fishFolder) == .directory
            }
        }
    }

    private func files(for shell: ShellKind) -> [ShellStartupFile] {
        let c = CompanionConstants.ShellIntegration.self
        switch shell {
        case .zsh: return [ShellStartupFile(path: inHome(c.zshFile), shell: .zsh, style: .zshOrBash)]
        case .bash: return [ShellStartupFile(path: inHome(c.bashFile), shell: .bash, style: .zshOrBash), bashLoginFile]
        case .fish:
            return [ShellStartupFile(path: (fishFolder as NSString).appendingPathComponent(c.fishFunctionFile), shell: .fish, style: .fish)]
        }
    }

    /// The files turning it on writes.
    public func targets() -> [ShellStartupFile] { shellsInUse().flatMap(files(for:)) }

    /// Every file Sidemoon could have written, for every shell, in use or not: turning it off looks in all of them.
    public func candidates() -> [ShellStartupFile] {
        let c = CompanionConstants.ShellIntegration.self
        var all = ShellKind.allCases.flatMap(files(for:))
        for name in c.bashLoginFiles {
            let file = ShellStartupFile(path: inHome(name), shell: .bash,
                                        style: name == c.sharedProfileFile ? .bashInSharedProfile : .zshOrBash)
            if !all.contains(where: { $0.path == file.path }) { all.append(file) }
        }
        return all
    }

    public func block(for file: ShellStartupFile) -> String { ShellBlock.text(file.style, launcher: launcher, home: home) }

    public func status(of file: ShellStartupFile) -> ShellFileStatus {
        let kind = fs.kind(file.path)
        if kind == .missing {
            return ShellFileStatus(file: file, presence: .absent, obstacle: fs.isWritable(file.path) ? nil : .unwritable)
        }
        // A link is followed to tell whether the block is there, never to write.
        guard let text = fs.read(file.path) else {
            return ShellFileStatus(file: file, presence: .absent, obstacle: kind == .file ? .unreadable : .notAFile)
        }
        let presence = ShellBlock.presence(in: text, expected: block(for: file))
        let obstacle: ShellObstacle?
        switch kind {
        case .symlink: obstacle = .symlink
        case .directory, .other, .missing: obstacle = .notAFile
        case .file:
            if presence == .malformed {
                obstacle = .malformed
            } else if file.style == .fish, presence == .absent {
                obstacle = .foreignFunction
            } else {
                obstacle = fs.isWritable(file.path) ? nil : .unwritable
            }
        }
        return ShellFileStatus(file: file, presence: presence, obstacle: obstacle)
    }

    public func status() -> ShellIntegrationStatus {
        let targets = self.targets().map(status(of:))
        let withBlock = candidates().map(status(of:)).filter { $0.presence != .absent }
        return ShellIntegrationStatus(targets: targets, withBlock: withBlock)
    }

    /// Turns it on: the current block in every target file. Files Sidemoon will not write are listed, not changed.
    public func enable() -> ShellChangeReport {
        var report = ShellChangeReport()
        for file in targets() {
            let current = status(of: file)
            if let obstacle = current.obstacle {
                report.skipped.append(ShellSkip(path: file.path, reason: .obstacle(obstacle)))
                continue
            }
            guard current.presence != .current else { continue }
            let existing = fs.kind(file.path) == .missing ? "" : (fs.read(file.path) ?? "")
            guard case let .success(updated) = ShellBlock.adding(block(for: file), to: existing) else {
                report.skipped.append(ShellSkip(path: file.path, reason: .obstacle(.malformed)))
                continue
            }
            change(file.path, to: updated, report: &report)
        }
        return report
    }

    /// Turns it off: the block taken out of every file that has it. A file left empty is removed (Sidemoon made it).
    public func disable() -> ShellChangeReport {
        var report = ShellChangeReport()
        for current in status().withBlock {
            let path = current.file.path
            if let obstacle = current.obstacle {
                report.skipped.append(ShellSkip(path: path, reason: .obstacle(obstacle)))
                continue
            }
            guard let text = fs.read(path), case let .success(updated) = ShellBlock.removing(from: text) else {
                report.skipped.append(ShellSkip(path: path, reason: .obstacle(.malformed)))
                continue
            }
            change(path, to: updated, report: &report)
        }
        return report
    }

    /// Writes one file, after a backup the first time Sidemoon changes it. A file that held nothing but the block
    /// and has no backup is one Sidemoon created (a file that existed was backed up first), so it is removed.
    private func change(_ path: String, to text: String, report: inout ShellChangeReport) {
        do {
            let backedUp = hasBackup(path)
            if text.isEmpty, !backedUp {
                if fs.kind(path) != .missing { try fs.remove(path) }
                report.changed.append(path)
                return
            }
            if fs.kind(path) == .file, !backedUp {
                let backup = backupPath(for: path)
                try fs.copy(path, to: backup)
                report.backups.append(backup)
            }
            try fs.createDirectory((path as NSString).deletingLastPathComponent)
            try fs.write(text, to: path)
            report.changed.append(path)
        } catch {
            report.skipped.append(ShellSkip(path: path, reason: .failed("\(error)")))
        }
    }

    /// Named the way the hooks installer names a backup of settings.json: `<file>.sidemoon-backup-<timestamp>`.
    func backupPath(for path: String) -> String {
        let f = DateFormatter()
        f.dateFormat = Constants.Paths.backupTimestampFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        let base = path + Constants.Paths.backupSuffix + f.string(from: now())
        var candidate = base
        var n = 1
        while fs.kind(candidate) != .missing {
            candidate = base + "-\(n)"
            n += 1
        }
        return candidate
    }

    /// A backup from an earlier change exists, so the file as it was before Sidemoon touched it is kept already.
    func hasBackup(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent + Constants.Paths.backupSuffix
        return fs.names(in: (path as NSString).deletingLastPathComponent).contains { $0.hasPrefix(name) }
    }
}
