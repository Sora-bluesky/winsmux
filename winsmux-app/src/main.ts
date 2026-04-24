import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";
import { isTauri } from "@tauri-apps/api/core";
import { WebviewWindow, getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import {
  compareDesktopRuns,
  getDesktopEditorFile,
  getDesktopRunExplain,
  getDesktopSummarySnapshot,
  pickDesktopRunWinner,
  promoteDesktopRunTactic,
  subscribeToDesktopSummaryRefresh,
  type DesktopCompareRunsResult,
  type DesktopBoardPane,
  type DesktopEditorFilePayload,
  type DesktopExplainPayload,
  type DesktopRunProjection,
  type DesktopSummarySnapshot,
} from "./desktopClient";
import { getEditorFileKey, getSourceChangeKey, pickEditorPathCandidate } from "./editorTargets";
import {
  closePtyPane,
  resizePtyPane,
  spawnPtyPane,
  subscribeToPtyOutput,
  writePtyData,
} from "./ptyClient";

interface PaneEntry {
  terminal: Terminal;
  fitAddon: FitAddon;
  container: HTMLElement;
  labelElement: HTMLElement;
  metaElement: HTMLElement;
  lastOutputAt: number | null;
}

type ChipAction =
  | "open-explain"
  | "open-editor"
  | "open-source-context"
  | "toggle-context"
  | "open-terminal";

interface ConversationChip {
  label: string;
  action: ChipAction;
}

type TimelineFilter = "all" | "attention" | "review" | "activity";
type ConversationCategory = "user" | "attention" | "review" | "activity";

interface ConversationDetail {
  label: string;
  value: string;
}

interface ConversationItem {
  type: "user" | "operator" | "system";
  category: ConversationCategory;
  timestamp: string;
  actor: string;
  title?: string;
  body: string;
  details?: ConversationDetail[];
  chips?: ConversationChip[];
  attachments?: Array<{ name: string; kind: "image" | "file"; sizeLabel: string }>;
  tone?: SurfaceTone;
  runId?: string;
  statusLabel?: string;
}

interface SessionItem {
  name: string;
  meta: string;
  active?: boolean;
}

interface DetachedSurfaceSessionState {
  name: string;
  meta: string;
}

interface ExplorerItem {
  label: string;
  meta?: string;
  depth: number;
  kind: "folder" | "file";
  path?: string;
  worktree?: string;
  open?: boolean;
  active?: boolean;
}

interface EditorFile {
  key: string;
  path: string;
  summary: string;
  content: string;
  language: string;
  lineCount: number;
  modified?: boolean;
  origin: "explorer" | "context";
  active?: boolean;
}

interface EditorTarget {
  key: string;
  path: string;
  summary: string;
  worktree: string;
  origin: "explorer" | "context";
  modified: boolean;
  sourceChange?: SourceChange;
}

interface PreviewTarget {
  url: string;
  portLabel: string;
  sourceLabel: string;
  lastSeenAt: number;
}

type PopoutSurfaceState =
  | {
      mode: "preview";
      url: string;
      portLabel: string;
      sourceLabel: string;
      lastSeenAt: number;
      runId?: string;
      runLabel?: string;
    }
  | {
      mode: "editor";
      path: string;
      worktree: string;
      summary: string;
      origin: "explorer" | "context";
      modified: boolean;
      sourceChange?: SourceChange | null;
      content?: string;
      runId?: string;
      runLabel?: string;
    };

declare global {
  interface Window {
    __winsmuxViewportHarness?: {
      registerPreviewTarget: (sourceLabel: string, url: string) => void;
      openPreviewTarget: (url: string) => void;
      openEditorPreview: (path: string, content: string, worktree?: string) => void;
      setContextPanel: (open: boolean) => void;
      setTerminalDrawer: (open: boolean) => void;
    };
  }
}

type SourceFilter = "all" | "candidates" | "attention" | `pane:${string}`;

type ChangeStatus = "modified" | "added" | "deleted" | "renamed";
type ChangeRisk = "low" | "medium" | "high";

interface SourceChange {
  path: string;
  summary: string;
  paneLabel: string;
  worktree: string;
  status: ChangeStatus;
  risk: ChangeRisk;
  branch: string;
  lines: string;
  commitCandidate: boolean;
  needsAttention: boolean;
  run: string;
  review: string;
}

interface FooterStatusItem {
  label: string;
  value?: string;
  tone?: SurfaceTone;
}

interface ExperimentDetailLine {
  label: string;
  value: string;
  path?: string;
  worktree?: string;
  title?: string;
}

type SurfaceTone = "default" | "accent" | "success" | "warning" | "danger" | "info" | "focus";
type CompareRiskLevel = "low" | "medium" | "high";
type ThemeMode = "codex-dark" | "graphite-dark";
type DensityMode = "comfortable" | "compact";
type WrapMode = "balanced" | "compact";

interface ThemeState {
  theme: ThemeMode;
  density: DensityMode;
  wrapMode: WrapMode;
}

interface ShellPreferenceState extends ThemeState {
  sidebarWidth: number;
  wideSidebarOpen: boolean;
  wideContextOpen: boolean;
}

interface ComposerAttachment {
  id: string;
  name: string;
  kind: "image" | "file";
  sizeLabel: string;
  file: File;
  previewUrl?: string;
}

interface ComposerRemoteReference {
  id: string;
  label: string;
  meta: string;
}

interface ComposerAttachmentSnapshot {
  name: string;
  kind: "image" | "file";
  sizeLabel: string;
  file: File;
}

interface ComposerHistoryEntry {
  value: string;
  remoteReferenceIds: string[];
  attachments: ComposerAttachmentSnapshot[];
}

type ComposerMode = "ask" | "dispatch" | "review" | "explain";

interface CommandAction {
  id: string;
  label: string;
  description: string;
  keywords: string[];
  shortcut?: string;
  tone?: SurfaceTone;
  run: () => void;
}

const panes = new Map<string, PaneEntry>();
let paneCounter = 0;
let terminalDrawerOpen = false;
let contextPanelOpen = true;
let editorSurfaceOpen = false;
let editorSurfaceMode: "code" | "preview" = "code";
let settingsSheetOpen = false;
let sidebarOpen = true;
let composerImeActive = false;
let sidebarWidth = 292;
let selectedEditorKey = "";
let selectedPreviewUrl = "";
let lastPreviewExternalState: { url: string; at: number; ok: boolean } | null = null;
let lastPreviewClipboardState: { url: string; at: number; ok: boolean } | null = null;
let selectedRunId: string | null = null;
let detachedSurfaceRunLabel = "";
let detachedSurfaceSession: DetachedSurfaceSessionState | null = null;
let detachedSurfacePollTimer: number | null = null;
let activeComposerMode: ComposerMode = "dispatch";
let composerSlashOpen = false;
let composerSlashQuery = "";
let selectedComposerSlashIndex = 0;
let composerHistory: ComposerHistoryEntry[] = [];
let composerHistoryIndex = -1;
let composerDraftState: ComposerHistoryEntry = { value: "", remoteReferenceIds: [], attachments: [] };
let selectedComposerRemoteReferenceIds = new Set<string>();
let activeSourceFilter: SourceFilter = "all";
let activeTimelineFilter: TimelineFilter = "all";
let commandBarOpen = false;
let commandBarQuery = "";
let selectedCommandIndex = 0;
let commandBarImeActive = false;
let lastCommandBarFocus: HTMLElement | null = null;
let pendingAttachments: ComposerAttachment[] = [];
const detectedPreviewTargets = new Map<string, PreviewTarget>();
const PREVIEW_FRESHNESS_WINDOW_MS = 30_000;
const PANE_META_REFRESH_INTERVAL_MS = 30_000;
let desktopSummarySnapshot: DesktopSummarySnapshot | null = null;
let desktopSummaryRefreshInFlight: Promise<void> | null = null;
let desktopSummaryRefreshTimeout: number | null = null;
let desktopSummaryQueuedRunId: string | null = null;
let desktopSummaryRefreshRequestedVersion = 0;
let desktopSummaryRefreshRunningVersion = 0;
let desktopSummaryFallbackRefreshRegistered = false;
let desktopSummaryLiveRefreshAvailable = false;
let desktopSummaryLastSuccessfulRefreshAt = 0;
let desktopSummaryLastStreamSignalAt = 0;
let desktopSummaryRefreshSerial = 0;
const desktopExplainCache = new Map<string, DesktopExplainPayload>();
const desktopRunCompareCache = new Map<string, DesktopCompareRunsResult>();
const promotedRunCandidates = new Map<string, {
  fingerprint: string;
  candidateRef: string;
  collapseAfterRefreshSerial: number;
}>();
const desktopEditorFileCache = new Map<string, EditorFile>();
const desktopEditorLoadingPaths = new Set<string>();
const desktopEditorLoadErrors = new Map<string, string>();
const desktopStandaloneEditorTargets = new Map<string, EditorTarget>();
const promotingRunIds = new Set<string>();
const pickingWinnerRunIds = new Set<string>();
const pendingPromotedRunRefreshIds = new Set<string>();
const comparingRunPairKeys = new Set<string>();
const backendConversation: ConversationItem[] = [];
const runtimeConversation: ConversationItem[] = [];
const DESKTOP_SUMMARY_REFRESH_FALLBACK_INTERVAL_MS = 15_000;
const DESKTOP_SUMMARY_STREAM_STALE_MS = 60_000;
const MAX_RUNTIME_CONVERSATION_ITEMS = 80;
const themeState: ThemeState = {
  theme: "codex-dark",
  density: "comfortable",
  wrapMode: "balanced",
};
let settingsDraftState: ThemeState | null = null;
let preferredWideSidebarOpen = true;
let preferredWideContextOpen = true;
const SHELL_PREFERENCES_STORAGE_KEY = "winsmux.shell.preferences.v1";
const POPOUT_SURFACE_STORAGE_KEY_PREFIX = "winsmux.popout-surface.";

const composerModes: Array<{ mode: ComposerMode; label: string; placeholder: string }> = [
  { mode: "ask", label: "Ask", placeholder: "Ask the Operator for clarification, status, or guidance" },
  { mode: "dispatch", label: "Dispatch", placeholder: "Dispatch the next task to the Operator" },
  { mode: "review", label: "Review", placeholder: "Request review, approval, or audit from the Operator" },
  { mode: "explain", label: "Explain", placeholder: "Ask the Operator to explain the current run state" },
];

const composerSlashCommands: Array<{
  command: string;
  label: string;
  description: string;
  mode: ComposerMode;
}> = composerModes.map((item) => ({
  command: item.mode,
  label: item.label,
  description: item.placeholder,
  mode: item.mode,
}));

const timelineFilters: Array<{ filter: TimelineFilter; label: string }> = [
  { filter: "all", label: "All" },
  { filter: "attention", label: "Attention" },
  { filter: "review", label: "Review" },
  { filter: "activity", label: "Activity" },
];

const themeOptions: Array<{ value: ThemeMode; label: string; description: string }> = [
  { value: "codex-dark", label: "Codex TUI Dark", description: "Adaptation of public openai/codex TUI typography and contrast." },
  { value: "graphite-dark", label: "Graphite", description: "Softer shell contrast for long operator sessions." },
];

const densityOptions: Array<{ value: DensityMode; label: string; description: string }> = [
  { value: "comfortable", label: "Comfortable", description: "Default shell spacing for conversation and context." },
  { value: "compact", label: "Compact", description: "Tighter panel spacing and smaller composer height." },
];

const wrapOptions: Array<{ value: WrapMode; label: string; description: string }> = [
  { value: "balanced", label: "Balanced", description: "Preferred readability for timeline, code, and footer lanes." },
  { value: "compact", label: "Compact", description: "Denser wrapping for narrow windows and long traces." },
];

function createPane(paneId?: string): string {
  const id = paneId || `pane-${++paneCounter}`;
  const container = document.getElementById("panes-container");
  if (!container) {
    return id;
  }

  const paneDiv = document.createElement("div");
  paneDiv.className = "pane";
  paneDiv.id = `pane-${id}`;

  const header = document.createElement("div");
  header.className = "pane-header";

  const labelGroup = document.createElement("div");
  labelGroup.className = "pane-heading";

  const label = document.createElement("span");
  label.className = "pane-label";
  label.textContent = id;

  const meta = document.createElement("span");
  meta.className = "pane-meta";
  meta.textContent = "No branch · waiting for summary";

  const closeBtn = document.createElement("button");
  closeBtn.className = "pane-close";
  closeBtn.textContent = "×";
  closeBtn.onclick = () => closePane(id);

  labelGroup.appendChild(label);
  labelGroup.appendChild(meta);
  header.appendChild(labelGroup);
  header.appendChild(closeBtn);

  const termDiv = document.createElement("div");
  termDiv.className = "pane-terminal";

  paneDiv.appendChild(header);
  paneDiv.appendChild(termDiv);

  if (panes.size > 0) {
    const splitter = document.createElement("div");
    splitter.className = "splitter";
    container.appendChild(splitter);
  }

  container.appendChild(paneDiv);

  const terminal = new Terminal({
    cursorBlink: true,
    fontSize: 13,
    fontFamily: "'Cascadia Code', 'Consolas', monospace",
    theme: {
      background: "#131722",
      foreground: "#c7d2e6",
      cursor: "#c7d2e6",
    },
  });

  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(termDiv);
  fitAddon.fit();

  terminal.onData((data: string) => {
    void writePtyData(id, data);
  });

  terminal.onResize(({ cols, rows }) => {
    void resizePtyPane(id, cols, rows);
  });

  panes.set(id, {
    terminal,
    fitAddon,
    container: paneDiv,
    labelElement: label,
    metaElement: meta,
    lastOutputAt: null,
  });

  const { cols, rows } = { cols: terminal.cols, rows: terminal.rows };
  void spawnPtyPane(id, cols, rows)
    .catch((error) => {
      console.warn("Failed to spawn PTY pane", error);
    })
    .finally(() => {
      requestDesktopSummaryRefresh(undefined, 500);
    });

  return id;
}

function closePane(id: string) {
  const entry = panes.get(id);
  if (!entry) {
    return;
  }

  if (panes.size <= 1) {
    return;
  }

  entry.terminal.dispose();

  const prev = entry.container.previousElementSibling;
  if (prev && prev.classList.contains("splitter")) {
    prev.remove();
  }

  entry.container.remove();
  panes.delete(id);
  void closePtyPane(id)
    .catch((error) => {
      console.warn("Failed to close PTY pane", error);
    })
    .finally(() => {
      requestDesktopSummaryRefresh(undefined, 500);
    });

  panes.forEach((pane) => pane.fitAddon.fit());
}

function renderSessions() {
  const root = document.getElementById("session-list");
  if (!root) {
    return;
  }

  const activeSessions = getSessionItems();
  root.innerHTML = "";
  for (const session of activeSessions) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${session.active ? "is-active" : ""}`;
    button.innerHTML = `<span class="sidebar-row-title">${session.name}</span><span class="sidebar-row-meta">${session.meta}</span>`;
    root.appendChild(button);
  }
}

function getSessionItems() {
  if (!desktopSummarySnapshot) {
    const items: SessionItem[] = [{ name: "winsmux", meta: "Connecting to desktop summary", active: true }];
    if (detachedSurfaceSession) {
      items.push({
        name: detachedSurfaceSession.name,
        meta: detachedSurfaceSession.meta,
      });
    }
    return items;
  }

  const board = desktopSummarySnapshot.board.summary;
  const inbox = desktopSummarySnapshot.inbox.summary;
  const digest = desktopSummarySnapshot.digest.summary;

  const items = [
    {
      name: "winsmux",
      meta: `${board.pane_count} panes · ${inbox.item_count} inbox · ${board.tasks_blocked} blocked`,
      active: true,
    },
    {
      name: "summary-stream",
      meta: `${digest.item_count} runs · ${digest.actionable_items} actionable · ${board.review_pending} review pending`,
    },
  ] satisfies SessionItem[];

  if (detachedSurfaceSession) {
    items.push({
      name: detachedSurfaceSession.name,
      meta: detachedSurfaceSession.meta,
    });
  }

  return items;
}

function getRunProjections() {
  return desktopSummarySnapshot?.run_projections ?? [];
}

function getAvailableRunIds(snapshot: DesktopSummarySnapshot | null = desktopSummarySnapshot) {
  if (!snapshot) {
    return [] as string[];
  }

  return snapshot.run_projections.map((projection) => projection.run_id);
}

function resolveSelectedRunId(snapshot: DesktopSummarySnapshot | null = desktopSummarySnapshot, preferredRunId?: string | null) {
  const availableRunIds = getAvailableRunIds(snapshot);
  if (availableRunIds.length === 0) {
    return null;
  }

  if (preferredRunId && availableRunIds.includes(preferredRunId)) {
    return preferredRunId;
  }

  if (selectedRunId && availableRunIds.includes(selectedRunId)) {
    return selectedRunId;
  }

  return availableRunIds[0] ?? null;
}

function getRunProjectionByRunId(runId: string | null) {
  if (!runId) {
    return null;
  }
  return getRunProjections().find((projection) => projection.run_id === runId) ?? null;
}

function getPrimaryRunProjection() {
  const resolvedRunId = resolveSelectedRunId();
  return getRunProjectionByRunId(resolvedRunId) ?? getRunProjections()[0] ?? null;
}

function getComparePairKey(leftRunId: string, rightRunId: string) {
  return `${leftRunId}::${rightRunId}`;
}

function mirrorCompareRunsResult(result: DesktopCompareRunsResult): DesktopCompareRunsResult {
  return {
    ...result,
    left: result.right,
    right: result.left,
    left_only_changed_files: [...result.right_only_changed_files],
    right_only_changed_files: [...result.left_only_changed_files],
    confidence_delta: result.confidence_delta !== null ? -result.confidence_delta : null,
    differences: result.differences.map((difference) => ({
      ...difference,
      left: difference.right,
      right: difference.left,
    })),
  };
}

function getComparePeerProjection(
  selectedProjection: DesktopRunProjection,
  preferredRunId?: string | null,
) {
  const otherRuns = getRunProjections().filter(
    (projection) => projection.run_id !== selectedProjection.run_id,
  );
  if (otherRuns.length === 0) {
    return null;
  }

  if (preferredRunId) {
    const preferredPeer = otherRuns.find(
      (projection) => projection.run_id === preferredRunId,
    );
    if (preferredPeer) {
      return preferredPeer;
    }
  }

  const sameTaskPeer = otherRuns.find(
    (projection) =>
      Boolean(selectedProjection.task) &&
      projection.task === selectedProjection.task,
  );
  if (sameTaskPeer) {
    return sameTaskPeer;
  }

  const sameBranchPeer = otherRuns.find(
    (projection) =>
      Boolean(selectedProjection.branch) &&
      projection.branch === selectedProjection.branch,
  );

  return sameBranchPeer ?? null;
}

function getCompareWinnerLabel(result: DesktopCompareRunsResult) {
  if (!result.recommend.winning_run_id) {
    return "";
  }
  if (result.recommend.winning_run_id === result.left.run_id) {
    return result.left.label || result.left.run_id;
  }
  if (result.recommend.winning_run_id === result.right.run_id) {
    return result.right.label || result.right.run_id;
  }
  return result.recommend.winning_run_id;
}

function summarizeCompareDifferenceFields(
  result: DesktopCompareRunsResult,
  limit = 3,
) {
  const fields = Array.from(
    new Set(
      result.differences
        .map((difference) => difference.field)
        .filter((field) => Boolean(field)),
    ),
  );
  if (fields.length === 0) {
    return "";
  }
  if (fields.length <= limit) {
    return fields.join(", ");
  }
  return `${fields.slice(0, limit).join(", ")} +${fields.length - limit}`;
}

function getCompareConflictRadar(result: DesktopCompareRunsResult): {
  level: CompareRiskLevel;
  label: string;
  tone: SurfaceTone;
  hotspots: string[];
  summary: string;
} {
  const hotspots = result.shared_changed_files.filter((path) => Boolean(path));
  const requiresConsult = result.recommend.reconcile_consult;
  const riskyFields = new Set([
    "branch",
    "worktree",
    "env_fingerprint",
    "command_hash",
    "result",
    "changed_files",
  ]);
  const riskyDifferenceCount = result.differences.filter((difference) =>
    riskyFields.has(difference.field),
  ).length;
  const hasMaterialDrift = riskyDifferenceCount > 0 || result.differences.length >= 3;
  const hasUnrecommendableRun = !result.left.recommendable || !result.right.recommendable;
  const level: CompareRiskLevel =
    hasUnrecommendableRun || (requiresConsult && hotspots.length > 0)
      ? "high"
      : (hotspots.length > 0 || hasMaterialDrift ? "medium" : "low");
  const label = level === "high"
    ? "High"
    : (level === "medium" ? "Medium" : "Low");
  const tone: SurfaceTone =
    level === "high" ? "danger" : (level === "medium" ? "warning" : "success");
  const reason = hasUnrecommendableRun
    ? "run not recommendable"
    : (
      hotspots.length > 0
        ? `${hotspots.length} hotspot${hotspots.length === 1 ? "" : "s"}`
        : (hasMaterialDrift ? `${riskyDifferenceCount || result.differences.length} risk fields` : "no shared files")
    );

  return {
    level,
    label,
    tone,
    hotspots,
    summary: `${label} risk · ${reason}`,
  };
}

function setSelectedRun(runId: string | null) {
  selectedRunId = resolveSelectedRunId(desktopSummarySnapshot, runId);
}

function getProjectionSourceEntries(): SourceChange[] {
  const projections = getRunProjections();
  if (projections.length === 0) {
    return [];
  }

  const entries: SourceChange[] = [];
  for (const projection of projections) {
    const changedFiles = projection.changed_files;
    const reviewState = projection.review_state || "unknown";
    const verification = projection.verification_outcome || "";
    const security = projection.security_blocked || "";
    const commitCandidate =
      reviewState === "PASS" &&
      (verification === "" || verification === "PASS") &&
      (security === "" || security === "ALLOW" || security === "PASS");
    const needsAttention =
      reviewState === "PENDING" ||
      reviewState === "FAIL" ||
      reviewState === "FAILED" ||
      security === "BLOCK" ||
      projection.next_action === "blocked";
    const risk: ChangeRisk = needsAttention ? "high" : commitCandidate ? "low" : "medium";

    for (const path of changedFiles) {
      const recentReason = projection.reasons?.[0];
      entries.push({
        path,
        summary: recentReason || projection.summary || projection.task || `Projected from ${projection.run_id}`,
        paneLabel: projection.label || projection.pane_id || "summary-stream",
        worktree: projection.worktree || "",
        status: "modified",
        risk,
        branch: projection.branch || "no branch",
        lines: `${changedFiles.length} changed in run`,
        commitCandidate,
        needsAttention,
        run: projection.run_id,
        review: reviewState,
      });
    }
  }

  return entries;
}

function findSourceChangeByKey(key: string) {
  return getProjectionSourceEntries().find((entry) => getSourceChangeKey(entry) === key);
}

function findSourceChangeByPath(path: string, worktree = "") {
  return (
    pickEditorPathCandidate(getVisibleSourceChanges(), path, worktree, selectedEditorKey) ??
    pickEditorPathCandidate(getProjectionSourceEntries(), path, worktree, selectedEditorKey)
  );
}

function createStandaloneEditorTarget(path: string, worktree = ""): EditorTarget {
  const key = getEditorFileKey(path, worktree);
  return {
    key,
    path,
    summary: `Project file preview · ${path.split("/").pop() ?? path}`,
    worktree,
    origin: "explorer",
    modified: false,
  };
}

function getExplorerItems() {
  const targets = new Map<string, EditorTarget>();
  for (const entry of getProjectionSourceEntries()) {
    const target = getEditorTargetForSourceChange(entry);
    if (target) {
      targets.set(target.key, target);
    }
  }
  for (const [key, target] of desktopStandaloneEditorTargets) {
    if (!targets.has(key)) {
      targets.set(key, target);
    }
  }

  const items: ExplorerItem[] = [];
  const seenFolders = new Set<string>();

  const worktreeGroups = new Map<string, EditorTarget[]>();
  for (const target of Array.from(targets.values()).sort((left, right) => left.path.localeCompare(right.path))) {
    const worktreeKey = target.worktree || ".";
    const group = worktreeGroups.get(worktreeKey) ?? [];
    group.push(target);
    worktreeGroups.set(worktreeKey, group);
  }

  for (const [worktreeKey, group] of Array.from(worktreeGroups.entries()).sort((left, right) =>
    getWorktreeLabel(left[0]).localeCompare(getWorktreeLabel(right[0])),
  )) {
    items.push({
      label: getWorktreeLabel(worktreeKey),
      meta: `${group.length} file${group.length === 1 ? "" : "s"}`,
      depth: 0,
      kind: "folder",
      open: true,
      worktree: worktreeKey,
    });

    for (const target of group) {
      const normalizedPath = target.path.replace(/\\/g, "/");
      const segments = normalizedPath.split("/").filter(Boolean);
      let currentPath = "";
      segments.forEach((segment, index) => {
        currentPath = currentPath ? `${currentPath}/${segment}` : segment;
        const folderKey = `${worktreeKey}::${currentPath}`;
        const depth = index + 1;
        const isFile = index === segments.length - 1;
        if (isFile) {
          items.push({
            label: segment,
            meta: target.summary,
            depth,
            kind: "file",
            path: target.path,
            worktree: target.worktree,
            active: target.key === selectedEditorKey,
          });
          return;
        }

        if (seenFolders.has(folderKey)) {
          return;
        }

        seenFolders.add(folderKey);
        items.push({
          label: segment,
          depth,
          kind: "folder",
          open: true,
          worktree: target.worktree,
        });
      });
    }
  }

  return items;
}

function getEditorTargetForSourceChange(sourceChange: SourceChange | undefined): EditorTarget | null {
  if (!sourceChange) {
    return null;
  }

  return {
    key: getSourceChangeKey(sourceChange),
    path: sourceChange.path,
    summary: sourceChange.summary,
    worktree: sourceChange.worktree,
    origin: "context",
    modified: sourceChange.status !== "deleted",
    sourceChange,
  };
}

function getPreferredEditorTargetForSelectedRun(): EditorTarget | null {
  const runId = getSelectedRunId();
  if (!runId) {
    return null;
  }

  const runChanges = [
    ...getVisibleSourceChanges().filter((entry) => entry.run === runId),
    ...getProjectionSourceEntries().filter((entry) => entry.run === runId),
  ];
  const dedupedRunChanges = Array.from(
    new Map(runChanges.map((entry) => [getSourceChangeKey(entry), entry])).values(),
  );

  const selectedChange = dedupedRunChanges.find((entry) => getSourceChangeKey(entry) === selectedEditorKey);
  if (selectedChange) {
    return getEditorTargetForSourceChange(selectedChange);
  }

  if (dedupedRunChanges.length > 0) {
    return getEditorTargetForSourceChange(dedupedRunChanges[0]);
  }

  const projection = getRunProjectionByRunId(runId);
  const explainPayload = desktopExplainCache.get(runId) ?? null;
  const candidatePaths = [
    ...(explainPayload?.evidence_digest.changed_files ?? []),
    ...(projection?.changed_files ?? []),
    ...(explainPayload?.run.changed_files ?? []),
  ];
  const worktree = projection?.worktree || explainPayload?.run.worktree || "";

  for (const path of candidatePaths) {
    const existingChange = findSourceChangeByPath(path, worktree);
    if (existingChange) {
      return getEditorTargetForSourceChange(existingChange);
    }

    if (path) {
      const target = createStandaloneEditorTarget(path, worktree);
      desktopStandaloneEditorTargets.set(target.key, target);
      return target;
    }
  }

  return null;
}

function getEditorTargetByKey(key: string): EditorTarget | null {
  const sourceChange = findSourceChangeByKey(key);
  if (sourceChange) {
    return getEditorTargetForSourceChange(sourceChange);
  }

  return desktopStandaloneEditorTargets.get(key) ?? null;
}

function getPaneSourceFilter(label: string): SourceFilter {
  return `pane:${label}`;
}

function getPaneLabelFromSourceFilter(filter: SourceFilter) {
  if (!filter.startsWith("pane:")) {
    return null;
  }

  return filter.slice("pane:".length);
}

function getWorktreeLabel(worktree: string | undefined) {
  if (!worktree || worktree === "." || worktree === "./") {
    return "Project root";
  }

  const normalized = worktree.replace(/\\/g, "/").replace(/\/+$/, "");
  const segments = normalized.split("/").filter(Boolean);
  return segments[segments.length - 1] || normalized;
}

function renderExplorer() {
  const root = document.getElementById("explorer-list");
  if (!root) {
    return;
  }

  const explorerItems = getExplorerItems();
  root.innerHTML = "";
  if (explorerItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    empty.innerHTML =
      `<span class="sidebar-row-title">No projected files</span>` +
      `<span class="sidebar-row-meta">Changed files will appear here after the desktop summary refreshes.</span>`;
    root.appendChild(empty);
    return;
  }

  for (const item of explorerItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row sidebar-tree-row ${item.active ? "is-active" : ""}`;
    button.style.paddingLeft = `${12 + item.depth * 16}px`;
    button.innerHTML =
      `<span class="sidebar-row-title">${item.kind === "folder" ? (item.open ? "▾ " : "▸ ") : "• "}${item.label}</span>` +
      (item.meta ? `<span class="sidebar-row-meta">${item.meta}</span>` : "");
    if (item.kind === "file" && item.path) {
      const itemPath = item.path;
      const itemWorktree = item.worktree ?? "";
      button.addEventListener("click", () => {
        void openEditorPath(itemPath, itemWorktree);
      });
    }
    root.appendChild(button);
  }
}

