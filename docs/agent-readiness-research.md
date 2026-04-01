# Agent Readiness Research

Date: 2026-04-01

Scope:
- `scripts/psmux-bridge.ps1`
- `scripts/start-orchestra.ps1`
- `README.md`
- `tests/test-bridge.ps1`
- `skills/winsmux/references/orchestra-management.md`
- `skills/winsmux/references/agent-selection.md`

## 1. How `psmux-bridge send` currently works

Current behavior in `scripts/psmux-bridge.ps1:499-531`:

1. Resolve the target label/ID and verify that the pane exists with `Confirm-Target`.
2. Send the text literally with `psmux send-keys -l`.
3. Sleep for 300ms.
4. Press `Enter`.
5. Capture the pane once; if the buffer contains `[Pasted Content`, press `Enter` again.
6. Sleep for 800ms.
7. Capture the pane again and save a watermark hash.
8. Set the read mark so the next `read` call is allowed without a guard error.

What it does **not** do:

- It does **not** check whether the target agent is idle or ready before typing.
- It does **not** call `read` first.
- It does **not** call `wait-ready` first.
- It does **not** check the current prompt, approval state, child process, or pane title.
- It does **not** actually verify that the typed text landed before pressing `Enter`, even though the comment says "Verify text landed". The code only sleeps for 300ms and never inspects the pane at that step.

Important related behavior:

- `read` uses the saved watermark to decide whether the pane output changed. If not, it returns `[psmux-bridge] waiting for response...` (`scripts/psmux-bridge.ps1:428-445`).
- This means `send` currently optimizes for "fire message, then poll for any buffer change", not for "confirm target is ready before sending".

## 2. Does the current implementation check if the target is ready?

Short answer: **No, `send` itself does not.**

There is a separate `wait-ready` command, but it is not part of `send`.

- `wait-ready` exists in `scripts/psmux-bridge.ps1:874-905`.
- The usage string says: `wait-ready <target> [timeout_seconds]  Wait for Codex prompt in pane` (`scripts/psmux-bridge.ps1:1143-1145`).
- Internally it calls `Test-CodexReadyPrompt` (`scripts/psmux-bridge.ps1:199-209`).
- `Test-CodexReadyPrompt` captures the last 50 lines and returns true only when the **last non-empty line starts with `>`**.

Implications:

- `wait-ready` is a narrow prompt heuristic, not a general readiness model.
- `send` never invokes it, so current send-path behavior is still "send first, detect later".
- The anti-hang guidance in `scripts/start-orchestra.ps1:270-273` says commanders should `read` first and, if available, use `wait-ready`, but that is protocol guidance, not enforcement inside `send`.

## 3. Idle prompt patterns found for different agents

### Explicitly documented in this repo

The most direct readiness heuristics are in `skills/winsmux/references/orchestra-management.md:218-233`.

Documented idle/completion patterns:

- Line starts with `› ` or `> ` suggestions -> treat as complete/idle.
- Model/status line such as `gpt-5.4 high` or `100% left` -> treat as complete/idle.

Explicit examples in that doc:

- Codex idle example: `› Summarize recent commits`
- Claude idle example: `> ` prompt

### What the current code actually recognizes

`wait-ready` only checks `lastNonEmptyLine.TrimStart().StartsWith('>')`.

So in practice:

- Claude-style `> ` prompts are likely recognized.
- Any agent whose idle prompt literally starts with `>` is likely recognized.
- Codex's documented `› ...` suggestion form is **not** recognized by `wait-ready`.
- The broader documented idle heuristic (`› ` or `> ` or model-status line) exists only in docs/protocol, not in `wait-ready`.

### Gemini

I found support for launching Gemini CLI (`README.md:202-210`, `skills/winsmux/references/agent-selection.md:17-21`), but I did **not** find a Gemini-specific idle prompt literal in the local repo or skill references.

Best-supported conclusion from local sources:

