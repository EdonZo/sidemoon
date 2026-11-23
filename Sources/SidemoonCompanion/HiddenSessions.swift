import Foundation
import SidemoonCore

/// Sessions the user hid from the list. Hiding is Sidemoon's alone: nothing is run against the session, which keeps
/// working and can be shown again at any time. Saved in the settings, bounded, and forgotten once a hidden session
/// has not been seen for a long while.
public struct HiddenSessions: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable {
        public var hiddenAt: Date
        /// When Sidemoon last knew of the session (written down at most once per `Hidden.seenRefresh`).
        public var seenAt: Date
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public var ids: Set<String> { Set(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public func contains(_ id: String) -> Bool { entries[id] != nil }

    public mutating func hide(_ id: String, at now: Date = Date()) {
        entries[id] = Entry(hiddenAt: now, seenAt: now)
        cap()
    }

    /// Returns whether it was hidden.
    @discardableResult
    public mutating func unhide(_ id: String) -> Bool { entries.removeValue(forKey: id) != nil }

    /// Notes which hidden sessions Sidemoon still knows, and forgets the ones it has not seen for
    /// `Hidden.forgetAfter`. Returns whether anything changed (so it is saved only then).
    @discardableResult
    public mutating func prune(known: Set<String>, now: Date = Date()) -> Bool {
        let c = CompanionConstants.Hidden.self
        let before = entries
        for (id, entry) in entries {
            if known.contains(id) {
                if now.timeIntervalSince(entry.seenAt) >= c.seenRefresh { entries[id]?.seenAt = now }
            } else if now.timeIntervalSince(entry.seenAt) >= c.forgetAfter {
                entries[id] = nil
            }
        }
        cap()
        return entries != before
    }

    /// Keeps the most recently hidden `Hidden.maxEntries`.
    private mutating func cap() {
        let limit = CompanionConstants.Hidden.maxEntries
        guard entries.count > limit else { return }
        let newestFirst = entries.sorted { a, b in a.value.hiddenAt != b.value.hiddenAt ? a.value.hiddenAt > b.value.hiddenAt : a.key < b.key }
        entries = Dictionary(uniqueKeysWithValues: newestFirst.prefix(limit).map { ($0.key, $0.value) })
    }

    /// A hidden session comes back by itself when something happens the user would want to see: a new answer, or it
    /// starts waiting on them (a permission prompt). A listing that only says it is still there brings nothing back.
    /// - Parameters:
    ///   - before: the session as last seen, nil when this is the first time.
    ///   - newAnswer: this change added an answer to its conversation.
    public static func revealsItself(before: Session?, after: Session, newAnswer: Bool) -> Bool {
        if newAnswer { return true }
        return after.state == .needsInput && before?.state != .needsInput
    }

    // MARK: Saved form

    public var data: Data? { try? JSONEncoder().encode(self) }

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(HiddenSessions.self, from: $0) } ?? HiddenSessions()
    }
}

/// What "Undo" puts back after a session was hidden.
public struct HiddenUndo: Equatable, Sendable {
    public let sessionId: String
    /// The session was the target when it was hidden.
    public let wasTarget: Bool
    /// That target was Sidemoon's own pick, not the user's.
    public let targetWasAutomatic: Bool
}
