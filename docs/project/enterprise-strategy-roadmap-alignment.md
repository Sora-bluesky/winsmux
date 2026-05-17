# Enterprise Strategy Roadmap Alignment

Purpose: contributor-facing workflow note for `TASK-371`.

This document describes how winsmux keeps maintainer-only enterprise strategy input aligned with the roadmap without turning that input into public product narrative.

## Goal

The alignment rule answers one question:

> Where should an internal enterprise strategy change land in the existing roadmap?

It does **not** publish the strategy source, promise enterprise features early, or create a new product lane.

## Stable Roadmap Placement

Use these placements when internal strategy input affects planning:

| Area | Roadmap placement | Public narrative rule |
| --- | --- | --- |
| stabilization, desktop truth, compare UX, launcher UX | `v0.22.x` and nearby stabilization lanes | Describe reliability and operator clarity. Do not describe internal enterprise positioning. |
| Rust/Tauri migration and typed machine contracts | `v0.24.x` and Rust contract lanes | Describe durable contracts and verification evidence. Do not claim a complete enterprise platform. |
| semantic context packs and durable coordination | `v1.3.0` | Describe managed coordination and context references. Do not expose private strategy notes. |
| isolated execution substrate | `v1.4.0` | Describe explicit execution profiles and local boundaries. Do not imply broad hosted policy control. |
| approval, audit, and policy visibility | `v1.5.0` and `v1.6.0` | Describe evidence, approval records, and enforced policy surfaces. Do not turn reviewer prose into approval authority. |
| governance and threat-model packaging | `post-v1.0.0-governance` | Describe reviewable governance artifacts. Do not move private planning paths into public docs. |

If an input does not fit one of these placements, keep it in external planning until a clear destination exists.

## Public and Private Boundary

Public docs may describe:

- user-facing capability contracts
- verification and evidence expectations
- operator-owned final judgement
- explicit execution profiles
- approval and audit record shapes

Public docs must not include:

- private strategy source text
- maintainer-local planning paths
- prompt bodies or private skill bodies
- absolute market claims
- a new release lane created only from internal positioning

The public contract is the placement rule and the resulting durable surface. The private input that triggered the placement stays outside the public repository.

## Alignment Record

Every accepted alignment update should leave a short durable record in the external planning source of truth.

That record should include:

1. the internal input date or range
2. the roadmap placement selected
3. the public surface, if any, that changed
4. the surfaces intentionally left unchanged
5. the related issue and `TASK-*` entry

For `TASK-371`, issue `#454` is the completion record. The related public release must point to a PR, release URL, validation evidence, and synced roadmap state before `#454` is closed.

## Acceptance Checklist

Before closing an alignment task, confirm all of these:

1. The roadmap placement matches the stable table above.
2. Public docs keep winsmux product language and do not reveal private strategy source text.
3. Existing stabilization, Rust migration, approval, audit, and isolated execution lanes remain structurally stable.
4. The external roadmap and backlog show the accepted task state.
5. The release note explains the public contract without exposing private inputs.
