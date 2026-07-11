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
 * NOTE (round-9 fix): the returned pane_id values are INFORMATIONAL ONLY --
 * used for commands.jsonl/manifest.json metadata and for a startup warning
 * when the roster is incomplete. They are psmux SERVER session pane
 * identifiers (see core/src/session.rs), which are a disjoint address space
 * from the desktop app's in-process Tauri PTYs. The runner's actual capture
 * path (pty_capture over CDP, run-cli-bakeoff.mjs's capturePane) addresses
 * panes by worker SLOT id ("worker-1".."worker-6"), never by a pane_id
 * returned from this function. Do not wire this map's values into any new
 * capture call.
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
 * The desktop renders the badge through getLanguageText("ready for
 * benchmark", "ベンチ投入可能") (winsmux-app/src/main.ts), so a
 * Japanese-language desktop shows the localized text. Both localizations
 * must match here; otherwise a JP-UI desktop passes its readiness check
 * while the runner reports every worker not ready.
 *
 * @param {string[]} headTexts
 * @returns {Set<string>}
 */
export function collectReadyWorkers(headTexts) {
  const ready = new Set();
  if (!Array.isArray(headTexts)) return ready;

  const workerLabelRe = /worker-(\d+)/i;
  const readyPhraseRe = /ready for benchmark|ベンチ投入可能/i;

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
 * Count the raw occurrences of a round-end marker anywhere in a captured
 * pane blob (plain substring count, regex-escaped marker).
 *
 * Every `tasks/cli-bakeoff/v1/WB-*.md` packet instructs the worker to
 * "Return exactly this structure" -- a numbered list whose item 5 IS the
 * round END marker, e.g. `5. BAKEOFF_ROUND_A_END` (often with surrounding
 * digits/backticks, since the worker is following a numbered-list
 * instruction literally). A compliant completion is therefore
 * indistinguishable, by line shape alone, from the dispatch echo of the same
 * packet text: both are a numbered line containing the bare marker. Trying
 * to filter out the echo by rejecting digits/backticks around the marker
 * (the previous strategy here) also rejects every compliant worker's actual
 * completion output, which is why that strategy is gone.
 *
 * Echo disambiguation is handled by the CALLER, not by this function: after
 * dispatch confirmation, the runner waits until an exact, per-dispatch echo
 * receipt is visible before it seeds a baseline. The receipt is appended
 * after the complete packet, so the echo is already included in that
 * baseline; only a later marker occurrence -- i.e. the worker's own
 * completion output -- can register as an increase. This function's only
 * job is an honest raw count; do not reintroduce line-shape filtering here.
 *
 * @param {string} paneText
 * @param {string} [marker] defaults to BAKEOFF_ROUND_A_END for callers that
 *   have not been updated to pass a task-specific marker.
 * @returns {number}
 */
export function countEndMarkers(paneText, marker = "BAKEOFF_ROUND_A_END") {
  if (!paneText) return 0;
  const target = String(marker);
  if (!target) return 0;
  const escaped = target.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = String(paneText).match(new RegExp(escaped, "g"));
  return matches ? matches.length : 0;
}

/**
 * Build the exact per-dispatch receipt appended after a CLI packet's prompt.
 * This must stay in sync with writeWorkerBenchmarkSubmission in main.ts.
 *
 * @param {string} dispatchId
 * @returns {string}
 */
export function buildCliDispatchEchoMarker(dispatchId) {
  const id = typeof dispatchId === "string" ? dispatchId.trim() : "";
  return id ? `WINSMUX_BENCH_DISPATCH ${id}` : "";
}

/**
 * Extract the latest desktop-generated dispatch id from conversation text.
 *
 * @param {string} text
 * @returns {string}
 */
export function extractLatestDispatchId(text) {
  const matches = [...String(text || "").matchAll(/\bdispatch-[0-9a-z]+\b/gi)];
  return matches.length > 0 ? matches[matches.length - 1][0] : "";
}

/**
 * Count packet markers that appear after this dispatch's receipt in a pane
 * capture. The receipt is appended after the echoed packet, so markers in
 * the suffix after its last visible copy are worker output rather than
 * repeated echoed instructions.
 *
 * @param {string} paneText
 * @param {string} receipt
 * @param {string} beginMarker
 * @param {string} endMarker
 * @returns {{beginCount: number, endCount: number}|null}
 */
export function countCliMarkersAfterEchoReceipt(paneText, receipt, beginMarker, endMarker) {
  const text = typeof paneText === "string" ? paneText : "";
  const marker = typeof receipt === "string" ? receipt : "";
  const receiptIndex = marker ? text.lastIndexOf(marker) : -1;
  if (receiptIndex < 0) return null;

  const suffix = text.slice(receiptIndex + marker.length);
  return {
    beginCount: beginMarker ? countEndMarkers(suffix, beginMarker) : 0,
    endCount: countEndMarkers(suffix, endMarker),
  };
}

/**
 * Classify an api_llm worker's run.json content for a single task.
 *
 * `workers exec` initializes the api_llm run status to 'blocked' and only
 * upgrades it after a successful provider call (scripts/winsmux-core.ps1),
 * so a run.json persisted with status 'blocked' (missing API key,
 * unconfigured runner metadata) is a finished non-runnable outcome, not an
 * in-progress one. It is returned as terminal 'blocked' so the runner can
 * record it immediately instead of waiting out the full task timeout.
 *
 * NOTE: this function only inspects run.json's own status field. It does NOT
 * validate round begin/end markers in the response body -- callers that need
 * marker validation on a succeeded/completed run must use
 * classifyApiOutcome (below), which wraps this function and additionally
 * checks response text against the pack's markers, exactly mirroring
 * run-cli-bakeoff-openrouter.ps1's succeeded-but-no-marker downgrade to
 * invalid_output.
 *
 * @param {string} runJsonText
 * @returns {"completed"|"failed"|"blocked"|"pending"}
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
  if (status === "blocked") {
    return "blocked";
  }
  return "pending";
}

/**
 * Extract a task packet's round begin/end marker literals, mirroring
 * Get-PacketMarkers in run-cli-bakeoff-openrouter.ps1 (regex
 * `BAKEOFF_[A-Z_]+_BEGIN` / `BAKEOFF_[A-Z_]+_END` against the packet text).
 *
 * @param {string} packetText
 * @returns {{begin: string, end: string}}
 */
export function getPacketMarkers(packetText) {
  const text = typeof packetText === "string" ? packetText : "";
  const beginMatch = text.match(/BAKEOFF_[A-Z_]+_BEGIN/);
  const endMatch = text.match(/BAKEOFF_[A-Z_]+_END/);
  return {
    begin: beginMatch ? beginMatch[0] : "",
    end: endMatch ? endMatch[0] : "",
  };
}

/**
 * Classify an api_llm worker's full outcome for a single task: run.json
 * status PLUS (for a succeeded/completed run) round begin/end marker
 * presence in the response text.
 *
 * Mirrors run-cli-bakeoff-openrouter.ps1 lines ~289-304: a run.json that
 * reports success is only trusted as 'completed' when BOTH the round begin
 * marker and the round end marker are found verbatim in the response body.
 * A succeeded run.json missing either marker is downgraded to terminal
 * 'invalid_output' (counted the same as a task failure), never silently
 * accepted as completed and never left pending.
 *
 * blocked/failed/pending pass through unchanged from classifyApiRun --
 * marker validation only applies to a run that otherwise looks successful.
 *
 * @param {string} runJsonText
 * @param {string} responseText contents of the run's response.txt (or "" if
 *   not present/not read)
 * @param {{begin: string, end: string}} markers from getPacketMarkers
 * @returns {"completed"|"failed"|"blocked"|"pending"|"invalid_output"}
 */
export function classifyApiOutcome(runJsonText, responseText, markers) {
  const base = classifyApiRun(runJsonText);
  if (base !== "completed") return base;

  const text = typeof responseText === "string" ? responseText : "";
  const begin = markers && typeof markers.begin === "string" ? markers.begin : "";
  const end = markers && typeof markers.end === "string" ? markers.end : "";
  const hasBegin = begin.length > 0 && text.includes(begin);
  const hasEnd = end.length > 0 && text.includes(end);

  if (hasBegin && hasEnd) return "completed";
  return "invalid_output";
}

/**
 * Return true when an outcome is first observed at or after its configured
 * task deadline.
 *
 * @param {number} elapsedSeconds
 * @param {number} timeoutSeconds
 * @returns {boolean}
 */
export function hasTaskTimedOut(elapsedSeconds, timeoutSeconds) {
  return Number.isFinite(elapsedSeconds) &&
    Number.isFinite(timeoutSeconds) &&
    elapsedSeconds >= timeoutSeconds;
}

/**
 * Classify a CLI worker's progress on a single dispatched task by comparing
 * the current marker occurrence count against the lowest count observed
 * since the post-dispatch baseline was seeded.
 *
 * The caller must maintain `minObservedCount` as a running minimum over
 * SUCCESSFUL captures only: pane capture returns visible rows only, so a
 * leftover marker (previous task's output, or this dispatch's own echo) can
 * scroll off mid-task, and lowering the baseline when that happens is what
 * lets this task's own marker (count rising back above the minimum)
 * register as completion instead of reading as "no change" and timing out.
 * A failed capture must never feed this function -- an empty read would
 * wrongly lower the baseline and turn a stale marker into a false
 * completion.
 *
 * @param {number} minObservedCount lowest marker count observed since the
 *   baseline was seeded after dispatch confirmation and its exact echo
 *   receipt, then lowered by the caller whenever a successful poll observes
 *   a smaller count)
 * @param {number} currCount marker count observed at the current poll tick
 * @param {number} elapsedSeconds seconds since this task was dispatched
 * @param {number} timeoutSeconds this task's configured timeout
 * @returns {"completed"|"pending"|"timeout"}
 */
export function classifyCliWorker(minObservedCount, currCount, elapsedSeconds, timeoutSeconds) {
  const prev = Number.isFinite(minObservedCount) ? minObservedCount : 0;
  const curr = Number.isFinite(currCount) ? currCount : 0;
  if (curr > prev) return "completed";
  if (hasTaskTimedOut(elapsedSeconds, timeoutSeconds)) {
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
 * Reproduce, byte-for-byte, the base prompt the desktop app builds for a
 * benchmark task dispatch (buildHarnessTaskPrompt in
 * winsmux-app/src/main.ts, ~lines 4143-4157). The desktop then appends its
 * per-dispatch echo receipt before hashing and sending the interactive CLI
 * prompt; the runner obtains that receipt from the confirmed conversation
 * entry and appends the same value before comparing the displayed sha256.
 * This function must stay in sync with the base app-side builder.
 *
 * Pure/dependency-free by design: the actual sha256 digest is computed by
 * the CALLER (run-cli-bakeoff.mjs) using node:crypto, not here, so this
 * module keeps no runtime dependency beyond string formatting.
 *
 * @param {{pack_id?: string, default_timeout_seconds?: number}} pack
 * @param {{task_id?: string, title?: string, timeout_seconds?: number}} task
 * @param {string} packetContent
 * @returns {string}
 */
export function buildHarnessPromptMirror(pack, task, packetContent) {
  const packId = String((pack && pack.pack_id) || "winsmux-cli-bakeoff-v1");
  const taskId = String((task && task.task_id) || "").trim();
  const taskTitle = String((task && task.title) || taskId).trim();
  const timeoutSeconds = Number(
    (task && task.timeout_seconds) || (pack && pack.default_timeout_seconds) || 3600,
  );
  return [
    `Harness Bench task packet`,
    `Pack: ${packId}`,
    `Task: ${taskId}`,
    `Title: ${taskTitle}`,
    `Timeout seconds: ${Number.isFinite(timeoutSeconds) ? timeoutSeconds : 3600}`,
    "",
    "Instructions:",
    String(packetContent || "").trim(),
    "",
  ].join("\n");
}

/**
 * Extract the last 64-char lowercase hex string appearing near a "sha256"
 * label in a conversation-panel innerText blob, mirroring how the desktop
 * displays the full interactive prompt hash as a labeled conversation detail
 * (`{ label: "sha256", value: cliDispatchPromptSha }`).
 *
 * Deliberately liberal: tries a "sha256" label followed (within a short
 * distance) by a 64-hex-char run first; if that finds nothing, falls back to
 * the LAST bare 64-hex-char run anywhere in the text (covers layout/label
 * text differences without over-fitting to one exact DOM shape). Returns ""
 * when nothing matches -- callers must treat "" as "hash not found", never
 * as a valid comparison value.
 *
 * @param {string} conversationText
 * @returns {string}
 */
export function extractLatestSha256(conversationText) {
  const text = typeof conversationText === "string" ? conversationText : "";
  if (!text) return "";

  const labeled = [...text.matchAll(/sha256[^0-9a-fA-F]{0,20}([0-9a-fA-F]{64})/g)];
  if (labeled.length > 0) {
    return labeled[labeled.length - 1][1].toLowerCase();
  }

  const bare = [...text.matchAll(/\b([0-9a-fA-F]{64})\b/g)];
  if (bare.length > 0) {
    return bare[bare.length - 1][1].toLowerCase();
  }

  return "";
}

/**
 * Classify a CLI worker's full outcome once the round-end marker count has
 * been observed to increase, mirroring classifyApiOutcome's both-markers
 * contract (see its doc comment) for the CLI dispatch path: the packet
 * contract requires BOTH the round begin marker and the round end marker to
 * be present, and a completion that only shows the END marker (begin never
 * observed) must be downgraded the same way a succeeded-but-marker-missing
 * api_llm run is downgraded, not silently accepted as completed.
 *
 * `endStatus` is the caller's classifyCliWorker result for the END marker's
 * own running-minimum comparison (see that function) -- this function only
 * adds the begin-marker gate on top of an already-"completed" endStatus.
 * Any other endStatus ("pending"/"timeout") passes through unchanged: the
 * begin-marker gate only matters once completion is otherwise being
 * declared.
 *
 * Edge case: if packetMarkers.begin is "" (the packet text had no
 * extractable begin-marker literal -- see getPacketMarkers), beginObserved
 * can never become true for that task, so a completed endStatus always
 * downgrades to invalid_output here. This deliberately mirrors
 * classifyApiOutcome's own no-extractable-markers branch (both return
 * invalid_output when the packet itself yielded no marker literal to check
 * against), rather than treating an unextractable marker as an automatic
 * pass.
 *
 * @param {"completed"|"pending"|"timeout"} endStatus classifyCliWorker's
 *   result for the END marker
 * @param {boolean} beginObserved sticky flag: true once any successful
 *   capture for this task showed the begin-marker running count rise above
 *   its seeded baseline (mirrors how the END marker's own baseline/minimum
 *   is tracked)
 * @returns {"completed"|"invalid_output"|"pending"|"timeout"}
 */
export function classifyCliOutcome(endStatus, beginObserved) {
  if (endStatus !== "completed") return endStatus;
  return beginObserved ? "completed" : "invalid_output";
}

/**
 * Count occurrences of a "sha256"-labeled 64-hex-char run in a
 * conversation-panel innerText blob. Used by the runner's dispatch-confirm
 * poll (FIX A) to detect that a NEW dispatch success entry rendered: the
 * poll compares this count against a pre-submit snapshot count and treats
 * any increase as "this dispatch's success entry appeared", without needing
 * to know the specific new hash value in advance (extractLatestSha256 is
 * used separately, after confirmation, to actually read/compare the hash).
 *
 * Deliberately mirrors extractLatestSha256's tolerant "sha256" + nearby
 * 64-hex-char run matching so the two functions never disagree about what
 * counts as a sha256 occurrence.
 *
 * @param {string} text
 * @returns {number}
 */
export function countSha256Occurrences(text) {
  const s = typeof text === "string" ? text : "";
  if (!s) return 0;
  const matches = [...s.matchAll(/sha256[^0-9a-fA-F]{0,20}([0-9a-fA-F]{64})/g)];
  return matches.length;
}

/**
 * Count occurrences of a dispatch-blocked or dispatch-failed conversation
 * notice title in a conversation-panel innerText blob, across both
 * localizations the desktop renders via getLanguageText
 * (dispatchBenchmarkTaskFromOperatorCommand, winsmux-app/src/main.ts):
 * "Benchmark dispatch blocked" / "ベンチ課題投入を停止" and
 * "Benchmark dispatch failed" / "ベンチ課題投入に失敗".
 *
 * Used by the runner's dispatch-confirm poll (FIX A) to detect that the
 * desktop itself rejected or failed this dispatch attempt (missing worker
 * status rows, launch-approval differences, worker-readiness timeout, or an
 * unhandled exception in the dispatch handler), as an alternative terminal
 * signal to the sha256-count-increase success signal.
 *
 * @param {string} text
 * @returns {number}
 */
export function countDispatchBlockedNotices(text) {
  const s = typeof text === "string" ? text : "";
  if (!s) return 0;
  const titleRe = /Benchmark dispatch blocked|ベンチ課題投入を停止|Benchmark dispatch failed|ベンチ課題投入に失敗/g;
  const matches = s.match(titleRe);
  return matches ? matches.length : 0;
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

/**
 * True when the resolved task selection contains the complete official task set,
 * regardless of the order requested on the command line.
 *
 * @param {string[]} taskIds
 * @param {string[]} allTaskIds
 * @returns {boolean}
 */
export function isOfficialTaskSelection(taskIds, allTaskIds) {
  if (!Array.isArray(taskIds) || !Array.isArray(allTaskIds) || taskIds.length !== allTaskIds.length) {
    return false;
  }
  const selected = new Set(taskIds);
  return selected.size === allTaskIds.length && allTaskIds.every((id) => selected.has(id));
}

/**
 * Build a filesystem-safe, deterministic run_id for a single dispatched
 * task's summarize-compatible run directory, derived from the runner run
 * timestamp (already filesystem-safe, e.g. "runner-20260703T041530Z") and the
 * task id. Deterministic so re-running summarize against the same runner
 * output always resolves the same run_id / directory name.
 *
 * @param {string} runTimestampSlug e.g. "runner-20260703T041530Z"
 * @param {string} taskId e.g. "WB-001"
 * @returns {string}
 */
export function buildRunId(runTimestampSlug, taskId) {
  const ts = typeof runTimestampSlug === "string" ? runTimestampSlug : "runner-unknown";
  const task = typeof taskId === "string" ? taskId : "unknown-task";
  const slug = `${ts}-${task}`.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
  return slug || "runner-unknown-task";
}

/**
 * Map the runner's internal per-worker poll status
 * (completed/timeout/failed/blocked/invalid_output/pending/dispatch_failed)
 * into the summarize-consumer status vocabulary used by
 * run-cli-bakeoff-openrouter.ps1's commands.jsonl `status` field and by
 * Get-ScoreabilityDecision in summarize-cli-bakeoff.ps1 (see status literals
 * checked there: 'completed', 'timeout'/'timed_out', 'crash'/'crashed',
 * 'invalid_output'/'invalid_json'/'malformed', otherwise not_completed).
 *
 * The runner's own vocabulary is already aligned with the consumer's for
 * every value it can produce except 'dispatch_failed' (runner-only, meaning
 * the composer submit itself failed before any worker could run) and
 * 'pending' (should never reach this mapping -- a run that finishes the
 * poll loop without a terminal per-worker status is a runner bug, not a
 * task outcome). Both are mapped to 'failed' as the safe non-completed
 * fallback rather than silently passing through an unrecognized status
 * string summarize would otherwise report as 'unknown'.
 *
 * @param {string} runnerStatus
 * @returns {"completed"|"timeout"|"failed"|"blocked"|"invalid_output"}
 */
export function mapRunnerStatusToCommandStatus(runnerStatus) {
  switch (runnerStatus) {
    case "completed":
    case "timeout":
    case "failed":
    case "blocked":
    case "invalid_output":
      return runnerStatus;
    case "dispatch_failed":
    case "pending":
    default:
      return "failed";
  }
}

/**
 * Build the summarize-compatible manifest.json object for one dispatched
 * task's run directory, mirroring the field shapes written by
 * run-cli-bakeoff-openrouter.ps1's final manifest (run_id, task_class,
 * recording, evidence, active_workers, execution, run_governance) as read by
 * summarize-cli-bakeoff.ps1 (lines ~160-260).
 *
 * cli/model metadata is not knowable to this runner today: worker rows are
 * parsed from manifest.yaml (pane_id only) rather than fetched from the
 * benchmark pack's `default_workers` list the way the openrouter runner
 * does, so active_workers entries here honestly report 'unknown' rather
 * than inventing a cli/model pairing. See run-cli-bakeoff.mjs's call site
 * for the code comment tracking this gap.
 *
 * packet_hash_match is now a genuinely verified value (round-7 fix): the
 * runner independently reconstructs the exact dispatch prompt via
 * buildHarnessPromptMirror, hashes it with node:crypto, reads the
 * desktop-displayed sha256 out of the conversation panel via
 * extractLatestSha256, and passes in the equality result. true means the
 * desktop-displayed sha256 equals the independently reconstructed prompt
 * hash; false means either they differ or the desktop hash could not be
 * read at all. It is never fabricated true.
 *
 * @param {{
 *   runId: string,
 *   taskId: string,
 *   taskClass: string,
 *   activeWorkers: Array<{worker: string, cli: string, model: string, role: string, pane: string}>,
 *   endMarkerPresent: boolean,
 *   packetHashMatch: boolean,
 *   recordingStatus: string,
 *   recordingPublishable: boolean,
 *   executionStatus: string,
 *   generatedAtIso: string,
 *   scoreableGovernance: boolean,
 * }} input
 * @returns {object}
 */
export function buildRunManifest(input) {
  const {
    runId,
    taskId,
    taskClass,
    activeWorkers,
    endMarkerPresent,
    packetHashMatch,
    recordingStatus,
    recordingPublishable,
    executionStatus,
    generatedAtIso,
    scoreableGovernance = true,
  } = input || {};
  const governanceExecutionSurface = scoreableGovernance
    ? "visible_desktop_worker_panes"
    : "partial_visible_desktop_worker_panes";

  return {
    run_id: runId,
    task_id: taskId,
    task_class: taskClass || "unknown",
    generated_at_utc: generatedAtIso,
    active_workers: Array.isArray(activeWorkers) ? activeWorkers : [],
    recording: {
      status: recordingStatus || "not_declared",
      publishable: !!recordingPublishable,
    },
    evidence: {
      // Honest per-run rollup: true only when every worker's own
      // end_marker_present (in commands.jsonl) is true. The runner passes
      // the already-aggregated boolean in rather than recomputing it here
      // to keep this function a pure mirror of its single input.
      end_marker_present: !!endMarkerPresent,
      // Verified = desktop-displayed sha256 equals the independently
      // reconstructed prompt hash; false when the desktop hash could not be
      // read. See function doc comment above.
      packet_hash_match: !!packetHashMatch,
    },
    execution: {
      status: executionStatus || "unknown",
    },
    run_governance: {
      messaging_state: "worker_to_worker_disabled",
      operator_intervention_count: 0,
      execution_surface: governanceExecutionSurface,
    },
  };
}

/**
 * Build one commands.jsonl row (a single worker's outcome for a single
 * task), mirroring the openrouter runner's per-worker $command object
 * shape (cli, model, role, pane, task_id, task_class, status,
 * elapsed_seconds, end_marker_present, packet_hash_match).
 *
 * @param {{
 *   worker: string,
 *   cli: string,
 *   model: string,
 *   role: string,
 *   pane: string,
 *   taskId: string,
 *   taskClass: string,
 *   runnerStatus: string,
 *   elapsedSeconds: number,
 *   endMarkerPresent: boolean,
 *   packetHashMatch: boolean,
 * }} input
 * @returns {object}
 */
export function buildCommandRow(input) {
  const {
    worker,
    cli,
    model,
    role,
    pane,
    taskId,
    taskClass,
    runnerStatus,
    elapsedSeconds,
    endMarkerPresent,
    packetHashMatch,
  } = input || {};

  return {
    worker: worker || "unknown",
    cli: cli || "unknown",
    model: model || "unknown",
    role: role || "unknown",
    pane: pane || "unknown",
    task_id: taskId,
    task_class: taskClass || "unknown",
    status: mapRunnerStatusToCommandStatus(runnerStatus),
    elapsed_seconds: Number.isFinite(elapsedSeconds) ? Math.round(elapsedSeconds * 1000) / 1000 : null,
    end_marker_present: !!endMarkerPresent,
    // Verified = desktop-displayed sha256 equals the independently
    // reconstructed prompt hash; false when the desktop hash could not be
    // read. Never fabricated true. See buildRunManifest's doc comment.
    packet_hash_match: !!packetHashMatch,
  };
}

/**
 * Extract the captured pane text out of a `pty_capture` Tauri command
 * result value (round-9 fix, see run-cli-bakeoff.mjs's capturePane).
 *
 * The command (capture_pty in winsmux-app/src-tauri/src/lib.rs:1336-1356)
 * returns `serde_json::json!({ "paneId": pane_id, "output": output })`,
 * which is also PtyCaptureResult's shape on the TypeScript side
 * (winsmux-app/src/ptyClient.ts:49-52: `{ paneId: string; output: string }`).
 * Over CDP's Runtime.evaluate this arrives already deserialized as a plain
 * JS object (not a JSON string needing a second parse), so this function
 * takes the parsed value directly and just reads its `output` field.
 *
 * Returns null (not "") when the field is missing/not a string, so callers
 * can distinguish "genuinely empty pane" from "unexpected result shape" and
 * treat the latter as a capture failure rather than an empty pane.
 *
 * @param {unknown} resultValue the `result` field of the invoke response
 * @returns {string|null}
 */
export function extractPtyCaptureText(resultValue) {
  if (!resultValue || typeof resultValue !== "object") return null;
  const output = resultValue.output;
  return typeof output === "string" ? output : null;
}
