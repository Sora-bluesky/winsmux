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

## Release gate

- the staged package must pass the Windows verify job
- the publish workflow stays tag-driven
- the publish job uses the staged package from `scripts/stage-npm-release.mjs`
- repository publishing stays closed until that gate is intentionally opened

This package stays gated in the repository until the installer contract,
release verification, and public docs all match that surface.
