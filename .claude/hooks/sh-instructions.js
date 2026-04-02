#!/usr/bin/env node
// sh-instructions.js — Rule file integrity monitoring
// Spec: DETAILED_DESIGN.md §5.8
// Event: InstructionsLoaded
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  sha256,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-instructions";
const CLAUDE_MD = "CLAUDE.md";
const RULES_DIR = path.join(".claude", "rules");
const HASHES_FILE = path.join(".claude", "logs", "instructions-hashes.json");

// ---------------------------------------------------------------------------
// Hash Collection
// ---------------------------------------------------------------------------

/**
 * Compute SHA-256 hash for a file.
 * @param {string} filePath
 * @returns {string|null}
 */
function hashFile(filePath) {
  try {
    return sha256(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Collect current hashes for CLAUDE.md and all rule files.
 * @returns {Object} { filePath: hash }
 */
function collectCurrentHashes() {
  const hashes = {};

  // CLAUDE.md
  if (fs.existsSync(CLAUDE_MD)) {
    hashes[CLAUDE_MD] = hashFile(CLAUDE_MD);
  }

  // .claude/rules/*.md
  if (fs.existsSync(RULES_DIR)) {
    try {
      const files = fs.readdirSync(RULES_DIR).filter((f) => f.endsWith(".md"));
      for (const f of files) {
        const fp = path.join(RULES_DIR, f);
        hashes[fp] = hashFile(fp);
      }
    } catch {
      // Directory read failure — non-critical
    }
  }

  return hashes;
}

/**
 * Load stored hashes from disk.
 * @returns {Object|null} null if no baseline exists
 */
function loadStoredHashes() {
  try {
    if (!fs.existsSync(HASHES_FILE)) return null;
    return JSON.parse(fs.readFileSync(HASHES_FILE, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Save hashes to disk.
 * @param {Object} hashes
 */
function saveHashes(hashes) {
  const dir = path.dirname(HASHES_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(HASHES_FILE, JSON.stringify(hashes, null, 2));
}

/**
 * Detect changes between stored and current hashes.
 * @param {Object} stored
 * @param {Object} current
 * @returns {{ added: string[], modified: string[], removed: string[] }}
 */
function detectChanges(stored, current) {
  const added = [];
  const modified = [];
  const removed = [];

  // Check current against stored
  for (const [file, hash] of Object.entries(current)) {
    if (!(file in stored)) {
      added.push(file);
    } else if (stored[file] !== hash) {
      modified.push(file);
    }
  }

  // Check for removed files
  for (const file of Object.keys(stored)) {
    if (!(file in current)) {
      removed.push(file);
    }
  }

  return { added, modified, removed };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const currentHashes = collectCurrentHashes();
  const storedHashes = loadStoredHashes();

  // First run: save baseline, no warning
  if (!storedHashes) {
    saveHashes(currentHashes);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "InstructionsLoaded",
        decision: "allow",
        action: "baseline_recorded",
        file_count: Object.keys(currentHashes).length,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(
      `[${HOOK_NAME}] Baseline recorded: ${Object.keys(currentHashes).length} files`,
    );
    return;
  }

  // Detect changes
  const changes = detectChanges(storedHashes, currentHashes);
  const hasChanges =
    changes.added.length > 0 ||
    changes.modified.length > 0 ||
    changes.removed.length > 0;

  // Update stored hashes
  saveHashes(currentHashes);

  if (hasChanges) {
    // Build warning message
    const warnings = ["[RULE FILE CHANGE DETECTED]"];

    if (changes.added.length > 0) {
      warnings.push(`  Added: ${changes.added.join(", ")}`);
    }
    if (changes.modified.length > 0) {
      warnings.push(`  Modified: ${changes.modified.join(", ")}`);
    }
    if (changes.removed.length > 0) {
      warnings.push(`  Removed: ${changes.removed.join(", ")}`);
    }

    warnings.push("Re-read these files to ensure instructions are current.");

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "InstructionsLoaded",
        decision: "allow",
        action: "changes_detected",
        changes,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(warnings.join("\n"));
    return;
  }

  // No changes
  allow();
} catch (_err) {
  // Operational hook — fail-open
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  hashFile,
  collectCurrentHashes,
  loadStoredHashes,
  saveHashes,
  detectChanges,
};
