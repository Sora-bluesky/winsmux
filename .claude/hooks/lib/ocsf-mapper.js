// ocsf-mapper.js — OCSF Detection Finding (class_uid: 2004) transformer
// Maps Shield Harness hook evidence entries to OCSF Detection Finding format.
// Spec: https://schema.ocsf.io/ (v1.3.0)
"use strict";

const crypto = require("crypto");
const path = require("path");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const OCSF_VERSION = "1.3.0";
const CLASS_UID = 2004;
const CATEGORY_UID = 2;
const TYPE_UID = 200401; // Detection Finding: Create

// Product version from package.json (cached at module load)
let productVersion = "1.0.0";
try {
  productVersion = require(path.resolve("package.json")).version;
} catch {
  // Fallback — running outside project root
}

// Fields that map to OCSF common fields (not placed in unmapped)
const OCSF_COMMON_FIELDS = new Set([
  "hook",
  "event",
  "decision",
  "session_id",
  "tool",
  "seq",
  "severity",
  "sandbox_state",
  "sandbox_version",
  "sandbox_policy_enforced",
]);

// ---------------------------------------------------------------------------
// Severity mapping
// ---------------------------------------------------------------------------

const SEVERITY_NAMES = {
  1: "Informational",
  2: "Low",
  3: "Medium",
  4: "High",
  5: "Critical",
};

/**
 * Resolve OCSF severity_id from hook context.
 * @param {string} hook
 * @param {string} decision
 * @param {string} [severity] - Hook-provided severity string
 * @returns {number} 1-5
 */
function resolveSeverityId(hook, decision, severity) {
  if (decision !== "deny" && !severity) return 1; // Informational for allow

  // If hook provides explicit severity, map it
  if (severity) {
    const map = { critical: 5, high: 4, medium: 3, low: 2 };
    return map[severity.toLowerCase()] || 3;
  }

  // Hook-specific deny severity
  const hookSeverity = {
    "sh-injection-guard": 4,
    "sh-config-guard": 4,
    "sh-data-boundary": 4,
    "sh-gate": 3,
    "sh-user-prompt": 3,
    "sh-circuit-breaker": 3,
    "sh-elicitation": 3,
    "sh-permission": 3,
  };
  return hookSeverity[hook] || 3;
}

// ---------------------------------------------------------------------------
// Disposition mapping
// ---------------------------------------------------------------------------

/**
 * Resolve OCSF disposition_id.
 * @param {string} decision
 * @param {string|null} category
 * @returns {number}
 */
function resolveDispositionId(decision, category) {
  if (decision === "deny") return 2; // Blocked
  if (category === "pii_detected" || category === "leakage_detected") {
    return 15; // Detected
  }
  return 1; // Allowed
}

// ---------------------------------------------------------------------------
// Title generation
// ---------------------------------------------------------------------------

const TITLE_TEMPLATES = {
  "sh-evidence": (e) => `Tool execution recorded: ${e.tool || "unknown"}`,
  "sh-config-guard": (e) =>
    `Configuration change ${e.action || "check"}: ${e.decision}`,
  "sh-injection-guard": (e) =>
    `Injection pattern detected: ${e.category || "unknown"}`,
  "sh-circuit-breaker": (e) => `Circuit breaker: ${e.reason || e.decision}`,
  "sh-gate": (e) => `Bash command gate: ${e.decision}`,
  "sh-data-boundary": (e) =>
    `Data boundary violation: ${e.host || "unknown host"}`,
  "sh-instructions": (e) => `Instructions integrity: ${e.action || "check"}`,
  "sh-elicitation": (e) => `Elicitation check: ${e.reason || e.decision}`,
  "sh-dep-audit": (e) => `Dependency audit: ${e.reason || "recorded"}`,
  "sh-precompact": () => "Pre-compaction backup",
  "sh-postcompact": () => "Post-compaction integrity check",
  "sh-session-end": () => "Session closed",
  "sh-session-start": () => "Session initialized",
  "sh-subagent": () => "Subagent budget allocated",
  "sh-worktree": (e) => `Worktree operation: ${e.event || "unknown"}`,
  "sh-permission-learn": (e) =>
    `Permission learning: ${e.reason || "recorded"}`,
  "sh-permission": (e) => `Permission check: ${e.decision}`,
  "sh-pipeline": (e) => `Pipeline stage: ${e.stage || "unknown"}`,
  "sh-task-gate": (e) => `Task gate: ${e.reason || "check"}`,
  "sh-user-prompt": (e) =>
    `User prompt scan: ${e.category || "clean"} (${e.severity || "info"})`,
  "sh-output-control": (e) => `Output control: ${e.decision || "allow"}`,
};

