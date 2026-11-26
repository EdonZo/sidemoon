import CoreGraphics
import Foundation
import SidemoonCore

/// The visual system: warm paper-and-ink neutrals, one accent ("signal") that only ever means
/// live or needs-you, two typographic voices (content, and a small uppercase mono readout),
/// hairlines instead of boxes, fast small motion.
public enum Design {

    /// The user's size setting. Every size token below is multiplied by it, so text and layout grow
    /// together and stay sharp. Only written on the main thread, by the companion model.
    nonisolated(unsafe) public static var zoom: CGFloat = 1

    public enum Zoom {
        public static let minimum: Double = 0.8
        public static let maximum: Double = 1.6
        public static let step: Double = 0.1
        public static let standard: Double = 1
    }

    /// An sRGB colour with alpha, written as 0xRRGGBBAA.
    public struct Hex: Sendable, Equatable {
        public let value: UInt32
        public init(_ value: UInt32) { self.value = value }
        public var red: Double { Double((value >> 24) & 0xFF) / 255 }
        public var green: Double { Double((value >> 16) & 0xFF) / 255 }
        public var blue: Double { Double((value >> 8) & 0xFF) / 255 }
        public var alpha: Double { Double(value & 0xFF) / 255 }
    }

    /// A colour that adapts to appearance. `contrast` values apply when Increase Contrast is on.
    public struct Tone: Sendable, Equatable {
        public let light: Hex, dark: Hex
        public let lightContrast: Hex?, darkContrast: Hex?
        public init(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) {
            self.light = Hex(light)
            self.dark = Hex(dark)
            self.lightContrast = lightContrast.map(Hex.init)
            self.darkContrast = darkContrast.map(Hex.init)
        }
    }

    /// The look. Paper is always light and Terminal always dark; Mono follows the system's appearance.
    public enum Theme: String, CaseIterable, Sendable {
        case paper, terminal, mono

        public var title: String {
            switch self {
            case .paper: return "Paper"
            case .terminal: return "Terminal"
            case .mono: return "Mono"
            }
        }
        /// Terminal sets all its text in a monospaced face.
        public var isMonospaced: Bool { self == .terminal }
        public var isAlwaysDark: Bool { self == .terminal }
        /// Paper is a white page whatever the system setting.
        public var isAlwaysLight: Bool { self == .paper }
    }

    /// The user's theme. Only written on the main thread, by the companion model.
    nonisolated(unsafe) public static var theme: Theme = .paper
    /// The user's window size choice. Only written on the main thread, by the companion model.
    nonisolated(unsafe) public static var isLarge = false
    /// A window size the user dragged out, replacing the regular and large sizes. Only written on the main
    /// thread, by the companion model.
    nonisolated(unsafe) public static var customBubbleSize: CGSize?

    public enum Colors {
        private static func pick(_ paper: Tone, _ terminal: Tone, _ mono: Tone) -> Tone {
            switch Design.theme {
            case .paper: return paper
            case .terminal: return terminal
            case .mono: return mono
            }
        }
        /// One value for both appearances.
        private static func fixed(_ value: UInt32) -> Tone { Tone(light: value, dark: value) }

        /// Bubble base.
        public static var paper: Tone { pick(Tone(light: 0xFFFFFFFF, dark: 0x1F1A17FF), fixed(0x1F2128FF), Tone(light: 0xFFFFFFFF, dark: 0x000000FF)) }
        /// Code blocks and inline code.
        public static var paper2: Tone {
            pick(Tone(light: 0x6B4A2A14, dark: 0xF4ECDF12, lightContrast: 0x6B4A2A26, darkContrast: 0xF4ECDF29),
                 fixed(0xFFFFFF12), Tone(light: 0x0000000F, dark: 0xFFFFFF1F))
        }
        public static var ink: Tone { pick(Tone(light: 0x2A211CFF, dark: 0xF4ECDFFF), fixed(0xE4E6EBFF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF)) }
        /// Secondary text.
        public static var mute: Tone {
            pick(Tone(light: 0x7A6C5FFF, dark: 0xA39788FF, lightContrast: 0x54483DFF, darkContrast: 0xC9BDAEFF),
                 fixed(0x8E94A6FF), Tone(light: 0x5A5A5AFF, dark: 0xA6A6A6FF))
        }
        /// Hairlines.
        public static var line: Tone {
            pick(Tone(light: 0x2A211C1A, dark: 0xF4ECDF1F, lightContrast: 0x2A211C4D, darkContrast: 0xF4ECDF4D),
                 fixed(0xFFFFFF21), Tone(light: 0x00000033, dark: 0xFFFFFF40))
        }
        /// Bubble fill laid over the blur.
        public static var surface: Tone {
            pick(Tone(light: 0xFFFFFFF5, dark: 0x1F1A17EB, lightContrast: 0xFFFFFFFF, darkContrast: 0x1F1A17FF),
                 fixed(0x1F2128F5), Tone(light: 0xFFFFFFF7, dark: 0x000000F7))
        }
        /// The one accent: live, new reply, countdown. Mono has none; it uses ink.
        public static var signal: Tone {
            pick(Tone(light: 0xC2305AFF, dark: 0xFF7D9CFF, lightContrast: 0x9E1F45FF, darkContrast: 0xFFA3B8FF),
                 fixed(0xA9B1F7FF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF))
        }
        /// Selection and focus wash.
        public static var signalSoft: Tone { pick(Tone(light: 0xC2305A29, dark: 0xFF7D9C33), fixed(0xA9B1F733), Tone(light: 0x00000026, dark: 0xFFFFFF33)) }
        /// The card behind what the user sent. Paper tints it with the accent; the others keep it quiet.
        public static var sent: Tone { pick(Tone(light: 0xC2305A21, dark: 0xFF7D9C1F), fixed(0xFFFFFF12), Tone(light: 0x0000000F, dark: 0xFFFFFF1F)) }
        public static var error: Tone { pick(Tone(light: 0xD92D20FF, dark: 0xFF6B5EFF), fixed(0xFF7A70FF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF)) }
        /// Inner top highlight on the bubble.
        public static var highlight: Tone { pick(Tone(light: 0xFFFFFF66, dark: 0xFFFFFF14), fixed(0xFFFFFF14), Tone(light: 0xFFFFFF00, dark: 0xFFFFFF00)) }

