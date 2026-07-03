// Pure functions for the durable CLI Bakeoff runner (#1120). No I/O here --
// all filesystem/network access lives in run-cli-bakeoff.mjs so this module
// can be exercised directly by bakeoff-runner-check.mjs against fixed
// input/output shapes.

/**
 * Parse the `panes:` block of a winsmux manifest.yaml into a
 * { 'worker-1': '%2', ... } map. The manifest is a flat, one-token-per-line
 * YAML dump (no multi-line scalars inside the panes block), so a line-based
 * regex walk is reliable and avoids taking a YAML parser dependency.
 *
 * @param {string} yamlText
 * @returns {Record<string, string>}
 */
export function parseManifestPaneIds(yamlText) {
  const result = {};
  if (!yamlText) return result;

  const lines = yamlText.split(/\r?\n/);
  let inPanes = false;
  let currentWorker = null;

  const panesHeaderRe = /^panes:\s*$/;
  // Matches `  'worker-1':` or `  worker-1:` (single or no quotes).
  const workerKeyRe = /^\s{2}'?([\w-]+)'?:\s*$/;
  const paneIdRe = /^\s+pane_id:\s*'?([^'\s]+)'?\s*$/;
  // Any line indented at 2 spaces that is not a worker key ends the panes
  // block (e.g. a sibling top-level key resuming at column 0).
  const topLevelKeyRe = /^\S/;

  for (const rawLine of lines) {
    if (panesHeaderRe.test(rawLine)) {
      inPanes = true;
      currentWorker = null;
      continue;
    }
    if (!inPanes) continue;

    if (topLevelKeyRe.test(rawLine)) {
      // Left the panes block entirely.
      inPanes = false;
      currentWorker = null;
      continue;
    }

    const workerMatch = rawLine.match(workerKeyRe);
    if (workerMatch) {
      currentWorker = workerMatch[1];
      continue;
    }

    if (currentWorker) {
      const paneIdMatch = rawLine.match(paneIdRe);
      if (paneIdMatch) {
        result[currentWorker] = paneIdMatch[1];
      }
    }
  }

  return result;
}

/**
 * Given an array of pane-header innerText strings (one per worker pane),
 * return the set of worker labels ("worker-1".."worker-6") whose header
 * text contains the "ready for benchmark" badge.
 *
 * @param {string[]} headTexts
 * @returns {Set<string>}
 */
export function collectReadyWorkers(headTexts) {
  const ready = new Set();
  if (!Array.isArray(headTexts)) return ready;

  const workerLabelRe = /worker-(\d+)/i;
  const readyPhraseRe = /ready for benchmark/i;

  for (const text of headTexts) {
    if (typeof text !== "string") continue;
    if (!readyPhraseRe.test(text)) continue;
    const labelMatch = text.match(workerLabelRe);
    if (labelMatch) {
      ready.add(`worker-${labelMatch[1]}`);
    }
  }

  return ready;
}

/**
 * Map a benchmark-pack task id to the round-end marker string its packet
 * instructs the worker to print at completion. Task ids WB-001..WB-009 are
 * round A, WB-010..WB-018 are round B, and WB-019..WB-027 are round C, per
 * the `tasks/cli-bakeoff/v1/WB-*.md` packets (each packet's step 5 names its
 * round's END marker literally).
 *
 * @param {string} taskId
 * @returns {"BAKEOFF_ROUND_A_END"|"BAKEOFF_ROUND_B_END"|"BAKEOFF_ROUND_C_END"}
 */
export function taskIdToEndMarker(taskId) {
  const match = typeof taskId === "string" ? taskId.match(/^WB-(\d+)/) : null;
  const num = match ? Number(match[1]) : NaN;
  if (Number.isFinite(num) && num >= 19) return "BAKEOFF_ROUND_C_END";
  if (Number.isFinite(num) && num >= 10) return "BAKEOFF_ROUND_B_END";
  return "BAKEOFF_ROUND_A_END";
}

/**
 * Count occurrences of a round-end marker in a captured pane text blob.
 *
 * @param {string} paneText
 * @param {string} [marker] defaults to BAKEOFF_ROUND_A_END for callers that
 *   have not been updated to pass a task-specific marker.
 * @returns {number}
 */
export function countEndMarkers(paneText, marker = "BAKEOFF_ROUND_A_END") {
  if (!paneText) return 0;
  const escaped = String(marker).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = paneText.match(new RegExp(escaped, "g"));
  return matches ? matches.length : 0;
}

/**
 * Classify an api_llm worker's run.json content for a single task.
 *
 * @param {string} runJsonText
 * @returns {"completed"|"failed"|"pending"}
 */
