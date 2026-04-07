// sh-orchestra-gate.js — PreToolUse hook
// Prevents Commander from writing code or bypassing winsmux CLI
"use strict";

const { execFileSync } = require("child_process");
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
  const bashCommand = toolName === "Bash" ? stripHeredocBodies(rawCommand) : "";

  logCommand(toolName, rawCommand);

  // Rule 1: Commander cannot write/edit code files
  if (toolName === "Write" || toolName === "Edit") {
    const filePath = toolInput.file_path || toolInput.file || "";
    if (isProtectedReviewStatePath(filePath)) {
      deny("Direct writes to .winsmux/review-state.json are not allowed. Use review-approve or review-reset.");
    }

    if (/\.(ps1|js|rs|ts|py)$/i.test(filePath)) {
      deny("Commander cannot write code files. Delegate to Builder via winsmux send.");
    }
  }

  // Rule 2: No direct winsmux send-keys (use winsmux send)
  if (toolName === "Bash") {
    if (/winsmux\s+send-keys/.test(bashCommand) && !/winsmux-core/.test(bashCommand)) {
      deny("Use winsmux send instead of direct winsmux send-keys.");
    }
  }

  // Rule 3: Protect review state from direct edits
  if (toolName === "Bash") {
    if (isDirectReviewStateWriteCommand(bashCommand)) {
      deny("Direct writes to .winsmux/review-state.json are not allowed. Use review-approve or review-reset.");
    }
  }

  // Rule 4: review-approve may only run from a Reviewer pane
  if (toolName === "Bash") {
    if (isReviewApproveCommand(bashCommand) && normalizeAgentValue(process.env.WINSMUX_ROLE) !== "reviewer") {
      deny("review-approve can only be run from a Reviewer pane.");
    }
  }

  // Rule 5: No plaintext secrets in commands
  if (toolName === "Bash") {
    if (SECRET_PATTERN.test(bashCommand)) {
      deny("Use winsmux vault instead of plaintext secrets.");
    }
  }

  // Rule 6: Block writes that disable local hooks in settings.local.json
  if (toolName === "Bash") {
    if (isSettingsLocalHookMutation(bashCommand)) {
      deny("Hooks in .claude/settings.local.json cannot be disabled from Bash.");
    }
  }

  // Rule 7: No direct Codex dispatch outside winsmux send
  if (toolName === "Bash") {
    if (isDirectCodexDispatch(bashCommand)) {
      deny("Use winsmux send to dispatch Codex to panes");
    }
  }

  // Rule 8: Block shallow git clones (they break worktree creation)
  if (toolName === "Bash") {
    if (/git\s+clone\s+.*--depth/.test(bashCommand)) {
      deny("Shallow clones break git worktree. Use full clone (remove --depth).");
    }
  }

  // Rule 9: Block bare git rm (allow only git rm --cached)
  if (toolName === "Bash") {
    if (/git\s+rm\s/.test(bashCommand) && !/--cached/.test(bashCommand)) {
      deny("Use git rm --cached to untrack files. Bare git rm deletes local files.");
    }
  }

  // Rule 10: Block Commander from using write-capable Agent modes outside isolated worktrees
  if (toolName === "Agent") {
    const agentMode = normalizeAgentValue(toolInput.mode);
    const subagentType = normalizeAgentValue(toolInput.subagent_type);
    const isolation = normalizeAgentValue(toolInput.isolation);

    if (isolation !== "worktree" && agentMode !== "plan" && subagentType !== "explore" && isWriteCapableAgentMode(agentMode)) {
      deny("Commander cannot use write-capable Agent modes outside worktree isolation. Use plan mode, Explore subagents, or worktree isolation.");
    }
  }

  // Rule 11: REMOVED - winsmux verify not yet implemented.
  // Will be re-added when verify command exists. See #277.

  // Rule 12: Block review-gated commit/merge commands without valid Reviewer PASS for the current HEAD (#279)
  if (toolName === "Bash") {
    if (isReviewGatedCommand(bashCommand) && !/bump-version|chore:\s*bump/.test(bashCommand)) {
      const reviewStatePath = path.join(process.cwd(), ".winsmux", "review-state.json");
      const denyMessage = "Review required. Flow: 1) Reviewer runs winsmux review-request, 2) Reviewer reviews, 3) Reviewer runs winsmux review-approve from Reviewer pane.";
      try {
        const currentBranch = getCurrentBranch(process.cwd());
        const currentHeadSha = getCurrentHeadSha(process.cwd());
        const reviewState = JSON.parse(fs.readFileSync(reviewStatePath, "utf8"));
        if (!currentBranch || !hasValidReviewerPass(reviewState[currentBranch], currentHeadSha)) {
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

function isReviewApproveCommand(command) {
  return splitCommandSegments(command).some(isReviewApproveSegment);
}

function isReviewApproveSegment(segment) {
  const tokens = tokenizeCommandLine(segment);
  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if (isReadOnlySearchCommand(executable)) {
    return false;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? isReviewApproveCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const nestedCommand = getOptionValue(tokens, ["-command", "-c"]);
    if (nestedCommand) {
      return isReviewApproveCommand(nestedCommand);
    }

    const fileArgument = getOptionValue(tokens, ["-file"]);
    if (fileArgument && isWinsmuxCoreScript(fileArgument)) {
      return hasStandaloneCommandToken(tokens, "review-approve", tokens.indexOf(fileArgument) + 1);
    }

    const scriptIndex = tokens.findIndex((token) => isWinsmuxCoreScript(token));
    return scriptIndex >= 0 && hasStandaloneCommandToken(tokens, "review-approve", scriptIndex + 1);
  }

  if (isWinsmuxExecutable(executable)) {
    return hasStandaloneCommandToken(tokens, "review-approve", 1);
  }

  if (isWinsmuxCoreScript(tokens[0])) {
    return hasStandaloneCommandToken(tokens, "review-approve", 1);
  }

  return false;
}

function splitCommandSegments(command) {
  const segments = [];
  let current = "";
  let quote = "";

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];
    const nextChar = command[index + 1];

    if (quote) {
      if (char === quote && command[index - 1] !== "\\") {
        quote = "";
      }
      current += char;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      current += char;
      continue;
    }

    if (char === "\r" || char === "\n" || char === ";") {
      if (current.trim() !== "") {
        segments.push(current.trim());
      }
      current = "";
      continue;
    }

    if ((char === "&" && nextChar === "&") || (char === "|" && nextChar === "|")) {
      if (current.trim() !== "") {
        segments.push(current.trim());
      }
      current = "";
      index += 1;
      continue;
    }

    current += char;
  }

  if (current.trim() !== "") {
    segments.push(current.trim());
  }

  return segments;
}

function tokenizeCommandLine(command) {
  const tokens = [];
  let current = "";
  let quote = "";

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];

    if (quote) {
      if (char === quote && command[index - 1] !== "\\") {
        quote = "";
      } else {
        current += char;
      }
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      continue;
    }

    if (/\s/.test(char)) {
      if (current !== "") {
        tokens.push(current);
        current = "";
      }
      continue;
    }

    current += char;
  }

  if (current !== "") {
    tokens.push(current);
  }

  return tokens;
}

