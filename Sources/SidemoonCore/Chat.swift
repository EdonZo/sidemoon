import Foundation

/// A conversation Sidemoon owns, with no project folder: "General", which is always there, and the chats the user
/// starts with "+". Each message is one short `claude -p` run in Sidemoon's own chat folder, continuing the same
/// Claude Code conversation (`--resume`); nothing stays running between messages.
public struct ChatRecord: Codable, Equatable, Sendable {
    /// Sidemoon's own id for the chat, in session-id form so it can stand where a session id goes.
    public var id: String
    /// Shown in the list; nil for General, which the companion names itself.
    public var name: String?
    /// The Claude Code conversation it continues; nil until its first answer.
    public var claudeSessionId: String?
    public var createdAt: Date
    public var lastReply: String?
    public var lastReplyAt: Date?
    /// The model id its last answer came from.
    public var lastModel: String?

    public init(id: String, name: String?, claudeSessionId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.claudeSessionId = claudeSessionId
        self.createdAt = createdAt
    }

    public var isGeneral: Bool { id == Constants.Chat.generalId }

    /// How it shows in the session list: a session of kind `.chat`.
    public var session: Session {
        var s = Session(id: id)
        s.kind = .chat
        s.name = name
        s.state = .idle
        s.lastReply = lastReply
        s.lastReplyAt = lastReplyAt
        s.lastEventAt = lastReplyAt
        s.transcriptActivityAt = createdAt
        s.model = lastModel
        return s
    }
}

/// The chats, kept in a file in the support folder so their conversations carry on after a restart. Thread safe.
/// General is always there. Nothing is written until something changes.
public final class ChatBook: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String?
    private var records: [ChatRecord]

    /// Backed by a file; `path` nil keeps it in memory only (tests).
    public init(path: String?) {
        self.path = path
        var loaded: [ChatRecord] = []
        if let path, let data = FileManager.default.contents(atPath: path) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            loaded = (try? dec.decode([ChatRecord].self, from: data)) ?? []
        }
        if !loaded.contains(where: \.isGeneral) {
            loaded.insert(ChatRecord(id: Constants.Chat.generalId, name: nil, createdAt: .distantPast), at: 0)
        }
        records = loaded
    }

    public static func inMemory() -> ChatBook { ChatBook(path: nil) }
    public static func supportFolder() -> ChatBook { ChatBook(path: Constants.Paths.chatsPath) }

    public var all: [ChatRecord] { lock.withLock { records } }
    public func chat(_ id: String) -> ChatRecord? { lock.withLock { records.first { $0.id == id.lowercased() } } }

    /// A new, empty chat. Its conversation starts with its first message.
    @discardableResult
    public func create(name: String) -> ChatRecord {
        let record = ChatRecord(id: UUID().uuidString.lowercased(), name: name)
        lock.withLock {
            records.append(record)
            save()
        }
        return record
    }

    /// Records a run's outcome: the conversation it continues, and its answer.
    public func update(_ id: String, claudeSessionId: String?, reply: String?, at: Date, model: String? = nil) {
        lock.withLock {
            guard let i = records.firstIndex(where: { $0.id == id }) else { return }
            records[i].claudeSessionId = claudeSessionId
            if let model { records[i].lastModel = model }
            if let reply {
                records[i].lastReply = reply
                records[i].lastReplyAt = at
            }
            save()
        }
    }

    /// Called with the lock held.
    private func save() {
        guard let path else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(records) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: Constants.Permissions.directory])
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: Constants.Permissions.stateFile])
    }
}

public enum ChatFolder {
    /// The same folder however it is written (a symbolic link, a trailing slash): hook payloads carry the real path.
    public static func normal(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether a working directory is the chat folder (or inside it).
    public static func contains(_ cwd: String?, folder: String) -> Bool {
        guard let cwd else { return false }
        let c = normal(cwd), f = normal(folder)
        return c == f || c.hasPrefix(f + "/")
    }

    /// Makes the folder (owner only) when it is not there yet.
    public static func prepare(_ folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: Constants.Permissions.directory])
    }
}
