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

## Quick install

1. Choose the intended version from [Releases](https://github.com/Sora-bluesky/winsmux/releases).
2. Select its Windows installer for your architecture. Check the actual release assets rather than assuming every architecture or format is available.
3. Verify the download using that release's verification information. Check the signing information and publisher as well; a checksum match does not replace a signature or publisher check.
4. Run the installer and open winsmux from the Start menu.
5. Use **プロジェクトを開く** (Open project), check the working directory, and create a pane.

See [Quickstart](quickstart.md) for AI launch, artifacts, layout restoration and closing panes.

## Desktop app installer

Use the setup asset for a normal desktop installation. Use an MSI only when the selected release provides it and your deployment method requires it. The release information defines the available formats and signing status.

The desktop package includes its native workspace CLI and MCP companion. Use the three executables from the same distribution. Do not replace one companion with a different version.

Check Windows Settings > Apps > Installed apps and the installation location to identify the installed version. A blank screen, connection error or console without the workspace is not successful startup. See [Troubleshooting](TROUBLESHOOTING.md).

## CLI package install

The npm package launches an installer pinned to the release tag staged into that package. The repository's development package is not a published release tarball.

Select a published package version matching the desired release:

```powershell
npm install -g winsmux@<published-version>
winsmux install --profile core
```

Replace the placeholder before running the command. The npm entry point supports install, update, uninstall, version and help. It is not the native workspace request client. Check which executable your shell resolves before using workspace operations.

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

## Update

For the desktop app, obtain and verify the newer installer using that release's instructions. Save work and normally close the workspace before replacing the app. If closing is refused or unverified, inspect the run state first.

For npm, select the matching published package and its update action. Desktop maintenance and maintenance of another CLI installation are separate. The script installer retains its recorded profile when no new profile is specified.

After updating, check the app and companion versions, project selection, official CLI detection and fresh external connection information. If installation fails, preserve the error and the retained old distribution. Do not delete project data or authentication storage to make an update succeed.

## Uninstall

Use Windows Settings or the desktop package's deployment mechanism. For script/npm installations, use that installation's uninstall action. Check the target when multiple installations exist.

Keep repositories, saved work and official CLI authentication storage outside manual cleanup. Do not recursively delete a profile directory as an uninstall workaround.

## Verify

Compare the version, architecture and package identity with the selected release. Open the app, select a project, create a pane, check the working directory and official CLI detection. An installation command's success alone does not prove this workflow works.

See [Troubleshooting](TROUBLESHOOTING.md) for state rereads, permissions, shareable diagnostics and recovery.