        /// The lens: translucent over the blurred desktop behind it.
        public static var mascotBody: Tone {
            // Paper: the plum night of the app icon, so the mark stands out on a white page and on any desktop.
            pick(Tone(light: 0x3A2150F2, dark: 0x3A2150F2, lightContrast: 0x2B1B3DFF, darkContrast: 0x2B1B3DFF),
                 fixed(0x1F2128D9), Tone(light: 0xFFFFFFEB, dark: 0x000000EB))
        }
        public static var mascotEdge: Tone { pick(fixed(0xFF7D9C66), fixed(0xFFFFFF33), Tone(light: 0x00000059, dark: 0xFFFFFF66)) }
        /// The orbit, the centre point and the resting dot.
        public static var mascotMark: Tone { pick(fixed(0xFBEFEAFF), fixed(0xE4E6EBFF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF)) }
        /// The orbit, the moon and the glow: the icon's pink on Paper, the theme's own accent elsewhere.
        public static var mascotAccent: Tone { pick(fixed(0xFF7D9CFF), fixed(0xA9B1F7FF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF)) }
        /// The bar shown on a problem, light enough to read on the plum.
        public static var mascotProblem: Tone { pick(fixed(0xFF9A8AFF), fixed(0xFF7A70FF), Tone(light: 0x000000FF, dark: 0xFFFFFFFF)) }
        public static var mascotShadow: Tone { Tone(light: 0x0D0D0D21, dark: 0x00000073) }
    }

    public enum TypeScale {
        public static var label: CGFloat { 10.5 * Design.zoom }
        public static var labelTracking: CGFloat { 0.5 * Design.zoom }
        public static var body: CGFloat { 14 * Design.zoom }
        public static var bodyLineSpacing: CGFloat { 4 * Design.zoom }
        public static var small: CGFloat { 12 * Design.zoom }
        public static var h1: CGFloat { 17 * Design.zoom }
        public static var h2: CGFloat { 15 * Design.zoom }
        public static var code: CGFloat { 12 * Design.zoom }
        public static var codeLineSpacing: CGFloat { 3 * Design.zoom }
        public static var inlineCode: CGFloat { 12.5 * Design.zoom }
        public static var table: CGFloat { 12.5 * Design.zoom }
        public static var keycap: CGFloat { 11 * Design.zoom }
        public static var headingTracking: CGFloat { -0.2 * Design.zoom }
    }

    public enum Space {
        public static var xxs: CGFloat { 2 * Design.zoom }
        public static var xs: CGFloat { 4 * Design.zoom }
        public static var s: CGFloat { 6 * Design.zoom }
        public static var m: CGFloat { 8 * Design.zoom }
        public static var l: CGFloat { 12 * Design.zoom }
        public static var xl: CGFloat { 16 * Design.zoom }
        public static var xxl: CGFloat { 24 * Design.zoom }
        public static var bubbleHorizontal: CGFloat { 14 * Design.zoom }
        public static var bubbleVertical: CGFloat { 12 * Design.zoom }
    }

    public enum Radius {
        public static var inlineCode: CGFloat { 4 * Design.zoom }
        public static var control: CGFloat { 6 * Design.zoom }
        public static var card: CGFloat { 10 * Design.zoom }
        public static var panel: CGFloat { 14 * Design.zoom }
    }

    public enum Motion {
        public static let quick: TimeInterval = 0.12
        public static let fast: TimeInterval = 0.20
        public static let base: TimeInterval = 0.32
        public static let slow: TimeInterval = 0.48
        /// Control points of the ease-out curve.
        public static let easeOut: (Double, Double, Double, Double) = (0.16, 1, 0.3, 1)
        public static let pressScale: CGFloat = 0.97
        public static let press: TimeInterval = 0.11
        /// One left-right drift of the pupil while waiting.
        public static let waitingDrift: TimeInterval = 1.6
        public static let reducedMotionFade: TimeInterval = 0.15
        /// One pass of the working dots.
        public static let workingCycle: TimeInterval = 1.2
    }

    /// Bubble structure.
    public enum Bubble {
        /// The dashed outline of a message that was cancelled and never sent.
        public static let cancelledDash: [CGFloat] = [4, 3]
        public static let cancelledOutline: CGFloat = 1.2
        public static var width: CGFloat { Design.customBubbleSize?.width ?? (Design.isLarge ? 640 : 400) * Design.zoom }
        /// The smallest and largest window a drag can make.
        public static let customMinimum = CGSize(width: 300, height: 220)
        public static let customMaximum = CGSize(width: 1800, height: 1600)
        /// The corner grip that resizes the window.
        public static var gripSize: CGFloat { 16 * Design.zoom }
        /// The outline of the composer while it has the keyboard.
        public static var focusRing: CGFloat { 1.5 * Design.zoom }
        public static var minHeight: CGFloat { 150 * Design.zoom }
        public static var maxHeight: CGFloat { (Design.isLarge ? 900 : 560) * Design.zoom }
        /// The bubble never takes more than this share of the visible screen height.
        public static var maxScreenFraction: CGFloat { Design.isLarge ? 0.85 : 0.6 }
        public static var headerHeight: CGFloat { 32 * Design.zoom }
        public static var pillHeight: CGFloat { 22 * Design.zoom }
        public static var iconSize: CGFloat { 13 * Design.zoom }
        public static var hairline: CGFloat { 1 * Design.zoom }
        public static var countdownBarHeight: CGFloat { 2 * Design.zoom }
        public static var keycapHeight: CGFloat { 22 * Design.zoom }
        public static var buttonHeight: CGFloat { 28 * Design.zoom }
        public static var errorDot: CGFloat { 6 * Design.zoom }
        /// Space between entries of the thread.
        public static var entrySpacing: CGFloat { 16 * Design.zoom }
        public static var entryPadding: CGFloat { 10 * Design.zoom }
        public static var chipIcon: CGFloat { 10 * Design.zoom }
        public static var chipMaxWidth: CGFloat { 180 * Design.zoom }
        public static var sendButton: CGFloat { 24 * Design.zoom }
        public static var dropOutline: CGFloat { 2 * Design.zoom }
        /// The Stop control in the header: outlined in the problem colour, faintly.
        public static let stopOutlineOpacity: Double = 0.5
        /// Width of the label column in the settings.
        public static var settingsLabel: CGFloat { 76 * Design.zoom }
        /// The three dots shown while the session works on its answer.
        public static let workingDots = 3
        public static var workingDot: CGFloat { 4 * Design.zoom }
        public static var workingDotGap: CGFloat { 3 * Design.zoom }
        public static let workingDotMinOpacity: Double = 0.25
        /// A session that cannot be reached is drawn this faint in the session list.
        public static let unreachableOpacity: Double = 0.6
        /// A hidden session, listed while "Show hidden" is on.
        public static let hiddenOpacity: Double = 0.5
        /// The small symbol buttons a session row shows under the pointer.
        public static var rowActionIcon: CGFloat { 12 * Design.zoom }
        /// The new-session form's message field: a few lines before it scrolls.
        public static let messageFieldLines = 1...4
    }

