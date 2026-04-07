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
    const commandForRule2 = stripHeredocBodies(rawCommand);
    if (/winsmux\s+send-keys/.test(commandForRule2) && !/winsmux-core/.test(commandForRule2)) {
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

  // Rule 4: Block writes that disable local hooks in settings.local.json
  if (toolName === "Bash") {
    const commandForRule4 = stripHeredocBodies(rawCommand);
    if (isSettingsLocalHookMutation(commandForRule4)) {
      deny("Hooks in .claude/settings.local.json cannot be disabled from Bash.");
    }
  }

  // Rule 5: No direct Codex dispatch outside winsmux send
  if (toolName === "Bash") {
    const commandForRule5 = stripHeredocBodies(rawCommand);
    if (isDirectCodexDispatch(commandForRule5)) {
      deny("Use winsmux send to dispatch Codex to panes");
    }
  }

  // Rule 6: Block shallow git clones (they break worktree creation)
  if (toolName === "Bash") {
    if (/git\s+clone\s+.*--depth/.test(rawCommand)) {
      deny("Shallow clones break git worktree. Use full clone (remove --depth).");
    }
  }

  // Rule 7: Block bare git rm (allow only git rm --cached)
  if (toolName === "Bash") {
    if (/git\s+rm\s/.test(rawCommand) && !/--cached/.test(rawCommand)) {
      deny("Use git rm --cached to untrack files. Bare git rm deletes local files.");
    }
  }

  // Rule 8: Block Commander from using write-capable Agent modes outside isolated worktrees
  if (toolName === "Agent") {
    const agentMode = normalizeAgentValue(toolInput.mode);
    const subagentType = normalizeAgentValue(toolInput.subagent_type);
    const isolation = normalizeAgentValue(toolInput.isolation);

    if (isolation !== "worktree" && agentMode !== "plan" && subagentType !== "explore" && isWriteCapableAgentMode(agentMode)) {
      deny("Commander cannot use write-capable Agent modes outside worktree isolation. Use plan mode, Explore subagents, or worktree isolation.");
    }
  }

  // Rule 9: REMOVED - winsmux verify not yet implemented.
  // Will be re-added when verify command exists. See #277.

  // Rule 10: Block review-gated commit/merge commands without Reviewer PASS (#279)
  if (toolName === "Bash") {
    if (isReviewGatedCommand(rawCommand) && !/bump-version|chore:\s*bump/.test(rawCommand)) {
      const reviewStatePath = path.join(process.cwd(), '.winsmux', 'review-state.json');
      const denyMessage = "Reviewer PASS required before commit or merge. Run: pwsh scripts/winsmux-core.ps1 review-approve";
      try {
        const currentBranch = getCurrentBranch(process.cwd());
        const reviewState = JSON.parse(fs.readFileSync(reviewStatePath, 'utf8'));
        if (!currentBranch || !reviewState[currentBranch] || reviewState[currentBranch].status !== 'PASS') {
          deny(denyMessage);
        }
      } catch (e) {
        deny(denyMessage);
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

function isGitCommitCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+commit\b/.test(command);
}

function isGitMergeCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+merge\b/.test(command);
}

function isGhPrMergeCommand(command) {
  return /\bgh\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+pr\s+merge\b/.test(command);
}

function isReviewGatedCommand(command) {
  return isGitCommitCommand(command) || isGitMergeCommand(command) || isGhPrMergeCommand(command);
}

function normalizeAgentValue(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function isSettingsLocalHookMutation(command) {
  if (!/settings\.local\.json/i.test(command)) {
    return false;
  }

  const writePatterns = [
    /\bpython(?:\d+(?:\.\d+)*)?\b[\s\S]*settings\.local\.json/i,
    /\becho\b[\s\S]*settings\.local\.json/i,
    /\bcat\b[\s\S]*>\s*["']?[^"'\n]*settings\.local\.json/i,
  ];
  const hookDisablePatterns = [
    /hooks[\s\S]*\{\s*\}/i,
    /\bdelete\b[\s\S]*hooks/i,
    /\bpop\s*\(\s*['"]hooks['"]\s*\)/i,
    /\bdel\s*\(\s*\.hooks\s*\)/i,
  ];

  return (
    writePatterns.some((pattern) => pattern.test(command)) ||
    hookDisablePatterns.some((pattern) => pattern.test(command))
  );
}

function isDirectCodexDispatch(command) {
  const codexDispatchPattern = /\bcodex\b(?:\s+(?:exec|e)\b|\s+--sandbox\b)/i;
  return (
    codexDispatchPattern.test(command) &&
    !/\bwinsmux\s+send\b/i.test(command) &&
    !/\bwinsmux-core\b/i.test(command) &&
    !/^\s*gh\s+/i.test(command)
  );
}

function isWriteCapableAgentMode(mode) {
  return mode === "acceptedits" || mode === "auto" || mode === "bypasspermissions" || mode === "dontask";
}

function getCurrentBranch(repoRoot) {
  const gitDir = resolveGitDir(repoRoot);
  const headPath = path.join(gitDir, "HEAD");
  const head = fs.readFileSync(headPath, "utf8").trim();
  const match = /^ref:\s+refs\/heads\/(.+)$/.exec(head);
  return match ? match[1] : "";
}

function resolveGitDir(repoRoot) {
  const dotGitPath = path.join(repoRoot, ".git");
  const stat = fs.statSync(dotGitPath);
  if (stat.isDirectory()) {
    return dotGitPath;
  }

  const dotGitContents = fs.readFileSync(dotGitPath, "utf8").trim();
  const match = /^gitdir:\s*(.+)$/i.exec(dotGitContents);
  if (!match) {
    throw new Error("invalid .git pointer");
  }

  return path.resolve(repoRoot, match[1].trim());
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
  isDirectCodexDispatch,
  isGhPrMergeCommand,
  isGitCommitCommand,
  isGitMergeCommand,
  isReviewGatedCommand,
  isSettingsLocalHookMutation,
  isWriteCapableAgentMode,
  normalizeAgentValue,
  stripHeredocBodies,
};