- Gemini is supported operationally.
- Gemini does **not** currently have a dedicated readiness parser in `psmux-bridge.ps1`.
- Any Gemini idle detection today would have to rely on the generic polling heuristics from the management docs, not on code that knows Gemini-specific prompt text.

That last point is an inference from the absence of Gemini-specific logic in local sources.

## 4. Other failure modes besides "hang"

Beyond "agent keeps working and never completes", the current design has several other failure modes.

### A. Agent exited or crashed, but the pane still exists

`send` only checks that the pane ID exists (`Confirm-Target`). It does not verify that the agent process is still the intended agent.

Result:

- If Codex/Claude/Gemini crashes and the pane falls back to a PowerShell prompt, `send` will still type into that shell.
- This can become a silent misdelivery rather than a clear failure.

Related evidence:

- `list` can inspect pane title, current command, and first child process (`scripts/psmux-bridge.ps1:377-417`), but `send` does not use that information.

### B. False readiness / false completion

The current detection stack can treat the wrong state as success:

- `read` clears the watermark on **any** output change, not specifically a successful agent reply.
- A crash message, shell prompt, approval prompt, or redraw can all count as "response".
- `watch` detects silence, not completion. The docs explicitly warn that an approval wait can also be silent (`skills/winsmux/references/psmux-bridge.md:638-652`, `orchestra-management.md:151-155`).

### C. Approval/blocking prompts

The management protocol documents several blocking states that are not "hangs":

- `Do you want to proceed?`
- `1. Yes`
- `2. Yes, and don't ask again`
- `Esc to cancel`
- `[Y/n]` / `[y/N]`
- `Sandbox`

These appear in `skills/winsmux/references/orchestra-management.md:218-229`.

Result:

- The agent is alive but blocked on confirmation.
- `watch` may report silence.
- `send` itself does nothing to detect or resolve this.

### D. API/runtime failures

Also documented in `orchestra-management.md:224-226`:

- `"type": "error"`
- `API error`
- `rate limit`
- generic `error` / `failed` / `Error`

Result:

- The agent is responsive, but the task failed.
- Current readiness logic does not classify these inside `send`; a human or higher-level polling loop must inspect them.

### E. Stale or wrong target resolution

Targeting failures are separate from hangs:

- `invalid target` if the pane no longer exists (`scripts/psmux-bridge.ps1:87-103`)
- `label not found` if a label mapping is stale or missing (`scripts/psmux-bridge.ps1:585-591`)

This matters because pane recreation after a crash/restart can invalidate label-to-pane assumptions.

### F. Paste-mode edge cases

`send` has one specific mitigation:

- If the post-Enter pane snapshot contains `[Pasted Content`, it presses `Enter` again (`scripts/psmux-bridge.ps1:516-520`).

This suggests an already-known failure mode:

- Some TUIs do not immediately execute after paste and instead wait for confirmation or a second Enter.

But this is narrow:

- Only this exact pattern is handled.
- Other paste/IME/editor modes are not classified.

### G. Gemini orphan processes after session end

`skills/winsmux/references/agent-selection.md:25-29` documents:

- `Gemini CLI: Orphaned processes after session end.`

This is not a "hang" in the pane. It is a cleanup/lifecycle failure that can leave stray agent processes running even after orchestration ends.

## 5. Bottom line

- `send` is currently a delivery primitive, not a readiness-aware send.
- Readiness checking exists only as a separate helper (`wait-ready`) plus commander protocol docs.
- The current coded readiness heuristic is narrower than the documented idle patterns.
- The main non-hang risks are misdelivery into a dead/reused pane, approval-blocked silence, API/runtime errors, stale labels, and orphaned agent processes.

## 6. Most important gaps

If the goal is reliable agent readiness, the biggest gaps are:

1. `send` does not verify readiness before typing.
2. `wait-ready` only recognizes `>` and misses the documented Codex `› ...` idle form.
3. No send-path check confirms that the target process is still the intended agent.
4. Any pane output change is treated as progress, even if it is a crash or approval prompt.
