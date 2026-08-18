import { getDesktopEventsJson } from "./desktopClient";
import * as attentionCenter from "./attentionCenter";
import * as vaultOrganize from "./agentVaultOrganize";

export type AttentionCenterHost = {
  getLanguageText: (en: string, ja: string) => string;
  normalizeProjectDirInput: (value: string | null | undefined) => string;
  getActiveProjectDirPayload: () => string | null | undefined;
  getAvailableRunIds: () => string[];
  focusWorkerPaneFromStatus: (target: string) => void;
  getPaneDisplayLabel: (paneId: string) => string;
  setSelectedRun: (runId: string | null) => void;
  renderDesktopSurfaces: () => void;
  renderAgentVaultPanel: () => void;
};

type SurfaceTone = "default" | "accent" | "success" | "warning" | "danger" | "info" | "focus";

let host: AttentionCenterHost | null = null;
let attentionCenterState = attentionCenter.emptyAttentionCenterState();
let attentionCenterEvents: attentionCenter.CondensedEvent[] = [];
let attentionCenterSnapshotCursor = 0;
let attentionCenterStatusMessage = "";
let attentionCenterFilter: attentionCenter.AttentionFilter = "unread";

function requireHost(): AttentionCenterHost {
  if (!host) {
    throw new Error("attention center host is not bound");
  }
  return host;
}

function persistAttentionCenterState() {
  const bound = requireHost();
  const saved = attentionCenter.persistAttentionCenterStateToStorage(window.localStorage, attentionCenterState);
  if (!saved.ok) {
    attentionCenterStatusMessage = bound.getLanguageText(saved.error, "要確認センターの状態を保存できませんでした。");
    return false;
  }
  return true;
}

export function loadAttentionCenterStateFromStorage() {
  const bound = requireHost();
  const loaded = attentionCenter.loadAttentionCenterState(
    window.localStorage.getItem(attentionCenter.ATTENTION_CENTER_STORAGE_KEY),
  );
  attentionCenterState = loaded.state;
  if (loaded.error) {
    attentionCenterStatusMessage = bound.getLanguageText(loaded.error, "要確認センターの状態を読み込めませんでした。以前の状態を保持します。");
  }
}

export function bindAndLoadAttentionCenter(nextHost: AttentionCenterHost) {
  host = nextHost;
  loadAttentionCenterStateFromStorage();
}

export async function refreshAttentionCenter() {
  const bound = requireHost();
  const projectDir = bound.normalizeProjectDirInput(bound.getActiveProjectDirPayload()) || "";
  const previousProjectDir = attentionCenterState.projectDir;
  attentionCenterState = attentionCenter.alignAttentionCenterProject(attentionCenterState, projectDir);
  if (attentionCenterState.projectDir !== previousProjectDir) {
    persistAttentionCenterState();
  }
  if (!projectDir) {
    attentionCenterEvents = [];
    attentionCenterSnapshotCursor = 0;
    return;
  }

  try {
    const argv = attentionCenter.buildEventsCommandArgv(projectDir, attentionCenterState.lastSeenCursor);
    if (!argv.includes("--json")) {
      attentionCenterEvents = [];
      attentionCenterSnapshotCursor = 0;
      attentionCenterStatusMessage = bound.getLanguageText("events --json is required.", "events --json が必要です。");
      return;
    }
    const stdout = await getDesktopEventsJson(projectDir, attentionCenterState.lastSeenCursor);
    const snapshot = attentionCenter.parseEventsCommandJson(stdout);
    attentionCenterEvents = snapshot.events;
    attentionCenterSnapshotCursor = snapshot.cursor;
    attentionCenterStatusMessage = "";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (attentionCenter.isCompanionWinsmuxMissingError(message) || /companion winsmux CLI was not found/i.test(message)) {
      attentionCenterStatusMessage = bound.getLanguageText(
        attentionCenter.COMPANION_WINSMUX_MISSING_STATUS,
        "companion winsmux 実行ファイルが見つかりません。",
      );
      return;
    }
    attentionCenterEvents = [];
    attentionCenterSnapshotCursor = 0;
    if (attentionCenter.isEventsCommandUsageText(message)) {
      attentionCenterStatusMessage = bound.getLanguageText("events --json is required.", "events --json が必要です。");
      return;
    }
    attentionCenterStatusMessage = bound.getLanguageText(
      "Condensed events could not be read.",
      "要約イベントを読み取れませんでした。",
    );
  }
}

