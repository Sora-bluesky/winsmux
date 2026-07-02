# Run1 Debug Sub-Run Transient (2026-07-02)

The bounded readiness matrix (debug+release, warm on, fresh registry, MaxRuns 2,
30s timeout) was executed 4 times on 2026-07-02. Run 1 reported `failed=1` for
the debug sub-run in its summary, while the detail JSON for the same label
shows `passed=true`. Runs 2-4 fully passed. Zero stale winsmux server
processes were observed after every run. No hang or timeout approach was
required at any point.

Classification: non-reproducing first-touch warm-seed/registry contention,
contained fail-closed by the bounded harness; not a systematic defect.

Morning follow-ups before formal bench:

1. Re-confirm release binary freshness vs `winsmux-app/dist`
   (`Assert-DesktopExecutableFreshForDist` hard-fails if stale; rebuild if
   dist advanced).
2. Run `start-cli-bakeoff-desktop.ps1 -Json` live once with the user present
   to capture `operatorSurface` / `operatorControlPipe` / `windowAfterMove`
   as `ui_attached` evidence.
