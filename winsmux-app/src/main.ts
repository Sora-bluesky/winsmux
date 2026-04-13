import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";
import {
  getDesktopRunExplain,
  getDesktopSummarySnapshot,
  type DesktopDigestItem,
  type DesktopExplainPayload,
  type DesktopSummarySnapshot,
} from "./desktopClient";
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
  open?: boolean;
  active?: boolean;
}

interface EditorFile {
  path: string;
  summary: string;
  content: string;
  language: string;
  lineCount: number;
  modified?: boolean;
  origin: "explorer" | "context";
  active?: boolean;
}

type SourceFilter = "all" | "candidates" | "attention" | `pane:${string}`;

type ChangeStatus = "modified" | "added" | "deleted" | "renamed";
type ChangeRisk = "low" | "medium" | "high";

interface SourceChange {
  path: string;
  summary: string;
  paneLabel: string;
  status: ChangeStatus;
  risk: ChangeRisk;
  branch: string;
  lines: string;
  commitCandidate: boolean;
  needsAttention: boolean;
  run: string;
  review: string;
}

interface SourceControlState {
  entries: SourceChange[];
}

interface ContextSection {
  label: string;
  value: string;
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
let selectedEditorPath = "winsmux-app/src/main.ts";
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
const desktopExplainCache = new Map<string, DesktopExplainPayload>();
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

const seedConversation: ConversationItem[] = [
  {
    type: "user",
    category: "user",
    timestamp: "09:41",
    actor: "User",
    body: "Please tighten the notification boundary and show why this run is blocked.",
  },
  {
    type: "operator",
    category: "activity",
    timestamp: "09:42",
    actor: "Operator",
    title: "Operator update",
    body: "Inbox shows 2 approval waits. I am checking run ledger, source context, and the evidence digest before deciding the next action.",
    details: [
      { label: "focus", value: "run-246" },
      { label: "scope", value: "branch/head mismatch" },
    ],
    tone: "info",
    runId: "run-246",
  },
  {
    type: "system",
    category: "attention",
    timestamp: "09:43",
    actor: "System",
    title: "Commit blocked",
    body: "worker-2 changed 3 files. Review passed, but branch/head mismatch still blocks commit. Open Explain or inspect the edited files.",
    details: [
      { label: "run", value: "run-246" },
      { label: "slot", value: "worker-3" },
      { label: "review", value: "passed" },
      { label: "next", value: "Open Explain" },
    ],
    chips: [
      { label: "Open Explain", action: "open-explain" },
      { label: "Open in Editor", action: "open-editor" },
      { label: "Source Context", action: "open-source-context" },
      { label: "Terminal", action: "open-terminal" },
    ],
    tone: "warning",
    runId: "run-246",
    statusLabel: "Blocked",
  },
  {
    type: "operator",
    category: "review",
    timestamp: "09:44",
    actor: "Operator",
    title: "Review boundary",
    body: "Only external-facing review and commit-ready events should surface through the channel layer. Internal dispatch noise stays inside the workspace.",
    details: [
      { label: "channel", value: "external only" },
      { label: "profile", value: "review_requested, blocked, commit_ready" },
    ],
    tone: "focus",
  },
  {
    type: "system",
    category: "review",
    timestamp: "09:46",
    actor: "System",
    title: "Review requested",
    body: "A review-capable slot is ready to inspect the changed files for run-245. The timeline keeps the request, evidence, and next action in the same feed.",
    details: [
      { label: "run", value: "run-245" },
      { label: "slot", value: "worker-2" },
      { label: "target", value: "Changed files" },
    ],
    chips: [
      { label: "Open in Editor", action: "open-editor" },
      { label: "Source Context", action: "open-source-context" },
    ],
    tone: "focus",
    runId: "run-245",
    statusLabel: "Review",
  },
  {
    type: "system",
    category: "activity",
    timestamp: "09:48",
    actor: "worker-2",
    title: "Pane report",
    body: "worker-2 returned a structured execution report for the selected run.",
    details: [
      { label: "STATUS", value: "SUCCESS" },
      { label: "TASK", value: "TASK-138 source-control context slice" },
      { label: "RESULT", value: "source-control context now opens changed files in the editor with worktree-aware metadata" },
      { label: "FILES_CHANGED", value: "index.html, src/main.ts, src/styles.css" },
      { label: "ISSUES", value: "none" },
    ],
    tone: "info",
    runId: "run-138",
    statusLabel: "SUCCESS",
  },
];

const sessionItems: SessionItem[] = [
  { name: "winsmux", meta: "operator active · 2 runs blocked", active: true },
  { name: "release-check", meta: "digest clean · no review waits" },
];

const explorerItems: ExplorerItem[] = [
  { label: "winsmux-app", depth: 0, kind: "folder", open: true },
  { label: "src", depth: 1, kind: "folder", open: true },
  { label: "main.ts", depth: 2, kind: "file", path: "winsmux-app/src/main.ts", active: true },
  { label: "styles.css", depth: 2, kind: "file", path: "winsmux-app/src/styles.css" },
  { label: "index.html", depth: 1, kind: "file", path: "winsmux-app/index.html" },
  { label: "winsmux-core", depth: 0, kind: "folder" },
];

const editorFiles: EditorFile[] = [
  {
    path: "winsmux-app/src/main.ts",
    summary: "Conversation shell scaffold",
    language: "TypeScript",
    lineCount: 138,
    modified: true,
    origin: "context",
    active: true,
    content:
      "const summaryStream = [\n  'blocked',\n  'review_requested',\n  'commit_ready',\n];\n\nfunction openEditorSurface() {\n  // Secondary work surface opened from conversation or source context.\n}\n",
  },
  {
    path: "winsmux-app/src/styles.css",
    summary: "Workspace sidebar and responsive shell",
    language: "CSS",
    lineCount: 74,
    modified: true,
    origin: "context",
    content:
      ".workspace-sidebar {\n  width: var(--sidebar-width);\n}\n\n.editor-secondary-surface {\n  border-left: 1px solid var(--border-muted);\n}\n",
  },
  {
    path: "winsmux-app/index.html",
    summary: "Operator shell structure and panel hierarchy",
    language: "HTML",
    lineCount: 67,
    origin: "explorer",
    content:
      "<section id=\"conversation-panel\">\n  <div id=\"conversation-timeline\"></div>\n  <form id=\"composer\"></form>\n</section>\n\n<aside id=\"editor-surface\" hidden></aside>\n",
  },
  {
    path: "winsmux-core/scripts/team-pipeline.ps1",
    summary: "Review-capable slot dispatch and branch alignment gate",
    language: "PowerShell",
    lineCount: 44,
    modified: true,
    origin: "context",
    content:
      "function Resolve-ReviewTarget {\n  param($Run)\n  # Review is now a slot capability, not a dedicated pane kind.\n}\n\nif ($branchMismatch) {\n  return 'blocked'\n}\n",
  },
];

const sourceControlState: SourceControlState = {
  entries: [
  {
    path: "winsmux-app/src/main.ts",
    summary: "Conversation shell source-control actions and worktree metadata",
    paneLabel: "worker-2",
    status: "modified",
    risk: "medium",
    branch: "codex/task138-source-context",
    lines: "+46 -11",
    commitCandidate: true,
    needsAttention: false,
    run: "run-245",
    review: "passed",
  },
  {
    path: "winsmux-app/src/styles.css",
    summary: "Sidebar/context badges and source-control overview cards",
    paneLabel: "worker-2",
    status: "modified",
    risk: "low",
    branch: "codex/task138-source-context",
    lines: "+38 -4",
    commitCandidate: true,
    needsAttention: false,
    run: "run-245",
    review: "passed",
  },
  {
    path: "winsmux-core/scripts/team-pipeline.ps1",
    summary: "Branch mismatch still blocks commit despite review PASS",
    paneLabel: "worker-3",
    status: "modified",
    risk: "high",
    branch: "codex/task264-review-capable-slot",
    lines: "+9 -2",
    commitCandidate: false,
    needsAttention: true,
    run: "run-246",
    review: "blocked",
  },
  ],
};

const baseContextSections: ContextSection[] = [
  { label: "next", value: "Open Explain" },
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
  void spawnPtyPane(id, cols, rows);

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
  void closePtyPane(id);

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
    return sessionItems;
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

function getRunProjectionByRunId(runId: string | null) {
  if (!runId) {
    return null;
  }
  return getRunProjections().find((projection) => projection.run_id === runId) ?? null;
}

function getProjectionSourceEntries(): SourceChange[] {
  const projections = getRunProjections();
  if (projections.length === 0) {
    return sourceControlState.entries;
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

  return entries.length > 0 ? entries : sourceControlState.entries;
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

  root.innerHTML = "";
  for (const item of explorerItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row sidebar-tree-row ${item.active ? "is-active" : ""}`;
    button.style.paddingLeft = `${12 + item.depth * 16}px`;
    button.innerHTML =
      `<span class="sidebar-row-title">${item.kind === "folder" ? (item.open ? "▾ " : "▸ ") : "• "}${item.label}</span>`;
    if (item.kind === "file" && item.path) {
      const itemPath = item.path;
      button.addEventListener("click", () => {
        selectedEditorPath = findEditorFile(itemPath)?.path || selectedEditorPath;
        setEditorSurface(true);
        renderSourceSummary();
        renderRunSummary();
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
  for (const editor of editorFiles) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${editor.path === selectedEditorPath && editorSurfaceOpen ? "is-active" : ""}`;
    button.innerHTML = `<span class="sidebar-row-title">${editor.path.split("/").pop() ?? editor.path}</span><span class="sidebar-row-meta">${editor.summary}</span>`;
    button.addEventListener("click", () => {
      selectedEditorPath = editor.path;
      setEditorSurface(true);
      renderSourceSummary();
      renderRunSummary();
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
  const primaryChange = getPrimarySourceChange(visibleChanges);
  const entryCount = visibleChanges.length;
  const attentionCount = visibleChanges.filter((item) => item.needsAttention).length;
  const commitCandidates = visibleChanges.filter((item) => item.commitCandidate).length;
  const summaryItems = [
    { label: "Branch", value: primaryChange?.branch ?? "No branch" },
    { label: "Changed", value: `${entryCount} files` },
    { label: "Review", value: primaryChange?.review ?? "No review state" },
    { label: "Branch", value: primaryChange?.branch ?? "No source projection" },
    { label: "Ready", value: `${commitCandidates} candidate${commitCandidates === 1 ? "" : "s"}` },
    { label: "Risk", value: `${attentionCount} attention · ${activeEntries.length} projected` },
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
      if (editorSurfaceOpen && primaryChange) {
        selectedEditorPath = primaryChange.path;
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
  return changes.find((item) => item.path === selectedEditorPath) ?? changes[0] ?? getProjectionSourceEntries()[0];
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

function getPrimaryDigestItem() {
  if (desktopSummarySnapshot?.digest.items?.length) {
    return desktopSummarySnapshot.digest.items[0];
  }

  const projection = getRunProjections()[0];
  if (!projection) {
    return null;
  }

  return {
    run_id: projection.run_id,
    task: projection.task,
    label: projection.label,
    pane_id: projection.pane_id,
    role: "",
    task_state: projection.task_state,
    review_state: projection.review_state,
    next_action: projection.next_action,
    branch: projection.branch,
    head_short: "",
    changed_file_count: projection.changed_files.length,
    changed_files: projection.changed_files,
    verification_outcome: projection.verification_outcome,
    security_blocked: projection.security_blocked,
  } satisfies DesktopDigestItem;
}

function getSelectedRunId() {
  return getPrimaryDigestItem()?.run_id ?? null;
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

  sectionRoot.innerHTML = "";
  const resolvedContextSections = [
    ...baseContextSections,
    { label: "pane", value: primaryChange?.paneLabel ?? "No pane label" },
    { label: "branch", value: primaryChange?.branch ?? "No branch" },
    { label: "review", value: primaryChange?.review ?? "No review state" },
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
    button.className = `context-file-row ${change.path === selectedEditorPath && editorSurfaceOpen ? "is-active" : ""}`;
    button.dataset.tone = getSourceEntryTone(change);
    button.innerHTML =
      `<span class="context-file-name">${change.path.split("/").pop() ?? change.path}</span>` +
      `<span class="context-file-meta">${change.summary}</span>` +
      `<span class="context-file-trace">${change.status} · ${change.lines} · ${change.branch} · ${change.review}</span>`;
    button.addEventListener("click", () => {
      selectedEditorPath = change.path;
      setEditorSurface(true);
      renderSourceSummary();
      renderRunSummary();
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
  const branchStatus = getPrimaryDigestItem()?.branch || "main";

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
      renderConversation(seedConversation);
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

  const digestItem = getPrimaryDigestItem();
  if (digestItem) {
    const statusTone =
      digestItem.review_state === "PASS"
        ? "success"
        : digestItem.review_state === "PENDING"
          ? "warning"
          : digestItem.review_state === "FAIL" || digestItem.review_state === "FAILED"
            ? "danger"
            : "info";
    const verification = digestItem.verification_outcome ? `verify ${digestItem.verification_outcome}` : "verify n/a";
    const security = digestItem.security_blocked ? `security ${digestItem.security_blocked}` : "security n/a";

    root.innerHTML = `
      <div class="run-summary-card">
        <div class="run-summary-header">
          <div>
            <div class="timeline-eyebrow">Selected run</div>
            <div class="run-summary-title">${digestItem.run_id}</div>
          </div>
          <div class="run-summary-status" data-tone="${statusTone}">
            ${digestItem.review_state || "ready"}
          </div>
        </div>
        <div class="run-summary-meta-row">
          <span class="run-summary-pill">${digestItem.label || digestItem.pane_id || "summary-stream"}</span>
          <span class="run-summary-pill">${digestItem.branch || "no branch"}</span>
          <span class="run-summary-pill">${digestItem.changed_file_count} changed</span>
          <span class="run-summary-pill">${digestItem.next_action || "no next action"}</span>
          <span class="run-summary-pill">${verification}</span>
          <span class="run-summary-pill">${security}</span>
        </div>
        <div class="run-summary-body">${digestItem.task || "Summary-stream run surfaced by the backend adapter."}</div>
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

  const visibleChanges = getVisibleSourceChanges();
  const primaryChange = getPrimarySourceChange(visibleChanges);
  if (!primaryChange) {
    root.innerHTML = "";
    return;
  }

  const attentionCount = visibleChanges.filter((item) => item.needsAttention).length;
  const candidateCount = visibleChanges.filter((item) => item.commitCandidate).length;
  root.innerHTML = `
    <div class="run-summary-card">
      <div class="run-summary-header">
        <div>
          <div class="timeline-eyebrow">Selected run</div>
          <div class="run-summary-title">${primaryChange.run}</div>
        </div>
        <div class="run-summary-status" data-tone="${primaryChange.needsAttention ? "warning" : "success"}">
          ${primaryChange.review}
        </div>
      </div>
      <div class="run-summary-meta-row">
        <span class="run-summary-pill">${primaryChange.paneLabel}</span>
        <span class="run-summary-pill">${primaryChange.branch}</span>
        <span class="run-summary-pill">${primaryChange.branch}</span>
        <span class="run-summary-pill">${candidateCount} candidate${candidateCount === 1 ? "" : "s"}</span>
        <span class="run-summary-pill">${attentionCount} blocker${attentionCount === 1 ? "" : "s"}</span>
      </div>
      <div class="run-summary-body">${primaryChange.summary}</div>
      <div class="timeline-chip-row">
        <button type="button" class="timeline-chip" data-action="open-explain">Open Explain</button>
        <button type="button" class="timeline-chip" data-action="open-editor">Open in Editor</button>
        <button type="button" class="timeline-chip" data-action="open-source-context">Source Context</button>
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
    appendFallbackExplain();
    return;
  }

  try {
    const payload =
      desktopExplainCache.get(selectedRunId) ??
      await getDesktopRunExplain(selectedRunId);
    desktopExplainCache.set(selectedRunId, payload);

    const detailItems: ConversationDetail[] = [
      { label: "run", value: payload.run.run_id },
      { label: "next", value: payload.explanation.next_action || payload.evidence_digest.next_action || "no next action" },
    ];
    if (payload.run.branch) {
      detailItems.push({ label: "branch", value: payload.run.branch });
    }
    if (payload.evidence_digest.verification_outcome) {
      detailItems.push({ label: "verify", value: payload.evidence_digest.verification_outcome });
    }
    if (payload.evidence_digest.security_blocked) {
      detailItems.push({ label: "security", value: payload.evidence_digest.security_blocked });
    }

    const bodyParts = [payload.explanation.summary];
    if (payload.explanation.reasons.length > 0) {
      bodyParts.push(`Reasons: ${payload.explanation.reasons.join(" | ")}`);
    }
    if (payload.recent_events.length > 0) {
      const recent = payload.recent_events
        .slice(0, 2)
        .map((item) => `${item.event}: ${item.message}`)
        .join(" | ");
      bodyParts.push(`Recent: ${recent}`);
    }

    seedConversation.push({
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
  } catch (error) {
    console.warn("Failed to load desktop explain payload", error);
    appendFallbackExplain();
  }

  renderTimelineFilters();
  renderRunSummary();
  renderSourceSummary();
  renderSourceEntries();
  renderContextPanel();
  renderEditorSurface();
  renderConversation(seedConversation);
}

function appendFallbackExplain() {
  seedConversation.push({
    type: "operator",
    category: "activity",
    timestamp: "09:47",
    actor: "Operator",
    title: "Explain opened",
    body: "This run is blocked on branch/head alignment after review passed. Changed files and commit readiness stay available in the context sheet and source-control surface.",
    details: [
      { label: "run", value: "run-246" },
      { label: "focus", value: "branch/head alignment" },
    ],
    tone: "info",
    runId: "run-246",
  });
}

function handleChipAction(action: ChipAction) {
  switch (action) {
    case "open-editor":
      setEditorSurface(true);
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
        renderConversation(seedConversation);
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
        renderConversation(seedConversation);
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

  const selected = findEditorFile(selectedEditorPath) || editorFiles[0];
  const sourceChange = getProjectionSourceEntries().find((item) => item.path === selected.path);
  selectedEditorPath = selected.path;

  path.textContent = selected.path;
  meta.innerHTML = "";
  for (const item of [
    selected.language,
    `${selected.lineCount} lines`,
    selected.modified ? "Modified" : "Saved",
    selected.origin === "context" ? "Opened from context" : "Opened from explorer",
    sourceChange ? `${sourceChange.status} · ${sourceChange.branch}` : "No source metadata",
  ]) {
    const chip = document.createElement("span");
    chip.className = `editor-meta-chip ${item === "Modified" ? "is-modified" : ""}`;
    chip.dataset.tone = item === "Modified" ? "focus" : "default";
    chip.textContent = item;
    meta.appendChild(chip);
  }
  code.textContent = selected.content;
  statusbar.textContent = sourceChange
    ? `Secondary work surface: ${selected.origin === "context" ? "run context" : "explorer"} -> ${selected.path} · ${sourceChange.branch} · ${sourceChange.review}`
    : `Secondary work surface: ${selected.origin === "context" ? "run context" : "explorer"} -> ${selected.path}`;
  tabs.innerHTML = "";

  for (const editor of editorFiles) {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = `editor-tab ${editor.path === selected.path ? "is-active" : ""}`;
    tab.textContent = editor.path.split("/").pop() ?? editor.path;
    tab.addEventListener("click", () => {
      selectedEditorPath = editor.path;
      renderEditorSurface();
      renderOpenEditors();
      renderSourceSummary();
      renderContextPanel();
      renderSourceEntries();
      renderRunSummary();
    });
    tabs.appendChild(tab);
  }
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
  seedConversation.push({
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
  seedConversation.push({
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
  renderConversation(seedConversation);
}

function findEditorFile(label: string) {
  const existing = editorFiles.find((editor) => editor.path === label);
  if (existing) {
    return existing;
  }

  const sourceChange = getProjectionSourceEntries().find((entry) => entry.path === label);
  if (!sourceChange) {
    return undefined;
  }

  const projection = getRunProjectionByRunId(sourceChange.run);
  const explainSummary = projection?.summary || sourceChange.summary;
  const branch = projection?.branch || sourceChange.branch;
  const review = projection?.review_state || sourceChange.review;
  const state = projection?.task_state || "unknown";

  return {
    path: sourceChange.path,
    summary: explainSummary,
    content:
      `// Backend projection preview\n` +
      `// ${branch} · ${sourceChange.paneLabel} · ${review}\n` +
      `// ${sourceChange.lines} · state=${state}\n` +
      (projection?.reasons?.length ? `// ${projection.reasons.join(" | ")}\n` : ""),
    language: inferLanguageFromPath(sourceChange.path),
    lineCount: projection?.changed_files.length || 3,
    modified: sourceChange.status !== "deleted",
    origin: "context",
  };
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

async function loadDesktopSummary() {
  try {
    const snapshot = await getDesktopSummarySnapshot();
    desktopSummarySnapshot = snapshot;
    const topRunId = snapshot.digest.items[0]?.run_id;
    if (topRunId && !desktopExplainCache.has(topRunId)) {
      try {
        const explainPayload = await getDesktopRunExplain(topRunId);
        desktopExplainCache.set(topRunId, explainPayload);
      } catch (error) {
        console.warn("Failed to prefetch desktop explain payload", error);
      }
    }

    const existingTitles = new Set(["Summary stream connected", "Inbox: review_pending", "Inbox: review_failed", "Inbox: task_blocked"]);
    const retainedConversation = seedConversation.filter((item) => !item.title || !existingTitles.has(item.title));
    seedConversation.splice(0, seedConversation.length, ...buildDesktopSummaryConversation(snapshot), ...retainedConversation);

    renderSessions();
    renderFooterLane();
    renderRunSummary();
    renderSourceSummary();
    renderSourceEntries();
    renderContextPanel();
    renderOpenEditors();
    renderEditorSurface();
    renderConversation(seedConversation);
  } catch (error) {
    console.warn("Failed to load desktop summary snapshot", error);
  }
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
  renderConversation(seedConversation);
  renderComposerModes();
  renderAttachmentTray();
  renderCommandBar();
  renderEditorSurface();
  await loadDesktopSummary();
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