    /// The window offering to move Sidemoon into Applications.
    public enum Move {
        public static var width: CGFloat { 440 * Design.zoom }
    }

    /// The "Try it" guide.
    public enum Guide {
        public static let steps = 3
        /// The circle that holds a step's number or its tick.
        public static var mark: CGFloat { 18 * Design.zoom }
        public static var markIcon: CGFloat { 9 * Design.zoom }
        /// The shortcut drawn large, while it is the one thing the guide asks for.
        public static var heroKeycap: CGFloat { 44 * Design.zoom }
        public static var heroKeycapText: CGFloat { 20 * Design.zoom }
        public static var heroKeycapRadius: CGFloat { 10 * Design.zoom }
        public static var heroTitle: CGFloat { 16 * Design.zoom }
    }

    /// The setup window.
    public enum Setup {
        public static var width: CGFloat { 560 * Design.zoom }
        /// The window never takes more than this share of the visible screen height; the rest scrolls.
        public static let maxScreenFraction: CGFloat = 0.9
        public static var padding: CGFloat { 28 * Design.zoom }
        /// Space between steps.
        public static var stepSpacing: CGFloat { 22 * Design.zoom }
        /// The column holding each step's number and status mark.
        public static var markColumn: CGFloat { 26 * Design.zoom }
        public static var mark: CGFloat { 20 * Design.zoom }
        public static var markStroke: CGFloat { 1.25 * Design.zoom }
        public static var markIcon: CGFloat { 9 * Design.zoom }
        public static var title: CGFloat { 22 * Design.zoom }
    }

    /// Rendered Markdown.
    public enum Prose {
        public static var paragraphSpacing: CGFloat { 8 * Design.zoom }
        public static var h1Before: CGFloat { 14 * Design.zoom }
        public static var h1After: CGFloat { 6 * Design.zoom }
        public static var h2Before: CGFloat { 12 * Design.zoom }
        public static var h2After: CGFloat { 4 * Design.zoom }
        public static var listItemSpacing: CGFloat { 4 * Design.zoom }
        public static var listIndent: CGFloat { 16 * Design.zoom }
        public static var bulletSize: CGFloat { 4 * Design.zoom }
        public static var numberColumn: CGFloat { 18 * Design.zoom }
        public static var numberGap: CGFloat { 6 * Design.zoom }
        public static var codePaddingVertical: CGFloat { 10 * Design.zoom }
        public static var codePaddingHorizontal: CGFloat { 12 * Design.zoom }
        public static var quoteBar: CGFloat { 2 * Design.zoom }
        public static var quoteIndent: CGFloat { 12 * Design.zoom }
        public static var tableCellVertical: CGFloat { 6 * Design.zoom }
        /// A table column is as wide as its longest cell, up to this; longer cells wrap.
        public static var tableColumnMax: CGFloat { 200 * Design.zoom }
        public static var tableColumnMin: CGFloat { 28 * Design.zoom }
        /// The narrowest a column is squeezed to when the table has to fit the bubble.
        public static var tableColumnWrapMin: CGFloat { 72 * Design.zoom }
        /// Space between columns.
        public static var tableColumnGap: CGFloat { 14 * Design.zoom }
        /// Added to a measured column so its text never wraps by a hair.
        public static var tableColumnSlack: CGFloat { 4 * Design.zoom }
        public static var tableCellHorizontal: CGFloat { 10 * Design.zoom }
        public static var ruleSpacing: CGFloat { 12 * Design.zoom }
        public static var linkUnderlineOffset: CGFloat { 3 * Design.zoom }
    }

    /// The mascot: a glass lens holding a fine-line mark. A solid centre point is the user; a small dot
    /// on a hairline orbit is the companion that tags along. Drawn on a 64-unit grid, origin top-left, y down.
    public enum Mascot {
        public static let grid: CGFloat = 64
        /// Drawn size inside the mascot panel, leaving room for the shadow.
        public static var drawnSize: CGFloat { 54 * Design.zoom }
        public static let center = CGPoint(x: 32, y: 32)
        /// The glass disc everything sits in.
        public static let discRadius: CGFloat = 26
        public static let edgeStroke: CGFloat = 1
        /// The orbit: a hairline circle, in points so it stays fine at any size.
        public static let orbitRadius: CGFloat = 14
        public static let orbitStroke: CGFloat = 1
        public static let orbitStrokeActive: CGFloat = 1.75
        public static let orbitStrokeResting: CGFloat = 1.5
        public static let orbitTrackOpacity: Double = 0.18
        /// The centre point: the user and their work.
        public static let coreRadius: CGFloat = 4.5
        public static let coreRadiusCapturing: CGFloat = 2.5
        /// The centre becomes a short bar when something went wrong.
        public static let coreProblem = CGSize(width: 10, height: 2.5)
        /// The companion: a small dot on the orbit.
        public static let satelliteRadius: CGFloat = 2.75
        public static let satelliteRadiusReply: CGFloat = 3.5
        /// Where the satellite rests, in degrees clockwise from three o'clock.
        public static let restAngle: Double = -45
        /// Seconds per orbit while sending and while waiting for the answer.
        public static let sendingPeriod: TimeInterval = 0.9
        public static let waitingPeriod: TimeInterval = 1.8
        /// The orbit swells once when a reply lands.
        public static let replyPulseScale: CGFloat = 1.14
        /// Viewfinder brackets while capturing: dash and gap as fractions of a quarter circumference.
        public static let bracketDash: CGFloat = 0.6
        public static let bracketGap: CGFloat = 0.4
        public static let shadowRadius: CGFloat = 5
        public static let shadowOffsetY: CGFloat = 1.6
        public static let reducedMotionWaitingOpacity: Double = 0.5
        /// Under the pointer the lens lifts a little, lights its edge, and the dot takes one lap while a shine crosses.
        public static let hoverScale: CGFloat = 1.07
        /// After Setup, and when Sidemoon is opened again, the lens swells and glows a few times so the eye finds it.
        public static let attentionPulses = 3
        public static let attentionPulseDuration: TimeInterval = 0.45
        /// The badge that counts sessions with something waiting for the user: a circle for one digit, a pill for
        /// two characters ("9+"), its ring and shadow setting it off the lens and the desktop behind.
        public static var badgeSize: CGFloat { 18 * Design.zoom }
        public static var badgeText: CGFloat { 11 * Design.zoom }
        /// Room either side of the number, so "9+" sits inside the pill instead of touching its ring.
        public static var badgePadding: CGFloat { 4.5 * Design.zoom }
        public static var badgeRing: CGFloat { 1.5 * Design.zoom }
        public static var badgeShadowRadius: CGFloat { 1.5 * Design.zoom }
        public static let badgeShadowOpacity: Double = 0.35
        /// Where the badge's centre sits: on the lens's upper right, this many grid units outside its rim, so it
        /// overlaps the rim without covering the companion dot resting there (`restAngle`).
        public static let badgeRimOffset: CGFloat = 5
        public static let badgeAngle: Double = -45
        /// The badge centre's offset from the lens centre, in points.
        public static var badgeOffset: CGSize {
            let distance = (discRadius + badgeRimOffset) * drawnSize / grid
            let radians = badgeAngle * .pi / 180
            return CGSize(width: distance * cos(radians), height: distance * sin(radians))
        }
        public static let badgePulseScale: CGFloat = 1.1
        public static let badgePulseDuration: TimeInterval = 0.9
        /// Counts above this show as this number and a plus.
        public static let badgeMaxCount = 9
        public static let hoverLapDuration: TimeInterval = 0.85
        public static let hoverGlowRadius: CGFloat = 6
        public static let hoverGlowOpacity: Double = 0.55
        public static let shineDuration: TimeInterval = 0.75
        /// The shine band: its width as a fraction of the disc, its peak opacity and its tilt in degrees.
        public static let shineWidth: CGFloat = 0.42
        public static let shineOpacity: Double = 0.6
        public static let shineTilt: Double = 24
        /// A wash of the accent inside the lens, so the mark is never plain black on white.
        public static let tintOpacity: Double = 0.3
    }