function getCmdShellArgument(tokens) {
  for (let index = 1; index < tokens.length; index += 1) {
    const token = normalizeAgentValue(tokens[index]);
    if (token === "/c" || token === "/k") {
      return tokens.slice(index + 1).join(" ");
    }
  }

  return "";
}

function getOptionValue(tokens, optionNames) {
  const normalizedOptionNames = optionNames.map((optionName) => optionName.toLowerCase());

  for (let index = 1; index < tokens.length; index += 1) {
    const token = tokens[index];
    const normalizedToken = normalizeAgentValue(token);
    const exactMatch = normalizedOptionNames.indexOf(normalizedToken);
    if (exactMatch >= 0) {
      return index + 1 < tokens.length ? tokens[index + 1] : "";
    }

    for (const optionName of normalizedOptionNames) {
      if (normalizedToken.startsWith(optionName + "=")) {
        return token.slice(optionName.length + 1);
      }
    }
  }

  return "";
}

function getExecutableBasename(token) {
  return path.posix.basename(stripOuterQuotes(normalizePathValue(token)));
}

function hasStandaloneCommandToken(tokens, expectedToken, startIndex) {
  for (let index = startIndex; index < tokens.length; index += 1) {
    if (normalizeAgentValue(stripOuterQuotes(tokens[index])) === expectedToken) {
      return true;
    }
  }

  return false;
}

function isPowerShellExecutable(executable) {
  return executable === "pwsh" || executable === "pwsh.exe" || executable === "powershell" || executable === "powershell.exe";
}

