# Legacy Compatibility Surface Inventory

Purpose: contributor-facing `TASK-408` inventory and gate for keeping legacy `psmux`, `pmux`, and `tmux` references classified after the binary alias sunset.

The binary alias sunset has removed the shipped `psmux`, `pmux`, and `tmux` executable names from the Rust package. This inventory keeps the remaining compatibility surface explicit so release work can distinguish intentional tmux-compatible behavior from stale legacy references.

The machine-readable inventory is `docs/project/legacy-compat-surface-inventory.json`.
Validate it with either command:

- `pwsh -NoProfile -File scripts/validate-legacy-compat-inventory.ps1`
- `winsmux legacy-compat-gate --json`

## Release rule

| Class | Meaning | Release rule |
| --- | --- | --- |
| `intentional-shim` | A compatibility reference that still protects documented product behavior, migration behavior, or operator safety. | Keep until the replacement contract exists or product behavior changes. |
| `removal-candidate` | A legacy binary alias, packaging output, archived test, or diagnostic surface that should not remain after the alias sunset. | Remove, migrate, or archive before `v1.0.0`; do not delete without replacement evidence when behavior is still covered. |

## Current conclusion

- Public `tmux` command, configuration, target, pane environment, and control-mode compatibility remains product behavior.
- Legacy `psmux`, `pmux`, and `tmux` binary aliases are no longer shipped.
- Legacy upstream tests remain governed by `TASK-407`; this task only prevents unclassified compatibility references from being added.
- Operator startup guidance that forbids `psmux` probes is an intentional safety shim for older local installs and stale runbooks.

## Gate contract

The gate fails when:

- a repository text file from `git ls-files --cached --others --exclude-standard` contains `psmux`, `pmux`, or `tmux` and is not covered by the inventory,
- an inventory entry uses an unknown class,
- an inventory entry lacks owner, surface, reason, or target,
- an inventory path or glob matches no repository file,
- or the inventory/documentation introduces private local paths or maintainer-only skill references.

The gate can pass while reference-cleanup candidates remain. That is intentional for this task: `TASK-408` keeps the inventory and validation surface so stale legacy references do not re-enter public release artifacts unnoticed.
