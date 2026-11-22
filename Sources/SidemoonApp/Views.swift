import AppKit
import SwiftUI
import SidemoonCompanion

/// What the bubble's controls do; wired up by the panel controller.
struct BubbleActions {
    var showMenu: () -> Void
    var copyReply: () -> Void
    var capture: () -> Void
    var submitNote: () -> Void
    var cancelNote: () -> Void
    var close: () -> Void
    var dropFiles: @MainActor @Sendable ([URL]) -> Void
    var openSetup: () -> Void = {}
    /// Puts text on the clipboard (a command to paste in a terminal).
    var copyText: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    /// Opens a report, filled in, for the user to send.
    var sendFeedback: (FeedbackRoute) -> Void = { _ in }
    /// Opens the Terminal app with this session reopened through the launcher (session id, its folder).
    var openInTerminal: (String?, String?) -> Void = { _, _ in }
}

/// Collects the file URLs of a drop as their providers deliver them.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []
    func add(_ url: URL) { lock.withLock { collected.append(url) } }
    var urls: [URL] { lock.withLock { collected } }
}

/// The expanded companion: a slim header, then the session's latest reply as formatted text.
struct BubbleView: View {
    @Bindable var model: CompanionModel
    let actions: BubbleActions
    /// Reports the height the content wants, so the panel can grow or shrink to fit it.
    let onHeight: (CGFloat) -> Void
    @FocusState private var noteFocused: Bool
    @State private var shownEntries = CompanionConstants.Thread.visibleEntries
    @State private var copied = false
    @State private var topHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @State private var dropTargeted = false
    @State private var showsErrorDetail = false
    @State private var commandCopied = false

    /// Marks the bottom of the thread, where the newest entry is.
    static let newestID = "newest"
    static let topID = "top"

    /// The thread stays on its newest entry, at the bottom. The session list starts at the top,
    /// where the most recently active session is.
    private func follow(_ proxy: ScrollViewProxy) {
        if model.isPickingSession || model.isShowingSettings {
            proxy.scrollTo(BubbleView.topID, anchor: .top)
        } else {
            proxy.scrollTo(BubbleView.newestID, anchor: .bottom)
        }
    }

