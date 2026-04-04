import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Terminal } from "xterm";
import { FitAddon } from "@xterm/addon-fit";
import "xterm/css/xterm.css";

let terminal: Terminal;
let fitAddon: FitAddon;

async function initTerminal() {
  const container = document.getElementById("terminal-container");
  if (!container) return;

  terminal = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: "'Cascadia Code', 'Consolas', monospace",
    theme: {
      background: "#1a1b26",
      foreground: "#c0caf5",
      cursor: "#c0caf5",
    },
  });

  fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(container);
  fitAddon.fit();

  // Send user input to PTY backend
  terminal.onData((data: string) => {
    invoke("pty_write", { data });
  });

  // Resize handling
  terminal.onResize(({ cols, rows }) => {
    invoke("pty_resize", { cols, rows });
  });

  window.addEventListener("resize", () => fitAddon.fit());

  // Listen for PTY output from Rust backend
  await listen<string>("pty-output", (event) => {
    terminal.write(event.payload);
  });

  // Spawn PTY
  const { cols, rows } = { cols: terminal.cols, rows: terminal.rows };
  await invoke("pty_spawn", { cols, rows });
}

window.addEventListener("DOMContentLoaded", () => {
  initTerminal();
});
