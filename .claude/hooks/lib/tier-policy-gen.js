#!/usr/bin/env node
// tier-policy-gen.js — Generate OpenShell Policy Schema v1 YAML from permissions-spec.json
// Spec: ADR-037 Phase Beta, Stream C
// Purpose: Convert Shield Harness permission rules into OpenShell sandbox policy files
"use strict";

// --- Rule Parsing ---

/**
 * Parse a permission rule string into structured components.
 * Supports formats:
 *   "Read(~/.ssh/**)"          -> { action: "Read", target: "~/.ssh/**" }
 *   "Bash(curl *)"             -> { action: "Bash", command: "curl", pattern: "*" }
 *   "Edit(.claude/hooks/**)"   -> { action: "Edit", target: ".claude/hooks/**" }
 *   "Glob(*)"                  -> { action: "Glob", target: "*" }
 * @param {string} rule - Raw permission rule string
 * @returns {{ action: string, target?: string, command?: string, pattern?: string }|null}
 */
function parsePermissionRule(rule) {
  if (!rule || typeof rule !== "string") return null;

  const match = rule.match(/^(\w+)\((.+)\)$/);
  if (!match) return null;

  const action = match[1];
  const inner = match[2];

  if (action === "Bash") {
    // Split into command and pattern: "curl *" -> { command: "curl", pattern: "*" }
    const spaceIdx = inner.indexOf(" ");
    if (spaceIdx === -1) {
      return { action, command: inner, pattern: "" };
    }
    return {
      action,
      command: inner.slice(0, spaceIdx),
      pattern: inner.slice(spaceIdx + 1),
    };
  }

  return { action, target: inner };
}

// --- Domain Classification ---

/**
 * Network-related commands (Bash rules classified as network domain).
 * @type {Set<string>}
 */
const NETWORK_COMMANDS = new Set([
  "curl",
  "wget",
  "nc",
  "ncat",
  "nmap",
  "Invoke-WebRequest",
]);

/**
 * Destructive commands (classified as process domain).
 * @type {Set<string>}
 */
const DESTRUCTIVE_COMMANDS = new Set(["rm", "del", "format"]);

/**
 * Remove trailing glob wildcards from a path for policy use.
 * Example: "~/.ssh/[star][star]" becomes "~/.ssh"
 * Leading globs are preserved (e.g., "[star][star]/.env" stays as-is).
 * @param {string} p - Glob path
 * @returns {string}
 */
function cleanGlobPath(p) {
  return p.replace(/\/\*\*$/, "").replace(/\/\*$/, "");
}

/**
 * Classify an array of deny rules by security domain.
 * @param {Array<{rule: string, rationale?: string, threat_id?: string}>} rules
 * @returns {{
 *   denyRead: string[],
 *   denyWrite: string[],
 *   network: string[],
 *   process: string[],
 *   unclassified: string[]
 * }}
 */
function classifyRulesByDomain(rules) {
  const result = {
    denyRead: [],
    denyWrite: [],
    network: [],
    process: [],
    unclassified: [],
  };

  const readPaths = new Set();
  const writePaths = new Set();

  for (const entry of rules) {
    const ruleStr = typeof entry === "string" ? entry : entry.rule;
    const parsed = parsePermissionRule(ruleStr);

    if (!parsed) {
      result.unclassified.push(ruleStr);
      continue;
    }

    switch (parsed.action) {
      case "Read": {
        const cleaned = cleanGlobPath(parsed.target);
        if (!readPaths.has(cleaned)) {
          readPaths.add(cleaned);
          result.denyRead.push(cleaned);
        }
        break;
      }

      case "Edit":
      case "Write": {
        const cleaned = cleanGlobPath(parsed.target);
        if (!writePaths.has(cleaned)) {
          writePaths.add(cleaned);
          result.denyWrite.push(cleaned);
        }
        break;
      }

      case "Bash": {
        const cmd = parsed.command;
        const fullRule =
          parsed.command + (parsed.pattern ? " " + parsed.pattern : "");

        if (NETWORK_COMMANDS.has(cmd)) {
          result.network.push(fullRule);
        } else if (DESTRUCTIVE_COMMANDS.has(cmd)) {
          result.process.push(fullRule);
        } else if (cmd === "git" && /push\s+--force/.test(parsed.pattern)) {
          result.network.push(fullRule);
        } else if (cmd === "npm" && /publish/.test(parsed.pattern)) {
          result.network.push(fullRule);
        } else {
          // Other bash commands (e.g., cat */.ssh/*) — classify by intent
          result.process.push(fullRule);
        }
        break;
      }

      default:
        result.unclassified.push(ruleStr);
        break;
    }
  }

  return result;
}

// --- YAML Generation ---

/**
 * Merge two classification results (for strict mode: deny + ask).
 * Deduplicates paths/commands.
 * @param {ReturnType<typeof classifyRulesByDomain>} base
 * @param {ReturnType<typeof classifyRulesByDomain>} extra
 * @returns {ReturnType<typeof classifyRulesByDomain>}
 */
