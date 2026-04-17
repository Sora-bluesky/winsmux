import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";
import {
  getDesktopEditorFile,
  getDesktopRunExplain,
  getDesktopSummarySnapshot,
  subscribeToDesktopSummaryRefresh,
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

interface ExplorerItem {
  label: string;
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

type SurfaceTone = "default" | "accent" | "success" | "warning" | "danger" | "info" | "focus";
type ThemeMode = "codex-dark" | "graphite-dark";
type DensityMode = "comfortable" | "compact";
type WrapMode = "balanced" | "compact";

interface ThemeState {
  theme: ThemeMode;
  density: DensityMode;
  wrapMode: WrapMode;
}

interface ComposerAttachment {
  id: string;
  name: string;
  kind: "image" | "file";
  sizeLabel: string;
  file: File;
  previewUrl?: string;
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
let settingsSheetOpen = false;
let sidebarOpen = true;
let composerImeActive = false;
let sidebarWidth = 292;
let selectedEditorKey = "";
let selectedRunId: string | null = null;
let activeComposerMode: ComposerMode = "dispatch";
let activeSourceFilter: SourceFilter = "all";
let activeTimelineFilter: TimelineFilter = "all";
let commandBarOpen = false;
let commandBarQuery = "";
let selectedCommandIndex = 0;
let commandBarImeActive = false;
let lastCommandBarFocus: HTMLElement | null = null;
let pendingAttachments: ComposerAttachment[] = [];
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
const desktopExplainCache = new Map<string, DesktopExplainPayload>();
const desktopEditorFileCache = new Map<string, EditorFile>();
const desktopEditorLoadingPaths = new Set<string>();
const desktopEditorLoadErrors = new Map<string, string>();
const desktopStandaloneEditorTargets = new Map<string, EditorTarget>();
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

const composerModes: Array<{ mode: ComposerMode; label: string; placeholder: string }> = [
  { mode: "ask", label: "Ask", placeholder: "Ask the Operator for clarification, status, or guidance" },
  { mode: "dispatch", label: "Dispatch", placeholder: "Dispatch the next task to the Operator" },
  { mode: "review", label: "Review", placeholder: "Request review, approval, or audit from the Operator" },
  { mode: "explain", label: "Explain", placeholder: "Ask the Operator to explain the current run state" },
];

const timelineFilters: Array<{ filter: TimelineFilter; label: string }> = [
  { filter: "all", label: "All" },
  { filter: "attention", label: "Attention" },
  { filter: "review", label: "Review" },
  { filter: "activity", label: "Activity" },
];

const themeOptions: Array<{ value: ThemeMode; label: string; description: string }> = [
  { value: "codex-dark", label: "Codex Dark", description: "Close adaptation of Codex typography and contrast." },
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

  const label = document.createElement("span");
  label.className = "pane-label";
  label.textContent = id;

  const closeBtn = document.createElement("button");
  closeBtn.className = "pane-close";
  closeBtn.textContent = "×";
  closeBtn.onclick = () => closePane(id);

  header.appendChild(label);
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

  panes.set(id, { terminal, fitAddon, container: paneDiv });

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
    return [{ name: "winsmux", meta: "Connecting to desktop summary", active: true }] satisfies SessionItem[];
  }

  const board = desktopSummarySnapshot.board.summary;
  const inbox = desktopSummarySnapshot.inbox.summary;
  const digest = desktopSummarySnapshot.digest.summary;

  return [
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

  for (const target of Array.from(targets.values()).sort((left, right) => left.path.localeCompare(right.path))) {
    const normalizedPath = target.path.replace(/\\/g, "/");
    const segments = normalizedPath.split("/").filter(Boolean);
    let currentPath = "";
    segments.forEach((segment, index) => {
      currentPath = currentPath ? `${currentPath}/${segment}` : segment;
      const depth = index;
      const isFile = index === segments.length - 1;
      if (isFile) {
        items.push({
          label: segment,
          depth,
          kind: "file",
          path: target.path,
          worktree: target.worktree,
          active: target.key === selectedEditorKey,
        });
        return;
      }

      if (seenFolders.has(currentPath)) {
        return;
      }

      seenFolders.add(currentPath);
      items.push({
        label: segment,
        depth,
        kind: "folder",
        open: true,
      });
    });
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
      `<span class="sidebar-row-title">${item.kind === "folder" ? (item.open ? "▾ " : "▸ ") : "• "}${item.label}</span>`;
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
    button.innerHTML = `<span class="sidebar-row-title">${editor.path.split("/").pop() ?? editor.path}</span><span class="sidebar-row-meta">${editor.summary}</span>`;
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

function renderContextPanel() {
  const sectionRoot = document.getElementById("context-sections");
  const overviewRoot = document.getElementById("source-overview-cards");
  const fileRoot = document.getElementById("context-file-list");
  if (!sectionRoot || !overviewRoot || !fileRoot) {
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

function getFooterItems(): { left: FooterStatusItem[]; right: FooterStatusItem[] } {
  const themeLabel = themeOptions.find((item) => item.value === themeState.theme)?.label ?? themeState.theme;
  const densityLabel = densityOptions.find((item) => item.value === themeState.density)?.label ?? themeState.density;
  const wrapLabel = wrapOptions.find((item) => item.value === themeState.wrapMode)?.label ?? themeState.wrapMode;
  const summaryStatus = desktopSummarySnapshot
    ? `${desktopSummarySnapshot.digest.summary.item_count} runs`
    : "Operator ready";
  const inboxStatus = desktopSummarySnapshot
    ? `${desktopSummarySnapshot.inbox.summary.item_count} inbox`
    : "config.toml";
  const branchStatus = getPrimaryRunProjection()?.branch || "main";

  return {
    left: [
      { label: "Local environment" },
      { label: themeLabel, tone: "focus" },
      { label: densityLabel },
      { label: `Wrap ${wrapLabel}` },
      { label: "Command", value: "Ctrl/Cmd+K", tone: "accent" },
      { label: "Settings", tone: "accent" },
    ],
    right: [
      { label: inboxStatus },
      { label: branchStatus },
      { label: summaryStatus, tone: desktopSummarySnapshot ? "info" : "success" },
    ],
  };
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
  renderPreferenceOptions("theme-options", themeOptions, themeState.theme, (value) => {
    themeState.theme = value;
    applyShellPreferences();
    renderFooterLane();
    renderSettingsControls();
  });

  renderPreferenceOptions("density-options", densityOptions, themeState.density, (value) => {
    themeState.density = value;
    applyShellPreferences();
    renderFooterLane();
    renderSettingsControls();
  });

  renderPreferenceOptions("wrap-options", wrapOptions, themeState.wrapMode, (value) => {
    themeState.wrapMode = value;
    applyShellPreferences();
    renderFooterLane();
    renderSettingsControls();
  });
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
    renderConversation(getConversationItems());
  } catch (error) {
    console.warn("Failed to load desktop explain payload", error);
    appendFallbackExplain();
    return;
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
  renderConversation(getConversationItems());
}

function handleChipAction(action: ChipAction) {
  switch (action) {
    case "open-editor":
      void openEditorTarget(
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
  const path = document.getElementById("editor-file-path");
  const meta = document.getElementById("editor-meta-row");
  const tabs = document.getElementById("editor-tabs");
  const code = document.getElementById("editor-code");
  const statusbar = document.getElementById("editor-statusbar");
  if (!path || !meta || !tabs || !code || !statusbar) {
    return;
  }

  const editors = getEditorFiles();
  const selected = editors.find((editor) => editor.key === selectedEditorKey) || editors[0];
  if (!selected) {
    path.textContent = "Editor idle";
    meta.innerHTML = "";
    tabs.innerHTML = "";
    code.textContent = "No backend preview cached.";
    statusbar.textContent = "Secondary work surface: 0 projected files";
    return;
  }
  selectedEditorKey = selected.key;
  const selectedTarget = getEditorTargetByKey(selected.key);
  if (selectedTarget && !desktopEditorFileCache.has(selected.key) && !desktopEditorLoadingPaths.has(selected.key)) {
    void ensureEditorFileLoaded(selectedTarget);
  }

  path.textContent = selected.path;
  meta.innerHTML = "";
  for (const item of [
    selected.language,
    `${selected.lineCount} lines`,
    selected.modified ? "Modified" : "Saved",
    selected.origin === "context" ? "Opened from context" : "Opened from explorer",
  ]) {
    const chip = document.createElement("span");
    chip.className = `editor-meta-chip ${item === "Modified" ? "is-modified" : ""}`;
    chip.dataset.tone = item === "Modified" ? "focus" : "default";
    chip.textContent = item;
    meta.appendChild(chip);
  }
  code.textContent = selected.content;
  statusbar.textContent = `Secondary work surface: ${selected.origin === "context" ? "run context" : "explorer"} -> ${selected.path}`;
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

  const changedRunIds: string[] = [];
  const addedRunIds: string[] = [];
  const removedRunIds: string[] = [];

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

  const inboxCountChanged =
    previousSnapshot.inbox.summary.item_count !== nextSnapshot.inbox.summary.item_count;

  return {
    hasMeaningfulChange:
      inboxCountChanged ||
      addedRunIds.length > 0 ||
      removedRunIds.length > 0 ||
      changedRunIds.length > 0,
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
  ].slice(0, 3);

  const items: ConversationItem[] = [];
  for (const runId of prioritizedChangedRunIds) {
    const projection = nextProjectionMap.get(runId);
    if (!projection) {
      continue;
    }
    const experimentSummary = summarizeProjectionExperiment(projection);
    const consultationSummary = summarizeProjectionConsultation(projection);
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
        ? `${consultationSummary} · ${projection.changed_files.length} changed files · review ${projection.review_state || "n/a"}.`
        : experimentSummary
        ? `${experimentSummary} · Next ${projection.next_action || "idle"} · ${projection.changed_files.length} changed files · review ${projection.review_state || "n/a"}.`
        : `Next ${projection.next_action || "idle"} · ${projection.changed_files.length} changed files · review ${projection.review_state || "n/a"}.`,
      details: [
        { label: "run", value: runId },
        { label: "branch", value: projection.branch || "no branch" },
        { label: "head", value: projection.head_short || "n/a" },
        { label: "verify", value: projection.verification_outcome || "n/a" },
        ...(projection.confidence !== null
          ? [{ label: "confidence", value: formatConfidencePercent(projection.confidence) }]
          : []),
        ...(projection.consultation_ref
          ? [{ label: "source", value: summarizeArtifactRef(projection.consultation_ref) }]
          : []),
      ],
      tone:
        projection.review_state === "PASS"
          ? "success"
          : projection.review_state === "PENDING"
            ? "warning"
            : "info",
      runId,
      statusLabel: projection.next_action || projection.review_state || undefined,
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
        { label: "head", value: previousProjection.head_short || "n/a" },
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
  button.textContent = open ? "Hide Terminal" : "Terminal";
  button.setAttribute("aria-expanded", open ? "true" : "false");

  if (open && panes.size === 0) {
    createPane("main");
  }

  requestAnimationFrame(() => {
    panes.forEach((pane) => pane.fitAddon.fit());
  });
}

function setContextPanel(open: boolean) {
  contextPanelOpen = open;
  const panel = document.getElementById("context-panel");
  const button = document.getElementById("toggle-context-btn");
  const body = document.getElementById("workspace-body");
  if (!panel || !button || !body) {
    return;
  }

  panel.toggleAttribute("hidden", !open);
  body.classList.toggle("context-collapsed", !open);
  button.textContent = open ? "Hide Context" : "Context";
  button.setAttribute("aria-expanded", open ? "true" : "false");
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
  return window.matchMedia("(max-width: 1180px)").matches;
}

function setSidebarOpen(open: boolean) {
  sidebarOpen = open;
  const shell = document.getElementById("app-shell");
  const overlay = document.getElementById("sidebar-overlay");
  const button = document.getElementById("toggle-sidebar-btn");
  if (!shell || !overlay || !button) {
    return;
  }

  shell.classList.toggle("sidebar-open", open);
  overlay.hidden = !(open && isNarrowLayout());
  button.setAttribute("aria-expanded", open ? "true" : "false");
}

function setSettingsSheet(open: boolean) {
  settingsSheetOpen = open;
  const sheet = document.getElementById("settings-sheet");
  if (!sheet) {
    return;
  }

  if (open && commandBarOpen) {
    closeCommandBar();
  }

  sheet.hidden = !open;
}

function syncResponsiveShell() {
  if (isNarrowLayout()) {
    setSidebarOpen(false);
    setContextPanel(false);
  } else {
    setSidebarOpen(true);
    if (!contextPanelOpen) {
      setContextPanel(true);
    }
  }
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
}

function renderDesktopSurfaces() {
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
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  });
}

window.addEventListener("DOMContentLoaded", async () => {
  await subscribeToPtyOutput((payload) => {
    const entry = payload.pane_id ? panes.get(payload.pane_id) : undefined;
    if (entry) {
      entry.terminal.write(payload.data);
      return;
    }

    const first = panes.values().next().value as PaneEntry | undefined;
    if (first) {
      first.terminal.write(payload.data);
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
  renderAttachmentTray();
  renderCommandBar();
  renderEditorSurface();
  await refreshDesktopSummary();
  registerDesktopSummaryLiveRefresh();
  syncResponsiveShell();
  setEditorSurface(false);
  setTerminalDrawer(false);
  initializeSidebarResize();

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

  document.getElementById("toggle-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
  });

  document.getElementById("close-editor-btn")?.addEventListener("click", () => {
    setEditorSurface(false);
  });

  document.getElementById("settings-btn")?.addEventListener("click", () => {
    setSettingsSheet(true);
  });

  document.getElementById("close-settings-btn")?.addEventListener("click", () => {
    setSettingsSheet(false);
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
      if (event.key !== "Enter") {
        return;
      }

      if (event.shiftKey || composerImeActive || event.isComposing) {
        return;
      }

      event.preventDefault();
      composer.requestSubmit();
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
      const value = composerInput.value.trim();
      if (!value && pendingAttachments.length === 0) {
        return;
      }
      const submittedAttachments = [...pendingAttachments];
      appendUserMessage(value, submittedAttachments);
      composerInput.value = "";
      clearPendingAttachments();
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
      setSettingsSheet(false);
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
