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

/**
 * Returns true when the backend status row itself reports the worker pane
 * as running/healthy, independent of whether this webview has locally
 * observed a PTY output event for that pane yet.
 *
 * A pane restored/reattached from a previous session can be running and
 * healthy on the backend from the very first status poll, before this
 * webview ever sees a PTY output event for it (`pane.ptyStarted` starts out
 * false and only flips once output is observed). Relying on the local PTY
 * flag alone means a drifted-but-idle restored pane never gets flagged,
 * because `requiresReapproval` requires "already running" to be true. This
 * checks the row's own state/pane_state/heartbeat fields so restore-time
 * drift detection does not depend on the pane having produced output yet.
 */
export function isWorkerStatusRowRunning(
  row: {
    state?: string;
    pane_state?: string;
    heartbeat_state?: string;
    heartbeat_health?: string;
    heartbeat?: { state?: string; health?: string } | null;
  },
): boolean {
  const signals = [
    row.state,
    row.pane_state,
    row.heartbeat_state,
    row.heartbeat_health,
    row.heartbeat?.state,
    row.heartbeat?.health,
  ];
  return signals.some((value) => {
    const normalized = (value ?? "").trim().toLowerCase();
    return normalized === "running" || normalized === "healthy";
  });
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
 *
 * "Already running" is satisfied by either the caller's locally-observed
 * PTY signal (`isRunning`) or the backend row itself reporting a
 * running/healthy state (see `isWorkerStatusRowRunning`), because a
 * restored pane can be running on the backend before this webview has
 * observed any PTY output from it.
 */
export function classifyRestoredWorkerDrift(
  row: {
    approval_differences?: DesktopWorkerApprovalDifference[];
    state?: string;
    pane_state?: string;
    heartbeat_state?: string;
    heartbeat_health?: string;
    heartbeat?: { state?: string; health?: string } | null;
  },
  target: string,
  isRunning: boolean,
): RestoredWorkerDriftClassification {
  const differences = row.approval_differences ?? [];
  const drifted = differences.length > 0;
  const running = isRunning || isWorkerStatusRowRunning(row);
  return {
    target,
    drifted,
    requiresReapproval: drifted && running,
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
 *
 * `candidateIds` must come from the project's *actual* configured slots
 * (i.e. the keys of the backend status rows, since the backend only
 * returns a row per configured slot) rather than a fixed upper-bound list
 * such as `worker-1..worker-6`. A project configured with fewer than the
 * maximum worker count (`--worker-count`) never has status rows for the
 * unconfigured higher slots, and treating those as "missing" would block
 * the Start action entirely instead of starting the panes that do exist.
 * Callers that intentionally require the full fixed roster (for example a
 * benchmark gate that always needs all six panes) should keep passing
 * their own fixed id list and must not reuse this helper for that case.
 */
export function selectConfiguredWorkerStartRoster<TRow extends { approval_differences?: DesktopWorkerApprovalDifference[] }>(
  candidateIds: readonly string[],
  rowsByTarget: ReadonlyMap<string, TRow>,
): WorkerStartRosterSelection<TRow> {
  const startable: TRow[] = [];
  const blockedBySettings: TRow[] = [];
  const missingTargets: string[] = [];

  for (const target of candidateIds) {
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
