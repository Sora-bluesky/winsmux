#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const { allow, readStdin, sha256 } = require("./lib/sh-utils");

const ROOT_DIR = path.resolve(__dirname, "..", "..");
const DEFAULT_LEDGER_PATH = path.join(ROOT_DIR, ".claude", "logs", "evidence-ledger.jsonl");
const DEFAULT_SESSION_PATH = path.join(ROOT_DIR, ".shield-harness", "session.json");
const LEDGER_PATH = process.env.SH_EVIDENCE_LEDGER_PATH || DEFAULT_LEDGER_PATH;
const SESSION_PATH = process.env.SH_EVIDENCE_SESSION_PATH || DEFAULT_SESSION_PATH;
const HOOK_NAME = "sh-evidence";
const MAX_TRACE_SEGMENTS = 5;
const SECRET_PATTERNS = [/\bgho_[A-Za-z0-9_]+\b/g, /\bghp_[A-Za-z0-9_]+\b/g, /\bsk-[A-Za-z0-9_-]+\b/g];

function sanitizeValue(value) {
  if (typeof value === "string") {
    return SECRET_PATTERNS.reduce(
      (current, pattern) => current.replace(pattern, "[REDACTED]"),
      value,
    );
  }

  if (Array.isArray(value)) {
    return value.map((item) => sanitizeValue(item));
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, childValue]) => [key, sanitizeValue(childValue)]),
    );
  }

  return value;
}

function pickField(payload, camelKey, snakeKey, fallback = null) {
  if (!payload || typeof payload !== "object") {
    return fallback;
  }

  if (payload[camelKey] !== undefined) {
    return payload[camelKey];
  }

  if (payload[snakeKey] !== undefined) {
    return payload[snakeKey];
  }

  return fallback;
}

function normalizeText(value, limit = 200) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}

function summarizeResult(payload) {
  const toolResult = pickField(payload, "toolResult", "tool_result");
  const candidate =
    toolResult ??
    pickField(payload, "toolOutput", "tool_output") ??
    payload.result ??
    payload.output ??
    payload.stdout ??
    payload.response ??
    "";

  const text =
    typeof candidate === "string"
      ? candidate
      : JSON.stringify(candidate);

  return normalizeText(text, 200);
}

function readSession() {
  if (!fs.existsSync(SESSION_PATH)) {
    return {};
  }

  try {
    return JSON.parse(fs.readFileSync(SESSION_PATH, "utf8"));
  } catch {
    return {};
  }
}

function splitCommandSegments(command) {
  if (typeof command !== "string" || command.trim() === "") {
    return [];
  }

  const segments = [];
  let current = "";
  let quote = null;
  let escapeNext = false;

  const pushCurrent = () => {
    const trimmed = current.trim();
    if (trimmed) {
      segments.push(trimmed);
    }
    current = "";
  };

  for (let index = 0; index < command.length; index += 1) {
    const char = command[index];
    const pair = command.slice(index, index + 2);

    if (escapeNext) {
      current += char;
      escapeNext = false;
      continue;
    }

    if (char === "\\" && quote !== "'") {
      current += char;
      escapeNext = true;
      continue;
    }

    if (quote) {
      current += char;
      if (char === quote) {
        quote = null;
      }
      continue;
    }

    if (char === "'" || char === '"' || char === "`") {
      quote = char;
      current += char;
      continue;
    }

    if (pair === "&&" || pair === "||") {
      pushCurrent();
      index += 1;
      continue;
    }

    if (char === "|" || char === ";") {
      pushCurrent();
      continue;
    }

    current += char;
  }

  pushCurrent();

  return segments;
}

function resolveExitCode(payload, toolResult) {
  const directExitCode = pickField(payload, "exitCode", "exit_code");
  if (typeof directExitCode === "number") {
    return directExitCode;
  }

  if (toolResult && typeof toolResult === "object") {
    const nestedExitCode = pickField(toolResult, "exitCode", "exit_code");
    if (typeof nestedExitCode === "number") {
      return nestedExitCode;
    }

    const status = pickField(toolResult, "status", "status");
    if (typeof status === "number") {
      return status;
    }
  }

  return null;
}

