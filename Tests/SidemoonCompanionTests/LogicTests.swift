import CoreGraphics
import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let margin: CGFloat = 10

@Suite struct EdgeSnapTests {
    @Test func picksNearestEdge() {
        #expect(EdgeSnap.nearestEdge(of: CGRect(x: 50, y: 380, width: 60, height: 60), in: screen) == .left)
        #expect(EdgeSnap.nearestEdge(of: CGRect(x: 900, y: 380, width: 60, height: 60), in: screen) == .right)
        #expect(EdgeSnap.nearestEdge(of: CGRect(x: 470, y: 20, width: 60, height: 60), in: screen) == .bottom)
        #expect(EdgeSnap.nearestEdge(of: CGRect(x: 470, y: 720, width: 60, height: 60), in: screen) == .top)
    }

    @Test func snapsFlushWithMargin() {
        let left = EdgeSnap.snapped(CGRect(x: 80, y: 300, width: 60, height: 60), in: screen, margin: margin)
        #expect(left == CGRect(x: 10, y: 300, width: 60, height: 60))
        let right = EdgeSnap.snapped(CGRect(x: 850, y: 300, width: 60, height: 60), in: screen, margin: margin)
        #expect(right == CGRect(x: 930, y: 300, width: 60, height: 60))
        let top = EdgeSnap.snapped(CGRect(x: 400, y: 700, width: 60, height: 60), in: screen, margin: margin)
        #expect(top == CGRect(x: 400, y: 730, width: 60, height: 60))
        let bottom = EdgeSnap.snapped(CGRect(x: 400, y: 30, width: 60, height: 60), in: screen, margin: margin)
        #expect(bottom == CGRect(x: 400, y: 10, width: 60, height: 60))
    }

    @Test func offScreenFrameComesBackOnScreen() {
        // Dragged mostly past the right edge and below the bottom: ends inside the visible frame.
        let f = EdgeSnap.snapped(CGRect(x: 980, y: -40, width: 60, height: 60), in: screen, margin: margin)
        #expect(screen.insetBy(dx: margin, dy: margin).contains(f))
    }

    @Test func respectsScreenOrigin() {
        let second = CGRect(x: 1000, y: 100, width: 800, height: 600)
        let f = EdgeSnap.snapped(CGRect(x: 1020, y: 300, width: 60, height: 60), in: second, margin: margin)
        #expect(f.minX == 1010)
    }

    @Test func bubbleGoesTowardTheRoomierSide() {
        let size = CGSize(width: 300, height: 200)
        let onRight = CGRect(x: 930, y: 400, width: 60, height: 60)
        let b1 = EdgeSnap.bubbleFrame(mascot: onRight, bubble: size, visible: screen, gap: 8, margin: margin)
        #expect(b1.maxX == onRight.minX - 8)
        #expect(b1.maxY == onRight.maxY)
        let onLeft = CGRect(x: 10, y: 400, width: 60, height: 60)
        let b2 = EdgeSnap.bubbleFrame(mascot: onLeft, bubble: size, visible: screen, gap: 8, margin: margin)
        #expect(b2.minX == onLeft.maxX + 8)
        // Near the bottom the bubble is pushed up to stay on screen.
        let low = CGRect(x: 10, y: 10, width: 60, height: 60)
        let b3 = EdgeSnap.bubbleFrame(mascot: low, bubble: size, visible: screen, gap: 8, margin: margin)
        #expect(b3.minY == 10)
    }

    @Test func findsScreenForPoint() {
        let screens = [screen, CGRect(x: 1000, y: 0, width: 800, height: 600)]
        #expect(EdgeSnap.screenIndex(for: CGPoint(x: 1200, y: 100), in: screens) == 1)
        #expect(EdgeSnap.screenIndex(for: CGPoint(x: -50, y: 100), in: screens) == 0)
        #expect(EdgeSnap.screenIndex(for: CGPoint(x: 1900, y: 700), in: screens) == 1)
        #expect(EdgeSnap.screenIndex(for: .zero, in: []) == nil)
    }
}

private func session(_ id: String, name: String? = nil, cwd: String? = nil, state: SessionState = .idle,
                     at: TimeInterval? = nil, kind: SessionKind = .unknown, channel: Bool = false) -> Session {
    var s = Session(id: id)
    s.name = name
    s.cwd = cwd
    s.state = state
    s.lastEventAt = at.map { Date(timeIntervalSince1970: $0) }
    s.kind = kind
    s.channelConnected = channel
    return s
}

