import CoreGraphics
import Foundation
import SidemoonCore

/// A global hotkey, described without AppKit or Carbon so it can live with the other constants.
public struct HotKeySpec: Sendable, Equatable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Virtual key code (kVK_* in Carbon's Events.h).
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// The key as typed, lowercase, for menu key equivalents and display.
    public let key: String
    public let id: UInt32

    /// The keys as keycap symbols, for example ["⌃", "⌥", "S"].
    public var symbols: [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts
    }

    /// For example "Control-Option-S", spelled out so it reads the same everywhere.
    public var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(key.uppercased())
        return parts.joined(separator: "-")
    }
}

/// Every tunable of the companion app lives here.
public enum CompanionConstants {

    public enum App {
        /// The one place the bundle identifier is defined; the app prints its Info.plist from these values.
        public static let bundleIdentifier = "app.sidemoon.companion"
        /// The bundle identifier (and so the saved-settings domain) of builds from before the rename (Tagalong).
        public static let legacyBundleIdentifier = "dev.tagalong.companion"
        public static let name = "Sidemoon"
        public static let executableName = "Sidemoon"
        public static let version = "1.0.1"
        public static let build = "5"
        public static let minimumSystemVersion = "14.0"
        /// `SidemoonApp --print-info-plist` writes the bundle's Info.plist to stdout and exits.
        public static let printInfoPlistFlag = "--print-info-plist"
        /// `SidemoonApp --render-preview <directory>` writes design preview images and exits.
        public static let renderPreviewFlag = "--render-preview"
        /// `SidemoonApp --render-icon <directory> [--variant a|b|c]` writes the app icon concepts and AppIcon.icns.
        public static let renderIconFlag = "--render-icon"
        /// The icon file in the bundle's Resources, as Info.plist names it.
        public static let iconFileName = "AppIcon.icns"
        /// The `sidemoon` CLI inside the bundle (hooks and the channel run it). Not in Contents/MacOS: the app
        /// executable there is `Sidemoon`, and the default file system ignores case.
        public static let helperPathInBundle = "Contents/Helpers/\(Constants.Paths.cliExecutableName)"
        /// Info.plist key that names `helperPathInBundle`, so scripts/build-app.sh puts the helper there.
        public static let helperPlistKey = "SidemoonHelperPath"
        public static let bundleExtension = "app"
        /// A path with this in it is a quarantined app macOS runs from a temporary copy.
        public static let translocationMarker = "/AppTranslocation/"
        /// A bundle inside one of these folders is a build of the source, never offered a move.
        public static let developmentFolders: Set<String> = [".build", "dist"]
        /// Where macOS mounts disk images.
        public static let volumesFolder = "/Volumes"
        public static let applicationsFolder = "/Applications"
        /// The user's own Applications folder, inside the home folder.
        public static let applicationsFolderName = "Applications"
        /// The extended attribute macOS puts on downloads; taken off the copy in Applications so macOS does not run it
        /// from a temporary copy again.
        public static let quarantineAttribute = "com.apple.quarantine"
    }

    /// Automatic updates (Sparkle), for the notarized direct download.
    public enum Updates {
        /// The appcast the updater reads.
        public static let feedURL = "https://www.sidemoon.app/appcast.xml"
        /// The EdDSA public key Sparkle's `generate_keys` prints (base64). Empty until that key exists: while it
        /// is empty the updater never starts, its menu item and settings row are hidden, and the
        /// Info.plist keys below are left out.
        public static let publicEDKey = "5v56XOl1KX1n5zi32gm0A4nTJfgwdSHF7kdphcUCjz0="
        /// Whether a fresh install checks for updates on its own (the user can turn it off in settings).
        public static let enableAutomaticChecks = true
        /// Sparkle's Info.plist keys.
        public static let feedURLPlistKey = "SUFeedURL"
        public static let publicEDKeyPlistKey = "SUPublicEDKey"
        public static let enableAutomaticChecksPlistKey = "SUEnableAutomaticChecks"
        /// True once the public key is filled in.
        public static var isConfigured: Bool { !publicEDKey.isEmpty }
    }

