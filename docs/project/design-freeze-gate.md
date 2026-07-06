# v0.36.24 Design Freeze Gate

Purpose: freeze the v0.36.24 design boundary before the next contract-generation
lane. This gate turns the TASK-628 through TASK-631 inventories into release
rules that reviewers can check before a PR changes architecture, duplicated
contracts, size pressure points, or process topology.

## Source inputs

| Input | What this gate takes from it |
| --- | --- |
| `docs/project/component-map.md` | Component ownership, desktop-to-core process boundary, bridge command surface, and `sdk/` / `git-graph/` classification needs (`docs/project/component-map.md:15-26`, `docs/project/component-map.md:100-135`). |
| `docs/project/contract-source-of-truth-inventory.md` | Canonical contract files, confirmed drift cases, and follow-up validation targets (`docs/project/contract-source-of-truth-inventory.md:19-24`, `docs/project/contract-source-of-truth-inventory.md:31-62`, `docs/project/contract-source-of-truth-inventory.md:197-207`). |
| `docs/project/metrics-baseline.md` | Repository size, high fan-in/fan-out files, workflow duration, and process-launch baselines (`docs/project/metrics-baseline.md:15-27`, `docs/project/metrics-baseline.md:74-89`, `docs/project/metrics-baseline.md:144-193`, `docs/project/metrics-baseline.md:251-296`). |
| `docs/project/compatibility-deprecation-policy.md` | Surface classes, compatibility shims, support windows, and TASK-632 handoff rules (`docs/project/compatibility-deprecation-policy.md:18-25`, `docs/project/compatibility-deprecation-policy.md:44-53`, `docs/project/compatibility-deprecation-policy.md:65-83`, `docs/project/compatibility-deprecation-policy.md:126-163`). |

## Frozen module boundaries

The v0.36.24 release freezes these boundaries:

| Boundary | Freeze rule | Release blocker |
| --- | --- | --- |
| Desktop app to core runtime | Keep the desktop runtime path as a process boundary through `scripts/winsmux-core.ps1` for v0.36.x. The Tauri shell must not add a direct Rust dependency on the `core` crate without a migration plan, owner, and release gate update. | A PR introduces a direct desktop-to-core Rust API path, bypasses the bridge command surface, or changes bridge command shape without desktop and release-script checks. |
| Bridge command surface | Treat `scripts/winsmux-core.ps1` as the public-adjacent contract used by desktop, `winsmux-core/`, tests, release scripts, and SDK stubs. | A PR removes or renames bridge flags, fields, or command shapes without a caller inventory and support-window note. |
| `sdk/` | Keep `sdk/` reference-only until the default server path is fixed and CI covers the stubs. | A product caller is added before an owner, support window, and test coverage exist. |
| `git-graph/` | Keep `git-graph/` standalone/manual tooling until a product caller is explicitly added. | A product caller is added without assigning ownership, support window, and release-gate coverage. |
| Generated planning docs | Treat `docs/internal/` as generated output from planning sync. | A PR hand-edits generated internal docs instead of changing the authoritative planning input and running the sync script. |

## Contract freeze

The only tolerated v0.36.x compatibility exceptions are the ones already named in
`docs/project/compatibility-deprecation-policy.md`. Expanding any of these
patterns, or adding a new copy of the same contract without validation, blocks
the release PR.

| Contract area | Frozen decision | Required check before change |
| --- | --- | --- |
| `model_source` | The five-value provider catalog is the intended set; the current mismatch remains a named exception only until validators are reconciled. | Show that Rust, PowerShell, and TypeScript validators accept the same values, or keep the change out of the release. |
| Runtime provider IDs | Runtime provider IDs remain separate from Agent Vault provider vocabulary. | Do not compare Agent Vault command providers against runtime provider IDs unless TASK-632 records a separate command-provider schema. |
| Route role taxonomy | New role names or aliases are blocked until an explicit dispatch-to-coordinator map exists and Rust normalizers agree. | Add or update the explicit map and tests before adding a role or alias. |
| Backend capability vs concrete worker backend | Capability categories remain distinct from concrete worker-backend values. | Assert that every mapped concrete backend exists in `core/src/machine_contract.rs` or update the canonical contract in the same PR. |
| Manifest schema | PowerShell-produced manifests must remain accepted by Rust. | Add producer and consumer fixture coverage for version or field changes. |
| Mailbox envelope | Mailbox expansion stays blocked until the envelope has a chosen mirror/generated contract plus idempotency behavior. | Validate producer output and consumer de-duplication before changing envelope version or required fields. |
| Settings schema | Provider, backend, transport, and effort enum changes must update known callers together. | Update `settings.ps1`, desktop capability metadata, and operator CLI validation or document why a caller is outside the support window. |

## Size and coupling budget

The TASK-630 measurements are the v0.36.24 baseline. A PR can proceed without a
budget exception only when it stays within all rules below.

