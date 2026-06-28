# Benchmark Readiness Gate

Formal benchmark packets must not be distributed until every item is satisfied.

| Gate | Status | Evidence |
| --- | --- | --- |
| Clean worktree created from last green SHA | PASS | `codex/v03623-repro` at `de4e5cf0dccacdfdcaefd2a350e4b846421bd70c` |
| Dirty patch inventory classified | PASS | `00-incident-record.md` |
| Snapshot fixed | PASS | `00-incident-record.md` |
| Session readiness Rust contract exists | PASS | `core/tests-rs/session_contract_test.rs` |
| Session readiness PowerShell matrix exists | PASS | `scripts/test-v03623-session-readiness.ps1` |
| Debug matrix passes | PENDING | Run `pwsh -NoProfile -File scripts\test-v03623-session-readiness.ps1 -Json -Build debug` |
| Release matrix passes | PENDING | Run `pwsh -NoProfile -File scripts\test-v03623-session-readiness.ps1 -Json -Build release` |
| A/B/A/B root-cause proof complete | PENDING | Requires baseline fail, patch success, revert fail, reapply success |
| Opus 4.8 read-only review complete | PENDING | Failure packet only; no dirty implementation tree |
| Secrets/privacy scan for benchmark packet | PENDING | Confirm no key contents, tokens, cookies, or private logs are included |

Stopping rule: keep formal worker packets blocked while any `PENDING` or `FAIL` item remains.
