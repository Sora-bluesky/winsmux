#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

const { allow, readHookInput } = require("./lib/sh-utils");

const HOOK_ROOT = path.resolve(__dirname, "..", "..");
const PROJECT_ROOT = resolveProjectRoot();
const WINSMUX_DIR = path.join(PROJECT_ROOT, ".winsmux");
const EVENTS_PATH = path.join(WINSMUX_DIR, "events.jsonl");
const CURSOR_FILE_PREFIX = "monitor-cursor";
const CURSOR_PATH = path.join(WINSMUX_DIR, `${CURSOR_FILE_PREFIX}.txt`);
const ALERT_EVENTS = new Set([
  "pane.completed",
  "pane.crashed",
  "pane.approval_waiting",
]);

function findWinsmuxDir(startDir) {
  if (!startDir) {
    return null;
  }

  let currentDir = path.resolve(startDir);
  while (true) {
    const candidateDir = path.join(currentDir, ".winsmux");
    if (fs.existsSync(candidateDir) && fs.statSync(candidateDir).isDirectory()) {
      return candidateDir;
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      return null;
    }

    currentDir = parentDir;
  }
}

function parseManifestProjectDir(manifestContent) {
  if (typeof manifestContent !== "string" || manifestContent.trim() === "") {
    return null;
  }

  const match = manifestContent.match(/^\s{2}project_dir:\s*['"]?(.*?)['"]?\s*$/m);
  if (!match) {
    return null;
  }

  const projectDir = String(match[1] || "").trim();
  return projectDir || null;
}

function readProjectDirFromManifest(manifestPath) {
  try {
    if (!fs.existsSync(manifestPath)) {
      return null;
    }

    return parseManifestProjectDir(fs.readFileSync(manifestPath, "utf8"));
  } catch {
    return null;
  }
}

function resolveProjectRootFromGit(startDir) {
  try {
    const commonDirRaw = childProcess
      .execFileSync("git", ["rev-parse", "--git-common-dir"], {
        cwd: startDir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      })
      .trim();

    if (!commonDirRaw) {
      return null;
    }

    const commonDir = path.isAbsolute(commonDirRaw)
      ? commonDirRaw
      : path.resolve(startDir, commonDirRaw);
    return path.dirname(commonDir);
  } catch {
    return null;
  }
}

function resolveProjectRoot() {
  const starts = [process.cwd(), HOOK_ROOT];
  const visitedWinsmuxDirs = new Set();

  for (const startDir of starts) {
    const winsmuxDir = findWinsmuxDir(startDir);
    if (!winsmuxDir || visitedWinsmuxDirs.has(winsmuxDir)) {
      continue;
    }

    visitedWinsmuxDirs.add(winsmuxDir);
    const manifestProjectDir = readProjectDirFromManifest(path.join(winsmuxDir, "manifest.yaml"));
    if (manifestProjectDir) {
      return manifestProjectDir;
    }

    return path.dirname(winsmuxDir);
  }

  for (const startDir of starts) {
    const gitProjectRoot = resolveProjectRootFromGit(startDir);
    if (gitProjectRoot) {
      return gitProjectRoot;
    }
  }

  return HOOK_ROOT;
}

function sanitizeCursorScope(value) {
  const normalized = String(value || "")
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return normalized || null;
}

function resolveCursorScope(input = {}) {
  if (input && typeof input === "object") {
    const sessionId = sanitizeCursorScope(input.session_id || input.sessionId);
    if (sessionId) {
      return sessionId;
    }
  }

  if (Number.isInteger(process.ppid) && process.ppid > 0) {
    return `ppid-${process.ppid}`;
  }

  return `pid-${process.pid}`;
}

function getCursorPath(input = {}, winsmuxDir = WINSMUX_DIR) {
  return path.join(
    winsmuxDir,
    `${CURSOR_FILE_PREFIX}-${resolveCursorScope(input)}.txt`,
  );
}

function readCursor(cursorPath = CURSOR_PATH) {
  try {
    if (!fs.existsSync(cursorPath)) {
      return 0;
    }

    const raw = fs.readFileSync(cursorPath, "utf8").trim();
    if (!raw) {
      return 0;
    }

    const parsed = Number.parseInt(raw, 10);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
  } catch {
    return 0;
  }
}

function writeCursor(cursor, cursorPath = CURSOR_PATH) {
  fs.mkdirSync(path.dirname(cursorPath), { recursive: true });
  fs.writeFileSync(cursorPath, `${cursor}\n`, "utf8");
}

function readNewEventChunk(eventsPath = EVENTS_PATH, cursorPath = CURSOR_PATH) {
  if (!fs.existsSync(eventsPath)) {
    return { cursor: 0, content: "" };
  }

  const stats = fs.statSync(eventsPath);
  const fileSize = stats.size;
  const startOffset = Math.min(readCursor(cursorPath), fileSize);
  if (fileSize === startOffset) {
    return { cursor: fileSize, content: "" };
  }

  const length = fileSize - startOffset;
  const buffer = Buffer.allocUnsafe(length);
  const fd = fs.openSync(eventsPath, "r");

  try {
    fs.readSync(fd, buffer, 0, length, startOffset);
  } finally {
    fs.closeSync(fd);
  }

  return {
    cursor: fileSize,
    content: buffer.toString("utf8"),
  };
}

function parseEventLines(content) {
  if (typeof content !== "string" || content.trim() === "") {
    return [];
  }

  const events = [];
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    try {
      events.push(JSON.parse(trimmed));
    } catch {
      // Ignore malformed lines. The hook must never block tool execution.
    }
  }

  return events;
}

function isAlertEvent(record) {
  if (!record || typeof record !== "object") {
    return false;
  }

  return ALERT_EVENTS.has(String(record.event || "").trim());
}

function formatAlert(record) {
  const eventName = String(record.event || "").trim();
  const label = String(record.label || record.pane_id || "unknown-pane").trim() || "unknown-pane";

  switch (eventName) {
    case "pane.completed":
      return `[PANE ALERT] ${label} completed`;
    case "pane.crashed":
      return `[PANE ALERT] ${label} crashed`;
    case "pane.approval_waiting":
      return `[PANE ALERT] ${label} awaiting approval`;
    default:
      return "";
  }
}

function collectAlerts(content) {
  return parseEventLines(content)
    .filter((record) => isAlertEvent(record))
    .map((record) => formatAlert(record))
    .filter(Boolean);
}

function main() {
  try {
    const input = readHookInput();
    const cursorPath = getCursorPath(input);

    const chunk = readNewEventChunk(EVENTS_PATH, cursorPath);
    writeCursor(chunk.cursor, cursorPath);

    const alerts = collectAlerts(chunk.content);
    if (alerts.length > 0) {
      allow(alerts.join("\n"));
      return;
    }
  } catch {
    // Monitoring must never block normal tool execution.
  }

  allow();
}

if (require.main === module) {
  main();
}

module.exports = {
  ALERT_EVENTS,
  CURSOR_PATH,
  EVENTS_PATH,
  HOOK_ROOT,
  PROJECT_ROOT,
  collectAlerts,
  findWinsmuxDir,
  formatAlert,
  getCursorPath,
  isAlertEvent,
  parseManifestProjectDir,
  parseEventLines,
  readCursor,
  readProjectDirFromManifest,
  readNewEventChunk,
  resolveProjectRoot,
  resolveProjectRootFromGit,
  writeCursor,
};