    /// The setup window.
    public enum Setup {
        /// How often the steps re-check while the window is open.
        public static let refreshInterval: TimeInterval = 2
        /// How often the companion re-checks that it is still connected, window open or not.
        public static let connectionCheckInterval: TimeInterval = 5
        public static let screenRecordingSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        public static let claudeCodeURL = "https://docs.anthropic.com/en/docs/claude-code/overview"
        public static let launcherPermissions: Int16 = 0o755
        /// The first line of the launcher script; the remaining lines are built from the constants.
        public static let launcherShebang = "#!/bin/sh"
        public static let launcherComment = "# Starts Claude Code with the Sidemoon channel loaded, so captures can be sent into this session."
        public static let homeVariable = "$HOME"
        public static let pathSeparator: Character = ":"
        /// Relaunch: a shell waits for this process to exit, then opens the app again.
        public static let relaunchShell = "/bin/sh"
        public static let relaunchScript = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        public static let relaunchScriptName = "sidemoon-relaunch"
    }

    public enum HotKeys {
        // Control is part of both: Option-only combinations are unreliable for global hotkeys on recent macOS.
        public static let capture = HotKeySpec(keyCode: 0x01 /* kVK_ANSI_S */, modifiers: [.control, .option], key: "s", id: 1)
        public static let captureWithNote = HotKeySpec(keyCode: 0x2D /* kVK_ANSI_N */, modifiers: [.control, .option], key: "n", id: 2)
        public static let captureActiveWindow = HotKeySpec(keyCode: 0x00 /* kVK_ANSI_A */, modifiers: [.control, .option], key: "a", id: 3)
        /// Four-character signature Carbon uses to tag our hotkeys ('SDMN').
        public static let signature: UInt32 = 0x5344_4D4E
    }

    /// Virtual key codes (kVK_* in Carbon's Events.h) of the keys that move between the thread and the session list.
    public enum NavigationKeys {
        public static let byKeyCode: [UInt16: NavigationKey] = [
            0x7B: .left, 0x7C: .right, 0x7D: .down, 0x7E: .up, 0x24: .enter, 0x4C: .enter, 0x35: .escape,
        ]
    }

    public enum Messages {
        public static let defaultCaptureText = "Here is a screenshot of what I see right now."
        /// Sent with dropped files when no note is typed.
        public static let defaultFilesText = "Here are the files I want you to look at."
        /// How a capture is named in the thread.
        public static let captureAttachmentName = "Screen capture"
        public static let foldersNotSent = "Folders cannot be sent. Drop the files inside instead."
        /// The short mark put on every message when short replies are on. The full note explains it.
        public static let replyStyleTag = "[via Sidemoon]"
        /// Sent with the first message to a session and again every so often, because long sessions
        /// forget. It ties the short style to the tag, so messages typed elsewhere are answered as usual.
        public static let replyStyleNote = """
        [Note from Sidemoon: messages that end with the tag \(replyStyleTag) are ones I send from a small companion \
        window beside my work. For replies to those messages only, talk to me the way you would in conversation: start \
        with the answer or the next thing I should do, and keep it to a few short sentences. Fold the details into plain \
        sentences rather than headings, long lists or tables, but do not leave out anything I need in order to act; exact \
        names, values, commands and warnings stay. Use a short list or a code block only where it is truly clearer. \
        Messages without the tag are answered as usual: this does not change how you work or how thorough you are.]

        \(replyStyleTag)
        """
        /// The full note goes out again after this many tagged messages to the same session.
        public static let replyStyleNoteEvery = 10
    }

    /// The "Try it" guide.
    public enum Guide {
        /// The short video that shows Sidemoon in use.
        public static let videoURL = "https://www.sidemoon.app"
        /// What "Send a test message" sends: harmless, and asks for an answer short enough to read at a glance.
        public static let testMessage = "This is a test message from Sidemoon. Please answer with one short sentence so I can see it arrived."
        /// The shortcut the guide teaches.
        public static let shortcut = HotKeys.captureActiveWindow
    }