    public enum Copy {
        public static func openFile(_ path: String) -> String { "Open \(path)" }
        public static func showInFinder(_ path: String) -> String { "Show \(path) in Finder" }
        public static let showInFinderTitle = "Show in Finder"
        public static func earlierMessages(_ count: Int) -> String {
            count == 1 ? "Show 1 earlier message" : "Show earlier messages (\(count))"
        }
        public static let retry = "Retry"
        public static let resizeHelp = "Drag to resize. Double-click to go back to the automatic size."
        public static let windowCustom = "Custom"
        public static let retryHelp = "Send this message again"
        public static let menuSettings = "Settings…"
        public static let menuEdit = "Edit"
        /// Edit menu titles with the key each answers to.
        public static let menuEditItems: [(String, String)] = [("Undo", "z"), ("Cut", "x"), ("Copy", "c"), ("Paste", "v"), ("Select All", "a")]
        public static let menuRedo = "Redo"
        public static func waitingBadge(_ count: Int) -> String { count == 1 ? "1 session is waiting for you" : "\(count) sessions are waiting for you" }
        public static let notConnectedTitle = "Not connected to Claude Code yet"
        public static let setupPendingTitle = "Setup is not finished"
        public static let setupPendingAdvice = "Screen capture is not allowed yet, so screenshots cannot be sent. Open Setup to finish."
        public static let notConnectedAdvice = "You can send to a session, but its answers will not come back here until you connect."
        public static let menuRetryEngine = "Retry Engine"
        public static var menuQuit: String { "Quit \(CompanionConstants.App.name)" }
        public static func menuHotKeyTaken(_ key: String) -> String { "\(key) is taken by another app" }
        public static let stateReady = "Ready"
        public static let stateCapturing = "Capturing"
        public static let stateNote = "Add a note"
        public static let stateSending = "Sending"
        public static let stateWaiting = "Waiting"
        public static let stateNewReply = "New reply"
        public static let stateProblem = "Problem"
        public static let noSession = "Choose session"
        public static let empty = "Nothing yet."
        public static let emptyNoSession = "Choose the session that should see your screen."
        public static let emptyNoSessionsAtAll = "There are no Claude Code sessions yet. Start one here: pick a folder "
            + "and say what it should do first."
        public static func emptyHint(session: String) -> String { "show \(session) what you see." }
        public static let notePlaceholder = "Add a note, or let it send"
        public static let askPlaceholder = "Ask or reply"
        public static let regionNotePlaceholder = "Add a note, then Return to pick the region"
        public static let you = "You"
        public static let sending = "Sending"
        public static let working = "Working"
        public static let queued = "Waiting its turn"
        public static let cancel = "Cancel"
        public static let remove = "Take it back"
        public static let sendTo = "Send to"
        public static let noSessions = "No sessions yet. Start one here, or start Claude Code in a terminal and it shows up here."
        public static let needsYou = "Needs you"
        public static let ended = "Ended"
        public static let showEnded = "Show ended"
        public static let startup = "Startup"
        public static let history = "History"
        public static let clearHistory = "Clear conversations"
        public static let clearHistoryHelp = "Remove the saved conversations from this Mac. The sessions themselves are not touched."
        public static var interruptedByRestart: String { "\(CompanionConstants.App.name) was restarted before this went out" }
        public static let openAtLogin = "Open at login"
        public static let openAtLoginHelp = "Start \(CompanionConstants.App.name) when you log in to your Mac"
        public static var openAtLoginChoice: String { "Open \(CompanionConstants.App.name) when I log in" }
        public static let hideEnded = "Hide ended"
        public static let shortReplies = "Short replies"
        public static let shortRepliesHelp = "Ask the session to answer each message briefly, like in conversation"
        public static let size = "Size"
        public static let settings = "Settings"
        public static let theme = "Theme"
        public static let window = "Window"
        public static let windowRegular = "Regular"
        public static let windowLarge = "Large"
        public static let replies = "Replies"
        public static let sessions = "Sessions"
        public static let shortcuts = "Shortcuts"
        public static let done = "Done"
        public static let settingsHelp = "Settings: theme, size, window"
        public static let enlargeHelp = "Larger window"
        public static let shrinkHelp = "Smaller window"
        public static let minimizeHelp = "Minimize to the mascot"
        public static let smaller = "Smaller"
        public static let larger = "Larger"
        public static let actualSize = "Actual size"
        public static let notDelivered = "Not delivered"
        public static let sendHelp = "Send (Return)"
        public static let dropHere = "Drop to send"
        public static func sendsIn(_ seconds: Int) -> String { "Sends in \(seconds)" }
        public static let returnSends = "Return sends · Esc cancels"
        public static let copy = "Copy"
        public static let copied = "Copied"
        public static let dismiss = "Dismiss"
        public static let copyHelp = "Copy the reply"
        public static let captureHelp = "Capture a region and send"
        public static let sessionHelp = "Choose which session gets your captures"
        public static let keycaps = ["⌃", "⌥", "A"]
        public static let shortcutActiveWindow = "Send the active window"
        public static let shortcutRegion = "Send a region"
        public static let shortcutRegionNote = "Send a region with a note"
        public static let setup = "Setup"
        public static let openSetup = "Open setup"
        public static let setupMenuItem = "Setup…"
        public static let updates = "Updates"
        public static let checkAutomatically = "Check automatically"
        public static var checkAutomaticallyHelp: String { "Let \(CompanionConstants.App.name) look for a new version every day" }
        public static let checkNow = "Check now"
        public static let menuCheckForUpdates = "Check for Updates…"
        public static let app = "App"
        public static let quitHelp = "Close the companion. Your conversations are saved first."
        public static let menuNoSessions = "No live sessions. Start Claude Code, or open Setup to connect it."

