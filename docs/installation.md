# Installation

`winsmux` is distributed for Windows in two ways:

- a desktop app installer from GitHub Releases
- a Windows-first npm package for CLI-first setups and scripted installs

## Requirements

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js and `npm` when using the npm install path

The published npm wrapper supports Node.js 18 or newer. Source checkout
validation and desktop app builds use Node.js 24, matching CI. Rust is only
required when building the runtime from source.

For Colab-backed model workers, also prepare a Colab notebook or an
adapter-managed equivalent connected to `H100` or `A100`. The Windows PC does
not need a local LLM runtime for that path.

## Quick install

Desktop app:

1. Download `winsmux_<version>_x64-setup.exe` from the matching GitHub Release.
2. Verify `SHA256SUMS-desktop` when Windows shows a publisher or SmartScreen warning.
3. Run the installer and choose the project folder after launch.

CLI package:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

## Desktop app installer

For the desktop app, download the Windows installer from the matching GitHub Release:

- `winsmux_<version>_x64-setup.exe` for the standard guided installer
- `winsmux_<version>_x64_en-US.msi` for MSI-based deployment
- `SHA256SUMS-desktop` for checksum verification

Use the setup executable for a normal single-user install. Use the MSI when your deployment tooling expects MSI packages.

The setup executable includes English and Japanese installer UI. It shows a
language selector before the installer or uninstaller window opens.

If Windows shows a publisher or SmartScreen warning, verify the downloaded file against `SHA256SUMS-desktop` from the same release before running it. Release notes state the signing posture for each release.

The desktop packaging policy, effective for the `v1.0.0` release line, is:

- primary artifact: `winsmux_<version>_x64-setup.exe`
- deployment artifact: `winsmux_<version>_x64_en-US.msi`
- verification artifact: `SHA256SUMS-desktop`
- setup executable languages: English and Japanese, with the language selector enabled
- signing posture: documented per release until a stable signing certificate is available
- update story: install the newer desktop release over the existing install
- portable fallback: use the release `winsmux-x64.exe` core binary or the npm package; no portable desktop app artifact is published by default

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

For the desktop app, download the newer release installer and run it over the existing install. This does not remove project repositories, agent CLIs, or their authentication storage.

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