@Suite struct SessionListTests {
    let a = "aaaaaaaa-0000-4000-8000-000000000001"
    let b = "bbbbbbbb-0000-4000-8000-000000000002"
    let c = "cccccccc-0000-4000-8000-000000000003"
    let d = "dddddddd-0000-4000-8000-000000000004"

    @Test func ordersByMostRecentAndHidesEnded() {
        let list = [session(a, at: 100), session(b, at: 300), session(c, state: .ended, at: 400), session(d)]
        #expect(SessionList.rows(list, showEnded: false).map(\.id) == [b, a, d])
        #expect(SessionList.rows(list, showEnded: true).map(\.id) == [c, b, a, d])
    }

    @Test func namesFallBackToFolderThenShortId() {
        #expect(SessionList.displayName(session(a, name: "fix login", cwd: "/x/proj")) == "fix login")
        #expect(SessionList.displayName(session(a, name: "  ", cwd: "/Users/me/proj")) == "proj")
        #expect(SessionList.displayName(session(a)) == "aaaaaaaa")
    }

    @Test func reachabilityFollowsRoutes() {
        let rows = SessionList.rows([
            session(a, at: 3, channel: true),
            session(b, state: .working, at: 2, kind: .background),
            session(c, at: 1, kind: .interactive),
        ], showEnded: false)
        // A busy background session still counts: a message waits for it. Only a terminal session
        // started without the channel cannot be reached.
        #expect(rows.map(\.reachable) == [true, true, false])
        #expect(rows[1].stateText == "working")
        #expect(rows[1].state == .working)
        #expect(!rows[0].menuTitle.contains("reachable"))
    }
}

@Suite struct StatusTests {
    @Test func happyPathWithReply() {
        var s = CompanionStatus()
        #expect(s.indicator == .idle)
        let ok1 = s.handle(.captureBegan)
        #expect(ok1)
        #expect(s.indicator == .sending)
        let ok2 = s.handle(.sendBegan)
        #expect(ok2)
        let ok3 = s.handle(.targetStartedWorking)
        #expect(ok3)
        #expect(s.indicator == .waiting)
        let ok4 = s.handle(.sendSucceeded(hasReply: true))
        #expect(ok4)
        #expect(s.indicator == .replyReady)
        s.handle(.bubbleOpened)
        #expect(s.indicator == .idle)
    }

    @Test func cancelReturnsToIdleWithoutSending() {
        var s = CompanionStatus()
        s.handle(.captureBegan)
        let ok5 = s.handle(.captureCancelled)
        #expect(ok5)
        #expect(s.activity == .idle)
        let ok6 = s.handle(.captureCancelled)
        #expect(!ok6)
    }

    @Test func heldCaptureBlocksAnotherAndCanSendOrDiscard() {
        var s = CompanionStatus()
        s.handle(.captureBegan)
        let held = s.handle(.captureHeld)
        #expect(held)
        #expect(s.activity.isBusy)
        #expect(s.indicator == .sending)
        let again = s.handle(.captureBegan)
        #expect(!again)
        var sending = s
        let sent = sending.handle(.sendBegan)
        #expect(sent)
        #expect(sending.activity == .sending)
        let discarded = s.handle(.heldCaptureDiscarded)
        #expect(discarded)
        #expect(s.activity == .idle)
    }

    @Test func noteCountdownCountsWholeTicks() {
        var c = NoteCountdown(total: 3, tick: 0.1)
        #expect(c.totalTicks == 30)
        #expect(c.secondsLeft == 3)
        #expect(c.fractionRemaining == 1)
        c.tick()
        #expect(c.secondsLeft == 3)
        for _ in 0..<9 { c.tick() }
        #expect(c.secondsLeft == 2)
        #expect(!c.isExpired)
        for _ in 0..<20 { c.tick() }
        #expect(c.isExpired)
        #expect(c.fractionRemaining == 0)
        c.tick()
        #expect(c.isExpired)
    }

    @Test func oneCaptureAtATimeButSendsDoNotBlock() {
        var s = CompanionStatus()
        s.handle(.sendBegan)
        // A message on its way does not stop another message or a capture.
        let secondSend = s.handle(.sendBegan)
        let capture = s.handle(.captureBegan)
        #expect(secondSend)
        #expect(capture)
        // A capture in progress does stop a second capture.
        let secondCapture = s.handle(.captureBegan)
        s.handle(.captureHeld)
        let captureWhileHeld = s.handle(.captureBegan)
        #expect(!secondCapture)
        #expect(!captureWhileHeld)
    }

