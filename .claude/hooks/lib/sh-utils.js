const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const SH_DIR = path.join(".shield-harness");
const SESSION_FILE = path.join(SH_DIR, "session.json");
const EVIDENCE_FILE = path.join(".claude", "logs", "evidence-ledger.jsonl");
const PATTERNS_FILE = path.join(
  ".claude",
  "patterns",
  "injection-patterns.json",
);
const ZERO_WIDTH_RE =
  /[\u00ad\u034f\u180e\u200a-\u200f\u2028\u2029\u205f\u2060-\u2064\u3000\ufeff]/g;
const DEFAULT_PATTERNS = { categories: {} };
const DEFAULT_PREVIOUS_HASH = "genesis";
const DENY_THRESHOLD = 3;

function deny(reason) {
  process.stdout.write(`${JSON.stringify({ decision: "deny", reason })}\n`);
  process.exit(2);
}

function allow() {
  process.exit(0);
}

function readStdin() {
  const raw = fs.readFileSync(0, "utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function readHookInput() {
  return readStdin();
}

function sha256(data) {
  return crypto.createHash("sha256").update(String(data)).digest("hex");
}

function allowWithUpdate(updatedInput) {
  process.stderr.write(
    `${JSON.stringify({ hookSpecificOutput: { updatedInput } })}\n`,
  );
  process.exit(0);
}

function allowWithResult(resultObj) {
  process.stderr.write(
    `${JSON.stringify({ hookSpecificOutput: { result: resultObj } })}\n`,
  );
  process.exit(0);
}

function readSession() {
  try {
    if (!fs.existsSync(SESSION_FILE)) return {};
    const raw = fs.readFileSync(SESSION_FILE, "utf8").trim();
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function writeSession(data) {
  const sessionData =
    data && typeof data === "object" && !Array.isArray(data) ? data : {};
  const dir = path.dirname(SESSION_FILE);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const tmpFile = `${SESSION_FILE}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmpFile, JSON.stringify(sessionData, null, 2) + "\n", "utf8");
  fs.renameSync(tmpFile, SESSION_FILE);
  return sessionData;
}

function getPreviousEvidenceHash() {
  if (!fs.existsSync(EVIDENCE_FILE)) {
    return DEFAULT_PREVIOUS_HASH;
  }

  try {
    const lines = fs
      .readFileSync(EVIDENCE_FILE, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    if (lines.length === 0) {
      return DEFAULT_PREVIOUS_HASH;
    }

    const lastEntry = JSON.parse(lines.at(-1));
    return typeof lastEntry.hash === "string" && lastEntry.hash
      ? lastEntry.hash
      : DEFAULT_PREVIOUS_HASH;
  } catch {
    return DEFAULT_PREVIOUS_HASH;
  }
}

function appendEvidence(entry) {
  try {
    const evidence =
      entry && typeof entry === "object" && !Array.isArray(entry)
        ? { ...entry }
        : { value: entry };
    const recordedAt = new Date().toISOString();
    const previousHash = getPreviousEvidenceHash();
    const baseEntry = {
      ...evidence,
      recorded_at: recordedAt,
      timestamp: recordedAt,
      previous_hash: previousHash,
    };
    const hash = sha256(previousHash + JSON.stringify(baseEntry));
    const finalEntry = { ...baseEntry, hash };

    fs.mkdirSync(path.dirname(EVIDENCE_FILE), { recursive: true });
    fs.appendFileSync(EVIDENCE_FILE, `${JSON.stringify(finalEntry)}\n`, "utf8");
  } catch {
    // Evidence failures must never block hooks.
  }
}

function nfkcNormalize(str) {
  const value = str == null ? "" : String(str);
  return value.normalize("NFKC").replace(ZERO_WIDTH_RE, "");
}

function normalizePath(p) {
  if (typeof p !== "string" || p.trim() === "") {
    return "";
  }

  const resolved = path.resolve(p);
  if (process.platform === "win32") {
    return resolved.replace(/^([A-Z]):/, (_, drive) => `${drive.toLowerCase()}:`);
  }

  return resolved;
}

function loadPatterns() {
  try {
    if (!fs.existsSync(PATTERNS_FILE)) return { ...DEFAULT_PATTERNS };
    const raw = fs.readFileSync(PATTERNS_FILE, "utf8").trim();
    if (!raw) return { ...DEFAULT_PATTERNS };
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ...DEFAULT_PATTERNS };
    }
    if (!parsed.categories || typeof parsed.categories !== "object") {
      return { ...DEFAULT_PATTERNS };
    }
    return parsed;
  } catch {
    return { ...DEFAULT_PATTERNS };
  }
}

function trackDeny(sessionData, info) {
  const hasExplicitSession =
    sessionData && typeof sessionData === "object" && !Array.isArray(sessionData);
  const session = hasExplicitSession ? { ...sessionData } : readSession();
  const rawInfo = hasExplicitSession ? info : sessionData;
  let key = "unknown";

  if (typeof rawInfo === "string" && rawInfo.trim()) {
    key = rawInfo.trim();
  } else if (rawInfo && typeof rawInfo === "object" && !Array.isArray(rawInfo)) {
    key =
      rawInfo.key ||
      rawInfo.id ||
      rawInfo.label ||
      rawInfo.reason ||
      JSON.stringify(rawInfo);
  }

  const tracker =
    session.deny_tracker && typeof session.deny_tracker === "object"
      ? { ...session.deny_tracker }
      : {};
  const current = tracker[key] || {};
  const count = (current.count || 0) + 1;
  const updatedAt = new Date().toISOString();

  tracker[key] = {
    ...current,
    count,
    updated_at: updatedAt,
  };

  session.deny_tracker = tracker;
  writeSession(session);

  return {
    key,
    count,
    exceeded: count >= DENY_THRESHOLD,
    threshold: DENY_THRESHOLD,
    updated_at: updatedAt,
  };
}

function parseYamlScalar(rawValue) {
  const value = rawValue.trim();
  if (value === "") return "";
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null" || value === "~") return null;
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);
  if (value.startsWith("[") && value.endsWith("]")) {
    const inner = value.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(",").map((item) => parseYamlScalar(item));
  }
  return value;
}

function preprocessYaml(content) {
  return content
    .split(/\r?\n/)
    .map((line) => ({
      indent: (line.match(/^ */) || [""])[0].length,
      text: line.trimEnd(),
    }))
    .filter((line) => {
      const trimmed = line.text.trim();
      return trimmed !== "" && !trimmed.startsWith("#");
    })
    .map((line) => ({ indent: line.indent, text: line.text.trim() }));
}

function parseYamlObject(lines, startIndex, indent, seed = {}) {
  const result = seed;
  let index = startIndex;

  while (index < lines.length) {
    const line = lines[index];
    if (line.indent < indent) break;
    if (line.indent > indent) {
      index += 1;
      continue;
    }
    if (line.text.startsWith("- ")) break;

    const separator = line.text.indexOf(":");
    if (separator === -1) {
      index += 1;
      continue;
    }

    const key = line.text.slice(0, separator).trim();
    const rawValue = line.text.slice(separator + 1).trim();

    if (rawValue !== "") {
      result[key] = parseYamlScalar(rawValue);
      index += 1;
      continue;
    }

    const next = lines[index + 1];
    if (!next || next.indent <= indent) {
      result[key] = {};
      index += 1;
      continue;
    }

    const [child, nextIndex] = parseYamlBlock(lines, index + 1, next.indent);
    result[key] = child;
    index = nextIndex;
  }

  return [result, index];
}

function parseYamlArray(lines, startIndex, indent) {
  const result = [];
  let index = startIndex;

  while (index < lines.length) {
    const line = lines[index];
    if (line.indent < indent) break;
    if (line.indent !== indent || !line.text.startsWith("- ")) break;

    const itemText = line.text.slice(2).trim();
    if (itemText === "") {
      const next = lines[index + 1];
      if (next && next.indent > indent) {
        const [child, nextIndex] = parseYamlBlock(lines, index + 1, next.indent);
        result.push(child);
        index = nextIndex;
      } else {
        result.push(null);
        index += 1;
      }
      continue;
    }

    const separator = itemText.indexOf(":");
    if (separator !== -1 && !itemText.startsWith('"') && !itemText.startsWith("'")) {
      const key = itemText.slice(0, separator).trim();
      const rawValue = itemText.slice(separator + 1).trim();
      const seed = {};
      seed[key] = rawValue === "" ? {} : parseYamlScalar(rawValue);
      index += 1;

      if (index < lines.length && lines[index].indent > indent) {
        const [childObj, nextIndex] = parseYamlObject(
          lines,
          index,
          lines[index].indent,
          seed,
        );
        result.push(childObj);
        index = nextIndex;
      } else {
        result.push(seed);
      }
      continue;
    }

    result.push(parseYamlScalar(itemText));
    index += 1;
  }

  return [result, index];
}

function parseYamlBlock(lines, startIndex, indent) {
  if (startIndex >= lines.length) return [{}, startIndex];
  if (lines[startIndex].text.startsWith("- ")) {
    return parseYamlArray(lines, startIndex, indent);
  }
  return parseYamlObject(lines, startIndex, indent);
}

function readYaml(filePath) {
  try {
    if (!fs.existsSync(filePath)) return {};
    const content = fs.readFileSync(filePath, "utf8");
    const lines = preprocessYaml(content);
    if (lines.length === 0) return {};
    const [parsed] = parseYamlBlock(lines, 0, lines[0].indent);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function commandExists(cmd) {
  if (typeof cmd !== "string" || cmd.trim() === "") {
    return false;
  }

  const locator = process.platform === "win32" ? "where.exe" : "which";
  try {
    execSync(`${locator} ${cmd}`, {
      stdio: "ignore",
      timeout: 3000,
    });
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  deny,
  allow,
  readStdin,
  readHookInput,
  sha256,
  allowWithUpdate,
  allowWithResult,
  SH_DIR,
  SESSION_FILE,
  readSession,
  writeSession,
  EVIDENCE_FILE,
  appendEvidence,
  nfkcNormalize,
  normalizePath,
  loadPatterns,
  trackDeny,
  readYaml,
  commandExists,
};
