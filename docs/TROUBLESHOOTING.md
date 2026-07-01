# Troubleshooting

Use this guide when winsmux install, launch, panes, credentials, or release checks do not behave as expected.

## Startup problems

The `winsmux launch` commands in this section refer to the npm/CLI package path.
They start the managed Windows Terminal workspace. They do not open the desktop
app; use the installed desktop app directly when troubleshooting the graphical
control surface.

### Desktop app opens to a localhost connection error, blank page, or frozen window

The desktop app is the recommended graphical entrypoint. Open the installed
`winsmux` app from the Start menu or desktop shortcut after installing the
`winsmux_..._x64-setup.exe` asset from the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest).
`winsmux launch` is a CLI entrypoint and does not open the desktop app.

After installation, Windows Search should find the app by the name `winsmux`.
Windows Search does not have to show the version number. When you need install
metadata, check Windows Settings > Apps > Installed apps.

If the desktop app opens but shows a localhost connection error, a blank page, or
stops responding:

1. Close the `winsmux` desktop window.
2. Check whether an old desktop process is still running:

   ```powershell
   Get-Process winsmux-app -ErrorAction SilentlyContinue |
     Select-Object Id,ProcessName,Path,StartTime
   ```

3. If the listed process is the installed winsmux desktop app you just opened,
   close it from Windows Task Manager and open winsmux again.
4. If a black PowerShell, Windows Terminal, or WebView2 console window appears
   with the desktop app, close winsmux and file an issue. A normal desktop
   startup should show the winsmux window only.
5. If the issue repeats after a reboot, reinstall the desktop installer from
   the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest)
   for normal recovery. If you are reproducing a bug tied to a specific version,
   reinstall that exact release instead. Attach `.winsmux/startup-journal.log`,
   `.winsmux/manifest.yaml`, the installer version, and a screenshot.

### `Orchestra already starting (lock exists)`

Cause: a previous startup ended before removing the lock file.

Fix:

```powershell
winsmux list
Get-Process winsmux-app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path,StartTime
```

Only remove the lock when there is no live winsmux session for this project and
no running desktop app using it:

```powershell
Remove-Item .winsmux/orchestra.lock -Force
```

Then run the CLI workspace startup again:

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

### Verify desktop child-process cleanup

Closing the desktop app requests the summary stream to stop, stops native voice
capture when active, drains the PTY pane registry, and waits briefly after
killing worker-pane child processes. If the desktop feels slow to exit, wait a
few seconds before checking process state.

When debugging a suspected leak, check for winsmux-owned processes before
killing anything:

```powershell
Get-Process winsmux-app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path,StartTime
```

Stop only the process you can identify as the current winsmux desktop session.
Do not stop unrelated terminals, package manager processes, or other projects'
development tools.

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
