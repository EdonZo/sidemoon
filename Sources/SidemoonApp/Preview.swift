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

    private let list: [Session]
    init(sessions: [Session]) { list = sessions }

    func start() throws -> EngineStartOutcome { .running }
    func stop() {}
    func sessions() -> [Session] { list }
    func subscribe(_ handler: @escaping @Sendable (Session) -> Void) {}
    func send(_ request: SendRequest) -> SendResult {
        Thread.sleep(forTimeInterval: PreviewEngine.answerDelay)
        return SendResult(ok: true, sessionId: request.session, route: .channel, reply: "Team.", error: nil, detail: nil)
    }
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
        // Terminal is always dark, whatever the system.
        let theme = Design.theme
        Design.theme = .terminal
        let setup = setupModel(.done)
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        snapshot(SetupContent(model: setup, actions: SetupActions(openURL: { _ in }, copy: { _ in }, start: {})),
                 dark: true, to: dir.appendingPathComponent("setup-done-terminal.png"))
        Design.theme = theme
    }

    // MARK: Setup

    nonisolated static let helper = "/Applications/Sidemoon.app/Contents/Helpers/sidemoon"

    enum SetupVariant: String, CaseIterable { case fresh, attention, done }

    private static func setupModel(_ variant: SetupVariant) -> SetupModel {
        let paths = SetupPaths(home: "/Users/me", channelConfig: "/Users/me/Library/Application Support/Sidemoon/channel-mcp.json",
                               launcher: "/Users/me/.local/bin/sidemoon-claude")
        let launcher = Data(LauncherScript.content(configPath: paths.channelConfig, home: paths.home).utf8)
        let files: [String: Data]
        let hooks: PreviewHooks.Mode
        switch variant {
        case .fresh:
            files = [:]
            hooks = .none
        case .attention:
            files = [paths.launcher: Data("#!/bin/sh\nexec something-else\n".utf8)]
            hooks = .otherCopy
        case .done:
            files = [paths.launcher: launcher, paths.channelConfig: Data(ChannelServer.mcpConfig(executablePath: helper).utf8)]
            hooks = .ours
        }
        let model = SetupModel(helper: .found(helper), paths: paths, finder: PreviewClaudeFinder(usual: variant != .attention),
                               hooks: PreviewHooks(mode: hooks), files: PreviewFiles(contents: files),
                               permission: PreviewPermission(granted: variant == .done), relauncher: PreviewRelauncher(),
                               defaults: UserDefaults(suiteName: "sidemoon-preview-\(UUID().uuidString)") ?? .standard)
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
