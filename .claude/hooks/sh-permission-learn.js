#!/usr/bin/env node
// sh-permission-learn.js — Permission learning guard
// Spec: DETAILED_DESIGN.md §5.7
// Event: PermissionRequest
// Target response time: < 20ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  deny,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-permission-learn";
const SETTINGS_FILE = path.join(".claude", "settings.json");
const SETTINGS_LOCAL_FILE = path.join(".claude", "settings.local.json");
const MAX_LEARNED_RULES = 100;

// Overly broad patterns that should never be learned
const LEARNING_BLACKLIST = [
  /^Bash\(\*\)$/, // Too broad — allows all Bash commands
  /^Edit\(\*\)$/, // Too broad — allows editing any file
  /^Write\(\*\)$/, // Too broad — allows writing any file
  /^Bash\(curl\s/, // Network access
  /^Bash\(wget\s/, // Network access
  /^Edit\(\.claude\//, // Self-modification
  /^Write\(\.claude\//, // Self-modification
];

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/**
 * Load deny rules from settings.json.
 * @returns {string[]}
 */
function loadDenyRules() {
  try {
    if (!fs.existsSync(SETTINGS_FILE)) return [];
    const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
    return (settings.permissions && settings.permissions.deny) || [];
  } catch {
    return [];
  }
}

/**
 * Load current learned allow rules count from settings.local.json.
 * @returns {number}
 */
function getLearnedRuleCount() {
  try {
    if (!fs.existsSync(SETTINGS_LOCAL_FILE)) return 0;
    const local = JSON.parse(fs.readFileSync(SETTINGS_LOCAL_FILE, "utf8"));
    return ((local.permissions && local.permissions.allow) || []).length;
  } catch {
    return 0;
  }
}

/**
 * Check if a permission pattern conflicts with any deny rule.
 * A conflict exists when the requested permission would match something denied.
 * @param {string} permissionPattern - e.g., "Bash(rm -rf *)"
 * @param {string[]} denyRules
 * @returns {string|null} - Conflicting deny rule, or null
 */
function checkDenyConflict(permissionPattern, denyRules) {
  // Simple substring/overlap check
  // Extract tool name from pattern
  const toolMatch = permissionPattern.match(/^(\w+)\((.+)\)$/);
  if (!toolMatch) return null;

  const [, tool, pattern] = toolMatch;

  for (const denyRule of denyRules) {
    const denyMatch = denyRule.match(/^(\w+)\((.+)\)$/);
    if (!denyMatch) continue;

    const [, denyTool, denyPattern] = denyMatch;

    // Same tool type
    if (tool !== denyTool) continue;

    // Check if the requested pattern would overlap with deny
    // If the requested pattern contains the denied path/command, it conflicts
    if (
      pattern.includes(denyPattern.replace(/\*/g, "")) ||
      denyPattern.includes(pattern.replace(/\*/g, ""))
    ) {
      return denyRule;
    }
  }

  return null;
}

/**
 * Check if a permission pattern is in the blacklist.
 * @param {string} permissionPattern
 * @returns {boolean}
 */
function isBlacklisted(permissionPattern) {
  return LEARNING_BLACKLIST.some((re) => re.test(permissionPattern));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  // Permission pattern from the request
  const permissionPattern =
    input.toolInput.permission || input.toolInput.tool_pattern || "";

  if (!permissionPattern) {
    allow();
    return;
  }

  // Check 1: deny rule conflict
  const denyRules = loadDenyRules();
  const conflict = checkDenyConflict(permissionPattern, denyRules);
  if (conflict) {
    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "PermissionRequest",
        decision: "deny",
        reason: "deny_rule_conflict",
        pattern: permissionPattern,
        conflicting_rule: conflict,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    deny(
      `[${HOOK_NAME}] deny ルールは学習で上書きできません。衝突ルール: ${conflict}`,
    );
    return;
  }

  // Check 2: blacklist
  if (isBlacklisted(permissionPattern)) {
    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "PermissionRequest",
        decision: "deny",
        reason: "blacklisted_pattern",
        pattern: permissionPattern,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    deny(`[${HOOK_NAME}] パターンが広すぎます: ${permissionPattern}`);
    return;
  }

  // Check 3: learning limit
  const currentCount = getLearnedRuleCount();
  if (currentCount >= MAX_LEARNED_RULES) {
    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "PermissionRequest",
        decision: "deny",
        reason: "learning_limit_exceeded",
        pattern: permissionPattern,
        current_count: currentCount,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    deny(
      `[${HOOK_NAME}] 学習上限に到達しました (${currentCount}/${MAX_LEARNED_RULES})`,
    );
    return;
  }

  // All checks passed — allow
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "PermissionRequest",
      decision: "allow",
      pattern: permissionPattern,
      session_id: input.sessionId,
    });
  } catch {
    // Non-blocking
  }

  allow();
} catch (err) {
  // SECURITY hook — fail-close
  process.stdout.write(
    JSON.stringify({
      reason: `[${HOOK_NAME}] Hook error (fail-close): ${err.message}`,
    }),
  );
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  LEARNING_BLACKLIST,
  MAX_LEARNED_RULES,
  loadDenyRules,
  getLearnedRuleCount,
  checkDenyConflict,
  isBlacklisted,
};