    private func report() { onHeight(topHeight + bodyHeight + bottomHeight) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                hairline
                if let error = model.currentError { errorRow(error); hairline }
                else if model.needsConnection {
                    setupRow(Design.Copy.notConnectedTitle, Design.Copy.notConnectedAdvice); hairline
                } else if model.setupPending {
                    setupRow(Design.Copy.setupPendingTitle, Design.Copy.setupPendingAdvice); hairline
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0; report() }

            // The conversation: older entries scroll up, the newest stays in view at the bottom.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id(BubbleView.topID)
                        Group {
                            if model.isShowingSettings {
                                SettingsView(model: model, openSetup: actions.openSetup, sendFeedback: actions.sendFeedback)
                            } else if model.isPickingSession {
                                SessionPicker(model: model) { model.closeSessionList() }
                            } else {
                                content
                            }
                        }
                        .padding(.horizontal, Design.Space.bubbleHorizontal)
                        .padding(.vertical, Design.Space.bubbleVertical)
                        Color.clear.frame(height: Design.Bubble.hairline).id(BubbleView.newestID)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0; report() }
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.automatic)
                // Whatever just happened is at the bottom, so the view follows it there.
                .onChange(of: model.thread.count) { follow(proxy) }
                .onChange(of: model.thread.last?.delivery) { follow(proxy) }
                .onChange(of: model.isAwaitingReply) { follow(proxy) }
                .onChange(of: model.isExpanded) { follow(proxy) }
                .onChange(of: model.targetId) { follow(proxy) }
                .onChange(of: bodyHeight) { follow(proxy) }
                .onChange(of: model.isPickingSession) { follow(proxy) }
                .onChange(of: model.isShowingSettings) { follow(proxy) }
                // The arrow keys keep the highlighted session in view.
                .onChange(of: model.highlightedSession) { _, id in
                    if model.isPickingSession, let id { proxy.scrollTo(id) }
                }
            }

            VStack(spacing: 0) {
                hairline
                compose
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0; report() }
        }
        // Reading the dragged size here makes the layout follow it as it changes.
        .frame(width: model.bubbleSize?.width ?? Design.Bubble.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ZStack { shape.fill(.regularMaterial); shape.fill(Color.surface) })
        .overlay(shape.strokeBorder(dropTargeted ? Color.signal : Color.line,
                                    lineWidth: dropTargeted ? Design.Bubble.dropOutline : Design.Bubble.hairline))
        .clipShape(shape)
        // The corner away from the mascot resizes the window.
        .overlay(alignment: Alignment(horizontal: model.bubbleGrowsLeft ? .leading : .trailing,
                                      vertical: model.bubbleGrowsUp ? .top : .bottom)) { ResizeGrip(model: model) }
        .tint(.signal)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .onChange(of: model.isEditingNote) { _, editing in if editing { noteFocused = true } }
        // Opening the bubble or the list puts the keyboard in the composer, ready for typing or arrows.
        .onChange(of: model.isExpanded) { _, open in if open { noteFocused = true } }
        .onChange(of: model.isPickingSession) { _, picking in if picking { noteFocused = true } }
        .onChange(of: model.composerFocusRequests) { noteFocused = true }
        // A new size, theme or window choice redraws everything from the tokens.
        .id("\(model.zoom)-\(model.theme.rawValue)-\(model.isLarge)")
    }

    /// Files dropped anywhere on the bubble go to the session.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let dropped = DroppedURLs()
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { dropped.add(url) }
                group.leave()
            }
        }
        let deliver = actions.dropFiles
        group.notify(queue: .main) { Task { @MainActor in deliver(dropped.urls) } }
        return true
    }

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
    }

    // MARK: Header

    private var header: some View {
        let state = MascotState(model)
        return HStack(spacing: Design.Space.m) {
            Button { model.toggleSessionList() } label: {
                HStack(spacing: Design.Space.xs) {
                    ReadoutText(model.targetId == nil ? Design.Copy.noSession : model.targetTitle, color: .ink)
                        .truncationMode(.middle)
                    Image(systemName: model.isPickingSession ? "chevron.up" : "chevron.down")
                        .font(.system(size: Design.TypeScale.label - 3, weight: .semibold))
                        .foregroundStyle(Color.mute)
                    // Another session has answered.
                    if !model.unreadSessions.isEmpty {
                        Circle().fill(Color.signal).frame(width: Design.Bubble.errorDot, height: Design.Bubble.errorDot)
                    }
                }
                .padding(.horizontal, Design.Space.m)
                .frame(height: Design.Bubble.pillHeight)
                .frame(maxWidth: Design.Bubble.width * 0.38, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(Design.Copy.sessionHelp)

            ReadoutText(state.label, color: state == .reply ? .signal : (state == .error ? .problem : .mute))
            Spacer(minLength: Design.Space.xs)
            let capturing = model.status.activity == .capturing || model.status.activity == .holding
            iconButton("viewfinder", help: Design.Copy.captureHelp, disabled: capturing, action: actions.capture)
            iconButton(model.isShowingSettings ? "xmark" : "slider.horizontal.3", help: Design.Copy.settingsHelp, disabled: false) {
                model.toggleSettings()
            }
            iconButton(model.isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: model.isLarge ? Design.Copy.shrinkHelp : Design.Copy.enlargeHelp, disabled: false) {
                model.toggleLarge()
            }
            iconButton("minus", help: Design.Copy.minimizeHelp, disabled: false, action: actions.close)
        }
        .padding(.horizontal, Design.Space.bubbleHorizontal)
        .frame(height: Design.Bubble.headerHeight + Design.Space.m)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.Bubble.iconSize, weight: .medium))
                .foregroundStyle(disabled ? Color.mute.opacity(0.4) : Color.ink)
                .frame(width: Design.Bubble.pillHeight, height: Design.Bubble.pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .help(help)
    }

    // MARK: Note

    /// The composer: always there to ask or reply, and where a held capture or dropped files wait.
    private var compose: some View {
        let holding = model.isHoldingCapture
        let placeholder = holding ? Design.Copy.notePlaceholder
            : (model.isEditingNote ? Design.Copy.regionNotePlaceholder : Design.Copy.askPlaceholder)
        let canSend = holding || model.isEditingNote || !model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            if holding {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Design.Space.s) {
                        // The cross takes it back before anything is sent.
                        if model.heldCapture != nil {
                            AttachmentChip(name: CompanionConstants.Messages.captureAttachmentName, onRemove: actions.cancelNote)
                        }
                        ForEach(model.heldFiles, id: \.self) { file in
                            AttachmentChip(name: file.lastPathComponent) { model.removeHeldFile(file) }
                        }
                    }
                }
            }
            // The composer is outlined while typing will reach it, so it is plain where the keyboard is.
            let typingHere = noteFocused && model.hasKeyboard
            HStack(spacing: Design.Space.m) {
                TextField(placeholder, text: $model.noteDraft)
                    .textFieldStyle(.plain)
                    .font(.prose)
                    .foregroundStyle(Color.ink)
                    .focused($noteFocused)
                    .onSubmit(actions.submitNote)
                    .onExitCommand(perform: actions.cancelNote)
                    .padding(.horizontal, Design.Space.m)
                    .frame(minHeight: Design.Bubble.buttonHeight)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(typingHere ? Color.sent : Color.paper2))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .strokeBorder(typingHere ? Color.signal : Color.clear, lineWidth: Design.Bubble.focusRing))
                    .animation(.easeOutCurve(Design.Motion.fast), value: typingHere)
                Button(action: actions.submitNote) {
                    Image(systemName: "arrow.up")
                        .font(.text(Design.TypeScale.small, weight: .semibold))
                        .foregroundStyle(canSend ? Color.paper : Color.mute)
                        .frame(width: Design.Bubble.sendButton, height: Design.Bubble.sendButton)
                        .background(Circle().fill(canSend ? Color.signal : Color.paper2))
                }
                .buttonStyle(PressStyle())
                .disabled(!canSend)
                .help(Design.Copy.sendHelp)
            }
            if let countdown = model.noteCountdown {
                // The bar empties as the held capture counts down to sending without a note.
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.signal)
                        .frame(width: geo.size.width * countdown.fractionRemaining, height: Design.Bubble.countdownBarHeight)
                        .animation(.linear(duration: countdown.tickInterval), value: countdown.fractionRemaining)
                }
                .frame(height: Design.Bubble.countdownBarHeight)
                HStack(spacing: Design.Space.l) {
                    cancelButton
                    ReadoutText(Design.Copy.returnSends)
                    Spacer()
                    ReadoutText(Design.Copy.sendsIn(countdown.secondsLeft), color: .signal)
                }
            } else if holding || model.isEditingNote {
                HStack(spacing: Design.Space.l) {
                    cancelButton
                    ReadoutText(Design.Copy.returnSends)
                }
            }
        }
        .padding(.horizontal, Design.Space.bubbleHorizontal)
        .padding(.vertical, Design.Space.bubbleVertical)
    }

    /// Undo for a capture or files that are still waiting: nothing has been sent yet.
    private var cancelButton: some View {
        Button(action: actions.cancelNote) {
            ReadoutText(Design.Copy.cancel, color: .ink)
                .padding(.horizontal, Design.Space.m)
                .frame(height: Design.Bubble.pillHeight)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Error

    private func errorRow(_ error: CompanionError) -> some View {
        let needsSession = error == .noTarget || error == .unknownSession
        let remedies = model.remedies(for: error)
        let copy = Design.Copy.Unreachable.self
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                Circle().fill(Color.problem)
                    .frame(width: Design.Bubble.errorDot, height: Design.Bubble.errorDot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + Design.Space.xxs }
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text(error.title)
                            .font(.text(Design.TypeScale.body, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(error.advice)
                            .font(.proseSmall)
                            .foregroundStyle(Color.mute)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if remedies.contains(.runLogin) {
                        Text(copy.runLogin)
                            .font(.proseSmall)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if remedies.contains(.installTerminalCommand) {
                        Text(copy.installCommandNote)
                            .font(.proseSmall)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Side by side when they fit, one under the other when they do not (a narrow or zoomed window).
            // Dismiss goes on a line of its own before the next steps are split up.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Design.Space.s) {
                    remedyButtons(remedies)
                    dismissButton(remedies, needsSession: needsSession)
                }
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    HStack(spacing: Design.Space.s) { remedyButtons(remedies) }
                    dismissButton(remedies, needsSession: needsSession)
                }
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    remedyButtons(remedies)
                    dismissButton(remedies, needsSession: needsSession)
                }
            }
            if let detail = error.detail, !detail.isEmpty {
                Button { showsErrorDetail.toggle() } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: showsErrorDetail ? "chevron.down" : "chevron.right")
                            .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                            .foregroundStyle(Color.mute)
                        ReadoutText(showsErrorDetail ? copy.hideDetails : copy.details)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                if showsErrorDetail {
                    Text(detail)
                        .font(.system(size: Design.TypeScale.code, design: .monospaced))
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(Design.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.paper2))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.bubbleHorizontal)
        .padding(.vertical, Design.Space.bubbleVertical)
        .onChange(of: error) { showsErrorDetail = false }
    }

    /// The error's next steps, the first one filled.
    @ViewBuilder
    private func remedyButtons(_ remedies: [Remedy]) -> some View {
        let copy = Design.Copy.Unreachable.self
        let actionable = remedies.filter { $0 != .runLogin }
        ForEach(Array(actionable.enumerated()), id: \.element) { index, remedy in
            switch remedy {
            case .copyResumeCommand:
                cardButton(commandCopied ? copy.openedInTerminal : copy.openInTerminal, primary: index == 0) {
                    actions.openInTerminal(model.targetId, model.target?.cwd)
                    commandCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(CompanionConstants.Timing.copiedConfirmation))
                        commandCopied = false
                    }
                }
                .help(copy.openInTerminalHelp)
            case .installTerminalCommand:
                cardButton(copy.installCommand, primary: index == 0) {
                    actions.openSetup()
                    model.dismissError()
                }
            case .chooseAnotherSession:
                cardButton(copy.chooseAnother, primary: index == 0) {
                    model.dismissError()
                    model.openSessionList()
                }
            case .runLogin:
                EmptyView()
            }
        }
    }

    /// Dismiss, or the way to a session when that is what is missing. Filled when there is nothing else to do.
    @ViewBuilder
    private func dismissButton(_ remedies: [Remedy], needsSession: Bool) -> some View {
        let actionable = remedies.filter { $0 != .runLogin }
        if actionable.isEmpty {
            cardButton(needsSession ? Design.Copy.noSession : Design.Copy.dismiss, primary: true) {
                if needsSession { model.openSessionList() }
                model.dismissError()
            }
        } else {
            cardButton(Design.Copy.dismiss, primary: false) { model.dismissError() }
        }
    }

    /// A button in a card: filled with ink for the main step, outlined for the others.
    private func cardButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.text(Design.TypeScale.small, weight: .medium))
                .foregroundStyle(primary ? Color.paper : Color.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Design.Space.l)
                .frame(height: Design.Bubble.buttonHeight)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(primary ? Color.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                    .strokeBorder(primary ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// A reminder with a way back into Setup. Shown until the hooks are installed (sessions can be seen and
    /// written to, but their answers only come back once Claude Code is connected), and after that until the
    /// user has pressed Start, so a setup interrupted by a relaunch is not lost.
    private func setupRow(_ title: String, _ advice: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(title)
                    .font(.text(Design.TypeScale.body, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(advice)
                    .font(.proseSmall)
                    .foregroundStyle(Color.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: actions.openSetup) {
                Text(Design.Copy.openSetup)
                    .font(.text(Design.TypeScale.small, weight: .medium))
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, Design.Space.l)
                    .frame(height: Design.Bubble.buttonHeight)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.signal))
            }
            .buttonStyle(PressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.bubbleHorizontal)
        .padding(.vertical, Design.Space.bubbleVertical)
    }

    // MARK: Reply

    @ViewBuilder
    private var content: some View {
        let thread = model.thread
        let working = model.isAwaitingReply
        if model.showsGuide {
            GuideCard(model: model, actions: actions)
                .padding(.bottom, thread.isEmpty && !working ? 0 : Design.Bubble.entrySpacing)
        }
        if !thread.isEmpty || working {
            // Only the recent end of a long conversation is drawn; the rest waits behind "earlier messages".
            let hidden = max(0, thread.count - shownEntries)
            VStack(alignment: .leading, spacing: Design.Bubble.entrySpacing) {
                if hidden > 0 {
                    Button { shownEntries += CompanionConstants.Thread.visibleEntries } label: {
                        ReadoutText(Design.Copy.earlierMessages(hidden), color: .signal)
                            .padding(.horizontal, Design.Space.m)
                            .frame(height: Design.Bubble.pillHeight)
                            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                                .strokeBorder(Color.signalSoft, lineWidth: Design.Bubble.hairline))
                    }
                    .buttonStyle(PressStyle())
                }
                ForEach(thread.suffix(shownEntries)) { entry in
                    ThreadEntryView(entry: entry, sessionName: model.targetTitle, layoutWidth: Design.Bubble.width,
                                    onRetry: entry.canRetry ? { Task { await model.retry(entry.id) } } : nil).equatable()
                }
                if working { WorkingRow(sessionName: model.targetTitle) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Another session starts again from its recent end.
            .onChange(of: model.targetId) { shownEntries = CompanionConstants.Thread.visibleEntries }
        } else if !model.showsGuide {
            emptyState
        }
    }

    /// A conversation with nothing in it yet: how to start one.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            if model.targetId == nil {
                Text(Design.Copy.emptyNoSession)
                    .font(.prose)
                    .foregroundStyle(Color.mute)
                    .fixedSize(horizontal: false, vertical: true)
                cardButton(Design.Copy.noSession, primary: true) { model.openSessionList() }
            } else {
                Text(Design.Copy.emptyThread(session: model.targetTitle))
                    .font(.prose)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Design.Space.xs) {
                    ForEach(CompanionConstants.Guide.shortcut.symbols, id: \.self) { Keycap($0) }
                    Text(Design.Copy.emptyShortcut)
                        .font(.proseSmall)
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Design.Space.xs)
                }
                Text(Design.Copy.emptyOrType)
                    .font(.proseSmall)
                    .foregroundStyle(Color.mute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Try it" guide: three steps that tick off as the user does them, a test message, and the video.
struct GuideCard: View {
    @Bindable var model: CompanionModel
    let actions: BubbleActions

    var body: some View {
        let g = Design.Copy.Guide.self
        let progress = model.guide
        VStack(alignment: .leading, spacing: Design.Space.l) {
            HStack(spacing: Design.Space.m) {
                ReadoutText(progress.isComplete ? g.doneHeading : g.heading, color: .signal)
                ReadoutText(g.progress(progress.doneCount))
                Spacer(minLength: 0)
                Button(action: model.dismissGuide) {
                    Image(systemName: "xmark")
                        .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                        .foregroundStyle(Color.mute)
                        .frame(width: Design.Bubble.pillHeight, height: Design.Bubble.pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(g.dismiss)
            }
            if progress.sentCapture {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    step(1, g.stepPick, done: progress.pickedSession) { EmptyView() }
                    step(2, g.stepSend, done: progress.sentCapture) {
                        HStack(spacing: Design.Space.xs) {
                            ForEach(CompanionConstants.Guide.shortcut.symbols, id: \.self) { Keycap($0) }
                        }
                    }
                    step(3, g.stepReply, done: progress.replied) { EmptyView() }
                }
            } else {
                // Until the first capture has gone out, the guide is one thing: the shortcut, drawn large.
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    HStack(spacing: Design.Space.s) {
                        ForEach(CompanionConstants.Guide.shortcut.symbols, id: \.self) { HeroKeycap($0) }
                    }
                    Text(g.heroTitle)
                        .font(.text(Design.Guide.heroTitle, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    if model.targetId == nil {
                        Text(g.heroNoSession)
                            .font(.proseSmall)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        smallButton(g.pickButton) { model.openSessionList() }
                    } else {
                        Text(g.heroBody(session: model.targetTitle, seconds: Int(CompanionConstants.Timing.noteGracePeriod)))
                            .font(.proseSmall)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if progress.isComplete {
                Button(action: model.dismissGuide) {
                    Text(g.doneButton)
                        .font(.text(Design.TypeScale.small, weight: .medium))
                        .foregroundStyle(Color.paper)
                        .padding(.horizontal, Design.Space.l)
                        .frame(height: Design.Bubble.buttonHeight)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.ink))
                }
                .buttonStyle(PressStyle())
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Space.l) { testAndVideo }
                    VStack(alignment: .leading, spacing: Design.Space.s) { testAndVideo }
                }
            }
            Text(g.terminalNote)
                .font(.proseSmall)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Bubble.entryPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.paper2))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
    }

    @ViewBuilder
    private var testAndVideo: some View {
        let g = Design.Copy.Guide.self
        let canTest = model.targetId != nil
        Button { Task { await model.sendTestMessage() } } label: {
            Text(g.testMessageButton)
                .font(.text(Design.TypeScale.small, weight: .medium))
                .foregroundStyle(canTest ? Color.paper : Color.mute)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Design.Space.l)
                .frame(height: Design.Bubble.buttonHeight)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(canTest ? Color.ink : Color.paper2))
        }
        .buttonStyle(PressStyle())
        .disabled(!canTest)
        Button {
            if let url = URL(string: CompanionConstants.Guide.videoURL) { actions.openURL(url) }
        } label: {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "play.circle")
                    .font(.system(size: Design.Bubble.iconSize, weight: .medium))
                Text(g.video)
                    .font(.text(Design.TypeScale.small, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Color.signal)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// One step: its number, or a tick once done, and what to do.
    private func step<Extra: View>(_ number: Int, _ text: String, done: Bool, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            ZStack {
                Circle()
                    .fill(done ? Color.signal : Color.clear)
                    .overlay(Circle().strokeBorder(done ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: Design.Guide.markIcon, weight: .bold))
                        .foregroundStyle(Color.paper)
                } else {
                    Text("\(number)")
                        .font(.system(size: Design.Guide.markIcon, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.mute)
                }
            }
            .frame(width: Design.Guide.mark, height: Design.Guide.mark)
            .accessibilityLabel(done ? Design.Copy.Guide.stepDone : "\(number)")
            Text(text)
                .font(.proseSmall)
                .foregroundStyle(done ? Color.mute : Color.ink)
                .strikethrough(done, color: Color.mute)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.s)
            extra()
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ReadoutText(title, color: .ink)
                .padding(.horizontal, Design.Space.m)
                .frame(height: Design.Bubble.pillHeight)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// A command to paste in a terminal, set in a quiet block and selectable.
struct CommandText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Design.TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.ink)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.paper2))
    }
}