function renderOpenEditors() {
  const root = document.getElementById("open-editors-list");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  const editors = getEditorFiles();
  if (editors.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar-row";
    empty.innerHTML = `<span class="sidebar-row-title">No changed files</span><span class="sidebar-row-meta">Connect the backend summary to inspect a real file preview.</span>`;
    root.appendChild(empty);
    return;
  }

  for (const editor of editors) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${editor.key === selectedEditorKey && editorSurfaceOpen ? "is-active" : ""}`;
    const target = getEditorTargetByKey(editor.key);
    const worktreeLabel = getWorktreeLabel(target?.worktree);
    button.innerHTML =
      `<span class="sidebar-row-title">${editor.path.split("/").pop() ?? editor.path}</span>` +
      `<span class="sidebar-row-meta">${worktreeLabel} · ${editor.summary}</span>`;
    button.addEventListener("click", () => {
      void openEditorTarget(getEditorTargetByKey(editor.key));
    });
    root.appendChild(button);
  }
}

function renderSourceSummary() {
  const root = document.getElementById("source-summary-list");
  if (!root) {
    return;
  }

  const activeEntries = getProjectionSourceEntries();
  const visibleChanges = getVisibleSourceChanges();
  const entryCount = visibleChanges.length;
  const attentionCount = visibleChanges.filter((item) => item.needsAttention).length;
  const commitCandidates = visibleChanges.filter((item) => item.commitCandidate).length;
  const summaryItems = [
    { label: "Selected scope", value: getSourceFilterLabel(activeSourceFilter) },
    { label: "Projected", value: `${activeEntries.length} files` },
    { label: "Changed", value: `${entryCount} files` },
    { label: "Ready", value: `${commitCandidates} candidate${commitCandidates === 1 ? "" : "s"}` },
    { label: "Risk", value: `${attentionCount} attention` },
  ];

  root.innerHTML = "";
  for (const item of summaryItems) {
    const row = document.createElement("div");
    row.className = "sidebar-summary-row";
    row.innerHTML = `<span class="sidebar-summary-label">${item.label}</span><span class="sidebar-summary-value">${item.value}</span>`;
    root.appendChild(row);
  }
}

function renderSourceEntries() {
  const root = document.getElementById("source-entry-list");
  if (!root) {
    return;
  }

  const activeEntries = getProjectionSourceEntries();
  root.innerHTML = "";
  const entryItems: Array<{ label: string; value: string; filter: SourceFilter; tone?: SurfaceTone }> = [
    { label: "Commit candidates", value: `${activeEntries.filter((item) => item.commitCandidate).length} ready`, tone: "success", filter: "candidates" },
    { label: "Needs attention", value: `${activeEntries.filter((item) => item.needsAttention).length} blocker`, tone: "danger", filter: "attention" },
  ];
  const paneLabels = [...new Set(activeEntries.map((item) => item.paneLabel).filter((item) => item))].sort((left, right) =>
    left.localeCompare(right),
  );
  for (const paneLabel of paneLabels) {
    entryItems.push({
      label: paneLabel,
      value: `${activeEntries.filter((item) => item.paneLabel === paneLabel).length} files`,
      filter: getPaneSourceFilter(paneLabel),
    });
  }

  for (const item of entryItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row source-entry-row ${activeSourceFilter === item.filter ? "is-active" : ""}`;
    button.dataset.tone = item.tone ?? "default";
    button.innerHTML = `<span class="sidebar-row-title">${item.label}</span><span class="sidebar-row-meta">${item.value}</span>`;
    button.addEventListener("click", () => {
      activeSourceFilter = item.filter;
      setContextPanel(true);
      const primaryChange = getPrimarySourceChange(getVisibleSourceChanges());
      setSelectedRun(primaryChange?.run ?? null);
      if (editorSurfaceOpen && primaryChange) {
        selectedEditorKey = getSourceChangeKey(primaryChange);
        renderEditorSurface();
        renderOpenEditors();
      }
      renderSourceSummary();
      renderSourceEntries();
      renderContextPanel();
      renderRunSummary();
    });
    root.appendChild(button);
  }
}

function getVisibleSourceChanges() {
  const activeEntries = getProjectionSourceEntries();
  switch (activeSourceFilter) {
    case "candidates":
      return activeEntries.filter((item) => item.commitCandidate);
    case "attention":
      return activeEntries.filter((item) => item.needsAttention);
    default:
      if (activeSourceFilter.startsWith("pane:")) {
        const paneLabel = getPaneLabelFromSourceFilter(activeSourceFilter);
        return activeEntries.filter((item) => item.paneLabel === paneLabel);
      }
      return activeEntries;
  }
}

function getPrimarySourceChange(changes: SourceChange[]) {
  return (
    changes.find((item) => item.run === selectedRunId) ??
    changes.find((item) => getSourceChangeKey(item) === selectedEditorKey) ??
    changes[0] ??
    getProjectionSourceEntries()[0]
  );
}

function stripAnsi(input: string) {
  return input.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "");
}

