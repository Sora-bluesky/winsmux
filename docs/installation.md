# Installation

This guide covers the v0.38.0 Windows workspace. Use the guide shipped with your installed version. Older releases use different operator/worker screens and startup commands.

## Requirements

- A Windows build and CPU architecture supported by the selected release.
- PowerShell 7 for the pane shell.
- Microsoft Edge WebView2 Runtime for the desktop UI.
- The official Codex or Claude Code CLI for the corresponding AI launch control.
- Node.js and npm only for the npm installer entry point.

A packaged app does not require Rust or a C++ compiler. Windows Terminal belongs to the older managed-terminal workflow; it is not the renderer for the v0.38.0 desktop terminal.

### Source build prerequisites on Windows

Source builds need Rust, the desktop frontend's Node.js dependencies, and the MSVC linker and Windows SDK for the requested target. See [Visual Studio C++ build tools](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022).

Use the repository's Windows distribution build and companion preparation scripts. A successful x64 build does not establish an ARM64 build or runtime test. Do not mix debug companions, other versions or other targets into a package.

## Windows binary component terms

Before downloading, installing or using the Windows GUI, CLI or MCP binaries, read the [Microsoft component supplement](../distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.txt). It is provided by the winsmux distributor for the embedded Microsoft Visual C++ runtime object code; it is not a Microsoft-issued agreement and does not change the Apache-2.0 license of winsmux source or other components’ licenses. The original Microsoft developer terms are retained separately in the bundled license catalog.

Installing or using the Microsoft component after the opportunity to review these conditions signifies agreement. If you do not agree, do not install or use that component. Distributors must pass on the conditions and require protective terms for their distributors and external end users.

Read the same terms before silent/passive MSI or NSIS installation, PowerShell/npm installation, or direct binary use. Silent/passive installation does not display an interactive license page.

The Japanese installer shows the [Japanese reference translation](../distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.ja.txt) of the supplement, followed by the English original. Where they differ, the English original prevails.

## Quick install

