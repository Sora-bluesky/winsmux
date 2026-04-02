#!/usr/bin/env node
// sh-worktree.js — Worktree security propagation & evidence merge
// Spec: DETAILED_DESIGN.md §5.8
// Events: WorktreeCreate, WorktreeRemove
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  deny,
  appendEvidence,
  EVIDENCE_FILE,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-worktree";

// Files/directories to copy to worktree
const COPY_TARGETS = [
  { src: path.join(".claude", "settings.json"), type: "file" },
  {
    src: path.join(".claude", "patterns", "injection-patterns.json"),
    type: "file",
  },
];

// Directories to recursively copy
const COPY_DIRS = [
  {
    src: path.join(".claude", "hooks"),
    filter: (f) => f.startsWith("sh-") && f.endsWith(".js"),
  },
  {
    src: path.join(".claude", "hooks", "lib"),
    filter: (f) => f === "sh-utils.js",
  },
  { src: path.join(".claude", "rules"), filter: (f) => f.endsWith(".md") },
];

// ---------------------------------------------------------------------------
// Copy Helpers
// ---------------------------------------------------------------------------

/**
 * Copy a single file to the worktree, preserving directory structure.
 * @param {string} srcFile - Relative path from project root
 * @param {string} worktreePath - Absolute path to worktree root
 */
function copyFileToWorktree(srcFile, worktreePath) {
  if (!fs.existsSync(srcFile)) return;

  const destFile = path.join(worktreePath, srcFile);
  const destDir = path.dirname(destFile);

  if (!fs.existsSync(destDir)) {
    fs.mkdirSync(destDir, { recursive: true });
  }

  fs.copyFileSync(srcFile, destFile);
}

/**
 * Copy filtered files from a directory to worktree.
 * @param {string} srcDir - Relative path from project root
 * @param {Function} filter - File name filter function
 * @param {string} worktreePath - Absolute path to worktree root
 */
function copyDirToWorktree(srcDir, filter, worktreePath) {
  if (!fs.existsSync(srcDir)) return;

  const files = fs.readdirSync(srcDir).filter(filter);
  for (const f of files) {
    copyFileToWorktree(path.join(srcDir, f), worktreePath);
  }
}

/**
 * Propagate Shield Harness security config to a worktree.
 * @param {string} worktreePath
 * @returns {number} Number of files copied
 */
function propagateConfig(worktreePath) {
  let count = 0;

  // Copy individual files
  for (const { src } of COPY_TARGETS) {
    if (fs.existsSync(src)) {
      copyFileToWorktree(src, worktreePath);
      count++;
    }
  }

  // Copy filtered directories
  for (const { src, filter } of COPY_DIRS) {
    if (fs.existsSync(src)) {
      const files = fs.readdirSync(src).filter(filter);
      for (const f of files) {
        copyFileToWorktree(path.join(src, f), worktreePath);
        count++;
      }
    }
  }

  return count;
}

/**
 * Merge worktree evidence ledger into main ledger.
 * @param {string} worktreePath
 * @returns {number} Number of entries merged
 */
function mergeEvidence(worktreePath) {
  const worktreeLedger = path.join(
    worktreePath,
    ".shield-harness",
    "logs",
    "evidence-ledger.jsonl",
  );

  if (!fs.existsSync(worktreeLedger)) return 0;

  const content = fs.readFileSync(worktreeLedger, "utf8").trim();
  if (!content) return 0;

  const lines = content.split("\n");
  let merged = 0;

  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      // Mark as merged from worktree
      entry.source_worktree = worktreePath;
      appendEvidence(entry);
      merged++;
    } catch {
      // Skip malformed entries
    }
  }

  return merged;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const { hookType } = input;
  const worktreePath =
    input.toolInput.worktree_path || input.toolInput.path || "";

  if (!worktreePath) {
    allow();
    return;
  }

  if (hookType === "WorktreeCreate") {
    // Propagate security config to new worktree
    const filesCopied = propagateConfig(worktreePath);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "WorktreeCreate",
        decision: "allow",
        worktree_path: worktreePath,
        files_copied: filesCopied,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(
      `[${HOOK_NAME}] Shield Harness 設定を worktree にコピーしました (${filesCopied} files)`,
    );
    return;
  }

  if (hookType === "WorktreeRemove") {
    // Merge evidence from worktree
    const entriesMerged = mergeEvidence(worktreePath);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "WorktreeRemove",
        decision: "allow",
        worktree_path: worktreePath,
        entries_merged: entriesMerged,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(
      `[${HOOK_NAME}] Worktree 証跡をマージしました (${entriesMerged} entries)`,
    );
    return;
  }

  // Unknown event type — allow passthrough
  allow();
} catch (err) {
  // SECURITY hook — fail-close
  process.stdout.write(
    JSON.stringify({
      reason: `[${HOOK_NAME}] Hook error (fail-close): ${err.message}`,
    }),
  );
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  COPY_TARGETS,
  COPY_DIRS,
  propagateConfig,
  mergeEvidence,
  copyFileToWorktree,
  copyDirToWorktree,
};