        /// A session Claude Code will not reopen: what happened, in plain words, and what to do.
        public enum Unreachable {
            public static func title(_ blocker: ResumeBlocker) -> String {
                switch blocker {
                case .homeFolder: return "This session cannot be reached from here"
                case .untrustedFolder: return "This session's folder is not trusted yet"
                case .noTranscript: return "This session never answered"
                case .loginNeeded: return "This session needs a login"
                case .waitingInTerminal: return "This session is waiting for you in Terminal"
                }
            }

            public static func advice(_ blocker: ResumeBlocker, messageSaved: Bool, stoppedFirst: Bool = false) -> String {
                let why: String
                switch blocker {
                case .homeFolder:
                    why = "It was started in your home folder, and Claude Code only opens a session there from a terminal. "
                        + "Open it in Terminal with the button below and carry on there."
                case .untrustedFolder:
                    why = "Claude Code has not been told it may work in this session's folder. Reopen the session in a terminal "
                        + "with the button below and answer yes when it asks, then try again."
                case .noTranscript:
                    why = "It stopped before it finished its first answer, so there is no conversation to pick up. "
                        + "Choose another session, or start a new one."
                case .loginNeeded:
                    why = "Claude Code is signed out, or its sign-in has expired, so the session cannot answer until you sign in again."
                case .waitingInTerminal:
                    why = waitingInTerminalAdvice
                }
                return [why, stoppedFirst ? stoppedNote : nil, messageSaved ? savedNote : nil].compactMap { $0 }.joined(separator: " ")
            }

            /// A session that has not started because Claude Code asks something first (a new MCP server, say). Also
            /// shown when a session Sidemoon just started turns out to be waiting like that.
            public static let waitingInTerminalAdvice = "Claude Code is asking a question in this session before it can start. "
                + "Open it in Terminal and answer it, then send again."

            public static let savedNote = "Claude Code kept your message and will pass it on the next time this session starts."
            /// Claude Code refused only after Sidemoon had stopped the running session to deliver the message.
            public static let stoppedNote = "Sidemoon had already stopped it; it starts again when you reopen it."

            /// A terminal session started with plain `claude`: the channel that reaches it is not loaded.
            public static let noChannelTitle = "This session was started without sidemoon-claude"
            public static let noChannelAdvice = "Sidemoon can only reach a terminal session that was started with sidemoon-claude. "
                + "Reopen it with the button below, then pick it again."
            /// The short reason such a session is greyed out in the session list.
            public static let noChannelReason = "Started without sidemoon-claude"

            /// Sidemoon's connection to the session was confirmed, but Claude Code never took the message in: it
            /// runs the session in a process that does not pass on what the connection sends.
            public static let notPickedUpTitle = "Claude Code did not pick up the message"
            public static let notPickedUpWhy = "It moved this session to the background, where the Sidemoon connection is not passed on."
            public static func notPickedUpAdvice(retryGoesInBackground: Bool) -> String {
                notPickedUpWhy + " " + (retryGoesInBackground
                    ? "Retry sends it the way Sidemoon reaches background sessions: it restarts the session with your message."
                    : "Nothing else reaches it while it runs there. Reopen it with the button below, then pick it again.")
            }
            /// The short reason such a session is greyed out in the session list.
            public static let notPickedUpReason = "Sidemoon connection not passed on"

            /// The short reason a session is greyed out in the session list.
            public static func reason(_ blocker: ResumeBlocker) -> String {
                switch blocker {
                case .homeFolder: return "Started in your home folder"
                case .untrustedFolder: return "Folder not trusted yet"
                case .noTranscript: return "Never answered"
                case .loginNeeded: return "Needs a login"
                case .waitingInTerminal: return "Waiting for you in Terminal"
                }
            }

            /// A session whose folder was moved or deleted.
            public static let folderGoneTitle = "This session's folder no longer exists"
            public static func folderGoneAdvice(_ folder: String) -> String {
                let named = folder.isEmpty ? "Its folder" : "Its folder, \(folder),"
                return "\(named) was moved or deleted, so this session cannot be reopened. Choose another session."
            }
            /// The short reason such a session is greyed out in the session list.
            public static let folderGoneReason = "Folder no longer exists"
            /// Printed in Terminal, followed by the folder, when the reopen script cannot go to the session's folder.
            public static let scriptFolderFailed = "Sidemoon could not reopen this session: its folder no longer exists:"

            /// Offered with a session started with plain claude while "Connect every claude" is off.
            public static let connectEveryClaude = "Connect every claude"
            public static let connectEveryClaudeNote = "Connect every claude, in Setup, makes the plain claude command connect "
                + "too, from the next terminal window you open."

            public static let copyCommand = "Copy the command"
            public static let openInTerminal = "Open in Terminal"
            public static let openedInTerminal = "Opened"
            public static let openInTerminalHelp = "Opens the Terminal app and reopens this session there. Nothing to type."
            /// "Open in Terminal" for a session waiting on a question: it shows the session itself, question and all.
            public static let attachInTerminalHelp = "Opens the Terminal app on this session, where Claude Code's question is waiting."
            public static let installCommand = "Install the terminal command"
            public static let installCommandNote = "The command is not installed yet. Setup installs it in one click."
            public static let chooseAnother = "Choose another session"
            public static let runLogin = "Type /login in that session's terminal, then try again."
            public static let details = "Details"
            public static let hideDetails = "Hide details"
            public static let commandHelp = "Paste this in a terminal and pick the session from the list"
        }

