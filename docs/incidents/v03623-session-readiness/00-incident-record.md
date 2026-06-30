# v0.36.23 Session Readiness Incident Record

## Scope

This record isolates the v0.36.23 session readiness investigation from the dirty implementation tree.

## Tree Preservation

- Dirty repo: `<repo-root>`
- Dirty HEAD: `08550b528500e6626c5040f6fa67a4687be2021a`
- Dirty patch: `<local-temp>/winsmux-v03623-debug-loop.patch`
- Dirty patch SHA256: `8088109A67DA2580666820A5D6BCDD451B4F6535FE76C29C830F15AC5BCEEECE`
- Dirty patch file list: `<local-temp>/winsmux-v03623-debug-loop-files.txt`

Untracked private files were not included in the patch; the saved patch came from `git diff --binary`.

## Last Green Baseline

- Baseline tag: `v0.36.22`
- Baseline SHA: `de4e5cf0dccacdfdcaefd2a350e4b846421bd70c`
- Evidence: annotated tag message states CI Core, Desktop, Pester matrix, gitleaks, release-note quality, public-surface audit, git diff check, git-guard full, and Merge Gate passed before merge.
- Clean worktree: `<clean-repro-worktree>`
- Branch: `codex/v03623-repro`

## Dirty Patch Inventory

| Area | Files | Classification | Reason |
| --- | --- | --- | --- |
| Session startup retry | `core/src/main.rs` | REVERT_SPECULATIVE | Retries can mask startup-order defects unless a timeline fixture proves the race. |
| Registry write/error handling | `core/src/server/mod.rs` | KEEP_INDEPENDENTLY_PROVEN | `v0.36.22` already has fallible registry writes and versioned registry identity; preserve only as baseline behavior. |
| Registry debug instrumentation | `core/src/server/mod.rs` | DIAGNOSTIC_ONLY | Useful for tracing, not product behavior. |
| Stale cleanup | `core/src/main.rs`, `core/src/session.rs` | KEEP_INDEPENDENTLY_PROVEN | `v0.36.22` has versioned cleanup ownership tests and recent startup protection. |
| Warm server behavior | `winsmux-core/scripts/orchestra-layout.ps1`, `winsmux-core/scripts/orchestra-start.ps1` | UNKNOWN | Needs matrix evidence before product adoption. |
| Bootstrap shell | `winsmux-core/scripts/orchestra-start.ps1` | REVERT_SPECULATIVE | `cmd.exe /K` bootstrap changes are one factor and must be isolated. |
| Catalog/UI changes | `core/tests-rs/operator_cli.rs` | UNRELATED_PREEXISTING | Formatting/catalog assertions are outside the session readiness failure cluster. |
| Benchmark local artifacts | `winsmux-core/scripts/internal-docs-meta.psd1`, `winsmux-core/scripts/sync-internal-docs.ps1`, `winsmux-core/scripts/sync-roadmap.ps1` | UNRELATED_PREEXISTING | Roadmap/doc sync compatibility is not part of runtime session readiness. |

## Snapshot

| Item | Value |
| --- | --- |
| baseline_sha | `de4e5cf0dccacdfdcaefd2a350e4b846421bd70c` |
| current_dirty_sha | `08550b528500e6626c5040f6fa67a4687be2021a` |
| current_patch_hash | `8088109A67DA2580666820A5D6BCDD451B4F6535FE76C29C830F15AC5BCEEECE` |
| PowerShell | `7.6.3` |
| Rust | `rustc 1.94.1 (e408947bf 2026-03-25)`, `cargo 1.94.1 (29ea6fb6a 2026-03-24)` |
| Node | `v24.13.0`, `npm 11.13.0` |
| clean worktree binary | not built at snapshot time |
| existing debug binary | `<repo-root>/target/debug/winsmux.exe`, `winsmux 0.36.17`, SHA256 `6DD2E0A430A4973696D8D48405E96450300E31BDB70E758877F86F44F1125AF2` |
| existing release binary | `<repo-root>/target/release/winsmux.exe`, `winsmux 0.36.16`, SHA256 `0BB14A335B32178592844A21D845319C35DA1C3A61A7A988C384C64D6041CAF4` |

## USERPROFILE Registry State

- Registry dir: `<user-home>/.psmux`
- `.port` files: none observed at `2026-06-26T08:28:42.7214362+09:00`
- `.key` files: `0.key`, `winsmux-probe-dash-4c89c074.key`, `winsmux-probe-e77b20e1.key`, `winsmux-probe-rel-b1147306.key`
- Classification: `orphan-key`
- Key contents were not recorded.

## Owned Process And Port Baseline

- `winsmux` PID `<pid>`, path `<repo-root>/target/debug/winsmux.exe`, start `2026-06-25T22:13:57.2429011+09:00`
- `winsmux-app` PID `<pid>`, path `<repo-root>/.worktrees/v03623-formal-benchmark/target/release/winsmux-app.exe`, start `2026-06-25T23:27:39.6479801+09:00`
- Open listener owned by `winsmux` PID `<pid>`: `127.0.0.1:<local-port>`

## Failure Packet Boundary

Opus 4.8 receives only:

- clean worktree path and baseline SHA
- fixture command outputs
- sanitized timeline JSON
- dirty patch inventory classification

The dirty implementation tree is not a review input.
