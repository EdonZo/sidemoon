import AppKit
import SwiftUI
import SidemoonCompanion
import SidemoonCore

/// A stand-in engine for previews: one session whose answers take a while.
final class PreviewEngine: CompanionEngine, @unchecked Sendable {
    static let answerDelay: TimeInterval = 30
    static let session: Session = {
        var s = Session(id: "00000000-0000-4000-8000-000000000001")
        s.name = "website-redesign"
        s.cwd = "/tmp/preview"
        s.channelConnected = true
        s.lastEventAt = Date()
        s.lastReply = "Open the billing page and show me what plan you are on."
        return s
    }()

    /// A handful of sessions in different states, for the picker.
    static let several: [Session] = {
        func make(_ suffix: String, _ name: String, _ folder: String, _ state: SessionState, _ kind: SessionKind, age: TimeInterval) -> Session {
            var s = Session(id: "00000000-0000-4000-8000-0000000000\(suffix)")
            s.name = name
            s.cwd = "/Users/me/Projects/\(folder)"
            s.state = state
            s.kind = kind
            s.lastEventAt = Date().addingTimeInterval(-age)
            return s
        }
        return [
            session,
            make("02", "API-SERVER", "api-server", .working, .background, age: 20),
            make("03", "mobile app redesign", "Projects", .idle, .background, age: 60),
            make("04", "Notes - Revisit", "notes", .needsInput, .background, age: 90),
            make("05", "scratch terminal", "notes", .idle, .interactive, age: 120),
        ]
    }()

    /// Sessions Claude Code would not reopen, next to ones that are fine, for the greyed rows of the picker.
    static let withUnreachable: [Session] = {
        func make(_ suffix: String, _ name: String, _ cwd: String, _ blocker: ResumeBlocker?, age: TimeInterval) -> Session {
            var s = Session(id: "00000000-0000-4000-8000-0000000001\(suffix)")
            s.name = name
            s.cwd = cwd
            s.kind = .background
            s.blocker = blocker
            s.lastEventAt = Date().addingTimeInterval(-age)
            return s
        }
        return [
            session,
            make("02", "api-server", "/Users/me/Projects/api-server", nil, age: 30),
            make("03", "quick question", "/Users/me", .homeFolder, age: 60),
            make("04", "billing-service", "/Users/me/Projects/billing-service", .loginNeeded, age: 90),
            make("05", "design-notes", "/Users/me/Projects/design-notes", .noTranscript, age: 120),
        ]
    }()

    /// A background session whose folder was deleted.
    static let goneFolder = "/Users/me/Projects/old-prototype"
    static let folderGone: Session = {
        var s = Session(id: "00000000-0000-4000-8000-000000000201")
        s.name = "old-prototype"
        s.cwd = goneFolder
        s.kind = .background
        s.lastEventAt = Date().addingTimeInterval(-15)
        return s
    }()

    /// A terminal session started with plain claude.
    static let plainTerminal: Session = {
        var s = Session(id: "00000000-0000-4000-8000-000000000202")
        s.name = "notes"
        s.cwd = "/Users/me/Projects/notes"
        s.kind = .interactive
        s.lastEventAt = Date().addingTimeInterval(-10)
        return s
    }()

    private let list: [Session]
    private let delay: TimeInterval
    private let failure: DeliveryError?
    /// `failure`: every send fails this way at once, with Claude Code's words as the detail.
    init(sessions: [Session], delay: TimeInterval = PreviewEngine.answerDelay, failure: DeliveryError? = nil) {
        list = sessions
        self.delay = delay
        self.failure = failure
    }

    func start() throws -> EngineStartOutcome { .running }
    func stop() {}
    func sessions() -> [Session] { list }
    func subscribe(_ handler: @escaping @Sendable (Session) -> Void) {}
    func send(_ request: SendRequest) -> SendResult {
        if let failure {
            var r = SendResult(ok: false, sessionId: request.session, route: .background, reply: nil,
                               error: failure.description, detail: Preview.refusalDetail)
            r.failure = failure
            return r
        }
        Thread.sleep(forTimeInterval: delay)
        return SendResult(ok: true, sessionId: request.session, route: .channel, reply: "Team.", error: nil, detail: nil)
    }

