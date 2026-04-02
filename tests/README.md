# Pester Tests

Requires `Pester` 5.0 or later.

## Run

```powershell
Invoke-Pester -Configuration (Import-PowerShellDataFile tests/.pester.ps1)
```

## Naming Convention

Use `test_{subject}_{condition}_{expected_result}` for test names.
