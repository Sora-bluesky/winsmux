# winsmux npm package

This directory is the future public npm install surface for `winsmux`.

The npm package name `winsmux` is already reserved.
Repository publishing stays gated until the public installer contract is ready.

Until that contract lands, use the documented install flows in the repository root
README instead of publishing this package from repository tags.

When the public installer contract is ready, the `winsmux` npm command will proxy
to the bundled Windows installer flow and expose:

- `winsmux install`
- `winsmux update`
- `winsmux uninstall`
- `winsmux version`
- `winsmux help`
