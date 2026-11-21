import Foundation

/// A Claude Code hook payload. Everything here came from outside the engine and is treated as untrusted:
/// fields are optional, lengths are capped, and paths are validated before they are used.
public struct HookEvent: Sendable, Equatable {
    public var sessionId: String
    public var eventName: String
    public var cwd: String?
    public var transcriptPath: String?
    public var scratchpadDir: String?
    public var lastAssistantMessage: String?
    public var notificationType: String?
    public var message: String?
    public var source: String?
    public var reason: String?
    public var prompt: String?
    public var promptId: String?
    /// The Claude Code process that ran the hook (CLAUDE_PID, else the hook's parent pid).
    public var claudePid: Int32?
    public var receivedAt: Date

    static let maxFieldLength = 256 * 1024

    public init?(json: Data, claudePid: Int32?, receivedAt: Date = Date()) {
        guard json.count <= Constants.Limits.maxHookPayloadBytes,
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            guard let s = obj[k] as? String, !s.isEmpty else { return nil }
            return s.count > HookEvent.maxFieldLength ? String(s.prefix(HookEvent.maxFieldLength)) : s
        }
        guard let sid = str("session_id"), SessionID.isValid(sid), let name = str("hook_event_name") else { return nil }
        sessionId = sid.lowercased()
        eventName = name
        cwd = str("cwd").flatMap(PathPolicy.absolute)
        transcriptPath = str("transcript_path").flatMap(PathPolicy.transcript)
        scratchpadDir = str("scratchpad_dir").flatMap(PathPolicy.scratchpad)
        lastAssistantMessage = str("last_assistant_message")
        notificationType = str("notification_type")
        message = str("message")
        source = str("source")
        reason = str("reason")
        prompt = str("prompt")
        promptId = str("prompt_id")
        self.claudePid = (claudePid ?? 0) > 1 ? claudePid : nil
        self.receivedAt = receivedAt
    }
}

public enum SessionID {
    /// Claude Code session ids are UUIDs.
    public static func isValid(_ s: String) -> Bool { UUID(uuidString: s) != nil }
    public static func short(_ s: String) -> String { String(s.prefix(Constants.ClaudeCLI.shortIdLength)) }
}

/// Rules for paths that arrive in untrusted payloads.
public enum PathPolicy {
    public static func absolute(_ p: String) -> String? {
        guard p.hasPrefix("/"), !p.contains("\0"), !p.split(separator: "/").contains("..") else { return nil }
        return p
    }

    public static func transcript(_ p: String) -> String? {
        guard let p = absolute(p), p.hasPrefix(Constants.Paths.claudeProjectsDirectory + "/"),
              (p as NSString).pathExtension == Constants.Paths.transcriptExtension else { return nil }
        return p
    }

    public static func scratchpad(_ p: String) -> String? {
        guard let p = absolute(p) else { return nil }
        let uid = String(getuid())
        let ok = Constants.Paths.scratchpadRootPrefixes.contains { p.hasPrefix($0 + uid + "/") }
        return ok ? p : nil
    }
}
