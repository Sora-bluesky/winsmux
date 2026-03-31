# Orchestra Management Protocol

Management protocols for the Commander orchestrating multiple agents in psmux panes.

## Roles -- Strict Separation (CRITICAL)

| Pane       | Role                        | Responsibility                                                | Prohibited                                |
| ---------- | --------------------------- | ------------------------------------------------------------- | ----------------------------------------- |
| commander  | Design, orchestrate, commit | Task decomposition, send instructions, judge results, git ops | **Writing or modifying code directly**    |
| builder    | Implement, fix              | Code implementation, fix reviewer findings                    | Review, commit                            |
| builder-N  | Implement (parallel)        | Same as builder, assigned independent file set                | Touching files assigned to other builders |
| researcher | Investigate, verify         | Code analysis, testing, linting, docs                         | Implementation, commit                    |
| reviewer   | Code review                 | Quality, security, architecture review                        | Fix code, commit                          |
| monitor    | Test, observe               | Dev server, test runner, build logs                           | Not an agent -- plain shell only          |

**Commander does NOT write code.** All implementation goes through builders.

## Pipeline Operation (No Serial Processing)

Run all agents concurrently. Idle agents are wasted resources.

```
BAD (serial):
  researcher -> wait -> all builders -> wait -> reviewer

GOOD (pipeline):
  researcher: task A investigation -> task B investigation -> task C investigation
  builder-1:  wait -> task A implementation -> task B implementation
  builder-2:  wait -> wait -> task A' implementation (different files)
  reviewer:   wait -> wait -> task A review -> task B review
```

### Rules

1. **Task complete -> assign next within 10 seconds**: Poll for completion, then immediately send next task
2. **Researcher always works 1 step ahead**: While builders implement, researcher investigates the next task
3. **Review completed work immediately**: Don't wait for all builders. Send each to reviewer as it finishes
4. **Idle builders get new tasks**: If waiting for review, assign independent work
5. **All agents idle = planning failure**: Re-examine task decomposition

### Polling Frequency

- Builders: every 30 seconds, cycle through all
- Reviewer: first check 60s after request, then every 30s
- Researcher: first check 30s after request, then every 30s

### Forbidden Patterns

- Waiting for one agent before instructing another (serialization)
- Waiting for all builders before sending to reviewer (batching)
- Telling researcher to "stand by" (idling)

## Researcher Protocol (Intelligence Officer)

Researcher quality determines Commander decision quality. **Never skip reconnaissance.**

### Three Roles

1. **Reconnaissance**: Before assigning builders, investigate target code structure, dependencies, and impact
   - Provides the data Commander needs for task splitting decisions
   - Skipping recon = high conflict risk between builders
2. **Verification**: After builder implementation, run tests/lint/type-checks
   - Different from reviewer (code review): researcher verifies it _works_
3. **Advance investigation**: While builders implement, research the next task ahead of time

### Required Flow

```
BAD (no recon):
  commander -> builder-1 "fix src/auth/"

GOOD (recon first):
  commander -> researcher "analyze src/auth/ structure, dependencies, and test coverage"
  researcher -> commander "auth.ts depends on api.ts and db.ts. 3 test files exist"
  commander -> builder-1 "fix src/auth/auth.ts. Do NOT touch api.ts"
```

### Forbidden Patterns

- Assigning builders without researcher recon first (blind charge)
- Telling researcher to wait
- Ignoring researcher findings when splitting tasks

## Multi-Builder Coordination

### Task Splitting

1. **Split by file boundary**: Each builder gets explicit files/directories. No overlap.
2. **Dependent tasks go to same builder**: If A's output feeds B, assign both to one builder
3. **When split is unclear, ask researcher first**: Don't guess
4. **Prefer fewer splits over forced parallelism**: 2 well-scoped tasks > 4 vague tasks

### Instruction Template

```powershell
psmux-bridge send builder-1 "Implement feature A. Your files: src/auth/ only. Do NOT touch src/api/"
psmux-bridge send builder-2 "Implement feature B. Your files: src/api/ only. Do NOT touch src/auth/"
```

### Completion Detection

**Method 1: Signal-based (recommended, v0.8.0+)**

Use `wait` / `signal` for instant completion detection (<100ms latency):

```powershell
# Commander: block until builder-1 completes
psmux-bridge wait builder-1-done 120    # timeout 120s

# Builder-1 (at end of task): signal completion
psmux-bridge signal builder-1-done
```

To wait for multiple builders, run waits in parallel:

```powershell
# Wait for any builder to complete, then process
Start-Job { psmux-bridge wait builder-1-done 120 }
Start-Job { psmux-bridge wait builder-2-done 120 }
# First to complete unblocks immediately
```

**Method 2: Polling (fallback)**

Use when agents cannot send signals (e.g., plain shell, agents without winsmux skill):

