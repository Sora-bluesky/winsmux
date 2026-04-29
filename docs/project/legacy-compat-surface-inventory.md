# Legacy Compatibility Surface Inventory

Purpose: contributor-facing `TASK-408` inventory and gate for removing legacy `psmux`, `pmux`, and `tmux` alias surfaces before `v1.0.0`.

This does not remove aliases. It makes the remaining compatibility surface explicit so release work can distinguish intentional shims from removal candidates.

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
- Legacy `psmux`, `pmux`, and `tmux` binary aliases remain a removal candidate for `v1.0.0`.
- Legacy upstream tests remain governed by `TASK-407`; this task only prevents unclassified compatibility references from being added.
- Operator startup guidance that forbids `psmux` probes is an intentional safety shim until the alias removal is complete.

## Gate contract

The gate fails when:

- a repository text file from `git ls-files --cached --others --exclude-standard` contains `psmux`, `pmux`, or `tmux` and is not covered by the inventory,
- an inventory entry uses an unknown class,
- an inventory entry lacks owner, surface, reason, or target,
- an inventory path or glob matches no repository file,
- or the inventory/documentation introduces private local paths or maintainer-only skill references.

The gate can pass while removal candidates remain. That is intentional for this task: `TASK-408` creates the release-sized inventory and validation surface, not the unsafe broad deletion.
