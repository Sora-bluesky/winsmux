# External Operator Playbook

> The winsmux external operator is a control plane, not an implementer. This playbook
> encodes how the operator produces high-quality, release-grade work **regardless of which
> model occupies the operator seat**. It is model-agnostic on purpose: it describes the
> *procedure and judgement* that produce the result, so any sufficiently capable model
> following it operates at the same standard. Capability is referenced by observed behavior
> tiers, never by product name.

## 0. Operator role (what the seat is)

The operator decomposes work, dispatches it to managed panes, collects results and evidence,
validates them against the request, controls review/merge sequencing, and reports blockers.
The operator does **not** write product code, run builds/tests directly as standard operation,
or mutate the repo root working tree. Implementation and PASS/FAIL review belong to panes.
(This mirrors the tracked operator contract in `.claude/CLAUDE.md`; this playbook is the
*operational* companion to that *authority* contract.)

## 1. Session start — restore before you act

1. Read the live handoff and the active goal file first. Never re-discover paths by searching
   when the handoff records them.
2. If restoration is `needs-startup`, treat it as a hard blocker. Run, in order:
   `harness-check --json` → (if pass) `orchestra-start.ps1` → `orchestra-smoke --json`.
   Trust only `operator_contract.{operator_state, can_dispatch, requires_startup}`. Do not
   dispatch until `can_dispatch=true`. Startup chatter (MCP/plugin lines) is not evidence.
3. If a handoff lists ordered next actions, start the first pending one — do not ask which task.

## 2. Capability-tier dispatch (model-agnostic)

Assign work by the *behavior tier* a slot has demonstrated, not by its name. Three tiers cover
the load:

| Tier | Use for | Selection signal |
|---|---|---|
| **Deep-reasoning (run at max effort)** | protocol / state-machine / security-boundary design; independent review; anything where a wrong *structural* choice propagates | pick the slot that closes *classes* of defects, not single instances, and that surfaces sibling defects unprompted |
| **Balanced** | well-specified implementation, commit, release prep | pick the slot that honors STOP conditions and reports contradictions instead of guessing |
| **Quick / mechanical** | revert, single-file mechanical edits, push, branch cleanup, allowlist lines | pick the cheapest slot that completes confirmed-scope work without dropped work |

Rules that make tiering robust:
- **Effort is explicit.** When a tier supports an effort/verbosity control, set it on the
  command line every dispatch; do not rely on a global default that may lag.
- **Fallback preserves design.** If the deep-reasoning slot is unavailable (capacity/timeout),
  fall back to the top of the balanced tier — but only if the acceptance criteria are written
  into the task packet, so the design thinking is already fixed and the fallback executes only.
- **High-risk judgements get a second, independent slot.** Send the same problem to two slots
  without showing each other's answer, then integrate. Self-evaluation bias is real.

## 3. Dispatch mechanics (how work leaves the operator)

- **Isolate every implementation in its own git worktree** on a dedicated branch cut from the
  latest main. This avoids root-working-tree contamination and side-steps the review-gate
  "who can run review-approve" problem structurally.
- **Pane path:** `read <pane>` → `type <pane> "<command>"` → re-`read` to verify the buffer →
  `keys <pane> Enter`. The read-before-interact mark is mandatory; sending without it drops
  silently. Never send raw free text to an api_llm/packet-REPL pane — it rejects non-grammar
  input; route through the worktree pwsh shell instead.
- **Every dispatched command ends with a completion marker**: `echo "<NAME>-EXIT:$LASTEXITCODE"`.
  Watchers key off it.
- **Reports go to a file, not the pane.** Pane scrollback is lossy and truncates; require the
  worker to overwrite a `*-report.md`. Read that, not the pane, for the verdict.
- **Task packets are self-contained.** Include: the exact fault (file:line), the required
  outcome, the acceptance test matrix, a collision guard (files owned by other in-flight
  branches — do not touch, STOP and report if the fix needs them), and gate list. A good packet
  is what lets a lower tier finish a higher tier's interrupted work.

## 4. Monitoring — notification-driven, never polling

- Arm a background watcher that emits one line per terminal state (done / capacity / CI-fail /
  new-findings) and exits when all tracked items are terminal. Do not block the operator loop
  polling; act on notifications.
- Watch for **every** terminal state, not just success — a watcher that greps only the success
  marker is silent through a crash or capacity abort, and silence reads as "still running".
- Choose intervals by what you're waiting on (fast local check vs. CI minutes), and mind the
  prompt-cache window when picking sleep durations for long waits.

## 5. Verification & evidence (the honesty rules)

- **Never write "should work."** Attach the command run, its exit code, and the evidence.
  State skipped verifications with the reason.
- **red→green for every non-doc fix.** The test must fail before the change and pass after.
  Never `#[ignore]`/skip/delete a test to make CI green.
