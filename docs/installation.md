# Installation

`winsmux` is distributed as a Windows-first npm package.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js and `npm`

Rust is only required when building the runtime from source.

## Install

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

## Uninstall

```powershell
winsmux uninstall
```

Uninstall removes the installed winsmux support files. It does not remove your agent CLIs or their own authentication storage.

## Verify

```powershell
winsmux version
winsmux doctor
```

Use `winsmux doctor` after install or update to confirm PowerShell startup, repository configuration, process pressure, and workspace prerequisites.
