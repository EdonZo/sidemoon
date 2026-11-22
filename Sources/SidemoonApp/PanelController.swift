import AppKit
import Observation
import SwiftUI
import SidemoonCompanion

/// A floating panel that never activates the app and only takes keyboard focus when allowed.
final class CompanionPanel: NSPanel {
    /// Off for the mascot. On for the bubble, which then becomes key only when the note field or the reply
    /// text is clicked (`becomesKeyOnlyIfNeeded`), or when the note hotkey explicitly focuses it.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        // Every Space, and on top of full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        // Keep the companion out of the user's own screenshots, unless the user asks otherwise (see `applySharing`).
        sharingType = .none
    }

    /// Cut, copy, paste, select all, undo and redo. macOS delivers these through the Edit menu of the active
    /// app, and this panel is used without its app ever being active, so they are sent to the focused field here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, let action = EditShortcut.action(for: event) else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// The standard editing shortcuts and the actions a text field answers to.
enum EditShortcut {
    static func action(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if flags == .command { return plain[key] }
        if flags == [.command, .shift] { return shifted[key] }
        return nil
    }

    static let plain: [String: Selector] = [
        "x": #selector(NSText.cut(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "a": #selector(NSText.selectAll(_:)),
        "z": Selector(("undo:")),
    ]
    static let shifted: [String: Selector] = ["z": Selector(("redo:"))]

    /// The same shortcuts as an Edit menu, for the app's ordinary windows (Setup), which do activate the app.
    @MainActor
    static func menu() -> NSMenu {
        let main = NSMenu()
        let item = NSMenuItem()
        let edit = NSMenu(title: Design.Copy.menuEdit)
        for (title, key) in Design.Copy.menuEditItems {
            guard let action = plain[key] else { continue }
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        if let redo = shifted["z"] {
            let entry = NSMenuItem(title: Design.Copy.menuRedo, action: redo, keyEquivalent: "z")
            entry.keyEquivalentModifierMask = [.command, .shift]
            edit.addItem(entry)
        }
        item.submenu = edit
        main.addItem(item)
        return main
    }
}

/// The mascot's content view: draws the SwiftUI mascot and handles click, drag and right-click itself.
final class MascotHostView: NSView {
    var onClick: () -> Void = {}
    var onDrag: (CGPoint) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onMenu: (NSEvent) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }
    private var pressPoint: CGPoint?
    private var pressOrigin: CGPoint = .zero
    private var dragging = false
    private let hover = MascotHover()

    init(model: CompanionModel) {
        let size = CompanionConstants.Layout.mascotSize
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let host = NSHostingView(rootView: MascotView(model: model, hover: hover))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Files dropped on the mascot

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        onDropFiles(files)
        return true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The panel never becomes key, so the pointer is tracked whatever app is active.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: lensRect, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    /// The part of the panel the lens is drawn in; the rest is clear room for its glow and takes no clicks.
    private var lensRect: CGRect {
        let inset = (CompanionConstants.Layout.mascotSize - Design.Mascot.drawnSize) / 2
        return bounds.insetBy(dx: inset, dy: inset)
    }

    override func mouseEntered(with event: NSEvent) { hover.isHovering = true }
    override func mouseExited(with event: NSEvent) { hover.isHovering = false }

    // All mouse events land here rather than in the SwiftUI view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let inside = superview?.convert(point, to: self) ?? Optional(point) else { return nil }
        return lensRect.contains(inside) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu(event); return }
        pressPoint = NSEvent.mouseLocation
        pressOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging, hypot(dx, dy) < CompanionConstants.Layout.dragThreshold { return }
        dragging = true
        onDrag(CGPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        if dragging { onDragEnd() } else { onClick() }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) { onMenu(event) }
}

/// Owns the two panels (mascot and bubble), their placement, and their persistence.
@MainActor
final class PanelController {
    let model: CompanionModel
    let mascot: CompanionPanel
    let bubble: CompanionPanel
    private let defaults: UserDefaults
    private let menuProvider: () -> NSMenu
    var bubbleActions: BubbleActions!

    init(model: CompanionModel, defaults: UserDefaults = .standard, menu: @escaping () -> NSMenu) {
        self.model = model
        self.defaults = defaults
        self.menuProvider = menu
        let layout = CompanionConstants.Layout.self
        mascot = CompanionPanel(size: CGSize(width: layout.mascotSize, height: layout.mascotSize))
        mascot.hasShadow = false
        bubble = CompanionPanel(size: CGSize(width: Design.Bubble.width, height: Design.Bubble.minHeight))
        bubble.allowsKey = true
    }

