# Codex Release Template Alignment

Updated: 2026-04-11

## Purpose

Persist the public GitHub Release format that winsmux should follow.
This is written to be readable by both Codex and Claude Code style agents.

## Source

- Official reference: [openai/codex `rust-v0.119.0`](https://github.com/openai/codex/releases/tag/rust-v0.119.0)

## Default public release structure

Use this section order when the content exists:

1. `New Features`
2. `Bug Fixes`
3. `Documentation`
4. `Chores`
5. `Full Changelog`

Rules:

- Public GitHub Releases stay in English.
- Omit empty sections instead of leaving placeholders.
- `Full Changelog` should point to the compare range for the released tags when available.
- Reuse the structure, not the wording. Do not copy Codex release prose verbatim.
- Keep bullets factual and scoped to winsmux changes only.

## What to carry over from Codex

- Clear top-level categorization by change type.
- Short factual bullets with links or PR references when useful.
- A final compare-range link as `Full Changelog`.
- Separation between user-visible features, bug fixes, docs, and maintenance work.

## What not to carry over blindly

- Codex-specific product wording.
- Sections that have no winsmux content for a given release.
- Implementation details that belong in PRs or handoff, not public release notes.

## Relevant observations from `rust-v0.119.0`

- The release keeps the body easy to scan by grouping many commits into a few user-meaningful headings.
- TUI, MCP, remote/app-server, and notification updates are surfaced under `New Features`.
- Stabilization and usability work are grouped under `Bug Fixes`.
- README/help wording changes stay under `Documentation`.
- crate/workspace/CI/compiler work stays under `Chores`.
- The release ends with a compare link, not a raw dump only.

## winsmux mapping

- `New Features`
  - user-visible operator shell, orchestration, desktop UX, or release capabilities
- `Bug Fixes`
  - regressions, fail-close behavior, runtime fixes, review-path fixes
- `Documentation`
  - public docs, help text, release wording, handoff-related public docs when user-facing
- `Chores`
  - CI/workflow maintenance, internal cleanup, non-user-facing refactors
- `Full Changelog`
  - compare link between the previous release tag and the current release tag
