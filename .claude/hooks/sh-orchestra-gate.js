// sh-orchestra-gate.js — PreToolUse hook
// Prevents Operator from writing code or bypassing winsmux CLI
"use strict";

const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEBUG_LOG_PATH = path.join(os.tmpdir(), "winsmux-sh-orchestra-gate-command.log");
const SECRET_PATTERN =
  /\b(?:gho_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b|(?:^|\s)(?:GITHUB_TOKEN|GH_TOKEN|API_KEY)\s*=/i;
const ORCHESTRA_SESSION_NAME = "winsmux-orchestra";
const STARTUP_GATE_DISABLED = normalizeAgentValue(process.env.WINSMUX_DISABLE_ORCHESTRA_STARTUP_GATE) === "1";

try {
  const input = fs.readFileSync(0, "utf8");
  const event = JSON.parse(input);
  const toolName = event.tool_name || "";
  const toolInput = event.tool_input || {};
  const rawCommand = typeof toolInput.command === "string" ? toolInput.command : "";
  const bashCommand = toolName === "Bash" ? stripHeredocBodies(rawCommand) : "";
  const currentRole = normalizeAgentValue(process.env.WINSMUX_ROLE);

  logCommand(toolName, rawCommand);

  // Rule 1: Operator cannot write/edit code files
  if (isFileMutationTool(toolName)) {
    const filePath = toolInput.file_path || toolInput.file || "";
    if (isProtectedReviewStatePath(filePath)) {
      deny("Direct writes to .winsmux/review-state.json are not allowed. Use review-approve, review-fail, or review-reset.");
    }

    if (currentRole !== "builder" &&
        currentRole !== "worker" &&
        /\.(ps1|js|rs|ts|py)$/i.test(filePath)) {
      deny("Operator cannot write code files. Delegate to Builder via winsmux send.");
    }
  }

  // Rule 2: No direct winsmux send-keys (use winsmux send)
  if (toolName === "Bash") {
    if (/winsmux\s+send-keys/.test(bashCommand) && !/winsmux-core/.test(bashCommand)) {
      deny("Use winsmux send instead of direct winsmux send-keys.");
    }
  }

  // Rule 2a: When orchestra is not ready, block PR/merge progression until startup succeeds (#424).
  if (toolName === "Bash") {
    if (!STARTUP_GATE_DISABLED && currentRole !== "builder" && currentRole !== "worker") {
      const orchestraProbeAvailable = hasOrchestraProbeInputs(process.cwd());
      const orchestraState = getOrchestraRestoreGateState(process.cwd());
      const shouldEnforceStartupGate =
        orchestraState.state === "needs-startup" ||
        (orchestraProbeAvailable && orchestraState.state === "unknown" && isUnknownStateFailClosedCommand(bashCommand));
      if (shouldEnforceStartupGate &&
          isBlockedUntilOrchestraReady(bashCommand) &&
          !isAllowedOrchestraRecoveryCommand(bashCommand)) {
        deny(
          `Orchestra is ${orchestraState.state} (${orchestraState.current}/${orchestraState.expected} panes, ${orchestraState.reason}). ` +
          "Run winsmux-core/scripts/orchestra-start.ps1 or pane diagnostics first. PR/merge progression commands are blocked until worker panes are ready.",
        );
      }
    }
  }

  // Rule 2c: Operator-side startup/status diagnosis must not use legacy psmux probes (#423).
  if (toolName === "Bash") {
    if (currentRole !== "builder" && currentRole !== "worker" && isLegacyOperatorProbeCommand(bashCommand)) {
      deny("Operator startup/status checks must use winsmux orchestra-smoke --json or winsmux list-sessions, not legacy psmux probes.");
    }
  }

  // Rule 2b: Operator shell wrappers must not write code-bearing files outside managed worker panes
  if (toolName === "Bash") {
    if (currentRole !== "builder" && currentRole !== "worker" && isDirectCodeWriteBypassCommand(bashCommand)) {
      deny("Operator shell write bypass blocked. Delegate implementation to managed worker panes.");
    }
  }

  // Rule 3: Protect review state from direct edits
  if (toolName === "Bash") {
    if (isDirectReviewStateWriteCommand(bashCommand)) {
      deny("Direct writes to .winsmux/review-state.json are not allowed. Use review-approve, review-fail, or review-reset.");
    }
  }

  // Rule 4: review-approve and review-fail may only run from a review-capable pane
  if (toolName === "Bash") {
    if (isReviewerOnlyCommand(bashCommand) && currentRole !== "reviewer" && currentRole !== "worker") {
      deny("review-approve and review-fail can only be run from a review-capable pane.");
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

  // Rule 10: Operator-side Agent use is limited to planning and startup diagnosis.
  if (toolName === "Agent") {
    const agentMode = normalizeAgentValue(toolInput.mode);
    const subagentType = normalizeAgentValue(toolInput.subagent_type);
    const isAllowedAgentUse =
      agentMode === "plan" ||
      (subagentType === "explore" && isStartupDiagnosisSubagent(toolInput));
    if (!isAllowedAgentUse) {
      deny("Operator delegated execution bypass blocked. Delegate task execution and review to managed worker panes via winsmux dispatch-task or dispatch-review. Allowed: plan mode, startup-diagnosis Explore subagents.");
    }
  }

  // Rule 11: REMOVED - winsmux verify not yet implemented.
  // Will be re-added when verify command exists. See #277.

  // Rule 12: worker-pane isolation — block writes outside assigned worktree (#385)
  const currentRoleForIsolation = currentRole;
  if (currentRoleForIsolation === "builder" || currentRoleForIsolation === "worker") {
    const worktreePath = process.env.WINSMUX_ASSIGNED_WORKTREE ||
      process.env.WINSMUX_BUILDER_WORKTREE ||
      "";
    const shellWriteTargets = toolName === "Bash" ? getShellWriteTargets(bashCommand) : [];
    if (toolName === "Bash" && hasWriteCapableInterpreterHeredoc(rawCommand)) {
      deny("Worker isolation: write-capable interpreter heredocs are not allowed from worker panes.");
    }

    if (!worktreePath) {
      if (isFileMutationTool(toolName) || shellWriteTargets.length > 0) {
        deny("Worker isolation: assigned worktree is required before file mutations are allowed.");
      }
    } else {
      if (isFileMutationTool(toolName)) {
        const filePath = toolInput.file_path || toolInput.file || "";
        if (filePath && !isPathInsideOrSame(filePath, worktreePath)) {
          deny(`Worker isolation: writes must target assigned worktree ${worktreePath}, not ${toolInput.file_path || toolInput.file}`);
        }
      }

      if (toolName === "Bash") {
        const unresolvedTarget = shellWriteTargets.find(isUnresolvedShellTarget);
        if (unresolvedTarget) {
          deny(`Worker isolation: unresolved shell write target is not allowed: ${unresolvedTarget}`);
        }

        if (hasShellCwdChangeCommand(bashCommand) && shellWriteTargets.some(isRelativeShellTarget)) {
          deny("Worker isolation: relative shell write targets are not allowed after changing the current directory.");
        }

        const outsideTarget = shellWriteTargets.find((target) => !isPathInsideOrSame(resolveShellTargetPath(target), worktreePath));
        if (outsideTarget) {
          deny(`Worker isolation: shell writes must target assigned worktree ${worktreePath}, not ${outsideTarget}`);
        }
      }
    }
  }

  // Rule 12a: workers may edit and test, but repo-level Git writes are Operator-only (#570)
  if (toolName === "Bash" &&
      (currentRoleForIsolation === "builder" || currentRoleForIsolation === "worker") &&
      isOperatorOnlyGitLifecycleCommand(bashCommand)) {
    deny("Worker-pane Git lifecycle blocked. Keep editing and testing in the assigned worktree; run git add, git commit, git push, and PR merge from the Operator shell.");
  }

  // Rule 13: Block review-gated commit/merge commands without valid Reviewer PASS for the current HEAD (#279)
  if (toolName === "Bash") {
    if (isReviewGatedCommand(bashCommand) && !/bump-version|chore:\s*bump/.test(bashCommand)) {
      const reviewStatePath = path.join(process.cwd(), ".winsmux", "review-state.json");
      const denyMessage = "Review required. Flow: 1) a review-capable pane runs winsmux review-request, 2) that pane reviews, 3) it runs winsmux review-approve or winsmux review-fail.";
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
  process.stderr.write(`Hook parse error: ${e.message}\n`);
  process.exit(2);
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

function isStartupDiagnosisSubagent(toolInput) {
  const fragments = [];
  const pushText = (value) => {
    if (typeof value === "string" && value.trim().length > 0) {
      fragments.push(value.trim().toLowerCase());
    }
  };

  pushText(toolInput.prompt);
  pushText(toolInput.description);
  if (Array.isArray(toolInput.items)) {
    for (const item of toolInput.items) {
      if (!item || typeof item !== "object") {
        continue;
      }
      pushText(item.text);
      pushText(item.name);
      pushText(item.path);
    }
  }

  const haystack = fragments.join(" ");
  if (!haystack) {
    return false;
  }

  const keywords = [
    "orchestra",
    "startup",
    "start-up",
    "smoke",
    "attach",
    "lock",
    "locked",
    "session",
    "pane",
    "worker pane",
    "manifest",
    "needs-startup",
    "ready-with-ui-warning",
    "blocked",
    "起動",
    "セッション",
    "ペイン",
    "ロック",
    "診断",
    "復旧",
    "復元",
  ];

  return keywords.some((keyword) => haystack.includes(keyword));
}

function getOrchestraRestoreGateState(cwd) {
  try {
    const script = `
$ErrorActionPreference = 'Stop'
. '${toPwshLiteral(path.join(cwd, "winsmux-core", "scripts", "settings.ps1"))}'
$root = '${toPwshLiteral(cwd)}'
$settings = Get-BridgeSettings -RootPath $root
$workerCount = [int]$settings.worker_count
$agentSlots = @()
if ($settings -is [System.Collections.IDictionary]) {
  if ($settings.Contains('agent_slots')) { $agentSlots = @($settings['agent_slots']) }
} elseif ($null -ne $settings -and $null -ne $settings.PSObject -and ($settings.PSObject.Properties.Name -contains 'agent_slots')) {
  $agentSlots = @($settings.agent_slots)
}
if ($agentSlots.Count -gt 0) { $workerCount = $agentSlots.Count }
$expected = $workerCount + $(if ([bool]$settings.external_operator) { 0 } else { 1 })
$winsmuxBin = $null
foreach ($candidate in @('winsmux','pmux','tmux','psmux')) {
  if (Get-Command $candidate -ErrorAction SilentlyContinue) { $winsmuxBin = $candidate; break }
}
if (-not $winsmuxBin) {
  @{ state = 'unknown'; expected = $expected; current = 0; reason = 'winsmux_bin_missing' } | ConvertTo-Json -Compress
  exit 0
}
$session = '${ORCHESTRA_SESSION_NAME}'
& $winsmuxBin has-session -t $session *> $null
if ($LASTEXITCODE -ne 0) {
  @{ state = 'needs-startup'; expected = $expected; current = 0; reason = 'session_missing' } | ConvertTo-Json -Compress
  exit 0
}
$paneIds = & $winsmuxBin list-panes -t $session -F '#{pane_id}' 2>$null
$current = @($paneIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
$state = if ($current -lt $expected) { 'needs-startup' } else { 'ready' }
@{ state = $state; expected = $expected; current = $current; reason = $(if ($state -eq 'ready') { 'ok' } else { 'pane_count_mismatch' }) } | ConvertTo-Json -Compress
`;
    const output = execFileSync("pwsh", ["-NoProfile", "-Command", script], {
      cwd,
      encoding: "utf8",
      timeout: 10000,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const parsed = JSON.parse(output);
    return {
      state: parsed.state || "unknown",
      expected: Number(parsed.expected || 0),
      current: Number(parsed.current || 0),
      reason: parsed.reason || "unknown",
    };
  } catch {
    return {
      state: "unknown",
      expected: 0,
      current: 0,
      reason: "state_probe_failed",
    };
  }
}

function hasOrchestraProbeInputs(cwd) {
  try {
    return fs.existsSync(path.join(cwd, "winsmux-core", "scripts", "settings.ps1"));
  } catch {
    return false;
  }
}

function isAllowedOrchestraRecoveryCommand(command) {
  const segments = splitCommandSegments(command);
  if (segments.length === 0) {
    return true;
  }

  return segments.every((segment) => isAllowedOrchestraRecoverySegment(segment));
}

function isAllowedOrchestraRecoverySegment(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const tokens = tokenizeCommandLine(normalizedSegment);
  if (tokens.length === 0) {
    return true;
  }

  const executable = getExecutableBasename(tokens[0]);
  if (isReadOnlySearchCommand(executable) || isReadOnlyPowerShellDiagnostic(executable, normalizedSegment)) {
    return true;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? isAllowedOrchestraRecoveryCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const commandValue = getOptionRemainderValue(tokens, ["-command", "-c"]);
    if (commandValue) {
      return isAllowedOrchestraRecoveryCommand(commandValue);
    }

    const fileArgument = getOptionValue(tokens, ["-file"]);
    if (fileArgument) {
      if (isOrchestraStartScript(fileArgument)) {
        return true;
      }
      if (isWinsmuxCoreScript(fileArgument)) {
        return hasAllowedWinsmuxDiagnosticCommand(tokens, tokens.indexOf(fileArgument) + 1);
      }
      return false;
    }

    const scriptIndex = tokens.findIndex((token) => isWinsmuxCoreScript(token));
    if (scriptIndex >= 0) {
      if (isOrchestraStartScript(tokens[scriptIndex])) {
        return true;
      }
      return hasAllowedWinsmuxDiagnosticCommand(tokens, scriptIndex + 1);
    }

    return false;
  }

  if (isWinsmuxExecutable(executable)) {
    return hasAllowedWinsmuxDiagnosticCommand(tokens, 1);
  }

  if (isWinsmuxCoreScript(tokens[0])) {
    if (isOrchestraStartScript(tokens[0])) {
      return true;
    }
    return hasAllowedWinsmuxDiagnosticCommand(tokens, 1);
  }

  return false;
}

function isBlockedUntilOrchestraReady(command) {
  const normalized = normalizePathValue(command);
  return isReviewGatedCommand(command) ||
         /\bgh\b(?:\s+(?:-[a-z]|--[a-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+pr\s+create\b/i.test(command) ||
         /\bgh\b(?:\s+(?:-[a-z]|--[a-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+pr\s+ready\b/i.test(command) ||
         /\/sync-roadmap\.ps1\b/i.test(normalized);
}

function isLegacyOperatorProbeCommand(command) {
  const segments = splitCommandSegments(command);
  if (segments.length === 0) {
    return false;
  }

  return segments.some((segment) => isLegacyOperatorProbeSegment(segment));
}

function isLegacyOperatorProbeSegment(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  if (/\bget-process\s+psmux-server\b/i.test(normalizedSegment)) {
    return true;
  }

  const tokens = tokenizeCommandLine(normalizedSegment);
  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if (["psmux", "psmux.exe"].includes(executable)) {
    return true;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? isLegacyOperatorProbeCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const commandValue = getOptionRemainderValue(tokens, ["-command", "-c"]);
    return commandValue ? isLegacyOperatorProbeCommand(commandValue) : false;
  }

  return false;
}

function isUnknownStateFailClosedCommand(command) {
  return /\bgh\b(?:\s+(?:-[a-z]|--[a-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+pr\s+(?:merge|create|ready)\b/i.test(command);
}

function unwrapPowerShellCommandWrapper(segment) {
  let current = typeof segment === "string" ? segment.trim() : "";

  while (true) {
    const wrappedWithCallOperatorCommand = /^&\s+([^{][\s\S]*)$/u.exec(current);
    if (wrappedWithCallOperatorCommand) {
      current = wrappedWithCallOperatorCommand[1].trim();
      continue;
    }

    const wrappedWithCallOperator = /^&\s*\{([\s\S]*)\}$/u.exec(current);
    if (wrappedWithCallOperator) {
      current = wrappedWithCallOperator[1].trim();
      continue;
    }

    const wrappedWithScriptBlock = /^\{([\s\S]*)\}$/u.exec(current);
    if (wrappedWithScriptBlock) {
      current = wrappedWithScriptBlock[1].trim();
      continue;
    }

    break;
  }

  return current;
}

function hasAllowedWinsmuxDiagnosticCommand(tokens, startIndex) {
  return hasStandaloneCommandToken(tokens, "has-session", startIndex) ||
         hasStandaloneCommandToken(tokens, "list-panes", startIndex) ||
         hasStandaloneCommandToken(tokens, "capture-pane", startIndex) ||
         hasStandaloneCommandToken(tokens, "display-message", startIndex) ||
         hasStandaloneCommandToken(tokens, "show-options", startIndex);
}

function isReadOnlyPowerShellDiagnostic(executable, segment) {
  const normalizedExecutable = normalizeAgentValue(executable);
  if (![
    "get-content",
    "test-path",
    "get-childitem",
    "get-item",
    "select-string",
    "write-host",
    "write-output",
    "echo",
    "dir",
    "ls",
    "type",
  ].includes(normalizedExecutable)) {
    return false;
  }

  return !/(?:>|>>|\bset-content\b|\badd-content\b|\bout-file\b|\bcopy-item\b|\bmove-item\b|\brename-item\b|\bremove-item\b|\bnew-item\b|\bni\b)/i.test(segment);
}

function isOrchestraStartScript(value) {
  if (!value) {
    return false;
  }
  const normalized = value.replace(/\\/g, "/").toLowerCase();
  return normalized.endsWith("/winsmux-core/scripts/orchestra-start.ps1") ||
         normalized === "winsmux-core/scripts/orchestra-start.ps1";
}

function toPwshLiteral(value) {
  return String(value).replace(/'/g, "''");
}

function isGitCommitCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+commit\b/.test(command);
}

function isGitAddCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+add\b/.test(command);
}

function isGitMergeCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+merge\b/.test(command);
}

function isGitPushCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+push\b/.test(command);
}

function isGitRebaseCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+rebase\b/.test(command);
}

function isGitResetCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+reset\b/.test(command);
}

function isGitCleanCommand(command) {
  return /\bgit\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+clean\b/.test(command);
}

function isGhPrMergeCommand(command) {
  return /\bgh\b(?:\s+(?:-[A-Za-z]|--[A-Za-z][\w-]*)(?:[=\s]+(?:"[^"]*"|'[^']*'|[^\s]+))?)*\s+pr\s+merge\b/.test(command);
}

function isOperatorOnlyGitLifecycleCommand(command) {
  if (hasPowerShellGitAliasLifecycleCommand(command, false)) {
    return true;
  }

  if (hasPowerShellScriptBlockGitLifecycleCommand(command)) {
    return true;
  }

  if (hasPowerShellDynamicCallLifecycleCommand(command)) {
    return true;
  }

  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some(isOperatorOnlyGitLifecycleSegment));
}

function hasPowerShellScriptBlockGitLifecycleCommand(command) {
  const source = String(command || "");
  const scriptBlockPattern = /\{([^{}]*\b(?:git|gh)\b[^{}]*)\}/giu;
  for (const match of source.matchAll(scriptBlockPattern)) {
    const body = (match[1] || "").trim();
    if (body && body !== source.trim() && isOperatorOnlyGitLifecycleCommand(body)) {
      return true;
    }
  }

  return false;
}

function isOperatorOnlyGitLifecycleSegment(segment) {
  if (hasPowerShellDynamicCallLifecycleCommand(segment)) {
    return true;
  }

  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedSegment));
  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if (isReadOnlySearchCommand(executable)) {
    return false;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? isOperatorOnlyGitLifecycleCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    if (hasPowerShellEncodedCommandOption(tokens)) {
      return true;
    }

    const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
    if (nestedCommand) {
      return isOperatorOnlyGitLifecycleCommand(nestedCommand);
    }
  }

  if (isShellCommandExecutable(executable)) {
    const nestedCommand = getShellCommandArgument(tokens);
    if (nestedCommand) {
      return isOperatorOnlyGitLifecycleCommand(nestedCommand);
    }
  }

  if (isPowerShellStartProcessExecutable(executable)) {
    if (hasPowerShellStartProcessLifecycleHint(normalizedSegment)) {
      return true;
    }
    const nestedCommand = getPowerShellStartProcessCommand(tokens);
    return nestedCommand ? isOperatorOnlyGitLifecycleCommand(nestedCommand) : false;
  }

  if (hasPowerShellDynamicGitLifecycleCommand(normalizedSegment, tokens)) {
    return true;
  }

  if (hasInterpreterGitLifecycleCommand(normalizedSegment, tokens)) {
    return true;
  }

  if (executable === "git" || executable === "git.exe") {
    const gitSubcommandIndex = findGitSubcommandIndex(tokens);
    if (gitSubcommandIndex < 0) {
      return false;
    }

    const gitSubcommand = getGitSubcommandName(tokens, gitSubcommandIndex);
    if (gitSubcommand === "branch") {
      return !isReadOnlyGitBranchCommand(tokens, gitSubcommandIndex);
    }

    if (gitSubcommand === "tag") {
      return !isReadOnlyGitTagCommand(tokens, gitSubcommandIndex);
    }

    if (gitSubcommand === "worktree") {
      return !isReadOnlyGitWorktreeCommand(tokens, gitSubcommandIndex);
    }

    return !isReadOnlyGitSubcommand(gitSubcommand, tokens, gitSubcommandIndex);
  }

  if (executable === "gh" || executable === "gh.exe") {
    return tokens.some((token, index) =>
      normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
      tokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
      isGhApiMergeCommand(tokens) ||
      isGhApiRefWriteCommand(tokens);
  }

  return false;
}

function hasPowerShellDynamicGitLifecycleCommand(segment, tokens) {
  const executable = normalizeExecutableName(tokens[0] || "");
  if (executable === "invoke-expression" || executable === "iex") {
    const nestedCommand = stripOuterQuotes(tokens.slice(1).join(" "));
    if (!nestedCommand || /^\$/u.test(nestedCommand)) {
      return true;
    }
    return isOperatorOnlyGitLifecycleCommand(nestedCommand);
  }

  for (const nestedCommand of getPowerShellScriptBlockCreateCommands(segment)) {
    if (isUnparsedPowerShellDynamicCommand(nestedCommand) || isOperatorOnlyGitLifecycleCommand(nestedCommand)) {
      return true;
    }
  }

  return false;
}

function getPowerShellScriptBlockCreateCommands(segment) {
  const commands = [];
  const assignments = getPowerShellStringAssignments(segment);
  const pattern = /\[\s*scriptblock\s*\]\s*::\s*create\s*\(\s*(?:"([^"]*)"|'([^']*)'|(\$[A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z_][A-Za-z0-9_]*)?))\s*\)/giu;
  for (const match of String(segment || "").matchAll(pattern)) {
    const variableName = normalizePowerShellVariableName(match[3] || "");
    if (variableName) {
      commands.push(assignments.get(variableName) || "$unparsed-powershell-dynamic");
      continue;
    }
    if (match[3]) {
      commands.push("$unparsed-powershell-dynamic");
      continue;
    }
    commands.push(match[1] || match[2] || "");
  }
  return commands;
}

function getPowerShellStringAssignments(segment) {
  const assignments = new Map();
  const pattern = /\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/gu;
  for (const match of String(segment || "").matchAll(pattern)) {
    assignments.set(normalizePowerShellVariableName(match[1] || ""), match[2] || match[3] || "");
  }
  return assignments;
}

function normalizePowerShellVariableName(value) {
  const normalized = String(value || "").trim().replace(/^\$/u, "").toLowerCase();
  return /^[a-z_][a-z0-9_]*$/u.test(normalized) ? normalized : "";
}

function isUnparsedPowerShellDynamicCommand(value) {
  return value === "$unparsed-powershell-dynamic";
}

function hasInterpreterGitLifecycleCommand(segment, tokens) {
  const interpreterKind = getShellInterpreterKind(tokens);
  if (!interpreterKind) {
    return false;
  }

  return interpreterKind === "node"
    ? hasNodeGitLifecycleCommand(segment)
    : hasPythonGitLifecycleCommand(segment);
}

function hasPythonGitLifecycleCommand(segment) {
  const source = String(segment || "");
  const literalCommandPatterns = [
    /\b(?:subprocess\.(?:run|call|check_call|check_output|popen)|os\.system)\s*\(\s*(?:"([^"]*\b(?:git|gh)\b[^"]*)"|'([^']*\b(?:git|gh)\b[^']*)')/giu,
  ];
  for (const pattern of literalCommandPatterns) {
    for (const match of source.matchAll(pattern)) {
      const command = match[1] || match[2] || "";
      if (command && isOperatorOnlyGitLifecycleCommand(command)) {
        return true;
      }
    }
  }

  return hasArrayGitLifecycleCommand(source) || hasDynamicInterpreterLifecycleHint(source);
}

function hasNodeGitLifecycleCommand(segment) {
  const source = String(segment || "");
  const literalCommandPatterns = [
    /\b(?:execsync|exec)\s*\(\s*(?:"([^"]*\b(?:git|gh)\b[^"]*)"|'([^']*\b(?:git|gh)\b[^']*)')/giu,
  ];
  for (const pattern of literalCommandPatterns) {
    for (const match of source.matchAll(pattern)) {
      const command = match[1] || match[2] || "";
      if (command && isOperatorOnlyGitLifecycleCommand(command)) {
        return true;
      }
    }
  }

  const fileCommandPattern = /\b(?:execfilesync|execfile|spawnsync|spawn)\s*\(\s*(?:"(git|gh)(?:\.exe)?"|'(git|gh)(?:\.exe)?')\s*,\s*\[([^\]]*)\]/giu;
  for (const match of source.matchAll(fileCommandPattern)) {
    const tool = match[1] || match[2] || "";
    const args = extractQuotedArguments(match[3] || "");
    if (tool && isOperatorOnlyGitLifecycleCommand([tool, ...args].join(" "))) {
      return true;
    }
  }

  return hasDynamicInterpreterLifecycleHint(source);
}

function hasDynamicInterpreterLifecycleHint(source) {
  const text = String(source || "").toLowerCase();
  const subprocessAliases = [...text.matchAll(/\bimport\s+subprocess\s+as\s+([a-z_][a-z0-9_]*)/gu)]
    .map((match) => match[1])
    .filter(Boolean);
  const subprocessCallPattern = subprocessAliases.length > 0
    ? new RegExp(`\\b(?:subprocess|${subprocessAliases.join("|")})\\.(?:run|call|check_call|check_output|popen)\\b|\\bos\\.system\\b|\\b(?:execfilesync|execfile|spawnsync|spawn|execsync|exec)\\b`, "u")
    : /\b(?:subprocess\.(?:run|call|check_call|check_output|popen)|os\.system|execfilesync|execfile|spawnsync|spawn|execsync|exec)\b/u;
  if (!subprocessCallPattern.test(text)) {
    return false;
  }

  return /\b(?:add|commit|merge|push|rebase|reset|restore|rm|checkout-index|update-index|notes|branch|tag|worktree|config)\b/u.test(text);
}

function hasPowerShellDynamicCallLifecycleCommand(segment) {
  const source = String(segment || "");
  if (!/(?:^|[\s;|])&\s*(?:\(|\$|\$\{)/u.test(source)) {
    return false;
  }

  return hasGitLifecycleHint(source);
}

function hasPowerShellStartProcessLifecycleHint(segment) {
  const source = String(segment || "");
  if (!/^\s*start-process\b/iu.test(source)) {
    return false;
  }

  return hasGitLifecycleHint(source) &&
    /(?:\(\s*get-command\b|\$env:comspec\b|\bpwsh\b|\bpowershell\b|\bcmd\b)/iu.test(source);
}

function hasGitLifecycleHint(source) {
  const normalized = normalizeAgentValue(String(source || ""));
  if (!/\b(?:add|commit|merge|push|rebase|reset|restore|rm|checkout-index|update-index|notes|branch|tag|worktree|config)\b/u.test(normalized)) {
    return false;
  }

  return /\b(?:git|gh)\b/u.test(normalized) ||
    /['"]g['"]\s*\+\s*['"]it['"]/u.test(normalized) ||
    /\bget-command\s+(?:git|gh)\b/u.test(normalized) ||
    /\$env:comspec\b/u.test(normalized) ||
    /(?:^|[\s;|])&\s*(?:\(|\$|\$\{)/u.test(normalized);
}

function hasArrayGitLifecycleCommand(source) {
  const arrayPattern = /\[\s*(?:"(git|gh)(?:\.exe)?"|'(git|gh)(?:\.exe)?')\s*,([^\]]*)\]/giu;
  for (const match of String(source || "").matchAll(arrayPattern)) {
    const tool = match[1] || match[2] || "";
    const args = extractQuotedArguments(match[3] || "");
    if (tool && isOperatorOnlyGitLifecycleCommand([tool, ...args].join(" "))) {
      return true;
    }
  }
  return false;
}

function extractQuotedArguments(value) {
  const args = [];
  const pattern = /"([^"]*)"|'([^']*)'/gu;
  for (const match of String(value || "").matchAll(pattern)) {
    args.push(match[1] || match[2] || "");
  }
  return args;
}

function isGhApiMergeCommand(tokens) {
  const normalizedTokens = tokens.map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  const apiIndex = normalizedTokens.indexOf("api");
  if (apiIndex < 0) {
    return false;
  }

  return normalizedTokens.slice(apiIndex + 1).some((token) =>
    /(?:^|\/)repos\/[^/]+\/[^/]+\/pulls\/\d+\/merge(?:$|[?#])/u.test(token) ||
    /(?:^|\/)pulls\/\d+\/merge(?:$|[?#])/u.test(token) ||
    token.includes("mergepullrequest"));
}

function isGhApiRefWriteCommand(tokens) {
  const normalizedTokens = tokens.map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  const apiIndex = normalizedTokens.indexOf("api");
  if (apiIndex < 0) {
    return false;
  }

  const args = normalizedTokens.slice(apiIndex + 1);
  if (!args.some(isGhApiGitRefEndpoint)) {
    return false;
  }

  return hasGhApiWriteMethod(args) || hasGhApiWriteField(args);
}

function isGhApiGitRefEndpoint(token) {
  return /(?:^|\/)repos\/[^/]+\/[^/]+\/git\/refs(?:\/|$|[?#])/u.test(token) ||
         /(?:^|\/)repos\/[^/]+\/[^/]+\/git\/ref(?:\/|$|[?#])/u.test(token);
}

function hasGhApiWriteMethod(args) {
  const writeMethods = new Set(["post", "put", "patch", "delete"]);
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if ((arg === "-x" || arg === "--method") && index + 1 < args.length) {
      if (writeMethods.has(args[index + 1])) {
        return true;
      }
      index += 1;
      continue;
    }

    const inlineMethod = /^(?:-x=?|--method=)(post|put|patch|delete)$/u.exec(arg);
    if (inlineMethod) {
      return true;
    }
  }

  return false;
}

function hasGhApiWriteField(args) {
  return args.some((arg) =>
    arg === "-f" ||
    arg === "-F" ||
    arg === "--field" ||
    arg === "--raw-field" ||
    arg === "--input" ||
    /^-(?:f|F).+/u.test(arg) ||
    /^--(?:field|raw-field|input)=/u.test(arg));
}

function isReadOnlyGitSubcommand(gitSubcommand, tokens, subcommandIndex) {
  if ([
    "diff",
    "grep",
    "log",
    "ls-files",
    "merge-base",
    "rev-list",
    "rev-parse",
    "show",
    "status",
  ].includes(gitSubcommand)) {
    return !hasGitWriteOption(tokens, subcommandIndex);
  }

  if (gitSubcommand === "config") {
    return isReadOnlyGitConfigCommand(tokens, subcommandIndex);
  }

  if (gitSubcommand === "remote") {
    return isReadOnlyGitRemoteCommand(tokens, subcommandIndex);
  }

  return false;
}

function hasGitWriteOption(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--output") {
      return true;
    }

    if (arg.startsWith("--output=")) {
      return true;
    }
  }

  return false;
}

function isReadOnlyGitConfigCommand(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  if (args.length === 0) {
    return false;
  }

  const readOptions = new Set([
    "--get",
    "--get-all",
    "--get-regexp",
    "--list",
    "--show-origin",
    "--show-scope",
    "-l",
  ]);
  const bareArgs = args.filter((arg) => !arg.startsWith("-"));
  const hasWriteFlag = args.some((arg) =>
    arg === "--add" ||
    arg === "--replace-all" ||
    arg === "--unset" ||
    arg === "--unset-all" ||
    arg === "--rename-section" ||
    arg === "--remove-section" ||
    arg === "--edit" ||
    arg === "-e");
  if (hasWriteFlag || bareArgs.length > 1 || bareArgs.some((arg) => arg.includes("="))) {
    return false;
  }

  return args.every((arg) =>
    readOptions.has(arg) ||
    arg.startsWith("--get-regexp=") ||
    (!arg.startsWith("-") && !arg.includes("=")));
}

function isReadOnlyGitRemoteCommand(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  if (args.length === 0) {
    return true;
  }

  if (args.every((arg) => arg === "-v" || arg === "--verbose")) {
    return true;
  }

  const subcommand = args.find((arg) => !arg.startsWith("-")) || "";
  return subcommand === "-v" || subcommand === "show" || subcommand === "get-url";
}

function findGitSubcommandIndex(tokens) {
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (!normalizedToken) {
      continue;
    }

    if (normalizedToken === "-c" ||
        normalizedToken === "-C" ||
        normalizedToken === "--git-dir" ||
        normalizedToken === "--work-tree" ||
        normalizedToken === "--namespace") {
      index += 1;
      continue;
    }

    if (normalizedToken.startsWith("-c=") ||
        normalizedToken.startsWith("--git-dir=") ||
        normalizedToken.startsWith("--work-tree=") ||
        normalizedToken.startsWith("--namespace=")) {
      continue;
    }

    if (normalizedToken.startsWith("-")) {
      continue;
    }

    return index;
  }

  return -1;
}

function getGitSubcommandName(tokens, subcommandIndex) {
  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex]));
  const aliasSubcommand = getGitAliasSubcommandName(tokens, subcommandIndex, subcommand);
  return aliasSubcommand || subcommand;
}

function getGitAliasSubcommandName(tokens, subcommandIndex, subcommand) {
  for (let index = 1; index < subcommandIndex; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    let configValue = "";

    if (normalizedToken === "-c" && index + 1 < subcommandIndex) {
      index += 1;
      configValue = stripOuterQuotes(tokens[index]);
    } else if (normalizedToken.startsWith("-c=")) {
      configValue = token.slice(3);
    }

    if (!configValue) {
      continue;
    }

    const aliasMatch = configValue.match(/^alias\.([A-Za-z0-9_.-]+)=(.+)$/iu);
    if (!aliasMatch || normalizeAgentValue(aliasMatch[1]) !== subcommand) {
      continue;
    }

    const aliasTokens = tokenizeCommandLine(aliasMatch[2]);
    if (aliasTokens.length === 0) {
      continue;
    }

    const delegatedSubcommand = getGitShellAliasDelegatedSubcommand(aliasTokens);
    if (delegatedSubcommand) {
      return delegatedSubcommand;
    }

    return normalizeAgentValue(stripOuterQuotes(aliasTokens[0]));
  }

  return "";
}

function getGitShellAliasDelegatedSubcommand(aliasTokens) {
  const normalizedTokens = aliasTokens.map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  const gitLikeIndex = normalizedTokens.findIndex((token) => token === "git" || token === "!git");
  if (gitLikeIndex < 0) {
    return "";
  }

  for (const token of normalizedTokens.slice(gitLikeIndex + 1)) {
    if (token.startsWith("-")) {
      continue;
    }

    if (isGitLifecycleSubcommandName(token)) {
      return token;
    }
  }

  return normalizedTokens[gitLikeIndex + 1] || "";
}

function isGitLifecycleSubcommandName(value) {
  return [
    "add",
    "commit",
    "merge",
    "push",
    "rebase",
    "reset",
    "restore",
    "rm",
    "checkout-index",
    "update-index",
    "notes",
    "branch",
    "tag",
    "worktree",
    "config",
  ].includes(normalizeAgentValue(value));
}

function hasPowerShellGitAliasLifecycleCommand(command, reviewOnly) {
  const aliases = new Map();
  const ghAliases = new Map();

  for (const segment of splitCommandSegments(command)) {
    for (const pipelineStage of splitCommandPipelineStages(segment)) {
      const normalizedSegment = unwrapPowerShellCommandWrapper(pipelineStage);
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedSegment));
      if (tokens.length === 0) {
        continue;
      }

      const executable = normalizeAgentValue(getExecutableBasename(tokens[0]));
      if (executable === "set-alias" || executable === "sal" || executable === "new-alias" || executable === "nal") {
        const { aliasName, aliasTarget } = getSetAliasDefinition(tokens);
        if (aliasName && (aliasTarget === "git" || aliasTarget === "git.exe")) {
          aliases.set(aliasName, []);
        }
        if (aliasName && (aliasTarget === "gh" || aliasTarget === "gh.exe")) {
          ghAliases.set(aliasName, []);
        }
        continue;
      }

      if (executable === "alias") {
        const aliasDefinition = getShellAliasDefinition(tokens);
        if (aliasDefinition.aliasName && aliasDefinition.aliasTarget === "git") {
          aliases.set(aliasDefinition.aliasName, aliasDefinition.aliasArgs);
        }
        if (aliasDefinition.aliasName && aliasDefinition.aliasTarget === "gh") {
          ghAliases.set(aliasDefinition.aliasName, aliasDefinition.aliasArgs);
        }
        continue;
      }

      if (aliases.has(executable)) {
        const aliasArgs = aliases.get(executable) || [];
        const effectiveTokens = [tokens[0], ...aliasArgs, ...tokens.slice(1)];
        const subcommand = normalizeAgentValue(stripOuterQuotes(effectiveTokens[1] || ""));
        if (reviewOnly) {
          if (subcommand === "commit" || subcommand === "merge") {
            return true;
          }
          continue;
        }

        if (isGitLifecycleSubcommandName(subcommand) ||
            !isReadOnlyGitSubcommand(subcommand, effectiveTokens, 1)) {
          return true;
        }
      }

      if (ghAliases.has(executable)) {
        const aliasArgs = ghAliases.get(executable) || [];
        const effectiveTokens = [tokens[0], ...aliasArgs, ...tokens.slice(1)];
        if (effectiveTokens.some((token, index) =>
          normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
          effectiveTokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
          isGhApiMergeCommand(effectiveTokens) ||
          isGhApiRefWriteCommand(effectiveTokens)) {
          return true;
        }
      }
    }
  }

  if (hasShellFunctionLifecycleCommand(command, reviewOnly)) {
    return true;
  }
  if (hasPowerShellFunctionLifecycleCommand(command, reviewOnly)) {
    return true;
  }
  if (hasAliasFunctionLifecycleCommand(command, reviewOnly, aliases, ghAliases)) {
    return true;
  }

  return false;
}

function getSetAliasDefinition(tokens) {
  let aliasName = "";
  let aliasTarget = "";
  const nameOptionPrefixes = expandPowerShellOptionPrefixes(["-name"]);
  const valueOptionPrefixes = expandPowerShellOptionPrefixes(["-value"]);
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (nameOptionPrefixes.includes(normalizedToken) && index + 1 < tokens.length) {
      aliasName = normalizeAgentValue(stripOuterQuotes(tokens[index + 1]));
      index += 1;
      continue;
    }
    if (valueOptionPrefixes.includes(normalizedToken) && index + 1 < tokens.length) {
      aliasTarget = normalizeAgentValue(stripOuterQuotes(tokens[index + 1]));
      index += 1;
      continue;
    }
    const inlineNameOption = nameOptionPrefixes.find((optionName) => normalizedToken.startsWith(optionName + ":"));
    if (inlineNameOption) {
      aliasName = normalizeAgentValue(token.slice(inlineNameOption.length + 1));
      continue;
    }
    const inlineValueOption = valueOptionPrefixes.find((optionName) => normalizedToken.startsWith(optionName + ":"));
    if (inlineValueOption) {
      aliasTarget = normalizeAgentValue(token.slice(inlineValueOption.length + 1));
      continue;
    }
    if (!normalizedToken.startsWith("-")) {
      if (!aliasName) {
        aliasName = normalizedToken;
      } else if (!aliasTarget) {
        aliasTarget = normalizedToken;
      }
    }
  }

  return { aliasName, aliasTarget };
}

function getShellAliasDefinition(tokens) {
  const assignment = stripOuterQuotes(tokens[1] || "");
  const match = /^([A-Za-z_][A-Za-z0-9_-]*)=(.+)$/u.exec(assignment);
  if (!match) {
    return { aliasName: "", aliasTarget: "", aliasArgs: [] };
  }

  const aliasTokens = unwrapEnvCommandTokens(tokenizeCommandLine(match[2] || ""));
  const aliasTarget = normalizeAgentValue(getExecutableBasename(aliasTokens[0] || ""));
  if (aliasTarget !== "git" && aliasTarget !== "git.exe" &&
      aliasTarget !== "gh" && aliasTarget !== "gh.exe") {
    return { aliasName: "", aliasTarget: "", aliasArgs: [] };
  }

  return {
    aliasName: normalizeAgentValue(match[1]),
    aliasTarget: aliasTarget.endsWith(".exe") ? aliasTarget.slice(0, -4) : aliasTarget,
    aliasArgs: aliasTokens.slice(1),
  };
}

function hasShellFunctionLifecycleCommand(command, reviewOnly) {
  const functionPattern = /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{[^}]*\b(git|gh)\b(?:\s+([A-Za-z0-9_-]+))?[^}]*\}\s*;\s*\1(?:\s+([^;&\r\n]+))?/giu;
  for (const match of command.matchAll(functionPattern)) {
    const toolName = normalizeAgentValue(match[2] || "");
    const bodySubcommand = normalizeAgentValue(match[3] || "");
    const callTokens = tokenizeCommandLine(match[4] || "");
    if (toolName === "git") {
      const subcommand = bodySubcommand && bodySubcommand !== "$@" ? bodySubcommand : normalizeAgentValue(callTokens[0] || "");
      if (reviewOnly) {
        if (subcommand === "commit" || subcommand === "merge") {
          return true;
        }
        continue;
      }

      if (isGitLifecycleSubcommandName(subcommand) || !isReadOnlyGitSubcommand(subcommand, [match[1], subcommand], 1)) {
        return true;
      }
    }

    if (toolName === "gh") {
      const effectiveTokens = ["gh"];
      if (bodySubcommand && bodySubcommand !== "$@") {
        effectiveTokens.push(bodySubcommand);
      }
      effectiveTokens.push(...callTokens);
      if (effectiveTokens.some((token, index) =>
        normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
        effectiveTokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
        isGhApiMergeCommand(effectiveTokens) ||
        isGhApiRefWriteCommand(effectiveTokens)) {
        return true;
      }
    }
  }

  return false;
}

function hasPowerShellFunctionLifecycleCommand(command, reviewOnly) {
  const functionPattern = /(?:^|[;&])\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\s*\{[^}]*\b(git|gh)\b(?:\s+([A-Za-z0-9_-]+))?[^}]*\}\s*;?\s*\1(?:\s+([^;&\r\n]+))?/giu;
  for (const match of command.matchAll(functionPattern)) {
    const toolName = normalizeAgentValue(match[2] || "");
    const bodySubcommand = normalizeAgentValue(match[3] || "");
    const callTokens = tokenizeCommandLine(match[4] || "");
    if (toolName === "git") {
      const subcommand = bodySubcommand && bodySubcommand !== "$args" ? bodySubcommand : normalizeAgentValue(callTokens[0] || "");
      if (reviewOnly) {
        if (subcommand === "commit" || subcommand === "merge") {
          return true;
        }
        continue;
      }

      if (isGitLifecycleSubcommandName(subcommand) || !isReadOnlyGitSubcommand(subcommand, [match[1], subcommand], 1)) {
        return true;
      }
    }

    if (toolName === "gh") {
      const effectiveTokens = ["gh"];
      if (bodySubcommand && bodySubcommand !== "$args") {
        effectiveTokens.push(bodySubcommand);
      }
      effectiveTokens.push(...callTokens);
      if (effectiveTokens.some((token, index) =>
        normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
        effectiveTokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
        isGhApiMergeCommand(effectiveTokens) ||
        isGhApiRefWriteCommand(effectiveTokens)) {
        return true;
      }
    }
  }

  return false;
}

function hasAliasFunctionLifecycleCommand(command, reviewOnly, aliases, ghAliases) {
  return hasAliasFunctionLifecycleCommandWithPattern(
    command,
    /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{([^}]*)\}\s*;\s*\1(?:\s+([^;&\r\n]+))?/giu,
    reviewOnly,
    aliases,
    ghAliases) ||
    hasAliasFunctionLifecycleCommandWithPattern(
      command,
      /(?:^|[;&])\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\s*\{([^}]*)\}\s*;?\s*\1(?:\s+([^;&\r\n]+))?/giu,
      reviewOnly,
      aliases,
      ghAliases);
}

function hasAliasFunctionLifecycleCommandWithPattern(command, pattern, reviewOnly, aliases, ghAliases) {
  if (aliases.size === 0 && ghAliases.size === 0) {
    return false;
  }

  for (const match of String(command || "").matchAll(pattern)) {
    const body = match[2] || "";
    const callTokens = tokenizeCommandLine(match[3] || "");
    if (hasAliasBodyGitLifecycleCommand(body, callTokens, reviewOnly, aliases)) {
      return true;
    }
    if (hasAliasBodyGhLifecycleCommand(body, callTokens, ghAliases)) {
      return true;
    }
  }

  return false;
}

function hasAliasBodyGitLifecycleCommand(body, callTokens, reviewOnly, aliases) {
  for (const [aliasName, aliasArgs] of aliases) {
    const pattern = new RegExp(`\\b${escapeRegex(aliasName)}\\b(?:\\s+([^;&|\\r\\n]+))?`, "iu");
    const match = pattern.exec(body);
    if (!match) {
      continue;
    }

    const bodyTokens = tokenizeCommandLine(match[1] || "");
    const effectiveTokens = [aliasName, ...aliasArgs, ...bodyTokens, ...callTokens];
    const subcommand = normalizeAgentValue(stripOuterQuotes(effectiveTokens[1] || ""));
    if (reviewOnly) {
      if (subcommand === "commit" || subcommand === "merge") {
        return true;
      }
      continue;
    }

    if (isGitLifecycleSubcommandName(subcommand) ||
        !isReadOnlyGitSubcommand(subcommand, effectiveTokens, 1)) {
      return true;
    }
  }

  return false;
}

function hasAliasBodyGhLifecycleCommand(body, callTokens, ghAliases) {
  for (const [aliasName, aliasArgs] of ghAliases) {
    const pattern = new RegExp(`\\b${escapeRegex(aliasName)}\\b(?:\\s+([^;&|\\r\\n]+))?`, "iu");
    const match = pattern.exec(body);
    if (!match) {
      continue;
    }

    const bodyTokens = tokenizeCommandLine(match[1] || "");
    const effectiveTokens = [aliasName, ...aliasArgs, ...bodyTokens, ...callTokens];
    if (effectiveTokens.some((token, index) =>
      normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
      effectiveTokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
      isGhApiMergeCommand(effectiveTokens) ||
      isGhApiRefWriteCommand(effectiveTokens)) {
      return true;
    }
  }

  return false;
}

function escapeRegex(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function isReadOnlyGitBranchCommand(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1);
  if (args.length === 0) {
    return true;
  }

  const selectorOptions = ["--list", "-l", "--contains", "--merged", "--no-merged", "--all", "-a", "--remotes", "-r"];
  let hasSelector = false;

  for (let index = 0; index < args.length; index += 1) {
    const arg = normalizeAgentValue(stripOuterQuotes(args[index]));
    if (arg === "--format") {
      index += 1;
      continue;
    }

    if (arg.startsWith("--format=")) {
      continue;
    }

    if (arg === "--show-current") {
      continue;
    }

    if (selectorOptions.includes(arg)) {
      hasSelector = true;
      continue;
    }

    if (!arg.startsWith("-") && hasSelector) {
      continue;
    }

    return false;
  }

  return true;
}

function isReadOnlyGitTagCommand(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1);
  if (args.length === 0) {
    return true;
  }

  const selectorOptions = ["--list", "-l", "--points-at", "--contains", "--merged", "--no-merged"];
  let hasSelector = false;

  for (let index = 0; index < args.length; index += 1) {
    const arg = normalizeAgentValue(stripOuterQuotes(args[index]));
    if (arg === "--format") {
      index += 1;
      continue;
    }

    if (arg.startsWith("--format=")) {
      continue;
    }

    if (selectorOptions.includes(arg)) {
      hasSelector = true;
      continue;
    }

    if (!arg.startsWith("-") && hasSelector) {
      continue;
    }

    return false;
  }

  return true;
}

function isReadOnlyGitWorktreeCommand(tokens, subcommandIndex) {
  const args = tokens.slice(subcommandIndex + 1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
  if (args.length === 0) {
    return true;
  }

  const subcommand = args.find((arg) => !arg.startsWith("-")) || "";
  return subcommand === "list";
}

function isReviewGatedCommand(command) {
  if (hasPowerShellGitAliasLifecycleCommand(command, true)) {
    return true;
  }

  return isGitCommitOrMergeCommandLine(command) ||
         isGitCommitCommand(command) ||
         isGitMergeCommand(command) ||
         isGhPrMergeCommandLine(command) ||
         isGhPrMergeCommand(command) ||
         isGhApiMergeCommandLine(command);
}

function isGitCommitOrMergeCommandLine(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapPowerShellCommandWrapper(stage)));
      if (tokens.length === 0) {
        return false;
      }

      const executable = getExecutableBasename(tokens[0]);
      if (executable === "cmd" || executable === "cmd.exe") {
        const nestedCommand = getCmdShellArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isPowerShellExecutable(executable)) {
        const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (executable !== "git" && executable !== "git.exe") {
        return false;
      }

      const gitSubcommandIndex = findGitSubcommandIndex(tokens);
      if (gitSubcommandIndex < 0) {
        return false;
      }

      const gitSubcommand = getGitSubcommandName(tokens, gitSubcommandIndex);
      return gitSubcommand === "commit" || gitSubcommand === "merge";
    }));
}

function isGhPrMergeCommandLine(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapPowerShellCommandWrapper(stage)));
      if (tokens.length === 0) {
        return false;
      }

      const executable = getExecutableBasename(tokens[0]);
      if (executable === "cmd" || executable === "cmd.exe") {
        const nestedCommand = getCmdShellArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isPowerShellExecutable(executable)) {
        const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      return (executable === "gh" || executable === "gh.exe") &&
             tokens.some((token, index) =>
               normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
               tokens.slice(index + 1).some((nextToken) =>
                 normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge"));
    }));
}

function isGhApiMergeCommandLine(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapPowerShellCommandWrapper(stage)));
      if (tokens.length === 0) {
        return false;
      }

      const executable = getExecutableBasename(tokens[0]);
      if (executable === "cmd" || executable === "cmd.exe") {
        const nestedCommand = getCmdShellArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isPowerShellExecutable(executable)) {
        const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      return (executable === "gh" || executable === "gh.exe") &&
             (isGhApiMergeCommand(tokens) || isGhApiRefWriteCommand(tokens));
    }));
}

function isReviewerOnlyCommand(command) {
  return splitCommandSegments(command).some(isReviewerOnlySegment);
}

function isReviewerOnlySegment(segment) {
  const tokens = tokenizeCommandLine(segment);
  if (tokens.length === 0) {
    return false;
  }

  function hasReviewerCommandToken(tokenList, startIndex) {
    return hasStandaloneCommandToken(tokenList, "review-approve", startIndex) ||
           hasStandaloneCommandToken(tokenList, "review-fail", startIndex);
  }

  const executable = getExecutableBasename(tokens[0]);
  if (isReadOnlySearchCommand(executable)) {
    return false;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? isReviewerOnlyCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
    if (nestedCommand) {
      return isReviewerOnlyCommand(nestedCommand);
    }

    const fileArgument = getOptionValue(tokens, ["-file"]);
    if (fileArgument && isWinsmuxCoreScript(fileArgument)) {
      return hasReviewerCommandToken(tokens, tokens.indexOf(fileArgument) + 1);
    }

    const scriptIndex = tokens.findIndex((token) => isWinsmuxCoreScript(token));
    return scriptIndex >= 0 && hasReviewerCommandToken(tokens, scriptIndex + 1);
  }

  if (isWinsmuxExecutable(executable)) {
    return hasReviewerCommandToken(tokens, 1);
  }

  if (isWinsmuxCoreScript(tokens[0])) {
    return hasReviewerCommandToken(tokens, 1);
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

    if (char === "&" && command[index - 1] !== ">") {
      if (current.trim() !== "") {
        segments.push(current.trim());
      }
      current = "";
      continue;
    }

    current += char;
  }

  if (current.trim() !== "") {
    segments.push(current.trim());
  }

  return segments;
}

function splitCommandPipelineStages(command) {
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

    if (char === "|" && nextChar !== "|") {
      if (current.trim() !== "") {
        segments.push(current.trim());
      }
      current = "";
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
      return unescapeCmdCaretEscapes(tokens.slice(index + 1).join(" "));
    }

    if (token.startsWith("/c") || token.startsWith("/k")) {
      const inlineCommand = tokens[index].slice(2);
      return unescapeCmdCaretEscapes([inlineCommand, ...tokens.slice(index + 1)].filter(Boolean).join(" "));
    }

    const inlineSwitchIndex = Math.max(token.lastIndexOf("/c"), token.lastIndexOf("/k"));
    if (inlineSwitchIndex > 0) {
      const inlineCommand = tokens[index].slice(inlineSwitchIndex + 2);
      return unescapeCmdCaretEscapes([inlineCommand, ...tokens.slice(index + 1)].filter(Boolean).join(" "));
    }
  }

  return "";
}

function isShellCommandExecutable(executable) {
  return [
    "bash",
    "bash.exe",
    "sh",
    "sh.exe",
    "dash",
    "dash.exe",
    "zsh",
    "zsh.exe",
  ].includes(normalizeAgentValue(executable));
}

function getShellCommandArgument(tokens) {
  for (let index = 1; index < tokens.length; index += 1) {
    const token = normalizeAgentValue(stripOuterQuotes(tokens[index]));
    if (/^-[a-z]*c[a-z]*$/u.test(token)) {
      return stripOuterQuotes(tokens.slice(index + 1).join(" "));
    }

    const inlineCommandMatch = /^-[a-z]*?c([\s\S]+)$/u.exec(stripOuterQuotes(tokens[index]));
    if (inlineCommandMatch) {
      return stripOuterQuotes([inlineCommandMatch[1], ...tokens.slice(index + 1)].filter(Boolean).join(" "));
    }
  }

  return "";
}

function isPowerShellStartProcessExecutable(executable) {
  const normalized = normalizeExecutableName(executable);
  return normalized === "start-process" || normalized === "saps" || normalized === "start";
}

function getPowerShellStartProcessCommand(tokens) {
  if (tokens.length < 2) {
    return "";
  }

  let filePath = "";
  const argumentList = [];
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const token = normalizeAgentValue(rawToken);
    if ((token === "-filepath" || token === "-file") && index + 1 < tokens.length) {
      filePath = stripOuterQuotes(tokens[index + 1]);
      index += 1;
      continue;
    }

    const inlineFilePath = /^-(?:filepath|file):(.+)$/u.exec(rawToken);
    if (inlineFilePath) {
      filePath = stripOuterQuotes(inlineFilePath[1]);
      continue;
    }

    if ((token === "-argumentlist" || token === "-args") && index + 1 < tokens.length) {
      for (let argumentIndex = index + 1; argumentIndex < tokens.length; argumentIndex += 1) {
        const argument = cleanPowerShellStartProcessArgument(tokens[argumentIndex]);
        if (argument) {
          argumentList.push(argument);
        }
      }
      break;
    }

    const inlineArgumentList = /^-(?:argumentlist|args):(.+)$/iu.exec(rawToken);
    if (inlineArgumentList) {
      const inlineArgument = cleanPowerShellStartProcessArgument(inlineArgumentList[1]);
      if (inlineArgument) {
        argumentList.push(inlineArgument);
      }
      for (let argumentIndex = index + 1; argumentIndex < tokens.length; argumentIndex += 1) {
        const argument = cleanPowerShellStartProcessArgument(tokens[argumentIndex]);
        if (argument) {
          argumentList.push(argument);
        }
      }
      break;
    }

    if (!filePath && !token.startsWith("-")) {
      filePath = stripOuterQuotes(tokens[index]);
    }
  }

  return [filePath, ...argumentList].filter(Boolean).join(" ").trim();
}

function cleanPowerShellStartProcessArgument(value) {
  return stripOuterQuotes(String(value || "").trim())
    .replace(/^@\(/u, "")
    .replace(/\)$/u, "")
    .replace(/^,+|,+$/gu, "")
    .trim();
}

function unescapeCmdCaretEscapes(value) {
  return String(value || "").replace(/\^([\s\S])/gu, "$1");
}

function unwrapEnvCommandTokens(tokens) {
  const withoutInlineAssignments = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokens));
  if (withoutInlineAssignments.length === 0) {
    return withoutInlineAssignments;
  }

  const executable = normalizeAgentValue(getExecutableBasename(withoutInlineAssignments[0]));
  if (executable !== "env" && executable !== "env.exe") {
    return withoutInlineAssignments;
  }

  let index = 1;
  while (index < withoutInlineAssignments.length) {
    const token = stripOuterQuotes(withoutInlineAssignments[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (isInlineEnvironmentAssignment(token)) {
      index += 1;
      continue;
    }

    if (normalizedToken === "-s" || normalizedToken === "--split-string") {
      if (index + 1 >= withoutInlineAssignments.length) {
        return [];
      }
      const splitTokens = tokenizeCommandLine(stripOuterQuotes(withoutInlineAssignments[index + 1]));
      return stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes([
        ...splitTokens,
        ...withoutInlineAssignments.slice(index + 2),
      ]));
    }

    if (normalizedToken.startsWith("--split-string=")) {
      const splitValue = token.slice(token.indexOf("=") + 1);
      const splitTokens = tokenizeCommandLine(stripOuterQuotes(splitValue));
      return stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes([
        ...splitTokens,
        ...withoutInlineAssignments.slice(index + 1),
      ]));
    }

    if (normalizedToken === "-u" || normalizedToken === "--unset") {
      index += 2;
      continue;
    }

    if (normalizedToken === "-c" || normalizedToken === "--chdir") {
      index += 2;
      continue;
    }

    if (normalizedToken.startsWith("--unset=") ||
        normalizedToken.startsWith("--chdir=") ||
        normalizedToken === "-i" ||
        normalizedToken === "--ignore-environment") {
      index += 1;
      continue;
    }

    if (!token.startsWith("-")) {
      break;
    }

    index += 1;
  }

  return stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(withoutInlineAssignments.slice(index)));
}

