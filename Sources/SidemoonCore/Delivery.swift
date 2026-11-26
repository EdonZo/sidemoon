import Foundation

public struct SendRequest: Sendable {
    public var session: String
    public var imagePath: String?
    /// More images, after `imagePath`, in the order they were taken. All of them go with the one message.
    public var imagePaths: [String]
    public var text: String?
    public var wait: Bool
    /// Files to hand to the session along with the message. The originals are never modified or deleted.
    public var filePaths: [String]
    /// A request about how to answer this one message, added after the text. Not shown as the user's words.
    public var styleNote: String?
    /// For a chat: the model its run uses (`--model`); nil runs Claude Code's default. Ignored for other sessions,
    /// which keep the model they were started with.
    public var model: String?
    public init(session: String, imagePath: String? = nil, imagePaths: [String] = [], text: String? = nil, wait: Bool = false,
                filePaths: [String] = [], styleNote: String? = nil, model: String? = nil) {
        self.model = model
        self.session = session
        self.imagePath = imagePath
        self.imagePaths = imagePaths
        self.text = text
        self.wait = wait
        self.filePaths = filePaths
        self.styleNote = styleNote
    }

    /// Every image of the message, in order.
    public var allImagePaths: [String] { (imagePath.map { [$0] } ?? []) + imagePaths }
}

public struct SendResult: Sendable {
    public var ok: Bool
    public var sessionId: String?
    public var route: Route?
    public var reply: String?
    public var error: String?
    public var detail: String?
    /// The typed cause of a failure, for in-process callers. Not carried over the socket.
    public var failure: DeliveryError?
    /// A chat whose earlier conversation Claude Code no longer had: this message started a fresh one.
    public var startedOver = false

    static func failure(_ e: DeliveryError, sessionId: String? = nil, route: Route? = nil) -> SendResult {
        var r = SendResult(ok: false, sessionId: sessionId, route: route, reply: nil, error: e.description, detail: nil)
        r.failure = e
        return r
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = ["ok": ok]
        if let sessionId { d["sessionId"] = sessionId }
        if let route { d["route"] = route.rawValue }
        if let reply { d["reply"] = reply }
        if let error { d["error"] = error }
        if let detail { d["detail"] = detail }
        return d
    }

    public init(ok: Bool, sessionId: String?, route: Route?, reply: String?, error: String?, detail: String?) {
        self.ok = ok
        self.sessionId = sessionId
        self.route = route
        self.reply = reply
        self.error = error
        self.detail = detail
    }

    public init(dictionary d: [String: Any]) {
        ok = d["ok"] as? Bool ?? false
        sessionId = d["sessionId"] as? String
        route = (d["route"] as? String).flatMap(Route.init(rawValue:))
        reply = d["reply"] as? String
        error = d["error"] as? String
        detail = d["detail"] as? String
    }
}

public enum DeliveryError: Error, CustomStringConvertible, Equatable, Sendable {
    case unknownSession(String)
    case emptyMessage
    /// A command (`SlashCommand`) with screenshots or files: a command is sent exactly as typed, alone.
    case commandWithAttachments
    /// Claude Code cannot use the model a chat asked for (unknown here, or not on this plan). The model's name.
    case modelUnavailable(String)
    /// The user stopped it (Control-C in the companion). A message already handed over stays delivered.
    case stopped
    case image(String)
    case file(String)
    /// An image to send is not there (any more): its path. Kept apart from other image problems so the companion
    /// can say so in plain words and never show the path.
    case imageMissing(String)
    /// A file to send is not there (any more), or cannot be read: its path.
    case fileMissing(String)
    case noScratchpad
    case busy(String)
    case forked(original: String, copy: String?)
    case noRoute(String)
    case channel(String)
    case background(String)
    case headless(String)
    case replyTimeout
    /// Claude Code will not reopen this background session, so the message cannot reach it this way.
    /// `messageSaved`: Claude Code kept the message and delivers it the next time the session starts.
    /// `stoppedFirst`: Sidemoon had already stopped the running session when Claude Code refused, so it is
    /// left stopped (the cases the checks before stopping cannot see).
    case cannotResume(ResumeBlocker, messageSaved: Bool, stoppedFirst: Bool = false)
    /// Claude Code does not pass on what Sidemoon's helper sends to this session: the process hosting it did not
    /// load the helper as a channel (known from its flags, or because a delivery was confirmed by the helper and
    /// then not picked up). `fallback`: the route a new attempt will take now, nil when there is none.
    case channelIgnored(fallback: Route?)