    @Test func errorsShowAndClear() {
        var s = CompanionStatus()
        s.handle(.sendBegan)
        s.handle(.failed(.busy))
        #expect(s.indicator == .error)
        #expect(!s.activity.isBusy)
        let ok9 = s.handle(.errorDismissed)
        #expect(ok9)
        #expect(s.indicator == .idle)
    }

    @Test func unsolicitedReplyReplacesErrorButNotInFlightSend() {
        var s = CompanionStatus(activity: .failed(.noRoute))
        s.handle(.replyArrived)
        #expect(s.indicator == .replyReady)
        var busy = CompanionStatus(activity: .waiting)
        busy.handle(.replyArrived)
        #expect(busy.activity == .waiting)
        #expect(busy.unseenReply)
    }

    @Test func workingOnlyMattersWhileSending() {
        var s = CompanionStatus()
        let ok10 = s.handle(.targetStartedWorking)
        #expect(!ok10)
        #expect(s.activity == .idle)
    }
}

@Suite struct ErrorMappingTests {
    @Test func mapsEngineFailures() {
        func result(_ e: DeliveryError) -> SendResult { SendResult.failure(e) }
        #expect(CompanionError.from(result(.busy("x"))) == .busy)
        #expect(CompanionError.from(result(.noRoute("x"))) == .noRoute)
        #expect(CompanionError.from(result(.noScratchpad)) == .noScratchpad)
        #expect(CompanionError.from(result(.unknownSession("x"))) == .unknownSession)
        #expect(CompanionError.from(result(.replyTimeout)) == .replyTimeout)
        if case .delivery(let m) = CompanionError.from(result(.headless("boom"))) { #expect(m.contains("boom")) } else { Issue.record("expected delivery") }
        for e in [CompanionError.busy, .noRoute, .engineConflict, .noTarget] {
            #expect(!e.title.isEmpty && !e.advice.isEmpty)
        }
    }

    @Test func hotKeysIncludeControl() {
        let keys = CompanionConstants.HotKeys.self
        for spec in [keys.capture, keys.captureWithNote, keys.captureActiveWindow] {
            #expect(spec.modifiers.contains(.control))
        }
        #expect(keys.capture.displayName == "Control-Option-S")
        #expect(keys.captureActiveWindow.displayName == "Control-Option-A")
        #expect(Set([keys.capture.id, keys.captureWithNote.id, keys.captureActiveWindow.id]).count == 3)
        #expect(Set([keys.capture.keyCode, keys.captureWithNote.keyCode, keys.captureActiveWindow.keyCode]).count == 3)
        #expect(!CompanionError.noActiveWindow.title.isEmpty && !CompanionError.noActiveWindow.advice.isEmpty)
    }
}

@Suite struct ActiveWindowTests {
    private let app: pid_t = 500
    private let other: pid_t = 600
    private let me: pid_t = 700

    private func window(_ id: CGWindowID, _ pid: pid_t, layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, layer: layer, bounds: CGRect(origin: .zero, size: size))
    }

    @Test func picksFrontmostNormalWindowOfTheApp() {
        let list = [window(1, other), window(2, app, layer: 25), window(3, app), window(4, app)]
        #expect(ActiveWindow.pick(list, pid: app, excludedPID: me)?.id == 3)
    }

    @Test func skipsTinyWindows() {
        let list = [window(1, app, size: CGSize(width: 20, height: 20)), window(2, app, size: CGSize(width: 900, height: 30)),
                    window(3, app)]
        #expect(ActiveWindow.pick(list, pid: app, excludedPID: me)?.id == 3)
    }

    @Test func nilWhenNoWindowOfTheApp() {
        #expect(ActiveWindow.pick([window(1, other), window(2, me)], pid: app, excludedPID: me) == nil)
        #expect(ActiveWindow.pick([], pid: app, excludedPID: me) == nil)
        #expect(ActiveWindow.pick([window(1, app, layer: 3)], pid: app, excludedPID: me) == nil)
    }

    @Test func targetIsTheFrontmostAppsWindowWhenItHasOne() {
        let list = [window(1, other), window(2, app)]
        #expect(ActiveWindow.target(list, frontmostPID: app, excludedPID: me)?.id == 2)
    }

    /// Sidemoon itself is in front after one of its own dialogs, the front app has no window, or nothing reports as
    /// front-most: the window the user sees is the front-most ordinary one that is not Sidemoon's.
    @Test func targetFallsBackToTheFrontmostOrdinaryWindow() {
        let list = [window(1, me), window(2, other, layer: 25), window(3, other, size: CGSize(width: 20, height: 20)),
                    window(4, other), window(5, app)]
        #expect(ActiveWindow.target(list, frontmostPID: me, excludedPID: me)?.id == 4)
        #expect(ActiveWindow.target(list, frontmostPID: 999, excludedPID: me)?.id == 4)
        #expect(ActiveWindow.target(list, frontmostPID: nil, excludedPID: me)?.id == 4)
    }