function stripShellCommandBuiltinPrefixes(tokens) {
  let index = 0;
  while (index < tokens.length) {
    const executable = normalizeAgentValue(getExecutableBasename(tokens[index]));
    if (executable !== "command" && executable !== "exec" && executable !== "builtin") {
      break;
    }

    index += 1;
    while (index < tokens.length) {
      const option = normalizeAgentValue(stripOuterQuotes(tokens[index]));
      if (option === "--") {
        index += 1;
        break;
      }
      if (option === "-p" || option === "-v" || option === "-V") {
        index += 1;
        continue;
      }
      if (executable === "exec" && option === "-a") {
        index += 2;
        continue;
      }
      break;
    }
  }

  return tokens.slice(index);
}

function stripInlineEnvironmentPrefixes(tokens) {
  let index = 0;
  while (index < tokens.length && isInlineEnvironmentAssignment(stripOuterQuotes(tokens[index]))) {
    index += 1;
  }

  return tokens.slice(index);
}

function isInlineEnvironmentAssignment(token) {
  return /^[A-Za-z_][A-Za-z0-9_]*=/u.test(String(token || ""));
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
  let basename = path.posix.basename(stripOuterQuotes(normalizePathValue(unescapeShellCommandName(token))));
  basename = basename.replace(/`([\s\S])/gu, "$1");
  while (true) {
    const expressionMatch = /^\(\s*['"]?([^'"()]+)['"]?\s*\)$/u.exec(basename);
    if (!expressionMatch) {
      break;
    }
    basename = expressionMatch[1].trim();
  }

  return stripOuterQuotes(basename);
}

function unescapeShellCommandName(token) {
  const value = stripOuterQuotes(token);
  if (/^[A-Za-z]:[\\/]/u.test(value) || /^[.]{1,2}[\\/]/u.test(value) || value.includes("/") || value.includes(".")) {
    return value;
  }

  return value.replace(/\\([^\s])/gu, "$1");
}

function normalizeExecutableName(token) {
  const normalized = normalizeAgentValue(getExecutableBasename(token));
  return normalized.endsWith(".exe") ? normalized.slice(0, -4) : normalized;
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

function hasPowerShellEncodedCommandOption(tokens) {
  const encodedOptionPrefixes = expandPowerShellOptionPrefixes(["-encodedcommand"]);
  for (let index = 1; index < tokens.length; index += 1) {
    const normalizedToken = normalizeAgentValue(stripOuterQuotes(tokens[index]));
    if (encodedOptionPrefixes.includes(normalizedToken)) {
      return true;
    }

    if (encodedOptionPrefixes.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      return true;
    }
  }

  return false;
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

function getOptionRemainderValue(tokens, optionNames) {
  const normalizedOptionNames = expandPowerShellOptionPrefixes(optionNames);

  for (let index = 1; index < tokens.length; index += 1) {
    const token = tokens[index];
    const normalizedToken = normalizeAgentValue(token);
    if (normalizedOptionNames.includes(normalizedToken)) {
      return stripOuterQuotes(tokens.slice(index + 1).join(" "));
    }

    for (const optionName of normalizedOptionNames) {
      if (normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":")) {
        return stripOuterQuotes(token.slice(optionName.length + 1));
      }
    }
  }

  return "";
}

function isFileMutationTool(toolName) {
  return toolName === "Write" || toolName === "Edit" || toolName === "MultiEdit";
}

function normalizeComparablePath(value) {
  return path.resolve(String(value || "")).replace(/\\/g, "/").replace(/\/+$/u, "").toLowerCase();
}

function isPathInsideOrSame(candidatePath, rootPath) {
  const candidate = normalizeComparablePath(candidatePath);
  const root = normalizeComparablePath(rootPath);
  return candidate === root || candidate.startsWith(root + "/");
}

function normalizeAgentValue(value) {
  return typeof value === "string" ? value.trim().replace(/`([\s\S])/gu, "$1").toLowerCase() : "";
}