    /// What starting a new session does in the previews: fails this way, or takes `delay` and starts nothing.
    var startFailure: NewSessionError?
    var homeRefused = false
    func startSession(_ request: NewSessionRequest) -> NewSessionResult {
        if let startFailure { return NewSessionResult(sessionId: nil, failure: startFailure, detail: Preview.startDetail) }
        Thread.sleep(forTimeInterval: delay)
        return NewSessionResult(sessionId: nil, failure: .notConfirmed, detail: nil)
    }
    func homeFolderRefused() -> Bool { homeRefused }
}

/// Stand-ins for the setup's side effects, so previews never touch the real system.
struct PreviewClaudeFinder: ClaudeFinder {
    /// False: only the login shell finds `claude`, somewhere the engine does not look, and ~/.local/bin is not on PATH.
    let usual: Bool
    func lookup() -> ClaudeLookup {
        usual
            ? ClaudeLookup(enginePath: "/Users/me/.local/bin/claude", loginShellPath: nil, pathEntries: ["/Users/me/.local/bin", "/usr/bin"])
            : ClaudeLookup(enginePath: nil, loginShellPath: "/Users/me/.npm-global/bin/claude", pathEntries: ["/Users/me/.npm-global/bin"])
    }
}

struct PreviewHooks: HooksService {
    enum Mode { case none, ours, otherCopy }
    let mode: Mode
    let settingsPath = "/Users/me/.claude/settings.json"
    func status() throws -> HooksInstaller.Status {
        switch mode {
        case .none: return .init(installed: [], missing: Constants.Hooks.events, commands: [])
        case .ours: return .init(installed: Constants.Hooks.events, missing: [], commands: [command(for: Preview.helper)])
        case .otherCopy:
            return .init(installed: Constants.Hooks.events, missing: [], commands: [command(for: "/Users/me/.local/bin/sidemoon")])
        }
    }
    func install(helper: String) throws -> HooksInstaller.Outcome { .init(changed: false, backupPath: nil) }
    func uninstall() throws -> HooksInstaller.Outcome { .init(changed: false, backupPath: nil) }
    func command(for helper: String) -> String { HooksInstaller(settingsPath: settingsPath, executablePath: helper).hookCommand }
}

struct PreviewFiles: SetupFiles {
    let contents: [String: Data]
    func exists(_ path: String) -> Bool { contents[path] != nil }
    func isExecutable(_ path: String) -> Bool { path.hasPrefix("/Users/me/.local/bin") }
    func read(_ path: String) -> Data? { contents[path] }
    func createDirectory(_ path: String, permissions: Int) throws {}
    func write(_ data: Data, to path: String, permissions: Int) throws {}
}

struct PreviewPermission: ScreenCapturePermission {
    let granted: Bool
    func isGranted() -> Bool { granted }
    func request() {}
    func openSettings() {}
}

struct PreviewRelauncher: AppRelauncher {
    var canRelaunch: Bool { true }
    func relaunch() {}
}

/// `SidemoonApp --render-preview <directory>` writes PNGs of the mascot states and a formatted reply,
/// in light and dark, so the design can be checked without running the companion.
@MainActor
enum Preview {
    static let settleTime: TimeInterval = 0.4
    static let largeMascot: CGFloat = 128
    static let sample = """
    # Next step
    Open **Settings**, then choose *Privacy & Security*. The switch you want is `Screen Recording`; see [the guide](https://example.com).

    ## What I can see
    - The sign-up form is filled in
      - except the phone number
    - The **Continue** button is disabled

    1. Enter the phone number
    2. Tick the terms box
    3. Press Continue

    > If a code is sent to your phone, show me the next screen.

    ```sh
    open ~/Applications/Sidemoon.app
    ```

    | Field | State |
    |---|---|
    | Email | filled |
    | Phone | **missing** |

    ---
    ### Note
    Nothing was sent to the site yet.
    """

