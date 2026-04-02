#!/usr/bin/env node
// sh-postcompact.js — Post-compaction state restoration & verification
// Spec: DETAILED_DESIGN.md §5.8
// Event: PostCompact
// Matcher: auto
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  sha256,
  readSession,
  writeSession,
  appendEvidence,
  SH_DIR,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-postcompact";
const BACKUP_DIR = path.join(SH_DIR, "compact-backup");
const CLAUDE_MD = "CLAUDE.md";

// ---------------------------------------------------------------------------
// Restore Logic
// ---------------------------------------------------------------------------

/**
 * Restore session state from compact-backup.
 * Merges backup into current session (backup values take precedence for key fields).
 * @returns {Object} restored session
 */
function restoreSessionState() {
  const backupFile = path.join(BACKUP_DIR, "session.json");
  const currentSession = readSession();

  if (!fs.existsSync(backupFile)) {
    return currentSession;
  }

  try {
    const backup = JSON.parse(fs.readFileSync(backupFile, "utf8"));
    // Merge: preserve backup's critical fields
    return {
      ...currentSession,
      ...backup,
      // Always update these from current state
      last_compact: new Date().toISOString(),
    };
  } catch {
    return currentSession;
  }
}

/**
 * Verify CLAUDE.md integrity after compaction.
 * @param {Object} session - Session with baseline hash
 * @returns {{ valid: boolean, message: string }}
 */
function verifyCLAUDEMD(session) {
  if (!fs.existsSync(CLAUDE_MD)) {
    return { valid: false, message: "CLAUDE.md not found" };
  }

  const currentHash = sha256(fs.readFileSync(CLAUDE_MD, "utf8"));

  // If we don't have a baseline, just record it
  if (!session.claude_md_hash) {
    return {
      valid: true,
      message: `CLAUDE.md hash recorded: ${currentHash.slice(0, 12)}...`,
    };
  }

  if (currentHash !== session.claude_md_hash) {
    return {
      valid: false,
      message: `WARNING: CLAUDE.md has been modified since session start! Expected: ${session.claude_md_hash.slice(0, 12)}..., Got: ${currentHash.slice(0, 12)}...`,
    };
  }

  return { valid: true, message: "CLAUDE.md integrity verified" };
}

/**
 * Build restoration context for systemMessage injection.
 * @param {Object} session
 * @param {{ valid: boolean, message: string }} integrityCheck
 * @returns {string}
 */
function buildRestorationContext(session, integrityCheck) {
  const parts = [];

  parts.push("=== Shield Harness Post-Compaction Restore ===");

  // Integrity check result
  if (!integrityCheck.valid) {
    parts.push(`⚠ ${integrityCheck.message}`);
  } else {
    parts.push(`✓ ${integrityCheck.message}`);
  }

  // Session state
  if (session.session_start) {
    parts.push(`Session started: ${session.session_start}`);
  }
  if (session.token_budget) {
    parts.push(
      `Token budget: ${session.token_budget.used || 0}/${session.token_budget.session_limit || "?"}`,
    );
  }

  // Key reminders
  parts.push("");
  parts.push("Key files to re-read if needed:");
  parts.push("  - CLAUDE.md (project instructions)");
  parts.push("  - .claude/rules/ (security & coding rules)");
  parts.push("  - tasks/backlog.yaml (task SoT)");
  parts.push("  - docs/DETAILED_DESIGN.md (hook specifications)");
  parts.push("==========================================");

  return parts.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();

  // Restore session state from backup
  const session = restoreSessionState();

  // Verify CLAUDE.md integrity
  const integrityCheck = verifyCLAUDEMD(session);

  // Update and save session
  writeSession(session);

  // Record evidence
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "PostCompact",
      decision: "allow",
      integrity_valid: integrityCheck.valid,
      integrity_message: integrityCheck.message,
      session_id: input.sessionId,
    });
  } catch {
    // Evidence failure is non-blocking
  }

  // Inject restoration context
  const context = buildRestorationContext(session, integrityCheck);
  allow(context);
} catch (_err) {
  // Operational hook — fail-open
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  restoreSessionState,
  verifyCLAUDEMD,
  buildRestorationContext,
  BACKUP_DIR,
};
