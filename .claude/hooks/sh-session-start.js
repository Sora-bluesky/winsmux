#!/usr/bin/env node
// sh-session-start.js — Session initialization & integrity baseline
// Spec: DETAILED_DESIGN.md §5.1
// Event: SessionStart
// Target response time: < 500ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  sha256,
  readSession,
  writeSession,
  appendEvidence,
  readYaml,
  getBacklogPath,
} = require("./lib/sh-utils");
// Enterprise libs — soft-disable with try-catch (Tier 3, not yet validated)
let detectOpenShell = () => ({ available: false, reason: "module_not_loaded" });
let checkPolicyCompatibility = () => ({ compatible: null, reason: "module_not_loaded" });
let checkPolicyDrift = () => ({ has_drift: false, warnings: [] });
let detectAutoMode = () => ({ detected: false, danger_level: "none", soft_deny_count: 0, soft_allow_count: 0 });
try { detectOpenShell = require("./lib/openshell-detect").detectOpenShell; } catch {}
try { checkPolicyCompatibility = require("./lib/policy-compat").checkPolicyCompatibility; } catch {}
try { checkPolicyDrift = require("./lib/policy-drift").checkPolicyDrift; } catch {}
try { detectAutoMode = require("./lib/automode-detect").detectAutoMode; } catch {}

const HOOK_NAME = "sh-session-start";
const CLAUDE_MD = "CLAUDE.md";
const SETTINGS_FILE = path.join(".claude", "settings.json");
const RULES_DIR = path.join(".claude", "rules");
const HOOKS_DIR = path.join(".claude", "hooks");
const HASHES_FILE = path.join(".claude", "logs", "instructions-hashes.json");
const PATTERNS_FILE = path.join(
  ".claude",
  "patterns",
  "injection-patterns.json",
);
const SESSION_FILE = path.join(".shield-harness", "session.json");
const VERSION_FILE = path.join(
  ".shield-harness",
  "state",
  "last-known-version.txt",
);

// Expected minimum deny rules (§5.1.1)
const REQUIRED_DENY_PATTERNS = [
  "backlog.yaml", // Edit/Write deny for backlog
];

// Expected minimum hook count
const MIN_HOOK_COUNT = 10; // Wave 0+1+2 = 10 hooks minimum

// Token budget defaults (§5.1.2, ADR-026)
const DEFAULT_TOKEN_BUDGET = {
  session_limit: 200000,
  tool_output_limit: 50000,
  used: 0,
};

function findUpFile(startDir, relativeSegments) {
  if (!startDir) {
    return "";
  }

  let currentDir = path.resolve(startDir);
  while (true) {
    const candidate = path.join(currentDir, ...relativeSegments);
    if (fs.existsSync(candidate)) {
      return candidate;
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      return "";
    }

    currentDir = parentDir;
  }
}

function resolveManifestPath() {
  const starts = [process.cwd(), path.resolve(__dirname, "..", "..")];
  for (const startDir of starts) {
    const candidate = findUpFile(startDir, [".winsmux", "manifest.yaml"]);
    if (candidate) {
      return candidate;
    }
  }

  return "";
}

function normalizeTaskId(value) {
  return String(value || "").trim().toUpperCase();
}

function collectManifestResumeState() {
  const manifestPath = resolveManifestPath();
  if (!manifestPath) {
    return null;
  }

  const manifest = readYaml(manifestPath);
  const sessionInfo =
    manifest && typeof manifest.session === "object" ? manifest.session : {};
  const paneEntries =
    manifest && manifest.panes && typeof manifest.panes === "object"
      ? Object.entries(manifest.panes)
      : [];

  const activePanes = paneEntries
    .map(([label, pane]) => {
      if (!pane || typeof pane !== "object") {
        return null;
      }

      const taskId = String(pane.task_id || "").trim();
      const taskState = String(pane.task_state || "").trim();
      const taskTitle = String(pane.task || pane.goal || "").trim();
      if (!taskId && !taskState && !taskTitle) {
        return null;
      }

      return {
        label,
        taskId,
        taskState,
        taskTitle,
      };
    })
    .filter(Boolean);

  return {
    manifestPath,
    sessionName: String(sessionInfo.name || "").trim(),
    projectDir: String(sessionInfo.project_dir || "").trim(),
    paneCount: paneEntries.length,
    activePanes: activePanes.slice(0, 3),
    taskIds: activePanes
      .map((pane) => normalizeTaskId(pane.taskId))
      .filter(Boolean),
  };
}

