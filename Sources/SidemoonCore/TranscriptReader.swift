import Foundation

/// Reads the full text of the final assistant turn from a session transcript.
///
/// The transcript format is internal to Claude Code and may change. All knowledge of it is kept in
/// `finalTurnText(transcriptPath:promptId:marker:)`; callers fall back to the hook's
/// `last_assistant_message` whenever this returns nil.
public enum TranscriptReader {

    static let flushRetryDelay: TimeInterval = 0.3

    /// The reply for a Stop event: the transcript's final turn when it agrees with the hook's
    /// `last_assistant_message` (retrying once in case the transcript is not flushed yet), else that message.
    public static func reply(for e: HookEvent, marker: String? = nil) -> String? {
        guard let path = e.transcriptPath else { return e.lastAssistantMessage }
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: flushRetryDelay) }
            guard let full = finalTurnText(transcriptPath: path, promptId: e.promptId, marker: marker) else { continue }
            guard let last = e.lastAssistantMessage else { return full }
            if full.contains(last.trimmingCharacters(in: .whitespacesAndNewlines)) { return full }
        }
        return e.lastAssistantMessage
    }

    /// - Parameters:
    ///   - promptId: the `prompt_id` of the Stop event; selects the turn that prompt started.
    ///   - marker: text that appears in the user message that started the turn (wins over promptId).
    /// - Returns: every assistant text block of that turn joined by blank lines, or nil if not found.
    public static func finalTurnText(transcriptPath: String, promptId: String?, marker: String? = nil) -> String? {
        guard let entries = readTail(transcriptPath) else { return nil }

        // A user entry that is not a tool result. Channel messages are recorded with isMeta=true,
        // so meta entries can start a turn (by marker or prompt id) but never end one.
        func isUserInput(_ o: [String: Any]) -> Bool {
            guard o["type"] as? String == "user" else { return false }
            let content = (o["message"] as? [String: Any])?["content"]
            if content is String { return true }
            guard let blocks = content as? [[String: Any]] else { return false }
            return !blocks.contains { $0["type"] as? String == "tool_result" }
        }
        func isPrompt(_ o: [String: Any]) -> Bool { isUserInput(o) && o["isMeta"] as? Bool != true }
        func text(_ o: [String: Any]) -> String {
            let content = (o["message"] as? [String: Any])?["content"]
            if let s = content as? String { return s }
            return ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        let main = entries.filter { $0["isSidechain"] as? Bool != true }
        let start: Int?
        if let marker {
            start = main.lastIndex { isUserInput($0) && text($0).contains(marker) }
        } else if let promptId {
            start = main.firstIndex { isUserInput($0) && $0["promptId"] as? String == promptId }
        } else {
            start = main.lastIndex { isPrompt($0) && !text($0).hasPrefix("<") }
        }
        guard let start else { return nil }

        var parts: [String] = []
        let turnId = main[start]["promptId"] as? String
        for o in main[(start + 1)...] {
            if isPrompt(o) { break }
            if isUserInput(o), let turnId, let id = o["promptId"] as? String, id != turnId { break }
            guard o["type"] as? String == "assistant",
                  let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in blocks where b["type"] as? String == "text" {
                if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(t) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Whether the session's last turn is still going, read from what the session itself last wrote.
    ///
    /// The last record of the conversation settles it: an assistant message that ended its turn means the
    /// session is at its prompt; anything else (a tool call, a tool result, a new prompt) means it is
    /// working. Nil when the transcript cannot be read or holds no such record in its tail.
    public static func turnIsOpen(transcriptPath: String) -> Bool? {
        for limit in [Constants.Limits.turnProbeTailBytes, Constants.Limits.maxTranscriptTailBytes] {
            guard let data = readTailData(transcriptPath, limit: limit) else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            // The first line of a cut tail is a fragment.
            if data.count >= limit, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                // Most records are bookkeeping; only parse lines that can be a message.
                guard line.range(of: Constants.Transcript.messageHint) != nil,
                      let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["isSidechain"] as? Bool != true,
                      let type = record["type"] as? String else { continue }
                if type == Constants.Transcript.assistantType {
                    let stop = (record["message"] as? [String: Any])?["stop_reason"] as? String
                    return !Constants.Transcript.turnEndingStopReasons.contains(stop ?? "")
                }
                if type == Constants.Transcript.userType { return true }
            }
            if data.count < limit { return nil }      // The whole file was read and has no message.
        }
        return nil
    }

    /// The model id of the transcript's most recent answer (`message.model` of its last assistant record, such as
    /// `claude-opus-5-5`): only the file's end is read (`Limits.modelProbeBytes`), so a long transcript stays cheap.
    /// Nil when there is no file, no assistant record in that end, or only ones Claude Code wrote itself (an error).
    public static func lastModel(transcriptPath path: String) -> String? {
        guard let data = readTailData(path, limit: Constants.Limits.modelProbeBytes) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // The first line of a cut tail is a fragment.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
           size > Constants.Limits.modelProbeBytes, !lines.isEmpty { lines.removeFirst() }
        let t = Constants.Transcript.self
        for line in lines.reversed() where line.range(of: t.messageHint) != nil {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  record["type"] as? String == t.assistantType, record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any], let model = message["model"] as? String,
                  !model.isEmpty, model != t.syntheticModel else { continue }
            return model
        }
        return nil
    }

    /// Whether the session has finished at least one real answer: an assistant message that ended its turn
    /// and is not an error Claude Code wrote in place of one (a failed login, for example).
    ///
    /// False when there is no transcript at that path. Only the two ends of the file are read; nil when it is
    /// longer than both and neither holds an answer, so a long session is never mistaken for an empty one.
    public static func hasFinishedAnswer(transcriptPath path: String) -> Bool? {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let limit = Constants.Limits.answerProbeBytes
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: limit) else { return size == 0 ? false : nil }
        var headLines = head.split(separator: UInt8(ascii: "\n"))
        // The last line of a cut head is a fragment.
        if size > UInt64(limit), !headLines.isEmpty { headLines.removeLast() }
        if headLines.contains(where: isFinishedAnswer) { return true }
        if size <= UInt64(limit) { return false }
        guard let tail = readTailData(path, limit: limit) else { return nil }
        var tailLines = tail.split(separator: UInt8(ascii: "\n"))
        if !tailLines.isEmpty { tailLines.removeFirst() }
        if tailLines.contains(where: isFinishedAnswer) { return true }
        // Both ends together covered the whole file.
        return size <= UInt64(2 * limit) ? false : nil
    }

    private static func isFinishedAnswer(_ line: Data.SubSequence) -> Bool {
        let t = Constants.Transcript.self
        guard line.range(of: t.messageHint) != nil,
              let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              record["type"] as? String == t.assistantType,
              record["isSidechain"] as? Bool != true,
              record[t.apiErrorKey] as? Bool != true,
              let message = record["message"] as? [String: Any],
              message["model"] as? String != t.syntheticModel,
              let stop = message["stop_reason"] as? String else { return false }
        return t.turnEndingStopReasons.contains(stop)
    }

    /// The session's transcript: at `hint` when it is there, else wherever Claude Code filed it under its
    /// projects folder (the folder name is derived from the working directory, which can be spelled differently).
    /// `.missing` only when Claude Code is seen keeping this session's project here (the folder for its working
    /// directory exists) and no transcript for the session is anywhere under it. `.unknown` otherwise: the
    /// projects folder cannot be read, or Claude Code keeps its files somewhere else (`CLAUDE_CONFIG_DIR`).
    public enum Location: Equatable, Sendable {
        case found(String)
        case missing
        case unknown
    }

    /// - Parameter hint: where the transcript should be for the session's working directory, from a hook or
    ///   derived from the working directory (`AgentInfo.transcriptPath`). Its folder is the project folder.
    public static func locate(sessionId: String, hint: String?,
                              projects: String = Constants.Paths.claudeProjectsDirectory) -> Location {
        let fm = FileManager.default
        if let hint, fm.fileExists(atPath: hint) { return .found(hint) }
        guard let folders = try? fm.contentsOfDirectory(atPath: projects) else { return .unknown }
        let name = "\(sessionId).\(Constants.Paths.transcriptExtension)"
        for folder in folders {
            let candidate = "\(projects)/\(folder)/\(name)"
            if fm.fileExists(atPath: candidate) { return .found(candidate) }
        }
        // Sure only when the project folder is here, directly under this projects folder, without the transcript.
        guard let hint else { return .unknown }
        let projectFolder = URL(fileURLWithPath: hint).deletingLastPathComponent().standardizedFileURL
        guard projectFolder.deletingLastPathComponent().path == URL(fileURLWithPath: projects).standardizedFileURL.path
        else { return .unknown }
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: projectFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? .missing : .unknown
    }

    /// Whether a session has finished an answer, wherever its transcript is (nil: cannot tell).
    public static func sessionHasAnswered(_ sessionId: String, hint: String?,
                                          projects: String = Constants.Paths.claudeProjectsDirectory) -> Bool? {
        switch locate(sessionId: sessionId, hint: hint, projects: projects) {
        case let .found(path): return hasFinishedAnswer(transcriptPath: path)
        case .missing: return false
        case .unknown: return nil
        }
    }

    /// Whether the session has no transcript at all, judged more widely than `locate` does: for a session that never
    /// ran a turn, Claude Code has not even made the folder for its working directory, so `locate` cannot be sure.
    /// True only when the projects folder can be read, holds no transcript for the session in any folder, and is
    /// seen to be where this Claude Code keeps its transcripts: one of `evidence` (the transcript paths of other
    /// sessions `claude agents` lists) exists directly in a folder under it. Without that (`CLAUDE_CONFIG_DIR`
    /// elsewhere, say) it is false, and nothing is concluded.
    public static func isAbsent(_ sessionId: String, evidence: [String],
                                projects: String = Constants.Paths.claudeProjectsDirectory) -> Bool {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: projects) else { return false }
        let name = "\(sessionId).\(Constants.Paths.transcriptExtension)"
        guard !folders.contains(where: { fm.fileExists(atPath: "\(projects)/\($0)/\(name)") }) else { return false }
        let root = URL(fileURLWithPath: projects).standardizedFileURL.path
        return evidence.contains { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return url.deletingLastPathComponent().deletingLastPathComponent().path == root && fm.fileExists(atPath: url.path)
        }
    }

    /// True when `needle` occurs in the transcript tail.
    public static func contains(_ path: String, _ needle: String) -> Bool {
        guard let data = readTailData(path) else { return false }
        return data.range(of: Data(needle.utf8)) != nil
    }

    private static func readTail(_ path: String) -> [[String: Any]]? {
        guard let data = readTailData(path) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if data.count >= Constants.Limits.maxTranscriptTailBytes, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    private static func readTailData(_ path: String, limit bytes: Int = Constants.Limits.maxTranscriptTailBytes) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let limit = UInt64(bytes)
        try? h.seek(toOffset: size > limit ? size - limit : 0)
        return try? h.readToEnd()
    }
}
