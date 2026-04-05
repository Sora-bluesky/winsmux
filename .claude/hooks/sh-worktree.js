#!/usr/bin/env node
// sh-worktree.js — Worktree security propagation & evidence merge
// Spec: DETAILED_DESIGN.md §5.8
// Events: WorktreeCreate, WorktreeRemove
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const {
  readHookInput,
  allow,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-worktree";
const WORKTREE_ROOT = ".worktrees";

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

function getHookEventName(input) {
  return (
    input.hook_event_name ||
    input.hookEventName ||
    input.hookType ||
    ""
  );
}

function getSessionId(input) {
  return input.session_id || input.sessionId || "";
}

function resolveProjectRoot(input) {
  const cwd = typeof input.cwd === "string" && input.cwd.trim() ? input.cwd : process.cwd();
  return path.resolve(cwd);
}

function sanitizeWorktreeName(name) {
  return String(name || "")
    .trim()
    .replace(/[<>:"/\\|?*\x00-\x1f]/g, "-")
    .replace(/\s+/g, "-");
}

function resolveRequestedWorktreePath(input, projectRoot) {
  const toolInput = input.tool_input || input.toolInput || {};
  const explicitPath =
    input.worktree_path ||
    input.path ||
    toolInput.worktree_path ||
    toolInput.path ||
    "";

  if (typeof explicitPath === "string" && explicitPath.trim()) {
    return path.isAbsolute(explicitPath)
      ? path.resolve(explicitPath)
      : path.resolve(projectRoot, explicitPath);
  }

  const safeName = sanitizeWorktreeName(input.name);
  if (!safeName) {
    throw new Error("WorktreeCreate hook requires a non-empty name.");
  }

  return path.join(projectRoot, WORKTREE_ROOT, safeName);
}

function ensurePathWithinRoot(targetPath, rootPath) {
  const resolvedTarget = path.resolve(targetPath);
  const resolvedRoot = path.resolve(rootPath);
  const relative = path.relative(resolvedRoot, resolvedTarget);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function runGit(projectRoot, args) {
  try {
    return execFileSync("git", ["-C", projectRoot, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch (error) {
    const stderr =
      typeof error.stderr === "string" && error.stderr.trim()
        ? error.stderr.trim()
        : "";
    const stdout =
      typeof error.stdout === "string" && error.stdout.trim()
        ? error.stdout.trim()
        : "";
    const detail = stderr || stdout || error.message;
    throw new Error(`git ${args.join(" ")} failed: ${detail}`);
  }
}

function createWorktree(projectRoot, worktreePath) {
  const worktreeRoot = path.join(projectRoot, WORKTREE_ROOT);
  if (!ensurePathWithinRoot(worktreePath, worktreeRoot)) {
    throw new Error(`Refusing to create worktree outside ${worktreeRoot}: ${worktreePath}`);
  }

  if (fs.existsSync(worktreePath)) {
    throw new Error(`Worktree path already exists: ${worktreePath}`);
  }

  fs.mkdirSync(path.dirname(worktreePath), { recursive: true });
  runGit(projectRoot, ["worktree", "add", "--detach", worktreePath, "HEAD"]);
  return path.resolve(worktreePath);
}

function removeWorktree(projectRoot, worktreePath) {
  const worktreeRoot = path.join(projectRoot, WORKTREE_ROOT);
  if (!ensurePathWithinRoot(worktreePath, worktreeRoot)) {
    throw new Error(`Refusing to remove worktree outside ${worktreeRoot}: ${worktreePath}`);
  }

  if (!fs.existsSync(worktreePath)) {
    return false;
  }

  try {
    runGit(projectRoot, ["worktree", "remove", "--force", worktreePath]);
  } catch (error) {
    fs.rmSync(worktreePath, { recursive: true, force: true });
    return true;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const toolName = input.tool_name || input.toolName || "";
  const toolInput = input.tool_input || input.toolInput || {};
  const sessionId = input.session_id || input.sessionId || "";
  void toolName;
  const hookType = getHookEventName(input);
  const projectRoot = resolveProjectRoot(input);

  if (hookType === "WorktreeCreate") {
    const worktreePath = createWorktree(
      projectRoot,
      resolveRequestedWorktreePath(input, projectRoot),
    );
    const filesCopied = propagateConfig(worktreePath);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "WorktreeCreate",
        decision: "allow",
        worktree_path: worktreePath,
        files_copied: filesCopied,
        session_id: sessionId || getSessionId(input),
      });
    } catch {
      // Non-blocking
    }

    process.stdout.write(`${worktreePath}\n`);
    process.exit(0);
  }

  if (hookType === "WorktreeRemove") {
    const worktreePath =
      input.worktree_path ||
      input.path ||
      toolInput.worktree_path ||
      toolInput.path ||
      "";

    if (!worktreePath) {
      process.exit(0);
    }

    const resolvedWorktreePath = path.resolve(worktreePath);
    const entriesMerged = mergeEvidence(resolvedWorktreePath);
    removeWorktree(projectRoot, resolvedWorktreePath);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "WorktreeRemove",
        decision: "allow",
        worktree_path: resolvedWorktreePath,
        entries_merged: entriesMerged,
        session_id: sessionId || getSessionId(input),
      });
    } catch {
      // Non-blocking
    }

    process.exit(0);
  }

  allow();
} catch (err) {
  process.stderr.write(`[${HOOK_NAME}] Hook error: ${err.message}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  COPY_TARGETS,
  COPY_DIRS,
  propagateConfig,
  mergeEvidence,
  sanitizeWorktreeName,
  resolveRequestedWorktreePath,
  createWorktree,
  removeWorktree,
  copyFileToWorktree,
  copyDirToWorktree,
};