/// One entry of the conversation: who, when, and either what was sent or the formatted reply.
struct ThreadEntryView: View, Equatable {
    let entry: ThreadEntry
    let sessionName: String
    /// The width the entry is laid out in: a table's columns are fitted to it.
    var layoutWidth: CGFloat = Design.Bubble.width
    /// Sends a message that was not delivered once more; nil where that is not offered.
    var onRetry: (() -> Void)?

    nonisolated static func == (a: ThreadEntryView, b: ThreadEntryView) -> Bool {
        // Whether a retry is offered follows from the entry itself, so it needs no comparing.
        a.entry == b.entry && a.sessionName == b.sessionName && a.layoutWidth == b.layoutWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                ReadoutText(entry.role == .you ? Design.Copy.you : sessionName, color: entry.role == .you ? .mute : .signal)
                    .truncationMode(.middle)
                ReadoutText(entry.date.formatted(date: .omitted, time: .shortened))
                switch entry.delivery {
                case .sending: ReadoutText(Design.Copy.sending, color: .signal)
                case .queued: ReadoutText(Design.Copy.queued, color: .signal)
                case .failed, .refused:
                    ReadoutText(Design.Copy.notDelivered, color: .problem)
                    if entry.canRetry, let onRetry {
                        Button(action: onRetry) {
                            ReadoutText(Design.Copy.retry, color: .paper)
                                .padding(.horizontal, Design.Space.m)
                                .padding(.vertical, Design.Space.xxs)
                                .background(Capsule().fill(Color.signal))
                        }
                        .buttonStyle(PressStyle())
                        .help(Design.Copy.retryHelp)
                    }
                case .delivered: EmptyView()
                }
                Spacer(minLength: 0)
            }
            if entry.role == .you {
                sent
            } else {
                MarkdownView(entry.text)
                // Files the answer names that really exist on this Mac: a click plays or opens them.
                let files = RenderCache.mentionedFiles(in: entry.text)
                if !files.isEmpty { FileChips(files: files) }
            }
        }
    }

    /// What the user sent: a quiet card with its attachments, text, and why it failed if it did.
    private var sent: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if !entry.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Design.Space.s) {
                        ForEach(Array(entry.attachments.enumerated()), id: \.offset) { _, name in AttachmentChip(name: name) }
                    }
                }
            }
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(.prose)
                    .foregroundStyle(Color.ink)
                    .lineSpacing(Design.TypeScale.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let reason = entry.delivery.failureReason {
                Text(reason).font(.proseSmall).foregroundStyle(Color.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Bubble.entryPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.sent))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(Color.signalSoft, lineWidth: Design.Bubble.hairline))
    }
}