function mergeClassified(base, extra) {
  const readSet = new Set(base.denyRead);
  const writeSet = new Set(base.denyWrite);
  const networkSet = new Set(base.network);
  const processSet = new Set(base.process);

  for (const p of extra.denyRead) {
    if (!readSet.has(p)) {
      readSet.add(p);
      base.denyRead.push(p);
    }
  }
  for (const p of extra.denyWrite) {
    if (!writeSet.has(p)) {
      writeSet.add(p);
      base.denyWrite.push(p);
    }
  }
  for (const p of extra.network) {
    if (!networkSet.has(p)) {
      networkSet.add(p);
      base.network.push(p);
    }
  }
  for (const p of extra.process) {
    if (!processSet.has(p)) {
      processSet.add(p);
      base.process.push(p);
    }
  }

  return base;
}

/**
 * Generate OpenShell Policy Schema v1 YAML from permissions-spec.json.
 * Uses template literals — no js-yaml dependency.
 * @param {Object} spec - Full permissions-spec.json object
 * @param {{ profile?: string }} [options]
 * @returns {string} YAML policy file content
 */
function generatePolicyYaml(spec, options = {}) {
  const profile = options.profile || "standard";

  if (!spec || !spec.permissions) {
    throw new Error("Invalid spec: missing permissions field");
  }

  const classified = classifyRulesByDomain(spec.permissions.deny || []);

  // In strict mode, also treat ask rules as deny
  if (profile === "strict" && spec.permissions.ask) {
    const askClassified = classifyRulesByDomain(spec.permissions.ask);
    mergeClassified(classified, askClassified);
  }

  const lines = [];
  lines.push("# Auto-generated by Shield Harness tier-policy-gen");
  lines.push("# Source: permissions-spec.json v" + (spec.version || "1.0.0"));
  lines.push("# Profile: " + profile);
  lines.push("# Generated: " + new Date().toISOString());
  lines.push("#");
  lines.push("# Usage:");
  lines.push("#   openshell sandbox create --policy <this-file> -- claude");
  lines.push("#");
  lines.push("# Static policies require sandbox recreation to change.");
  lines.push(
    "# Network policies can be hot-reloaded: openshell policy set <name> --policy <file> --wait",
  );
  lines.push("");
  lines.push("version: 1");

  // --- Filesystem policy (static) ---
  lines.push("");
  lines.push("# --- Static (locked at sandbox creation) ---");
  lines.push("");
  lines.push("filesystem_policy:");
  lines.push("  include_workdir: true");

  if (classified.denyRead.length > 0) {
    lines.push("  deny_read:");
    for (const p of classified.denyRead) {
      lines.push("    - " + p);
    }
  }

  if (classified.denyWrite.length > 0) {
    lines.push("  deny_write:");
    for (const p of classified.denyWrite) {
      lines.push("    - " + p);
    }
  }

  lines.push("  read_only:");
  lines.push("    - /usr");
  lines.push("    - /lib");
  lines.push("    - /etc");
  lines.push("  read_write:");
  lines.push("    - /sandbox");
  lines.push("    - /tmp");

  // --- Landlock ---
  lines.push("");
  lines.push("landlock:");
  lines.push("  compatibility: best_effort");

  // --- Process ---
  lines.push("");
  lines.push("process:");
  lines.push("  run_as_user: sandbox");
  lines.push("  run_as_group: sandbox");

  // --- Network policies (dynamic / hot-reloadable) ---
  lines.push("");
  lines.push("# --- Dynamic (hot-reloadable) ---");
  lines.push("");
  lines.push("network_policies:");

  // Default allowlist (matching openshell-default.yaml)
  lines.push("  anthropic_api:");
  lines.push("    name: anthropic-api");
  lines.push("    endpoints:");
  lines.push("      - host: api.anthropic.com");
  lines.push("        port: 443");
  lines.push("        access: full");
  lines.push("    binaries:");
  lines.push("      - path: /usr/local/bin/claude");
  lines.push("");
  lines.push("  github:");
  lines.push("    name: github");
  lines.push("    endpoints:");
  lines.push("      - host: github.com");
  lines.push("        port: 443");
  lines.push("        access: read-only");
  lines.push('      - host: "*.githubusercontent.com"');
  lines.push("        port: 443");
  lines.push("        access: read-only");
  lines.push("    binaries:");
  lines.push("      - path: /usr/bin/git");
  lines.push("");
  lines.push("  npm_registry:");
  lines.push("    name: npm-registry");
  lines.push("    endpoints:");
  lines.push("      - host: registry.npmjs.org");
  lines.push("        port: 443");
  lines.push("        access: read-only");
  lines.push("    binaries:");
  lines.push("      - path: /usr/bin/npm");
  lines.push("      - path: /usr/bin/node");

  // Append blocked network commands as comments for visibility
  if (classified.network.length > 0) {
    lines.push("");
    lines.push(
      "# Blocked network operations (from permissions-spec.json deny rules):",
    );
    for (const cmd of classified.network) {
      lines.push("#   - " + cmd);
    }
  }

  // Append blocked destructive commands as comments
  if (classified.process.length > 0) {
    lines.push("");
    lines.push(
      "# Blocked process operations (from permissions-spec.json deny rules):",
    );
    for (const cmd of classified.process) {
      lines.push("#   - " + cmd);
    }
  }

  return lines.join("\n") + "\n";
}

module.exports = {
  parsePermissionRule,
  classifyRulesByDomain,
  generatePolicyYaml,
  // Internal helpers exported for testing
  cleanGlobPath,
  mergeClassified,
};
