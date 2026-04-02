#!/usr/bin/env node
// sh-precompact.js — Pre-compaction state backup & context injection
// Spec: DETAILED_DESIGN.md §5.8
// Event: PreCompact
// Matcher: auto
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  readSession,
  appendEvidence,
  SESSION_FILE,
  SH_DIR,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-precompact";
const BACKUP_DIR = path.join(SH_DIR, "compact-backup");

// ---------------------------------------------------------------------------
// Backup Logic
// ---------------------------------------------------------------------------

/**
 * Copy session.json to compact-backup directory.
 */
function backupSessionState() {
  if (!fs.existsSync(BACKUP_DIR)) {
    fs.mkdirSync(BACKUP_DIR, { recursive: true });
  }

  // Backup session.json
  if (fs.existsSync(SESSION_FILE)) {
    fs.copyFileSync(SESSION_FILE, path.join(BACKUP_DIR, "session.json"));
  }
}

/**
 * Build context output for injection into compacted conversation.
 * @param {Object} session - Current session state
 * @returns {string}
 */
function buildContextOutput(session) {
  const parts = [];

  parts.push("=== Shield Harness Pre-Compaction Snapshot ===");

  // Session state
  if (session.session_start) {
    parts.push(`Session started: ${session.session_start}`);
  }
  if (session.token_budget) {
    parts.push(
      `Token budget used: ${session.token_budget.used || 0}/${session.token_budget.session_limit || "?"}`,
    );
  }

  // Key project files reminder
  parts.push("");
  parts.push("Key files:");
  parts.push("  - CLAUDE.md (project instructions)");
  parts.push("  - .claude/rules/ (security & coding rules)");
  parts.push("  - tasks/backlog.yaml (task SoT — read-only)");
  parts.push("  - docs/DETAILED_DESIGN.md (hook specifications)");

  parts.push("=========================================");

  return parts.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const session = readSession();

  // Backup state before compaction
  backupSessionState();

  // Record evidence
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "PreCompact",
      decision: "allow",
      backup_created: true,
      session_id: input.sessionId,
    });
  } catch {
    // Evidence failure is non-blocking
  }

  // Inject context
  const context = buildContextOutput(session);
  allow(context);
} catch (_err) {
  // Operational hook — fail-open
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  backupSessionState,
  buildContextOutput,
  BACKUP_DIR,
};
