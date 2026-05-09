# Quickstart

This guide takes a new Windows user from install to a first managed pane run.

## 1. Check requirements

Install these first:

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js with `npm`
- The agent CLIs you want to run, such as Codex CLI, Claude Code, or Gemini CLI

## 2. Install winsmux

For the desktop app, download `winsmux_<version>_x64-setup.exe` from the matching GitHub Release and run it. After launch, choose the project folder you want agents to work in.

For CLI-first setups, install the npm package:

```powershell
npm install -g winsmux
winsmux install --profile full
```

The `full` profile installs the terminal runtime, orchestration scripts, Windows Terminal profile, vault support, and audit-oriented helpers.

## 3. Create project settings

From the repository or project you want agents to work in:

```powershell
winsmux init
```

The default workspace lifecycle is `managed-worktree`, which keeps worker file changes separated.

## 4. Launch the workspace

```powershell
winsmux launch
```

This starts the managed Windows Terminal workspace. In the desktop app, use the project selector to open the same project and inspect the operator and worker panes from the control plane. The operator remains responsible for reading pane output and deciding what to accept.

## 5. Read and send

Check a pane before sending instructions:

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-1 "Inspect the current branch and report the next safe step."
```

The final number for `winsmux read` is the number of tail lines to capture.

## 6. Compare work

After two recorded runs exist, compare them before choosing a winner:

```powershell
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare promote <run_id>
```

## Next steps

- Choose install profiles and update behavior in [Installation](installation.md).
- Customize launcher presets, worktree policy, slots, and credentials in [Customization](customization.md).
- Review authentication boundaries in [Authentication support](authentication-support.md).
