import Foundation

extension CompanionConstants {
    /// Where feedback goes. There is no server: each route opens something the user sends themselves.
    public enum Feedback {
        /// The public issue tracker; a new issue opens already filled in.
        public static let issuesURL = "https://github.com/EdonZo/sidemoon/issues/new"
        public static let issueTitleParameter = "title"
        public static let issueBodyParameter = "body"
        /// The address the email route writes to.
        public static let emailAddress = "edon@dardanlabs.com"
        public static let mailScheme = "mailto"
        public static let mailSubjectParameter = "subject"
        public static let mailBodyParameter = "body"
        /// `claude --version`, to say which Claude Code the report is about.
        public static let claudeVersionArguments = ["--version"]
        public static let claudeVersionTimeout: TimeInterval = 5
        /// Only the first line of that output is used, and no more of it than this.
        public static let claudeVersionMaxLength = 60
    }
}

extension Design.Copy {
    public enum Feedback {
        public static let title = "Feedback"
        public static let menuItem = "Send Feedback…"
        public static let onGitHub = "Report on GitHub"
        public static let onGitHubHelp = "Opens a new issue in your browser, filled in with your versions. You press Submit."
        public static let byEmail = "Email us"
        public static let byEmailHelp = "Opens a message in your mail app, filled in with your versions. You press Send."
        public static var subject: String { "\(CompanionConstants.App.name) feedback" }
        public static let whatHappened = "What happened:"
        public static let whatExpected = "What I expected:"
        public static let detailsNote = "Details (added by Sidemoon; delete anything you do not want to share):"
        public static let unknown = "unknown"
        public static let appleSilicon = "Apple Silicon"
        public static let intel = "Intel"
    }
}

/// What a feedback report says about the Mac it comes from. Nothing else is collected, and nothing is sent
/// by Sidemoon: the user sees the text and sends it.
public struct FeedbackDetails: Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var system: String
    public var processor: String
    public var claudeCode: String?

    public init(appVersion: String = CompanionConstants.App.version, appBuild: String = CompanionConstants.App.build,
                system: String, processor: String, claudeCode: String?) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.system = system
        self.processor = processor
        self.claudeCode = claudeCode
    }

    /// One line, for example "Sidemoon 1.0.2 (6) · macOS 26.2 · Apple Silicon · Claude Code 2.1.330".
    public var line: String {
        ["\(CompanionConstants.App.name) \(appVersion) (\(appBuild))", system, processor,
         "Claude Code \(claudeCode ?? Design.Copy.Feedback.unknown)"].joined(separator: " · ")
    }

    /// The first line of `claude --version`, shortened; nil when there is nothing usable.
    public static func claudeVersion(fromOutput output: String) -> String? {
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? nil : String(first.prefix(CompanionConstants.Feedback.claudeVersionMaxLength))
    }
}

/// The two ways a report can be sent; in both the user presses the final button.
public enum FeedbackRoute: Sendable { case gitHub, email }

public enum Feedback {
    public static func url(_ route: FeedbackRoute, _ details: FeedbackDetails) -> URL? {
        switch route {
        case .gitHub: return issueURL(details)
        case .email: return mailURL(details)
        }
    }

    /// The text a report starts from: two prompts to fill in, then the details.
    public static func body(_ details: FeedbackDetails) -> String {
        let copy = Design.Copy.Feedback.self
        return "\(copy.whatHappened)\n\n\n\(copy.whatExpected)\n\n\n\(copy.detailsNote)\n\(details.line)\n"
    }

    /// A new issue on the public tracker, already filled in.
    public static func issueURL(_ details: FeedbackDetails) -> URL? {
        let c = CompanionConstants.Feedback.self
        var parts = URLComponents(string: c.issuesURL)
        parts?.queryItems = [URLQueryItem(name: c.issueTitleParameter, value: ""),
                             URLQueryItem(name: c.issueBodyParameter, value: body(details))]
        return parts?.url
    }

    /// A message in the user's mail app, already addressed and filled in.
    public static func mailURL(_ details: FeedbackDetails) -> URL? {
        let c = CompanionConstants.Feedback.self
        var parts = URLComponents()
        parts.scheme = c.mailScheme
        parts.path = c.emailAddress
        parts.queryItems = [URLQueryItem(name: c.mailSubjectParameter, value: Design.Copy.Feedback.subject),
                            URLQueryItem(name: c.mailBodyParameter, value: body(details))]
        // Mail clients read "+" in a mailto link as a plus sign, so spaces must be %20.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}
