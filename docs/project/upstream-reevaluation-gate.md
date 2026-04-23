# Upstream Reevaluation Gate

Purpose: contributor-facing workflow note for `TASK-315`.

This document describes how winsmux reassesses upstream patterns without turning every public change into a constant-follow exercise.

## Goal

The reevaluation gate exists to answer one question:

> Which upstream structures, checklists, and policy shapes should become durable winsmux contracts?

It does **not** exist to copy generic persona prompts into the public repository.

## What counts as input

Representative reevaluation inputs are:

- official documentation
- release notes
- public CLI help surfaces
- public harness structure
- public checklist and policy shape
- public issue or PR discussions when they reveal stable contract patterns

The gate is intentionally selective.
An upstream source is only adopted when it improves one or more of these:

- security
- user-facing clarity
- maintainability
- evidence quality
- operator judgement quality

## What the gate produces

The gate may update:

- public product docs such as `README.md`, `README.ja.md`, and `docs/operator-model.md`
- contributor/test docs such as this directory and `docs/repo-surface-policy.md`
- external planning notes and roadmap sync output
- private maintainer skills outside the public repository

The gate must keep these outputs separate.
Public docs get durable contracts.
Private maintainer skills get maintainer-only bodies and detailed prompt assets.

## Default landing zones

Accepted patterns should land in the smallest durable surface that matches their effect.

Use these defaults:

- public product docs:
  - user-facing capability contracts
  - public verification expectations
  - operator judgement boundaries that users must understand
- contributor/test docs:
  - contributor workflow notes
  - public/private boundary rules
  - validation and evidence-shape rules for contributors
- external planning:
  - task-level scope changes
  - roadmap placement
  - issue-to-task mapping
  - reevaluation outcomes that change version or lane priority
- private maintainer assets:
  - maintainer-only skill bodies
  - maintainer-only prompt assets
  - local operating details that are not durable public contracts

The current default task mapping for `#460` is:

- `TASK-315`: reevaluation gate and adoption rule
- `TASK-321`: review evidence envelope
- `TASK-323`: public capability and evidence contract inventory
- `TASK-337`: command/help surfaces that expose required evidence and judgement boundaries
- `TASK-361`: context-pack references that carry evidence without exposing prompt bodies
- `TASK-362`: approval and audit evidence normalization

If a pattern does not clearly fit one of those landing zones, reject it until the destination is clear.

## Minimum reevaluation record

Every accepted reevaluation pass should leave a short durable record.

That record should answer these questions:

1. Which upstream source set was reviewed?
2. Which patterns were accepted?
3. Which patterns were rejected?
4. Which landing zone received the accepted change?
5. Which issue and `TASK-*` entries now track the result?

Use this minimum shape:

- source date or release range
- source type:
  - official docs
  - release notes
  - CLI help
  - policy/checklist shape
  - public issue/PR discussion
- accepted pattern summary
- rejected pattern summary with a reason
- landing zone:
  - public docs
  - contributor docs
  - external planning
  - private maintainer assets
- related issue or PR
- related `TASK-*`

If that record cannot be written clearly, the pattern is not ready to become a durable contract.

When the input reveals public metadata drift such as version, naming, or license mismatch,
do not patch around it in unrelated product docs.
Open or update a public issue, map it into the release-hardening lane, and only then decide
which public docs need a follow-up correction.

## Command surface

The working command surface for `TASK-315` is:

- `collect`
- `summarize`
- `assess`
- `prune`
- `plan`
- `apply`

Those verbs mean:

- `collect`: gather the relevant upstream source set
- `summarize`: reduce it to reusable patterns
- `assess`: decide whether the pattern improves winsmux
- `prune`: reject cargo-cult adoption and remove stale assumptions
- `plan`: map accepted patterns into tasks and docs
- `apply`: update the public contract, contributor docs, planning, or private maintainer assets

## Public/private boundary

When the reevaluation gate touches public surfaces:

- publish capability contracts
- publish evidence contracts
- publish operator judgement boundaries

Do not publish:

- generic persona prompt bodies
- maintainer-only skill bodies
- private planning paths
- local operational notes

## Current Rust-oriented baseline

For Rust-oriented work, the representative verification evidence set is:

- `cargo fmt --check`
- `cargo clippy -- -D warnings`
- `cargo test`
- `cargo audit`

These commands are representative evidence, not the whole workflow.
The public contract is that winsmux treats their results as reusable evidence.
The public contract is **not** a promise to expose a generic Rust persona prompt.

## Acceptance rule

Before an upstream pattern becomes a durable contract, confirm all of these:

1. The change improves a stable winsmux surface.
2. The public docs only describe durable contracts.
3. Maintainer-only prompt bodies stay outside the public repository.
4. Planning notes and public docs do not contradict each other.
5. Final accept/reject judgement remains with the operator.
