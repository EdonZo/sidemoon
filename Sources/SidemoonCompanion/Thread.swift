import Foundation
import SidemoonCore

/// One entry in the running conversation with a session: something the user sent, or a reply.
public struct ThreadEntry: Identifiable, Equatable, Sendable, Codable {
    public enum Role: String, Equatable, Sendable, Codable { case you, session }

    public enum Delivery: Equatable, Sendable, Codable {
        case sending
        /// The session is busy; this goes out as soon as it finishes its turn.
        case queued
        case delivered
        /// Not delivered; the text says why in plain words.
        case failed(String)
        /// Not delivered, and sending it again as it is would fail the same way (Claude Code refused the
        /// session), so it is not offered again. The text says why in plain words.
        case refused(String)

        /// Why it did not go out, for either kind of failure.
        public var failureReason: String? {
            switch self {
            case let .failed(reason), let .refused(reason): return reason
            case .sending, .queued, .delivered: return nil
            }
        }
    }

    public let id: UUID
    public let role: Role
    public let text: String
    /// Display names of what was attached: a capture or dropped files.
    public let attachments: [String]
    public let date: Date
    public var delivery: Delivery

    /// A typed message that did not go out can be sent again as it is. One that carried a screenshot or
    /// files cannot: the screenshot is deleted once sending ends, and only the files' names are kept.
    public var canRetry: Bool {
        guard role == .you, attachments.isEmpty, !text.isEmpty, case .failed = delivery else { return false }
        return true
    }

    public init(id: UUID = UUID(), role: Role, text: String, attachments: [String] = [], date: Date = Date(),
                delivery: Delivery = .delivered) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.date = date
        self.delivery = delivery
    }
}

/// The conversations, one per session. Saved to disk by `ThreadArchive`, so they survive a restart.
public struct Threads: Equatable, Sendable, Codable {
    private var entries: [String: [ThreadEntry]] = [:]
    /// Per session, when the turn of its most recently recorded reply ended.
    private var stamps: [String: Date] = [:]
    /// Sessions whose most recent reply was recorded before its stamp was known.
    private var unstamped: Set<String> = []

    public init() {}

    public func thread(for session: String?) -> [ThreadEntry] {
        session.flatMap { entries[$0] } ?? []
    }

    /// Adds an entry, dropping the oldest once a thread passes its limit.
    @discardableResult
    public mutating func append(_ entry: ThreadEntry, to session: String) -> UUID {
        var list = entries[session] ?? []
        list.append(entry)
        if list.count > CompanionConstants.Thread.maxEntries { list.removeFirst(list.count - CompanionConstants.Thread.maxEntries) }
        entries[session] = list
        return entry.id
    }

    /// Adds an entry at the start of a conversation: the first message of a session Sidemoon started, whose answer
    /// can arrive before Sidemoon learns the session's id.
    @discardableResult
    public mutating func prepend(_ entry: ThreadEntry, to session: String) -> UUID {
        entries[session, default: []].insert(entry, at: 0)
        return entry.id
    }

    /// Records a reply once. The same reply is reported several times: by the send that asked for it,
    /// by the session's hook, and again whenever the session is seen anew (a resumed session
    /// re-announces its previous reply). `stamp` is when the reply's turn ended, when known; it is what
    /// tells a new reply from an old one seen again, even after the user has sent something since.
    public mutating func appendReply(_ text: String, to session: String, stamp: Date? = nil, date: Date = Date()) {
        if let stamp, stamps[session] == stamp {
            // The same turn again, possibly with fuller text.
            if let index = entries[session]?.lastIndex(where: { $0.role == .session }), entries[session]?[index].text != text {
                let old = entries[session]![index]
                entries[session]![index] = ThreadEntry(id: old.id, role: .session, text: text, date: old.date)
            }
            return
        }
        let newest = entries[session]?.last
        let lastReply = entries[session]?.last(where: { $0.role == .session })
        // Already shown: it is the newest entry, or it was added without a stamp and this is its stamp arriving.
        if (newest?.role == .session && newest?.text == text) || (stamp != nil && unstamped.contains(session) && lastReply?.text == text) {
            if let stamp {
                stamps[session] = stamp
                unstamped.remove(session)
            }
            return
        }
        append(ThreadEntry(role: .session, text: text, date: date), to: session)
        if let stamp {
            stamps[session] = stamp
            unstamped.remove(session)
        } else {
            unstamped.insert(session)
        }
    }

    public var isEmpty: Bool { entries.values.allSatisfy(\.isEmpty) }

    /// After a restart nothing is still on its way: what was being sent or waiting its turn did not go out.
    public mutating func settleInterrupted(reason: String) {
        for session in entries.keys {
            for index in entries[session]!.indices {
                switch entries[session]![index].delivery {
                case .sending, .queued: entries[session]![index].delivery = .failed(reason)
                case .delivered, .failed, .refused: break
                }
            }
        }
    }

    /// Keeps the sessions written to most recently, so the saved file cannot grow without end.
    public mutating func keepMostRecent(_ limit: Int) {
        guard entries.count > limit else { return }
        func lastWritten(_ list: [ThreadEntry]) -> Date { list.last?.date ?? .distantPast }
        let newestFirst = entries.sorted { a, b in lastWritten(a.value) > lastWritten(b.value) }
        let kept = Set(newestFirst.prefix(limit).map(\.key))
        entries = entries.filter { pair in kept.contains(pair.key) }
        stamps = stamps.filter { pair in kept.contains(pair.key) }
        unstamped = unstamped.intersection(kept)
    }

    /// Takes one entry out of a conversation (a failed message that is being sent again).
    @discardableResult
    public mutating func remove(entry id: UUID, in session: String) -> ThreadEntry? {
        guard let index = entries[session]?.firstIndex(where: { $0.id == id }) else { return nil }
        return entries[session]?.remove(at: index)
    }

    public mutating func setDelivery(_ delivery: ThreadEntry.Delivery, entry id: UUID, in session: String) {
        guard let index = entries[session]?.firstIndex(where: { $0.id == id }) else { return }
        entries[session]?[index].delivery = delivery
    }
}

/// Where the conversations are kept between runs: one private file in the app's support folder.
/// They never leave the Mac, and "Clear" in the settings empties the file.
public struct ThreadArchive: Sendable {
    public let url: URL

    public init(url: URL = Constants.Paths.supportDirectory.appendingPathComponent(CompanionConstants.Thread.archiveName)) {
        self.url = url
    }

    /// The saved conversations, or nil when there are none or the file cannot be read.
    public func load() -> Threads? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Threads.self, from: data)
    }

    public func save(_ threads: Threads) {
        var kept = threads
        kept.keepMostRecent(CompanionConstants.Thread.maxSavedSessions)
        guard let data = try? JSONEncoder().encode(kept) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: Constants.Permissions.directory)])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Constants.Permissions.imageFile)], ofItemAtPath: url.path)
    }
}
