#!/usr/bin/env node
// policy-compat.js — Policy version compatibility check
// Spec: TASK-021, ADR-037 Phase Beta
// Purpose: Verify OpenShell policy schema version compatibility at SessionStart
"use strict";

const fs = require("fs");

/**
 * Compatibility matrix: OpenShell CLI version range → supported policy schema versions.
 * Each entry defines which policy schema versions are supported by a given
 * OpenShell CLI version range (min inclusive, max exclusive).
 *
 * Update this matrix when OpenShell releases breaking policy schema changes.
 * @type {Array<{openshell_min: string, openshell_max: string, supported_policy_versions: number[], latest_policy_version: number}>}
 */
const COMPAT_MATRIX = [
  {
    // OpenShell Alpha (0.0.x): policy schema v1 only
    openshell_min: "0.0.0",
    openshell_max: "1.0.0",
    supported_policy_versions: [1],
    latest_policy_version: 1,
  },
  // Future entries (example):
  // {
  //   openshell_min: "1.0.0",
  //   openshell_max: "2.0.0",
  //   supported_policy_versions: [1, 2],
  //   latest_policy_version: 2,
  // },
];

/**
 * Extract policy schema version from YAML content string.
 * Uses regex to avoid js-yaml dependency (zero external deps).
 * Only matches top-level (non-indented, non-commented) version: field.
 * @param {string} content - Raw YAML file content
 * @returns {number|null} - Extracted version number, or null if not found/invalid
 */
function extractPolicyVersion(content) {
  if (!content) return null;
  // Match top-level version field: no leading whitespace, not in a comment
  // Supports: version: 1, version: "1", version: '1'
  const match = content.match(/^version:\s*["']?(\d+)["']?/m);
  if (!match) return null;
  // Verify the matched line is not indented (top-level only)
  const lineStart = content.lastIndexOf("\n", match.index) + 1;
  if (match.index > lineStart) return null; // indented
  // Verify line is not a comment
  const linePrefix = content.slice(lineStart, match.index);
  if (linePrefix.includes("#")) return null;
  return parseInt(match[1], 10);
}

/**
 * Compare two semver strings (X.Y.Z format).
 * @param {string} a - First version string
 * @param {string} b - Second version string
 * @returns {-1|0|1} - -1 if a < b, 0 if equal, 1 if a > b
 */
function compareSemver(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const va = pa[i] || 0;
    const vb = pb[i] || 0;
    if (va < vb) return -1;
    if (va > vb) return 1;
  }
  return 0;
}

/**
 * Check if a semver version falls within a range [min, max).
 * @param {string} version - Version to check
 * @param {string} min - Minimum version (inclusive)
 * @param {string} maxExclusive - Maximum version (exclusive)
 * @returns {boolean}
 */
function semverInRange(version, min, maxExclusive) {
  return (
    compareSemver(version, min) >= 0 && compareSemver(version, maxExclusive) < 0
  );
}

/**
 * Check policy file schema version compatibility with installed OpenShell version.
 * fail-safe: never throws, returns { compatible: null } on any error.
 * @param {{ openshellVersion: string|null, policyFilePath: string }} params
 * @returns {{
 *   compatible: boolean|null,
 *   policy_version: number|null,
 *   openshell_version: string|null,
 *   reason: string|null,
 *   recommended_policy_version: number|null,
 *   migration_hint: string|null,
 *   checked_at: string
 * }}
 */
function checkPolicyCompatibility({ openshellVersion, policyFilePath }) {
  const checked_at = new Date().toISOString();
  const base = {
    compatible: null,
    policy_version: null,
    openshell_version: openshellVersion || null,
    reason: null,
    recommended_policy_version: null,
    migration_hint: null,
    checked_at,
  };

  try {
    // Step 1: Read policy file
    if (!fs.existsSync(policyFilePath)) {
      return { ...base, reason: "policy_not_found" };
    }

    const content = fs.readFileSync(policyFilePath, "utf8");

    // Step 2: Extract schema version
    const policyVersion = extractPolicyVersion(content);
    base.policy_version = policyVersion;

    if (policyVersion == null) {
      return { ...base, reason: "version_not_readable" };
    }

    // Step 3: Check OpenShell version availability
    if (!openshellVersion) {
      return { ...base, reason: "openshell_version_unknown" };
    }

    // Step 4: Find matching matrix entry
    const entry = COMPAT_MATRIX.find((e) =>
      semverInRange(openshellVersion, e.openshell_min, e.openshell_max),
    );

    if (!entry) {
      return { ...base, reason: "unknown_combination" };
    }

    // Step 5: Check compatibility
    if (entry.supported_policy_versions.includes(policyVersion)) {
      return { ...base, compatible: true };
    }

    // Incompatible: policy version not supported by this OpenShell range
    return {
      ...base,
      compatible: false,
      recommended_policy_version: entry.latest_policy_version,
      migration_hint:
        "Policy schema v" +
        policyVersion +
        " is not supported by OpenShell v" +
        openshellVersion +
        ". " +
        "Supported versions: " +
        entry.supported_policy_versions.join(", ") +
        ". " +
        "Regenerate policy with: npx shield-harness init --policy",
    };
  } catch {
    // fail-safe: any unexpected error returns unknown
    return { ...base, reason: "check_error" };
  }
}

module.exports = {
  extractPolicyVersion,
  compareSemver,
  semverInRange,
  checkPolicyCompatibility,
  COMPAT_MATRIX,
};