function extractPreviewUrls(data: string) {
  const matches = stripAnsi(data).match(/https?:\/\/(?:localhost|127\.0\.0\.1):\d+(?:\/[^\s"'<>)]*)?/gi);
  return matches ?? [];
}

function getPreviewPortLabel(url: string) {
  try {
    const parsed = new URL(url);
    return parsed.port ? `:${parsed.port}` : parsed.host;
  } catch {
    return url;
  }
}

function formatPreviewSeenAt(timestamp: number) {
  return new Date(timestamp).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function registerPreviewTargets(paneId: string, data: string) {
  let changed = false;
  const now = Date.now();
  for (const url of extractPreviewUrls(data)) {
    const existing = detectedPreviewTargets.get(url);
    if (existing) {
      if (existing.sourceLabel !== (paneId || "terminal") || now - existing.lastSeenAt >= PREVIEW_FRESHNESS_WINDOW_MS) {
        detectedPreviewTargets.set(url, {
          ...existing,
          sourceLabel: paneId || "terminal",
          lastSeenAt: now,
        });
        changed = true;
      }
      continue;
    }
    detectedPreviewTargets.set(url, {
      url,
      portLabel: getPreviewPortLabel(url),
      sourceLabel: paneId || "terminal",
      lastSeenAt: now,
    });
    changed = true;
  }

  if (changed) {
    renderContextPanel();
    renderEditorSurface();
  }
}

function registerPreviewTargetForHarness(sourceLabel: string, url: string) {
  detectedPreviewTargets.set(url, {
    url,
    portLabel: getPreviewPortLabel(url),
    sourceLabel: sourceLabel || "viewport-harness",
    lastSeenAt: Date.now(),
  });
  renderContextPanel();
  renderEditorSurface();
}

function openEditorPreviewForHarness(path: string, content: string, worktree = "") {
  restoreStandaloneEditorFromSnapshot({
    mode: "editor",
    path,
    worktree,
    summary: `Project file preview · ${path.split("/").pop() ?? path}`,
    origin: "explorer",
    modified: false,
    sourceChange: null,
    content,
  });
}

function restoreStandaloneEditorFromSnapshot(state: Extract<PopoutSurfaceState, { mode: "editor" }> & { content: string }) {
  const target: EditorTarget = {
    key: getEditorFileKey(state.path, state.worktree),
    path: state.path,
    summary: state.summary,
    worktree: state.worktree,
    origin: state.origin,
    modified: state.modified,
    sourceChange: state.sourceChange ?? undefined,
  };
  desktopStandaloneEditorTargets.set(target.key, target);
  desktopEditorFileCache.set(target.key, {
    key: target.key,
    path: state.path,
    summary: state.summary,
    content: state.content,
    language: inferLanguageFromPath(state.path),
    lineCount: countEditorLines(state.content),
    modified: state.modified,
    origin: state.origin,
  });
  desktopEditorLoadErrors.delete(target.key);
  desktopEditorLoadingPaths.delete(target.key);
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  lastPreviewClipboardState = null;
  selectedEditorKey = target.key;
  setSelectedRun(target.sourceChange?.run ?? selectedRunId);
  setEditorSurface(true);
  renderOpenEditors();
  renderSourceSummary();
  renderRunSummary();
}

function getCurrentEditorSurfaceState(): PopoutSurfaceState | null {
  const selectedProjection = getPrimaryRunProjection();
  const runId = selectedProjection?.run_id || undefined;
  const runLabel = selectedProjection?.label || selectedProjection?.run_id || undefined;
  const previewTarget = selectedPreviewUrl ? detectedPreviewTargets.get(selectedPreviewUrl) ?? null : null;
  if (editorSurfaceMode === "preview" && previewTarget) {
    return {
      mode: "preview",
      url: previewTarget.url,
      portLabel: previewTarget.portLabel,
      sourceLabel: previewTarget.sourceLabel,
      lastSeenAt: previewTarget.lastSeenAt,
      runId,
      runLabel,
    };
  }

  const editors = getEditorFiles();
  const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
  if (!selected) {
    return null;
  }

  const selectedTarget = getEditorTargetByKey(selected.key);
  return {
    mode: "editor",
    path: selected.path,
    worktree: selectedTarget?.worktree ?? "",
    summary: selected.summary,
    origin: selected.origin,
    modified: Boolean(selected.modified),
    sourceChange: selectedTarget?.sourceChange ?? null,
    content: isTauri() ? undefined : selected.content,
    runId,
    runLabel,
  };
}

function readPopoutSurfaceState() {
  const searchParams = new URLSearchParams(window.location.search);
  if (searchParams.get("popout") !== "1") {
    return null;
  }

  const key = searchParams.get("popout-key");
  if (!key) {
    return null;
  }

  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) {
      return null;
    }
    window.localStorage.removeItem(key);
    return JSON.parse(raw) as PopoutSurfaceState;
  } catch {
    return null;
  }
}

function describeDetachedSurfaceSession(state: PopoutSurfaceState): DetachedSurfaceSessionState {
  if (state.mode === "preview") {
    return {
      name: "detached-preview",
      meta: `${state.portLabel} · ${state.sourceLabel}${state.runLabel ? ` · ${state.runLabel}` : ""}`,
    };
  }

  const fileLabel = state.path.split("/").pop() ?? state.path;
  const worktreeLabel = state.worktree ? getWorktreeLabel(state.worktree) : "Project root";
  return {
    name: "detached-editor",
    meta: `${fileLabel} · ${worktreeLabel}${state.runLabel ? ` · ${state.runLabel}` : ""}`,
  };
}

function clearDetachedSurfaceSession() {
  detachedSurfaceSession = null;
  if (detachedSurfacePollTimer !== null) {
    window.clearInterval(detachedSurfacePollTimer);
    detachedSurfacePollTimer = null;
  }
  renderSessions();
}

function setDetachedSurfaceSession(state: PopoutSurfaceState) {
  detachedSurfaceSession = describeDetachedSurfaceSession(state);
  renderSessions();
}

function applyPopoutSurfaceState(state: PopoutSurfaceState | null) {
  if (!state) {
    return;
  }

  document.body.dataset.popoutSurface = "1";
  detachedSurfaceRunLabel = state.runLabel ?? state.runId ?? "";
  const title = document.getElementById("workspace-title");
  const subtitle = document.getElementById("workspace-subtitle");
  const editorLabel = state.mode === "editor" ? state.path.split("/").pop() ?? state.path : "";
  const editorWorktreeLabel = state.mode === "editor" && state.worktree ? getWorktreeLabel(state.worktree) : "Project root";
  if (title) {
    title.textContent =
      state.mode === "preview"
        ? `${state.portLabel} preview`
        : `${editorLabel} editor`;
  }
  if (subtitle) {
    subtitle.textContent =
      state.mode === "preview"
        ? `Detached secondary surface from ${state.sourceLabel}${detachedSurfaceRunLabel ? ` · ${detachedSurfaceRunLabel}` : ""}.`
        : `Detached secondary surface for ${editorWorktreeLabel}${detachedSurfaceRunLabel ? ` · ${detachedSurfaceRunLabel}` : ""}.`;
  }

  setSidebarOpen(false, { preserveWidePreference: false });
  setContextPanel(false, { preserveWidePreference: false });
  setTerminalDrawer(false);
  setSettingsSheet(false);
  closeCommandBar();

  if (state.mode === "preview") {
    setSelectedRun(state.runId ?? null);
    registerPreviewTargetForHarness(state.sourceLabel, state.url);
    const target = detectedPreviewTargets.get(state.url);
    if (target) {
      target.portLabel = state.portLabel || target.portLabel;
      target.lastSeenAt = state.lastSeenAt || target.lastSeenAt;
    }
    openPreviewTarget(state.url);
    return;
  }

  if (typeof state.content === "string") {
    setSelectedRun(state.runId ?? null);
    restoreStandaloneEditorFromSnapshot({ ...state, content: state.content });
    return;
  }

  setSelectedRun(state.runId ?? null);
  void openEditorPath(state.path, state.worktree);
}

function getPreviewTargets(activeUrl = selectedPreviewUrl) {
  return Array.from(detectedPreviewTargets.values()).sort((left, right) => {
    if (activeUrl) {
      if (left.url === activeUrl && right.url !== activeUrl) {
        return -1;
      }
      if (right.url === activeUrl && left.url !== activeUrl) {
        return 1;
      }
    }
    if (left.lastSeenAt !== right.lastSeenAt) {
      return right.lastSeenAt - left.lastSeenAt;
    }
    return left.url.localeCompare(right.url);
  });
}

function openPreviewTarget(url: string) {
  selectedPreviewUrl = url;
  editorSurfaceMode = "preview";
  if (lastPreviewExternalState?.url !== url) {
    lastPreviewExternalState = null;
  }
  if (lastPreviewClipboardState?.url !== url) {
    lastPreviewClipboardState = null;
  }
  setEditorSurface(true);
}

function closePreviewTarget() {
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  lastPreviewClipboardState = null;
  if (!selectedEditorKey) {
    setEditorSurface(false);
    return;
  }
  setEditorSurface(true);
}

function reloadPreviewTarget() {
  if (!selectedPreviewUrl) {
    return;
  }
  const browserFrame = document.getElementById("browser-frame") as HTMLIFrameElement | null;
  if (!browserFrame) {
    return;
  }
  browserFrame.src = selectedPreviewUrl;
}

function openPreviewTargetExternally() {
  if (!selectedPreviewUrl) {
    return;
  }
  const previewUrl = selectedPreviewUrl;
  const opened = window.open(previewUrl, "_blank", "noopener");
  lastPreviewExternalState = {
    url: previewUrl,
    at: Date.now(),
    ok: Boolean(opened),
  };
  renderEditorSurface();
  if (!opened) {
    return;
  }
}

async function copyPreviewTargetUrl() {
  if (!selectedPreviewUrl || !navigator.clipboard) {
    return;
  }
  const previewUrl = selectedPreviewUrl;
  try {
    await navigator.clipboard.writeText(previewUrl);
    lastPreviewClipboardState = {
      url: previewUrl,
      at: Date.now(),
      ok: true,
    };
  } catch {
    lastPreviewClipboardState = {
      url: previewUrl,
      at: Date.now(),
      ok: false,
    };
  }
  renderEditorSurface();
}

async function openEditorSurfacePopout() {
  const state = getCurrentEditorSurfaceState();
  if (!state) {
    return;
  }

  const key = `${POPOUT_SURFACE_STORAGE_KEY_PREFIX}${Date.now()}`;
  try {
    window.localStorage.setItem(key, JSON.stringify(state));
  } catch {
    return;
  }

  const popoutUrl = `/?popout=1&popout-key=${encodeURIComponent(key)}`;
  if (isTauri()) {
    const label = `secondary-surface-${Date.now()}`;
    const detachedWindow = new WebviewWindow(label, {
      url: popoutUrl,
      title: state.mode === "preview" ? "winsmux Preview" : "winsmux Editor",
      width: state.mode === "preview" ? 1180 : 1040,
      height: 760,
      minWidth: 720,
      minHeight: 480,
      focus: true,
    });
    setDetachedSurfaceSession(state);
    void detachedWindow.once("tauri://destroyed", () => {
      clearDetachedSurfaceSession();
    });
    return;
  }

  const popup = window.open(popoutUrl, "_blank");
  if (!popup) {
    return;
  }
  setDetachedSurfaceSession(state);
  if (detachedSurfacePollTimer !== null) {
    window.clearInterval(detachedSurfacePollTimer);
  }
  detachedSurfacePollTimer = window.setInterval(() => {
    if (popup.closed) {
      clearDetachedSurfaceSession();
    }
  }, 500);
}

function getSourceFilterLabel(filter: SourceFilter) {
  switch (filter) {
    case "all":
      return "All changes";
    case "candidates":
      return "Commit candidates";
    case "attention":
      return "Needs attention";
    default:
      return getPaneLabelFromSourceFilter(filter) ?? filter;
  }
}

function getSelectedRunId() {
  return resolveSelectedRunId();
}

function renderExperimentContext() {
  const overviewRoot = document.getElementById("experiment-overview-cards");
  const detailRoot = document.getElementById("experiment-detail-list");
  if (!overviewRoot || !detailRoot) {
    return;
  }

  overviewRoot.innerHTML = "";
  detailRoot.innerHTML = "";

  const selectedProjection = getPrimaryRunProjection();
  if (!selectedProjection) {
    const empty = document.createElement("div");
    empty.className = "experiment-detail-card";
    empty.dataset.tone = "info";
    empty.innerHTML =
      `<div class="experiment-detail-title">No experiment run</div>` +
      `<div class="experiment-detail-body">Select a run to inspect observation, compare, and playbook context.</div>`;
    detailRoot.appendChild(empty);
    return;
  }

  const payload = desktopExplainCache.get(selectedProjection.run_id) ?? null;
  if (!payload) {
    const empty = document.createElement("div");
    empty.className = "experiment-detail-card";
    empty.dataset.tone = "info";
    empty.innerHTML =
      `<div class="experiment-detail-title">Explain not loaded</div>` +
      `<div class="experiment-detail-body">Open Explain to load experiment context for the selected run.</div>`;
    detailRoot.appendChild(empty);
    return;
  }

  const observationPack = getObservationPack(payload);
  const consultationPacket = getConsultationPacket(payload);
  const consultationSummary = getConsultationSummary(payload);
  const experimentPacket = payload.run.experiment_packet;
  const explainFingerprint = getExplainPayloadFingerprint(payload);
  const promotedCandidate = promotedRunCandidates.get(selectedProjection.run_id) ?? null;
  const hasPromotedCandidate =
    promotedCandidate !== null &&
    promotedCandidate.fingerprint === explainFingerprint;
  const isPromotedCandidate = hasPromotedCandidate &&
    promotedCandidate !== null &&
    desktopSummaryRefreshSerial <= promotedCandidate.collapseAfterRefreshSerial;
  const showLastExport = hasPromotedCandidate && !isPromotedCandidate;
  const promotedCandidateRef = hasPromotedCandidate && promotedCandidate
    ? summarizeArtifactRef(promotedCandidate.candidateRef)
    : "";
  const comparePeer = getComparePeerProjection(
    selectedProjection,
    payload.run.parent_run_id || null,
  );
  const comparePairKey = comparePeer
    ? getComparePairKey(selectedProjection.run_id, comparePeer.run_id)
    : "";
  const compareResult = comparePairKey
    ? desktopRunCompareCache.get(comparePairKey) ?? null
    : null;
  const compareInFlight = comparePairKey
    ? comparingRunPairKeys.has(comparePairKey)
    : false;
  const compareWinnerRunId = compareResult?.recommend.winning_run_id || null;
  const compareWinnerProjection = compareWinnerRunId
    ? getRunProjectionByRunId(compareWinnerRunId)
    : null;
  const compareLeftProjection = compareResult
    ? (getRunProjectionByRunId(compareResult.left.run_id) ?? selectedProjection)
    : selectedProjection;
  const compareRightProjection = compareResult
    ? (getRunProjectionByRunId(compareResult.right.run_id) ?? comparePeer)
    : comparePeer;
  const compareWinnerConfidence = compareResult
    ? (
      compareResult.left.run_id === compareWinnerRunId
        ? (compareResult.left.confidence ?? null)
        : (
          compareResult.right.run_id === compareWinnerRunId
            ? (compareResult.right.confidence ?? null)
            : null
        )
    )
    : null;
  const compareLoserSlot = compareResult
    ? (
      compareResult.left.run_id === compareWinnerRunId
        ? (compareRightProjection?.label || compareResult.right.label || compareResult.right.run_id)
        : (compareLeftProjection?.label || compareResult.left.label || compareResult.left.run_id)
    )
    : "";
  const canPickCompareWinner = Boolean(
    compareResult &&
    !compareResult.recommend.reconcile_consult &&
    compareWinnerProjection,
  );
  const persistedCompareTargetMatchesPeer = Boolean(
    comparePeer &&
    consultationPacket.target_slot &&
    consultationPacket.target_slot === (comparePeer.label || comparePeer.run_id),
  );
  const hasPersistedCompareWinner =
    !compareResult &&
    consultationPacket.kind === "consult_result" &&
    consultationPacket.mode === "final" &&
    persistedCompareTargetMatchesPeer;
  const compareWinnerLabel = compareResult
    ? getCompareWinnerLabel(compareResult)
    : "";
  const compareDifferenceSummary = compareResult
    ? summarizeCompareDifferenceFields(compareResult)
    : "";
  const compareConflictRadar = compareResult
    ? getCompareConflictRadar(compareResult)
    : null;
  const compareFileSummary = compareResult
    ? [
        compareResult.shared_changed_files.length > 0
          ? `shared ${summarizeChangedFiles(compareResult.shared_changed_files, 2)}`
          : "",
        compareResult.left_only_changed_files.length > 0
          ? `${compareResult.left.label || "left"} ${summarizeChangedFiles(compareResult.left_only_changed_files, 2)}`
          : "",
        compareResult.right_only_changed_files.length > 0
          ? `${compareResult.right.label || "right"} ${summarizeChangedFiles(compareResult.right_only_changed_files, 2)}`
          : "",
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
    : "";
  const compareTone: SurfaceTone = compareResult
    ? (
      compareConflictRadar?.level === "high"
        ? "danger"
        : (
          compareConflictRadar?.level === "medium"
            ? "warning"
            : (compareWinnerLabel ? "success" : "info")
        )
    )
    : hasPersistedCompareWinner
      ? "success"
    : "info";
  const compareBody = compareResult
    ? [
        compareResult.recommend.reconcile_consult
          ? "Reconcile consult"
          : `Winner ${compareWinnerLabel || "not decided"}`,
        compareResult.recommend.next_action || "reconcile_consult",
        [
          compareConflictRadar?.summary || "",
          compareDifferenceSummary,
          compareFileSummary,
        ]
          .filter((value) => Boolean(value))
          .join(" · ") || "No material diff",
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
      : comparePeer
      ? (
        hasPersistedCompareWinner
          ? [
              "Winner selected",
              consultationPacket.recommendation || selectedProjection.label || selectedProjection.run_id,
              consultationPacket.target_slot ? `vs ${consultationPacket.target_slot}` : "",
              consultationPacket.next_test || "winner persisted",
            ]
              .filter((value) => Boolean(value))
              .join(" · ")
          : [
          `vs ${comparePeer.label || comparePeer.run_id}`,
          comparePeer.branch || "no branch",
          comparePeer.review_state || "pending",
        ]
              .filter((value) => Boolean(value))
              .join(" · ")
      )
      : "Compare needs another surfaced run.";
  const compareOverviewValue = compareInFlight
    ? "Refreshing compare"
    : (
      compareResult
        ? (
          compareResult.recommend.reconcile_consult
            ? "Consult before pick"
            : `Winner ${compareWinnerLabel || "not decided"}`
        )
        : (
          hasPersistedCompareWinner
            ? "Winner selected"
        : (comparePeer ? `vs ${comparePeer.label || comparePeer.run_id}` : "Need peer")
        )
    );
  const compareDisplayBody = compareInFlight
    ? `Refreshing compare result${compareResult ? "..." : " from current runs..." }`
    : compareBody;
  const compareCandidateSummary = compareResult
    ? [
        compareWinnerLabel ? `winner ${compareWinnerLabel}` : "",
        compareConflictRadar?.summary || "",
        `diffs ${compareResult.differences.length}`,
      ]
        .filter((value) => Boolean(value))
        .join(" · ")
    : "";
  const canPromoteCandidate =
    isDesktopRunPromotable(payload.run) &&
    !promotingRunIds.has(selectedProjection.run_id) &&
    !pendingPromotedRunRefreshIds.has(selectedProjection.run_id) &&
    !isPromotedCandidate;

  const overviewCards = [
    {
      label: "Hypothesis",
      value: experimentPacket.hypothesis || selectedProjection.hypothesis || "No hypothesis",
    },
    {
      label: "Observe",
      value: observationPack.changed_files.length > 0
        ? `${observationPack.changed_files.length} files`
        : (observationPack.working_tree_summary || "No observation pack"),
    },
    {
      label: "Consult",
      value: consultationSummary.next_test || consultationPacket.recommendation || "No consult",
    },
    {
      label: "Compare",
      value: compareOverviewValue,
    },
    {
      label: "Candidate",
      value: isPromotedCandidate
        ? "Exported"
        : (experimentPacket.next_action || payload.explanation.next_action || "No candidate"),
    },
  ];

  for (const item of overviewCards) {
    const card = document.createElement("div");
    card.className = "source-overview-card";
    card.innerHTML = `<div class="context-label">${item.label}</div><div class="source-overview-value">${item.value}</div>`;
    overviewRoot.appendChild(card);
  }

  const experimentCards = [
    {
      title: "Observation Pack",
      body:
        observationPack.working_tree_summary ||
        observationPack.failing_command ||
        "Observation details will appear after the selected run emits an observation pack.",
      tone: "focus" as SurfaceTone,
      details: [
        { label: "files", value: `${observationPack.changed_files.length}` },
        { label: "test", value: observationPack.test_plan[0] || "n/a" },
        { label: "slot", value: observationPack.slot || "n/a" },
      ],
    },
    {
      title: "Compare",
      body: compareDisplayBody,
      tone: compareTone,
      actionLabel: comparePeer ? "Compare" : undefined,
      actionPendingLabel: "Comparing...",
      actionDisabled: compareInFlight,
      actionType: "compare" as const,
      actionRunId: selectedProjection.run_id,
      actionPeerRunId: comparePeer?.run_id,
      secondaryActionLabel: canPickCompareWinner ? "Pick winner" : undefined,
      secondaryActionType: "pick_winner" as const,
      secondaryActionRunId: compareWinnerProjection?.run_id,
      secondaryActionPeerSlot: compareLoserSlot || undefined,
      secondaryActionPeerRunId: compareResult
        ? (
          compareResult.left.run_id === compareWinnerRunId
            ? compareResult.right.run_id
            : compareResult.left.run_id
        )
        : undefined,
      secondaryActionRecommendation: compareResult
        ? `Pick ${compareWinnerLabel || compareWinnerProjection?.label || compareWinnerProjection?.run_id || "winner"}`
        : undefined,
      secondaryActionConfidence: compareWinnerConfidence,
      secondaryActionNextTest: compareResult?.recommend.next_action || undefined,
      secondaryActionDisabled: compareWinnerRunId ? pickingWinnerRunIds.has(compareWinnerRunId) : false,
      secondaryActionPendingLabel: "Picking...",
      details: compareResult
        ? [
            {
              label: "peer",
              value: comparePeer?.label || compareResult.right.label || compareResult.right.run_id,
            },
            { label: "winner", value: compareWinnerLabel || "none" },
            {
              label: "risk",
              value: compareConflictRadar?.label || "n/a",
              tone: compareConflictRadar?.tone,
            },
            {
              label: "hotspots",
              value: `${compareConflictRadar?.hotspots.length ?? 0}`,
              tone: compareConflictRadar?.tone,
            },
            { label: "diffs", value: `${compareResult.differences.length}` },
            {
              label: "delta",
              value: compareResult.confidence_delta !== null
                ? formatConfidencePercent(Math.abs(compareResult.confidence_delta))
                : "n/a",
            },
            { label: "shared", value: `${compareResult.shared_changed_files.length}` },
            { label: "left", value: `${compareResult.left_only_changed_files.length}` },
            { label: "right", value: `${compareResult.right_only_changed_files.length}` },
          ]
        : hasPersistedCompareWinner
          ? [
              { label: "winner", value: selectedProjection.label || selectedProjection.run_id },
              { label: "target", value: consultationPacket.target_slot || "n/a" },
              { label: "next", value: consultationPacket.next_test || "n/a" },
            ]
        : [
            { label: "peer", value: comparePeer?.label || "n/a" },
            { label: "changed", value: `${payload.evidence_digest.changed_file_count}` },
            { label: "verify", value: payload.evidence_digest.verification_outcome || "n/a" },
          ],
      lines: compareResult
        ? [
            {
              label: "Selected run",
              value: [
                compareResult.left.branch || compareLeftProjection?.branch || "no branch",
                compareLeftProjection?.head_short || "",
                compareResult.left.review_state || compareResult.left.state,
                compareResult.left.next_action || "idle",
              ]
                .filter((value) => Boolean(value))
                .join(" · "),
            },
            {
              label: "Peer run",
              value: [
                compareResult.right.branch || compareRightProjection?.branch || "no branch",
                compareRightProjection?.head_short || "",
                compareResult.right.review_state || compareResult.right.state,
                compareResult.right.next_action || "idle",
              ]
                .filter((value) => Boolean(value))
                .join(" · "),
            },
            {
              label: "Decision",
              value: compareResult.recommend.reconcile_consult
                ? "consult before pick"
                : [
                  compareWinnerLabel || "no winner",
                  compareResult.confidence_delta !== null
                    ? formatConfidencePercent(Math.abs(compareResult.confidence_delta))
                    : "",
                ]
                  .filter((value) => Boolean(value))
                  .join(" · "),
            },
            {
              label: "Decision basis",
              value: [
                compareDifferenceSummary,
                compareFileSummary,
              ]
                .filter((value) => Boolean(value))
                .join(" · ") || "none",
            },
            {
              label: "Recommendation",
              value: compareResult.recommend.next_action || "reconcile_consult",
            },
            {
              label: "Difference fields",
              value: compareDifferenceSummary || "none",
            },
            {
              label: "Conflict radar",
              value: compareConflictRadar?.summary || "low risk · no shared files",
            },
            buildExperimentFileLine(
              "Hotspot files",
              compareResult.shared_changed_files,
              compareLeftProjection?.worktree || selectedProjection.worktree || "",
            ),
            buildExperimentFileLine(
              `${selectedProjection.label || "Selected"} only`,
              compareResult.left_only_changed_files,
              compareLeftProjection?.worktree || selectedProjection.worktree || "",
            ),
            buildExperimentFileLine(
              `${comparePeer?.label || compareResult.right.label || "Peer"} only`,
              compareResult.right_only_changed_files,
              compareRightProjection?.worktree || comparePeer?.worktree || "",
            ),
          ]
        : [],
    },
    {
      title: "Playbook Candidate",
      body: isPromotedCandidate
        ? `Exported as ${promotedCandidateRef}.`
        : [
          consultationPacket.recommendation ||
            experimentPacket.result ||
            experimentPacket.next_action ||
            "No playbook candidate is ready yet.",
          compareCandidateSummary,
        ]
          .filter((value) => Boolean(value))
          .join(" · "),
      tone: "success" as SurfaceTone,
      actionLabel: canPromoteCandidate ? "Promote" : undefined,
      actionPendingLabel: "Promoting...",
      actionDisabled:
        promotingRunIds.has(selectedProjection.run_id) ||
        pendingPromotedRunRefreshIds.has(selectedProjection.run_id),
      actionType: "promote" as const,
      actionRunId: selectedProjection.run_id,
      details: [
        ...(isPromotedCandidate
          ? [{ label: "exported", value: promotedCandidateRef }]
          : (showLastExport
            ? [{ label: "last export", value: promotedCandidateRef }]
            : [])),
        { label: "next", value: experimentPacket.next_action || "n/a" },
        { label: "consult", value: consultationSummary.next_test || "n/a" },
        { label: "confidence", value: formatConfidencePercent(experimentPacket.confidence || 0) },
      ],
    },
  ];

  for (const item of experimentCards) {
    const card = document.createElement("div");
    card.className = "experiment-detail-card";
    card.dataset.tone = item.tone;
    card.innerHTML =
      `<div class="experiment-detail-title">${item.title}</div>` +
      `<div class="experiment-detail-body">${item.body}</div>`;

    const meta = document.createElement("div");
    meta.className = "experiment-detail-meta";
    for (const detail of item.details) {
      const pill = document.createElement("span");
      pill.className = "experiment-detail-pill";
      if ("tone" in detail && detail.tone) {
        pill.dataset.tone = detail.tone;
      }
      pill.innerHTML = `<span class="experiment-detail-pill-label">${detail.label}</span><span>${detail.value}</span>`;
      meta.appendChild(pill);
    }
    card.appendChild(meta);

    if (item.lines && item.lines.length > 0) {
      const lineList = document.createElement("div");
      lineList.className = "experiment-detail-lines";
      for (const line of item.lines as ExperimentDetailLine[]) {
        const row = document.createElement("div");
        row.className = "experiment-detail-line";
        row.innerHTML =
          `<span class="experiment-detail-line-label">${line.label}</span>` +
          `<span class="experiment-detail-line-value">${line.value}</span>`;
        if (line.path) {
          row.classList.add("is-actionable");
          row.tabIndex = 0;
          row.setAttribute("role", "button");
          if (line.title) {
            row.title = line.title;
          }
          row.addEventListener("click", () => {
            void openEditorPath(line.path, line.worktree || "");
          });
          row.addEventListener("keydown", (event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              void openEditorPath(line.path, line.worktree || "");
            }
          });
        }
        lineList.appendChild(row);
      }
      card.appendChild(lineList);
    }

    if ((item.actionLabel || item.secondaryActionLabel) && selectedProjection.run_id) {
      const chipRow = document.createElement("div");
      chipRow.className = "timeline-chip-row";
      const appendActionButton = (
        label: string,
        type: "compare" | "promote" | "focus" | "pick_winner",
        runId: string,
        disabled?: boolean,
        pendingLabel?: string,
        peerRunId?: string,
        peerSlot?: string,
        recommendation?: string,
        confidence?: number | null,
        nextTest?: string,
      ) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "timeline-chip";
        button.textContent = disabled && pendingLabel ? pendingLabel : label;
        button.disabled = disabled ?? false;
        button.addEventListener("click", async () => {
          if (type === "compare" && peerRunId) {
            await compareSelectedRunWithPeer(runId, peerRunId);
            return;
          }
          if (type === "focus") {
            await focusRunInContext(runId);
            return;
          }
          if (type === "pick_winner") {
            await pickCompareWinner(
              runId,
              peerRunId || "",
              peerSlot || "",
              recommendation || "",
              confidence ?? null,
              nextTest || "",
            );
            return;
          }
          await promoteSelectedRunTactic(runId);
        });
        chipRow.appendChild(button);
      };

      if (item.actionLabel) {
        appendActionButton(
          item.actionLabel,
          item.actionType,
          item.actionRunId ?? selectedProjection.run_id,
          item.actionDisabled,
          item.actionPendingLabel,
          item.actionPeerRunId,
        );
      }
      if (item.secondaryActionLabel && item.secondaryActionType && item.secondaryActionRunId) {
        appendActionButton(
          item.secondaryActionLabel,
          item.secondaryActionType,
          item.secondaryActionRunId,
          item.secondaryActionDisabled,
          item.secondaryActionPendingLabel,
          item.secondaryActionPeerRunId,
          item.secondaryActionPeerSlot,
          item.secondaryActionRecommendation,
          item.secondaryActionConfidence,
          item.secondaryActionNextTest,
        );
      }
      card.appendChild(chipRow);
    }
    detailRoot.appendChild(card);
  }
}

function renderContextPanel() {
  const sectionRoot = document.getElementById("context-sections");
  const previewRoot = document.getElementById("preview-target-list");
  const overviewRoot = document.getElementById("source-overview-cards");
  const fileRoot = document.getElementById("context-file-list");
  if (!sectionRoot || !previewRoot || !overviewRoot || !fileRoot) {
    return;
  }

  const visibleChanges = getVisibleSourceChanges();
  const primaryChange = getPrimarySourceChange(visibleChanges);
  const selectedProjection = getPrimaryRunProjection();

  sectionRoot.innerHTML = "";
  const resolvedContextSections = [
    { label: "next", value: selectedProjection?.next_action || "Open Explain" },
    { label: "run", value: selectedProjection?.run_id || primaryChange?.run || "No active run" },
    { label: "pane", value: primaryChange?.paneLabel ?? "No pane label" },
    { label: "branch", value: selectedProjection?.branch || primaryChange?.branch || "No branch" },
    { label: "worktree", value: selectedProjection?.worktree || primaryChange?.worktree || "Project root" },
    { label: "review", value: selectedProjection?.review_state || primaryChange?.review || "No review state" },
  ];
  for (const item of resolvedContextSections) {
    const row = document.createElement("div");
    row.className = "context-section";
    row.innerHTML = `<div class="context-label">${item.label}</div><div class="context-value">${item.value}</div>`;
    sectionRoot.appendChild(row);
  }

  renderExperimentContext();

  previewRoot.innerHTML = "";
  const previewTargets = getPreviewTargets();
  if (previewTargets.length === 0) {
    const empty = document.createElement("div");
    empty.className = "context-empty-state";
    empty.innerHTML =
      `<div class="context-label">No detected ports</div>` +
      `<div class="context-value">Run a localhost dev server in the utility terminal to surface a preview target.</div>`;
    previewRoot.appendChild(empty);
  } else {
    for (const target of previewTargets) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `context-file-row ${editorSurfaceOpen && editorSurfaceMode === "preview" && selectedPreviewUrl === target.url ? "is-active" : ""}`;
      button.dataset.tone = "info";
      const name = document.createElement("span");
      name.className = "context-file-name";
      name.textContent = target.url;
      const metaLine = document.createElement("span");
      metaLine.className = "context-file-meta";
      metaLine.textContent = `Preview target · ${target.portLabel} · Seen ${formatPreviewSeenAt(target.lastSeenAt)}`;
      const trace = document.createElement("span");
      trace.className = "context-file-trace";
      trace.textContent = `Detected from ${target.sourceLabel}`;
      button.appendChild(name);
      button.appendChild(metaLine);
      button.appendChild(trace);
      button.addEventListener("click", () => {
        openPreviewTarget(target.url);
      });
      previewRoot.appendChild(button);
    }
  }

  overviewRoot.innerHTML = "";
  const overviewCards = [
    { label: "Selected scope", value: getSourceFilterLabel(activeSourceFilter) },
    { label: "Commit candidates", value: `${visibleChanges.filter((item) => item.commitCandidate).length}` },
    { label: "Needs attention", value: `${visibleChanges.filter((item) => item.needsAttention).length}` },
    { label: "Active pane", value: primaryChange?.paneLabel ?? "n/a" },
    { label: "Worktree", value: primaryChange?.worktree || "Project root" },
  ];

  for (const item of overviewCards) {
    const card = document.createElement("div");
    card.className = "source-overview-card";
    card.innerHTML = `<div class="context-label">${item.label}</div><div class="source-overview-value">${item.value}</div>`;
    overviewRoot.appendChild(card);
  }

  fileRoot.innerHTML = "";
  for (const change of visibleChanges) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `context-file-row ${getSourceChangeKey(change) === selectedEditorKey && editorSurfaceOpen ? "is-active" : ""}`;
    button.dataset.tone = getSourceEntryTone(change);
    button.innerHTML =
      `<span class="context-file-name">${change.path.split("/").pop() ?? change.path}</span>` +
      `<span class="context-file-meta">${change.summary}</span>` +
      `<span class="context-file-trace">${change.status} · ${change.lines} · ${change.branch} · ${change.review}${change.worktree ? ` · ${change.worktree}` : ""}</span>`;
    button.addEventListener("click", () => {
      setSelectedRun(change.run);
      void openEditorSourceChange(change);
    });
    fileRoot.appendChild(button);
  }

  renderComposerRemoteReferences();
}