function normalizePathValue(value) {
  return typeof value === "string" ? value.replace(/\\/g, "/").trim().toLowerCase() : "";
}

function isProtectedReviewStatePath(filePath) {
  const normalized = normalizePathValue(filePath);
  return normalized === ".winsmux/review-state.json" || normalized.endsWith("/.winsmux/review-state.json");
}

function isDirectCodeWriteBypassCommand(command) {
  const normalized = normalizePathValue(command);
  if (!/\.(ps1|psm1|js|ts|rs|py)\b/.test(normalized)) {
    return false;
  }

  const codePathPattern = /[^"'|\r\n]*\.(?:ps1|psm1|js|ts|rs|py)\b/i;
  const directWritePattern = /(?:>|>>)\s*["']?[^"'|\r\n]*\.(?:ps1|psm1|js|ts|rs|py)\b|(?:set-content|add-content|out-file|copy-item|move-item|rename-item|new-item|ni)\b[^|&\r\n]*\.(?:ps1|psm1|js|ts|rs|py)\b/i;
  if (directWritePattern.test(normalized)) {
    return true;
  }

  const segments = splitCommandSegments(command);
  for (const segment of segments) {
    const tokens = tokenizeCommandLine(segment);
    if (tokens.length === 0) {
      continue;
    }

    const executable = getExecutableBasename(tokens[0]);
    if (isPowerShellExecutable(executable)) {
      const commandArgument = getOptionRemainderValue(tokens, ["-command", "-c"]);
      if (commandArgument && codePathPattern.test(commandArgument) && directWritePattern.test(normalizePathValue(commandArgument))) {
        return true;
      }
    }

    if (executable === "cmd" || executable === "cmd.exe") {
      const shellArgument = getCmdShellArgument(tokens);
      if (shellArgument && codePathPattern.test(shellArgument) && directWritePattern.test(normalizePathValue(shellArgument))) {
        return true;
      }
    }

    if ((executable === "python" || executable === "python.exe" || executable === "python3" || executable === "py") &&
        /(?:open|write_text|write_bytes|Path\()/i.test(segment) &&
        codePathPattern.test(segment)) {
      return true;
    }
  }

  return false;
}

function getShellWriteTargets(command) {
  const targets = [];
  collectShellWriteTargetsFromCommand(command, targets);
  return targets.filter((target) => target);
}

function collectShellWriteTargetsFromCommand(command, targets, powerShellAliases = new Map()) {
  for (const segment of splitCommandSegments(command)) {
    for (const pipelineStage of splitCommandPipelineStages(segment)) {
      collectShellWriteTargets(pipelineStage, targets, powerShellAliases);
    }
  }
}

function isUnresolvedShellTarget(target) {
  const normalized = String(target || "").trim();
  return normalized.startsWith("$") ||
         normalized.startsWith("%") ||
         normalized.startsWith("@") ||
         normalized.startsWith("(") ||
         normalized.includes("$") ||
         normalized.includes("$(") ||
         normalized.includes("@args") ||
         normalized.includes("${");
}

function collectShellWriteTargets(segment, targets, powerShellAliases = new Map()) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  collectPowerShellScriptBlockWriteTargets(normalizedSegment, targets, powerShellAliases);

  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedSegment));
  if (tokens.length === 0) {
    return;
  }

  if (collectPowerShellDynamicWriteTargets(normalizedSegment, tokens, targets, powerShellAliases)) {
    return;
  }

  let executable = getExecutableBasename(tokens[0]);
  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    if (nestedCommand) {
      collectShellWriteTargets(nestedCommand, targets, powerShellAliases);
      collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
    }
    return;
  }

  if (isPowerShellExecutable(executable)) {
    if (hasPowerShellEncodedCommandOption(tokens)) {
      targets.push("$encoded-powershell-command");
      return;
    }

    const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
    if (nestedCommand) {
      collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
      return;
    }
  }

  if (isShellCommandExecutable(executable)) {
    const nestedCommand = getShellCommandArgument(tokens);
    if (nestedCommand) {
      collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
      return;
    }
  }

  if (isPowerShellStartProcessExecutable(executable)) {
    collectPowerShellStartProcessRedirectTargets(tokens, targets);
    const nestedCommand = getPowerShellStartProcessCommand(tokens);
    if (nestedCommand) {
      collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
    }
    return;
  }

  const normalizedExecutable = normalizeAgentValue(executable);
  if (normalizedExecutable === "set-alias" || normalizedExecutable === "sal" ||
      normalizedExecutable === "new-alias" || normalizedExecutable === "nal") {
    const { aliasName, aliasTarget } = getSetAliasDefinition(tokens);
    if (aliasName && isPowerShellMutationExecutable(aliasTarget)) {
      powerShellAliases.set(aliasName, aliasTarget);
    }
    return;
  }

  const aliasTarget = powerShellAliases.get(normalizedExecutable);
  if (aliasTarget) {
    tokens[0] = aliasTarget;
    executable = getExecutableBasename(tokens[0]);
  }

  collectRedirectionTargets(normalizedSegment, targets);
  collectPosixMutationTargets(tokens, targets);
  collectWindowsCopyUtilityTargets(tokens, targets);
  collectPowerShellMutationTargets(tokens, targets);
  collectPowerShellDotNetMutationTargets(normalizedSegment, targets);
  collectInterpreterMutationTargets(normalizedSegment, tokens, targets);
}

