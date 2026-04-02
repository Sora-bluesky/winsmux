// sh-orchestra-gate.js — PreToolUse hook
// Prevents Commander from writing code or bypassing psmux-bridge
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const DEBUG_LOG_PATH = path.join(os.tmpdir(), "winsmux-sh-orchestra-gate-command.log");
const SECRET_PATTERN =
  /\b(?:gho_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b|(?:^|\s)(?:GITHUB_TOKEN|GH_TOKEN|API_KEY)\s*=/i;

try {
  const input = fs.readFileSync(0, "utf8");
  const event = JSON.parse(input);
  const toolName = event.tool_name || "";
  const toolInput = event.tool_input || {};
  const rawCommand = typeof toolInput.command === "string" ? toolInput.command : "";

  logCommand(toolName, rawCommand);

  // Rule 1: Commander cannot write/edit code files
  if (toolName === "Write" || toolName === "Edit") {
    const filePath = toolInput.file_path || toolInput.file || "";
    if (/\.(ps1|js|rs|ts|py)$/i.test(filePath)) {
      deny("Commander cannot write code files. Delegate to Builder via psmux-bridge send.");
    }
  }

  // Rule 2: No direct psmux send-keys (use psmux-bridge send)
  if (toolName === "Bash") {
    if (/psmux\s+send-keys/.test(rawCommand) && !/psmux-bridge/.test(rawCommand)) {
      deny("Use psmux-bridge send instead of direct psmux send-keys.");
    }
  }

  // Rule 3: No plaintext secrets in commands
  if (toolName === "Bash") {
    const commandForSecretScan = stripHeredocBodies(rawCommand);
    if (SECRET_PATTERN.test(commandForSecretScan)) {
      deny("Use psmux-bridge vault instead of plaintext secrets.");
    }
  }

  // Rule 4: No direct codex exec (use orchestra-start)
  if (toolName === "Bash") {
    if (/codex\s+(exec|e)\s/.test(rawCommand) && !/psmux\s+send-keys/.test(rawCommand)) {
      deny("Use orchestra-start or psmux send-keys to dispatch Codex, not direct codex exec.");
    }
  }

  // Rule 5: Block shallow git clones (they break worktree creation)
  if (toolName === "Bash") {
    if (/git\s+clone\s+.*--depth/.test(rawCommand)) {
      deny("Shallow clones break git worktree. Use full clone (remove --depth).");
    }
  }

  // Rule 6: Block bare git rm (allow only git rm --cached)
  if (toolName === "Bash") {
    if (/git\s+rm\s/.test(rawCommand) && !/--cached/.test(rawCommand)) {
      deny("Use git rm --cached to untrack files. Bare git rm deletes local files.");
    }
  }

  process.exit(0);
} catch (e) {
  deny("Hook parse error: " + e.message);
}

function logCommand(toolName, command) {
  try {
    const entry = {
      timestamp: new Date().toISOString(),
      tool_name: toolName,
      command,
    };
    fs.appendFileSync(DEBUG_LOG_PATH, JSON.stringify(entry) + os.EOL, "utf8");
  } catch {
    // Debug logging must never block the hook.
  }
}

function stripHeredocBodies(command) {
  if (!command.includes("<<")) {
    return command;
  }

  const lines = command.split(/\r?\n/);
  const output = [];
  let activeTerminator = null;

  for (const line of lines) {
    if (activeTerminator !== null) {
      if (line.trim() === activeTerminator) {
        activeTerminator = null;
        output.push(line);
      }
      continue;
    }

    output.push(line);

    const heredocMatches = Array.from(line.matchAll(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/g));
    if (heredocMatches.length > 0) {
      activeTerminator = heredocMatches[heredocMatches.length - 1][2];
    }
  }

  return output.join("\n");
}

function deny(reason) {
  process.stderr.write(JSON.stringify({
    hookSpecificOutput: { permissionDecision: "deny" },
    systemMessage: reason,
  }));
  process.exit(2);
}

module.exports = {
  DEBUG_LOG_PATH,
  SECRET_PATTERN,
  stripHeredocBodies,
};