/// Shown at the bottom of the thread while the session is working on its answer.
struct WorkingRow: View {
    let sessionName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Design.Space.m) {
            ReadoutText(sessionName, color: .ink).truncationMode(.middle)
            ReadoutText(Design.Copy.working, color: .signal)
            if !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: Design.Bubble.workingDotGap) {
                        ForEach(0..<Design.Bubble.workingDots, id: \.self) { index in
                            // Each dot brightens in turn.
                            let phase = (t / Design.Motion.workingCycle - Double(index) / Double(Design.Bubble.workingDots))
                            let wave = (sin(phase * 2 * .pi) + 1) / 2
                            Circle()
                                .fill(Color.signal)
                                .frame(width: Design.Bubble.workingDot, height: Design.Bubble.workingDot)
                                .opacity(Design.Bubble.workingDotMinOpacity + (1 - Design.Bubble.workingDotMinOpacity) * wave)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A capture or a file, named in a small outlined chip.
struct AttachmentChip: View {
    let name: String
    /// When set, the chip carries a cross that takes the attachment back.
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: name == CompanionConstants.Messages.captureAttachmentName ? "viewfinder" : "doc")
                .font(.system(size: Design.Bubble.chipIcon, weight: .medium))
                .foregroundStyle(Color.mute)
            Text(name)
                .font(.proseSmall)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: Design.Bubble.chipIcon - 1, weight: .semibold))
                        .foregroundStyle(Color.mute)
                        .frame(width: Design.Bubble.chipIcon + Design.Space.s, height: Design.Bubble.pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(Design.Copy.remove)
            }
        }
        .padding(.horizontal, Design.Space.m)
        .frame(height: Design.Bubble.pillHeight)
        .frame(maxWidth: Design.Bubble.chipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
    }
}

