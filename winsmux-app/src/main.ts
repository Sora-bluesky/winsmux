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
  open?: boolean;
  active?: boolean;
}

interface EditorFile {
  path: string;
  summary: string;
  content: string;
  active?: boolean;
}

interface SourceSummaryItem {
  label: string;
  value: string;
}

interface FooterStatusItem {
  label: string;
  value?: string;
  tone?: "default" | "accent";
}

const panes = new Map<string, PaneEntry>();
let paneCounter = 0;
let terminalDrawerOpen = false;
let contextPanelOpen = true;
let editorSurfaceOpen = false;
let composerImeActive = false;
let sidebarWidth = 292;
let selectedEditorPath = "winsmux-app/src/main.ts";

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
  { label: "main.ts", depth: 2, kind: "file", active: true },
  { label: "styles.css", depth: 2, kind: "file" },
  { label: "index.html", depth: 1, kind: "file" },
  { label: "winsmux-core", depth: 0, kind: "folder" },
];

const editorFiles: EditorFile[] = [
  {
    path: "winsmux-app/src/main.ts",
    summary: "Conversation shell scaffold",
    active: true,
    content:
      "const summaryStream = [\n  'blocked',\n  'review_requested',\n  'commit_ready',\n];\n\nfunction openEditorSurface() {\n  // Secondary work surface opened from conversation or source context.\n}\n",
  },
  {
    path: "winsmux-app/src/styles.css",
    summary: "Workspace sidebar and responsive shell",
    content:
      ".workspace-sidebar {\n  width: var(--sidebar-width);\n}\n\n.editor-secondary-surface {\n  border-left: 1px solid var(--border-muted);\n}\n",
  },
];

const sourceSummaryItems: SourceSummaryItem[] = [
  { label: "Branch", value: "codex/task264-review-capable-slot" },
  { label: "Changed", value: "3 files" },
  { label: "Review", value: "passed · branch mismatch" },
  { label: "Worktree", value: ".worktrees/builder-2" },
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
    if (item.kind === "file") {
      button.addEventListener("click", () => {
        selectedEditorPath = findEditorFile(item.label)?.path || selectedEditorPath;
        setEditorSurface(true);
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
    });
    root.appendChild(button);
  }
}

function renderSourceSummary() {
  const root = document.getElementById("source-summary-list");
  if (!root) {
    return;
  }

  root.innerHTML = "";
  for (const item of sourceSummaryItems) {
    const row = document.createElement("div");
    row.className = "sidebar-summary-row";
    row.innerHTML = `<span class="sidebar-summary-label">${item.label}</span><span class="sidebar-summary-value">${item.value}</span>`;
    root.appendChild(row);
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
  const tabs = document.getElementById("editor-tabs");
  const code = document.getElementById("editor-code");
  if (!path || !tabs || !code) {
    return;
  }

  const selected = findEditorFile(selectedEditorPath) || editorFiles[0];
  selectedEditorPath = selected.path;

  path.textContent = selected.path;
  code.textContent = selected.content;
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
  return editorFiles.find((editor) => editor.path.endsWith(label));
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
  renderFooterLane();
  renderConversation(seedConversation);
  renderEditorSurface();
  setContextPanel(true);
  setEditorSurface(false);
  setTerminalDrawer(false);
  initializeSidebarResize();

  document.getElementById("toggle-terminal-btn")?.addEventListener("click", () => {
    setTerminalDrawer(!terminalDrawerOpen);
  });

  document.getElementById("toggle-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
  });

  document.getElementById("close-editor-btn")?.addEventListener("click", () => {
    setEditorSurface(false);
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

  window.addEventListener("resize", () => {
    panes.forEach((pane) => pane.fitAddon.fit());
  });
});
