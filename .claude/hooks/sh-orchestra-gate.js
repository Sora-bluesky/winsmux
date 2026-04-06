// sh-orchestra-gate.js — PreToolUse hook
// Prevents Commander from writing code or bypassing winsmux CLI
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
      deny("Commander cannot write code files. Delegate to Builder via winsmux send.");
    }
  }

  // Rule 2: No direct winsmux send-keys (use winsmux send)
  if (toolName === "Bash") {
    if (/winsmux\s+send-keys/.test(rawCommand) && !/winsmux-core/.test(rawCommand)) {
      deny("Use winsmux send instead of direct winsmux send-keys.");
    }
  }

  // Rule 3: No plaintext secrets in commands
  if (toolName === "Bash") {
    const commandForSecretScan = stripHeredocBodies(rawCommand);
    if (SECRET_PATTERN.test(commandForSecretScan)) {
      deny("Use winsmux vault instead of plaintext secrets.");
    }
  }

  // Rule 4: No direct codex exec (use orchestra-start)
  if (toolName === "Bash") {
    if (/codex\s+(exec|e)\s/.test(rawCommand) && !/winsmux\s+send/.test(rawCommand) && !/winsmux-core/.test(rawCommand) && !/^gh\s/.test(rawCommand)) {
      deny("Use orchestra-start or winsmux send to dispatch Codex, not direct codex exec.");
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

  // Rule 7: REMOVED - winsmux verify not yet implemented.
  // Will be re-added when verify command exists. See #277.

  // Rule 8: Block git commit without Reviewer PASS (#279)
  if (toolName === "Bash") {
    if (/git\s+(commit|merge)/.test(rawCommand) && !/bump-version|chore:\s*bump/.test(rawCommand)) {
      const reviewStatePath = path.join(process.cwd(), '.winsmux', 'review-state.json');
      try {
        if (fs.existsSync(reviewStatePath)) {
          const cp = require('child_process');
          const currentBranch = cp.execSync('git branch --show-current', { encoding: 'utf8' }).trim();
          if (currentBranch && currentBranch !== 'main') {
            const reviewState = JSON.parse(fs.readFileSync(reviewStatePath, 'utf8'));
            if (!reviewState[currentBranch] || reviewState[currentBranch].status !== 'PASS') {
              deny("Reviewer PASS required before commit. Run: pwsh winsmux-core/scripts/review-approve.ps1");
            }
          }
        }
      } catch (e) {
        // If review-state.json missing or invalid, allow (bootstrapping)
      }
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
