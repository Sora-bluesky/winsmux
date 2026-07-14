# Metrics Baseline

TASK-630 deliverable for the v0.36.24 design-debt inventory lane. This freezes
the first repeatable baseline for repository size, static coupling, test
duration, PR/release density, and process-launch surface count. The follow-up
refactor and design-freeze tasks should compare against this document before
changing boundaries or budgets.

Measured on 2026-07-06 from `main` at `ddf48d14` unless a section says
otherwise. Local counts use only `git`-tracked files. Binary files are included
in file counts but excluded from line counts.

## Summary

| Dimension | Baseline | Measurement source |
| --- | ---: | --- |
| Tracked files | 698 | `git ls-files` |
| Text files | 678 | tracked files without NUL bytes |
| Binary files | 20 | tracked files with NUL bytes |
| Physical text lines | 324,429 | LF-based line count, non-binary tracked files |
| Full path-reference edges | 1,029 | exact tracked-path string references across all text files |
| Source-only path-reference edges | 169 | same method, limited to source/test/tooling components |
| Static process-launch match lines | 609 | process-spawn regex over source/test/tooling files |
| Latest `Tests` workflow wall time | 670 seconds | GitHub Actions run `28778182895` |
| Latest `Tests` workflow max job | 662 seconds | `Desktop Build and Test` in run `28778182895` |
| Merged PRs in last 30 days | 104 | GitHub GraphQL search, merged since 2026-06-06 |
| Merged PRs in last 90 days | 604 | GitHub GraphQL search, merged since 2026-04-07 |
| Releases in last 30 days | 13 | GitHub Releases, published since 2026-06-06 |
| Releases in last 90 days | 100 | GitHub Releases, published since 2026-04-07 |

## File LOC

Physical line counts deliberately include generated lockfiles and large tests.
That makes the value useful as a release-load baseline rather than a pure
maintainability score.

| Top-level path | Text files | Lines |
| --- | ---: | ---: |
| `core/` | 298 | 147,756 |
| `winsmux-app/` | 56 | 50,888 |
| `tests/` | 46 | 32,942 |
| `winsmux-core/` | 65 | 28,338 |
| `scripts/` | 29 | 28,082 |
| `.claude/` | 41 | 13,278 |
| root files | 20 | 8,777 |
| `docs/` | 59 | 8,453 |
| `tasks/` | 30 | 1,506 |
| `workers/` | 5 | 1,136 |
| `git-graph/` | 9 | 1,040 |
| `.github/` | 10 | 1,034 |
| `sdk/` | 3 | 555 |
| `.githooks/` | 3 | 370 |
| `packages/` | 3 | 258 |
| `.agents/` | 1 | 16 |

| Extension | Files | Lines |
| --- | ---: | ---: |
| `.ps1` | 280 | 138,504 |
| `.rs` | 108 | 99,147 |
| `.ts` | 12 | 22,803 |
| `.js` | 36 | 12,949 |
| `.md` | 123 | 12,793 |
| `.lock` | 4 | 10,052 |
| `.mjs` | 17 | 9,964 |
| `.css` | 2 | 6,048 |
| `.json` | 24 | 5,800 |
| `.py` | 7 | 1,983 |

Largest files by physical lines:

| File | Lines |
| --- | ---: |
| `tests/winsmux-bridge.Tests.ps1` | 21,722 |
| `scripts/winsmux-core.ps1` | 19,989 |
| `winsmux-app/src/main.ts` | 19,172 |
| `core/src/operator_cli.rs` | 11,657 |
| `core/tests-rs/operator_cli.rs` | 7,076 |
| `Cargo.lock` | 6,689 |
| `winsmux-app/src-tauri/src/desktop_backend.rs` | 6,108 |
| `winsmux-app/src/styles.css` | 6,041 |
| `core/src/ledger.rs` | 5,134 |
| `core/src/server/mod.rs` | 3,997 |

Interpretation for TASK-632: the first budget pressure points are the bridge
test suite, the PowerShell bridge, the desktop frontend, and the Rust operator
CLI. A future module-boundary gate should treat those four surfaces as explicit
owners rather than hiding them inside repo-wide totals.

