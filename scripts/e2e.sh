#!/bin/sh
# Runs Sidemoon's end-to-end scenarios (Tests/SidemoonCompanionTests/EndToEndTests.swift) against real,
# throwaway Claude Code sessions, beside a Sidemoon app that may be running: the test engine gets its own
# socket in a scratch folder (SIDEMOON_SUPPORT_DIR), and the scratch projects' hooks and the channel point at
# the freshly built helper with that override. Only sessions this run starts are ever sent to or stopped.
# usage: scripts/e2e.sh                run every scenario
#        scripts/e2e.sh --list         list the scenarios
#        scripts/e2e.sh <name> ...     run only these
# SIDEMOON_E2E_TMP chooses where the scratch folder goes (default: $TMPDIR).
# Uses a little Claude usage (haiku, one-line prompts). Always cleans up: stops and removes every session it
# started, removes its scratch folders and the Claude Code data Claude Code kept for them (`claude purge`).
set -u

HELPER_PRODUCT=sidemoon
TEST_SUITE=EndToEndTests
MODEL=haiku
NAME_PREFIX=sidemoon-e2e
HOME_SESSION_NAME=$NAME_PREFIX-home
HOME_PROMPT="Reply with only the word READY."
SCRATCH_TEMPLATE=$NAME_PREFIX.XXXXXX
SETTING_SOURCES=project
# The variables the scenarios read (E2E.Variable and Constants.Paths.supportDirectoryOverrideVariable).
SUPPORT_VARIABLE=SIDEMOON_SUPPORT_DIR
RUN_VARIABLE=SIDEMOON_E2E_RUN
HELPER_VARIABLE=SIDEMOON_E2E_HELPER
LEDGER_VARIABLE=SIDEMOON_E2E_LEDGER
HOME_VARIABLE=SIDEMOON_E2E_HOME_SESSION
# Ledger lines the scenarios write (E2E.Ledger).
LEDGER_BACKGROUND=bg
LEDGER_PROCESS=pid
OWNER_ONLY=700
PASS_WORD=PASS
FAIL_WORD=FAIL
# swift-testing's line for a passed test.
PASSED_MARK="passed after"
# Lines of a failed scenario's log shown under its FAIL line.
FAILURE_LINES='^e2e: |recorded an issue|^↳ |error:'
# swift-testing also prints these under "↳": the test's doc comment and its own banner.
NOISE_LINES='^↳ (///|Testing Library|Target Platform)'

# name|test function|needs the home-folder session|what it checks
SCENARIOS='idle|idleBackgroundSession|no|Idle background session: answered, same session continued
busy|busyBackgroundSession|no|Busy background session: the message waits its turn, then goes
home|homeFolderSession|yes|Home-folder session: answered here; refused before any stop where a refusal is remembered
never-answered|neverAnsweredSession|no|Session stopped before its first answer: refused, untouched
ended|endedSession|no|Ended session: resumed headlessly and answers
channel|terminalChannelSession|no|Terminal session with the channel: delivered, never restarted
wrapped|wrappedPlainClaude|no|Plain claude in zsh with Connect every claude on: through the launcher, delivered over the channel
mcp-without-channel|mcpWithoutChannel|no|Helper loaded without the channel flag: not claimed, a send fails fast
attachments|imageAndFile|no|A capture with one word and a dropped text file reach the session
retry|retryAfterFailure|yes|A failed send then Retry succeeds; no Retry for a refusal
session-list|sessionListTruth|yes|Session list reachability matches what Claude Code says
create|createSession|no|New session from the companion: started in a fresh folder, answered, then a second message to it'

ROOT=$(cd "$(dirname "$0")/.." && pwd)

list() {
    printf '%s\n' "$SCENARIOS" | while IFS='|' read -r name _ _ what; do
        printf '  %-20s %s\n' "$name" "$what"
    done
}

field() { # field <name> <column>
    printf '%s\n' "$SCENARIOS" | while IFS='|' read -r name fn home what; do
        [ "$name" = "$1" ] || continue
        case $2 in fn) echo "$fn" ;; home) echo "$home" ;; what) echo "$what" ;; esac
    done
}

case "${1:-}" in
    --list|-l) echo "scenarios:"; list; exit 0 ;;
    --help|-h) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

