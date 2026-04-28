// mcp-server.js — MCP server exposing winsmux commands as tools
// Transport: stdio (newline-delimited JSON-RPC 2.0)
"use strict";

const { execSync } = require("child_process");
const path = require("path");

const BRIDGE_SCRIPT = resolveBridgeScript();
const SERVER_NAME = "winsmux-mcp";
const SERVER_VERSION = "0.24.3";
const PROTOCOL_VERSION = "2024-11-05";

// --- Tool Definitions ---

const TOOLS = [
  {
    name: "winsmux_list",
    description: "List labeled panes in the current winsmux session",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "winsmux_read",
    description: "Read recent output from a pane",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", description: "Pane label or ID" },
        lines: { type: "number", description: "Number of lines to capture (default: 50)" },
      },
      required: ["target"],
    },
  },
  {
    name: "winsmux_send",
    description: "Send text to a pane via winsmux send",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", description: "Pane label or ID" },
        text: { type: "string", description: "Text to send" },
      },
      required: ["target", "text"],
    },
  },
  {
    name: "winsmux_dispatch",
    description: "Route text to the appropriate pane by keyword",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "Text to dispatch" },
      },
      required: ["text"],
    },
  },
  {
    name: "winsmux_health",
    description: "Health check all panes",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "winsmux_pipeline",
    description: "Run plan-exec-verify-fix pipeline for a task",
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "string", description: "Task description" },
      },
      required: ["task"],
    },
  },
];

// --- Bridge Invocation ---

function resolveBridgeScript() {
  // Try sibling first (winsmux-core/mcp-server.js -> ../scripts/winsmux-core.ps1)
  const candidates = [
    path.resolve(__dirname, "..", "scripts", "winsmux-core.ps1"),
    path.resolve(__dirname, "winsmux-core.ps1"),
  ];
  for (const p of candidates) {
    try {
      require("fs").accessSync(p, require("fs").constants.R_OK);
      return p;
    } catch {
      // continue
    }
  }
  // Fallback — let pwsh report the error at runtime
  return candidates[0];
}

function invokeBridge(args) {
  const escaped = args.map((a) => {
    const s = String(a);
    if (s === "") return '""';
    if (/\s/.test(s)) return '"' + s.replace(/"/g, '\\"') + '"';
    return s;
  });
  const cmd = `pwsh -NoProfile -File "${BRIDGE_SCRIPT}" ${escaped.join(" ")}`;
  try {
    const stdout = execSync(cmd, {
      encoding: "utf8",
      timeout: 30000,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { success: true, output: stdout.trimEnd() };
  } catch (err) {
    const stderr = err.stderr ? err.stderr.trimEnd() : "";
    const stdout = err.stdout ? err.stdout.trimEnd() : "";
    return { success: false, output: stderr || stdout || err.message };
  }
}

// --- Tool Handlers ---

function handleToolCall(name, args) {
  switch (name) {
    case "winsmux_list":
      return invokeBridge(["list"]);

    case "winsmux_read": {
      const bridgeArgs = ["read", args.target];
      if (args.lines) bridgeArgs.push(String(args.lines));
      return invokeBridge(bridgeArgs);
    }

    case "winsmux_send":
      return invokeBridge(["send", args.target, args.text]);

    case "winsmux_dispatch":
      return invokeBridge(["dispatch-route", args.text]);

    case "winsmux_health":
      return invokeBridge(["health-check"]);

    case "winsmux_pipeline":
      return invokeBridge(["pipeline", args.task]);

    default:
      return { success: false, output: `Unknown tool: ${name}` };
  }
}

// --- JSON-RPC Response Helpers ---

function jsonRpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function jsonRpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

// --- MCP Method Handlers ---

function handleInitialize(id, params) {
  return jsonRpcResult(id, {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: { tools: {} },
    serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
  });
}

function handleInitializedNotification() {
  // No response needed for notifications
  return null;
}

function handleToolsList(id) {
  return jsonRpcResult(id, { tools: TOOLS });
}

function handleToolsCall(id, params) {
  const name = params.name;
  const args = params.arguments || {};

  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) {
    return jsonRpcError(id, -32602, `Unknown tool: ${name}`);
  }

  const result = handleToolCall(name, args);
  return jsonRpcResult(id, {
    content: [
      {
        type: "text",
        text: result.output,
      },
    ],
    isError: !result.success,
  });
}

function handlePing(id) {
  return jsonRpcResult(id, {});
}

function dispatch(msg) {
  const method = msg.method;
  const id = msg.id;
  const params = msg.params || {};

  switch (method) {
    case "initialize":
      return handleInitialize(id, params);
    case "notifications/initialized":
      return handleInitializedNotification();
    case "ping":
      return handlePing(id);
    case "tools/list":
      return handleToolsList(id);
    case "tools/call":
      return handleToolsCall(id, params);
    default:
      if (id !== undefined) {
        return jsonRpcError(id, -32601, `Method not found: ${method}`);
      }
      // Unknown notification — ignore
      return null;
  }
}

// --- stdio Transport ---

function send(obj) {
  const line = JSON.stringify(obj);
  process.stdout.write(line + "\n");
}

let buffer = "";

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let newlineIdx;
  while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newlineIdx).trim();
    buffer = buffer.slice(newlineIdx + 1);
    if (!line) continue;

    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      send(jsonRpcError(null, -32700, "Parse error"));
      continue;
    }

    const response = dispatch(msg);
    if (response !== null) {
      send(response);
    }
  }
});

process.stdin.on("end", () => {
  process.exit(0);
});

// Suppress unhandled errors on stdout (broken pipe)
process.stdout.on("error", () => process.exit(0));
