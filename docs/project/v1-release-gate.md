# v1.0.0 Release Gate

This project note records the `v1.0.0` release gate decisions that were tracked
by `TASK-220`, `TASK-491`, and `TASK-498`.

## Packaging decision

The Windows desktop app is the primary `v1.0.0` distribution path.

Required public artifacts:

- `winsmux_<version>_x64-setup.exe` as the normal installer
- `winsmux_<version>_x64_en-US.msi` for MSI deployment tooling
- `SHA256SUMS-desktop` for checksum verification
- signed updater metadata, including `latest.json` and at least one `.sig`
  file next to the desktop release assets
- npm package and CLI installer path for CLI-first users
- release notes that state the signing posture and update path
- English and Japanese installer UI for the setup executable, with the language
  selector enabled

The default release does not publish a portable desktop app artifact. If a
portable fallback is needed, users can use the release `winsmux-x64.exe` core
binary or the npm package.

## Signing and update posture

`TASK-720` is the signed desktop updater release assets gate. Starting with
`v0.36.23`, the release workflow must require signing secrets
`WINDOWS_SIGNING_CERTIFICATE_BASE64`, `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`,
`TAURI_SIGNING_PRIVATE_KEY`, and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` before it
builds desktop bundles for GitHub Release upload. The normal setup executable
and MSI must be Authenticode signed before updater signatures and release
metadata are finalized. The updater metadata must include `latest.json` plus
`.sig` files generated for the final release assets. An unsigned installer,
missing updater signature, or missing `latest.json` must not be published as a
release artifact.

Each release note must still state the signing posture. Users should verify
installer downloads against `SHA256SUMS-desktop` when Windows shows publisher or
SmartScreen warnings.

The desktop update path is installing the newer desktop release over the
existing installation. This keeps project repositories, agent CLI
authentication, and external provider credentials outside the app uninstaller.

Automatic in-app update detection is delivered in the `v0.36.23` desktop app
and tracked by issue `#1082`. The release gate verifies the update check,
download prompt, installer handoff, progress state, checksum verification when
release metadata provides a digest, and restart guidance. Published builds
before `v0.36.23` must still document the installer-over-existing-install
update path.

The visible desktop UX must match the Codex-style update affordance: a compact
persistent status/action in the main chrome that distinguishes download progress
from the final update action. The gate must verify at least `downloading`,
`update available`, install handoff, and post-install restart guidance states
before `v0.36.23` release publication.

The expected desktop update flow is:

- When a newer release is detected, the persistent update action changes to an
  update-ready state such as `Update`.
- Clicking the update action opens a confirmation dialog that explains the app
  will close during installation and local active sessions may be interrupted.
- Clicking `Update` inside the dialog starts installation and changes the dialog
  to an installing state with progress text and progress indication.
- Clicking `Cancel` or outside the dialog closes the dialog without starting the
  installer.
- After installation completes, the app restarts or shows an explicit restart
  action. Silent background replacement without user-visible state is not
  accepted.

## Public distribution boundary

The `v1.0.0` release gate verifies the public binary distribution boundary
described in [Public Distribution Boundary](../source-access.md). Public users
receive installers, packages, checksums, release notes, and public docs after
the release gate is complete. Public repository materials must not describe
non-public agreements or internal operational planning.

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
- Public docs describe the `v1.0.0` public binary distribution boundary.
- Removed legacy binary aliases are documented in the
  [compatibility guide](../../core/docs/compatibility.md), and their remaining
  references have been retired or formally accepted by the completed
  compatibility gates.
- The manual checklist gate is complete and machine-readable.
- Desktop shutdown cleanup is covered by a focused Rust test and by release
  notes text.
- Post-release smoke checks verify that published installers, checksums, npm
  package metadata, and public docs are reachable from the GitHub Release.
- Public install docs must link to the GitHub `releases/latest` route for the
  normal path and use the version-neutral installer example
  `winsmux_..._x64-setup.exe`. Release publication must fail if public install
  docs contain a fixed release asset name such as
  `winsmux_0.x.y_x64-setup.exe`.
- Quickstart must stay desktop-app first. It must not include npm installation,
  `winsmux init`, or `winsmux launch` commands. CLI-first setup belongs in the
  Installation CLI section and in the npm package README.
- Each release must verify README, Quickstart, Installation, Troubleshooting,
  and `packages/winsmux/README.md` together so the latest-release link,
  version-neutral installer name, desktop-first path, and CLI-only npm boundary
  stay synchronized.
- Desktop installer smoke checks verify that Windows Search finds the app by
  name, Windows Installed apps shows the installed app entry, and the installed
  app opens the desktop control surface without a localhost error or extra
  console window. A version number is not required in Windows Search; version
  evidence belongs in the installer asset, app metadata, or Installed apps
  details.
- Desktop installer evidence must come from the installed Windows app. Repo-local
  `target\debug`, repo-local `target\release`, and `.local\bin` wrapper paths
  are developer evidence only and must not be accepted as desktop installer
  registration or normal-launch proof.
- Issue `#751` can be closed because the installer decision is recorded.
- Issue `#967` can be closed after the cleanup implementation is merged.
