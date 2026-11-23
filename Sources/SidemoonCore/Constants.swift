import Foundation

/// Every path, name, flag, event name and timeout the engine relies on lives here.
public enum Constants {

    // MARK: Files and sockets

    public enum Paths {
        /// Engine state directory, created with owner-only permissions. Everything Sidemoon keeps derives from
        /// it: the engine socket the hooks and the channel talk to, the channel config, saved conversations.
        public static var supportDirectory: URL {
            if let override = supportDirectoryOverride { return URL(fileURLWithPath: override, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(supportDirectoryInHome, isDirectory: true)
        }
        /// For the end-to-end tests only (scripts/e2e.sh), never set in normal use: an absolute folder that
        /// replaces the support directory, so a test engine, its hooks and its channel use their own socket and
        /// never reach the engine inside the running app.
        public static let supportDirectoryOverrideVariable = "SIDEMOON_SUPPORT_DIR"
        static var supportDirectoryOverride: String? {
            guard let value = ProcessInfo.processInfo.environment[supportDirectoryOverrideVariable],
                  PathPolicy.absolute(value) != nil else { return nil }
            return value
        }
        /// The support directory relative to the home directory (the launcher script names it after `$HOME`).
        public static let supportDirectoryInHome = "Library/Application Support/Sidemoon"
        /// The MCP config `claude --mcp-config` reads to load the Sidemoon channel.
        public static let channelConfigName = "channel-mcp.json"
        public static var channelConfigPath: String { supportDirectory.appendingPathComponent(channelConfigName).path }
        /// The per-user command directory the launcher goes into.
        public static var userBinDirectory: String {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        }
        /// The launcher that starts Claude Code with the channel loaded.
        public static let launcherName = "sidemoon-claude"
        public static var launcherPath: String { (userBinDirectory as NSString).appendingPathComponent(launcherName) }
        /// The CLI's file name (the hooks and the channel run it).
        public static let cliExecutableName = "sidemoon"
        /// Where the CLI was installed by hand before it shipped inside the app.
        public static var legacyCLIPath: String { (userBinDirectory as NSString).appendingPathComponent(cliExecutableName) }
        public static let socketName = "engine.sock"
        /// Present while this Mac's Claude Code has been seen refusing to reopen a background session in the
        /// home folder; removed when it later reopens one.
        public static let homeFolderRefusalName = "home-folder-refused"
        public static var homeFolderRefusalPath: String { supportDirectory.appendingPathComponent(homeFolderRefusalName).path }
        public static var socketPath: String { supportDirectory.appendingPathComponent(socketName).path }

        /// Default Claude Code user settings file (the installer only touches it when asked).
        public static var defaultClaudeSettings: String {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
        }
        /// Transcripts are only read from under this directory.
        public static var claudeProjectsDirectory: String {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
        }
        /// Session scratchpads live under these prefixes (followed by the numeric uid).
        public static let scratchpadRootPrefixes = ["/private/tmp/claude-", "/tmp/claude-"]
        public static let scratchpadDirName = "scratchpad"
        public static let transcriptExtension = "jsonl"
        public static let imageFilePrefix = "sidemoon-"
        public static let backupSuffix = ".sidemoon-backup-"
        public static let backupTimestampFormat = "yyyyMMdd-HHmmss"

        /// Where the `claude` executable is looked for, before falling back to PATH.
        public static var claudeExecutableCandidates: [String] {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        }
        public static let claudeExecutableName = "claude"
    }

    public enum Permissions {
        public static let directory: mode_t = 0o700
        public static let socket: mode_t = 0o600
        public static let stateFile: Int16 = 0o600
        public static let imageFile: Int16 = 0o600
    }

    /// What the transcript reader knows of Claude Code's (internal, changeable) transcript format.
    public enum Transcript {
        public static let assistantType = "assistant"
        public static let userType = "user"
        /// Every message record carries a `message` object; bookkeeping records do not.
        public static let messageHint = Data("\"message\":".utf8)
        /// An assistant message with one of these ended its turn; "tool_use" and a missing value did not.
        public static let turnEndingStopReasons: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]
        /// Claude Code writes an error (a failed login, an API outage) as an assistant message with this flag set
        /// and this model name. Such a message ended its turn but is not an answer.
        public static let apiErrorKey = "isApiErrorMessage"
        public static let syntheticModel = "<synthetic>"
    }