    /// The bubble's current height: it follows its content between the minimum and the maximum.
    private var bubbleHeight = Design.Bubble.minHeight

    /// The height the content last asked for, kept for when the size goes back to automatic.
    private var contentHeight = Design.Bubble.minHeight

    private func setBubbleHeight(_ wanted: CGFloat) {
        contentHeight = wanted
        let visible = visibleFrame(for: mascot.frame)
        let height: CGFloat
        if let custom = model.bubbleSize {
            // A size the user dragged out is kept as it is, as far as the screen allows; the content scrolls.
            height = min(custom.height, visible.height - CompanionConstants.Layout.edgeMargin * 2)
        } else {
            let limit = min(Design.Bubble.maxHeight, visible.height * Design.Bubble.maxScreenFraction)
            height = max(Design.Bubble.minHeight, min(wanted.rounded(.up), limit))
        }
        guard abs(height - bubbleHeight) >= 1 else { return }
        bubbleHeight = height
        if bubble.isVisible {
            placeBubble()
            bubble.invalidateShadow()
        }
    }

    func install(actions: BubbleActions) {
        bubbleActions = actions
        let host = MascotHostView(model: model)
        host.onClick = { [weak self] in
            guard let self else { return }
            // Opened by hand, the bubble takes the keyboard: type straight away, or use the arrows.
            wantsKeyOnOpen = !model.isExpanded
            model.toggleBubble()
        }
        host.onDrag = { [weak self] origin in self?.dragMascot(to: origin) }
        host.onDragEnd = { [weak self] in self?.snapMascot() }
        host.onMenu = { [weak self] event in self?.popUpMenu(with: event) }
        host.onDropFiles = { files in actions.dropFiles(files) }
        mascot.contentView = host
        let bubbleHost = NSHostingView(rootView: BubbleView(model: model, actions: actions) { [weak self] height in
            self?.setBubbleHeight(height)
        })
        // The panel sizes the content, not the other way round.
        bubbleHost.sizingOptions = []
        bubble.contentView = bubbleHost

        applyTheme()
        applySharing()
        mascot.setFrame(restoredMascotFrame(), display: false)
        mascot.orderFrontRegardless()
        observeModel()
        // The composer shows whether typing will reach it.
        for (name, hasKeyboard) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: bubble, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.hasKeyboard = hasKeyboard }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapMascot() }
        }
        syncBubble()
    }

    // MARK: Menu

    func popUpMenu(with event: NSEvent? = nil) {
        let menu = menuProvider()
        if let event, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: Placement

    private var screenFrames: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    private func visibleFrame(for frame: CGRect) -> CGRect {
        let frames = screenFrames
        guard let i = EdgeSnap.screenIndex(for: CGPoint(x: frame.midX, y: frame.midY), in: frames) else {
            return NSScreen.main?.visibleFrame ?? frame
        }
        return frames[i]
    }

    private func restoredMascotFrame() -> CGRect {
        let size = CompanionConstants.Layout.mascotSize, margin = CompanionConstants.Layout.edgeMargin
        let keys = CompanionConstants.Defaults.self
        if let x = defaults.object(forKey: keys.mascotOriginX) as? Double, let y = defaults.object(forKey: keys.mascotOriginY) as? Double {
            let saved = CGRect(x: x, y: y, width: size, height: size)
            return EdgeSnap.snapped(saved, in: visibleFrame(for: saved), margin: margin)
        }
        let main = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return EdgeSnap.defaultFrame(size: size, visible: main, margin: margin)
    }

    private func dragMascot(to origin: CGPoint) {
        mascot.setFrameOrigin(origin)
        if bubble.isVisible { placeBubble() }
    }

    private func snapMascot() {
        let target = EdgeSnap.snapped(mascot.frame, in: visibleFrame(for: mascot.frame), margin: CompanionConstants.Layout.edgeMargin)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = CompanionConstants.Timing.snapAnimation
            mascot.animator().setFrame(target, display: true)
        }
        defaults.set(Double(target.minX), forKey: CompanionConstants.Defaults.mascotOriginX)
        defaults.set(Double(target.minY), forKey: CompanionConstants.Defaults.mascotOriginY)
        if bubble.isVisible { placeBubble(mascotFrame: target) }
    }

    private func placeBubble(mascotFrame: CGRect? = nil) {
        let m = mascotFrame ?? mascot.frame
        let layout = CompanionConstants.Layout.self
        let visible = visibleFrame(for: m)
        let width = min(Design.Bubble.width, visible.width - layout.edgeMargin * 2)
        let frame = EdgeSnap.bubbleFrame(mascot: m, bubble: CGSize(width: width, height: bubbleHeight),
                                         visible: visible, gap: layout.bubbleGap, margin: layout.edgeMargin)
        bubble.setFrame(frame, display: true)
        // The resize grip sits on the corner away from the mascot, and needs to know which way that is.
        model.shownBubbleSize = frame.size
        let growsLeft = frame.midX < m.midX, growsUp = frame.midY > m.midY
        if model.bubbleGrowsLeft != growsLeft { model.bubbleGrowsLeft = growsLeft }
        if model.bubbleGrowsUp != growsUp { model.bubbleGrowsUp = growsUp }
    }

    // MARK: Model to windows

    private func observeModel() {
        withObservationTracking {
            _ = model.isExpanded
            _ = model.isEditingNote
            _ = model.isPickingSession
            _ = model.zoom
            _ = model.theme
            _ = model.isLarge
            _ = model.bubbleSize
            _ = model.visibleInRecordings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySharing()
                self?.applyZoom()
                self?.applyTheme()
                if let self { self.setBubbleHeight(self.contentHeight) }
                self?.syncBubble()
                self?.observeModel()
            }
        }
    }

    private var appliedZoom = Design.zoom

    /// Hidden from screen recordings and screen sharing by default; shown, read-only, when the user turns it on.
    private func applySharing() {
        let sharing: NSWindow.SharingType = model.visibleInRecordings ? .readOnly : .none
        for panel in [mascot, bubble] where panel.sharingType != sharing { panel.sharingType = sharing }
    }

    /// Brings the mascot back onto a screen the user can see (a display may have gone, or it was dragged off),
    /// in front, with the bubble open beside it.
    func reveal() {
        let margin = CompanionConstants.Layout.edgeMargin
        let frames = screenFrames
        let onScreen = frames.contains { $0.intersects(mascot.frame) }
        let main = NSScreen.main?.visibleFrame ?? mascot.frame
        let target = onScreen
            ? EdgeSnap.snapped(mascot.frame, in: visibleFrame(for: mascot.frame), margin: margin)
            : EdgeSnap.defaultFrame(size: CompanionConstants.Layout.mascotSize, visible: main, margin: margin)
        mascot.setFrame(target, display: true)
        defaults.set(Double(target.minX), forKey: CompanionConstants.Defaults.mascotOriginX)
        defaults.set(Double(target.minY), forKey: CompanionConstants.Defaults.mascotOriginY)
        mascot.orderFrontRegardless()
        model.openBubble()
        placeBubble(mascotFrame: target)
        bubble.orderFrontRegardless()
    }

    /// A theme that is always dark or always light draws its panels that way whatever the system setting.
    func applyTheme() {
        let theme = Design.theme
        let appearance = theme.isAlwaysDark ? NSAppearance(named: .darkAqua) : (theme.isAlwaysLight ? NSAppearance(named: .aqua) : nil)
        mascot.appearance = appearance
        bubble.appearance = appearance
        mascot.invalidateShadow()
        bubble.invalidateShadow()
    }

    /// The size setting changed: the mascot panel takes its new size, staying on its edge.
    private func applyZoom() {
        guard appliedZoom != Design.zoom else { return }
        appliedZoom = Design.zoom
        let side = CompanionConstants.Layout.mascotSize
        var frame = mascot.frame
        frame.origin.y += frame.height - side
        frame.size = CGSize(width: side, height: side)
        mascot.setFrame(frame, display: true)
        snapMascot()
    }

    private var wasEditingNote = false
    private var wantsKeyOnOpen = false

    private func syncBubble() {
        if model.isExpanded {
            placeBubble()
            bubble.orderFrontRegardless()
            // The session list is driven by the arrow keys, so it needs the keyboard too.
            if wantsKeyOnOpen || (model.isPickingSession && !bubble.isKeyWindow) { bubble.makeKey() }
        } else {
            bubble.orderOut(nil)
        }
        wantsKeyOnOpen = false
        if model.isEditingNote, !wasEditingNote {
            // The note hotkey is the one moment the companion may take the keyboard.
            bubble.makeKey()
        } else if !model.isEditingNote, wasEditingNote {
            releaseKeyboard()
        }
        wasEditingNote = model.isEditingNote
    }

    /// Keeps the keyboard in the open bubble.
    func takeKeyboard() {
        guard model.isExpanded, !bubble.isKeyWindow else { return }
        bubble.makeKey()
    }

    /// Gives keyboard focus back to the app the user was working in (ours was never activated).
    func releaseKeyboard() {
        guard bubble.isKeyWindow else { return }
        let visible = bubble.isVisible
        bubble.orderOut(nil)
        if visible { bubble.orderFrontRegardless() }
    }
}