| Budget | Baseline | Rule |
| --- | ---: | --- |
| Total tracked files | 698 | A release PR must run `git ls-files` before push and explain every new public file. |
| Physical text lines | 324,429 | Large mechanical growth must be split unless the PR names the owner and release-gate reason. |
| Longest bridge file | `scripts/winsmux-core.ps1` at 19,989 lines | More than 200 net new lines in this file requires an owner, caller inventory, and focused bridge test. |
| Longest desktop frontend file | `winsmux-app/src/main.ts` at 19,172 lines | More than 200 net new lines requires an owner and either extraction plan or desktop test evidence. |
| Rust operator CLI | `core/src/operator_cli.rs` at 11,657 lines | More than 200 net new lines requires an owner and focused Rust or CLI contract test. |
| Desktop backend shell | `winsmux-app/src-tauri/src/desktop_backend.rs` at 6,108 lines | More than 100 net new lines requires desktop launch or command-invocation evidence. |
| High fan-in bridge target | `scripts/winsmux-core.ps1` has source/test/tooling fan-in 26 | Any command-shape change needs direct checks for desktop, tests, SDK stubs, and release scripts. |
| Process-launch surface | 609 matching lines across 163 files | New launch paths must name owner, environment propagation, cleanup behavior, and at least one test or release-gate check. |

Budget exceptions are allowed only when the PR body names the owner, the reason
the growth is release-critical, the tests that cover the changed boundary, and
the rollback path.

## No-go conditions

Do not merge a release-lane PR when any condition below is true:

- It creates a new source of truth for provider, backend, role, manifest,
  mailbox, readiness, or settings data without generation, validation, or an
  explicit compatibility shim.
- It expands one of the named compatibility exceptions instead of removing or
  containing it.
- It promotes `sdk/` or `git-graph/` from reference-only status without owner,
  support window, and CI coverage.
- It changes public user behavior without release notes and the support window
  required by `docs/project/compatibility-deprecation-policy.md`.
- It changes process launch, child-process cleanup, credential propagation, or
  environment handling without a focused test or release-gate command.
- It adds a new `docs/project/*.md` public document without the three public
  surface gates: `.gitignore` allowlist, legacy compatibility classification
  when legacy literals appear, and `.githooks/pre-commit-whitelist.ps1` entry.
- It changes external planning status without updating the authoritative
  planning file first and regenerating derived roadmap outputs.

## Release blockers

For v0.36.24, the release PR must stop until these checks are satisfied:

1. The final release head passes the public-surface audit and secret scan.
2. The final release head has a clean `chatgpt-codex-connector[bot]` review
   result or every finding has a fix or first-source reply and resolved thread.
3. No new compatibility exception exists outside the tables in this file and
   `docs/project/compatibility-deprecation-policy.md`.
4. Bridge command-shape changes include desktop, SDK-stub, test, and release
   script impact notes.
5. Version bump, release notes, and generated planning outputs agree on
   `v0.36.24`.
6. TASK-723 either lands before release or the release notes clearly say that
   bench preflight fairness assertions remain the next gate, not a completed
   release guarantee.

## Verification

Run these checks for this gate itself:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/PublicSurfacePolicy.Tests.ps1 -FullName '*design-freeze gate*' -PassThru"
pwsh -NoProfile -File scripts/audit-public-surface.ps1
pwsh -NoProfile -File .githooks/pre-commit-whitelist.ps1
rg -n "p(s)?mux|t[m]ux" docs/project/design-freeze-gate.md
```

Expected result: the first three commands succeed, and the `rg` command returns
no matches for this document. If a future edit intentionally adds one of those
legacy literals, update `docs/project/legacy-compat-surface-inventory.json` in
the same PR and explain why the public document needs it.

Extra checks are required when a PR touches a frozen area:

| Changed area | Extra evidence |
| --- | --- |
| Bridge command surface | Focused bridge test plus a desktop or release-script caller check. |
| Runtime provider, Agent Vault provider vocabulary, backend, or effort enum | Validator/caller parity evidence across TypeScript, PowerShell, and Rust. |
| Route roles | Explicit dispatch-to-coordinator map and tests rejecting cross-taxonomy strings. |
| Manifest or mailbox shape | Producer fixture and consumer validation evidence. |
| Process-launch topology | Test or release-gate output proving launch, cleanup, and environment handling. |
| SDK or standalone tooling promotion | Owner, support window, CI coverage, and rollback path. |

## TASK-723 handoff

TASK-723 remains the next release-lane implementation gate. This design-freeze
gate names bench fairness as a release blocker only after TASK-723 lands: the
operator must stay non-scored, every worker must use the same task set, timeout,
and workspace, operator intervention count must be zero, and worker-to-worker
messaging must be disabled or recorded as a failed preflight condition.