    static func render(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var halfway = NoteCountdown()
        for _ in 0..<(halfway.totalTicks / 3) { halfway.tick() }
        let states: [MascotState] = [.idle, .capturing, .holding, .sending, .waiting, .reply, .error]

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let mascots = VStack(spacing: Design.Space.xxl) {
                HStack(spacing: Design.Space.xl) {
                    ForEach(states, id: \.label) { MascotFigure(state: $0, countdown: $0 == .holding ? halfway : nil) }
                }
                HStack(spacing: Design.Space.xl) {
                    ForEach(states, id: \.label) {
                        MascotFigure(state: $0, countdown: $0 == .holding ? halfway : nil, side: largeMascot)
                    }
                }
            }
            .padding(Design.Space.xxl)
            .background(Color(nsColor: .windowBackgroundColor))
            snapshot(mascots, dark: dark, to: dir.appendingPathComponent("mascot-\(suffix).png"))

            let reply = MarkdownView(sample)
                .padding(.horizontal, Design.Space.bubbleHorizontal)
                .padding(.vertical, Design.Space.bubbleVertical)
                .frame(width: Design.Bubble.width)
                .background(Color.paper)
            snapshot(reply, dark: dark, to: dir.appendingPathComponent("reply-\(suffix).png"))

            let now = Date()
            let entries = [
                ThreadEntry(role: .session, text: "Open the billing page and show me what plan you are on.", date: now),
                ThreadEntry(role: .you, text: "", attachments: [CompanionConstants.Messages.captureAttachmentName], date: now),
                ThreadEntry(role: .session, text: "You are on **Starter**. Click `Upgrade`, then pick *Team*:\n\n1. Choose yearly billing\n2. Show me the summary before you pay", date: now),
                ThreadEntry(role: .you, text: "is this the right invoice?", attachments: ["invoice-november.pdf", "terms.txt"], date: now,
                            delivery: .sending),
                ThreadEntry(role: .you, text: "and this one", date: now, delivery: .failed(CompanionError.busy.title)),
            ]
            let thread = VStack(alignment: .leading, spacing: Design.Bubble.entrySpacing) {
                ForEach(entries) { ThreadEntryView(entry: $0, sessionName: "website-redesign") }
            }
            .padding(.horizontal, Design.Space.bubbleHorizontal)
            .padding(.vertical, Design.Space.bubbleVertical)
            .frame(width: Design.Bubble.width)
            .background(Color.paper)
            snapshot(thread, dark: dark, to: dir.appendingPathComponent("thread-\(suffix).png"))

            let noop = BubbleActions(showMenu: {}, copyReply: {}, capture: {}, submitNote: {}, cancelNote: {}, close: {},
                                     dropFiles: { _ in })
            let scratch = CaptureStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sidemoon-preview-\(UUID().uuidString)", isDirectory: true))

            let empty = CompanionModel(engine: PreviewEngine(sessions: []), capture: ScreencaptureProvider(), store: scratch)
            bubbleSnapshot(empty, actions: noop, dark: dark, to: dir.appendingPathComponent("bubble-empty-\(suffix).png"))

            let picking = CompanionModel(engine: PreviewEngine(sessions: PreviewEngine.several), capture: ScreencaptureProvider(),
                                         store: scratch)
            picking.startEngine()
            picking.selectTarget(PreviewEngine.session.id)
            let picker = SessionPicker(model: picking) {}
                .padding(.horizontal, Design.Space.bubbleHorizontal)
                .padding(.vertical, Design.Space.bubbleVertical)
                .frame(width: Design.Bubble.width)
                .background(Color.paper)
            snapshot(picker, dark: dark, to: dir.appendingPathComponent("picker-\(suffix).png"))

            // A wide table with long last-column notes, the case that used to overlap.
            let wide = """
            | Name | .ai | .com | .dev | .app | Notes |
            |---|---|---|---|---|---|
            | **Quasimoon** | free | taken | free | free | Best story, fits the mascot, no GitHub collision |
            | **Coorbit** | free | taken | free | free | Shares your orbit. Short and techy, but spelling it aloud is awkward |
            | **Minimoon** | free | taken | taken | taken | Good name, but only one ending is open |
            """
            for theme in Design.Theme.allCases {
                picking.setTheme(theme)
                let table = MarkdownView(wide)
                    .padding(.horizontal, Design.Space.bubbleHorizontal)
                    .padding(.vertical, Design.Space.bubbleVertical)
                    .frame(width: Design.Bubble.width)
                    .background(Color.paper)
                snapshot(table, dark: dark, to: dir.appendingPathComponent("table-\(theme.rawValue)-\(suffix).png"))
                let settings = SettingsView(model: picking)
                    .padding(.horizontal, Design.Space.bubbleHorizontal)
                    .padding(.vertical, Design.Space.bubbleVertical)
                    .frame(width: Design.Bubble.width)
                    .background(Color.paper)
                snapshot(settings, dark: dark, to: dir.appendingPathComponent("settings-\(theme.rawValue)-\(suffix).png"))
            }
            picking.setTheme(.paper)

            // The real bubble in the middle of a send: the sent message and the working row must both show.
            let live = CompanionModel(engine: PreviewEngine(sessions: [PreviewEngine.session]), capture: ScreencaptureProvider(),
                                      store: scratch)
            live.startEngine()
            live.selectTarget(PreviewEngine.session.id)
            Task { await live.sendMessage("Which plan should I pick for a team of five?") }
            bubbleSnapshot(live, actions: noop, dark: dark, to: dir.appendingPathComponent("bubble-sending-\(suffix).png"))

            // The setup window: a fresh Mac, one that needs attention, and one where everything is done.
            for variant in SetupVariant.allCases {
                let setup = setupModel(variant)
                RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
                snapshot(SetupContent(model: setup, actions: SetupActions(openURL: { _ in }, copy: { _ in }, start: {})),
                         dark: dark, to: dir.appendingPathComponent("setup-\(variant.rawValue)-\(suffix).png"))
            }
        }
        renderReachability(to: dir)
        renderNewSessionAndHidden(to: dir)
        // Terminal is always dark, whatever the system.
        let theme = Design.theme
        Design.theme = .terminal
        let setup = setupModel(.done)
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        snapshot(SetupContent(model: setup, actions: SetupActions(openURL: { _ in }, copy: { _ in }, start: {})),
                 dark: true, to: dir.appendingPathComponent("setup-done-terminal.png"))
        Design.theme = theme
    }

    // MARK: Sessions that cannot be reached, and the guide

    /// What Claude Code said, as the Details of a refused send show it.
    nonisolated static let refusalDetail = "resume exited 1: Workspace not trusted. The home directory is trusted one session at a time."
    /// What `claude --bg` printed, as the new-session form's Details show it.
    nonisolated static let startDetail = "claude --bg exited 1\nError: Workspace not trusted. Run claude in this folder once to trust it."

    /// The error cards, the greyed picker rows, the guide (fresh, half done, done) and the empty conversation,
    /// in each theme. Paper is drawn light, Terminal dark, Mono both.
    private static func renderReachability(to dir: URL) {
        let looks: [(Design.Theme, Bool)] = [(.paper, false), (.terminal, true), (.mono, false), (.mono, true)]
        let noop = BubbleActions(showMenu: {}, copyReply: {}, capture: {}, submitNote: {}, cancelNote: {}, close: {},
                                 dropFiles: { _ in })
        let scratch = CaptureStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sidemoon-preview-\(UUID().uuidString)", isDirectory: true))
        let session = PreviewEngine.session.id

        /// A model on its own settings, so a preview never writes to the app's.
        func model(_ engine: PreviewEngine, theme: Design.Theme, guide: Bool = false,
                   checks: PathChecks = .everythingExists) -> CompanionModel {
            let defaults = UserDefaults(suiteName: "sidemoon-preview-\(UUID().uuidString)") ?? .standard
            let m = CompanionModel(engine: engine, capture: ScreencaptureProvider(), store: scratch, defaults: defaults,
                                   pathChecks: checks)
            m.setTheme(theme)
            m.startEngine()
            if !guide { m.dismissGuide() }
            m.openBubble()
            return m
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(settleTime)) }

        for (theme, dark) in looks {
            let look = theme == .mono ? "mono-\(dark ? "dark" : "light")" : theme.rawValue

            // Each refusal as the card shows it after a failed send.
            let cases: [(String, ResumeBlocker, Bool, Bool)] = [
                ("home", .homeFolder, true, true), ("untrusted", .untrustedFolder, false, true),
                ("never-answered", .noTranscript, true, true), ("login", .loginNeeded, false, true),
                ("install", .homeFolder, false, false),
            ]
            for (name, blocker, saved, installed) in cases {
                let m = model(PreviewEngine(sessions: [PreviewEngine.session],
                                            failure: .cannotResume(blocker, messageSaved: saved)), theme: theme)
                m.terminalCommandInstalled = installed
                m.selectTarget(session)
                Task { await m.sendMessage("Which plan should I pick for a team of five?") }
                settle()
                bubbleSnapshot(m, actions: noop, dark: dark, to: dir.appendingPathComponent("error-\(name)-\(look).png"))
            }

            // A session whose folder was deleted: greyed in the list, and the card that explains it.
            let goneChecks = PathChecks(folderExists: { $0 != PreviewEngine.goneFolder }, isExecutable: { _ in true })
            let gone = model(PreviewEngine(sessions: PreviewEngine.withUnreachable + [PreviewEngine.folderGone]), theme: theme,
                             checks: goneChecks)
            gone.selectTarget(session)
            gone.openSessionList()
            bubbleSnapshot(gone, actions: noop, dark: dark, to: dir.appendingPathComponent("picker-folder-gone-\(look).png"))
            gone.pickSession(PreviewEngine.folderGone.id)
            bubbleSnapshot(gone, actions: noop, dark: dark, to: dir.appendingPathComponent("error-folder-gone-\(look).png"))

            // A plain-claude terminal session while "Connect every claude" is off: the switch is offered.
            let plain = model(PreviewEngine(sessions: [PreviewEngine.session, PreviewEngine.plainTerminal]), theme: theme)
            plain.connectsEveryClaude = false
            plain.selectTarget(session)
            plain.pickSession(PreviewEngine.plainTerminal.id)
            bubbleSnapshot(plain, actions: noop, dark: dark, to: dir.appendingPathComponent("error-plain-claude-\(look).png"))

            // The picker with the sessions that cannot be reached greyed out.
            let picking = model(PreviewEngine(sessions: PreviewEngine.withUnreachable), theme: theme)
            picking.selectTarget(session)
            picking.openSessionList()
            bubbleSnapshot(picking, actions: noop, dark: dark, to: dir.appendingPathComponent("picker-unreachable-\(look).png"))
            // Choosing one of them explains instead.
            if let blocked = PreviewEngine.withUnreachable.first(where: { $0.blocker == .homeFolder }) {
                picking.pickSession(blocked.id)
                bubbleSnapshot(picking, actions: noop, dark: dark, to: dir.appendingPathComponent("picker-chose-unreachable-\(look).png"))
            }

            // The guide: nothing done, the session picked, everything done.
            let fresh = model(PreviewEngine(sessions: [PreviewEngine.session], delay: 0), theme: theme, guide: true)
            bubbleSnapshot(fresh, actions: noop, dark: dark, to: dir.appendingPathComponent("guide-fresh-\(look).png"))
            fresh.selectTarget(session)
            bubbleSnapshot(fresh, actions: noop, dark: dark, to: dir.appendingPathComponent("guide-half-\(look).png"))
            let capture = scratch.newFileURL()
            try? scratch.prepare()
            try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: capture)
            Task {
                await fresh.send(imageAt: capture, note: nil)
                await fresh.sendMessage("Done, what next?")
            }
            settle()
            bubbleSnapshot(fresh, actions: noop, dark: dark, to: dir.appendingPathComponent("guide-done-\(look).png"))

            // The offer to move into Applications, and the same after a failed move.
            let offer = MoveState()
            snapshot(MoveView(state: offer, move: {}, notNow: {}), dark: dark, to: dir.appendingPathComponent("move-\(look).png"))
            offer.problem = Design.Copy.Move.noWritableFolder
            snapshot(MoveView(state: offer, move: {}, notNow: {}), dark: dark, to: dir.appendingPathComponent("move-failed-\(look).png"))

            // Settings, with the screen recording switch.
            let settings = model(PreviewEngine(sessions: [PreviewEngine.session]), theme: theme)
            snapshot(SettingsView(model: settings)
                .padding(.horizontal, Design.Space.bubbleHorizontal)
                .padding(.vertical, Design.Space.bubbleVertical)
                .frame(width: Design.Bubble.width)
                .background(Color.paper), dark: dark, to: dir.appendingPathComponent("settings-recording-\(look).png"))

            // A conversation with nothing in it yet.
            var quiet = PreviewEngine.session
            quiet.lastReply = nil
            let empty = model(PreviewEngine(sessions: [quiet]), theme: theme)
            empty.selectTarget(session)
            bubbleSnapshot(empty, actions: noop, dark: dark, to: dir.appendingPathComponent("empty-\(look).png"))
        }
        Design.theme = .paper
    }

    // MARK: New session and hidden sessions

    /// The "+" and a row's actions, the new-session form in each state, Undo after hiding, the list with hidden
    /// sessions shown, and the empty states, in each theme.
    private static func renderNewSessionAndHidden(to dir: URL) {
        let looks: [(Design.Theme, Bool)] = [(.paper, false), (.terminal, true), (.mono, false), (.mono, true)]
        let noop = BubbleActions(showMenu: {}, copyReply: {}, capture: {}, submitNote: {}, cancelNote: {}, close: {},
                                 dropFiles: { _ in })
        let scratch = CaptureStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sidemoon-preview-\(UUID().uuidString)", isDirectory: true))
        let session = PreviewEngine.session.id
        let hovered = PreviewEngine.several[2].id
        let home = "/Users/me"

        final class NoChooser: FolderChooser {
            func chooseFolder(startingAt: String?) async -> String? { nil }
        }
        let chooser = NoChooser()

        func model(_ engine: PreviewEngine, theme: Design.Theme) -> CompanionModel {
            let defaults = UserDefaults(suiteName: "sidemoon-preview-\(UUID().uuidString)") ?? .standard
            let m = CompanionModel(engine: engine, capture: ScreencaptureProvider(), store: scratch, defaults: defaults)
            m.homeFolder = home
            m.folderChooser = chooser
            m.setTheme(theme)
            m.startEngine()
            m.dismissGuide()
            m.openBubble()
            return m
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(settleTime)) }
        func picker(_ m: CompanionModel, hoveredRow: String? = nil) -> some View {
            SessionPicker(model: m, hoveredRow: hoveredRow) {}
                .padding(.horizontal, Design.Space.bubbleHorizontal)
                .padding(.vertical, Design.Space.bubbleVertical)
                .frame(width: Design.Bubble.width)
                .background(Color.paper)
        }

        for (theme, dark) in looks {
            let look = theme == .mono ? "mono-\(dark ? "dark" : "light")" : theme.rawValue

            // The list with its "+", and the actions of the row under the pointer.
            let listed = model(PreviewEngine(sessions: PreviewEngine.several), theme: theme)
            listed.selectTarget(session)
            snapshot(picker(listed, hoveredRow: hovered), dark: dark, to: dir.appendingPathComponent("new-picker-hover-\(look).png"))

            // Just hidden: Undo at the top. Then the list with the hidden ones shown.
            listed.openSessionList()
            listed.hideSession(PreviewEngine.several[3].id)
            listed.hideSession(hovered)
            bubbleSnapshot(listed, actions: noop, dark: dark, to: dir.appendingPathComponent("hidden-undo-\(look).png"))
            listed.showHidden = true
            bubbleSnapshot(listed, actions: noop, dark: dark, to: dir.appendingPathComponent("hidden-shown-\(look).png"))

            // No sessions at all: the guide, the companion and the list offer starting one.
            let guided = CompanionModel(engine: PreviewEngine(sessions: []), capture: ScreencaptureProvider(), store: scratch,
                                        defaults: UserDefaults(suiteName: "sidemoon-preview-\(UUID().uuidString)") ?? .standard)
            guided.setTheme(theme)
            guided.startEngine()
            guided.openBubble()
            bubbleSnapshot(guided, actions: noop, dark: dark, to: dir.appendingPathComponent("new-none-guide-\(look).png"))
            let none = model(PreviewEngine(sessions: []), theme: theme)
            bubbleSnapshot(none, actions: noop, dark: dark, to: dir.appendingPathComponent("new-none-\(look).png"))
            none.openSessionList()
            bubbleSnapshot(none, actions: noop, dark: dark, to: dir.appendingPathComponent("new-none-list-\(look).png"))

            // The form: empty (nothing to offer yet), then filled with the recent folders.
            none.openNewSession()
            bubbleSnapshot(none, actions: noop, dark: dark, to: dir.appendingPathComponent("new-form-empty-\(look).png"))
            let filled = model(PreviewEngine(sessions: PreviewEngine.several, delay: PreviewEngine.answerDelay), theme: theme)
            filled.openNewSession()
            filled.newSessionMessage = "Find out why the sign-up test fails and fix it"
            bubbleSnapshot(filled, actions: noop, dark: dark, to: dir.appendingPathComponent("new-form-filled-\(look).png"))
            // The home folder: a caution, or not allowed where this Mac refuses it.
            filled.chooseNewSessionFolder(home)
            bubbleSnapshot(filled, actions: noop, dark: dark, to: dir.appendingPathComponent("new-form-home-\(look).png"))
            let refusing = PreviewEngine(sessions: PreviewEngine.several)
            refusing.homeRefused = true
            let refused = model(refusing, theme: theme)
            refused.openNewSession()
            refused.chooseNewSessionFolder(home)
            refused.newSessionMessage = "Tidy my downloads"
            bubbleSnapshot(refused, actions: noop, dark: dark, to: dir.appendingPathComponent("new-form-home-refused-\(look).png"))
            // Starting.
            filled.chooseNewSessionFolder(PreviewEngine.several[1].cwd ?? home)
            Task { await filled.startNewSession() }
            settle()
            bubbleSnapshot(filled, actions: noop, dark: dark, to: dir.appendingPathComponent("new-form-starting-\(look).png"))

            // Each way it can fail, with Details open on the first.
            let failures: [(String, NewSessionError)] = [
                ("untrusted", .refused(.untrustedFolder)), ("login", .refused(.loginNeeded)), ("home", .homeFolderRefused),
                ("not-found", .claudeNotFound), ("folder-missing", .folderMissing("/Users/me/Projects/old")),
                ("timed-out", .timedOut), ("not-confirmed", .notConfirmed), ("failed", .failed(status: 1)),
            ]
            for (name, failure) in failures {
                let engine = PreviewEngine(sessions: PreviewEngine.several)
                engine.startFailure = failure
                let m = model(engine, theme: theme)
                m.openNewSession()
                m.newSessionMessage = "Find out why the sign-up test fails and fix it"
                Task { await m.startNewSession() }
                settle()
                bubbleSnapshot(m, actions: noop, dark: dark, to: dir.appendingPathComponent("new-error-\(name)-\(look).png"))
            }
        }
        Design.theme = .paper
    }

    // MARK: Setup

    nonisolated static let helper = "/Applications/Sidemoon.app/Contents/Helpers/sidemoon"

    /// `diskImage`: opened straight from the disk image, so the steps that change things point to the move.
    /// `shellOff` and `shellOn`: everything done, with "Connect every claude" off and on (in a scratch home folder).
    enum SetupVariant: String, CaseIterable { case fresh, attention, done, diskImage, shellOff, shellOn }

    /// A scratch home folder with a .zshrc and fish's folder, as on a Mac that has both shells.
    static func scratchHome() -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-preview-home-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home + "/.config/fish", withIntermediateDirectories: true)
        try? "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        return home
    }

    private static func setupModel(_ variant: SetupVariant) -> SetupModel {
        let paths = SetupPaths(home: "/Users/me", channelConfig: "/Users/me/Library/Application Support/Sidemoon/channel-mcp.json",
                               launcher: "/Users/me/.local/bin/sidemoon-claude")
        let launcher = Data(LauncherScript.content(configPath: paths.channelConfig, helper: helper, home: paths.home).utf8)
        let files: [String: Data]
        let hooks: PreviewHooks.Mode
        switch variant {
        case .fresh:
            files = [:]
            hooks = .none
        case .attention:
            files = [paths.launcher: Data("#!/bin/sh\nexec something-else\n".utf8)]
            hooks = .otherCopy
        case .done, .shellOff, .shellOn:
            files = [paths.launcher: launcher, paths.channelConfig: Data(ChannelServer.mcpConfig(executablePath: helper).utf8)]
            hooks = .ours
        case .diskImage:
            files = [:]
            hooks = .none
        }
        // The switch writes real files, so it gets a scratch home; the paths shown are still "~/…".
        var shell: ShellIntegration?
        if variant == .shellOff || variant == .shellOn {
            let scratch = scratchHome()
            shell = ShellIntegration(home: scratch, loginShell: "/bin/zsh", launcher: scratch + "/.local/bin/sidemoon-claude",
                                     fileSystem: SystemShellFileSystem())
        }
        let shown = shell.map { SetupPaths(home: $0.home, channelConfig: $0.home + "/Library/Application Support/Sidemoon/channel-mcp.json",
                                          launcher: $0.launcher) } ?? paths
        let shownFiles = shell == nil ? files : [
            shown.launcher: Data(LauncherScript.content(configPath: shown.channelConfig, helper: helper, home: shown.home).utf8),
            shown.channelConfig: Data(ChannelServer.mcpConfig(executablePath: helper).utf8),
        ]
        let model = SetupModel(helper: .found(helper), paths: shown, finder: PreviewClaudeFinder(usual: variant != .attention),
                               hooks: PreviewHooks(mode: hooks), files: PreviewFiles(contents: shownFiles),
                               permission: PreviewPermission(granted: variant != .fresh && variant != .attention && variant != .diskImage),
                               relauncher: PreviewRelauncher(),
                               defaults: UserDefaults(suiteName: "sidemoon-preview-\(UUID().uuidString)") ?? .standard,
                               location: variant == .diskImage ? .diskImage("/Volumes/Sidemoon/Sidemoon.app") : .applications,
                               shell: shell)
        if variant == .shellOn { model.setConnectsEveryClaude(true) }
        if variant == .attention { model.requestCapture() }
        Task { await model.refresh() }
        return model
    }

    /// Renders the bubble the way the panel hosts it: fixed width, height following what the content reports.
    private static func bubbleSnapshot(_ model: CompanionModel, actions: BubbleActions, dark: Bool, to url: URL) {
        let wanted = HeightBox()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: BubbleView(model: model, actions: actions) { wanted.height = $0 })
        host.sizingOptions = []
        host.appearance = appearance
        host.frame = CGRect(x: 0, y: 0, width: Design.Bubble.width, height: Design.Bubble.minHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        let height = max(Design.Bubble.minHeight, min(wanted.height.rounded(.up), Design.Bubble.maxHeight))
        window.setContentSize(CGSize(width: Design.Bubble.width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: Design.Bubble.width, height: height)
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private final class HeightBox { var height: CGFloat = 0 }

    private static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
