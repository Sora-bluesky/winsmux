#!/usr/bin/env node
// sh-config-guard.js — Settings.json mutation guard
// Spec: DETAILED_DESIGN.md §5.3
// Event: ConfigChange
// Target response time: < 100ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  deny,
  sha256,
  appendEvidence,
} = require("./lib/sh-utils");
const {
  readSettingsFile: readAutoModeSection,
} = require("./lib/automode-detect");

const HOOK_NAME = "sh-config-guard";
const SETTINGS_FILE = path.join(".claude", "settings.json");
const CONFIG_HASH_FILE = path.join(".claude", "logs", "config-hash.json");
const POLICIES_DIR = path.join(".claude", "policies");
const SETTINGS_LOCAL = path.join(".claude", "settings.local.json");

// ---------------------------------------------------------------------------
// Config Analysis
// ---------------------------------------------------------------------------

/**
 * Read and parse settings.json.
 * @returns {Object|null}
 */
function readSettings() {
  try {
    if (!fs.existsSync(SETTINGS_FILE)) return null;
    return JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Load previously stored config snapshot.
 * @returns {{ hash: string, deny_rules: string[], hook_count: number, sandbox: boolean }|null}
 */
function loadStoredConfig() {
  try {
    if (!fs.existsSync(CONFIG_HASH_FILE)) return null;
    const data = JSON.parse(fs.readFileSync(CONFIG_HASH_FILE, "utf8"));
    // Validate shield-harness format (deny_rules array required)
    // Reject legacy-format snapshots (hash + snapshot_keys only)
    if (!Array.isArray(data.deny_rules)) return null;
    return data;
  } catch {
    return null;
  }
}

/**
 * Save current config snapshot.
 * @param {Object} snapshot
 */
function saveConfigSnapshot(snapshot) {
  const dir = path.dirname(CONFIG_HASH_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(CONFIG_HASH_FILE, JSON.stringify(snapshot, null, 2));
}

/**
 * Count items in a YAML list section.
 * Matches a section header like "deny_read:" followed by indented list items.
 * @param {string} content - YAML file content
 * @param {string} sectionName - Name of the YAML section to count
 * @returns {number} Number of list items in the section
 */
function countYamlListItems(content, sectionName) {
  const regex = new RegExp(sectionName + ":\\n((?:\\s+-\\s+.+\\n)*)", "m");
  const match = content.match(regex);
  if (!match) return 0;
  return match[1].split("\n").filter((l) => l.trim().startsWith("- ")).length;
}

/**
 * Count host: entries in network_policies section.
 * @param {string} content - YAML file content
 * @returns {number} Number of network endpoint entries
 */
function countNetworkEndpoints(content) {
  const matches = content.match(/^\s+[-\s]*host:\s/gm);
  return matches ? matches.length : 0;
}

/**
 * Scan .claude/policies/ for YAML files and compute SHA-256 hash of each.
 * @returns {Object.<string, string>} Map of file path to SHA-256 hash
 */
function extractPolicyHashes() {
  const hashes = {};
  if (!fs.existsSync(POLICIES_DIR)) return hashes;
  try {
    const files = fs
      .readdirSync(POLICIES_DIR)
      .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"));
    for (const file of files) {
      const filePath = path.join(POLICIES_DIR, file);
      try {
        const content = fs.readFileSync(filePath, "utf8");
        hashes[filePath] = sha256(content);
      } catch {
        /* skip unreadable */
      }
    }
  } catch {
    /* dir read error */
  }
  return hashes;
}

/**
 * Extract security-critical counts from each YAML policy file.
 * @returns {Object.<string, { deny_read_count: number, deny_write_count: number, read_write_count: number, network_endpoint_count: number }>}
 */
function extractPolicyMetrics() {
  const metrics = {};
  if (!fs.existsSync(POLICIES_DIR)) return metrics;
  try {
    const files = fs
      .readdirSync(POLICIES_DIR)
      .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"));
    for (const file of files) {
      const filePath = path.join(POLICIES_DIR, file);
      try {
        const content = fs.readFileSync(filePath, "utf8");
        metrics[filePath] = {
          deny_read_count: countYamlListItems(content, "deny_read"),
          deny_write_count: countYamlListItems(content, "deny_write"),
          read_write_count: countYamlListItems(content, "read_write"),
          network_endpoint_count: countNetworkEndpoints(content),
        };
      } catch {
        /* skip */
      }
    }
  } catch {
    /* dir read error */
  }
  return metrics;
}

/**
 * Extract security-critical fields from settings.
 * @param {Object} settings
 * @returns {{ deny_rules: string[], hook_count: number, hook_events: string[], hook_commands: string[], sandbox: boolean, unsandboxed: boolean, disableAllHooks: boolean, policy_hashes: Object, policy_metrics: Object }}
 */
function extractSecurityFields(settings) {
  const denyRules = (settings.permissions && settings.permissions.deny) || [];

  // Count total hooks and collect command strings across all events
  const hooks = settings.hooks || {};
  let hookCount = 0;
  const hookEvents = [];
  const hookCommands = [];
  for (const [event, entries] of Object.entries(hooks)) {
    hookEvents.push(event);
    for (const entry of Array.isArray(entries) ? entries : []) {
      const hookList = entry.hooks || [];
      hookCount += hookList.length;
      for (const h of hookList) {
        if (h.command) {
          hookCommands.push(h.command);
        }
      }
    }
  }

  const result = {
    deny_rules: denyRules,
    hook_count: hookCount,
    hook_events: hookEvents,
    hook_commands: hookCommands.sort(),
    sandbox:
      settings.sandbox !== undefined
        ? Boolean(settings.sandbox.enabled !== false)
        : true,
    unsandboxed: Boolean(settings.allowUnsandboxedCommands),
    disableAllHooks: Boolean(settings.disableAllHooks),
    policy_hashes: extractPolicyHashes(),
    policy_metrics: extractPolicyMetrics(),
    soft_deny_count: 0,
    soft_allow_count: 0,
  };

  // Auto Mode: read autoMode from both settings files (Phase 7, ADR-038)
  try {
    const mainAutoMode = readAutoModeSection(SETTINGS_FILE);
    const localAutoMode = readAutoModeSection(SETTINGS_LOCAL);
    const softDeny = [
      ...new Set([
        ...(mainAutoMode ? mainAutoMode.soft_deny : []),
        ...(localAutoMode ? localAutoMode.soft_deny : []),
      ]),
    ];
    const softAllow = [
      ...new Set([
        ...(mainAutoMode ? mainAutoMode.soft_allow : []),
        ...(localAutoMode ? localAutoMode.soft_allow : []),
      ]),
    ];
    result.soft_deny_count = softDeny.length;
    result.soft_allow_count = softAllow.length;
  } catch {
    // Auto Mode detection failure is non-blocking for config-guard
  }

  return result;
}

/**
 * Check for dangerous mutations between stored and current config.
 * @param {Object} stored - Previous security fields
 * @param {Object} current - Current security fields
 * @returns {{ blocked: boolean, reasons: string[] }}
 */
function detectDangerousMutations(stored, current) {
  const reasons = [];

  // Check 1: deny rules removed
  for (const rule of stored.deny_rules) {
    if (!current.deny_rules.includes(rule)) {
      reasons.push(`deny rule removed: "${rule}"`);
    }
  }

  // Check 2: hooks removed (event-level check)
  if (current.hook_count < stored.hook_count) {
    const removedCount = stored.hook_count - current.hook_count;
    reasons.push(`${removedCount} hook(s) removed from configuration`);
  }
  for (const event of stored.hook_events) {
    if (!current.hook_events.includes(event)) {
      reasons.push(`hook event "${event}" entirely removed`);
    }
  }

  // Check 2b: hook command content swap (B23 — same count, different commands)
  const storedCmds = stored.hook_commands || [];
  const currentCmds = current.hook_commands || [];
  if (storedCmds.length > 0 && currentCmds.length > 0) {
    for (const cmd of storedCmds) {
      if (!currentCmds.includes(cmd)) {
        reasons.push(`hook command removed or swapped: "${cmd}"`);
      }
    }
  }

  // Check 3: sandbox disabled
  if (stored.sandbox && !current.sandbox) {
    reasons.push("sandbox.enabled set to false");
  }

  // Check 4: unsandboxed commands allowed
  if (!stored.unsandboxed && current.unsandboxed) {
    reasons.push("allowUnsandboxedCommands set to true");
  }

  // Check 5: all hooks disabled
  if (!stored.disableAllHooks && current.disableAllHooks) {
    reasons.push("disableAllHooks set to true");
  }

  // Check 6: OpenShell policy file tampering (ADR-037 GA Phase)
  const storedHashes = stored.policy_hashes || {};
  const currentHashes = current.policy_hashes || {};
  const storedMetrics = stored.policy_metrics || {};
  const currentMetrics = current.policy_metrics || {};

  for (const [filePath, storedHash] of Object.entries(storedHashes)) {
    if (!(filePath in currentHashes)) {
      // Policy file was deleted
      reasons.push(`OpenShell policy file removed: "${filePath}"`);
      continue;
    }
    if (currentHashes[filePath] !== storedHash) {
      // Policy file changed — check for weakening
      const sm = storedMetrics[filePath] || {};
      const cm = currentMetrics[filePath] || {};

      if (
        sm.deny_read_count > 0 &&
        (cm.deny_read_count || 0) < sm.deny_read_count
      ) {
        reasons.push(
          `OpenShell policy weakened: deny_read reduced (${sm.deny_read_count} → ${cm.deny_read_count || 0}) in "${filePath}"`,
        );
      }
      if (
        sm.deny_write_count > 0 &&
        (cm.deny_write_count || 0) < sm.deny_write_count
      ) {
        reasons.push(
          `OpenShell policy weakened: deny_write reduced (${sm.deny_write_count} → ${cm.deny_write_count || 0}) in "${filePath}"`,
        );
      }
      if ((cm.network_endpoint_count || 0) > (sm.network_endpoint_count || 0)) {
        reasons.push(
          `OpenShell policy weakened: network endpoints expanded (${sm.network_endpoint_count || 0} → ${cm.network_endpoint_count}) in "${filePath}"`,
        );
      }
      if ((cm.read_write_count || 0) > (sm.read_write_count || 0)) {
        reasons.push(
          `OpenShell policy weakened: read_write paths expanded (${sm.read_write_count || 0} → ${cm.read_write_count}) in "${filePath}"`,
        );
      }
    }
  }

  // Check 7: Auto Mode soft_deny addition (CRITICAL — all default protections lost)
  const storedSoftDeny = stored.soft_deny_count || 0;
  const currentSoftDeny = current.soft_deny_count || 0;
  if (currentSoftDeny > storedSoftDeny) {
    reasons.push(
      `Auto Mode soft_deny added (${storedSoftDeny} → ${currentSoftDeny}) — ALL default protections would be lost`,
    );
  }

  // Check 8: Auto Mode soft_allow expansion
  const storedSoftAllow = stored.soft_allow_count || 0;
  const currentSoftAllow = current.soft_allow_count || 0;
  if (currentSoftAllow > storedSoftAllow) {
    reasons.push(
      `Auto Mode soft_allow expanded (${storedSoftAllow} → ${currentSoftAllow}) — additional tools auto-approved`,
    );
  }

  return {
    blocked: reasons.length > 0,
    reasons,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

if (require.main === module) {
  try {
    const input = readHookInput();

    const settings = readSettings();
    if (!settings) {
      deny(`[${HOOK_NAME}] settings.json not found or unreadable — fail-close`);
      return;
    }

    const currentFields = extractSecurityFields(settings);
    const settingsContent = fs.readFileSync(SETTINGS_FILE, "utf8");
    const currentHash = sha256(settingsContent);

    const stored = loadStoredConfig();

    // First run: record baseline
    if (!stored) {
      saveConfigSnapshot({
        hash: currentHash,
        ...currentFields,
      });

      try {
        appendEvidence({
          hook: HOOK_NAME,
          event: "ConfigChange",
          decision: "allow",
          action: "baseline_recorded",
          settings_hash: `sha256:${currentHash}`,
          session_id: input.sessionId,
        });
      } catch {
        // Non-blocking
      }

      allow(`[${HOOK_NAME}] Config baseline recorded`);
      return;
    }

    // Check for dangerous mutations
    const mutations = detectDangerousMutations(stored, currentFields);

    if (mutations.blocked) {
      try {
        appendEvidence({
          hook: HOOK_NAME,
          event: "ConfigChange",
          decision: "deny",
          reasons: mutations.reasons,
          settings_hash: `sha256:${currentHash}`,
          previous_hash: `sha256:${stored.hash}`,
          session_id: input.sessionId,
        });
      } catch {
        // Non-blocking
      }

      deny(
        `[${HOOK_NAME}] Blocked dangerous config change: ${mutations.reasons.join("; ")}`,
      );
      return;
    }

    // Safe change — update snapshot and allow
    saveConfigSnapshot({
      hash: currentHash,
      ...currentFields,
    });

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "ConfigChange",
        decision: "allow",
        action: "config_updated",
        settings_hash: `sha256:${currentHash}`,
        previous_hash: stored ? `sha256:${stored.hash}` : null,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow();
  } catch (err) {
    // SECURITY hook — fail-close (§2.3b)
    process.stdout.write(
      JSON.stringify({
        reason: `[${HOOK_NAME}] Hook error (fail-close): ${err.message}`,
      }),
    );
    process.exit(2);
  }
} // end require.main === module

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  readSettings,
  loadStoredConfig,
  saveConfigSnapshot,
  extractSecurityFields,
  detectDangerousMutations,
  extractPolicyHashes,
  extractPolicyMetrics,
  countYamlListItems,
  countNetworkEndpoints,
};