function collectPowerShellStartProcessRedirectTargets(tokens, targets) {
  const redirectOptionPrefixes = expandPowerShellOptionPrefixes([
    "-redirectstandardoutput",
    "-redirectstandarderror",
  ]);
  for (const value of collectPowerShellOptionValues(tokens, redirectOptionPrefixes)) {
    pushPowerShellTargetValues(targets, value);
  }
}

function collectPowerShellDynamicWriteTargets(segment, tokens, targets, powerShellAliases) {
  const executable = normalizeExecutableName(tokens[0] || "");
  if (executable === "invoke-expression" || executable === "iex") {
    const nestedCommand = stripOuterQuotes(tokens.slice(1).join(" "));
    if (!nestedCommand || /^\$/u.test(nestedCommand)) {
      targets.push("$unparsed-powershell-dynamic-write");
      return true;
    }
    collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
    return true;
  }

  const nestedCommands = getPowerShellScriptBlockCreateCommands(segment);
  if (nestedCommands.length === 0) {
    return false;
  }

  for (const nestedCommand of nestedCommands) {
    if (!nestedCommand || isUnparsedPowerShellDynamicCommand(nestedCommand)) {
      targets.push("$unparsed-powershell-dynamic-write");
      continue;
    }
    collectShellWriteTargetsFromCommand(nestedCommand, targets, powerShellAliases);
  }
  return true;
}

