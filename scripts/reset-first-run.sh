#!/bin/sh
# Puts this Mac back to how a new user's is, so the first-run setup can be tested:
# quits the app, removes its hooks from Claude Code's settings (after a backup), forgets its saved
# settings and its Screen Recording permission, takes its lines out of the shell startup files ("Connect every
# claude"), and moves the launcher, the support folder and any hand-installed helper to the Trash. Then opens the
# app again.
# It also clears what builds from before the rename (Tagalong) left behind; the old app itself stays.
# usage: scripts/reset-first-run.sh [path-to-app]   (default: ~/Applications/Sidemoon.app)
set -eu

APP=${1:-"$HOME/Applications/Sidemoon.app"}
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "no app at $APP" >&2; exit 1; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")
HELPER="$APP/$(/usr/libexec/PlistBuddy -c "Print :SidemoonHelperPath" "$PLIST")"
HELPER_NAME=$(basename "$HELPER")
LAUNCHER_NAME=sidemoon-claude
USER_BIN="$HOME/.local/bin"
SUPPORT="$HOME/Library/Application Support/$NAME"
QUIT_WAIT_SECONDS=10

# Names used before the rename (CompanionConstants.App.legacyBundleIdentifier and friends).
LEGACY_BUNDLE_ID=dev.tagalong.companion
LEGACY_NAME=Tagalong
LEGACY_EXECUTABLE="$LEGACY_NAME.app/Contents/MacOS/$LEGACY_NAME"
LEGACY_LAUNCHER_NAME=claude-tag
LEGACY_HELPER_NAME=tagalong
LEGACY_SUPPORT="$HOME/Library/Application Support/$LEGACY_NAME"

# "Connect every claude": the marked block in the shell startup files (CompanionConstants.ShellIntegration).
BLOCK_START='# >>> sidemoon >>>'
BLOCK_END='# <<< sidemoon <<<'
# Backups are named as Sidemoon names them (Constants.Paths.backupSuffix, backupTimestampFormat).
BACKUP_SUFFIX=.sidemoon-backup-
BACKUP_TIMESTAMP=%Y%m%d-%H%M%S
SHELL_FILES="$HOME/.zshrc $HOME/.bashrc $HOME/.bash_profile $HOME/.bash_login $HOME/.profile $HOME/.config/fish/functions/claude.fish"

# Takes Sidemoon's block out of one startup file, with the empty line put before it when it is the last thing in
# the file, and nothing else. A link is left alone (Sidemoon never writes through one). A file left empty is removed.
remove_block() {
    [ -f "$1" ] || return 0
    grep -qxF "$BLOCK_START" "$1" || return 0
    if [ -L "$1" ]; then echo "left alone (a link): $1" >&2; return 0; fi
    tmp="$1.sidemoon-tmp-$$"
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
        $0 == start { inblock = 1; before = held; held = ""; next }
        inblock { if ($0 == end) { inblock = 0; after = 1 } ; next }
        $0 == "" { held = held "\n"; next }
        { if (after) { printf "%s", before; after = 0 } ; printf "%s", held; held = ""; print }
        END {
            if (after) { if (held == "") before = substr(before, 2); printf "%s", before }
            printf "%s", held
        }
    ' "$1" > "$tmp" || { rm -f "$tmp"; echo "could not clean $1" >&2; return 0; }
    cp -p "$1" "$1$BACKUP_SUFFIX$(date +$BACKUP_TIMESTAMP)"
    if [ -s "$tmp" ]; then cat "$tmp" > "$1"; else rm -f "$1"; fi
    rm -f "$tmp"
    echo "removed Sidemoon's lines from $1"
}

discard() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if command -v trash > /dev/null 2>&1; then trash "$1"; else mv "$1" "$HOME/.Trash/$(basename "$1").$$"; fi
    echo "moved to Trash: $1"
}

# Quits every process whose command line contains $1 and waits for it to go.
quit() {
    pkill -f "$1" 2> /dev/null || true
    waited=0
    while pgrep -f "$1" > /dev/null 2>&1; do
        [ "$waited" -lt "$QUIT_WAIT_SECONDS" ] || { echo "$1 did not quit" >&2; exit 1; }
        sleep 1
        waited=$((waited + 1))
    done
}

# 1. Quit the app, and an old Tagalong build (its engine lives in the old support folder removed below).
quit "$APP/Contents/MacOS/$EXECUTABLE"
quit "$LEGACY_EXECUTABLE"

# 2. Remove the hooks. The helper backs the settings file up first and removes only its own lines,
#    including the ones an old Tagalong build wrote.
"$HELPER" hooks uninstall

# 3. Forget saved settings and the Screen Recording permission, under the new and the old identifier.
defaults delete "$BUNDLE_ID" 2> /dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID"
defaults delete "$LEGACY_BUNDLE_ID" 2> /dev/null || true
tccutil reset ScreenCapture "$LEGACY_BUNDLE_ID" 2> /dev/null || true

# 4. "Connect every claude" (its lines in the shell startup files), then the launcher, the support folder and a
#    helper installed by hand, new names and old.
for f in $SHELL_FILES; do remove_block "$f"; done
discard "$USER_BIN/$LAUNCHER_NAME"
discard "$SUPPORT"
discard "$USER_BIN/$HELPER_NAME"
discard "$USER_BIN/$LEGACY_LAUNCHER_NAME"
discard "$LEGACY_SUPPORT"
discard "$USER_BIN/$LEGACY_HELPER_NAME"

# 5. Start again as a new user would.
open "$APP"
echo "reset done; $NAME opened"
