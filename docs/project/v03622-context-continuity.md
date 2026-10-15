# Context continuity and reliable coordination

winsmux defines how it preserves enough context to resume, route, and review multi-pane work without storing private transcripts or turning automation into final authority.


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

See the [operator model](../operator-model.md) for the public control-plane workflow.