function describeAttentionEvent(event: attentionCenter.CondensedEvent): { title: string; body: string; tone: SurfaceTone } {
  const bound = requireHost();
  const kind = attentionCenter.classifyAttention(event);
  switch (event.type) {
    case "thread_created":
      return {
        title: bound.getLanguageText("Unread thread", "未読スレッド"),
        body: String(event.role || event.pane_id || event.run_id || ""),
        tone: "info",
      };
    case "status_running":
      return {
        title: bound.getLanguageText("Running", "実行中"),
        body: String(event.pane_id || event.run_id || ""),
        tone: "info",
      };
    case "status_idle":
      return {
        title: bound.getLanguageText("Idle", "アイドル"),
        body: String(event.stop_reason || event.pane_id || ""),
        tone: "info",
      };
    case "message_received":
      return {
        title: bound.getLanguageText("Waiting to collect", "回収待ち"),
        body: String(event.task_id || event.run_id || ""),
        tone: "warning",
      };
    case "requires_action":
      if (kind === "failure") {
        return { title: bound.getLanguageText("Failure", "失敗"), body: String(event.kind || ""), tone: "danger" };
      }
      if (kind === "approval") {
        return { title: bound.getLanguageText("Approval", "承認"), body: String(event.kind || ""), tone: "warning" };
      }
      return { title: bound.getLanguageText("Waiting", "待機"), body: String(event.kind || ""), tone: "warning" };
    default:
      return { title: event.type, body: "", tone: "info" };
  }
}

function getAttentionAndFeedTone(feedEntries: Array<{ tone: string }>): SurfaceTone {
  const unread = attentionCenter.unreadEvents(attentionCenterEvents, attentionCenterState.lastSeenCursor);
  if (unread.some((event) => attentionCenter.classifyAttention(event) === "failure") || feedEntries.some((entry) => entry.tone === "danger")) {
    return "danger";
  }
  if (
    unread.some((event) => {
      const kind = attentionCenter.classifyAttention(event);
      return kind === "approval" || kind === "waiting";
    })
    || feedEntries.some((entry) => entry.tone === "warning")
  ) {
    return "warning";
  }
  return vaultOrganize.getAgentVaultNotificationTone(feedEntries);
}

function markAllAttentionRead() {
  attentionCenterState = attentionCenter.markAllRead(attentionCenterState, attentionCenterSnapshotCursor);
  persistAttentionCenterState();
  requireHost().renderAgentVaultPanel();
}

function focusAttentionEvent(event: attentionCenter.CondensedEvent) {
  const bound = requireHost();
  const jump = attentionCenter.attentionJumpTarget(event, bound.getAvailableRunIds());
  attentionCenterState = attentionCenter.markEventRead(attentionCenterState, event);
  persistAttentionCenterState();
  if (jump.paneId) {
    bound.focusWorkerPaneFromStatus(jump.paneId);
    attentionCenterStatusMessage = bound.getLanguageText(
      `Focused ${bound.getPaneDisplayLabel(jump.paneId)} from Attention center.`,
      `要確認センターから ${bound.getPaneDisplayLabel(jump.paneId)} へ移動しました。`,
    );
  } else if (jump.runId) {
    bound.setSelectedRun(jump.runId);
    attentionCenterStatusMessage = bound.getLanguageText(
      `Selected run ${jump.runId} from Attention center.`,
      `要確認センターから run ${jump.runId} を選択しました。`,
    );
    bound.renderDesktopSurfaces();
    return;
  } else {
    attentionCenterStatusMessage = bound.getLanguageText(
      "No pane is attached to this event.",
      "このイベントに紐づくペインはありません。",
    );
  }
  bound.renderAgentVaultPanel();
}

