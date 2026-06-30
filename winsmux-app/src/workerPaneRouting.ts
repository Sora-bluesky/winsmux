import type { DesktopBoardPane, DesktopWorkerStatusRow } from "./desktopClient";

function compactPaneAlias(value: string | null | undefined) {
  return (value || "").trim();
}

export function getWorkerStatusPaneAliases(row: DesktopWorkerStatusRow) {
  const target = compactPaneAlias(row.slot_id) || compactPaneAlias(row.slot) || compactPaneAlias(row.pane_id);
  const aliases = [
    row.slot_id,
    row.slot,
    row.pane_id,
    target,
  ].map(compactPaneAlias).filter((value) => Boolean(value));
  return Array.from(new Set(aliases));
}

export function findWorkerStatusRowByPaneAlias(rows: DesktopWorkerStatusRow[], paneId: string) {
  const normalizedPaneId = compactPaneAlias(paneId);
  if (!normalizedPaneId) {
    return null;
  }
  return rows.find((row) => getWorkerStatusPaneAliases(row).includes(normalizedPaneId)) ?? null;
}

export function resolveWorkbenchPaneIdForBackendPaneId(
  paneId: string,
  rows: DesktopWorkerStatusRow[],
  visiblePaneIds: ReadonlySet<string>,
) {
  const normalizedPaneId = compactPaneAlias(paneId);
  if (!normalizedPaneId) {
    return null;
  }
  if (visiblePaneIds.has(normalizedPaneId)) {
    return normalizedPaneId;
  }

  const row = findWorkerStatusRowByPaneAlias(rows, normalizedPaneId);
  if (!row) {
    return null;
  }

  const aliases = getWorkerStatusPaneAliases(row);
  return aliases.find((alias) => visiblePaneIds.has(alias)) ?? null;
}

export function findBoardPaneForWorkbenchPane(
  boardPanes: DesktopBoardPane[],
  paneId: string,
  rows: DesktopWorkerStatusRow[],
) {
  const direct = boardPanes.find((item) => item.pane_id === paneId || item.label === paneId);
  if (direct) {
    return direct;
  }

  const workerRow = findWorkerStatusRowByPaneAlias(rows, paneId);
  if (!workerRow) {
    return null;
  }

  const aliases = getWorkerStatusPaneAliases(workerRow);
  return boardPanes.find((item) => aliases.includes(item.pane_id) || aliases.includes(item.label)) ?? null;
}
