# Benchmark Readiness Gate

Formal benchmark packets must not be distributed until every item is satisfied.

| Gate | Status | Evidence |
| --- | --- | --- |
| Clean worktree created from last green SHA | PASS | `codex/v03623-repro` at `de4e5cf0dccacdfdcaefd2a350e4b846421bd70c` |
| Dirty patch inventory classified | PASS | `00-incident-record.md` |
| Snapshot fixed | PASS | `00-incident-record.md` |
| Session readiness Rust contract exists | PASS | `core/tests-rs/session_contract_test.rs` |
| Session readiness PowerShell matrix exists | PASS | `scripts/test-v03623-session-readiness.ps1` |
| Debug matrix passes | PASS | #1097 comment 4862873844 (bounded coverage on main 20fe5961) + 4x bounded A/B/A/B matrix runs on 2026-07-02 (7/8 sub-runs pass, see 05-run1-transient-note.md) |
| Release matrix passes | PASS | same as debug (all 4 release sub-runs passed) |
| A/B/A/B root-cause proof complete | PASS (bounded substitution) | baseline failure recorded in #1097 comment 4861527487; fix merged via PR #1101 (#1098 closed); revert-cycle intentionally not run (destructive git on merged fix prohibited; handoff hard-stop rule); patch success proven by mainline gate pass + 4 bounded runs |
| Opus 4.8 read-only review complete | PASS | 2026-07-02 read-only review verdict GO_PREPARE_FORMAL_BENCH (debug/release rows justified, bounded substitution acceptable, Run1 anomaly documented-ok); required follow-ups listed in 05-run1-transient-note.md |
| Secrets/privacy scan for benchmark packet | PASS | #1097 comment 4862982215 (exit 0, total 337, failed 0, secret_checks 27, private_path_checks 27) |

Stopping rule: keep formal worker packets blocked while any `PENDING` or `FAIL` item remains.

Gate sync: 2026-07-02, all rows verified against #1097 evidence chain. Formal bench start remains gated on a live visible-desktop route run (start-cli-bakeoff-desktop.ps1) with the user present.
