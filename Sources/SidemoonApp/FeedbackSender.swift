import AppKit
import SidemoonCompanion
import SidemoonCore

/// Gathers the versions a report mentions and opens it for the user to send. Nothing is sent from here.
@MainActor
enum FeedbackSender {
    static func send(_ route: FeedbackRoute) {
        Task {
            let claude = await Task.detached { claudeVersion() }.value
            let details = FeedbackDetails(system: ProcessInfo.processInfo.operatingSystemVersionString,
                                          processor: processor, claudeCode: claude)
            guard let url = Feedback.url(route, details) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private static var processor: String {
        #if arch(arm64)
        Design.Copy.Feedback.appleSilicon
        #else
        Design.Copy.Feedback.intel
        #endif
    }

    private nonisolated static func claudeVersion() -> String? {
        let c = CompanionConstants.Feedback.self
        let result = SystemClaudeRunner().run(c.claudeVersionArguments, cwd: nil, stdin: Data(), timeout: c.claudeVersionTimeout)
        guard result.status == 0 else { return nil }
        return FeedbackDetails.claudeVersion(fromOutput: result.stdoutText)
    }
}
