# Troubleshooting

This guide covers the v0.38.0 workspace UI and common CLI/MCP. The older operator screen and `winsmux init` / `winsmux launch` use different entry points. Check your installed version and its matching distribution and guide first.

## Desktop app opens to a localhost connection error

Open the installed winsmux app from the Start menu. The CLI command `winsmux workspace connect` does not launch the desktop UI.

For a connection error, blank screen, or a black PowerShell, Windows Terminal, or WebView2 console window without the app:

Compare the installed version with its release assets. The [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest) may be a different version; do not substitute it without checking. An x64 installer is named `winsmux_..._x64-setup.exe`; select the actual asset for your version and CPU. Open the installed app from the Start menu or desktop shortcut. Before reinstalling, confirm normal exit and preserve the saved layout and project files; a refused close is not a completed exit.

1. Check the app version and install location. Starting a development web server is not a recovery procedure for the installed app.
2. If the UI responds, use **状態を読み直す** (Reread state) and **導入状況を確認** (Check installation).
3. To exit, inspect running panes, save required files, and use the normal close action. A refused or unverified close is not a confirmed exit.
4. Record the version, the action that triggered the problem, and the fixed error classification shown. Inspect screenshots for private paths, input and output before sharing them.

You can inspect process state without terminating anything:

```powershell
Get-Process winsmux-app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,StartTime
```

A list of processes with the same name does not establish which work they own. Deleting locks or saved layouts, or terminating every PowerShell process, is not a recovery procedure.

## Unverified project or pane state

Use **状態を読み直す** to recheck the target and run. A running process does not prove completed AI work. Inspect the work state, evidence and observation time together.

If the working directory changed, disappeared, or is inaccessible, inspect the current folder. A different folder with the same display name is not the original target. **一覧から外す（ファイルは保持）** removes a registration, not the files.

When an operation result is unverified, inspect the original target and result before repeating it. In CLI/MCP responses, inspect `accepted`, `result` and `error`. A missing response does not prove success or justify a safe retry.

## Japanese input and shortcuts

Click inside the terminal, type with the IME, convert with Space, and commit with Enter. Distinguish committing a composition from pressing Enter to execute a command.

If Ctrl+Shift+P/T/W conflicts with your work, uncheck **アプリのショートカットを使う**. When input admission or delivery is unverified, inspect the displayed information before sending duplicate input.

## Codex or Claude Code does not start

Use **導入状況を再確認** (Recheck installation) to refresh the detected official CLI and version. CLIs change over time. Detection alone does not verify authentication or support for a requested model or reasoning setting.

- If the executable is missing, check the install location of the official CLI you intend to use.
- If authentication is needed, follow that CLI's own instructions. Do not copy credentials from another CLI.
- If a setting is rejected, inspect the reason and the official CLI's supported settings. Do not assume another AI was selected automatically.
- For an approval requested by an official CLI, inspect its configuration and the requested action. This is separate from winsmux connection authorization. This guide does not prescribe disabling safety controls to reduce prompts.

Use **現在の実行を中断** (Interrupt current run) and check whether termination of the target is observed. Sending an interruption or pressing the button alone is not proof of completion.

## CLI or MCP connection is refused

Use **現在の接続情報をコピー** (Copy current connection information) in the GUI and explicitly pass the information for the current host. Do not reuse old connection information or grants after restarting the host.

Use **接続一覧を読み直す** (Refresh connections), select the connection, and inspect its requested projects and scopes. Metadata, output reading and control are separate permissions. Metadata permission alone does not permit reading terminal content.

Select the required scope and use **選択内容を許可** (Allow selection). Use **要求を拒否** (Deny request) for unwanted requests or **許可を失効** (Revoke permission) to stop an existing grant. Connection authorization does not sign in to an AI service.

## Artifacts or layout cannot be read

Refresh the artifact list and check the target before reading its content or diff. Do not use a disappeared file's previous body as current content. A binary body being hidden, or a limited display range, does not mean the complete content was inspected.

**配置だけを復元** restores the saved layout without automatically running previous processes. If save or restore fails, do not empty the saved file or manually modify its schema.

## Share diagnostics

Use **診断を確認** (Check diagnostics) in **診断** (Diagnostics) to display the five shareable fields, then **診断をコピー** (Copy diagnostics). Check the copied result before sharing it.

Do not attach raw terminal transcripts, CLI arguments or environment variables, authentication files, private connection information, or saved layouts to bug reports. If more detail is needed, prepare a generated reproduction with no secrets and the sanitized error classification.

## Older versions, updates and uninstall

Do not manually convert an older version's configuration into the v0.38.0 saved layout. Preserve ongoing work and configuration in the old version; select the folder and create a layout in the new UI. Retain the original distribution and configuration needed for recovery.

Choose update or uninstall actions for the actual installation method and version. npm package maintenance and desktop app maintenance are separate. See [Installation](installation.md) and the release information for your version.
