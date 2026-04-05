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

const panes = new Map<string, PaneEntry>();
let paneCounter = 0;

function createPane(paneId?: string): string {
  const id = paneId || `pane-${++paneCounter}`;
  const container = document.getElementById("panes-container")!;

  // Create pane wrapper
  const paneDiv = document.createElement("div");
  paneDiv.className = "pane";
  paneDiv.id = `pane-${id}`;

  // Header
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

  // Terminal container
  const termDiv = document.createElement("div");
  termDiv.className = "pane-terminal";

  paneDiv.appendChild(header);
  paneDiv.appendChild(termDiv);

  // Add splitter if not first pane
  if (panes.size > 0) {
    const splitter = document.createElement("div");
    splitter.className = "splitter";
    container.appendChild(splitter);
  }

  container.appendChild(paneDiv);

  // Initialize xterm
  const terminal = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: "'Cascadia Code', 'Consolas', monospace",
    theme: {
      background: "#1a1b26",
      foreground: "#c0caf5",
      cursor: "#c0caf5",
    },
  });

  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(termDiv);
  fitAddon.fit();

  terminal.onData((data: string) => {
    invoke("pty_write", { paneId: id, data });
  });

  terminal.onResize(({ cols, rows }) => {
    invoke("pty_resize", { paneId: id, cols, rows });
  });

  panes.set(id, { terminal, fitAddon, container: paneDiv });

  // Spawn PTY
  const { cols, rows } = { cols: terminal.cols, rows: terminal.rows };
  invoke("pty_spawn", { paneId: id, cols, rows });

  return id;
}

function closePane(id: string) {
  const entry = panes.get(id);
  if (!entry) return;

  // Don't close last pane
  if (panes.size <= 1) return;

  entry.terminal.dispose();

  // Remove splitter before this pane if exists
  const prev = entry.container.previousElementSibling;
  if (prev && prev.classList.contains("splitter")) {
    prev.remove();
  }

  entry.container.remove();
  panes.delete(id);
  invoke("pty_close", { paneId: id });

  // Refit remaining panes
  panes.forEach((p) => p.fitAddon.fit());
}

window.addEventListener("DOMContentLoaded", async () => {
  // Listen for PTY output (JSON payload with pane_id and data)
  await listen<string>("pty-output", (event) => {
    try {
      const payload = JSON.parse(event.payload);
      const entry = panes.get(payload.pane_id);
      if (entry) {
        entry.terminal.write(payload.data);
      }
    } catch {
      // Fallback: write to first pane if not JSON
      const first = panes.values().next().value;
      if (first) first.terminal.write(event.payload);
    }
  });

  // Create default pane
  createPane("main");

  // Wire add pane button
  document.getElementById("add-pane-btn")!.onclick = () => createPane();

  // Global resize
  window.addEventListener("resize", () => {
    panes.forEach((p) => p.fitAddon.fit());
  });
});
