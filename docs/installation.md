# Installation

`winsmux` is distributed for Windows in two ways. Use the desktop app installer
for the normal graphical operator/worker experience. Use the npm package for
CLI-first, scripted, or headless setups.

- recommended: a desktop app installer from GitHub Releases
- separate CLI path: a Windows-first npm package for CLI-first setups and scripted installs

| Use case | Install path | Startup path |
| --- | --- | --- |
| Normal graphical operator/worker use | Download and run `winsmux_..._x64-setup.exe` from the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest) | Open the installed `winsmux` desktop app and choose the project folder |
| CLI-first or headless orchestration | `npm install -g winsmux`, then `winsmux install --profile full` | Run `winsmux init` and `winsmux launch` from the project directory |
| External automation against the desktop operator | Install and open the desktop app first | Use the local control pipe after the desktop operator is visible |

`winsmux launch` starts the managed Windows Terminal workspace. It does not open
the desktop app.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js and `npm` when using the npm install path

Rust is only required when building the runtime from source.

For Colab-backed model workers, also prepare a Colab notebook or an
adapter-managed equivalent connected to `H100` or `A100`. The Windows PC does
not need a local LLM runtime for that path.

## Quick install

Desktop app:

1. Open the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest).
2. Download the `winsmux_..._x64-setup.exe` asset.
3. Verify `SHA256SUMS-desktop` from the same release when Windows shows a publisher or SmartScreen warning.
4. Run the installer, open the installed winsmux app, and choose the project folder after launch.

Verify the desktop install as a Windows app install:

- Windows Search finds the app by name as `winsmux`.
- Windows Settings > Apps > Installed apps lists `winsmux` with the publisher,
  install date, and size fields that Windows provides.
- Windows Search does not need to show a version number. Check the version from
  the app, the installer file, or Windows Installed apps details when a version
  value is needed.
- Opening the installed app shows the winsmux desktop control surface, not a
  localhost connection error or a separate console window.

CLI package:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

Then open the project you want agents to work in and start the CLI-managed
workspace from that project directory. This does not open the desktop app:

```powershell
cd <project>
winsmux init
winsmux launch
```

## Desktop app installer

For the recommended desktop app path, download the Windows installer from the [latest release](https://github.com/Sora-bluesky/winsmux/releases/latest). Use the [Releases page](https://github.com/Sora-bluesky/winsmux/releases) when you need a specific older version:

- `winsmux_..._x64-setup.exe` for the standard guided installer
- `winsmux_..._x64_en-US.msi` for MSI-based deployment
- `SHA256SUMS-desktop` for checksum verification

Use the setup executable for a normal single-user install. Use the MSI when your deployment tooling expects MSI packages.

The setup executable includes English and Japanese installer UI. It shows a
language selector before the installer or uninstaller window opens.

If Windows shows a publisher or SmartScreen warning, verify the downloaded file against `SHA256SUMS-desktop` from the same release before running it. Release notes state the signing posture for each release.

The desktop packaging policy, effective for the `v1.0.0` release line, is:

- primary artifact: `winsmux_..._x64-setup.exe`
- deployment artifact: `winsmux_..._x64_en-US.msi`
- verification artifact: `SHA256SUMS-desktop`
- setup executable languages: English and Japanese, with the language selector enabled
- signing posture: documented per release until a stable signing certificate is available
- update story: install the newer desktop release over the existing install
- portable fallback: use the release `winsmux-x64.exe` or `winsmux-arm64.exe` core binary, or use the npm package; no portable desktop app artifact is published by default

The `v1.0.0` public distribution is installer-first. Full implementation source
is no longer part of the public release surface. See [Public Distribution
Boundary](source-access.md) for the public distribution and redistribution
boundary.

## CLI package install

```powershell
npm install -g winsmux
winsmux install --profile full
```

The npm command delegates to the bundled installer and pins the installer to the same release tag as the npm package.
The repository `packages/winsmux` directory is not published directly. Release
automation stages the npm tarball with `scripts/stage-npm-release.mjs`, which
adds the release-pinned `install.ps1` before publication.

After the package install finishes, move to the project directory and launch the
managed workspace:

```powershell
cd <project>
winsmux init
winsmux launch
```

`winsmux launch` is the public CLI startup path. It runs the first-run checks
and starts the managed Windows Terminal workspace. The desktop app installer is
separate: install the desktop app from GitHub Releases, open it, and choose the
same project folder there when you want the graphical control surface.

## Installer profiles

| Profile | Installs | Use it when |
| ------- | -------- | ----------- |
| `core` | runtime binary, wrapper scripts, `PATH` setup, base config | you only need the Windows-native terminal runtime |
| `orchestra` | `core` plus orchestration scripts and Windows Terminal profile | you run managed pane agents under one operator |
| `security` | `core` plus vault and audit-oriented scripts | you need credential handling without the full orchestration surface |
| `full` | `core`, `orchestra`, and `security` | you want the standard winsmux setup |

## Update

```powershell
winsmux update
winsmux update --profile orchestra
```

When no profile is supplied, `winsmux update` keeps the previously recorded profile. When the profile changes, scripts outside the selected profile are removed from the installed support directory.

For the desktop app, builds starting with `v0.36.23` check GitHub Releases for
a newer Windows setup installer. When an update is available, the desktop app
shows a compact update action, opens a confirmation dialog, downloads the
installer with progress, verifies the checksum when release metadata provides
one, starts the installer, and exits so the installer can replace the running
app. Published builds before `v0.36.23` are updated by running the newer
installer over the existing install.

This update flow does not remove project repositories, agent CLIs, or their
authentication storage.

## Uninstall

```powershell
winsmux uninstall
```

Uninstall removes the installed winsmux support files. It does not remove your agent CLIs or their own authentication storage.

For the desktop app installer, uninstall `winsmux` from Windows Settings or your MSI deployment tool. This removes the desktop app. It does not remove project repositories, agent CLIs, or their authentication storage.

## Verify

```powershell
winsmux version
winsmux doctor
```

Use `winsmux doctor` after install or update to confirm PowerShell startup, repository configuration, process pressure, and workspace prerequisites.

For Colab-backed worker slots, also run:

```powershell
winsmux workers doctor
```

The Colab doctor path reports missing adapter commands, missing authentication,
and `H100` / `A100` runtime mismatches as worker state instead of silently
falling back to a local model runtime.
