# v0.36.22 Context Continuity and Reliable Coordination

v0.36.22 defines how winsmux preserves enough context to resume, route, and review multi-pane work without storing private transcripts or turning automation into final authority.

This release does not contain the formal six-pane benchmark. The benchmark lane uses these contracts later so the measurement reflects the completed coordination path.

## Contracts

| Contract | Purpose | Public boundary |
|---|---|---|
| Context Capsule v1 | Compact run summary for routing, review, and handoff. | Stores status, next action, evidence refs, digests, claim level, source SHA, and privacy flags. Does not store raw transcripts, prompt bodies, secrets, or private paths. |
| Reliable Mailbox v2 | Auditable worker-to-operator messaging. | Uses message, correlation, causation, idempotency, TTL, state, sender, recipient, and content metadata. Exit code alone is not delivery success. |
| Checkpoint package v1 | Restart-safe resume packet. | Stores objective, phase, next exact step, claim level, resume handle, source SHA, public changed files, verification state, active messages, and open questions. |
| Restore candidate v1 | Layer 1 restart discovery for sessions and runs. | Stores pane/session IDs, assignment metadata, transcript ring summaries, Context Capsule refs, and Checkpoint refs. It is enumerate-only and does not perform automatic restore. Does not store raw transcripts, prompt bodies, secrets, or private paths. |
| Context pressure status | Operator-facing context risk snapshot. | Separates usage, source, confidence, capsule age, checkpoint age, pending mailbox count, unresolved questions, state, and recommended action. Unknown values stay explicit. |
| Summary quality gate | Deterministic validation before routing automation. | Requires status, next action, evidence refs, freshness, SHA match, verification consistency, risks/questions separation, and redaction. |
| Split-worthiness policy | Suggests whether work should be split. | Suggestion only. The operator remains the final authority. |

## Required behavior

- Invalid or stale capsules must not be used for router or operator automation.
- Mailbox delivery is at least once and idempotent; duplicate side effects must be rejected by idempotency keys.
- Checkpoints must support restart-safe resume without depending on a provider-specific compact hook.
- Restore candidates must be enumerable from SessionRegistry metadata and `winsmux runs --json` without copying raw terminal transcripts, and incomplete restore metadata must be skipped rather than repaired implicitly.
- Context pressure must not display false precision.
- Summary quality failures must trigger re-summary or operator escalation.
- Split recommendations must not automatically create or start worker panes.

## Release evidence

The release gate should include focused schema tests, mailbox v2 conversion tests, checkpoint package tests, privacy checks, public-surface checks, and release/post-release smoke evidence.

## Phase 0 baseline boundary

v0.36.22 records a lightweight baseline only. It does not publish the formal six-pane benchmark or a model leaderboard.

| Item | v0.36.22 baseline | Boundary |
|---|---|---|
| Operator summary size | Bounded by Context Capsule fields. | Raw worker transcripts and prompt bodies are not copied into the capsule. |
| Worker output size | Not persisted as a routing artifact. | Formal per-worker output byte totals move to the GA-readiness bench lane (v0.36.43; re-scoped from v0.36.23 on 2026-07-05). |
| Manual cross-pane transfer | Replaced by Reliable Mailbox v2 metadata for auditable messages. | Message write success is not treated as delivery success. |
| Handoff and restart | Checkpoint package v1 records resume handle, next exact step, source SHA, active messages, and open questions. | Provider-specific compact hooks are optional, not required. |
| Task split decision | Split-worthiness is suggestion-only and governed by retry cost, context pressure, write conflict risk, and unhealthy scope. | It does not auto-create panes or bypass the operator. |
| Current verification cost | `ledger_contract` 80 tests passed, focused mailbox/runs/explain Pester 5 tests passed, planning sync compatibility 3 tests passed, desktop production build passed. | These are contract and build checks, not live provider or formal benchmark measurements. |

The formal benchmark must use the GA-readiness bench lane (v0.36.43, after the v0.36.39 Harness Bench productization lane; decision record in `docs/incidents/v03623-session-readiness/04-benchmark-readiness-gate.md`) after the release gate verifies that these coordination contracts are available to the desktop workflow.
