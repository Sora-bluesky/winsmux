# Pester Tests

Requires PowerShell 7.6.x and `Pester` 5.0 or later. This requirement applies
to the official developer Pester runner; product PowerShell support remains 7+.

## Run

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-tests.ps1
```

## Naming Convention

Use `test_{subject}_{condition}_{expected_result}` for test names.