        /// The "Try it" guide shown in the bubble once Setup is finished.
        public enum Guide {
            public static let heading = "Try it"
            public static let stepPick = "Pick the session to talk to"
            public static let stepSend = "Send the window you are looking at"
            public static let stepReply = "Read the answer here and reply"
            public static let pickButton = "Choose session"
            /// The one move, before anything else is explained.
            public static let heroTitle = "Press this now, in any app"
            public static func heroBody(session: String, seconds: Int) -> String {
                "It sends the window you are looking at to \(session). You get \(seconds) seconds to type a note, "
                    + "or press Return to send at once. The answer shows up here."
            }
            public static let heroNoSession = "First choose the session to talk to. Then press the keys above in any app."
            public static let heroNoSessions = "There is no Claude Code session yet. Start one here first, then press the "
                + "keys above in any app."
            public static let testMessageButton = "Send a test message"
            public static let video = "Watch the 45-second video"
            public static let terminalNote = "A session you start in a terminal needs sidemoon-claude. Setup installs it."
            public static let dismiss = "Hide guide"
            public static let doneHeading = "You are all set"
            public static let doneButton = "Close guide"
            public static let stepDone = "Done"
            public static func progress(_ done: Int) -> String { "\(done) of \(Design.Guide.steps)" }
        }

        public static let guide = "Guide"
        public static let showGuide = "Show guide"
        public static func emptyThread(session: String) -> String { "Nothing with \(session) yet." }
        public static let emptyShortcut = "sends the window you are looking at."
        public static let emptyOrType = "Or type a question below."

        /// The setup window. Plain sentences that say what each button changes.
        public enum Setup {
            public static let windowTitle = "Set up Sidemoon"
            public static let heading = "Set up Sidemoon"
            public static let intro = "Sidemoon sends what is on your screen to Claude Code and shows the answer beside your work. "
                + "These steps get it ready. Each one says what it changes on your Mac."
            public static let optional = "Optional"
            public static let stateChecking = "Checking"
            public static let stateDone = "Done"
            public static let stateNotDone = "Not yet"
            public static let stateProblem = "Needs attention"

            public static let claudeTitle = "Claude Code"
            public static let claudeChecking = "Looking for Claude Code…"
            public static func claudeFound(_ path: String) -> String { "Found at \(path)." }
            public static let claudeMissing = "Claude Code is not installed, or Sidemoon cannot find it. Install it, then come back "
                + "here. The other steps work without it."
            public static func claudeOutsideReach(_ path: String, places: [String]) -> String {
                "Found at \(path), but Sidemoon only starts Claude Code from \(places.joined(separator: ", ")). "
                    + "Sending to a session running in the background may fail until it is in one of those places."
            }
            public static let getClaude = "Get Claude Code"

            public static let connectTitle = "Connect to Claude Code"
            public static func connectExplain(_ file: String) -> String {
                "Connect adds a few lines to \(file), so Claude Code tells Sidemoon when a session starts, answers or ends. "
                    + "A backup copy of that file is saved next to it first. Nothing else in it changes."
            }
            public static func connected(_ file: String) -> String {
                "Connected through \(file). Disconnect removes only Sidemoon's lines, after another backup."
            }
            public static let connectIncomplete = "Only partly connected. Repair adds what is missing, after a backup."
            public static func connectOtherCopy(_ path: String) -> String {
                "Connected to another copy of Sidemoon at \(path). Repair switches it to this app, after a backup."
            }
            public static func connectMissingCopy(_ path: String) -> String {
                "Connected to a copy of Sidemoon that is no longer there (\(path)), so nothing arrives. "
                    + "Repair switches it to this app, after a backup."
            }
            public static func connectUnreadable(_ file: String, reason: String) -> String {
                "\(file) could not be read, so Sidemoon left it alone. Fix the file, then check again. (\(reason))"
            }
            public static let connect = "Connect"
            public static let repair = "Repair"
            public static let disconnect = "Disconnect"
            public static func backupSaved(_ path: String) -> String { "Backup saved at \(path)." }

            public static let captureTitle = "Allow screen capture"
            public static let captureExplain = "Lets Sidemoon take the screenshots you ask for, and nothing else. "
                + "macOS asks you to turn on Sidemoon under Screen Recording in System Settings."
            public static let captureGranted = "Allowed."
            public static let capturePending = "Once Sidemoon is turned on in System Settings, relaunch it. "
                + "macOS only applies the change after a restart."
            public static let capturePendingQuit = "Once Sidemoon is turned on in System Settings, quit it and open it again. "
                + "macOS only applies the change after a restart."
            public static let allow = "Allow"
            public static let openSystemSettings = "Open System Settings"
            public static let relaunch = "Relaunch"

            public static let terminalTitle = "Terminal sessions"
            public static let terminalWhy = "Sessions you start in a terminal can only receive messages from Sidemoon when "
                + "you start them with sidemoon-claude instead of claude."
            public static func terminalChanges(_ launcher: String, config: String) -> String {
                "Install adds the sidemoon-claude command at \(launcher) and a small settings file at \(config)."
            }
            public static let terminalPreview = "This relies on a research-preview option of Claude Code, which may change."
            public static let terminalInstalled = "Installed. In the Terminal app, type this where you would normally type claude:"
            public static let terminalResume = "To reopen a session you already have, type this and pick it from the list:"
            /// Shown in place of a step that would change something, while Sidemoon runs from outside Applications.
            public static let moveFirst = "Move Sidemoon to your Applications folder first. This copy runs from a place that "
                + "can go away, and what this step sets up would point at it."
            public static let moveButton = "Move to Applications"
            public static let openAtLoginAfterMove = "Opening at login can be turned on once Sidemoon is in your Applications folder."
            public static let whereItSits = "Sidemoon is the small round companion at the edge of your screen. "
                + "After Start it opens beside it with a short guide."
            public static let terminalConfigOutdated = "sidemoon-claude is installed, but its settings point to another copy of "
                + "Sidemoon. Repair points them at this app."
            public static func terminalForeign(_ path: String) -> String {
                "A different file is already at \(path). Sidemoon will not replace it. Move or rename it, then try again."
            }
            public static func notOnPath(_ directory: String, launcher: String) -> String {
                "\(directory) is not on your shell's PATH, so type the full path: \(launcher)"
            }
            public static let install = "Install"
            public static let terminalLauncherOutdated = "sidemoon-claude is from an earlier version of Sidemoon. "
                + "Update replaces it with this version's."
            public static let update = "Update"