1. Choose the intended version from [Releases](https://github.com/Sora-bluesky/winsmux/releases).
2. Select its Windows installer for your architecture. Check the actual release assets rather than assuming every architecture or format is available.
3. Verify the download using that release's verification information, and check its signature as described in [Check the installer signature](#check-the-installer-signature). A checksum match does not replace the signature check.
4. Run the installer. Its pages are described in [Installer pages](#installer-pages). Open winsmux from the Start menu, or let the last page start it.
5. Use **プロジェクトを開く** (Open project), check the working directory, and create a pane.

See [Quickstart](quickstart.md) for AI launch, artifacts, layout restoration and closing panes.

## Desktop app installer

Use the setup asset for a normal desktop installation. Use an MSI only when the selected release provides it and your deployment method requires it. The release information defines the available formats and signing status.

The desktop package includes its native workspace CLI and MCP companion: `winsmux-app.exe`, `winsmux.exe` and `winsmux-workspace-mcp.exe`. Use the three executables from the same distribution. Do not replace one companion with a different version.

Check Windows Settings > Apps > Installed apps and the installation location to identify the installed version. A blank screen, connection error or console without the workspace is not successful startup. See [Troubleshooting](TROUBLESHOOTING.md).

### Check the installer signature

The v0.38.0 installer is signed with a self-signed certificate whose subject is `CN=winsmux release signing`. Windows does not trust that certificate, so `Get-AuthenticodeSignature` reports the status `UnknownError` on a normal Windows installation. Check the file you downloaded, replacing `...` with the version in its file name:

```powershell
Get-FileHash .\winsmux_..._x64-setup.exe -Algorithm SHA256
$signature = Get-AuthenticodeSignature .\winsmux_..._x64-setup.exe
$signature.Status
$signature.SignerCertificate.Subject
$signature.SignerCertificate.Thumbprint
```

The hash must match the release's checksum, the subject must be `CN=winsmux release signing`, and the thumbprint must be `2D4D1904E09B510BF9CD8994A2CD49C36BB0C4BA`. If the status is `NotSigned` or `HashMismatch`, or the subject or thumbprint differs, the file is not the one the release describes. Do not run it.

After installation, Installed apps shows the publisher as `github`. GitHub did not sign or publish winsmux, and that name says nothing about who built the file. Use the signer check above to identify the file.

### Installer pages

The installer shows these pages: installer language, welcome, license agreement, install location, installation, and a finish page.

- You must accept the license agreement to continue.
- The install location defaults to `%LOCALAPPDATA%\winsmux`. The same page has a desktop shortcut option, selected by default. A Start menu shortcut is always created. A new shortcut that the installer creates starts `winsmux-app.exe` with the install folder as its working folder (**Start in** in the shortcut's properties). When you install again or update, a shortcut that this installer created earlier and recorded in its install record (`.winsmux-desktop\installed.json`) stays as it is, including its Start in folder, if it is still on the Desktop or Start menu. Do not edit that Start in folder by hand. The shortcut then no longer matches the record, and the next update or uninstall stops. To give such a shortcut the install folder as its Start in folder, delete the shortcut and run the installer again.
- The finish page has an option to run winsmux, selected by default. Leave it selected to start winsmux when you close the installer.

The installer also adds **Open with winsmux** to the right-click menu of folders and folder backgrounds in File Explorer. It does not add winsmux to PATH.

winsmux keeps its own data, such as saved layouts, in `%LOCALAPPDATA%\winsmux\workspace\v1`. That location stays the same when you choose another install folder. With the default install folder it is inside the install folder, and the installer leaves it as it is. The install folder also has a `.winsmux-desktop` folder, where the installer keeps its install record, its recovery data and the shortcuts it set aside.

### Existing winsmux shortcuts

If the Desktop or Start menu already has a `winsmux.lnk` that this installer did not create, for example one that opens an older version, the installer moves it to `.winsmux-desktop\preserved` in the install folder without changing the file and puts the new shortcut in its place. From then on, that shortcut opens v0.38.0. Uninstalling v0.38.0 puts the set-aside shortcuts back. If the uninstaller reports that the shortcuts are still set aside, they remain in that folder.

### If the installer stops

Read the installer's message before doing anything else. The uninstaller shows the same kinds of messages. The table lists every message and what to do before you run the installer or uninstaller again.

| The message says | What to do |
|---|---|
| WebView2 could not be installed, and the app cannot run without it. | The installer stopped before it installed winsmux. It shows this message when the PC does not have the WebView2 Runtime and the installer cannot download or install it, for example because the PC is offline. Connect to the internet and run the installer again. If it stops again, install Microsoft Edge WebView2 Runtime first, then run the installer again. |
| winsmux is still running or its folder is locked. | Close winsmux and any window open in that folder. |
| A folder has a file with a winsmux name that this installer or uninstaller did not create and cannot set aside. | Move that file away. The installer also lets you choose another install folder. |
| It could not confirm the files and shortcuts that winsmux created or set aside. | Put back any winsmux file that was moved or edited, or move away anything winsmux did not create. |
| The Desktop or Start menu folder that holds the winsmux shortcut has moved since winsmux was installed. | Move that folder back to where it was. OneDrive can move it when it backs up the folder. |
| The record of the earlier winsmux install is incomplete. | In the installer, uninstall the earlier winsmux first or choose another folder. The uninstaller gives no next step, so record the details as in the last row. |
| The winsmux registry entries do not match. | In the installer, uninstall the earlier winsmux first. The uninstaller gives no next step, so record the details as in the last row. |
| An earlier install or uninstall did not finish, or could not be finished, and its recovery data is kept. | Run the program that showed the message again, as described after the table. |
| Installation or uninstallation could not be confirmed. | The message gives no next step. Select **Show details** and record what it shows, checking it for private paths before you share it. Leave the install folder as it is. |

A message can end with a note about the Desktop and Start menu shortcuts. When it says that the set-aside shortcuts are preserved in the winsmux folder, they are in `.winsmux-desktop\preserved` in the install folder. When it says that winsmux could not confirm that the shortcuts were put back, check the Desktop and the Start menu.

When the message says that recovery data is kept, run the program that showed it again, either the installer or the uninstaller. If you run the installer, choose the same install folder as the install or uninstall that stopped. The install location page does not always show that folder. For example, after a first install into a folder other than the default stops, the page can show the default `%LOCALAPPDATA%\winsmux`. If you continue with another folder, the installer installs winsmux there and leaves the recovery data in the folder where it stopped. The program first reads the recovery data in `.winsmux-desktop` in the install folder and deals with the install or uninstall that stopped, as recorded there. If that operation had already reached its final state, it completes it. Otherwise it puts back what that operation changed. Then it does the operation you started it for. The installer installs winsmux, and the uninstaller removes it. The message calls this resuming. After an uninstall that stopped, running the installer therefore leaves winsmux installed. To remove winsmux, run the uninstaller again. Do not delete `.winsmux-desktop`.

## CLI package install

The npm package launches an installer pinned to the release tag staged into that package. The repository's development package is not a published release tarball.

Select a published package version matching the desired release:

```powershell
npm install -g winsmux@<published-version>
winsmux install --profile core
```

Replace the placeholder before running the command. The npm entry point supports install, update, uninstall, version and help. It is not the native workspace request client. Check which executable your shell resolves before using workspace operations.

The desktop installer does not add winsmux to PATH. Its CLI is `winsmux.exe` in the install folder, by default `%LOCALAPPDATA%\winsmux\winsmux.exe`. The script and npm installers add the folder that holds their own `winsmux.exe` to the user PATH. They also add a line to your PowerShell profile that puts `%USERPROFILE%\.winsmux\bin` at the front of PATH. That folder holds `winsmux.cmd`, so in a PowerShell session that loads your profile, `winsmux` runs that `winsmux.cmd` instead of any other winsmux on PATH. `Get-Command winsmux -All` lists the ones your shell can find. To use the desktop's CLI, run it by its full path.

The native runtime's public entry points are:

```powershell
winsmux.exe workspace host
winsmux.exe workspace connect
```

These are alternative entry points. `host` starts a separate host; it does not connect to the desktop's existing workspace. To operate the desktop host, copy its current public connection information in the GUI and provide it to `connect`. The first input line is discovery JSON, followed by one common request JSON per line. Inspect each response's `accepted`, `result` and `error`.

The MCP companion accepts `--discovery-json` with the current public discovery JSON and uses standard input/output. CLI and MCP require explicit project and scope authorization in the GUI. Do not pass private owner capabilities as public discovery information. Obtain new information and grants after restarting the host.

## Installer profiles

The script/npm installer accepts `core`, `orchestra`, `security` and `full`. Profiles select installed support components, not AI permissions or desktop pane roles. `core` selects the native runtime and base support. Other profiles include older orchestration, terminal or vault support; their presence does not make the old startup commands the v0.38.0 GUI flow.

## Older versions and migration

Retain the original distribution and configuration before transition. Save ongoing work and identify the old version's running processes. Do not replace an executable while it is in use.

Select the existing project folder in v0.38.0 and create the desired pane layout. Do not manually convert old configuration into the saved-layout schema. Removing a registration keeps the project files; restoring a layout does not automatically execute previous shells or agents.

To return to the old version, use its retained executable, configuration and guide. Do not overwrite the old configuration with the new layout file.

The desktop installer replaces a Desktop or Start menu `winsmux.lnk` that opened the old version (see [Existing winsmux shortcuts](#existing-winsmux-shortcuts)). To start the old version after that, run its executable directly.

## Update

For the desktop app, obtain and verify the newer installer using that release's instructions. Save work and normally close the workspace before replacing the app. If closing is refused or unverified, inspect the run state first.

For npm, select the matching published package and its update action. Desktop maintenance and maintenance of another CLI installation are separate. The script installer retains its recorded profile when no new profile is specified.

After updating, check the app and companion versions, project selection, official CLI detection and fresh external connection information. If installation fails, preserve the error and the retained old distribution, and follow [If the installer stops](#if-the-installer-stops). Do not delete project data or authentication storage to make an update succeed.

## Uninstall

Use Windows Settings or the desktop package's deployment mechanism. For script/npm installations, use that installation's uninstall action. Check the target when multiple installations exist.

Keep repositories, saved work and official CLI authentication storage outside manual cleanup. Do not recursively delete a profile directory as an uninstall workaround. Do not delete the desktop install folder by hand either. Its `.winsmux-desktop` folder holds the install record and recovery data, and with the default install folder, winsmux's own data in `%LOCALAPPDATA%\winsmux\workspace\v1` is inside it too.

## Verify

Compare the version, architecture and package identity with the selected release. Open the app, select a project, create a pane, check the working directory and official CLI detection. An installation command's success alone does not prove this workflow works.

See [Troubleshooting](TROUBLESHOOTING.md) for state rereads, permissions, shareable diagnostics and recovery.