    public var description: String {
        switch self {
        case let .unknownSession(s): return "unknown session: \(s) (no hook event or `claude agents` entry for it)"
        case .emptyMessage: return "nothing to send: give an image, text, or both"
        case .commandWithAttachments: return "a command is sent on its own, without screenshots or files"
        case let .modelUnavailable(m): return "claude code cannot use the model \(m)"
        case .stopped: return "stopped by the user"
        case let .image(m): return "image: \(m)"
        case let .file(m): return "file: \(m)"
        case let .imageMissing(p): return "image: not a readable regular file: \(p)"
        case let .fileMissing(p): return "file: not a readable regular file: \(p)"
        case .noScratchpad: return "no scratchpad_dir is known for this session yet (it arrives with its next hook event), so the image has nowhere it can be read without a permission prompt"
        case let .busy(s): return "busy: session \(s) is working; refusing to interrupt it"
        case let .forked(o, c): return "resume forked a copy (\(c ?? "unknown id")) instead of continuing \(o); the copy was stopped and nothing was delivered to \(o)"
        case let .noRoute(m): return "no delivery route: \(m)"
        case let .channel(m): return "channel route failed: \(m)"
        case let .background(m): return "background route failed: \(m)"
        case let .headless(m): return "headless route failed: \(m)"
        case .replyTimeout: return "delivered, but no reply arrived before the timeout"
        case let .cannotResume(b, saved, stopped):
            return "cannot resume: \(b.description)" + (saved ? "; claude code saved the message for the session's next start" : "")
                + (stopped ? "; sidemoon had stopped the running session before the resume was refused" : "")
        case let .channelIgnored(fallback):
            return "channel not picked up: the claude code process hosting this session does not pass on what the "
                + "sidemoon channel sends; " + (fallback.map { "the next attempt uses the \($0.rawValue) route" } ?? "no other route reaches it")
        }
    }
}

/// Why Claude Code will not reopen a background session with `claude --resume <id> --bg`.
public enum ResumeBlocker: String, Sendable, Codable, CaseIterable, CustomStringConvertible {
    /// It runs in the home folder, which Claude Code only trusts for one interactive session at a time.
    case homeFolder
    /// It runs in a folder Claude Code has not been told to trust.
    case untrustedFolder
    /// It stopped before its first answer finished, so there is no conversation to reopen.
    case noTranscript
    /// The Claude login it runs under is missing or expired.
    case loginNeeded
    /// It has never answered and Claude Code lists it as blocked: it is waiting for someone to answer a question
    /// in its terminal before its first turn (seen with Claude Code 2.1.330: the "New MCP server found in this
    /// project" dialog, asked once per project). Resuming it cannot continue a conversation that never began, so
    /// Claude Code starts a new session instead. Attaching to it in a terminal and answering lets it start.
    case waitingInTerminal

    public var description: String {
        switch self {
        case .homeFolder: return "the session's working directory is the home folder"
        case .untrustedFolder: return "the session's working directory is not trusted"
        case .noTranscript: return "the session has no finished answer to resume from"
        case .loginNeeded: return "claude code needs a login"
        case .waitingInTerminal: return "the session is waiting on a question in its terminal and has not started yet"
        }
    }
}

