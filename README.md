# Sidemoon

A small floating companion for macOS that sends what is on your screen to a Claude Code session with one key, and shows the answer beside your work.

![Sidemoon: press Control-Option-A, the active window goes to a Claude Code session, and the answer appears next to the page](docs/demo.gif)

Free and open source (MIT). Requires macOS 14 or later and [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview). Works with Claude Code only, for now.

Sidemoon is an independent project and is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.

## What it does

- **One key sends your screen.** Send the active window, drag over a region, or write a note first and then pick a region. The capture goes to the session you chose.
- **The answer appears beside your work.** A small window next to the mascot shows the reply, formatted (lists, code, tables), so you do not switch to the terminal.
- **Talk back right there.** Type questions or replies in the companion window, or drag files onto it.
- **One thread per session.** Each Claude Code session keeps its own conversation, and the conversations are kept across restarts.
- **Knows when you are needed.** A counter on the mascot shows when a session has a new answer or is waiting for you.
- **Messages wait their turn.** If a session is busy, what you send waits until it is free (up to 30 minutes) instead of getting lost.
- **Files named in an answer become buttons.** When a reply mentions a file on your Mac, it shows up as a button that opens it.
- **Short replies, if you want them.** On by default: each message carries a `[via Sidemoon]` tag and, now and then, a note asking the session to answer those messages briefly. Messages typed elsewhere are answered as usual. Turn it off in Settings.
- Themes (Paper, Terminal, Mono), adjustable size, and an option to open at login.

## Install

