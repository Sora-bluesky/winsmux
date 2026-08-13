# Pester Tests

Requires `Pester` 5.0 or later.

## Run

Prefer the canonical operator/CI runner (TASK-800 / TASK-810):

```powershell
pwsh -NoProfile -NoLogo -NonInteractive -File scripts/run-tests.ps1
```

For a single file during development you may still use Pester 5 configuration, but operator full-suite entry points must go through `scripts/run-tests.ps1` (or the shared leaf `scripts/operator-run-full-tests.ps1`).

## Naming Convention

Use `test_{subject}_{condition}_{expected_result}` for test names.
