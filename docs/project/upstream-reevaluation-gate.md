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