    // MARK: Limits and timeouts (seconds unless noted)

    public enum Limits {
        public static let maxMessageBytes = 1 << 20
        public static let maxHookPayloadBytes = 1 << 20
        public static let maxImageBytes = 30 << 20
        /// Largest file a drop can hand to a session.
        public static let maxFileBytes = 50 << 20
        /// Characters of a random id put in front of a copied file's name to keep copies apart.
        public static let fileIdLength = 8
        public static let maxTranscriptTailBytes = 4 << 20
        /// Read first when only the last record matters; the full tail is the fallback.
        public static let turnProbeTailBytes = 256 << 10
        /// Read from each end of a transcript to find a finished answer; a longer file whose ends hold none is
        /// left undecided rather than read whole.
        public static let answerProbeBytes = 256 << 10
        /// Characters of `claude` output kept with a failure, for the Details a bug report can quote.
        public static let failureDetailCharacters = 300
        public static let listenBacklog: Int32 = 16
    }

    public enum Timeouts {
        /// Total budget for `sidemoon hook`, including reading stdin.
        public static let hookTotal: TimeInterval = 0.5
        public static let socketSend: TimeInterval = 0.5
        public static let replyWait: TimeInterval = 300
        public static let cliCommand: TimeInterval = 60
        public static let agentsRefreshInterval: TimeInterval = 10
        public static let backgroundStopWait: TimeInterval = 30
        public static let backgroundResumeVerify: TimeInterval = 60
        public static let pollInterval: TimeInterval = 0.5
        public static let headlessRun: TimeInterval = 300
        public static let channelReconnect: TimeInterval = 2
        public static let channelDeliveryAck: TimeInterval = 5
        /// After the channel helper confirmed a delivery: how long an idle session has to show it took the
        /// message in (the delivery marker in its transcript) before the send fails as not picked up. A session
        /// in the middle of a turn, or waiting on a prompt, gets this long again once it is idle.
        public static let channelPickupWait: TimeInterval = 20
        /// Budget for reading the login shell's environment once at startup.
        public static let loginEnvironment: TimeInterval = 10
        /// Grace period after terminating a login shell that overran its budget.
        public static let loginEnvironmentTerminateGrace: TimeInterval = 2
        /// How long `claude --bg "<message>"` may take to print the new session's id. Seen with Claude Code
        /// 2.1.330: about a second.
        public static let newSessionStart: TimeInterval = 30
        /// After that: how long the new session has to show up in `claude agents` (seen: at once).
        public static let newSessionVerify: TimeInterval = 30
    }

    // MARK: Environment given to `claude`

    public enum LoginShell {
        /// Used when the account database names no usable shell.
        public static let fallbackShell = "/bin/zsh"
        /// Login and interactive, so both profile and rc files run (PATH additions live in either).
        public static let flags = ["-l", "-i", "-c"]
        public static let envTool = "/usr/bin/env"
        /// Prints every variable NUL-separated, so values may hold newlines and `=`.
        public static let envToolFlag = "-0"
        /// Brackets the env output so shell startup noise around it is ignored.
        public static let marker = "__SIDEMOON_LOGIN_ENV_7f3c9a__"
        /// Prints its argument with no trailing newline.
        public static let printCommand = "printf %s"
        public static let commandSeparator = "; "
        public static let pathVariable = "PATH"
        /// Variables that mark a process as running inside a Claude Code session. Passed to `claude`,
        /// they make a resumed session behave as a nested child of whichever session launched Sidemoon.
        public static let strippedVariables = [
            "AI_AGENT", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_JOB_DIR",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_AGENT", "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
            "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_HOST_SHORT_TEMP_DIRS",
        ]
    }

    // MARK: Claude Code CLI