function collectWindowsCopyUtilityTargets(tokens, targets) {
  const executable = normalizeExecutableName(tokens[0]);
  if (executable !== "xcopy" && executable !== "robocopy") {
    return;
  }

  const positional = tokens.slice(1)
    .map((token) => stripOuterQuotes(token))
    .filter((token) => token && !token.startsWith("/") && !token.startsWith("-"));
  if (executable === "xcopy") {
    if (positional.length >= 2) {
      targets.push(positional[positional.length - 1]);
    } else {
      targets.push("$unparsed-windows-copy-target");
    }
    return;
  }

  if (positional.length >= 2) {
    if (tokens.some((token) => {
      const normalizedToken = normalizeAgentValue(stripOuterQuotes(token));
      return normalizedToken === "/mov" || normalizedToken === "/move";
    })) {
      targets.push(positional[0]);
    }
    targets.push(positional[1]);
  } else {
    targets.push("$unparsed-windows-copy-target");
  }
}

function collectPosixMutationTargets(tokens, targets) {
  const executable = normalizeExecutableName(tokens[0]);
  if (["touch", "mkdir", "rm", "rmdir", "unlink"].includes(executable)) {
    const positional = collectPosixPositionalValues(tokens);
    if (positional.length === 0) {
      targets.push("$unparsed-posix-write-target");
      return;
    }
    targets.push(...positional);
    return;
  }

  if (executable === "cp") {
    const positional = collectPosixPositionalValues(tokens);
    if (positional.length >= 2) {
      targets.push(positional[positional.length - 1]);
    } else {
      targets.push("$unparsed-posix-write-target");
    }
    return;
  }

  if (executable === "mv") {
    const positional = collectPosixPositionalValues(tokens);
    if (positional.length >= 2) {
      targets.push(positional[0]);
      targets.push(positional[positional.length - 1]);
    } else {
      targets.push("$unparsed-posix-write-target");
    }
  }
}

