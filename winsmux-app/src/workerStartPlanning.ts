import type { DesktopWorkerApprovalDifference, DesktopWorkerStatusRow } from "./desktopClient";

/**
 * Returns true when the backend reports that the currently approved/running
 * launch configuration for a worker pane differs from what the active
 * Settings (per-pane provider/model assignment) would launch right now.
 *
 * This is the single source of truth for "settings drift" and must be used
 * by every start/restore/roster decision instead of re-deriving the same
 * `(row.approval_differences ?? []).length > 0` check inline.
 */
export function hasWorkerLaunchApprovalDrift(
  row: { approval_differences?: DesktopWorkerApprovalDifference[] },
): boolean {
  return (row.approval_differences ?? []).length > 0;
}

export interface RestoredWorkerDriftClassification {
  target: string;
  drifted: boolean;
  requiresReapproval: boolean;
  differences: DesktopWorkerApprovalDifference[];
}

/**
 * Classifies a worker pane discovered during restore/refresh.
 *
 * A pane only "requiresReapproval" when it is BOTH already running (so a
 * user would otherwise never be prompted, because they have no reason to
 * click Start on a pane that already looks alive) AND drifted from the
 * current Settings. This intentionally never recommends killing or
 * silently restarting the pane with the new Settings value -- restart
 * still requires explicit re-approval, matching the existing
 * approval-differences gate used by the manual start actions.
 */
export function classifyRestoredWorkerDrift(
  row: { approval_differences?: DesktopWorkerApprovalDifference[] },
  target: string,
  isRunning: boolean,
): RestoredWorkerDriftClassification {
  const differences = row.approval_differences ?? [];
  const drifted = differences.length > 0;
  return {
    target,
    drifted,
    requiresReapproval: drifted && isRunning,
    differences,
  };
}

export interface WorkerStartRosterSelection<TRow> {
  /** Configured pane ids that have a status row and no settings drift. */
  startable: TRow[];
  /** Configured pane ids whose row has unresolved settings drift. */
  blockedBySettings: TRow[];
  /** Configured pane ids that have no status row at all yet. */
  missingTargets: string[];
}

/**
 * Selects the roster of configured worker panes that a "Start" action
 * should target. This is used both by the toolbar Start button (which must
 * start every configured-but-not-yet-running pane, not only the focused
 * one) and by the operator "start all" command, so the two surfaces cannot
 * drift apart again.
 */
export function selectConfiguredWorkerStartRoster<TRow extends { approval_differences?: DesktopWorkerApprovalDifference[] }>(
  configuredIds: readonly string[],
  rowsByTarget: ReadonlyMap<string, TRow>,
): WorkerStartRosterSelection<TRow> {
  const startable: TRow[] = [];
  const blockedBySettings: TRow[] = [];
  const missingTargets: string[] = [];

  for (const target of configuredIds) {
    const row = rowsByTarget.get(target);
    if (!row) {
      missingTargets.push(target);
      continue;
    }
    if (hasWorkerLaunchApprovalDrift(row)) {
      blockedBySettings.push(row);
      continue;
    }
    startable.push(row);
  }

  return { startable, blockedBySettings, missingTargets };
}

// Referenced for the exported type surface only -- keeps DesktopWorkerStatusRow
// imported for callers that want to annotate rows explicitly.
export type { DesktopWorkerStatusRow };