/// The checks made before a background session is stopped, and the reading of a refused resume.
public enum ResumeCheck {
    /// The same folder, however it is written (a trailing slash, `..`, a symbolic link).
    public static func isHomeFolder(_ cwd: String, home: String) -> Bool {
        func normal(_ p: String) -> String {
            var s = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return normal(cwd) == normal(home)
    }

    /// What would make a resume fail, from what can be seen without trying. `answered` is whether the
    /// session has finished an answer (nil: unknown, which never blocks). `homeFolderRefused`: Claude Code on
    /// this Mac has refused to reopen a home-folder session (`HomeFolderMemory`). Only then does the home folder
    /// block; on other Macs Claude Code reopens such sessions. `blockedInTerminal`: `claude agents` lists the
    /// session as blocked, which for one that never answered means a question in its terminal holds up its start.
    public static func blocker(cwd: String?, home: String, answered: Bool?, homeFolderRefused: Bool,
                               blockedInTerminal: Bool = false) -> ResumeBlocker? {
        if homeFolderRefused, let cwd, isHomeFolder(cwd, home: home) { return .homeFolder }
        if answered == false { return blockedInTerminal ? .waitingInTerminal : .noTranscript }
        return nil
    }

    /// Whether `claude agents` lists the session as waiting on a person (its `state`).
    public static func isBlocked(_ agent: AgentInfo) -> Bool { agent.state == Constants.ClaudeCLI.blockedState }

    /// Reads Claude Code's output from a resume that exited with an error. Nil when it says nothing known.
    public static func classify(_ output: String) -> (blocker: ResumeBlocker, messageSaved: Bool)? {
        let text = output.lowercased()
        func says(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }
        let r = Constants.ResumeRefusal.self
        let blocker: ResumeBlocker
        if says(r.homeFolderPhrases) { blocker = .homeFolder }
        else if says(r.noTranscriptPhrases) { blocker = .noTranscript }
        else if says(r.loginPhrases) { blocker = .loginNeeded }
        else if says(r.untrustedFolderPhrases) { blocker = .untrustedFolder }
        else { return nil }
        return (blocker, says(r.messageSavedPhrases))
    }
}

/// Whether Claude Code on this Mac has refused to reopen a background session in the home folder. Some Macs
/// refuse ("the home directory is trusted one session at a time"), others reopen such sessions, so nothing is
/// assumed until a refusal is seen. Remembered in a file in the support directory, so it survives a restart;
/// a later home-folder resume that works forgets it.
public final class HomeFolderMemory: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String?
    private var value: Bool

    /// Backed by a file; `path` nil keeps it in memory only (tests, and engines that do not own the support folder).
    public init(path: String?) {
        self.path = path
        value = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    public static func inMemory() -> HomeFolderMemory { HomeFolderMemory(path: nil) }
    public static func supportFolder() -> HomeFolderMemory { HomeFolderMemory(path: Constants.Paths.homeFolderRefusalPath) }

    public var refused: Bool { lock.withLock { value } }

    /// Records what the last home-folder resume showed. Returns whether that changed what is remembered.
    @discardableResult
    public func set(refused: Bool) -> Bool {
        lock.withLock {
            guard value != refused else { return false }
            value = refused
            guard let path else { return true }
            if refused {
                let stamp = Data(ISO8601DateFormatter().string(from: Date()).utf8)
                FileManager.default.createFile(atPath: path, contents: stamp,
                                               attributes: [.posixPermissions: Constants.Permissions.stateFile])
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
            return true
        }
    }
}

/// Image validation and placement.
enum ImageFile {
    struct Loaded {
        var data: Data
        var mediaType: String
        var fileExtension: String
    }

    static func load(_ path: String) throws -> Loaded {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { throw DeliveryError.imageMissing(path) }
        guard let size = attrs[.size] as? Int, size > 0, size <= Constants.Limits.maxImageBytes else {
            throw DeliveryError.image("size must be between 1 byte and \(Constants.Limits.maxImageBytes) bytes")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw DeliveryError.image("cannot read \(path)") }
        guard let (type, ext) = mediaType(data) else { throw DeliveryError.image("unsupported format (png, jpeg, gif or webp)") }
        return Loaded(data: data, mediaType: type, fileExtension: ext)
    }

    static func mediaType(_ d: Data) -> (String, String)? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if b.starts(with: Array("GIF8".utf8)) { return ("image/gif", "gif") }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return ("image/webp", "webp") }
        return nil
    }