function getSourceEntryTone(entry: SourceChange): SurfaceTone {
  if (entry.needsAttention || entry.risk === "high") {
    return "danger";
  }
  if (entry.commitCandidate) {
    return "success";
  }
  if (entry.risk === "medium") {
    return "warning";
  }
  return "info";
}

function getFooterReviewTone(reviewState: string | undefined): SurfaceTone {
  switch ((reviewState || "").toUpperCase()) {
    case "PASS":
      return "success";
    case "PENDING":
      return "warning";
    case "FAIL":
    case "FAILED":
      return "danger";
    default:
      return "info";
  }
}

function getFooterNextTone(nextAction: string | undefined): SurfaceTone {
  switch ((nextAction || "").toLowerCase()) {
    case "blocked":
    case "reconcile_consult":
      return "warning";
    case "review":
    case "dispatch":
      return "focus";
    default:
      return "info";
  }
}

function getFooterSurfaceStatus() {
  if (commandBarOpen) {
    return "Command";
  }
  if (settingsSheetOpen) {
    return "Settings";
  }
  if (selectedPreviewUrl) {
    return "Preview";
  }
  if (editorSurfaceOpen) {
    return "Code";
  }
  if (terminalDrawerOpen) {
    return "Terminal";
  }
  return "Shell";
}

function getFooterOperatorStatus(projection: DesktopRunProjection | undefined) {
  if (!projection) {
    return {
      label: desktopSummarySnapshot ? "Monitoring" : "Ready",
      tone: desktopSummarySnapshot ? "info" as SurfaceTone : "success" as SurfaceTone,
    };
  }

  const taskState = (projection.task_state || "").toLowerCase();
  if (taskState === "blocked") {
    return { label: "Blocked", tone: "danger" as SurfaceTone };
  }
  if (taskState === "commit_ready") {
    return { label: "Commit ready", tone: "success" as SurfaceTone };
  }
  if (taskState === "completed" || taskState === "task_completed" || taskState === "done") {
    return { label: "Completed", tone: "success" as SurfaceTone };
  }
  if (projection.verification_outcome) {
    return {
      label: `Verify ${projection.verification_outcome}`,
      tone: projection.verification_outcome.toUpperCase() === "PASS" ? "success" as SurfaceTone : "warning" as SurfaceTone,
    };
  }
  if (projection.next_action) {
    return {
      label: projection.next_action,
      tone: getFooterNextTone(projection.next_action),
    };
  }
  return {
    label: projection.task_state || "Tracking",
    tone: "info" as SurfaceTone,
  };
}

function getFooterSettingsTone(status: string): SurfaceTone {
  switch (status) {
    case "Draft":
      return "warning";
    case "Editing":
      return "info";
    case "Ready":
      return "focus";
    case "Saved":
      return "success";
    default:
      return "accent";
  }
}

function getFooterInboxTone(count: number): SurfaceTone {
  if (count > 0) {
    return "warning";
  }
  return "success";
}

function getFooterContextItem(settingsStatus: string): FooterStatusItem {
  if (commandBarOpen) {
    const actions = getFilteredCommandActions();
    const activeAction = actions[Math.min(selectedCommandIndex, Math.max(0, actions.length - 1))];
    const query = commandBarQuery.trim();
    return {
      label: "Context",
      value: query ? `Search ${query}` : (activeAction?.label || "Search actions"),
      tone: "focus",
    };
  }

  if (settingsSheetOpen) {
    return {
      label: "Context",
      value: `Settings ${settingsStatus}`,
      tone: getFooterSettingsTone(settingsStatus),
    };
  }

  if (selectedPreviewUrl) {
    const previewTarget = detectedPreviewTargets.get(selectedPreviewUrl);
    if (previewTarget) {
      return {
        label: "Context",
        value: `${previewTarget.portLabel} · ${previewTarget.sourceLabel}`,
        tone: "accent",
      };
    }
  }

  if (editorSurfaceOpen) {
    const editors = getEditorFiles();
    const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
    if (selected) {
      return {
        label: "Context",
        value: selected.path.split("/").pop() ?? selected.path,
        tone: selected.origin === "context" ? "focus" : "info",
      };
    }
  }

  if (terminalDrawerOpen) {
    return {
      label: "Context",
      value: "Utility drawer",
      tone: "info",
    };
  }

  return {
    label: "Context",
    value: "Ctrl/Cmd+K",
    tone: "accent",
  };
}

function getFooterItems(): { left: FooterStatusItem[]; right: FooterStatusItem[] } {
  const selectedProjection = getPrimaryRunProjection();
  const modeLabel = composerModes.find((item) => item.mode === activeComposerMode)?.label ?? activeComposerMode;
  const inboxCount = desktopSummarySnapshot?.inbox.summary.item_count ?? 0;
  const inboxStatus = desktopSummarySnapshot ? `${inboxCount} inbox` : "Inbox idle";
  const runStatus = selectedProjection?.label || selectedProjection?.run_id || "No run selected";
  const reviewStatus = selectedProjection?.review_state || "No review";
  const nextStatus = selectedProjection?.next_action || "idle";
  const operatorStatus = getFooterOperatorStatus(selectedProjection ?? undefined);
  const settingsStatus = settingsDraftState
    ? (themeStatesEqual(settingsDraftState, themeState) ? (settingsSheetOpen ? "Editing" : "Ready") : "Draft")
    : "Saved";
  const surfaceStatus = getFooterSurfaceStatus();
  const contextItem = getFooterContextItem(settingsStatus);

  return {
    left: [
      { label: "Mode", value: modeLabel, tone: "focus" },
      { label: "Surface", value: surfaceStatus },
      contextItem,
      { label: "Settings", value: settingsStatus, tone: getFooterSettingsTone(settingsStatus) },
    ],
    right: [
      { label: "Run", value: runStatus },
      { label: "Operator", value: operatorStatus.label, tone: operatorStatus.tone },
      { label: "Review", value: reviewStatus, tone: getFooterReviewTone(selectedProjection?.review_state) },
      { label: "Next", value: nextStatus, tone: getFooterNextTone(selectedProjection?.next_action) },
      { label: "Inbox", value: inboxStatus, tone: getFooterInboxTone(inboxCount) },
    ],
  };
}

function cloneThemeState(state: ThemeState): ThemeState {
  return {
    theme: state.theme,
    density: state.density,
    wrapMode: state.wrapMode,
  };
}

function themeStatesEqual(left: ThemeState, right: ThemeState) {
  return left.theme === right.theme
    && left.density === right.density
    && left.wrapMode === right.wrapMode;
}

function readStoredShellPreferences(): ShellPreferenceState | null {
  try {
    const rawValue = window.localStorage.getItem(SHELL_PREFERENCES_STORAGE_KEY);
    if (!rawValue) {
      return null;
    }

    const parsed = JSON.parse(rawValue) as Partial<ShellPreferenceState>;
    const theme = themeOptions.find((item) => item.value === parsed.theme)?.value;
    const density = densityOptions.find((item) => item.value === parsed.density)?.value;
    const wrapMode = wrapOptions.find((item) => item.value === parsed.wrapMode)?.value;
    if (!theme || !density || !wrapMode) {
      return null;
    }

    const sidebarWidthValue = typeof parsed.sidebarWidth === "number" ? parsed.sidebarWidth : 292;
    const wideSidebarOpen = typeof parsed.wideSidebarOpen === "boolean" ? parsed.wideSidebarOpen : true;
    const wideContextOpen = typeof parsed.wideContextOpen === "boolean" ? parsed.wideContextOpen : true;

    return {
      theme,
      density,
      wrapMode,
      sidebarWidth: Math.max(240, Math.min(380, Math.round(sidebarWidthValue))),
      wideSidebarOpen,
      wideContextOpen,
    };
  } catch {
    return null;
  }
}

function persistThemeState() {
  try {
    const nextState: ShellPreferenceState = {
      theme: themeState.theme,
      density: themeState.density,
      wrapMode: themeState.wrapMode,
      sidebarWidth,
      wideSidebarOpen: preferredWideSidebarOpen,
      wideContextOpen: preferredWideContextOpen,
    };
    window.localStorage.setItem(SHELL_PREFERENCES_STORAGE_KEY, JSON.stringify(nextState));
    return true;
  } catch (error) {
    console.warn("Failed to persist shell preferences", error);
    return false;
  }
}

function applyShellPreferences() {
  const shell = document.getElementById("app-shell");
  if (!shell) {
    return;
  }

  shell.dataset.theme = themeState.theme;
  shell.dataset.density = themeState.density;
  shell.dataset.wrapMode = themeState.wrapMode;
}

function applyThemeState(nextState: ThemeState) {
  themeState.theme = nextState.theme;
  themeState.density = nextState.density;
  themeState.wrapMode = nextState.wrapMode;
  applyShellPreferences();
  renderFooterLane();
}

function renderPreferenceOptions<T extends string>(
  rootId: string,
  options: Array<{ value: T; label: string; description: string }>,
  selected: T,
  onSelect: (value: T) => void,
) {
  const root = document.getElementById(rootId);
  if (!root) {
    return;
  }

  root.innerHTML = "";
  for (const option of options) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `settings-option-chip ${option.value === selected ? "is-active" : ""}`;
    button.setAttribute("aria-pressed", option.value === selected ? "true" : "false");
    button.innerHTML = `<span class="settings-option-label">${option.label}</span><span class="settings-option-description">${option.description}</span>`;
    button.addEventListener("click", () => onSelect(option.value));
    root.appendChild(button);
  }
}

function renderSettingsControls() {
  const activeState = settingsDraftState ?? themeState;
  const applyButton = document.getElementById("apply-settings-btn") as HTMLButtonElement | null;

  renderPreferenceOptions("theme-options", themeOptions, activeState.theme, (value) => {
    if (!settingsDraftState) {
      settingsDraftState = cloneThemeState(themeState);
    }
    settingsDraftState.theme = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("density-options", densityOptions, activeState.density, (value) => {
    if (!settingsDraftState) {
      settingsDraftState = cloneThemeState(themeState);
    }
    settingsDraftState.density = value;
    renderSettingsControls();
  });

  renderPreferenceOptions("wrap-options", wrapOptions, activeState.wrapMode, (value) => {
    if (!settingsDraftState) {
      settingsDraftState = cloneThemeState(themeState);
    }
    settingsDraftState.wrapMode = value;
    renderSettingsControls();
  });

  if (applyButton) {
    const hasChanges = Boolean(settingsDraftState && !themeStatesEqual(settingsDraftState, themeState));
    applyButton.disabled = !hasChanges;
    applyButton.setAttribute("aria-disabled", hasChanges ? "false" : "true");
  }

  renderFooterLane();
}

function renderFooterLane() {
  const left = document.getElementById("footer-left");
  const right = document.getElementById("footer-right");
  if (!left || !right) {
    return;
  }

  const footerItems = getFooterItems();

  const buildPill = (item: FooterStatusItem) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "footer-pill";
    button.dataset.tone = item.tone ?? "default";
    button.innerHTML = item.value
      ? `<span class="footer-pill-label">${item.label}</span><span class="footer-pill-value">${item.value}</span>`
      : `<span class="footer-pill-value">${item.label}</span>`;
    if (item.label === "Command" || item.value === "Command") {
      button.addEventListener("click", () => openCommandBar());
    }
    if (item.label === "Settings" || item.value === "Settings") {
      button.addEventListener("click", () => setSettingsSheet(true));
    }
    return button;
  };

  left.innerHTML = "";
  right.innerHTML = "";

  for (const item of footerItems.left) {
    left.appendChild(buildPill(item));
  }

  for (const item of footerItems.right) {
    right.appendChild(buildPill(item));
  }
}

function setComposerMode(mode: ComposerMode) {
  activeComposerMode = mode;
  renderComposerModes();
}

function focusComposer() {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  composerInput.focus();
  const length = composerInput.value.length;
  composerInput.setSelectionRange(length, length);
}

function getComposerSlashMatch(value: string) {
  const match = value.match(/^\/([a-z-]+)(?=\s|$)/i);
  if (!match) {
    return null;
  }

  const token = match[1].toLowerCase();
  return composerSlashCommands.find((item) => item.command === token) ?? null;
}

function getFilteredComposerSlashCommands() {
  if (!composerSlashOpen) {
    return [];
  }

  if (!composerSlashQuery) {
    return composerSlashCommands;
  }

  return composerSlashCommands.filter((item) => item.command.startsWith(composerSlashQuery));
}

function renderComposerSlashCommands() {
  const root = document.getElementById("composer-slash-row");
  if (!root) {
    return;
  }

  const commands = getFilteredComposerSlashCommands();
  root.innerHTML = "";
  root.hidden = commands.length === 0;
  if (commands.length === 0) {
    return;
  }

  commands.forEach((item, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `slash-chip ${index === selectedComposerSlashIndex ? "is-active" : ""}`;
    button.innerHTML = `<span class="slash-chip-command">/${item.command}</span><span class="slash-chip-description">${item.label}</span>`;
    button.addEventListener("click", () => {
      applyComposerSlashCommand(item);
    });
    root.appendChild(button);
  });
}

function syncComposerSlashState(value: string) {
  const match = value.match(/^\/([a-z-]*)$/i);
  composerSlashOpen = Boolean(match);
  composerSlashQuery = match ? match[1].toLowerCase() : "";
  const commands = getFilteredComposerSlashCommands();
  if (commands.length === 0) {
    selectedComposerSlashIndex = 0;
  } else {
    selectedComposerSlashIndex = Math.min(selectedComposerSlashIndex, commands.length - 1);
  }
  renderComposerSlashCommands();
}

function applyComposerSlashCommand(command: (typeof composerSlashCommands)[number]) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  setComposerMode(command.mode);
  composerInput.value = composerInput.value.replace(/^\/[^\s]+/, "").replace(/^\s+/, "");
  syncComposerSlashState(composerInput.value);
  exitComposerHistoryToDraft(composerInput.value);
  composerInput.focus();
  const length = composerInput.value.length;
  composerInput.setSelectionRange(length, length);
}

function insertComposerTab(composerInput: HTMLTextAreaElement) {
  const start = composerInput.selectionStart;
  const end = composerInput.selectionEnd;
  composerInput.setRangeText("\t", start, end, "end");
}

function isComposerSelectionCollapsed(composerInput: HTMLTextAreaElement) {
  return composerInput.selectionStart === composerInput.selectionEnd;
}

function isCaretOnFirstLine(composerInput: HTMLTextAreaElement) {
  return !composerInput.value.slice(0, composerInput.selectionStart).includes("\n");
}

function isCaretOnLastLine(composerInput: HTMLTextAreaElement) {
  return !composerInput.value.slice(composerInput.selectionEnd).includes("\n");
}

function setComposerValue(value: string) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!composerInput) {
    return;
  }

  composerInput.value = value;
  syncComposerSlashState(value);
  const length = value.length;
  composerInput.setSelectionRange(length, length);
}

function syncComposerDraftState(value?: string) {
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  composerDraftState = captureComposerHistoryEntry(value ?? composerInput?.value ?? "");
}

function exitComposerHistoryToDraft(value?: string) {
  composerHistoryIndex = -1;
  syncComposerDraftState(value);
}

function snapshotComposerAttachments(attachments: ComposerAttachment[]): ComposerAttachmentSnapshot[] {
  return attachments.map((item) => ({
    name: item.name,
    kind: item.kind,
    sizeLabel: item.sizeLabel,
    file: item.file,
  }));
}

function restoreComposerAttachments(snapshots: ComposerAttachmentSnapshot[]) {
  return snapshots.map((item) => ({
    id: `${item.name}-${item.file.size}-${item.file.lastModified}-${Math.random().toString(36).slice(2, 8)}`,
    name: item.name,
    kind: item.kind,
    sizeLabel: item.sizeLabel,
    file: item.file,
    previewUrl: item.kind === "image" ? URL.createObjectURL(item.file) : undefined,
  }));
}

function captureComposerHistoryEntry(value: string): ComposerHistoryEntry {
  return {
    value,
    remoteReferenceIds: Array.from(selectedComposerRemoteReferenceIds),
    attachments: snapshotComposerAttachments(pendingAttachments),
  };
}

function applyComposerHistoryEntry(entry: ComposerHistoryEntry) {
  setComposerValue(entry.value);
  clearPendingAttachments();
  pendingAttachments = restoreComposerAttachments(entry.attachments);
  selectedComposerRemoteReferenceIds = new Set(entry.remoteReferenceIds);
  renderAttachmentTray();
  renderComposerRemoteReferences();
}

function stepComposerHistory(direction: -1 | 1) {
  if (composerHistory.length === 0) {
    return;
  }

  if (direction === -1) {
    if (composerHistoryIndex === -1) {
      const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
      composerDraftState = captureComposerHistoryEntry(composerInput?.value ?? "");
      composerHistoryIndex = composerHistory.length - 1;
    } else if (composerHistoryIndex > 0) {
      composerHistoryIndex -= 1;
    }
    applyComposerHistoryEntry(composerHistory[composerHistoryIndex] ?? composerDraftState);
    return;
  }

  if (composerHistoryIndex === -1) {
    return;
  }

  if (composerHistoryIndex < composerHistory.length - 1) {
    composerHistoryIndex += 1;
    applyComposerHistoryEntry(composerHistory[composerHistoryIndex] ?? composerDraftState);
    return;
  }

  composerHistoryIndex = -1;
  applyComposerHistoryEntry(composerDraftState);
}

function pushComposerHistoryEntry(entry: ComposerHistoryEntry) {
  if (!entry.value && entry.remoteReferenceIds.length === 0 && entry.attachments.length === 0) {
    return;
  }

  composerHistory = [entry, ...composerHistory].slice(0, 20);
  composerHistoryIndex = -1;
  composerDraftState = { value: "", remoteReferenceIds: [], attachments: [] };
}

function getComposerRemoteReferences() {
  const selectedProjection = getPrimaryRunProjection();
  const references: ComposerRemoteReference[] = [];

  if (selectedProjection) {
    references.push({
      id: `run:${selectedProjection.run_id}`,
      label: selectedProjection.run_id,
      meta: `${selectedProjection.next_action || "idle"} · ${selectedProjection.branch || "no branch"}`,
    });
  }

  for (const change of getVisibleSourceChanges().slice(0, 3)) {
    references.push({
      id: `change:${getSourceChangeKey(change)}`,
      label: change.path.split("/").pop() ?? change.path,
      meta: `${change.status} · ${change.branch}`,
    });
  }

  return references;
}

function renderComposerRemoteReferences() {
  const root = document.getElementById("composer-remote-row");
  if (!root) {
    return;
  }

  const references = getComposerRemoteReferences();
  root.innerHTML = "";
  root.hidden = references.length === 0;
  if (references.length === 0) {
    selectedComposerRemoteReferenceIds.clear();
    return;
  }

  const validIds = new Set(references.map((item) => item.id));
  selectedComposerRemoteReferenceIds = new Set(
    Array.from(selectedComposerRemoteReferenceIds).filter((id) => validIds.has(id)),
  );

  references.forEach((item) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `remote-chip ${selectedComposerRemoteReferenceIds.has(item.id) ? "is-active" : ""}`;
    const label = document.createElement("span");
    label.className = "remote-chip-label";
    label.textContent = item.label;
    const meta = document.createElement("span");
    meta.className = "remote-chip-meta";
    meta.textContent = item.meta;
    button.appendChild(label);
    button.appendChild(meta);
    button.addEventListener("click", () => {
      if (selectedComposerRemoteReferenceIds.has(item.id)) {
        selectedComposerRemoteReferenceIds.delete(item.id);
      } else {
        selectedComposerRemoteReferenceIds.add(item.id);
      }
      exitComposerHistoryToDraft();
      renderComposerRemoteReferences();
    });
    root.appendChild(button);
  });
}

function renderComposerModes() {
  const root = document.getElementById("composer-mode-row");
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  if (!root || !composerInput) {
    return;
  }

  root.innerHTML = "";
  for (const item of composerModes) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `mode-chip ${item.mode === activeComposerMode ? "is-active" : ""}`;
    button.textContent = item.label;
    button.setAttribute("aria-pressed", item.mode === activeComposerMode ? "true" : "false");
    button.addEventListener("click", () => {
      setComposerMode(item.mode);
    });
    root.appendChild(button);
  }

  const selected = composerModes.find((item) => item.mode === activeComposerMode);
  if (selected) {
    composerInput.placeholder = selected.placeholder;
  }

  renderComposerSlashCommands();
  renderComposerRemoteReferences();
}

function formatAttachmentSize(size: number) {
  if (size >= 1024 * 1024) {
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }
  if (size >= 1024) {
    return `${Math.max(1, Math.round(size / 1024))} KB`;
  }
  return `${size} B`;
}

function synthesizeScreenshotName() {
  const now = new Date();
  const date = `${now.getFullYear()}-${`${now.getMonth() + 1}`.padStart(2, "0")}-${`${now.getDate()}`.padStart(2, "0")}`;
  const time = `${`${now.getHours()}`.padStart(2, "0")}.${`${now.getMinutes()}`.padStart(2, "0")}.${`${now.getSeconds()}`.padStart(2, "0")}`;
  return `Screenshot ${date} ${time}.png`;
}

function createComposerAttachment(file: File) {
  const name = file.name?.trim() ? file.name : file.type.startsWith("image/") ? synthesizeScreenshotName() : "Attachment";
  const kind: "image" | "file" = file.type.startsWith("image/") ? "image" : "file";
  return {
    id: `${name}-${file.size}-${file.lastModified}-${Math.random().toString(36).slice(2, 8)}`,
    name,
    kind,
    sizeLabel: formatAttachmentSize(file.size),
    file,
    previewUrl: kind === "image" ? URL.createObjectURL(file) : undefined,
  } satisfies ComposerAttachment;
}

function releaseAttachmentPreview(attachment: ComposerAttachment) {
  if (attachment.previewUrl) {
    URL.revokeObjectURL(attachment.previewUrl);
  }
}

function clearPendingAttachments() {
  for (const attachment of pendingAttachments) {
    releaseAttachmentPreview(attachment);
  }
  pendingAttachments = [];
}

