# Quickstart

This guide takes a new Windows user from install to a first managed pane run.

## 1. Check requirements

Install these first:

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js with `npm`
- The official agent CLIs you want to run, such as Codex, Claude Code, or Gemini

## 2. Install winsmux

For the desktop app, download `winsmux_<version>_x64-setup.exe` from the matching GitHub Release and run it. After launch, choose the project folder you want agents to work in.

For CLI-first setups, install the npm package:

```powershell
npm install -g winsmux
winsmux install --profile full
```

The `full` profile installs the terminal runtime, orchestration scripts, Windows Terminal profile, vault support, and audit-oriented helpers.

Quick install:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

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

Check the configured workers before sending work:

```powershell
winsmux workers status
winsmux workers attach w2
winsmux workers doctor
```

For Colab-backed worker slots, run one file-backed task and inspect its log:

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"Implement this change"}' --worker-id worker-2 --run-id demo-1
winsmux workers logs w2
```

The tracked templates in `workers/colab/` cover implementation, critique,
repository scouting, test execution planning, and heavy second-opinion work.
They emit structured JSON and write artifacts under
`/content/winsmux_artifacts/<worker_id>/<run_id>/` by default.

Uploads are intentionally constrained. Explicit files are allowed, while
directory uploads require `--allow-dir` and still exclude `.git`, secrets,
`node_modules`, virtual environments, build outputs, coverage, and oversized
files by default.

For Colab-backed model work, prepare a Colab notebook or an adapter-managed
equivalent connected to `H100` or `A100`. winsmux records model metadata such
as `model_family` and `model_id`, but the task script loads the exact model,
including Gemma, Llama, Mistral, Qwen, DeepSeek, Kimi/Moonshot, and distilled
variants.

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
- Review model and runtime policy in [Provider and model support](provider-and-model-support.md).
- Prepare GPU-backed one-shot execution in [Google Colab workers](google-colab-workers.md).