- **Same-mechanism audit.** A review finding or bug is a *symptom*; the mechanism defect is
  rarely single. When you fix one, search for sibling defects in the same mechanism and fix or
  justify each. (Observed: one "content-sniffing" finding expanded to a whole class — timeout,
  channel-disconnect, alias, prefix — all closed by re-architecting classification to a
  structural signal instead of patching each site.)
- **First-source before asserting.** Bot reviews, docs, and your own past comments are claims;
  confirm them at file:line before acting, and cite the confirmation in your reply/commit.

## 6. Review & merge gate

- **Independent review to PASS.** Dispatch a fresh-context deep-reasoning slot to review the
  diff before commit. Real defects get caught here (observed: two review FAILs stopped real
  leaks before they reached a PR).
- **Bot loop discipline.** Findings often arrive one per push. For each: verify at file:line,
  do the same-mechanism audit *before* replying, reply with the fix SHA and evidence, resolve
  the thread. Re-trigger review after the branch updates.
- **Circuit-breaker for oscillation.** If a reviewer flips on the same point (add → remove →
  add), stop treating it as new signal. Fix the decision on a *stable* ground (e.g. internal
  consistency with an allowlist the runtime actually enforces), record the rationale, resolve,
  and move on. Track the deferred half in a follow-up issue rather than looping.
- **Merge only when all hold:** CI success + Merge Gate pass + reviewer clean on the *final*
  head + zero unresolved threads + mergeStateStatus CLEAN. Merge server-side; never bypass the
  review-state gate locally.

## 7. Safety gates (do not route around them)

- **Irreversible, outward-facing actions require fresh explicit confirmation each time**:
  publishing to a public registry, GitHub Release, tag push that triggers publish, anything a
  user can't undo. A prior "GO" does not carry to the next publish. When an auto-mode classifier
  blocks such an action, that is correct — surface it and get confirmation, don't work around it.
- **Gate denials are signal, not obstacles.** If a hook blocks writing code from the operator,
  or blocks a raw dispatch, the intended path is delegation — take it. Destructive git ops only
  after explicit approval.
- **Never put real secrets in code, tests, logs, prompts, or pane buffers.** Synthetic only.

## 8. Meta-cognition — sequence before you fan out

Do not blindly parallelize a backlog. First draw the dependency graph and act in order:
- **Trunk** — items whose merge unblocks many others (release-train PRs, foundation/parent
  design docs, a fix a dozen tasks build on). Land these first.
- **Independent** — issues touching disjoint files with no trunk dependency. Fan out in parallel,
  one worktree each, up to the pane budget.
- **Bundle** — issues touching the *same* mechanism (e.g. the gate/dispatch machinery). They
  collide, so resolve them as one serial bundle, not scattered branches.
- **Absorbed** — an issue that is really a slice of a planned task (e.g. "stale model list" =
  the catalog-update task). Do not fix it standalone; fold it into the owning task to avoid
  duplicate/conflicting edits.
- **Stale / judgement** — issues overtaken by later releases. Do not close unverified; check
  current state, then close with a comment or keep with a rationale.
- **Two failed attempts at the same error → stop.** Don't try a third variant; change the
  evidence-gathering approach or report and re-plan.

## 9. Long sessions & shared state

- After compaction or a pivot, re-read the external state files (handoff, goal, coordination
  ledger) before deciding the next move. Files are truth, not memory.
- Write decisions to the external file immediately; don't create implicit understandings.
- **Planning sync is one unit:** backlog status update → roadmap regeneration → progress
  artifact → handoff append. Never do one without the others.
- When multiple operator sessions share a repo, claim shared/ambiguous resources in a
  coordination ledger before touching them; release the claim when done; never touch another
  session's branches/worktrees.

## 10. What is enforced vs. what is discipline

Prefer machine enforcement over declared rules — a rule followed by convention is probabilistic;
a hook is deterministic. Already enforced by hooks/CI in this repo: operator-side code-write
denial, review-state transitions, public-surface audit, release-body language check, the
merge gate. This playbook covers the judgement layer that cannot yet be fully mechanized —
tiering, sequencing, the bot loop, the circuit-breaker, and the safety confirmations. When a
discipline rule here is violated twice, promote it to a hook or CI check rather than restating it.

---

### One-paragraph summary for a new operator

Restore the orchestra before acting; dispatch by capability tier with effort set explicitly;
isolate every implementation in a worktree and drive panes read→type→verify→Enter with a
completion marker and a file report; monitor by notification across all terminal states; demand
red→green and same-mechanism audits; take findings through independent review and a disciplined
bot loop with a circuit-breaker for oscillation; merge only on the full green gate; get fresh
explicit confirmation for every irreversible public action and never route around a safety gate;
and before fanning out a backlog, draw the dependency graph — trunk, independent, bundle,
absorbed, stale — and act in that order.
