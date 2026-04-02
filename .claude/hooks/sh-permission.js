#!/usr/bin/env node
// sh-permission.js — 4-category tool governance (Tier 2)
// Spec: DETAILED_DESIGN.md §3.1
// Hook event: PreToolUse
// Matcher: Bash|Edit|Write|Read|WebFetch|MCP
// Target response time: < 50ms
"use strict";

const { readHookInput, allow, deny } = require("./lib/sh-utils");

// ---------------------------------------------------------------------------
// Category Constants
// ---------------------------------------------------------------------------

const CATEGORY = {
  READONLY: 1,
  AGENT_SPAWN: 2,
  EXECUTION: 3,
  WRITE: 4,
};

// ---------------------------------------------------------------------------
// READONLY_PATTERNS (Category 1 — auto-approve for Bash commands)
// Spec: §3.1 READONLY_PATTERNS
// ---------------------------------------------------------------------------

const READONLY_PATTERNS = [
  /^git\s+(status|diff|log|branch|show|blame|stash\s+list)\b/,
  /^(ls|dir|pwd|whoami|date|uname|cat|head|tail|wc|find|which|type|file)\b/,
  /^npm\s+(test|run|list|outdated|audit)\b/,
  /^(node|bun|python|python3)\s+--version\b/,
  /^(grep|rg|ag|awk)\s/,
  /^sed\s+[^-]/, // sed without flags (read-only pipe usage only)
];

// ---------------------------------------------------------------------------
// WRITE_PATTERNS (Category 4 — write operation detection for Bash commands)
// Spec: §3.1 WRITE_PATTERNS
// ---------------------------------------------------------------------------

const WRITE_PATTERNS = [
  /^(rm|del|rmdir|mkdir|mv|cp|chmod|chown)\b/,
  /^git\s+(push|commit|merge|rebase|reset|checkout|clean)\b/,
  /^npm\s+(install|publish|uninstall|update|link)\b/,
  /^pip3?\s+install\b/,
];

// ---------------------------------------------------------------------------
// Classification Logic
// ---------------------------------------------------------------------------

/**
 * Classify a tool invocation into one of 4 categories.
 *
 * @param {string} toolName - Claude Code tool name
 * @param {Object} toolInput - Tool input parameters
 * @returns {{ category: number, label: string }}
 */
function classify(toolName, toolInput) {
  // --- Category 1: Read-only tools (always auto-approve) ---
  if (
    toolName === "Read" ||
    toolName === "Grep" ||
    toolName === "Glob" ||
    toolName === "WebSearch"
  ) {
    return { category: CATEGORY.READONLY, label: "read-only tool" };
  }

  // --- Category 2: Agent spawn (delegate to SubagentStart hook) ---
  if (toolName === "Task" || toolName === "Agent") {
    return { category: CATEGORY.AGENT_SPAWN, label: "agent spawn" };
  }

  // --- Bash command classification (Categories 1, 3, or 4) ---
  if (toolName === "Bash") {
    const command = (toolInput.command || "").trim();

    // Check read-only patterns first (Category 1)
    for (const pattern of READONLY_PATTERNS) {
      if (pattern.test(command)) {
        return { category: CATEGORY.READONLY, label: "read-only command" };
      }
    }

    // Check write patterns (Category 4)
    for (const pattern of WRITE_PATTERNS) {
      if (pattern.test(command)) {
        return { category: CATEGORY.WRITE, label: "write command" };
      }
    }

    // Neither read-only nor write: Execution (Category 3)
    return { category: CATEGORY.EXECUTION, label: "execution command" };
  }

  // --- Category 4: Write tools ---
  if (toolName === "Edit" || toolName === "Write") {
    return { category: CATEGORY.WRITE, label: "file write" };
  }

  // --- Category 3: WebFetch ---
  if (toolName === "WebFetch") {
    return { category: CATEGORY.EXECUTION, label: "web fetch" };
  }

  // --- Category 3: MCP tools ---
  // Any tool not matched above is treated as MCP / unknown execution
  return { category: CATEGORY.EXECUTION, label: "MCP tool" };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const toolName = input.toolName;
  const toolInput = input.toolInput;

  const { category, label } = classify(toolName, toolInput);

  switch (category) {
    case CATEGORY.READONLY:
      // Category 1: auto-approve, no context needed
      allow();
      break;

    case CATEGORY.AGENT_SPAWN:
      // Category 2: allow here, SubagentStart hook handles governance
      allow();
      break;

    case CATEGORY.EXECUTION:
      // Category 3: allow with context for awareness
      allow(`[sh-permission] Category 3 (execution): ${label}`);
      break;

    case CATEGORY.WRITE:
      // Category 4: allow (protected path checks are gate.sh's responsibility)
      allow();
      break;

    default:
      // Unknown category — fail-close
      deny("Unknown category in sh-permission");
      break;
  }
} catch (err) {
  // fail-close: any uncaught error = deny
  process.stdout.write(
    JSON.stringify({
      reason: `Hook error (sh-permission): ${err.message}`,
    }),
  );
  process.exit(2);
}