SELECTED=${*:-$(printf '%s\n' "$SCENARIOS" | cut -d'|' -f1)}
for name in $SELECTED; do
    [ -n "$(field "$name" fn)" ] || { echo "unknown scenario: $name" >&2; echo "scenarios:" >&2; list >&2; exit 2; }
done
command -v claude > /dev/null 2>&1 || { echo "claude is not on PATH" >&2; exit 1; }

# The scenarios start `claude` themselves; markers of an enclosing Claude Code session would make those
# sessions children of it (and could send their output to it).
for v in $(env | sed -n -e 's/^\(CLAUDE[A-Z0-9_]*\)=.*/\1/p' -e 's/^\(AI_AGENT\)=.*/\1/p'); do unset "$v"; done

SCRATCH_PARENT=${SIDEMOON_E2E_TMP:-${TMPDIR:-/tmp}}
mkdir -p "$SCRATCH_PARENT"
# Resolved, because Claude Code records the real path (/private/var/..., not /var/...).
RUN=$(cd "$(mktemp -d "$SCRATCH_PARENT/$SCRATCH_TEMPLATE")" && pwd -P)
SUPPORT=$RUN/support
LEDGER=$RUN/ledger
LOGS=$RUN/logs
mkdir -p "$SUPPORT" "$LOGS" "$RUN/projects"
chmod "$OWNER_ONLY" "$SUPPORT"
: > "$LEDGER"
START=$(date +%s)

remove() {
    if command -v trash > /dev/null 2>&1; then trash "$@" 2> /dev/null || rm -rf "$@"; else rm -rf "$@"; fi
}

# `claude agents --json --all`, one session per line (read-only).
agents_lines() {
    claude agents --json --all "$@" 2> /dev/null | tr -d '\n' | tr '}' '\n'
}

# Only the sessions this run started: the ledger, and whatever Claude Code lists under this run's folder.
own_sessions() {
    sed -n "s/^$LEDGER_BACKGROUND \([0-9a-f]\{8\}\)\$/\1/p" "$LEDGER" 2> /dev/null
    agents_lines --cwd "$RUN" | sed -n 's/.*"id": *"\([0-9a-f]\{8\}\)".*/\1/p'
}

# The full session id of a short one.
session_id() {
    agents_lines | grep "\"id\": *\"$1\"" | sed -n 's/.*"sessionId": *"\([^"]*\)".*/\1/p' | head -1
}

# The short ids of every session that has a process right now.
running_sessions() {
    agents_lines | grep '"pid"' | sed -n 's/.*"id": *"\([0-9a-f]\{8\}\)".*/\1/p'
}