    public enum ClaudeCLI {
        public static let agentsArgs = ["agents", "--json", "--all"]
        /// `status` and `state` values in the agents listing.
        public static let busyStatus = "busy"
        public static let workingState = "working"
        /// Added to a message whose delivery stopped the session while it had background work running.
        public static let backgroundWorkNote = "[Note from Sidemoon: delivering this message restarted the session, which stopped "
            + "any background shells or agents it had running. Restart them if they are still needed.]"
        public static let stopCommand = "stop"
        public static let resumeFlag = "--resume"
        public static let backgroundFlag = "--bg"
        public static let printFlag = "-p"
        public static let headlessFlags = ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        /// Words in `claude --resume --bg` output that mean a copy was started instead.
        public static let forkIndicators = ["copy", "fork", "new session"]
        public static let backgroundedMarker = "backgrounded"
        /// Ends the options, so a message that starts with a dash is not read as a flag (seen to work with `--bg`).
        public static let endOfOptions = "--"
        /// Names a new session.
        public static let nameFlag = "-n"
        /// `claude attach <short id>` opens a background session in a terminal.
        public static let attachCommand = "attach"
        public static let shortIdLength = 8
        /// Flags a user adds to an interactive launch so the Sidemoon channel loads.
        public static let channelLaunchFlags = ["--mcp-config", "--dangerously-load-development-channels"]
        /// The value that follows the channel flag: the channel server's name.
        public static var channelLaunchValue: String { "server:\(Channel.serverName)" }
        /// The flag that loads approved channels; the Sidemoon channel counts when its value names it.
        public static let channelsFlag = "--channels"
        /// What joins a flag to its value in the one-argument form (`--flag=value`).
        public static let flagValueSeparator: Character = "="
        /// What separates several channel names given as one value.
        public static let channelListSeparators: Set<Character> = [",", " "]
        /// Arguments that start a flag (a channel flag's values run until the next one).
        public static let flagPrefix = "-"
    }

    /// Claude Code's own words when `claude --resume <id> --bg` refuses to reopen a session, matched in
    /// lower case. Checked in this order: the home-folder message also says "workspace not trusted".
    public enum ResumeRefusal {
        public static let homeFolderPhrases = ["home directory is trusted one session at a time"]
        public static let noTranscriptPhrases = ["has no saved transcript", "stopped before its first response"]
        public static let loginPhrases = ["login expired", "login required", "/login", "not signed in", "failed to authenticate"]
        public static let untrustedFolderPhrases = ["workspace not trusted"]
        /// Added when Claude Code kept the message to deliver the next time the session starts.
        public static let messageSavedPhrases = ["your message is saved and will be delivered"]
    }

    // MARK: Hooks

    public enum Hooks {
        public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]
        public static let subcommand = "hook"
        /// Present in every command Sidemoon installs; uninstall removes exactly these.
        public static let marker = "--sidemoon-managed"
        /// The marker builds from before the rename to Sidemoon wrote (as Tagalong). Still treated as ours, so
        /// status reports those entries, install replaces them and uninstall removes them.
        public static let legacyMarker = "--tagalong-managed"
        public static let allMarkers = [marker, legacyMarker]
        public static let hookType = "command"
        public static let timeoutSeconds = 5
        public static let claudePidEnv = "CLAUDE_PID"
    }

    public enum HookEvents {
        public static let sessionStart = "SessionStart"
        public static let userPromptSubmit = "UserPromptSubmit"
        public static let stop = "Stop"
        public static let notification = "Notification"
        public static let sessionEnd = "SessionEnd"
        public static let notificationIdle = "idle_prompt"
        public static let notificationPermission = "permission_prompt"
    }

    // MARK: Channel (MCP over stdio)

    public enum Channel {
        public static let serverName = "sidemoon"
        public static let serverVersion = "0.1.0"
        public static let subcommand = "channel"
        public static let capability = "claude/channel"
        public static let notificationMethod = "notifications/claude/channel"
        public static let defaultProtocolVersion = "2025-06-18"
        public static let sessionIdEnv = "CLAUDE_CODE_SESSION_ID"
        public static let deliveryIdMetaKey = "sidemoon_id"
        /// The `channel.hello` field that says whether the Claude Code process that started the helper loads it
        /// as a channel (a `ChannelRole` raw value). Helpers before 1.0.2 leave it out, which reads as unknown.
        public static let roleKey = "channelRole"
        public static let instructions = """
            Messages from Sidemoon arrive as <channel source="sidemoon">. They are typed by the user in the \
            Sidemoon companion while they follow your guidance, so treat them as the user's own messages and answer \
            them. When a message names an image file, read that file with the Read tool before answering.
            """
    }

    // MARK: Wire protocol over the engine socket

    public enum Ops {
        public static let hook = "hook"
        public static let channelHello = "channel.hello"
        public static let channelDeliver = "channel.deliver"
        public static let channelAck = "channel.ack"
        public static let sessions = "sessions"
        public static let send = "send"
        /// Starts a new background session with a first message.
        public static let newSession = "session.new"
    }
}
