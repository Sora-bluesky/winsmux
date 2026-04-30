# Local-First UI Contract

Status: `TASK-414` design intake for `v0.24.15`

This contract records which local-first UI ideas winsmux will adopt from internal reference snapshots. It intentionally uses generic reference labels only. Public docs, release notes, task titles, and roadmap text must not publish the upstream repository names.

## Adopt

### Live Work Surface Tabs

winsmux will evolve the current `editor-surface` into a multi-mode work surface with three stable modes:

- `Preview`: show the selected preview target from existing preview target data.
- `Code`: show the selected `EditorTarget` and loaded editor file content.
- `Files`: show safe file candidates from existing `SourceChange` projections.

The conversation remains the primary work area. Terminal output stays in `terminal-drawer`; raw PTY output does not move into the work surface.

First implementation boundary:

- Reuse `previewTargets`, `EditorTarget`, and `SourceChange`.
- Keep the current TypeScript and CSS architecture.
- Do not copy external component code or assets.
- Add viewport coverage before treating the tab layout as release-ready.

### Safe Activity Cards

winsmux will use compact activity cards for long-running or stateful work instead of raw tool output.

Initial card kinds:

- file change
- test run
- review result
- preview opened
- snapshot captured

Cards must use existing projections or safe summaries. They must not show raw thinking text, private prompt bodies, private memory bodies, private local paths, secrets, or unfiltered tool output.

### Progress Envelope

winsmux will standardize a UI-facing progress envelope before adding new producers.

Fields:

- `stage`
- `message`
- `progress`
- `bytes_done`
- `bytes_total`
- `source_ref`
- `safe_to_show`

The first mapping should cover verification, review wait, and snapshot work because those already exist in winsmux projections.

## Defer

### Local Voice Composer

Voice input remains a prototype only. It may be added behind a feature flag after package size, browser support, WebGPU availability, and offline cache behavior are measured.

Constraints:

- user-triggered only
- local transcription only
- default off in release builds
- no cloud transcription fallback

### Runtime or Model Provisioning

winsmux will not add platform-specific model runtime provisioning as part of `v0.24.15`. Readiness UI may show operational state, but it must not turn winsmux into a local model chat app.

## Reject

winsmux will not adopt these patterns:

- raw thinking text display
- XML tool calls as a public winsmux contract
- generated file writes to arbitrary filesystem paths
- direct reuse of external desktop shell code
- direct reuse of external UI assets without `THIRD_PARTY_NOTICES.md`
- private prompt or memory bodies in any visible UI surface

## Follow-Up Split

No more than three follow-up tasks should be created from this intake:

1. Live work surface tabs for `Preview`, `Code`, and `Files`.
2. Progress envelope cards for verification, review wait, and snapshot work.
3. Optional local voice composer prototype behind a feature flag.
