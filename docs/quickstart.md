# Quickstart: Desktop app

This guide covers the v0.38.0 desktop app: opening a project, working in panes, and inspecting artifacts. Its controls differ from the operator/worker screen in older versions. Check the version of the app you downloaded and use the guide shipped with that version.

For normal use, start with the desktop app. If you want a CLI-first, headless, or scripted workflow, use the separate CLI path in [Installation](installation.md#cli-package-install) instead of following this page.

## 1. Prepare prerequisites

- A Windows build and CPU architecture supported by the selected release
- PowerShell 7+
- Microsoft Edge WebView2 Runtime for the desktop UI
- The official agent CLIs you want to use. The AI launch screen offers Codex and Claude Code.

`winsmux` does not sign in to AI services for you. Each agent CLI keeps using its own official sign-in or API key setup.

## 2. Install the desktop app

1. Choose the version you intend to install from [Releases](https://github.com/Sora-bluesky/winsmux/releases).
2. Download the Windows setup asset for your architecture and verify it using that release's verification information.
3. Run the installer.
4. After installation, open `winsmux` from Windows Search or the Start menu.

Windows Search or the Start menu does not need to show the app version. What matters is that `winsmux` appears as a normal Windows app and opens.

## 3. Open a project folder

When the desktop app starts, choose the project folder you want agents to work in.

Use **プロジェクトを開く** (Open project) to select a local folder. Check the selected project and the displayed working directory. You do not need to run CLI initialization commands by hand for the desktop path.

**一覧から外す（ファイルは保持）** (Remove from list; keep files) removes the registration. It does not delete the project's files.

## 4. Work in panes

Use **新しいペイン** (New pane) to open a terminal. **左右に分割** and **上下に分割** split the working area horizontally or vertically. Check the selected project and pane before an operation.

You can create up to four panes in a project. When it has four or more, **新しいペイン** and the split buttons are disabled. Close a pane before adding another.

For Japanese input, click the terminal, type using your IME, convert with Space, and commit with Enter. Distinguish committing an IME composition from pressing Enter to execute a shell command.

Use **操作検索** (Operation search) to find controls. App shortcuts are Ctrl+Shift+P (operation search), Ctrl+Shift+T (new pane), and Ctrl+Shift+W (close the selected pane). Uncheck **アプリのショートカットを使う** to stop using these combinations for app operations.

## 5. Choose and start an AI

1. Select the target project and pane, then choose Codex or Claude Code.
2. Check the detected official CLI and working directory. After updating a CLI, use **導入状況を再確認** (Recheck installation).
3. Optionally specify the model and reasoning setting. Empty fields use the official CLI's defaults.
4. Select **起動内容を確認** (Review launch), check the target, directory and settings, then **確認した内容で起動** (Launch reviewed settings).
5. Use **ターミナルへ戻る** (Return to terminal) to enter instructions. Follow the official CLI's prompts if sign-in is required.

A running process and completed AI work are separate states. When a state is **未確認** (Unverified), inspect the terminal result, the displayed evidence and observation time before treating it as success or failure. Use **現在の実行を中断** (Interrupt current run) to interrupt, and check that termination is observed.

## 6. Inspect artifacts

In **成果物** (Artifacts), use **ファイルを選ぶ** (Choose file) or register a Git candidate. Use **成果物を再確認** (Refresh artifacts), select a registered file, and use **本文を読む** (Read content) or **差分を読む** (Read diff). Binary files do not display a text body. If a file disappears, do not treat its previous body as current content.

In a project folder with a top-level `.git` folder, **差分を読む** reads the whole folder, including untracked and ignored files and the Git objects. If that passes 1 MiB, or the folder contains a junction, symbolic link, hard-linked file or nested `.git`, the diff cannot be read even for a small file, and **成果物を再確認** shows the reason in place of the Git candidates. **本文を読む** is not affected. See [Troubleshooting](TROUBLESHOOTING.md#artifacts-or-layout-cannot-be-read).

Inspect the file content, diff and command results before adopting AI output.

## 7. Restore the layout

In **配置** (Layout), use **配置だけを復元** (Restore layout only). Restoring a layout does not automatically restart its previous shells or AI processes. Check the targets and explicitly start the runs you need.

## 8. Close a pane

When closing a running pane, read the target and interruption confirmation. Use **戻る** (Back) to continue working, or **中断して閉じる** (Interrupt and close) to finish. If the result is unverified, use **状態を読み直す** (Reread state) rather than assuming the pane has closed.

## 9. If the app does not open correctly

These states are not a successful desktop launch:

- a `localhost` connection error
- only a black PowerShell or Windows Terminal window
- a blank window, or an extremely small leftover window

See [Troubleshooting](TROUBLESHOOTING.md) for recovery steps.

## If you want the CLI path

For CLI-first, headless, or scripted operation, use the CLI package and instructions for your version. In v0.38.0, GUI, CLI and MCP operate on a common workspace. This differs from the older Windows Terminal workflow using `winsmux init` / `winsmux launch`.

The steps are separated in [Installation](installation.md#cli-package-install). Do not mix them into the desktop app first-run flow.

## Next steps

- Desktop installer, CLI path, updates, and uninstall: [Installation](installation.md)
- Startup errors, authentication, and model settings: [Troubleshooting](TROUBLESHOOTING.md)
- Authentication and data boundaries: [README](../README.md#authentication-and-data)
