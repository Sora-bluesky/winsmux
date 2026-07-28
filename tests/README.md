# Pester Tests

Requires `Pester` 5.0 or later.

## Run

Repository Pester validation requires PowerShell 7.6 or later. Run it through
the canonical developer runner:

```powershell
pwsh -NoProfile -File scripts/run-tests.ps1
```

## Naming Convention

Use `test_{subject}_{condition}_{expected_result}` for test names.