function renderAttachmentTray() {
  const tray = document.getElementById("attachment-tray");
  if (!tray) {
    return;
  }

  tray.innerHTML = "";
  tray.classList.toggle("is-empty", pendingAttachments.length === 0);

  if (pendingAttachments.length === 0) {
    const empty = document.createElement("div");
    empty.className = "attachment-empty-state";
    empty.textContent = "Paste a screenshot, drop files, or use Attach.";
    tray.appendChild(empty);
    return;
  }

  for (const attachment of pendingAttachments) {
    const item = document.createElement("div");
    item.className = "attachment-item";

    if (attachment.previewUrl) {
      const thumb = document.createElement("img");
      thumb.className = "attachment-thumb";
      thumb.src = attachment.previewUrl;
      thumb.alt = attachment.name;
      item.appendChild(thumb);
    } else {
      const icon = document.createElement("div");
      icon.className = "attachment-thumb attachment-thumb-file";
      icon.textContent = attachment.kind === "image" ? "IMG" : "FILE";
      item.appendChild(icon);
    }

    const meta = document.createElement("div");
    meta.className = "attachment-meta";
    meta.innerHTML = `<span class="attachment-name">${attachment.name}</span><span class="attachment-size">${attachment.sizeLabel}</span>`;
    item.appendChild(meta);

    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.className = "attachment-remove";
    removeButton.setAttribute("aria-label", `Remove ${attachment.name}`);
    removeButton.textContent = "Remove";
    removeButton.addEventListener("click", () => {
      releaseAttachmentPreview(attachment);
      pendingAttachments = pendingAttachments.filter((item) => item.id !== attachment.id);
      exitComposerHistoryToDraft();
      renderAttachmentTray();
    });
    item.appendChild(removeButton);

    tray.appendChild(item);
  }
}

function appendAttachments(files: File[]) {
  if (files.length === 0) {
    return;
  }

  const remaining = Math.max(0, 5 - pendingAttachments.length);
  if (remaining <= 0) {
    return;
  }

  const next = files.slice(0, remaining).map((file) => createComposerAttachment(file));
  pendingAttachments = [...pendingAttachments, ...next];
  exitComposerHistoryToDraft();
  renderAttachmentTray();
}

function getVisibleConversationItems(items: ConversationItem[]) {
  switch (activeTimelineFilter) {
    case "attention":
      return items.filter((item) => item.category === "attention");
    case "review":
      return items.filter((item) => item.category === "review");
    case "activity":
      return items.filter((item) => item.category === "activity" || item.type === "operator");
    default:
      return items;
  }
}

function renderTimelineFilters() {
  const root = document.getElementById("timeline-filter-row");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  for (const item of timelineFilters) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `timeline-filter-chip ${item.filter === activeTimelineFilter ? "is-active" : ""}`;
    button.textContent = item.label;
    button.setAttribute("aria-pressed", item.filter === activeTimelineFilter ? "true" : "false");
    button.addEventListener("click", () => {
      activeTimelineFilter = item.filter;
      renderTimelineFilters();
      renderConversation(getConversationItems());
      renderRunSummary();
    });
    root.appendChild(button);
  }
}

function renderRunSummary() {
  const root = document.getElementById("selected-run-summary");
  if (!root) {
    return;
  }

  const projection = getPrimaryRunProjection();
  if (projection) {
    const statusTone =
      projection.review_state === "PASS"
        ? "success"
        : projection.review_state === "PENDING"
          ? "warning"
          : projection.review_state === "FAIL" || projection.review_state === "FAILED"
            ? "danger"
            : "info";
    const verification = projection.verification_outcome ? `verify ${projection.verification_outcome}` : "verify n/a";
    const security = projection.security_blocked ? `security ${projection.security_blocked}` : "security n/a";

    root.innerHTML = `
      <div class="run-summary-card">
        <div class="run-summary-header">
          <div>
            <div class="timeline-eyebrow">Selected run</div>
            <div class="run-summary-title">${projection.run_id}</div>
          </div>
          <div class="run-summary-status" data-tone="${statusTone}">
            ${projection.review_state || "ready"}
          </div>
        </div>
        <div class="run-summary-meta-row">
          <span class="run-summary-pill">${projection.label || projection.pane_id || "summary-stream"}</span>
          <span class="run-summary-pill">${projection.branch || "no branch"}</span>
          <span class="run-summary-pill">${projection.changed_files.length} changed</span>
          <span class="run-summary-pill">${projection.next_action || "no next action"}</span>
          <span class="run-summary-pill">${verification}</span>
          <span class="run-summary-pill">${security}</span>
        </div>
        <div class="run-summary-body">${projection.summary || projection.task || "Projected run surfaced by the backend adapter."}</div>
        <div class="timeline-chip-row">
          <button type="button" class="timeline-chip" data-action="open-explain">Open Explain</button>
          <button type="button" class="timeline-chip" data-action="open-source-context">Source Context</button>
          <button type="button" class="timeline-chip" data-action="open-terminal">Terminal</button>
        </div>
      </div>
    `;

    for (const button of root.querySelectorAll<HTMLButtonElement>(".timeline-chip")) {
      const action = button.dataset.action as ChipAction | undefined;
      if (!action) {
        continue;
      }
      button.addEventListener("click", () => handleChipAction(action));
    }
    return;
  }

  root.innerHTML = `
    <div class="run-summary-card">
      <div class="run-summary-header">
        <div>
          <div class="timeline-eyebrow">Selected run</div>
          <div class="run-summary-title">No projected run</div>
        </div>
        <div class="run-summary-status" data-tone="info">
          awaiting summary
        </div>
      </div>
      <div class="run-summary-body">The desktop summary has not surfaced a run for the current view yet.</div>
    </div>
  `;
}

function renderConversation(items: ConversationItem[]) {
  const timeline = document.getElementById("conversation-timeline");
  if (!timeline) {
    return;
  }

  timeline.innerHTML = "";
  const visibleItems = getVisibleConversationItems(items);

  if (visibleItems.length === 0) {
    const empty = document.createElement("div");
    empty.className = "attachment-empty-state";
    empty.textContent = "No events in this filter yet.";
    timeline.appendChild(empty);
    return;
  }

  for (const item of visibleItems) {
    const article = document.createElement("article");
    article.className = `timeline-item timeline-${item.type}`;
    article.dataset.tone = item.tone ?? (item.type === "operator" ? "info" : item.type === "system" ? "focus" : "default");
    if (item.runId) {
      article.classList.toggle("is-selected-run", item.runId === getSelectedRunId());
      article.addEventListener("click", () => {
        setSelectedRun(item.runId ?? null);
        renderDesktopSurfaces();
      });
    }

    const meta = document.createElement("div");
    meta.className = "timeline-meta-row";
    meta.innerHTML =
      `<span class="timeline-actor">${item.actor}</span>` +
      `<span class="timeline-meta-separator">·</span>` +
      `<span>${item.timestamp}</span>` +
      (item.runId ? `<span class="timeline-meta-separator">·</span><span>${item.runId}</span>` : "") +
      (item.statusLabel ? `<span class="timeline-status-pill">${item.statusLabel}</span>` : "");
    article.appendChild(meta);

    if (item.title) {
      const title = document.createElement("div");
      title.className = "timeline-title";
      title.textContent = item.title;
      article.appendChild(title);
    }

    const body = document.createElement("div");
    body.className = "timeline-body";
    body.textContent = item.body;
    article.appendChild(body);

    if (item.details?.length) {
      const detailRow = document.createElement("div");
      detailRow.className = "timeline-detail-row";
      for (const detail of item.details) {
        const pill = document.createElement("span");
        pill.className = "timeline-detail-pill";
        pill.innerHTML = `<span class="timeline-detail-label">${detail.label}</span><span>${detail.value}</span>`;
        detailRow.appendChild(pill);
      }
      article.appendChild(detailRow);
    }

    if (item.attachments?.length) {
      const attachmentRow = document.createElement("div");
      attachmentRow.className = "timeline-attachment-row";
      for (const attachment of item.attachments) {
        const pill = document.createElement("span");
        pill.className = "timeline-attachment-pill";
        pill.innerHTML = `<span>${attachment.kind === "image" ? "Image" : "File"}</span><span>${attachment.name}</span><span>${attachment.sizeLabel}</span>`;
        attachmentRow.appendChild(pill);
      }
      article.appendChild(attachmentRow);
    }

    if (item.chips?.length) {
      const chipRow = document.createElement("div");
      chipRow.className = "timeline-chip-row";
      for (const chipInfo of item.chips) {
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "timeline-chip";
        chip.textContent = chipInfo.label;
        chip.addEventListener("click", () => handleChipAction(chipInfo.action));
        chipRow.appendChild(chip);
      }
      article.appendChild(chipRow);
    }

    timeline.appendChild(article);
  }
}

async function openExplainForSelectedRun() {
  const selectedRunId = getSelectedRunId();
  if (!selectedRunId) {
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Select a run first",
      body: "Explain requires a selected run from the desktop summary.",
      details: [{ label: "runs", value: `${getRunProjections().length}` }],
      tone: "info",
    });
    renderConversation(getConversationItems());
    return;
  }

  try {
    const previousPayload = desktopExplainCache.get(selectedRunId) ?? null;
    const payload = await getDesktopRunExplain(selectedRunId);
    const observationPack = getObservationPack(payload);
    const consultationSummary = getConsultationSummary(payload);
    desktopExplainCache.set(selectedRunId, payload);

    const detailItems: ConversationDetail[] = [
      { label: "run", value: payload.run.run_id },
      { label: "next", value: payload.explanation.next_action || payload.evidence_digest.next_action || "no next action" },
    ];
    if (payload.run.provider_target) {
      detailItems.push({ label: "model", value: payload.run.provider_target });
    }
    if (payload.run.priority) {
      detailItems.push({ label: "priority", value: payload.run.priority });
    }
    if (payload.run.pane_count > 0) {
      detailItems.push({ label: "panes", value: `${payload.run.pane_count}` });
    }
    if (payload.run.tokens_remaining) {
      detailItems.push({ label: "context", value: payload.run.tokens_remaining });
    }
    if (payload.run.experiment_packet.next_action) {
      detailItems.push({ label: "experiment", value: payload.run.experiment_packet.next_action });
    }
    if (observationPack.hypothesis) {
      detailItems.push({ label: "observe", value: observationPack.hypothesis });
    }
    if (consultationSummary.next_test) {
      detailItems.push({ label: "consult", value: consultationSummary.next_test });
    }
    if (payload.run.primary_label) {
      detailItems.push({ label: "pane", value: payload.run.primary_label });
    }
    if (payload.run.branch) {
      detailItems.push({ label: "branch", value: payload.run.branch });
    }
    if (payload.run.worktree) {
      detailItems.push({ label: "worktree", value: payload.run.worktree });
    }
    if (payload.run.head_sha) {
      detailItems.push({ label: "head", value: payload.run.head_sha.slice(0, 8) });
    }
    if (payload.run.last_event) {
      detailItems.push({ label: "event", value: payload.run.last_event });
    }
    if (
      payload.explanation.current_state.state ||
      payload.explanation.current_state.task_state ||
      payload.explanation.current_state.review_state
    ) {
      const currentStateParts = [
        payload.explanation.current_state.state,
        payload.explanation.current_state.task_state,
        payload.explanation.current_state.review_state,
      ].filter((value) => Boolean(value));
      detailItems.push({ label: "state", value: currentStateParts.join(" / ") });
    }
    if (payload.run.review_state) {
      detailItems.push({ label: "review", value: payload.run.review_state });
    }
    if (payload.review_state?.reviewer?.label) {
      detailItems.push({ label: "reviewer", value: payload.review_state.reviewer.label });
    }
    if (payload.evidence_digest.verification_outcome) {
      detailItems.push({ label: "verify", value: payload.evidence_digest.verification_outcome });
    }
    if (payload.evidence_digest.security_blocked) {
      detailItems.push({ label: "security", value: payload.evidence_digest.security_blocked });
    }
    const changedFiles = payload.run.changed_files.length > 0
      ? payload.run.changed_files
      : payload.evidence_digest.changed_files;
    if (changedFiles.length > 0) {
      detailItems.push({ label: "changed", value: `${changedFiles.length}` });
    }

    const bodyParts = [payload.explanation.summary];
    if (payload.run.goal) {
      bodyParts.push(`Goal: ${payload.run.goal}`);
    }
    const workspaceContext = summarizeWorkspaceContext(payload.run.branch, payload.run.worktree);
    if (workspaceContext) {
      bodyParts.push(`Workspace: ${workspaceContext}`);
    }
    const reviewVerdict = summarizeReviewVerdict(payload);
    if (reviewVerdict) {
      bodyParts.push(`Review: ${reviewVerdict}`);
    }
    if (payload.explanation.reasons.length > 0) {
      bodyParts.push(`Reasons: ${payload.explanation.reasons.join(" | ")}`);
    }
    if (payload.explanation.current_state.last_event) {
      bodyParts.push(`State: ${payload.explanation.current_state.last_event}`);
    }
    if (payload.run.action_items.length > 0) {
      const actions = payload.run.action_items
        .slice(0, 2)
        .map((item) => `${item.kind}: ${item.message}`)
        .join(" | ");
      bodyParts.push(`Actions: ${actions}`);
    }
    if (observationPack.working_tree_summary || observationPack.failing_command) {
      const observationParts = [
        observationPack.working_tree_summary,
        observationPack.failing_command,
      ].filter((value) => Boolean(value));
      bodyParts.push(`Observe: ${observationParts.join(" | ")}`);
    }
    if (changedFiles.length > 0) {
      bodyParts.push(`Files: ${summarizeChangedFiles(changedFiles)}`);
    }
    if (payload.recent_events.length > 0) {
      const recent = payload.recent_events
        .slice(0, 2)
        .map((item) => `${item.event}: ${item.message}`)
        .join(" | ");
      bodyParts.push(`Recent: ${recent}`);
    }

    const previousFingerprint = getExplainPayloadFingerprint(previousPayload);
    const nextFingerprint = getExplainPayloadFingerprint(payload);
    if (previousFingerprint !== nextFingerprint) {
      appendRuntimeConversation({
        type: "operator",
        category: "activity",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
        actor: "Operator",
        title: "Explain opened",
        body: bodyParts.join(" "),
        details: detailItems,
        tone: "info",
        runId: payload.run.run_id,
      });
    }
    renderRunSummary();
    renderContextPanel();
    renderConversation(getConversationItems());
  } catch (error) {
    console.warn("Failed to load desktop explain payload", error);
    appendFallbackExplain();
    return;
  }
}

async function promoteSelectedRunTactic(runId: string) {
  if (promotingRunIds.has(runId) || pendingPromotedRunRefreshIds.has(runId)) {
    return;
  }

  promotingRunIds.add(runId);
  renderContextPanel();

  try {
    const result = await promoteDesktopRunTactic(runId);
    pendingPromotedRunRefreshIds.add(runId);
    renderContextPanel();
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Playbook candidate exported",
      body: result.candidate.summary || result.candidate.title,
      details: [
        { label: "run", value: result.run_id },
        { label: "kind", value: result.candidate.kind },
        { label: "candidate", value: result.candidate_ref },
      ],
      tone: "success",
      runId,
    });
    renderConversation(getConversationItems());
    requestDesktopSummaryRefresh(undefined, 0);
    try {
      const explainPayload = await getDesktopRunExplain(runId);
      desktopExplainCache.set(runId, explainPayload);
      promotedRunCandidates.set(runId, {
        fingerprint: getExplainPayloadFingerprint(explainPayload),
        candidateRef: result.candidate_ref,
        collapseAfterRefreshSerial: desktopSummaryRefreshSerial + 1,
      });
    } catch (refreshError) {
      console.warn("Failed to refresh promoted run explain payload", refreshError);
      promotedRunCandidates.delete(runId);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Promote failed",
      body: message,
      details: [{ label: "run", value: runId }],
      tone: "warning",
      runId,
    });
    renderConversation(getConversationItems());
  } finally {
    promotingRunIds.delete(runId);
    pendingPromotedRunRefreshIds.delete(runId);
    renderContextPanel();
    renderRunSummary();
  }
}

async function focusRunInContext(runId: string) {
  setSelectedRun(runId);
  const focusedSourceChange = getProjectionSourceEntries().find((change) => change.run === runId);
  if (focusedSourceChange) {
    selectedEditorKey = getSourceChangeKey(focusedSourceChange);
  }
  renderDesktopSurfaces();

  try {
    const explainPayload = await getDesktopRunExplain(runId);
    desktopExplainCache.set(runId, explainPayload);
  } catch (error) {
    console.warn("Failed to preload explain payload for focused run", error);
  } finally {
    renderDesktopSurfaces();
  }
}

async function pickCompareWinner(
  runId: string,
  peerRunId: string,
  peerSlot: string,
  recommendation: string,
  confidence: number | null,
  nextTest: string,
) {
  if (pickingWinnerRunIds.has(runId)) {
    return;
  }

  pickingWinnerRunIds.add(runId);
  renderContextPanel();

  try {
    const result = await pickDesktopRunWinner(
      runId,
      peerSlot,
      recommendation,
      confidence,
      nextTest,
    );
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Winner picked",
      body: result.recommendation || runId,
      details: [
        { label: "run", value: result.run_id },
        { label: "target", value: result.target_slot || "n/a" },
        { label: "next", value: result.next_test || "n/a" },
      ],
      tone: "success",
      runId,
    });
    renderConversation(getConversationItems());
    if (peerRunId) {
      desktopRunCompareCache.delete(getComparePairKey(runId, peerRunId));
      desktopRunCompareCache.delete(getComparePairKey(peerRunId, runId));
    }
    requestDesktopSummaryRefresh(runId, 0);
    await focusRunInContext(runId);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Pick winner failed",
      body: message,
      details: [{ label: "run", value: runId }],
      tone: "warning",
      runId,
    });
    renderConversation(getConversationItems());
  } finally {
    pickingWinnerRunIds.delete(runId);
    renderContextPanel();
  }
}

async function compareSelectedRunWithPeer(leftRunId: string, rightRunId: string) {
  const pairKey = getComparePairKey(leftRunId, rightRunId);
  if (comparingRunPairKeys.has(pairKey)) {
    return;
  }

  const leftFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(leftRunId));
  const rightFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(rightRunId));
  comparingRunPairKeys.add(pairKey);
  renderContextPanel();

  try {
    const result = await compareDesktopRuns(leftRunId, rightRunId);
    const latestLeftFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(leftRunId));
    const latestRightFingerprint = getRunProjectionFingerprint(getRunProjectionByRunId(rightRunId));
    if (
      leftFingerprint !== latestLeftFingerprint ||
      rightFingerprint !== latestRightFingerprint
    ) {
      appendRuntimeConversation({
        type: "operator",
        category: "activity",
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
        actor: "Operator",
        title: "Compare needs rerun",
        body: "The selected runs changed while compare was running.",
        details: [
          { label: "left", value: leftRunId },
          { label: "right", value: rightRunId },
        ],
        tone: "warning",
        runId: leftRunId,
      });
      renderConversation(getConversationItems());
      return;
    }

    desktopRunCompareCache.set(pairKey, result);
    desktopRunCompareCache.set(
      getComparePairKey(rightRunId, leftRunId),
      mirrorCompareRunsResult(result),
    );
    appendRuntimeConversation({
      type: "operator",
      category: "activity",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Compare completed",
      body: [
        `${result.left.label || result.left.run_id} vs ${result.right.label || result.right.run_id}`,
        result.recommend.next_action || "reconcile_consult",
      ].join(" · "),
      details: [
        { label: "winner", value: result.recommend.winning_run_id || "none" },
        { label: "diffs", value: `${result.differences.length}` },
        {
          label: "delta",
          value: result.confidence_delta !== null
            ? formatConfidencePercent(Math.abs(result.confidence_delta))
            : "n/a",
        },
      ],
      tone: result.recommend.reconcile_consult ? "warning" : "info",
      runId: leftRunId,
    });
    renderConversation(getConversationItems());
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendRuntimeConversation({
      type: "operator",
      category: "attention",
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Compare failed",
      body: message,
      details: [
        { label: "left", value: leftRunId },
        { label: "right", value: rightRunId },
      ],
      tone: "warning",
      runId: leftRunId,
    });
    renderConversation(getConversationItems());
  } finally {
    comparingRunPairKeys.delete(pairKey);
    renderContextPanel();
  }
}

function appendFallbackExplain() {
  const timestamp = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
  const selectedRunId = getSelectedRunId();
  const projection = getPrimaryRunProjection();
  if (!selectedRunId || projection?.run_id !== selectedRunId) {
    return;
  }
  const workspaceContext = summarizeWorkspaceContext(projection.branch, projection.worktree);

  appendRuntimeConversation({
    type: "operator",
    category: "activity",
    timestamp,
    actor: "Operator",
    title: "Explain unavailable",
    body: workspaceContext
      ? `Explain unavailable for ${selectedRunId}. Workspace: ${workspaceContext}.`
      : `Explain unavailable for ${selectedRunId}.`,
    details: [
      { label: "run", value: selectedRunId },
      { label: "next", value: projection.next_action || "idle" },
      { label: "branch", value: projection.branch || "no branch" },
      { label: "worktree", value: projection.worktree || "project root" },
      { label: "changed", value: `${projection.changed_files.length}` },
    ],
    tone: "info",
    runId: selectedRunId,
  });
  renderRunSummary();
  renderContextPanel();
  renderConversation(getConversationItems());
}

function handleChipAction(action: ChipAction) {
  switch (action) {
    case "open-editor":
      void openEditorTarget(
        getPreferredEditorTargetForSelectedRun() ??
          getEditorTargetForSourceChange(getPrimarySourceChange(getVisibleSourceChanges())) ??
          getEditorTargetByKey(selectedEditorKey),
      );
      break;
    case "open-source-context":
    case "toggle-context":
      setContextPanel(true);
      break;
    case "open-terminal":
      setTerminalDrawer(true);
      break;
    case "open-explain":
      void openExplainForSelectedRun();
      break;
  }
}

function getCommandActions(): CommandAction[] {
  return [
    {
      id: "dispatch",
      label: "Dispatch next task",
      description: "Switch the composer to dispatch mode and focus the operator input.",
      keywords: ["dispatch", "task", "composer", "operator"],
      shortcut: "Ctrl/Cmd+K",
      tone: "focus",
      run: () => {
        setComposerMode("dispatch");
        focusComposer();
      },
    },
    {
      id: "ask",
      label: "Ask the operator",
      description: "Switch to ask mode for status questions, clarifications, and routing checks.",
      keywords: ["ask", "status", "clarify", "operator"],
      tone: "info",
      run: () => {
        setComposerMode("ask");
        focusComposer();
      },
    },
    {
      id: "review",
      label: "Request review",
      description: "Switch to review mode to request approval, audit, or verification.",
      keywords: ["review", "approve", "audit", "verify"],
      tone: "warning",
      run: () => {
        setComposerMode("review");
        focusComposer();
      },
    },
    {
      id: "explain",
      label: "Explain selected run",
      description: "Open the explain flow for the currently selected run and add operator context to the timeline.",
      keywords: ["explain", "run", "blocked", "why"],
      tone: "info",
      run: () => handleChipAction("open-explain"),
    },
    {
      id: "editor",
      label: "Open secondary editor",
      description: "Open the secondary work surface for the currently selected file or run context.",
      keywords: ["editor", "file", "changed files", "secondary"],
      tone: "default",
      run: () => handleChipAction("open-editor"),
    },
    {
      id: "source-context",
      label: "Open source context",
      description: "Reveal the source-control context sheet and changed-file drill-down.",
      keywords: ["source", "context", "changed files", "worktree", "branch"],
      tone: "default",
      run: () => handleChipAction("open-source-context"),
    },
    {
      id: "terminal",
      label: "Open terminal drawer",
      description: "Show the utility drawer for raw PTY output, diagnostics, and pane control.",
      keywords: ["terminal", "drawer", "pty", "diagnostics", "pane"],
      tone: "default",
      run: () => handleChipAction("open-terminal"),
    },
    {
      id: "settings",
      label: "Open settings",
      description: "Open theme, density, wrap, and workspace preferences.",
      keywords: ["settings", "theme", "density", "wrap", "preferences"],
      tone: "accent",
      run: () => setSettingsSheet(true),
    },
    {
      id: "attention-filter",
      label: "Filter timeline: attention",
      description: "Show only blocked and urgent attention events in the conversation feed.",
      keywords: ["filter", "attention", "blocked", "timeline"],
      tone: "danger",
      run: () => {
        activeTimelineFilter = "attention";
        renderTimelineFilters();
        renderRunSummary();
        renderConversation(getConversationItems());
      },
    },
    {
      id: "review-filter",
      label: "Filter timeline: review",
      description: "Show review requests, approvals, and review-capable slot activity.",
      keywords: ["filter", "review", "timeline", "approve"],
      tone: "warning",
      run: () => {
        activeTimelineFilter = "review";
        renderTimelineFilters();
        renderRunSummary();
        renderConversation(getConversationItems());
      },
    },
  ];
}