function collectPosixPositionalValues(tokens) {
  return tokens.slice(1)
    .map((token) => stripOuterQuotes(token))
    .filter((token) => token && !token.startsWith("-"));
}

function collectPowerShellScriptBlockWriteTargets(segment, targets, powerShellAliases) {
  const commandNames = powerShellAliases.size > 0
    ? [...getPowerShellMutationExecutableNames(), ...powerShellAliases.keys()]
    : getPowerShellMutationExecutableNames();
  const mutationNames = commandNames.map((name) => name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")).join("|");
  const scriptBlockPattern = new RegExp(`\\{([^{}]*\\b(?:${mutationNames})\\b[^{}]*)\\}`, "giu");
  for (const match of segment.matchAll(scriptBlockPattern)) {
    collectShellWriteTargetsFromCommand(match[1] || "", targets, powerShellAliases);
  }
}

function collectRedirectionTargets(segment, targets) {
  const redirectionPattern = /(?:^|[^\r\n])(?:\d|\*)?(?:>>|>)\s*(?:"([^"]+)"|'([^']+)'|([^\s&|;]+))/gu;
  for (const match of segment.matchAll(redirectionPattern)) {
    targets.push(match[1] || match[2] || match[3] || "");
  }
}

function collectPowerShellMutationTargets(tokens, targets) {
  const executable = normalizeExecutableName(tokens[0]);
  if (!isPowerShellMutationExecutable(executable)) {
    return;
  }

  const initialTargetCount = targets.length;
  const pathOptionNames = [
    "-path",
    "-pspath",
    "-literalpath",
    "-filepath",
    "-destination",
    "-outfile",
    "-outputdirectory",
  ];
  const pathOptionPrefixes = expandPowerShellOptionPrefixes(pathOptionNames);
  const valueOptionNames = [
    "-value",
    "-encoding",
    "-stream",
    "-itemtype",
    "-name",
  ];
  const valueOptionPrefixes = expandPowerShellOptionPrefixes(valueOptionNames);

  if (isPowerShellRequestExecutable(executable)) {
    collectPowerShellRequestOutputTargets(tokens, targets);
    return;
  }

  if (isPowerShellCopyExecutable(executable)) {
    collectPowerShellCopyTargets(tokens, targets, pathOptionPrefixes, valueOptionPrefixes);
    return;
  }

  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (pathOptionPrefixes.includes(normalizedToken)) {
      if (index + 1 < tokens.length) {
        pushPowerShellTargetValues(targets, stripOuterQuotes(tokens[index + 1]));
      }
      index += 1;
      continue;
    }

    if (valueOptionPrefixes.includes(normalizedToken)) {
      index += 1;
      continue;
    }

    if (valueOptionPrefixes.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      continue;
    }

    const inlinePathOption = pathOptionPrefixes.find((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"));
    if (inlinePathOption) {
      pushPowerShellTargetValues(targets, token.slice(inlinePathOption.length + 1));
      continue;
    }

    if (!normalizedToken.startsWith("-")) {
      pushPowerShellTargetValues(targets, token);
    }
  }

  if (executable === "new-item" || executable === "ni" || executable === "mkdir" || executable === "md") {
    const nameValues = collectPowerShellOptionValues(tokens, expandPowerShellOptionPrefixes(["-name"]));
    const pathValues = [
      ...collectPowerShellOptionValues(tokens, pathOptionPrefixes),
      ...collectPowerShellPositionalValues(tokens, pathOptionPrefixes, valueOptionPrefixes).slice(0, 1),
    ];
    if (nameValues.length > 0 && pathValues.length > 0) {
      for (const pathValue of pathValues) {
        for (const nameValue of nameValues) {
          targets.push(path.join(stripOuterQuotes(pathValue), stripOuterQuotes(nameValue)));
        }
      }
    } else if (nameValues.length > 0 && targets.length === initialTargetCount) {
      targets.push("$unparsed-powershell-write");
    }
  }
}

function isPowerShellCopyExecutable(executable) {
  return ["copy-item", "copy", "cp", "cpi"].includes(normalizeExecutableName(executable));
}

function collectPowerShellCopyTargets(tokens, targets, pathOptionPrefixes, valueOptionPrefixes) {
  const destinationPrefixes = expandPowerShellOptionPrefixes(["-destination"]);
  const destinationValues = collectPowerShellOptionValues(tokens, destinationPrefixes);
  if (destinationValues.length > 0) {
    for (const value of destinationValues) {
      pushPowerShellTargetValues(targets, value);
    }
    return;
  }

  const positionalValues = collectPowerShellPositionalValues(tokens, pathOptionPrefixes, valueOptionPrefixes);
  if (positionalValues.length >= 2) {
    pushPowerShellTargetValues(targets, positionalValues[1]);
    return;
  }

  targets.push("$unparsed-powershell-copy-target");
}

function isPowerShellRequestExecutable(executable) {
  return [
    "invoke-webrequest",
    "iwr",
    "wget",
    "curl",
    "invoke-restmethod",
    "irm",
  ].includes(normalizeExecutableName(executable));
}

function collectPowerShellRequestOutputTargets(tokens, targets) {
  const outputOptionPrefixes = new Set([
    ...expandPowerShellOptionPrefixes(["-outfile"]),
    "-o",
    "--output",
  ]);

  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (outputOptionPrefixes.has(normalizedToken)) {
      if (index + 1 < tokens.length) {
        pushPowerShellTargetValues(targets, stripOuterQuotes(tokens[index + 1]));
      }
      index += 1;
      continue;
    }

    const inlineOption = [...outputOptionPrefixes].find((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"));
    if (inlineOption) {
      pushPowerShellTargetValues(targets, token.slice(inlineOption.length + 1));
    }
  }
}

function pushPowerShellTargetValues(targets, value) {
  for (const target of splitPowerShellTargetValue(value)) {
    targets.push(target);
  }
}

function splitPowerShellTargetValue(value) {
  return String(value || "")
    .split(",")
    .map((target) => stripOuterQuotes(target.trim()))
    .filter(Boolean);
}

function isPowerShellMutationExecutable(executable) {
  const normalizedExecutable = normalizeExecutableName(executable);
  return getPowerShellMutationExecutableNames().includes(normalizedExecutable);
}

function getPowerShellMutationExecutableNames() {
  return [
    "set-content",
    "sc",
    "add-content",
    "ac",
    "out-file",
    "copy-item",
    "copy",
    "cp",
    "cpi",
    "move-item",
    "move",
    "mv",
    "mi",
    "rename-item",
    "ren",
    "rni",
    "remove-item",
    "remove",
    "rm",
    "del",
    "erase",
    "rd",
    "ri",
    "rmdir",
    "clear-content",
    "clc",
    "new-item",
    "ni",
    "mkdir",
    "md",
    "tee-object",
    "tee",
    "export-csv",
    "epcsv",
    "export-clixml",
    "start-transcript",
    "invoke-webrequest",
    "iwr",
    "wget",
    "curl",
    "invoke-restmethod",
    "irm",
  ];
}

function collectPowerShellOptionValues(tokens, optionPrefixes) {
  const values = [];
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (optionPrefixes.includes(normalizedToken)) {
      if (index + 1 < tokens.length) {
        values.push(stripOuterQuotes(tokens[index + 1]));
      }
      index += 1;
      continue;
    }

    const inlineOption = optionPrefixes.find((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"));
    if (inlineOption) {
      values.push(token.slice(inlineOption.length + 1));
    }
  }

  return values;
}

function collectPowerShellPositionalValues(tokens, pathOptionPrefixes, valueOptionPrefixes) {
  const values = [];
  const allValueOptions = new Set([...pathOptionPrefixes, ...valueOptionPrefixes]);
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (allValueOptions.has(normalizedToken)) {
      index += 1;
      continue;
    }

    if ([...allValueOptions].some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      continue;
    }

    if (!normalizedToken.startsWith("-")) {
      values.push(token);
    }
  }

  return values;
}

function expandPowerShellOptionPrefixes(optionNames) {
  const prefixes = new Set();
  for (const optionName of optionNames) {
    const normalizedOption = normalizeAgentValue(optionName);
    for (let length = 2; length <= normalizedOption.length; length += 1) {
      prefixes.add(normalizedOption.slice(0, length));
    }
  }

  return Array.from(prefixes);
}

function collectPowerShellDotNetMutationTargets(segment, targets) {
  const firstArgumentPatterns = [
    /\[(?:system\.)?io\.file\]\s*::\s*(?:writealltext|writeallbytes|writealllines|appendalltext|appendalllines|create|createtext|delete|open|openwrite|openhandle)\s*\(\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\[(?:system\.)?io\.directory\]\s*::\s*(?:createdirectory|delete|move)\s*\(\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*::\s*new\s*\(\s*(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:delete|create|createtext|openwrite)\s*\(/giu,
    /\(\s*new-object\s+(?:-typename(?:\s+|:))?(?:system\.)?io\.(?:fileinfo|directoryinfo)\s+(?:-argumentlist(?:\s+|:))?(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:delete|create|createtext|openwrite)\s*\(/giu,
    /\(\s*\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:delete|create|createtext|openwrite)\s*\(/giu,
  ];
  const twoArgumentPatterns = [
    /\[(?:system\.)?io\.file\]\s*::\s*(?:copy|move|replace)\s*\(\s*(?:"([^"]+)"|'([^']+)')\s*,\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\[(?:system\.)?io\.directory\]\s*::\s*(?:move)\s*\(\s*(?:"([^"]+)"|'([^']+)')\s*,\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*::\s*new\s*\(\s*(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:moveto|copyto)\s*\(\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\(\s*new-object\s+(?:-typename(?:\s+|:))?(?:system\.)?io\.(?:fileinfo|directoryinfo)\s+(?:-argumentlist(?:\s+|:))?(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:moveto|copyto)\s*\(\s*(?:"([^"]+)"|'([^']+)')/giu,
    /\(\s*\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*(?:"([^"]+)"|'([^']+)')\s*\)\s*\.\s*(?:moveto|copyto)\s*\(\s*(?:"([^"]+)"|'([^']+)')/giu,
  ];
  let foundTarget = false;
  for (const pattern of firstArgumentPatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || match[2] || "");
      foundTarget = true;
    }
  }
  for (const pattern of twoArgumentPatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || match[2] || "");
      targets.push(match[3] || match[4] || "");
      foundTarget = true;
    }
  }

  const unquotedNewObjectFirstArgumentPatterns = [
    /\(\s*new-object\s+(?:-typename(?:\s+|:))?(?:system\.)?io\.(?:fileinfo|directoryinfo)\s+(?:-argumentlist(?:\s+|:))?([^\s)]+)\s*\)\s*\.\s*(?:delete|create|createtext|openwrite)\s*\(/giu,
    /\(\s*\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*([^\s)]+)\s*\)\s*\.\s*(?:delete|create|createtext|openwrite)\s*\(/giu,
  ];
  const unquotedNewObjectTwoArgumentPatterns = [
    /\(\s*new-object\s+(?:-typename(?:\s+|:))?(?:system\.)?io\.(?:fileinfo|directoryinfo)\s+(?:-argumentlist(?:\s+|:))?([^\s)]+)\s*\)\s*\.\s*(?:moveto|copyto)\s*\(\s*(?:"([^"]+)"|'([^']+)'|([^\s)]+))/giu,
    /\(\s*\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*([^\s)]+)\s*\)\s*\.\s*(?:moveto|copyto)\s*\(\s*(?:"([^"]+)"|'([^']+)'|([^\s)]+))/giu,
  ];
  for (const pattern of unquotedNewObjectFirstArgumentPatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || "");
      foundTarget = true;
    }
  }
  for (const pattern of unquotedNewObjectTwoArgumentPatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || "");
      targets.push(match[2] || match[3] || match[4] || "");
      foundTarget = true;
    }
  }

  if (/\bnew-object\b[\s\S]*(?:system\.)?io\.(?:fileinfo|directoryinfo)\b[\s\S]*\.\s*(?:delete|create|createtext|openwrite|moveto|copyto)\s*\(/iu.test(segment)) {
    targets.push("$unparsed-powershell-dotnet-write");
  }

  if (!foundTarget && (/\[(?:system\.)?io\.(?:file|directory)\]\s*::\s*(?:writealltext|writeallbytes|writealllines|appendalltext|appendalllines|create|createtext|delete|open|openwrite|openhandle|copy|move|replace|createdirectory)\s*\(/iu.test(segment) ||
      /\[(?:system\.)?io\.(?:fileinfo|directoryinfo)\]\s*::\s*new\s*\([^)]*\)\s*\.\s*(?:delete|create|createtext|openwrite|moveto|copyto)\s*\(/iu.test(segment))) {
    targets.push("$unparsed-powershell-dotnet-write");
  }
}

function collectInterpreterMutationTargets(segment, tokens, targets) {
  const interpreterKind = getShellInterpreterKind(tokens);
  if (!interpreterKind) {
    return;
  }

  if (interpreterKind === "node") {
    collectNodeMutationTargets(segment, targets);
    return;
  }

  collectPythonMutationTargets(segment, targets);
}

function getShellInterpreterKind(tokens) {
  const effectiveTokens = unwrapEnvCommandTokens(tokens);
  if (effectiveTokens.length === 0) {
    return "";
  }

  const executable = normalizeAgentValue(getExecutableBasename(effectiveTokens[0]));

  if (/^python(?:\d+(?:\.\d+)*)?(?:\.exe)?$/u.test(executable) || executable === "py" || executable === "py.exe") {
    return "python";
  }

  if (/^(?:node|nodejs)(?:\.exe)?$/u.test(executable)) {
    return "node";
  }

  return "";
}

function collectPythonMutationTargets(segment, targets) {
  const writePatterns = [
    /(?:^|[^\w])Path\s*\(\s*["']([^"']+)["']\s*\)\s*\.\s*(?:write_text|write_bytes)\s*\(/giu,
    /(?:^|[^\w])Path\s*\(\s*["']([^"']+)["']\s*\)\s*\.\s*(?:mkdir|rename|replace|rmdir|touch|unlink)\s*\(/giu,
    /(?:^|[^\w])Path\s*\(\s*["'][^"']+["']\s*\)\s*\.\s*(?:rename|replace)\s*\(\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])Path\s*\(\s*["'][^"']+["']\s*\)\s*\.\s*(?:rename|replace)\s*\(\s*Path\s*\(\s*["']([^"']+)["']\s*\)\s*\)/giu,
    /(?:^|[^\w])open\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']*[wax+][^"']*["']/giu,
    /(?:^|[^\w])os\.(?:makedirs|mkdir|removedirs|remove|rmdir|unlink)\s*\(\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])os\.(?:rename|replace)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']+["']\s*\)/giu,
    /(?:^|[^\w])os\.(?:rename|replace)\s*\(\s*["'][^"']+["']\s*,\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])(?:makedirs|mkdir|removedirs|remove|rmdir|unlink)\s*\(\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])(?:rename|replace)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']+["']\s*\)/giu,
    /(?:^|[^\w])(?:rename|replace)\s*\(\s*["'][^"']+["']\s*,\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])shutil\.(?:rmtree)\s*\(\s*["']([^"']+)["']\s*\)/giu,
    /(?:^|[^\w])shutil\.(?:move)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']+["']\s*\)/giu,
    /(?:^|[^\w])shutil\.(?:copy|copy2|copyfile|copytree|move)\s*\(\s*["'][^"']+["']\s*,\s*["']([^"']+)["']\s*\)/giu,
  ];
  let foundTarget = false;
  for (const pattern of writePatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || "");
      foundTarget = true;
    }
  }

  if (/(?:^|[^\w])Path\s*\(\s*["'][^"']+["']\s*\)\s*\.\s*(?:rename|replace)\s*\(\s*(?!["'])/iu.test(segment)) {
    targets.push("$unparsed-python-write");
  }

  if (/(?:^|[^\w])Path\s*\(\s*(?!["'])[A-Za-z_][A-Za-z0-9_]*\s*\)\s*\.\s*(?:write_text|write_bytes|mkdir|rename|replace|rmdir|touch|unlink)\s*\(/iu.test(segment) ||
      /(?:^|[^\w])open\s*\(\s*(?!["'])[A-Za-z_][A-Za-z0-9_]*\s*,/iu.test(segment) ||
      /(?:^|[^\w])os\.(?:makedirs|mkdir|removedirs|remove|rmdir|unlink)\s*\(\s*(?!["'])[A-Za-z_][A-Za-z0-9_]*/iu.test(segment)) {
    targets.push("$unparsed-python-write");
  }

  if (/(?:^|[^\w])os\.(?:rename|replace)\s*\(\s*["'][^"']+["']\s*,\s*(?!["'])/iu.test(segment) ||
      /(?:^|[^\w])shutil\.(?:copy|copy2|copyfile|copytree|move)\s*\(\s*["'][^"']+["']\s*,\s*(?!["'])/iu.test(segment)) {
    targets.push("$unparsed-python-write");
  }

  if (!foundTarget && /(?:write_text|write_bytes|\.write\s*\(|\bopen\s*\(|\.(?:makedirs|mkdir|removedirs|remove|rename|replace|rmdir|touch|unlink)\s*\(|\b(?:copy|copy2|copyfile|copytree|move|rmtree)\s*\()/iu.test(segment)) {
    targets.push("$unparsed-python-write");
  }
}

function collectNodeMutationTargets(segment, targets) {
  const writePatterns = [
    /(?:writeFileSync|appendFileSync|rmSync|unlinkSync|mkdirSync|mkdtempSync|rmdirSync|truncateSync|createWriteStream)\s*\(\s*["']([^"']+)["']/giu,
    /(?:openSync)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']*[wax+][^"']*["']/giu,
    /(?:renameSync)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']+["']/giu,
    /(?:renameSync|copyFileSync|cpSync)\s*\(\s*["'][^"']+["']\s*,\s*["']([^"']+)["']/giu,
    /(?:writeFile|appendFile|rm|unlink|mkdir|mkdtemp|rmdir|truncate)\s*\(\s*["']([^"']+)["']/giu,
    /(?:open)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']*[wax+][^"']*["']/giu,
    /(?:rename)\s*\(\s*["']([^"']+)["']\s*,\s*["'][^"']+["']/giu,
    /(?:rename|copyFile|cp)\s*\(\s*["'][^"']+["']\s*,\s*["']([^"']+)["']/giu,
  ];
  let foundTarget = false;
  for (const pattern of writePatterns) {
    for (const match of segment.matchAll(pattern)) {
      targets.push(match[1] || "");
      foundTarget = true;
    }
  }

  if (/(?:renameSync|copyFileSync|cpSync)\s*\(\s*["'][^"']+["']\s*,\s*(?!["'])/iu.test(segment) ||
      /(?:rename|copyFile|cp)\s*\(\s*["'][^"']+["']\s*,\s*(?!["'])/iu.test(segment)) {
    targets.push("$unparsed-node-write");
  }

  if (/(?:writeFileSync|appendFileSync|rmSync|unlinkSync|mkdirSync|mkdtempSync|rmdirSync|truncateSync|createWriteStream|openSync|writeFile|appendFile|rm|unlink|mkdir|mkdtemp|rmdir|truncate|open)\s*\(\s*(?!["'])[A-Za-z_$][A-Za-z0-9_$]*/iu.test(segment)) {
    targets.push("$unparsed-node-write");
  }

  if (!foundTarget && /(?:writeFileSync|appendFileSync|rmSync|unlinkSync|mkdirSync|mkdtempSync|rmdirSync|truncateSync|createWriteStream|openSync|renameSync|copyFileSync|cpSync|writeFile|appendFile|rm|unlink|mkdir|mkdtemp|rmdir|truncate|open|rename|copyFile|cp|\.write\s*\()/iu.test(segment)) {
    targets.push("$unparsed-node-write");
  }
}

function hasWriteCapableInterpreterHeredoc(command) {
  for (const line of command.split(/\r?\n/u)) {
    const markerIndex = line.indexOf("<<");
    if (markerIndex < 0) {
      continue;
    }

    const prefix = line.slice(0, markerIndex).trim();
    if (hasWriteCapableInterpreterHeredocPrefix(prefix)) {
      return true;
    }

    const suffix = line.slice(markerIndex + 2).trim();
    if (hasWriteCapableInterpreterHeredocSuffix(suffix)) {
      return true;
    }
  }

  return false;
}

function hasWriteCapableInterpreterHeredocSuffix(suffix) {
  const stages = splitCommandPipelineStages(suffix);
  return stages.slice(1).some((stage) => hasWriteCapableInterpreterHeredocPrefix(stage));
}

function hasWriteCapableInterpreterHeredocPrefix(prefix) {
  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapPowerShellCommandWrapper(prefix)));
  if (getShellInterpreterKind(tokens)) {
    return true;
  }

  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if (isPowerShellExecutable(executable) || isShellHeredocConsumerExecutable(executable)) {
    return true;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? hasWriteCapableInterpreterHeredocPrefix(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
    return nestedCommand ? hasWriteCapableInterpreterHeredocPrefix(nestedCommand) : false;
  }

  return false;
}

function isShellHeredocConsumerExecutable(executable) {
  return [
    "bash",
    "bash.exe",
    "sh",
    "sh.exe",
    "dash",
    "dash.exe",
    "zsh",
    "zsh.exe",
  ].includes(executable);
}

function resolveShellTargetPath(target) {
  const cleaned = stripOuterQuotes(String(target || "").trim());
  if (!cleaned) {
    return cleaned;
  }

  if (/^[A-Za-z]:[\\/]/.test(cleaned) || cleaned.startsWith("\\\\") || cleaned.startsWith("/")) {
    return cleaned;
  }

  if (cleaned === "~" || cleaned.startsWith("~\\") || cleaned.startsWith("~/")) {
    return path.join(os.homedir(), cleaned.replace(/^~[\\/]?/u, ""));
  }

  if (cleaned.startsWith("\\")) {
    return path.join(path.parse(process.cwd()).root, cleaned.replace(/^[\\/]+/u, ""));
  }

  return path.join(process.cwd(), cleaned);
}

function hasShellCwdChangeCommand(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some(isShellCwdChangeSegment));
}

function isShellCwdChangeSegment(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const tokens = stripInlineEnvironmentPrefixes(tokenizeCommandLine(normalizedSegment));
  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if ((executable === "env" || executable === "env.exe") && hasEnvChdirOption(tokens)) {
    return true;
  }

  if (executable === "cmd" || executable === "cmd.exe") {
    const nestedCommand = getCmdShellArgument(tokens);
    return nestedCommand ? hasShellCwdChangeCommand(nestedCommand) : false;
  }

  if (isPowerShellExecutable(executable)) {
    const nestedCommand = getOptionRemainderValue(tokens, ["-command", "-c"]);
    return nestedCommand ? hasShellCwdChangeCommand(nestedCommand) : false;
  }

  if (isShellCommandExecutable(executable)) {
    const nestedCommand = getShellCommandArgument(tokens);
    return nestedCommand ? hasShellCwdChangeCommand(nestedCommand) : false;
  }

  return [
    "cd",
    "chdir",
    "set-location",
    "sl",
    "push-location",
    "pop-location",
  ].includes(executable);
}

function hasEnvChdirOption(tokens) {
  for (let index = 1; index < tokens.length; index += 1) {
    const normalizedToken = normalizeAgentValue(stripOuterQuotes(tokens[index]));
    if (normalizedToken === "-c" || normalizedToken === "--chdir" || normalizedToken.startsWith("--chdir=")) {
      return true;
    }
    if (normalizedToken === "--") {
      return false;
    }
    if (!normalizedToken.startsWith("-") && !/^[A-Za-z_][A-Za-z0-9_]*=/u.test(stripOuterQuotes(tokens[index]))) {
      return false;
    }
  }

  return false;
}

function isRelativeShellTarget(target) {
  const cleaned = stripOuterQuotes(String(target || "").trim());
  return cleaned !== "" &&
    !/^[A-Za-z]:[\\/]/.test(cleaned) &&
    !cleaned.startsWith("\\\\") &&
    !cleaned.startsWith("\\") &&
    !cleaned.startsWith("~") &&
    !cleaned.startsWith("/");
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
  const reviewerRole = normalizeAgentValue(reviewer?.role);
  if (!reviewer || (reviewerRole !== "reviewer" && reviewerRole !== "worker")) {
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
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
    systemMessage: reason,
  })}\n`);
  process.exit(0);
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
  hasOrchestraProbeInputs,
  hasStandaloneCommandToken,
  hasValidReviewerPass,
  isBlockedUntilOrchestraReady,
  isDirectCodexDispatch,
  isDirectCodeWriteBypassCommand,
  isDirectReviewStateWriteCommand,
  isGitAddCommand,
  isGitCleanCommand,
  isGhPrMergeCommand,
  isLegacyOperatorProbeCommand,
  isGitCommitCommand,
  isGitMergeCommand,
  isGitPushCommand,
  isGitRebaseCommand,
  isGitResetCommand,
  isFileMutationTool,
  isPathInsideOrSame,
  isOperatorOnlyGitLifecycleSegment,
  isOperatorOnlyGitLifecycleCommand,
  normalizeComparablePath,
  isPowerShellExecutable,
  isProtectedReviewStatePath,
  isReadOnlyPowerShellDiagnostic,
  isReadOnlySearchCommand,
  isReviewerOnlyCommand,
  isReviewerOnlySegment,
  isReviewGatedCommand,
  isSettingsLocalHookMutation,
  isUnknownStateFailClosedCommand,
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
  unwrapPowerShellCommandWrapper,
};
