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
} = require("./lib/sh-utils");
const { detectOpenShell } = require("./lib/openshell-detect");
const { checkPolicyCompatibility } = require("./lib/policy-compat");
const { checkPolicyDrift } = require("./lib/policy-drift");
const { detectAutoMode } = require("./lib/automode-detect");

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

try {
  const input = readHookInput();
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
  const session = readSession();
  if (!session.token_budget) {
    session.token_budget = { ...DEFAULT_TOKEN_BUDGET };
  }
  session.session_start = new Date().toISOString();
  session.retry_count = 0;
  session.stop_hook_active = false;
  session.deny_tracker = {};
  contextParts.push("[env-check] Session initialized, token budget set");

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
      session_id: input.sessionId,
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
