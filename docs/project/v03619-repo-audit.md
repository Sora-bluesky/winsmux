# v0.36.19 Repository-Wide Audit

This document records the v0.36.19 repository-wide re-audit package. It is a
release stabilization artifact, not a feature specification.

## Scope

v0.36.19 covers regression risk across:

- Rust core build and test workflows
- Desktop build and release workflows
- PowerShell runtime settings and provider capability validation
- Public installation documentation
- npm package release staging
- Desktop installer artifact naming
- Worker-pane model catalog consistency

The release is complete only after the pull request, merge, GitHub Release,
post-release smoke checks, and branch cleanup finish.

## Baseline Package

| Area | Baseline | v0.36.19 expectation |
|---|---|---|
| Version surface | `VERSION`, Rust crates, npm packages, Tauri config | all set to `0.36.19` |
| Pester matrix | split categories in `.github/workflows/test.yml` | full-name filters must have source matches before execution |
| npm release | `scripts/stage-npm-release.mjs` rewrites package version | staged package must not retain `0.0.0-development` |
| desktop release | release docs specify versioned NSIS/MSI names | workflow must validate exact versioned filenames |
| public docs | installer-first desktop distribution | portable fallback must mention both x64 and arm64 core binaries |
| model runtime | desktop catalog from `winsmux-app/src/modelCapabilities.ts` | UI provider list must not expose the retired standalone Gemini provider |
| reasoning effort | provider-specific values | `none` and `minimal` must not be accepted as reasoning effort values |

## v0.36.14 to v0.36.18 Regression Delta

| Source release | Regression surface | v0.36.19 treatment |
|---|---|---|
| v0.36.14 | worker-pane model picker and benchmark comparison introduced provider/model/effort configuration | audit UI/runtime source-of-truth drift and provider-specific reasoning effort |
| v0.36.17 | benchmark readiness depended on real worker-pane assignments | keep benchmark execution out of v0.36.19, but verify the model catalog does not mislabel setup state |
| v0.36.18 | release hardening added lifecycle and loop-control gates | keep hardening gates and add repo-wide audit checks for CI/release drift |

## Fix Findings

| ID | Severity | Finding | Treatment |
|---|---|---|---|
| A-001 | High | Desktop runtime provider type still contained a retired standalone `gemini` provider while the catalog uses Antigravity-hosted Gemini models. | Fixed in `winsmux-app/src/main.ts`. |
| A-002 | High | PowerShell provider registry accepted `none` and `minimal` as reasoning efforts even though current provider UIs do not expose those values. | Fixed in `winsmux-core/scripts/settings.ps1`. |
| CI-01 | High | Pester matrix full-name filters could drift without an explicit source-match guard. | Fixed in `.github/workflows/test.yml`. |
| CI-05 | Medium | Long-running CI and release jobs lacked explicit timeouts. | Fixed in workflow files. |
| C2-VULN-001 | Medium | npm release staging relied on script output but did not assert staged package version after writing. | Fixed in `.github/workflows/release-npm.yml`. |
| C2-ASSET-002 | Medium | desktop release workflow collected installer artifacts by wildcard without validating documented filenames. | Fixed in `.github/workflows/release-desktop.yml`. |
| C2-DOC-003 | Low | portable fallback docs mentioned only the x64 core binary while release workflow publishes x64 and arm64. | Fixed in `docs/installation*.md`. |

## Deferred Findings

| ID | Severity | Reason deferred |
|---|---|---|
| A-003 | High | Session registry rename/claim atomicity is shared Rust control-plane behavior and needs focused design plus Rust tests. Track for a follow-up release before GA. |
| CI-03 | Medium | Eliminating runtime Pester installation needs a broader dependency/cache policy. Track as CI reliability work. |
| CI-04 | Medium | Reusable secret/public-surface checks in tag release workflows need a workflow factoring pass. Track after v0.36.19 release. |
| CI-06 | Low | Explicit artifact retention is useful but not release-blocking. Track as CI polish. |
| TST-07 | Medium | Skipped acceptance suites need scheduled coverage with real prerequisites. Track after current release gates. |
| WIN-08 | Medium | Real process lifecycle/port cleanup integration coverage needs a controlled Windows test harness. Track after current static release audit. |

## Release Artifact Verification Manifest

The v0.36.19 release gate must verify:

- `release-npm.yml` fails if staged `package.json` remains `0.0.0-development`.
- `release-npm.yml` fails if staged package version differs from the tag or workflow-dispatch version.
- `release-desktop.yml` fails if `winsmux_<version>_x64-setup.exe` is absent.
- `release-desktop.yml` fails if `winsmux_<version>_x64_en-US.msi` is absent.
- `release-core.yml` continues to publish `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- `docs/installation.md` and `docs/installation.ja.md` document both core binary fallback names.
- `tests/V03619RepoAudit.Tests.ps1` and `scripts/test-v03619-repo-audit.ps1` pass.

## Release Notes Draft

### English

v0.36.19 is a repository-wide release audit and hardening release. It adds
explicit CI timeouts, guards Pester category filters against source drift,
validates staged npm package versions, validates documented desktop installer
asset names, aligns portable fallback documentation with x64 and arm64 core
artifacts, and removes stale standalone Gemini provider handling from the
desktop runtime model picker.

### Japanese

v0.36.19 は、リポジトリ全体の再監査とリリース前の仕上げを目的とした安定化版です。
CI のタイムアウト、Pester カテゴリフィルタの空振り検知、npm staged package の
version 検証、デスクトップインストーラー成果物名の検証、x64/arm64 core binary の
fallback 文書化、デスクトップモデル選択に残っていた旧 standalone Gemini provider
扱いの削除を行います。