            /// "Connect every claude": the shell startup files send the plain claude command through sidemoon-claude.
            public static let shellTitle = "Connect every claude you start in a terminal"
            public static func shellExplain(_ files: [String]) -> String {
                "When this is on, typing claude in a terminal starts it through sidemoon-claude, so Sidemoon can send to "
                    + "it. Sidemoon adds a few marked lines to \(list(files)), after saving a backup copy. Terminal windows "
                    + "you open from then on pick it up; windows already open do not. Commands such as claude mcp, "
                    + "claude -p or claude --bg run as before."
            }
            public static func shellOn(_ files: [String]) -> String {
                "On. Terminal windows you open from now on connect claude to Sidemoon. Turning it off removes Sidemoon's "
                    + "lines from \(list(files)) and nothing else."
            }
            public static let shellPartial = "Only partly on: some files have Sidemoon's lines and some do not, or have an "
                + "older form of them. Turn it on to bring them all up to date, or off to remove them."
            public static let shellNoShell = "Sidemoon found no zsh, bash or fish set up for you, so there is nothing to change."
            public static let shellConfirmNote = "Each time Claude Code starts this way it asks you to confirm "
                + "\"I am using this for local development\". Press Return to go on."
            public static let shellNeedsLauncher = "Turning this on also installs the sidemoon-claude command."
            public static func shellLink(_ file: String) -> String {
                "\(file) is a link to another file, so Sidemoon did not change it. To connect claude there, copy the lines "
                    + "and add them to that file yourself."
            }
            public static func shellUnwritable(_ file: String) -> String {
                "Sidemoon is not allowed to change \(file), so it did not. Copy the lines and add them yourself."
            }
            public static func shellUnreadable(_ file: String) -> String { "\(file) could not be read, so Sidemoon left it alone." }
            public static func shellNotAFile(_ file: String) -> String { "\(file) is not a plain file, so Sidemoon left it alone." }
            public static func shellForeignFunction(_ file: String) -> String {
                "\(file) already holds a claude command of your own, so Sidemoon left it alone."
            }
            public static func shellMalformed(_ file: String) -> String {
                "\(file) has only one of the two lines that mark Sidemoon's block, so Sidemoon left it alone. Remove the "
                    + "lines starting with \"# >>> sidemoon\" or \"# <<< sidemoon\" by hand, then try again."
            }
            public static func shellFailed(_ file: String, reason: String) -> String { "\(file) could not be changed: \(reason)" }
            public static func backupsSaved(_ paths: [String]) -> String {
                paths.count == 1 ? backupSaved(paths[0]) : "Backups saved at \(list(paths))."
            }
            public static let copyLines = "Copy the lines"

            /// "a", "a and b", "a, b and c".
            static func list(_ items: [String]) -> String {
                guard let last = items.last else { return "" }
                return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
            }

            public static func helperMissing(_ path: String) -> String {
                "A part of Sidemoon is missing (\(path)). Download Sidemoon again."
            }
            public static let helperTranslocated = "Move Sidemoon to your Applications folder and open it from there first. "
                + "macOS is running it from a temporary copy that goes away."
            public static func failed(_ reason: String) -> String { "That did not work: \(reason)" }

            public static let readyTitle = "Ready"
            public static let readyExplain = "Use these shortcuts in any app. Click the companion to read the answers. "
                + "You can open this window again from the companion's right-click menu."
            public static let start = "Start"
            /// Optional: finish Setup and start the first session from Sidemoon itself.
            public static let startWithSession = "Start a session here"
            public static let startWithSessionHelp = "Finishes setup and opens a small form: pick a folder and say what the session should do first. Nothing to type in a terminal."
        }

        /// The window that offers to move Sidemoon into the Applications folder.
        public enum Move {
            public static let windowTitle = "Move Sidemoon"
            public static let heading = "Move Sidemoon to Applications?"
            public static let explain = "Sidemoon is running from where it was downloaded. Kept in your Applications folder, it is "
                + "still there after the disk image is ejected, you can find it with Spotlight, and macOS keeps the permissions "
                + "you give it."
            public static let move = "Move to Applications"
            public static let notNow = "Not now"
            public static let notNowNote = "Until it is moved, Sidemoon will not connect to Claude Code or open at login."
            public static let noWritableFolder = "Neither Applications folder can be written to. Drag Sidemoon into "
                + "Applications in the Finder instead."
            public static func failed(_ reason: String) -> String { "The move did not work: \(reason)" }
        }

        /// Starting a new session from the companion.
        /// Control-C, and the Stop button, for the selected session.
        public enum Stop {
            public static let button = "Cancel"
            public static let help = "Cancel the messages still waiting to go (Control-C). The session keeps working."
            /// Under a message that was not sent because the user stopped it.
            public static let cancelled = "Not sent"
            /// Under a cancelled message, so it cannot be mistaken for one that went.
            public static let cancelledNote = "Cancelled with Control-C. This message never reached the session."
            /// In the conversation after a turn was stopped.
            public static let stopped = "Stopped."
            public static let inTerminalTitle = "This session runs in Terminal"
            public static let inTerminalAdvice = "Press Esc there to stop it. Sidemoon does not interrupt a terminal session."
        }

        /// The model chats run with.
        public enum ChatModels {
            /// The settings row.
            public static let label = "Chat model"
            public static let defaultChoice = "Default"
            public static let help = "The model General and your other chats answer with. Sessions in a folder keep the "
                + "model they were started with."
            /// How a model is named in sentences.
            public static let defaultName = "the Claude Code default"
            /// A chat on the default model before its first answer: shown where a model name goes.
            public static let defaultLabel = "default"
            /// On the model shown in the header.
            public static let modelHelp = "The model this session's answers come from"
            /// Under a chat that has said nothing yet, and shown with a chat in the header.
            public static func answersWith(_ name: String) -> String { "Answers come from \(name)." }
            /// After `/model <name>` in a chat.
            public static func nowUsing(_ name: String) -> String { "Chats now use \(name)." }
            /// After `/model` alone, or a name that matches nothing.
            public static func current(_ name: String, choices: [String]) -> String {
                "Chats use \(name). Type /model and one of: \(choices.joined(separator: ", "))."
            }
            /// Claude Code cannot use the model asked for.
            public static func unavailableTitle(_ name: String) -> String { "\(name) is not available here" }
            public static let unavailableAdvice = "Claude Code could not use this model for chats: it may need a newer "
                + "Claude Code, or a plan that includes it. Go back to the Claude Code default, then send again."
            public static let useDefault = "Use the default model"
        }

