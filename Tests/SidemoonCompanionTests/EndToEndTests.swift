import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

/// Opt-in end-to-end run through the app's view model against a real, throwaway Claude Code session.
/// It creates that session itself (headless, in the given scratch project) and targets nothing else.
///
///   SIDEMOON_E2E_PROJECT=<scratch project with Sidemoon hooks in .claude/settings.json>
///   SIDEMOON_E2E_IMAGE=<png showing one word>  SIDEMOON_E2E_WORD=<that word>  swift test --filter EndToEnd
///
/// Uses the real engine socket, so no other Sidemoon engine may be running.
enum E2E {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["SIDEMOON_E2E_PROJECT"] != nil && env["SIDEMOON_E2E_IMAGE"] != nil && env["SIDEMOON_E2E_WORD"] != nil }
    static let model = "haiku"
    static let followUpWord = "BANANA"
}

@MainActor
@Suite(.serialized) struct EndToEndTests {
    private func claude(_ args: [String], cwd: String) async -> ProcessResult {
        await Task.detached { SystemClaudeRunner().run(args, cwd: cwd, stdin: Data(), timeout: 180) }.value
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return true
    }

    @Test(.enabled(if: E2E.enabled)) func screenshotReachesSessionAndReplyReachesBubble() async throws {
        let project = E2E.env["SIDEMOON_E2E_PROJECT"]!
        let image = URL(fileURLWithPath: E2E.env["SIDEMOON_E2E_IMAGE"]!)
        let word = E2E.env["SIDEMOON_E2E_WORD"]!
        let defaults = UserDefaults(suiteName: "sidemoon-e2e-\(UUID().uuidString)")!
        let store = CaptureStore()
        let model = CompanionModel(engine: InProcessEngine(), capture: InjectedImageCapture(source: image),
                                   store: store, defaults: defaults)
        model.startEngine()
        #expect(model.engineState == .running)
        defer { model.stopEngine() }

        // 1. A throwaway session of our own.
        let first = await claude(["-p", "--model", E2E.model, "--output-format", "json", "Reply with only the word READY."], cwd: project)
        let json = try JSONSerialization.jsonObject(with: first.stdout) as? [String: Any]
        let sid = try #require((json?["session_id"] as? String)?.lowercased())
        print("e2e: created throwaway session \(sid)")
        let ended = await waitFor(60) { model.sessions.first { $0.id == sid }?.state == .ended }
        try #require(ended, "hooks never reported the throwaway session ending")
        #expect(!model.rows.contains { $0.id == sid })  // ended sessions are hidden by default
        model.selectTarget(sid)
        #expect(model.target?.routes == [.headless])

        // 2. Note hotkey path with an injected capture.
        model.beginNote()
        model.noteDraft = "What single word is written in this image? Reply with only that word."
        let note = model.finishNote()
        model.closeBubble()
        await model.captureAndSend(note: note)
        print("e2e: reply via model = \(model.latestReply ?? "nil"), status = \(model.status), error = \(String(describing: model.currentError))")
        #expect(model.currentError == nil)
        #expect(model.latestReply?.uppercased().contains(word.uppercased()) == true)
        #expect(model.indicator == .replyReady)
        #expect(store.files().isEmpty, "capture file should be deleted after delivery")
        model.openBubble()
        #expect(model.indicator == .idle)

        // 3. A turn Sidemoon did not trigger still lands in the bubble.
        let ext = await claude(["-p", "--resume", sid, "--model", E2E.model, "--output-format", "json",
                                "Reply with only the word \(E2E.followUpWord)."], cwd: project)
        #expect(ext.status == 0)
        let arrived = await waitFor(60) { model.latestReply?.uppercased().contains(E2E.followUpWord) == true }
        print("e2e: after external turn, model reply = \(model.latestReply ?? "nil"), indicator = \(model.indicator)")
        #expect(arrived)
        #expect(model.indicator == .replyReady)
    }
}