## Fan-in and fan-out

This baseline uses exact tracked-path references as the repeatable coupling
metric. It is not a semantic call graph. A file has fan-out when it mentions
another tracked file path; a file has fan-in when other tracked files mention
its path. This catches doc/test/script coupling and public-surface allowlists,
which are part of the release burden in this repo.

Full tracked text graph:

| Metric | Count |
| --- | ---: |
| Edges | 1,029 |
| Source files with fan-out | 138 |
| Target files with fan-in | 334 |

Top full-graph fan-out:

| Source file | Fan-out |
| --- | ---: |
| `.githooks/pre-commit-whitelist.ps1` | 122 |
| `.gitignore` | 62 |
| `docs/project/powershell-adapter-inventory.md` | 61 |
| `docs/project/pester-suite-inventory.json` | 60 |
| `docs/project/legacy-compat-surface-inventory.json` | 48 |
| `docs/project/pester-suite-reduction-plan.md` | 42 |
| `.github/workflows/test.yml` | 36 |
| `tests/PublicSurfacePolicy.Tests.ps1` | 30 |
| `install.ps1` | 29 |
| `.claude/settings.json` | 29 |

Top full-graph fan-in:

| Target file | Fan-in |
| --- | ---: |
| `scripts/winsmux-core.ps1` | 36 |
| `docs/operator-model.md` | 21 |
| `scripts/audit-public-surface.ps1` | 16 |
| `scripts/git-guard.ps1` | 15 |
| `tests/winsmux-bridge.Tests.ps1` | 15 |
| `winsmux-app/src/main.ts` | 15 |
| `core/Cargo.toml` | 11 |
| `docs/repo-surface-policy.md` | 11 |
| `.claude/settings.json` | 10 |
| `.github/workflows/test.yml` | 9 |

Source/test/tooling graph, excluding docs and allowlist-heavy repo metadata as
sources and targets:

| Metric | Count |
| --- | ---: |
| Edges | 169 |
| Source files with fan-out | 60 |
| Target files with fan-in | 78 |

Top source/test/tooling fan-in:

| Target file | Fan-in |
| --- | ---: |
| `scripts/winsmux-core.ps1` | 26 |
| `winsmux-app/src/main.ts` | 11 |
| `tests/winsmux-bridge.Tests.ps1` | 10 |
| `winsmux-core/scripts/pane-status.ps1` | 6 |
| `scripts/audit-public-surface.ps1` | 5 |
| `scripts/git-guard.ps1` | 5 |
| `core/Cargo.toml` | 4 |
| `scripts/gitleaks-history-baseline.txt` | 4 |
| `tests/test_support/rust_parity.rs` | 4 |
| `winsmux-core/mcp-server.js` | 3 |

Top source/test/tooling fan-out:

| Source file | Fan-out |
| --- | ---: |
| `tests/PublicSurfacePolicy.Tests.ps1` | 11 |
| `scripts/bump-version.ps1` | 9 |
| `tests/winsmux-bridge.Tests.ps1` | 9 |
| `scripts/test-v03618-release-hardening.ps1` | 9 |
| `winsmux-core/scripts/powershell-deescalation.ps1` | 7 |
| `core/src/operator_cli.rs` | 7 |
| `scripts/test-v03621-local-router-shadow.ps1` | 6 |
| `tests/VersionSurface.Tests.ps1` | 5 |
| `core/tests-rs/ledger_contract.rs` | 5 |
| `winsmux-app/scripts/bakeoff-runner-lib.mjs` | 5 |

Top source/test/tooling component edges:

| Source | Target | Edges |
| --- | --- | ---: |
| `tests/` | `scripts/` | 26 |
| `tests/` | `winsmux-core/` | 15 |
| `winsmux-app/` | `winsmux-app/` | 14 |
| `core/` | `scripts/` | 12 |
| `scripts/` | `winsmux-core/` | 12 |
| `tests/` | `tests/` | 11 |
| `scripts/` | `scripts/` | 10 |
| `core/` | `tests/` | 10 |
| `scripts/` | `winsmux-app/` | 9 |
| `winsmux-core/` | `winsmux-core/` | 7 |

