# Planning Backlog

`backlog.yaml` is maintained outside this repository.

Default resolution order:

- `WINSMUX_BACKLOG_PATH`
- `WINSMUX_PLANNING_ROOT\backlog.yaml`
- the user-profile-relative default returned by `winsmux-core/scripts/planning-paths.ps1`

Override with:

- `WINSMUX_PLANNING_ROOT`
- `WINSMUX_BACKLOG_PATH`

Use `winsmux-core/scripts/sync-roadmap.ps1` to regenerate the external roadmap from the external backlog.