export function classifyApiRun(runJsonText) {
  if (!runJsonText) return "pending";
  let parsed;
  try {
    parsed = JSON.parse(runJsonText);
  } catch {
    return "pending";
  }
  const status = typeof parsed?.status === "string" ? parsed.status.toLowerCase() : "";
  if (status === "succeeded" || status === "completed" || status === "success") {
    return "completed";
  }
  if (status === "failed" || status === "error" || status === "errored") {
    return "failed";
  }
  return "pending";
}

/**
 * Classify a CLI worker's progress on a single dispatched task by comparing
 * the BAKEOFF_ROUND_A_END marker count before and after dispatch.
 *
 * @param {number} prevCount marker count observed before this task's dispatch
 * @param {number} currCount marker count observed at the current poll tick
 * @param {number} elapsedSeconds seconds since this task was dispatched
 * @param {number} timeoutSeconds this task's configured timeout
 * @returns {"completed"|"pending"|"timeout"}
 */
export function classifyCliWorker(prevCount, currCount, elapsedSeconds, timeoutSeconds) {
  const prev = Number.isFinite(prevCount) ? prevCount : 0;
  const curr = Number.isFinite(currCount) ? currCount : 0;
  if (curr > prev) return "completed";
  if (Number.isFinite(elapsedSeconds) && Number.isFinite(timeoutSeconds) && elapsedSeconds >= timeoutSeconds) {
    return "timeout";
  }
  return "pending";
}

/**
 * Pick the newest dispatch-* run directory name created at or after a given
 * epoch-ms threshold, from a flat list of directory names. Directory names
 * follow `dispatch-<runid>-worker-N`; selection here is name-only (the
 * caller is expected to have already filtered/sorted by actual filesystem
 * mtime and pass only candidate names created since the threshold, OR pass
 * an array of {name, mtimeMs} pairs). To keep this function pure and
 * dependency-free, it accepts either plain strings (already pre-filtered by
 * the caller) or {name, mtimeMs} objects and does the mtime filtering here
 * when mtimeMs is present.
 *
 * @param {(string|{name:string,mtimeMs:number})[]} entries
 * @param {number} [sinceEpochMs]
 * @returns {string|null}
 */
export function selectNewRunDir(entries, sinceEpochMs) {
  if (!Array.isArray(entries) || entries.length === 0) return null;

  const normalized = entries
    .map((entry) => (typeof entry === "string" ? { name: entry, mtimeMs: undefined } : entry))
    .filter((entry) => entry && typeof entry.name === "string" && entry.name.startsWith("dispatch-"));

  const candidates = Number.isFinite(sinceEpochMs)
    ? normalized.filter((entry) => !Number.isFinite(entry.mtimeMs) || entry.mtimeMs >= sinceEpochMs)
    : normalized;

  if (candidates.length === 0) return null;

  const withMtime = candidates.filter((entry) => Number.isFinite(entry.mtimeMs));
  if (withMtime.length > 0) {
    withMtime.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return withMtime[0].name;
  }

  // No mtime info available -- fall back to lexicographic max, which is a
  // reasonable last resort since dispatch ids are opaque but directory
  // listing order is not guaranteed to be creation order.
  const sorted = [...candidates].sort((a, b) => (a.name < b.name ? 1 : a.name > b.name ? -1 : 0));
  return sorted[0].name;
}

/**
 * Build the ready-check command string sent through the composer.
 * @returns {string}
 */
export function buildReadyCheckCommand() {
  return "winsmux benchmark ready-check";
}

/**
 * Build the dispatch command string sent through the composer for a task.
 * @param {string} taskId
 * @returns {string}
 */
export function buildDispatchCommand(taskId) {
  return `winsmux benchmark dispatch task ${taskId}`;
}

/**
 * Given the full ordered list of task ids and an optional requested subset
 * (comma-separated string or array), return the ordered list of task ids to
 * run. Unknown requested ids are dropped silently from the returned list but
 * reported via the second return value so callers can warn.
 *
 * @param {string[]} allTaskIds
 * @param {string|string[]|undefined} requested
 * @returns {{ taskIds: string[], unknown: string[] }}
 */
export function resolveTaskSelection(allTaskIds, requested) {
  const known = new Set(allTaskIds);
  if (!requested) {
    return { taskIds: [...allTaskIds], unknown: [] };
  }
  const requestedList = Array.isArray(requested)
    ? requested
    : String(requested).split(",").map((s) => s.trim()).filter(Boolean);

  const taskIds = [];
  const unknown = [];
  for (const id of requestedList) {
    if (known.has(id)) {
      if (!taskIds.includes(id)) taskIds.push(id);
    } else {
      unknown.push(id);
    }
  }
  return { taskIds, unknown };
}
