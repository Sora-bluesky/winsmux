# v1.0.0 Release Gate

This project note records the `v1.0.0` release gate decisions that were tracked
by `TASK-220`, `TASK-491`, and `TASK-498`.

## Packaging decision

The Windows desktop app is the primary `v1.0.0` distribution path.

Required public artifacts:

- `winsmux_<version>_x64-setup.exe` as the normal installer
- `winsmux_<version>_x64_en-US.msi` for MSI deployment tooling
- `SHA256SUMS-desktop` for checksum verification
- npm package and CLI installer path for CLI-first users
- release notes that state the signing posture and update path
- English and Japanese installer UI for the setup executable, with the language
  selector enabled

The default release does not publish a portable desktop app artifact. If a
portable fallback is needed, users can use the release `winsmux-x64.exe` core
binary or the npm package.

## Signing and update posture

Until a stable code-signing certificate is available, every release note must
state the signing posture. Users should verify installer downloads against
`SHA256SUMS-desktop` when Windows shows publisher or SmartScreen warnings.

The desktop update path is installing the newer desktop release over the
existing installation. This keeps project repositories, agent CLI
authentication, and external provider credentials outside the app uninstaller.

## Public distribution boundary

`v1.0.0` starts the closed-source public distribution model described in
[Public Distribution Boundary](../source-access.md). Public users receive
installers, packages, checksums, release notes, and public docs. Public
repository materials must not describe private source-sharing, review, or
business arrangements.

## Shutdown cleanup gate

The desktop app must not leave this session's worker-pane child processes
running after the app exits. The Tauri shutdown path now requests summary stream
shutdown, stops native voice capture when active, drains all active PTY panes,
kills their children, and waits briefly for those children to exit. Existing
`pty.close` remains available for explicit per-pane cleanup.

The `v1.0.0` release notes must mention that desktop shutdown cleans up
worker-pane child processes.

## Final gate checklist

- Public install docs describe the setup executable, MSI artifact, checksum
  file, installer UI languages, signing posture, update path, and portable
  fallback policy.
- Public docs describe the `v1.0.0` public distribution boundary.
- Legacy `psmux` compatibility has already been retired or formally accepted by
  the completed compatibility gates.
- The manual checklist gate is complete and machine-readable.
- Desktop shutdown cleanup is covered by a focused Rust test and by release
  notes text.
- Issue `#751` can be closed because the installer decision is recorded.
- Issue `#967` can be closed after the cleanup implementation is merged.
