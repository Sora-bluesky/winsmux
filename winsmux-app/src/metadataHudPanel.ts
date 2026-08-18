import type { DesktopExplainPayload, DesktopRunProjection, DesktopWorkerStatusRow } from "./desktopClient";
import { hudChipsFromSources, type MetadataHudChip, type MetadataHudSources } from "./metadataHud";

export type MetadataHudHost = {
  getLanguageText: (en: string, ja: string) => string;
  openPreviewTarget: (url: string) => void;
  getWorkerStatusRowsForSurface: () => DesktopWorkerStatusRow[];
  getFocusedWorkbenchPaneId: () => string | null;
  getWorkerStatusTarget: (row: DesktopWorkerStatusRow) => string;
  getWorkerApiPosture: (row: DesktopWorkerStatusRow) => { cost: string };
  getWorkerHeartbeatHealth: (row: DesktopWorkerStatusRow) => string;
  getWorkerHeartbeatState: (row: DesktopWorkerStatusRow) => string;
  getPrimaryRunProjection: () => DesktopRunProjection | null;
  getExplainForRunId: (runId: string) => DesktopExplainPayload | null;
  getPreviewUrl: () => string;
};

let host: MetadataHudHost | null = null;

function requireHost(): MetadataHudHost {
  if (!host) {
    throw new Error("metadata HUD host is not bound");
  }
  return host;
}

export function bindAndLoadMetadataHud(nextHost: MetadataHudHost) {
  host = nextHost;
}

function collectMetadataHudSources(): MetadataHudSources {
  const bound = requireHost();
  const sources: MetadataHudSources = {};
  const rows = bound.getWorkerStatusRowsForSurface();
  const focusedPaneId = bound.getFocusedWorkbenchPaneId();
  const focusedRow = rows.find((row) => bound.getWorkerStatusTarget(row) === focusedPaneId) ?? rows[0] ?? null;
  if (focusedRow) {
    const cost = bound.getWorkerApiPosture(focusedRow).cost.trim();
    if (cost) {
      sources.cost = cost;
    }
    const heartbeat = (bound.getWorkerHeartbeatHealth(focusedRow) || bound.getWorkerHeartbeatState(focusedRow)).trim();
    if (heartbeat) {
      sources.heartbeat = heartbeat;
    }
  }

  const projection = bound.getPrimaryRunProjection();
  const explain = projection ? bound.getExplainForRunId(projection.run_id) : null;
  const tokensRemaining = (explain?.run.tokens_remaining || "").trim();
  if (tokensRemaining) {
    sources.tokensRemaining = tokensRemaining;
  }
  const branch = (projection?.branch || explain?.run.branch || "").trim();
  if (branch) {
    sources.branch = branch;
  }
  const headSha = (explain?.run.head_sha || projection?.head_sha || "").trim();
  if (headSha) {
    sources.headSha = headSha;
  }
  const worktree = (explain?.run.worktree || projection?.worktree || "").trim();
  if (worktree) {
    sources.worktree = worktree;
  }
  const previewUrl = bound.getPreviewUrl().trim();
  if (previewUrl) {
    sources.previewUrl = previewUrl;
  }
  return sources;
}

function metadataHudChipLabel(id: MetadataHudChip["id"]) {
  const bound = requireHost();
  switch (id) {
    case "cost":
      return bound.getLanguageText("cost", "コスト");
    case "heartbeat":
      return bound.getLanguageText("heartbeat", "生存確認");
    case "context":
      return bound.getLanguageText("context", "コンテキスト");
    case "branch":
      return bound.getLanguageText("branch", "ブランチ");
    case "head":
      return bound.getLanguageText("head", "HEAD");
    case "worktree":
      return bound.getLanguageText("worktree", "ワークツリー");
    case "preview":
      return bound.getLanguageText("preview", "プレビュー");
    case "cpu":
      return bound.getLanguageText("cpu", "CPU");
    case "memory":
      return bound.getLanguageText("memory", "メモリ");
    default:
      return id;
  }
}

export function renderMetadataHud() {
  const root = document.getElementById("metadata-hud");
  if (!root || !host) {
    return;
  }

  const chips = hudChipsFromSources(collectMetadataHudSources());
  root.replaceChildren();
  root.hidden = chips.length === 0;
  root.setAttribute("aria-label", host.getLanguageText("Metadata", "メタデータ"));
  if (chips.length === 0) {
    return;
  }

  const title = document.createElement("span");
  title.className = "metadata-hud-title";
  title.textContent = host.getLanguageText("Metadata", "メタデータ");
  root.appendChild(title);

  for (const chip of chips) {
    const label = metadataHudChipLabel(chip.id);
    const text = `${label}:${chip.value}`;
    if (chip.id === "preview") {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "metadata-hud-chip";
      button.dataset.hudChip = chip.id;
      button.textContent = text;
      button.title = chip.value;
      button.addEventListener("click", () => host?.openPreviewTarget(chip.value));
      root.appendChild(button);
      continue;
    }
    const span = document.createElement("span");
    span.className = "metadata-hud-chip";
    span.dataset.hudChip = chip.id;
    span.textContent = text;
    span.title = chip.value;
    root.appendChild(span);
  }
}