function collectPlanningResumeState(preferredTaskIds = []) {
  const preferredSet = new Set(
    preferredTaskIds.map((taskId) => normalizeTaskId(taskId)).filter(Boolean),
  );
  if (preferredSet.size === 0) {
    return null;
  }

  const backlogPath = getBacklogPath();
  if (!backlogPath || !fs.existsSync(backlogPath)) {
    return null;
  }

  const backlog = readYaml(backlogPath);
  const tasks = Array.isArray(backlog.tasks) ? backlog.tasks : [];
  let selected = tasks.filter((task) => preferredSet.has(normalizeTaskId(task.id)));

  selected = selected.slice(0, 2).map((task) => ({
    id: String(task.id || "").trim(),
    title: String(task.title || "").trim(),
    targetVersion: String(task.target_version || "").trim(),
  }));

  if (selected.length === 0) {
    return null;
  }

  return {
    backlogPath,
    selected,
  };
}

function buildWinsmuxResumeContext() {
  const lines = [];
  const manifestState = collectManifestResumeState();
  if (manifestState) {
    if (manifestState.sessionName) {
      lines.push(`[winsmux-resume] Session: ${manifestState.sessionName}`);
    }
    if (manifestState.projectDir) {
      lines.push(`[winsmux-resume] Project: ${manifestState.projectDir}`);
    }
    lines.push(`[winsmux-resume] Managed panes: ${manifestState.paneCount}`);
    for (const pane of manifestState.activePanes) {
      const details = [pane.label];
      if (pane.taskId) {
        details.push(pane.taskId);
      }
      if (pane.taskState) {
        details.push(pane.taskState);
      }
      if (pane.taskTitle) {
        details.push(`- ${pane.taskTitle}`);
      }
      lines.push(`[winsmux-resume] Pane: ${details.join(" ")}`);
    }
  }

  const planningState = manifestState
    ? collectPlanningResumeState(manifestState.taskIds)
    : null;
  if (planningState) {
    for (const task of planningState.selected) {
      const details = [task.id];
      if (task.targetVersion) {
        details.push(task.targetVersion);
      }
      if (task.title) {
        details.push(`- ${task.title}`);
      }
      lines.push(`[winsmux-resume] Planning: ${details.join(" ")}`);
    }
  }

  return {
    lines,
    manifestState,
    planningState,
  };
}

const winsmuxHookProfile = (process.env.WINSMUX_HOOK_PROFILE || "standard").trim() || "standard";
const winsmuxGovernanceMode = (process.env.WINSMUX_GOVERNANCE_MODE || "standard").trim() || "standard";

