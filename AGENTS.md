# Codex Project Rules — winsmux

## Windows Sandbox: Constrained Language Mode Workaround (CRITICAL)

On Windows, the Codex sandbox (`unelevated`) runs PowerShell in ConstrainedLanguageMode.
This blocks Set-Content, Out-File, Add-Content, property assignments, and most file-editing cmdlets.

**You MUST use these alternatives for ALL file operations:**

### Writing/creating files

Use `apply_patch` (preferred) or `cmd /c`:

```
# PREFERRED: apply_patch for creating/editing files
apply_patch <<'EOF'
--- /dev/null
+++ path/to/file.ps1
@@ -0,0 +1,3 @@
+line 1
+line 2
+line 3
EOF

# ALTERNATIVE: cmd /c for simple writes
cmd /c "echo content > path\to\file.txt"
```

### Forbidden commands (will fail silently or error)

- `Set-Content` / `Out-File` / `Add-Content`
- `[IO.File]::WriteAllText()` / `[IO.File]::WriteAllBytes()`
- Property assignment on non-core types
- `New-Object` with non-core types

### Safe commands (these still work)

- `Get-Content` (reading files is allowed)
- `Test-Path`, `Get-Item`, `Get-ChildItem`
- `git` commands
- `cmd /c` (cmd.exe is not subject to CLM)
- `apply_patch` (Codex built-in tool, bypasses shell entirely)

## Project Context

winsmux is a Windows-native AI agent orchestration platform.
Builders operate in isolated git worktrees under `.worktrees/builder-N/`.