    /// Finding local files named in an answer.
    public enum FileMentions {
        /// Chips shown under one answer.
        public static let maxPerReply = 6
        /// Words tried when a file name has spaces in it.
        public static let maxWords = 14
        /// A path starts at the line's start or after one of these.
        public static let boundaries: Set<Character> = [" ", "\t", "`", "\"", "'", "(", "[", "<", ":", "=", "*"]
        /// A path in running text never contains these.
        public static let terminators: Set<Character> = ["`", "\"", "<", ">", "|", "\t"]
        /// Punctuation that may follow a path without being part of it.
        public static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", ")", "]", "'", "*", "!", "?"]
    }

    public enum Thread {
        /// Entries kept per session before the oldest are dropped.
        public static let maxEntries = 200
        /// The file the conversations are saved in, inside the support folder.
        public static let archiveName = "threads.json"
        /// Sessions whose conversations are kept on disk; the least recently used fall off.
        public static let maxSavedSessions = 40
        /// How long after the last change the conversations are written to disk.
        public static let saveDelay: TimeInterval = 0.8
        /// Entries drawn when a conversation opens, and how many more each "earlier" click adds.
        /// Older ones stay in the conversation; they are only not drawn until asked for.
        public static let visibleEntries = 30
        /// Parsed answers kept ready for redrawing before the oldest are dropped.
        public static let renderCacheLimit = 300
        /// How long a check for the files an answer mentions stays valid.
        public static let fileMentionsLifetime: TimeInterval = 30
    }

    public enum Layout {
        /// The mascot panel's side; it follows the user's size setting. Wide enough that the lens, grown and
        /// glowing under the pointer, and the badge never reach the panel's square edge.
        public static var mascotSize: CGFloat { 78 * Design.zoom }
        /// Space between the mascot panel and the bubble (the panel already has clear room around the lens).
        public static let bubbleGap: CGFloat = 0
        /// Distance kept from the screen edge after snapping.
        public static let edgeMargin: CGFloat = 12
        /// Pointer travel (points) before a press on the mascot counts as a drag instead of a click.
        public static let dragThreshold: CGFloat = 4
    }

    public enum Timing {
        public static let snapAnimation: TimeInterval = 0.18
        /// How often a message waiting for a busy session checks whether it can go.
        public static let busyRetryInterval: TimeInterval = 2
        /// Every this many checks the send is retried even if the session still looks busy.
        public static let busyRetryEvery = 8
        /// After this long a waiting message gives up and says so.
        public static let busyWaitLimit: TimeInterval = 30 * 60
        /// How long the "Copied" confirmation stays on the copy button.
        public static let copiedConfirmation: TimeInterval = 1.2
        /// How long an active-window capture waits for a note before it is sent with the default message.
        public static let noteGracePeriod: TimeInterval = 3
        /// How often that countdown updates (drives the progress bar).
        public static let noteCountdownTick: TimeInterval = 0.1
    }

    public enum Capture {
        public static let tool = "/usr/sbin/screencapture"
        /// -i interactive region selection (Escape cancels), -x no sound.
        public static let arguments = ["-i", "-x"]
        /// -x no sound, -o no window shadow, -l capture the window whose id follows.
        public static let windowArguments = ["-x", "-o", "-l"]
        /// Ordinary app windows sit on this layer; menus, panels and overlays sit above it.
        public static let normalWindowLayer = 0
        /// Smaller windows (tool strips, popovers) are never taken for the window the user is working in.
        public static let minimumWindowSize = CGSize(width: 100, height: 60)
        public static let directoryName = "Captures"
        public static let filePrefix = "capture-"
        public static let fileExtension = "png"
        public static var directory: URL {
            Constants.Paths.supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
        }
    }

    public enum Defaults {
        public static let targetSession = "targetSessionId"
        public static let showEndedSessions = "showEndedSessions"
        public static let mascotOriginX = "mascotOriginX"
        public static let mascotOriginY = "mascotOriginY"
        public static let showEndedByDefault = false
        public static let zoom = "zoom"
        public static let shortReplies = "shortReplies"
        public static let theme = "theme"
        public static let largeWindow = "largeWindow"
        /// A window size dragged out by the user; absent while the size is automatic.
        public static let bubbleWidth = "bubbleWidth"
        public static let bubbleHeight = "bubbleHeight"
        public static let shortRepliesByDefault = true
        /// Set once the user pressed Start in the setup window; until then it opens on launch.
        public static let setupSeen = "setupSeen"
        /// Set once the "Try it" guide was finished or hidden; it then only shows when asked for from the settings.
        public static let guideClosed = "guideClosed"
        /// The companion's panels show up in screen recordings and screen sharing. Off unless the user turns it on.
        public static let visibleInRecordings = "visibleInRecordings"
        /// Every key above that holds a saved setting; these are carried over from the legacy domain once.
        public static let savedKeys = [
            theme, zoom, largeWindow, bubbleWidth, bubbleHeight, shortReplies, showEndedSessions, targetSession, mascotOriginX, mascotOriginY, setupSeen,
            guideClosed, visibleInRecordings,
        ]
    }
}