/**
 * Generate finding_info.title from hook and entry.
 * @param {string} hook
 * @param {Object} entry
 * @returns {string}
 */
function generateTitle(hook, entry) {
  const template = TITLE_TEMPLATES[hook];
  if (template) return template(entry);
  return `${hook}: ${entry.decision || entry.event || "recorded"}`;
}

// ---------------------------------------------------------------------------
// UUID generation (Node.js 18 compatible)
// ---------------------------------------------------------------------------

function generateUUID() {
  if (typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // Fallback for Node.js < 19
  const bytes = crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

// ---------------------------------------------------------------------------
// Unmapped field extraction
// ---------------------------------------------------------------------------

/**
 * Extract hook-specific fields that have no OCSF mapping.
 * @param {Object} entry
 * @returns {Object}
 */
function extractUnmapped(entry) {
  const unmapped = {};
  for (const [key, value] of Object.entries(entry)) {
    if (!OCSF_COMMON_FIELDS.has(key) && value !== undefined) {
      unmapped[key] = value;
    }
  }
  return Object.keys(unmapped).length > 0 ? unmapped : undefined;
}

// ---------------------------------------------------------------------------
// Main transformer
// ---------------------------------------------------------------------------

/**
 * Transform a hook evidence entry to OCSF Detection Finding (class_uid: 2004).
 * @param {Object} entry - Raw hook evidence entry
 * @returns {Object} OCSF-compliant Detection Finding
 */
function toDetectionFinding(entry) {
  const hook = entry.hook || "unknown";
  const decision = entry.decision || "allow";
  const severityId = resolveSeverityId(hook, decision, entry.severity);
  const dispositionId = resolveDispositionId(decision, entry.category);
  const isAllow = decision === "allow";

  const finding = {
    // OCSF required
    class_uid: CLASS_UID,
    class_name: "Detection Finding",
    category_uid: CATEGORY_UID,
    category_name: "Findings",
    type_uid: TYPE_UID,
    activity_id: 1,
    time: Date.now(),
    severity_id: severityId,
    severity: SEVERITY_NAMES[severityId] || "Unknown",
    status_id: 1,
    status: "New",

    // OCSF recommended
    action_id: isAllow ? 1 : 2,
    action: isAllow ? "Allowed" : "Denied",
    disposition_id: dispositionId,

    // Metadata
    metadata: {
      version: OCSF_VERSION,
      product: {
        name: "Shield Harness",
        vendor_name: "Shield Harness",
        version: productVersion,
      },
      log_name: "evidence-ledger",
    },

    // Finding info
    finding_info: {
      uid: generateUUID(),
      title: generateTitle(hook, entry),
      analytic: {
        type_id: 1,
        type: "Rule",
        name: hook,
        uid: hook,
      },
    },
  };

  // Correlation (session_id → metadata.correlation_uid)
  if (entry.session_id) {
    finding.metadata.correlation_uid = entry.session_id;
  }

  // Sequence (seq → metadata.sequence)
  if (typeof entry.seq === "number") {
    finding.metadata.sequence = entry.seq;
  }

  // Resources (tool name)
  if (entry.tool) {
    finding.resources = [{ type: "tool", name: entry.tool }];
  }

  // OpenShell sandbox metadata (Beta Phase)
  if (entry.sandbox_state === "active") {
    finding.resources = finding.resources || [];
    finding.resources.push({
      type: "container",
      name: "openshell-sandbox",
      labels: [
        "state:" + entry.sandbox_state,
        entry.sandbox_version ? "version:" + entry.sandbox_version : null,
        entry.sandbox_policy_enforced ? "policy_enforced:true" : null,
      ].filter(Boolean),
    });
  }

  // Unmapped (hook-specific fields)
  const unmapped = extractUnmapped(entry);
  if (unmapped) {
    finding.unmapped = unmapped;
  }

  return finding;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  toDetectionFinding,
  // Exported for testing
  resolveSeverityId,
  resolveDispositionId,
  generateTitle,
  extractUnmapped,
  generateUUID,
  OCSF_VERSION,
};
