import Foundation

public struct SendRequest: Sendable {
    public var session: String
    public var imagePath: String?
    public var text: String?
    public var wait: Bool
    /// Files to hand to the session along with the message. The originals are never modified or deleted.
    public var filePaths: [String]
    /// A request about how to answer this one message, added after the text. Not shown as the user's words.
    public var styleNote: String?
    public init(session: String, imagePath: String? = nil, text: String? = nil, wait: Bool = false, filePaths: [String] = [],
                styleNote: String? = nil) {
        self.session = session
        self.imagePath = imagePath
        self.text = text
        self.wait = wait
        self.filePaths = filePaths
        self.styleNote = styleNote
    }
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
    case image(String)
    case file(String)
    case noScratchpad
    case busy(String)
    case forked(original: String, copy: String?)
    case noRoute(String)
    case channel(String)
    case background(String)
    case headless(String)
    case replyTimeout

    public var description: String {
        switch self {
        case let .unknownSession(s): return "unknown session: \(s) (no hook event or `claude agents` entry for it)"
        case .emptyMessage: return "nothing to send: give an image, text, or both"
        case let .image(m): return "image: \(m)"
        case let .file(m): return "file: \(m)"
        case .noScratchpad: return "no scratchpad_dir is known for this session yet (it arrives with its next hook event), so the image has nowhere it can be read without a permission prompt"
        case let .busy(s): return "busy: session \(s) is working; refusing to interrupt it"
        case let .forked(o, c): return "resume forked a copy (\(c ?? "unknown id")) instead of continuing \(o); the copy was stopped and nothing was delivered to \(o)"
        case let .noRoute(m): return "no delivery route: \(m)"
        case let .channel(m): return "channel route failed: \(m)"
        case let .background(m): return "background route failed: \(m)"
        case let .headless(m): return "headless route failed: \(m)"
        case .replyTimeout: return "delivered, but no reply arrived before the timeout"
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
              attrs[.type] as? FileAttributeType == .typeRegular else { throw DeliveryError.image("not a readable regular file: \(path)") }
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
              attrs[.type] as? FileAttributeType == .typeRegular else { throw DeliveryError.file("not a readable regular file: \(path)") }
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

    /// The message text for routes that reference the image and files by path.
    static func messageText(text: String?, imagePath: String?, filePaths: [String] = []) -> String {
        var parts: [String] = []
        if let text, !text.isEmpty { parts.append(text) }
        if let imagePath { parts.append("[Screenshot from Sidemoon: \(imagePath) - read this image file to see it.]") }
        parts += filePaths.map { "[File from Sidemoon: \($0) - read this file.]" }
        return parts.joined(separator: "\n\n")
    }
}