        /// Messages that are Claude Code commands, such as /model or /compact.
        public enum Commands {
            public static let withAttachmentsTitle = "A command goes on its own"
            /// Under the composer when Return is pressed on a command while screenshots or files wait.
            public static let notWithAttachments = "A command like /compact is sent on its own, exactly as typed. "
                + "Send the screenshots with words, or remove them, then send the command."
        }

        /// Screenshots and files that were not there when it came to sending them.
        public enum Captures {
            public static let missingTitle = "The screenshot was no longer available"
            public static let missingAdvice = "Nothing was sent. Capture it again, then send."
            public static let fileMissingTitle = "A file was no longer available"
            public static let fileMissingAdvice = "It was moved, deleted or cannot be read. Attach it again, then send."
            /// Under a failed message whose screenshots are gone and that had no words of its own: nothing was sent.
            public static let goneNothingSent = "The screenshots were no longer available, so nothing was sent. Capture again."
            /// After Retry sent the words of a message whose screenshots were gone.
            public static let goneSentWords = "The screenshots were no longer available, so only your words were sent."
        }

        /// General, and the chats started with "+": conversations with no folder.
        public enum Chat {
            /// The built-in conversation's name.
            public static let general = "General"
            /// Its empty state: what a chat can and cannot do.
            public static let readOnlyNote = "This chat can look at what you send and answer. It cannot change files or run commands."
            /// Shown in the conversation when Claude Code no longer had the earlier conversation.
            public static let startedOver = "Claude Code no longer had the earlier conversation, so this chat started over from this message."
            /// The state text of a chat in the list.
            public static let kind = "chat"
        }

        public enum NewSession {
            /// The "+" beside "Send to".
            public static let plusHelp = "Start a new chat"
            /// The main action where there are no sessions at all.
            public static let startButton = "Start a new chat"
            /// The form without a folder: a new chat.
            public static let chatHeading = "New chat"
            /// The secondary control that reveals the folder choice, and the one that hides it again.
            public static let workInFolder = "Work in a folder…"
            public static let workInFolderHelp = "Start a Claude Code session that works in one of your folders and can change files there"
            public static let noFolder = "Just chat, no folder"
            public static let chatNote = "A chat needs no folder. It can look at what you send and answer, nothing more."
            public static let heading = "New session in a folder"
            public static let folder = "Folder"
            public static let message = "First message"
            public static let chooseFolder = "Choose or create a folder…"
            public static let chooseFolderHelp = "Pick any folder on this Mac, or make a new one there with New Folder"
            public static let noFolderYet = "Pick the folder the session should work in."
            /// How the home folder is named in the list of folders.
            public static let homeFolderName = "Home folder"
            public static let messagePlaceholder = "What should it do first?"
            public static let start = "Start"
            public static let tryAgain = "Try again"
            public static let starting = "Starting…"
            public static let returnStarts = "Return starts · Esc cancels"
            /// Under the starting row: why there is no Cancel.
            public static let startingNote = "Claude Code is starting the session in the background. This takes a few seconds."
            /// The folder panel.
            public static let panelMessage = "Choose the folder the new session should work in. New Folder, at the bottom left, makes one here."
            public static let panelPrompt = "Choose"
            /// One line under the folders, about the chosen one.
            public static let homeCaution = "Your home folder works, but a project folder is the safer choice."
            public static let homeRefused = "Claude Code on this Mac does not reopen sessions in your home folder, "
                + "so Sidemoon could not send to this one again. Choose a project folder."
            public static let folderMissing = "This folder no longer exists. Choose another one."

            public static func problemTitle(_ problem: NewSessionProblem) -> String {
                switch problem {
                case .folderMissing: return "That folder no longer exists"
                case .homeFolderRefused: return "Not in your home folder on this Mac"
                case .claudeNotFound: return "Claude Code was not found"
                case .untrustedFolder: return "Claude Code does not trust this folder yet"
                case .loginNeeded: return "Claude Code needs a login"
                case .timedOut: return "Claude Code took too long to start it"
                case .notConfirmed: return "The new session did not show up"
                case .failed: return "The session could not be started"
                }
            }

            public static func problemAdvice(_ problem: NewSessionProblem) -> String {
                switch problem {
                case .folderMissing: return "It was moved or deleted. Choose another folder."
                case .homeFolderRefused: return homeRefused
                case .claudeNotFound:
                    return "Sidemoon could not find the claude command. Install Claude Code, or open Setup to see where "
                        + "Sidemoon looks for it, then try again."
                case .untrustedFolder:
                    return "Open a terminal in this folder, type claude once and answer yes when it asks whether you trust "
                        + "the folder. Then try again here."
                case .loginNeeded: return "Type claude in a terminal and sign in with /login, then try again here."
                case .timedOut:
                    return "Sidemoon stopped waiting. Look at the session list in a moment: if the session is not there, try again."
                case .notConfirmed:
                    return "Claude Code said it started a session, but Sidemoon could not find it. Look at the session list "
                        + "in a moment, or try again."
                case .failed: return "Claude Code stopped with an error. Details says what it printed."
                }
            }
        }

        /// Hiding sessions from the list. Nothing is done to the session itself.
        public enum Hidden {
            public static let hide = "Hide"
            public static let hideHelp = "Hide this session from the list. Nothing happens to the session, and it comes "
                + "back by itself when it answers or needs you. Delete key."
            public static let unhide = "Unhide"
            public static let unhideHelp = "Put this session back in the list"
            public static let undo = "Undo"
            public static func hid(_ name: String) -> String { "Hid \(name)" }
            public static func show(_ count: Int) -> String { "Show hidden (\(count))" }
            public static let hideAgain = "Hide them again"
            /// The settings switch.
            public static let showSwitch = "Show hidden"
            public static let openInTerminalHelp = "Open this session in the Terminal app. It keeps running in the background."
        }

        public static let recording = "Recording"
        public static let visibleInRecordings = "Show Sidemoon in screen recordings and screen sharing"
        public static let visibleInRecordingsNote = "Off by default, so the companion never ends up in the screenshots it sends."
    }
}
