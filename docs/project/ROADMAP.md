# Roadmap

> Auto-generated from `tasks/backlog.yaml` — do not edit manually.
> Last sync: 2026-04-02 02:00 (+09:00)

## Version Summary

| Version | Tasks | Progress |
|---------|-------|----------|
| v0.9.6 | 12 | [=======-------------] 33% (4/12) |
| v0.9.7 | 4 | [--------------------] 0% (0/4) |
| v0.10.0 | 2 | [--------------------] 0% (0/2) |

## Work Breakdown

### v0.9.6

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-017 | Implement Orchestra builder isolation (worktree + diff gate) | P0 | winsmux | backlog |
| [ ] | TASK-001 | Fix resize-pane -x/-y routing to ResizePaneAbsolute | P1 | sora-psmux | backlog |
| [ ] | TASK-002 | Separate split-window -l (cells) from -p (percent) | P1 | sora-psmux | backlog |
| [x] | TASK-007 | Sync VERSION and install.ps1 to v0.9.5 | P1 | winsmux | done |
| [x] | TASK-008 | Add orchestra-layout skill and dispatch scripts | P1 | winsmux | done |
| [x] | TASK-009 | Create ROADMAP.md, backlog.yaml, and sync workflow | P1 | winsmux | done |
| [x] | TASK-016 | Sync all public docs to v0.9.5 and add version-drift pre-commit gate | P1 | winsmux | done |
| [ ] | TASK-018 | Orchestra dispatch reliability (Issue #67) | P1 | winsmux | backlog |
| [ ] | TASK-003 | Fix select-layout tiled pane redistribution | P2 | sora-psmux | backlog |
| [ ] | TASK-004 | Fix pane_index using pane id instead of actual index | P2 | sora-psmux | backlog |
| [ ] | TASK-005 | Fix select-pane -T empty string title clear | P2 | sora-psmux | backlog |
| [ ] | TASK-006 | Fix remote client label last-row clipping | P2 | sora-psmux | backlog |

### v0.9.7

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-010 | Integrate wait-ready into send command | P1 | winsmux | backlog |
| [ ] | TASK-011 | Add Codex idle prompt detection | P1 | winsmux | backlog |
| [ ] | TASK-012 | Add agent crash/exit detection | P2 | winsmux | backlog |
| [ ] | TASK-013 | Add approval prompt detection | P2 | winsmux | backlog |

### v0.10.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-014 | Integrate shield-harness hooks into winsmux | P1 | winsmux | backlog |
| [ ] | TASK-015 | Installer overhaul with shield-harness bundling | P2 | winsmux | backlog |

## Legend

| Symbol | Meaning |
|--------|---------|
| [x] | Done |
| [-] | In progress |
| [R] | In review |
| [ ] | Backlog / Ready |

| Priority | Meaning |
|----------|---------|
| P0 | Critical / Blocker |
| P1 | High |
| P2 | Medium |
| P3 | Low |