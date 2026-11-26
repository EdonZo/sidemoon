import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let project = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"

@MainActor
func commandModel(_ engine: FakeEngine, defaults: UserDefaults? = nil) -> (CompanionModel, CaptureStore, UserDefaults) {
    let d = defaults ?? UserDefaults(suiteName: "sidemoon-cmd-\(UUID().uuidString)")!
    let store = scratchStore()
    let m = CompanionModel(engine: engine, capture: FakeCapture(), windowCapture: FakeCapture(), store: store, defaults: d,
                           sleeper: { _ in await Task.yield() })
    m.startEngine()
    return (m, store, d)
}

func projectSession() -> Session {
    var s = Session(id: project)
    s.cwd = "/tmp/proj"
    s.channelConnected = true
    s.lastEventAt = Date()
    return s
}

func chatSession(_ id: String = Constants.Chat.generalId) -> Session {
    var s = Session(id: id)
    s.kind = .chat
    return s
}

@MainActor
@Suite struct CommandTests {
    /// A command goes exactly as typed: with short replies on, no note and no tag.
    @Test func aCommandCarriesNoStyleNote() async {
        let engine = FakeEngine()
        engine.list = [projectSession()]
        let (m, _, _) = commandModel(engine)
        m.selectTarget(project)
        #expect(m.shortReplies)
        await m.sendMessage("/compact")
        await m.sendMessage("hello")
        #expect(engine.sent.map(\.text) == ["/compact", "hello"])
        #expect(engine.sent[0].styleNote == nil && engine.sent[1].styleNote != nil)
        // The full note is still due with the first real message.
        #expect(engine.sent[1].styleNote == CompanionConstants.Messages.replyStyleNote)
    }

    /// Return on a command while screenshots wait: nothing is sent, nothing is dropped, and the user is told.
    @Test func aCommandWithScreenshotsWaitingIsNotSent() async {
        let engine = FakeEngine()
        engine.list = [projectSession()]
        let (m, store, _) = commandModel(engine)
        m.selectTarget(project)
        let task = Task { await m.captureActiveWindowAndSend() }
        while !m.isHoldingCapture { await Task.yield() }
        m.noteDraft = "/compact"
        m.submitHeldCapture()
        #expect(engine.sent.isEmpty && m.isHoldingCapture && store.files().count == 1)
        #expect(m.holdNotice == Design.Copy.Commands.notWithAttachments && m.noteCountdown == nil)
        // Typing words instead sends the screenshot with them.
        m.noteDraft = "look at this"
        #expect(m.holdNotice == nil)
        m.submitHeldCapture()
        await task.value
        #expect(engine.sent.first?.text == "look at this" && engine.sent.first?.allImagePaths.count == 1)
    }

    @Test func theEnginesRefusalIsPlain() {
        let e = CompanionError.from(.failure(.commandWithAttachments))
        #expect(e == .commandWithAttachments && !e.canRetry && !e.threadNote.contains("/"))
    }
}

@Suite struct ModelNameTests {
    @Test func idsReadAsNames() {
        #expect(ModelName.short("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.short("claude-fable-5-2") == "Fable 5.2")
        #expect(ModelName.short("claude-haiku-5-5-20261001") == "Haiku 5.5")
        #expect(ModelName.short("claude-sonnet-4-20250514") == "Sonnet 4")
        #expect(ModelName.short("claude-opus-4") == "Opus 4")
        #expect(ModelName.short("claude-opus-5-5[1m]") == "Opus 5.5")
        // Not the pattern: as it is, shortened when long.
        #expect(ModelName.short("claude-3-5-sonnet-20241022").hasPrefix("claude-3-5-sonnet"))
        #expect(ModelName.short("claude-3-5-sonnet-20241022").count == CompanionConstants.Chat.rawModelCharacters + 1)
        #expect(ModelName.short("gpt-5") == "gpt-5")
        #expect(ModelName.short("") == "")
    }

    /// A chat shows the model chosen for chats; on the default, the one its last answer came from, else "default".
    /// Another session shows only what its transcript says.
    @Test func whatEachSessionShows() {
        var chat = chatSession()
        #expect(SessionList.modelLabel(chat, chatModel: .standard) == Design.Copy.ChatModels.defaultLabel)
        chat.model = "claude-opus-5-5"
        #expect(SessionList.modelLabel(chat, chatModel: .standard) == "Opus 5.5")
        #expect(SessionList.modelLabel(chat, chatModel: ChatModel(alias: "haiku")) == "Haiku")
        var project = projectSession()
        #expect(SessionList.modelLabel(project, chatModel: ChatModel(alias: "haiku")) == nil)
        project.model = "claude-fable-5-2"
        project.name = "api work"
        let rows = SessionList.rows([project, chat], showEnded: false, chatModel: ChatModel(alias: "haiku"))
        #expect(rows.first { $0.id == project.id }?.detail == "proj" + CompanionConstants.Chat.detailSeparator + "Fable 5.2")
        #expect(rows.first { $0.isChat }?.detail == "Haiku")
    }
}

