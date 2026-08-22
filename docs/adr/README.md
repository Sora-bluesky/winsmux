# Architecture decision records

This file is the recorded method for durable architecture decisions.
It does not own domain maps or repository surfaces.

- Domain ownership: [Component map](../project/component-map.md)
- Surface classification: [Repository surface policy](../repo-surface-policy.md)
- Contribution workflow: [CONTRIBUTING](../../CONTRIBUTING.md)

[v0.36.24 Design Freeze Gate](../project/design-freeze-gate.md) is a historical snapshot. Do not treat it as the current decision log.

## When a record is required

Write a record before a change that is durable and cross-domain: it assigns or moves ownership, changes a process or contract boundary, or removes a named compatibility path. Do not write a record for a single-file bug fix, a test-only pin, or a VERSION synchronization.

## Who does what

A coding agent may draft the record and attach evidence. A human maintainer accepts or rejects it. An agent does not mark a record accepted.

## Status

| Status | Meaning |
| --- | --- |
| `proposed` | Draft. Not yet accepted. |
| `accepted` | A human maintainer accepted the decision. |
| `superseded` | Replaced by a later record. Name that record. |
| `rejected` | A human maintainer rejected the proposal. Keep the file. |

Status moves only `proposed` → `accepted` or `proposed` → `rejected`, and `accepted` → `superseded`. Do not skip `proposed`.

## Naming

Store each record as `docs/adr/YYYY-MM-DD-slug.md` next to this file. The date is the proposal date. The slug is lowercase hyphenated English. Do not number records.

## Template

Copy this block into a new file. Fill every heading. Link authority. Do not paste ownership tables, PR-budget rules, or another task's decision.

```markdown
# <title>

- Status: proposed
- Date: YYYY-MM-DD
- Authors: <human maintainer; agent drafts named as drafts>

## Context

Why a decision is needed now.

## Decision

The choice, in one paragraph.

## Alternatives

What was considered and why it was not chosen.

## Affected domains

Name domains from the component map. Do not copy that table.

## Authority

Which existing contract remains source of truth (component map, surface policy, CONTRIBUTING, or a named runtime contract). This record must not replace that contract.

## Evidence

Commands, file:line, or review sessions that support the decision.

## Cutover

What changes after acceptance, and what stays unchanged.

## Rollback

How to undo the decision.

## Supersession

`none`, or the later record that replaces this one.
```
