#!/usr/bin/env node
// sh-quiet-inject.js — Auto-inject quiet flags to save tokens
// Spec: DETAILED_DESIGN.md §3.5
// Hook event: PreToolUse
// Matcher: Bash
// Target response time: < 10ms
"use strict";

const { readHookInput, allow, allowWithUpdate } = require("./lib/sh-utils");

// ---------------------------------------------------------------------------
// Quiet Injection Rules
// ---------------------------------------------------------------------------

/**
 * Each rule: { pattern, flag, verboseCheck }
 * - pattern: RegExp matching the command (e.g., /\bgit\s+clone\b/)
 * - flag: The quiet flag to inject (e.g., "-q", "--silent")
 * - verboseCheck: RegExp matching verbose flags that should prevent injection
 */
const QUIET_RULES = [
  // Git commands: inject -q unless -v/--verbose present
  {
    pattern: /\bgit\s+clone\b/,
    flag: "-q",
    verboseCheck: /\s-v\b|\s--verbose\b/,
  },
  {
    pattern: /\bgit\s+fetch\b/,
    flag: "-q",
    verboseCheck: /\s-v\b|\s--verbose\b/,
  },
  {
    pattern: /\bgit\s+pull\b/,
    flag: "-q",
    verboseCheck: /\s-v\b|\s--verbose\b/,
  },
  {
    pattern: /\bgit\s+push\b/,
    flag: "-q",
    verboseCheck: /\s-v\b|\s--verbose\b/,
  },

  // npm commands: inject --silent unless --verbose present
  {
    pattern: /\bnpm\s+install\b/,
    flag: "--silent",
    verboseCheck: /\s--verbose\b/,
  },
  {
    pattern: /\bnpm\s+ci\b/,
    flag: "--silent",
    verboseCheck: /\s--verbose\b/,
  },

  // cargo build: inject -q unless --verbose/-v present
  {
    pattern: /\bcargo\s+build\b/,
    flag: "-q",
    verboseCheck: /\s--verbose\b|\s-v\b/,
  },

  // pip install: inject -q unless --verbose/-v present
  {
    pattern: /\bpip3?\s+install\b/,
    flag: "-q",
    verboseCheck: /\s--verbose\b|\s-v\b/,
  },

  // docker pull: inject -q unless --verbose/-v present
  {
    pattern: /\bdocker\s+pull\b/,
    flag: "-q",
    verboseCheck: /\s--verbose\b|\s-v\b/,
  },
];

// ---------------------------------------------------------------------------
// Injection Logic
// ---------------------------------------------------------------------------

/**
 * Attempt to inject a quiet flag into a command string.
 *
 * Finds the matching subcommand (e.g., "git clone") and inserts the flag
 * immediately after it.
 *
 * @param {string} command - The original command string.
 * @returns {{ modified: boolean, command: string }}
 */
function injectQuietFlag(command) {
  for (const rule of QUIET_RULES) {
    const match = command.match(rule.pattern);
    if (!match) continue;

    // Skip if already has quiet flag injected
    // Check for common quiet flags in the command
    if (/\s-q\b|\s--quiet\b|\s--silent\b/.test(command)) continue;

    // Skip if verbose flag is present
    if (rule.verboseCheck.test(command)) continue;

    // Insert flag right after the matched subcommand
    const insertPos = match.index + match[0].length;
    const modified =
      command.slice(0, insertPos) + " " + rule.flag + command.slice(insertPos);

    return { modified: true, command: modified };
  }

  return { modified: false, command };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const command = (input.toolInput.command || "").trim();

  // Empty command — nothing to inject
  if (!command) {
    allow();
    return;
  }

  const result = injectQuietFlag(command);

  if (result.modified) {
    allowWithUpdate({ command: result.command });
  } else {
    allow();
  }
} catch (_err) {
  // Operational hook, not security — on error, just allow.
  // Worst case: extra output tokens, not a security breach.
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  QUIET_RULES,
  injectQuietFlag,
};
