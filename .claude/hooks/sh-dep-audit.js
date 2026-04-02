#!/usr/bin/env node
// sh-dep-audit.js — Dependency package install detection + security scan advisory
// Spec: DETAILED_DESIGN.md §4.3
// Hook event: PostToolUse
// Matcher: Bash
// Target response time: < 30ms
"use strict";

const { readHookInput, allow, appendEvidence } = require("./lib/sh-utils");

// ---------------------------------------------------------------------------
// Constants / Patterns
// ---------------------------------------------------------------------------

const HOOK_NAME = "sh-dep-audit";

// Package manager install detection patterns (FR-11-04)
const INSTALL_PATTERNS = [
  {
    regex: /npm (install|i|add|ci)\b/,
    manager: "npm",
    scan: "npm audit --json",
  },
  { regex: /pnpm (add|install)\b/, manager: "pnpm", scan: "pnpm audit --json" },
  { regex: /yarn add\b/, manager: "yarn", scan: "yarn audit --json" },
  { regex: /bun (add|install)\b/, manager: "bun", scan: "bun audit" },
  { regex: /pip3? install\b/, manager: "pip", scan: "pip-audit --format=json" },
  { regex: /cargo (add|install)\b/, manager: "cargo", scan: "cargo audit" },
  { regex: /go get\b/, manager: "go", scan: "govulncheck ./..." },
];

// ---------------------------------------------------------------------------
// Helper Functions
// ---------------------------------------------------------------------------

/**
 * Detect package install command in a string.
 * @param {string} command
 * @returns {{ manager: string, scan: string } | null}
 */
function detectInstall(command) {
  if (!command) return null;
  for (const pattern of INSTALL_PATTERNS) {
    if (pattern.regex.test(command)) {
      return { manager: pattern.manager, scan: pattern.scan };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const { toolInput, sessionId } = input;
  const command = (toolInput.command || "").trim();

  // Detect install command
  const match = detectInstall(command);

  if (!match) {
    allow();
    // Unreachable after allow(), but explicit return for clarity
    return;
  }

  // Record evidence (non-blocking)
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "PostToolUse",
      tool: "Bash",
      decision: "allow",
      reason: `${match.manager} install detected`,
      command: command.length > 120 ? command.slice(0, 120) + "..." : command,
      session_id: sessionId,
    });
  } catch (_) {
    // Evidence failure is non-blocking
  }

  // Advisory: recommend security scan
  allow(
    `[${HOOK_NAME}] ${match.manager} によるパッケージインストールを検出しました。` +
      `セキュリティスキャンを推奨します: \`${match.scan}\``,
  );
} catch (_err) {
  // Operational hook — on error, allow through.
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  INSTALL_PATTERNS,
  detectInstall,
};
