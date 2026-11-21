# Sidemoon plan

Sidemoon is a macOS companion for Claude Code. It sits at the edge of the screen; one hotkey sends what
you see to a chosen session, and the reply appears in a small thread beside your work.

## Next: voice (push to talk)

Hold a hotkey, say what you want, release. Sidemoon sends your words and a screenshot to the right session.

### How it works

1. Hold Control-Option-Z (key to be confirmed). The active window is captured at once, while the app
   you are working in is still in front, and recording starts.
2. Release. Recording stops and the speech is transcribed on the Mac.
3. The existing 3-second window opens with the transcript, the capture, and the session it will go to.
   Edit the text, change the session, or cancel. Untouched, it sends.
4. The reply arrives in the thread as usual.

### Step 1: voice to the current session

- Hotkey press and release (the hotkey system already reports both).
- Record with AVAudioEngine; transcribe with Apple's on-device speech recognition.
- Two new permissions: Microphone and Speech Recognition. Ask on first use, explain why.
- The transcript becomes the message text; the capture rides along as it does for Control-Option-A.
- The mascot shows a listening state while the key is held.
- A "new session" choice in the window starts a fresh background session (`claude --bg "..."`) in a
  folder the user picks, instead of sending to the current one.

### Step 2: automatic routing

- A small model picks the destination. One headless call (`claude -p` with a small model) receives the
  transcript and the session list (name, folder, state, last reply) and answers with a session id or
  "new".
- The pick is shown in the 3-second window before anything is sent; the user can override it.
- No open session is interrupted to do the routing.
- Cost: a few seconds and a little usage per voice message.

### Risks

- Transcription of technical words (file names, commands). Mitigation: the transcript is shown and
  editable before sending.
- The router choosing the wrong session. Mitigation: the choice is shown and can be changed; when
  unsure it should prefer the current session.
- More permission prompts during onboarding.

### Not in scope

- Spoken replies.
- Always-on listening. Recording happens only while the key is held.

## Also open

- Peek card: a new reply slides out beside the mascot without a click.
- First run: pick a session, then press the hotkey, in two steps.
- A log file, so problems can be diagnosed after the fact.
- More terminal adapters (iTerm2, Ghostty, tmux) for sessions started without the channel.
- Other agents (Codex and others) as further targets.

## Known limits

- A terminal session started without `sidemoon-claude` cannot be reached.
- Sending to a background session stops and resumes it.
- Chats in the Claude desktop app cannot be reached: there is no documented way in.