Interpretation for TASK-631/TASK-632: the bridge script is the highest fan-in
target in both graphs. That matches the TASK-628 component map: non-core
surfaces reach the runtime through the PowerShell bridge. If the bridge
contract changes, the design-freeze gate should require direct checks for
desktop, tests, SDK stubs, and release scripts.

## Test duration

Source: GitHub Actions `Tests` run `28778182895`, branch `main`, head
`ddf48d14c1583d8f56e289bdfa972f0044f5b9f3`, created
`2026-07-06T08:26:58Z`, completed `2026-07-06T08:38:08Z`.

| Metric | Value |
| --- | ---: |
| Workflow wall time | 670 seconds |
| Jobs | 26 |
| Longest job | 662 seconds |
| Pester jobs | 21 |
| Longest Pester job | 233 seconds |
| Sum of Pester job durations | 2,135 seconds |

Longest jobs:

| Job | Seconds |
| --- | ---: |
| `Desktop Build and Test` | 662 |
| `Core Build and Test` | 379 |
| `Pester Tests (bridge-worker-policy)` | 233 |
| `Pester Tests (bridge-worker-heartbeat-start)` | 226 |
| `Pester Tests (bridge-worker-broker-token)` | 167 |
| `Pester Tests (worker-benchmark)` | 166 |
| `Pester Tests (bridge-provider-commands)` | 155 |
| `Pester Tests (bridge-worker-workspace-sandbox)` | 119 |
| `Pester Tests (bridge-worker-secrets-status)` | 115 |
| `Pester Tests (bridge-worker-api-agy-exec)` | 111 |
| `Pester Tests (integration)` | 110 |

The source run contains one additional 204-second Pester job whose original
label names a retired worker surface. It is intentionally omitted from the
exact-label table above; the 21-job count and 2,135-second sum remain the
recorded source-run values.

Interpretation for release load: total workflow time is bounded by the desktop
job, while most test breadth lives in the Pester matrix. Optimizing only the
Pester matrix will not lower PR wall time below the desktop-build ceiling unless
the desktop job is split or shortened.

## PR and release density

The density windows use 2026-07-06 as the measurement date. PR density counts
merged PRs by merge date, bounded to merges on or before 2026-07-06. Release
density counts GitHub Releases by publish date, bounded to releases published on
or before 2026-07-06. The 90-day release count was computed with paginated
release reads, not a single 100-item page.

| Window | Merged PRs | PRs/day | Releases | Releases/day |
| --- | ---: | ---: | ---: | ---: |
| 30 days, since 2026-06-06 | 104 | 3.47 | 13 | 0.43 |
| 90 days, since 2026-04-07 | 604 | 6.71 | 100 | 1.11 |

Interpretation for release burden: the repo has been operating at high change
and release frequency. TASK-631/TASK-632 should prefer automated checks and
machine-readable policy over manual review steps that scale with each PR.

## Process count

This section measures static process-launch surface count, not the number of
live operating-system processes. Live process count depends on whether the
desktop app, worker panes, and release runners are active. The desktop app was
not running during this baseline, so the static count is the reproducible value
recorded here.

Regex family counted: PowerShell `Start-Process` / job starts / .NET process
types, Node `child_process` / spawn / exec helpers, Rust `Command::new`, and
Python `subprocess` / `Popen`. The Node helper pattern excludes method calls
such as `.exec(...)` so ordinary `RegExp.prototype.exec` parser calls do not
inflate the process-launch surface count.

| Metric | Count |
| --- | ---: |
| Matching lines | 609 |
| Files with matches | 163 |

| Top-level path | Matching lines | Files |
| --- | ---: | ---: |
| `core/` | 457 | 124 |
| `tests/` | 62 | 8 |
| `winsmux-app/` | 38 | 9 |
| `.claude/` | 22 | 10 |
| `sdk/` | 11 | 2 |
| `winsmux-core/` | 10 | 4 |
| `scripts/` | 7 | 5 |
| `packages/` | 2 | 1 |

