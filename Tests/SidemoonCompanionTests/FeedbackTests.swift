import Foundation
import Testing
@testable import SidemoonCompanion

@Suite struct FeedbackTests {
    private let details = FeedbackDetails(appVersion: "1.0.2", appBuild: "6", system: "macOS 26.2", processor: "Apple Silicon",
                                          claudeCode: "2.1.330 (Claude Code)")

    @Test func detailsReadAsOneLine() {
        #expect(details.line == "Sidemoon 1.0.2 (6) · macOS 26.2 · Apple Silicon · Claude Code 2.1.330 (Claude Code)")
        var unknown = details
        unknown.claudeCode = nil
        #expect(unknown.line.hasSuffix("Claude Code unknown"))
    }

    @Test func claudeVersionIsTheFirstLineOnly() {
        #expect(FeedbackDetails.claudeVersion(fromOutput: "2.1.330 (Claude Code)\nextra\n") == "2.1.330 (Claude Code)")
        #expect(FeedbackDetails.claudeVersion(fromOutput: "  \n") == nil)
        #expect(FeedbackDetails.claudeVersion(fromOutput: "") == nil)
        let long = String(repeating: "x", count: 500)
        #expect(FeedbackDetails.claudeVersion(fromOutput: long)?.count == CompanionConstants.Feedback.claudeVersionMaxLength)
    }

    @Test func issueOpensOnThePublicTrackerFilledIn() throws {
        let url = try #require(Feedback.issueURL(details))
        #expect(url.absoluteString.hasPrefix(CompanionConstants.Feedback.issuesURL + "?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try #require(items.first { $0.name == CompanionConstants.Feedback.issueBodyParameter }?.value)
        #expect(body == Feedback.body(details))
        #expect(body.contains(details.line))
        #expect(body.contains(Design.Copy.Feedback.whatHappened))
    }

    @Test func mailIsAddressedAndKeepsItsSpaces() throws {
        let url = try #require(Feedback.mailURL(details))
        let text = url.absoluteString
        #expect(text.hasPrefix("mailto:\(CompanionConstants.Feedback.emailAddress)?"))
        // A space must travel as %20: mail apps show "+" as a plus sign.
        #expect(!text.contains("+"))
        #expect(text.contains("subject=Sidemoon%20feedback"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == CompanionConstants.Feedback.mailBodyParameter }?.value == Feedback.body(details))
    }

    /// The report holds versions only: no user name, no paths, no session names.
    @Test func nothingPersonalIsAdded() {
        let body = Feedback.body(details)
        #expect(!body.contains(NSUserName()))
        #expect(!body.contains(NSHomeDirectory()))
    }
}
