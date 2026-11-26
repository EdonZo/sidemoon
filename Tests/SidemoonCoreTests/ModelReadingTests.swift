import Foundation
import Testing
@testable import SidemoonCore

private func transcript(_ lines: [String]) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-model-\(UUID().uuidString).jsonl")
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    return url.path
}

private func answer(_ model: String, sidechain: Bool = false) -> String {
    #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"role":"assistant","model":"\#(model)","stop_reason":"end_turn","content":[]}}"#
}

private let prompt = #"{"type":"user","message":{"role":"user","content":"go"}}"#

@Suite struct ModelReadingTests {
    @Test func theLastAnswerWins() throws {
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript([prompt, answer("claude-haiku-5-5"), prompt,
                                                                          answer("claude-opus-5-5"), prompt])) == "claude-opus-5-5")
        // A subagent's, and one Claude Code wrote itself (an error), do not count.
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript([answer("claude-opus-5-5"), answer("claude-haiku-5-5", sidechain: true),
                                                                          answer("<synthetic>")])) == "claude-opus-5-5")
    }

    @Test func noAnswerNoModel() throws {
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript([prompt])) == nil)
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript([])) == nil)
        #expect(TranscriptReader.lastModel(transcriptPath: "/nonexistent/x.jsonl") == nil)
    }

    /// Only the end is read: an answer only at the start of a long file is not found (rather than reading it whole),
    /// and one at the end is.
    @Test func aLongTranscriptIsReadAtItsEndOnly() throws {
        let filler = #"{"type":"progress","note":"padding padding padding padding padding padding padding padding"}"#
        let padding = Array(repeating: filler, count: 2 * Constants.Limits.modelProbeBytes / filler.utf8.count)
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript([answer("claude-opus-5-5")] + padding)) == nil)
        #expect(TranscriptReader.lastModel(transcriptPath: try transcript(padding + [answer("claude-opus-5-5")])) == "claude-opus-5-5")
    }

    /// The listing is refreshed every few seconds; a transcript is read again only when it changed.
    @Test func theModelIsReadAgainOnlyWhenTheTranscriptChanged() throws {
        let path = try transcript([prompt, answer("claude-haiku-5-5")])
        let reads = ReadCount()
        let registry = SessionRegistry(replyReader: { _ in nil }, answerProbe: { _, _ in true },
                                       modelProbe: { reads.add(); return TranscriptReader.lastModel(transcriptPath: $0) })
        #expect(registry.model("s", transcriptPath: path) == "claude-haiku-5-5")
        #expect(registry.model("s", transcriptPath: path) == "claude-haiku-5-5")
        #expect(reads.count == 1)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + answer("claude-opus-5-5")).utf8))
        try handle.close()
        #expect(registry.model("s", transcriptPath: path) == "claude-opus-5-5")
        #expect(reads.count == 2)
    }

    /// A chat's model comes with its run's stream.
    @Test func aChatTakesTheModelOfItsAnswer() {
        let out = #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Hi."}]}}"# + "\n"
            + #"{"type":"result","is_error":false,"result":"Hi.","session_id":"aaaaaaaa-0000-4000-8000-000000000001"}"# + "\n"
        #expect(Engine.parseStream(Data(out.utf8)).model == "claude-opus-5-5")
        let record = { () -> ChatRecord in
            var r = ChatRecord(id: Constants.Chat.generalId, name: nil)
            r.lastModel = "claude-opus-5-5"
            return r
        }()
        #expect(record.session.model == "claude-opus-5-5")
    }
}

private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
