# Repository Surface Policy

winsmux uses a single public repository, but it does not treat every tracked file as the same kind of surface.

All new files must be classified into one of these surfaces before they are added or changed.

## 1. Public product surface

This is the public product-facing surface for external users.

Examples:

- `README.md`
- `README.ja.md`
- `docs/operator-model.md`
- `docs/TROUBLESHOOTING.md`
- `core/docs/*`
- product code and public release assets

Rules:

- safe to publish as-is
- must not contain maintainer-local paths
- must not require private planning roots or live operational notes
- must not link readers directly into local-only operational files

## 2. Runtime contract surface

This surface is tracked, but it is for repository-operated runtime contracts, not for the public product guide.

Examples:

- `.claude/CLAUDE.md`
- `AGENT-BASE.md`
- `AGENT.md`
- `GEMINI.md`
- `AGENTS.md`
- `GUARDRAILS.md`
- `.agents/skills/**`

Rules:

- may describe repo-operated and dogfooding runtime behavior
- must still avoid maintainer-local absolute paths
- may not depend on tracked live handoff files
- public docs should not use this surface as the primary reader entrypoint

## 3. Contributor/test surface

This surface is tracked, but it is for contributors, CI, validation, and fixtures rather than operator/runtime contracts.

Examples:

- `tests/**`
- `.githooks/**`
- `.github/workflows/**`
- `scripts/audit-public-surface.ps1`
- `scripts/git-guard.ps1`
- contributor-only maintenance docs

Rules:

- may include CI, validation, fixture, and contributor workflow details
- should avoid maintainer-local absolute paths in durable docs and scripts
- may use synthetic or fixture-only sample data in tests when clearly non-secret
- is not part of the public product guide or pane runtime contract

## 4. Private live-ops surface

This surface is for live operational state and maintainer-only material.

Examples:

- current operator handoff
- `HANDOFF.md`
- `docs/handoff.md`
- live roadmap title overrides
- local planning notes
- maintainer-only checklists

Rules:

- never tracked
- stored in ignored local paths or the external planning root
- may contain active branch names, live PR state, local planning roots, and temporary operational guidance

Default local handoff location:

- `.claude/local/operator-handoff.md`

Default external planning location:

- the planning root resolved by `winsmux-core/scripts/planning-paths.ps1`

## 5. Generated/runtime artifacts

Generated output and runtime state.

Examples:

- `.winsmux/`
- `.orchestra-prompts/`
- `testResults.xml`
- temporary cache and marker files

Rules:

- never tracked
- safe to delete and regenerate

## Durable publication rules

1. A tracked file must belong to `Public product surface`, `Runtime contract surface`, or `Contributor/test surface`.
2. A live operational file must not be tracked.
3. A tracked file must not be ignored by `.gitignore`.
4. Public docs must not instruct readers to use private live-ops files.
5. Any maintainer-local path such as `C:\Users\...`, `iCloudDrive`, or `MainVault` is forbidden in tracked docs.