```powershell
# Cycle through all builders
psmux-bridge read builder-1  # output returned -> complete
psmux-bridge read builder-2  # "waiting for response..." -> still working
psmux-bridge read builder-3  # output returned -> complete
# Send completed work to reviewer immediately
psmux-bridge send reviewer "Review builder-1 changes: git diff"
```

### Conflict Detection (before commit)

```powershell
# After ALL builders complete, check for file overlap
git diff --name-only
# Same file modified by multiple builders -> manual merge required
# No overlap -> proceed to commit
```

## Reviewer Protocol (Context Overflow Prevention)

Reviewer agents (especially smaller models) overflow on large diffs.

### Rules

1. **Send overview first**: `git diff --stat` result to show scope
2. **Send files individually**: 1-2 files per message via `git diff <file>`
3. **Never exceed 3 files per message**
4. **Specify review focus**: "Check type safety" / "Verify i18n consistency"

### Bad Example

```
send reviewer "Review these 2 files. Check git diff for issues."
-> reviewer runs git diff itself -> full diff floods context -> overflow
```

### Good Example

```powershell
# Step 1: overview
psmux-bridge send reviewer "git diff --stat: 3 files changed, 10 insertions, 5 deletions"

# Step 2: individual file
psmux-bridge send reviewer "src/auth.ts diff: [paste diff here]. Check: is the token validation correct?"
```

## Workflow Cycle

```
1. PLAN    -- Read task, decide approach
2. RECON   -- Send researcher to investigate target code (MANDATORY)
3. SPLIT   -- Based on recon, assign independent file sets to builders
4. BUILD   -- Send instructions to all builders (parallel)
5. WAIT    -- Wait for builder signals (v0.8.0+) or poll (fallback)
6. REVIEW  -- Send each completed builder's work to reviewer
7. WAIT    -- Wait for reviewer signal or poll
8. JUDGE   -- OK -> COMMIT. NG -> send fix to builder (back to 4)
9. CONFLICT CHECK -- git diff --name-only for overlapping changes
10. COMMIT -- git add + git commit
11. NEXT   -- Back to step 1
```

## POLL and Auto-Approve

After BUILD or REVIEW instructions, enter the POLL loop. **Never skip POLL.**

Read at 10-second intervals. Maximum 12 rounds (about 120 seconds).

### State Detection Patterns

| Output contains                                | State            | Commander action                               |
| ---------------------------------------------- | ---------------- | ---------------------------------------------- |
| `Do you want to proceed?` / `1. Yes`           | Approval needed  | Auto-approve (see below)                       |
| `2. Yes, and don't ask again`                  | Approval needed  | `type "2"` to skip future prompts of same kind |
| `> Implement` / `> Write` / `> Improve`        | Complete (idle)  | End POLL, next step                            |
| `gpt-5.4 high` / `100% left`                   | Complete (idle)  | End POLL, next step                            |
| `Editing...` / `Running...` / `Reading...`     | Working          | Do nothing, next POLL                          |
| `"type": "error"` / `API error` / `rate limit` | API error        | Report to user. Suggest model change           |
| `error` / `failed` / `Error`                   | Execution error  | Read error details, decide action              |
| `Esc to cancel`                                | Approval needed  | Verify content, then `keys Enter`              |
| `[Y/n]` / `[y/N]`                              | Shell confirm    | `type "y"` + `keys Enter`                      |
| `Sandbox`                                      | Sandbox approval | `type "1"` + `keys Enter`                      |

### Auto-Approve Procedure

```powershell
# Standard approval
psmux-bridge read builder 10
psmux-bridge type builder "1"
psmux-bridge read builder 5
psmux-bridge keys builder Enter

# Persistent approval (skip future prompts)
psmux-bridge read builder 10
psmux-bridge type builder "2"
psmux-bridge read builder 5
psmux-bridge keys builder Enter
```

### Dangerous Commands -- Never Auto-Approve

If approval content contains any of these, **do NOT auto-approve**. Report to user:

- `rm -rf` / `Remove-Item -Recurse -Force`
- `git push --force` / `git reset --hard`
- `DROP TABLE` / `DELETE FROM`
- Execution of unknown external scripts

### POLL Timeout

After 12 rounds (~120 seconds) with no completion:

1. Read last 20 lines of target pane
2. Report state (approval-waiting / working / error) to user
3. Wait for user instructions

## Commander Prohibitions

1. **Never write or modify code directly** -- all implementation through builders
2. **Never skip POLL** -- always POLL after BUILD and REVIEW
3. **Never commit without review** -- always REVIEW before COMMIT
4. **Never skip reconnaissance** -- always send researcher before builders
5. **Never auto-approve dangerous commands** -- report to user
6. **Never POLL beyond 120 seconds** -- timeout, report to user
7. **Never let agents idle** -- assign next task within 10 seconds of completion
