# winsmux npm package

This directory is the future public npm install surface for `winsmux`.

The npm package name `winsmux` is already reserved.
Repository publishing stays gated until the public installer contract is ready.

Until that contract lands, use the documented install flows in the repository root
README instead of publishing this package from repository tags.

When the public installer contract is ready, the `winsmux` npm command will proxy
to the bundled Windows installer flow.

## Planned public contract

- Windows only
- future public install command: `npm install -g winsmux`
- `winsmux install`
- `winsmux update`
- `winsmux uninstall`
- `winsmux version`
- `winsmux help`
- the npm package version will pin `install.ps1` to the same GitHub release tag

## Installer profiles

The public package will keep one package name and expose profile selection through
the installer command instead of publishing separate package names.

| Profile | Shape | Primary use |
| ------- | ------- | ------- |
| `core` | runtime binary, wrapper scripts, `PATH` setup, and base config | users who only need the Windows-native tmux-compatible runtime |
| `orchestra` | `core` plus orchestration scripts and the Windows Terminal profile | users who need managed pane agents under one operator |
| `security` | `core` plus vault, redaction, and audit-oriented scripts | users who need credential handling and evidence checks without the full orchestration surface |
| `full` | `core`, `orchestra`, and `security` contents | default public install profile |

The planned npm form is:

```powershell
winsmux install --profile full
winsmux update --profile orchestra
```

`install.ps1` accepts the same profile names through `-Profile`. The package
entrypoint forwards `--profile` to that script as `-Profile`.

Updates keep the previously recorded profile when no new profile is supplied.
Each install or update records the selected shape in:

- `~\.winsmux\install-profile`
- `~\.winsmux\install-profile.json`

## Release gate

- the staged package must pass the Windows verify job
- the publish workflow stays tag-driven
- the publish job uses the staged package from `scripts/stage-npm-release.mjs`
- repository publishing stays closed until that gate is intentionally opened

This package stays gated in the repository until the installer contract,
release verification, and public docs all match that surface.