function getFilteredCommandActions() {
  const query = commandBarQuery.trim().toLowerCase();
  const actions = getCommandActions();
  if (!query) {
    return actions;
  }

  return actions.filter((action) => {
    const haystack = [action.label, action.description, action.shortcut ?? "", ...action.keywords]
      .join(" ")
      .toLowerCase();
    return haystack.includes(query);
  });
}

function openCommandBar() {
  commandBarOpen = true;
  commandBarQuery = "";
  selectedCommandIndex = 0;
  lastCommandBarFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  if (settingsSheetOpen) {
    setSettingsSheet(false);
  }
  renderCommandBar();

  const shell = document.getElementById("command-bar-shell");
  const button = document.getElementById("open-command-bar-btn");
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  if (shell) {
    shell.hidden = false;
  }
  if (button) {
    button.setAttribute("aria-expanded", "true");
  }

  requestAnimationFrame(() => input?.focus());
}

function closeCommandBar(restoreFocus = true) {
  commandBarOpen = false;
  commandBarQuery = "";
  selectedCommandIndex = 0;
  commandBarImeActive = false;

  const shell = document.getElementById("command-bar-shell");
  const button = document.getElementById("open-command-bar-btn");
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  if (shell) {
    shell.hidden = true;
  }
  if (button) {
    button.setAttribute("aria-expanded", "false");
  }
  if (input) {
    input.value = "";
  }

  if (restoreFocus) {
    requestAnimationFrame(() => lastCommandBarFocus?.focus());
  }
}

function executeSelectedCommand() {
  const actions = getFilteredCommandActions();
  if (actions.length === 0) {
    return;
  }

  const action = actions[Math.min(selectedCommandIndex, actions.length - 1)];
  closeCommandBar(false);
  action.run();
}

function renderCommandBar() {
  const input = document.getElementById("command-bar-input") as HTMLInputElement | null;
  const results = document.getElementById("command-bar-results");
  if (!input || !results) {
    return;
  }

  input.value = commandBarQuery;
  const actions = getFilteredCommandActions();
  if (selectedCommandIndex >= actions.length) {
    selectedCommandIndex = Math.max(0, actions.length - 1);
  }

  results.innerHTML = "";
  if (actions.length === 0) {
    input.removeAttribute("aria-activedescendant");
    const empty = document.createElement("div");
    empty.className = "command-bar-empty";
    empty.textContent = "No matching command. Try run, review, terminal, source, or settings.";
    results.appendChild(empty);
    return;
  }

  actions.forEach((action, index) => {
    const optionId = `command-option-${action.id}`;
    const button = document.createElement("button");
    button.type = "button";
    button.id = optionId;
    button.className = `command-bar-item ${index === selectedCommandIndex ? "is-active" : ""}`;
    button.dataset.tone = action.tone ?? "default";
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", index === selectedCommandIndex ? "true" : "false");
    button.innerHTML =
      `<div class="command-bar-item-main">` +
      `<span class="command-bar-item-label">${action.label}</span>` +
      `<span class="command-bar-item-description">${action.description}</span>` +
      `</div>` +
      `<div class="command-bar-item-meta">` +
      (action.shortcut ? `<span class="command-bar-item-shortcut">${action.shortcut}</span>` : "") +
      `<span class="command-bar-item-keywords">${action.keywords.slice(0, 3).join(" · ")}</span>` +
      `</div>`;
    button.addEventListener("mouseenter", () => {
      selectedCommandIndex = index;
      renderCommandBar();
    });
    button.addEventListener("click", () => {
      selectedCommandIndex = index;
      executeSelectedCommand();
    });
    results.appendChild(button);
  });

  const activeAction = actions[Math.min(selectedCommandIndex, actions.length - 1)];
  if (activeAction) {
    input.setAttribute("aria-activedescendant", `command-option-${activeAction.id}`);
  } else {
    input.removeAttribute("aria-activedescendant");
  }
}

function trapCommandBarTab(event: KeyboardEvent) {
  const root = document.getElementById("command-bar");
  if (!root || event.key !== "Tab") {
    return;
  }

  const focusables = Array.from(
    root.querySelectorAll<HTMLElement>('input, button, [href], [tabindex]:not([tabindex="-1"])'),
  ).filter((element) => !element.hasAttribute("disabled") && !element.getAttribute("aria-hidden"));

  if (focusables.length === 0) {
    return;
  }

  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  const active = document.activeElement;

  if (!event.shiftKey && active === last) {
    event.preventDefault();
    first.focus();
    return;
  }

  if (event.shiftKey && active === first) {
    event.preventDefault();
    last.focus();
  }
}

