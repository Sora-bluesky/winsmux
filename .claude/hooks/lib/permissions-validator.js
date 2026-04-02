#!/usr/bin/env node
// permissions-validator.js — Validates alignment between permissions-spec.json and settings.json
// Part of the permanent countermeasure system for design-implementation divergence prevention
"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Load and validate permissions-spec.json.
 * @param {string} specPath - Path to permissions-spec.json
 * @returns {{ deny: string[], ask: string[], allow: string[], expected_counts: object }}
 * @throws {Error} If file is missing, invalid JSON, or malformed
 */
function loadPermissionsSpec(specPath) {
  if (!fs.existsSync(specPath)) {
    throw new Error(`Permissions spec not found: ${specPath}`);
  }

  const raw = fs.readFileSync(specPath, "utf8");
  let spec;
  try {
    spec = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Permissions spec is not valid JSON: ${err.message}`);
  }

  if (!spec.permissions) {
    throw new Error("Permissions spec missing 'permissions' field");
  }

  const perms = spec.permissions;
  const deny = (perms.deny || []).map((entry) =>
    typeof entry === "string" ? entry : entry.rule,
  );
  const ask = (perms.ask || []).map((entry) =>
    typeof entry === "string" ? entry : entry.rule,
  );
  const allow = (perms.allow || []).map((entry) =>
    typeof entry === "string" ? entry : entry.rule,
  );

  return {
    deny,
    ask,
    allow,
    expected_counts: spec.expected_counts || null,
  };
}

/**
 * Load permissions from settings.json.
 * @param {string} settingsPath - Path to settings.json
 * @returns {{ deny: string[], ask: string[], allow: string[] }}
 * @throws {Error} If file is missing, invalid JSON, or missing permissions
 */
function loadSettingsPermissions(settingsPath) {
  if (!fs.existsSync(settingsPath)) {
    throw new Error(`Settings file not found: ${settingsPath}`);
  }

  const raw = fs.readFileSync(settingsPath, "utf8");
  let settings;
  try {
    settings = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Settings file is not valid JSON: ${err.message}`);
  }

  const perms = settings.permissions || {};
  return {
    deny: perms.deny || [],
    ask: perms.ask || [],
    allow: perms.allow || [],
  };
}

/**
 * Compute the set difference: items in setA but not in setB.
 * @param {string[]} setA
 * @param {string[]} setB
 * @returns {string[]}
 */
function setDiff(setA, setB) {
  const bSet = new Set(setB);
  return setA.filter((item) => !bSet.has(item));
}

/**
 * Diff permissions spec against settings.json.
 * @param {{ deny: string[], ask: string[], allow: string[] }} spec
 * @param {{ deny: string[], ask: string[], allow: string[] }} settings
 * @returns {object} Diff result with missing/extra rules per category
 */
function diffPermissions(spec, settings) {
  const result = {
    missingDeny: setDiff(spec.deny, settings.deny),
    extraDeny: setDiff(settings.deny, spec.deny),
    missingAsk: setDiff(spec.ask, settings.ask),
    extraAsk: setDiff(settings.ask, spec.ask),
    missingAllow: setDiff(spec.allow, settings.allow),
    extraAllow: setDiff(settings.allow, spec.allow),
  };

  result.totalMissing =
    result.missingDeny.length +
    result.missingAsk.length +
    result.missingAllow.length;
  result.totalExtra =
    result.extraDeny.length + result.extraAsk.length + result.extraAllow.length;
  result.aligned = result.totalMissing === 0 && result.totalExtra === 0;

  return result;
}

/**
 * Validate alignment between permissions-spec.json and settings.json.
 * @param {string} specPath
 * @param {string} settingsPath
 * @returns {{ aligned: boolean, diff: object, summary: string, counts: string }}
 */
function validateAlignment(specPath, settingsPath) {
  const spec = loadPermissionsSpec(specPath);
  const settings = loadSettingsPermissions(settingsPath);
  const diff = diffPermissions(spec, settings);

  const counts = `${spec.deny.length} deny, ${spec.ask.length} ask, ${spec.allow.length} allow`;

  if (diff.aligned) {
    return { aligned: true, diff, summary: "All rules aligned", counts };
  }

  const parts = [];
  if (diff.missingDeny.length > 0) {
    parts.push(`${diff.missingDeny.length} deny rules missing from settings`);
  }
  if (diff.extraDeny.length > 0) {
    parts.push(`${diff.extraDeny.length} extra deny rules in settings`);
  }
  if (diff.missingAsk.length > 0) {
    parts.push(`${diff.missingAsk.length} ask rules missing from settings`);
  }
  if (diff.extraAsk.length > 0) {
    parts.push(`${diff.extraAsk.length} extra ask rules in settings`);
  }
  if (diff.missingAllow.length > 0) {
    parts.push(`${diff.missingAllow.length} allow rules missing from settings`);
  }
  if (diff.extraAllow.length > 0) {
    parts.push(`${diff.extraAllow.length} extra allow rules in settings`);
  }

  const summary = parts.join("; ");
  return { aligned: false, diff, summary, counts };
}

/**
 * Format a human-readable report of the alignment diff.
 * @param {{ aligned: boolean, diff: object, summary: string }} result
 * @returns {string}
 */
function formatReport(result) {
  if (result.aligned) {
    return "Permissions alignment: OK";
  }

  const lines = ["Permissions alignment: DIVERGENCE DETECTED", ""];
  const { diff } = result;

  if (diff.missingDeny.length > 0) {
    lines.push("Missing deny rules (in spec but not in settings.json):");
    diff.missingDeny.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }
  if (diff.extraDeny.length > 0) {
    lines.push("Extra deny rules (in settings.json but not in spec):");
    diff.extraDeny.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }
  if (diff.missingAsk.length > 0) {
    lines.push("Missing ask rules (in spec but not in settings.json):");
    diff.missingAsk.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }
  if (diff.extraAsk.length > 0) {
    lines.push("Extra ask rules (in settings.json but not in spec):");
    diff.extraAsk.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }
  if (diff.missingAllow.length > 0) {
    lines.push("Missing allow rules (in spec but not in settings.json):");
    diff.missingAllow.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }
  if (diff.extraAllow.length > 0) {
    lines.push("Extra allow rules (in settings.json but not in spec):");
    diff.extraAllow.forEach((r) => lines.push(`  - ${r}`));
    lines.push("");
  }

  return lines.join("\n");
}

module.exports = {
  loadPermissionsSpec,
  loadSettingsPermissions,
  setDiff,
  diffPermissions,
  validateAlignment,
  formatReport,
};
