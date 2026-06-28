# Council Review Protocol

## Sections

Each patch attempt records these five sections before implementation:

1. Evidence: observed failure and reproduction command.
2. Scope: the single factor allowed to change.
3. Test: failing contract or matrix cell that must pass.
4. Risk: behavior, rollback, and security/privacy impact.
5. Decision: one of `PATCH`, `HOLD`, `REVERT`, or `ESCALATE_READ_ONLY_REVIEW`.

## Review 001: Fixture First

### Evidence

No product patch is trusted because the dirty tree mixes startup retry, registry handling, stale cleanup, warm server behavior, and bootstrap shell changes.

### Scope

Add only reproducible session readiness fixtures and incident records. Do not change product runtime logic.

### Test

Create:

- `cargo test -p winsmux --test session_contract_test`
- `pwsh -NoProfile -File scripts\test-v03623-session-readiness.ps1 -Json`

### Risk

The fixture creates temporary `USERPROFILE` homes and namespaces every run. It must not read or emit session keys, and `kill-server` must be scoped with `-L`.

### Decision

`PATCH`