function renderEditorSurface() {
  const title = document.getElementById("editor-surface-title");
  const summary = document.getElementById("editor-surface-summary");
  const path = document.getElementById("editor-file-path");
  const meta = document.getElementById("editor-meta-row");
  const diffPreview = document.getElementById("editor-diff-preview");
  const browserSurface = document.getElementById("browser-surface");
  const browserFrame = document.getElementById("browser-frame") as HTMLIFrameElement | null;
  const browserMeta = document.getElementById("browser-meta-row");
  const browserTargetList = document.getElementById("browser-target-list");
  const browserToolbarSummary = document.getElementById("browser-toolbar-summary");
  const browserBackButton = document.getElementById("browser-back-btn") as HTMLButtonElement | null;
  const browserCopyButton = document.getElementById("browser-copy-btn") as HTMLButtonElement | null;
  const browserReloadButton = document.getElementById("browser-reload-btn") as HTMLButtonElement | null;
  const browserOpenButton = document.getElementById("browser-open-btn") as HTMLButtonElement | null;
  const popoutButton = document.getElementById("popout-editor-btn") as HTMLButtonElement | null;
  const tabs = document.getElementById("editor-tabs");
  const code = document.getElementById("editor-code");
  const statusbar = document.getElementById("editor-statusbar");
  if (!title || !summary || !path || !meta || !diffPreview || !browserSurface || !browserFrame || !browserMeta || !browserTargetList || !browserToolbarSummary || !browserBackButton || !browserCopyButton || !browserReloadButton || !browserOpenButton || !popoutButton || !tabs || !code || !statusbar) {
    return;
  }

  const editors = getEditorFiles();
  const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
  const previewTarget = selectedPreviewUrl ? detectedPreviewTargets.get(selectedPreviewUrl) ?? null : null;
  const previewTargets = getPreviewTargets();
  const previewModeActive = editorSurfaceMode === "preview" && Boolean(previewTarget);
  const detachedSurface = document.body.dataset.popoutSurface === "1";
  if (!selected && !previewModeActive) {
    title.textContent = "Editor";
    path.textContent = "Editor idle";
    summary.innerHTML = "";
    summary.hidden = true;
    meta.innerHTML = "";
    meta.hidden = true;
    diffPreview.innerHTML = "";
    diffPreview.hidden = true;
    browserMeta.innerHTML = "";
    browserMeta.hidden = true;
    browserTargetList.innerHTML = "";
    browserTargetList.hidden = true;
    browserFrame.src = "about:blank";
    browserSurface.hidden = true;
    tabs.innerHTML = "";
    code.textContent = "No backend preview cached.";
    code.hidden = false;
    renderEditorStatusbar(statusbar, [
      { label: "Surface", value: "Idle" },
      { label: "Files", value: "0 projected" },
    ]);
    popoutButton.disabled = true;
    return;
  }
  if (selected && !previewModeActive) {
    selectedEditorKey = selected.key;
  }
  const selectedTarget = selected ? getEditorTargetByKey(selected.key) : null;
  if (selected && selectedTarget && !desktopEditorFileCache.has(selected.key) && !desktopEditorLoadingPaths.has(selected.key)) {
    void ensureEditorFileLoaded(selectedTarget);
  }
  const selectedWorktreeLabel = selectedTarget?.worktree
    ? getWorktreeLabel(selectedTarget.worktree)
    : "";

  meta.innerHTML = "";
  meta.hidden = true;
  summary.innerHTML = "";
  summary.hidden = true;
  diffPreview.innerHTML = "";
  diffPreview.hidden = true;
  browserMeta.innerHTML = "";
  browserMeta.hidden = true;
  browserTargetList.innerHTML = "";
  browserToolbarSummary.textContent = "";
  browserTargetList.hidden = true;
  browserSurface.hidden = true;
  browserBackButton.disabled = true;
  browserCopyButton.disabled = true;
  browserReloadButton.disabled = true;
  browserOpenButton.disabled = true;
  code.hidden = false;

  if (previewModeActive && previewTarget) {
    title.textContent = "Preview";
    path.textContent = previewTarget.url;
    for (const item of [
      "Preview",
      detachedSurface ? "Detached" : "",
      detachedSurfaceRunLabel,
      previewTarget.portLabel,
      previewTarget.sourceLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.dataset.tone = item === "Preview" ? "focus" : "default";
      chip.textContent = item;
      summary.appendChild(chip);
    }
    summary.hidden = summary.childElementCount === 0;
    if (lastPreviewExternalState?.url === previewTarget.url) {
      const openedAt = new Date(lastPreviewExternalState.at).toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
      });
      const handoffTitle = document.createElement("div");
      handoffTitle.className = "editor-diff-preview-title";
      handoffTitle.textContent = "External browser";
      const handoffBody = document.createElement("div");
      handoffBody.className = "editor-diff-preview-body";
      handoffBody.textContent = lastPreviewExternalState.ok ? `Opened at ${openedAt}` : `Blocked at ${openedAt}`;
      browserMeta.appendChild(handoffTitle);
      browserMeta.appendChild(handoffBody);
      browserMeta.hidden = false;
    }
    if (previewTargets.length > 0) {
      for (const target of previewTargets) {
        const targetButton = document.createElement("button");
        targetButton.type = "button";
        targetButton.className = `editor-tab ${target.url === previewTarget.url ? "is-active" : ""}`;
        targetButton.textContent = target.portLabel;
        targetButton.title = `${target.url} (${target.sourceLabel}, ${formatPreviewSeenAt(target.lastSeenAt)})`;
        targetButton.addEventListener("click", () => {
          openPreviewTarget(target.url);
        });
        browserTargetList.appendChild(targetButton);
      }
      browserTargetList.hidden = false;
    }
    browserToolbarSummary.textContent =
      `${previewTargets.length} targets · active ${previewTarget.portLabel}` +
      ` · from ${previewTarget.sourceLabel}` +
      ` · seen ${formatPreviewSeenAt(previewTarget.lastSeenAt)}` +
      `${lastPreviewExternalState?.url === previewTarget.url ? (lastPreviewExternalState.ok ? " · external open" : " · external blocked") : ""}`;
    if (lastPreviewClipboardState?.url === previewTarget.url) {
      browserToolbarSummary.textContent += lastPreviewClipboardState.ok ? " · copied" : " · copy failed";
    }
    if (browserFrame.dataset.previewUrl !== previewTarget.url) {
      browserFrame.src = previewTarget.url;
      browserFrame.dataset.previewUrl = previewTarget.url;
    }
    browserSurface.hidden = false;
    browserBackButton.disabled = false;
    browserCopyButton.disabled = !Boolean(navigator.clipboard);
    browserReloadButton.disabled = false;
    browserOpenButton.disabled = false;
    code.textContent = "";
    code.hidden = true;
    renderEditorStatusbar(statusbar, [
      { label: "Surface", value: "Preview" },
      ...(detachedSurface ? [{ label: "Window", value: "Detached" }] : []),
      ...(detachedSurface && detachedSurfaceRunLabel ? [{ label: "Run", value: detachedSurfaceRunLabel }] : []),
      { label: "Target", value: previewTarget.portLabel },
      { label: "Source", value: previewTarget.sourceLabel },
      { label: "Seen", value: formatPreviewSeenAt(previewTarget.lastSeenAt) },
      ...(lastPreviewExternalState?.url === previewTarget.url
        ? [{ label: "External", value: lastPreviewExternalState.ok ? "Opened" : "Blocked" }]
        : []),
    ]);
    popoutButton.disabled = false;
  } else if (selected) {
    title.textContent = selectedTarget?.sourceChange ? "Diff review" : "Editor";
    path.textContent = selected.path;
    for (const item of [
      "Code",
      detachedSurface ? "Detached" : "",
      detachedSurfaceRunLabel,
      selected.origin === "context" ? "Run context" : "Explorer",
      selectedWorktreeLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.dataset.tone = item === "Code" ? "focus" : "default";
      chip.textContent = item;
      summary.appendChild(chip);
    }
    if (selectedTarget?.sourceChange) {
      const diffChip = document.createElement("span");
      diffChip.className = "editor-meta-chip";
      diffChip.dataset.tone = "focus";
      diffChip.textContent = "Diff review";
      summary.appendChild(diffChip);
    }
    summary.hidden = summary.childElementCount === 0;
    for (const item of [
      selected.language,
      `${selected.lineCount} lines`,
      selected.modified ? "Modified" : "Saved",
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = `editor-meta-chip ${item === "Modified" ? "is-modified" : ""}`;
      chip.dataset.tone = item === "Modified" ? "focus" : "default";
      chip.textContent = item;
      meta.appendChild(chip);
    }
    meta.hidden = meta.childElementCount === 0;
    if (selectedTarget?.sourceChange) {
      const previewTitle = document.createElement("div");
      previewTitle.className = "editor-diff-preview-title";
      previewTitle.textContent = "Diff preview";
    const previewBody = document.createElement("div");
    previewBody.className = "editor-diff-preview-body";
    previewBody.textContent = selectedTarget.sourceChange.summary;
    const previewMeta = document.createElement("div");
    previewMeta.className = "editor-diff-preview-meta";
    for (const item of [
      selectedTarget.sourceChange.status,
      selectedTarget.sourceChange.lines,
      selectedTarget.sourceChange.branch,
      selectedTarget.sourceChange.review,
      selectedTarget.sourceChange.paneLabel,
    ]) {
      if (!item) {
        continue;
      }
      const chip = document.createElement("span");
      chip.className = "editor-meta-chip";
      chip.textContent = item;
      previewMeta.appendChild(chip);
    }
      diffPreview.appendChild(previewTitle);
      diffPreview.appendChild(previewBody);
      diffPreview.appendChild(previewMeta);
      diffPreview.hidden = false;
    }
    code.textContent = selected.content;
    renderEditorStatusbar(statusbar, [
      { label: "Surface", value: selectedTarget?.sourceChange ? "Diff review" : "Editor" },
      ...(detachedSurface ? [{ label: "Window", value: "Detached" }] : []),
      ...(detachedSurface && detachedSurfaceRunLabel ? [{ label: "Run", value: detachedSurfaceRunLabel }] : []),
      { label: "Source", value: selected.origin === "context" ? "Run context" : "Explorer" },
      ...(selectedWorktreeLabel ? [{ label: "Worktree", value: selectedWorktreeLabel }] : []),
    ]);
    popoutButton.disabled = false;
  }
  tabs.innerHTML = "";

  for (const editor of editors) {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = `editor-tab ${editor.key === selected.key ? "is-active" : ""}`;
    tab.textContent = editor.path.split("/").pop() ?? editor.path;
    tab.addEventListener("click", () => {
      void openEditorTarget(getEditorTargetByKey(editor.key));
    });
    tabs.appendChild(tab);
  }
}

function renderEditorStatusbar(
  root: HTMLElement,
  items: Array<{ label: string; value: string }>,
) {
  root.innerHTML = "";
  for (const item of items) {
    const entry = document.createElement("span");
    entry.className = "editor-status-item";

    const label = document.createElement("span");
    label.className = "editor-status-label";
    label.textContent = item.label;

    const value = document.createElement("span");
    value.className = "editor-status-value";
    value.textContent = item.value;

    entry.appendChild(label);
    entry.appendChild(value);
    root.appendChild(entry);
  }
}

function getConversationItems() {
  return [...backendConversation, ...runtimeConversation];
}

function appendRuntimeConversation(item: ConversationItem) {
  const lastItem = runtimeConversation[runtimeConversation.length - 1];
  if (
    lastItem &&
    lastItem.type === item.type &&
    lastItem.title === item.title &&
    lastItem.body === item.body &&
    lastItem.runId === item.runId
  ) {
    return;
  }

  runtimeConversation.push(item);
  if (runtimeConversation.length > MAX_RUNTIME_CONVERSATION_ITEMS) {
    runtimeConversation.splice(0, runtimeConversation.length - MAX_RUNTIME_CONVERSATION_ITEMS);
  }
}

function getExplainPayloadFingerprint(payload: DesktopExplainPayload | null | undefined) {
  if (!payload) {
    return "";
  }

  const observationPack = getObservationPack(payload);
  const consultationPacket = getConsultationPacket(payload);
  const consultationSummary = getConsultationSummary(payload);

  return JSON.stringify([
    payload.run.run_id,
    payload.run.task_id,
    payload.run.parent_run_id,
    payload.run.goal,
    payload.run.task_type,
    payload.run.priority,
    payload.run.blocking,
    payload.run.state,
    payload.run.task_state,
    payload.run.review_state,
    payload.run.provider_target,
    payload.run.agent_role,
    payload.run.branch,
    payload.run.head_sha,
    payload.run.worktree,
    payload.run.primary_label,
    payload.run.primary_pane_id,
    payload.run.primary_role,
    payload.run.last_event,
    payload.run.last_event_at,
    payload.run.tokens_remaining,
    payload.run.pane_count,
    payload.run.changed_file_count,
    payload.run.labels.join("|"),
    payload.run.pane_ids.join("|"),
    payload.run.roles.join("|"),
    payload.run.write_scope.join("|"),
    payload.run.read_scope.join("|"),
    payload.run.constraints.join("|"),
    payload.run.expected_output,
    payload.run.verification_plan.join("|"),
    payload.run.review_required,
    payload.run.timeout_policy,
    payload.run.handoff_refs.join("|"),
    payload.run.experiment_packet.hypothesis,
    payload.run.experiment_packet.test_plan.join("|"),
    payload.run.experiment_packet.result,
    payload.run.experiment_packet.confidence,
    payload.run.experiment_packet.next_action,
    payload.run.experiment_packet.observation_pack_ref,
    payload.run.experiment_packet.consultation_ref,
    payload.run.experiment_packet.run_id,
    payload.run.experiment_packet.slot,
    payload.run.experiment_packet.branch,
    payload.run.experiment_packet.worktree,
    payload.run.experiment_packet.env_fingerprint,
    payload.run.experiment_packet.command_hash,
    JSON.stringify(payload.run.security_policy),
    JSON.stringify(payload.run.security_verdict),
    JSON.stringify(payload.run.verification_contract),
    JSON.stringify(payload.run.verification_result),
    payload.run.changed_files.join("|"),
    payload.run.action_items.map((item) => `${item.kind}:${item.event}:${item.source}`).join("|"),
    payload.explanation.summary,
    payload.explanation.next_action,
    payload.explanation.reasons.join("|"),
    payload.explanation.current_state.state,
    payload.explanation.current_state.task_state,
    payload.explanation.current_state.review_state,
    payload.explanation.current_state.last_event,
    observationPack.run_id,
    observationPack.task_id,
    observationPack.pane_id,
    observationPack.slot,
    observationPack.hypothesis,
    observationPack.test_plan.join("|"),
    observationPack.changed_files.join("|"),
    observationPack.working_tree_summary,
    observationPack.failing_command,
    observationPack.env_fingerprint,
    observationPack.command_hash,
    observationPack.generated_at,
    consultationPacket.run_id,
    consultationPacket.task_id,
    consultationPacket.pane_id,
    consultationPacket.slot,
    consultationPacket.kind,
    consultationPacket.mode,
    consultationPacket.target_slot,
    consultationPacket.confidence,
    consultationPacket.recommendation,
    consultationPacket.next_test,
    consultationPacket.risks.join("|"),
    consultationPacket.generated_at,
    consultationSummary.kind,
    consultationSummary.mode,
    consultationSummary.target_slot,
    consultationSummary.confidence,
    consultationSummary.next_test,
    consultationSummary.risks.join("|"),
    payload.evidence_digest.next_action,
    payload.evidence_digest.verification_outcome,
    payload.evidence_digest.security_blocked,
    payload.evidence_digest.changed_files.join("|"),
    payload.recent_events.map((item) => `${item.event}:${item.message}`).join("|"),
  ]);
}

function getObservationPack(payload: DesktopExplainPayload): DesktopExplainPayload["observation_pack"] {
  const pack = (
    payload as DesktopExplainPayload & {
      observation_pack?: DesktopExplainPayload["observation_pack"];
    }
  ).observation_pack;
  return (
    pack ?? {
      run_id: "",
      task_id: "",
      pane_id: "",
      slot: "",
      hypothesis: "",
      test_plan: [],
      changed_files: [],
      working_tree_summary: "",
      failing_command: "",
      env_fingerprint: "",
      command_hash: "",
      generated_at: "",
    }
  );
}

function getConsultationPacket(payload: DesktopExplainPayload): DesktopExplainPayload["consultation_packet"] {
  const packet = (
    payload as DesktopExplainPayload & {
      consultation_packet?: DesktopExplainPayload["consultation_packet"];
    }
  ).consultation_packet;
  return (
    packet ?? {
      run_id: "",
      task_id: "",
      pane_id: "",
      slot: "",
      kind: "",
      mode: "",
      target_slot: "",
      confidence: 0,
      recommendation: "",
      next_test: "",
      risks: [],
      generated_at: "",
    }
  );
}

function getConsultationSummary(payload: DesktopExplainPayload): {
  kind: string;
  mode: string;
  target_slot: string;
  confidence: number;
  next_test: string;
  risks: string[];
} {
  const packet = getConsultationPacket(payload);
  return {
    kind: packet.kind,
    mode: packet.mode,
    target_slot: packet.target_slot,
    confidence: packet.confidence,
    next_test: packet.next_test,
    risks: packet.risks,
  };
}

function summarizeChangedFiles(paths: string[], limit = 3) {
  const visible = paths.filter((value) => Boolean(value)).slice(0, limit);
  if (visible.length === 0) {
    return "";
  }

  const remaining = paths.length - visible.length;
  return remaining > 0 ? `${visible.join(", ")} +${remaining} more` : visible.join(", ");
}

function buildExperimentFileLine(
  label: string,
  paths: string[],
  worktree: string,
): ExperimentDetailLine {
  const path = paths.find((value) => Boolean(value));
  return {
    label,
    value: paths.length > 0 ? summarizeChangedFiles(paths, 4) : "none",
    path: path || undefined,
    worktree: path ? worktree : undefined,
    title: path ? `Open ${path} in the read-only editor.` : undefined,
  };
}

function summarizeWorkspaceContext(branch: string, worktree: string) {
  const parts = [branch, worktree].filter((value) => Boolean(value));
  return parts.join(" @ ");
}

function summarizeReviewVerdict(payload: DesktopExplainPayload) {
  const status = payload.review_state?.status || payload.run.review_state;
  if (!status) {
    return "";
  }

  const parts = [status];
  if (payload.review_state?.reviewer?.label) {
    parts.push(`by ${payload.review_state.reviewer.label}`);
  }

  const evidence = payload.review_state?.evidence;
  const evidenceSource =
    (status === "PASS" ? evidence?.approved_via : undefined) ||
    ((status === "FAIL" || status === "FAILED") ? evidence?.failed_via : undefined);
  if (evidenceSource) {
    parts.push(`via ${evidenceSource}`);
  }

  return parts.join(" ");
}

function summarizeProjectionExperiment(projection: DesktopRunProjection) {
  if (!projection.hypothesis) {
    return "";
  }

  const parts = [`Hypothesis ${projection.hypothesis}`];
  if (projection.confidence !== null) {
    parts.push(`confidence ${formatConfidencePercent(projection.confidence)}`);
  }

  return parts.join(" · ");
}

function summarizeProjectionConsultation(projection: DesktopRunProjection) {
  if (!projection.consultation_ref) {
    return "";
  }

  const parts = [summarizeProjectionExperiment(projection) || "Consultation linked"];
  parts.push(`Next ${projection.next_action || "idle"}`);
  const reasons = projection.reasons.filter((value) => Boolean(value)).slice(0, 2);
  if (reasons.length > 0) {
    parts.push(`Reasons ${reasons.join(" | ")}`);
  }

  return parts.join(" · ");
}

function formatConfidencePercent(value: number) {
  return `${Math.round(value * 100)}%`;
}

function summarizeArtifactRef(path: string) {
  if (!path) {
    return "";
  }

  const parts = path.split(/[\\/]/).filter((value) => Boolean(value));
  return parts[parts.length - 1] || path;
}

function getRunProjectionFingerprint(projection: DesktopRunProjection | null | undefined) {
  if (!projection) {
    return "";
  }

  return JSON.stringify([
    projection.label,
    projection.head_sha,
    projection.head_short,
    projection.worktree,
    projection.review_state,
    projection.next_action,
    projection.verification_outcome,
    projection.security_blocked,
    projection.branch,
    projection.provider_target,
    projection.changed_files.join("|"),
    projection.hypothesis,
    projection.confidence,
  ]);
}

function getBoardPaneFingerprint(pane: DesktopBoardPane) {
  return JSON.stringify([
    pane.label,
    pane.role,
    pane.state,
    pane.task_state,
    pane.review_state,
    pane.branch,
    pane.worktree,
    pane.head_sha,
    pane.changed_file_count,
    pane.last_event_at,
  ]);
}

function diffDesktopSummarySnapshots(
  previousSnapshot: DesktopSummarySnapshot | null,
  nextSnapshot: DesktopSummarySnapshot,
) {
  if (!previousSnapshot) {
    return {
      hasMeaningfulChange: true,
      changedRunIds: [] as string[],
      inboxCountChanged: false,
      addedRunIds: [] as string[],
      removedRunIds: [] as string[],
    };
  }

  const previousProjectionMap = new Map(
    previousSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const nextProjectionMap = new Map(
    nextSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const previousBoardPaneMap = new Map(
    previousSnapshot.board.panes.map((pane) => [pane.pane_id, pane]),
  );
  const nextBoardPaneMap = new Map(
    nextSnapshot.board.panes.map((pane) => [pane.pane_id, pane]),
  );

  const changedRunIds: string[] = [];
  const addedRunIds: string[] = [];
  const removedRunIds: string[] = [];
  let boardPaneChanged = previousSnapshot.board.panes.length !== nextSnapshot.board.panes.length;

  for (const [runId, nextProjection] of nextProjectionMap) {
    const previousProjection = previousProjectionMap.get(runId);
    if (!previousProjection) {
      addedRunIds.push(runId);
      continue;
    }

    if (getRunProjectionFingerprint(previousProjection) !== getRunProjectionFingerprint(nextProjection)) {
      changedRunIds.push(runId);
    }
  }

  for (const runId of previousProjectionMap.keys()) {
    if (!nextProjectionMap.has(runId)) {
      removedRunIds.push(runId);
    }
  }

  if (!boardPaneChanged) {
    for (const [paneId, nextPane] of nextBoardPaneMap) {
      const previousPane = previousBoardPaneMap.get(paneId);
      if (!previousPane) {
        boardPaneChanged = true;
        break;
      }

      if (getBoardPaneFingerprint(previousPane) !== getBoardPaneFingerprint(nextPane)) {
        boardPaneChanged = true;
        break;
      }
    }
  }

  const inboxCountChanged =
    previousSnapshot.inbox.summary.item_count !== nextSnapshot.inbox.summary.item_count;

  return {
    hasMeaningfulChange:
      boardPaneChanged ||
      inboxCountChanged ||
      addedRunIds.length > 0 ||
      removedRunIds.length > 0 ||
      changedRunIds.length > 0,
    boardPaneChanged,
    changedRunIds,
    inboxCountChanged,
    addedRunIds,
    removedRunIds,
  };
}

function buildDesktopFollowConversation(
  previousSnapshot: DesktopSummarySnapshot | null,
  nextSnapshot: DesktopSummarySnapshot,
) {
  const diff = diffDesktopSummarySnapshots(previousSnapshot, nextSnapshot);
  if (!previousSnapshot || !diff.hasMeaningfulChange) {
    return [];
  }

  const timestamp = new Date(nextSnapshot.generated_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const previousProjectionMap = new Map(
    previousSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const nextProjectionMap = new Map(
    nextSnapshot.run_projections.map((projection) => [projection.run_id, projection]),
  );
  const selected = resolveSelectedRunId(nextSnapshot);
  const prioritizedChangedRunIds = [
    ...diff.changedRunIds.filter((runId) => runId === selected),
    ...diff.addedRunIds.filter((runId) => runId === selected),
    ...diff.changedRunIds.filter((runId) => runId !== selected),
    ...diff.addedRunIds.filter((runId) => runId !== selected),
  ]
    .map((runId, index) => {
      const projection = nextProjectionMap.get(runId);
      const selectedRank = runId === selected ? 0 : 1;
      const signalRank = projection?.consultation_ref ? 0 : projection?.hypothesis ? 1 : 2;
      const sourceRank = diff.changedRunIds.includes(runId) ? 0 : 1;
      return { runId, index, selectedRank, signalRank, sourceRank };
    })
    .sort((left, right) => {
      if (left.selectedRank !== right.selectedRank) {
        return left.selectedRank - right.selectedRank;
      }
      if (left.signalRank !== right.signalRank) {
        return left.signalRank - right.signalRank;
      }
      if (left.sourceRank !== right.sourceRank) {
        return left.sourceRank - right.sourceRank;
      }
      return left.index - right.index;
    })
    .map((item) => item.runId)
    .slice(0, 3);

  const items: ConversationItem[] = [];
  for (const runId of prioritizedChangedRunIds) {
    const projection = nextProjectionMap.get(runId);
    if (!projection) {
      continue;
    }
    const experimentSummary = summarizeProjectionExperiment(projection);
    const consultationSummary = summarizeProjectionConsultation(projection);
    const tone: SurfaceTone = consultationSummary
      ? "focus"
      : experimentSummary
        ? "accent"
        : projection.review_state === "PASS"
          ? "success"
          : projection.review_state === "PENDING"
            ? "warning"
            : "info";
    const statusLabel = consultationSummary
      ? "consultation"
      : experimentSummary
        ? "hypothesis"
        : projection.next_action || undefined;
    const title = consultationSummary
      ? (diff.addedRunIds.includes(runId) ? "Consultation surfaced" : "Consultation updated")
      : experimentSummary
      ? (diff.addedRunIds.includes(runId) ? "Hypothesis surfaced" : "Hypothesis updated")
      : (diff.addedRunIds.includes(runId) ? "Run surfaced" : "Run updated");

    items.push({
      type: "system",
      category:
        projection.review_state === "PENDING" ||
        projection.review_state === "FAIL" ||
        projection.review_state === "FAILED"
          ? "review"
          : "activity",
      timestamp,
      actor: projection.label || projection.pane_id || "System",
      title,
      body: consultationSummary
        ? `Consultation: ${consultationSummary}`
        : experimentSummary
        ? `Hypothesis: ${experimentSummary}`
        : `Run: ${projection.next_action || "idle"}`,
      details: [
        ...((consultationSummary || experimentSummary) && projection.changed_files.length > 0
          ? [
              {
                label: "files",
                value: `${projection.changed_files.length}: ${summarizeChangedFiles(projection.changed_files)}`,
              },
            ]
          : []),
        ...(projection.review_state
          ? [{ label: "review", value: projection.review_state }]
          : []),
        ...((consultationSummary || experimentSummary) && projection.head_short
          ? [{ label: "head", value: projection.head_short }]
          : []),
        ...((consultationSummary || experimentSummary)
          ? [{ label: "branch", value: projection.branch || "no branch" }]
          : []),
        ...(!(consultationSummary || experimentSummary) && projection.changed_files.length > 0
          ? [{ label: "changed", value: `${projection.changed_files.length}` }]
          : []),
        ...(projection.verification_outcome
          ? [{ label: "verify", value: projection.verification_outcome }]
          : []),
        ...((consultationSummary || experimentSummary)
          ? [{ label: "next", value: projection.next_action || "idle" }]
          : []),
        ...(!(consultationSummary || experimentSummary) && projection.head_short
          ? [{ label: "head", value: projection.head_short }]
          : []),
        ...(!(consultationSummary || experimentSummary)
          ? [{ label: "branch", value: projection.branch || "no branch" }]
          : []),
        ...(projection.consultation_ref
          ? [{ label: "consultation", value: summarizeArtifactRef(projection.consultation_ref) }]
          : []),
        ...(projection.hypothesis
          ? [{ label: "hypothesis", value: projection.hypothesis }]
          : []),
      ],
      tone,
      runId,
      statusLabel,
    });
  }

  for (const runId of diff.removedRunIds.slice(0, 2)) {
    const previousProjection = previousProjectionMap.get(runId);
    if (!previousProjection) {
      continue;
    }

    items.push({
      type: "system",
      category: "attention",
      timestamp,
      actor: previousProjection.label || previousProjection.pane_id || "System",
      title: "Run removed",
      body: `Run ${runId} dropped out of the desktop summary snapshot.`,
      details: [
        { label: "branch", value: previousProjection.branch || "no branch" },
        ...(previousProjection.head_short ? [{ label: "head", value: previousProjection.head_short }] : []),
      ],
      tone: "warning",
      runId,
      statusLabel: previousProjection.review_state || undefined,
    });
  }

  if (diff.inboxCountChanged) {
    items.push({
      type: "system",
      category: "attention",
      timestamp,
      actor: "System",
      title: "Inbox changed",
      body: `Inbox items moved from ${previousSnapshot.inbox.summary.item_count} to ${nextSnapshot.inbox.summary.item_count}.`,
      details: [{ label: "inbox", value: `${nextSnapshot.inbox.summary.item_count}` }],
      tone: "warning",
    });
  }

  return items.slice(0, 4);
}

function setTerminalDrawer(open: boolean) {
  terminalDrawerOpen = open;
  const drawer = document.getElementById("terminal-drawer");
  const button = document.getElementById("toggle-terminal-btn");
  if (!drawer || !button) {
    return;
  }

  drawer.hidden = !open;
  setCompactButtonLabel(button, open ? "Hide" : "Terminal");
  button.setAttribute("aria-expanded", open ? "true" : "false");
  button.setAttribute("aria-label", open ? "Hide terminal drawer" : "Open terminal drawer");

  if (open && panes.size === 0) {
    createPane("main");
  }

  requestAnimationFrame(() => {
    panes.forEach((pane) => pane.fitAddon.fit());
  });
}

function setContextPanel(open: boolean, options?: { preserveWidePreference?: boolean }) {
  contextPanelOpen = open;
  const panel = document.getElementById("context-panel");
  const button = document.getElementById("toggle-context-btn");
  const body = document.getElementById("workspace-body");
  if (!panel || !button || !body) {
    return;
  }

  if ((options?.preserveWidePreference ?? true) && !isNarrowLayout()) {
    preferredWideContextOpen = open;
    void persistThemeState();
  }

  panel.toggleAttribute("hidden", !open);
  body.classList.toggle("context-collapsed", !open);
  setCompactButtonLabel(button, open ? "Hide" : "Context");
  button.setAttribute("aria-expanded", open ? "true" : "false");
  button.setAttribute("aria-label", open ? "Hide context panel" : "Show context panel");
}

function setCompactButtonLabel(button: Element, label: string) {
  const labelNode = button.querySelector(".btn-label");
  if (labelNode) {
    labelNode.textContent = label;
    return;
  }

  button.textContent = label;
}

function setEditorSurface(open: boolean) {
  editorSurfaceOpen = open;
  const panel = document.getElementById("editor-surface");
  const body = document.getElementById("workspace-body");
  if (!panel || !body) {
    return;
  }

  panel.toggleAttribute("hidden", !open);
  body.classList.toggle("editor-open", open);
  renderEditorSurface();
  renderOpenEditors();
  renderContextPanel();
}

function isNarrowLayout() {
  return window.matchMedia("(max-width: 1366px)").matches;
}

function setSidebarOpen(open: boolean, options?: { preserveWidePreference?: boolean }) {
  sidebarOpen = open;
  const shell = document.getElementById("app-shell");
  const overlay = document.getElementById("sidebar-overlay");
  const button = document.getElementById("toggle-sidebar-btn");
  if (!shell || !overlay || !button) {
    return;
  }

  if ((options?.preserveWidePreference ?? true) && !isNarrowLayout()) {
    preferredWideSidebarOpen = open;
    void persistThemeState();
  }

  shell.classList.toggle("sidebar-open", open);
  overlay.hidden = !(open && isNarrowLayout());
  button.setAttribute("aria-expanded", open ? "true" : "false");
}

function setSettingsSheet(open: boolean) {
  const sheet = document.getElementById("settings-sheet");
  if (!sheet) {
    return;
  }

  if (open && commandBarOpen) {
    closeCommandBar();
  }

  settingsSheetOpen = open;
  if (open) {
    if (!settingsDraftState) {
      settingsDraftState = cloneThemeState(themeState);
    }
    renderSettingsControls();
  }
  sheet.hidden = !open;
  renderFooterLane();
}

function applySettingsDraft() {
  if (settingsDraftState) {
    applyThemeState(settingsDraftState);
    persistThemeState();
  }
  settingsDraftState = null;
  setSettingsSheet(false);
}

function cancelSettingsDraft() {
  settingsDraftState = null;
  setSettingsSheet(false);
}

function syncResponsiveShell() {
  if (isNarrowLayout()) {
    setSidebarOpen(false, { preserveWidePreference: false });
    setContextPanel(false, { preserveWidePreference: false });
  } else {
    setSidebarOpen(preferredWideSidebarOpen, { preserveWidePreference: false });
    setContextPanel(preferredWideContextOpen, { preserveWidePreference: false });
  }
}

function installViewportHarnessHooks() {
  const searchParams = new URLSearchParams(window.location.search);
  if (searchParams.get("viewport-harness") !== "1") {
    return;
  }

  window.__winsmuxViewportHarness = {
    registerPreviewTarget: (sourceLabel: string, url: string) => {
      registerPreviewTargetForHarness(sourceLabel, url);
    },
    openPreviewTarget: (url: string) => {
      openPreviewTarget(url);
    },
    openEditorPreview: (path: string, content: string, worktree?: string) => {
      openEditorPreviewForHarness(path, content, worktree);
    },
    setContextPanel: (open: boolean) => {
      setContextPanel(open);
    },
    setTerminalDrawer: (open: boolean) => {
      setTerminalDrawer(open);
    },
  };
}

function appendUserMessage(message: string, attachments: ComposerAttachment[]) {
  const now = new Date();
  const timestamp = `${`${now.getHours()}`.padStart(2, "0")}:${`${now.getMinutes()}`.padStart(2, "0")}`;
  appendRuntimeConversation({
    type: "user",
    category: "user",
    timestamp,
    actor: "User",
    body: message || "Attached files for dispatch.",
    attachments: attachments.map((attachment) => ({
      name: attachment.name,
      kind: attachment.kind,
      sizeLabel: attachment.sizeLabel,
    })),
  });
  appendRuntimeConversation({
    type: "operator",
    category: "activity",
    timestamp,
    actor: "Operator",
    title: "Queued for dispatch",
    body: "The request is now part of the operator feed. Open Explain, inspect changed files, or use the terminal drawer only if raw PTY detail becomes necessary.",
    details: [
      { label: "mode", value: activeComposerMode },
      { label: "attachments", value: `${attachments.length}` },
    ],
    tone: "info",
  });
  renderRunSummary();
  renderConversation(getConversationItems());
}

function findEditorFile(target: EditorTarget | null) {
  if (!target) {
    return null;
  }

  const existing = desktopEditorFileCache.get(target.key);
  if (existing) {
    return existing;
  }

  const loading = desktopEditorLoadingPaths.has(target.key);
  const loadError = desktopEditorLoadErrors.get(target.key);
  const previewBody = loadError
    ? `Backend preview failed to load.\n\n${loadError}`
    : loading
      ? "Backend preview request in flight."
      : "No backend preview cached.";

  return {
    key: target.key,
    path: target.path,
    summary: target.summary,
    content: `${previewBody}\n`,
    language: inferLanguageFromPath(target.path),
    lineCount: countEditorLines(previewBody),
    modified: target.modified,
    origin: target.origin,
  };
}

function countEditorLines(content: string) {
  return content.split(/\r?\n/).length;
}

function getUpperRecordField(record: Record<string, unknown> | null | undefined, key: string) {
  const value = record?.[key];
  return typeof value === "string" ? value.toUpperCase() : "";
}

function isDesktopRunPromotable(run: DesktopExplainPayload["run"]) {
  const taskState = (run.task_state || "").toLowerCase();
  const reviewState = (run.review_state || "").toUpperCase();
  const verificationOutcome = getUpperRecordField(run.verification_result, "outcome");
  const securityVerdict = getUpperRecordField(run.security_verdict, "verdict");

  if (!["completed", "task_completed", "commit_ready", "done"].includes(taskState)) {
    return false;
  }
  if (reviewState && reviewState !== "PASS") {
    return false;
  }
  if (verificationOutcome !== "PASS") {
    return false;
  }
  if (!["ALLOW", "PASS"].includes(securityVerdict)) {
    return false;
  }

  return true;
}

function buildCachedEditorFile(
  target: EditorTarget,
  payload: DesktopEditorFilePayload,
): EditorFile {
  const summary = payload.truncated
    ? `${target.summary} · preview truncated`
    : target.summary;
  return {
    key: target.key,
    path: payload.path,
    summary,
    content: payload.content,
    language: inferLanguageFromPath(payload.path),
    lineCount: payload.line_count || countEditorLines(payload.content),
    modified: target.modified,
    origin: target.origin,
  };
}

function getEditorFiles() {
  const targets = new Map<string, EditorTarget>();
  for (const entry of getProjectionSourceEntries()) {
    const target = getEditorTargetForSourceChange(entry);
    if (target) {
      targets.set(target.key, target);
    }
  }
  for (const [key, target] of desktopStandaloneEditorTargets) {
    if (!targets.has(key)) {
      targets.set(key, target);
    }
  }

  return Array.from(targets.values()).map((target) => findEditorFile(target)).filter((item): item is EditorFile => Boolean(item));
}

async function ensureEditorFileLoaded(target: EditorTarget | null) {
  if (!target) {
    return;
  }

  if (!target.path || desktopEditorFileCache.has(target.key) || desktopEditorLoadingPaths.has(target.key)) {
    return;
  }

  desktopEditorLoadingPaths.add(target.key);
  desktopEditorLoadErrors.delete(target.key);
  renderEditorSurface();
  renderOpenEditors();

  try {
    const payload = await getDesktopEditorFile(target.path, target.worktree || undefined);
    desktopEditorFileCache.set(target.key, buildCachedEditorFile(target, payload));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    desktopEditorLoadErrors.set(target.key, message);
  } finally {
    desktopEditorLoadingPaths.delete(target.key);
    renderEditorSurface();
    renderOpenEditors();
    renderSourceSummary();
    renderContextPanel();
    renderSourceEntries();
    renderRunSummary();
  }
}

async function openEditorTarget(target: EditorTarget | null) {
  if (!target) {
    setEditorSurface(true);
    return;
  }

  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  selectedEditorKey = target.key;
  setSelectedRun(target.sourceChange?.run ?? selectedRunId);
  setEditorSurface(true);
  renderSourceSummary();
  renderRunSummary();
  await ensureEditorFileLoaded(target);
}

async function openEditorSourceChange(sourceChange: SourceChange | undefined) {
  await openEditorTarget(getEditorTargetForSourceChange(sourceChange));
}

async function openEditorPath(path: string | undefined, worktree = "") {
  if (!path) {
    await openEditorSourceChange(getPrimarySourceChange(getVisibleSourceChanges()));
    return;
  }

  const sourceChange = findSourceChangeByPath(path, worktree);
  if (sourceChange) {
    setSelectedRun(sourceChange.run);
    await openEditorSourceChange(sourceChange);
    return;
  }

  const target = createStandaloneEditorTarget(path, worktree);
  desktopStandaloneEditorTargets.set(target.key, target);
  editorSurfaceMode = "code";
  selectedPreviewUrl = "";
  lastPreviewExternalState = null;
  selectedEditorKey = target.key;
  setEditorSurface(true);
  renderOpenEditors();
  renderEditorSurface();
  await ensureEditorFileLoaded(target);
}

function inferLanguageFromPath(path: string) {
  if (path.endsWith(".ts")) {
    return "TypeScript";
  }
  if (path.endsWith(".css")) {
    return "CSS";
  }
  if (path.endsWith(".html")) {
    return "HTML";
  }
  if (path.endsWith(".ps1")) {
    return "PowerShell";
  }
  return "Text";
}

function buildDesktopSummaryConversation(snapshot: DesktopSummarySnapshot): ConversationItem[] {
  const board = snapshot.board.summary;
  const digest = snapshot.digest.summary;
  const inbox = snapshot.inbox.summary;
  const topInboxItems = snapshot.inbox.items.slice(0, 2);
  const topDigestItems = snapshot.run_projections.slice(0, 3);

  const items: ConversationItem[] = [
    {
      type: "operator",
      category: "activity",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: "Operator",
      title: "Summary stream connected",
      body: "Tauri is reading board, inbox, and digest surfaces from the backend adapter instead of treating raw PTY output as the primary UI source.",
      details: [
        { label: "panes", value: `${board.pane_count}` },
        { label: "inbox", value: `${inbox.item_count}` },
        { label: "runs", value: `${digest.item_count}` },
      ],
      tone: "info",
    },
  ];

  for (const topInboxItem of topInboxItems) {
    items.push({
      type: "system",
      category: "attention",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: topInboxItem.label || topInboxItem.pane_id || "System",
      title: `Inbox: ${topInboxItem.kind}`,
      body: topInboxItem.message,
      details: [
        { label: "branch", value: topInboxItem.branch || "no branch" },
        { label: "review", value: topInboxItem.review_state || "n/a" },
        { label: "task", value: topInboxItem.task_state || "n/a" },
      ],
      tone: "warning",
      statusLabel: topInboxItem.kind,
    });
  }

  for (const digestItem of topDigestItems) {
    items.push({
      type: "operator",
      category: digestItem.review_state === "PENDING" || digestItem.review_state === "FAIL" || digestItem.review_state === "FAILED" ? "review" : "activity",
      timestamp: new Date(snapshot.generated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }),
      actor: digestItem.label || digestItem.pane_id || "Operator",
      title: digestItem.task || "Projected run",
      body: `Next ${digestItem.next_action || "idle"} · ${digestItem.changed_files.length} changed files · review ${digestItem.review_state || "n/a"}.`,
      details: [
        { label: "run", value: digestItem.run_id },
        { label: "branch", value: digestItem.branch || "no branch" },
        { label: "verify", value: digestItem.verification_outcome || "n/a" },
      ],
      tone: digestItem.review_state === "PASS" ? "success" : digestItem.review_state === "PENDING" ? "warning" : "info",
      runId: digestItem.run_id,
      statusLabel: digestItem.review_state || digestItem.next_action || undefined,
      chips: [
        { label: "Open Explain", action: "open-explain" },
        { label: "Source Context", action: "open-source-context" },
      ],
    });
  }

  return items;
}

function pruneExplainCache(snapshot: DesktopSummarySnapshot, preservedRunId?: string | null) {
  const activeRunIds = new Set(snapshot.run_projections.map((projection) => projection.run_id));
  if (preservedRunId) {
    activeRunIds.add(preservedRunId);
  }

  for (const runId of Array.from(desktopExplainCache.keys())) {
    if (!activeRunIds.has(runId)) {
      desktopExplainCache.delete(runId);
    }
  }

  for (const pairKey of Array.from(desktopRunCompareCache.keys())) {
    const [leftRunId, rightRunId] = pairKey.split("::");
    if (!activeRunIds.has(leftRunId) || !activeRunIds.has(rightRunId)) {
      desktopRunCompareCache.delete(pairKey);
    }
  }

  for (const runId of Array.from(promotedRunCandidates.keys())) {
    if (!activeRunIds.has(runId)) {
      promotedRunCandidates.delete(runId);
    }
  }
}

function renderDesktopSurfaces() {
  renderPaneMetadata();
  renderSessions();
  renderFooterLane();
  renderRunSummary();
  renderSourceSummary();
  renderSourceEntries();
  renderContextPanel();
  renderOpenEditors();
  renderEditorSurface();
  renderConversation(getConversationItems());
}

function formatPaneMetaTime(timestamp: string) {
  const parsed = Date.parse(timestamp);
  if (Number.isNaN(parsed)) {
    return "";
  }

  return new Date(parsed).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatPaneWaitDuration(timestamp: string, now = Date.now()) {
  const parsed = Date.parse(timestamp);
  if (Number.isNaN(parsed)) {
    return "";
  }

  const elapsedMs = Math.max(0, now - parsed);
  const elapsedMinutes = Math.floor(elapsedMs / 60000);
  if (elapsedMinutes < 1) {
    return "<1m wait";
  }
  if (elapsedMinutes < 60) {
    return `${elapsedMinutes}m wait`;
  }

  const hours = Math.floor(elapsedMinutes / 60);
  const minutes = elapsedMinutes % 60;
  if (minutes === 0) {
    return `${hours}h wait`;
  }

  return `${hours}h ${minutes}m wait`;
}

function summarizeBoardPaneStatus(pane: DesktopBoardPane | null) {
  if (!pane) {
    return "";
  }

  const role = pane.role || "pane";
  const taskState = (pane.task_state || "").toLowerCase();
  const reviewState = (pane.review_state || "").toUpperCase();

  if (taskState === "blocked") {
    return `${role} · blocked`;
  }
  if (reviewState === "FAIL" || reviewState === "FAILED") {
    return `${role} · review failed`;
  }
  if (reviewState === "PENDING") {
    return `${role} · review pending`;
  }
  if (reviewState === "PASS") {
    return `${role} · review pass`;
  }
  if (taskState === "commit_ready") {
    return `${role} · commit ready`;
  }
  if (taskState === "completed" || taskState === "task_completed" || taskState === "done") {
    return `${role} · completed`;
  }
  if (pane.task_state) {
    return `${role} · ${pane.task_state}`;
  }

  return role;
}

function renderPaneMetadata() {
  const boardPanes = desktopSummarySnapshot?.board.panes ?? [];
  const now = Date.now();

  panes.forEach((pane, paneId) => {
    const paneRecord = boardPanes.find((item) => item.pane_id === paneId) ?? null;
    const paneLabel = paneRecord?.label || paneId;
    pane.labelElement.textContent = paneLabel;

    const status = summarizeBoardPaneStatus(paneRecord);
    const branch = paneRecord?.branch || "";
    const eventTime = paneRecord?.last_event_at ? formatPaneMetaTime(paneRecord.last_event_at) : "";
    const waitDuration = paneRecord?.last_event_at
      ? formatPaneWaitDuration(paneRecord.last_event_at, now)
      : pane.lastOutputAt
        ? `${formatPreviewSeenAt(pane.lastOutputAt)} · live output`
        : "waiting for summary";

    const parts = [status];
    if (branch) {
      parts.push(branch);
    }
    if (eventTime) {
      parts.push(eventTime);
    }
    parts.push(waitDuration);
    const metaText = parts.filter((value) => Boolean(value)).join(" · ");
    pane.metaElement.textContent = metaText;
    pane.metaElement.title = metaText;
    pane.labelElement.title = paneLabel;
  });
}

async function refreshDesktopSummary(forceExplainRunId?: string | null) {
  if (desktopSummaryRefreshInFlight) {
    return desktopSummaryRefreshInFlight;
  }

  desktopSummaryRefreshInFlight = (async () => {
  try {
    const previousSnapshot = desktopSummarySnapshot;
    const previousSelectedRunId = selectedRunId;
    const snapshot = await getDesktopSummarySnapshot();
    const diff = diffDesktopSummarySnapshots(previousSnapshot, snapshot);
    const invalidatedRunIds = new Set([
      ...diff.changedRunIds,
      ...diff.addedRunIds,
      ...diff.removedRunIds,
    ]);
    for (const pairKey of Array.from(desktopRunCompareCache.keys())) {
      const [leftRunId, rightRunId] = pairKey.split("::");
      if (
        invalidatedRunIds.has(leftRunId) ||
        invalidatedRunIds.has(rightRunId)
      ) {
        desktopRunCompareCache.delete(pairKey);
      }
    }
    for (const runId of invalidatedRunIds) {
      promotedRunCandidates.delete(runId);
    }
    desktopSummaryRefreshSerial += 1;
    desktopSummarySnapshot = snapshot;
    desktopSummaryLastSuccessfulRefreshAt = Date.now();
    selectedRunId = resolveSelectedRunId(snapshot, forceExplainRunId);
    pruneExplainCache(snapshot, forceExplainRunId);
    const selectedRunHasMaterialChange = Boolean(
      selectedRunId &&
        (diff.changedRunIds.includes(selectedRunId) || diff.addedRunIds.includes(selectedRunId)),
    );
    const shouldPrefetchExplain =
      Boolean(selectedRunId) &&
      (
        forceExplainRunId === selectedRunId ||
        !previousSnapshot ||
        selectedRunId !== previousSelectedRunId ||
        !desktopExplainCache.has(selectedRunId ?? "") ||
        selectedRunHasMaterialChange
      );
    if (selectedRunId && shouldPrefetchExplain) {
      try {
        const explainPayload = await getDesktopRunExplain(selectedRunId);
        desktopExplainCache.set(selectedRunId, explainPayload);
      } catch (error) {
        console.warn("Failed to prefetch desktop explain payload", error);
      }
    }

    if (previousSnapshot && !diff.hasMeaningfulChange && !forceExplainRunId && !shouldPrefetchExplain) {
      return;
    }

    backendConversation.splice(0, backendConversation.length, ...buildDesktopSummaryConversation(snapshot));
    for (const item of buildDesktopFollowConversation(previousSnapshot, snapshot)) {
      appendRuntimeConversation(item);
    }
    renderDesktopSurfaces();
    } catch (error) {
      console.warn("Failed to load desktop summary snapshot", error);
    } finally {
      desktopSummaryRefreshInFlight = null;
      if (desktopSummaryRefreshRunningVersion < desktopSummaryRefreshRequestedVersion) {
        flushDesktopSummaryRefreshQueue();
      }
    }
  })();

  return desktopSummaryRefreshInFlight;
}

function flushDesktopSummaryRefreshQueue() {
  if (desktopSummaryRefreshInFlight) {
    return;
  }

  if (desktopSummaryRefreshRunningVersion >= desktopSummaryRefreshRequestedVersion) {
    return;
  }

  const queuedRunId = desktopSummaryQueuedRunId;
  desktopSummaryQueuedRunId = null;
  desktopSummaryRefreshRunningVersion = desktopSummaryRefreshRequestedVersion;
  void refreshDesktopSummary(queuedRunId);
}

function requestDesktopSummaryRefresh(forceExplainRunId?: string | null, delayMs = 150) {
  desktopSummaryRefreshRequestedVersion += 1;
  if (forceExplainRunId) {
    desktopSummaryQueuedRunId = forceExplainRunId;
  }
  if (desktopSummaryRefreshTimeout !== null) {
    window.clearTimeout(desktopSummaryRefreshTimeout);
  }

  desktopSummaryRefreshTimeout = window.setTimeout(() => {
    desktopSummaryRefreshTimeout = null;
    if (desktopSummaryRefreshInFlight) {
      return;
    }
    flushDesktopSummaryRefreshQueue();
  }, delayMs);
}

function shouldRunDesktopSummaryFallbackRefresh(now = Date.now()) {
  if (!desktopSummaryLiveRefreshAvailable) {
    return true;
  }

  const lastLiveActivityAt = Math.max(
    desktopSummaryLastSuccessfulRefreshAt,
    desktopSummaryLastStreamSignalAt,
  );
  return now - lastLiveActivityAt >= DESKTOP_SUMMARY_STREAM_STALE_MS;
}

function registerDesktopSummaryFallbackRefresh() {
  if (desktopSummaryFallbackRefreshRegistered) {
    return;
  }

  desktopSummaryFallbackRefreshRegistered = true;

  window.setInterval(() => {
    if (document.visibilityState !== "visible") {
      return;
    }
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  }, DESKTOP_SUMMARY_REFRESH_FALLBACK_INTERVAL_MS);

  window.addEventListener("focus", () => {
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      return;
    }
    if (!shouldRunDesktopSummaryFallbackRefresh()) {
      return;
    }
    requestDesktopSummaryRefresh(undefined, 0);
  });
}

function registerDesktopSummaryLiveRefresh() {
  registerDesktopSummaryFallbackRefresh();

  void subscribeToDesktopSummaryRefresh((event) => {
    if (event.source !== "pty") {
      desktopSummaryLastStreamSignalAt = Date.now();
    }
    requestDesktopSummaryRefresh(event.run_id, 0);
  }).then(() => {
    desktopSummaryLiveRefreshAvailable = true;
  }).catch((error) => {
    console.warn("Failed to subscribe to desktop summary refresh events", error);
    desktopSummaryLiveRefreshAvailable = false;
  });
}

function initializeSidebarResize() {
  const appShell = document.getElementById("app-shell");
  const handle = document.getElementById("sidebar-resizer");
  if (!appShell || !handle) {
    return;
  }

  appShell.style.setProperty("--sidebar-width", `${sidebarWidth}px`);

  handle.addEventListener("pointerdown", (event) => {
    const startX = event.clientX;
    const startWidth = sidebarWidth;
    const onMove = (moveEvent: PointerEvent) => {
      sidebarWidth = Math.max(240, Math.min(380, startWidth + (moveEvent.clientX - startX)));
      appShell.style.setProperty("--sidebar-width", `${sidebarWidth}px`);
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      void persistThemeState();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  });
}

window.addEventListener("DOMContentLoaded", async () => {
  installViewportHarnessHooks();
  const popoutSurfaceState = readPopoutSurfaceState();

  const storedShellPreferences = readStoredShellPreferences();
  if (storedShellPreferences) {
    applyThemeState(storedShellPreferences);
    sidebarWidth = storedShellPreferences.sidebarWidth;
    preferredWideSidebarOpen = storedShellPreferences.wideSidebarOpen;
    preferredWideContextOpen = storedShellPreferences.wideContextOpen;
  }

  await subscribeToPtyOutput((payload) => {
    registerPreviewTargets(payload.pane_id, payload.data);
    const entry = payload.pane_id ? panes.get(payload.pane_id) : undefined;
    if (entry) {
      entry.lastOutputAt = Date.now();
      entry.terminal.write(payload.data);
      renderPaneMetadata();
      return;
    }

    const first = panes.values().next().value as PaneEntry | undefined;
    if (first) {
      first.lastOutputAt = Date.now();
      first.terminal.write(payload.data);
      renderPaneMetadata();
    }
  });

  renderSessions();
  renderExplorer();
  renderOpenEditors();
  renderSourceSummary();
  renderSourceEntries();
  renderContextPanel();
  applyShellPreferences();
  renderSettingsControls();
  renderFooterLane();
  renderTimelineFilters();
  renderRunSummary();
  renderConversation(getConversationItems());
  renderComposerModes();
  renderComposerSlashCommands();
  renderComposerRemoteReferences();
  renderAttachmentTray();
  renderCommandBar();
  renderEditorSurface();
  syncResponsiveShell();
  setEditorSurface(false);
  setTerminalDrawer(false);
  applyPopoutSurfaceState(popoutSurfaceState);
  await refreshDesktopSummary();
  registerDesktopSummaryLiveRefresh();
  initializeSidebarResize();
  window.setInterval(() => {
    renderPaneMetadata();
  }, PANE_META_REFRESH_INTERVAL_MS);

  document.getElementById("toggle-sidebar-btn")?.addEventListener("click", () => {
    setSidebarOpen(!sidebarOpen);
  });

  document.getElementById("open-command-bar-btn")?.addEventListener("click", () => {
    if (commandBarOpen) {
      closeCommandBar();
      return;
    }
    openCommandBar();
  });

  document.getElementById("toggle-terminal-btn")?.addEventListener("click", () => {
    setTerminalDrawer(!terminalDrawerOpen);
  });

  document.getElementById("browser-reload-btn")?.addEventListener("click", () => {
    reloadPreviewTarget();
  });

  document.getElementById("browser-back-btn")?.addEventListener("click", () => {
    closePreviewTarget();
  });

  document.getElementById("browser-copy-btn")?.addEventListener("click", async () => {
    await copyPreviewTargetUrl();
  });

  document.getElementById("browser-open-btn")?.addEventListener("click", () => {
    openPreviewTargetExternally();
  });

  document.getElementById("toggle-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
  });

  document.getElementById("close-editor-btn")?.addEventListener("click", async () => {
    if (document.body.dataset.popoutSurface === "1") {
      if (isTauri()) {
        await getCurrentWebviewWindow().close();
        return;
      }
      window.close();
      return;
    }
    setEditorSurface(false);
  });

  document.getElementById("popout-editor-btn")?.addEventListener("click", async () => {
    await openEditorSurfacePopout();
  });

  document.getElementById("settings-btn")?.addEventListener("click", () => {
    setSettingsSheet(true);
  });

  document.getElementById("apply-settings-btn")?.addEventListener("click", () => {
    applySettingsDraft();
  });

  document.getElementById("close-settings-btn")?.addEventListener("click", () => {
    cancelSettingsDraft();
  });

  document.getElementById("sidebar-overlay")?.addEventListener("click", () => {
    setSidebarOpen(false);
  });

  document.getElementById("command-bar-backdrop")?.addEventListener("click", () => {
    closeCommandBar();
  });

  document.getElementById("command-bar")?.addEventListener("keydown", (event) => {
    trapCommandBarTab(event);
  });

  const commandBarInput = document.getElementById("command-bar-input") as HTMLInputElement | null;
  commandBarInput?.addEventListener("compositionstart", () => {
    commandBarImeActive = true;
  });

  commandBarInput?.addEventListener("compositionend", () => {
    commandBarImeActive = false;
  });

  commandBarInput?.addEventListener("input", () => {
    commandBarQuery = commandBarInput.value;
    selectedCommandIndex = 0;
    renderCommandBar();
  });

  commandBarInput?.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const actions = getFilteredCommandActions();
      if (actions.length === 0) {
        return;
      }
      selectedCommandIndex = (selectedCommandIndex + 1) % actions.length;
      renderCommandBar();
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      const actions = getFilteredCommandActions();
      if (actions.length === 0) {
        return;
      }
      selectedCommandIndex = (selectedCommandIndex - 1 + actions.length) % actions.length;
      renderCommandBar();
      return;
    }

    if (event.key === "Enter") {
      if (commandBarImeActive || event.isComposing) {
        return;
      }
      event.preventDefault();
      executeSelectedCommand();
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      closeCommandBar();
    }
  });

  document.getElementById("add-pane-btn")?.addEventListener("click", () => {
    if (!terminalDrawerOpen) {
      setTerminalDrawer(true);
    }
    createPane();
  });

  const composer = document.getElementById("composer") as HTMLFormElement | null;
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
  const composerFileInput = document.getElementById("composer-file-input") as HTMLInputElement | null;
  const attachButton = document.getElementById("attach-btn") as HTMLButtonElement | null;
  if (composer && composerInput) {
    composerInput.addEventListener("compositionstart", () => {
      composerImeActive = true;
    });

    composerInput.addEventListener("compositionend", () => {
      composerImeActive = false;
    });

    composerInput.addEventListener("keydown", (event) => {
      const slashCommands = getFilteredComposerSlashCommands();
      const composerImeBlocking = composerImeActive || event.isComposing;
      if (event.key === "ArrowUp" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && !composerSlashOpen && composerHistory.length > 0 && isComposerSelectionCollapsed(composerInput) && isCaretOnFirstLine(composerInput)) {
        event.preventDefault();
        stepComposerHistory(-1);
        return;
      }

      if (event.key === "ArrowDown" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && !composerSlashOpen && composerHistoryIndex !== -1 && isComposerSelectionCollapsed(composerInput) && isCaretOnLastLine(composerInput)) {
        event.preventDefault();
        stepComposerHistory(1);
        return;
      }

      if (event.key === "ArrowDown" && !composerImeBlocking && slashCommands.length > 0) {
        event.preventDefault();
        selectedComposerSlashIndex = (selectedComposerSlashIndex + 1) % slashCommands.length;
        renderComposerSlashCommands();
        return;
      }

      if (event.key === "ArrowUp" && !composerImeBlocking && slashCommands.length > 0) {
        event.preventDefault();
        selectedComposerSlashIndex = (selectedComposerSlashIndex - 1 + slashCommands.length) % slashCommands.length;
        renderComposerSlashCommands();
        return;
      }

      if (event.key === "Tab" && !composerImeBlocking && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
        event.preventDefault();
        if (slashCommands.length > 0) {
          applyComposerSlashCommand(slashCommands[selectedComposerSlashIndex] ?? slashCommands[0]);
          return;
        }
        insertComposerTab(composerInput);
        syncComposerSlashState(composerInput.value);
        exitComposerHistoryToDraft(composerInput.value);
        return;
      }

      if (event.key !== "Enter") {
        return;
      }

      if (event.shiftKey || composerImeActive || event.isComposing) {
        return;
      }

      event.preventDefault();
      composer.requestSubmit();
    });

    composerInput.addEventListener("input", () => {
      if (composerHistoryIndex !== -1) {
        composerHistoryIndex = -1;
      }
      syncComposerDraftState(composerInput.value);
      syncComposerSlashState(composerInput.value);
    });

    composerInput.addEventListener("paste", (event) => {
      const items = Array.from(event.clipboardData?.items ?? []);
      const attachmentFiles = items
        .filter((item) => item.kind === "file")
        .map((item) => item.getAsFile())
        .filter((file): file is File => Boolean(file));

      if (attachmentFiles.length === 0) {
        return;
      }

      event.preventDefault();
      appendAttachments(attachmentFiles);
    });

    composerInput.addEventListener("dragover", (event) => {
      if (event.dataTransfer?.files?.length) {
        event.preventDefault();
      }
    });

    composerInput.addEventListener("drop", (event) => {
      const files = Array.from(event.dataTransfer?.files ?? []);
      if (files.length === 0) {
        return;
      }

      event.preventDefault();
      appendAttachments(files);
    });

    composer.addEventListener("submit", (event) => {
      event.preventDefault();
      const slashMatch = getComposerSlashMatch(composerInput.value);
      if (slashMatch) {
        applyComposerSlashCommand(slashMatch);
      }
      const rawValue = composerInput.value;
      const value = rawValue.trim();
      const selectedRemoteReferences = getComposerRemoteReferences().filter((item) => selectedComposerRemoteReferenceIds.has(item.id));
      if (!value && pendingAttachments.length === 0 && selectedRemoteReferences.length === 0) {
        return;
      }
      const historyEntry = captureComposerHistoryEntry(rawValue);
      const submittedAttachments = [
        ...pendingAttachments,
        ...selectedRemoteReferences.map((item) => ({
          id: item.id,
          name: item.label,
          kind: "file" as const,
          sizeLabel: item.meta,
          file: new File([], item.label),
        })),
      ];
      appendUserMessage(rawValue, submittedAttachments);
      pushComposerHistoryEntry(historyEntry);
      composerInput.value = "";
      syncComposerSlashState(composerInput.value);
      clearPendingAttachments();
      selectedComposerRemoteReferenceIds.clear();
      renderComposerRemoteReferences();
      renderAttachmentTray();
      requestDesktopSummaryRefresh(undefined, 750);
    });
  }

  attachButton?.addEventListener("click", () => {
    composerFileInput?.click();
  });

  composerFileInput?.addEventListener("change", () => {
    const files = Array.from(composerFileInput.files ?? []);
    appendAttachments(files);
    composerFileInput.value = "";
  });

  window.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      if (commandBarOpen) {
        closeCommandBar();
      } else {
        openCommandBar();
      }
      return;
    }

    if (event.key === "Escape" && commandBarOpen) {
      event.preventDefault();
      closeCommandBar();
      return;
    }

    if (event.key === "Escape" && settingsSheetOpen) {
      event.preventDefault();
      cancelSettingsDraft();
      return;
    }

    if ((event.ctrlKey || event.metaKey) && event.key === ",") {
      event.preventDefault();
      setSettingsSheet(!settingsSheetOpen);
    }
  });

  window.addEventListener("resize", () => {
    syncResponsiveShell();
    panes.forEach((pane) => pane.fitAddon.fit());
  });
});
