import Foundation
import SidemoonCore

/// Picks a folder with the system's folder panel. Injected, so the model can be tested without AppKit.
@MainActor
public protocol FolderChooser: AnyObject {
    /// The folder the user chose, or nil when they cancelled. `startingAt`: where the panel opens.
    func chooseFolder(startingAt: String?) async -> String?
}

/// The folders offered first when starting a new session.
public enum RecentFolders {
    /// The folders of the sessions Sidemoon knows, most recently active first, each once, only ones that still exist
    /// and never the home folder; the folder used last goes first when it qualifies.
    public static func list(sessions: [Session], lastUsed: String?, home: String, checks: PathChecks,
                            limit: Int = CompanionConstants.NewSession.recentFolders) -> [String] {
        let byActivity = sessions.sorted { a, b in
            let ta = a.activityAt ?? .distantPast, tb = b.activityAt ?? .distantPast
            return ta != tb ? ta > tb : a.id < b.id
        }
        var seen: Set<String> = []
        var folders: [String] = []
        for folder in [lastUsed].compactMap({ $0 }) + byActivity.compactMap(\.cwd) {
            let key = normal(folder)
            guard !folder.isEmpty, !seen.contains(key), !ResumeCheck.isHomeFolder(folder, home: home),
                  checks.folderExists(folder) else { continue }
            seen.insert(key)
            folders.append(folder)
            if folders.count == limit { break }
        }
        return folders
    }

    /// The same folder however it is written (a trailing slash).
    static func normal(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// What the form says about the chosen folder.
public enum FolderNote: Equatable, Sendable {
    /// The home folder works on this Mac, but a project folder is the safer choice.
    case homeCaution
    /// Claude Code on this Mac refuses to reopen background sessions in the home folder: not allowed.
    case homeRefused
    /// The folder was moved or deleted since it was chosen.
    case missing

    /// Whether a session may be started there.
    public var blocksStart: Bool { self != .homeCaution }

    public static func of(_ folder: String?, home: String, homeRefused: Bool, checks: PathChecks) -> FolderNote? {
        guard let folder else { return nil }
        guard checks.folderExists(folder) else { return .missing }
        guard ResumeCheck.isHomeFolder(folder, home: home) else { return nil }
        return homeRefused ? .homeRefused : .homeCaution
    }
}

/// Why a new session did not start, in plain words. `detail` (what Claude Code printed) goes behind Details.
public enum NewSessionProblem: Equatable, Sendable {
    case folderMissing
    case homeFolderRefused
    case claudeNotFound
    case untrustedFolder
    case loginNeeded
    case timedOut
    case notConfirmed
    case failed

    public static func from(_ error: NewSessionError) -> NewSessionProblem {
        switch error {
        case .folderMissing: return .folderMissing
        case .homeFolderRefused, .refused(.homeFolder): return .homeFolderRefused
        case .claudeNotFound: return .claudeNotFound
        case .refused(.untrustedFolder): return .untrustedFolder
        case .refused(.loginNeeded): return .loginNeeded
        case .timedOut: return .timedOut
        case .notConfirmed: return .notConfirmed
        case .emptyMessage, .failed, .refused(.noTranscript), .refused(.waitingInTerminal): return .failed
        }
    }

    public var title: String { Design.Copy.NewSession.problemTitle(self) }
    public var advice: String { Design.Copy.NewSession.problemAdvice(self) }
}

/// The new-session form: the folder, the first message, and where starting it has got to.
public struct NewSessionForm: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case editing
        /// `claude --bg` is running. Not cancellable: once launched, the session exists, and stopping it again
        /// half-started is not something to do behind the user's back.
        case starting
        case failed(NewSessionProblem, detail: String?)
    }

    public var folder: String?
    public var message = ""
    public private(set) var phase: Phase = .editing
    /// "Work in a folder…" is open: a Claude Code session in the chosen folder (`claude --bg`). Off, the form starts a
    /// chat, which needs no folder.
    public var inFolder = false

    public init(folder: String? = nil) { self.folder = folder }

    public var isStarting: Bool { phase == .starting }
    public var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var problem: NewSessionProblem? {
        if case let .failed(problem, _) = phase { return problem }
        return nil
    }

    public var problemDetail: String? {
        if case let .failed(_, detail) = phase { return detail }
        return nil
    }

    /// The name a new session gets (`claude --bg -n`): the form has no name field, and without one Claude Code names
    /// the session after its whole first prompt, Sidemoon's short-replies note included. The folder's own name is
    /// short and says where it works. Nil when there is no usable name (Claude Code then names it).
    public static func defaultName(for folder: String) -> String? {
        let name = (RecentFolders.normal(folder) as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }

    /// There is a message and nothing is starting already; in a folder, one is chosen that may be used.
    public func canStart(note: FolderNote?) -> Bool {
        guard !trimmedMessage.isEmpty, !isStarting else { return false }
        return !inFolder || (folder != nil && !(note?.blocksStart ?? false))
    }

    /// Opens or closes the folder choice. Not while starting; an error about the last attempt no longer applies.
    public mutating func setInFolder(_ on: Bool) {
        guard !isStarting else { return }
        inFolder = on
        if case .failed = phase { phase = .editing }
    }

    /// A different folder is chosen: an error about the last attempt no longer applies.
    public mutating func choose(_ folder: String) {
        guard !isStarting else { return }
        self.folder = folder
        if case .failed = phase { phase = .editing }
    }

    /// Returns false when it may not start now.
    @discardableResult
    public mutating func begin(note: FolderNote?) -> Bool {
        guard canStart(note: note) else { return false }
        phase = .starting
        return true
    }

    public mutating func fail(_ problem: NewSessionProblem, detail: String?) {
        guard isStarting else { return }
        phase = .failed(problem, detail: detail)
    }
}
