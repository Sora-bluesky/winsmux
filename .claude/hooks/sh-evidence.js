const fs = require("fs");
const path = require("path");

const { allow, readStdin, sha256 } = require("./lib/sh-utils");

const ROOT_DIR = path.resolve(__dirname, "..", "..");
const LEDGER_PATH = path.join(ROOT_DIR, ".claude", "logs", "evidence-ledger.jsonl");
const SESSION_PATH = path.join(ROOT_DIR, ".shield-harness", "session.json");
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

function summarizeResult(payload) {
  const candidate =
    payload.tool_result ??
    payload.tool_output ??
    payload.result ??
    payload.output ??
    payload.stdout ??
    payload.response ??
    "";

  const text =
    typeof candidate === "string"
      ? candidate
      : JSON.stringify(candidate);

  return (text || "").replace(/\s+/g, " ").slice(0, 200);
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

function getPreviousHash() {
  if (!fs.existsSync(LEDGER_PATH)) {
    return "genesis";
  }

  try {
    const lines = fs
      .readFileSync(LEDGER_PATH, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    if (lines.length === 0) {
      return "genesis";
    }

    const lastEntry = JSON.parse(lines.at(-1));
    return typeof lastEntry.hash === "string" && lastEntry.hash ? lastEntry.hash : "genesis";
  } catch {
    return "genesis";
  }
}

function buildEntry(payload) {
  const session = readSession();
  const entry = {
    timestamp: new Date().toISOString(),
    tool_name: payload.tool_name ?? null,
    tool_input: sanitizeValue(payload.tool_input ?? {}),
    result_summary: summarizeResult(payload),
    session_id: session.session_id ?? session.id ?? null,
    is_channel: session.source === "channel",
  };
  const previousHash = getPreviousHash();
  const entryJson = JSON.stringify(entry);

  return {
    ...entry,
    hash: sha256(previousHash + entryJson),
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

main();