function isReadOnlySearchCommand(executable) {
  return executable === "rg" ||
    executable === "rg.exe" ||
    executable === "grep" ||
    executable === "grep.exe" ||
    executable === "cat" ||
    executable === "cat.exe" ||
    executable === "head" ||
    executable === "head.exe" ||
    executable === "tail" ||
    executable === "tail.exe" ||
    executable === "less" ||
    executable === "less.exe" ||
    executable === "find" ||
    executable === "find.exe" ||
    executable === "findstr" ||
    executable === "findstr.exe";
}

function isWinsmuxCoreScript(token) {
  const normalized = stripOuterQuotes(normalizePathValue(token));
  return normalized === "winsmux-core.ps1" || normalized.endsWith("/winsmux-core.ps1");
}

function isWinsmuxExecutable(executable) {
  return executable === "winsmux" || executable === "winsmux.cmd" || executable === "winsmux.ps1" || executable === "winsmux.exe";
}

function stripOuterQuotes(value) {
  return typeof value === "string" ? value.replace(/^['"]+|['"]+$/g, "") : "";
}

function isDirectReviewStateWriteCommand(command) {
  const normalized = normalizePathValue(command);
  return /(?:>|>>)\s*["']?[^"'|\r\n]*\.winsmux\/review-state\.json\b|(?:set-content|add-content|out-file|copy-item|move-item|remove-item|rename-item)\b[^|&\r\n]*\.winsmux\/review-state\.json\b|(?:echo|type)\b[^|&\r\n]*(?:>|>>)\s*["']?[^"'|\r\n]*\.winsmux\/review-state\.json\b/.test(normalized);
}

function normalizeAgentValue(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function normalizePathValue(value) {
  return typeof value === "string" ? value.replace(/\\/g, "/").trim().toLowerCase() : "";
}

function isProtectedReviewStatePath(filePath) {
  const normalized = normalizePathValue(filePath);
  return normalized === ".winsmux/review-state.json" || normalized.endsWith("/.winsmux/review-state.json");
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

function hasValidReviewerPass(reviewStateEntry, currentHeadSha) {
  if (!reviewStateEntry || reviewStateEntry.status !== "PASS") {
    return false;
  }

  const recordedHeadSha = getReviewStateHeadSha(reviewStateEntry);
  if (typeof recordedHeadSha !== "string" || recordedHeadSha.trim() !== currentHeadSha) {
    return false;
  }

  const reviewer = reviewStateEntry.reviewer;
  if (!reviewer || normalizeAgentValue(reviewer.role) !== "reviewer") {
    return false;
  }

  return typeof reviewer.pane_id === "string" && reviewer.pane_id.trim() !== "";
}

function getReviewStateHeadSha(reviewStateEntry) {
  if (typeof reviewStateEntry?.head_sha === "string" && reviewStateEntry.head_sha.trim() !== "") {
    return reviewStateEntry.head_sha;
  }

  if (typeof reviewStateEntry?.request?.head_sha === "string" && reviewStateEntry.request.head_sha.trim() !== "") {
    return reviewStateEntry.request.head_sha;
  }

  return "";
}

function getCurrentBranch(repoRoot) {
  const gitDir = resolveGitDir(repoRoot);
  const headPath = path.join(gitDir, "HEAD");
  const head = fs.readFileSync(headPath, "utf8").trim();
  const match = /^ref:\s+refs\/heads\/(.+)$/.exec(head);
  return match ? match[1] : "";
}

function getCurrentHeadSha(repoRoot) {
  return execFileSync("git", ["-C", repoRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
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
  getCmdShellArgument,
  getCurrentBranch,
  getCurrentHeadSha,
  getExecutableBasename,
  getOptionValue,
  getReviewStateHeadSha,
  hasStandaloneCommandToken,
  hasValidReviewerPass,
  isDirectCodexDispatch,
  isDirectReviewStateWriteCommand,
  isGhPrMergeCommand,
  isGitCommitCommand,
  isGitMergeCommand,
  isPowerShellExecutable,
  isProtectedReviewStatePath,
  isReadOnlySearchCommand,
  isReviewApproveCommand,
  isReviewApproveSegment,
  isReviewGatedCommand,
  isSettingsLocalHookMutation,
  isWinsmuxCoreScript,
  isWinsmuxExecutable,
  isWriteCapableAgentMode,
  normalizeAgentValue,
  normalizePathValue,
  resolveGitDir,
  splitCommandSegments,
  stripHeredocBodies,
  stripOuterQuotes,
  tokenizeCommandLine,
};
