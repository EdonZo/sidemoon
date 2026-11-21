import AppKit
import SidemoonCompanion
import SidemoonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The panels never activate Sidemoon, so the front-most app is the one the user is working in.
    let model = CompanionModel(engine: InProcessEngine(), capture: ScreencaptureProvider(),
                               windowCapture: ActiveWindowCaptureProvider { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                               archive: ThreadArchive())
    private var panels: PanelController!
    private let hotKeys = HotKeyCenter()
    private var failedHotKeys: [HotKeySpec] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var keyMonitor: Any?
    private var setupWindow: SetupWindowController?
    private var connectionTimer: Timer?

    /// Tells the companion whether the hooks are in place, so it can say when answers cannot come back.
    private func syncConnection() {
        guard let setup = setupWindow?.setup else { return }
        setup.refreshLocal()
        let needs = setup.connectionState != .done
        if model.needsConnection != needs { model.needsConnection = needs }
        // Only the required steps count: the optional terminal step never makes setup look unfinished. It shows
        // even after Start was pressed, since a permission can be lost later (a reset, or a new bundle id).
        let pending = !setup.requiredStepsDone
        if model.setupPending != pending { model.setupPending = pending }
    }

    /// Opens the setup window (first launch, the menu, the settings).
    private func showSetup() {
        let controller = setupWindow ?? SetupWindowController(setup: .system(), companion: model)
        setupWindow = controller
        controller.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panels = PanelController(model: model) { [unowned self] in self.buildMenu() }
        panels.install(actions: BubbleActions(
            showMenu: { [unowned self] in panels.popUpMenu() },
            copyReply: { [unowned self] in copyReply() },
            // The button's capture waits in the note window, so it can be undone before it is sent.
            capture: { [unowned self] in Task { await model.captureAndSend(hold: true) } },
            submitNote: { [unowned self] in submitNote() },
            cancelNote: { [unowned self] in
                model.cancelNote()
                // Escape always hands the keyboard back to the app the user was in.
                panels.releaseKeyboard()
            },
            close: { [unowned self] in model.closeBubble() },
            dropFiles: { [unowned self] files in Task { await model.dropFiles(files) } },
            openSetup: { [unowned self] in showSetup() }))

        model.loginItem = SystemLoginItem()
        model.updater = SparkleUpdater()
        // Never shown (the app has no menu bar), but it is what makes Command-C and friends work in Setup.
        NSApp.mainMenu = EditShortcut.menu()
        model.startEngine()
        if model.currentError != nil { model.openBubble() }

        // Arrow keys in the bubble: Left leaves the session for the list, Up and Down move, Right enters.
        // Caught here, before the text field, which would otherwise use them to move the caret.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard plain, let key = CompanionConstants.NavigationKeys.byKeyCode[event.keyCode] else { return event }
            let used = MainActor.assumeIsolated { event.window === panels.bubble && model.navigate(key) }
            return used ? nil : event
        }

        let keys = CompanionConstants.HotKeys.self
        if !hotKeys.register(keys.capture, action: { [unowned self] in capture(withNote: false) }) { failedHotKeys.append(keys.capture) }
        if !hotKeys.register(keys.captureWithNote, action: { [unowned self] in capture(withNote: true) }) {
            failedHotKeys.append(keys.captureWithNote)
        }
        if !hotKeys.register(keys.captureActiveWindow, action: { [unowned self] in captureActiveWindow() }) {
            failedHotKeys.append(keys.captureActiveWindow)
        }

        // Quit cleanly (socket removed) on SIGTERM and SIGINT too.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        // Until the user pressed Start once, setup opens on launch.
        let setup = SetupWindowController(setup: .system(), companion: model)
        setupWindow = setup
        if setup.setup.shouldShowOnLaunch { setup.show() }
        syncConnection()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: CompanionConstants.Setup.connectionCheckInterval,
                                               repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncConnection() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
        // A capture still waiting for its note is deleted, never left on disk.
        model.discardHeldCapture()
        model.flushThreads()
        model.stopEngine()
    }

    // MARK: Actions

    private func capture(withNote: Bool) {
        if withNote {
            model.beginNote()
        } else {
            Task { await model.captureAndSend() }
        }
    }

    private func captureActiveWindow() {
        Task { await model.captureActiveWindowAndSend() }
    }

    private func submitNote() {
        // Return on a held active-window capture: its own capture task does the sending.
        if model.isHoldingCapture { model.submitHeldCapture(); return }
        if model.isEditingNote {
            // Control-Option-N: the note is written first, then the region is picked.
            let note = model.finishNote()
            Task { await model.captureAndSend(note: note) }
            return
        }
        // Otherwise it is a typed question or reply.
        model.submitDraft()
        // Return ends the field's editing, and a panel that is key only while it is needed then hands the
        // keyboard back to the other app. The user is in a conversation here: keep the keyboard in the
        // composer, for the next message or the arrow keys. (After the field has finished ending its edit.)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.isExpanded else { return }
            self.panels.takeKeyboard()
            self.model.requestComposerFocus()
        }
    }

    private func copyReply() {
        guard let text = model.latestReply else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Menu

    /// The right-click menu: only what cannot be reached from the window itself. Sessions, shortcuts, size and
    /// the other choices live in the window and its settings.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = Design.Copy.self

        for spec in failedHotKeys {
            let warn = NSMenuItem(title: copy.menuHotKeyTaken(spec.displayName), action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        if !failedHotKeys.isEmpty { menu.addItem(.separator()) }

        menu.addItem(ClosureMenuItem(title: copy.menuSettings) { [unowned self] in
            model.openBubble()
            if !model.isShowingSettings { model.toggleSettings() }
        })
        menu.addItem(ClosureMenuItem(title: copy.setupMenuItem) { [unowned self] in showSetup() })
        if model.canUpdate {
            menu.addItem(ClosureMenuItem(title: copy.menuCheckForUpdates) { [unowned self] in model.checkForUpdates() })
        }
        switch model.engineState {
        case .running: break
        case .conflict, .failed, .stopped:
            menu.addItem(ClosureMenuItem(title: copy.menuRetryEngine) { [unowned self] in model.startEngine() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: copy.menuQuit) { NSApp.terminate(nil) })
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
