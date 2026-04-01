# Development Environment

## Script Execution

- **PowerShell 7** (`pwsh`) for all automation scripts
- Scripts are located in `scripts/` directory

## Pre-commit Security

- Git hooks in `.githooks/` (pre-commit)
- Pre-commit hook blocks internal files (tasks/, scripts/, HANDOFF, INSTRUCTIONS) from being committed
- Configured via `git config core.hooksPath .githooks`

## Linting (Future)

- PowerShell: PSScriptAnalyzer (`Invoke-ScriptAnalyzer`)
- Markdown: markdownlint (optional)
- Currently: manual review + git-guard-scan

## Testing (Future)

- PowerShell: Pester 5.0+ (`Invoke-Pester -Verbose`)
- Currently: manual verification + git-guard checks

## Task Management

- **SoT**: `tasks/backlog.yaml`

## Important Commands

```powershell
# Sync project views (backlog → docs/project/)
pwsh ./scripts/sync-project-views.ps1

# Sync bilingual README
pwsh ./scripts/sync-readme.ps1

# Pre-commit hook (manual run)
bash .githooks/pre-commit
```
