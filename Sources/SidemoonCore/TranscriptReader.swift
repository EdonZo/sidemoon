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
