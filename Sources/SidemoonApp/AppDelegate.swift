import AppKit
import SidemoonCompanion
import SidemoonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The panels never activate Sidemoon, so the front-most app is the one the user is working in.
    let model = CompanionModel(engine: InProcessEngine(), capture: ScreencaptureProvider(),
                               windowCapture: ActiveWindowCaptureProvider { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                               store: CaptureStore(root: CompanionConstants.Capture.directory),
                               archive: ThreadArchive(), pathChecks: .system)
    private var panels: PanelController!
    private let hotKeys = HotKeyCenter()
    private var failedHotKeys: [HotKeySpec] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var keyMonitor: Any?
    private var setupWindow: SetupWindowController?
    private var moveWindow: MoveWindowController?
    private var connectionTimer: Timer?
    /// Where this copy runs from: outside Applications it offers to move there and changes nothing outside itself.
    private let location = AppLocation.current
    /// Another copy was already running and was asked to show itself; this one quits without touching anything.
    private var handingOff = false

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
        // Decides whether an error offers the resume command or the way to install it.
        let installed = setup.terminal == .installed
        if model.terminalCommandInstalled != installed { model.terminalCommandInstalled = installed }
        // Offered with a plain-claude session only while it is off and could be turned on.
        let connectsEvery = setup.connectsEveryClaude || !setup.canChangeShell
        if model.connectsEveryClaude != connectsEvery { model.connectsEveryClaude = connectsEvery }
    }

    /// Opens the setup window (first launch, the menu, the settings).
    private func showSetup() {
        let controller = setupWindow ?? makeSetupWindow()
        setupWindow = controller
        controller.show()
    }

    private func makeSetupWindow() -> SetupWindowController {
        let controller = SetupWindowController(setup: .system(), companion: model)
        // After Start: the companion opens beside the mascot, with the guide, and the mascot pulses.
        controller.onStart = { [unowned self] in
            model.presentAfterSetup()
            panels.reveal()
        }
        // The optional last step: start the first session from here, so nothing has to be typed in a terminal.
        controller.onStartWithSession = { [unowned self] in
            model.presentAfterSetup()
            panels.reveal()
            model.openNewSession()
        }
        controller.onMove = { [unowned self] in offerMove() }
        return controller
    }

    /// The window offering to move Sidemoon into Applications. `then` runs if it stays where it is.
    private func offerMove(then: @escaping () -> Void = {}) {
        let controller = MoveWindowController { [weak self] in
            self?.moveWindow = nil
            then()
        }
        moveWindow = controller
        controller.show()
    }

    /// Opening Sidemoon while it runs (a double-click in the Finder, Spotlight, or a second copy) brings the companion
    /// back where it can be seen, and Setup when it is not finished. With no Dock icon or menu bar item, this is how a
    /// lost companion is found.
    private func showYourself() {
        panels.reveal()
        model.requestAttention()
        if let setup = setupWindow?.setup, setup.shouldShowOnLaunch || !setup.requiredStepsDone { showSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showYourself()
        return false
    }

    /// A second copy started while one is running: the running one is asked to show itself, and this one quits.
    private func handOffToRunningCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }),
              let url = other.bundleURL else { return false }
        handingOff = true
        // Opening a running app sends it the reopen event.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        NSApp.terminate(nil)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningCopy() { return }
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
            openSetup: { [unowned self] in showSetup() },
            copyText: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openURL: { NSWorkspace.shared.open($0) },
            sendFeedback: { FeedbackSender.send($0) },
            openInTerminal: { TerminalOpener.open(script: $0) },
            connectEveryClaude: { [unowned self] in
                showSetup()
                setupWindow?.setup.setConnectsEveryClaude(true)
                syncConnection()
            },
            dragWindow: { [unowned self] ended in panels.dragByHeader(ended: ended) }))

        // A copy outside Applications never registers itself to open at login: the setting would point at it.
        model.loginItem = location.maySetUp ? SystemLoginItem() : nil
        model.updater = SparkleUpdater()
        // "Choose folder…" in the new-session form, and the claude "Open in Terminal" attaches with.
        model.folderChooser = FolderPanel()
        model.claudePath = SystemClaudeRunner.locateClaude()
        // Never shown (the app has no menu bar), but it is what makes Command-C and friends work in Setup.
        NSApp.mainMenu = EditShortcut.menu()
        model.startEngine()
        if model.currentError != nil { model.openBubble() }

        // Arrow keys in the bubble: Left leaves the session for the list, Up and Down move, Right enters.
        // Caught here, before the text field, which would otherwise use them to move the caret.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            // Control-C in the open bubble stops the selected session; anywhere else it is left alone.
            if CompanionConstants.InterruptKey.matches(keyCode: event.keyCode, modifiers: HotKeySpec.Modifiers(event.modifierFlags)) {
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard event.window === panels.bubble, model.isExpanded, !model.isCreatingSession else { return false }
                    Task { await model.interrupt() }
                    return true
                }
                if used { return nil }
            }
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

        // Until the user pressed Start once, setup opens on launch; first, a copy outside Applications offers to move.
        let setup = makeSetupWindow()
        setupWindow = setup
        if location.offersMove {
            offerMove { if setup.setup.shouldShowOnLaunch { setup.show() } }
        } else if setup.setup.shouldShowOnLaunch {
            setup.show()
        }
        syncConnection()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: CompanionConstants.Setup.connectionCheckInterval,
                                               repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncConnection() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Handing off, nothing was started, and the running copy owns the saved conversations.
        guard !handingOff else { return }
        hotKeys.unregisterAll()
        // A capture still waiting for its note is deleted, never left on disk.
        model.discardHeldCapture()
        // Kept for Retry only while Sidemoon runs: a failed message restored after a restart has no Retry.
        model.discardKeptCaptures()
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
        menu.addItem(ClosureMenuItem(title: Design.Copy.Feedback.menuItem) { FeedbackSender.send(.gitHub) })
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
