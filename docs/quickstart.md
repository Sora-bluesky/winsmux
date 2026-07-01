# Quickstart: Desktop app

This guide is for a first-time Windows user who wants to install the `winsmux` desktop app and open the first project.

For normal use, start with the desktop app. If you want a CLI-first, headless, or scripted workflow, use the separate CLI path in [Installation](installation.md#cli-package-install) instead of following this page.

## 1. Prepare prerequisites

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- The official agent CLIs you want to use, such as Claude Code, Codex, Antigravity, or Grok Build

`winsmux` does not sign in to AI services for you. Each agent CLI keeps using its own official sign-in or API key setup.

## 2. Install the desktop app

1. Open the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest).
2. Download the `winsmux_..._x64-setup.exe` asset from Assets.
3. Run the installer.
4. After installation, open `winsmux` from Windows Search or the Start menu.

Windows Search or the Start menu does not need to show the app version. What matters is that `winsmux` appears as a normal Windows app and opens.

## 3. Open a project folder

When the desktop app starts, choose the project folder you want agents to work in.

You do not need to run CLI initialization commands by hand for the desktop path. In the desktop app, choose the project in the UI, then use the operator and worker panes.

## 4. Start from the operator

Type your first instruction in the operator pane.

Example:

```text
Inspect this repository and suggest the next safe task.
```

In `winsmux`, the operator watches the worker panes and sends instructions as needed. Do not accept worker output blindly; compare changes, command results, and review evidence before deciding what to keep.

## 5. Use worker panes

If worker panes are configured, the operator can route work to them.

Worker panes can use Claude Code, Codex, Antigravity, Grok Build, OpenRouter-backed models, and other supported providers. Check the desktop app Settings screen to confirm which model is assigned to each pane.

## 6. If the app does not open correctly

These states are not a successful desktop launch:

- a `localhost` connection error
- only a black PowerShell or Windows Terminal window
- a blank window, or an extremely small leftover window

See [Troubleshooting](TROUBLESHOOTING.md) for recovery steps.

## If you want the CLI path

For CLI-first, headless, or scripted operation, use the npm package. That path starts a managed Windows Terminal workspace; it does not open the desktop app.

The steps are separated in [Installation](installation.md#cli-package-install). Do not mix them into the desktop app first-run flow.

## Next steps

- Desktop installer, CLI path, updates, and uninstall: [Installation](installation.md)
- Launcher presets, worktree policy, slots, and credentials: [Customization](customization.md)
- Authentication boundaries: [Authentication support](authentication-support.md)
- Model and runtime policy: [Provider and model support](provider-and-model-support.md)
