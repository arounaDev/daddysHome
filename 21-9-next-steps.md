# 21-9 — Next steps

State of the mode/policy work, and what to do next. Nothing below was compiled
or run — see step 0.

## What shipped

Three new files in `daddycore-spm/Sources/DaddyCore/`, plus wiring in
`AgentAdapter.swift`, `SessionManager.swift`, `Models.swift`,
`WorkflowState.swift`. Two new test files, unrun.

### `ModePolicy.swift` — the dropdowns got teeth

Before: picking a work mode changed one string (`WorkMode.systemPrompt`) and
nothing else. Targeted and Plan & Build launched the same CLI with the same
flags. They were personalities, not controls.

Now `WorkMode.policy` returns a `ModePolicy`:

| | effort | tools | edits |
|---|---|---|---|
| Targeted | `--effort low` | `--strict-mcp-config` | yes |
| Plan & Build | `--effort high` | project MCP | yes |
| Explore | `--effort medium` | project MCP | no (asked, not enforced) |
| Debug | `--effort high` | project MCP | yes |

Plus the half no flag can carry — `allowsSubagents`, `requiresPlanApproval`,
`maxRepairLoops` — generated from the same struct so the numbers can't drift
from the policy.

`AgentAdapter.policyArgs(_:)` is the new protocol member, default `[]`:

- **Claude** — `--effort`, `--strict-mcp-config`, `--disallowedTools`
- **Codex** — `-c model_reasoning_effort="…"` only
- **Cursor** — `--mode ask` only (read-only, opt-in)
- **OpenCode** — `--agent plan` only (read-only, opt-in)

`BuildPolicy.verification` maps frozen→`.none`, compile→`.targeted`,
run/free→`.broad`. `SessionPolicy` resolves mode against build policy: a mode
that can't edit has nothing to verify, whatever the build policy permits.

**Read-only is opt-in.** `enforcesReadOnly` defaults to `false`. A launch flag
can't be revoked from inside the conversation, so an Explore session that turns
out to need a one-line fix would be stuck and need a relaunch. The default is
the soft version; `SessionPolicy(…, enforceReadOnly: true)` or
`session.enforcesReadOnly` brings the deny flags back. Opting in on an editing
mode does nothing — it hardens an intent, it isn't a second read-only switch.

### `TaskContract.swift` — goal / done-when / do-not

On `Session`, persisted in `SessionState`, injected at launch as labelled lines
(`GOAL:` / `DONE WHEN:` / `DO NOT:`) plus "Stop when the done-when condition is
met." `SessionManager.setContract` stores **and** pastes, so a card can't show a
goal the agent was never told. Nil allowed — a card opened to poke around
doesn't need one.

The expensive omission was `doneWhen`. Without a stopping condition agents keep
going: one more refactor, one more file that could be tidied.

### `Verification.swift` — "finished" ≠ "verified"

`unverified / running / passed / failed / stale`, separate from `AgentState`,
carrying profile, command, display-only summary, timestamp.

**There is no `setVerified(true)`.** `.passed` is reachable only through
`record(exitCode:command:)` — an `Int32`, not a `Bool`, because a `Bool` is
something a caller can compute from an agent's own report of how it went. A
non-zero exit is a failure whatever the summary claims.

Staleness: a pass invalidates when the tree moves (`invalidateVerification`,
caller-driven — there's no file watch); raising the bar stales a pass, lowering
it doesn't; a relaunch resets outright.

New on `SessionManager`: `setContract`, `contract(for:)`, `beginVerification`,
`recordVerification`, `invalidateVerification`, `verification(for:)`, and a
private `retargetVerificationLocked` (named for the lock because that file has
deadlocked once on a non-recursive `NSLock`).

`SessionState` decodes both new fields with `decodeIfPresent` — every existing
state file predates these keys, and a hard `decode` would fail the whole
workflow load rather than drop one session's goal.

---

## Next steps

### 0. Build it

```
swift build --package-path daddycore-spm
swift test  --package-path daddycore-spm
swift build --package-path DaddyApp
```

Two suite failures are pre-existing, confirmed against a stashed tree: a
`/private/var` symlink assertion in `ProjectScannerTests`, and a title
truncation assertion in `SessionResumeTests`. Two PTY integration tests are
flaky under load and pass in isolation.

Two things I fixed by inspection rather than by a compiler, so check them
first if something breaks: `AgentState` encodes as `{"ready": null}`, not
`"ready"` (matters for the backward-compat test JSON), and
`Verification.init` originally had a ternary with identical branches.

### 1. The verify runner — the actual next feature

Nothing calls `recordVerification`, so every session sits at "Unverified"
forever. This closes the loop:

- a per-project verify command (`Package.swift` → `swift build` / `swift test`;
  detected, overridable)
- `BuildPolicy` decides whether it may run at all — `frozen` never does, which
  is exactly why that profile resolves to `.none`
- run through `ShellSession`, feed the exit code to `recordVerification`
- write full output to disk, keep only a summary line in memory
- call `invalidateVerification` when the diff changes, or the green badge
  decays into "was green once"

The log-to-disk bullet is the externalised-tool-output idea arriving early: the
verify run is the first thing that produces a log worth keeping out of context.

### 2. UI, minimally

Not the budget — explicitly not wanted. But `goal` / `done when` has to be typed
somewhere and the verified badge has to be visible, or neither feature exists
from the human's side. Two text fields on session create, one state chip on the
card.

### 3. Worktrees

Independent of the above, and the only item that prevents an actual data-loss
bug: two `free`-policy sessions in one project currently edit the same tree.
Zero `worktree` references in the codebase today. Rule: >1 writer in a project →
`git worktree add`; read-only modes share. Claude has `-w, --worktree` natively;
Cursor CLI has its own.

---

## Flags verified against the installed CLIs

Checked by running them, not from memory.

- `--effort low|medium|high|xhigh|max`, `--strict-mcp-config`,
  `--disallowedTools Edit,Write,NotebookEdit` — all launch clean on Claude.
- `MultiEdit` is **not** a known tool anymore. Claude printed
  `Permission deny rule "MultiEdit" matches no known tool` into the terminal and
  the denial did nothing. Removed.
- `--disallowedTools` is variadic, so its value is comma-joined into a single
  argument. Spelled as separate argv entries it swallows the following flag —
  and a swallowed `--session-id` is a card that has lost its conversation.
- Cursor's `--mode` choices are `plan` and `ask`, both read-only. `--mode plan`
  looks like the home for Plan & Build and is the wrong one: Cursor's plan mode
  never writes.
- OpenCode's `agent list` confirms a primary `plan` agent.
- **Unproven:** Codex validates neither the config key nor its value —
  `-c model_reasoning_effort="nonsense"` is accepted silently. The documented
  spelling is used, but that the key is honoured is unconfirmed. Codex hit its
  usage limit mid-test, so parsing was confirmed and effect was not.
