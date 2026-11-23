import AppKit
import ServiceManagement
import SwiftUI
import SidemoonCompanion
import SidemoonCore

// MARK: The real permission and relaunch

struct SystemScreenCapturePermission: ScreenCapturePermission {
    func isGranted() -> Bool { ScreenCaptureAccess.isGranted() }
    func request() { _ = CGRequestScreenCaptureAccess() }
    func openSettings() {
        guard let url = URL(string: CompanionConstants.Setup.screenRecordingSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// macOS's own login-item registration for this app (System Settings, General, Login Items).
struct SystemLoginItem: LoginItem {
    /// Nil outside an app bundle, where there is nothing to register.
    init?() {
        guard Bundle.main.bundleURL.pathExtension == CompanionConstants.App.bundleExtension else { return nil }
    }
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Starts a shell that waits for this process to exit and then opens the bundle again, then quits.
struct BundleRelauncher: AppRelauncher {
    /// The bundle to open: this one, or its new copy after a move to Applications.
    var target = Bundle.main.bundlePath
    var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == CompanionConstants.App.bundleExtension }

    func relaunch() {
        let s = CompanionConstants.Setup.self
        let p = Process()
        p.executableURL = URL(fileURLWithPath: s.relaunchShell)
        p.arguments = ["-c", s.relaunchScript, s.relaunchScriptName, String(getpid()), target]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }
}

extension SetupModel {
    /// The setup for this process: the helper in this bundle (or next to this executable), the user's files.
    @MainActor
    static func system(defaults: UserDefaults = .standard) -> SetupModel {
        let helper = HelperLocator.locate(bundlePath: Bundle.main.bundlePath, executablePath: Bundle.main.executablePath,
                                          legacyPath: Constants.Paths.legacyCLIPath,
                                          isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        let paths = SetupPaths.standard
        return SetupModel(helper: helper, paths: paths, finder: SystemClaudeFinder(), hooks: SystemHooksService(),
                          files: SystemSetupFiles(), permission: SystemScreenCapturePermission(),
                          relauncher: BundleRelauncher(), defaults: defaults, location: .current,
                          shell: .system(launcher: paths.launcher))
    }
}

extension AppLocation {
    /// Where this process runs from.
    static var current: AppLocation {
        AppLocator.locate(bundlePath: Bundle.main.bundlePath, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

// MARK: Window

/// A normal titled window, centred, for reading and clicking. The app stays an accessory (no Dock icon); it is
/// activated while the window is open and hands focus back to the previous app when it closes.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let setup: SetupModel
    private let companion: CompanionModel
    /// Runs after Start, once the window has closed.
    var onStart: () -> Void = {}
    /// Runs after "Start a session here": as `onStart`, then the new-session form opens.
    var onStartWithSession: () -> Void = {}
    /// The move to Applications, from the steps that wait for it.
    var onMove: () -> Void = {}
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var timer: Timer?
    private var previousApp: NSRunningApplication?
    private var placed = false

    init(setup: SetupModel, companion: CompanionModel) {
        self.setup = setup
        self.companion = companion
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        applyLook()
        // Ticked for a first run; afterwards the tick shows what is actually set.
        companion.refreshOpensAtLogin()
        setup.offersOpenAtLogin = companion.canOpenAtLogin
        setup.openAtLoginChoice = setup.shouldShowOnLaunch ? true : companion.opensAtLogin
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // An app with no Dock icon is often not made active, above all when macOS reopens it after a
        // permission change; this puts the window in front all the same.
        window.orderFrontRegardless()
        startTimer()
        Task { await setup.refresh() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Design.Setup.width, height: Design.Bubble.minHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Design.Copy.Setup.windowTitle
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let host = NSHostingView(rootView: rootView())
        // The window sizes the content, from the height the content reports.
        host.sizingOptions = []
        window.contentView = host
        window.center()
        self.host = host
        self.window = window
        observeLook()
        return window
    }

    private func rootView() -> AnyView {
        AnyView(SetupView(model: setup, actions: SetupActions(
            openURL: { NSWorkspace.shared.open($0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            start: { [weak self] in self?.start() },
            startWithSession: { [weak self] in self?.start(withSession: true) },
            moveToApplications: { [weak self] in self?.onMove() })) { [weak self] height in self?.fit(height) }
            // A new size or theme redraws everything from the tokens.
            .id("\(companion.zoom)-\(companion.theme.rawValue)"))
    }

    /// The window follows its content's height, up to most of the screen; the rest scrolls. The top edge stays put.
    private func fit(_ height: CGFloat) {
        guard let window, height > 0 else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? height
        let wanted = CGSize(width: Design.Setup.width, height: min(height.rounded(.up), screen * Design.Setup.maxScreenFraction))
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.height - wanted.height) >= 1 || abs(current.width - wanted.width) >= 1 else { return }
        let top = window.frame.maxY
        window.setContentSize(wanted)
        if placed {
            window.setFrameOrigin(CGPoint(x: window.frame.minX, y: top - window.frame.height))
        } else {
            window.center()
            placed = true
        }
    }

    /// Paper is always light, Terminal always dark, Mono follows the system: as the panels do.
    private func applyLook() {
        guard let window else { return }
        let theme = Design.theme
        window.appearance = theme.isAlwaysDark ? NSAppearance(named: .darkAqua) : (theme.isAlwaysLight ? NSAppearance(named: .aqua) : nil)
        window.backgroundColor = .tone(Design.Colors.paper)
    }

    private func observeLook() {
        withObservationTracking {
            _ = companion.theme
            _ = companion.zoom
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyLook()
                self.host?.rootView = self.rootView()
                self.observeLook()
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: CompanionConstants.Setup.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.setup.refresh() }
            }
        }
    }

    private func start(withSession: Bool = false) {
        if setup.offersOpenAtLogin { companion.setOpensAtLogin(setup.openAtLoginChoice) }
        setup.finish()
        window?.close()
        if withSession { onStartWithSession() } else { onStart() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        Task { await setup.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // Back to the app the user was in; Sidemoon itself never stays front-most.
        previousApp?.activate()
        previousApp = nil
    }
}

// MARK: View

struct SetupActions {
    var openURL: (URL) -> Void
    var copy: (String) -> Void
    var start: () -> Void
    var startWithSession: () -> Void = {}
    var moveToApplications: () -> Void = {}
}

/// The setup window's content, scrolling when the screen is short.
struct SetupView: View {
    let model: SetupModel
    let actions: SetupActions
    let onHeight: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            SetupContent(model: model, actions: actions)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollIndicators(.automatic)
        .frame(width: Design.Setup.width)
        .background(Color.paper)
    }
}

/// The steps, top to bottom.
struct SetupContent: View {
    let model: SetupModel
    let actions: SetupActions
    @State private var copied: String?

    private typealias C = Design.Copy.Setup

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Setup.stepSpacing) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Text(C.heading)
                    .font(.text(Design.Setup.title, weight: .semibold))
                    .tracking(Design.TypeScale.headingTracking)
                    .foregroundStyle(Color.ink)
                paragraph(C.intro)
            }
            hairline
            step(1, C.claudeTitle, state: model.claudeState) {
                paragraph(model.claudeDetail)
                if model.claude == .missing, let url = URL(string: CompanionConstants.Setup.claudeCodeURL) {
                    buttons { secondary(C.getClaude) { actions.openURL(url) } }
                }
            }
            step(2, C.connectTitle, state: model.connectionState) {
                paragraph(model.connectionDetail)
                feedback(model.connectionFeedback)
                if model.needsMove, model.connectionState != .done {
                    buttons { primary(C.moveButton, action: actions.moveToApplications) }
                }
                if model.canConnect || model.hasHooks {
                    buttons {
                        if model.canConnect {
                            primary(model.needsRepair ? C.repair : C.connect) { model.connect() }
                        }
                        if model.hasHooks { secondary(C.disconnect) { model.disconnect() } }
                    }
                }
            }
            step(3, C.captureTitle, state: model.captureState) {
                paragraph(model.captureDetail)
                if model.capture != .granted {
                    buttons {
                        if model.capture == .notGranted {
                            primary(C.allow) { model.requestCapture() }
                        } else {
                            secondary(C.openSystemSettings) { model.openCaptureSettings() }
                            if model.canRelaunch { primary(C.relaunch) { model.relaunch() } }
                        }
                    }
                }
            }
            step(4, C.terminalTitle, optional: true, state: model.terminalState) {
                paragraph(C.terminalWhy)
                paragraph(model.terminalDetail)
                feedback(model.terminalFeedback)
                if model.terminal == .installed {
                    command(model.launcherCommand)
                    paragraph(C.terminalResume)
                    command(model.launcherResumeCommand)
                }
                if let warning = model.pathWarning { paragraph(warning) }
                if model.shell != nil { shellChoice }
                paragraph(C.terminalPreview)
                if model.canInstallLauncher {
                    buttons {
                        primary(model.terminal == .configOutdated ? C.repair : (model.terminal == .launcherOutdated ? C.update : C.install)) {
                        model.installLauncher()
                    }
                    }
                }
            }
            hairline
            ready
        }
        .padding(Design.Setup.padding)
        .frame(width: Design.Setup.width, alignment: .leading)
        .background(Color.paper)
        .tint(.signal)
    }

    // MARK: Pieces

    /// "Connect every claude": a switch, what it changes, and what went wrong with a file.
    private var shellChoice: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Toggle(isOn: Binding(get: { model.connectsEveryClaude }, set: { model.setConnectsEveryClaude($0) })) {
                Text(C.shellTitle).font(.prose).foregroundStyle(Color.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.canChangeShell)
            paragraph(model.shellDetail)
            if model.connectsEveryClaude || model.shell?.state == .partial {
                paragraph(C.shellConfirmNote)
            } else if model.canChangeShell, model.terminal != .installed {
                paragraph(C.shellNeedsLauncher)
            }
            feedback(model.shellFeedback)
            if let lines = model.shellLinesToCopy {
                buttons { secondary(C.copyLines) { actions.copy(lines) } }
            }
        }
        .padding(.top, Design.Space.xs)
    }

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.proseSmall)
            .foregroundStyle(Color.mute)
            .lineSpacing(Design.TypeScale.codeLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func feedback(_ value: SetupFeedback?) -> some View {
        if let value {
            Text(value.text)
                .font(.proseSmall)
                .foregroundStyle(value.isProblem ? Color.problem : Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, optional: Bool = false, state: SetupStepState,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Design.Space.l) {
            StepMark(number: number, state: state)
                .frame(width: Design.Setup.markColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                    Text(title)
                        .font(.text(Design.TypeScale.h2, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    if optional { ReadoutText(C.optional) }
                    Spacer(minLength: Design.Space.m)
                    stateLabel(state)
                }
                content()
            }
        }
    }

    private func stateLabel(_ state: SetupStepState) -> some View {
        switch state {
        case .checking: return ReadoutText(C.stateChecking)
        case .done: return ReadoutText(C.stateDone, color: .ink)
        case .notDone: return ReadoutText(C.stateNotDone)
        case .problem: return ReadoutText(C.stateProblem, color: .problem)
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Design.Space.m) { content() }
            .padding(.top, Design.Space.xxs)
    }

    /// The main action of a step: filled with ink.
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.text(Design.TypeScale.small, weight: .medium))
                .foregroundStyle(Color.paper)
                .padding(.horizontal, Design.Space.l)
                .frame(height: Design.Bubble.buttonHeight)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.ink))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// A second, quieter action: outlined.
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.text(Design.TypeScale.small, weight: .medium))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, Design.Space.l)
                .frame(height: Design.Bubble.buttonHeight)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// A command to type in a terminal, with a copy button.
    private func command(_ text: String) -> some View {
        HStack(spacing: Design.Space.m) {
            Text(text)
                .font(.code)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Design.Space.m)
            Button {
                actions.copy(text)
                copied = text
                Task {
                    try? await Task.sleep(for: .seconds(CompanionConstants.Timing.copiedConfirmation))
                    if copied == text { copied = nil }
                }
            } label: {
                ReadoutText(copied == text ? Design.Copy.copied : Design.Copy.copy, color: copied == text ? .signal : .ink)
                    .padding(.horizontal, Design.Space.m)
                    .frame(height: Design.Bubble.pillHeight)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, Design.Prose.codePaddingHorizontal)
        .padding(.vertical, Design.Space.s)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.sent))
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text(C.readyTitle)
                .font(.text(Design.TypeScale.h2, weight: .semibold))
                .foregroundStyle(Color.ink)
            paragraph(C.readyExplain)
            paragraph(C.whereItSits)
            VStack(alignment: .leading, spacing: Design.Space.m) {
                shortcut(CompanionConstants.HotKeys.captureActiveWindow, Design.Copy.shortcutActiveWindow)
                shortcut(CompanionConstants.HotKeys.capture, Design.Copy.shortcutRegion)
                shortcut(CompanionConstants.HotKeys.captureWithNote, Design.Copy.shortcutRegionNote)
            }
            HStack {
                if model.offersOpenAtLogin {
                    Button { model.openAtLoginChoice.toggle() } label: {
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: model.openAtLoginChoice ? "checkmark.square.fill" : "square")
                                .font(.system(size: Design.TypeScale.body, weight: .medium))
                                .foregroundStyle(model.openAtLoginChoice ? Color.signal : Color.mute)
                            Text(Design.Copy.openAtLoginChoice).font(.prose).foregroundStyle(Color.ink)
                        }
                    }
                    .buttonStyle(PressStyle())
                } else if model.needsMove {
                    paragraph(C.openAtLoginAfterMove)
                }
                Spacer()
                secondary(C.startWithSession, action: actions.startWithSession)
                    .help(C.startWithSessionHelp)
                primary(C.start, action: actions.start)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func shortcut(_ spec: HotKeySpec, _ what: String) -> some View {
        HStack(spacing: Design.Space.xs) {
            ForEach(spec.symbols, id: \.self) { Keycap($0) }
            Text(what).font(.proseSmall).foregroundStyle(Color.ink).padding(.leading, Design.Space.s)
        }
    }
}

/// A step's number in a ring; a tick when done, a bar when it needs attention.
struct StepMark: View {
    let number: Int
    let state: SetupStepState

    var body: some View {
        let size = Design.Setup.mark
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: Design.Setup.markIcon, weight: .bold))
                    .foregroundStyle(Color.paper)
            case .problem:
                Circle().fill(Color.problem)
                Image(systemName: "exclamationmark")
                    .font(.system(size: Design.Setup.markIcon, weight: .bold))
                    .foregroundStyle(Color.paper)
            case .notDone, .checking:
                Circle().strokeBorder(Color.line, lineWidth: Design.Setup.markStroke)
                Text("\(number)")
                    .font(.system(size: Design.TypeScale.label, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mute)
            }
        }
        .frame(width: size, height: size)
        // Sits on the title's line.
        .padding(.top, Design.Space.xxs)
    }
}
