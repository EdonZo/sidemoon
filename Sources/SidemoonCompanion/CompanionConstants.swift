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
        public static let version = "1.0.7"
        public static let build = "12"
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

    /// Reopening a session in the Terminal app with one click: a small script file that Terminal runs.
    public enum TerminalOpen {
        /// Written in the support folder and opened; the Finder hands `.command` files to Terminal.
        public static let scriptName = "open-session.command"
        public static let scriptPermissions: Int16 = 0o700
        public static let shebang = "#!/bin/sh"
        /// A session id is letters, digits and dashes; anything else is left out and Claude Code lists the sessions.
        public static let sessionIdCharacters = "0123456789abcdefABCDEF-"
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
        /// The second line of every launcher Sidemoon ever wrote (1.0.3 and later): a file starting with the shebang
        /// and this line is Sidemoon's own, and Setup replaces it when it is not the current script.
        public static let launcherComment = "# Starts Claude Code with the Sidemoon channel loaded, so captures can be sent into this session."
        public static let launcherPassThroughComment = "# Anything that does not start a session here (a subcommand, -p, --bg, --version, --help) runs "
            + "plain claude, and so does every launch while Sidemoon or its settings file is missing."
        public static let homeVariable = "$HOME"
        public static let pathSeparator: Character = ":"
        /// Relaunch: a shell waits for this process to exit, then opens the app again.
        public static let relaunchShell = "/bin/sh"
        public static let relaunchScript = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        public static let relaunchScriptName = "sidemoon-relaunch"
    }

    /// Which `claude` invocations the launcher passes through unchanged, without the channel flags. Taken from
    /// `claude --help` of Claude Code 2.1.330: everything that does not start an interactive session in this terminal.
    public enum Launcher {
        /// A first argument naming one of these runs a command, not a session (aliases included).
        public static let passThroughSubcommands = [
            "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin",
            "plugins", "purge", "respawn", "rm", "setup-token", "stop", "kill", "ultrareview", "update", "upgrade",
        ]
        /// Any of these, anywhere before `--`, means no interactive session here: print mode, a background session,
        /// version and help, and sessions opened in the desktop app or the cloud.
        public static let passThroughFlags = [
            "-p", "--print", "--bg", "--background", "-v", "--version", "-h", "--help", "--desktop", "--cloud", "--environment",
        ]
        /// Of those, the ones that may also be written `--flag=value`.
        public static let passThroughValueFlags = ["--cloud", "--environment"]
        /// Arguments after this one are never read as flags.
        public static let endOfOptions = "--"
        /// The shell variables the script uses.
        public static let helperVariable = "helper"
        public static let configVariable = "config"
    }

    /// "Connect every claude": a marked block in the shell startup files that sends the plain `claude` command
    /// through the launcher.
    public enum ShellIntegration {
        public static let startMarker = "# >>> sidemoon >>>"
        public static let endMarker = "# <<< sidemoon <<<"
        public static let comment = "# Added by Sidemoon: claude starts through sidemoon-claude, so Sidemoon can send to it. "
            + "Turn it off in Sidemoon's Setup."
        public static let functionName = "claude"
        public static let zshFile = ".zshrc"
        public static let bashFile = ".bashrc"
        /// The files a bash login shell (what Terminal opens) reads, first found wins.
        public static let bashLoginFiles = [".bash_profile", ".bash_login", ".profile"]
        /// Shared with other shells (sh, dash): the block there only runs under bash.
        public static let sharedProfileFile = ".profile"
        public static let configFolder = ".config"
        public static let fishFolder = "fish"
        /// Fish loads a function from this file the first time the command is typed.
        public static let fishFunctionFile = "functions/claude.fish"
        public static let fishDescription = "Claude Code, started through sidemoon-claude so Sidemoon can send to it"
        /// The login shell's file name, as the account database names it.
        public static let zshName = "zsh"
        public static let bashName = "bash"
        public static let fishName = "fish"
        /// A file being written is first written next to it under this name, then moved into place.
        public static let temporarySuffix = ".sidemoon-tmp-"
        public static let newFilePermissions: Int16 = 0o644
        public static let newDirectoryPermissions: Int16 = 0o755
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
            0x33: .delete, 0x75: .delete,
        ]
    }

    public enum Messages {
        /// How much of the engine's reason is kept under a failed message in the thread.
        public static let threadReasonCharacters = 160
        public static let defaultCaptureText = "Here is a screenshot of what I see right now."
        /// Sent with several captures when no note is typed.
        public static let defaultCapturesText = "Here are screenshots of what I see, in the order I took them."
        /// The text sent with captures and no note: one, or several.
        public static func defaultCaptureText(count: Int) -> String { count > 1 ? defaultCapturesText : defaultCaptureText }
        /// Sent with dropped files when no note is typed.
        public static let defaultFilesText = "Here are the files I want you to look at."
        /// How a capture is named in the thread.
        public static let captureAttachmentName = "Screen capture"
        /// Several captures are named shorter and numbered, so a few chips fit side by side.
        public static let numberedCaptureName = "Capture"
        /// How each of several captures is named, in the order taken; one keeps the plain name.
        public static func captureAttachmentName(number: Int, of count: Int) -> String {
            count > 1 ? "\(numberedCaptureName) \(number)" : captureAttachmentName
        }
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

    /// Chats (General, and those started with "+").
    public enum Chat {
        /// A new chat is named after the start of its first message, cut at a word to at most this many characters.
        public static let nameCharacters = 32
        /// Added where the name was cut.
        public static let nameEllipsis = "…"
    }

    /// Starting a new background session from the companion.
    public enum NewSession {
        /// Folders offered before "Choose folder…".
        public static let recentFolders = 5
    }

    /// Sessions hidden from the list (never stopped or removed).
    public enum Hidden {
        /// How long "Undo" stays in the list after a session is hidden.
        public static let undoSeconds: TimeInterval = 6
        /// Hidden sessions remembered; the ones hidden longest ago are forgotten first.
        public static let maxEntries = 200
        /// A hidden session Sidemoon has not seen for this long is forgotten (it was removed, or its conversation
        /// is long over). Kept a while, since sessions only show up again once they report or are listed.
        public static let forgetAfter: TimeInterval = 30 * 24 * 60 * 60
        /// How often "still seen" is written down for a hidden session that is listed.
        public static let seenRefresh: TimeInterval = 24 * 60 * 60
    }

    /// Command-V in the composer: what on the clipboard is taken as an attachment instead of text.
    public enum Paste {
        /// Image data, in order of preference. A screenshot copied with Command-Shift-Control-4 puts both on the
        /// clipboard; PNG is used as it is, the others are turned into PNG first (the engine sends PNG, JPEG, GIF, WebP).
        public static let imageTypes = ["public.png", "public.tiff"]
        /// The one that needs no conversion.
        public static let pngType = "public.png"
        /// Plain text in any of these is pasted as text, even when an image comes with it (rich text from some apps
        /// carries a picture of itself). HTML or RTF alone does not count: a browser's Copy Image adds an HTML tag.
        public static let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text",
                                                     "NSStringPboardType"]
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
        /// Each running Sidemoon keeps its captures in a folder of its own, named this, its process id and start time.
        public static let runFolderPrefix = "run-"
        /// A run folder whose owner cannot be judged is kept this long, then removed by a later launch.
        public static let unjudgedMaxAge: TimeInterval = 7 * 24 * 60 * 60
        /// A loose capture from a version before run folders is removed once this old: such a version may still be
        /// running and waiting to send it (a message may wait for a busy session up to `Timing.busyWaitLimit`).
        public static let legacyMaxAge: TimeInterval = 2 * 60 * 60
        /// Captures one message can carry. Pressing the capture shortcut again while they wait adds one more,
        /// up to this many; a press beyond it is ignored and nothing is sent early.
        public static let maxPerMessage = 6
        /// Failed messages that keep their captures for Retry. The oldest beyond this lose theirs (deleted at once):
        /// a later Retry then sends only the typed words, or nothing.
        public static let maxKeptMessages = 3
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
        /// The sessions hidden from the list (`HiddenSessions`, as JSON).
        public static let hiddenSessions = "hiddenSessions"
        /// The folder the last new session was started in.
        public static let newSessionFolder = "newSessionFolder"
        /// Every key above that holds a saved setting; these are carried over from the legacy domain once.
        public static let savedKeys = [
            theme, zoom, largeWindow, bubbleWidth, bubbleHeight, shortReplies, showEndedSessions, targetSession, mascotOriginX, mascotOriginY, setupSeen,
            guideClosed, visibleInRecordings, hiddenSessions, newSessionFolder,
        ]
    }
}
