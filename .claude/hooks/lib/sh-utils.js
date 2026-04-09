const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
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
// Zero-width and invisible Unicode ranges removed during normalization:
// U+00AD, U+034F, U+061C, U+180E, U+200A-U+200F, U+2028-U+2029, U+202A-U+202E,
// U+205F, U+2060-U+2064, U+2066-U+2069, U+115F-U+1160, U+17B4-U+17B5, U+3000,
// U+3164, U+FE00-U+FE0F, U+FEFF, U+FFA0, U+E0001-U+E007F, U+E0100-U+E01EF
const ZERO_WIDTH_RE =
  /(?:[\u00ad\u034f\u061c\u180e\u200a-\u200f\u2028\u2029\u202a-\u202e\u205f\u2060-\u2064\u2066-\u2069\u115f-\u1160\u17b4-\u17b5\u3000\u3164\ufe00-\ufe0f\ufeff\uffa0]|\udb40[\udc01-\udc7f\udd00-\uddef])/g;
const DEFAULT_PATTERNS = { categories: {} };
const DEFAULT_PREVIOUS_HASH = "genesis";
const DENY_THRESHOLD = 3;
const DEFAULT_PLANNING_ROOT = path.join(os.homedir(), ".winsmux", "planning");
const PLANNING_ROOT_MARKER = path.join(
  process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
  "winsmux",
  "planning-root.txt",
);
let cachedPlanningRoot = null;

function deny(reason) {
  process.stdout.write(`${JSON.stringify({ decision: "deny", reason })}\n`);
  process.exit(2);
}

function allow(additionalContext) {
  if (additionalContext) {
    process.stderr.write(
      `${JSON.stringify({ hookSpecificOutput: { additionalContext } })}\n`,
    );
  }
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

function readPlanningRootMarker() {
  try {
    if (!fs.existsSync(PLANNING_ROOT_MARKER)) {
      return "";
    }

    return fs.readFileSync(PLANNING_ROOT_MARKER, "utf8").trim();
  } catch {
    return "";
  }
}

function findPlanningRoot(startDir, depth = 0, maxDepth = 8) {
  if (depth > maxDepth) {
    return "";
  }

  let entries;
  try {
    entries = fs.readdirSync(startDir, { withFileTypes: true });
  } catch {
    return "";
  }

  const hasBacklog = entries.some(
    (entry) => entry.isFile() && entry.name === "backlog.yaml",
  );
  const hasRoadmap = entries.some(
    (entry) => entry.isFile() && entry.name === "ROADMAP.md",
  );

  if (
    hasBacklog &&
    hasRoadmap &&
    normalizePath(startDir).replace(/\\/g, "/").endsWith("/winsmux/planning")
  ) {
    return startDir;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    if (entry.name === ".git" || entry.name === "node_modules") {
      continue;
    }

    const candidate = findPlanningRoot(
      path.join(startDir, entry.name),
      depth + 1,
      maxDepth,
    );
    if (candidate) {
      return candidate;
    }
  }

  return "";
}

function getPlanningRoot() {
  if (
    typeof process.env.WINSMUX_PLANNING_ROOT === "string" &&
    process.env.WINSMUX_PLANNING_ROOT.trim() !== ""
  ) {
    return process.env.WINSMUX_PLANNING_ROOT;
  }

  if (cachedPlanningRoot) {
    return cachedPlanningRoot;
  }

  const markerRoot = readPlanningRootMarker();
  if (markerRoot) {
    cachedPlanningRoot = markerRoot;
    return cachedPlanningRoot;
  }

  const discoveredRoot = findPlanningRoot(os.homedir());
  if (discoveredRoot) {
    cachedPlanningRoot = discoveredRoot;
    return cachedPlanningRoot;
  }

  cachedPlanningRoot = DEFAULT_PLANNING_ROOT;
  return cachedPlanningRoot;
}

function resolvePlanningFile(localRelativePath, envKey, fileName) {
  const explicit = process.env[envKey];
  if (typeof explicit === "string" && explicit.trim() !== "") {
    return explicit;
  }

  const externalPath = path.join(getPlanningRoot(), fileName);
  if (fs.existsSync(externalPath) || !fs.existsSync(localRelativePath)) {
    return externalPath;
  }

  return localRelativePath;
}

function getBacklogPath() {
  return resolvePlanningFile(path.join("tasks", "backlog.yaml"), "WINSMUX_BACKLOG_PATH", "backlog.yaml");
}

function getRoadmapPath() {
  return resolvePlanningFile(path.join("docs", "project", "ROADMAP.md"), "WINSMUX_ROADMAP_PATH", "ROADMAP.md");
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
  getPlanningRoot,
  getBacklogPath,
  getRoadmapPath,
};