    /// A failure with no words of its own keeps the engine's reason under the message; the others keep their title.
    @Test func aFailedMessageKeepsTheReason() {
        #expect(CompanionError.delivery("image: cannot read /x.png").threadNote == "Sending failed: image: cannot read /x.png")
        let long = String(repeating: "a", count: CompanionConstants.Messages.threadReasonCharacters + 40)
        #expect(CompanionError.delivery(long).threadNote.hasSuffix("…"))
        #expect(CompanionError.busy.threadNote == CompanionError.busy.title)
    }

    @Test func targetIsNilWhenOnlySidemoonHasWindows() {
        #expect(ActiveWindow.target([window(1, me)], frontmostPID: me, excludedPID: me) == nil)
        #expect(ActiveWindow.target([], frontmostPID: app, excludedPID: me) == nil)
    }

    @Test func neverPicksOwnWindows() {
        #expect(ActiveWindow.pick([window(1, me)], pid: me, excludedPID: me) == nil)
    }

    @Test func readsWindowServerEntries() {
        let entry: [String: Any] = [
            kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 500, kCGWindowLayer as String: 0,
            kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 300, height: 200).dictionaryRepresentation,
        ]
        #expect(WindowInfo(entry) == WindowInfo(id: 42, ownerPID: 500, layer: 0, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)))
        #expect(WindowInfo([kCGWindowNumber as String: 42]) == nil)
    }
}

@Suite struct PasteContentTests {
    @Test func decidesFromTheClipboardDescription() {
        let file = URL(fileURLWithPath: "/Users/me/report.pdf")
        // A screenshot copied with Command-Shift-Control-4.
        #expect(PasteContent.of(types: ["public.png", "public.tiff"], fileURLs: []) == .image(type: "public.png"))
        #expect(PasteContent.of(types: ["public.tiff"], fileURLs: []) == .image(type: "public.tiff"))
        // Plain text, and rich text that carries a picture of itself, paste as text exactly as before.
        #expect(PasteContent.of(types: ["public.utf8-plain-text"], fileURLs: []) == .text)
        #expect(PasteContent.of(types: ["public.rtf", "public.utf8-plain-text", "public.tiff"], fileURLs: []) == .text)
        // A browser's Copy Image adds HTML but no plain text: still an image.
        #expect(PasteContent.of(types: ["public.html", "public.png"], fileURLs: []) == .image(type: "public.png"))
        // Files copied in the Finder (their names come along as text).
        #expect(PasteContent.of(types: ["public.file-url", "public.utf8-plain-text"], fileURLs: [file]) == .files([file]))
        // Nothing known: left to the text field.
        #expect(PasteContent.of(types: [], fileURLs: []) == .text)
        #expect(PasteContent.of(types: ["com.example.private"], fileURLs: []) == .text)
    }
}

@Suite struct PendingCapturesTests {
    private let a = URL(fileURLWithPath: "/c/a.png"), b = URL(fileURLWithPath: "/c/b.png"), c = URL(fileURLWithPath: "/c/c.png")

    @Test func addsInOrderUpToTheLimit() {
        var p = PendingCaptures(limit: 2)
        #expect(p.isEmpty && !p.isFull)
        let first = p.add(a), second = p.add(b), overLimit = p.add(c), again = p.add(a)
        #expect(first && second && !overLimit && !again)
        #expect(p.urls == [a, b] && p.isFull)
        #expect(PendingCaptures().limit == CompanionConstants.Capture.maxPerMessage)
    }

    @Test func removesOneAndKeepsTheOrder() {
        var p = PendingCaptures()
        [a, b, c].forEach { p.add($0) }
        let removed = p.remove(b), twice = p.remove(b)
        #expect(removed && !twice)
        #expect(p.urls == [a, c])
        p.removeAll()
        #expect(p.isEmpty)
    }

    /// One capture is named and described as before; several are numbered and described in the plural.
    @Test func namesAndDefaultText() {
        var p = PendingCaptures()
        p.add(a)
        #expect(p.names == [CompanionConstants.Messages.captureAttachmentName])
        #expect(p.defaultText == CompanionConstants.Messages.defaultCaptureText)
        p.add(b)
        #expect(p.names == ["Capture 1", "Capture 2"])
        #expect(p.defaultText == CompanionConstants.Messages.defaultCapturesText)
    }
}