**Download.** Get the latest version from [sidemoon.app](https://www.sidemoon.app). It is a signed and notarized build for Apple Silicon and Intel Macs; Sidemoon is not distributed through the Mac App Store. Open the downloaded disk image, drag `Sidemoon.app` to your Applications folder and open it from there.

**Homebrew.** Coming. A draft cask is in [`packaging/homebrew`](packaging/homebrew); it is not published yet.

**Build from source.** Needs a Swift 6 toolchain (Xcode 16 or later). The first build downloads the one dependency, Sparkle, through Swift Package Manager.

```sh
git clone https://github.com/EdonZo/sidemoon.git
cd sidemoon
scripts/build-app.sh            # writes dist/Sidemoon.app
```

The script builds the app and the `sidemoon` helper for your Mac's architecture, puts the helper inside the bundle, and signs the bundle ad hoc. macOS ties the Screen Recording permission to the signature, so with ad hoc signing it has to be granted again after every rebuild. To keep it, sign with a certificate from your keychain:

```sh
SIDEMOON_SIGN_IDENTITY="Your certificate name" scripts/build-app.sh
```

## First run

On first launch Sidemoon opens a setup window. Each step says what it changes on your Mac.

1. **Claude Code.** Sidemoon checks that it can find the `claude` command. It looks in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
2. **Connect to Claude Code.** Adds Sidemoon's hooks to `~/.claude/settings.json`, so Claude Code tells Sidemoon when a session starts, answers or ends. A backup of the file is saved next to it first, and nothing else in it changes. Disconnect removes only Sidemoon's lines, after another backup.
3. **Allow screen capture.** macOS asks you to turn on Sidemoon under Screen Recording in System Settings. macOS applies the change only after the app restarts; the setup window offers a Relaunch button.
4. **Terminal sessions (optional).** Installs the `sidemoon-claude` command in `~/.local/bin` and a small config file in `~/Library/Application Support/Sidemoon`. Start terminal sessions with `sidemoon-claude` instead of `claude` so Sidemoon can send to them. If `~/.local/bin` is not on your PATH, the window tells you the full path to type.

Press **Start** when the steps are done. You can open the setup window again from the companion's right-click menu.

## Shortcuts

They work in any app.

| Keys | What it does |
|---|---|
| Control-Option-A (⌃⌥A) | Send the active window. You get 3 seconds to type a note before it goes. |
| Control-Option-S (⌃⌥S) | Send a region. Drag over the part of the screen you want to show; Escape cancels. |
| Control-Option-N (⌃⌥N) | Send a region with a note. Write the note, press Return, then pick the region. |

If another app already uses one of these keys, the companion's right-click menu says so.

In the note field, Return sends and Escape cancels.

## How it works

Sidemoon has no Dock icon and no menu bar; the floating companion (the mascot and its window) is the whole interface. An engine runs inside the app and listens on a Unix socket in `~/Library/Application Support/Sidemoon` (the folder is readable only by you, and the engine accepts connections only from your own user).

**Knowing about sessions.** Connect writes hooks for the `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification` and `SessionEnd` events into `~/.claude/settings.json`. Each hook runs the `sidemoon` helper inside the app bundle (`Sidemoon.app/Contents/Helpers/sidemoon`), which forwards the event to the engine. Every hook command carries the marker `--sidemoon-managed`, so Disconnect (or `sidemoon hooks uninstall`) removes exactly those entries and nothing else. If the app is deleted, the hooks check that the helper exists and do nothing. Sidemoon also reads `claude agents` to list background sessions, and reads replies from the session transcripts under `~/.claude/projects`.

**Delivering a message.** How a message reaches a session depends on how the session was started:

- **Terminal sessions started with `sidemoon-claude`.** The launcher runs `claude --mcp-config <config> --dangerously-load-development-channels server:sidemoon`, which loads Sidemoon as a channel: an MCP server that can push messages into the running session. Channels are a research preview in Claude Code and may change.
- **Background sessions (`claude --bg`).** Sidemoon stops the session and resumes it with the message using `claude --resume <id> --bg "<message>"`, then checks that the same session continued rather than a copy. Stopping a session ends any background shells or agents it had running; when that happens, the message tells the session so.
- **Ended sessions.** Sidemoon resumes them headlessly with `claude -p --resume <id>` and shows the answer.

A terminal session started with plain `claude` cannot be reached. Chats in the Claude desktop app are not supported.

**Images and files.** For live sessions, the capture and any dropped files are copied into that session's scratchpad folder (under `/tmp/claude-<uid>/`) so Claude Code can read them without a permission prompt. Files up to 50 MB can be sent; folders cannot.

## Privacy

- **No server, no account.** Sidemoon talks only to Claude Code on your Mac, through the `claude` command, the hooks and the channel. What a session then sends to Anthropic is up to Claude Code, as with any message you type into it.
- **The only network request is the update check.** Sidemoon uses [Sparkle](https://sparkle-project.org) to look for new versions: it reads `https://www.sidemoon.app/appcast.xml`, and updates are verified with a signing key before they are installed. "Check automatically" in Settings turns the check off. Apart from this, Sidemoon makes no network requests of its own.
- **No telemetry.** There is no analytics or tracking code in the app.
- **Captures are deleted after sending.** Sidemoon keeps captures in `~/Library/Application Support/Sidemoon/Captures` only until they are sent, and deletes them whether the send succeeds or not. The copy placed in the session's scratchpad folder (see above) is left for Claude Code to read.
- **Conversations stay on your Mac.** They are saved in `~/Library/Application Support/Sidemoon/threads.json` (up to 200 entries per session, for the 40 most recently used sessions). "Clear conversations" in Settings removes them; the sessions themselves are not touched.
- **The companion stays out of screenshots.** The companion window is excluded from screen sharing and screen captures, including Sidemoon's own.

## Uninstall

1. Open Setup from the companion's right-click menu and press **Disconnect**. This removes Sidemoon's hooks from `~/.claude/settings.json` after saving a backup next to it (`settings.json.sidemoon-backup-<timestamp>`). From a terminal, the same thing:

   ```sh
   /Applications/Sidemoon.app/Contents/Helpers/sidemoon hooks uninstall
   ```

2. Turn off **Open at login** in Settings if you turned it on, then quit Sidemoon.
3. Delete `Sidemoon.app`, and move these to the Trash if they exist: `~/.local/bin/sidemoon-claude` and `~/Library/Application Support/Sidemoon`.
4. Forget saved settings and the Screen Recording permission:

   ```sh
   defaults delete app.sidemoon.companion
   tccutil reset ScreenCapture app.sidemoon.companion
   ```

**Reset for testing.** `scripts/reset-first-run.sh [path-to-app]` does steps 1, 3 (except deleting the app) and 4, then opens the app again as a new user would see it. The default path is `~/Applications/Sidemoon.app`. It also clears what builds from before the rename (Tagalong) left behind.

## Building and testing

```sh
swift build                 # debug build of the library, the app binary and the CLI
swift test                  # unit and end-to-end tests
scripts/build-app.sh        # Sidemoon.app in dist/
```

The code is split into:

- `Sources/SidemoonCore` — the engine: hooks installer, session registry, delivery routes, channel server, transcript reader.
- `Sources/sidemoon` — the `sidemoon` command-line helper (`sidemoon hooks install|uninstall|status`, `sidemoon sessions`, `sidemoon send`, and the `hook` and `channel` subcommands that Claude Code runs).
- `Sources/SidemoonCompanion` — view models and UI logic without AppKit, so they can be tested headless. Every tunable value is in `CompanionConstants.swift`, and every user-facing string is in `DesignTokens.swift` (`Design.Copy`).
- `Sources/SidemoonApp` — the AppKit and SwiftUI app.

Tests do not touch your real `~/.claude/settings.json` or the Screen Recording permission.

## Contributing

Issues and pull requests are welcome. For anything larger than a small fix, open an issue first so we can agree on the approach. Please keep changes focused, add tests for logic in `SidemoonCore` and `SidemoonCompanion`, put new constants and strings with the existing ones, and run `swift test` before sending. See [PLAN.md](PLAN.md) for what is planned next.

## Licence

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Dardan Labs.
