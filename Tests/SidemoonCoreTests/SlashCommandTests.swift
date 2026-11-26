import Foundation
import Testing
@testable import SidemoonCore

@Suite struct SlashCommandTests {
    @Test func whatIsACommand() {
        #expect(SlashCommand.parse("/model opus") == SlashCommand(name: "model", arguments: "opus"))
        #expect(SlashCommand.parse("/compact") == SlashCommand(name: "compact", arguments: ""))
        #expect(SlashCommand.parse("  /model   opus 5.5  ") == SlashCommand(name: "model", arguments: "opus 5.5"))
        #expect(SlashCommand.parse("/plugin:do-it now")?.name == "plugin:do-it")
        #expect(SlashCommand.parse("/add-dir ../x")?.name == "add-dir")
        #expect(SlashCommand.parse("/model\nopus")?.arguments == "opus")
        // Not commands.
        #expect(SlashCommand.parse("/ not a command") == nil)
        #expect(SlashCommand.parse("/Users/me/file.txt is broken") == nil)
        #expect(SlashCommand.parse("/tmp/x") == nil)
        #expect(SlashCommand.parse("/1abc") == nil)
        #expect(SlashCommand.parse("please run /compact") == nil)
        #expect(SlashCommand.parse("why does a/b fail?") == nil)
        #expect(SlashCommand.parse("") == nil && SlashCommand.parse("/") == nil)
        #expect(SlashCommand.parse("/model")?.is("MODEL") == true)
    }

    /// The command reaches Claude Code exactly as typed: the reply-style note or tag is left off.
    @Test func aCommandIsSentWithoutTheStyleNote() throws {
        let runner = ChatRunnerForCommands()
        let e = Engine(socketPath: "/tmp/unused-\(UUID().uuidString).sock", runner: runner, chats: .inMemory(),
                       chatFolder: FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-cmd-\(UUID().uuidString)").path)
        _ = e.send(SendRequest(session: Constants.Chat.generalId, text: "/compact", wait: true, styleNote: "[via Sidemoon]"))
        _ = e.send(SendRequest(session: Constants.Chat.generalId, text: "hello", wait: true, styleNote: "[via Sidemoon]"))
        let inputs = runner.inputs
        #expect(inputs.count == 2)
        #expect(inputs[0].contains("\"text\":\"\\/compact\"") && !inputs[0].contains("via Sidemoon"))
        #expect(inputs[1].contains("via Sidemoon"))
        // With a screenshot or a file: refused before anything runs.
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-cmd-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        #expect(e.send(SendRequest(session: Constants.Chat.generalId, imagePaths: [image.path], text: "/compact")).failure
                == .commandWithAttachments)
        #expect(runner.inputs.count == 2)
    }
}

/// Answers every chat run; keeps what each was given on stdin.
private final class ChatRunnerForCommands: ClaudeRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var stdins: [String] = []
    func run(_ args: [String], cwd: String?, stdin: Data?, timeout: TimeInterval) -> ProcessResult {
        if let stdin { lock.withLock { stdins.append(String(decoding: stdin, as: UTF8.self)) } }
        let out = #"{"type":"result","is_error":false,"result":"ok","session_id":"aaaaaaaa-0000-4000-8000-000000000001"}"# + "\n"
        return ProcessResult(status: 0, stdout: Data(out.utf8), stderr: Data(), timedOut: false)
    }
    var inputs: [String] { lock.withLock { stdins } }
}