    /// Copies the image into the session's scratchpad (owner-only, never following symlinks).
    static func place(_ image: Loaded, inScratchpad dir: String) throws -> String {
        try write(image.data, named: "\(UUID().uuidString.lowercased()).\(image.fileExtension)", inScratchpad: dir)
    }

    /// Checks that a dropped file can be sent: a readable regular file within the size limit.
    static func checkFile(_ path: String) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular else { throw DeliveryError.fileMissing(path) }
        guard let size = attrs[.size] as? Int, size <= Constants.Limits.maxFileBytes else {
            throw DeliveryError.file("\((path as NSString).lastPathComponent) is larger than \(Constants.Limits.maxFileBytes) bytes")
        }
    }

    /// Copies a file into the session's scratchpad, keeping a readable version of its name.
    static func placeFile(_ path: String, inScratchpad dir: String) throws -> String {
        try checkFile(path)
        guard let data = FileManager.default.contents(atPath: path) else { throw DeliveryError.file("cannot read \(path)") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = String((path as NSString).lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return try write(data, named: "\(UUID().uuidString.lowercased().prefix(Constants.Limits.fileIdLength))-\(name)", inScratchpad: dir)
    }

    private static func write(_ data: Data, named name: String, inScratchpad dir: String) throws -> String {
        guard PathPolicy.scratchpad(dir) != nil else { throw DeliveryError.image("scratchpad path is outside the Claude temp root") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: Constants.Permissions.directory])
        }
        guard let real = realpath(dir, nil) else { throw DeliveryError.image("scratchpad does not exist: \(dir)") }
        let resolved = String(cString: real)
        free(real)
        guard PathPolicy.scratchpad(resolved) != nil else { throw DeliveryError.image("scratchpad resolves outside the Claude temp root") }
        let path = "\(resolved)/\(Constants.Paths.imageFilePrefix)\(name)"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(Constants.Permissions.imageFile))
        guard fd >= 0 else { throw DeliveryError.image("cannot create \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let ok = data.isEmpty || data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) == $0.count }
        guard ok else { throw DeliveryError.image("short write to \(path)") }
        return path
    }

    /// The session's scratchpad: from its hook payloads, else (for sessions only seen in `claude agents`)
    /// an existing `<claude temp root>/<project>/<session id>/scratchpad` directory. The second form is
    /// inferred from observed payloads, so it is only used when that session directory already exists.
    static func scratchpad(for s: Session) -> String? {
        if let known = s.scratchpadDir { return known }
        let fm = FileManager.default
        for prefix in Constants.Paths.scratchpadRootPrefixes {
            let root = prefix + String(getuid())
            guard let projects = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for project in projects {
                let sessionDir = "\(root)/\(project)/\(s.id)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: sessionDir, isDirectory: &isDir), isDir.boolValue {
                    return PathPolicy.scratchpad("\(sessionDir)/\(Constants.Paths.scratchpadDirName)")
                }
            }
        }
        return nil
    }

    /// The message text for routes that reference the images and files by path. One image keeps the line it always
    /// had; several are numbered in the order they were taken, so the session reads them in that order.
    static func messageText(text: String?, imagePaths: [String], filePaths: [String] = []) -> String {
        var parts: [String] = []
        if let text, !text.isEmpty { parts.append(text) }
        if imagePaths.count == 1, let only = imagePaths.first {
            parts.append("[Screenshot from Sidemoon: \(only) - read this image file to see it.]")
        } else {
            parts += imagePaths.enumerated().map { index, path in
                "[Screenshot \(index + 1) of \(imagePaths.count) from Sidemoon: \(path) - read this image file to see it.]"
            }
        }
        parts += filePaths.map { "[File from Sidemoon: \($0) - read this file.]" }
        return parts.joined(separator: "\n\n")
    }
}
