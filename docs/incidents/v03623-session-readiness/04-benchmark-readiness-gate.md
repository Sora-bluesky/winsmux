# Benchmark Readiness Gate

Formal benchmark packets must not be distributed until every item is satisfied.

| Gate | Status | Evidence |
| --- | --- | --- |
| Clean worktree created from last green SHA | PASS | `codex/v03623-repro` at `de4e5cf0dccacdfdcaefd2a350e4b846421bd70c` |
| Dirty patch inventory classified | PASS | `00-incident-record.md` |
| Snapshot fixed | PASS | `00-incident-record.md` |
| Session readiness Rust contract exists | PASS | `core/tests-rs/session_contract_test.rs` |
| Session readiness PowerShell matrix exists | PASS | `scripts/test-v03623-session-readiness.ps1` |
| Debug matrix passes | PASS | #1097 comment 4862873844 (bounded coverage on main 20fe5961) + 4x bounded A/B/A/B matrix runs on 2026-07-02: runs 2-4 fully passed; the run-1 summary reported one debug sub-run failed while the detail JSON for the same label shows passed=true (summary-level transient, not a matrix failure; divergence recorded in 05-run1-transient-note.md) |
| Release matrix passes | PASS | same as debug (all 4 release sub-runs passed) |
| A/B/A/B root-cause proof complete | PASS (bounded substitution) | baseline failure recorded in #1097 comment 4861527487; fix merged via PR #1101 (#1098 closed); revert-cycle intentionally not run (destructive git on merged fix prohibited; handoff hard-stop rule); patch success proven by mainline gate pass + 4 bounded runs |
| Opus 4.8 read-only review complete | PASS | 2026-07-02 read-only review verdict GO_PREPARE_FORMAL_BENCH (debug/release rows justified, bounded substitution acceptable, Run1 anomaly documented-ok); required follow-ups listed in 05-run1-transient-note.md |
| Secrets/privacy scan for benchmark packet | PASS | #1097 comment 4862982215 (exit 0, total 337, failed 0, secret_checks 27, private_path_checks 27) |
| Runner classifies CLI completions trustworthily | FAIL | #1134: echo-race in the runner's marker baseline seeding classifies CLI workers as terminal ~30s after dispatch while panes are still working (both 2026-07-05 runs); fix tracked in the v0.36.39 Harness Bench productization lane |
| Codex pane executes dispatched packets | FAIL | #1135: the WB-001 packet stayed in the Codex composer and never executed (2026-07-05 run), serializing a full per-task timeout into every task; fix tracked in the v0.36.39 Harness Bench productization lane |

Stopping rule: keep formal worker packets blocked while any `PENDING` or `FAIL` item remains.

Gate sync: 2026-07-02, all rows verified against #1097 evidence chain. Formal bench start remains gated on a live visible-desktop route run (start-cli-bakeoff-desktop.ps1) with the user present.

## 2026-07-05 bring-up runs and formal-bench re-scope

Two live visible-desktop route runs were executed with the user present on
2026-07-05 (local evidence:
`.winsmux/evidence/cli-bakeoff-runner-logs/runner-2026-07-05T05-23-58-514Z/`
and `runner-2026-07-05T09-36-47-526Z/`, driven by the durable runner from
#1121/#1128 over CDP). Bring-up evidence achieved:

- ready-check reported 6/6 workers and the pty_capture preflight reached every
  worker pane in both runs.
- The dispatch->exec loop delivered the WB-001 packet to all six workers, and
  the desktop-displayed sha256 matched the independently computed packet hash
  in both runs (`packetHashMatch=true`).
- api_llm workers (worker-5/6) completed end-to-end with structured
  run.json/response evidence once the missing `OPENROUTER_API_KEY` environment
  variable was restored on the new host (first run was blocked by
  `api_llm_api_key_env_missing`; a fix-verification pilot dispatch then
  returned `status=succeeded` for both workers).

Both runs were stopped under the stopping rule because two harness defects
make CLI-worker scoring evidence untrustworthy:

- #1134: echo-race in the runner's marker baseline seeding classifies CLI
  workers as terminal ~30s after dispatch while their panes are still working,
  corrupting status, elapsed time, and evidence captures for every CLI row.
- #1135: the Codex worker pane receives the packet but never executes it (the
  submission stays in the composer), which serializes a full per-task timeout
  into every one of the 27 tasks.

These two defects are recorded as explicit `FAIL` rows in the gate table
above, so the stopping rule itself keeps formal worker packets blocked until
both rows turn `PASS` on the productized harness.

Decision (user-approved, 2026-07-05): the formal recorded 27-task bench is
re-scheduled to a GA-readiness bench milestone that runs after the Harness
Bench productization lane (v0.36.39), where #1134 and #1135 are tracked. The
v0.36.23 release gate is re-scoped to the bring-up evidence listed above; the
`FAIL` rows gate the formal bench, not the re-scoped v0.36.23 release.
