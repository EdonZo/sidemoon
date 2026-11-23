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
        case .emptyMessage, .failed, .refused(.noTranscript): return .failed
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

    /// A folder is chosen that may be used, there is a message, and nothing is starting already.
    public func canStart(note: FolderNote?) -> Bool {
        folder != nil && !trimmedMessage.isEmpty && !isStarting && !(note?.blocksStart ?? false)
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