export function renderAttentionCenter(root: HTMLElement) {
  const bound = requireHost();
  const counts = attentionCenter.attentionFilterCounts(attentionCenterEvents, attentionCenterState.lastSeenCursor);
  const rows = attentionCenter.attentionEventsForFilter(
    attentionCenterEvents,
    attentionCenterState.lastSeenCursor,
    attentionCenterFilter,
  );
  root.replaceChildren();

  const header = document.createElement("div");
  header.className = "attention-center-header";
  const title = document.createElement("div");
  title.className = "attention-center-title";
  title.textContent = bound.getLanguageText("Attention center", "要確認センター");
  const markAll = document.createElement("button");
  markAll.type = "button";
  markAll.className = "agent-vault-filter-btn";
  markAll.textContent = bound.getLanguageText("Mark all read", "すべて既読");
  markAll.addEventListener("click", () => markAllAttentionRead());
  header.append(title, markAll);
  root.appendChild(header);

  const filters = document.createElement("div");
  filters.className = "attention-center-filters";
  const filterItems: Array<{ id: attentionCenter.AttentionFilter; label: string; count: number }> = [
    { id: "unread", label: bound.getLanguageText("Unread", "未読"), count: counts.unread },
    { id: "waiting", label: bound.getLanguageText("Waiting", "待機"), count: counts.waiting },
    { id: "approval", label: bound.getLanguageText("Approval", "承認"), count: counts.approval },
    { id: "failure", label: bound.getLanguageText("Failure", "失敗"), count: counts.failure },
  ];
  for (const filter of filterItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "agent-vault-filter-btn";
    button.textContent = `${filter.label} ${filter.count}`;
    button.setAttribute("aria-pressed", attentionCenterFilter === filter.id ? "true" : "false");
    button.addEventListener("click", () => {
      attentionCenterFilter = filter.id;
      bound.renderAgentVaultPanel();
    });
    filters.appendChild(button);
  }
  root.appendChild(filters);

  if (attentionCenterStatusMessage) {
    const status = document.createElement("div");
    status.className = "attention-center-status";
    status.textContent = attentionCenterStatusMessage;
    root.appendChild(status);
  }

  if (rows.length === 0) {
    const empty = document.createElement("div");
    empty.className = "attention-center-empty";
    empty.textContent = bound.getLanguageText("No unread condensed events.", "未読の要約イベントはありません。");
    root.appendChild(empty);
    return;
  }

  for (const event of rows) {
    const described = describeAttentionEvent(event);
    const row = document.createElement("button");
    row.type = "button";
    row.className = "attention-center-row";
    row.dataset.tone = described.tone;
    row.textContent = described.body ? `${described.title}: ${described.body}` : described.title;
    row.addEventListener("click", () => focusAttentionEvent(event));
    root.appendChild(row);
  }
}

export function applyVaultRing(ring: HTMLElement | null, feedEntries: Array<{ tone: string }>) {
  if (!ring) {
    return;
  }
  const bound = requireHost();
  const attentionCounts = attentionCenter.attentionFilterCounts(
    attentionCenterEvents,
    attentionCenterState.lastSeenCursor,
  );
  const ringCount = attentionCounts.unread + feedEntries.length;
  ring.textContent = ringCount > 0 ? `${ringCount}` : "OK";
  ring.dataset.tone = getAttentionAndFeedTone(feedEntries);
  ring.title = bound.getLanguageText(
    `${attentionCounts.unread} unread attention · ${feedEntries.length} inbox`,
    `未読 ${attentionCounts.unread} · 受信箱 ${feedEntries.length}`,
  );
}
