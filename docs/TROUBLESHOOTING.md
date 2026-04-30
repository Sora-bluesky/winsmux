# Troubleshooting

Use this guide when winsmux install, launch, panes, credentials, or release checks do not behave as expected.

## Startup problems

### `Orchestra already starting (lock exists)`

Cause: a previous startup ended before removing the lock file.

Fix:

```powershell
Remove-Item .winsmux/orchestra.lock -Force
```

Then run:

```powershell
winsmux launch
```

### Empty pane or agent does not start

Cause: the pane shell may not have been ready when the agent was sent its startup command.

Fix:

```powershell
winsmux doctor
winsmux launch
```

If only one pane is affected, read the pane before sending another instruction:

```powershell
winsmux read <pane> 60
```

The final number for `winsmux read` is the number of tail lines to capture.

### `pwsh.exe` fails with `0xc0000142`

This is Windows status `STATUS_DLL_INIT_FAILED`: Windows could not initialize a DLL required by `pwsh.exe`. If bare PowerShell works but winsmux launch fails, the issue is likely tied to a specific launch path, parent process, profile, environment, or Windows Terminal pane command.

Check bare PowerShell:

```powershell
where.exe pwsh
pwsh -NoProfile -NoLogo -Command "Write-Output `$PSVersionTable.PSVersion"
```

Check winsmux diagnostics:

```powershell
winsmux doctor
```

Check recent Windows application errors:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-6)} |
  Where-Object { $_.Message -match 'pwsh.exe|0xc0000142' -or $_.ProviderName -match 'Application Error|Windows Error Reporting' } |
  Select-Object -First 20 TimeCreated,ProviderName,Id,LevelDisplayName,Message
```

If bare PowerShell fails, repair or reinstall PowerShell 7 and reboot Windows. If bare PowerShell works, check the Windows Terminal profile command line and the winsmux pane startup logs.

## Pane and sandbox problems

### Codex asks for approval on every command

Cause: Codex may be configured for an elevated Windows sandbox.

Fix:

```toml
[windows]
sandbox = "unelevated"
```

### File writes or git commands fail inside a Codex pane

Symptoms:

- `git add` or `git commit` fails because `.git/worktrees/*/index.lock` cannot be created.
- PowerShell is in Constrained Language Mode.
- `Set-Content`, `Out-File`, or `[IO.File]::*` fails.

Fix:

- keep editing and focused verification inside the pane
- run repository-level `git add`, `git commit`, and `git push` from a regular shell
- use `apply_patch` or `cmd /c` for pane-side file writes

## Credential problems

### Vault key not found

Cause: the key is not stored in Windows Credential Manager.

Fix:

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux does not extract tokens from other CLIs. See [Authentication support](authentication-support.md).

## Diagnostics

```powershell
winsmux doctor
winsmux version
winsmux list
winsmux read <pane> 60
```

The final number for `winsmux read` is the number of tail lines to capture.

Important local logs:

| File | Purpose |
| ---- | ------- |
| `.winsmux/startup-journal.log` | startup failures |
| `.winsmux/manifest.yaml` | current workspace state |