try {
  const input = readHookInput();
  const toolName = input.tool_name || input.toolName || "";
  const toolInput = input.tool_input || input.toolInput || {};
  const sessionId = input.session_id || input.sessionId || "";
  void toolName;
  void toolInput;
  const contextParts = [];

  // --- Module 1: Gate Check (§5.1.1) ---

  // 1a: CLAUDE.md baseline hash
  let claudeMdHash = null;
  if (fs.existsSync(CLAUDE_MD)) {
    const content = fs.readFileSync(CLAUDE_MD, "utf8");
    claudeMdHash = sha256(content);
    contextParts.push(
      `[gate-check] CLAUDE.md baseline: ${claudeMdHash.slice(0, 12)}...`,
    );
  } else {
    contextParts.push("[gate-check] WARNING: CLAUDE.md not found");
  }

  // 1b: settings.json deny rules check
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
      const denyRules =
        (settings.permissions && settings.permissions.deny) || [];
      const missingDeny = REQUIRED_DENY_PATTERNS.filter(
        (p) => !denyRules.some((rule) => rule.includes(p)),
      );
      if (missingDeny.length > 0) {
        contextParts.push(
          `[gate-check] WARNING: Missing deny rules for: ${missingDeny.join(", ")}`,
        );
      }
    } catch {
      contextParts.push("[gate-check] WARNING: settings.json parse error");
    }
  }

  // 1c: Hook count verification
  if (fs.existsSync(HOOKS_DIR)) {
    const hookFiles = fs
      .readdirSync(HOOKS_DIR)
      .filter((f) => f.startsWith("sh-") && f.endsWith(".js"));
    if (hookFiles.length < MIN_HOOK_COUNT) {
      contextParts.push(
        `[gate-check] Hook count: ${hookFiles.length}/${MIN_HOOK_COUNT} (below minimum)`,
      );
    } else {
      contextParts.push(
        `[gate-check] Hooks verified: ${hookFiles.length} scripts`,
      );
    }
  }

  // 1d: injection-patterns.json validation
  if (fs.existsSync(PATTERNS_FILE)) {
    try {
      const patterns = JSON.parse(fs.readFileSync(PATTERNS_FILE, "utf8"));
      const categoryCount = Object.keys(patterns).length;
      contextParts.push(
        `[gate-check] Injection patterns: ${categoryCount} categories loaded`,
      );
    } catch {
      contextParts.push(
        "[gate-check] WARNING: injection-patterns.json corrupted",
      );
    }
  } else {
    contextParts.push(
      "[gate-check] WARNING: injection-patterns.json not found",
    );
  }

  // 1e: Permissions alignment check (permanent countermeasure)
  const PERM_SPEC_FILE = path.join(".claude", "permissions-spec.json");
  if (fs.existsSync(PERM_SPEC_FILE)) {
    try {
      const { validateAlignment } = require("./lib/permissions-validator");
      const result = validateAlignment(PERM_SPEC_FILE, SETTINGS_FILE);
      if (result.aligned) {
        contextParts.push(
          `[gate-check] Permissions alignment: OK (${result.counts})`,
        );
      } else {
        contextParts.push(
          "[gate-check] WARNING: Permissions divergence detected",
        );
        contextParts.push(`[gate-check] ${result.summary}`);
      }
    } catch (err) {
      contextParts.push(
        `[gate-check] WARNING: Permissions check failed: ${err.message}`,
      );
    }
  }

  // --- Module 2: Env Check (§5.1.2) ---

  // 2a: OS detection
  const platform = process.platform;
  contextParts.push(`[env-check] Platform: ${platform}`);

  // 2b: Token budget initialization
  const rawSession = readSession();
  const session =
    rawSession && typeof rawSession === "object" && !Array.isArray(rawSession)
      ? rawSession
      : {};
  if (!session.token_budget) {
    session.token_budget = { ...DEFAULT_TOKEN_BUDGET };
  }
  session.session_start = new Date().toISOString();
  session.retry_count = 0;
  session.stop_hook_active = false;
  session.deny_tracker = {};
  session.winsmux_contract = {
    hook_profile: winsmuxHookProfile,
    governance_mode: winsmuxGovernanceMode,
  };
  session.winsmux_resume = {
    manifest_path: null,
    pane_count: 0,
    task_ids: [],
    backlog_path: null,
  };
  const winsmuxResumeContext = buildWinsmuxResumeContext();
  if (winsmuxResumeContext.lines.length > 0) {
    contextParts.push(...winsmuxResumeContext.lines);
    session.winsmux_resume.manifest_path = winsmuxResumeContext.manifestState
      ? winsmuxResumeContext.manifestState.manifestPath
      : null;
    session.winsmux_resume.pane_count = winsmuxResumeContext.manifestState
      ? winsmuxResumeContext.manifestState.paneCount
      : 0;
    session.winsmux_resume.task_ids = winsmuxResumeContext.manifestState
      ? winsmuxResumeContext.manifestState.taskIds
      : [];
    session.winsmux_resume.backlog_path = winsmuxResumeContext.planningState
      ? winsmuxResumeContext.planningState.backlogPath
      : null;
  }
  contextParts.push("[env-check] Session initialized, token budget set");
  contextParts.push(
    `[winsmux] Hook profile: ${winsmuxHookProfile}, governance mode: ${winsmuxGovernanceMode}`,
  );

  // 2c: OpenShell detection (Layer 3b, ADR-037)
  const openshellResult = detectOpenShell();
  session.sandbox_openshell = openshellResult;
  writeSession(session);

  if (openshellResult.available) {
    contextParts.push(
      `[layer-3b] OpenShell v${openshellResult.version} active — kernel-level sandbox enabled`,
    );
    if (openshellResult.update_available && openshellResult.latest_version) {
      contextParts.push(
        `[layer-3b] OpenShell update available: v${openshellResult.version} → v${openshellResult.latest_version} (run: uv tool upgrade openshell)`,
      );
    }
  } else {
    const messages = {
      docker_not_found:
        "[layer-3b] Docker not found — OpenShell requires Docker",
      openshell_not_installed:
        "[layer-3b] OpenShell not installed — Layer 1-2 defense active (95% coverage)",
      container_not_running:
        "[layer-3b] OpenShell installed but container not running — run: openshell sandbox create --policy .claude/policies/openshell-default.yaml -- claude",
      detection_error:
        "[layer-3b] OpenShell detection error — Layer 1-2 defense active",
    };
    contextParts.push(
      messages[openshellResult.reason] || "[layer-3b] OpenShell unavailable",
    );
  }

  // 2d: Policy version compatibility check (TASK-021, ADR-037 Phase Beta)
  let policyCompat = null;
  if (openshellResult.available || openshellResult.version) {
    try {
      policyCompat = checkPolicyCompatibility({
        openshellVersion: openshellResult.version,
        policyFilePath: path.join(
          ".claude",
          "policies",
          "openshell-default.yaml",
        ),
      });
      session.policy_compat = policyCompat;
      writeSession(session);

      if (policyCompat.compatible === false) {
        contextParts.push(
          "[layer-3b] WARNING: Policy schema v" +
            policyCompat.policy_version +
            " incompatible with OpenShell v" +
            policyCompat.openshell_version +
            ". " +
            (policyCompat.migration_hint || "Update your policy file."),
        );
      } else if (policyCompat.compatible === null && policyCompat.reason) {
        contextParts.push(
          "[layer-3b] Policy compatibility: unknown (" +
            policyCompat.reason +
            ")",
        );
      }
      // compatible === true: normal operation, no extra message needed
    } catch {
      // fail-safe: compatibility check failure does not block session
    }
  }

  // 2e: Policy drift check (ADR-037 GA Phase)
  const POLICIES_DIR = path.join(".claude", "policies");
  if (fs.existsSync(POLICIES_DIR)) {
    try {
      const driftResult = checkPolicyDrift({
        specPath: PERM_SPEC_FILE,
        policyDir: POLICIES_DIR,
      });
      session.policy_drift = driftResult;
      writeSession(session);

      if (driftResult.has_drift) {
        contextParts.push(
          `[layer-3b] WARNING: Policy drift detected — ${driftResult.warnings.length} issue(s) found`,
        );
        for (const warning of driftResult.warnings.slice(0, 3)) {
          contextParts.push(`[layer-3b]   ${warning}`);
        }
        if (driftResult.warnings.length > 3) {
          contextParts.push(
            `[layer-3b]   ... and ${driftResult.warnings.length - 3} more`,
          );
        }
        contextParts.push(
          "[layer-3b] Run: npx shield-harness generate-policy to regenerate",
        );
      }
    } catch {
      // drift check failure is non-blocking
    }
  }

  // 2f: Auto Mode detection (Phase 7, ADR-038)
  let autoModeResult = null;
  try {
    autoModeResult = detectAutoMode();
    session.auto_mode = autoModeResult;
    writeSession(session);

    if (autoModeResult.danger_level === "critical") {
      contextParts.push(
        `[auto-mode] CRITICAL: Auto Mode soft_deny detected (${autoModeResult.soft_deny_count} rules) — ALL default protections lost`,
      );
      for (const item of autoModeResult.danger_items.slice(0, 3)) {
        contextParts.push(`[auto-mode]   Lost: ${item}`);
      }
      if (autoModeResult.danger_items.length > 3) {
        contextParts.push(
          `[auto-mode]   ... and ${autoModeResult.danger_items.length - 3} more protections lost`,
        );
      }
    } else if (autoModeResult.danger_level === "warn") {
      contextParts.push(
        `[auto-mode] WARNING: Auto Mode soft_allow detected — ${autoModeResult.soft_allow_count} rules auto-approved`,
      );
    } else if (autoModeResult.detected) {
      contextParts.push("[auto-mode] Auto Mode configured (safe)");
    } else {
      contextParts.push("[auto-mode] Auto Mode: not configured");
    }
  } catch {
    // Auto Mode detection failure is non-blocking
    contextParts.push("[auto-mode] Auto Mode detection error (non-blocking)");
  }

  // --- Module 3: Version Check (§5.1.4) ---
  // Store baseline hashes for instructions monitoring
  const hashes = {};
  if (fs.existsSync(CLAUDE_MD)) {
    hashes[CLAUDE_MD] = claudeMdHash;
  }
  if (fs.existsSync(RULES_DIR)) {
    try {
      const ruleFiles = fs
        .readdirSync(RULES_DIR)
        .filter((f) => f.endsWith(".md"));
      for (const f of ruleFiles) {
        const fp = path.join(RULES_DIR, f);
        hashes[fp] = sha256(fs.readFileSync(fp, "utf8"));
      }
    } catch {
      // Non-critical
    }
  }
  // Save baseline hashes (used by instructions hook later)
  const hashDir = path.dirname(HASHES_FILE);
  if (!fs.existsSync(hashDir)) fs.mkdirSync(hashDir, { recursive: true });
  fs.writeFileSync(HASHES_FILE, JSON.stringify(hashes, null, 2));

  // --- Evidence Recording ---
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "SessionStart",
      decision: "allow",
      claude_md_hash: claudeMdHash ? `sha256:${claudeMdHash}` : null,
      platform,
      openshell: openshellResult.available
        ? {
            version: openshellResult.version,
            container_running: openshellResult.container_running,
          }
        : { available: false, reason: openshellResult.reason },
      session_id: sessionId,
      sandbox_state: openshellResult.available ? "active" : "inactive",
      sandbox_version: openshellResult.version || null,
      sandbox_policy_enforced:
        openshellResult.available && openshellResult.container_running,
      policy_drift: session.policy_drift
        ? {
            has_drift: session.policy_drift.has_drift,
            warning_count: session.policy_drift.warnings
              ? session.policy_drift.warnings.length
              : 0,
          }
        : null,
      auto_mode: autoModeResult
        ? {
            detected: autoModeResult.detected,
            danger_level: autoModeResult.danger_level,
            soft_deny_count: autoModeResult.soft_deny_count,
            soft_allow_count: autoModeResult.soft_allow_count,
          }
        : null,
      policy_compat: policyCompat
        ? {
            compatible: policyCompat.compatible,
            policy_version: policyCompat.policy_version,
            reason: policyCompat.reason,
          }
        : null,
      winsmux_contract: {
        hook_profile: winsmuxHookProfile,
        governance_mode: winsmuxGovernanceMode,
      },
    });
  } catch {
    // Evidence failure is non-blocking
  }

  // --- Output ---
  const context = [
    "=== Shield Harness Security Harness Initialized ===",
    ...contextParts,
    "=============================================",
  ].join("\n");

  allow(context);
} catch (_err) {
  // Operational hook — fail-open
  allow("[sh-session-start] Initialization error (fail-open): " + _err.message);
}

module.exports = {
  REQUIRED_DENY_PATTERNS,
  MIN_HOOK_COUNT,
  DEFAULT_TOKEN_BUDGET,
};
