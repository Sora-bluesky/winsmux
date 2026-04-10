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

interface ConversationItem {
  type: "user" | "operator" | "system";
  title?: string;
  body: string;
  chips?: string[];
}

const panes = new Map<string, PaneEntry>();
let paneCounter = 0;
let terminalDrawerOpen = false;
let contextPanelOpen = true;
let composerImeActive = false;

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
    title: "Review requested",
    body: "worker-2 changed 3 files. Branch/head mismatch is blocking commit. Open Explain to inspect.",
    chips: ["Open Explain", "Review", "Commit Ready"],
  },
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
      for (const chipText of item.chips) {
        const chip = document.createElement("span");
        chip.className = "timeline-chip";
        chip.textContent = chipText;
        chipRow.appendChild(chip);
      }
      article.appendChild(chipRow);
    }

    timeline.appendChild(article);
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

function appendUserMessage(message: string) {
  seedConversation.push({ type: "user", body: message });
  seedConversation.push({
    type: "operator",
    body: "Operator update: queued for dispatch. Open Explain or Digest after the next material event.",
  });
  renderConversation(seedConversation);
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

  renderConversation(seedConversation);
  setContextPanel(true);
  setTerminalDrawer(false);

  document.getElementById("toggle-terminal-btn")?.addEventListener("click", () => {
    setTerminalDrawer(!terminalDrawerOpen);
  });

  document.getElementById("toggle-context-btn")?.addEventListener("click", () => {
    setContextPanel(!contextPanelOpen);
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
