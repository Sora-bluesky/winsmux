import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";

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

interface ConversationItem {
  type: "user" | "operator" | "system";
  title?: string;
  body: string;
  chips?: ConversationChip[];
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

type SourceFilter = "all" | "candidates" | "attention" | "builder-2" | "builder-3";

type ChangeStatus = "modified" | "added" | "deleted" | "renamed";
type ChangeRisk = "low" | "medium" | "high";

interface SourceChange {
  path: string;
  summary: string;
  slot: string;
  status: ChangeStatus;
  risk: ChangeRisk;
  worktree: string;
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
  tone?: "default" | "accent";
}

type ComposerMode = "ask" | "dispatch" | "review" | "explain";

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

const composerModes: Array<{ mode: ComposerMode; label: string; placeholder: string }> = [
  { mode: "ask", label: "Ask", placeholder: "Ask the Operator for clarification, status, or guidance" },
  { mode: "dispatch", label: "Dispatch", placeholder: "Dispatch the next task to the Operator" },
  { mode: "review", label: "Review", placeholder: "Request review, approval, or audit from the Operator" },
  { mode: "explain", label: "Explain", placeholder: "Ask the Operator to explain the current run state" },
];

const seedConversation: ConversationItem[] = [
  {
    type: "user",
    body: "Please tighten the notification boundary and show why this run is blocked.",
  },
  {
    type: "operator",
    body: "Operator update: inbox shows 2 approval waits. I am checking run ledger and evidence digest now.",
  },
  {
    type: "system",
    title: "Commit blocked",
    body: "worker-2 changed 3 files. Review passed, but branch/head mismatch still blocks commit. Open Explain or inspect the edited files.",
    chips: [
      { label: "Open Explain", action: "open-explain" },
      { label: "Open in Editor", action: "open-editor" },
      { label: "Source Context", action: "open-source-context" },
      { label: "Terminal", action: "open-terminal" },
    ],
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
    slot: "worker-2",
    status: "modified",
    risk: "medium",
    worktree: "builder-2",
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
    slot: "worker-2",
    status: "modified",
    risk: "low",
    worktree: "builder-2",
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
    slot: "worker-3",
    status: "modified",
    risk: "high",
    worktree: "builder-3",
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

const footerLeftItems: FooterStatusItem[] = [
  { label: "Local environment" },
  { label: "GPT-5.4" },
  { label: "High" },
  { label: "Settings", tone: "accent" },
];

const footerRightItems: FooterStatusItem[] = [
  { label: "config.toml" },
  { label: "main" },
  { label: "Operator ready", tone: "accent" },
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
    void invoke("pty_write", { paneId: id, data });
  });

  terminal.onResize(({ cols, rows }) => {
    void invoke("pty_resize", { paneId: id, cols, rows });
  });

  panes.set(id, { terminal, fitAddon, container: paneDiv });

  const { cols, rows } = { cols: terminal.cols, rows: terminal.rows };
  void invoke("pty_spawn", { paneId: id, cols, rows });

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
  void invoke("pty_close", { paneId: id });

  panes.forEach((pane) => pane.fitAddon.fit());
}

function renderSessions() {
  const root = document.getElementById("session-list");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  for (const session of sessionItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row ${session.active ? "is-active" : ""}`;
    button.innerHTML = `<span class="sidebar-row-title">${session.name}</span><span class="sidebar-row-meta">${session.meta}</span>`;
    root.appendChild(button);
  }
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
    });
    root.appendChild(button);
  }
}

function renderSourceSummary() {
  const root = document.getElementById("source-summary-list");
  if (!root) {
    return;
  }

  const visibleChanges = getVisibleSourceChanges();
  const primaryChange = getPrimarySourceChange(visibleChanges);
  const entryCount = visibleChanges.length;
  const attentionCount = visibleChanges.filter((item) => item.needsAttention).length;
  const commitCandidates = visibleChanges.filter((item) => item.commitCandidate).length;
  const summaryItems = [
    { label: "Branch", value: primaryChange?.branch ?? "No branch" },
    { label: "Changed", value: `${entryCount} files` },
    { label: "Review", value: primaryChange?.review ?? "No review state" },
    { label: "Worktree", value: primaryChange ? `.worktrees/${primaryChange.worktree}` : "No worktree" },
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

  root.innerHTML = "";
  const entryItems: Array<{ label: string; value: string; filter: SourceFilter; tone?: "success" | "attention" }> = [
    { label: "Commit candidates", value: `${sourceControlState.entries.filter((item) => item.commitCandidate).length} ready`, tone: "success", filter: "candidates" },
    { label: "Needs attention", value: `${sourceControlState.entries.filter((item) => item.needsAttention).length} blocker`, tone: "attention", filter: "attention" },
    { label: "worktree-builder-2", value: `${sourceControlState.entries.filter((item) => item.worktree === "builder-2").length} files`, filter: "builder-2" },
    { label: "worktree-builder-3", value: `${sourceControlState.entries.filter((item) => item.worktree === "builder-3").length} files`, filter: "builder-3" },
  ];

  for (const item of entryItems) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `sidebar-row source-entry-row ${activeSourceFilter === item.filter ? "is-active" : ""} ${
      item.tone ? `is-${item.tone}` : ""
    }`;
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
    });
    root.appendChild(button);
  }
}

function getVisibleSourceChanges() {
  switch (activeSourceFilter) {
    case "candidates":
      return sourceControlState.entries.filter((item) => item.commitCandidate);
    case "attention":
      return sourceControlState.entries.filter((item) => item.needsAttention);
    case "builder-2":
      return sourceControlState.entries.filter((item) => item.worktree === "builder-2");
    case "builder-3":
      return sourceControlState.entries.filter((item) => item.worktree === "builder-3");
    default:
      return sourceControlState.entries;
  }
}

function getPrimarySourceChange(changes: SourceChange[]) {
  return changes.find((item) => item.path === selectedEditorPath) ?? changes[0] ?? sourceControlState.entries[0];
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
    { label: "slot", value: primaryChange?.slot ?? "No slot" },
    { label: "branch", value: primaryChange?.branch ?? "No branch" },
    { label: "review", value: primaryChange?.review ?? "No review state" },
    { label: "worktree", value: primaryChange ? `.worktrees/${primaryChange.worktree}` : "No worktree" },
  ];
  for (const item of resolvedContextSections) {
    const row = document.createElement("div");
    row.className = "context-section";
    row.innerHTML = `<div class="context-label">${item.label}</div><div class="context-value">${item.value}</div>`;
    sectionRoot.appendChild(row);
  }

  overviewRoot.innerHTML = "";
  const overviewCards = [
    { label: "Selected scope", value: activeSourceFilter === "all" ? "All changes" : activeSourceFilter.replace("-", " ") },
    { label: "Commit candidates", value: `${visibleChanges.filter((item) => item.commitCandidate).length}` },
    { label: "Needs attention", value: `${visibleChanges.filter((item) => item.needsAttention).length}` },
    { label: "Active worktree", value: primaryChange?.worktree ?? "n/a" },
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
    button.className = `context-file-row ${change.path === selectedEditorPath && editorSurfaceOpen ? "is-active" : ""} risk-${change.risk}`;
    button.innerHTML =
      `<span class="context-file-name">${change.path.split("/").pop() ?? change.path}</span>` +
      `<span class="context-file-meta">${change.summary}</span>` +
      `<span class="context-file-trace">${change.status} · ${change.lines} · ${change.worktree} · ${change.review}</span>`;
    button.addEventListener("click", () => {
      selectedEditorPath = change.path;
      setEditorSurface(true);
      renderSourceSummary();
    });
    fileRoot.appendChild(button);
  }
}

function renderFooterLane() {
  const left = document.getElementById("footer-left");
  const right = document.getElementById("footer-right");
  if (!left || !right) {
    return;
  }

  const buildPill = (item: FooterStatusItem) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `footer-pill ${item.tone === "accent" ? "is-accent" : ""}`;
    button.innerHTML = item.value
      ? `<span class="footer-pill-label">${item.label}</span><span class="footer-pill-value">${item.value}</span>`
      : `<span class="footer-pill-value">${item.label}</span>`;
    if (item.label === "Settings" || item.value === "Settings") {
      button.addEventListener("click", () => setSettingsSheet(true));
    }
    return button;
  };

  left.innerHTML = "";
  right.innerHTML = "";

  for (const item of footerLeftItems) {
    left.appendChild(buildPill(item));
  }

  for (const item of footerRightItems) {
    right.appendChild(buildPill(item));
  }
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
      activeComposerMode = item.mode;
      composerInput.placeholder = item.placeholder;
      renderComposerModes();
    });
    root.appendChild(button);
  }

  const selected = composerModes.find((item) => item.mode === activeComposerMode);
  if (selected) {
    composerInput.placeholder = selected.placeholder;
  }
}

function renderConversation(items: ConversationItem[]) {
  const timeline = document.getElementById("conversation-timeline");
  if (!timeline) {
    return;
  }

  timeline.innerHTML = "";

  for (const item of items) {
    const article = document.createElement("article");
    article.className = `timeline-item timeline-${item.type}`;

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
      seedConversation.push({
        type: "operator",
        body: "Explain opened: this run is blocked on branch/head alignment after review passed. Changed files and commit readiness are available in the context sheet.",
      });
      renderConversation(seedConversation);
      break;
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
  const sourceChange = sourceControlState.entries.find((item) => item.path === selected.path);
  selectedEditorPath = selected.path;

  path.textContent = selected.path;
  meta.innerHTML = "";
  for (const item of [
    selected.language,
    `${selected.lineCount} lines`,
    selected.modified ? "Modified" : "Saved",
    selected.origin === "context" ? "Opened from context" : "Opened from explorer",
    sourceChange ? `${sourceChange.status} · ${sourceChange.worktree}` : "No source metadata",
  ]) {
    const chip = document.createElement("span");
    chip.className = `editor-meta-chip ${item === "Modified" ? "is-modified" : ""}`;
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

function appendUserMessage(message: string) {
  seedConversation.push({ type: "user", body: message });
  seedConversation.push({
    type: "operator",
    body: "Operator update: queued for dispatch. Open Explain, inspect changed files, or use the terminal drawer if raw PTY detail becomes necessary.",
  });
  renderConversation(seedConversation);
}

function findEditorFile(label: string) {
  const existing = editorFiles.find((editor) => editor.path === label);
  if (existing) {
    return existing;
  }

  const sourceChange = sourceControlState.entries.find((entry) => entry.path === label);
  if (!sourceChange) {
    return undefined;
  }

  return {
    path: sourceChange.path,
    summary: sourceChange.summary,
    content:
      `// Generated source-control preview\n` +
      `// ${sourceChange.branch} · ${sourceChange.worktree} · ${sourceChange.review}\n` +
      `// ${sourceChange.lines}\n`,
    language: inferLanguageFromPath(sourceChange.path),
    lineCount: 3,
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
  await listen<string>("pty-output", (event) => {
    try {
      const payload = JSON.parse(event.payload);
      const entry = panes.get(payload.pane_id);
      if (entry) {
        entry.terminal.write(payload.data);
      }
    } catch {
      const first = panes.values().next().value as PaneEntry | undefined;
      if (first) {
        first.terminal.write(event.payload);
      }
    }
  });

  renderSessions();
  renderExplorer();
  renderOpenEditors();
  renderSourceSummary();
  renderSourceEntries();
  renderContextPanel();
  renderFooterLane();
  renderConversation(seedConversation);
  renderComposerModes();
  renderEditorSurface();
  syncResponsiveShell();
  setEditorSurface(false);
  setTerminalDrawer(false);
  initializeSidebarResize();

  document.getElementById("toggle-sidebar-btn")?.addEventListener("click", () => {
    setSidebarOpen(!sidebarOpen);
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

  document.getElementById("add-pane-btn")?.addEventListener("click", () => {
    if (!terminalDrawerOpen) {
      setTerminalDrawer(true);
    }
    createPane();
  });

  const composer = document.getElementById("composer") as HTMLFormElement | null;
  const composerInput = document.getElementById("composer-input") as HTMLTextAreaElement | null;
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

    composer.addEventListener("submit", (event) => {
      event.preventDefault();
      const value = composerInput.value.trim();
      if (!value) {
        return;
      }
      appendUserMessage(value);
      composerInput.value = "";
    });
  }

  window.addEventListener("keydown", (event) => {
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