/// Where captures and messages go: every live session, one click to choose, plus the size setting.
struct SessionPicker: View {
    @Bindable var model: CompanionModel
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ReadoutText(Design.Copy.sendTo)
            let rows = model.rows
            if rows.isEmpty {
                Text(Design.Copy.noSessions)
                    .font(.prose)
                    .foregroundStyle(Color.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Design.Space.xxs) {
                ForEach(rows) { row in
                    SessionRowView(row: row, selected: row.id == model.targetId, unread: model.unreadSessions.contains(row.id),
                                   highlighted: row.id == model.highlightedSession) {
                        model.pickSession(row.id)
                        onPick()
                    }
                    .id(row.id)
                }
            }
            Button { model.showEnded.toggle() } label: {
                ReadoutText(model.showEnded ? Design.Copy.hideEnded : Design.Copy.showEnded, color: .ink)
            }
            .buttonStyle(PressStyle())
            .padding(.leading, Design.Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Theme, size, window and reply style, in one place.
struct SettingsView: View {
    @Bindable var model: CompanionModel
    var openSetup: () -> Void = {}
    var sendFeedback: (FeedbackRoute) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            row(Design.Copy.theme) {
                ForEach(Design.Theme.allCases, id: \.self) { theme in
                    choice(theme.title, selected: model.theme == theme) { model.setTheme(theme) }
                }
            }
            row(Design.Copy.window) {
                choice(Design.Copy.windowRegular, selected: !model.isLarge && model.bubbleSize == nil) { model.setLarge(false) }
                choice(Design.Copy.windowLarge, selected: model.isLarge && model.bubbleSize == nil) { model.setLarge(true) }
                // A size dragged out with the corner grip; choosing one of the others goes back to it.
                if model.bubbleSize != nil { choice(Design.Copy.windowCustom, selected: true) {} }
            }
            row(Design.Copy.size) {
                stepButton("minus", help: Design.Copy.smaller, disabled: model.zoom <= Design.Zoom.minimum) { model.zoomOut() }
                Button { model.resetZoom() } label: {
                    ReadoutText("\(Int((model.zoom * 100).rounded()))%", color: .ink)
                        .frame(minWidth: Design.Bubble.pillHeight * 2)
                }
                .buttonStyle(PressStyle())
                .help(Design.Copy.actualSize)
                stepButton("plus", help: Design.Copy.larger, disabled: model.zoom >= Design.Zoom.maximum) { model.zoomIn() }
            }
            row(Design.Copy.replies) {
                choice(Design.Copy.shortReplies, selected: model.shortReplies) { model.shortReplies.toggle() }
                    .help(Design.Copy.shortRepliesHelp)
            }
            row(Design.Copy.sessions) {
                choice(Design.Copy.showEnded, selected: model.showEnded) { model.showEnded.toggle() }
            }
            if model.canOpenAtLogin {
                row(Design.Copy.startup) {
                    choice(Design.Copy.openAtLogin, selected: model.opensAtLogin) { model.setOpensAtLogin(!model.opensAtLogin) }
                        .help(Design.Copy.openAtLoginHelp)
                }
            }
            if model.canUpdate {
                row(Design.Copy.updates) {
                    choice(Design.Copy.checkAutomatically, selected: model.checksForUpdates) {
                        model.setChecksForUpdates(!model.checksForUpdates)
                    }
                    .help(Design.Copy.checkAutomaticallyHelp)
                    choice(Design.Copy.checkNow, selected: false) { model.checkForUpdates() }
                }
            }
            row(Design.Copy.history) {
                choice(Design.Copy.clearHistory, selected: false) { model.clearThreads() }
                    .help(Design.Copy.clearHistoryHelp)
            }
            row(Design.Copy.setup) {
                choice(Design.Copy.openSetup, selected: false, action: openSetup)
            }
            row(Design.Copy.guide) {
                choice(Design.Copy.showGuide, selected: false) { model.showGuide() }
            }
            HStack(alignment: .top, spacing: Design.Space.s) {
                ReadoutText(Design.Copy.recording).frame(width: Design.Bubble.settingsLabel, alignment: .leading)
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Button { model.visibleInRecordings.toggle() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                            Image(systemName: model.visibleInRecordings ? "checkmark.square.fill" : "square")
                                .font(.system(size: Design.TypeScale.body, weight: .medium))
                                .foregroundStyle(model.visibleInRecordings ? Color.signal : Color.mute)
                            Text(Design.Copy.visibleInRecordings)
                                .font(.proseSmall)
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    Text(Design.Copy.visibleInRecordingsNote)
                        .font(.proseSmall)
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
            VStack(alignment: .leading, spacing: Design.Space.m) {
                ReadoutText(Design.Copy.shortcuts)
                shortcut(CompanionConstants.HotKeys.captureActiveWindow, Design.Copy.shortcutActiveWindow)
                shortcut(CompanionConstants.HotKeys.capture, Design.Copy.shortcutRegion)
                shortcut(CompanionConstants.HotKeys.captureWithNote, Design.Copy.shortcutRegionNote)
            }
            Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
            row(Design.Copy.Feedback.title) {
                choice(Design.Copy.Feedback.onGitHub, selected: false) { sendFeedback(.gitHub) }
                    .help(Design.Copy.Feedback.onGitHubHelp)
                choice(Design.Copy.Feedback.byEmail, selected: false) { sendFeedback(.email) }
                    .help(Design.Copy.Feedback.byEmailHelp)
            }
            // The normal terminate path, so applicationWillTerminate saves the conversations first.
            row(Design.Copy.app) {
                choice(Design.Copy.menuQuit, selected: false) { NSApp.terminate(nil) }
                    .help(Design.Copy.quitHelp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.refreshOpensAtLogin()
            model.refreshAutomaticUpdates()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Design.Space.s) {
            ReadoutText(label).frame(width: Design.Bubble.settingsLabel, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// One option: outlined, filled with ink when chosen.
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ReadoutText(title, color: selected ? .paper : .ink)
                .padding(.horizontal, Design.Space.m)
                .frame(height: Design.Bubble.pillHeight)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(selected ? Color.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                    .strokeBorder(selected ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func stepButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                .foregroundStyle(disabled ? Color.mute.opacity(0.4) : Color.ink)
                .frame(width: Design.Bubble.pillHeight, height: Design.Bubble.pillHeight)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .help(help)
    }

    private func shortcut(_ spec: HotKeySpec, _ what: String) -> some View {
        HStack(spacing: Design.Space.xs) {
            ForEach(spec.symbols, id: \.self) { Keycap($0) }
            Text(what).font(.proseSmall).foregroundStyle(Color.mute).padding(.leading, Design.Space.xs)
        }
    }
}

/// One session in the picker: its name, where it runs, and what it is doing.
struct SessionRowView: View {
    let row: SessionRow
    let selected: Bool
    /// It has answered since the user last looked at it.
    let unread: Bool
    /// The arrow keys are on this row.
    var highlighted = false
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Design.Space.m) {
                Circle()
                    .fill(selected ? Color.signal : Color.clear)
                    .overlay(Circle().strokeBorder(selected ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                    .frame(width: Design.Bubble.errorDot, height: Design.Bubble.errorDot)
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(row.title)
                        .font(.text(Design.TypeScale.body, weight: selected ? .semibold : .regular))
                        .foregroundStyle(row.reachable ? Color.ink : Color.mute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let folder = row.folder, folder != row.title { ReadoutText(folder).truncationMode(.middle) }
                }
                .opacity(row.reachable ? 1 : Design.Bubble.unreachableOpacity)
                Spacer(minLength: Design.Space.m)
                status
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(highlighted || hovering ? Color.paper2 : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(highlighted ? Color.signal : Color.clear, lineWidth: Design.Bubble.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }

    /// Plain words for what the session is doing. A busy one is still fine to pick: messages wait for it.
    @ViewBuilder
    private var status: some View {
        if let blocker = row.blocker {
            ReadoutText(Design.Copy.Unreachable.reason(blocker))
        } else if unread {
            ReadoutText(Design.Copy.stateNewReply, color: .signal)
        } else if row.reachability == .channelDropped {
            ReadoutText(Design.Copy.Unreachable.notPickedUpReason)
        } else if !row.reachable && !row.ended {
            ReadoutText(Design.Copy.Unreachable.noChannelReason)
        } else {
            switch row.state {
            case .working: ReadoutText(Design.Copy.working, color: .signal)
            case .idle: ReadoutText(Design.Copy.stateReady)
            case .needsInput: ReadoutText(Design.Copy.needsYou, color: .signal)
            case .ended: ReadoutText(Design.Copy.ended)
            }
        }
    }
}

/// One key of a shortcut, drawn as a small keycap.
/// A key of the shortcut, drawn large: the accent on the letter, as on the website.
struct HeroKeycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Guide.heroKeycapRadius, style: .continuous)
        let isLetter = key == CompanionConstants.Guide.shortcut.key.uppercased()
        Text(key)
            .font(.system(size: Design.Guide.heroKeycapText, weight: .semibold, design: .rounded))
            .foregroundStyle(isLetter ? Color.paper : Color.ink)
            .frame(minWidth: Design.Guide.heroKeycap, minHeight: Design.Guide.heroKeycap)
            .background(shape.fill(isLetter ? Color.signal : Color.paper))
            .background(shape.fill(Color.line).offset(y: Design.Space.xs))
            .overlay(shape.strokeBorder(isLetter ? Color.signal : Color.line, lineWidth: Design.Bubble.hairline))
    }
}

struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.control)
        Text(key)
            .font(.system(size: Design.TypeScale.keycap, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.ink)
            .frame(minWidth: Design.Bubble.keycapHeight, minHeight: Design.Bubble.keycapHeight)
            .background(shape.fill(Color.paper))
            .background(shape.fill(Color.line).offset(y: Design.Space.xxs))
            .overlay(shape.strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
    }
}
