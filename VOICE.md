# Voice — where it stands

Branch `jarvisV1`. Steps 1–3 are committed and pushed; step 4's confirmation
loop is **uncommitted and never built**. Build it first.

```
cd DaddyApp && swift run
```

## Test this version

Uncommitted: `MockStore`, `SpeechOutputController`, `VoiceCaptureController`,
`VoiceRouter`.

**1. Speech fires on finished work, not on redraws.** The last bug was the
announcement firing on *any* transition into `.ready` — pasting a transcript
repaints the composer, which knocked an idle agent out of `.ready` and back,
and every bounce sounded like "agent finished".

- Give an agent a task taking >3s. On finish, expect exactly one "CLAUDE is done."
- Record and paste a transcript. Expect **silence**. This is the bug.
- Idle agent sitting there: silence.

**2. The confirmation loop.** Say: *"create a task fix the UI bug, daddy
project, category UIUX"*.

- Expect: nothing is created yet, Daddy says "Confirm …", mic reopens by itself.
- Say "yes" → task is created, toast appears. ("sí" / "dale" also work.)
- Repeat, say "no" → "Cancelled.", nothing created.
- Repeat, say something unrelated → treated as a new command, not a bad answer.
- Repeat, say nothing → lapses silently after 20s.

Expect ~1.7s before each "Confirm …" line. Those strings are per-work-item so
they miss the prewarm cache. Known, not a bug.

**3. Keyboard focus** (`TerminalSurface.hop` was retyped to clear a warning).
Open a session, come back from the board — caret should land in the terminal
with no click. If it doesn't, revert that closure; the warning was cosmetic.

## Step 4 — remaining

The loop works off `VoiceCommandParser`'s exact phrases. Still to do:

- **Ollama fallback.** Loose phrasing → action. Hand it `AppAction.name` +
  parameters as the vocabulary. `OllamaClient` is already on `MockStore` and
  the orchestrator already calls it — copy that path.
- **Show what it understood.** Pending confirmations are audible only; the
  pill doesn't show one is standing.
- `AppAction.isDestructive` exists and is currently unused — everything
  confirms. Decide whether non-destructive actions should stop asking.

## Then

**5. History.** `voiceLog` is in-memory and dies with the process. Persist it,
feed recent turns back to the model for context ("move *that one* to done").

**6. System-wide actions.** Same registry, but opening apps and tabs outside
Daddy. Needs the macOS permissions that implies. The trigger is already global
(`OptionDoubleTapMonitor` uses `addGlobalMonitorForEvents`); only the actions
are app-scoped.

**7. Trigger.** Push-to-talk hotkey first, wake word after.

## Worth knowing

- Parakeet models: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.
- Kokoro: `~/.cache/fluidaudio`, voice `bm_lewis`, one constant at the top of
  `SpeechOutputController`.
- No Apple speech anywhere. Both directions are Kokoro/Parakeet only, so a
  model failure is silence — check `engineError` on either controller.