usage_report() {
    command -v jq > /dev/null 2>&1 || { echo "usage: (jq not found, not counted)"; return; }
    files=""
    for dir in "$RUN"/projects/*; do
        [ -d "$dir" ] || continue
        folder=$HOME/.claude/projects/$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9]/-/g')
        for f in "$folder"/*.jsonl; do [ -f "$f" ] && files="$files $f"; done
    done
    if [ -n "${HOME_SHORT:-}" ]; then
        f=$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')/$(session_id "$HOME_SHORT").jsonl
        [ -f "$f" ] && files="$files $f"
    fi
    [ -n "$files" ] || { echo "usage: no transcripts found"; return; }
    # One record per content block repeats its message's usage: count each message once.
    # shellcheck disable=SC2086
    jq -r 'select(.type == "assistant" and .message.usage != null and .message.model != "<synthetic>")
           | [.message.id, .message.model, (.message.usage.input_tokens // 0), (.message.usage.output_tokens // 0),
              (.message.usage.cache_creation_input_tokens // 0), (.message.usage.cache_read_input_tokens // 0)] | @tsv' \
        $files 2> /dev/null | sort -u -k1,1 | awk -F'\t' '
        { n++; i += $3; o += $4; cw += $5; cr += $6; models[$2] = 1 }
        END { m = ""; for (k in models) m = m (m == "" ? "" : ",") k
              printf "usage: %d model calls (%s): %d input, %d output, %d cache-write, %d cache-read tokens\n", n, m, i, o, cw, cr }'
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    echo "cleaning up"
    usage_report
    for short in $(own_sessions | sort -u); do
        claude stop "$short" > /dev/null 2>&1
        claude rm "$short" > /dev/null 2>&1 && echo "  stopped and removed session $short"
    done
    # Terminal sessions: only a process that is still the one the scenario started (its name is on its command line).
    sed -n "s/^$LEDGER_PROCESS \([0-9]*\) \(.*\)\$/\1 \2/p" "$LEDGER" 2> /dev/null | while read -r pid name; do
        if ps -p "$pid" -o command= 2> /dev/null | grep -q -- "$name"; then
            kill "$pid" 2> /dev/null && echo "  ended terminal session process $pid"
        fi
    done
    for dir in "$RUN"/projects/*; do
        [ -d "$dir" ] || continue
        claude purge -y "$dir" > /dev/null 2>&1
        folder=$HOME/.claude/projects/$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9]/-/g')
        [ -e "$folder" ] && remove "$folder"
        echo "  removed Claude Code's data for $dir"
    done
    left=""
    running=$(running_sessions)
    for short in $(own_sessions | sort -u); do
        printf '%s\n' "$running" | grep -qx "$short" && left="$left $short"
    done
    remove "$RUN"
    echo "left running:${left:- none}"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cd "$ROOT"
echo "building"
swift build --product "$HELPER_PRODUCT" > "$LOGS/build.log" 2>&1 && swift build --build-tests >> "$LOGS/build.log" 2>&1 \
    || { tail -20 "$LOGS/build.log"; echo "build failed" >&2; exit 1; }
HELPER=$(swift build --show-bin-path)/$HELPER_PRODUCT

NEEDS_HOME=no
for name in $SELECTED; do [ "$(field "$name" home)" = yes ] && NEEDS_HOME=yes; done
HOME_SHORT=""
if [ "$NEEDS_HOME" = yes ]; then
    # The one session this suite starts in the home folder: a harmless one-line prompt, stopped at the end.
    out=$(cd "$HOME" && claude --bg --setting-sources "$SETTING_SOURCES" --model "$MODEL" -n "$HOME_SESSION_NAME" "$HOME_PROMPT" < /dev/null 2>&1)
    HOME_SHORT=$(printf '%s\n' "$out" | sed -n 's/.*backgrounded · \([0-9a-f]\{8\}\) ·.*/\1/p' | head -1)
    if [ -n "$HOME_SHORT" ]; then
        echo "$LEDGER_BACKGROUND $HOME_SHORT" >> "$LEDGER"
        echo "started $HOME_SESSION_NAME ($HOME_SHORT) in $HOME"
    else
        echo "could not start $HOME_SESSION_NAME in $HOME: $out"
    fi
fi

PASSED=0
FAILED=0
RESULTS=""
for name in $SELECTED; do
    fn=$(field "$name" fn)
    log=$LOGS/$name.log
    began=$(date +%s)
    env "$SUPPORT_VARIABLE=$SUPPORT" "$RUN_VARIABLE=$RUN" "$HELPER_VARIABLE=$HELPER" "$LEDGER_VARIABLE=$LEDGER" \
        "$HOME_VARIABLE=$HOME_SHORT" swift test --skip-build --filter "$TEST_SUITE/$fn" > "$log" 2>&1
    code=$?
    took=$(( $(date +%s) - began ))
    if [ "$code" -eq 0 ] && grep -q "Test $fn() $PASSED_MARK" "$log"; then
        PASSED=$((PASSED + 1)); line="$PASS_WORD  $name (${took}s)"
        echo "$line"
    else
        FAILED=$((FAILED + 1)); line="$FAIL_WORD  $name (${took}s)"
        echo "$line"
        grep -E "$FAILURE_LINES" "$log" | grep -v -E "$NOISE_LINES" | sed 's/^/      /'
    fi
    # Kept after the scratch folder goes, for a look at what happened.
    cp "$log" "$SCRATCH_PARENT/$NAME_PREFIX-last-$name.log" 2> /dev/null
    RESULTS="$RESULTS
$line"
done

echo
echo "summary: $PASSED passed, $FAILED failed, $(( $(date +%s) - START ))s$RESULTS"
echo "logs of this run: $SCRATCH_PARENT/$NAME_PREFIX-last-<scenario>.log"
[ "$FAILED" -eq 0 ]
