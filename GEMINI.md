# Gemini Project Rules — winsmux

Windows-native AI agent orchestration platform built on winsmux-core.

## Architecture

- `winsmux-core/`: CLI core for vault, settings, role gates, orchestra scripts.
- `.claude/hooks/`: PreToolUse hooks for governance enforcement.
- `install.ps1`: Downloads the winsmux-core binary from GitHub Releases.

## Conventions

- Commit messages: English, conventional commits (`feat:`, `fix:`, `chore:`).
- PowerShell: strict mode, UTF-8, `$ErrorActionPreference = 'Stop'`.

## Commands

```powershell
# Pester tests
NO_COLOR=1 pwsh -Command "Invoke-Pester tests/ -Output Minimal"

# Version bump
pwsh scripts/bump-version.ps1 -Version X.Y.Z
```
