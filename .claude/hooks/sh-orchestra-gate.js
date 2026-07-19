// sh-orchestra-gate.js — PreToolUse hook
// Prevents Operator from writing code or bypassing winsmux CLI
"use strict";

const { execFileSync } = require("child_process");
const acorn = require("./vendor/acorn-8.17.0/acorn.js");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEBUG_LOG_PATH = path.join(os.tmpdir(), "winsmux-sh-orchestra-gate-command.log");
const SECRET_PATTERN =
  /\b(?:gho_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b|(?:^|\s)(?:GITHUB_TOKEN|GH_TOKEN|API_KEY)\s*=/i;
const ORCHESTRA_SESSION_NAME = "winsmux-orchestra";
const STARTUP_GATE_DISABLED = normalizeAgentValue(process.env.WINSMUX_DISABLE_ORCHESTRA_STARTUP_GATE) === "1";
const INTERPRETER_PROCESS_BOUNDARY = Object.freeze({
  ALLOW_PROVEN_NON_PROTECTED: "allow-proven-non-protected",
  ALLOW_STATIC_READONLY: "allow-static-readonly",
  DENY_PROTECTED: "deny-protected",
  DENY_AMBIGUOUS_PROTECTED: "deny-ambiguous-protected",
  DENY_UNOWNED_PROCESS: "deny-unowned-process",
});
const STATIC_NON_EXECUTOR_TOOL_ALLOWLIST = new Set(["echo"]);
const DIRECT_PROCESS_TRAMPOLINE_TOOLS = new Set([
  "cscript",
  "conhost",
  "mshta",
  "regsvr32",
  "rundll32",
  "schtasks",
  "wmic",
  "wsl",
  "wscript",
]);

try {
  const input = fs.readFileSync(0, "utf8");
  const event = JSON.parse(input);
  const toolName = event.tool_name || "";
  const toolInput = event.tool_input || {};
  const rawCommand = typeof toolInput.command === "string" ? toolInput.command : "";
  const bashCommand = toolName === "Bash" ? stripHeredocBodies(rawCommand) : "";
  const reviewCommand = toolName === "Bash" ? rawCommand : "";
  const reviewBaseCwd = typeof toolInput.cwd === "string" && toolInput.cwd.trim() !== ""
    ? toolInput.cwd
    : process.cwd();
  const executableHeredocBodies = toolName === "Bash" ? getExecutableHeredocBodies(reviewCommand) : [];
  const staticScriptEvidence = toolName === "Bash"
    ? getStaticInvokedScriptEvidence(reviewCommand, reviewBaseCwd)
    : { contents: [], unresolved: false };
  const reviewInlineCommand = toolName === "Bash"
    ? [bashCommand, ...executableHeredocBodies].filter(Boolean).join("\n")
    : "";
  const reviewDetectionCommand = toolName === "Bash"
    ? [reviewInlineCommand, ...staticScriptEvidence.contents].filter(Boolean).join("\n")
    : "";
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
    if (isDirectCodexDispatch(reviewDetectionCommand)) {
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
      if (toolName === "Bash" && isOperatorOnlyGitLifecycleCommand(bashCommand)) {
        deny("Worker-pane Git lifecycle blocked. Keep editing and testing in the assigned worktree; run git add, git commit, git push, and PR merge from the Operator shell.");
      }

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

  // Rule 12b: AST completeness guard. Worker ownership rules run first so their
  // more specific remediation remains observable for protected Git lifecycle calls.
  if (toolName === "Bash" &&
      (staticScriptEvidence.unresolved ||
       hasUnsupportedInlineInterpreterBoundary(reviewInlineCommand) ||
       hasUnsupportedDirectProcessBoundary(reviewInlineCommand))) {
    deny("Unsupported inline process construction is blocked. Use a supported literal form or a managed winsmux workflow.");
  }

  // Rule 13: Block review-gated commit/merge commands without valid Reviewer PASS for the current HEAD (#279)
  if (toolName === "Bash") {
    if (isReviewGatedCommand(reviewDetectionCommand) || hasConfiguredGitReviewLifecycleAlias(reviewDetectionCommand, reviewBaseCwd)) {
      const denyMessage = "Review required. Flow: 1) a review-capable pane runs winsmux review-request, 2) that pane reviews, 3) it runs winsmux review-approve or winsmux review-fail.";
      try {
        if (hasForeignGitHubLifecycleTarget(reviewDetectionCommand, reviewBaseCwd)) {
          deny(denyMessage);
        }
        const reviewRepoRoots = resolveReviewGateRepoRoots(toolInput, reviewDetectionCommand);
        if (reviewRepoRoots === null) {
          deny(denyMessage);
        }
        for (const reviewRepoRoot of reviewRepoRoots) {
          const reviewStatePath = path.join(reviewRepoRoot, ".winsmux", "review-state.json");
          const currentBranch = getCurrentBranch(reviewRepoRoot);
          const currentHeadSha = getCurrentHeadSha(reviewRepoRoot);
          const reviewState = JSON.parse(fs.readFileSync(reviewStatePath, "utf8"));
          if (!currentBranch || !hasValidReviewerPass(reviewState[currentBranch], currentHeadSha)) {
            deny(denyMessage);
          }
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

function stripHeredocBodiesAndTerminators(command) {
  if (!command.includes("<<")) return command;
  const lines = command.split(/\r?\n/u);
  const output = [];
  let activeTerminator = null;
  for (const line of lines) {
    if (activeTerminator !== null) {
      if (line.trim() === activeTerminator) activeTerminator = null;
      continue;
    }
    output.push(line);
    const matches = Array.from(line.matchAll(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/gu));
    if (matches.length > 0) activeTerminator = matches[matches.length - 1][2];
  }
  return output.join("\n").replace(/\s*\d*<<-?\s*(['"]?)[A-Za-z_][A-Za-z0-9_]*\1/gu, " ");
}

function getExecutableHeredocBodies(command) {
  if (typeof command !== "string" || !command.includes("<<")) {
    return [];
  }

  const lines = command.split(/\r?\n/);
  const bodies = [];
  for (let index = 0; index < lines.length; index += 1) {
    let commandLine = lines[index];
    let commandLineEnd = index;
    while (hasUnescapedTrailingBackslash(commandLine) && commandLineEnd + 1 < lines.length) {
      commandLine = commandLine.slice(0, -1) + lines[commandLineEnd + 1];
      commandLineEnd += 1;
    }

    const declarations = [...commandLine.matchAll(/(?:(?<![A-Za-z0-9_])([0-9]+))?<<(?!<)(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\3/gu)];
    if (declarations.length === 0) {
      index = commandLineEnd;
      continue;
    }

    const declarationPattern = /(?:(?<![A-Za-z0-9_])[0-9]+)?<<(?!<)-?\s*(['"]?)[A-Za-z_][A-Za-z0-9_]*\1/gu;
    const executableFds = new Set(declarations
      .map((declaration) => declaration[1] || "0")
      .filter((fd) => hasExecutableHeredocConsumer(commandLine, declarationPattern, fd)));
    const materializedTarget = getStaticHeredocOutputTarget(commandLine);

    const parsedBodies = [];
    let bodyIndex = commandLineEnd + 1;
    for (const declaration of declarations) {
      const body = [];
      const stripTabs = declaration[2] === "-";
      const terminator = declaration[4];
      while (bodyIndex < lines.length) {
        const candidate = stripTabs ? lines[bodyIndex].replace(/^\t+/u, "") : lines[bodyIndex];
        if (candidate === terminator) {
          bodyIndex += 1;
          break;
        }
        body.push(stripTabs ? lines[bodyIndex].replace(/^\t+/u, "") : lines[bodyIndex]);
        bodyIndex += 1;
      }
      parsedBodies.push({ fd: declaration[1] || "0", body: body.join("\n") });
    }
    index = Math.max(index, bodyIndex - 1);
    const laterCommand = lines.slice(bodyIndex).join("\n");
    const materializedBodyExecutesLater = materializedTarget !== "" &&
      doesCommandExecuteStaticScriptPath(laterCommand, materializedTarget);

    for (const parsedBody of parsedBodies) {
      if ((executableFds.has(parsedBody.fd) || materializedBodyExecutesLater) && parsedBody.body) {
        bodies.push(parsedBody.body);
      }
    }
  }

  return bodies;
}

function getStaticHeredocOutputTarget(commandLine) {
  const targets = [...String(commandLine || "").matchAll(
    /(?<![<>])([0-9]*)>>?(?![>&])[ \t]*(?:'([^']+)'|"([^"$\x60]+)"|([^\s;&|]+))/gu,
  )].filter((match) => !match[1] || match[1] === "1");
  if (targets.length === 0) return "";
  const match = targets[targets.length - 1];
  const target = stripOuterQuotes(match[2] || match[3] || match[4] || "").trim();
  const exactShellVariable = /^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$/u.test(target);
  if (!target || (!exactShellVariable && /[$%\x60*?\[\]{}\0]/u.test(target))) return "";
  return target;
}

function doesCommandExecuteStaticScriptPath(command, expectedPath, initialCwd = ".") {
  const expected = resolveComparableStaticScriptPath(expectedPath, initialCwd);
  const expectedVariable = getShellScriptVariableName(expectedPath);
  if (!expected && !expectedVariable) return false;
  const knownPaths = new Set(expected ? [expected] : []);
  let effectiveCwd = initialCwd;
  let cwdUnresolved = false;
  const matchesKnownPath = (value) => {
    const variable = getShellScriptVariableName(value);
    if (expectedVariable && variable === expectedVariable) return true;
    if (isDynamicStdinScriptPath(value)) return true;
    const resolved = resolveComparableStaticScriptPath(value, effectiveCwd);
    return Boolean(resolved && knownPaths.has(resolved));
  };
  const rememberPath = (value) => {
    if (!value || isDynamicStdinScriptPath(value)) return false;
    const resolved = resolveComparableStaticScriptPath(value, effectiveCwd);
    if (!resolved) return false;
    knownPaths.add(resolved);
    return true;
  };
  for (const segment of splitCommandSegments(String(command || ""))) {
    const stages = splitCommandPipelineStages(segment);
    let pipelineCarriesKnownBody = false;
    for (const stage of stages) {
      const rawTokens = tokenizeCommandLine(stage);
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(rawTokens));
      if (execution.nestedCommand && doesCommandExecuteStaticScriptPath(execution.nestedCommand, expectedPath, effectiveCwd)) {
        return true;
      }
      const executable = normalizeExecutableName(execution.tokens[0] || "");
      if (stages.length === 1 && (executable === "cd" || executable === "pushd")) {
        const nextCwd = stripOuterQuotes(execution.tokens[1] || "");
        if (!nextCwd || isDynamicStdinScriptPath(nextCwd)) {
          cwdUnresolved = true;
        } else {
          effectiveCwd = resolveComparableStaticScriptPath(nextCwd, effectiveCwd);
          cwdUnresolved = !effectiveCwd;
        }
        continue;
      }
      if (isShellCommandExecutable(executable)) {
        const startupAssignments = rawTokens
          .map((token) => stripOuterQuotes(token))
          .map((token) => /^(?:BASH_ENV|ENV)=(.*)$/u.exec(token))
          .filter(Boolean)
          .map((match) => stripOuterQuotes(match[1] || ""));
        if (startupAssignments.some((value) => !value || matchesKnownPath(value))) {
          return true;
        }
      }
      if (executable === "cat") {
        const source = execution.tokens.slice(1).find((token) => {
          const value = stripOuterQuotes(token);
          return value && !value.startsWith("-") && !/^[<>]/u.test(value);
        });
        const carriesKnownBody = Boolean(source && matchesKnownPath(source));
        if (carriesKnownBody) {
          const destination = getStaticHeredocOutputTarget(stage);
          if (destination) rememberPath(destination);
          pipelineCarriesKnownBody = true;
        }
      } else if (executable === "tee") {
        const inputTarget = getStaticShellInputTarget(stage);
        const carriesKnownBody = pipelineCarriesKnownBody || Boolean(inputTarget && matchesKnownPath(inputTarget));
        if (carriesKnownBody) {
          for (const token of execution.tokens.slice(1)) {
            const value = stripOuterQuotes(token);
            if (!value || value.startsWith("-") || /^[<>]/u.test(value) || value === inputTarget) continue;
            rememberPath(value);
            break;
          }
          pipelineCarriesKnownBody = true;
        }
      } else {
        pipelineCarriesKnownBody = false;
      }
      const scriptPath = getStaticInterpreterScriptPath(execution.tokens);
      if (!scriptPath) continue;
      if (cwdUnresolved || scriptPath.includes("\0") || matchesKnownPath(scriptPath)) {
        return true;
      }
    }
  }
  return false;
}

function getStaticShellInputTarget(commandLine) {
  const targets = [...String(commandLine || "").matchAll(
    /(?<![<])(?:0)?<(?![<&])[ \t]*(?:'([^']+)'|"([^"$\x60]+)"|([^\s;&|>]+))/gu,
  )];
  if (targets.length === 0) return "";
  const match = targets[targets.length - 1];
  const target = stripOuterQuotes(match[1] || match[2] || match[3] || "").trim();
  if (!target || /[$%\x60*?\[\]{}\0]/u.test(target)) return "";
  return target;
}

function normalizeStaticScriptPathToken(value) {
  return stripOuterQuotes(String(value || "").trim())
    .replace(/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/u, "$$$1")
    .replace(/^[.][\\/]/u, "")
    .replace(/\\/gu, "/")
    .replace(/\/+$/u, "")
    .toLowerCase();
}

function getShellScriptVariableName(value) {
  const source = stripOuterQuotes(String(value || "").trim());
  const match = source.match(/^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?:(?:#{1,2}|%{1,2})[^}]*)?\})$/u);
  return normalizeAgentValue(match?.[1] || match?.[2] || "");
}

function resolveComparableStaticScriptPath(value, cwd = ".") {
  const normalized = normalizeStaticScriptPathToken(value);
  if (!normalized || getShellScriptVariableName(value) || isDynamicStdinScriptPath(value)) return "";
  if (/^[a-z]:\//u.test(normalized) || normalized.startsWith("/")) {
    return path.posix.normalize(normalized);
  }
  const normalizedCwd = normalizeStaticScriptPathToken(cwd) || ".";
  return path.posix.normalize(path.posix.join(normalizedCwd, normalized)).replace(/^\.\//u, "");
}

function getStaticInterpreterScriptPath(tokens) {
  if (!Array.isArray(tokens) || tokens.length < 2) return "";
  const executable = normalizeExecutableName(tokens[0] || "");
  if (isPowerShellExecutable(executable)) {
    const fileArgument = getPowerShellFileArgument(tokens);
    return fileArgument.present ? fileArgument.value : "";
  }
  if (!isShellCommandExecutable(executable)) return "";
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalized = normalizeAgentValue(token);
    if (normalized === "-c" || normalized === "--command") return "";
    if (/^--(?:init-file|rcfile|startup-file)=/u.test(normalized)) {
      return token.slice(token.indexOf("=") + 1);
    }
    if (["--init-file", "--rcfile", "--startup-file"].includes(normalized)) {
      return index + 1 < tokens.length ? stripOuterQuotes(tokens[index + 1]) : "\0unresolved-shell-startup-file";
    }
    if (shellInterpreterOptionConsumesNextValue(token)) {
      if (index + 1 >= tokens.length) return "\0unresolved-shell-option-value";
      index += 1;
      continue;
    }
    if (normalized === "--") {
      return index + 1 < tokens.length ? stripOuterQuotes(tokens[index + 1]) : "";
    }
    if (token.startsWith("-")) continue;
    return token;
  }
  return "";
}

function getPowerShellFileArgument(tokens) {
  const fileOptionNames = expandPowerShellOptionPrefixes(["-file"]);
  const commandOptionNames = expandPowerShellOptionPrefixes([
    "-command",
    "-commandwithargs",
    "-encodedcommand",
  ]);
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(rawToken);
    if (commandOptionNames.includes(normalizedToken) || commandOptionNames.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      return { present: false, value: "", valueIndex: -1 };
    }
    if (fileOptionNames.includes(normalizedToken)) {
      return {
        present: true,
        value: index + 1 < tokens.length ? stripOuterQuotes(tokens[index + 1]) : "",
        valueIndex: index + 1,
      };
    }
    for (const optionName of fileOptionNames) {
      if (normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":")) {
        return { present: true, value: rawToken.slice(optionName.length + 1), valueIndex: index };
      }
    }
  }
  const valueOptionNames = expandPowerShellOptionPrefixes([
    "-configurationname",
    "-custompipename",
    "-executionpolicy",
    "-inputformat",
    "-outputformat",
    "-settingsfile",
    "-workingdirectory",
  ]);
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(rawToken);
    if (valueOptionNames.includes(normalizedToken)) {
      index += 1;
      continue;
    }
    if (valueOptionNames.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      continue;
    }
    if (rawToken.startsWith("-")) continue;
    if (/\.(?:ps1|psm1)$/iu.test(rawToken)) {
      return { present: true, value: rawToken, valueIndex: index };
    }
    break;
  }
  return { present: false, value: "", valueIndex: -1 };
}

function getStaticInvokedScriptEvidence(command, baseCwd, depth = 0) {
  const evidence = { contents: [], unresolved: false };
  if (depth > 5) {
    evidence.unresolved = true;
    return evidence;
  }
  const baseRepoRoot = resolveGitTopLevel(baseCwd);
  if (!baseRepoRoot) return evidence;
  const commandSurface = stripHeredocBodiesAndTerminators(String(command || ""));
  for (const segment of splitCommandSegments(commandSurface)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
      if (execution.nestedCommand) {
        const nestedEvidence = getStaticInvokedScriptEvidence(execution.nestedCommand, baseCwd, depth + 1);
        evidence.contents.push(...nestedEvidence.contents);
        evidence.unresolved = evidence.unresolved || nestedEvidence.unresolved;
      }
      const tokens = execution.tokens;
      const executable = normalizeExecutableName(tokens[0] || "");
      if (executable === "cmd" || executable === "cmd.exe") {
        const rawNestedCommand = getCmdShellArgument(tokens, false);
        if (rawNestedCommand) {
          const nestedCommand = getStaticNestedShellCommand("cmd", tokens.slice(1));
          if (nestedCommand === null) {
            evidence.unresolved = true;
          } else {
            const nestedEvidence = getStaticInvokedScriptEvidence(nestedCommand, baseCwd, depth + 1);
            evidence.contents.push(...nestedEvidence.contents);
            evidence.unresolved = evidence.unresolved || nestedEvidence.unresolved;
          }
        }
        continue;
      }
      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        if (nestedCommand) {
          const nestedEvidence = getStaticInvokedScriptEvidence(nestedCommand, baseCwd, depth + 1);
          evidence.contents.push(...nestedEvidence.contents);
          evidence.unresolved = evidence.unresolved || nestedEvidence.unresolved;
        }
        continue;
      }
      if (!isPowerShellExecutable(executable)) continue;
      const wrapperPrefix = getPowerShellWrapperPrefixTokens(tokens);
      if (wrapperPrefix.length < tokens.length) {
        const nestedCommand = getStaticNestedShellCommand(executable, tokens.slice(1));
        const initialWorkingDirectory = getPowerShellInitialWorkingDirectory(tokens, executable);
        if (nestedCommand === null || !nestedCommand || initialWorkingDirectory.includes("\0") ||
            isDynamicStdinScriptPath(initialWorkingDirectory)) {
          evidence.unresolved = true;
        } else {
          const nestedCwd = initialWorkingDirectory
            ? path.resolve(baseCwd, stripOuterQuotes(initialWorkingDirectory))
            : baseCwd;
          const nestedEvidence = getStaticInvokedScriptEvidence(nestedCommand, nestedCwd, depth + 1);
          evidence.contents.push(...nestedEvidence.contents);
          evidence.unresolved = evidence.unresolved || nestedEvidence.unresolved;
        }
        continue;
      }
      const fileArgument = getPowerShellFileArgument(tokens);
      if (!fileArgument.present) continue;
      const value = fileArgument.value;
      if (!value || value === "-" || /[$%\x60*?\[\]{}\0]/u.test(value)) {
        evidence.unresolved = true;
        continue;
      }
      const initialWorkingDirectory = getPowerShellInitialWorkingDirectory(tokens, executable);
      if (initialWorkingDirectory.includes("\0")) {
        evidence.unresolved = true;
        continue;
      }
      const scriptBaseCwd = initialWorkingDirectory
        ? path.resolve(baseCwd, stripOuterQuotes(initialWorkingDirectory))
        : baseCwd;
      const scriptPath = path.resolve(scriptBaseCwd, value);
      const scriptRepoRoot = resolveGitTopLevel(scriptBaseCwd);
      if (!scriptRepoRoot ||
          !isManagedReviewGateRepo(scriptRepoRoot, baseRepoRoot) ||
          !isPathInsideOrSame(scriptPath, scriptRepoRoot)) {
        evidence.unresolved = true;
        continue;
      }
      try {
        const stat = fs.statSync(scriptPath);
        if (!stat.isFile() || stat.size > 1024 * 1024) {
          evidence.unresolved = true;
          continue;
        }
        const source = fs.readFileSync(scriptPath, "utf8").replace(/^\uFEFF/u, "");
        const knownReadOnlyState = getKnownReadOnlyPowerShellScriptInvocationState(
          tokens,
          fileArgument,
          scriptPath,
          scriptRepoRoot,
          source,
        );
        if (knownReadOnlyState === "safe") {
          continue;
        }
        if (knownReadOnlyState === "unsafe") {
          evidence.unresolved = true;
          continue;
        }
        const protectedEvidence = getStaticScriptProtectedEvidence(source, path.dirname(scriptPath));
        evidence.contents.push(...protectedEvidence.commands);
        evidence.unresolved = evidence.unresolved || protectedEvidence.unresolved;
      } catch {
        evidence.unresolved = true;
      }
    }
  }
  return evidence;
}

function getKnownReadOnlyPowerShellScriptInvocationState(tokens, fileArgument, scriptPath, repoRoot, source) {
  const relativePath = path.relative(repoRoot, scriptPath).replace(/\\/gu, "/").toLowerCase();
  if (relativePath !== "scripts/winsmux-core.ps1" || fileArgument.valueIndex < 0) return "none";
  const args = tokens.slice(fileArgument.valueIndex + 1).map((token) => stripOuterQuotes(token));
  if (args.length === 0 || args.some((token) => /[$%\x60;&|{}\0]/u.test(token))) return "none";
  const command = normalizeAgentValue(args[0]);
  const rest = args.slice(1).map(normalizeAgentValue);
  const contracts = {
    version: { functionName: "Invoke-Version", allowedArgs: [[]] },
  };
  const contract = contracts[command];
  if (!contract || !contract.allowedArgs.some((allowed) =>
    allowed.length === rest.length && allowed.every((value, index) => value === rest[index]))) {
    return "none";
  }
  const escapedCommand = command.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const escapedFunction = contract.functionName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const hasRouterBinding = new RegExp(
    String.raw`^[ \t]*['"]${escapedCommand}['"][ \t]*\{[ \t]*${escapedFunction}\b`,
    "imu",
  ).test(source);
  const functionDefinitionPattern = new RegExp(
    String.raw`^[ \t]*function[ \t]+${escapedFunction}[ \t]*\{`,
    "imu",
  );
  const functionMatch = functionDefinitionPattern.exec(source);
  if (!hasRouterBinding || !functionMatch) return "unsafe";
  const bodies = getBraceBlockBodies(source.slice(functionMatch.index));
  if (bodies.length === 0) return "unsafe";
  const body = bodies[0];
  const protectedEvidence = getStaticScriptProtectedEvidence(body, path.dirname(scriptPath));
  if (protectedEvidence.unresolved || protectedEvidence.commands.length > 0) return "unsafe";
  const mutatesState = /(?:^|[;\r\n])\s*(?:&\s*)?(?:git|gh|codex|set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|rename-item|set-itemproperty|new-itemproperty|remove-itemproperty|start-process|saps|invoke-expression|iex|set-alias|new-alias|reg(?:\.exe)?)\b|(?:^|[;\r\n])\s*\.\s+[^\r\n]+|&\s*\$[A-Za-z_]/imu.test(body);
  return mutatesState ? "unsafe" : "safe";
}

function getStaticScriptProtectedEvidence(source, scriptCwd) {
  const text = String(source || "");
  const lines = text.split(/\r?\n/u);
  const commands = [];
  const seen = new Set();
  for (let index = 0; index < lines.length; index += 1) {
    const windows = [lines[index]];
    if (/[`\\]\s*$/u.test(lines[index]) && index + 1 < lines.length) {
      windows.push(`${lines[index]}\n${lines[index + 1]}`);
      if (/[`\\]\s*$/u.test(lines[index + 1]) && index + 2 < lines.length) {
        windows.push(`${lines[index]}\n${lines[index + 1]}\n${lines[index + 2]}`);
      }
    }
    for (const candidate of windows) {
      if (!/(?:^|[;&|({])\s*(?:&\s*)?(?:codex|git|gh|winsmux|start-process|saps)\b/iu.test(candidate) &&
          !/\b(?:Process|ProcessStartInfo)\s*\]::(?:Start|new)\s*\(/iu.test(candidate)) {
        continue;
      }
      const directCodex = /\bcodex(?:\.exe)?\b/iu.test(candidate) && isDirectCodexDispatch(candidate);
      const reviewGated = !directCodex && isReviewGatedCommand(candidate);
      if (!reviewGated && !directCodex) {
        continue;
      }
      const hasExplicitTarget = /(?:\bgit(?:\.exe)?\s+(?:[^;&\r\n]*\s)?-C\b|--git-dir\b|--work-tree\b|\bGIT_(?:DIR|WORK_TREE)\b|\bgh\s+(?:pr|repo)\s+merge\b[^;&\r\n]*--repo\b|\b(?:set-location|workingdirectory)\b)/iu.test(candidate);
      const normalized = directCodex
        ? "codex exec"
        : (hasExplicitTarget ? candidate.trim() : `git -C "${scriptCwd}" commit`);
      if (normalized && !seen.has(normalized)) {
        commands.push(normalized);
        seen.add(normalized);
      }
    }
  }
  const executableText = lines
    .filter((line) => !/^\s*#/u.test(line))
    .join("\n");
  const hasUnparsedDynamicProtectedCommand =
    /(?:&\s*\$[A-Za-z_][A-Za-z0-9_:]*|\b(?:invoke-expression|iex)\b)[\s\S]{0,200}\b(?:commit|merge|push|tag|codex\s+(?:exec|e)|--sandbox)\b/iu.test(executableText);
  return {
    commands,
    unresolved: hasUnparsedDynamicProtectedCommand && commands.length === 0,
  };
}

function hasExecutableHeredocConsumer(commandLine, declarationPattern, expectedFd = "0") {
  const marker = "__WINSMUX_HEREDOC_DECLARATION__";
  const markedCommandLine = commandLine.replace(declarationPattern, ` ${marker} `);
  const stdinDeviceAliases = getStdinDeviceAliases(commandLine);
  const reachableFds = getReachableHeredocFds(commandLine, expectedFd);
  const persistentDescriptor = expectedFd !== "0" && hasPersistentHeredocDescriptor(markedCommandLine, marker);
  if (persistentDescriptor) {
    return true;
  }
  const functionConsumers = new Set();
  const functionPattern = /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{([^}]*)\}/giu;
  for (const match of String(commandLine || "").matchAll(functionPattern)) {
    if ([...reachableFds].some((fd) => isStdinScriptConsumerStage(match[2] || "", stdinDeviceAliases, fd))) {
      functionConsumers.add(normalizeAgentValue(match[1]));
    }
  }

  for (const segment of splitCommandSegments(markedCommandLine)) {
    if (!segment.includes(marker) && !persistentDescriptor) {
      continue;
    }
    for (const markedStage of splitCommandPipelineStages(segment)) {
      const stageHasDeclaration = markedStage.includes(marker);
      const stage = markedStage.replaceAll(marker, " ");
      if (expectedFd !== "0" && !persistentDescriptor && !stageHasDeclaration) {
        continue;
      }
      if ([...reachableFds].some((fd) => isStdinScriptConsumerStage(stage, stdinDeviceAliases, fd))) {
        return true;
      }
      const stageTokens = unwrapEnvCommandTokens(tokenizeCommandLine(stage));
      if (functionConsumers.has(normalizeAgentValue(stripOuterQuotes(stageTokens[0] || "")))) {
        return true;
      }
    }
  }

  return false;
}

function getReachableHeredocFds(commandLine, sourceFd) {
  const normalizedSource = String(Number.parseInt(String(sourceFd), 10));
  const reachable = new Set([normalizedSource]);
  const duplications = [...String(commandLine || "").matchAll(/(?<![A-Za-z0-9_])([0-9]+)<&([0-9]+)(?![0-9])/gu)]
    .map((match) => [String(Number.parseInt(match[1], 10)), String(Number.parseInt(match[2], 10))]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [destination, source] of duplications) {
      if (reachable.has(source) && !reachable.has(destination)) {
        reachable.add(destination);
        changed = true;
      }
    }
  }
  return reachable;
}

function hasPersistentHeredocDescriptor(markedCommandLine, marker) {
  for (const segment of splitCommandSegments(markedCommandLine)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      if (!stage.includes(marker)) {
        continue;
      }
      const tokens = tokenizeCommandLine(stage.replaceAll(marker, " "));
      if (normalizeExecutableName(tokens[0] || "") === "exec" && tokens.length === 1) {
        return true;
      }
    }
  }
  return false;
}

function hasUnescapedTrailingBackslash(value) {
  const source = String(value || "");
  let count = 0;
  for (let index = source.length - 1; index >= 0 && source[index] === "\\"; index -= 1) {
    count += 1;
  }
  return count % 2 === 1;
}

function isStdinScriptConsumerStage(stage, stdinDeviceAliases = new Map(), expectedFd = "0") {
  const normalizedStage = String(stage || "").trim();
  const commandSegments = splitCommandSegments(normalizedStage);
  if (commandSegments.length > 1 || (commandSegments.length === 1 && commandSegments[0] !== normalizedStage)) {
    return commandSegments.some((segment) =>
      splitCommandPipelineStages(segment).some((pipelineStage) =>
        isStdinScriptConsumerStage(pipelineStage, stdinDeviceAliases, expectedFd)));
  }

  const executableStage = unwrapShellExecutableControlFlowPrefix(stage);
  if (executableStage && executableStage !== String(stage || "").trim()) {
    return isStdinScriptConsumerStage(executableStage, stdinDeviceAliases, expectedFd);
  }

  for (const blockBody of getBraceBlockBodies(stage)) {
    if (isStdinScriptConsumerStage(blockBody, stdinDeviceAliases, expectedFd)) {
      return true;
    }
  }

  for (const match of String(stage || "").matchAll(/>\(([^()]*)\)/gu)) {
    if (isStdinScriptConsumerStage(match[1] || "", stdinDeviceAliases, expectedFd)) {
      return true;
    }
  }

  const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
  if (execution.nestedCommand) {
    return isStdinScriptConsumerStage(execution.nestedCommand, stdinDeviceAliases, expectedFd);
  }

  const tokens = execution.tokens;
  const executable = normalizeExecutableName(tokens[0] || "");
  if (["source", "."].includes(executable)) {
    return isStdinDevicePathOrAlias(tokens[1] || "", stdinDeviceAliases, expectedFd) ||
      isDynamicStdinScriptPath(tokens[1] || "");
  }
  if (isShellCommandExecutable(executable)) {
    if (tokens.slice(1).some((token) => /^-[a-z]*c(?:[a-z]*|[\s\S]+)$/u.test(normalizeAgentValue(stripOuterQuotes(token))))) {
      return false;
    }

    let ambiguousOption = false;
    for (let index = 1; index < tokens.length; index += 1) {
      const token = stripOuterQuotes(tokens[index]);
      if (token === "-") {
        return true;
      }
      if (/^-[A-Za-z]*s[A-Za-z]*$/u.test(token)) {
        return true;
      }
      if (token === "--") {
        return index + 1 >= tokens.length;
      }
      if (shellInterpreterOptionConsumesNextValue(token)) {
        index += 1;
        continue;
      }
      if (/^[-+][abefhkmnptuvxBCEHPT]+$/u.test(token)) {
        continue;
      }
      if (token.startsWith("-") || token.startsWith("+")) {
        ambiguousOption = true;
        continue;
      }
      return isStdinDevicePathOrAlias(token, stdinDeviceAliases, expectedFd) ||
        isDynamicStdinScriptPath(token) || ambiguousOption;
    }
    return true;
  }

  if (["node", "python", "python3"].includes(executable)) {
    let ambiguousOption = false;
    for (let index = 1; index < tokens.length; index += 1) {
      const rawToken = stripOuterQuotes(tokens[index]);
      const token = normalizeAgentValue(rawToken);
      if (["-c", "-e", "-p", "-pe", "--eval", "--print", "-m"].includes(token) ||
          token.startsWith("--eval=") || token.startsWith("--print=")) {
        return false;
      }
      if (token === "-") {
        return true;
      }
      if (interpreterOptionConsumesNextValue(executable, rawToken, token)) {
        index += 1;
        continue;
      }
      if (isKnownValuelessInterpreterOption(executable, token)) {
        continue;
      }
      if (token.startsWith("-")) {
        ambiguousOption = true;
        continue;
      }
      return isStdinDevicePathOrAlias(rawToken, stdinDeviceAliases, expectedFd) ||
        isDynamicStdinScriptPath(rawToken) || ambiguousOption;
    }
    return true;
  }

  if (isPowerShellExecutable(executable)) {
    for (let index = 1; index < tokens.length; index += 1) {
      const token = normalizeAgentValue(stripOuterQuotes(tokens[index]));
      if (["-command", "-c", "-file", "-f"].includes(token)) {
        const scriptPath = tokens[index + 1] || "";
        return isStdinDevicePathOrAlias(scriptPath, stdinDeviceAliases, expectedFd) ||
          isDynamicStdinScriptPath(scriptPath);
      }
    }
    return true;
  }

  return false;
}

function isStdinDevicePath(token, expectedFd = "0", depth = 0, seen = new Set()) {
  const rawValue = stripOuterQuotes(String(token || "").trim());
  const value = normalizeAgentValue(rawValue).replaceAll("\\", "/");
  const normalizedFd = Number.parseInt(String(expectedFd), 10);
  if (!Number.isInteger(normalizedFd) || normalizedFd < 0) {
    return false;
  }
  if (normalizedFd === 0 && value === "-") {
    return true;
  }
  const normalizedPath = path.posix.normalize(value);
  if (normalizedFd === 0 && normalizedPath === "/dev/stdin") {
    return true;
  }
  const fdMatch = normalizedPath.match(/^\/(?:dev|proc\/self)\/fd\/([0-9]+)$/u);
  if (fdMatch && Number.parseInt(fdMatch[1], 10) === normalizedFd) {
    return true;
  }
  const alias = getFilesystemAliasTarget(rawValue);
  if (!alias.matched) {
    return false;
  }
  const aliasKey = normalizeAgentValue(path.resolve(rawValue)).replaceAll("\\", "/");
  if (alias.unresolved || depth >= 8 || seen.has(aliasKey)) {
    return true;
  }
  const nextSeen = new Set(seen);
  nextSeen.add(aliasKey);
  return isStdinDevicePath(alias.target, expectedFd, depth + 1, nextSeen);
}

function isStdinDevicePathOrAlias(token, stdinDeviceAliases, expectedFd = "0") {
  if (isStdinDevicePath(token, expectedFd)) {
    return true;
  }
  const aliasTarget = stdinDeviceAliases.get(normalizeStdinAliasPath(token));
  return Boolean(aliasTarget) && isStdinDevicePath(aliasTarget, expectedFd);
}

function normalizeStdinAliasPath(token) {
  const value = normalizeAgentValue(stripOuterQuotes(String(token || "").trim())).replaceAll("\\", "/");
  return value ? path.posix.normalize(value) : "";
}

function isAnyStdinDevicePath(token, depth = 0, seen = new Set()) {
  const rawValue = stripOuterQuotes(String(token || "").trim());
  const normalizedPath = path.posix.normalize(normalizeAgentValue(rawValue).replaceAll("\\", "/"));
  if (normalizedPath === "/dev/stdin" || /^\/(?:dev|proc\/self)\/fd\/[0-9]+$/u.test(normalizedPath)) {
    return true;
  }
  const alias = getFilesystemAliasTarget(rawValue);
  if (!alias.matched) {
    return false;
  }
  const aliasKey = normalizeAgentValue(path.resolve(rawValue)).replaceAll("\\", "/");
  if (alias.unresolved || depth >= 8 || seen.has(aliasKey)) {
    return true;
  }
  const nextSeen = new Set(seen);
  nextSeen.add(aliasKey);
  return isAnyStdinDevicePath(alias.target, depth + 1, nextSeen);
}

function getFilesystemAliasTarget(rawValue) {
  const candidate = path.resolve(String(rawValue || ""));
  let stat;
  try {
    stat = fs.lstatSync(candidate);
  } catch {
    return { matched: false, target: "", unresolved: false };
  }

  if (stat.isSymbolicLink()) {
    try {
      const target = fs.readlinkSync(candidate, "utf8");
      return {
        matched: true,
        target: path.isAbsolute(target) ? target : path.resolve(path.dirname(candidate), target),
        unresolved: !target,
      };
    } catch {
      return { matched: true, target: "", unresolved: true };
    }
  }

  if (stat.isFile() && stat.size >= 10 && stat.size <= 65536) {
    try {
      const content = fs.readFileSync(candidate);
      const magic = Buffer.from("!<symlink>", "ascii");
      if (content.subarray(0, magic.length).equals(magic)) {
        let payload = content.subarray(magic.length);
        let target = "";
        if (payload.length >= 2 && payload[0] === 0xff && payload[1] === 0xfe) {
          target = payload.subarray(2).toString("utf16le");
        } else if (payload.length >= 2 && payload[0] === 0xfe && payload[1] === 0xff) {
          const swapped = Buffer.from(payload.subarray(2));
          for (let index = 0; index + 1 < swapped.length; index += 2) {
            [swapped[index], swapped[index + 1]] = [swapped[index + 1], swapped[index]];
          }
          target = swapped.toString("utf16le");
        } else if (payload.length >= 2 && payload[1] === 0x00) {
          target = payload.toString("utf16le");
        } else {
          target = payload.toString("utf8");
        }
        target = target.replace(/^\uFEFF/u, "").replace(/\0+$/u, "").replace(/\r?\n$/u, "");
        return {
          matched: true,
          target: target && !path.isAbsolute(target) ? path.resolve(path.dirname(candidate), target) : target,
          unresolved: !target,
        };
      }
    } catch {
      return { matched: true, target: "", unresolved: true };
    }
  }

  try {
    const realPath = fs.realpathSync(candidate);
    if (normalizeStdinAliasPath(realPath) !== normalizeStdinAliasPath(candidate)) {
      return { matched: true, target: realPath, unresolved: false };
    }
  } catch {
    // A regular non-alias path is not an stdin device.
  }
  return { matched: false, target: "", unresolved: false };
}

function getStdinDeviceAliases(commandLine) {
  const aliases = new Map();
  for (const segment of splitCommandSegments(commandLine)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
      const tokens = execution.tokens;
      if (normalizeExecutableName(tokens[0] || "") !== "ln") {
        continue;
      }
      let symbolic = false;
      const operands = [];
      let optionsComplete = false;
      for (const rawToken of tokens.slice(1)) {
        const token = stripOuterQuotes(rawToken);
        if (!optionsComplete && token === "--") {
          optionsComplete = true;
          continue;
        }
        if (!optionsComplete && token.startsWith("-")) {
          symbolic = symbolic || token === "--symbolic" || /^-[A-Za-z]*s[A-Za-z]*$/u.test(token);
          continue;
        }
        optionsComplete = true;
        operands.push(rawToken);
      }
      if (!symbolic || operands.length !== 2) {
        continue;
      }
      const sourceKey = normalizeStdinAliasPath(operands[0]);
      const source = aliases.get(sourceKey) || operands[0];
      if (isAnyStdinDevicePath(source) || isDynamicStdinScriptPath(source)) {
        aliases.set(normalizeStdinAliasPath(operands[1]), source);
      }
    }
  }
  return aliases;
}

function isDynamicStdinScriptPath(token) {
  const value = stripOuterQuotes(String(token || "").trim());
  return /(?:\$\{|\$[A-Za-z_]|`|\$\()/u.test(value);
}

function shellInterpreterOptionConsumesNextValue(token) {
  return ["-o", "+o", "-O", "+O", "--rcfile", "--init-file", "--startup-file"].includes(token) ||
    /^[-+][A-Za-z]*[oO]$/u.test(token);
}

function interpreterOptionConsumesNextValue(executable, rawToken, normalizedToken) {
  if (executable === "python" || executable === "python3") {
    return ["-W", "-X"].includes(rawToken) || normalizedToken === "--check-hash-based-pycs";
  }
  return ["-r", "--require", "--input-type", "--loader", "--import", "--conditions", "--experimental-loader"].includes(normalizedToken);
}

function isKnownValuelessInterpreterOption(executable, token) {
  if (executable === "python" || executable === "python3") {
    return /^-[bdeiopqssuvx]+$/u.test(token);
  }
  return ["--no-warnings", "--trace-warnings", "--use-strict"].includes(token);
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

function unwrapShellGroupingWrapper(segment) {
  let current = typeof segment === "string" ? segment.trim() : "";

  while (isFullyWrappedShellGroup(current)) {
    current = current.slice(1, -1).trim();
  }

  return current;
}

function unwrapShellExecutableControlFlowPrefix(stage) {
  let current = typeof stage === "string" ? stage.trim() : "";
  for (let depth = 0; depth < 8 && current; depth += 1) {
    const ungrouped = unwrapShellGroupingWrapper(current);
    if (ungrouped !== current) {
      current = ungrouped;
      continue;
    }

    const unaryPrefix = /^(?:!\s*|coproc\b\s*)/iu.exec(current);
    if (unaryPrefix) {
      current = current.slice(unaryPrefix[0].length).trim();
      continue;
    }

    const caseArm = /^case\b[\s\S]*?\bin\b[\s\S]*?\)\s*/iu.exec(current);
    if (caseArm) {
      current = current.slice(caseArm[0].length).trim();
      continue;
    }

    const match = /^(if|then|else|elif|while|until|for|do|case|try|catch|finally|switch|foreach|fi|done|esac)\b\s*/iu.exec(current);
    if (!match) {
      break;
    }
    current = current.slice(match[0].length).trim();
    if (["fi", "done", "esac"].includes(normalizeAgentValue(match[1]))) {
      return "";
    }
  }

  return unwrapShellGroupingWrapper(current);
}

function isFullyWrappedShellGroup(value) {
  const source = typeof value === "string" ? value.trim() : "";
  if (!source.startsWith("(") || !source.endsWith(")")) {
    return false;
  }

  let quote = "";
  let parenDepth = 0;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (isShellQuoteTerminator(source, index, quote)) {
        quote = "";
      }
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(source, index, char);
      continue;
    }

    if (char === "(") {
      parenDepth += 1;
      continue;
    }

    if (char === ")" && parenDepth > 0) {
      parenDepth -= 1;
      if (parenDepth === 0 && index < source.length - 1) {
        return false;
      }
    }
  }

  return parenDepth === 0;
}

function isShellQuoteTerminator(source, index, quote) {
  const quoteCharacter = quote === "ansi-single" ? "'" : quote;
  if (source[index] !== quoteCharacter) {
    return false;
  }
  if (quote === "'") {
    return true;
  }

  let backslashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    backslashCount += 1;
  }
  return backslashCount % 2 === 0;
}

function getShellQuoteMode(source, index, quoteCharacter) {
  if (quoteCharacter === "'" && source[index - 1] === "$") {
    return "ansi-single";
  }
  return quoteCharacter;
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
  const powerShellComSpecCommand = materializePowerShellComSpecAliases(command);
  if (powerShellComSpecCommand !== command) {
    return isOperatorOnlyGitLifecycleCommand(powerShellComSpecCommand);
  }

  if (hasPowerShellGitAliasLifecycleCommand(command, false)) {
    return true;
  }

  if (hasXargsGitLifecycleCommand(command, false)) {
    return true;
  }

  if (hasPowerShellScriptBlockGitLifecycleCommand(command)) {
    return true;
  }

  if (hasPowerShellDynamicCallLifecycleCommand(command)) {
    return true;
  }

  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const powerShellStage = unwrapPowerShellCommandWrapper(stage);
      const groupedStage = unwrapShellGroupingWrapper(powerShellStage);
      if (groupedStage !== powerShellStage.trim()) {
        return isOperatorOnlyGitLifecycleCommand(groupedStage);
      }

      return isOperatorOnlyGitLifecycleSegment(stage);
    }));
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

  if (hasNestedPowerShellControlBlock(source) && hasGitLifecycleHint(source)) {
    return true;
  }

  return false;
}

function hasNestedPowerShellControlBlock(source) {
  const normalized = normalizeAgentValue(String(source || ""));
  return /\{[\s\S]*\{[\s\S]*\}[\s\S]*\}/u.test(normalized) &&
    /\b(?:if|foreach|for|while|switch|try|catch|finally|function)\b/u.test(normalized);
}

function hasXargsGitLifecycleCommand(command, reviewOnly) {
  const source = String(command || "");
  return splitCommandSegments(source).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const normalizedStage = unwrapPowerShellCommandWrapper(stage);
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage)));
      if (execution.nestedCommand) {
        return isReviewGatedCommand(execution.nestedCommand);
      }
      const tokens = execution.tokens;
      if (tokens.length === 0 || normalizeExecutableName(tokens[0]) !== "xargs") {
        return false;
      }

      const nestedTokens = getNormalizedXargsCommandTokens(tokens);
      if (isGitTokenLifecycleCommand(nestedTokens, reviewOnly) ||
          isGhTokenLifecycleCommand(nestedTokens)) {
        return true;
      }

      if (hasShellWrappedXargsLifecycleCommand(nestedTokens, source, reviewOnly)) {
        return true;
      }

      if (hasUnresolvedXargsLifecycleCommand(nestedTokens)) {
        return true;
      }

      const nestedExecutable = normalizeExecutableName(nestedTokens[0] || "");
      if (reviewOnly && nestedExecutable === "git" && findGitSubcommandIndex(nestedTokens) < 0) {
        return /\b(?:commit|merge|push|update-ref|branch|tag)\b/u.test(normalizeAgentValue(source));
      }

      if (nestedExecutable === "gh") {
        return hasGhLifecycleArgumentHint(source);
      }

      if (hasXargsLifecycleArgumentHint(source, reviewOnly)) {
        return true;
      }

      return false;
    }));
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

  if (executable === "xargs" || executable === "xargs.exe") {
    const nestedTokens = getNormalizedXargsCommandTokens(tokens);
    return isGitTokenLifecycleCommand(nestedTokens, false) ||
      isGhTokenLifecycleCommand(nestedTokens) ||
      hasShellWrappedXargsLifecycleCommand(nestedTokens, segment, false);
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

function hasInterpreterReviewGatedGitLifecycleCommand(segment, tokens) {
  if (hasDynamicInterpreterGitSubcommand(segment)) {
    return true;
  }
  const literalCommands = getInterpreterLiteralGitCommands(segment, tokens);
  if (literalCommands.some((command) => isReviewGatedCommand(command))) {
    return true;
  }

  return literalCommands.length === 0 &&
    hasDynamicInterpreterLifecycleHint(segment) &&
    /\b(?:commit|merge|push|update-ref|branch|tag)\b/iu.test(String(segment || ""));
}

function getInterpreterLiteralGitCommands(segment, tokens) {
  const interpreterKind = getShellInterpreterKind(tokens);
  if (!interpreterKind) {
    return [];
  }

  return getInterpreterLiteralGitCommandsForKind(segment, interpreterKind);
}

function getInterpreterLiteralGitCommandsForKind(segment, interpreterKind) {
  const source = String(segment || "");
  const commands = [];
  const calls = interpreterKind === "node"
    ? getNodeChildProcessCalls(source)
    : getPythonProcessCalls(source);
  for (const call of calls) {
    const callBody = getBalancedCallBody(source, call.openIndex);
    if (callBody === null) {
      continue;
    }
    const args = splitTopLevelCallArguments(callBody);
    const method = normalizeAgentValue(call.method);
    const assignments = getConstantStringAssignments(source, call.openIndex);
    if (interpreterKind === "node" && (method === "exec" || method === "execsync")) {
      const command = evaluateStaticStringExpression(args[0], assignments) || "";
      if (/\b(?:git|gh)(?:\.exe)?\b/iu.test(command)) {
        commands.push(command);
      }
      continue;
    }
    if (interpreterKind === "python" && method === "system") {
      const command = evaluateStaticStringExpression(args[0], assignments) || "";
      if (/\b(?:git|gh)(?:\.exe)?\b/iu.test(command)) {
        commands.push(command);
      }
      continue;
    }

    const commandExpression = stripLeadingCallComments(args[0]);
    const elements = interpreterKind === "node"
      ? getArrayLiteralElements(args[1])
      : commandExpression && ["[", "("].includes(commandExpression[0])
      ? splitTopLevelCallArguments(commandExpression.slice(1, -1))
      : null;
    const tool = interpreterKind === "node"
      ? normalizeExecutableName(evaluateStaticStringExpression(args[0], assignments) || "")
      : elements
      ? normalizeExecutableName(evaluateStaticStringExpression(elements[0], assignments) || "")
      : "";
    const argumentExpressions = interpreterKind === "node" ? elements : elements?.slice(1);
    if ((tool === "git" || tool === "gh") && argumentExpressions) {
      const staticArguments = argumentExpressions.map((expression) => evaluateStaticStringExpression(expression, assignments) || "");
      if (staticArguments.every((argument) => argument !== "")) {
        commands.push([tool, ...staticArguments].join(" "));
      }
    }
  }
  return commands.filter(Boolean);
}

function hasPythonGitLifecycleCommand(segment) {
  const source = String(segment || "");
  return getInterpreterLiteralGitCommandsForKind(source, "python")
    .some((command) => isOperatorOnlyGitLifecycleCommand(command)) ||
    hasDynamicInterpreterLifecycleHint(source);
}

function hasNodeGitLifecycleCommand(segment) {
  const source = String(segment || "");
  return getInterpreterLiteralGitCommandsForKind(source, "node")
    .some((command) => isOperatorOnlyGitLifecycleCommand(command)) ||
    hasDynamicInterpreterLifecycleHint(source);
}

function hasDynamicInterpreterLifecycleHint(source) {
  const text = String(source || "").toLowerCase();
  if (getNodeChildProcessCalls(text).length === 0 &&
      getPythonProcessCalls(text).length === 0) {
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
  if (!/^\s*(?:start-process|saps|start)\b/iu.test(source)) {
    return false;
  }

  const embeddedSetIndex = source.search(/\bset\s+[A-Za-z_][A-Za-z0-9_]*=/iu);
  if (embeddedSetIndex >= 0 && getCmdDynamicLifecycleCommand(unescapeCmdCaretEscapes(source.slice(embeddedSetIndex)))) {
    return true;
  }
  const invocation = getPowerShellStartProcessInvocation(tokenizeCommandLine(source));
  if (invocation.command) {
    return isOperatorOnlyGitLifecycleCommand(invocation.command);
  }
  return hasGitLifecycleHint(source) &&
    /(?:\(\s*get-command\b|\$env:comspec\b|\bpwsh\b|\bpowershell\b|\bcmd\b|['"]g['"]\s*\+\s*['"](?:it|h)['"]|^\s*(?:start-process|saps|start)\s+(?:['"]?git(?:\.exe)?['"]?|['"]?gh(?:\.exe)?['"]?))/iu.test(source);
}

function hasGitLifecycleHint(source) {
  const normalized = normalizeAgentValue(String(source || ""));
  if (!/\b(?:add|commit|merge|push|rebase|reset|restore|rm|checkout-index|update-index|notes|branch|tag|worktree|config)\b/u.test(normalized)) {
    return false;
  }

  return /\b(?:git|gh)\b/u.test(normalized) ||
    /['"]g['"]\s*\+\s*['"]it['"]/u.test(normalized) ||
    /['"]g['"]\s*\+\s*['"]h['"]/u.test(normalized) ||
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
  if (isGhApiGraphqlRefMutation(args)) {
    return true;
  }

  if (!args.some(isGhApiGitRefEndpoint)) {
    return false;
  }

  return hasGhApiWriteMethod(args) || hasGhApiWriteField(args);
}

function hasForeignGitHubLifecycleTarget(command, baseCwd, depth = 0) {
  if (depth > 5) {
    return true;
  }

  const currentRepo = getGitHubRepositorySlug(baseCwd);
  let ghRepoEnvironmentTarget = "";
  for (const segment of splitCommandSegments(command)) {
    const segmentGhRepo = getConstantGhRepoAssignment(segment);
    if (segmentGhRepo) {
      ghRepoEnvironmentTarget = segmentGhRepo;
    }
    for (const stage of splitCommandPipelineStages(segment)) {
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
      if (execution.nestedCommand && hasForeignGitHubLifecycleTarget(execution.nestedCommand, baseCwd, depth + 1)) {
        return true;
      }
      const tokens = execution.tokens;
      if (tokens.length === 0) {
        continue;
      }
      const executable = normalizeExecutableName(tokens[0]);
      if (isShellCommandExecutable(executable) || isPowerShellExecutable(executable)) {
        const nestedCommand = isShellCommandExecutable(executable)
          ? getShellCommandArgument(tokens)
          : getPowerShellNestedCommand(tokens);
        if (nestedCommand && hasForeignGitHubLifecycleTarget(nestedCommand, baseCwd, depth + 1)) {
          return true;
        }
        continue;
      }
      if (!isGhExecutableToken(tokens[0])) {
        continue;
      }
      if (isGhApiGraphqlRefMutation(tokens.map((token) => normalizeAgentValue(stripOuterQuotes(token))))) {
        return true;
      }

      let explicitRepo = "";
      for (let index = 1; index < tokens.length; index += 1) {
        const token = stripOuterQuotes(tokens[index]);
        const normalized = normalizeAgentValue(token);
        if ((normalized === "-r" || normalized === "--repo") && index + 1 < tokens.length) {
          explicitRepo = normalizeAgentValue(stripOuterQuotes(tokens[index + 1]));
          break;
        }
        if (normalized.startsWith("--repo=")) {
          explicitRepo = normalizeAgentValue(token.slice(token.indexOf("=") + 1));
          break;
        }
        if (normalized.startsWith("-r=") || (/^-r[^-]/u.test(normalized) && normalized.length > 2)) {
          explicitRepo = normalizeAgentValue(token.slice(token.startsWith("-R=") || token.startsWith("-r=") ? 3 : 2));
          break;
        }
        const pullUrlRepo = /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+\/[^/]+)\/pull\/\d+(?:[/?#]|$)/iu.exec(token);
        if (pullUrlRepo) {
          explicitRepo = normalizeAgentValue(pullUrlRepo[1]);
          break;
        }
        const apiRepo = /(?:^|\/)repos\/([^/]+\/[^/]+)(?:\/|$)/iu.exec(token);
        if (apiRepo) {
          explicitRepo = normalizeAgentValue(apiRepo[1]);
          break;
        }
      }

      if (!explicitRepo && ghRepoEnvironmentTarget) {
        explicitRepo = ghRepoEnvironmentTarget;
      }

      if (explicitRepo && (!currentRepo || explicitRepo !== currentRepo)) {
        return true;
      }
    }
  }
  return false;
}

function getConstantGhRepoAssignment(source) {
  let value = "";
  const pattern = /(?:^|[\s;])(?:export\s+)?(?:\$env:)?gh_repo\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s;]+))/giu;
  for (const match of String(source || "").matchAll(pattern)) {
    value = match[1] || match[2] || match[3] || "";
  }
  return normalizeAgentValue(stripOuterQuotes(value));
}

function getGitHubRepositorySlug(repoCwd) {
  const repoRoot = resolveGitTopLevel(repoCwd);
  if (!repoRoot) {
    return "";
  }
  try {
    const remote = execFileSync("git", ["-C", repoRoot, "config", "--get", "remote.origin.url"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim().replace(/\\/gu, "/");
    const match = /(?:github\.com[:/])([^/]+\/[^/]+)$/iu.exec(remote);
    return match ? normalizeAgentValue(match[1]).replace(/\.git$/u, "") : "";
  } catch {
    return "";
  }
}

function isGhApiGraphqlRefMutation(args) {
  const joinedArgs = args.join(" ");
  return /\bgraphql\b/u.test(joinedArgs) &&
    /\bmutation\b/u.test(joinedArgs) &&
    /\b(?:createref|updateref|deleteref)\b/u.test(joinedArgs);
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
  if (gitSubcommand === "grep") {
    return !hasGitWriteOption(tokens, subcommandIndex) &&
      hasOnlyCanonicalGitGrepLongOptions(tokens, subcommandIndex);
  }

  if ([
    "diff",
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

function hasOnlyCanonicalGitGrepLongOptions(tokens, subcommandIndex) {
  const exactOptions = new Set([
    "--all-match", "--and", "--basic-regexp", "--break", "--cached", "--count",
    "--extended-regexp", "--files-with-matches", "--files-without-match", "--fixed-strings",
    "--full-name", "--heading", "--ignore-case", "--invert-match", "--line-number",
    "--name-only", "--no-color", "--no-index", "--not", "--null", "--or",
    "--perl-regexp", "--quiet", "--recurse-submodules", "--text", "--untracked",
    "--word-regexp",
  ]);
  const valuedOptions = [
    "--after-context=", "--before-context=", "--color=", "--context=", "--max-count=",
    "--max-depth=", "--threads=",
  ];
  return tokens.slice(subcommandIndex + 1)
    .map((token) => normalizeAgentValue(stripOuterQuotes(token)))
    .every((argument) =>
      !argument.startsWith("--") ||
      argument === "--" ||
      exactOptions.has(argument) ||
      valuedOptions.some((prefix) => argument.startsWith(prefix) && argument.length > prefix.length));
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

  const commandIndex = args.findIndex((arg) => !arg.startsWith("-"));
  const subcommand = commandIndex < 0 ? "" : args[commandIndex];
  if (subcommand !== "show" && subcommand !== "get-url") return false;
  const operands = args.slice(commandIndex + 1).filter((arg) => !arg.startsWith("-"));
  const noQuery = args.includes("-n") || args.includes("--no-query");
  return operands.length === 1 &&
    /^[a-z0-9._-]+$/u.test(operands[0]) &&
    (subcommand === "get-url" || noQuery);
}

function findGitSubcommandIndex(tokens) {
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (!normalizedToken) {
      continue;
    }

    if (isGitGlobalOptionWithSeparateValue(normalizedToken)) {
      index += 1;
      continue;
    }

    if (isGitGlobalOptionWithInlineValue(normalizedToken)) {
      continue;
    }

    if (normalizedToken.startsWith("-")) {
      continue;
    }

    return index;
  }

  return -1;
}

function isGitGlobalOptionWithSeparateValue(normalizedToken) {
  return normalizedToken === "-c" ||
         normalizedToken === "--config-env" ||
         normalizedToken === "--git-dir" ||
         normalizedToken === "--work-tree" ||
         normalizedToken === "--namespace";
}

function isGitGlobalOptionWithInlineValue(normalizedToken) {
  return normalizedToken.startsWith("-c=") ||
         normalizedToken.startsWith("--config-env=") ||
         normalizedToken.startsWith("--git-dir=") ||
         normalizedToken.startsWith("--work-tree=") ||
         normalizedToken.startsWith("--namespace=");
}

function getGitSubcommandName(tokens, subcommandIndex) {
  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex]));
  const aliasSubcommand = getGitAliasSubcommandName(tokens, subcommandIndex, subcommand);
  return aliasSubcommand || subcommand;
}

function isReviewGatedGitSubcommand(subcommand, tokens = [], subcommandIndex = -1) {
  const normalized = normalizeAgentValue(subcommand);
  if (["commit", "merge", "push", "update-ref"].includes(normalized)) {
    return true;
  }

  if (normalized === "branch") {
    return !isReadOnlyGitBranchCommand(tokens, subcommandIndex);
  }

  if (normalized === "tag") {
    return !isReadOnlyGitTagCommand(tokens, subcommandIndex);
  }

  return false;
}

function getConfiguredGitAliasSubcommand(aliasValue) {
  if (typeof aliasValue !== "string" || aliasValue.trim() === "" || aliasValue.trim().startsWith("!")) {
    return "";
  }

  const aliasTokens = tokenizeCommandLine(aliasValue);
  return aliasTokens.length > 0 ? normalizeAgentValue(stripOuterQuotes(aliasTokens[0])) : "";
}

function getConfiguredGitAliasValue(repoCwd, aliasName) {
  const normalizedAlias = normalizeAgentValue(aliasName);
  if (!repoCwd || !/^[a-z0-9._-]+$/u.test(normalizedAlias)) {
    return "";
  }

  try {
    return execFileSync("git", ["-C", repoCwd, "config", "--get", `alias.${normalizedAlias}`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function hasConfiguredGitReviewLifecycleAlias(command, baseCwd, depth = 0) {
  if (depth > 5) {
    return true;
  }

  for (const segment of splitCommandSegments(command)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const rawTokens = tokenizeCommandLine(stage);
      const gitEnvContext = getGitInlineEnvironmentContext(rawTokens, baseCwd);
      const commandBaseCwd = gitEnvContext.baseCwd || baseCwd;
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(rawTokens));
      if (execution.nestedCommand && hasConfiguredGitReviewLifecycleAlias(execution.nestedCommand, baseCwd, depth + 1)) {
        return true;
      }
      const tokens = execution.tokens;
      if (tokens.length === 0) {
        continue;
      }

      const executable = normalizeExecutableName(tokens[0]);
      if (isShellCommandExecutable(executable) || isPowerShellExecutable(executable)) {
        const nestedCommand = isShellCommandExecutable(executable)
          ? getShellCommandArgument(tokens)
          : getPowerShellNestedCommand(tokens);
        if (nestedCommand && hasConfiguredGitReviewLifecycleAlias(nestedCommand, baseCwd, depth + 1)) {
          return true;
        }
        continue;
      }

      if (!isGitExecutableToken(tokens[0])) {
        continue;
      }
      const subcommandIndex = findGitSubcommandIndex(tokens);
      if (subcommandIndex < 0) {
        continue;
      }
      const rawSubcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex]));
      const gitBaseCwd = getGitGlobalCwdOption(tokens, 0, commandBaseCwd, gitEnvContext) || commandBaseCwd || process.cwd();
      const aliasValue = getConfiguredGitAliasValue(gitBaseCwd, rawSubcommand);
      const aliasSubcommand = getConfiguredGitAliasSubcommand(aliasValue);
      if (isReviewGatedGitSubcommand(aliasSubcommand)) {
        return true;
      }
      if (aliasValue.trim().startsWith("!") && isReviewGatedCommand(aliasValue.trim().slice(1))) {
        return true;
      }
    }
  }

  return false;
}

function getGitAliasSubcommandName(tokens, subcommandIndex, subcommand) {
  const aliasValue = getGitAliasConfigValue(tokens, subcommandIndex, subcommand);
  if (!aliasValue) {
    return "";
  }

  const aliasTokens = tokenizeCommandLine(aliasValue);
  if (aliasTokens.length === 0) {
    return "";
  }

  const delegatedSubcommand = getGitShellAliasDelegatedSubcommand(aliasTokens);
  if (delegatedSubcommand) {
    return delegatedSubcommand;
  }

  return normalizeAgentValue(stripOuterQuotes(aliasTokens[0]));
}

function getGitShellAliasCommand(tokens, subcommandIndex, subcommand) {
  const aliasValue = getGitAliasConfigValue(tokens, subcommandIndex, subcommand);
  const trimmedAliasValue = typeof aliasValue === "string" ? aliasValue.trim() : "";
  if (!trimmedAliasValue.startsWith("!")) {
    return "";
  }

  return trimmedAliasValue.slice(1).trim();
}

function getGitAliasConfigValue(tokens, subcommandIndex, subcommand) {
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

    return aliasMatch[2] || "";
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

function hasPowerShellGitAliasLifecycleCommand(command, reviewOnly, options = {}) {
  const includeFunctionCommands = options.includeFunctionCommands !== false;
  const aliases = new Map();
  const ghAliases = new Map();
  const shellAliases = new Map();

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
        if (aliasDefinition.aliasName) {
          shellAliases.set(aliasDefinition.aliasName, aliasDefinition);
        }
        if (aliasDefinition.aliasName && aliasDefinition.aliasTarget === "git") {
          aliases.set(aliasDefinition.aliasName, aliasDefinition.aliasArgs);
        }
        if (aliasDefinition.aliasName && aliasDefinition.aliasTarget === "gh") {
          ghAliases.set(aliasDefinition.aliasName, aliasDefinition.aliasArgs);
        }
        continue;
      }

      const shellExpansion = expandShellAliasInvocation(tokens, shellAliases);
      if (shellExpansion.unresolved) {
        return true;
      }
      if (shellExpansion.matched) {
        const effectiveTokens = shellExpansion.tokens;
        const effectiveExecutable = normalizeExecutableName(effectiveTokens[0] || "");
        if (effectiveExecutable === "git") {
          const subcommandIndex = findGitSubcommandIndex(effectiveTokens);
          const subcommand = subcommandIndex >= 0
            ? getGitSubcommandName(effectiveTokens, subcommandIndex)
            : "";
          if (reviewOnly
            ? isReviewGatedGitSubcommand(subcommand, effectiveTokens, subcommandIndex)
            : isGitLifecycleSubcommandName(subcommand) || !isReadOnlyGitSubcommand(subcommand, effectiveTokens, subcommandIndex)) {
            return true;
          }
        }
        if (effectiveExecutable === "gh" &&
            (isGhPrMergeTokenCommand(effectiveTokens) ||
             isGhApiMergeCommand(effectiveTokens) ||
             isGhApiRefWriteCommand(effectiveTokens))) {
          return true;
        }
      }

      if (aliases.has(executable)) {
        const aliasArgs = aliases.get(executable) || [];
        const effectiveTokens = [tokens[0], ...aliasArgs, ...tokens.slice(1)];
        const subcommand = normalizeAgentValue(stripOuterQuotes(effectiveTokens[1] || ""));
        if (reviewOnly) {
          if (isReviewGatedGitSubcommand(subcommand, ["git", ...effectiveTokens.slice(1)], 1)) {
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

  if (includeFunctionCommands && hasShellFunctionLifecycleCommand(command, reviewOnly)) {
    return true;
  }
  if (includeFunctionCommands && hasPowerShellFunctionLifecycleCommand(command, reviewOnly)) {
    return true;
  }
  if (includeFunctionCommands && hasAliasFunctionLifecycleCommand(command, reviewOnly, aliases, ghAliases)) {
    return true;
  }

  return false;
}

function getSetAliasDefinition(tokens) {
  let aliasName = "";
  let aliasTarget = "";
  let unsupportedSyntax = false;
  const nameOptionPrefixes = expandPowerShellOptionPrefixes(["-name"]);
  const valueOptionPrefixes = expandPowerShellOptionPrefixes(["-value"]);
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (nameOptionPrefixes.includes(normalizedToken) && index + 1 < tokens.length) {
      if (aliasName) unsupportedSyntax = true;
      aliasName = normalizeAgentValue(stripOuterQuotes(tokens[index + 1]));
      index += 1;
      continue;
    }
    if (valueOptionPrefixes.includes(normalizedToken) && index + 1 < tokens.length) {
      if (aliasTarget) unsupportedSyntax = true;
      aliasTarget = normalizeAgentValue(stripOuterQuotes(tokens[index + 1]));
      index += 1;
      continue;
    }
    const inlineNameOption = nameOptionPrefixes.find((optionName) => normalizedToken.startsWith(optionName + ":"));
    if (inlineNameOption) {
      if (aliasName) unsupportedSyntax = true;
      aliasName = normalizeAgentValue(token.slice(inlineNameOption.length + 1));
      continue;
    }
    const inlineValueOption = valueOptionPrefixes.find((optionName) => normalizedToken.startsWith(optionName + ":"));
    if (inlineValueOption) {
      if (aliasTarget) unsupportedSyntax = true;
      aliasTarget = normalizeAgentValue(token.slice(inlineValueOption.length + 1));
      continue;
    }
    if (normalizedToken.startsWith("-")) {
      unsupportedSyntax = true;
      continue;
    }
    if (!normalizedToken.startsWith("-")) {
      if (!aliasName) {
        aliasName = normalizedToken;
      } else if (!aliasTarget) {
        aliasTarget = normalizedToken;
      } else {
        unsupportedSyntax = true;
      }
    }
  }

  return {
    aliasName,
    aliasTarget,
    canonicalSyntax: Boolean(
      aliasName && aliasTarget && !unsupportedSyntax && tokens.length === 3 &&
      !normalizeAgentValue(stripOuterQuotes(tokens[1] || "")).startsWith("-") &&
      !normalizeAgentValue(stripOuterQuotes(tokens[2] || "")).startsWith("-"),
    ),
  };
}

function getShellAliasDefinition(tokens) {
  const assignment = stripOuterQuotes(tokens[1] || "");
  const match = /^([A-Za-z_][A-Za-z0-9_-]*)=(.+)$/u.exec(assignment);
  if (!match) {
    return { aliasName: "", aliasTarget: "", aliasArgs: [], aliasTokens: [], expandsNext: false };
  }

  const aliasValue = match[2] || "";
  const aliasTokens = unwrapEnvCommandTokens(tokenizeCommandLine(aliasValue));
  const aliasTarget = normalizeAgentValue(getExecutableBasename(aliasTokens[0] || ""));

  return {
    aliasName: normalizeAgentValue(match[1]),
    aliasTarget: aliasTarget.endsWith(".exe") ? aliasTarget.slice(0, -4) : aliasTarget,
    aliasArgs: aliasTokens.slice(1),
    aliasTokens,
    expandsNext: /\s$/u.test(aliasValue),
  };
}

function splitTopLevelPlusExpressions(value) {
  const source = String(value || "");
  const parts = [];
  let current = "";
  let quote = "";
  let escaped = false;
  let depth = 0;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      current += char;
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === quote) {
        quote = "";
      }
      continue;
    }
    if (char === "'" || char === '"' || char === "`") {
      quote = char;
      current += char;
      continue;
    }
    if (char === "(" || char === "[" || char === "{") {
      depth += 1;
      current += char;
      continue;
    }
    if (char === ")" || char === "]" || char === "}") {
      depth = Math.max(0, depth - 1);
      current += char;
      continue;
    }
    if (char === "+" && depth === 0) {
      parts.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  parts.push(current.trim());
  return parts;
}

function evaluateStaticStringExpression(expression, assignments = new Map(), depth = 0) {
  if (depth > 8) {
    return null;
  }
  let source = stripLeadingCallComments(String(expression || "").trim());
  while (source.startsWith("(") && source.endsWith(")")) {
    const body = getBalancedCallBody(source, 0);
    if (body === null || body.length !== source.length - 2) {
      break;
    }
    source = body.trim();
  }
  const literal = getStaticCallStringLiteral(source);
  if (literal !== "" || /^(?:''|""|``)$/u.test(source)) {
    return literal;
  }

  if (/^\$(?:env:comspec|\{env:comspec\})$/iu.test(source) ||
      /^\[(?:System\.)?Environment\]\s*::\s*GetEnvironmentVariable\s*\(\s*["']ComSpec["']\s*\)$/iu.test(source)) {
    return "\0winsmux-comspec";
  }
  const environmentVariableCall = /^\[(?:System\.)?Environment\]\s*::\s*GetEnvironmentVariable\s*\(([\s\S]*)\)$/iu.exec(source);
  if (environmentVariableCall) {
    const nameExpression = splitTopLevelCallArguments(environmentVariableCall[1])[0];
    const resolvedName = evaluateStaticStringExpression(nameExpression, assignments, depth + 1);
    if (normalizeAgentValue(resolvedName) === "comspec") {
      return "\0winsmux-comspec";
    }
  }
  if (/^(?:Get-Item|gi)\s+(?:-(?:Path|LiteralPath)\s+)?Env:\\?ComSpec$/iu.test(source) ||
      /^\(\s*(?:Get-Item|gi)\s+(?:-(?:Path|LiteralPath)\s+)?Env:\\?ComSpec\s*\)\.Value$/iu.test(source)) {
    return "\0winsmux-comspec";
  }

  const variableValue = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))\.Value$/u.exec(source);
  if (variableValue) {
    const name = normalizeAgentValue(variableValue[1] || variableValue[2]);
    return assignments.has(name) ? assignments.get(name) : null;
  }

  const variableName = source.replace(/^\$/u, "");
  if (/^[A-Za-z_][A-Za-z0-9_]*$/u.test(variableName) && assignments.has(normalizeAgentValue(variableName))) {
    return assignments.get(normalizeAgentValue(variableName));
  }

  const plusParts = splitTopLevelPlusExpressions(source);
  if (plusParts.length > 1) {
    const values = plusParts.map((part) => evaluateStaticStringExpression(part, assignments, depth + 1));
    return values.every((value) => value !== null) ? values.join("") : null;
  }

  const arrayJoin = /^\[([\s\S]*)\]\s*\.\s*join\s*\(\s*([\s\S]*)\s*\)$/u.exec(source);
  if (arrayJoin) {
    const separator = evaluateStaticStringExpression(arrayJoin[2], assignments, depth + 1);
    const values = splitTopLevelCallArguments(arrayJoin[1])
      .map((part) => evaluateStaticStringExpression(part, assignments, depth + 1));
    return separator !== null && values.every((value) => value !== null) ? values.join(separator) : null;
  }

  const pythonJoin = /^([\s\S]+?)\.\s*join\s*\(\s*\[([\s\S]*)\]\s*\)$/u.exec(source);
  if (pythonJoin) {
    const separator = evaluateStaticStringExpression(pythonJoin[1], assignments, depth + 1);
    const values = splitTopLevelCallArguments(pythonJoin[2])
      .map((part) => evaluateStaticStringExpression(part, assignments, depth + 1));
    return separator !== null && values.every((value) => value !== null) ? values.join(separator) : null;
  }

  const dotNetConcat = /^\[(?:System\.)?String\]\s*::\s*Concat\s*\(\s*([\s\S]*)\s*\)$/iu.exec(source);
  if (dotNetConcat) {
    const values = splitTopLevelCallArguments(dotNetConcat[1])
      .map((part) => evaluateStaticStringExpression(part, assignments, depth + 1));
    return values.every((value) => value !== null) ? values.join("") : null;
  }

  return null;
}

function getConstantStringAssignments(source, endIndex = String(source || "").length) {
  const text = String(source || "");
  const events = [];
  const seen = new Set();
  const collect = (pattern, nameGroup = 1, expressionGroup = 2) => {
    for (const match of text.matchAll(pattern)) {
      const index = match.index || 0;
      const name = normalizeAgentValue(match[nameGroup]);
      const expression = match[expressionGroup];
      const key = `${index}:${name}:${expression}`;
      if (index < endIndex && name && expression !== undefined && !seen.has(key)) {
        seen.add(key);
        events.push({ index, name, expression });
      }
    }
  };
  collect(/\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu);
  collect(/(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\r\n]+)/gu);
  collect(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))\s*=\s*([^;\r\n]+)/gu, 1, 3);
  for (const match of text.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}\s*=\s*([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    const name = normalizeAgentValue(match[1]);
    const key = `${index}:${name}:${match[2]}`;
    if (index < endIndex && !seen.has(key)) {
      seen.add(key);
      events.push({ index, name, expression: match[2] });
    }
  }
  for (const match of text.matchAll(/\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    const name = normalizeAgentValue(match[1]);
    const key = `${index}:${name}:${match[2]}`;
    if (index < endIndex && !seen.has(key)) {
      seen.add(key);
      events.push({ index, name, expression: match[2] });
    }
  }

  events.sort((left, right) => left.index - right.index);
  const assignments = new Map();
  for (const event of events) {
    const value = evaluateStaticStringExpression(event.expression, assignments);
    if (value === null) {
      assignments.delete(event.name);
    } else {
      assignments.set(event.name, value);
    }
  }
  return assignments;
}

function getLatestAssignmentExpression(source, name, endIndex = String(source || "").length) {
  const text = String(source || "");
  const normalizedName = String(name || "");
  const events = [];
  for (const pattern of [
    /\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu,
    /(?:^|[;\r\n])\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu,
  ]) {
    for (const match of text.matchAll(pattern)) {
      if ((match.index || 0) < endIndex && match[1] === normalizedName) {
        events.push({ index: match.index || 0, expression: match[2].trim() });
      }
    }
  }
  events.sort((left, right) => left.index - right.index);
  return events.at(-1)?.expression || "";
}

function getLatestScopedAssignmentEvent(source, name, endIndex, scopes, language = "javascript") {
  const text = String(source || "");
  const target = String(name || "");
  const events = [];
  const collect = (pattern, declared) => {
    for (const match of text.matchAll(pattern)) {
      const index = match.index || 0;
      if (index < endIndex && match[1] === target) {
        events.push({ index, expression: match[2].trim(), declared });
      }
    }
  };
  collect(/\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu, true);
  collect(/(?:^|[;{\r\n])\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu, false);
  events.sort((left, right) => left.index - right.index);

  const scoped = [];
  for (const event of events) {
    let scope = scopes.scopeAt(event.index);
    if (!event.declared && language === "javascript") {
      const existing = scopes.chainAt(event.index).find((candidateScope) =>
        scoped.some((candidate) => candidate.scope === candidateScope && candidate.index < event.index));
      if (existing !== undefined) {
        scope = existing;
      }
    }
    scoped.push({ ...event, scope });
  }
  for (const scope of scopes.chainAt(endIndex)) {
    const event = scoped
      .filter((candidate) => candidate.scope === scope && candidate.index < endIndex)
      .sort((left, right) => left.index - right.index)
      .at(-1);
    if (event) {
      return event;
    }
  }
  return null;
}

function getLatestScopedPowerShellAssignmentEvent(source, name, endIndex, scopes) {
  const events = [];
  const pattern = /\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))\s*=\s*([^;\r\n]+)/gu;
  for (const match of String(source || "").matchAll(pattern)) {
    const index = match.index || 0;
    if (index < endIndex && normalizeAgentValue(match[1] || match[2]) === normalizeAgentValue(name)) {
      events.push({ index, scope: scopes.scopeAt(index), expression: match[3].trim() });
    }
  }
  for (const scope of scopes.chainAt(endIndex)) {
    const event = events
      .filter((candidate) => candidate.scope === scope)
      .sort((left, right) => left.index - right.index)
      .at(-1);
    if (event) {
      return event;
    }
  }
  return null;
}

function hasContainerMutationBetween(source, name, startIndex, endIndex) {
  const text = String(source || "");
  const body = text.slice(Math.max(0, startIndex), Math.max(0, endIndex));
  const aliases = new Set([String(name || "")]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const match of body.matchAll(/\b(?:const|let|var)?\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([A-Za-z_$][A-Za-z0-9_$]*)\b/gu)) {
      if (aliases.has(match[2]) && !aliases.has(match[1])) {
        aliases.add(match[1]);
        changed = true;
      }
    }
  }
  try {
    const ast = acorn.parse(text, { ecmaVersion: "latest", sourceType: "script", allowAwaitOutsideFunction: true });
    const rootIdentifier = (node) => {
      let current = node;
      while (current?.type === "MemberExpression") current = current.object;
      return current?.type === "Identifier" ? current.name : null;
    };
    let hasMutation = false;
    walkJavaScriptAst(ast, (node) => {
      if (hasMutation || typeof node.start !== "number" || node.start < startIndex || node.start >= endIndex) return;
      if (node.type === "AssignmentExpression" && aliases.has(rootIdentifier(node.left))) {
        hasMutation = true;
        return;
      }
      if (node.type === "UpdateExpression" && aliases.has(rootIdentifier(node.argument))) {
        hasMutation = true;
        return;
      }
      if (node.type === "UnaryExpression" && node.operator === "delete" && aliases.has(rootIdentifier(node.argument))) {
        hasMutation = true;
        return;
      }
      if (node.type !== "CallExpression") return;
      if (node.callee?.end === endIndex) return;
      if (node.callee?.type === "MemberExpression" && aliases.has(rootIdentifier(node.callee))) {
        hasMutation = true;
        return;
      }
      if ((node.arguments || []).some((argument) => {
        const value = argument?.type === "SpreadElement" ? argument.argument : argument;
        return value?.type === "Identifier" && aliases.has(value.name);
      })) hasMutation = true;
    });
    if (hasMutation) return true;
  } catch (_) {
    // Non-JavaScript callers retain the conservative text fallback below.
  }
  return [...aliases].some((candidate) => {
    const alias = escapeRegex(candidate);
    return new RegExp(`\\b${alias}\\s*\\[[^\\]]+\\]\\s*=`, "u").test(body) ||
      new RegExp(`\\b${alias}\\s*\\.\\s*[A-Za-z_$][A-Za-z0-9_$]*\\s*(?:=|\\+=|-=|\\*=|/=|%=|\\+\\+|--)`, "u").test(body) ||
      new RegExp(`\\b(?:delete|del)\\s+${alias}\\s*\\[`, "u").test(body) ||
      new RegExp(`\\b${alias}\\s*\\.[A-Za-z_$][A-Za-z0-9_$]*\\s*\\(`, "u").test(body) ||
      new RegExp(`\\b(?:Object\\s*\\.\\s*assign|Reflect\\s*\\.\\s*set)\\s*\\(\\s*${alias}(?:\\s*,|\\s*\\))`, "u").test(body) ||
      new RegExp(`\\b[A-Za-z_$][A-Za-z0-9_$]*(?:(?:\\s*\\.\\s*[A-Za-z_$][A-Za-z0-9_$]*)|(?:\\s*\\[[^\\]]+\\]))*\\s*\\([^)]*\\b${alias}\\b`, "u").test(body);
  });
}

function recordPositionState(history, name, value, index) {
  const key = String(name || "");
  if (!key) {
    return;
  }
  if (!history.has(key)) {
    history.set(key, []);
  }
  history.get(key).push({ index, value });
  history.get(key).sort((left, right) => left.index - right.index);
}

function getPositionState(history, name, index) {
  const entries = history.get(String(name || "")) || [];
  let state = null;
  for (const entry of entries) {
    if (entry.index > index) {
      break;
    }
    state = entry.value;
  }
  return state;
}

function findBalancedBraceEnd(source, openIndex) {
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = openIndex; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === quote) {
        quote = "";
      }
      continue;
    }
    if (char === "'" || char === '"' || char === "`") {
      quote = char;
      continue;
    }
    if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }
  return -1;
}

function buildFunctionScopeIndex(source) {
  const text = String(source || "");
  const ranges = [];
  const rangeStarts = new Set();
  for (const pattern of [
    /\bfunction\b[^{};]*\{/gu,
    /=>\s*\{/gu,
    /\b(?:if|for|while|switch|try|catch|finally|do)\b[^{};]*\{/gu,
    /(?:^|;)\s*\{/gu,
  ]) {
    for (const match of text.matchAll(pattern)) {
      const start = (match.index || 0) + match[0].lastIndexOf("{");
      rangeStarts.add(start);
    }
  }
  for (const start of [...rangeStarts].sort((left, right) => left - right)) {
    const end = findBalancedBraceEnd(text, start);
    if (end > start) {
      ranges.push({ id: start, start, end, parent: -1 });
    }
  }
  const lines = text.split(/\r?\n/u);
  let offset = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    const definition = /^(\s*)(?:async\s+)?def\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)\s*:/u.exec(line);
    if (definition) {
      const indent = definition[1].replace(/\t/gu, "    ").length;
      let endOffset = offset + line.length;
      let cursorOffset = endOffset + 1;
      for (let cursor = lineIndex + 1; cursor < lines.length; cursor += 1) {
        const candidate = lines[cursor];
        const trimmed = candidate.trim();
        const candidateIndent = candidate.match(/^\s*/u)[0].replace(/\t/gu, "    ").length;
        if (trimmed && candidateIndent <= indent) {
          break;
        }
        endOffset = cursorOffset + candidate.length;
        cursorOffset += candidate.length + 1;
      }
      ranges.push({ id: offset, start: offset, end: endOffset, parent: -1 });
    }
    offset += line.length + 1;
  }
  ranges.sort((left, right) => left.start - right.start || right.end - left.end);
  for (const range of ranges) {
    const parent = ranges
      .filter((candidate) => candidate.id !== range.id && candidate.start < range.start && candidate.end >= range.end)
      .sort((left, right) => right.start - left.start)[0];
    range.parent = parent?.id ?? -1;
  }
  const byId = new Map(ranges.map((range) => [range.id, range]));
  const scopeAt = (index) => ranges
    .filter((range) => range.start <= index && index <= range.end)
    .sort((left, right) => right.start - left.start)[0]?.id ?? -1;
  const chainAt = (index) => {
    const chain = [];
    let scope = scopeAt(index);
    while (scope !== -1) {
      chain.push(scope);
      scope = byId.get(scope)?.parent ?? -1;
    }
    chain.push(-1);
    return chain;
  };
  return { scopeAt, chainAt };
}

function recordScopedPositionState(history, name, value, index, scope) {
  recordPositionState(history, `${scope}:${name}`, value, index);
}

function getScopedPositionState(history, name, index, scopes) {
  for (const scope of scopes.chainAt(index)) {
    const key = `${scope}:${name}`;
    if (history.has(key)) {
      return getPositionState(history, key, index);
    }
  }
  return null;
}

function getExistingBindingScope(histories, name, index, scopes) {
  for (const scope of scopes.chainAt(index)) {
    if (histories.some((history) => history.has(`${scope}:${name}`))) {
      return scope;
    }
  }
  return scopes.scopeAt(index);
}

function evaluateScopedStaticStringExpression(expression, source, evaluationIndex, scopes, language = "javascript") {
  const assignments = new Map();
  const resolving = new Set();
  const populate = (candidate, index, depth = 0) => {
    if (depth > 8) {
      return;
    }
    for (const match of String(candidate || "").matchAll(/\b([A-Za-z_$][A-Za-z0-9_$]*)\b/gu)) {
      const name = match[1];
      const key = `${name}:${index}`;
      if (resolving.has(key)) {
        continue;
      }
      const event = getLatestScopedAssignmentEvent(source, name, index, scopes, language);
      if (!event) {
        continue;
      }
      resolving.add(key);
      populate(event.expression, event.index, depth + 1);
      const value = evaluateStaticStringExpression(event.expression, assignments);
      resolving.delete(key);
      if (value !== null) {
        assignments.set(normalizeAgentValue(name), value);
      }
    }
  };
  populate(expression, evaluationIndex);
  return evaluateStaticStringExpression(expression, assignments);
}

function getNodeChildProcessCalls(source) {
  const text = String(source || "");
  const supportedMethods = new Map([
    ["exec", "exec"],
    ["execsync", "execSync"],
    ["execfile", "execFile"],
    ["execfilesync", "execFileSync"],
    ["spawn", "spawn"],
    ["spawnsync", "spawnSync"],
  ]);
  const calls = [];
  const seen = new Set();
  const scopes = buildFunctionScopeIndex(text);
  const objectHistory = new Map();
  const methodHistory = new Map();
  const propertyHistory = new Map();
  const objectAliases = new Set();
  const methodAliases = new Set();
  const recordObject = (alias, active, index, scope = scopes.scopeAt(index)) => {
    objectAliases.add(alias);
    recordScopedPositionState(objectHistory, alias, active, index, scope);
    for (const method of supportedMethods.values()) {
      recordScopedPositionState(propertyHistory, `${alias}.${method}`, "", index, scope);
    }
  };
  const isDirectChildProcessObject = (expression) => {
    const candidate = String(expression || "").trim();
    return /^(?:await\s+)?(?:require|import)\(\s*["'`](?:node:)?child_process["'`]\s*\)$/u.test(candidate) ||
      /^Object\.assign\s*\(\s*\{\s*\}\s*,\s*(?:require|import)\(\s*["'`](?:node:)?child_process["'`]\s*\)\s*\)$/u.test(candidate);
  };
  const isChildProcessObjectAt = (expression, index) => {
    const candidate = String(expression || "").trim();
    return isDirectChildProcessObject(candidate) ||
      (/^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(candidate) && getScopedPositionState(objectHistory, candidate, index, scopes) === true);
  };
  for (const match of text.matchAll(/\bimport\s+\*\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+from\s*["'`](?:node:)?child_process["'`]/gu)) {
    recordObject(match[1], true, match.index || 0);
  }
  for (const match of text.matchAll(/\bimport\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+from\s*["'`](?:node:)?child_process["'`]/gu)) {
    recordObject(match[1], true, match.index || 0);
  }

  const recordMethod = (alias, method, index, scope = scopes.scopeAt(index)) => {
    methodAliases.add(alias);
    recordScopedPositionState(methodHistory, alias, method || "", index, scope);
  };
  const addBindingList = (body, separator, index = 0, active = true) => {
    for (const rawBinding of String(body || "").split(",")) {
      const binding = rawBinding.trim();
      const pattern = separator === "as"
        ? /^(exec|execSync|execFile|execFileSync|spawn|spawnSync)\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)$/u
        : /^(exec|execSync|execFile|execFileSync|spawn|spawnSync)(?:\s*:\s*([A-Za-z_$][A-Za-z0-9_$]*))?$/u;
      const match = pattern.exec(binding);
      if (match) {
        recordMethod(match[2] || match[1], active ? match[1] : "", index);
      }
    }
  };
  for (const match of text.matchAll(/\bimport\s*\{([^}]*)\}\s*from\s*["'`](?:node:)?child_process["'`]/gu)) {
    addBindingList(match[1], "as", match.index || 0);
  }

  const assignmentEvents = [];
  const assignmentKeys = new Set();
  const collectAssignments = (pattern, declared) => {
    for (const match of text.matchAll(pattern)) {
      const event = { index: match.index || 0, alias: match[1], expression: match[2].trim(), declared };
      const key = `${event.index}:${event.alias}:${event.expression}`;
      if (!assignmentKeys.has(key)) {
        assignmentKeys.add(key);
        assignmentEvents.push(event);
      }
    }
  };
  collectAssignments(/\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu, true);
  collectAssignments(/(?:^|[;{\r\n])\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu, false);
  assignmentEvents.sort((left, right) => left.index - right.index);
  for (const event of assignmentEvents) {
    const { alias, index } = event;
    const expression = event.expression.startsWith("{")
      ? event.expression
      : event.expression.replace(/\}\s*$/u, "");
    const assignmentScope = event.declared
      ? scopes.scopeAt(index)
      : getExistingBindingScope([objectHistory, methodHistory], alias, index, scopes);
    recordObject(alias, isChildProcessObjectAt(expression, index), index, assignmentScope);
    let method = "";
    const directMember = /^([A-Za-z_$][A-Za-z0-9_$]*|require\(\s*["'`](?:node:)?child_process["'`]\s*\))\s*(?:\?\.|\.)\s*([A-Za-z_$][A-Za-z0-9_$]*)(?:\.bind\s*\([^)]*\))?$/u.exec(expression);
    if (directMember && isChildProcessObjectAt(directMember[1], index)) {
      method = supportedMethods.get(normalizeAgentValue(directMember[2])) || "";
    }
    const computedMember = /^([A-Za-z_$][A-Za-z0-9_$]*|require\(\s*["'`](?:node:)?child_process["'`]\s*\))\s*(?:\?\.\s*)?\[([\s\S]+)\](?:\.bind\s*\([^)]*\))?$/u.exec(expression);
    if (!method && computedMember && isChildProcessObjectAt(computedMember[1], index)) {
      const computedName = evaluateStaticStringExpression(computedMember[2], getConstantStringAssignments(text, index));
      method = computedName === null ? "unknown" : supportedMethods.get(normalizeAgentValue(computedName)) || "";
    }
    if (!method && /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(expression)) {
      method = getScopedPositionState(methodHistory, expression, index, scopes) || "";
    }
    recordMethod(alias, method, index, assignmentScope);
    const objectLiteral = /^\{([\s\S]*)\}$/u.exec(expression);
    if (objectLiteral) {
      for (const entry of splitTopLevelCallArguments(objectLiteral[1])) {
        const property = /^(?:([A-Za-z_$][A-Za-z0-9_$]*)|["']([^"']+)["']|\[([\s\S]+)\])\s*:\s*([\s\S]+)$/u.exec(entry.trim());
        if (!property) {
          continue;
        }
        const propertyName = property[1] || property[2] ||
          evaluateScopedStaticStringExpression(property[3], text, index, scopes, "javascript");
        if (!propertyName) {
          continue;
        }
        const member = /^(?:require\(\s*["'`](?:node:)?child_process["'`]\s*\)|([A-Za-z_$][A-Za-z0-9_$]*))\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)$/u.exec(property[4].trim());
        const propertyMethod = member && (!member[1] || isChildProcessObjectAt(member[1], index))
          ? supportedMethods.get(normalizeAgentValue(member[2])) || ""
          : "";
        recordScopedPositionState(propertyHistory, `${alias}.${propertyName}`, propertyMethod, index, assignmentScope);
      }
    }
  }

  const destructuringEvents = [];
  for (const pattern of [
    /\b(?:const|let|var)\s*\{([^}]*)\}\s*=\s*([^;\r\n]+)/gu,
    /(?:^|[;\r\n])\s*\(\s*\{([^}]*)\}\s*=\s*([^;\r\n]+)\s*\)(?=\s*(?:;|$))/gu,
  ]) {
    for (const match of text.matchAll(pattern)) {
      destructuringEvents.push({ index: match.index || 0, body: match[1], expression: match[2].trim() });
    }
  }
  destructuringEvents.sort((left, right) => left.index - right.index);
  for (const event of destructuringEvents) {
    addBindingList(event.body, "colon", event.index, isChildProcessObjectAt(event.expression, event.index));
  }

  for (const match of text.matchAll(/(?:^|[;\r\n])\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*(exec|execSync|execFile|execFileSync|spawn|spawnSync)\s*=\s*([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    const property = `${match[1]}.${match[2]}`;
    const expression = match[3].trim();
    let method = "";
    const directMember = /^(?:require\(\s*["'`](?:node:)?child_process["'`]\s*\)|([A-Za-z_$][A-Za-z0-9_$]*))\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)$/u.exec(expression);
    if (directMember && (!directMember[1] || isChildProcessObjectAt(directMember[1], index))) {
      method = supportedMethods.get(normalizeAgentValue(directMember[2])) || "";
    } else if (/^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(expression)) {
      method = getScopedPositionState(methodHistory, expression, index, scopes) || "";
    }
    recordScopedPositionState(propertyHistory, property, method, index, scopes.scopeAt(index));
  }
  for (const match of text.matchAll(/(?:^|[;\r\n])\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\[([^\]]+)\]\s*=\s*([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    const propertyName = evaluateScopedStaticStringExpression(match[2], text, index, scopes, "javascript");
    if (!propertyName) {
      continue;
    }
    const expression = match[3].trim();
    const directMember = /^(?:require\(\s*["'`](?:node:)?child_process["'`]\s*\)|([A-Za-z_$][A-Za-z0-9_$]*))\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)$/u.exec(expression);
    const method = directMember && (!directMember[1] || isChildProcessObjectAt(directMember[1], index))
      ? supportedMethods.get(normalizeAgentValue(directMember[2])) || ""
      : "";
    recordScopedPositionState(propertyHistory, `${match[1]}.${propertyName}`, method, index, scopes.scopeAt(index));
  }

  for (const match of text.matchAll(/(?:^|[;\r\n])\s*\[\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*,\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\]\s*=\s*\[\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*,\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\]/gu)) {
    const index = match.index || 0;
    const left = [match[1], match[2]];
    const right = [match[3], match[4]].map((name) => getScopedPositionState(methodHistory, name, index, scopes) || "");
    for (let offset = 0; offset < left.length; offset += 1) {
      const scope = getExistingBindingScope([methodHistory], left[offset], index, scopes);
      recordMethod(left[offset], right[offset], index, scope);
    }
  }

  const addCall = (method, openIndex) => {
    const normalizedMethod = normalizeAgentValue(method) === "unknown"
      ? "unknown"
      : supportedMethods.get(normalizeAgentValue(method));
    if (!normalizedMethod) {
      return;
    }
    const key = `${openIndex}:${normalizedMethod.toLowerCase()}`;
    if (!seen.has(key)) {
      seen.add(key);
      calls.push({ method: normalizedMethod, openIndex });
    }
  };
  for (const match of text.matchAll(/\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:\?\.|\.)\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/gu)) {
    const callIndex = match.index || 0;
    const propertyMethod = getScopedPositionState(propertyHistory, `${match[1]}.${match[2]}`, callIndex, scopes);
    if (propertyMethod) {
      addCall(propertyMethod, callIndex + match[0].lastIndexOf("("));
    } else if (getScopedPositionState(objectHistory, match[1], callIndex, scopes) === true) {
      addCall(match[2], callIndex + match[0].lastIndexOf("("));
    }
  }
  for (const match of text.matchAll(/\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:\?\.\s*)?\[([^\]]+)\]\s*\(/gu)) {
    const callIndex = match.index || 0;
    if (getScopedPositionState(objectHistory, match[1], callIndex, scopes) === true) {
      const method = evaluateStaticStringExpression(match[2], getConstantStringAssignments(text, callIndex));
      addCall(method === null ? "unknown" : method, callIndex + match[0].lastIndexOf("("));
    }
  }
  for (const match of text.matchAll(/require\(\s*["'`](?:node:)?child_process["'`]\s*\)\s*(?:\?\.|\.)\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/gu)) {
    addCall(match[1], (match.index || 0) + match[0].lastIndexOf("("));
  }
  for (const match of text.matchAll(/require\(\s*["'`](?:node:)?child_process["'`]\s*\)\s*(?:\?\.\s*)?\[([^\]]+)\]\s*\(/gu)) {
    const callIndex = match.index || 0;
    const method = evaluateStaticStringExpression(match[1], getConstantStringAssignments(text, callIndex));
    addCall(method === null ? "unknown" : method, callIndex + match[0].lastIndexOf("("));
  }
  for (const alias of methodAliases) {
    const pattern = new RegExp(`(?<![.$A-Za-z0-9_])${escapeRegex(alias)}\\s*\\(`, "gu");
    for (const match of text.matchAll(pattern)) {
      const callIndex = match.index || 0;
      const method = getScopedPositionState(methodHistory, alias, callIndex, scopes);
      if (method) {
        addCall(method, callIndex + match[0].lastIndexOf("("));
      }
    }
  }
  return calls;
}

function getPythonSubprocessCalls(source) {
  const text = String(source || "");
  const supportedMethods = new Map([
    ["run", "run"],
    ["call", "call"],
    ["popen", "Popen"],
    ["check_call", "check_call"],
    ["check_output", "check_output"],
  ]);
  const calls = [];
  const seen = new Set();
  const scopes = buildFunctionScopeIndex(text);
  const objectHistory = new Map();
  const methodHistory = new Map();
  const objectAliases = new Set(["subprocess"]);
  const methodAliases = new Set();
  const recordObject = (alias, active, index, scope = scopes.scopeAt(index)) => {
    objectAliases.add(alias);
    recordScopedPositionState(objectHistory, alias, active, index, scope);
  };
  const recordMethod = (alias, method, index, scope = scopes.scopeAt(index)) => {
    methodAliases.add(alias);
    recordScopedPositionState(methodHistory, alias, method || "", index, scope);
  };
  recordObject("subprocess", true, -1, -1);
  for (const match of text.matchAll(/\bimport\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^subprocess(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (binding) {
        recordObject(binding[1] || "subprocess", true, match.index || 0);
      }
    }
  }
  for (const match of text.matchAll(/\bfrom\s+subprocess\s+import\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (!binding) {
        continue;
      }
      const method = supportedMethods.get(normalizeAgentValue(binding[1]));
      if (method) {
        recordMethod(binding[2] || binding[1], method, match.index || 0);
      }
    }
  }
  const assignmentEvents = [];
  const seenAssignments = new Set();
  for (const pattern of [
    /(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\r\n]+)/gu,
  ]) {
    for (const match of text.matchAll(pattern)) {
      const event = { index: match.index || 0, alias: match[1], expression: match[2].trim() };
      const key = `${event.index}:${event.alias}:${event.expression}`;
      if (!seenAssignments.has(key)) {
        seenAssignments.add(key);
        assignmentEvents.push(event);
      }
    }
  }
  assignmentEvents.sort((left, right) => left.index - right.index);
  for (const event of assignmentEvents) {
    const { alias, expression, index } = event;
    const objectValue = /^[A-Za-z_][A-Za-z0-9_]*$/u.test(expression) &&
      getScopedPositionState(objectHistory, expression, index, scopes) === true;
    recordObject(alias, objectValue, index);
    let method = "";
    const directMember = /^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$/u.exec(expression);
    if (directMember && getScopedPositionState(objectHistory, directMember[1], index, scopes) === true) {
      method = supportedMethods.get(normalizeAgentValue(directMember[2])) || "";
    }
    const getattrMember = /^getattr\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([\s\S]+)\)$/u.exec(expression);
    if (!method && getattrMember && getScopedPositionState(objectHistory, getattrMember[1], index, scopes) === true) {
      const computedName = evaluateStaticStringExpression(getattrMember[2], getConstantStringAssignments(text, index));
      method = computedName === null ? "unknown" : supportedMethods.get(normalizeAgentValue(computedName)) || "";
    }
    if (!method && /^[A-Za-z_][A-Za-z0-9_]*$/u.test(expression)) {
      method = getScopedPositionState(methodHistory, expression, index, scopes) || "";
    }
    recordMethod(alias, method, index);
  }

  for (const match of text.matchAll(/(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*([^;\r\n]+)/gu)) {
    const aliases = match[1].split(",").map((value) => value.trim());
    const expressions = splitTopLevelCallArguments(match[2]);
    const assignmentIndex = match.index || 0;
    const resolved = expressions.map((rawExpression) => {
      const expression = rawExpression.trim();
      const member = /^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$/u.exec(expression);
      const method = member && getScopedPositionState(objectHistory, member[1], assignmentIndex, scopes) === true
        ? supportedMethods.get(normalizeAgentValue(member[2])) || ""
        : getScopedPositionState(methodHistory, expression, assignmentIndex, scopes) || "";
      const object = getScopedPositionState(objectHistory, expression, assignmentIndex, scopes) === true;
      return { method, object };
    });
    for (let offset = 0; offset < Math.min(aliases.length, resolved.length); offset += 1) {
      recordMethod(aliases[offset], resolved[offset].method, assignmentIndex);
      recordObject(aliases[offset], resolved[offset].object, assignmentIndex);
    }
  }

  const addCall = (method, openIndex) => {
    const normalizedMethod = normalizeAgentValue(method) === "unknown"
      ? "unknown"
      : supportedMethods.get(normalizeAgentValue(method));
    if (!normalizedMethod) {
      return;
    }
    const key = `${openIndex}:${normalizedMethod.toLowerCase()}`;
    if (!seen.has(key)) {
      seen.add(key);
      calls.push({ method: normalizedMethod, openIndex });
    }
  };
  for (const objectAlias of objectAliases) {
    const escapedAlias = escapeRegex(objectAlias);
    for (const match of text.matchAll(new RegExp(`\\b${escapedAlias}\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\(`, "gu"))) {
      if (getScopedPositionState(objectHistory, objectAlias, match.index || 0, scopes) !== true) {
        continue;
      }
      addCall(match[1], (match.index || 0) + match[0].lastIndexOf("("));
    }
    for (const match of text.matchAll(new RegExp(`\\bgetattr\\s*\\(\\s*${escapedAlias}\\s*,\\s*([^,)]+)\\s*\\)\\s*\\(`, "gu"))) {
      if (getScopedPositionState(objectHistory, objectAlias, match.index || 0, scopes) !== true) {
        continue;
      }
      const method = evaluateStaticStringExpression(match[1], getConstantStringAssignments(text, match.index || 0));
      addCall(method === null ? "unknown" : method, (match.index || 0) + match[0].lastIndexOf("("));
    }
  }
  for (const alias of methodAliases) {
    const pattern = new RegExp(`\\b${escapeRegex(alias)}\\s*\\(`, "gu");
    for (const match of text.matchAll(pattern)) {
      const method = getScopedPositionState(methodHistory, alias, match.index || 0, scopes);
      if (method) {
        addCall(method, (match.index || 0) + match[0].lastIndexOf("("));
      }
    }
  }
  return calls;
}

function getPythonOsSystemCalls(source) {
  const text = String(source || "");
  const supportedMethods = new Set(["system", "popen"]);
  const scopes = buildFunctionScopeIndex(text);
  const objectHistory = new Map();
  const methodHistory = new Map();
  const objectAliases = new Set(["os"]);
  const methodAliases = new Set();
  const recordObject = (alias, active, index, scope = scopes.scopeAt(index)) => {
    objectAliases.add(alias);
    recordScopedPositionState(objectHistory, alias, active, index, scope);
  };
  const recordMethod = (alias, method, index, scope = scopes.scopeAt(index)) => {
    methodAliases.add(alias);
    recordScopedPositionState(methodHistory, alias, method || "", index, scope);
  };
  recordObject("os", true, -1, -1);
  for (const match of text.matchAll(/\bimport\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^os(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (binding) {
        recordObject(binding[1] || "os", true, match.index || 0);
      }
    }
  }
  for (const match of text.matchAll(/\bfrom\s+os\s+import\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^(system|popen)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (binding) {
        recordMethod(binding[2] || binding[1], binding[1], match.index || 0);
      }
    }
  }
  const assignments = /(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\r\n]+)/gu;
  for (const match of text.matchAll(assignments)) {
    const alias = match[1];
    const expression = match[2].trim();
    const index = match.index || 0;
    recordObject(alias,
      /^[A-Za-z_][A-Za-z0-9_]*$/u.test(expression) && getScopedPositionState(objectHistory, expression, index, scopes) === true,
      index);
    const member = /^([A-Za-z_][A-Za-z0-9_]*)\.(system|popen)$/u.exec(expression);
    const getattr = /^getattr\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*["'](system|popen)["']\s*\)$/u.exec(expression);
    const method = ((member && getScopedPositionState(objectHistory, member[1], index, scopes) === true) ||
      (getattr && getScopedPositionState(objectHistory, getattr[1], index, scopes) === true))
      ? (member?.[2] || getattr?.[2] || "")
      : getScopedPositionState(methodHistory, expression, index, scopes) || "";
    recordMethod(alias, method, index);
  }

  for (const match of text.matchAll(/(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*([^;\r\n]+)/gu)) {
    const aliases = match[1].split(",").map((value) => value.trim());
    const expressions = splitTopLevelCallArguments(match[2]);
    const index = match.index || 0;
    const resolved = expressions.map((rawExpression) => {
      const expression = rawExpression.trim();
      const object = /^[A-Za-z_][A-Za-z0-9_]*$/u.test(expression) &&
        getScopedPositionState(objectHistory, expression, index, scopes) === true;
      const member = /^([A-Za-z_][A-Za-z0-9_]*)\.(system|popen)$/u.exec(expression);
      const getattr = /^getattr\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*["'](system|popen)["']\s*\)$/u.exec(expression);
      const method = ((member && getScopedPositionState(objectHistory, member[1], index, scopes) === true) ||
        (getattr && getScopedPositionState(objectHistory, getattr[1], index, scopes) === true))
        ? (member?.[2] || getattr?.[2] || "")
        : getScopedPositionState(methodHistory, expression, index, scopes) || "";
      return { object, method };
    });
    for (let offset = 0; offset < Math.min(aliases.length, resolved.length); offset += 1) {
      recordObject(aliases[offset], resolved[offset].object, index);
      recordMethod(aliases[offset], resolved[offset].method, index);
    }
  }

  const calls = [];
  const seen = new Set();
  const addCall = (method, openIndex) => {
    const normalizedMethod = normalizeAgentValue(method);
    if (supportedMethods.has(normalizedMethod) && !seen.has(`${openIndex}:${normalizedMethod}`)) {
      seen.add(`${openIndex}:${normalizedMethod}`);
      calls.push({ method: normalizedMethod, openIndex });
    }
  };
  for (const alias of objectAliases) {
    for (const match of text.matchAll(new RegExp(`\\b${escapeRegex(alias)}\\.(system|popen)\\s*\\(`, "gu"))) {
      if (getScopedPositionState(objectHistory, alias, match.index || 0, scopes) === true) {
        addCall(match[1], (match.index || 0) + match[0].lastIndexOf("("));
      }
    }
  }
  for (const alias of methodAliases) {
    for (const match of text.matchAll(new RegExp(`\\b${escapeRegex(alias)}\\s*\\(`, "gu"))) {
      if (getScopedPositionState(methodHistory, alias, match.index || 0, scopes) === "system") {
        addCall("system", (match.index || 0) + match[0].lastIndexOf("("));
      } else if (getScopedPositionState(methodHistory, alias, match.index || 0, scopes) === "popen") {
        addCall("popen", (match.index || 0) + match[0].lastIndexOf("("));
      }
    }
  }
  return calls;
}

function getPythonProcessCalls(source) {
  return [...getPythonSubprocessCalls(source), ...getPythonOsSystemCalls(source)]
    .sort((left, right) => left.openIndex - right.openIndex);
}

function hasDynamicInterpreterGitSubcommand(segment) {
  const source = String(segment || "");
  const hasProtectedGitHint = /["']git(?:\.exe)?["'][\s\S]{0,512}["'](?:commit|merge|push|update-ref|branch|tag)["']/iu.test(source) ||
    /["'`]git(?:\.exe)?\s+(?:commit|merge|push|update-ref)\b/iu.test(source);
  const hasUnsupportedNodeBoundary = /["'](?:node:)?child_process["']/u.test(source) && (
    /\b(?:if|for|while|switch|try|catch|finally|do)\b[^{};]*\{[\s\S]{0,512}\b(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*=/u.test(source) ||
    /\bObject\.assign\s*\([^)]*["'](?:node:)?child_process["']/u.test(source) ||
    /(?:^|[;\r\n])\s*\[[^\]]+\]\s*=\s*\[[^\]]+\]/u.test(source) ||
    /\b[A-Za-z_$][A-Za-z0-9_$]*\s*\[[^\]]+\]\s*=\s*(?:require\(\s*["'](?:node:)?child_process["']\s*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*\./u.test(source)
  );
  if (hasProtectedGitHint && hasUnsupportedNodeBoundary) {
    return true;
  }
  for (const call of getNodeChildProcessCalls(source).filter((candidate) => /^(?:exec|execsync)$/iu.test(candidate.method))) {
    const openIndex = call.openIndex;
    const callBody = getBalancedCallBody(source, openIndex);
    if (callBody === null) {
      return /(?:['"`](?:git|gh)(?:\.exe)?\b|['"]g['"]\s*\+\s*['"](?:it|h))/iu.test(source.slice(openIndex, openIndex + 512));
    }
    const commandExpression = stripLeadingCallComments(splitTopLevelCallArguments(callBody)[0]);
    if (evaluateStaticStringExpression(commandExpression, getConstantStringAssignments(source, openIndex)) === null &&
        /(?:['"`](?:git|gh)(?:\.exe)?\b|['"]g['"]\s*\+\s*['"](?:it|h))/iu.test(commandExpression)) {
      return true;
    }
  }
  for (const call of getNodeChildProcessCalls(source).filter((candidate) => /^(?:execfile|execfilesync|spawn|spawnsync|unknown)$/iu.test(candidate.method))) {
    const openIndex = call.openIndex;
    const callBody = getBalancedCallBody(source, openIndex);
    if (callBody === null) {
      return /['"](?:git|gh)(?:\.exe)?['"]/iu.test(source.slice(openIndex, openIndex + 512));
    }
    const args = splitTopLevelCallArguments(callBody);
    const assignments = getConstantStringAssignments(source, openIndex);
    const resolvedTool = evaluateStaticStringExpression(args[0], assignments);
    const tool = normalizeExecutableName(resolvedTool || "");
    const argumentExpressions = getArrayLiteralElements(args[1]);
    if (resolvedTool === null && argumentExpressions &&
        /\b(?:commit|merge|push|update-ref|branch|tag|pr|api)\b/iu.test(args[1] || "")) {
      return true;
    }
    if (tool !== "git" && tool !== "gh") {
      continue;
    }
    if (normalizeAgentValue(call.method) === "unknown" && argumentExpressions) {
      const resolvedArguments = argumentExpressions.map((expression) => evaluateStaticStringExpression(expression, assignments));
      if (resolvedArguments.every((value) => value !== null) &&
          isReviewGatedCommand([tool, ...resolvedArguments].join(" "))) {
        return true;
      }
    }
    const resolvedFirstArgument = argumentExpressions
      ? evaluateStaticStringExpression(argumentExpressions[0], assignments)
      : null;
    if (tool === "git" &&
        resolvedFirstArgument !== null &&
        !/^\s*["'][^"']+["']\s*$/u.test(String(argumentExpressions[0] || ""))) {
      return true;
    }
    if (argumentExpressions === null ||
        (tool === "git" && resolvedFirstArgument === null) ||
        (tool === "gh" && hasUnresolvedGhLifecycleExpressions(argumentExpressions))) {
      return true;
    }
  }

  for (const call of getPythonProcessCalls(source)) {
    const openIndex = call.openIndex;
    const callBody = getBalancedCallBody(source, openIndex);
    if (callBody === null) {
      return /[\[(]\s*['"](?:git|gh)(?:\.exe)?['"]/iu.test(source.slice(openIndex, openIndex + 512));
    }
    const args = splitTopLevelCallArguments(callBody);
    const commandArg = stripLeadingCallComments(args[0]);
    const assignments = getConstantStringAssignments(source, openIndex);
    if (normalizeAgentValue(call.method) === "system") {
      const resolvedCommand = evaluateStaticStringExpression(commandArg, assignments);
      if ((resolvedCommand === null && /['"](?:git|gh)(?:\.exe)?\b/iu.test(commandArg)) ||
          (resolvedCommand !== null &&
           normalizeExecutableName(tokenizeCommandLine(resolvedCommand)[0] || "") !== "" &&
           ["git", "gh"].includes(normalizeExecutableName(tokenizeCommandLine(resolvedCommand)[0] || "")) &&
           getStaticCallStringLiteral(commandArg) === "")) {
        return true;
      }
      continue;
    }
    if (!commandArg || !(["[", "("].includes(commandArg[0]))) {
      continue;
    }
    const elements = splitTopLevelCallArguments(commandArg.slice(1, -1));
    const resolvedTool = evaluateStaticStringExpression(elements[0], assignments);
    const tool = normalizeExecutableName(resolvedTool || "");
    if (resolvedTool === null && /\b(?:commit|merge|push|update-ref|branch|tag|pr|api)\b/iu.test(commandArg)) {
      return true;
    }
    if (tool !== "git" && tool !== "gh") {
      continue;
    }
    if (normalizeAgentValue(call.method) === "unknown") {
      const resolvedArguments = elements.slice(1).map((expression) => evaluateStaticStringExpression(expression, assignments));
      if (resolvedArguments.every((value) => value !== null) &&
          isReviewGatedCommand([tool, ...resolvedArguments].join(" "))) {
        return true;
      }
    }
    const resolvedSubcommand = evaluateStaticStringExpression(elements[1], assignments);
    if (tool === "git" &&
        resolvedSubcommand !== null &&
        !/^\s*["'][^"']+["']\s*$/u.test(String(elements[1] || ""))) {
      return true;
    }
    if ((tool === "git" && resolvedSubcommand === null) ||
        (tool === "gh" && hasUnresolvedGhLifecycleExpressions(elements.slice(1)))) {
      return true;
    }
  }
  return false;
}

function getArrayLiteralElements(value) {
  const arrayValue = stripLeadingCallComments(value);
  if (!arrayValue || arrayValue[0] !== "[" || arrayValue[arrayValue.length - 1] !== "]") {
    return null;
  }
  return splitTopLevelCallArguments(arrayValue.slice(1, -1));
}

function hasUnresolvedGhLifecycleExpressions(expressions) {
  const values = expressions.map((expression) => normalizeAgentValue(getStaticCallStringLiteral(expression)));
  const hasDynamic = values.some((value) => value === "");
  if (!hasDynamic) {
    return false;
  }
  const prIndex = values.indexOf("pr");
  const apiIndex = values.indexOf("api");
  return values[0] === "" || prIndex >= 0 || apiIndex >= 0;
}

function getStaticCallStringLiteral(value) {
  const source = stripLeadingCallComments(value);
  const singleQuoted = source.match(/^'([^'\\]*(?:\\.[^'\\]*)*)'$/u);
  if (singleQuoted) {
    return singleQuoted[1];
  }
  const doubleQuoted = source.match(/^"([^"\\]*(?:\\.[^"\\]*)*)"$/u);
  if (doubleQuoted) {
    return doubleQuoted[1];
  }
  const templateLiteral = source.match(/^`([^`\\$]*(?:\\.[^`\\$]*)*)`$/u);
  return templateLiteral ? templateLiteral[1] : "";
}

function expandShellAliasInvocation(tokens, aliases, depth = 0, seen = new Set()) {
  const aliasName = normalizeAgentValue(getExecutableBasename(tokens[0] || ""));
  const definition = aliases.get(aliasName);
  if (!definition) {
    return { matched: depth > 0, unresolved: false, tokens };
  }
  if (depth >= 8 || seen.has(aliasName)) {
    return { matched: true, unresolved: true, tokens: [] };
  }

  const nextSeen = new Set(seen);
  nextSeen.add(aliasName);
  let remainder = tokens.slice(1);
  if (definition.expandsNext && remainder.length > 0) {
    const expandedRemainder = expandShellAliasInvocation(remainder, aliases, depth + 1, nextSeen);
    if (expandedRemainder.unresolved) {
      return expandedRemainder;
    }
    remainder = expandedRemainder.tokens;
  }

  const expandedTokens = [...definition.aliasTokens, ...remainder];
  const expandedExecutable = normalizeAgentValue(getExecutableBasename(expandedTokens[0] || ""));
  if (aliases.has(expandedExecutable)) {
    return expandShellAliasInvocation(expandedTokens, aliases, depth + 1, nextSeen);
  }
  return { matched: true, unresolved: false, tokens: expandedTokens };
}

function hasShellFunctionLifecycleCommand(command, reviewOnly) {
  if (hasShellForwardingFunctionLifecycleCommand(command, reviewOnly)) {
    return true;
  }

  const functionPattern = /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{[^}]*\b(git|gh)\b(?:\s+([A-Za-z0-9_-]+))?[^}]*\}\s*;\s*\1(?:\s+([^;&\r\n]+))?/giu;
  for (const match of command.matchAll(functionPattern)) {
    const toolName = normalizeAgentValue(match[2] || "");
    const bodySubcommand = normalizeAgentValue(match[3] || "");
    const callTokens = tokenizeCommandLine(match[4] || "");
    if (toolName === "git") {
      const subcommand = bodySubcommand && bodySubcommand !== "$@" ? bodySubcommand : normalizeAgentValue(callTokens[0] || "");
      if (reviewOnly) {
        if (isReviewGatedGitSubcommand(subcommand, ["git", subcommand, ...callTokens.slice(1)], 1)) {
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

function hasShellForwardingFunctionLifecycleCommand(command, reviewOnly) {
  const functionPattern = /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{([^}]*)\}\s*;\s*\1(?:\s+([^;&\r\n]+))?/giu;
  for (const match of String(command || "").matchAll(functionPattern)) {
    const body = match[2] || "";
    if (!/(?:^|[\s;|&])(?:command\s+|exec\s+|builtin\s+)?["']?\$@["']?(?:$|[\s;|&])/u.test(body)) {
      continue;
    }

    const callTokens = unwrapEnvCommandTokens(tokenizeCommandLine(match[3] || ""));
    if (isGitTokenLifecycleCommand(callTokens, reviewOnly) ||
        (/\bgit\b/u.test(body) && isGitTokenLifecycleCommand(["git", ...callTokens], reviewOnly))) {
      return true;
    }
    if (isGhTokenLifecycleCommand(callTokens) ||
        (/\bgh\b/u.test(body) && isGhTokenLifecycleCommand(["gh", ...callTokens]))) {
      return true;
    }
  }

  return false;
}

function isGitTokenLifecycleCommand(tokens, reviewOnly) {
  if (tokens.length === 0 || normalizeExecutableName(tokens[0]) !== "git") {
    return false;
  }

  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[1] || ""));
  if (reviewOnly) {
    return isReviewGatedGitSubcommand(subcommand, tokens, 1);
  }

  return isGitLifecycleSubcommandName(subcommand) ||
    !isReadOnlyGitSubcommand(subcommand, tokens, 1);
}

function isGhTokenLifecycleCommand(tokens) {
  if (tokens.length === 0 || normalizeExecutableName(tokens[0]) !== "gh") {
    return false;
  }

  return tokens.some((token, index) =>
    normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
    tokens.slice(index + 1).some((nextToken) => normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge")) ||
    isGhApiMergeCommand(tokens) ||
    isGhApiRefWriteCommand(tokens);
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
        if (isReviewGatedGitSubcommand(subcommand, ["git", subcommand, ...callTokens.slice(1)], 1)) {
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
      if (isReviewGatedGitSubcommand(subcommand, ["git", ...effectiveTokens.slice(1)], 1)) {
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

function hasConservativeProtectedInterpreterBoundary(command, intent) {
  const source = String(command || "");
  const hasProcessApi = /["'](?:node:)?child_process["']|\b(?:import\s+subprocess|from\s+subprocess\s+import|os\.system\s*\()/iu.test(source);
  if (!hasProcessApi) {
    return false;
  }
  if (intent === "codex") {
    return /\bcodex(?:\.exe)?\b/iu.test(source) &&
      /(?:["'`]\s*(?:exec|e|--sandbox(?:=[^"'`\s]*)?)\s*["'`]|\bcodex(?:\.exe)?\s+(?:exec|e|--sandbox)\b)/iu.test(source);
  }
  return /(?:["'`]git(?:\.exe)?["'`]|\bgit(?:\.exe)?\b)[\s\S]{0,1024}(?:["'`]\s*(?:commit|merge|push|update-ref)\s*["'`]|\b(?:commit|merge|push|update-ref)\b)/iu.test(source) ||
    /(?:["'`]git(?:\.exe)?["'`]|\bgit(?:\.exe)?\b)[\s\S]{0,1024}\b(?:branch|tag)\b[\s\S]{0,128}(?:--delete|-d|-D|--move|-m|-M|--force|-f)\b/iu.test(source);
}

function walkJavaScriptAst(node, visitor) {
  if (!node || typeof node !== "object") {
    return;
  }
  if (typeof node.type === "string") {
    visitor(node);
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === "start" || key === "end" || key === "loc" || key === "range") {
      continue;
    }
    if (Array.isArray(value)) {
      for (const child of value) walkJavaScriptAst(child, visitor);
    } else if (value && typeof value === "object") {
      walkJavaScriptAst(value, visitor);
    }
  }
}

function collectJavaScriptBindingIdentifiers(pattern, target) {
  if (!pattern || !target) return;
  if (pattern.type === "Identifier") {
    target.add(pattern.name);
    return;
  }
  if (pattern.type === "RestElement") {
    collectJavaScriptBindingIdentifiers(pattern.argument, target);
    return;
  }
  if (pattern.type === "AssignmentPattern") {
    collectJavaScriptBindingIdentifiers(pattern.left, target);
    return;
  }
  if (pattern.type === "ArrayPattern") {
    for (const element of pattern.elements || []) collectJavaScriptBindingIdentifiers(element, target);
    return;
  }
  if (pattern.type === "ObjectPattern") {
    for (const property of pattern.properties || []) {
      collectJavaScriptBindingIdentifiers(property.type === "RestElement" ? property.argument : property.value, target);
    }
  }
}

function evaluateJavaScriptStaticValue(node, bindings, depth = 0) {
  if (!node || depth > 12) return null;
  if (node.type === "Literal" && (typeof node.value === "string" || typeof node.value === "number")) {
    return node.value;
  }
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    return node.quasis.map((part) => part.value.cooked).join("");
  }
  if (node.type === "Identifier") {
    return bindings.has(node.name) ? bindings.get(node.name) : null;
  }
  if (node.type === "BinaryExpression" && node.operator === "+") {
    const left = evaluateJavaScriptStaticValue(node.left, bindings, depth + 1);
    const right = evaluateJavaScriptStaticValue(node.right, bindings, depth + 1);
    return left !== null && right !== null ? String(left) + String(right) : null;
  }
  if (node.type === "ArrayExpression") {
    const values = node.elements.map((element) => evaluateJavaScriptStaticValue(element, bindings, depth + 1));
    return values.some((value) => value === null) ? null : values;
  }
  if (node.type === "CallExpression" && node.callee?.type === "MemberExpression") {
    const property = node.callee.computed
      ? evaluateJavaScriptStaticValue(node.callee.property, bindings, depth + 1)
      : node.callee.property?.name;
    if (property === "join") {
      const array = evaluateJavaScriptStaticValue(node.callee.object, bindings, depth + 1);
      const separator = node.arguments.length === 0 ? "," : evaluateJavaScriptStaticValue(node.arguments[0], bindings, depth + 1);
      return Array.isArray(array) && separator !== null ? array.join(String(separator)) : null;
    }
    if (property === "fromCharCode" && node.callee.object?.type === "Identifier" && node.callee.object.name === "String") {
      const codes = node.arguments.map((argument) => evaluateJavaScriptStaticValue(argument, bindings, depth + 1));
      return codes.every((value) => typeof value === "number") ? String.fromCharCode(...codes) : null;
    }
  }
  return null;
}

function getJavaScriptStaticBindings(ast) {
  const declarations = [];
  walkJavaScriptAst(ast, (node) => {
    if (node.type === "VariableDeclarator" && node.id?.type === "Identifier" && node.init) {
      declarations.push(node);
    }
  });
  const bindings = new Map();
  for (let pass = 0; pass < declarations.length + 1; pass += 1) {
    let changed = false;
    for (const declaration of declarations) {
      const value = evaluateJavaScriptStaticValue(declaration.init, bindings);
      if (value !== null && bindings.get(declaration.id.name) !== value) {
        bindings.set(declaration.id.name, value);
        changed = true;
      }
    }
    if (!changed) break;
  }
  return bindings;
}

function getJavaScriptMemberName(member, bindings) {
  if (!member || member.type !== "MemberExpression") return null;
  return member.computed
    ? evaluateJavaScriptStaticValue(member.property, bindings)
    : member.property?.name || null;
}

function getCanonicalJavaScriptModuleSpecifier(node) {
  if (node?.type === "Literal" && typeof node.value === "string") return node.value;
  if (node?.type === "TemplateLiteral" && node.expressions.length === 0) {
    return node.quasis.map((part) => part.value.cooked).join("");
  }
  return null;
}

function hasUnsupportedNodeProcessConstruction(script) {
  const source = String(script || "");
  let ast;
  try {
    ast = acorn.parse(source, { ecmaVersion: "latest", sourceType: "script", allowAwaitOutsideFunction: true });
  } catch (_) {
    return /\b(?:require|import|process|spawn|exec|fork|eval|Function|Proxy)\b/u.test(source);
  }
  const bindings = getJavaScriptStaticBindings(ast);
  const stableModuleBindings = new Map();
  const moduleBindingCounts = new Map();
  const unstableModuleBindings = new Set();
  walkJavaScriptAst(ast, (node) => {
    if (node.type === "VariableDeclaration") {
      for (const declaration of node.declarations) {
        if (declaration.id?.type !== "Identifier") continue;
        const name = declaration.id.name;
        moduleBindingCounts.set(name, (moduleBindingCounts.get(name) || 0) + 1);
        const value = node.kind === "const" ? evaluateJavaScriptStaticValue(declaration.init, bindings) : null;
        if (typeof value === "string") stableModuleBindings.set(name, value);
        else unstableModuleBindings.add(name);
      }
    }
    if (node.type === "AssignmentExpression") {
      collectJavaScriptBindingIdentifiers(node.left, unstableModuleBindings);
    }
    if (node.type === "UpdateExpression" && node.argument?.type === "Identifier") {
      unstableModuleBindings.add(node.argument.name);
    }
    if (["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"].includes(node.type)) {
      for (const parameter of node.params || []) {
        collectJavaScriptBindingIdentifiers(parameter, unstableModuleBindings);
      }
    }
    if (node.type === "CatchClause") {
      collectJavaScriptBindingIdentifiers(node.param, unstableModuleBindings);
    }
  });
  for (const [name, count] of moduleBindingCounts) {
    if (count !== 1 || unstableModuleBindings.has(name)) stableModuleBindings.delete(name);
  }
  const getStableModuleSpecifier = (node) => {
    const canonical = getCanonicalJavaScriptModuleSpecifier(node);
    if (canonical !== null) return canonical;
    return node?.type === "Identifier" && stableModuleBindings.has(node.name)
      ? stableModuleBindings.get(node.name)
      : null;
  };
  const staticObjectBindings = new Map();
  const unstableObjectBindings = new Set();
  walkJavaScriptAst(ast, (node) => {
    if (node.type === "AssignmentExpression") collectJavaScriptBindingIdentifiers(node.left, unstableObjectBindings);
    if (node.type === "UpdateExpression" && node.argument?.type === "Identifier") unstableObjectBindings.add(node.argument.name);
    if (["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"].includes(node.type)) {
      for (const parameter of node.params || []) {
        collectJavaScriptBindingIdentifiers(parameter, unstableObjectBindings);
      }
    }
    if (node.type === "CatchClause") collectJavaScriptBindingIdentifiers(node.param, unstableObjectBindings);
  });
  walkJavaScriptAst(ast, (node) => {
    if (node.type !== "VariableDeclaration" || node.kind !== "const") return;
    for (const declaration of node.declarations) {
      if (declaration.id?.type === "Identifier" && declaration.init?.type === "ObjectExpression" &&
          moduleBindingCounts.get(declaration.id.name) === 1 && !unstableObjectBindings.has(declaration.id.name)) {
        staticObjectBindings.set(declaration.id.name, {
          expression: declaration.init,
          end: declaration.end || declaration.start || 0,
        });
      }
    }
  });
  const getStaticObjectKeys = (node, sinkIndex, depth = 0) => {
    if (!node || depth > 8) return null;
    if (node.type === "Identifier") {
      const binding = staticObjectBindings.get(node.name);
      if (!binding || hasContainerMutationBetween(source, node.name, binding.end, sinkIndex)) return null;
      return getStaticObjectKeys(binding.expression, sinkIndex, depth + 1);
    }
    if (node.type !== "ObjectExpression") return null;
    const keys = new Set();
    for (const property of node.properties) {
      if (property.type === "SpreadElement") {
        const spreadKeys = getStaticObjectKeys(property.argument, sinkIndex, depth + 1);
        if (spreadKeys === null) return null;
        for (const key of spreadKeys) keys.add(key);
        continue;
      }
      if (property.type !== "Property" || property.kind && property.kind !== "init" || property.method) return null;
      const key = property.computed
        ? evaluateJavaScriptStaticValue(property.key, bindings)
        : property.key?.name || property.key?.value;
      if (typeof key !== "string") return null;
      keys.add(key);
    }
    return keys;
  };
  const processMethods = new Set(["exec", "execSync", "execFile", "execFileSync", "spawn", "spawnSync", "fork"]);
  const childProcessObjects = new Set();
  const childProcessMethodAliases = new Set();
  const processEnvironmentAliases = new Set();
  const moduleLoaderAliases = new Set();
  let hasUnsupportedProvenance = false;
  const isBuiltinModuleLoaderCallee = (node) => {
    if (node?.type === "Identifier") {
      return node.name === "require" || moduleLoaderAliases.has(node.name);
    }
    if (node?.type === "MemberExpression" && getJavaScriptMemberName(node, bindings) === "require") {
      const object = node.object;
      return object?.type === "Identifier" && object.name === "module" ||
        object?.type === "MemberExpression" &&
          object.object?.type === "Identifier" && object.object.name === "process" &&
          getJavaScriptMemberName(object, bindings) === "mainModule";
    }
    if (node?.type === "MemberExpression" && getJavaScriptMemberName(node, bindings) === "getBuiltinModule") {
      return node.object?.type === "Identifier" && node.object.name === "process";
    }
    if (node?.type === "CallExpression" && node.callee?.type === "MemberExpression" &&
        getJavaScriptMemberName(node.callee, bindings) === "createRequire") {
      const object = node.callee.object;
      return object?.type === "Identifier" && ["module", "Module"].includes(object.name);
    }
    return false;
  };
  const isChildProcessRequire = (node) => {
    if (node?.type !== "CallExpression" || !isBuiltinModuleLoaderCallee(node.callee)) return false;
    const moduleName = node.arguments.length === 1 ? getStableModuleSpecifier(node.arguments[0]) : null;
    return moduleName === "child_process" || moduleName === "node:child_process";
  };
  walkJavaScriptAst(ast, (node) => {
    if (node.type !== "VariableDeclaration") return;
    for (const declaration of node.declarations) {
      if (declaration.id?.type === "Identifier" &&
          declaration.init?.type === "Identifier" && declaration.init.name === "require") {
        moduleLoaderAliases.add(declaration.id.name);
        continue;
      }
      if (declaration.id?.type === "Identifier" && isChildProcessRequire(declaration.init)) {
        childProcessObjects.add(declaration.id.name);
        if (node.kind !== "const") hasUnsupportedProvenance = true;
        continue;
      }
      if (declaration.id?.type === "ObjectPattern" && isChildProcessRequire(declaration.init)) {
        for (const property of declaration.id.properties) {
          const method = property.computed
            ? evaluateJavaScriptStaticValue(property.key, bindings)
            : property.key?.name || property.key?.value;
          const alias = property.value?.type === "Identifier" ? property.value.name : null;
          if (processMethods.has(method) && alias) childProcessMethodAliases.add(alias);
        }
        if (node.kind !== "const") hasUnsupportedProvenance = true;
        continue;
      }
      if (declaration.id?.type === "Identifier" && declaration.init?.type === "MemberExpression") {
        const method = getJavaScriptMemberName(declaration.init, bindings);
        const object = declaration.init.object;
        if (object?.type === "Identifier" && object.name === "process" && method === "env") {
          processEnvironmentAliases.add(declaration.id.name);
          continue;
        }
        const isChildObject = isChildProcessRequire(object) ||
          (object?.type === "Identifier" && childProcessObjects.has(object.name));
        if (isChildObject && processMethods.has(method)) {
          childProcessMethodAliases.add(declaration.id.name);
          if (node.kind !== "const") hasUnsupportedProvenance = true;
        }
      }
    }
  });
  let capabilityAliasChanged = true;
  while (capabilityAliasChanged) {
    capabilityAliasChanged = false;
    walkJavaScriptAst(ast, (node) => {
      if (node.type !== "VariableDeclaration") return;
      for (const declaration of node.declarations || []) {
        if (declaration.id?.type !== "Identifier" || declaration.init?.type !== "Identifier") continue;
        if (childProcessObjects.has(declaration.init.name) && !childProcessObjects.has(declaration.id.name)) {
          childProcessObjects.add(declaration.id.name);
          capabilityAliasChanged = true;
          if (node.kind !== "const") hasUnsupportedProvenance = true;
        }
        if (childProcessMethodAliases.has(declaration.init.name) && !childProcessMethodAliases.has(declaration.id.name)) {
          childProcessMethodAliases.add(declaration.id.name);
          capabilityAliasChanged = true;
          if (node.kind !== "const") hasUnsupportedProvenance = true;
        }
      }
    });
  }
  const activeEnvironmentAliases = new Set(processEnvironmentAliases);
  const inspectEnvironmentAliasFlow = (node, functionDepth = 0) => {
    if (!node || typeof node !== "object") return;
    const entersFunction = ["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"].includes(node.type);
    const currentDepth = functionDepth + (entersFunction ? 1 : 0);
    if (node.type === "AssignmentExpression" && node.left?.type === "Identifier" &&
        activeEnvironmentAliases.has(node.left.name) && currentDepth === 0) {
      activeEnvironmentAliases.delete(node.left.name);
    }
    if (node.type === "AssignmentExpression" && node.left?.type === "MemberExpression" &&
        node.left.object?.type === "Identifier" && activeEnvironmentAliases.has(node.left.object.name)) {
      const key = node.left.computed
        ? evaluateJavaScriptStaticValue(node.left.property, bindings)
        : node.left.property?.name;
      if (key === "GIT_DIR" || key === "GIT_WORK_TREE") hasUnsupportedProvenance = true;
    }
    for (const [key, value] of Object.entries(node)) {
      if (["start", "end", "loc", "range"].includes(key)) continue;
      if (Array.isArray(value)) {
        for (const child of value) inspectEnvironmentAliasFlow(child, currentDepth);
      } else if (value && typeof value === "object") {
        inspectEnvironmentAliasFlow(value, currentDepth);
      }
    }
  };
  inspectEnvironmentAliasFlow(ast);
  let hasChildProcessModule = false;
  let hasDynamicModuleLoad = false;
  let hasUnsupportedReflection = false;
  let hasTargetChangingOptions = false;
  let hasChildProcessCapabilityCall = false;
  const containsChildProcessCapability = (node, depth = 0) => {
    if (!node || depth > 12) return false;
    if (isChildProcessRequire(node)) return true;
    if (node.type === "Identifier" &&
        (childProcessObjects.has(node.name) || childProcessMethodAliases.has(node.name))) return true;
    if (node.type === "MemberExpression") {
      const method = getJavaScriptMemberName(node, bindings);
      const object = node.object;
      if (processMethods.has(method) &&
          (isChildProcessRequire(object) ||
           (object?.type === "Identifier" && childProcessObjects.has(object.name)))) return true;
    }
    for (const [key, value] of Object.entries(node)) {
      if (["start", "end", "loc", "range"].includes(key)) continue;
      if (Array.isArray(value) && value.some((child) => containsChildProcessCapability(child, depth + 1))) return true;
      if (value && typeof value === "object" && containsChildProcessCapability(value, depth + 1)) return true;
    }
    return false;
  };
  const inspectCapabilityEscapes = (node, parent = null, grandparent = null) => {
    if (!node || typeof node !== "object") return;
    const isRequireCapability = isChildProcessRequire(node);
    const isObjectCapability = node.type === "Identifier" && childProcessObjects.has(node.name);
    const isMethodCapability = node.type === "Identifier" && childProcessMethodAliases.has(node.name);
    if ((isRequireCapability || isObjectCapability || isMethodCapability) && parent) {
      const isBindingOccurrence = parent.type === "VariableDeclarator" && parent.id === node ||
        parent.type === "Property" && grandparent?.type === "ObjectPattern";
      const isCanonicalRequireUse = isRequireCapability && (
        parent.type === "VariableDeclarator" && parent.init === node &&
          ["Identifier", "ObjectPattern"].includes(parent.id?.type) ||
        parent.type === "MemberExpression" && parent.object === node ||
        parent.type === "ExpressionStatement" && parent.expression === node
      );
      const isCanonicalObjectUse = isObjectCapability && (
        isBindingOccurrence ||
        parent.type === "MemberExpression" && parent.object === node ||
        parent.type === "VariableDeclarator" && parent.init === node &&
          parent.id?.type === "Identifier" && childProcessObjects.has(parent.id.name)
      );
      const isCanonicalMethodUse = isMethodCapability && (
        isBindingOccurrence ||
        parent.type === "CallExpression" && parent.callee === node ||
        parent.type === "VariableDeclarator" && parent.init === node &&
          parent.id?.type === "Identifier" && childProcessMethodAliases.has(parent.id.name)
      );
      if (!isBindingOccurrence && !isCanonicalRequireUse && !isCanonicalObjectUse && !isCanonicalMethodUse) {
        hasUnsupportedProvenance = true;
      }
    }
    for (const [key, value] of Object.entries(node)) {
      if (["start", "end", "loc", "range"].includes(key)) continue;
      if (Array.isArray(value)) {
        for (const child of value) inspectCapabilityEscapes(child, node, parent);
      } else if (value && typeof value === "object") {
        inspectCapabilityEscapes(value, node, parent);
      }
    }
  };
  inspectCapabilityEscapes(ast);
  const getMemberRootIdentifier = (node) => {
    let current = node;
    while (current?.type === "MemberExpression") current = current.object;
    return current?.type === "Identifier" ? current.name : null;
  };
  const functionBindings = new Map();
  walkJavaScriptAst(ast, (node) => {
    if (node.type === "FunctionDeclaration" && node.id?.type === "Identifier") {
      functionBindings.set(node.id.name, node);
    }
    if (node.type === "VariableDeclarator" && node.id?.type === "Identifier" &&
        ["FunctionExpression", "ArrowFunctionExpression"].includes(node.init?.type)) {
      functionBindings.set(node.id.name, node.init);
    }
  });
  const getProcessParameterIndexes = (functionNode) => {
    if (!functionNode || !Array.isArray(functionNode.params)) return [];
    const indexes = [];
    functionNode.params.forEach((parameter, index) => {
      if (parameter?.type !== "Identifier") return;
      let reachesProcessCapability = false;
      walkJavaScriptAst(functionNode.body, (node) => {
        if (node.type === "MemberExpression" && processMethods.has(getJavaScriptMemberName(node, bindings)) &&
            getMemberRootIdentifier(node) === parameter.name) {
          reachesProcessCapability = true;
        }
      });
      if (reachesProcessCapability) indexes.push(index);
    });
    return indexes;
  };
  walkJavaScriptAst(ast, (node) => {
    if (node.type !== "CallExpression") return;
    const functionNode = node.callee?.type === "Identifier"
      ? functionBindings.get(node.callee.name)
      : ["FunctionExpression", "ArrowFunctionExpression"].includes(node.callee?.type) ? node.callee : null;
    for (const index of getProcessParameterIndexes(functionNode)) {
      if (containsChildProcessCapability(node.arguments[index])) hasUnsupportedProvenance = true;
    }
  });
  walkJavaScriptAst(ast, (node) => {
    if (node.type === "ImportExpression") {
      const moduleName = getStableModuleSpecifier(node.source);
      if (moduleName === null) hasDynamicModuleLoad = true;
      if (moduleName === "child_process" || moduleName === "node:child_process") {
        hasChildProcessModule = true;
        hasUnsupportedProvenance = true;
      }
    }
    if (node.type === "CallExpression" && isBuiltinModuleLoaderCallee(node.callee)) {
      const moduleName = node.arguments.length === 1 ? getStableModuleSpecifier(node.arguments[0]) : null;
      if (moduleName === null) hasDynamicModuleLoad = true;
      if (moduleName === "child_process" || moduleName === "node:child_process") {
        hasChildProcessModule = true;
        if (node.callee?.type === "Identifier" && moduleLoaderAliases.has(node.callee.name)) {
          hasUnsupportedProvenance = true;
        }
      }
    }
    if (node.type === "SpreadElement" && isChildProcessRequire(node.argument)) {
      hasUnsupportedProvenance = true;
    }
    if (node.type === "CallExpression") {
      const calleeName = node.callee?.type === "MemberExpression" ? getJavaScriptMemberName(node.callee, bindings) : null;
      const calleeObject = node.callee?.type === "MemberExpression" ? node.callee.object : null;
      const objectName = calleeObject?.type === "Identifier" ? calleeObject.name : null;
      const descriptorTarget = node.arguments[0];
      const isSensitiveDescriptor = containsChildProcessCapability(descriptorTarget) ||
        descriptorTarget?.type === "Identifier" && descriptorTarget.name === "process";
      if ((objectName === "Object" && calleeName === "getOwnPropertyDescriptor" && isSensitiveDescriptor) ||
          (objectName === "Reflect" && ["get", "set"].includes(calleeName)) ||
          (node.callee?.type === "Identifier" && ["eval", "Function"].includes(node.callee.name))) {
        hasUnsupportedReflection = true;
      }
      if (processMethods.has(calleeName)) {
        const optionsIndex = ["exec", "execSync"].includes(calleeName) ? 1 : 2;
        const options = node.arguments[optionsIndex];
        const optionKeys = options ? getStaticObjectKeys(options, node.start || 0) : new Set();
        if (optionKeys === null || ["cwd", "env", "shell"].some((key) => optionKeys.has(key))) {
          hasTargetChangingOptions = true;
        }
      }
      if (node.callee?.type === "MemberExpression" && node.callee.computed &&
          node.callee.object?.type === "Identifier" && childProcessObjects.has(node.callee.object.name) &&
          processMethods.has(calleeName)) {
        hasUnsupportedProvenance = true;
      }
      const isCanonicalDirectMember = node.callee?.type === "MemberExpression" &&
        processMethods.has(getJavaScriptMemberName(node.callee, bindings)) &&
        (isChildProcessRequire(node.callee.object) ||
         (node.callee.object?.type === "Identifier" && childProcessObjects.has(node.callee.object.name)));
      const isCanonicalAlias = node.callee?.type === "Identifier" && childProcessMethodAliases.has(node.callee.name);
      const hasWrappedCapability = containsChildProcessCapability(node.callee);
      if (isCanonicalDirectMember || isCanonicalAlias || hasWrappedCapability) {
        hasChildProcessCapabilityCall = true;
      }
      if (hasWrappedCapability && !isCanonicalDirectMember && !isCanonicalAlias) {
        hasUnsupportedProvenance = true;
      }
    }
    if (node.type === "AssignmentExpression" && node.left?.type === "Identifier" &&
        (childProcessObjects.has(node.left.name) ||
         childProcessMethodAliases.has(node.left.name) ||
         processEnvironmentAliases.has(node.left.name) && node.right?.type !== "ObjectExpression")) {
      hasUnsupportedProvenance = true;
    }
    if (node.type === "NewExpression" && node.callee?.type === "Identifier" && ["Function", "Proxy"].includes(node.callee.name)) {
      hasUnsupportedReflection = true;
    }
  });
  if (hasDynamicModuleLoad || hasUnsupportedReflection || hasTargetChangingOptions || hasUnsupportedProvenance) {
    return true;
  }
  if (!hasChildProcessModule) {
    return false;
  }
  return hasChildProcessCapabilityCall && hasUnresolvedInterpreterProcessBoundary(source);
}

function getInterpreterInlineSourceDescriptors(tokens, kind) {
  const options = kind === "python" ? ["-c"] : ["-e", "-p", "-pe", "--eval", "--print"];
  const descriptors = [];
  for (let index = 1; index < tokens.length; index += 1) {
    const token = String(tokens[index] || "");
    const normalized = normalizeAgentValue(token);
    if (options.includes(normalized)) {
      if (kind === "node" && (normalized === "-p" || normalized === "--print")) {
        const next = normalizeAgentValue(String(tokens[index + 1] || ""));
        if (options.includes(next) || options.some((option) =>
          next.startsWith(option + "=") || next.startsWith(option + ":"))) continue;
      }
      descriptors.push({
        source: index + 1 < tokens.length ? stripOuterQuotes(tokens[index + 1]) : "",
        trailingIndex: Math.min(index + 2, tokens.length),
      });
      if (kind === "python") break;
      index += 1;
      continue;
    }
    for (const option of options) {
      if (normalized.startsWith(option + "=") || normalized.startsWith(option + ":")) {
        descriptors.push({ source: stripOuterQuotes(token.slice(option.length + 1)), trailingIndex: index + 1 });
        if (kind === "python") return descriptors;
        break;
      }
    }
  }
  return descriptors;
}

function getInterpreterInlineSourceDescriptor(tokens, kind) {
  const descriptors = getInterpreterInlineSourceDescriptors(tokens, kind);
  return descriptors.length > 0 ? descriptors[descriptors.length - 1] : null;
}

function getInterpreterInlineSourceToken(tokens, kind) {
  return getInterpreterInlineSourceDescriptor(tokens, kind)?.source ?? null;
}

function getInterpreterTrailingArgumentTokens(command) {
  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(String(command || "")));
  const kind = getShellInterpreterKind(tokens);
  if (!kind) return [];
  const descriptor = getInterpreterInlineSourceDescriptor(tokens, kind);
  return descriptor ? tokens.slice(descriptor.trailingIndex) : [];
}

function hasOuterCodexProtectedArguments(command) {
  const trailing = getInterpreterTrailingArgumentTokens(command)
    .map((token) => stripOuterQuotes(String(token || "")));
  return normalizeExecutableName(trailing[0] || "") === "codex" &&
    trailing.slice(1).some(isDeniedCodexMode);
}

function hasUnsupportedPythonProcessConstruction(script) {
  const source = String(script || "");
  const code = maskPythonNonCode(source);
  const hasDynamicExecution = /(?<![.A-Za-z0-9_])(?:exec|eval)\s*\(/u.test(code);
  if (!hasDynamicExecution) return false;
  const isProtectedProcessSource = (value) =>
    /\b(?:subprocess|__import__|importlib)\b|\bos\s*\.\s*(?:exec|spawn|posix_spawn|system)/iu.test(value) &&
    /\b(?:codex|git|gh)(?:\.exe)?\b[\s\S]*\b(?:exec|e|--sandbox|commit|merge|push|update-ref)\b/iu.test(value);
  if (isProtectedProcessSource(code)) return true;
  for (const match of code.matchAll(/(?<![.A-Za-z0-9_])(?:exec|eval)\s*\(/gu)) {
    const openIndex = (match.index || 0) + match[0].lastIndexOf("(");
    const body = getBalancedCallBody(source, openIndex);
    if (body === null) return true;
    const expression = splitTopLevelCallArguments(body)[0];
    const materialized = evaluateScopedStaticStringExpression(
      expression,
      source,
      openIndex,
      buildFunctionScopeIndex(source),
      "python",
    );
    if (materialized === null || isProtectedProcessSource(materialized)) return true;
  }
  return false;
}

function hasUnsupportedPythonModuleLoad(script) {
  const source = String(script || "");
  const code = maskPythonNonCode(source);
  if (/\b(?:globals|locals)\s*\(/u.test(code)) {
    return true;
  }
  const canonicalModuleRoots = new Set([
    "builtins", "collections", "functools", "importlib", "itertools", "json", "math",
    "operator", "os", "pathlib", "platform", "re", "shlex", "subprocess", "sys", "time", "types",
  ]);
  for (const match of code.matchAll(/(?:^|[;\r\n])\s*import\s+([^;\r\n]+)/gu)) {
    for (const binding of String(match[1] || "").split(",")) {
      const moduleRoot = /^\s*([A-Za-z_][A-Za-z0-9_]*)/u.exec(binding)?.[1] || "";
      if (!canonicalModuleRoots.has(moduleRoot)) return true;
    }
  }
  for (const match of code.matchAll(/(?:^|[;\r\n])\s*from\s+([A-Za-z_][A-Za-z0-9_]*)\b/gu)) {
    if (!canonicalModuleRoots.has(match[1])) return true;
  }
  const nonCanonicalModuleRegistry = source.replace(
    /\bsys\s*\.\s*modules\s*(?:\[\s*["']json["']\s*\]|\.\s*get\s*\(\s*["']json["']\s*\))/gu,
    "",
  );
  if (/\bsys\s*\.\s*modules\b/u.test(nonCanonicalModuleRegistry)) {
    return true;
  }
  const scopes = buildFunctionScopeIndex(source);
  const containerHistory = new Map();
  const loaderHistory = new Map();
  const containerAliases = new Set(["__builtins__"]);
  const loaderAliases = new Set(["__import__"]);
  let unsupportedLoad = false;
  let escapedLoader = false;

  const recordContainer = (name, kind, index, scope = scopes.scopeAt(index)) => {
    containerAliases.add(name);
    recordScopedPositionState(containerHistory, name, kind || "", index, scope);
  };
  const recordLoader = (name, kind, index, scope = scopes.scopeAt(index)) => {
    loaderAliases.add(name);
    recordScopedPositionState(loaderHistory, name, kind || "", index, scope);
  };
  recordContainer("__builtins__", "builtins", -1, -1);
  recordLoader("__import__", "__import__", -1, -1);

  for (const match of code.matchAll(/(?:^|[;\r\n])\s*import\s+([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    for (const rawBinding of String(match[1] || "").split(",")) {
      const binding = /^\s*(importlib|builtins)(?:\.([A-Za-z_][A-Za-z0-9_.]*))?(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*$/u.exec(rawBinding);
      if (!binding) continue;
      const root = binding[1];
      const suffix = binding[2];
      const alias = binding[3];
      if (!suffix) {
        recordContainer(alias || root, root, index);
      } else if (!alias) {
        recordContainer(root, root, index);
      }
    }
  }
  for (const match of code.matchAll(/(?:^|[;\r\n])\s*from\s+(importlib|builtins)\s+import\s+([^;\r\n]+)/gu)) {
    const index = match.index || 0;
    const expected = match[1] === "importlib" ? "import_module" : "__import__";
    for (const rawBinding of String(match[2] || "").replace(/[()]/gu, "").split(",")) {
      const binding = /^\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*$/u.exec(rawBinding);
      if (binding?.[1] === expected) recordLoader(binding[2] || binding[1], expected, index);
    }
  }

  const hasExplicitProtectedContainer = /(?:^|[;\r\n])\s*(?:import\s+[^;\r\n]*\b(?:importlib|builtins)\b|from\s+(?:importlib|builtins)\s+import\b)|\b(?:__builtins__|__import__)\b/u.test(code);
  if (hasExplicitProtectedContainer &&
      (/\b(?:async|await|class|def|for|lambda|match|return|try|while|with|yield)\b/u.test(code) || /:=/u.test(code))) {
    return true;
  }

  const getContainerKind = (name, index) => getScopedPositionState(containerHistory, name, index, scopes) || "";
  const getLoaderKind = (name, index) => getScopedPositionState(loaderHistory, name, index, scopes) || "";
  const loaderForMember = (containerKind, memberName) => {
    const member = normalizeAgentValue(memberName);
    if (containerKind === "importlib" && member === "import_module") return "import_module";
    if (containerKind === "builtins" && member === "__import__") return "__import__";
    return "";
  };
  const unwrapGrouping = (value) => {
    let candidate = String(value || "").trim();
    while (candidate.startsWith("(") && candidate.endsWith(")")) {
      const body = getBalancedCallBody(candidate, 0);
      if (body === null || body.length !== candidate.length - 2 || /,\s*$/u.test(body)) break;
      candidate = body.trim();
    }
    return candidate;
  };
  const findTrailingCallOpen = (value) => {
    const candidate = String(value || "").trim();
    for (let index = 0; index < candidate.length; index += 1) {
      if (candidate[index] !== "(") continue;
      const body = getBalancedCallBody(candidate, index);
      if (body !== null && index + body.length + 1 === candidate.length - 1) return index;
    }
    return -1;
  };
  const getExactCallBody = (value, openIndex) => {
    const candidate = String(value || "").trim();
    const body = getBalancedCallBody(candidate, openIndex);
    return body !== null && openIndex + body.length + 1 === candidate.length - 1 ? body : null;
  };
  const classifyLoaderCall = (callBody, index) => {
    const moduleExpression = splitTopLevelCallArguments(callBody)[0];
    const moduleName = moduleExpression === undefined
      ? null
      : evaluateScopedStaticStringExpression(moduleExpression, source, index, scopes, "python");
    const moduleRoot = moduleName === null ? null : normalizeAgentValue(moduleName).split(".")[0];
    if (moduleRoot === null || moduleRoot === "os" || moduleRoot === "subprocess") unsupportedLoad = true;
    return { type: "module", kind: moduleRoot || "unknown" };
  };

  const resolveCapabilityExpression = (rawExpression, index, depth = 0) => {
    if (depth > 8) return null;
    const expression = unwrapGrouping(rawExpression);
    const identifier = /^([A-Za-z_][A-Za-z0-9_]*)$/u.exec(expression)?.[1];
    if (identifier) {
      const loader = getLoaderKind(identifier, index);
      if (loader) return { type: "loader", kind: loader };
      const container = getContainerKind(identifier, index);
      return container ? { type: "container", kind: container } : null;
    }

    const callOpen = findTrailingCallOpen(expression);
    if (callOpen >= 0) {
      const callee = resolveCapabilityExpression(expression.slice(0, callOpen), index, depth + 1);
      if (callee?.type === "loader") {
        return classifyLoaderCall(expression.slice(callOpen + 1, -1), index);
      }
    }

    const directMember = /^([\s\S]+?)\s*\.\s*(import_module|__import__)$/u.exec(expression);
    if (directMember) {
      const owner = resolveCapabilityExpression(directMember[1], index, depth + 1);
      const loader = owner?.type === "container" ? loaderForMember(owner.kind, directMember[2]) : "";
      return loader ? { type: "loader", kind: loader } : null;
    }
    const dictMember = /^([\s\S]+?)\s*\.\s*__dict__\s*\[([\s\S]+)\]$/u.exec(expression);
    if (dictMember) {
      const owner = resolveCapabilityExpression(dictMember[1], index, depth + 1);
      const member = evaluateScopedStaticStringExpression(dictMember[2], source, index, scopes, "python");
      const loader = owner?.type !== "container" ? "" : member === null ? "unknown" : loaderForMember(owner.kind, member);
      return loader ? { type: "loader", kind: loader } : null;
    }
    const dictGet = /^([\s\S]+?)\s*\.\s*__dict__\s*\.\s*get\s*\(/u.exec(expression);
    const dictGetOpen = dictGet ? dictGet[0].lastIndexOf("(") : -1;
    const dictGetBody = dictGetOpen >= 0 ? getExactCallBody(expression, dictGetOpen) : null;
    if (dictGet && dictGetBody !== null) {
      const owner = resolveCapabilityExpression(dictGet[1], index, depth + 1);
      const args = splitTopLevelCallArguments(dictGetBody);
      const member = evaluateScopedStaticStringExpression(args[0], source, index, scopes, "python");
      const loader = owner?.type !== "container" ? "" : member === null ? "unknown" : loaderForMember(owner.kind, member);
      return loader ? { type: "loader", kind: loader } : null;
    }
    const varsMember = /^vars\s*\(\s*([\s\S]+)\s*\)\s*\[([\s\S]+)\]$/u.exec(expression);
    if (varsMember) {
      const owner = resolveCapabilityExpression(varsMember[1], index, depth + 1);
      const member = evaluateScopedStaticStringExpression(varsMember[2], source, index, scopes, "python");
      const loader = owner?.type !== "container" ? "" : member === null ? "unknown" : loaderForMember(owner.kind, member);
      return loader ? { type: "loader", kind: loader } : null;
    }
    const computedMember = /^([\s\S]+?)\s*\[([\s\S]+)\]$/u.exec(expression);
    if (computedMember) {
      const owner = resolveCapabilityExpression(computedMember[1], index, depth + 1);
      const member = evaluateScopedStaticStringExpression(computedMember[2], source, index, scopes, "python");
      const loader = owner?.type !== "container" ? "" : member === null ? "unknown" : loaderForMember(owner.kind, member);
      if (loader) return { type: "loader", kind: loader };
    }
    const getattrCall = /^getattr\s*\(/u.exec(expression);
    const getattrOpen = getattrCall ? getattrCall[0].lastIndexOf("(") : -1;
    const getattrBody = getattrOpen >= 0 ? getExactCallBody(expression, getattrOpen) : null;
    if (getattrBody !== null) {
      const args = splitTopLevelCallArguments(getattrBody);
      const owner = resolveCapabilityExpression(args[0], index, depth + 1);
      if (owner?.type === "container") {
        const member = evaluateScopedStaticStringExpression(args[1], source, index, scopes, "python");
        const loader = member === null ? "unknown" : loaderForMember(owner.kind, member);
        if (loader) return { type: "loader", kind: loader };
      }
    }

    const indexedSequence = /^(\([\s\S]*\)|\[[\s\S]*\])\s*\[\s*(\d+)\s*\]$/u.exec(expression);
    if (indexedSequence) {
      const body = indexedSequence[1].slice(1, -1);
      const elements = splitTopLevelCallArguments(body);
      const selected = Number.parseInt(indexedSequence[2], 10);
      return selected < elements.length
        ? resolveCapabilityExpression(elements[selected], index, depth + 1)
        : null;
    }

    return null;
  };

  const hasLiveLoaderReference = (expression, index) => {
    const maskedExpression = maskPythonNonCode(String(expression || ""));
    for (const alias of loaderAliases) {
      const pattern = new RegExp(`(?<![.A-Za-z0-9_])${escapeRegex(alias)}\\b`, "gu");
      for (const match of maskedExpression.matchAll(pattern)) {
        if (getLoaderKind(alias, index + (match.index || 0))) return true;
      }
    }
    for (const alias of containerAliases) {
      if (!getContainerKind(alias, index)) continue;
      const escaped = escapeRegex(alias);
      if (new RegExp(`\\b${escaped}\\s*\\.\\s*(?:import_module|__import__)\\b`, "u").test(expression) ||
          new RegExp(`\\b(?:getattr|vars)\\s*\\(\\s*${escaped}\\b`, "u").test(expression) ||
          new RegExp(`\\b${escaped}\\s*(?:\\.\\s*__dict__)?\\s*\\[`, "u").test(expression)) return true;
    }
    return false;
  };
  const hasEscapingContainerReference = (expression, index) => {
    const maskedExpression = maskPythonNonCode(String(expression || ""));
    const canonicalReadOnlyMembers = {
      builtins: new Set(["__name__"]),
      importlib: new Set(["__name__", "metadata", "util"]),
    };
    for (const alias of containerAliases) {
      const pattern = new RegExp(`(?<![.A-Za-z0-9_])${escapeRegex(alias)}\\b`, "gu");
      for (const match of maskedExpression.matchAll(pattern)) {
        const referenceIndex = index + (match.index || 0);
        const containerKind = getContainerKind(alias, referenceIndex);
        if (!containerKind) continue;
        const tail = maskedExpression.slice((match.index || 0) + match[0].length);
        const member = /^\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)/u.exec(tail)?.[1] || "";
        if (!member) return true;
        if (loaderForMember(containerKind, member)) continue;
        if (!canonicalReadOnlyMembers[containerKind]?.has(member)) return true;
      }
    }
    return false;
  };

  const assignments = [];
  for (const match of code.matchAll(/(?:^|[;\r\n])\s*([^=;\r\n]+?)\s*(?<![<>=!:])=(?!=)\s*([^;\r\n]+)/gu)) {
    const start = match.index || 0;
    const equalsOffset = match[0].indexOf("=");
    assignments.push({
      index: start,
      left: match[1].trim(),
      right: source.slice(start + equalsOffset + 1, start + match[0].length).trim(),
    });
  }
  assignments.sort((left, right) => left.index - right.index);
  for (const assignment of assignments) {
    const left = getPythonAssignmentElements(assignment.left);
    const right = getPythonAssignmentElements(assignment.right);
    const pairs = left.sequence && right.sequence
      ? Math.min(left.elements.length, right.elements.length)
      : !left.sequence ? 1 : 0;
    for (let offset = 0; offset < pairs; offset += 1) {
      const name = /^([A-Za-z_][A-Za-z0-9_]*)$/u.exec(left.elements[offset])?.[1];
      const expression = right.sequence ? right.elements[offset] : assignment.right;
      if (!name) {
        if (hasLiveLoaderReference(expression, assignment.index) ||
            hasEscapingContainerReference(expression, assignment.index)) escapedLoader = true;
        continue;
      }
      const resolved = resolveCapabilityExpression(expression, assignment.index);
      const scope = scopes.scopeAt(assignment.index);
      recordContainer(name, resolved?.type === "container" ? resolved.kind : "", assignment.index, scope);
      recordLoader(name, resolved?.type === "loader" ? resolved.kind : "", assignment.index, scope);
      if (!resolved && (hasLiveLoaderReference(expression, assignment.index) ||
          hasEscapingContainerReference(expression, assignment.index))) escapedLoader = true;
    }
    if (!left.sequence && right.sequence && right.elements.some((expression) => hasLiveLoaderReference(expression, assignment.index))) {
      escapedLoader = true;
    }
  }
  for (const match of code.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*([^,;\r\n)\]}]+)/gu)) {
    const expression = source.slice(
      (match.index || 0) + match[0].indexOf(":=") + 2,
      (match.index || 0) + match[0].length,
    ).trim();
    if (hasLiveLoaderReference(expression, match.index || 0) ||
        hasEscapingContainerReference(expression, match.index || 0)) escapedLoader = true;
  }
  for (const match of code.matchAll(/\bfor\b/gu)) {
    const clauseStart = (match.index || 0) + match[0].length;
    const remainingClause = source.slice(clauseStart);
    if (hasLiveLoaderReference(remainingClause, clauseStart) ||
        hasEscapingContainerReference(remainingClause, clauseStart)) escapedLoader = true;
  }

  const resolveCallCallee = (openIndex) => {
    let unresolvedGroupedCapability = false;
    for (let start = openIndex - 1; start >= 0; start -= 1) {
      if (start > 0 && /[A-Za-z0-9_]/u.test(source[start - 1] || "")) continue;
      const expression = source.slice(start, openIndex).trim();
      if (!expression) continue;
      const resolved = resolveCapabilityExpression(expression, openIndex);
      if (resolved) return { resolved, escaped: false };
      if (expression.startsWith("(") && expression.endsWith(")") &&
          (hasLiveLoaderReference(expression, start) || hasEscapingContainerReference(expression, start))) {
        unresolvedGroupedCapability = true;
      }
      if (/[;\r\n]/u.test(expression)) break;
    }
    return { resolved: null, escaped: unresolvedGroupedCapability };
  };
  for (let openIndex = 0; openIndex < code.length; openIndex += 1) {
    if (code[openIndex] !== "(") continue;
    let previousIndex = openIndex - 1;
    while (previousIndex >= 0 && /\s/u.test(code[previousIndex])) previousIndex -= 1;
    if (previousIndex < 0 || !/[A-Za-z0-9_)\]]/u.test(code[previousIndex])) continue;
    const precedingIdentifier = /([A-Za-z_][A-Za-z0-9_]*)\s*$/u.exec(code.slice(0, openIndex))?.[1] || "";
    if (precedingIdentifier === "import") continue;
    const callee = resolveCallCallee(openIndex);
    const maskedBody = getBalancedCallBody(code, openIndex);
    if (maskedBody === null) {
      if (callee.resolved?.type === "loader" || callee.escaped) return true;
      continue;
    }
    const body = source.slice(openIndex + 1, openIndex + 1 + maskedBody.length);
    if (callee.resolved?.type === "loader") {
      classifyLoaderCall(body, openIndex);
      continue;
    }
    if (callee.escaped) escapedLoader = true;
    const simpleCallee = /([A-Za-z_][A-Za-z0-9_]*)\s*$/u.exec(source.slice(0, openIndex))?.[1] || "";
    const canonicalContainerConsumer = ["getattr", "print", "vars"].includes(simpleCallee) &&
      !getLatestScopedAssignmentEvent(source, simpleCallee, openIndex, scopes, "python");
    for (const argument of splitTopLevelCallArguments(body)) {
      const capability = resolveCapabilityExpression(argument, openIndex);
      if (capability?.type === "loader") escapedLoader = true;
      if (capability?.type === "container" && !canonicalContainerConsumer) escapedLoader = true;
      if (!capability && !canonicalContainerConsumer &&
          (hasLiveLoaderReference(argument, openIndex) || hasEscapingContainerReference(argument, openIndex))) {
        escapedLoader = true;
      }
    }
  }
  return unsupportedLoad || escapedLoader;
}

function hasUnsupportedInlineInterpreterBoundary(command) {
  const source = String(command || "");
  for (const segment of splitCommandSegments(source)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const normalizedStage = unwrapPowerShellCommandWrapper(String(stage || "").trim());
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage));
      const kind = getShellInterpreterKind(tokens);
      if (kind && hasUnownedInterpreterProcessBoundary(normalizedStage)) return true;
      if (kind === "node") {
        const scripts = getInterpreterInlineSourceDescriptors(tokens, kind).map((descriptor) => descriptor.source);
        if (scripts.some((script) =>
          hasRuntimeGitEnvironmentMutation(script) ||
          hasRuntimeNodeOptionsEnvironmentMutation(script) ||
          hasUnsupportedNodeProcessConstruction(script) ||
          hasDynamicInterpreterGitSubcommand(script))) return true;
      } else if (kind === "python") {
        const script = String(getInterpreterInlineSourceToken(tokens, kind) || "");
        if (hasRuntimeGitEnvironmentMutation(script) ||
            hasRuntimeNodeOptionsEnvironmentMutation(script) ||
            hasUnsupportedPythonModuleLoad(script) ||
            hasUnsupportedPythonProcessConstruction(script) ||
            hasUnresolvedInterpreterProcessBoundary(script) ||
            hasDynamicInterpreterGitSubcommand(script)) return true;
      }
      const executable = tokens.length > 0 ? normalizeAgentValue(getExecutableBasename(tokens[0])) : "";
      if ((executable === "cmd" || executable === "cmd.exe")) {
        const nested = getCmdShellArgument(tokens, false);
        if (/\bif\s+(?:not\s+)?exist\b/iu.test(nested) && /![^!]+!/u.test(nested)) return true;
      }
    }
  }
  return false;
}

function hasUnsupportedDirectProcessBoundary(command) {
  const rawSource = String(command || "");
  if (/\b(?:start-process|saps|start)\s+\([^)]*\+[^)]*\)/iu.test(rawSource)) return true;
  const source = materializePowerShellComSpecAliases(rawSource);
  const commandSurface = stripHeredocBodiesAndTerminators(source);
  const canonicalPowerShellGhRepoMerge = isCanonicalPowerShellGhRepoMerge(commandSurface);
  const powerShellAliases = new Map();
  const uncertainPowerShellAliases = new Set();
  const shellAliases = new Map();
  if (hasUnownedStdinScriptPipeline(source)) return true;
  if (hasRuntimeNodeOptionsEnvironmentMutation(commandSurface)) return true;
  if (hasUnownedNodeCommandPrelude(commandSurface)) return true;
  for (const segmentEntry of splitCommandSegmentsWithSeparators(commandSurface)) {
    const pipelineStages = splitCommandPipelineStages(segmentEntry.segment);
    const aliasStateUpdateIsDeterministic =
      !["&&", "||"].includes(segmentEntry.separatorBefore) && pipelineStages.length === 1;
    for (let stageIndex = 0; stageIndex < pipelineStages.length; stageIndex += 1) {
      const stage = pipelineStages[stageIndex];
      const normalizedStage = unwrapShellExecutableControlFlowPrefix(
        unwrapPowerShellCommandWrapper(String(stage || "").trim()),
      );
      const rawTokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage));
      const rawExecutable = normalizeExecutableName(rawTokens[0] || "");
      const rawNestedPowerShell = isPowerShellExecutable(rawExecutable)
        ? getPowerShellNestedCommand(rawTokens)
        : "";
      const rawEvaluationTokens = rawNestedPowerShell
        ? getPowerShellWrapperPrefixTokens(rawTokens)
        : rawTokens;
      const hasCanonicalReviewSubstitution = isCanonicalRule13CommandSubstitutionStage(normalizedStage);
      const rawHasUnresolvedEvaluation = isPowerShellStartProcessExecutable(rawExecutable)
        ? hasUnresolvedPowerShellStartProcessArgumentEvaluation(rawEvaluationTokens, normalizedStage)
        : hasUnresolvedPowerShellArgumentEvaluation(rawEvaluationTokens) && !hasCanonicalReviewSubstitution;
      if (rawHasUnresolvedEvaluation) return true;
      const aliasTokens = resolveStaticDirectAliasTokens(
        rawTokens,
        powerShellAliases,
        uncertainPowerShellAliases,
        shellAliases,
        aliasStateUpdateIsDeterministic,
      );
      if (aliasTokens === null) return true;
      const tokens = aliasTokens;
      const executable = normalizeExecutableName(tokens[0] || "");
      if (!executable) continue;
      const nestedPowerShell = isPowerShellExecutable(executable)
        ? getPowerShellNestedCommand(tokens)
        : "";
      const evaluationTokens = nestedPowerShell
        ? getPowerShellWrapperPrefixTokens(tokens)
        : tokens;
      const hasUnresolvedEvaluation = isPowerShellStartProcessExecutable(executable)
        ? hasUnresolvedPowerShellStartProcessArgumentEvaluation(evaluationTokens, normalizedStage)
        : hasUnresolvedPowerShellArgumentEvaluation(evaluationTokens) && !hasCanonicalReviewSubstitution;
      if (hasUnresolvedEvaluation) {
        return true;
      }
      if (isCanonicalRule13StartProcessStage(normalizedStage, tokens) ||
          isCanonicalLiteralProducerXargsReviewStage(
            pipelineStages[stageIndex - 1] || "",
            normalizedStage,
            tokens,
          ) ||
          hasCanonicalReviewSubstitution ||
          isCanonicalRule13EmptyGitCwdStage(normalizedStage)) {
        continue;
      }
      if (isCanonicalUnprotectedPowerShellEnvironmentStage(normalizedStage)) continue;
      if (!canonicalPowerShellGhRepoMerge && isUnownedPowerShellStage(normalizedStage, tokens)) {
        return true;
      }
      if ((executable === "node" || executable === "nodejs") &&
          hasNodeStartupCodeConfiguration(tokens, commandSurface)) return true;
      if (executable === "git") {
        const hasInlineAliasConfiguration = /\balias\.[A-Za-z0-9._-]+\b/iu.test(normalizedStage) &&
          (/\bGIT_CONFIG_(?:COUNT|KEY_[0-9]+|VALUE_[0-9]+)\b/iu.test(normalizedStage) ||
           /--config-env(?:=|\s)/iu.test(normalizedStage) ||
           /(?:^|\s)-c(?:=|\s)[^;&\r\n]*\balias\./iu.test(normalizedStage));
        const hasCanonicalCommandLocalAlias = hasInlineAliasConfiguration &&
          !hasCommandLocalGitAliasConfiguration(normalizedStage);
        const hasConfiguredReviewAlias = hasConfiguredGitReviewLifecycleAlias(normalizedStage, process.cwd());
        const hasConfiguredReadOnlyAlias = isCanonicalConfiguredReadOnlyGitAliasInvocation(tokens, process.cwd());
        const hasCanonicalReviewShellAlias = isCanonicalCommandLocalGitShellReviewAlias(tokens);
        const hasUnsafeDirectEnvironment = hasDirectGitProcessEnvironment(normalizedStage) &&
          !hasCanonicalCommandLocalAlias && !hasCanonicalReviewShellAlias;
        if (hasUnsafeDirectEnvironment ||
            (hasGitExternalProcessConfiguration(tokens) && !hasCanonicalReviewShellAlias)) return true;
        if (!hasCanonicalCommandLocalAlias && !hasConfiguredReviewAlias &&
            !hasConfiguredReadOnlyAlias && !hasCanonicalReviewShellAlias) {
          const gitProcessDecision = classifyStaticProcessInvocation("git", tokens.slice(1), normalizedStage);
          if (gitProcessDecision !== INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY &&
              gitProcessDecision !== INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED) return true;
        }
      }
      if (executable === "rg" && hasRgExternalProcessConfiguration(tokens)) return true;
      if (executable === "xargs") {
        const nestedTokens = unwrapEnvCommandTokens(getNormalizedXargsCommandTokens(tokens));
        const nestedExecutable = normalizeExecutableName(nestedTokens[0] || "");
        const finiteSafeTargets = new Set(["", "echo", "printf"]);
        if (finiteSafeTargets.has(nestedExecutable)) continue;
        const result = classifyStaticProcessInvocation(nestedExecutable, nestedTokens.slice(1), nestedTokens.join(" "));
        if (result === INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY ||
            result === INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED) continue;
        return true;
      }
      if (!isOwnedDirectExecutable(executable)) {
        if ((executable === "npm" || executable === "cargo") &&
            tokens.length === 2 && normalizeAgentValue(tokens[1]) === "--version") continue;
        const nestedExecutable = tokens.slice(1).some((value) => {
          const candidate = normalizeExecutableName(value);
          return candidate === "codex" || isNestedShellProcessLauncher(candidate);
        });
        if (nestedExecutable ||
            /\bcodex(?:\.exe)?\b[\s"']+(?:exec|e|--sandbox)\b/iu.test(normalizedStage)) return true;
        return true;
      }
      if (isPowerShellExecutable(executable)) {
        const nestedCommand = nestedPowerShell;
        if (nestedCommand && nestedCommand !== normalizedStage && hasUnsupportedDirectProcessBoundary(nestedCommand)) {
          return true;
        }
      }
      if (executable === "cmd") {
        const nestedCommand = getCmdShellArgument(tokens, false);
        if (nestedCommand && nestedCommand !== normalizedStage && hasUnsupportedDirectProcessBoundary(nestedCommand)) {
          return true;
        }
      }
      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        if (nestedCommand && nestedCommand !== normalizedStage && hasUnsupportedDirectProcessBoundary(nestedCommand)) {
          return true;
        }
      }
      if (DIRECT_PROCESS_TRAMPOLINE_TOOLS.has(executable)) return true;
      if (executable === "forfiles") {
        const result = classifyStaticProcessInvocation(executable, tokens.slice(1), normalizedStage);
        if (result !== INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY &&
            result !== INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED) return true;
      }
    }
  }
  return false;
}

function isCanonicalFlatReviewLifecycleTokens(tokens) {
  if (!Array.isArray(tokens) || tokens.length === 0) return false;
  const executable = normalizeExecutableName(tokens[0] || "");
  if (executable === "git") {
    const subcommandIndex = findGitSubcommandIndex(tokens);
    if (subcommandIndex < 1 ||
        !hasOnlyCanonicalGitGlobalArguments(tokens, subcommandIndex) ||
        hasGitExternalProcessConfiguration(tokens)) return false;
    return isReviewGatedGitSubcommand(
      getGitSubcommandName(tokens, subcommandIndex),
      tokens,
      subcommandIndex,
    );
  }
  return executable === "gh" && isGhTokenLifecycleCommand(tokens);
}

function hasOnlyFinitePowerShellStartProcessReviewOptions(tokens) {
  const allowedNamedOptions = new Set([
    "-argumentlist", "-args", "-file", "-filepath",
    "-nonewwindow", "-wait", "-workingdirectory",
  ]);
  for (let index = 1; index < tokens.length; index += 1) {
    if (isQuotedCommandToken(tokens[index])) continue;
    const raw = stripOuterQuotes(String(tokens[index] || ""));
    const normalized = normalizeAgentValue(raw);
    if (!normalized.startsWith("-") || normalized.startsWith("--") || /^-[a-z],?$/u.test(normalized)) continue;
    const optionName = normalized.split(/[:=]/u, 1)[0];
    if (!allowedNamedOptions.has(optionName)) return false;
  }
  return true;
}

function isCanonicalRule13StartProcessStage(stage, tokens) {
  const executable = normalizeExecutableName(tokens[0] || "");
  if (!isPowerShellStartProcessExecutable(executable) ||
      !/^\s*(?:start-process|saps|start)\s+(?:(?:-(?:file|filepath)(?::|\s+))?)(?:["']?(?:git|gh)(?:\.exe)?["']?|\(\s*get-command\s+(?:git|gh)(?:\.exe)?\s*\))(?=\s|$)/iu.test(String(stage || "")) ||
      hasUnresolvedPowerShellStartProcessArgumentEvaluation(tokens, stage) ||
      !hasOnlyFinitePowerShellStartProcessReviewOptions(tokens)) return false;
  const invocation = getPowerShellStartProcessInvocation(tokens);
  const nestedTokens = tokenizeCommandLine(invocation.command || "");
  return isCanonicalFlatReviewLifecycleTokens(nestedTokens);
}

function getLiteralPrintfArgv(stage) {
  const match = /^\s*printf\s+(["'])([\s\S]*)\1\s*$/u.exec(String(stage || ""));
  if (!match) return null;
  const payload = String(match[2] || "")
    .replace(/\\[rn]/gu, " ")
    .trim();
  if (!payload || /[$`;&|<>(){}\r\n]/u.test(payload)) return null;
  const argv = tokenizeCommandLine(payload);
  return argv.length > 0 ? argv : null;
}

function isCanonicalRule13EmptyGitCwdStage(stage) {
  const source = String(stage || "").trim();
  if (!/^git(?:\.exe)?\b/iu.test(source) || /[;&|<>$`(){}\r\n]/u.test(source)) return false;
  let sawEffectiveCwd = false;
  let sawEmptyNoop = false;
  const materialized = source.replace(/\s-C\s+(["'])([^"']*)\1/gu, (match, _quote, value) => {
    if (String(value || "").trim()) {
      sawEffectiveCwd = true;
      return match;
    }
    if (!sawEffectiveCwd) return match;
    sawEmptyNoop = true;
    return "";
  });
  return sawEmptyNoop && isCanonicalFlatReviewLifecycleTokens(tokenizeCommandLine(materialized));
}

function isCanonicalLiteralProducerXargsReviewStage(previousStage, stage, tokens) {
  if (normalizeExecutableName(tokens[0] || "") !== "xargs") return false;
  const producedArgv = getLiteralPrintfArgv(previousStage);
  if (!producedArgv) return false;
  const nestedTokens = getNormalizedXargsCommandTokens(tokens);
  if (nestedTokens.length === 0) return false;
  const nestedExecutable = normalizeExecutableName(nestedTokens[0] || "");
  if (nestedExecutable === "git" || nestedExecutable === "gh") {
    return isCanonicalFlatReviewLifecycleTokens([...nestedTokens, ...producedArgv]);
  }
  if (!isShellCommandExecutable(nestedExecutable)) return false;
  const normalizedStage = normalizeAgentValue(String(stage || ""));
  if (!/\bxargs\s+-i\{\}\s+(?:sh|bash|zsh)\s+-c\b/u.test(normalizedStage)) return false;
  const nestedCommand = getShellCommandArgument(nestedTokens);
  if (!nestedCommand || /[$`;&|<>()[\]\r\n]/u.test(nestedCommand)) return false;
  const materialized = nestedCommand.replace(/\{\}/gu, producedArgv.join(" "));
  return isCanonicalFlatReviewLifecycleTokens(tokenizeCommandLine(materialized));
}

function isCanonicalRule13CommandSubstitutionStage(stage) {
  const substitutions = getShellCommandSubstitutionCommands(stage);
  if (substitutions.length !== 1 ||
      !isCanonicalFlatReviewLifecycleTokens(tokenizeCommandLine(substitutions[0]))) return false;
  const masked = String(stage || "").replace(`$(${substitutions[0]})`, "WINSMUX_STATIC_REVIEW_RESULT");
  const tokens = tokenizeCommandLine(masked);
  return tokens.length > 0 && STATIC_NON_EXECUTOR_TOOL_ALLOWLIST.has(normalizeExecutableName(tokens[0] || "")) &&
    !/[$`;&|<>(){}\r\n]/u.test(masked.replace("WINSMUX_STATIC_REVIEW_RESULT", ""));
}

function isCanonicalCommandLocalGitShellReviewAlias(tokens) {
  if (normalizeExecutableName(tokens[0] || "") !== "git") return false;
  const subcommandIndex = findGitSubcommandIndex(tokens);
  if (subcommandIndex < 1 || tokens.length !== subcommandIndex + 1) return false;
  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex] || ""));
  const aliasCommand = getGitShellAliasCommand(tokens, subcommandIndex, subcommand);
  if (!aliasCommand || /[;&|<>$`(){}\r\n]/u.test(aliasCommand)) return false;
  let aliasConfigCount = 0;
  for (let index = 1; index < subcommandIndex; index += 1) {
    const raw = stripOuterQuotes(String(tokens[index] || ""));
    if (raw === "-c" && index + 1 < subcommandIndex) {
      const value = stripOuterQuotes(String(tokens[++index] || ""));
      if (!/^alias\.[A-Za-z0-9_.-]+=/iu.test(value)) return false;
      aliasConfigCount += 1;
      continue;
    }
    return false;
  }
  return aliasConfigCount === 1 && isCanonicalFlatReviewLifecycleTokens(tokenizeCommandLine(aliasCommand));
}

function resolveStaticDirectAliasTokens(
  inputTokens,
  powerShellAliases,
  uncertainPowerShellAliases,
  shellAliases,
  aliasStateUpdateIsDeterministic = true,
) {
  const executable = normalizeExecutableName(inputTokens[0] || "");
  if (["set-alias", "sal", "new-alias", "nal"].includes(executable)) {
    const definition = getSetAliasDefinition(inputTokens);
    if (definition.aliasName) {
      const isCanonicalSetAlias = ["set-alias", "sal"].includes(executable) &&
        definition.canonicalSyntax;
      if (!aliasStateUpdateIsDeterministic || !isCanonicalSetAlias) {
        powerShellAliases.delete(definition.aliasName);
        uncertainPowerShellAliases.add(definition.aliasName);
      } else if (uncertainPowerShellAliases.has(definition.aliasName)) {
        powerShellAliases.delete(definition.aliasName);
      } else if (["git", "git.exe", "gh", "gh.exe"].includes(definition.aliasTarget)) {
        powerShellAliases.set(definition.aliasName, normalizeExecutableName(definition.aliasTarget));
      } else {
        powerShellAliases.delete(definition.aliasName);
      }
    }
    return [];
  }
  if (executable === "alias") {
    const definition = getShellAliasDefinition(inputTokens);
    if (definition.aliasName) {
      if (aliasStateUpdateIsDeterministic) shellAliases.set(definition.aliasName, definition);
      else shellAliases.delete(definition.aliasName);
    }
    return [];
  }
  if (executable === "shopt") return [];
  if (powerShellAliases.has(executable)) return [powerShellAliases.get(executable), ...inputTokens.slice(1)];
  const expansion = expandShellAliasInvocation(inputTokens, shellAliases);
  if (expansion.unresolved) return null;
  return expansion.matched ? expansion.tokens : inputTokens;
}

function isCanonicalUnprotectedPowerShellEnvironmentStage(stage) {
  const literal = String.raw`(?:'(?:[^']|'')*'|"[^"$\x60]*"|[A-Za-z0-9_./:\\-]+)`;
  const source = String(stage || "").trim();
  const positional = new RegExp(
    String.raw`^(?:si|set-item|ni|new-item)\s+Env:\\?([A-Za-z_][A-Za-z0-9_]*)\s+(?:-Value\s+)?${literal}$`,
    "iu",
  ).exec(source);
  const byPath = new RegExp(
    String.raw`^(?:si|set-item|ni|new-item)\s+-Path(?::|\s+)Env:\\?([A-Za-z_][A-Za-z0-9_]*)\s+-Value(?::|\s+)${literal}$`,
    "iu",
  ).exec(source);
  const match = positional || byPath;
  if (!match) return false;
  return !/^(?:GIT_|GH_|NODE_OPTIONS$|COMSPEC$|PATH$|PATHEXT$)/iu.test(match[1]);
}

function isCanonicalPowerShellGhRepoMerge(source) {
  const segments = splitCommandSegments(String(source || ""));
  if (segments.length !== 2) return false;
  const assignment = /^\$env:GH_REPO\s*=\s*(["'])([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\1$/iu.exec(segments[0].trim());
  if (!assignment) return false;
  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(segments[1]));
  return normalizeExecutableName(tokens[0] || "") === "gh" && isReviewGatedCommand(segments[1]);
}

function isUnownedPowerShellStage(stage, tokens) {
  const source = String(stage || "").trim();
  const executable = normalizeExecutableName(tokens[0] || "");
  if (/^(?:\$|\[|@(?:\(|\{)|\(|&\s|\.\s)/u.test(source)) return true;
  if (/^[a-z][a-z0-9]*-[a-z][a-z0-9-]*$/u.test(executable)) return true;
  return new Set([
    "clc", "cli", "iex", "ni", "ri", "sc", "set", "si",
    "class", "filter", "for", "foreach", "function", "if", "param", "switch", "trap", "try", "using", "while",
  ]).has(executable);
}

function hasUnownedNodeCommandPrelude(source) {
  const segments = splitCommandSegments(String(source || ""));
  for (let segmentIndex = 1; segmentIndex < segments.length; segmentIndex += 1) {
    for (const stage of splitCommandPipelineStages(segments[segmentIndex])) {
      const normalizedStage = unwrapPowerShellCommandWrapper(String(stage || "").trim());
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapShellExecutableControlFlowPrefix(normalizedStage)));
      const executable = normalizeExecutableName(tokens[0] || "");
      if (executable === "node" || executable === "nodejs") return true;
    }
  }
  return false;
}

function hasUnresolvedPowerShellArgumentEvaluation(tokens) {
  return tokens.slice(1).some((token) => {
    const value = stripOuterQuotes(String(token || "").trim());
    return /\$\(|@\(/u.test(value) || /^\(/u.test(value);
  });
}

function hasUnresolvedPowerShellStartProcessArgumentEvaluation(_tokens, source) {
  let maskedSource = maskCanonicalPowerShellArgumentArrays(source);
  maskedSource = maskedSource
    .replace(/\(\s*get-command\s+(?:git|gh|codex)\s*\)/giu, "__WINSMUX_STATIC_COMMAND__")
    .replace(/'(?:[^']|'')*'/gu, "__WINSMUX_STATIC_STRING__")
    .replace(/"[^"$\x60]*"/gu, "__WINSMUX_STATIC_STRING__");
  if (/\$(?:env:comspec|\{env:comspec\})|%comspec%/iu.test(maskedSource)) return true;
  return /\$\(|@\(|@\{|<#|#>|[()[\]{}&]/u.test(maskedSource);
}

function maskCanonicalPowerShellArgumentArrays(value) {
  const source = String(value || "");
  const literal = String.raw`(?:'(?:[^']|'')*'|"[^"$\x60]*"|[A-Za-z0-9_./:\\-]+)`;
  const staticArray = String.raw`@\(\s*(?:${literal}(?:\s*,\s*${literal})*)?\s*\)`;
  return source.replace(
    new RegExp(String.raw`-(?:argumentlist|args)(?::|=|\s+)${staticArray}`, "giu"),
    "-ArgumentList __WINSMUX_STATIC_ARRAY__",
  );
}

function hasUnownedStdinScriptPipeline(source) {
  return splitCommandSegments(String(source || "")).some((segment) => {
    const stages = splitCommandPipelineStages(segment);
    if (stages.length > 1 && stages.slice(1).some((stage) => isStdinScriptConsumerStage(stage))) {
      return true;
    }
    return stages.some((stage) =>
      isStdinScriptConsumerStage(stage) && /<<(?!<)|<\s*(?:<\(|[^>&])|<\(/u.test(stage));
  });
}

function isOwnedDirectExecutable(executable) {
  const normalized = normalizeExecutableName(executable);
  if (/^python[0-9]+(?:\.[0-9]+)?$/u.test(normalized)) return true;
  return new Set([
    ":", "bash", "cat", "cd", "cmd", "codex", "curl", "declare", "echo", "export", "false", "gh", "git", "grep", "jq", "local", "ls", "node", "nodejs", "pwd",
    "powershell", "printf", "pwsh", "py", "python", "python3", "rg", "rustc", "saps", "sh", "start", "start-process", "type", "typeset", "unset", "where",
    "tee", "true", "which", "winsmux", "xargs", "zsh",
  ]).has(normalized);
}

function hasUnresolvedInterpreterProcessBoundary(command) {
  const source = String(command || "");
  const scopes = buildFunctionScopeIndex(source);
  const nodeMarker = /["'](?:node:)?child_process["']/u.test(source);
  const pythonCode = maskPythonNonCode(source);
  const pythonMarker = /\bsubprocess\b|\bos\.system\s*\(/iu.test(pythonCode);
  if (!nodeMarker && !pythonMarker) {
    return false;
  }
  if (/\bReflect\.(?:get|set)\s*\(/u.test(source) ||
      /\.\.\.\s*(?:require|import)\(\s*["'](?:node:)?child_process["']\s*\)/u.test(source)) {
    return true;
  }
  const inspectCalls = (calls, language) => {
    if (calls.length === 0) {
      return true;
    }
    for (const call of calls) {
      if (normalizeAgentValue(call.method) === "unknown") {
        return true;
      }
      const body = getBalancedCallBody(source, call.openIndex);
      if (body === null) {
        return true;
      }
      const args = splitTopLevelCallArguments(body);
      const method = normalizeAgentValue(call.method);
      if (method === "exec" || method === "execsync" || method === "system") {
        if (evaluateScopedStaticStringExpression(args[0], source, call.openIndex, scopes, language) === null) {
          return true;
        }
        continue;
      }
      const elements = getArgumentContainerElements(args[language === "python" ? 0 : 1], source, call.openIndex, scopes, language);
      const toolExpression = language === "python" ? elements?.[0] : args[0];
      if (!elements || evaluateScopedStaticStringExpression(toolExpression, source, call.openIndex, scopes, language) === null ||
          elements.some((element) => evaluateScopedStaticStringExpression(element, source, call.openIndex, scopes, language) === null)) {
        return true;
      }
    }
    return false;
  };
  return (nodeMarker && inspectCalls(getNodeChildProcessCalls(source), "javascript")) ||
    (pythonMarker && inspectCalls(getPythonProcessCalls(pythonCode), "python"));
}

function hasConservativeProtectedCmdBoundary(command) {
  const source = String(command || "");
  if (!/\bcmd(?:\.exe)?\b/iu.test(source) ||
      !/\b(?:git|codex)(?:\.exe)?\b/iu.test(source)) {
    return false;
  }
  return /\b(?:setlocal|endlocal)\b|\bif\s+(?:not\s+)?(?:defined|exist|errorlevel|cmdextversion)\b/iu.test(source) ||
    (/&&[\s\S]*\|\||\|\|[\s\S]*&&/u.test(source) && !/\/c\s+["']?\s*set\b/iu.test(source));
}

function isReviewGatedCommand(command) {
  if (hasConservativeProtectedInterpreterBoundary(command, "git") || hasConservativeProtectedCmdBoundary(command)) {
    return true;
  }
  if (hasCommandLocalGitAliasConfiguration(command)) {
    return true;
  }
  if (hasDynamicShellReviewGatedArguments(command) || hasShellArrayReviewGatedCommand(command)) {
    return true;
  }

  const powerShellComSpecCommand = materializePowerShellComSpecAliases(command);
  if (powerShellComSpecCommand !== command) {
    return isReviewGatedCommand(powerShellComSpecCommand);
  }

  const materializedCommand = materializeConstantExecutableSubstitutions(command);
  if (materializedCommand !== command && isGitCommitOrMergeCommandLine(materializedCommand)) {
    return true;
  }

  const groupedCommand = unwrapShellGroupingWrapper(command);
  if (groupedCommand !== String(command || "").trim() && isReviewGatedCommand(groupedCommand)) {
    return true;
  }

  for (const blockBody of getBraceBlockBodies(command)) {
    if (isReviewGatedCommand(blockBody)) {
      return true;
    }
  }

  for (const substitutionCommand of getShellCommandSubstitutionCommands(command)) {
    if (isReviewGatedCommand(substitutionCommand)) {
      return true;
    }
  }

  for (const segment of splitCommandSegments(command)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const executableStage = unwrapShellExecutableControlFlowPrefix(stage);
      if (executableStage && executableStage !== stage.trim() && isReviewGatedCommand(executableStage)) {
        return true;
      }
    }
  }

  if (hasPowerShellGitAliasLifecycleCommand(command, true)) {
    return true;
  }

  if (hasXargsGitLifecycleCommand(command, true)) {
    return true;
  }

  for (const indirectCommand of getConstantShellStdinCommands(command)) {
    if (isReviewGatedCommand(indirectCommand)) {
      return true;
    }
  }

  return isGitCommitOrMergeCommandLine(command) ||
         isGhPrMergeCommandLine(command) ||
         isGhApiMergeCommandLine(command);
}

function getConstantShellStdinCommands(command) {
  const source = String(command || "");
  const commands = [];
  const pipePattern = /\b(?:echo|printf(?:\s+%s)?)\s+(['"])([\s\S]*?)\1\s*\|\s*(?:bash|sh|zsh|pwsh|powershell)(?:\.exe)?\b/giu;
  const hereStringPattern = /\b(?:bash|sh|zsh)(?:\.exe)?\b[^;\r\n]*?<<<\s*(['"])([\s\S]*?)\1/giu;
  for (const pattern of [pipePattern, hereStringPattern]) {
    for (const match of source.matchAll(pattern)) {
      if (match[2]) {
        commands.push(match[2]);
      }
    }
  }
  return commands;
}

function isGitCommitOrMergeCommandLine(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const normalizedStage = unwrapPowerShellCommandWrapper(stage);
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage)));
      if (execution.nestedCommand) {
        return isReviewGatedCommand(execution.nestedCommand);
      }
      const tokens = execution.tokens;
      if (tokens.length === 0) {
        return false;
      }

      if (isDynamicShellExecutableToken(tokens[0])) {
        const syntheticTokens = ["git", ...tokens.slice(1)];
        const syntheticSubcommandIndex = findGitSubcommandIndex(syntheticTokens);
        if (syntheticSubcommandIndex >= 0) {
          const syntheticSubcommand = getGitSubcommandName(syntheticTokens, syntheticSubcommandIndex);
          return isReviewGatedGitSubcommand(syntheticSubcommand, syntheticTokens, syntheticSubcommandIndex);
        }
      }

      const executable = getExecutableBasename(tokens[0]);
      if (executable === "cmd" || executable === "cmd.exe") {
        const nestedCommand = getCmdShellArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isPowerShellExecutable(executable)) {
        const nestedCommand = getPowerShellNestedCommand(tokens);
        return nestedCommand
          ? isReviewGatedCommand(nestedCommand) || getBraceBlockBodies(nestedCommand).some(isReviewGatedCommand)
          : false;
      }

      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (isPowerShellStartProcessExecutable(executable)) {
        if (hasPowerShellStartProcessLifecycleHint(normalizedStage)) {
          return true;
        }
        const nestedCommand = getPowerShellStartProcessCommand(tokens);
        return nestedCommand ? isReviewGatedCommand(nestedCommand) : false;
      }

      if (hasInterpreterReviewGatedGitLifecycleCommand(normalizedStage, tokens)) {
        return true;
      }

      if (executable !== "git" && executable !== "git.exe") {
        return false;
      }

      const gitSubcommandIndex = findGitSubcommandIndex(tokens);
      if (gitSubcommandIndex < 0) {
        return false;
      }

      const gitSubcommand = getGitSubcommandName(tokens, gitSubcommandIndex);
      return isReviewGatedGitSubcommand(gitSubcommand, tokens, gitSubcommandIndex);
    }));
}

function isGhPrMergeCommandLine(command) {
  return splitCommandSegments(command).some((segment) =>
    splitCommandPipelineStages(segment).some((stage) => {
      const normalizedStage = unwrapPowerShellCommandWrapper(stage);
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage));
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

      if (isPowerShellStartProcessExecutable(executable)) {
        if (hasPowerShellStartProcessLifecycleHint(normalizedStage)) {
          return true;
        }
        const nestedCommand = getPowerShellStartProcessCommand(tokens);
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
      const normalizedStage = unwrapPowerShellCommandWrapper(stage);
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage));
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

      if (isPowerShellStartProcessExecutable(executable)) {
        if (hasPowerShellStartProcessLifecycleHint(normalizedStage)) {
          return true;
        }
        const nestedCommand = getPowerShellStartProcessCommand(tokens);
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
  return splitCommandSegmentsWithSeparators(command).map((entry) => entry.segment);
}

function splitCommandSegmentsWithSeparators(command) {
  const segments = [];
  let current = "";
  let quote = "";
  let parenDepth = 0;
  let braceDepth = 0;
  let separatorBefore = "";

  const pushSegment = (separatorAfter) => {
    if (current.trim() !== "") {
      segments.push({
        segment: current.trim(),
        separatorBefore,
        separatorAfter,
      });
    }
    current = "";
    separatorBefore = separatorAfter;
  };

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];
    const nextChar = command[index + 1];

    if (quote) {
      if (isShellQuoteTerminator(command, index, quote)) {
        quote = "";
      }
      current += char;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(command, index, char);
      current += char;
      continue;
    }

    if (char === "(") {
      parenDepth += 1;
      current += char;
      continue;
    }

    if (char === ")" && parenDepth > 0) {
      parenDepth -= 1;
      current += char;
      continue;
    }

    if (char === "{" && command[index - 1] !== "$") {
      braceDepth += 1;
      current += char;
      continue;
    }

    if (char === "}" && braceDepth > 0) {
      braceDepth -= 1;
      current += char;
      continue;
    }

    if ((char === "\r" || char === "\n" || char === ";") && parenDepth === 0 && braceDepth === 0) {
      pushSegment(";");
      continue;
    }

    if (((char === "&" && nextChar === "&") || (char === "|" && nextChar === "|")) && parenDepth === 0 && braceDepth === 0) {
      pushSegment(char + nextChar);
      index += 1;
      continue;
    }

    if (char === "&" && command[index - 1] !== ">" && command[index - 1] !== "|" && parenDepth === 0 && braceDepth === 0) {
      pushSegment("&");
      continue;
    }

    current += char;
  }

  pushSegment("");

  return segments;
}

function splitCommandPipelineStages(command) {
  const segments = [];
  let current = "";
  let quote = "";
  let parenDepth = 0;
  let braceDepth = 0;

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];
    const nextChar = command[index + 1];

    if (quote) {
      if (isShellQuoteTerminator(command, index, quote)) {
        quote = "";
      }
      current += char;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(command, index, char);
      current += char;
      continue;
    }

    if (char === "(") {
      parenDepth += 1;
      current += char;
      continue;
    }

    if (char === ")" && parenDepth > 0) {
      parenDepth -= 1;
      current += char;
      continue;
    }

    if (char === "{" && command[index - 1] !== "$") {
      braceDepth += 1;
      current += char;
      continue;
    }

    if (char === "}" && braceDepth > 0) {
      braceDepth -= 1;
      current += char;
      continue;
    }

    if (char === "|" && nextChar !== "|" && command[index - 1] !== "|" && parenDepth === 0 && braceDepth === 0) {
      if (current.trim() !== "") {
        segments.push(current.trim());
      }
      current = "";
      if (nextChar === "&") {
        index += 1;
      }
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
  let tokenStarted = false;

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];

    if (quote) {
      if (isShellQuoteTerminator(command, index, quote)) {
        quote = "";
      } else {
        current += char;
      }
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(command, index, char);
      tokenStarted = true;
      continue;
    }

    if (/\s/.test(char)) {
      if (tokenStarted) {
        tokens.push(current);
        current = "";
        tokenStarted = false;
      }
      continue;
    }

    current += char;
    tokenStarted = true;
  }

  if (tokenStarted) {
    tokens.push(current);
  }

  return tokens;
}

function getCmdShellArgument(tokens, materialize = true) {
  let delayedExpansion = false;
  for (let index = 1; index < tokens.length; index += 1) {
    const token = normalizeAgentValue(tokens[index]);
    if (token === "/v:on") {
      delayedExpansion = true;
      continue;
    }
    if (token === "/v:off") {
      delayedExpansion = false;
      continue;
    }
    if (token === "/c" || token === "/k") {
      const nestedCommand = stripLeadingCmdCallBuiltins(unescapeCmdCaretEscapes(tokens.slice(index + 1).join(" ")));
      return materialize ? getCmdDynamicLifecycleCommand(nestedCommand, delayedExpansion) || nestedCommand : nestedCommand;
    }

    if (token.startsWith("/c") || token.startsWith("/k")) {
      const inlineCommand = tokens[index].slice(2);
      const nestedCommand = stripLeadingCmdCallBuiltins(unescapeCmdCaretEscapes([inlineCommand, ...tokens.slice(index + 1)].filter(Boolean).join(" ")));
      return materialize ? getCmdDynamicLifecycleCommand(nestedCommand, delayedExpansion) || nestedCommand : nestedCommand;
    }

    const inlineSwitchIndex = Math.max(token.lastIndexOf("/c"), token.lastIndexOf("/k"));
    if (inlineSwitchIndex > 0) {
      const inlineCommand = tokens[index].slice(inlineSwitchIndex + 2);
      const nestedCommand = stripLeadingCmdCallBuiltins(unescapeCmdCaretEscapes([inlineCommand, ...tokens.slice(index + 1)].filter(Boolean).join(" ")));
      return materialize ? getCmdDynamicLifecycleCommand(nestedCommand, delayedExpansion) || nestedCommand : nestedCommand;
    }
  }

  return "";
}

function splitCmdConditionalStatements(command) {
  const source = String(command || "");
  const statements = [];
  let current = "";
  let quote = false;
  let precedingOperator = "";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (char === "^" && index + 1 < source.length) {
      current += char + source[index + 1];
      index += 1;
      continue;
    }
    if (char === '"') {
      quote = !quote;
      current += char;
      continue;
    }
    if (!quote && (char === "&" || char === "|")) {
      const operator = source[index + 1] === char ? char + char : char;
      statements.push({ operator: precedingOperator, text: current.trim() });
      current = "";
      precedingOperator = operator;
      if (operator.length === 2) {
        index += 1;
      }
      continue;
    }
    current += char;
  }
  statements.push({ operator: precedingOperator, text: current.trim() });
  return statements.filter((statement) => statement.text !== "");
}

function getCmdDynamicLifecycleCommand(command, delayedExpansion = true) {
  const source = String(command || "");
  for (const match of source.matchAll(/\bfor(?:\s+\/[A-Za-z]+)?\s+%%?([A-Za-z])\s+in\s*\(([^)]*)\)\s+do\s+@?%%?\1(?:\.exe)?\s+([^&|\r\n]+)/giu)) {
    const candidates = tokenizeCommandLine(match[2]).map(normalizeExecutableName);
    const args = tokenizeCommandLine(match[3]).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
    if (candidates.includes("codex") && args.some(isDeniedCodexMode)) {
      return "codex exec";
    }
    if (candidates.some((candidate) => /[%!]/u.test(candidate)) && args.some(isDeniedCodexMode) && /\bcodex(?:\.exe)?\b/iu.test(source)) {
      return "codex exec";
    }
  }
  if (/&&[\s\S]*\|\||\|\|[\s\S]*&&/u.test(source) &&
      !/^\s*set\b/iu.test(source) &&
      /(?:%[^%]+%|![^!]+!)[\s\S]*\b(?:commit|merge|push|update-ref|exec|--sandbox)\b/iu.test(source)) {
    return /\b(?:exec|--sandbox)\b/iu.test(source) ? "codex exec" : "git commit";
  }
  const assignments = new Map();
  let lastSucceeded = true;
  const gitTargetAssignments = new Map();
  const isLifecycle = (candidate) => isOperatorOnlyGitLifecycleCommand(candidate) ||
    isDirectCodexDispatch(candidate) || isGhPrMergeCommandLine(candidate) || isGhApiMergeCommandLine(candidate);
  for (const entry of splitCmdConditionalStatements(source)) {
    const shouldExecute = entry.operator === "&&"
      ? lastSucceeded !== false
      : entry.operator === "||"
      ? lastSucceeded !== true
      : true;
    if (!shouldExecute) {
      continue;
    }
    let statement = entry.text;
    const setLocalMatch = /^setlocal(?:\s+(EnableDelayedExpansion|DisableDelayedExpansion))?$/iu.exec(statement);
    if (setLocalMatch) {
      if (setLocalMatch[1]) {
        delayedExpansion = normalizeAgentValue(setLocalMatch[1]) === "enabledelayedexpansion";
      }
      lastSucceeded = true;
      continue;
    }
    const ifDefinedMatch = /^if\s+(not\s+)?defined\s+([A-Za-z_][A-Za-z0-9_]*)\s+([\s\S]+)$/iu.exec(statement);
    if (ifDefinedMatch) {
      const isDefined = assignments.has(normalizeAgentValue(ifDefinedMatch[2]));
      const shouldRun = ifDefinedMatch[1] ? !isDefined : isDefined;
      if (!shouldRun) {
        lastSucceeded = false;
        continue;
      }
      statement = ifDefinedMatch[3].trim();
    }
    const setMatch = /^(?:call\s+)?set\s+"?([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*?)"?$/iu.exec(statement);
    if (setMatch) {
      const value = expandCmdVariables(setMatch[2].trim(), assignments, delayedExpansion).value;
      const name = normalizeAgentValue(setMatch[1]);
      assignments.set(name, value);
      if (isGitEnvironmentName(name)) {
        gitTargetAssignments.set(name.toUpperCase(), value);
      }
      lastSucceeded = true;
      continue;
    }
    for (let pass = 0; pass < 8; pass += 1) {
      const expansion = expandCmdVariables(statement, assignments, delayedExpansion);
      statement = expansion.value;
      if (!expansion.replaced) {
        break;
      }
    }
    const expandedSetMatch = /^(?:call\s+)?set\s+"?([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*?)"?$/iu.exec(statement);
    if (expandedSetMatch) {
      const name = normalizeAgentValue(expandedSetMatch[1]);
      const value = expandedSetMatch[2].trim();
      assignments.set(name, value);
      if (isGitEnvironmentName(name)) {
        gitTargetAssignments.set(name.toUpperCase(), value);
      }
      lastSucceeded = true;
      continue;
    }
    const invocation = /^(?:call\s+)?(git|gh|codex)(?:\.exe)?\b([\s\S]*)$/iu.exec(statement);
    if (invocation) {
      const candidate = [invocation[1], invocation[2]].filter(Boolean).join(" ").trim();
      if (isLifecycle(candidate)) {
        const targetPrefix = [...gitTargetAssignments.entries()]
          .map(([name, value]) => `${name}=${JSON.stringify(value)}`)
          .join(" ");
        return [targetPrefix, candidate].filter(Boolean).join(" ");
      }
      lastSucceeded = null;
      continue;
    }
    const unresolved = /^(?:call\s+)?((?:%[^%]+%|![^!]+!))\s+([\s\S]*)$/u.exec(statement);
    if (!unresolved || (!delayedExpansion && unresolved[1].startsWith("!"))) {
      lastSucceeded = null;
      continue;
    }
    const variableName = /^[%!](?:([A-Za-z_][A-Za-z0-9_]*))/u.exec(unresolved[1])?.[1] || "";
    for (const executable of ["gh", "codex", "git"]) {
      const candidateAssignments = new Map(assignments);
      if (variableName) {
        candidateAssignments.set(normalizeAgentValue(variableName), executable);
      }
      const expandedExecutable = expandCmdVariables(unresolved[1], candidateAssignments, delayedExpansion).value;
      const candidate = `${expandedExecutable} ${unresolved[2]}`.trim();
      if (isLifecycle(candidate)) {
        return candidate;
      }
    }
    lastSucceeded = /^(?:echo|rem|setlocal|endlocal)\b/iu.test(statement) ? true : null;
  }
  return "";
}

function expandCmdVariables(value, assignments, delayedExpansion = true) {
  let replaced = false;
  const replacementExpanded = String(value || "").replace(
    /(!|%)([A-Za-z_][A-Za-z0-9_]*):([^=!%\r\n]*)=([^!%\r\n]*)\1/giu,
    (full, delimiter, rawName, searchValue, replacementValue) => {
      if (delimiter === "!" && !delayedExpansion) {
        return full;
      }
      const name = normalizeAgentValue(rawName);
      if (!assignments.has(name)) {
        return full;
      }
      replaced = true;
      const source = String(assignments.get(name));
      if (searchValue === "") {
        return source;
      }
      if (searchValue.startsWith("*")) {
        const needle = searchValue.slice(1);
        if (needle === "") {
          return `${replacementValue}${source}`;
        }
        const matchIndex = source.toLocaleLowerCase("en-US").indexOf(needle.toLocaleLowerCase("en-US"));
        return matchIndex < 0 ? source : `${replacementValue}${source.slice(matchIndex + needle.length)}`;
      }
      return source.replace(new RegExp(escapeRegex(searchValue), "giu"), replacementValue);
    },
  );
  const expanded = replacementExpanded.replace(
    /(!|%)([A-Za-z_][A-Za-z0-9_]*)(?::~(-?\d+)(?:,(-?\d+))?)?\1/giu,
    (full, delimiter, rawName, rawStart, rawLength) => {
      if (delimiter === "!" && !delayedExpansion) {
        return full;
      }
      const name = normalizeAgentValue(rawName);
      if (!assignments.has(name)) {
        return full;
      }
      replaced = true;
      const source = String(assignments.get(name));
      if (rawStart === undefined) {
        return source;
      }
      let start = Number.parseInt(rawStart, 10);
      if (start < 0) {
        start = Math.max(0, source.length + start);
      }
      if (rawLength === undefined) {
        return source.slice(start);
      }
      let length = Number.parseInt(rawLength, 10);
      if (length < 0) {
        length = Math.max(0, source.length - start + length);
      }
      return source.slice(start, start + length);
    },
  );
  return { value: expanded, replaced };
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

function getXargsCommandTokens(tokens) {
  const optionsWithValue = new Set([
    "-a",
    "--arg-file",
    "-d",
    "--delimiter",
    "-e",
    "-E",
    "--eof",
    "-I",
    "-i",
    "--replace",
    "-L",
    "--max-lines",
    "-n",
    "--max-args",
    "-P",
    "--max-procs",
    "-s",
    "--max-chars",
  ].map((option) => normalizeAgentValue(option)));

  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (!normalizedToken.startsWith("-")) {
      return tokens.slice(index);
    }

    const optionName = normalizedToken.includes("=")
      ? normalizedToken.slice(0, normalizedToken.indexOf("="))
      : normalizedToken;
    if (optionsWithValue.has(optionName) && !normalizedToken.includes("=")) {
      index += 1;
    }
  }

  return [];
}

function getNormalizedXargsCommandTokens(tokens) {
  return unwrapEnvCommandTokens(getXargsCommandTokens(tokens));
}

function hasShellWrappedXargsLifecycleCommand(tokens, source, reviewOnly) {
  const executable = normalizeExecutableName(tokens[0] || "");
  if (!isShellCommandExecutable(executable)) {
    return false;
  }

  const nestedCommand = getShellCommandArgument(tokens);
  if (!nestedCommand) {
    return false;
  }

  return reviewOnly
    ? isReviewGatedCommand(nestedCommand) || hasXargsLifecycleArgumentHint(source, true)
    : isOperatorOnlyGitLifecycleCommand(nestedCommand) || hasXargsLifecycleArgumentHint(source, false);
}

function getReviewGatedXargsCommandTargets(tokens, source, baseCwd, depth, inheritedGitEnvContext = {}) {
  const nestedTokens = getNormalizedXargsCommandTokens(tokens);
  const lifecycleHint = hasXargsLifecycleArgumentHint(source, true);
  const nestedExecutable = normalizeExecutableName(nestedTokens[0] || "");
  const fallbackTarget = baseCwd || process.cwd();

  if (nestedExecutable === "git") {
    const subcommandIndex = findGitSubcommandIndex(nestedTokens);
    const subcommand = subcommandIndex >= 0
      ? getGitSubcommandName(nestedTokens, subcommandIndex)
      : "";
    if (subcommandIndex < 0 || isReviewGatedGitSubcommand(subcommand, nestedTokens, subcommandIndex) || lifecycleHint) {
      const targetCwd = getGitGlobalCwdOption(nestedTokens, 0, baseCwd, inheritedGitEnvContext) || fallbackTarget;
      return { targetCwds: [targetCwd || "\0unresolved-xargs-git-target"], requiresBaseCwd: false, matched: true };
    }
  }

  if (nestedExecutable === "gh") {
    if (nestedTokens.length < 2 ||
        isGhPrMergeTokenCommand(nestedTokens) ||
        isGhApiMergeCommand(nestedTokens) ||
        isGhApiRefWriteCommand(nestedTokens) ||
        hasGhLifecycleArgumentHint(source)) {
      return { targetCwds: [fallbackTarget], requiresBaseCwd: false, matched: true };
    }
  }

  if (isShellCommandExecutable(nestedExecutable)) {
    const nestedCommand = getShellCommandArgument(nestedTokens);
    if (nestedCommand) {
      const nestedTargets = getReviewGatedCommandTargets(nestedCommand, baseCwd, depth + 1, inheritedGitEnvContext);
      if (nestedTargets.targetCwds.length > 0 || nestedTargets.requiresBaseCwd) {
        return { ...nestedTargets, matched: true };
      }

      if (lifecycleHint) {
        const materializedCommand = materializeXargsLifecyclePlaceholders(nestedCommand);
        const materializedTargets = getReviewGatedCommandTargets(materializedCommand, baseCwd, depth + 1, inheritedGitEnvContext);
        if (materializedTargets.targetCwds.length > 0 || materializedTargets.requiresBaseCwd) {
          return { ...materializedTargets, matched: true };
        }
      }
    }
  }

  if (isGitTokenLifecycleCommand(nestedTokens, true) ||
      isGhTokenLifecycleCommand(nestedTokens) ||
      hasShellWrappedXargsLifecycleCommand(nestedTokens, source, true) ||
      hasUnresolvedXargsLifecycleCommand(nestedTokens) ||
      lifecycleHint) {
    return { targetCwds: ["\0unresolved-xargs-review-target"], requiresBaseCwd: false, matched: true };
  }

  return { targetCwds: [], requiresBaseCwd: false, matched: false };
}

function materializeXargsLifecyclePlaceholders(command) {
  return String(command || "")
    .replace(/(["'])\{\}\1/gu, "commit")
    .replace(/\{\}/gu, "commit")
    .replace(/(["'])\$@\1/gu, "commit")
    .replace(/\$@/gu, "commit");
}

function hasXargsLifecycleArgumentHint(source, reviewOnly) {
  const normalized = normalizeAgentValue(String(source || ""));
  const hasXargsGit = /\bxargs\b[\s\S]*\bgit\b/u.test(normalized);
  const hasXargsGh = /\bxargs\b[\s\S]*\bgh\b/u.test(normalized);
  if (reviewOnly) {
    return (hasXargsGit && /\b(?:commit|merge)\b/u.test(normalized)) ||
      (hasXargsGh && hasGhLifecycleArgumentHint(source));
  }

  return (hasXargsGit && hasGitLifecycleArgumentHint(source)) ||
    (hasXargsGh && hasGhLifecycleArgumentHint(source));
}

function isPowerShellStartProcessExecutable(executable) {
  const normalized = normalizeExecutableName(executable);
  return normalized === "start-process" || normalized === "saps" || normalized === "start";
}

function getPowerShellStartProcessInvocation(tokens) {
  if (tokens.length < 2) {
    return { command: "", workingDirectory: "" };
  }

  let filePath = "";
  const workingDirectory = getPowerShellStartProcessWorkingDirectory(tokens);
  const argumentList = [];
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const token = normalizeAgentValue(rawToken);
    if (isPowerShellStartProcessWorkingDirectoryToken(token)) {
      index += 1;
      continue;
    }

    if (getInlinePowerShellStartProcessWorkingDirectory(rawToken)) {
      continue;
    }

    if (!filePath && /^\(?get-command$/u.test(token) && index + 1 < tokens.length) {
      filePath = stripOuterQuotes(tokens[index + 1]).replace(/\)+$/u, "");
      index += 1;
      continue;
    }

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
        const argumentToken = normalizeAgentValue(stripOuterQuotes(tokens[argumentIndex]));
        if (isPowerShellStartProcessWorkingDirectoryToken(argumentToken)) {
          argumentIndex += 1;
          continue;
        }
        if (getInlinePowerShellStartProcessWorkingDirectory(stripOuterQuotes(tokens[argumentIndex]))) {
          continue;
        }
        for (const argument of cleanPowerShellStartProcessArguments(tokens[argumentIndex])) {
          argumentList.push(argument);
        }
      }
      break;
    }

    const inlineArgumentList = /^-(?:argumentlist|args):(.+)$/iu.exec(rawToken);
    if (inlineArgumentList) {
      for (const inlineArgument of cleanPowerShellStartProcessArguments(inlineArgumentList[1])) {
        argumentList.push(inlineArgument);
      }
      for (let argumentIndex = index + 1; argumentIndex < tokens.length; argumentIndex += 1) {
        const argumentToken = normalizeAgentValue(stripOuterQuotes(tokens[argumentIndex]));
        if (isPowerShellStartProcessWorkingDirectoryToken(argumentToken)) {
          argumentIndex += 1;
          continue;
        }
        if (getInlinePowerShellStartProcessWorkingDirectory(stripOuterQuotes(tokens[argumentIndex]))) {
          continue;
        }
        for (const argument of cleanPowerShellStartProcessArguments(tokens[argumentIndex])) {
          argumentList.push(argument);
        }
      }
      break;
    }

    if (!filePath && !token.startsWith("-")) {
      filePath = stripOuterQuotes(tokens[index]);
      continue;
    }

    if (filePath && !token.startsWith("-")) {
      for (const argument of cleanPowerShellStartProcessArguments(tokens[index])) {
        argumentList.push(argument);
      }
    }
  }

  const joinedArguments = argumentList.filter(Boolean).join(" ").trim();
  const normalizedFilePath = stripOuterQuotes(filePath).replace(/^\(+|\)+$/gu, "");
  if (/^\$(?:env:comspec|\{env:comspec\})$/iu.test(normalizedFilePath) ||
      /^%comspec%$/iu.test(normalizedFilePath) ||
      /^\[(?:System\.)?Environment\]\s*::\s*GetEnvironmentVariable\s*\(\s*["']?ComSpec["']?\s*\)$/iu.test(normalizedFilePath)) {
    return {
      command: ["cmd", joinedArguments].filter(Boolean).join(" ").trim(),
      workingDirectory,
    };
  }
  if (isPowerShellVariableReference(filePath)) {
    if (hasGhLifecycleArgumentHint(joinedArguments)) {
      return {
        command: ["gh", joinedArguments].filter(Boolean).join(" ").trim(),
        workingDirectory,
      };
    }
    if (hasGitLifecycleArgumentHint(joinedArguments)) {
      return {
        command: ["git", joinedArguments].filter(Boolean).join(" ").trim(),
        workingDirectory,
      };
    }
  }

  return {
    command: [filePath, joinedArguments].filter(Boolean).join(" ").trim(),
    workingDirectory,
  };
}

function getPowerShellStartProcessCommand(tokens) {
  return getPowerShellStartProcessInvocation(tokens).command;
}

function getPowerShellStartProcessWorkingDirectory(tokens) {
  let argumentListSeen = false;
  let argumentListIsArrayLike = false;
  for (let index = 1; index < tokens.length; index += 1) {
    const originalToken = tokens[index];
    if (isQuotedCommandToken(originalToken)) {
      if (argumentListSeen) {
        argumentListIsArrayLike = true;
      }
      continue;
    }
    const rawToken = stripOuterQuotes(originalToken);
    const token = normalizeAgentValue(rawToken);
    if (token === "-argumentlist" || token === "-args") {
      argumentListSeen = true;
      continue;
    }
    if (token.startsWith("-argumentlist:") || token.startsWith("-argumentlist=") ||
        token.startsWith("-args:") || token.startsWith("-args=")) {
      argumentListSeen = true;
      argumentListIsArrayLike = true;
      continue;
    }
    if (isPowerShellStartProcessWorkingDirectoryToken(token) && index + 1 < tokens.length) {
      return cleanPowerShellStartProcessArgument(tokens[index + 1]);
    }

    const inlineWorkingDirectory = getInlinePowerShellStartProcessWorkingDirectory(rawToken);
    if (argumentListSeen && argumentListIsArrayLike && inlineWorkingDirectory) {
      continue;
    }
    if (inlineWorkingDirectory) {
      return inlineWorkingDirectory;
    }

    if (argumentListSeen && /,+$/u.test(String(originalToken || "").trim())) {
      argumentListIsArrayLike = true;
    }
  }

  return "";
}

function stripLeadingCmdCallBuiltins(command) {
  let remaining = String(command || "").trim();
  for (let depth = 0; depth < 8; depth += 1) {
    const stripped = remaining.replace(/^@?call(?:\.exe)?\s+/iu, "").trim();
    if (stripped === remaining) {
      break;
    }
    remaining = stripped;
  }
  return remaining;
}

function isQuotedCommandToken(value) {
  const token = String(value || "").trim().replace(/,+$/u, "");
  return token.length >= 2 &&
    ((token.startsWith("'") && token.endsWith("'")) ||
     (token.startsWith('"') && token.endsWith('"')));
}

function isPowerShellStartProcessWorkingDirectoryToken(token) {
  return expandPowerShellOptionPrefixes(["-workingdirectory"]).includes(normalizeAgentValue(token));
}

function getInlinePowerShellStartProcessWorkingDirectory(token) {
  const normalizedToken = normalizeAgentValue(token);
  for (const optionName of expandPowerShellOptionPrefixes(["-workingdirectory"])) {
    if (normalizedToken.startsWith(optionName + ":") || normalizedToken.startsWith(optionName + "=")) {
      return cleanPowerShellStartProcessArgument(token.slice(optionName.length + 1));
    }
  }

  return "";
}

function cleanPowerShellStartProcessArguments(value) {
  const cleaned = cleanPowerShellStartProcessArgument(value);
  if (!cleaned) {
    return [];
  }

  const normalizedArray = cleaned
    .replace(/'\s*,\s*'/gu, ",")
    .replace(/"\s*,\s*"/gu, ",");
  return splitPowerShellCommaArguments(normalizedArray)
    .map((argument) => cleanPowerShellStartProcessArgument(argument))
    .filter(Boolean);
}

function cleanPowerShellStartProcessArgument(value) {
  return stripOuterQuotes(String(value || "").trim())
    .replace(/^@\(/u, "")
    .replace(/\)$/u, "")
    .replace(/^,+|,+$/gu, "")
    .trim();
}

function splitPowerShellCommaArguments(value) {
  const source = String(value || "");
  const parts = [];
  let current = "";
  let quote = "";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (isShellQuoteTerminator(source, index, quote)) {
        quote = "";
      }
      current += char;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(source, index, char);
      current += char;
      continue;
    }

    if (char === ",") {
      parts.push(current);
      current = "";
      continue;
    }

    current += char;
  }

  parts.push(current);
  return parts;
}

function isPowerShellVariableReference(value) {
  return /^\$(?:env:)?[A-Za-z_][A-Za-z0-9_]*$/u.test(stripOuterQuotes(String(value || "").trim()));
}

function hasGitLifecycleArgumentHint(value) {
  const normalized = normalizeAgentValue(String(value || ""));
  return /\b(?:add|commit|merge|push|rebase|reset|restore|rm|checkout-index|update-index|notes|branch|tag|worktree|config)\b/u.test(normalized);
}

function hasGhLifecycleArgumentHint(value) {
  const normalized = normalizeAgentValue(String(value || ""));
  return /\bpr\s+merge\b/u.test(normalized) ||
    /\bapi\b[\s\S]*\b(?:pulls\/\d+\/merge|git\/refs?|git\/ref\/heads)\b/u.test(normalized);
}

function unescapeCmdCaretEscapes(value) {
  return String(value || "").replace(/\^([\s\S])/gu, "$1");
}

function hasUnresolvedXargsLifecycleCommand(tokens) {
  const executable = normalizeExecutableName(tokens[0] || "");
  if (executable === "git") {
    return findGitSubcommandIndex(tokens) < 0;
  }
  if (executable === "gh") {
    return tokens.length < 2;
  }
  if (!isShellCommandExecutable(executable)) {
    return false;
  }

  const nestedCommand = getShellCommandArgument(tokens);
  return /(?:^|[;&|]\s*)(?:env\s+)?(?:git|gh)\s+(?:["']?\$@["']?|\{\})(?:\s|$)/iu.test(String(nestedCommand || ""));
}

function parseEnvShortOptionCluster(value) {
  const token = stripOuterQuotes(String(value || ""));
  if (!/^-[^-]/u.test(token)) {
    return null;
  }

  const parsed = { ignoreEnvironment: false, nullOutput: false, valueOption: "", value: "" };
  for (let index = 1; index < token.length; index += 1) {
    const option = token[index];
    if (option === "i") {
      parsed.ignoreEnvironment = true;
      continue;
    }
    if (option === "0") {
      parsed.nullOutput = true;
      continue;
    }
    if (option === "S" || option === "s" || option === "C" || option === "c" || option === "u") {
      parsed.valueOption = option.toUpperCase();
      parsed.value = token.slice(index + 1);
      return parsed;
    }
    return null;
  }
  return parsed;
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

    const shortOptions = parseEnvShortOptionCluster(token);
    if (shortOptions) {
      if (shortOptions.valueOption === "S") {
        const splitValue = shortOptions.value || stripOuterQuotes(withoutInlineAssignments[index + 1] || "");
        if (!splitValue) {
          return [];
        }
        const consumedTokens = shortOptions.value ? 1 : 2;
        const splitTokens = tokenizeCommandLine(splitValue);
        return stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes([
          ...splitTokens,
          ...withoutInlineAssignments.slice(index + consumedTokens),
        ]));
      }
      if (shortOptions.valueOption === "C" || shortOptions.valueOption === "U") {
        index += shortOptions.value ? 1 : 2;
        continue;
      }
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

    if (normalizedToken.startsWith("-s") && normalizedToken.length > 2) {
      const splitTokens = tokenizeCommandLine(stripOuterQuotes(token.slice(2)));
      return stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes([
        ...splitTokens,
        ...withoutInlineAssignments.slice(index + 1),
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

    if (normalizedToken.startsWith("-c") && normalizedToken.length > 2) {
      index += 1;
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
    if (executable === "time") {
      index += 1;
      while (index < tokens.length) {
        const option = normalizeAgentValue(stripOuterQuotes(tokens[index]));
        if (option === "-p" || option === "--portability") {
          index += 1;
          continue;
        }
        break;
      }
      continue;
    }

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

function unwrapReviewGateExecutionTokens(tokens) {
  let remaining = stripShellCommandBuiltinPrefixes(tokens);
  for (let depth = 0; depth < 8 && remaining.length > 0; depth += 1) {
    const executable = normalizeExecutableName(remaining[0]);
    if (executable === "eval") {
      return { tokens: [], nestedCommand: remaining.slice(1).join(" ") };
    }

    if (executable === "script") {
      for (let index = 1; index < remaining.length; index += 1) {
        const option = normalizeAgentValue(stripOuterQuotes(remaining[index]));
        if ((option === "-c" || option === "--command") && index + 1 < remaining.length) {
          return { tokens: [], nestedCommand: stripOuterQuotes(remaining[index + 1]) };
        }
        if (option.startsWith("--command=")) {
          return { tokens: [], nestedCommand: stripOuterQuotes(remaining[index].slice(remaining[index].indexOf("=") + 1)) };
        }
      }
      return { tokens: [], nestedCommand: "" };
    }

    if (executable === "timeout") {
      let index = 1;
      while (index < remaining.length) {
        const option = stripOuterQuotes(remaining[index]);
        if (option === "--") {
          index += 1;
          break;
        }
        if (!option.startsWith("-")) {
          break;
        }
        index += reviewGateWrapperOptionConsumesNextValue(executable, option) ? 2 : 1;
      }
      if (index < remaining.length) {
        index += 1;
      }
      remaining = remaining.slice(index);
      continue;
    }

    if (["nohup", "stdbuf", "nice", "ionice", "setsid", "sudo"].includes(executable)) {
      let index = 1;
      while (index < remaining.length) {
        const option = stripOuterQuotes(remaining[index]);
        if (option === "--") {
          index += 1;
          break;
        }
        if (!option.startsWith("-")) {
          break;
        }
        index += reviewGateWrapperOptionConsumesNextValue(executable, option) ? 2 : 1;
      }
      remaining = remaining.slice(index);
      continue;
    }

    const stripped = stripShellCommandBuiltinPrefixes(remaining);
    if (stripped.length !== remaining.length) {
      remaining = stripped;
      continue;
    }
    break;
  }

  return { tokens: remaining, nestedCommand: "" };
}

function reviewGateWrapperOptionConsumesNextValue(executable, option) {
  const normalizedOption = normalizeAgentValue(stripOuterQuotes(option));
  const valueOptions = {
    timeout: new Set(["-k", "--kill-after", "-s", "--signal"]),
    stdbuf: new Set(["-i", "--input", "-o", "--output", "-e", "--error"]),
    nice: new Set(["-n", "--adjustment"]),
    ionice: new Set(["-c", "--class", "-n", "--classdata", "-p", "--pid", "-p", "--pgid", "-u", "--uid"]),
    sudo: new Set([
      "-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
      "-c", "--close-from", "-r", "--role", "-t", "--type",
      "--command-timeout", "-d", "--chdir",
    ]),
  };
  return Boolean(valueOptions[executable]?.has(normalizedOption));
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
  return normalized.replace(/\.(?:bat|cmd|com|exe)$/u, "");
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
  if (hasPowerShellComputedMutationCall(normalizedSegment)) {
    targets.push("$unparsed-powershell-computed-write");
    return;
  }

  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedSegment));
  if (tokens.length === 0) {
    return;
  }

  if (collectPowerShellDynamicWriteTargets(normalizedSegment, tokens, targets, powerShellAliases)) {
    return;
  }

  if (collectPowerShellComputedCallWriteTargets(normalizedSegment, tokens, targets)) {
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
  collectXargsMutationTargets(tokens, targets);
  collectPosixMutationTargets(tokens, targets);
  collectWindowsCopyUtilityTargets(tokens, targets);
  collectPowerShellMutationTargets(tokens, targets);
  collectPowerShellDotNetMutationTargets(normalizedSegment, targets);
  collectInterpreterMutationTargets(normalizedSegment, tokens, targets);
}

function collectXargsMutationTargets(tokens, targets) {
  const executable = normalizeExecutableName(tokens[0]);
  if (executable !== "xargs") {
    return;
  }

  const nestedTargets = [];
  const nestedTokens = getNormalizedXargsCommandTokens(tokens);
  collectPosixMutationTargets(nestedTokens, nestedTargets);
  if (isShellCommandExecutable(normalizeExecutableName(nestedTokens[0] || ""))) {
    const nestedCommand = getShellCommandArgument(nestedTokens);
    if (nestedCommand) {
      collectShellWriteTargetsFromCommand(nestedCommand, nestedTargets);
    }
  }
  if (nestedTargets.length > 0) {
    targets.push("$unparsed-xargs-write");
  }
}

function collectPowerShellComputedCallWriteTargets(segment, tokens, targets) {
  if (normalizeAgentValue(tokens[0]) !== "&") {
    return false;
  }

  const executable = resolvePowerShellComputedCallExecutable(segment, tokens);
  if (!isPowerShellMutationExecutable(executable)) {
    return false;
  }

  const initialTargetCount = targets.length;
  collectPowerShellMutationTargets([executable, ...tokens.slice(2)], targets);
  if (targets.length === initialTargetCount) {
    targets.push("$unparsed-powershell-computed-write");
  }
  return true;
}

function hasPowerShellComputedMutationCall(segment) {
  const compact = normalizeAgentValue(segment)
    .replace(/[`'"\s()]/gu, "");
  return getPowerShellMutationExecutableNames()
    .map((name) => normalizeAgentValue(name).replace(/-/gu, "+-"))
    .some((computedName) => compact.includes("&" + computedName));
}

function resolvePowerShellComputedCallExecutable(segment, tokens) {
  const expression = extractPowerShellCallOperatorExpression(segment) || tokens[1] || "";
  const quotedParts = [...String(expression).matchAll(/["']([^"']+)["']/gu)]
    .map((match) => match[1])
    .filter(Boolean);
  if (quotedParts.length > 0) {
    return quotedParts.join("");
  }

  const compactExpression = String(expression)
    .replace(/^\s*\(/u, "")
    .replace(/\)\s*$/u, "")
    .split("+")
    .map((part) => stripOuterQuotes(part.trim()))
    .join("");
  return compactExpression;
}

function extractPowerShellCallOperatorExpression(segment) {
  const match = String(segment || "").match(/^\s*&\s+(\([^)]*\)|[^\s]+)/u);
  return match ? match[1] || "" : "";
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
    const targetDirectory = getPosixOptionValue(tokens, ["-t", "--target-directory"]);
    if (targetDirectory) {
      targets.push(targetDirectory);
      return;
    }

    const positional = collectPosixPositionalValues(tokens);
    if (positional.length >= 2) {
      targets.push(positional[positional.length - 1]);
    } else {
      targets.push("$unparsed-posix-write-target");
    }
    return;
  }

  if (executable === "install") {
    const targetDirectory = getPosixOptionValue(tokens, ["-t", "--target-directory"]);
    if (targetDirectory) {
      targets.push(targetDirectory);
      return;
    }

    const positional = collectPosixPositionalValues(tokens);
    if (positional.length >= 2) {
      targets.push(positional[positional.length - 1]);
    } else {
      targets.push("$unparsed-posix-write-target");
    }
    return;
  }

  if (executable === "sed" && hasPosixOption(tokens, ["-i", "--in-place"])) {
    const positional = collectPosixPositionalValues(tokens);
    if (positional.length >= 2) {
      targets.push(...positional.slice(1));
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

function getPosixOptionValue(tokens, optionNames) {
  const normalizedOptionNames = optionNames.map((name) => normalizeAgentValue(name));
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (normalizedOptionNames.includes(normalizedToken) && index + 1 < tokens.length) {
      return stripOuterQuotes(tokens[index + 1]);
    }

    const inlineOption = normalizedOptionNames.find((name) => normalizedToken.startsWith(name + "="));
    if (inlineOption) {
      return token.slice(inlineOption.length + 1);
    }
  }

  return "";
}

function hasPosixOption(tokens, optionNames) {
  const normalizedOptionNames = optionNames.map((name) => normalizeAgentValue(name));
  return tokens.slice(1).some((token) => {
    const normalizedToken = normalizeAgentValue(stripOuterQuotes(token));
    return normalizedOptionNames.some((name) =>
      normalizedToken === name ||
      normalizedToken.startsWith(name + "=") ||
      (name.length === 2 && normalizedToken.startsWith(name) && !normalizedToken.startsWith("--")));
  });
}

function collectPowerShellScriptBlockWriteTargets(segment, targets, powerShellAliases) {
  const commandNames = powerShellAliases.size > 0
    ? [...getPowerShellMutationExecutableNames(), ...powerShellAliases.keys()]
    : getPowerShellMutationExecutableNames();
  const initialTargetCount = targets.length;
  const mutationNames = commandNames.map((name) => name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")).join("|");
  const scriptBlockPattern = new RegExp(`\\{([^{}]*\\b(?:${mutationNames})\\b[^{}]*)\\}`, "giu");
  for (const match of segment.matchAll(scriptBlockPattern)) {
    collectShellWriteTargetsFromCommand(match[1] || "", targets, powerShellAliases);
  }

  if (targets.length === initialTargetCount &&
      hasNestedPowerShellControlBlock(segment) &&
      hasPowerShellMutationHint(segment, commandNames)) {
    targets.push("$unparsed-powershell-scriptblock-write");
  }
}

function hasPowerShellMutationHint(source, commandNames) {
  const mutationNames = commandNames
    .map((name) => normalizeAgentValue(name))
    .map((name) => name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"))
    .join("|");
  const pattern = new RegExp(`\\b(?:${mutationNames})\\b`, "u");
  return pattern.test(normalizeAgentValue(String(source || "")));
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
    const originalToken = tokens[index];
    if (isQuotedCommandToken(originalToken)) {
      continue;
    }
    const token = stripOuterQuotes(originalToken);
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

  for (const alias of collectPythonMutationAliases(segment)) {
    const escapedAlias = escapeRegex(alias.name);
    if (alias.kind === "single") {
      const pattern = new RegExp(`(?:^|[^\\w])${escapedAlias}\\s*\\(\\s*["']([^"']+)["']\\s*\\)`, "giu");
      for (const match of segment.matchAll(pattern)) {
        targets.push(match[1] || "");
        foundTarget = true;
      }
      continue;
    }

    const pattern = new RegExp(`(?:^|[^\\w])${escapedAlias}\\s*\\(\\s*["']([^"']+)["']\\s*,\\s*["']([^"']+)["']\\s*\\)`, "giu");
    for (const match of segment.matchAll(pattern)) {
      if (alias.kind === "sourceAndDestination") {
        targets.push(match[1] || "");
      }
      targets.push(match[2] || "");
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

  if (hasUnparsedPythonMutationAliasCall(segment)) {
    targets.push("$unparsed-python-write");
  }

  if (!foundTarget && /(?:write_text|write_bytes|\.(?:makedirs|mkdir|removedirs|remove|rename|replace|rmdir|touch|unlink)\s*\(|\b(?:copy|copy2|copyfile|copytree|move|rmtree)\s*\()/iu.test(segment)) {
    targets.push("$unparsed-python-write");
  }
}

function collectPythonMutationAliases(segment) {
  const aliases = [];
  const singleTargetNames = new Set(["makedirs", "mkdir", "removedirs", "remove", "rmdir", "unlink", "rmtree"]);
  const sourceAndDestinationNames = new Set(["rename", "replace"]);
  const destinationNames = new Set(["copy", "copy2", "copyfile", "copytree", "move"]);

  for (const match of String(segment || "").matchAll(/\bfrom\s+(os|shutil)\s+import\s+([^;\n]+)/giu)) {
    const importList = match[2] || "";
    for (const part of importList.split(",")) {
      const aliasMatch = /^\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*$/u.exec(part);
      if (!aliasMatch || !aliasMatch[1]) {
        continue;
      }

      const importedName = aliasMatch[1];
      const aliasName = aliasMatch[2] || importedName;
      if (singleTargetNames.has(importedName)) {
        aliases.push({ name: aliasName, kind: "single" });
      } else if (sourceAndDestinationNames.has(importedName)) {
        aliases.push({ name: aliasName, kind: "sourceAndDestination" });
      } else if (destinationNames.has(importedName)) {
        aliases.push({ name: aliasName, kind: "destination" });
      }
    }
  }

  const moduleAliasPattern = /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(os|shutil)\.([A-Za-z_][A-Za-z0-9_]*)\b/giu;
  for (const match of String(segment || "").matchAll(moduleAliasPattern)) {
    const aliasName = match[1];
    const importedName = match[3];
    if (singleTargetNames.has(importedName)) {
      aliases.push({ name: aliasName, kind: "single" });
    } else if (sourceAndDestinationNames.has(importedName)) {
      aliases.push({ name: aliasName, kind: "sourceAndDestination" });
    } else if (destinationNames.has(importedName)) {
      aliases.push({ name: aliasName, kind: "destination" });
    }
  }

  return aliases;
}

function hasUnparsedPythonMutationAliasCall(segment) {
  for (const alias of collectPythonMutationAliases(segment)) {
    const escapedAlias = escapeRegex(alias.name);
    if (new RegExp(`(?:^|[^\\w])${escapedAlias}\\s*\\(\\s*(?!["'])`, "iu").test(segment)) {
      return true;
    }
  }

  return false;
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

  if (!foundTarget && /(?:writeFileSync|appendFileSync|rmSync|unlinkSync|mkdirSync|mkdtempSync|rmdirSync|truncateSync|createWriteStream|openSync|renameSync|copyFileSync|cpSync|writeFile|appendFile|rm|unlink|mkdir|mkdtemp|rmdir|truncate|open|rename|copyFile|cp)/iu.test(segment)) {
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
  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(normalizedSegment)));
  if (tokens.length === 0) {
    return false;
  }

  const executable = getExecutableBasename(tokens[0]);
  if ((executable === "env" || executable === "env.exe") && hasEnvChdirOption(tokens)) {
    return true;
  }

  const effectiveTokens = unwrapEnvCommandTokens(tokens);
  if (hasInterpreterCwdChangeCommand(normalizedSegment, effectiveTokens)) {
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

  if (isPowerShellStartProcessExecutable(executable)) {
    return hasPowerShellStartProcessWorkingDirectoryOption(tokens);
  }

  return [
    "cd",
    "chdir",
    "pushd",
    "popd",
    "set-location",
    "sl",
    "push-location",
    "pop-location",
  ].includes(executable);
}

function hasInterpreterCwdChangeCommand(segment, tokens) {
  const kind = getShellInterpreterKind(tokens);
  if (!kind) {
    return false;
  }

  const inlineScript = getInterpreterInlineScript(tokens, kind) || segment;
  if (kind === "python") {
    return hasPythonCwdChangeCommand(inlineScript);
  }

  if (kind === "node") {
    return hasNodeCwdChangeCommand(inlineScript);
  }

  return false;
}

function getInterpreterInlineScript(tokens, kind) {
  return getInterpreterInlineSourceToken(tokens, kind) || "";
}

function hasPythonCwdChangeCommand(script) {
  const text = String(script || "");
  return /\bos\s*\.\s*chdir\s*\(/iu.test(text) ||
    /\bfrom\s+os\s+import\s+[^;\n]*\bchdir\b/iu.test(text) && /(?:^|[^\w])(?:chdir|[A-Za-z_][A-Za-z0-9_]*)\s*\(/iu.test(text) ||
    /\bimport\s+os\s+as\s+([A-Za-z_][A-Za-z0-9_]*)/iu.test(text) && /\b[A-Za-z_][A-Za-z0-9_]*\s*\.\s*chdir\s*\(/iu.test(text);
}

function hasNodeCwdChangeCommand(script) {
  return /\bprocess\s*\.\s*chdir\s*\(/iu.test(String(script || ""));
}

function hasPowerShellStartProcessWorkingDirectoryOption(tokens) {
  return collectPowerShellOptionValues(tokens, expandPowerShellOptionPrefixes(["-workingdirectory"]))
    .some((value) => Boolean(stripOuterQuotes(String(value || "").trim())));
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

function evaluatePowerShellLiteralStringExpression(expression) {
  let candidate = String(expression || "").trim();
  while (candidate.startsWith("(") && candidate.endsWith(")")) {
    const body = getBalancedCallBody(candidate, 0);
    if (body === null || body.length !== candidate.length - 2) break;
    candidate = body.trim();
  }
  const literal = /'(?:[^']|'')*'|"(?:[^"`$]|"")*"/gu;
  const remainder = candidate.replace(literal, "").replace(/\s*\+\s*/gu, "").trim();
  if (remainder !== "") return null;
  const values = [...candidate.matchAll(literal)].map((match) => {
    const value = match[0];
    return value.startsWith("'")
      ? value.slice(1, -1).replace(/''/gu, "'")
      : value.slice(1, -1).replace(/""/gu, '"');
  });
  return values.length > 0 ? values.join("") : null;
}

function hasPowerShellDynamicCodexDispatch(command, depth) {
  const source = String(command || "");
  const dynamicExpressions = [];
  for (const match of source.matchAll(/\b(?:Invoke-Expression|iex)\b/giu)) {
    const start = (match.index || 0) + match[0].length;
    const remainder = source.slice(start).trimStart();
    if (remainder.startsWith("(")) {
      const body = getBalancedCallBody(remainder, 0);
      if (body !== null) dynamicExpressions.push(body);
    } else {
      const quoted = /^(?:'(?:[^']|'')*'|"(?:[^"`$]|"")*")/u.exec(remainder);
      dynamicExpressions.push(quoted ? quoted[0] : (/^[^;\r\n]+/u.exec(remainder) || [""])[0]);
    }
  }
  for (const match of source.matchAll(/\[\s*(?:(?:System\.)?Management\.Automation\.)?ScriptBlock\s*\]\s*::\s*Create\s*\(/giu)) {
    const openIndex = (match.index || 0) + match[0].lastIndexOf("(");
    const body = getBalancedCallBody(source, openIndex);
    if (body !== null) dynamicExpressions.push(body);
  }
  if (dynamicExpressions.some((expression) => {
    const value = evaluatePowerShellLiteralStringExpression(expression);
    return value !== null && isDirectCodexDispatch(value, depth + 1);
  })) return true;

  const processPatterns = [
    /\[\s*(?:System\.)?Diagnostics\.Process\s*\]\s*::\s*Start\s*\(\s*(["'])codex(?:\.exe)?\1\s*,\s*(["'])([\s\S]*?)\2/giu,
    /\[\s*(?:System\.)?Diagnostics\.ProcessStartInfo\s*\]\s*::\s*new\s*\(\s*(["'])codex(?:\.exe)?\1\s*,\s*(["'])([\s\S]*?)\2/giu,
  ];
  return processPatterns.some((pattern) => [...source.matchAll(pattern)].some((match) =>
    tokenizeCommandLine(match[3]).some(isDeniedCodexMode)));
}

function isDirectCodexDispatch(command, depth = 0) {
  if (typeof command !== "string" || command.trim() === "") {
    return false;
  }
  if (depth > 6) {
    return true;
  }
  const directTokens = tokenizeCommandLine(command);
  if (normalizeExecutableName(directTokens[0] || "") === "codex" &&
      directTokens.slice(1).some(isDeniedCodexMode)) {
    return true;
  }
  if (hasPowerShellDynamicCodexDispatch(command, depth)) {
    return true;
  }
  if (hasShellArrayDirectCodexDispatch(command, depth)) {
    return true;
  }
  if (/\bxargs\b[^;&\r\n]*\bcodex\b/iu.test(command) ||
      /\b(?:echo|printf)\b[^|]*\bcodex\b[^|]*\|\s*xargs\b[^;&\r\n]*\b(?:sh|bash|zsh)\b[^;&\r\n]*\$0[^;&\r\n]*\b(?:exec|--sandbox)\b/iu.test(command)) {
    return true;
  }

  const powerShellComSpecCommand = materializePowerShellComSpecAliases(command);
  if (powerShellComSpecCommand !== command) {
    return isDirectCodexDispatch(powerShellComSpecCommand, depth + 1);
  }

  const materializedCommand = materializeConstantExecutableSubstitutions(command);
  if (materializedCommand !== command && isDirectCodexDispatch(materializedCommand, depth + 1)) {
    return true;
  }

  for (const heredocBody of getExecutableHeredocBodies(command)) {
    if (isDirectCodexDispatch(heredocBody, depth + 1)) {
      return true;
    }
  }

  for (const segment of splitCommandSegments(command)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const executableStage = unwrapShellExecutableControlFlowPrefix(stage);
      if (executableStage && executableStage !== stage.trim()) {
        if (isDirectCodexDispatch(executableStage, depth + 1)) {
          return true;
        }
        continue;
      }

      for (const substitution of getShellCommandSubstitutionCommands(stage)) {
        if (isDirectCodexDispatch(substitution, depth + 1)) {
          return true;
        }
      }

      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
      if (execution.nestedCommand && isDirectCodexDispatch(execution.nestedCommand, depth + 1)) {
        return true;
      }
      const tokens = execution.tokens;
      if (tokens.length === 0) {
        continue;
      }

      const executable = normalizeExecutableName(tokens[0]);
      if (isDynamicShellExecutableToken(tokens[0])) {
        const dynamicArgs = tokens.slice(1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
        if (dynamicArgs.some((arg) => arg === "exec" || arg === "e" || arg === "--sandbox" || arg.startsWith("--sandbox="))) {
          return true;
        }
      }
      if (executable === "codex") {
        const args = tokens.slice(1).map((token) => normalizeAgentValue(stripOuterQuotes(token)));
        if (args.some((arg) => arg === "exec" || arg === "e" || arg === "--sandbox" || arg.startsWith("--sandbox="))) {
          return true;
        }
      }

      if (isPowerShellStartProcessExecutable(executable)) {
        const nestedCommand = getPowerShellStartProcessCommand(tokens);
        if (nestedCommand && isDirectCodexDispatch(nestedCommand, depth + 1)) {
          return true;
        }
      } else if (executable === "cmd") {
        const nestedCommand = getCmdShellArgument(tokens);
        if (nestedCommand && isDirectCodexDispatch(nestedCommand, depth + 1)) {
          return true;
        }
      } else if (isPowerShellExecutable(executable)) {
        const nestedCommand = getPowerShellNestedCommand(tokens);
        if (nestedCommand && isDirectCodexDispatch(nestedCommand, depth + 1)) {
          return true;
        }
      } else if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        if (nestedCommand && isDirectCodexDispatch(nestedCommand, depth + 1)) {
          return true;
        }
      } else if (getShellInterpreterKind(tokens) && hasInterpreterCodexDispatch(stage)) {
        return true;
      } else if (executable === "xargs") {
        const nestedTokens = getNormalizedXargsCommandTokens(tokens);
        if (nestedTokens.length > 0 && isDirectCodexDispatch(nestedTokens.join(" "), depth + 1)) {
          return true;
        }
      }
    }
  }

  return false;
}

function getArgumentContainerElements(
  expression,
  source,
  evaluationIndex,
  scopes = buildFunctionScopeIndex(source),
  language = "javascript",
  depth = 0,
  seen = new Set(),
  sinkIndex = evaluationIndex,
) {
  if (depth > 8) {
    return null;
  }
  const candidate = stripLeadingCallComments(String(expression || "").trim());
  const arrayElements = getArrayLiteralElements(candidate);
  if (arrayElements) {
    return arrayElements;
  }
  if (candidate.startsWith("(") && candidate.endsWith(")")) {
    const body = getBalancedCallBody(candidate, 0);
    if (body !== null && body.length === candidate.length - 2) {
      return splitTopLevelCallArguments(body);
    }
  }
  if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(candidate) || seen.has(`${candidate}:${evaluationIndex}`)) {
    return null;
  }
  const event = getLatestScopedAssignmentEvent(source, candidate, evaluationIndex, scopes, language);
  if (!event || hasContainerMutationBetween(source, candidate, event.index, sinkIndex)) {
    return null;
  }
  const nextSeen = new Set(seen);
  nextSeen.add(`${candidate}:${evaluationIndex}`);
  return getArgumentContainerElements(
    event.expression,
    source,
    event.index,
    scopes,
    language,
    depth + 1,
    nextSeen,
    sinkIndex,
  );
}

function isDeniedCodexMode(value) {
  const mode = normalizeAgentValue(value);
  return mode === "exec" || mode === "e" || mode === "--sandbox" || mode.startsWith("--sandbox=");
}

function isTerminalReadOnlyCodexMode(value) {
  return ["--version", "-v", "--help", "-h", "help"].includes(normalizeAgentValue(value));
}

function isDeniedInterpreterProcessBoundary(result) {
  return result === INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED ||
    result === INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
}

function isCanonicalReadOnlyCodexArguments(values) {
  return values.length === 1 && isTerminalReadOnlyCodexMode(values[0]);
}

function classifyStaticShellCommandString(command, depth = 0, denyGit = false) {
  if (depth > 6) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  let sawStage = false;
  let strongestAllow = INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED;
  for (const segment of splitCommandSegments(String(command || ""))) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(String(stage || "").trim()));
      if (tokens.length === 0) continue;
      sawStage = true;
      const result = classifyStaticProcessInvocation(
        normalizeExecutableName(tokens[0]),
        tokens.slice(1),
        stage,
        depth + 1,
        denyGit,
      );
      if (result === INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED ||
          result === INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED ||
          result === INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS) return result;
      if (result === INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY) {
        strongestAllow = result;
      }
    }
  }
  return sawStage ? strongestAllow : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
}

function classifyCodexCommandExpression(expression, assignments, source = "", callIndex = 0, scopes = buildFunctionScopeIndex(source), language = "javascript", outerProtectedHint = false, denyGit = false) {
  const candidate = stripLeadingCallComments(String(expression || "").trim());
  const resolved = source
    ? evaluateScopedStaticStringExpression(candidate, source, callIndex, scopes, language)
    : evaluateStaticStringExpression(candidate, assignments);
  if (resolved !== null) {
    return classifyStaticShellCommandString(resolved, 0, denyGit);
  }
  let prefix = "";
  for (const part of splitTopLevelPlusExpressions(candidate)) {
    const value = evaluateStaticStringExpression(part, assignments);
    if (value === null) {
      break;
    }
    prefix += value;
  }
  const prefixTokens = tokenizeCommandLine(prefix);
  const prefixTool = normalizeExecutableName(prefixTokens[0] || "");
  if (prefixTool && prefixTool !== "codex") {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  if (prefixTool === "codex") {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
  }
  if (outerProtectedHint) {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
  }
  return /^(?:f["']|`|["'])codex(?:\.exe)?\s+(?:\$\{|\{)[\s\S]*(?:["']|`)$/iu.test(candidate)
    ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
    : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
}

function isNestedShellProcessLauncher(tool) {
  return tool === "cmd" || isPowerShellExecutable(tool) || isShellCommandExecutable(tool);
}

function materializeStaticPosixShellCommand(tokens) {
  let commandIndex = -1;
  for (let index = 1; index < tokens.length; index += 1) {
    if (/^-[a-z]*c[a-z]*$/u.test(normalizeAgentValue(stripOuterQuotes(tokens[index])))) {
      commandIndex = index + 1;
      break;
    }
  }
  if (commandIndex < 0 || commandIndex >= tokens.length) return null;
  const script = String(tokens[commandIndex] || "");
  const positional = tokens.slice(commandIndex + 1).map((value) => String(value || ""));
  if (/\$(?:[@*]|\{|\(|[A-Za-z_])|`|\$\d{2,}|[*?\[]/u.test(script)) return null;
  const materialized = script.replace(/\$(\d)/gu, (_match, rawIndex) => {
    const index = Number.parseInt(rawIndex, 10);
    return index < positional.length ? positional[index] : "";
  });
  return /\$(?:[@*{(A-Za-z_]|\d)/u.test(materialized) ? null : materialized;
}

function getStaticNestedShellCommand(tool, resolvedArguments) {
  const tokens = [tool, ...resolvedArguments];
  if (tool === "cmd") {
    const command = getCmdShellArgument(tokens, false);
    return command && !/%(?:[^%\r\n]+%|\d)|![^!\r\n]+!/u.test(command) ? command : null;
  }
  if (isPowerShellExecutable(tool)) {
    const command = getPowerShellNestedCommand(tokens);
    return command && !/\$(?:\{|\(|[A-Za-z_])/u.test(command) ? command : null;
  }
  return materializeStaticPosixShellCommand(tokens);
}

function hasGitExternalProcessConfiguration(tokens) {
  const normalized = tokens.map((value) => normalizeAgentValue(value));
  if (normalized.some((value) => value.includes("ext::"))) return true;
  const subcommandIndex = findGitSubcommandIndex(tokens);
  const executionOptions = subcommandIndex < 0 ? [] : normalized.slice(subcommandIndex + 1);
  const subcommand = subcommandIndex < 0 ? "" : normalized[subcommandIndex];
  if (subcommand === "difftool" && executionOptions.some((value) =>
    value === "-x" || value.startsWith("-x") || value === "--extcmd" || value.startsWith("--extcmd="))) return true;
  if (executionOptions.some((value) =>
    value === "--ext-diff" ||
    value === "--textconv" ||
    value === "--paginate" ||
    value === "-p" ||
    /^-o/u.test(value) ||
    value.startsWith("--open-f"))) return true;
  for (let index = 1; index < Math.max(subcommandIndex, 1); index += 1) {
    const value = normalized[index];
    if (value !== "-c" && !value.startsWith("-c")) continue;
    const config = value === "-c" ? normalized[index + 1] || "" : value.slice(2);
    if (/^(?:diff\..*\.command|diff\.external|core\.fsmonitor|core\.hookspath|credential\..*\.helper|credential\.helper|pager\..*|core\.pager)=/u.test(config)) {
      return true;
    }
  }
  return false;
}

function isCanonicalSafeGitInlineConfiguration(configuration) {
  const match = /^alias\.([A-Za-z0-9._-]+)=([\s\S]+)$/iu.exec(String(configuration || "").trim());
  if (!match || String(match[2] || "").trim().startsWith("!")) return false;
  const aliasTokens = tokenizeCommandLine(String(match[2] || "").trim());
  if (aliasTokens.length === 0) return false;
  const tokens = ["git", ...aliasTokens];
  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[1] || ""));
  return isCanonicalReadOnlyGitResolvedTokens(tokens, 1) ||
    isGitLifecycleSubcommandName(subcommand);
}

function isCanonicalReadOnlyGitResolvedTokens(tokens, subcommandIndex) {
  if (subcommandIndex < 1 || hasGitExternalProcessConfiguration(tokens)) return false;
  const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex] || ""));
  return isReadOnlyGitSubcommand(subcommand, tokens, subcommandIndex) ||
    (subcommand === "branch" && isReadOnlyGitBranchCommand(tokens, subcommandIndex)) ||
    (subcommand === "tag" && isReadOnlyGitTagCommand(tokens, subcommandIndex)) ||
    (subcommand === "worktree" && isReadOnlyGitWorktreeCommand(tokens, subcommandIndex));
}

function isCanonicalReadOnlyGitInlineAliasInvocation(tokens, subcommandIndex) {
  const invokedAlias = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex] || ""));
  for (let index = 1; index < subcommandIndex; index += 1) {
    const raw = stripOuterQuotes(String(tokens[index] || ""));
    const configuration = raw === "-c" && index + 1 < subcommandIndex
      ? stripOuterQuotes(tokens[++index])
      : raw.startsWith("-c") && raw.length > 2
      ? raw.slice(2)
      : "";
    const match = /^alias\.([A-Za-z0-9._-]+)=([\s\S]+)$/iu.exec(String(configuration || "").trim());
    if (!match || normalizeAgentValue(match[1]) !== invokedAlias) continue;
    const aliasTokens = tokenizeCommandLine(String(match[2] || "").trim());
    if (aliasTokens.length === 0 || String(match[2] || "").trim().startsWith("!")) return false;
    const resolvedTokens = ["git", ...aliasTokens, ...tokens.slice(subcommandIndex + 1)];
    return isCanonicalReadOnlyGitResolvedTokens(resolvedTokens, 1);
  }
  return false;
}

function isCanonicalConfiguredReadOnlyGitAliasInvocation(tokens, baseCwd) {
  const subcommandIndex = findGitSubcommandIndex(tokens);
  if (subcommandIndex < 1) return false;
  const rawSubcommand = normalizeAgentValue(stripOuterQuotes(tokens[subcommandIndex] || ""));
  const gitBaseCwd = getGitGlobalCwdOption(tokens, 0, baseCwd, {}) || baseCwd || process.cwd();
  const aliasValue = getConfiguredGitAliasValue(gitBaseCwd, rawSubcommand);
  if (!aliasValue || aliasValue.trim().startsWith("!")) return false;
  const aliasTokens = tokenizeCommandLine(aliasValue.trim());
  if (aliasTokens.length === 0) return false;
  const resolvedTokens = ["git", ...aliasTokens, ...tokens.slice(subcommandIndex + 1)];
  return isCanonicalReadOnlyGitResolvedTokens(resolvedTokens, 1);
}

function hasOnlyCanonicalGitGlobalArguments(tokens, subcommandIndex) {
  const safeValueless = new Set([
    "--bare", "--glob-pathspecs", "--icase-pathspecs", "--literal-pathspecs",
    "--no-optional-locks", "--no-pager", "--noglob-pathspecs",
  ]);
  const safeValued = new Set(["--git-dir", "--namespace", "--work-tree"]);
  let hasEffectiveCwd = false;
  for (let index = 1; index < subcommandIndex; index += 1) {
    const raw = stripOuterQuotes(String(tokens[index] || ""));
    const value = normalizeAgentValue(raw);
    if (safeValueless.has(value)) continue;
    if (raw === "-C") {
      if (++index >= subcommandIndex) return false;
      const cwd = stripOuterQuotes(String(tokens[index] || "")).trim();
      if (!cwd && !hasEffectiveCwd) return false;
      if (cwd) hasEffectiveCwd = true;
      continue;
    }
    if (raw.startsWith("-C") && raw.length > 2) {
      hasEffectiveCwd = true;
      continue;
    }
    if (raw === "-c") {
      if (index + 1 >= subcommandIndex || !isCanonicalSafeGitInlineConfiguration(stripOuterQuotes(tokens[++index]))) return false;
      continue;
    }
    if (raw.startsWith("-c") && raw.length > 2) {
      if (!isCanonicalSafeGitInlineConfiguration(raw.slice(2))) return false;
      continue;
    }
    if (safeValued.has(value)) {
      if (++index >= subcommandIndex || !stripOuterQuotes(String(tokens[index] || "")).trim()) return false;
      continue;
    }
    if (["--git-dir=", "--namespace=", "--work-tree="].some((prefix) => value.startsWith(prefix) && value.length > prefix.length)) continue;
    return false;
  }
  return true;
}

function hasDirectGitProcessEnvironment(source) {
  return /(?:^|\s)(?:GIT_CONFIG_[A-Z0-9_]+|GIT_EXTERNAL_DIFF|GIT_PAGER|GIT_EDITOR|GIT_SEQUENCE_EDITOR|GIT_SSH|GIT_SSH_COMMAND|GIT_ASKPASS|GIT_ALLOW_PROTOCOL)\s*=/iu.test(
    String(source || ""),
  );
}

function hasNodeStartupCodeConfiguration(tokens, source = "") {
  if (hasRuntimeNodeOptionsEnvironmentMutation(source)) return true;
  const inlineOptions = new Set(["-e", "-p", "-pe", "--eval", "--print"]);
  const safeValueOptions = new Set(["--conditions", "--input-type"]);
  const safeValuelessOptions = new Set([
    "-c", "-h", "-v", "--check", "--help", "--no-warnings", "--trace-warnings", "--use-strict", "--version",
  ]);
  const inlineAssignmentPrefixes = ["--eval=", "--eval:", "--print=", "--print:"];
  let sawInline = false;
  for (let index = 1; index < tokens.length; index += 1) {
    const rawValue = stripOuterQuotes(String(tokens[index] || ""));
    const value = normalizeAgentValue(rawValue);
    if (value === "--") return false;
    if (inlineOptions.has(value)) {
      sawInline = true;
      const next = normalizeAgentValue(String(tokens[index + 1] || ""));
      if ((value === "-p" || value === "--print") &&
          (inlineOptions.has(next) || inlineAssignmentPrefixes.some((prefix) => next.startsWith(prefix)))) continue;
      if (index + 1 < tokens.length) index += 1;
      continue;
    }
    if (inlineAssignmentPrefixes.some((prefix) => value.startsWith(prefix))) {
      sawInline = true;
      continue;
    }
    if (safeValueOptions.has(value)) {
      if (index + 1 >= tokens.length) return true;
      index += 1;
      continue;
    }
    if (["--conditions=", "--input-type="].some((prefix) => value.startsWith(prefix))) continue;
    if (safeValuelessOptions.has(value)) continue;
    if (value.startsWith("-") || value.startsWith("+")) return true;
    if (!sawInline) return false;
  }
  return false;
}

function hasRuntimeNodeOptionsEnvironmentMutation(source) {
  const text = String(source || "");
  const environmentNameStates = getRuntimeEnvironmentMutationNameStates(text);
  if (environmentNameStates.hasNodeOptions || environmentNameStates.hasUnresolved) return true;
  const powerShellEnvironmentReflection = /(?:\[(?:System\.)?Environment\]|\[type\]\s*::\s*GetType\s*\(\s*["']System\.Environment["']\s*\))[\s\S]{0,1024}?\.(?:GetMethod|GetMethods|GetMember|GetMembers|InvokeMember)\s*\(/iu;
  if (powerShellEnvironmentReflection.test(text)) return true;
  const unownedPowerShellReflection = /(?:\.|::)(?:GetMethod|GetMethods|GetMember|GetMembers|InvokeMember|CreateDelegate)\s*\(/iu;
  if (unownedPowerShellReflection.test(text)) return true;
  const dynamicPowerShellMemberInvocation = /(?:\.|::)\s*(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\([^)]*\)|\([^\r\n)]*\)|["'][^"'\r\n]+["']|[A-Za-z_][A-Za-z0-9_`]*`[A-Za-z0-9_`]*)\s*\(/u;
  if (dynamicPowerShellMemberInvocation.test(text)) return true;
  return /\$env:NODE_OPTIONS\s*(?:=|\+=)/iu.test(text) ||
    /\[(?:System\.)?Environment\]\s*::\s*SetEnvironmentVariable\s*\(\s*["']NODE_OPTIONS["']/iu.test(text) ||
    /\b(?:Set-Item|si|New-Item|ni|Remove-Item|ri|Clear-Item|cli|Set-Content|sc|Clear-Content|clc)\b[^;&\r\n]*(?:Env:\\?)?NODE_OPTIONS\b/iu.test(text) ||
    /(?:^|[;&\r\n])\s*(?:export|declare|typeset|local)\s+(?:[-+][A-Za-z]+\s+)*["']?NODE_OPTIONS\s*=/iu.test(text) ||
    /(?:^|[;&\r\n])\s*set\s+["']?NODE_OPTIONS\s*=/iu.test(text) ||
    /(?:^|\s)NODE_OPTIONS\s*=/iu.test(text) ||
    /\bprocess\.env(?:\.NODE_OPTIONS|\[\s*["']NODE_OPTIONS["']\s*\])\s*(?:=|\+=|\|\|=|\?\?=)/iu.test(text) ||
    /\bos\.(?:environ\s*\[\s*["']NODE_OPTIONS["']\s*\]\s*=|putenv\s*\(\s*["']NODE_OPTIONS["'])/iu.test(text);
}

function hasRgExternalProcessConfiguration(tokens) {
  return tokens.slice(1).map((value) => normalizeAgentValue(value)).some((value) =>
    value === "--pre" ||
    value.startsWith("--pre=") ||
    value === "--hostname-bin" ||
    value.startsWith("--hostname-bin="));
}

function isCanonicalReadOnlyGhArguments(values) {
  const args = values.map((value) => normalizeAgentValue(value));
  if (args.length >= 2 && (args[0] === "pr" || args[0] === "issue") && args[1] === "view") return true;
  if (args[0] !== "api") return false;
  for (let index = 1; index < args.length; index += 1) {
    if ((args[index] === "--method" || args[index] === "-x") && args[index + 1] !== "get") return false;
    if (args[index].startsWith("--method=") && args[index].slice("--method=".length) !== "get") return false;
  }
  return !args.some((value) => value === "--input" || value === "-f" || value === "--field" || value === "--raw-field");
}

function classifyStaticProcessInvocation(tool, resolvedArguments, rawBoundary = "", depth = 0, denyGit = false) {
  if (!resolvedArguments || resolvedArguments.some((value) => value === null)) {
    return /\bcodex(?:\.exe)?\b/iu.test(rawBoundary)
      ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  if (depth > 6) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  const normalizedTool = normalizeExecutableName(tool);
  if (normalizedTool === "env") {
    const unwrapped = unwrapEnvCommandTokens([tool, ...resolvedArguments]);
    if (unwrapped.length === 0 || normalizeExecutableName(unwrapped[0]) === "env") {
      return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    }
    return classifyStaticProcessInvocation(
      normalizeExecutableName(unwrapped[0]),
      unwrapped.slice(1),
      rawBoundary,
      depth + 1,
      denyGit,
    );
  }
  if (normalizedTool === "codex") {
    if (resolvedArguments.some(isDeniedCodexMode)) return INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED;
    return isCanonicalReadOnlyCodexArguments(resolvedArguments)
      ? INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY
      : INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED;
  }
  const nestedInterpreterKind = getShellInterpreterKind([normalizedTool, ...resolvedArguments]);
  if (nestedInterpreterKind === "node" || nestedInterpreterKind === "python") {
    if (denyGit) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    if (nestedInterpreterKind === "node" &&
        hasNodeStartupCodeConfiguration([normalizedTool, ...resolvedArguments], rawBoundary)) {
      return INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED;
    }
    const script = getInterpreterInlineSourceToken([normalizedTool, ...resolvedArguments], nestedInterpreterKind);
    if (script === null || script === undefined) {
      return resolvedArguments.length === 1 && ["--help", "--version", "-v"].includes(normalizeAgentValue(resolvedArguments[0]))
        ? INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY
        : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    }
    const unsupported = nestedInterpreterKind === "node"
      ? hasUnsupportedNodeProcessConstruction(script) || hasDynamicInterpreterGitSubcommand(script)
      : hasUnsupportedPythonModuleLoad(script) ||
        hasUnsupportedPythonProcessConstruction(script) ||
        hasUnresolvedInterpreterProcessBoundary(script) ||
        hasDynamicInterpreterGitSubcommand(script);
    return unsupported
      ? INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED;
  }
  if (normalizedTool === "git") {
    if (denyGit) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    const tokens = [normalizedTool, ...resolvedArguments];
    const subcommandIndex = findGitSubcommandIndex(tokens);
    const subcommand = subcommandIndex < 0 ? "" : normalizeAgentValue(tokens[subcommandIndex]);
    const canLaunchExternalProcess = hasGitExternalProcessConfiguration(tokens);
    const readOnlySubcommand = isReadOnlyGitSubcommand(subcommand, tokens, subcommandIndex) ||
      (subcommand === "branch" && isReadOnlyGitBranchCommand(tokens, subcommandIndex)) ||
      (subcommand === "tag" && isReadOnlyGitTagCommand(tokens, subcommandIndex)) ||
      (subcommand === "worktree" && isReadOnlyGitWorktreeCommand(tokens, subcommandIndex)) ||
      isCanonicalReadOnlyGitInlineAliasInvocation(tokens, subcommandIndex);
    const reviewGatedSubcommand = isReviewGatedCommand(tokens.join(" "));
    if (subcommandIndex <= 0 || !hasOnlyCanonicalGitGlobalArguments(tokens, subcommandIndex) || canLaunchExternalProcess) {
      return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    }
    return readOnlySubcommand || reviewGatedSubcommand
      ? INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  if (normalizedTool === "gh") {
    return isCanonicalReadOnlyGhArguments(resolvedArguments)
      ? INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  if (normalizedTool === "forfiles") {
    const commandIndex = resolvedArguments.findIndex((value) => normalizeAgentValue(value) === "/c");
    if (commandIndex < 0) return INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED;
    const nestedCommand = resolvedArguments[commandIndex + 1];
    if (!nestedCommand) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    const nestedTokens = tokenizeCommandLine(nestedCommand);
    if (nestedTokens.length === 0) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    return classifyStaticProcessInvocation(
      normalizeExecutableName(nestedTokens[0]),
      nestedTokens.slice(1),
      nestedCommand,
      depth + 1,
      denyGit,
    );
  }
  if (!isNestedShellProcessLauncher(normalizedTool)) {
    return STATIC_NON_EXECUTOR_TOOL_ALLOWLIST.has(normalizedTool)
      ? INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  const nestedCommand = getStaticNestedShellCommand(normalizedTool, resolvedArguments);
  if (nestedCommand === null) {
    return /\bcodex(?:\.exe)?\b|\b(?:exec|e|--sandbox)\b/iu.test(rawBoundary)
      ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  if (isDirectCodexDispatch(nestedCommand)) return INTERPRETER_PROCESS_BOUNDARY.DENY_PROTECTED;
  if (/[;&|<>\r\n]/u.test(nestedCommand)) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  const nestedTokens = tokenizeCommandLine(nestedCommand);
  if (nestedTokens.length === 0) return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  const nestedDecision = classifyStaticProcessInvocation(
    normalizeExecutableName(nestedTokens[0]),
    nestedTokens.slice(1),
    nestedCommand,
    depth + 1,
    denyGit,
  );
  return nestedDecision === INTERPRETER_PROCESS_BOUNDARY.ALLOW_STATIC_READONLY ||
    nestedDecision === INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED
    ? nestedDecision
    : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
}

function classifyCodexArgvInvocation(toolExpression, argvExpression, source, callIndex, scopes, language, toolInsideVector, outerProtectedHint = false, denyGit = false) {
  const elements = getArgumentContainerElements(argvExpression, source, callIndex, scopes, language);
  const resolvedTool = toolInsideVector
    ? (elements ? evaluateScopedStaticStringExpression(elements[0], source, callIndex, scopes, language) : null)
    : evaluateScopedStaticStringExpression(toolExpression, source, callIndex, scopes, language);
  const tool = normalizeExecutableName(resolvedTool || "");
  const argumentElements = elements?.slice(toolInsideVector ? 1 : 0);
  const resolvedArguments = argumentElements?.map((element) =>
    evaluateScopedStaticStringExpression(element, source, callIndex, scopes, language));
  if (toolInsideVector && !elements) {
    const containerName = String(argvExpression || "").trim();
    const event = /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(containerName)
      ? getLatestScopedAssignmentEvent(source, containerName, callIndex, scopes, language)
      : null;
    if (/\bcodex(?:\.exe)?\b/iu.test(event?.expression || containerName)) {
      return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
    }
  }
  if (resolvedTool !== null) {
    return classifyStaticProcessInvocation(
      tool,
      resolvedArguments,
      [toolExpression, argvExpression, ...(elements || [])].join(" "),
      0,
      denyGit,
    );
  }
  const rawBoundary = [toolExpression, argvExpression, ...(elements || [])].join(" ");
  if (outerProtectedHint || /\bcodex(?:\.exe)?\b/iu.test(rawBoundary)) {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
  }
  return INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
}

function isPythonOsProcessCapabilityName(value) {
  return /^(?:(?:exec|spawn|posix_spawn)[A-Za-z0-9_]*|system|popen|startfile)$/u.test(normalizeAgentValue(value));
}

function getPythonOsProcessSignature(value) {
  const method = normalizeAgentValue(value);
  if (/^posix_spawnp?$/u.test(method)) {
    return { toolIndex: 0, argvKind: "vector", argvIndex: 1, hasEnvironment: true };
  }
  const match = /^(exec|spawn)([lv])((?:e|p|pe)?)$/u.exec(method);
  if (!match) return null;
  const toolIndex = match[1] === "spawn" ? 1 : 0;
  return {
    toolIndex,
    argvKind: match[2] === "v" ? "vector" : "scalar",
    argvIndex: toolIndex + 1,
    hasEnvironment: match[3].endsWith("e"),
  };
}

function getPythonAssignmentElements(value) {
  const candidate = String(value || "").trim();
  if (candidate.startsWith("[") && candidate.endsWith("]")) {
    return { sequence: true, elements: splitTopLevelCallArguments(candidate.slice(1, -1)).map((part) => part.trim()) };
  }
  if (candidate.startsWith("(") && candidate.endsWith(")")) {
    const body = getBalancedCallBody(candidate, 0);
    if (body !== null && body.length === candidate.length - 2) {
      const elements = splitTopLevelCallArguments(body).map((part) => part.trim());
      const sequence = elements.length > 1 || /,\s*$/u.test(body);
      return { sequence, elements };
    }
  }
  if (candidate.startsWith("{") && candidate.endsWith("}")) {
    return { sequence: true, elements: splitTopLevelCallArguments(candidate.slice(1, -1)).map((part) => part.trim()) };
  }
  const elements = splitTopLevelCallArguments(candidate).map((part) => part.trim());
  return { sequence: elements.length > 1, elements };
}

function maskPythonNonCode(source) {
  const characters = String(source || "").split("");
  const mask = (index) => {
    if (characters[index] !== "\r" && characters[index] !== "\n") characters[index] = " ";
  };
  for (let index = 0; index < characters.length;) {
    if (characters[index] === "#") {
      while (index < characters.length && characters[index] !== "\r" && characters[index] !== "\n") {
        mask(index);
        index += 1;
      }
      continue;
    }
    if (characters[index] !== "'" && characters[index] !== '"') {
      index += 1;
      continue;
    }
    const quote = characters[index];
    const triple = characters[index + 1] === quote && characters[index + 2] === quote;
    const width = triple ? 3 : 1;
    for (let offset = 0; offset < width; offset += 1) mask(index + offset);
    index += width;
    while (index < characters.length) {
      if (!triple && characters[index] === "\\") {
        mask(index);
        index += 1;
        if (index < characters.length) {
          mask(index);
          index += 1;
        }
        continue;
      }
      if (triple && characters[index] === quote && characters[index + 1] === quote && characters[index + 2] === quote) {
        for (let offset = 0; offset < 3; offset += 1) mask(index + offset);
        index += 3;
        break;
      }
      if (!triple && characters[index] === quote) {
        mask(index);
        index += 1;
        break;
      }
      mask(index);
      index += 1;
    }
  }
  return characters.join("");
}

function decodeStaticJavaScriptStringLiteral(source) {
  const text = String(source || "").trim();
  try {
    const node = acorn.parseExpressionAt(text, 0, { ecmaVersion: "latest" });
    if (node.end !== text.length) return null;
    if (node.type === "Literal" && typeof node.value === "string") return node.value;
    if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
      return node.quasis.map((part) => part.value.cooked).join("");
    }
  } catch (_) {
    return null;
  }
  return null;
}

function maskJavaScriptNonCodeForProcessDiscovery(source) {
  const original = String(source || "");
  const characters = original.split("");
  const maskRange = (start, end) => {
    for (let index = start; index < end; index += 1) {
      if (characters[index] !== "\r" && characters[index] !== "\n") characters[index] = " ";
    }
  };
  for (let index = 0; index < characters.length;) {
    if (characters[index] === "/" && characters[index + 1] === "/") {
      const start = index;
      while (index < characters.length && characters[index] !== "\r" && characters[index] !== "\n") index += 1;
      maskRange(start, index);
      continue;
    }
    if (characters[index] === "/" && characters[index + 1] === "*") {
      const start = index;
      index += 2;
      while (index < characters.length && !(characters[index] === "*" && characters[index + 1] === "/")) index += 1;
      index = Math.min(characters.length, index + 2);
      maskRange(start, index);
      continue;
    }
    const quote = characters[index];
    if (quote !== "'" && quote !== '"' && quote !== "`") {
      index += 1;
      continue;
    }
    const start = index;
    index += 1;
    let escaped = false;
    while (index < characters.length) {
      if (escaped) {
        escaped = false;
      } else if (characters[index] === "\\") {
        escaped = true;
      } else if (characters[index] === quote) {
        index += 1;
        break;
      }
      index += 1;
    }
    const decodedLiteral = decodeStaticJavaScriptStringLiteral(original.slice(start, index));
    const isStaticChildProcessModule = decodedLiteral === "child_process" || decodedLiteral === "node:child_process";
    if (!isStaticChildProcessModule) {
      maskRange(start, index);
    } else {
      maskRange(start + 1, index);
      for (let offset = 0; offset < decodedLiteral.length && start + 1 + offset < index; offset += 1) {
        characters[start + 1 + offset] = decodedLiteral[offset];
      }
      if (start + 1 + decodedLiteral.length < index) {
        characters[start + 1 + decodedLiteral.length] = quote;
      }
    }
  }
  return characters.join("");
}

function getResolvedPythonCallStrings(callBody, source, callIndex, scopes) {
  const values = [];
  const visit = (expression) => {
    const elements = getArgumentContainerElements(expression, source, callIndex, scopes, "python");
    if (elements) {
      for (const element of elements) visit(element);
      return;
    }
    const value = evaluateScopedStaticStringExpression(expression, source, callIndex, scopes, "python");
    if (value !== null) values.push(value);
  };
  for (const expression of splitTopLevelCallArguments(callBody)) visit(expression);
  return values;
}

function hasProtectedCodexEvidenceInPythonCall(callBody, source, callIndex, scopes, outerProtectedHint = false) {
  if (outerProtectedHint) return true;
  const values = getResolvedPythonCallStrings(callBody, source, callIndex, scopes);
  return values.some((value) => normalizeExecutableName(value) === "codex") &&
    values.some(isDeniedCodexMode);
}

function classifyPythonOsProcessCall(method, callBody, source, callIndex, scopes, outerProtectedHint = false, escapedCapability = false) {
  const protectedHint = hasProtectedCodexEvidenceInPythonCall(callBody, source, callIndex, scopes, outerProtectedHint);
  const protectedModeHint = getResolvedPythonCallStrings(callBody, source, callIndex, scopes).some(isDeniedCodexMode);
  const normalizedMethod = normalizeAgentValue(method);
  if (normalizedMethod === "system" || normalizedMethod === "popen") {
    if (escapedCapability) {
      return protectedHint || protectedModeHint
        ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
        : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
    }
    const commandExpression = stripLeadingCallComments(splitTopLevelCallArguments(callBody)[0]);
    return classifyCodexCommandExpression(
      commandExpression,
      getConstantStringAssignments(source, callIndex),
      source,
      callIndex,
      scopes,
      "python",
      outerProtectedHint,
      true,
    );
  }
  const signature = getPythonOsProcessSignature(method);
  if (escapedCapability || !signature) {
    return protectedHint
      ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }
  const expressions = splitTopLevelCallArguments(callBody);
  const toolExpression = expressions[signature.toolIndex];
  const resolvedTool = toolExpression === undefined
    ? null
    : evaluateScopedStaticStringExpression(toolExpression, source, callIndex, scopes, "python");
  const tool = normalizeExecutableName(resolvedTool || "");
  if (resolvedTool === null) {
    return protectedHint || protectedModeHint
      ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
      : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS;
  }

  let argumentExpressions;
  if (signature.argvKind === "vector") {
    argumentExpressions = getArgumentContainerElements(expressions[signature.argvIndex], source, callIndex, scopes, "python");
  } else {
    const end = signature.hasEnvironment ? Math.max(signature.argvIndex, expressions.length - 1) : expressions.length;
    argumentExpressions = expressions.slice(signature.argvIndex, end);
  }
  if (!argumentExpressions || argumentExpressions.length === 0) {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
  }
  const resolvedArguments = argumentExpressions.map((expression) =>
    evaluateScopedStaticStringExpression(expression, source, callIndex, scopes, "python"));
  if (resolvedArguments.some((value) => value === null)) {
    return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
  }
  return classifyStaticProcessInvocation(tool, resolvedArguments.slice(1), callBody, 0, true);
}

function classifyPythonOsProcessBoundary(source, scopes, outerProtectedHint = false) {
  const text = String(source || "");
  const code = maskPythonNonCode(text);
  const moduleAliases = new Set(["os"]);
  const escapedAliases = new Set();
  let hasCapabilityEscape = false;
  for (const match of code.matchAll(/\bimport\s+os\s+as\s+([A-Za-z_][A-Za-z0-9_]*)/gu)) {
    moduleAliases.add(match[1]);
  }
  for (const match of code.matchAll(/\bfrom\s+os\s+import\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (binding && isPythonOsProcessCapabilityName(binding[1])) {
        escapedAliases.add(binding[2] || binding[1]);
      }
    }
  }

  const assignments = [];
  for (const match of code.matchAll(/(?:^|[;\r\n])\s*([^=;\r\n]+?)\s*(?<![<>=!:])=(?!=)\s*([^;\r\n]+)/gu)) {
    assignments.push({ index: match.index || 0, left: match[1].trim(), right: match[2].trim() });
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const assignment of assignments) {
      const leftNames = [...assignment.left.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\b/gu)].map((match) => match[1]);
      const leftBinding = getPythonAssignmentElements(assignment.left);
      const rightBinding = getPythonAssignmentElements(assignment.right);
      const leftElements = leftBinding.elements;
      const rightElements = rightBinding.elements;
      if (!leftBinding.sequence && rightBinding.sequence && rightElements.some((element) => moduleAliases.has(element))) {
        hasCapabilityEscape = true;
      }
      for (let offset = 0; offset < Math.min(leftElements.length, rightElements.length); offset += 1) {
        if (rightBinding.sequence && !leftBinding.sequence) break;
        if (/^[A-Za-z_][A-Za-z0-9_]*$/u.test(leftElements[offset]) && moduleAliases.has(rightElements[offset])) {
          if (!moduleAliases.has(leftElements[offset])) {
            moduleAliases.add(leftElements[offset]);
            changed = true;
          }
        }
      }
      const rightName = rightElements.length === 1 && !rightBinding.sequence
        ? /^([A-Za-z_][A-Za-z0-9_]*)$/u.exec(rightElements[0])?.[1]
        : undefined;
      if (rightName && moduleAliases.has(rightName)) {
        for (const name of leftNames) {
          if (!moduleAliases.has(name)) {
            moduleAliases.add(name);
            changed = true;
          }
        }
      }
      const modulePattern = [...moduleAliases].map(escapeRegex).join("|");
      const capabilityReference = modulePattern && new RegExp(`\\b(?:${modulePattern})\\.(?:(?:exec|spawn|posix_spawn)[A-Za-z0-9_]*|system|popen|startfile)\\b(?!\\s*\\()`, "u").test(assignment.right);
      const getattrReference = modulePattern && new RegExp(`\\bgetattr\\s*\\(\\s*(?:${modulePattern})\\s*,`, "u").test(assignment.right);
      if (capabilityReference || getattrReference || rightName && escapedAliases.has(rightName)) {
        for (const name of leftNames) escapedAliases.add(name);
      }
    }
  }

  const modulePattern = [...moduleAliases].map(escapeRegex).join("|");
  const processMethodPattern = "(?:exec|spawn|posix_spawn)[A-Za-z0-9_]*|system|popen|startfile";
  const parameterizedCapabilityFunctions = new Set();
  for (const assignment of assignments) {
    const functionName = /^([A-Za-z_][A-Za-z0-9_]*)$/u.exec(assignment.left)?.[1];
    const lambda = /^lambda\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([\s\S]+)$/u.exec(assignment.right);
    if (functionName && lambda && new RegExp(`\\b${escapeRegex(lambda[1])}\\.(?:${processMethodPattern})\\s*\\(`, "u").test(lambda[2])) {
      parameterizedCapabilityFunctions.add(functionName);
    }
  }
  if (modulePattern) {
    const moduleDictionaryAccess = new RegExp(`\\b(?:${modulePattern})\\s*\\.\\s*__dict__\\b`, "u");
    if (moduleDictionaryAccess.test(code)) hasCapabilityEscape = true;
    const directLambda = new RegExp(`\\(\\s*lambda\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*:\\s*\\1\\.(?:${processMethodPattern})\\s*\\([^)]*\\)\\s*\\)\\s*\\(\\s*(?:${modulePattern})\\s*\\)`, "u");
    if (directLambda.test(code)) hasCapabilityEscape = true;
    const defaultedLambda = new RegExp(`\\blambda\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?:${modulePattern})\\s*:\\s*\\1\\.(?:${processMethodPattern})\\s*\\(`, "u");
    if (defaultedLambda.test(code)) hasCapabilityEscape = true;
    for (const functionName of parameterizedCapabilityFunctions) {
      if (new RegExp(`\\b${escapeRegex(functionName)}\\s*\\(\\s*(?:${modulePattern})\\s*\\)`, "u").test(code)) {
        hasCapabilityEscape = true;
      }
    }
    const callPattern = /(?<![.A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*(?:(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)|(?:\s*\[[^\]]+\]))*)\s*\(/gu;
    for (const match of code.matchAll(callPattern)) {
      const callee = normalizeAgentValue(match[1]).replace(/\s+/gu, "");
      if (callee === "getattr") continue;
      const openIndex = (match.index || 0) + match[0].lastIndexOf("(");
      const body = getBalancedCallBody(text, openIndex);
      if (body === null) continue;
      const argumentsList = splitTopLevelCallArguments(body).map((argument) => String(argument || "").trim());
      if (argumentsList.some((argument) => moduleAliases.has(argument))) {
        hasCapabilityEscape = true;
        break;
      }
    }
  }

  const calls = [];
  const seen = new Set();
  const addCall = (method, openIndex, escaped) => {
    const key = `${openIndex}:${method}:${escaped}`;
    if (!seen.has(key)) {
      seen.add(key);
      calls.push({ method, openIndex, escaped });
    }
  };
  for (const alias of moduleAliases) {
    const pattern = new RegExp(`\\b${escapeRegex(alias)}\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\(`, "gu");
    for (const match of code.matchAll(pattern)) {
      if (isPythonOsProcessCapabilityName(match[1])) {
        addCall(match[1], (match.index || 0) + match[0].lastIndexOf("("), false);
      }
    }
  }
  for (const match of code.matchAll(/\bgetattr\s*\(/gu)) {
    const getattrOpenIndex = (match.index || 0) + match[0].lastIndexOf("(");
    const getattrBody = getBalancedCallBody(text, getattrOpenIndex);
    if (getattrBody === null) continue;
    const getattrArguments = splitTopLevelCallArguments(getattrBody);
    if (getattrArguments.length < 2 || !moduleAliases.has(String(getattrArguments[0] || "").trim())) continue;
    const method = evaluateScopedStaticStringExpression(getattrArguments[1], text, getattrOpenIndex, scopes, "python");
    if (method !== null && !isPythonOsProcessCapabilityName(method)) continue;
    const getattrCloseIndex = getattrOpenIndex + getattrBody.length + 1;
    const invocationSuffix = /^\s*\(/u.exec(code.slice(getattrCloseIndex + 1));
    if (invocationSuffix) {
      addCall(method || "unknown", getattrCloseIndex + 1 + invocationSuffix[0].lastIndexOf("("), method === null);
    } else {
      hasCapabilityEscape = true;
    }
  }
  for (const alias of escapedAliases) {
    const pattern = new RegExp(`(?<![A-Za-z0-9_])${escapeRegex(alias)}(?:\\s*\\[[^\\]]+\\])?\\s*\\(`, "gu");
    for (const match of code.matchAll(pattern)) {
      const callIndex = match.index || 0;
      const event = getLatestScopedAssignmentEvent(text, alias, callIndex, scopes, "python");
      if (event) {
        const expression = String(event.expression || "").trim();
        const referencedAlias = /^([A-Za-z_][A-Za-z0-9_]*)$/u.exec(expression)?.[1];
        const directCapability = modulePattern && new RegExp(
          `\\b(?:${modulePattern})\\.(?:(?:exec|spawn|posix_spawn)[A-Za-z0-9_]*|system|popen|startfile)\\b`,
          "u",
        ).test(expression);
        const reflectedCapability = modulePattern && new RegExp(
          `\\bgetattr\\s*\\(\\s*(?:${modulePattern})\\s*,`,
          "u",
        ).test(expression);
        if (!directCapability && !reflectedCapability && !(referencedAlias && escapedAliases.has(referencedAlias))) {
          continue;
        }
      }
      addCall("unknown", (match.index || 0) + match[0].lastIndexOf("("), true);
    }
  }

  let unowned = hasCapabilityEscape;
  for (const call of calls.sort((left, right) => left.openIndex - right.openIndex)) {
    const callBody = getBalancedCallBody(text, call.openIndex);
    if (callBody === null) {
      if (outerProtectedHint) return INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED;
      unowned = true;
      continue;
    }
    const result = classifyPythonOsProcessCall(
      call.method,
      callBody,
      text,
      call.openIndex,
      scopes,
      outerProtectedHint,
      call.escaped,
    );
    if (isDeniedInterpreterProcessBoundary(result)) return result;
    if (result === INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS) unowned = true;
  }
  return unowned
    ? INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS
    : INTERPRETER_PROCESS_BOUNDARY.ALLOW_PROVEN_NON_PROTECTED;
}

function getInterpreterProcessBoundaryResults(source) {
  const stage = String(source || "");
  const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(stage));
  const kind = getShellInterpreterKind(tokens);
  const inlineSource = kind ? getInterpreterInlineSourceToken(tokens, kind) : null;
  const text = inlineSource === null || inlineSource === undefined ? stage : String(inlineSource);
  const scopes = buildFunctionScopeIndex(text);
  const outerProtectedHint = hasOuterCodexProtectedArguments(stage);
  const results = [];

  if (kind === "python" || kind === null) {
    results.push(classifyPythonOsProcessBoundary(text, scopes, outerProtectedHint));
    const pythonCode = maskPythonNonCode(text);
    for (const call of getPythonProcessCalls(pythonCode)) {
      const callBody = getBalancedCallBody(text, call.openIndex);
      if (callBody === null) {
        results.push(outerProtectedHint
          ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
          : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS);
        continue;
      }
      const commandExpression = stripLeadingCallComments(splitTopLevelCallArguments(callBody)[0]);
      const assignments = getConstantStringAssignments(text, call.openIndex);
      if (normalizeAgentValue(call.method) === "system" || call.method === "popen") {
        const event = /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(commandExpression)
          ? getLatestScopedAssignmentEvent(text, commandExpression, call.openIndex, scopes, "python")
          : null;
        const resolvedExpression = event?.expression || commandExpression;
        results.push(classifyCodexCommandExpression(
          resolvedExpression,
          assignments,
          text,
          call.openIndex,
          scopes,
          "python",
          outerProtectedHint,
          true,
        ));
      } else {
        results.push(classifyCodexArgvInvocation(
          "",
          commandExpression,
          text,
          call.openIndex,
          scopes,
          "python",
          true,
          outerProtectedHint,
          true,
        ));
      }
    }
  }

  if (kind === "node" || kind === null) {
    const nodeCode = maskJavaScriptNonCodeForProcessDiscovery(text);
    for (const call of getNodeChildProcessCalls(nodeCode)) {
      const callBody = getBalancedCallBody(text, call.openIndex);
      if (callBody === null) {
        results.push(outerProtectedHint
          ? INTERPRETER_PROCESS_BOUNDARY.DENY_AMBIGUOUS_PROTECTED
          : INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS);
        continue;
      }
      const args = splitTopLevelCallArguments(callBody);
      const method = normalizeAgentValue(call.method);
      const assignments = getConstantStringAssignments(text, call.openIndex);
      if (method === "exec" || method === "execsync") {
        const commandCandidate = String(args[0] || "").trim();
        const event = /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(commandCandidate)
          ? getLatestScopedAssignmentEvent(text, commandCandidate, call.openIndex, scopes, "javascript")
          : null;
        results.push(classifyCodexCommandExpression(
          event?.expression || args[0],
          assignments,
          text,
          call.openIndex,
          scopes,
          "javascript",
          outerProtectedHint,
        ));
      } else {
        results.push(classifyCodexArgvInvocation(
          args[0],
          args[1],
          text,
          call.openIndex,
          scopes,
          "javascript",
          false,
          outerProtectedHint,
        ));
      }
    }
  }
  return results;
}

function hasInterpreterCodexDispatch(source) {
  return getInterpreterProcessBoundaryResults(source).some(isDeniedInterpreterProcessBoundary);
}

function hasUnownedInterpreterProcessBoundary(source) {
  return getInterpreterProcessBoundaryResults(source)
    .some((result) => result === INTERPRETER_PROCESS_BOUNDARY.DENY_UNOWNED_PROCESS);
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

function resolveReviewGateRepoRoots(toolInput, command) {
  const toolInputCwd = typeof toolInput?.cwd === "string" ? toolInput.cwd : "";
  const baseCwd = toolInputCwd || process.cwd();
  const baseRepoRoot = resolveGitTopLevel(baseCwd);
  const commandTargets = getReviewGatedCommandTargets(command, baseCwd);
  const candidates = commandTargets.targetCwds.length > 0
    ? [
        ...commandTargets.targetCwds,
        ...(commandTargets.requiresBaseCwd ? [baseCwd] : []),
      ]
    : [baseCwd];
  const repoRoots = [];
  const seen = new Set();

  for (const candidate of candidates) {
    const repoRoot = resolveGitTopLevel(candidate);
    if (!repoRoot) {
      return null;
    }
    if (repoRoot && isManagedReviewGateRepo(repoRoot, baseRepoRoot) && !seen.has(repoRoot)) {
      repoRoots.push(repoRoot);
      seen.add(repoRoot);
    }
  }

  return repoRoots;
}

function isManagedReviewGateRepo(repoRoot, baseRepoRoot) {
  if (!repoRoot) {
    return false;
  }

  if (baseRepoRoot && normalizeComparablePath(repoRoot) === normalizeComparablePath(baseRepoRoot)) {
    return true;
  }

  const repoCommonDir = getGitCommonDir(repoRoot);
  const baseCommonDir = getGitCommonDir(baseRepoRoot);
  if (repoCommonDir && baseCommonDir && normalizeComparablePath(repoCommonDir) === normalizeComparablePath(baseCommonDir)) {
    return true;
  }

  return fs.existsSync(path.join(repoRoot, ".winsmux"));
}

function getGitCommonDir(repoRoot) {
  if (!repoRoot) {
    return "";
  }

  try {
    const commonDir = execFileSync("git", ["-C", repoRoot, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return commonDir ? path.resolve(repoRoot, commonDir) : "";
  } catch {
    return "";
  }
}

function resolveGitTopLevel(candidate) {
  if (typeof candidate !== "string" || candidate.trim() === "" || candidate.includes("\0")) {
    return "";
  }

  const resolved = path.resolve(process.cwd(), stripOuterQuotes(candidate.trim()));
  try {
    return execFileSync("git", ["-C", resolved, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function getReviewGatedCommandTargets(command, baseCwd, depth = 0, inheritedGitEnvContext = {}) {
  if (depth > 5) {
    const inheritedTarget = inheritedGitEnvContext?.targetCwd || "";
    return {
      targetCwds: [...(inheritedTarget ? [inheritedTarget] : []), "\0unresolved-review-target-depth"],
      requiresBaseCwd: true,
    };
  }

  const powerShellComSpecCommand = materializePowerShellComSpecAliases(command);
  if (powerShellComSpecCommand !== command) {
    return getReviewGatedCommandTargets(powerShellComSpecCommand, baseCwd, depth + 1, inheritedGitEnvContext);
  }

  const targetCwds = [];
  let requiresBaseCwd = false;
  if (hasConservativeProtectedCmdBoundary(command)) {
    targetCwds.push("\0conservative-cmd-review-target");
  }
  if (hasCommandLocalGitAliasConfiguration(command)) {
    targetCwds.push("\0unresolved-command-local-git-alias");
  }
  if (hasPersistentGitTargetMutation(command)) {
    targetCwds.push("\0unresolved-persistent-git-environment");
  }
  if (hasUnresolvedChildProcessGitTarget(command)) {
    targetCwds.push("\0unresolved-child-process-git-target");
  }
  let parsedSeparatedFunctionWrapper = false;
  let parsedXargsWrapper = false;
  const shellForwardingFunctions = getSeparatedForwardingFunctionDefinitions(command);
  let effectiveBaseCwd = baseCwd || process.cwd();
  const controlFlowExecutionStack = [];
  const materializedCommand = materializeConstantExecutableSubstitutions(command);
  if (materializedCommand !== command && isReviewGatedCommand(materializedCommand)) {
    const materializedTargets = getReviewGatedCommandTargets(materializedCommand, baseCwd, depth + 1, inheritedGitEnvContext);
    targetCwds.push(...materializedTargets.targetCwds);
    requiresBaseCwd = requiresBaseCwd || materializedTargets.requiresBaseCwd;
  }
  for (const indirectCommand of getConstantShellStdinCommands(command)) {
    if (!isReviewGatedCommand(indirectCommand)) {
      continue;
    }
    const indirectTargets = getReviewGatedCommandTargets(indirectCommand, baseCwd, depth + 1, inheritedGitEnvContext);
    targetCwds.push(...indirectTargets.targetCwds);
    requiresBaseCwd = requiresBaseCwd || indirectTargets.requiresBaseCwd;
  }
  for (const heredocBody of getExecutableHeredocBodies(command)) {
    if (!isReviewGatedCommand(heredocBody) && !hasConfiguredGitReviewLifecycleAlias(heredocBody, baseCwd)) {
      continue;
    }
    const nestedTargets = getReviewGatedCommandTargets(heredocBody, baseCwd, depth + 1, inheritedGitEnvContext);
    targetCwds.push(...nestedTargets.targetCwds);
    requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
  }
  for (const commandSegment of splitCommandSegmentsWithSeparators(command)) {
    const segment = commandSegment.segment;
    const controlFlowBoundary = getShellControlFlowBoundary(segment);
    if (controlFlowBoundary === "branch") {
      updateShellControlFlowBranchExecution(controlFlowExecutionStack, segment, commandSegment.separatorAfter);
    }

    const segmentBaseCwd = effectiveBaseCwd;
    const controlFlowExecutionState = getShellControlFlowExecutionState(controlFlowExecutionStack);
    for (const stage of splitCommandPipelineStages(segment)) {
      const executableStage = unwrapShellExecutableControlFlowPrefix(stage);
      if (executableStage && executableStage !== stage.trim()) {
        const nestedTargets = getReviewGatedCommandTargets(executableStage, segmentBaseCwd, depth + 1, inheritedGitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      const powerShellStage = unwrapPowerShellCommandWrapper(stage);
      if (powerShellStage !== stage.trim()) {
        const nestedTargets = getReviewGatedCommandTargets(powerShellStage, segmentBaseCwd, depth + 1, inheritedGitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      const groupedStage = unwrapShellGroupingWrapper(powerShellStage);
      if (groupedStage !== powerShellStage.trim()) {
        const nestedTargets = getReviewGatedCommandTargets(groupedStage, segmentBaseCwd, depth + 1, inheritedGitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      const normalizedStage = groupedStage;
      for (const substitutionCommand of getShellCommandSubstitutionCommands(normalizedStage)) {
        if (!isReviewGatedCommand(substitutionCommand)) {
          continue;
        }

        const substitutionTargets = getReviewGatedCommandTargets(substitutionCommand, segmentBaseCwd, depth + 1, inheritedGitEnvContext);
        if (substitutionTargets.targetCwds.length === 0 && !substitutionTargets.requiresBaseCwd) {
          targetCwds.push(segmentBaseCwd || process.cwd());
        } else {
          targetCwds.push(...substitutionTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || substitutionTargets.requiresBaseCwd;
        }
      }

      const rawTokens = tokenizeCommandLine(normalizedStage);
      const gitEnvContext = mergeGitInlineEnvironmentContext(
        inheritedGitEnvContext,
        getGitInlineEnvironmentContext(rawTokens, segmentBaseCwd),
      );
      const gitCommandBaseCwd = gitEnvContext.baseCwd || segmentBaseCwd;
      const unwrappedExecution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(rawTokens));
      if (unwrappedExecution.nestedCommand) {
        const nestedTargets = getReviewGatedCommandTargets(unwrappedExecution.nestedCommand, gitCommandBaseCwd, depth + 1, gitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }
      const tokens = unwrappedExecution.tokens;
      if (tokens.length === 0) {
        continue;
      }

      const executable = getExecutableBasename(tokens[0]);
      const forwardingFunctionCommand = getForwardingFunctionInvocationCommand(tokens, shellForwardingFunctions);
      if (forwardingFunctionCommand) {
        parsedSeparatedFunctionWrapper = true;
        const nestedTargets = getReviewGatedCommandTargets(forwardingFunctionCommand, gitCommandBaseCwd, depth + 1, gitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      if (executable === "cmd" || executable === "cmd.exe") {
        const nestedCommand = getCmdShellArgument(tokens);
        const rawNestedCommand = getCmdShellArgument(tokens, false);
        const hasUnsupportedCmdState = /\bsetlocal\s+(?:Enable|Disable)DelayedExpansion\b/iu.test(rawNestedCommand) ||
          /\bif\s+(?:not\s+)?defined\b/iu.test(rawNestedCommand) ||
          (/&&[\s\S]*\|\||\|\|[\s\S]*&&/u.test(rawNestedCommand) &&
            !/^(?:\s*set\s+[^&|]+\s*(?:&&|\|\|)\s*)+/iu.test(rawNestedCommand));
        if (hasUnsupportedCmdState && nestedCommand && isReviewGatedCommand(nestedCommand)) {
          targetCwds.push("\0unresolved-cmd-review-target");
          continue;
        }
        const nestedTargets = getReviewGatedCommandTargets(nestedCommand || "", gitCommandBaseCwd, depth + 1, gitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      if (isPowerShellExecutable(executable)) {
        const nestedCommand = getPowerShellNestedCommand(tokens);
        const initialWorkingDirectory = getPowerShellInitialWorkingDirectory(tokens, executable);
        const powerShellCommandBaseCwd = initialWorkingDirectory
          ? resolveGitCwdOption(gitCommandBaseCwd, "", initialWorkingDirectory)
          : gitCommandBaseCwd;
        if (initialWorkingDirectory && !powerShellCommandBaseCwd &&
            (isReviewGatedCommand(nestedCommand) || hasConfiguredGitReviewLifecycleAlias(nestedCommand, gitCommandBaseCwd))) {
          targetCwds.push("\0unresolved-powershell-working-directory");
          continue;
        }
        const nestedTargets = getReviewGatedCommandTargets(nestedCommand || "", powerShellCommandBaseCwd, depth + 1, gitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        for (const blockBody of getBraceBlockBodies(nestedCommand)) {
          const blockTargets = getReviewGatedCommandTargets(blockBody, powerShellCommandBaseCwd, depth + 1, gitEnvContext);
          targetCwds.push(...blockTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || blockTargets.requiresBaseCwd;
        }
        continue;
      }

      if (isShellCommandExecutable(executable)) {
        const nestedCommand = getShellCommandArgument(tokens);
        const nestedTargets = getReviewGatedCommandTargets(nestedCommand || "", gitCommandBaseCwd, depth + 1, gitEnvContext);
        targetCwds.push(...nestedTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        continue;
      }

      if (isPowerShellStartProcessExecutable(executable)) {
        const invocation = getPowerShellStartProcessInvocation(tokens);
        const startProcessBaseCwd = invocation.workingDirectory
          ? resolveGitCwdOption(gitCommandBaseCwd, "", invocation.workingDirectory)
          : gitCommandBaseCwd;
        const startsWithFreshEnvironment = rawTokens.some((token) => normalizeAgentValue(stripOuterQuotes(token)) === "-usenewenvironment");
        const nestedTargets = getReviewGatedCommandTargets(
          invocation.command || "",
          startProcessBaseCwd,
          depth + 1,
          startsWithFreshEnvironment ? {} : gitEnvContext,
        );
        if (nestedTargets.targetCwds.length === 0 &&
            !nestedTargets.requiresBaseCwd &&
            hasPowerShellStartProcessLifecycleHint(normalizedStage)) {
          targetCwds.push(startProcessBaseCwd || "\0unresolved-start-process-working-directory");
        } else {
          targetCwds.push(...nestedTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || nestedTargets.requiresBaseCwd;
        }
        continue;
      }

      if (hasDynamicInterpreterGitSubcommand(normalizedStage)) {
        targetCwds.push("\0unresolved-interpreter-review-target");
        continue;
      }
      const interpreterCommands = getInterpreterLiteralGitCommands(normalizedStage, tokens)
        .filter((interpreterCommand) => isReviewGatedCommand(interpreterCommand));
      if (interpreterCommands.length > 0) {
        for (const interpreterCommand of interpreterCommands) {
          const interpreterTargets = getReviewGatedCommandTargets(interpreterCommand, gitCommandBaseCwd, depth + 1, gitEnvContext);
          targetCwds.push(...interpreterTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || interpreterTargets.requiresBaseCwd;
        }
        continue;
      }
      if (hasInterpreterReviewGatedGitLifecycleCommand(normalizedStage, tokens)) {
        targetCwds.push("\0unresolved-interpreter-review-target");
        continue;
      }

      if (executable === "xargs" || executable === "xargs.exe") {
        const xargsTargets = getReviewGatedXargsCommandTargets(tokens, segment, gitCommandBaseCwd, depth, gitEnvContext);
        if (xargsTargets.matched) {
          parsedXargsWrapper = true;
          targetCwds.push(...xargsTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || xargsTargets.requiresBaseCwd;
        }
        continue;
      }

      if (isGhExecutableToken(stripOuterQuotes(tokens[0]))) {
        if (isGhPrMergeTokenCommand(tokens) || isGhApiMergeCommand(tokens) || isGhApiRefWriteCommand(tokens)) {
          targetCwds.push(gitCommandBaseCwd || process.cwd());
        }
        continue;
      }

      if (!isGitExecutableToken(stripOuterQuotes(tokens[0]))) {
        continue;
      }

      const gitSubcommandIndex = findGitSubcommandIndex(tokens);
      if (gitSubcommandIndex < 0) {
        continue;
      }

      const rawGitSubcommand = normalizeAgentValue(stripOuterQuotes(tokens[gitSubcommandIndex]));
      const gitBaseCwd = getGitGlobalCwdOption(tokens, 0, gitCommandBaseCwd, gitEnvContext) || gitCommandBaseCwd || process.cwd();
      const configuredAliasValue = getConfiguredGitAliasValue(gitBaseCwd, rawGitSubcommand);
      if (configuredAliasValue && configuredAliasValue.trim().startsWith("!")) {
        const aliasTargets = getReviewGatedCommandTargets(configuredAliasValue.trim().slice(1), gitBaseCwd, depth + 1, gitEnvContext);
        if (aliasTargets.targetCwds.length === 0 && !aliasTargets.requiresBaseCwd) {
          targetCwds.push("\0unresolved-configured-git-alias");
        } else {
          targetCwds.push(...aliasTargets.targetCwds);
          requiresBaseCwd = requiresBaseCwd || aliasTargets.requiresBaseCwd;
        }
        continue;
      }

      const gitSubcommand = getConfiguredGitAliasSubcommand(configuredAliasValue) ||
        getGitSubcommandName(tokens, gitSubcommandIndex);
      if (!isReviewGatedGitSubcommand(gitSubcommand, tokens, gitSubcommandIndex)) {
        continue;
      }

      const shellAliasCommand = getGitShellAliasCommand(tokens, gitSubcommandIndex, rawGitSubcommand);
      if (shellAliasCommand) {
        const aliasTargets = getReviewGatedCommandTargets(shellAliasCommand, gitBaseCwd, depth + 1, gitEnvContext);
        if (aliasTargets.targetCwds.length === 0 && !aliasTargets.requiresBaseCwd) {
          targetCwds.push("\0unresolved-git-alias");
          continue;
        }

        targetCwds.push(...aliasTargets.targetCwds);
        requiresBaseCwd = requiresBaseCwd || aliasTargets.requiresBaseCwd;
        continue;
      }

      targetCwds.push(gitBaseCwd);
    }

    const cwdChange = getShellCwdChange(segment, segmentBaseCwd);
    const nextBaseCwd = cwdChange.target;
    if (nextBaseCwd) {
      const skipCwdChange = cwdChange.controlFlowPrefixed && controlFlowExecutionState === "inactive";
      if (!skipCwdChange && cwdChange.controlFlowPrefixed && controlFlowExecutionState === "unknown") {
        requiresBaseCwd = true;
      }
      effectiveBaseCwd = skipCwdChange
        ? effectiveBaseCwd
        : cwdChange.controlFlowPrefixed && controlFlowExecutionState === "unknown"
        ? "\0unresolved-control-flow-cwd"
        : hasConditionalCwdChangeBoundary(commandSegment)
        ? "\0unresolved-conditional-cwd-change"
        : nextBaseCwd;
    }
    updateShellControlFlowDepthExecution(controlFlowExecutionStack, segment, commandSegment.separatorAfter);
  }

  if (targetCwds.length > 0 && hasUnparsedBaseScopedReviewGatedCommand(command, parsedSeparatedFunctionWrapper, parsedXargsWrapper)) {
    requiresBaseCwd = true;
  }

  return { targetCwds, requiresBaseCwd };
}

function hasCommandLocalGitAliasConfiguration(command) {
  const source = String(command || "");
  const hasAliasConfiguration = /\bgit(?:\.exe)?\b/iu.test(source) &&
    /\balias\.[A-Za-z0-9._-]+\b/iu.test(source) &&
    (/\bGIT_CONFIG_(?:COUNT|KEY_[0-9]+|VALUE_[0-9]+)\b/iu.test(source) ||
     /--config-env(?:=|\s)/iu.test(source) ||
     /(?:^|\s)-c(?:=|\s)[^;&\r\n]*\balias\./iu.test(source));
  if (!hasAliasConfiguration) {
    return false;
  }
  const tokens = tokenizeCommandLine(source).map((token) => stripOuterQuotes(token));
  const environment = new Map();
  let hasNonAliasConfiguration = false;
  for (const token of tokens) {
    const assignment = /^([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*)$/u.exec(token);
    if (assignment) environment.set(normalizeAgentValue(assignment[1]), assignment[2]);
  }
  const aliasConfigurations = new Map();
  const addAliasConfiguration = (configuration) => {
    const candidate = String(configuration || "").trim();
    const match = /^alias\.([A-Za-z0-9._-]+)=([\s\S]*)$/iu.exec(candidate);
    if (match) aliasConfigurations.set(normalizeAgentValue(match[1]), match[2]);
    else if (candidate.includes("=")) hasNonAliasConfiguration = true;
  };
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    const normalized = normalizeAgentValue(token);
    if (normalized === "-c" && index + 1 < tokens.length) {
      addAliasConfiguration(tokens[index + 1]);
      index += 1;
      continue;
    }
    if (normalized.startsWith("-calias.")) {
      addAliasConfiguration(token.slice(2));
      continue;
    }
    const configEnv = normalized === "--config-env" && index + 1 < tokens.length
      ? tokens[++index]
      : normalized.startsWith("--config-env=")
      ? token.slice(token.indexOf("=") + 1)
      : "";
    if (configEnv) {
      const match = /^alias\.([A-Za-z0-9._-]+)=([A-Za-z_][A-Za-z0-9_]*)$/iu.exec(configEnv);
      if (match) aliasConfigurations.set(
        normalizeAgentValue(match[1]),
        environment.get(normalizeAgentValue(match[2])) || "",
      );
      else hasNonAliasConfiguration = true;
    }
  }
  for (const [name, value] of environment) {
    const keyMatch = /^git_config_key_([0-9]+)$/u.exec(name);
    if (keyMatch) {
      if (/^alias\.[A-Za-z0-9._-]+$/iu.test(value)) {
        aliasConfigurations.set(
          normalizeAgentValue(value.slice("alias.".length)),
          environment.get(`git_config_value_${keyMatch[1]}`) || "",
        );
      } else {
        hasNonAliasConfiguration = true;
      }
    }
  }
  if (hasNonAliasConfiguration || aliasConfigurations.size === 0) return true;
  const gitIndex = tokens.findIndex((token) => normalizeExecutableName(token) === "git");
  if (gitIndex < 0) return true;
  const gitTokens = tokens.slice(gitIndex);
  if ([...aliasConfigurations.values()].some((value) => String(value || "").trim().startsWith("!"))) {
    return !isCanonicalCommandLocalGitShellReviewAlias(gitTokens);
  }
  for (const value of aliasConfigurations.values()) {
    if (!isCanonicalSafeGitInlineConfiguration(`alias.x=${value}`)) return true;
  }
  const subcommandIndex = findGitSubcommandIndex(gitTokens);
  if (subcommandIndex < 1) return true;
  const invokedAlias = normalizeAgentValue(stripOuterQuotes(gitTokens[subcommandIndex] || ""));
  const aliasValue = aliasConfigurations.get(invokedAlias);
  if (aliasValue === undefined) return true;
  const aliasTokens = tokenizeCommandLine(String(aliasValue || "").trim());
  if (aliasTokens.length === 0 || String(aliasValue || "").trim().startsWith("!")) return true;
  const resolvedTokens = ["git", ...aliasTokens, ...gitTokens.slice(subcommandIndex + 1)];
  return !isCanonicalReadOnlyGitResolvedTokens(resolvedTokens, 1);
}

function hasConstructedGitEnvironmentName(source) {
  const text = String(source || "");
  const assignments = getConstantStringAssignments(text);
  return [...assignments.values()].some(isGitEnvironmentName) ||
    getRuntimeEnvironmentMutationNameStates(text, assignments).hasGit;
}

function isGitEnvironmentName(value) {
  const normalized = String(value || "").trim().replace(/^Env:\\?/iu, "").toUpperCase();
  return /^GIT_[A-Z0-9_]+$/u.test(normalized);
}

function getEnvironmentObjectAliasHistories(source) {
  const text = String(source || "");
  const history = new Map();
  const scopes = buildFunctionScopeIndex(text);
  const aliases = new Set(["process.env", "os.environ"]);
  const osAliases = new Set(["os"]);
  recordScopedPositionState(history, "process.env", true, -1, -1);
  recordScopedPositionState(history, "os.environ", true, -1, -1);
  for (const match of text.matchAll(/\bimport\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^os(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?$/u.exec(rawBinding.trim());
      if (binding) {
        const alias = binding[1] || "os";
        osAliases.add(alias);
        aliases.add(`${alias}.environ`);
        recordScopedPositionState(history, `${alias}.environ`, true, match.index || 0, scopes.scopeAt(match.index || 0));
      }
    }
  }
  const isEnvironmentObjectAt = (expression, index) => {
    const candidate = String(expression || "").trim();
    if (/^process\s*(?:\?\.env|\.env|\[\s*["']env["']\s*\])$/u.test(candidate)) {
      return true;
    }
    const osMember = /^([A-Za-z_][A-Za-z0-9_]*)\.environ$/u.exec(candidate) ||
      /^getattr\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*["']environ["']\s*\)$/u.exec(candidate) ||
      /^([A-Za-z_][A-Za-z0-9_]*)\.__dict__\s*\[\s*["']environ["']\s*\]$/u.exec(candidate);
    if (osMember && osAliases.has(osMember[1])) {
      return true;
    }
    return /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(candidate) && getScopedPositionState(history, candidate, index, scopes) === true;
  };
  for (const match of text.matchAll(/\bfrom\s+os\s+import\s+environ(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?/gu)) {
    const alias = match[1] || "environ";
    aliases.add(alias);
    recordScopedPositionState(history, alias, true, match.index || 0, scopes.scopeAt(match.index || 0));
  }
  for (const match of text.matchAll(/(?:\b(?:const|let|var)\s*)?\(?\s*\{([^}]*)\}\s*=\s*process\s*\)?/gu)) {
    for (const rawBinding of match[1].split(",")) {
      const binding = /^(?:env|["']env["'])(?:\s*:\s*([A-Za-z_$][A-Za-z0-9_$]*))?$/u.exec(rawBinding.trim());
      if (binding) {
        const alias = binding[1] || "env";
        aliases.add(alias);
        recordScopedPositionState(history, alias, true, match.index || 0, scopes.scopeAt(match.index || 0));
      }
    }
  }
  const events = [];
  const seen = new Set();
  const assignmentPatterns = [
    { pattern: /\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*([^;\r\n]+)/gu, declared: true },
    { pattern: /(?:^|[;{\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\r\n]+)/gu, declared: false },
  ];
  for (const { pattern, declared } of assignmentPatterns) {
    for (const match of text.matchAll(pattern)) {
      const event = { index: match.index || 0, alias: match[1], expression: match[2].trim(), declared };
      const key = `${event.index}:${event.alias}:${event.expression}`;
      if (!seen.has(key)) {
        seen.add(key);
        events.push(event);
      }
    }
  }
  for (const match of text.matchAll(/(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*([^;\r\n]+)/gu)) {
    const left = match[1].split(",").map((value) => value.trim());
    const right = splitTopLevelCallArguments(match[2]);
    for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
      events.push({ index: match.index || 0, alias: left[index], expression: right[index].trim() });
    }
  }
  events.sort((left, right) => left.index - right.index);
  for (const event of events) {
    aliases.add(event.alias);
    const bindingScope = event.declared
      ? scopes.scopeAt(event.index)
      : getExistingBindingScope([history], event.alias, event.index, scopes);
    recordScopedPositionState(
      history,
      event.alias,
      isEnvironmentObjectAt(event.expression, event.index),
      event.index,
      bindingScope,
    );
  }
  return { history, scopes, aliases };
}

function getPowerShellProviderPathExpression(tail) {
  let source = String(tail || "").trim();
  source = source.replace(/^-(?:Path|LiteralPath)\s+/iu, "");
  if (source.startsWith("(")) {
    const body = getBalancedCallBody(source, 0);
    return body === null ? source : `(${body})`;
  }
  const quoted = /^("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/u.exec(source);
  if (quoted) {
    return quoted[1];
  }
  const variable = /^(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)/u.exec(source);
  if (variable) {
    return variable[1];
  }
  return source.split(/\s/u)[0] || "";
}

function getRuntimeEnvironmentMutationNameStates(source, assignments = getConstantStringAssignments(source)) {
  const text = String(source || "");
  const expressions = [];
  const addMatches = (pattern, group = 1) => {
    for (const match of text.matchAll(pattern)) {
      if (match[group]) {
        expressions.push(match[group]);
      }
    }
  };

  const environmentAliases = getEnvironmentObjectAliasHistories(text);
  const environmentMutationFunctions = new Set(["operator.setitem", "operator.delitem"]);
  for (const match of text.matchAll(/\bimport\s+operator(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?/gu)) {
    const alias = match[1] || "operator";
    environmentMutationFunctions.add(`${alias}.setitem`);
    environmentMutationFunctions.add(`${alias}.delitem`);
  }
  for (const match of text.matchAll(/\bfrom\s+operator\s+import\s+([^;\r\n]+)/gu)) {
    for (const rawBinding of String(match[1] || "").split(",")) {
      const binding = /^\s*(setitem|delitem)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*$/u.exec(rawBinding);
      if (binding) environmentMutationFunctions.add(binding[2] || binding[1]);
    }
  }
  const pushObjectEntries = (body, bareIdentifierIsLiteral = false) => {
    for (const entry of splitTopLevelCallArguments(body)) {
      const key = /^\s*(?:\[([^\]]+)\]|([^:]+))\s*:/u.exec(entry);
      if (key) {
        const keyExpression = (key[1] || key[2]).trim();
        expressions.push(bareIdentifierIsLiteral && !key[1] && /^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(keyExpression)
          ? JSON.stringify(keyExpression)
          : keyExpression);
      }
    }
  };
  for (const alias of environmentAliases.aliases) {
    const escapedAlias = escapeRegex(alias);
    const addActiveMatches = (pattern, group = 1) => {
      for (const match of text.matchAll(pattern)) {
        if (getScopedPositionState(environmentAliases.history, alias, match.index || 0, environmentAliases.scopes) === true && match[group]) {
          expressions.push(match[group]);
        }
      }
    };
    addActiveMatches(new RegExp(`\\b${escapedAlias}\\s*\\[\\s*([^\\]]+)\\s*\\]\\s*(?:=|\\+\\+|--|\\|=)`, "giu"));
    addActiveMatches(new RegExp(`\\b(?:delete|del)\\s+${escapedAlias}\\s*\\[\\s*([^\\]]+)\\s*\\]`, "giu"));
    addActiveMatches(new RegExp(`\\b(?:Reflect\\.(?:set|deleteProperty)|Object\\.defineProperty)\\s*\\(\\s*${escapedAlias}\\s*,\\s*([^,\\)]+)`, "giu"));
    for (const mutationFunction of environmentMutationFunctions) {
      addActiveMatches(new RegExp(`\\b${escapeRegex(mutationFunction)}\\s*\\(\\s*${escapedAlias}\\s*,\\s*([^,\\)]+)`, "giu"));
    }
    addActiveMatches(new RegExp(`\\b${escapedAlias}\\.(?:setdefault|pop|__setitem__|__delitem__)\\s*\\(\\s*([^,\\)]+)`, "giu"));
    for (const match of text.matchAll(new RegExp(`\\b${escapedAlias}\\s*\\|=\\s*\\{([\\s\\S]{0,1024}?)\\}`, "giu"))) {
      if (getScopedPositionState(environmentAliases.history, alias, match.index || 0, environmentAliases.scopes) === true) {
        pushObjectEntries(match[1]);
      }
    }
    for (const match of text.matchAll(new RegExp(`\\bObject\\.assign\\s*\\(\\s*${escapedAlias}\\s*,\\s*\\{([\\s\\S]{0,1024}?)\\}\\s*\\)`, "giu"))) {
      if (getScopedPositionState(environmentAliases.history, alias, match.index || 0, environmentAliases.scopes) === true) {
        pushObjectEntries(match[1], true);
      }
    }
    for (const match of text.matchAll(new RegExp(`\\b${escapedAlias}\\.update\\s*\\(\\s*\\{([\\s\\S]{0,1024}?)\\}\\s*\\)`, "giu"))) {
      if (getScopedPositionState(environmentAliases.history, alias, match.index || 0, environmentAliases.scopes) === true) {
        pushObjectEntries(match[1]);
      }
    }
  }
  addMatches(/\bos\.(?:putenv|unsetenv)\s*\(\s*([^,\)]+)/giu);
  addMatches(/\b(?:Object\.assign\s*\(\s*process\.env|os\.environ\.update\s*\()[\s\S]{0,1024}?\[\s*([^\]]+)\s*\]\s*:/giu);
  for (const match of text.matchAll(/\[(?:System\.)?Environment\]\s*::\s*SetEnvironmentVariable\s*\(/giu)) {
    const openIndex = (match.index || 0) + match[0].lastIndexOf("(");
    const body = getBalancedCallBody(text, openIndex);
    const firstArgument = body === null ? "" : splitTopLevelCallArguments(body)[0];
    if (firstArgument) {
      expressions.push(firstArgument);
    }
  }

  const dynamicProviderMutation = /\b(?:Set-Item|si|New-Item|ni|Remove-Item|ri|Clear-Item|cli|Set-Content|sc|Clear-Content|clc|Move-Item|mi|Rename-Item|rni|Copy-Item|ci)\b([^;\r\n]*)/giu;
  for (const match of text.matchAll(dynamicProviderMutation)) {
    const pathExpression = getPowerShellProviderPathExpression(match[1]);
    if (/Env:/iu.test(pathExpression) || /^\$\{?[A-Za-z_]/u.test(pathExpression)) {
      expressions.push(pathExpression);
    }
  }

  const cmdAssignments = new Map();
  let cmdDelayedExpansion = true;
  for (const match of text.matchAll(/\/v:(on|off)\b/giu)) {
    cmdDelayedExpansion = normalizeAgentValue(match[1]) === "on";
  }
  const cmdEnvironmentAssignment = /(?:^|["']|&&|\|\||&|\|)\s*set\s+"?((?:![A-Za-z_][A-Za-z0-9_]*(?::[^=!%\r\n]*=[^!%\r\n]*)?!|%[A-Za-z_][A-Za-z0-9_]*(?::[^=!%\r\n]*=[^!%\r\n]*)?%|[A-Za-z_][A-Za-z0-9_]*))=([^"&|\r\n]*)"?/giu;
  for (const match of text.matchAll(cmdEnvironmentAssignment)) {
    const rawName = String(match[1] || "").trim();
    const expandedName = expandCmdVariables(rawName, cmdAssignments, cmdDelayedExpansion).value;
    const expandedValue = expandCmdVariables(String(match[2] || "").trim(), cmdAssignments, cmdDelayedExpansion).value;
    const disabledBangReference = !cmdDelayedExpansion && /^![^!]+!$/u.test(rawName);
    if (/^[A-Za-z_][A-Za-z0-9_]*$/u.test(expandedName)) {
      cmdAssignments.set(normalizeAgentValue(expandedName), expandedValue);
      if (/[%!]/u.test(rawName) || isGitEnvironmentName(expandedName)) {
        expressions.push(JSON.stringify(expandedName));
      }
    } else if (/[%!]/u.test(rawName) && !disabledBangReference) {
      expressions.push(rawName);
    }
  }

  let hasGit = false;
  let hasNodeOptions = false;
  let hasUnresolved = false;
  for (const expression of expressions) {
    const providerPath = /^Env:\\?([A-Za-z_][A-Za-z0-9_]*)$/iu.exec(String(expression || "").trim());
    const value = providerPath ? providerPath[1] : evaluateStaticStringExpression(expression, assignments);
    if (value === null) {
      hasUnresolved = true;
    } else if (isGitEnvironmentName(value)) {
      hasGit = true;
    } else if (normalizeAgentValue(value) === "node_options") {
      hasNodeOptions = true;
    }
  }
  return { hasGit, hasNodeOptions, hasUnresolved, count: expressions.length };
}

function hasPersistentGitTargetMutation(command) {
  const source = String(command || "");
  return /(?:^|[;&\r\n])\s*(?:export|declare|typeset|local)\s+(?:[-+][A-Za-z]+\s+)*["']?(?:GIT_DIR|GIT_WORK_TREE)(?:=|["']?\b)/iu.test(source) ||
    /(?:^|[;&\r\n])\s*unset\s+(?:-[A-Za-z]+\s+)*["']?(?:GIT_DIR|GIT_WORK_TREE)\b/iu.test(source) ||
    /\$env:(?:GIT_DIR|GIT_WORK_TREE)\s*=/iu.test(source) ||
    /\b(?:Set-Item|si|New-Item|ni|Remove-Item|ri|Clear-Item|cli|Set-Content|sc|Clear-Content|clc)\b[^;&\r\n]*(?:Env:\\?)?(?:GIT_DIR|GIT_WORK_TREE)\b/iu.test(source) ||
    /\[(?:System\.)?Environment\]\s*::\s*SetEnvironmentVariable\s*\(\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']/iu.test(source) ||
    /\bprocess\.env(?:\.(?:GIT_DIR|GIT_WORK_TREE)|\[\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']\s*\])\s*=/iu.test(source) ||
    /\bos\.(?:environ\s*\[\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']\s*\]\s*=|putenv\s*\(\s*["'](?:GIT_DIR|GIT_WORK_TREE)["'])/iu.test(source) ||
    /(?:^|[;&\r\n])\s*set\s+(?:GIT_DIR|GIT_WORK_TREE)=/iu.test(source) ||
    hasRuntimeGitEnvironmentMutation(source) ||
    hasDynamicPowerShellGitEnvironmentMutation(source);
}

function hasRuntimeGitEnvironmentMutation(source) {
  const text = String(source || "");
  const gitName = /\b(?:GIT_DIR|GIT_WORK_TREE)\b/iu;
  const environmentNameStates = getRuntimeEnvironmentMutationNameStates(text);
  if (environmentNameStates.hasGit || environmentNameStates.hasUnresolved) {
    return true;
  }
  const constructedGitName = hasConstructedGitEnvironmentName(text);
  const escapedEnvironmentAlias = /\bfunction\b[^{};]*\{[^{};]*\b([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*process\.env[^{};]*\}[\s\S]{0,1024}\b\1\s*\[\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']\s*\]\s*=/iu.test(text);
  if (escapedEnvironmentAlias) {
    return true;
  }
  const nodeMutation = /\b(?:delete\s+)?process\.env\s*\[[^\]]+\]\s*(?:=|\+\+|--)/iu.test(text) ||
    /\b(?:Object\.(?:assign|defineProperty)|Reflect\.(?:set|deleteProperty))\s*\(\s*process\.env\b/iu.test(text) ||
    /\bprocess\.env\s*=\s*\{/iu.test(text);
  const pythonMutation = /\bos\.environ\s*\[[^\]]+\]\s*=/iu.test(text) ||
    /\bos\.environ\.(?:update|setdefault|pop|__setitem__|__delitem__)\s*\(/iu.test(text) ||
    /\bos\.(?:putenv|unsetenv)\s*\(/iu.test(text);
  if (constructedGitName && (nodeMutation || pythonMutation)) {
    return true;
  }
  if (/\b(?:delete\s+process\.env(?:\.(?:GIT_DIR|GIT_WORK_TREE)|\[\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']\s*\])|process\.env\s*=\s*\{[\s\S]{0,1024}\b(?:GIT_DIR|GIT_WORK_TREE)\b)/iu.test(text)) {
    return true;
  }
  if (/\b(?:Object\.(?:assign|defineProperty)|Reflect\.(?:set|deleteProperty))\s*\(\s*process\.env\b[\s\S]{0,1024}\b(?:GIT_DIR|GIT_WORK_TREE)\b/iu.test(text)) {
    return true;
  }
  if (/\bos\.environ\.(?:update|setdefault|pop|__setitem__|__delitem__)\s*\([^)]*\b(?:GIT_DIR|GIT_WORK_TREE)\b/iu.test(text) ||
      /\b(?:del\s+os\.environ\s*\[\s*["'](?:GIT_DIR|GIT_WORK_TREE)["']\s*\]|os\.environ\s*\|=\s*\{[\s\S]{0,1024}\b(?:GIT_DIR|GIT_WORK_TREE)\b|os\.(?:unsetenv|putenv)\s*\(\s*["'](?:GIT_DIR|GIT_WORK_TREE)["'])/iu.test(text)) {
    return true;
  }
  return gitName.test(text) &&
    (/\b(?:Object\.(?:assign|defineProperty)|Reflect\.(?:set|deleteProperty))\s*\(\s*process\.env\b/iu.test(text) ||
     /\bos\.environ\.(?:update|setdefault|pop|__setitem__|__delitem__)\s*\(/iu.test(text));
}

function hasDynamicPowerShellGitEnvironmentMutation(source) {
  const text = String(source || "");
  const environmentNameStates = getRuntimeEnvironmentMutationNameStates(text);
  if (environmentNameStates.hasGit || environmentNameStates.hasUnresolved) {
    return true;
  }
  if (!/\b(?:GIT_DIR|GIT_WORK_TREE)\b/iu.test(text) && !hasConstructedGitEnvironmentName(text)) {
    return false;
  }
  const dynamicProviderMutation = /\b(?:Set-Item|si|New-Item|ni|Remove-Item|ri|Clear-Item|cli|Set-Content|sc|Clear-Content|clc|Move-Item|mi|Rename-Item|rni|Copy-Item|ci)\b[^;\r\n]*(?:["']Env:|Env:\\?)[^;\r\n]*(?:\$|\+|-f\b|\[)/iu;
  const dynamicDotNetMutation = /\[(?:System\.)?Environment\]\s*::\s*SetEnvironmentVariable\s*\(\s*(?!["'](?:GIT_DIR|GIT_WORK_TREE)["'])[^,]+,/iu;
  return dynamicProviderMutation.test(text) || dynamicDotNetMutation.test(text);
}

function hasUnresolvedChildProcessGitTarget(command) {
  const source = String(command || "");
  const hasGatedGit = /\bgit(?:\.exe)?\b[\s\S]*\b(?:commit|merge|push|update-ref|branch|tag)\b/iu.test(source) ||
    hasDynamicInterpreterGitSubcommand(source);
  if (!hasGatedGit) {
    return false;
  }
  return hasNodeChildProcessTargetMetadata(source) ||
    hasPythonChildProcessTargetMetadata(source) ||
    /\b(?:Start-Process|saps|start)\b[^;\r\n]*-Envir(?:onment|onmentVariables)?\b/iu.test(source);
}

function hasNodeChildProcessTargetMetadata(source) {
  for (const call of getNodeChildProcessCalls(source)) {
    const openIndex = call.openIndex;
    const callBody = getBalancedCallBody(source, openIndex);
    if (callBody === null) {
      return true;
    }
    const args = splitTopLevelCallArguments(callBody);
    for (const argument of args.slice(1)) {
      const value = stripLeadingCallComments(argument);
      if (!value || value === "undefined" || value === "null" || value.startsWith("[") || /^(?:function\b|\(?[A-Za-z_$][A-Za-z0-9_$,\s]*\)?\s*=>)/u.test(value)) {
        continue;
      }
      if (value.startsWith("{")) {
        const structuralValue = stripJavaScriptRegexLiterals(value);
        if (/\.\.\./u.test(structuralValue) || /\[\s*(?!["'](?:cwd|env)["']\s*\])/iu.test(structuralValue) ||
            /(?:^|[,{]\s*)(?:cwd|env|["'](?:cwd|env)["']|\[\s*["'](?:cwd|env)["']\s*\])\s*(?::|,|\})/iu.test(structuralValue)) {
          return true;
        }
        continue;
      }
      if (/^[A-Za-z_$][A-Za-z0-9_$]*$/u.test(value)) {
        return true;
      }
      return true;
    }
  }
  return false;
}

function hasPythonChildProcessTargetMetadata(source) {
  for (const call of getPythonProcessCalls(source)) {
    const openIndex = call.openIndex;
    const callBody = getBalancedCallBody(source, openIndex);
    if (callBody === null) {
      return true;
    }
    const args = splitTopLevelCallArguments(callBody);
    if (normalizeAgentValue(call.method) === "popen") {
      for (const index of [9, 10]) {
        const positionalTarget = String(args[index] || "").trim();
        if (positionalTarget && !/^(?:None|null)$/iu.test(positionalTarget)) {
          return true;
        }
      }
    }
    for (const argument of args.slice(1)) {
      const value = stripLeadingCallComments(argument);
      if (/^(?:cwd|env)\s*=/iu.test(value) || value.startsWith("**")) {
        return true;
      }
    }
  }
  return false;
}

function getBalancedCallBody(source, openIndex) {
  const value = String(source || "");
  if (value[openIndex] !== "(") {
    return null;
  }
  let quote = "";
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  let regexLiteral = false;
  let regexCharacterClass = false;
  let regexEscaped = false;
  let depth = 1;
  for (let index = openIndex + 1; index < value.length; index += 1) {
    const char = value[index];
    const next = value[index + 1] || "";
    if (lineComment) {
      if (char === "\n" || char === "\r") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (char === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (regexLiteral) {
      if (regexEscaped) {
        regexEscaped = false;
      } else if (char === "\\") {
        regexEscaped = true;
      } else if (char === "[" && !regexCharacterClass) {
        regexCharacterClass = true;
      } else if (char === "]" && regexCharacterClass) {
        regexCharacterClass = false;
      } else if (char === "/" && !regexCharacterClass) {
        regexLiteral = false;
      } else if (char === "\n" || char === "\r") {
        return null;
      }
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote) {
      if (char === "\\") {
        escaped = true;
      } else if (char === quote) {
        quote = "";
      }
      continue;
    }
    if (["'", '"', "`"].includes(char)) {
      quote = char;
      continue;
    }
    if (char === "/" && next !== "/" && next !== "*" && isJavaScriptRegexLiteralStart(value, index, openIndex + 1)) {
      regexLiteral = true;
      regexCharacterClass = false;
      regexEscaped = false;
      continue;
    }
    if (char === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if ((char === "/" && next === "/") || char === "#") {
      lineComment = true;
      if (char === "/") index += 1;
      continue;
    }
    if (char === "(") {
      depth += 1;
    } else if (char === ")") {
      depth -= 1;
      if (depth === 0) {
        return value.slice(openIndex + 1, index);
      }
    }
  }
  return null;
}

function stripLeadingCallComments(value) {
  let result = String(value || "").trim();
  let previous = "";
  while (result !== previous) {
    previous = result;
    result = result
      .replace(/^\/\*[\s\S]*?\*\/\s*/u, "")
      .replace(/^\/\/[^\r\n]*(?:\r?\n|$)\s*/u, "")
      .replace(/^#[^\r\n]*(?:\r?\n|$)\s*/u, "");
  }
  return result;
}

function splitTopLevelCallArguments(callBody) {
  const source = String(callBody || "");
  const result = [];
  let start = 0;
  let quote = "";
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  let regexLiteral = false;
  let regexCharacterClass = false;
  let regexEscaped = false;
  let roundDepth = 0;
  let squareDepth = 0;
  let braceDepth = 0;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1] || "";
    if (lineComment) {
      if (char === "\n" || char === "\r") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (char === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (regexLiteral) {
      if (regexEscaped) {
        regexEscaped = false;
      } else if (char === "\\") {
        regexEscaped = true;
      } else if (char === "[" && !regexCharacterClass) {
        regexCharacterClass = true;
      } else if (char === "]" && regexCharacterClass) {
        regexCharacterClass = false;
      } else if (char === "/" && !regexCharacterClass) {
        regexLiteral = false;
      }
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote) {
      if (char === "\\") {
        escaped = true;
      } else if (char === quote) {
        quote = "";
      }
      continue;
    }
    if (["'", '"', "`"].includes(char)) {
      quote = char;
      continue;
    }
    if (char === "/" && next !== "/" && next !== "*" && isJavaScriptRegexLiteralStart(source, index, 0)) {
      regexLiteral = true;
      regexCharacterClass = false;
      regexEscaped = false;
      continue;
    }
    if (char === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if ((char === "/" && next === "/") || char === "#") {
      lineComment = true;
      if (char === "/") index += 1;
      continue;
    }
    if (char === "(") roundDepth += 1;
    else if (char === ")") roundDepth = Math.max(0, roundDepth - 1);
    else if (char === "[") squareDepth += 1;
    else if (char === "]") squareDepth = Math.max(0, squareDepth - 1);
    else if (char === "{") braceDepth += 1;
    else if (char === "}") braceDepth = Math.max(0, braceDepth - 1);
    else if (char === "," && roundDepth === 0 && squareDepth === 0 && braceDepth === 0) {
      result.push(source.slice(start, index).trim());
      start = index + 1;
    }
  }
  result.push(source.slice(start).trim());
  return result;
}

function isJavaScriptRegexLiteralStart(source, index, lowerBound = 0) {
  const value = String(source || "");
  let cursor = index - 1;
  while (cursor >= lowerBound && /\s/u.test(value[cursor])) {
    cursor -= 1;
  }
  if (cursor < lowerBound) {
    return true;
  }
  const previous = value[cursor];
  if ("([{=,:;!?&|+-*%^~<>".includes(previous)) {
    return true;
  }
  const prefix = value.slice(lowerBound, cursor + 1);
  return /(?:^|[^A-Za-z0-9_$])(?:return|throw|case|delete|void|typeof|instanceof|in|of|yield|await)\s*$/u.test(prefix);
}

function stripJavaScriptRegexLiterals(source) {
  const value = String(source || "");
  const output = [...value];
  let quote = "";
  let escaped = false;
  let regexLiteral = false;
  let regexCharacterClass = false;
  let regexEscaped = false;
  for (let index = 0; index < value.length; index += 1) {
    const char = value[index];
    const next = value[index + 1] || "";
    if (regexLiteral) {
      output[index] = " ";
      if (regexEscaped) {
        regexEscaped = false;
      } else if (char === "\\") {
        regexEscaped = true;
      } else if (char === "[" && !regexCharacterClass) {
        regexCharacterClass = true;
      } else if (char === "]" && regexCharacterClass) {
        regexCharacterClass = false;
      } else if (char === "/" && !regexCharacterClass) {
        regexLiteral = false;
        while (/[A-Za-z]/u.test(value[index + 1] || "")) {
          index += 1;
          output[index] = " ";
        }
      }
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote) {
      if (char === "\\") escaped = true;
      else if (char === quote) quote = "";
      continue;
    }
    if (["'", '"', "`"].includes(char)) {
      quote = char;
      continue;
    }
    if (char === "/" && next !== "/" && next !== "*" && isJavaScriptRegexLiteralStart(value, index, 0)) {
      regexLiteral = true;
      regexCharacterClass = false;
      regexEscaped = false;
      output[index] = " ";
    }
  }
  return output.join("");
}

function hasConditionalCwdChangeBoundary(commandSegment) {
  return commandSegment?.separatorBefore === "&&" ||
         commandSegment?.separatorBefore === "||" ||
         commandSegment?.separatorAfter === "||" ||
         commandSegment?.separatorAfter === "&";
}

function getShellCwdChange(segment, baseCwd) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const stages = splitCommandPipelineStages(normalizedSegment);
  if (stages.length !== 1) {
    return { target: "", controlFlowPrefixed: false };
  }

  const rawTokens = stripInlineEnvironmentPrefixes(tokenizeCommandLine(stages[0]));
  const controlFlowPrefixed = hasShellControlFlowPrefix(rawTokens);
  const tokens = stripShellCommandBuiltinPrefixes(stripShellControlFlowPrefixes(rawTokens));
  if (tokens.length === 0) {
    return { target: "", controlFlowPrefixed };
  }

  const executable = normalizeAgentValue(getExecutableBasename(tokens[0]));
  if (!["cd", "chdir", "pushd", "set-location", "sl", "push-location"].includes(executable)) {
    if (["popd", "pop-location"].includes(executable)) {
      return { target: "\0unresolved-cwd-change", controlFlowPrefixed };
    }
    return { target: "", controlFlowPrefixed };
  }

  const target = getShellCwdChangeArgument(tokens);
  if (!target || target.includes("\0")) {
    return { target: "\0unresolved-cwd-change", controlFlowPrefixed };
  }

  return {
    target: resolveGitCwdOption(baseCwd || process.cwd(), "", target) || "\0unresolved-cwd-change",
    controlFlowPrefixed,
  };
}

function getShellCwdChangeArgument(tokens) {
  let optionsTerminated = false;
  for (let index = 1; index < tokens.length; index += 1) {
    const token = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(token);
    if (!optionsTerminated && normalizedToken === "--") {
      optionsTerminated = true;
      continue;
    }

    if (token === "-") {
      return "\0unresolved-cwd-change";
    }

    if (!optionsTerminated && normalizedToken === "/d") {
      continue;
    }

    if (!optionsTerminated && (normalizedToken === "-path" ||
        normalizedToken === "-literalpath" ||
        normalizedToken === "-pspath")) {
      return index + 1 < tokens.length ? stripOuterQuotes(tokens[index + 1]) : "";
    }

    if (!optionsTerminated && (normalizedToken.startsWith("-path:") ||
        normalizedToken.startsWith("-literalpath:") ||
        normalizedToken.startsWith("-pspath:"))) {
      return token.slice(token.indexOf(":") + 1);
    }

    if (!optionsTerminated && token.startsWith("-")) {
      continue;
    }

    return token;
  }

  return os.homedir();
}

function hasUnparsedBaseScopedReviewGatedCommand(command, parsedSeparatedFunctionWrapper = false, parsedXargsWrapper = false) {
  return hasPowerShellGitAliasLifecycleCommand(command, true, { includeFunctionCommands: false }) ||
         (!parsedXargsWrapper && hasXargsGitLifecycleCommand(command, true)) ||
         (!parsedSeparatedFunctionWrapper && hasShellFunctionLifecycleCommand(command, true)) ||
         hasPowerShellFunctionLifecycleCommand(command, true) ||
         hasControlFlowReviewGatedCommand(command) ||
         (!parsedSeparatedFunctionWrapper && hasSeparatedShellFunctionReviewLifecycleCommand(command)) ||
         hasSeparatedPowerShellFunctionReviewLifecycleCommand(command);
}

function hasControlFlowReviewGatedCommand(command) {
  const source = String(command || "");
  for (const segment of splitCommandSegments(source)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const normalizedStage = unwrapShellGroupingWrapper(unwrapPowerShellCommandWrapper(stage));
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(normalizedStage));
      if (!tokens.some((token) => isShellControlFlowToken(token))) {
        continue;
      }

      if (hasControlFlowLifecycleTokens(tokens)) {
        return true;
      }
    }
  }

  return false;
}

function getPowerShellNestedCommand(tokens) {
  const plainCommand = getOptionRemainderValue(tokens, ["-command", "-c", "-commandwithargs", "-cwa"]);
  if (plainCommand) {
    return plainCommand;
  }

  const encodedOptionPrefixes = expandPowerShellOptionPrefixes(["-encodedcommand"]);
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(rawToken);
    let encodedValue = "";
    if (encodedOptionPrefixes.includes(normalizedToken) && index + 1 < tokens.length) {
      encodedValue = stripOuterQuotes(tokens[index + 1]);
    } else {
      for (const optionName of encodedOptionPrefixes) {
        if (normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":")) {
          encodedValue = rawToken.slice(optionName.length + 1);
          break;
        }
      }
    }

    if (!encodedValue || !/^[A-Za-z0-9+/]+={0,2}$/u.test(encodedValue)) {
      continue;
    }
    try {
      return Buffer.from(encodedValue, "base64").toString("utf16le").replace(/^\uFEFF/u, "");
    } catch {
      return "";
    }
  }

  return "";
}

function getPowerShellInitialWorkingDirectory(tokens, executable) {
  if (executable !== "pwsh" && executable !== "pwsh.exe") {
    return "";
  }
  const optionNames = [
    ...expandPowerShellOptionPrefixes(["-workingdirectory"]).filter((optionName) => optionName.length >= 3),
    "-wd",
  ];
  const nestedOptionNames = expandPowerShellOptionPrefixes([
    "-command",
    "-c",
    "-commandwithargs",
    "-cwa",
    "-encodedcommand",
  ]);
  for (let index = 1; index < tokens.length; index += 1) {
    const rawToken = stripOuterQuotes(tokens[index]);
    const normalizedToken = normalizeAgentValue(rawToken);
    if (nestedOptionNames.includes(normalizedToken) || nestedOptionNames.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      break;
    }
    if (optionNames.includes(normalizedToken)) {
      return index + 1 < tokens.length
        ? stripOuterQuotes(tokens[index + 1])
        : "\0unresolved-powershell-working-directory";
    }
  }

  return "";
}

function getPowerShellWrapperPrefixTokens(tokens) {
  const nestedOptionPrefixes = expandPowerShellOptionPrefixes([
    "-command",
    "-c",
    "-commandwithargs",
    "-cwa",
    "-encodedcommand",
  ]);
  for (let index = 1; index < tokens.length; index += 1) {
    const normalizedToken = normalizeAgentValue(stripOuterQuotes(tokens[index]));
    if (nestedOptionPrefixes.includes(normalizedToken)) {
      return tokens.slice(0, index);
    }
    if (nestedOptionPrefixes.some((optionName) =>
      normalizedToken.startsWith(optionName + "=") || normalizedToken.startsWith(optionName + ":"))) {
      return tokens.slice(0, index);
    }
  }
  return tokens;
}

function getBraceBlockBodies(command) {
  const source = String(command || "");
  const bodies = [];
  const stack = [];
  let quote = "";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (isShellQuoteTerminator(source, index, quote)) {
        quote = "";
      }
      continue;
    }
    if (char === "'" || char === '"') {
      quote = getShellQuoteMode(source, index, char);
      continue;
    }
    if (char === "{") {
      stack.push(index + 1);
      continue;
    }
    if (char === "}" && stack.length > 0) {
      const start = stack.pop();
      if (stack.length === 0 && start < index) {
        bodies.push(source.slice(start, index).trim());
      }
    }
  }
  return bodies.filter(Boolean);
}

function hasControlFlowLifecycleTokens(tokens) {
  for (let index = 0; index < tokens.length; index += 1) {
    if (!isAfterControlFlowExecutionBoundary(tokens, index)) {
      continue;
    }

    const effectiveTokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokens.slice(index)));
    if (effectiveTokens.length === 0) {
      continue;
    }

    const executable = stripOuterQuotes(effectiveTokens[0]);
    if (isGitExecutableToken(executable)) {
      const gitSubcommandIndex = findGitSubcommandIndex(effectiveTokens);
      if (gitSubcommandIndex >= 0) {
        const gitSubcommand = getGitSubcommandName(effectiveTokens, gitSubcommandIndex);
        if (gitSubcommand === "commit" || gitSubcommand === "merge") {
          return true;
        }
      }
    }

    if (isGhExecutableToken(executable)) {
      if (isGhPrMergeTokenCommand(effectiveTokens) ||
          isGhApiMergeCommand(effectiveTokens) ||
          isGhApiRefWriteCommand(effectiveTokens)) {
        return true;
      }
    }
  }

  return false;
}

function isAfterControlFlowExecutionBoundary(tokens, index) {
  const previousToken = getPreviousMeaningfulControlFlowToken(tokens, index);
  if (!previousToken) {
    return false;
  }

  return previousToken === "{" || isShellControlFlowToken(previousToken);
}

function getPreviousMeaningfulControlFlowToken(tokens, index) {
  for (let currentIndex = index - 1; currentIndex >= 0; currentIndex -= 1) {
    const token = normalizeAgentValue(stripOuterQuotes(tokens[currentIndex] || ""));
    if (!token || token === "(" || token === ")" || token === ";") {
      continue;
    }

    return token;
  }

  return "";
}

function isShellControlFlowToken(token) {
  const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
  return [
    "if",
    "then",
    "else",
    "elif",
    "while",
    "until",
    "for",
    "do",
    "case",
    "try",
    "catch",
    "finally",
    "switch",
    "foreach",
  ].includes(normalized);
}

function hasShellControlFlowPrefix(tokens) {
  for (const token of tokens) {
    const normalized = normalizeAgentValue(stripOuterQuotes(token || ""));
    if (!normalized) {
      continue;
    }

    return normalized === "{" || isShellControlFlowToken(normalized);
  }

  return false;
}

function getShellControlFlowBoundary(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const stages = splitCommandPipelineStages(normalizedSegment);
  if (stages.length !== 1) {
    return "";
  }

  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(stages[0])));
  for (const token of tokens) {
    const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
    if (!normalized || normalized === "{" || normalized === "}") {
      continue;
    }

    if (["else", "elif", "catch", "finally"].includes(normalized)) {
      return "branch";
    }

    if (["fi", "done", "esac"].includes(normalized)) {
      return "end";
    }

    return "";
  }

  return "";
}

function getShellControlFlowDepthChange(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const stages = splitCommandPipelineStages(normalizedSegment);
  if (stages.length !== 1) {
    return 0;
  }

  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(stages[0])));
  let sawControlFlowPrefix = false;
  let depthChange = 0;
  for (const token of tokens) {
    const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
    if (!normalized || normalized === "{" || normalized === "}") {
      continue;
    }

    if (!sawControlFlowPrefix) {
      if (!isShellControlFlowToken(normalized) && !isShellControlFlowEndToken(normalized)) {
        return 0;
      }
      sawControlFlowPrefix = true;
    }

    if (["if", "while", "until", "for", "case"].includes(normalized)) {
      depthChange += 1;
    } else if (isShellControlFlowEndToken(normalized)) {
      depthChange -= 1;
    }
  }

  return depthChange;
}

function isShellControlFlowEndToken(token) {
  const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
  return ["fi", "done", "esac"].includes(normalized);
}

function getShellControlFlowExecutionState(stack) {
  if (!Array.isArray(stack) || stack.length === 0) {
    return "active";
  }

  const states = stack.map((frame) => typeof frame === "string" ? frame : frame?.state || "unknown");
  if (states.includes("inactive")) {
    return "inactive";
  }

  if (states.includes("unknown")) {
    return "unknown";
  }

  return "active";
}

function updateShellControlFlowBranchExecution(stack, segment, separatorAfter = "") {
  if (!Array.isArray(stack) || stack.length === 0) {
    return;
  }

  const branchToken = getShellControlFlowBranchToken(segment);
  const current = stack[stack.length - 1];
  const frame = typeof current === "string"
    ? createShellControlFlowFrame(current)
    : current;
  stack[stack.length - 1] = frame;

  if (branchToken === "else") {
    if (frame.matched === true) {
      frame.state = "inactive";
    } else if (frame.matched === false) {
      frame.state = "active";
      frame.matched = true;
    } else {
      frame.state = "unknown";
      frame.matched = "unknown";
    }
  } else if (branchToken === "elif") {
    if (frame.matched === true) {
      frame.state = "inactive";
    } else if (frame.matched === false) {
      frame.state = isCompoundShellConditionContinuation(separatorAfter)
        ? "unknown"
        : getShellControlFlowConditionState(segment, "elif");
      frame.matched = frame.state === "active" ? true : frame.state === "inactive" ? false : "unknown";
    } else {
      frame.state = "unknown";
      frame.matched = "unknown";
    }
  } else {
    frame.state = "unknown";
    frame.matched = "unknown";
  }
}

function updateShellControlFlowDepthExecution(stack, segment, separatorAfter = "") {
  if (!Array.isArray(stack)) {
    return;
  }

  for (const action of getShellControlFlowExecutionActions(segment, separatorAfter)) {
    if (action.type === "open") {
      stack.push(createShellControlFlowFrame(action.state));
    } else if (action.type === "end" && stack.length > 0) {
      stack.pop();
    }
  }
}

function createShellControlFlowFrame(state) {
  return {
    state,
    matched: state === "active" ? true : state === "inactive" ? false : "unknown",
  };
}

function getShellControlFlowExecutionActions(segment, separatorAfter = "") {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const stages = splitCommandPipelineStages(normalizedSegment);
  if (stages.length !== 1) {
    return [];
  }

  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(stages[0])));
  if (!tokensHaveShellControlFlowPrefix(tokens)) {
    return [];
  }

  const actions = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const normalized = normalizeAgentValue(stripOuterQuotes(tokens[index] || "")).replace(/^[()]+|[()]+$/gu, "");
    if (["if", "while", "until", "for", "case"].includes(normalized)) {
      const state = normalized === "if" && !isCompoundShellConditionContinuation(separatorAfter)
        ? getShellControlFlowConditionStateFromTokens(tokens, index)
        : "unknown";
      actions.push({ type: "open", state });
    } else if (isShellControlFlowEndToken(normalized)) {
      actions.push({ type: "end" });
    }
  }

  return actions;
}

function isCompoundShellConditionContinuation(separatorAfter) {
  return separatorAfter === "&&" || separatorAfter === "||";
}

function tokensHaveShellControlFlowPrefix(tokens) {
  for (const token of tokens) {
    const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
    if (!normalized || normalized === "{" || normalized === "}") {
      continue;
    }

    return isShellControlFlowToken(normalized) || isShellControlFlowEndToken(normalized);
  }

  return false;
}

function getShellControlFlowBranchToken(segment) {
  const normalizedSegment = unwrapPowerShellCommandWrapper(segment);
  const stages = splitCommandPipelineStages(normalizedSegment);
  if (stages.length !== 1) {
    return "";
  }

  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(stages[0])));
  for (const token of tokens) {
    const normalized = normalizeAgentValue(stripOuterQuotes(token || "")).replace(/^[()]+|[()]+$/gu, "");
    if (!normalized || normalized === "{" || normalized === "}") {
      continue;
    }

    return ["else", "elif", "catch", "finally"].includes(normalized) ? normalized : "";
  }

  return "";
}

function getShellControlFlowConditionState(segment, keyword) {
  const tokens = stripShellCommandBuiltinPrefixes(stripInlineEnvironmentPrefixes(tokenizeCommandLine(unwrapPowerShellCommandWrapper(segment))));
  const targetKeyword = normalizeAgentValue(keyword || "if");
  for (let index = 0; index < tokens.length; index += 1) {
    const normalized = normalizeAgentValue(stripOuterQuotes(tokens[index] || "")).replace(/^[()]+|[()]+$/gu, "");
    if (normalized === targetKeyword) {
      return getShellControlFlowConditionStateFromTokens(tokens, index);
    }
  }

  return "unknown";
}

function getShellControlFlowConditionStateFromTokens(tokens, keywordIndex) {
  for (let index = keywordIndex + 1; index < tokens.length; index += 1) {
    const normalized = normalizeAgentValue(stripOuterQuotes(tokens[index] || "")).replace(/^[()]+|[()]+$/gu, "");
    if (!normalized || normalized === "{" || normalized === "}" || normalized === ";") {
      continue;
    }

    if (normalized === "true" || normalized === ":") {
      return "active";
    }
    if (normalized === "false") {
      return "inactive";
    }
    return "unknown";
  }

  return "unknown";
}

function stripShellControlFlowPrefixes(tokens) {
  let index = 0;
  while (index < tokens.length) {
    const token = normalizeAgentValue(stripOuterQuotes(tokens[index] || ""));
    if (token === "{" || isShellControlFlowToken(token)) {
      index += 1;
      continue;
    }

    break;
  }

  return tokens.slice(index);
}

function getSeparatedForwardingFunctionDefinitions(command) {
  const source = String(command || "");
  const functions = new Map();
  const functionPattern = /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{([^}]*)\}/giu;
  const forwardingPattern = /(?:^|[\s;|&])(?:command\s+|exec\s+|builtin\s+)?["']?\$@["']?(?:$|[\s;|&])/u;

  for (const match of source.matchAll(functionPattern)) {
    const functionName = normalizeAgentValue(match[1] || "");
    const body = match[2] || "";
    if (!functionName || !forwardingPattern.test(body) || !/\b(?:git|gh)\b/u.test(body)) {
      continue;
    }

    functions.set(functionName, body);
  }

  return functions;
}

function getForwardingFunctionInvocationCommand(tokens, functions) {
  if (!functions || functions.size === 0 || tokens.length === 0) {
    return "";
  }

  const commandName = normalizeAgentValue(getExecutableBasename(tokens[0]));
  const body = functions.get(commandName);
  if (!body) {
    return "";
  }

  const callArguments = tokens.slice(1).join(" ");
  const nestedCommand = body.replace(/["']?\$@["']?/gu, callArguments).trim();
  return nestedCommand && isReviewGatedCommand(nestedCommand) ? nestedCommand : "";
}

function getShellCommandSubstitutionCommands(stage) {
  const source = String(stage || "");
  const commands = [];
  let inSingleQuote = false;
  for (let index = 0; index < source.length - 1; index += 1) {
    if (inSingleQuote) {
      if (source[index] === "'") {
        inSingleQuote = false;
      }
      continue;
    }

    if (source[index] === "'") {
      inSingleQuote = true;
      continue;
    }

    if (source[index] === "`" && isUnescapedShellMetacharacter(source, index)) {
      let depthIndex = index + 1;
      let command = "";
      while (depthIndex < source.length) {
        if (source[depthIndex] === "`" && isUnescapedShellMetacharacter(source, depthIndex)) {
          break;
        }

        command += source[depthIndex];
        depthIndex += 1;
      }

      if (depthIndex < source.length && command.trim()) {
        commands.push(command.trim());
        index = depthIndex;
      }
      continue;
    }

    if (source[index] !== "$" || source[index + 1] !== "(") {
      continue;
    }

    const parsed = readBalancedShellCommandSubstitution(source, index + 2);
    if (parsed.command.trim() !== "") {
      commands.push(parsed.command.trim());
    }
    index = parsed.endIndex;
  }

  return commands;
}

function isUnescapedShellMetacharacter(source, index) {
  let backslashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    backslashCount += 1;
  }
  return backslashCount % 2 === 0;
}

function readPowerShellExecutableExpression(source, startIndex) {
  let start = startIndex;
  while (/\s/u.test(source[start] || "")) {
    start += 1;
  }
  if (source[start] === "(") {
    const body = getBalancedCallBody(source, start);
    if (body === null) {
      return null;
    }
    let end = start + body.length + 2;
    const valueMember = /^\.Value\b/iu.exec(source.slice(end));
    if (valueMember) {
      end += valueMember[0].length;
    }
    return { start, end, expression: source.slice(start, end) };
  }
  const variable = /^\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)(?:\.Value)?/u.exec(source.slice(start));
  if (variable) {
    return { start, end: start + variable[0].length, expression: variable[0] };
  }
  const quoted = /^(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/u.exec(source.slice(start));
  if (quoted) {
    return { start, end: start + quoted[0].length, expression: quoted[0] };
  }
  const token = /^[^\s;|&]+/u.exec(source.slice(start));
  return token ? { start, end: start + token[0].length, expression: token[0] } : null;
}

function materializePowerShellComSpecAliases(command) {
  let source = String(command || "")
    .replace(/\[(?:System\.)?Environment\]\s*::\s*GetEnvironmentVariable\s*\(\s*['"]ComSpec['"]\s*\)/giu, "$env:ComSpec");
  const replacements = [];
  const scopes = buildFunctionScopeIndex(source);
  for (const match of source.matchAll(/\b(?:Start-Process|saps|start)\b\s+(?:-(?:FilePath|File)\s+)?/giu)) {
    const callIndex = match.index || 0;
    const executableReference = readPowerShellExecutableExpression(source, callIndex + match[0].length);
    if (!executableReference) {
      continue;
    }
    const assignments = getConstantStringAssignments(source, callIndex);
    let executable = evaluateStaticStringExpression(executableReference.expression, assignments);
    const variable = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(?:\.Value)?$/u.exec(executableReference.expression);
    if (variable) {
      const event = getLatestScopedPowerShellAssignmentEvent(source, variable[1] || variable[2], callIndex, scopes);
      if (event) {
        executable = evaluateStaticStringExpression(event.expression, new Map());
      }
    }
    if (executable === "\0winsmux-comspec") {
      replacements.push({ ...executableReference, value: "$env:ComSpec" });
    } else if (typeof executable === "string" && /^[A-Za-z0-9._:\\/ -]+$/u.test(executable) && !/\s/u.test(executable)) {
      replacements.push({ ...executableReference, value: executable });
    }
  }
  for (const replacement of replacements.sort((left, right) => right.start - left.start)) {
    source = `${source.slice(0, replacement.start)}${replacement.value}${source.slice(replacement.end)}`;
  }
  return source;
}

function materializeConstantExecutableSubstitutions(command) {
  let source = String(command || "")
    .replace(/\$\(\s*(?:echo|printf(?:\s+['"]?%s['"]?)?)\s+['"]?(git|codex)['"]?\s*\)/giu, "$1")
    .replace(/`\s*(?:echo|printf(?:\s+['"]?%s['"]?)?)\s+['"]?(git|codex)['"]?\s*`/giu, "$1");

  const assignments = new Map();
  const assignmentPattern = /(?:^|[;&\r\n])\s*(?:(?:export|readonly|declare|typeset|local)\s+(?:[-+][A-Za-z]+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(['"]?)(?:[^\s;&"'=]*[\\/])?(git|gh|codex)(?:\.exe)?\2(?=\s|[;&\r\n]|$)/giu;
  for (const match of source.matchAll(assignmentPattern)) {
    assignments.set(match[1], normalizeAgentValue(match[3]));
  }

  for (const [name, executable] of assignments) {
    const variableReference = `\\$(?:\\{${name}\\}|${name}\\b)`;
    const executablePosition = new RegExp(
      `(^|[;&|(){}\\r\\n]\\s*|["']|\\b(?:then|elif|else|do)\\s+)(["']?)${variableReference}\\2(?=\\s)`,
      "giu");
    source = source.replace(executablePosition, (_match, prefix) => `${prefix}${executable}`);
  }
  return source;
}

function isDynamicShellExecutableToken(token) {
  const value = stripOuterQuotes(String(token || "").trim());
  return /^\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)$/u.test(value) ||
    /^\$\{[^}]+\}$/u.test(value) ||
    /^\$\([^)]*\)$/u.test(value) ||
    /^`[^`]*`$/u.test(value);
}

function hasDynamicShellReviewGatedArguments(command) {
  for (const segment of splitCommandSegments(command)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const execution = unwrapReviewGateExecutionTokens(unwrapEnvCommandTokens(tokenizeCommandLine(stage)));
      const tokens = execution.tokens;
      if (tokens.length === 0 || !isDynamicShellExecutableToken(tokens[0])) {
        continue;
      }
      const syntheticGit = ["git", ...tokens.slice(1)];
      const subcommandIndex = findGitSubcommandIndex(syntheticGit);
      if (subcommandIndex >= 0 &&
          isReviewGatedGitSubcommand(getGitSubcommandName(syntheticGit, subcommandIndex), syntheticGit, subcommandIndex)) {
        return true;
      }
      const syntheticGh = ["gh", ...tokens.slice(1)];
      if (hasUnresolvedShellGhLifecycleTokens(syntheticGh) ||
          isGhPrMergeTokenCommand(syntheticGh) || isGhApiMergeCommand(syntheticGh) || isGhApiRefWriteCommand(syntheticGh)) {
        return true;
      }
    }
  }
  return false;
}

function hasUnresolvedShellGhLifecycleTokens(tokens) {
  const args = tokens.slice(1).map((token) => stripOuterQuotes(String(token || "")));
  const dynamic = args.map((arg) => /(?:\$\{|\$[A-Za-z_]|`|\$\()/u.test(arg));
  if (!dynamic.some(Boolean)) {
    return false;
  }
  const normalized = args.map((arg) => normalizeAgentValue(arg));
  return dynamic[0] || normalized.includes("pr") || normalized.includes("api");
}

function getExecutedShellArrayBodies(command) {
  const source = String(command || "");
  const bodies = [];
  const assignmentPattern = /(?:^|[;&\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\(([^()]*)\)/gu;
  for (const match of source.matchAll(assignmentPattern)) {
    const name = match[1];
    const invocationPattern = new RegExp(`["']?\\$\\{${name}\\[(?:@|\\*)\\]\\}["']?`, "gu");
    if (invocationPattern.test(source.slice((match.index || 0) + match[0].length))) {
      bodies.push(match[2] || "");
    }
  }
  return bodies;
}

function hasShellArrayReviewGatedCommand(command) {
  return getExecutedShellArrayBodies(command).some((body) => isReviewGatedCommand(body));
}

function hasShellArrayDirectCodexDispatch(command, depth) {
  return getExecutedShellArrayBodies(command).some((body) => isDirectCodexDispatch(body, depth + 1));
}

function readBalancedShellCommandSubstitution(source, startIndex) {
  let depth = 1;
  let quote = "";
  let command = "";
  for (let index = startIndex; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (isShellQuoteTerminator(source, index, quote)) {
        quote = "";
      }
      command += char;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = getShellQuoteMode(source, index, char);
      command += char;
      continue;
    }

    if (char === "(") {
      depth += 1;
      command += char;
      continue;
    }

    if (char === ")") {
      depth -= 1;
      if (depth === 0) {
        return { command, endIndex: index };
      }
      command += char;
      continue;
    }

    command += char;
  }

  return { command: "", endIndex: source.length - 1 };
}

function hasSeparatedShellFunctionReviewLifecycleCommand(command) {
  return hasSeparatedForwardingFunctionReviewLifecycleCommand(
    command,
    /(?:^|[;&])\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{([^}]*)\}/giu,
    "$@");
}

function hasSeparatedPowerShellFunctionReviewLifecycleCommand(command) {
  return hasSeparatedForwardingFunctionReviewLifecycleCommand(
    command,
    /(?:^|[;&])\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\s*\{([^}]*)\}/giu,
    "$args");
}

function hasSeparatedForwardingFunctionReviewLifecycleCommand(command, functionPattern, forwardingToken) {
  const source = String(command || "");
  const gitFunctions = new Set();
  const ghFunctions = new Set();
  const forwardingPattern = new RegExp(`(?:^|[\\s;|&])(?:command\\s+|exec\\s+|builtin\\s+)?["']?\\${forwardingToken}["']?(?:$|[\\s;|&])`, "u");

  for (const match of source.matchAll(functionPattern)) {
    const functionName = normalizeAgentValue(match[1] || "");
    const body = match[2] || "";
    if (!functionName || !forwardingPattern.test(body)) {
      continue;
    }

    if (/\bgit\b/u.test(body)) {
      gitFunctions.add(functionName);
    }
    if (/\bgh\b/u.test(body)) {
      ghFunctions.add(functionName);
    }
  }

  if (gitFunctions.size === 0 && ghFunctions.size === 0) {
    return false;
  }

  for (const segment of splitCommandSegments(source)) {
    for (const stage of splitCommandPipelineStages(segment)) {
      const tokens = unwrapEnvCommandTokens(tokenizeCommandLine(unwrapPowerShellCommandWrapper(stage)));
      if (tokens.length === 0) {
        continue;
      }

      const commandName = normalizeAgentValue(getExecutableBasename(tokens[0]));
      if (gitFunctions.has(commandName)) {
        const subcommand = normalizeAgentValue(stripOuterQuotes(tokens[1] || ""));
        if (subcommand === "commit" || subcommand === "merge") {
          return true;
        }
      }

      if (ghFunctions.has(commandName)) {
        const effectiveTokens = ["gh", ...tokens.slice(1)];
        if (isGhPrMergeTokenCommand(effectiveTokens) || isGhApiMergeCommand(effectiveTokens) || isGhApiRefWriteCommand(effectiveTokens)) {
          return true;
        }
      }
    }
  }

  return false;
}

function isGitExecutableToken(token) {
  const normalized = normalizeAgentValue(token).replace(/\\/g, "/");
  return normalized === "git" || normalized === "git.exe" || normalized.endsWith("/git") || normalized.endsWith("/git.exe");
}

function isGhExecutableToken(token) {
  const normalized = normalizeAgentValue(token).replace(/\\/g, "/");
  return normalized === "gh" || normalized === "gh.exe" || normalized.endsWith("/gh") || normalized.endsWith("/gh.exe");
}

function isGhPrMergeTokenCommand(tokens) {
  return tokens.some((token, index) =>
    normalizeAgentValue(stripOuterQuotes(token)) === "pr" &&
    tokens.slice(index + 1).some((nextToken) =>
      normalizeAgentValue(stripOuterQuotes(nextToken)) === "merge"));
}

function getGitGlobalCwdOption(tokens, gitIndex, baseCwd, gitEnvContext = {}) {
  let effectiveCwd = "";
  let effectiveGitDir = null;
  let effectiveWorkTree = null;

  for (let i = gitIndex + 1; i < tokens.length; i++) {
    const token = stripOuterQuotes(tokens[i]);
    const normalizedToken = normalizeAgentValue(token);
    if (token === "-C") {
      if (i + 1 >= tokens.length) {
        return "";
      }
      effectiveCwd = resolveGitCwdOption(baseCwd, effectiveCwd, stripOuterQuotes(tokens[i + 1]));
      i++;
      continue;
    }

    if (token.startsWith("-C") && token.length > 2) {
      effectiveCwd = resolveGitCwdOption(baseCwd, effectiveCwd, token.slice(2));
      continue;
    }

    if (normalizedToken === "--git-dir") {
      if (i + 1 >= tokens.length) {
        return "";
      }
      effectiveGitDir = stripOuterQuotes(tokens[i + 1]);
      i++;
      continue;
    }

    if (normalizedToken.startsWith("--git-dir=")) {
      effectiveGitDir = token.slice("--git-dir=".length);
      continue;
    }

    if (normalizedToken === "--work-tree") {
      if (i + 1 >= tokens.length) {
        return "";
      }
      effectiveWorkTree = stripOuterQuotes(tokens[i + 1]);
      i++;
      continue;
    }

    if (normalizedToken.startsWith("--work-tree=")) {
      effectiveWorkTree = token.slice("--work-tree=".length);
      continue;
    }

    if (isGitGlobalOptionWithSeparateValue(normalizedToken)) {
      i++;
      continue;
    }

    if (isGitGlobalOptionWithInlineValue(normalizedToken)) {
      continue;
    }

    if (!token.startsWith("-")) {
      return resolveGitGlobalTargetCwd(baseCwd, effectiveCwd, effectiveGitDir, effectiveWorkTree, gitEnvContext);
    }
  }

  return resolveGitGlobalTargetCwd(baseCwd, effectiveCwd, effectiveGitDir, effectiveWorkTree, gitEnvContext);
}

function resolveGitGlobalTargetCwd(baseCwd, effectiveCwd, gitDirOption, workTreeOption, gitEnvContext = {}) {
  const envGitDir = typeof gitEnvContext?.gitDir === "string" ? gitEnvContext.gitDir : null;
  const envWorkTree = typeof gitEnvContext?.workTree === "string" ? gitEnvContext.workTree : null;
  const envTargetCwd = typeof gitEnvContext?.targetCwd === "string" ? gitEnvContext.targetCwd : "";
  const finalGitDir = gitDirOption === null ? envGitDir : gitDirOption;
  const finalWorkTree = workTreeOption === null ? envWorkTree : workTreeOption;
  const fallbackCwd = typeof finalGitDir === "string" && finalGitDir !== ""
    ? (envTargetCwd || effectiveCwd)
    : (effectiveCwd || envTargetCwd);
  return resolveGitRepositoryTargetCwd(baseCwd, effectiveCwd, finalGitDir, finalWorkTree, fallbackCwd);
}

function resolveGitPathOption(baseCwd, effectiveCwd, optionValue) {
  if (typeof optionValue !== "string") {
    return "";
  }

  return resolveGitCwdOption(baseCwd, effectiveCwd, optionValue);
}

function getGitInlineEnvironmentContext(tokens, baseCwd) {
  const effectiveTokens = stripShellCommandBuiltinPrefixes(tokens);
  let commandBaseCwd = baseCwd || process.cwd();
  let gitDir = null;
  let workTree = null;
  let clearedGitDir = false;
  let clearedWorkTree = false;

  for (let index = 0; index < effectiveTokens.length; index += 1) {
    const token = stripOuterQuotes(effectiveTokens[index]);
    const executable = normalizeAgentValue(getExecutableBasename(token));
    if (executable === "env" || executable === "env.exe") {
      index += 1;
      while (index < effectiveTokens.length) {
        const envToken = stripOuterQuotes(effectiveTokens[index]);
        const normalizedEnvToken = normalizeAgentValue(envToken);
        if (isInlineEnvironmentAssignment(envToken)) {
          const separatorIndex = envToken.indexOf("=");
          const name = envToken.slice(0, separatorIndex).toUpperCase();
          const value = envToken.slice(separatorIndex + 1);
          if (name === "GIT_WORK_TREE") {
            workTree = value;
            clearedWorkTree = false;
          } else if (name === "GIT_DIR") {
            gitDir = value;
            clearedGitDir = false;
          }
          index += 1;
          continue;
        }

        const shortOptions = parseEnvShortOptionCluster(envToken);
        if (shortOptions) {
          if (shortOptions.ignoreEnvironment) {
            gitDir = null;
            workTree = null;
            clearedGitDir = true;
            clearedWorkTree = true;
          }

          const shortOptionValue = shortOptions.value || stripOuterQuotes(effectiveTokens[index + 1] || "");
          const consumedTokens = shortOptions.value ? 1 : 2;
          if (shortOptions.valueOption === "C") {
            if (!shortOptionValue) {
              break;
            }
            commandBaseCwd = resolveGitCwdOption(commandBaseCwd, "", shortOptionValue);
            index += consumedTokens;
            continue;
          }
          if (shortOptions.valueOption === "S") {
            if (!shortOptionValue) {
              break;
            }
            const splitTokens = tokenizeCommandLine(shortOptionValue);
            return mergeGitInlineEnvironmentContext(
              { baseCwd: commandBaseCwd, gitDir, workTree, clearedGitDir, clearedWorkTree },
              getGitInlineEnvironmentContext([...splitTokens, ...effectiveTokens.slice(index + consumedTokens)], commandBaseCwd),
            );
          }
          if (shortOptions.valueOption === "U") {
            const unsetName = normalizeAgentValue(shortOptionValue).toUpperCase();
            if (unsetName === "GIT_DIR") {
              gitDir = null;
              clearedGitDir = true;
            } else if (unsetName === "GIT_WORK_TREE") {
              workTree = null;
              clearedWorkTree = true;
            }
            index += consumedTokens;
            continue;
          }

          index += 1;
          continue;
        }

        if ((normalizedEnvToken === "-c" || normalizedEnvToken === "--chdir") && index + 1 < effectiveTokens.length) {
          commandBaseCwd = resolveGitCwdOption(commandBaseCwd, "", stripOuterQuotes(effectiveTokens[index + 1]));
          index += 2;
          continue;
        }

        if (normalizedEnvToken.startsWith("-c") && normalizedEnvToken.length > 2) {
          commandBaseCwd = resolveGitCwdOption(commandBaseCwd, "", envToken.slice(2));
          index += 1;
          continue;
        }

        if ((normalizedEnvToken === "-s" || normalizedEnvToken === "--split-string") && index + 1 < effectiveTokens.length) {
          const splitTokens = tokenizeCommandLine(stripOuterQuotes(effectiveTokens[index + 1]));
          return mergeGitInlineEnvironmentContext(
            { baseCwd: commandBaseCwd, gitDir, workTree },
            getGitInlineEnvironmentContext([...splitTokens, ...effectiveTokens.slice(index + 2)], commandBaseCwd),
          );
        }

        if (normalizedEnvToken.startsWith("-s") && normalizedEnvToken.length > 2) {
          const splitTokens = tokenizeCommandLine(stripOuterQuotes(envToken.slice(2)));
          return mergeGitInlineEnvironmentContext(
            { baseCwd: commandBaseCwd, gitDir, workTree },
            getGitInlineEnvironmentContext([...splitTokens, ...effectiveTokens.slice(index + 1)], commandBaseCwd),
          );
        }

        if (normalizedEnvToken.startsWith("--chdir=")) {
          commandBaseCwd = resolveGitCwdOption(commandBaseCwd, "", envToken.slice(envToken.indexOf("=") + 1));
          index += 1;
          continue;
        }

        if (normalizedEnvToken.startsWith("--split-string=")) {
          const splitValue = envToken.slice(envToken.indexOf("=") + 1);
          const splitTokens = tokenizeCommandLine(stripOuterQuotes(splitValue));
          return mergeGitInlineEnvironmentContext(
            { baseCwd: commandBaseCwd, gitDir, workTree },
            getGitInlineEnvironmentContext([...splitTokens, ...effectiveTokens.slice(index + 1)], commandBaseCwd),
          );
        }

        if (normalizedEnvToken === "--") {
          index += 1;
          break;
        }

        if (normalizedEnvToken === "-u" || normalizedEnvToken === "--unset") {
          const unsetName = index + 1 < effectiveTokens.length
            ? normalizeAgentValue(stripOuterQuotes(effectiveTokens[index + 1])).toUpperCase()
            : "";
          if (unsetName === "GIT_DIR") {
            gitDir = null;
            clearedGitDir = true;
          } else if (unsetName === "GIT_WORK_TREE") {
            workTree = null;
            clearedWorkTree = true;
          }
          index += 2;
          continue;
        }

        if (normalizedEnvToken.startsWith("-u") && normalizedEnvToken.length > 2) {
          const unsetName = normalizeAgentValue(envToken.slice(2)).toUpperCase();
          if (unsetName === "GIT_DIR") {
            gitDir = null;
            clearedGitDir = true;
          } else if (unsetName === "GIT_WORK_TREE") {
            workTree = null;
            clearedWorkTree = true;
          }
          index += 1;
          continue;
        }

        if (normalizedEnvToken.startsWith("--unset=")) {
          const unsetName = normalizeAgentValue(envToken.slice(envToken.indexOf("=") + 1)).toUpperCase();
          if (unsetName === "GIT_DIR") {
            gitDir = null;
            clearedGitDir = true;
          } else if (unsetName === "GIT_WORK_TREE") {
            workTree = null;
            clearedWorkTree = true;
          }
          index += 1;
          continue;
        }

        if (normalizedEnvToken === "-i" ||
            normalizedEnvToken === "--ignore-environment") {
          gitDir = null;
          workTree = null;
          clearedGitDir = true;
          clearedWorkTree = true;
          index += 1;
          continue;
        }

        if (normalizedEnvToken === "-0" ||
            normalizedEnvToken === "--null") {
          index += 1;
          continue;
        }

        break;
      }
      index -= 1;
      continue;
    }

    const assignment = stripOuterQuotes(token);
    if (!isInlineEnvironmentAssignment(assignment)) {
      break;
    }

    const separatorIndex = assignment.indexOf("=");
    const name = assignment.slice(0, separatorIndex).toUpperCase();
    const value = assignment.slice(separatorIndex + 1);
    if (name === "GIT_WORK_TREE") {
      workTree = value;
      clearedWorkTree = false;
    } else if (name === "GIT_DIR") {
      gitDir = value;
      clearedGitDir = false;
    }
  }

  return {
    baseCwd: commandBaseCwd,
    gitDir,
    workTree,
    clearedGitDir,
    clearedWorkTree,
    targetCwd: resolveGitRepositoryTargetCwd(commandBaseCwd, "", gitDir, workTree, ""),
  };
}

function mergeGitInlineEnvironmentContext(prefixContext, nestedContext) {
  const baseCwd = nestedContext?.baseCwd || prefixContext?.baseCwd || process.cwd();
  const nestedHasGitDir = nestedContext?.gitDir !== null && typeof nestedContext?.gitDir === "string";
  const nestedHasWorkTree = nestedContext?.workTree !== null && typeof nestedContext?.workTree === "string";
  const gitDir = nestedHasGitDir
    ? nestedContext.gitDir
    : nestedContext?.clearedGitDir
      ? null
      : prefixContext?.gitDir;
  const workTree = nestedHasWorkTree
    ? nestedContext.workTree
    : nestedContext?.clearedWorkTree
      ? null
      : prefixContext?.workTree;
  const clearedGitDir = nestedHasGitDir
    ? false
    : Boolean(nestedContext?.clearedGitDir || prefixContext?.clearedGitDir);
  const clearedWorkTree = nestedHasWorkTree
    ? false
    : Boolean(nestedContext?.clearedWorkTree || prefixContext?.clearedWorkTree);

  return {
    baseCwd,
    gitDir,
    workTree,
    clearedGitDir,
    clearedWorkTree,
    targetCwd: resolveGitRepositoryTargetCwd(baseCwd, "", gitDir, workTree, ""),
  };
}

function resolveGitRepositoryTargetCwd(baseCwd, effectiveCwd, gitDirOption, workTreeOption, fallbackCwd = "") {
  const resolvedGitDir = resolveGitPathOption(baseCwd, effectiveCwd, gitDirOption);
  const resolvedWorkTree = resolveGitPathOption(baseCwd, effectiveCwd, workTreeOption);
  if (resolvedGitDir) {
    const gitDirTarget = resolveGitDirTargetCwd(resolvedGitDir);
    if (gitDirTarget && !gitDirTarget.includes("\0")) {
      return gitDirTarget;
    }

    return resolveGitDirWorkTreeTargetCwd(resolvedGitDir, resolvedWorkTree) || gitDirTarget;
  }

  if (resolvedWorkTree) {
    return fallbackCwd || effectiveCwd || baseCwd || process.cwd();
  }

  return fallbackCwd;
}

function resolveGitDirTargetCwd(gitDir) {
  if (typeof gitDir !== "string" || gitDir.trim() === "" || gitDir.includes("\0")) {
    return "";
  }

  const resolvedGitDir = path.resolve(process.cwd(), stripOuterQuotes(gitDir.trim()));
  try {
    const stat = fs.statSync(resolvedGitDir);
    if ((stat.isDirectory() || stat.isFile()) && path.basename(resolvedGitDir).toLowerCase() === ".git") {
      return path.dirname(resolvedGitDir);
    }
  } catch {
    return "\0unresolved-git-dir";
  }

  return "\0unresolved-git-dir";
}

function resolveGitDirWorkTreeTargetCwd(gitDir, workTree) {
  if (typeof gitDir !== "string" ||
      typeof workTree !== "string" ||
      gitDir.trim() === "" ||
      workTree.trim() === "" ||
      gitDir.includes("\0") ||
      workTree.includes("\0")) {
    return "";
  }

  const gitDirPath = stripOuterQuotes(gitDir.trim());
  const workTreePath = stripOuterQuotes(workTree.trim());
  if (!fs.existsSync(gitDirPath) || !fs.existsSync(workTreePath)) {
    return "";
  }

  try {
    return execFileSync("git", [
      "--git-dir",
      gitDirPath,
      "--work-tree",
      workTreePath,
      "rev-parse",
      "--show-toplevel",
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

function resolveGitCwdOption(baseCwd, currentCwd, nextCwd) {
  if (typeof nextCwd !== "string" || nextCwd.includes("\0")) {
    return "";
  }

  const normalizedNextCwd = stripOuterQuotes(nextCwd);
  if (normalizedNextCwd === "") {
    return currentCwd || baseCwd || process.cwd();
  }

  if (normalizedNextCwd.trim() === "") {
    return "";
  }

  const trimmedNextCwd = normalizedNextCwd.trim();
  if (hasShellExpandedPathToken(trimmedNextCwd)) {
    return "\0unresolved-shell-expanded-cwd";
  }

  const base = currentCwd || baseCwd || process.cwd();
  return path.resolve(base, trimmedNextCwd);
}

function hasShellExpandedPathToken(value) {
  if (typeof value !== "string" || value === "") {
    return false;
  }

  return /(?:^~(?:$|[\\/])|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}|%[^%\s]+%|![^!\s]+!|`|\$\(|[?*[\]{}])/.test(value);
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
