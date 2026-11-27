import Foundation

/// Remembers where each session's scratchpad is, so images still have a place to go after Sidemoon restarts. Claude
/// Code reports the scratchpad only in hook payloads, and a session seen again only in `claude agents` (after the
/// Mac or Sidemoon restarted) brings none until its next hook event. macOS also empties the temp folder at restart,
/// so the remembered folder may be gone; it is made again when an image is written (`ImageFile.write`).
public enum ScratchpadMemory {
    private static let lock = NSLock()

    /// The remembered scratchpad for a session, if it is still one Claude Code would use.
    public static func recall(_ sessionId: String, path: String = Constants.Paths.scratchpadsPath) -> String? {
        lock.withLock { load(path)[sessionId] }.flatMap(PathPolicy.scratchpad)
    }

    /// Notes a session's scratchpad. Written only when it is new or changed; the oldest are forgotten past the cap.
    public static func remember(_ sessionId: String, scratchpad: String, path: String = Constants.Paths.scratchpadsPath) {
        guard PathPolicy.scratchpad(scratchpad) != nil else { return }
        lock.withLock {
            var entries = loadEntries(path)
            if entries.last?.id == sessionId, entries.last?.dir == scratchpad { return }
            entries.removeAll { $0.id == sessionId }
            entries.append(Entry(id: sessionId, dir: scratchpad))
            if entries.count > Constants.Limits.rememberedScratchpads {
                entries.removeFirst(entries.count - Constants.Limits.rememberedScratchpads)
            }
            guard let data = try? JSONEncoder().encode(entries) else { return }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    struct Entry: Codable, Equatable {
        var id: String
        var dir: String
    }

    private static func loadEntries(_ path: String) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func load(_ path: String) -> [String: String] {
        Dictionary(loadEntries(path).map { ($0.id, $0.dir) }, uniquingKeysWith: { _, last in last })
    }
}

/// Claude Code's `claude agents` screen runs hooks like a session does, but it is not a conversation: it has nothing
/// to send to. It is told apart by its own command line, never by its folder or name.
public enum AgentsScreen {
    public static func isAgentsScreen(arguments: [String]?) -> Bool {
        guard let arguments, !arguments.contains(where: Constants.ClaudeCLI.printFlags.contains) else { return false }
        // The subcommand is the first argument that is neither a flag nor the script a runtime was started with.
        let cli = Constants.ClaudeCLI.self
        let subcommand = arguments.first { arg in
            !arg.hasPrefix(cli.flagPrefix) && !cli.scriptExtensions.contains { arg.hasSuffix($0) }
        }
        return subcommand == Constants.ClaudeCLI.agentsSubcommand
    }

    public static func isAgentsScreen(pid: Int32?) -> Bool {
        guard let pid else { return false }
        return isAgentsScreen(arguments: ProcessArguments.read(pid: pid))
    }
}
