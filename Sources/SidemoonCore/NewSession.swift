import Foundation

/// A new background session, started by Sidemoon with `claude --bg "<message>"` in a folder.
public struct NewSessionRequest: Sendable, Equatable {
    /// The folder the session works in.
    public var folder: String
    /// The first message, as the user typed it.
    public var text: String
    /// A request about how to answer, added after the text like on any send. Not shown as the user's words.
    public var styleNote: String?
    /// A display name for the session (`-n`); nil lets Claude Code name it.
    public var name: String?

    public init(folder: String, text: String, styleNote: String? = nil, name: String? = nil) {
        self.folder = folder
        self.text = text
        self.styleNote = styleNote
        self.name = name
    }
}

/// Why a new session could not be started.
public enum NewSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyMessage
    /// The folder does not exist (or is not a folder).
    case folderMissing(String)
    /// The home folder, where Claude Code on this Mac has refused to reopen a background session: Sidemoon could
    /// start one there but not send to it again.
    case homeFolderRefused
    /// The `claude` command cannot be found or run.
    case claudeNotFound
    /// Claude Code refused, in words `ResumeCheck.classify` knows (an untrusted folder, a login, the home folder).
    case refused(ResumeBlocker)
    /// `claude --bg` did not finish in time.
    case timedOut
    /// `claude --bg` exited with an error Sidemoon does not know.
    case failed(status: Int32)
    /// It did not print a session id, or the session it named never showed up.
    case notConfirmed

    public var description: String {
        switch self {
        case .emptyMessage: return "nothing to send: a new session needs a first message"
        case let .folderMissing(f): return "the folder does not exist: \(f)"
        case .homeFolderRefused: return "claude code on this mac refuses to reopen background sessions in the home folder"
        case .claudeNotFound: return "the claude command was not found"
        case let .refused(b): return "claude code refused: \(b.description)"
        case .timedOut: return "claude --bg did not finish within \(Int(Constants.Timeouts.newSessionStart))s"
        case let .failed(status): return "claude --bg exited \(status)"
        case .notConfirmed: return "the new session could not be confirmed"
        }
    }
}

public struct NewSessionResult: Sendable {
    /// The new session's full id; nil when it was not started.
    public var sessionId: String?
    public var failure: NewSessionError?
    /// What Claude Code printed, for the Details a bug report can quote.
    public var detail: String?
    public var ok: Bool { failure == nil && sessionId != nil }

    public init(sessionId: String?, failure: NewSessionError?, detail: String?) {
        self.sessionId = sessionId
        self.failure = failure
        self.detail = detail
    }

    static func failed(_ e: NewSessionError, detail: String? = nil) -> NewSessionResult {
        NewSessionResult(sessionId: nil, failure: e, detail: detail)
    }

    /// Over the socket the failure travels as its description only, like `SendResult`.
    public var dictionary: [String: Any] {
        var d: [String: Any] = ["ok": ok]
        if let sessionId { d["sessionId"] = sessionId }
        if let failure { d["error"] = failure.description }
        if let detail { d["detail"] = detail }
        return d
    }
}
