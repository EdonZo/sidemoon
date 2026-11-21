import Foundation

/// Merges Sidemoon's command hooks into a Claude Code settings.json and removes them again.
/// Everything Sidemoon did not write is left exactly as it was (keys, order, values).
public struct HooksInstaller: Sendable {
    public enum InstallerError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case unexpectedShape(String)
        case io(String)
        public var description: String {
            switch self {
            case let .invalidJSON(m): return "refusing to write: settings file is not valid JSON (\(m))"
            case let .unexpectedShape(m): return "refusing to write: \(m)"
            case let .io(m): return m
            }
        }
    }

    public struct Status: Sendable, Equatable {
        public var installed: [String]
        public var missing: [String]
        public var commands: [String]
        public var isComplete: Bool { missing.isEmpty }
        public init(installed: [String], missing: [String], commands: [String]) {
            self.installed = installed
            self.missing = missing
            self.commands = commands
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var changed: Bool
        public var backupPath: String?
        public init(changed: Bool, backupPath: String?) {
            self.changed = changed
            self.backupPath = backupPath
        }
    }

    public let settingsPath: String
    public let hookCommand: String

    /// - Parameter executablePath: absolute path of the `sidemoon` binary the hooks should run.
    public init(settingsPath: String, executablePath: String) {
        self.settingsPath = settingsPath
        let quoted = HooksInstaller.shellQuote(executablePath)
        // Guarded so a moved or deleted binary can never make a Claude session's hook fail.
        self.hookCommand = "[ -x \(quoted) ] && \(quoted) \(Constants.Hooks.subcommand) \(Constants.Hooks.marker) || true"
    }

    // MARK: Public operations

    public func install(now: Date = Date()) throws -> Outcome {
        let original = try load()
        let updated = try HooksInstaller.merged(original ?? .object([]), command: hookCommand)
        return try save(original: original, updated: updated, now: now)
    }

    public func uninstall(now: Date = Date()) throws -> Outcome {
        guard let original = try load() else { return Outcome(changed: false, backupPath: nil) }
        let updated = try HooksInstaller.removed(original)
        return try save(original: original, updated: updated, now: now)
    }

    public func status() throws -> Status {
        let root = try load() ?? .object([])
        var installed: [String] = [], missing: [String] = [], commands: [String] = []
        for event in Constants.Hooks.events {
            let found = HooksInstaller.managedCommands(in: root, event: event)
            if found.isEmpty { missing.append(event) } else { installed.append(event) }
            commands.append(contentsOf: found)
        }
        return Status(installed: installed, missing: missing, commands: Array(Set(commands)).sorted())
    }

    // MARK: Pure transformations (unit tested)

    static func merged(_ root: JSONValue, command: String) throws -> JSONValue {
        guard root.objectValue != nil else { throw InstallerError.unexpectedShape("top level is not an object") }
        var hooks = try existingHooks(root)
        for event in Constants.Hooks.events {
            var groups = try groupsFor(hooks, event: event)
            if managedCommands(in: root, event: event) == [command] { continue }
            groups = groups.compactMap { stripManaged(fromGroup: $0) }
            groups.append(.object([
                ("hooks", .array([.object([
                    ("type", .string(Constants.Hooks.hookType)),
                    ("command", .string(command)),
                    ("timeout", .number(String(Constants.Hooks.timeoutSeconds))),
                ])])),
            ]))
            hooks = hooks.setting(event, to: .array(groups))
        }
        return root.setting("hooks", to: hooks)
    }

    static func removed(_ root: JSONValue) throws -> JSONValue {
        guard root.objectValue != nil else { throw InstallerError.unexpectedShape("top level is not an object") }
        guard root["hooks"] != nil else { return root }
        var hooks = try existingHooks(root)
        for event in Constants.Hooks.events {
            guard hooks[event] != nil else { continue }
            let groups = try groupsFor(hooks, event: event)
            let kept = groups.compactMap { stripManaged(fromGroup: $0) }
            guard kept.count != groups.count || kept != groups else { continue }
            hooks = hooks.setting(event, to: kept.isEmpty ? nil : .array(kept))
        }
        let emptied = hooks.objectValue?.isEmpty == true && root["hooks"]?.objectValue?.isEmpty == false
        return root.setting("hooks", to: emptied ? nil : hooks)
    }

    static func managedCommands(in root: JSONValue, event: String) -> [String] {
        guard let groups = root["hooks"]?[event]?.arrayValue else { return [] }
        return groups.flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }.filter(isManaged)
        }
    }

    /// Written by this installer, under the current marker or the legacy one.
    static func isManaged(_ command: String) -> Bool {
        command.split(separator: " ").contains { word in Constants.Hooks.allMarkers.contains { word == Substring($0) } }
    }

    // MARK: Helpers

    private static func existingHooks(_ root: JSONValue) throws -> JSONValue {
        guard let hooks = root["hooks"] else { return .object([]) }
        guard hooks.objectValue != nil else { throw InstallerError.unexpectedShape("\"hooks\" is not an object") }
        return hooks
    }

    private static func groupsFor(_ hooks: JSONValue, event: String) throws -> [JSONValue] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value.arrayValue else { throw InstallerError.unexpectedShape("\"hooks.\(event)\" is not an array") }
        return groups
    }

    /// Removes Sidemoon's handlers from one matcher group; drops the group if nothing else is left in it.
    private static func stripManaged(fromGroup group: JSONValue) -> JSONValue? {
        guard let handlers = group["hooks"]?.arrayValue else { return group }
        let kept = handlers.filter { !isManaged($0["command"]?.stringValue ?? "") }
        if kept.count == handlers.count { return group }
        return kept.isEmpty ? nil : group.setting("hooks", to: .array(kept))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The binary a command written by this installer runs: the inverse of the quoting in `init`.
    /// Nil for a command in any other form.
    public static func executablePath(inCommand command: String) -> String? {
        let prefix = "[ -x "
        guard command.hasPrefix(prefix) else { return nil }
        var rest = command.dropFirst(prefix.count)[...]
        var path = ""
        // A single-quoted word, possibly in several pieces joined by \' (how shellQuote writes a quote).
        while true {
            guard rest.first == "'" else { break }
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "'") else { return nil }
            path += rest[rest.startIndex..<close]
            rest = rest[rest.index(after: close)...]
            if rest.hasPrefix("\\'") {
                path += "'"
                rest = rest.dropFirst(2)
            } else {
                break
            }
        }
        return path.isEmpty ? nil : path
    }

    // MARK: File IO

    private func load() throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return nil }
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            throw InstallerError.io("cannot read \(settingsPath)")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw InstallerError.invalidJSON("not UTF-8") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw InstallerError.invalidJSON("file is empty") }
        do { return try JSONValue.parse(text) } catch { throw InstallerError.invalidJSON("\(error)") }
    }

    private func save(original: JSONValue?, updated: JSONValue, now: Date) throws -> Outcome {
        if let original, original == updated { return Outcome(changed: false, backupPath: nil) }
        let fm = FileManager.default
        var backup: String?
        var attributes: [FileAttributeKey: Any] = [:]
        if original != nil {
            let f = DateFormatter()
            f.dateFormat = Constants.Paths.backupTimestampFormat
            f.locale = Locale(identifier: "en_US_POSIX")
            var candidate = settingsPath + Constants.Paths.backupSuffix + f.string(from: now)
            var n = 1
            while fm.fileExists(atPath: candidate) { candidate = settingsPath + Constants.Paths.backupSuffix + f.string(from: now) + "-\(n)"; n += 1 }
            do { try fm.copyItem(atPath: settingsPath, toPath: candidate) } catch {
                throw InstallerError.io("could not write backup \(candidate): \(error.localizedDescription)")
            }
            backup = candidate
            if let perms = try? fm.attributesOfItem(atPath: settingsPath)[.posixPermissions] { attributes[.posixPermissions] = perms }
        } else {
            try? fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let tmp = settingsPath + ".sidemoon-tmp-\(getpid())"
        let data = Data((updated.serialized() + "\n").utf8)
        guard fm.createFile(atPath: tmp, contents: data, attributes: attributes.isEmpty ? nil : attributes) else {
            throw InstallerError.io("could not write \(tmp)")
        }
        guard rename(tmp, settingsPath) == 0 else {
            try? fm.removeItem(atPath: tmp)
            throw InstallerError.io("could not replace \(settingsPath): \(String(cString: strerror(errno)))")
        }
        return Outcome(changed: true, backupPath: backup)
    }
}