Top process-launch surfaces:

| File | Matching lines |
| --- | ---: |
| `core/tests-rs/operator_cli.rs` | 126 |
| `tests/Integration.GateEnforcement.Tests.ps1` | 32 |
| `core/tests/test_issues_107_109_110.ps1` | 18 |
| `core/tests/test_theme_rendering.ps1` | 15 |
| `tests/winsmux-bridge.Tests.ps1` | 14 |
| `core/tests/test_warm_pane.ps1` | 14 |
| `core/src/main.rs` | 13 |
| `core/tests/test_issue105_plugin_env_leak.ps1` | 9 |
| `core/tests/test_github_issues_all.ps1` | 9 |
| `winsmux-app/scripts/desktop-pane-e2e.mjs` | 9 |

Interpretation for design freeze: process spawning is primarily a Rust runtime
and test-suite concern, but the desktop shell, operator hooks, SDK stubs, and
bridge scripts also own process boundaries. A future process-topology gate
should separate live runtime process counts from static spawn surfaces.

## Reproduction notes

Run these commands from the repository root.

File and line counts:

```powershell
$files = @(& git ls-files)
# Count physical lines from tracked files after skipping files containing NUL bytes.
```

Fan-in and fan-out:

```powershell
$files = @(& git ls-files)
# Normalize text to forward slashes and count exact tracked-path references.
# Limit the source-only graph to core, winsmux-app, winsmux-core, scripts,
# tests, workers, sdk, packages, and git-graph.
```

Test duration:

```powershell
gh run list --repo Sora-bluesky/winsmux --branch main --limit 30 `
  --json databaseId,workflowName,status,conclusion,createdAt,updatedAt,headSha,event
gh run view 28778182895 --repo Sora-bluesky/winsmux --json jobs
```

PR and release density:

```powershell
gh api graphql -f query='query($q:String!){ search(query:$q, type:ISSUE, first:1) { issueCount } }' `
  -f q='repo:Sora-bluesky/winsmux is:pr is:merged merged:>=2026-06-06 merged:<=2026-07-06'
gh api graphql -f query='query($q:String!){ search(query:$q, type:ISSUE, first:1) { issueCount } }' `
  -f q='repo:Sora-bluesky/winsmux is:pr is:merged merged:>=2026-04-07 merged:<=2026-07-06'
$windowStart30 = [datetimeoffset]'2026-06-06T00:00:00Z'
$windowStart90 = [datetimeoffset]'2026-04-07T00:00:00Z'
$measurementDate = [datetimeoffset]'2026-07-06T23:59:59Z'
$releases = gh api --paginate 'repos/Sora-bluesky/winsmux/releases?per_page=100' |
  ConvertFrom-Json |
  Where-Object { [datetimeoffset]$_.published_at -le $measurementDate }
@($releases | Where-Object { [datetimeoffset]$_.published_at -ge $windowStart30 }).Count
@($releases | Where-Object { [datetimeoffset]$_.published_at -ge $windowStart90 }).Count
```

Process-launch surface count:

```powershell
$regex = 'Start-Process|Start-Job|Start-ThreadJob|System\.Diagnostics\.Process|ProcessStartInfo|child_process|(?<![\w.])spawn(?:Sync)?\s*\(|(?<![\w.])exec(?:File|FileSync|Sync)?\s*\(|(?<![\w.])fork\s*\(|Command::new|std::process::Command|subprocess\.|(?<![\w.])Popen\s*\('
# Apply the regex to tracked .ps1, .psm1, .js, .mjs, .ts, .rs, and .py files.
```

## Use in the next tasks

- TASK-631 should use the high fan-in bridge and desktop files as compatibility
  surfaces whose support window must be explicit.
- TASK-632 should set size and coupling gates against this baseline, not against
  a subjective target. A reasonable first gate is "no new file over the current
  top-file threshold without a named owner and release-gate reason".
- Future releases should append a new baseline row only when the measurement
  script or window changes; otherwise compare directly to the counts above.
