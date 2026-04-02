#!/usr/bin/env node
// automode-detect.js — Claude Code Auto Mode detection & danger assessment
// Spec: Phase 7 ADR-038 (.reference/PHASE7_8_AUTO_MODE_SELF_EVOLUTION_PLAN.md)
// Purpose: Detect Auto Mode configuration and classify danger level
"use strict";

const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SETTINGS_LOCAL = path.join(".claude", "settings.local.json");
const SETTINGS_MAIN = path.join(".claude", "settings.json");

/**
 * Protections lost when autoMode.soft_deny is configured.
 * A single soft_deny entry disables ALL classifier default protections.
 */
const LOST_PROTECTIONS = [
  "Default force-push prevention (git push --force)",
  "Default destructive command blocking (rm -rf, format)",
  "Default credential access prevention (~/.ssh, ~/.aws)",
  "Default network isolation (curl|bash, data exfiltration)",
  "Default file system protection (system files modification)",
  "Default package execution control (npm install, npx)",
  "Classifier-based safety judgments for all unlisted tools",
];

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/**
 * Read autoMode section from a settings JSON file.
 * fail-safe: returns null on any error (file missing, parse error, no autoMode).
 * @param {string} filePath - Path to settings JSON file
 * @returns {{ soft_deny: string[], soft_allow: string[], environment: string|null }|null}
 */
function readSettingsFile(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    const content = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const autoMode = content.autoMode;
    if (!autoMode || typeof autoMode !== "object") return null;
    return {
      soft_deny: Array.isArray(autoMode.soft_deny) ? autoMode.soft_deny : [],
      soft_allow: Array.isArray(autoMode.soft_allow) ? autoMode.soft_allow : [],
      environment:
        typeof autoMode.environment === "string" ? autoMode.environment : null,
    };
  } catch {
    return null;
  }
}

/**
 * Classify danger level based on soft_deny and soft_allow counts.
 * @param {number} softDenyCount
 * @param {number} softAllowCount
 * @returns {"safe"|"warn"|"critical"}
 */
function classifyDangerLevel(softDenyCount, softAllowCount) {
  if (softDenyCount > 0) return "critical";
  if (softAllowCount > 0) return "warn";
  return "safe";
}

// ---------------------------------------------------------------------------
// Main detection function
// ---------------------------------------------------------------------------

/**
 * Detect Auto Mode configuration and assess danger level.
 * Reads settings.local.json (priority) and settings.json, merges results.
 * fail-safe: never throws, returns safe defaults on any error.
 *
 * @returns {{
 *   detected: boolean,
 *   danger_level: "safe"|"warn"|"critical",
 *   reason: string,
 *   soft_deny_count: number,
 *   soft_allow_count: number,
 *   has_environment: boolean,
 *   environment_snippet: string|null,
 *   danger_items: string[],
 *   source: "settings_local"|"settings"|"both"|"none",
 *   detected_at: string
 * }}
 */
function detectAutoMode() {
  const detected_at = new Date().toISOString();
  const base = {
    detected: false,
    danger_level: "safe",
    reason: "not_configured",
    soft_deny_count: 0,
    soft_allow_count: 0,
    has_environment: false,
    environment_snippet: null,
    danger_items: [],
    source: "none",
    detected_at,
  };

  try {
    const localResult = readSettingsFile(SETTINGS_LOCAL);
    const mainResult = readSettingsFile(SETTINGS_MAIN);

    // No autoMode in either file
    if (!localResult && !mainResult) {
      return base;
    }

    // Determine source
    const source =
      localResult && mainResult
        ? "both"
        : localResult
          ? "settings_local"
          : "settings";

    // Merge soft_deny and soft_allow from both files (deduplicate)
    const softDeny = [
      ...new Set([
        ...(localResult ? localResult.soft_deny : []),
        ...(mainResult ? mainResult.soft_deny : []),
      ]),
    ];
    const softAllow = [
      ...new Set([
        ...(localResult ? localResult.soft_allow : []),
        ...(mainResult ? mainResult.soft_allow : []),
      ]),
    ];

    // Environment: local overrides main
    const environment =
      (localResult && localResult.environment) ||
      (mainResult && mainResult.environment) ||
      null;

    const dangerLevel = classifyDangerLevel(softDeny.length, softAllow.length);

    // Determine reason code
    let reason = "configured_safe";
    if (softDeny.length > 0 && softAllow.length > 0) {
      reason = "both_present";
    } else if (softDeny.length > 0) {
      reason = "soft_deny_present";
    } else if (softAllow.length > 0) {
      reason = "soft_allow_only";
    }

    return {
      detected: true,
      danger_level: dangerLevel,
      reason,
      soft_deny_count: softDeny.length,
      soft_allow_count: softAllow.length,
      has_environment: environment !== null,
      environment_snippet: environment ? environment.slice(0, 80) : null,
      danger_items: dangerLevel === "critical" ? [...LOST_PROTECTIONS] : [],
      source,
      detected_at,
    };
  } catch {
    return { ...base, reason: "read_error" };
  }
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  detectAutoMode,
  classifyDangerLevel,
  readSettingsFile,
  LOST_PROTECTIONS,
  SETTINGS_LOCAL,
  SETTINGS_MAIN,
};