function extractCommandTrace(toolName, toolInput, payload) {
  if (toolName !== "Bash" || !toolInput || typeof toolInput !== "object") {
    return null;
  }

  const rawCommand =
    typeof toolInput.command === "string" ? toolInput.command.trim() : "";
  if (!rawCommand) {
    return null;
  }

  const command = sanitizeValue(rawCommand);
  const segments = splitCommandSegments(command);
  const toolResult = pickField(payload, "toolResult", "tool_result");

  return {
    shell: "Bash",
    command_hash: sha256(command),
    command_preview: normalizeText(command, 200),
    segment_count: segments.length,
    segments: segments
      .slice(0, MAX_TRACE_SEGMENTS)
      .map((segment) => normalizeText(segment, 160)),
    truncated: segments.length > MAX_TRACE_SEGMENTS,
    working_directory: sanitizeValue(toolInput.cwd ?? toolInput.workdir ?? null),
    exit_code: resolveExitCode(payload, toolResult),
  };
}

function computeEntryHash(entry, impliedPreviousHash = "genesis") {
  const candidate =
    entry && typeof entry === "object" && !Array.isArray(entry) ? { ...entry } : {};
  const previousHash =
    typeof candidate.previous_hash === "string" && candidate.previous_hash
      ? candidate.previous_hash
      : impliedPreviousHash;

  delete candidate.hash;
  return sha256(previousHash + JSON.stringify(candidate));
}

function readLedgerLines() {
  if (!fs.existsSync(LEDGER_PATH)) {
    return [];
  }

  return fs
    .readFileSync(LEDGER_PATH, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function verifyLedgerIntegrity() {
  const lines = readLedgerLines();
  if (lines.length === 0) {
    return { valid: true, entries_checked: 0, last_hash: "genesis", issue: null };
  }

  let previousHash = "genesis";

  for (let index = 0; index < lines.length; index += 1) {
    const lineNumber = index + 1;
    let entry;

    try {
      entry = JSON.parse(lines[index]);
    } catch {
      return {
        valid: false,
        entries_checked: index,
        last_hash: previousHash,
        issue: `Malformed JSON at line ${lineNumber}`,
      };
    }

    const declaredPreviousHash =
      typeof entry.previous_hash === "string" && entry.previous_hash
        ? entry.previous_hash
        : previousHash;

    if (declaredPreviousHash !== previousHash) {
      return {
        valid: false,
        entries_checked: index,
        last_hash: previousHash,
        issue: `previous_hash mismatch at line ${lineNumber}`,
      };
    }

    const expectedHash = computeEntryHash(entry, previousHash);
    if (entry.hash !== expectedHash) {
      return {
        valid: false,
        entries_checked: index,
        last_hash: previousHash,
        issue: `hash mismatch at line ${lineNumber}`,
      };
    }

    previousHash = entry.hash;
  }

  return {
    valid: true,
    entries_checked: lines.length,
    last_hash: previousHash,
    issue: null,
  };
}

function buildEntry(payload) {
  const session = readSession();
  const toolName = pickField(payload, "toolName", "tool_name");
  const toolInput = sanitizeValue(pickField(payload, "toolInput", "tool_input", {}));
  const integrityCheck = verifyLedgerIntegrity();
  const recordedAt = new Date().toISOString();
  const entry = {
    hook: HOOK_NAME,
    event: "PostToolUse",
    decision: "allow",
    recorded_at: recordedAt,
    timestamp: recordedAt,
    tool: toolName ?? null,
    tool_name: toolName ?? null,
    tool_input: toolInput,
    result_summary: summarizeResult(payload),
    session_id: session.session_id ?? session.id ?? null,
    is_channel: session.source === "channel",
    command_trace: extractCommandTrace(toolName, toolInput, payload),
    integrity_check: {
      valid: integrityCheck.valid,
      entries_checked: integrityCheck.entries_checked,
      issue: integrityCheck.issue,
    },
  };
  const previousHash = integrityCheck.last_hash || "genesis";
  const entryWithPreviousHash = {
    ...entry,
    previous_hash: previousHash,
  };

  return {
    ...entryWithPreviousHash,
    hash: computeEntryHash(entryWithPreviousHash, previousHash),
  };
}

function appendEntry(entry) {
  fs.mkdirSync(path.dirname(LEDGER_PATH), { recursive: true });
  fs.appendFileSync(LEDGER_PATH, `${JSON.stringify(entry)}\n`, "utf8");
}

function main() {
  try {
    const payload = readStdin();
    const entry = buildEntry(payload);
    appendEntry(entry);
  } catch {
    // Evidence recording must never block tool execution.
  }

  allow();
}

if (require.main === module) {
  main();
}

module.exports = {
  DEFAULT_LEDGER_PATH,
  DEFAULT_SESSION_PATH,
  HOOK_NAME,
  sanitizeValue,
  summarizeResult,
  splitCommandSegments,
  extractCommandTrace,
  computeEntryHash,
  verifyLedgerIntegrity,
  buildEntry,
};
