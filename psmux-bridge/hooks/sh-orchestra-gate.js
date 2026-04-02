#!/usr/bin/env node

/**
 * Claude Code PreToolUse hook that prevents the Commander role from editing code.
 *
 * Commander should register this in settings.json. Example:
 * {
 *   "hooks": {
 *     "PreToolUse": [
 *       {
 *         "matcher": "*",
 *         "hooks": [
 *           {
 *             "type": "command",
 *             "command": "node psmux-bridge/hooks/sh-orchestra-gate.js"
 *           }
 *         ]
 *       }
 *     ]
 *   }
 * }
 */

const blockedTools = new Set(["Edit", "Write", "NotebookEdit"]);
const denyReason = "Commander role cannot edit code. Dispatch to a Builder pane.";

function emitAllow() {
  process.stdout.write(JSON.stringify({ decision: "allow" }));
}

function emitDeny(reason) {
  process.stdout.write(JSON.stringify({ decision: "deny", reason }));
}

function handleInput(raw) {
  let input = {};

  try {
    const trimmed = raw.trim();
    input = trimmed ? JSON.parse(trimmed) : {};
  } catch {
    emitAllow();
    return;
  }

  const role = (process.env.WINSMUX_ROLE || "").trim().toLowerCase();
  const toolName = typeof input.tool_name === "string" ? input.tool_name : "";

  if (role === "commander" && blockedTools.has(toolName)) {
    emitDeny(denyReason);
    return;
  }

  emitAllow();
}

let data = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  data += chunk;
});
process.stdin.on("end", () => {
  handleInput(data);
});
process.stdin.resume();