@Suite struct ChatModelLogicTests {
    @Test func theChoicesComeFromTheConstants() {
        #expect(ChatModel.all.map(\.alias) == [nil] + CompanionConstants.Chat.modelAliases)
        #expect(ChatModel.all.map(\.title) == [Design.Copy.ChatModels.defaultChoice, "Opus", "Sonnet", "Haiku"])
        #expect(ChatModel(saved: "opus")?.alias == "opus" && ChatModel(saved: "default") == .standard)
        #expect(ChatModel(saved: "gpt") == nil && ChatModel(saved: nil) == nil)
    }

    @Test func namesAreMatchedForgivingly() {
        #expect(ChatModel.match("opus")?.alias == "opus")
        #expect(ChatModel.match("Opus 5.5")?.alias == "opus")
        #expect(ChatModel.match("claude-opus-5-5")?.alias == "opus")
        #expect(ChatModel.match("SONNET")?.alias == "sonnet")
        #expect(ChatModel.match("haiku please")?.alias == "haiku")
        #expect(ChatModel.match("Default") == .standard)
        #expect(ChatModel.match("gpt-5") == nil && ChatModel.match("") == nil)
        // A word that only contains a family name is not one.
        #expect(ChatModel.match("opusculum") == nil)
    }

    @Test func theModelCommand() {
        #expect(ChatModelCommand.parse("/model opus 5.5") == .set(ChatModel(alias: "opus")))
        #expect(ChatModelCommand.parse("/MODEL default") == .set(.standard))
        #expect(ChatModelCommand.parse("/model") == .show)
        #expect(ChatModelCommand.parse("/model banana") == .show)
        #expect(ChatModelCommand.parse("/compact") == nil && ChatModelCommand.parse("model opus") == nil)
    }
}

@MainActor
@Suite struct ChatModelSettingTests {
    /// In a chat, /model is Sidemoon's: the setting changes and is confirmed, and nothing goes to Claude Code.
    @Test func modelInAChatSetsTheChatModel() async {
        let engine = FakeEngine()
        engine.list = [chatSession()]
        let (m, _, d) = commandModel(engine)
        await m.sendMessage("/model opus 5.5")
        #expect(engine.sent.isEmpty)
        #expect(m.chatModel.alias == "opus" && d.string(forKey: CompanionConstants.Defaults.chatModel) == "opus")
        #expect(m.thread.map(\.text) == ["/model opus 5.5", Design.Copy.ChatModels.nowUsing("Opus")])
        // The next message runs with it, and so does the one after a restart.
        await m.sendMessage("hello")
        #expect(engine.sent.last?.model == "opus")
        let (again, _, _) = commandModel(engine, defaults: d)
        #expect(again.chatModel.alias == "opus")
    }

    @Test func modelAloneOrUnknownSaysWhatIsInUse() async {
        let engine = FakeEngine()
        engine.list = [chatSession()]
        let (m, _, _) = commandModel(engine)
        await m.sendMessage("/model")
        await m.sendMessage("/model banana")
        let expected = Design.Copy.ChatModels.current(Design.Copy.ChatModels.defaultName, choices: ["default", "opus", "sonnet", "haiku"])
        #expect(m.thread.filter { $0.role == .session }.map(\.text) == [expected, expected])
        #expect(engine.sent.isEmpty && m.chatModel == .standard)
    }

    /// In a project session Claude Code handles /model itself: passed through untouched, and no model is attached.
    @Test func modelInAProjectSessionGoesToClaudeCode() async {
        let engine = FakeEngine()
        engine.list = [projectSession(), chatSession()]
        let (m, _, _) = commandModel(engine)
        m.setChatModel(ChatModel(alias: "haiku"))
        m.selectTarget("0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01")
        await m.sendMessage("/model opus")
        await m.sendMessage("hi")
        #expect(engine.sent.map(\.text) == ["/model opus", "hi"])
        #expect(engine.sent.allSatisfy { $0.model == nil } && engine.sent[0].styleNote == nil)
        #expect(m.chatModel.alias == "haiku")
    }

    /// Claude Code cannot use the model: said plainly, with the way back to the default.
    @Test func anUnavailableModelOffersTheDefault() async {
        let engine = FakeEngine()
        engine.list = [chatSession()]
        engine.reply = { r in .failure(.modelUnavailable(r.model ?? "-"), sessionId: r.session, route: .headless) }
        let (m, _, _) = commandModel(engine)
        m.setChatModel(ChatModel(alias: "opus"))
        await m.sendMessage("hello")
        #expect(m.currentError == .modelUnavailable("opus"))
        #expect(m.currentError?.title == Design.Copy.ChatModels.unavailableTitle("Opus"))
        #expect(m.remedies(for: .modelUnavailable("opus")) == [.useDefaultChatModel])
    }
}
