import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  parseManifestPaneIds,
  collectReadyWorkers,
  countEndMarkers,
  taskIdToEndMarker,
  classifyApiRun,
  classifyApiOutcome,
  getPacketMarkers,
  classifyCliWorker,
  selectNewRunDir,
  buildReadyCheckCommand,
  buildDispatchCommand,
  resolveTaskSelection,
  buildRunId,
  mapRunnerStatusToCommandStatus,
  buildRunManifest,
  buildCommandRow,
  buildHarnessPromptMirror,
  extractLatestSha256,
  classifyCliOutcome,
  countSha256Occurrences,
  countDispatchBlockedNotices,
  extractPtyCaptureText,
} from "./bakeoff-runner-lib.mjs";

// --- parseManifestPaneIds ---------------------------------------------

const manifestFixture = [
  "version: '1'",
  "saved_at: '2026-07-02T20:27:30.0317629+09:00'",
  "session:",
  "  name: 'winsmux-orchestra'",
  "  status: 'running'",
  "  ui_attached: 'true'",
  "panes:",
  "  'worker-1':",
  "    pane_id: '%2'",
  "    slot_id: 'worker-1'",
  "    worker_backend: 'local'",
  "  'worker-2':",
  "    pane_id: '%5'",
  "    slot_id: 'worker-2'",
  "  'worker-3':",
  "    pane_id: '%4'",
  "  'worker-4':",
  "    pane_id: '%3'",
  "  'worker-5':",
  "    pane_id: '%7'",
  "  'worker-6':",
  "    pane_id: '%6'",
  "trailing_top_level_key: 'should-not-leak-into-panes'",
].join("\n");

assert.deepEqual(
  parseManifestPaneIds(manifestFixture),
  {
    "worker-1": "%2",
    "worker-2": "%5",
    "worker-3": "%4",
    "worker-4": "%3",
    "worker-5": "%7",
    "worker-6": "%6",
  },
  "parseManifestPaneIds must extract all six worker pane_id mappings and stop at the next top-level key",
);

assert.deepEqual(parseManifestPaneIds(""), {}, "parseManifestPaneIds must return {} for empty input");
assert.deepEqual(parseManifestPaneIds("no panes block here"), {}, "parseManifestPaneIds must return {} when there is no panes: block");

// --- collectReadyWorkers -------------------------------------------------

const headTexts = [
  "worker-1 Claude Code / Claude Opus 4.8 ready for benchmark",
  "worker-2 Codex / gpt-5.5",
  "worker-3 Antigravity CLI ready for benchmark",
  "worker-4 Gemini CLI ベンチ投入可能",
  "",
];
assert.deepEqual(
  collectReadyWorkers(headTexts),
  new Set(["worker-1", "worker-3", "worker-4"]),
  "collectReadyWorkers must match both the English and the localized (Japanese) ready badge, and only for workers whose header shows one",
);
assert.deepEqual(collectReadyWorkers([]), new Set(), "collectReadyWorkers must return empty set for empty input");
assert.deepEqual(collectReadyWorkers(undefined), new Set(), "collectReadyWorkers must tolerate non-array input");

// --- countEndMarkers -------------------------------------------------------
//
// Strategy note (round-7 fix, baseline-timing updated round-8): completion
// detection is no longer line-shape filtering. Every packet instructs the
// worker to return a numbered list whose item 5 IS the round END marker
// (e.g. "5. BAKEOFF_ROUND_A_END", often backtick-wrapped) -- a compliant
// completion is therefore indistinguishable, by line shape, from the
// dispatch echo of that same packet text. countEndMarkers is now an honest
// raw substring occurrence count; echo disambiguation happens in the RUNNER
// by seeding its baseline AFTER dispatch has been CONFIRMED via the
// conversation-panel poll (countSha256Occurrences /
// countDispatchBlockedNotices, plus ECHO_RENDER_SETTLE_MS in
// run-cli-bakeoff.mjs), once the echo is already on screen -- not by
// filtering line shapes here. Do not reintroduce line filtering in this
// function.

assert.equal(countEndMarkers(""), 0, "countEndMarkers must return 0 for empty text");
assert.equal(countEndMarkers("no marker here"), 0, "countEndMarkers must return 0 when marker absent");
assert.equal(
  countEndMarkers("task 1 done\nBAKEOFF_ROUND_A_END\nmore text"),
  1,
  "countEndMarkers must count a bare marker occurrence",
);
assert.equal(
  countEndMarkers("5. BAKEOFF_ROUND_A_END"),
  1,
  "countEndMarkers must count a compliant numbered-list completion line (digits present)",
);
assert.equal(
  countEndMarkers("5. `BAKEOFF_ROUND_A_END`"),
  1,
  "countEndMarkers must count a backtick-wrapped marker occurrence (digits and backticks no longer disqualify)",
);
assert.equal(
  countEndMarkers("5. `BAKEOFF_ROUND_A_END`\nwork output\nBAKEOFF_ROUND_A_END"),
  2,
  "countEndMarkers must count every occurrence, including both an echoed instruction line and a later bare line",
);
assert.equal(
  countEndMarkers("BAKEOFF_ROUND_A_END\nsome output\nBAKEOFF_ROUND_A_END"),
  2,
  "countEndMarkers must count multiple marker occurrences across a pane transcript",
);
assert.equal(
  countEndMarkers("BAKEOFF_ROUND_B_END\nBAKEOFF_ROUND_A_END", "BAKEOFF_ROUND_B_END"),
  1,
  "countEndMarkers must count only the requested round's marker, ignoring other rounds' markers",
);

// --- taskIdToEndMarker -----------------------------------------------------

assert.equal(
  taskIdToEndMarker("WB-001"),
  "BAKEOFF_ROUND_A_END",
  "taskIdToEndMarker must map the first round-A task id to BAKEOFF_ROUND_A_END",
);
assert.equal(
  taskIdToEndMarker("WB-009"),
  "BAKEOFF_ROUND_A_END",
  "taskIdToEndMarker must map the last round-A task id (WB-009) to BAKEOFF_ROUND_A_END",
);
assert.equal(
  taskIdToEndMarker("WB-010"),
  "BAKEOFF_ROUND_B_END",
  "taskIdToEndMarker must map the first round-B task id (WB-010) to BAKEOFF_ROUND_B_END",
);
assert.equal(
  taskIdToEndMarker("WB-018"),
  "BAKEOFF_ROUND_B_END",
  "taskIdToEndMarker must map the last round-B task id (WB-018) to BAKEOFF_ROUND_B_END",
);
assert.equal(
  taskIdToEndMarker("WB-019"),
  "BAKEOFF_ROUND_C_END",
  "taskIdToEndMarker must map the first round-C task id (WB-019) to BAKEOFF_ROUND_C_END",
);
assert.equal(
  taskIdToEndMarker("WB-027"),
  "BAKEOFF_ROUND_C_END",
  "taskIdToEndMarker must map the last round-C task id (WB-027) to BAKEOFF_ROUND_C_END",
);
assert.equal(
  taskIdToEndMarker("bogus"),
  "BAKEOFF_ROUND_A_END",
  "taskIdToEndMarker must fall back to round A for an unparsable task id rather than throwing",
);

// --- classifyApiRun ---------------------------------------------------

assert.equal(
  classifyApiRun(JSON.stringify({ status: "succeeded" })),
  "completed",
  "classifyApiRun must classify status=succeeded as completed",
);
assert.equal(
  classifyApiRun(JSON.stringify({ status: "failed", reason: "network error" })),
  "failed",
  "classifyApiRun must classify status=failed as failed",
);
assert.equal(
  classifyApiRun(JSON.stringify({ status: "blocked", reason: "api_llm_runner_unconfigured" })),
  "blocked",
  "classifyApiRun must classify a persisted status=blocked run.json (missing key / unconfigured runner) as terminal blocked, not pending",
);
assert.equal(
  classifyApiRun(JSON.stringify({ status: "running" })),
  "pending",
  "classifyApiRun must classify an in-progress status as pending",
);
assert.equal(classifyApiRun(""), "pending", "classifyApiRun must classify empty/missing run.json as pending");
assert.equal(classifyApiRun("{not json"), "pending", "classifyApiRun must classify unparsable JSON as pending, not throw");
assert.equal(
  classifyApiRun(JSON.stringify({ status: "SUCCEEDED" })),
  "completed",
  "classifyApiRun must be case-insensitive on status",
);

// --- classifyCliWorker --------------------------------------------------

assert.equal(
  classifyCliWorker(0, 1, 30, 3600),
  "completed",
  "classifyCliWorker must classify a marker-count increase as completed",
);
assert.equal(
  classifyCliWorker(1, 1, 30, 3600),
  "pending",
  "classifyCliWorker must classify no marker-count change (well under timeout) as pending",
);
assert.equal(
  classifyCliWorker(5, 5, 5, 3600),
  "pending",
  "classifyCliWorker must stay pending immediately after dispatch when the baseline was seeded from " +
    "leftover markers from a previous run (minObservedCount=5 carried over, currCount unchanged) -- it must not " +
    "misread stale markers as this task's own completion",
);
assert.equal(
  classifyCliWorker(5, 6, 5, 3600),
  "completed",
  "classifyCliWorker must classify completion correctly once the marker count rises above a seeded " +
    "non-zero baseline (minObservedCount=5 from leftover markers, currCount=6 after this task's own marker)",
);

// P1 scroll-off scenario (visible-rows-only capture): the previous task's
// marker is on screen at dispatch (baseline 1), scrolls off mid-task (the
// runner lowers the baseline to the observed 0), then this task's own marker
// appears and must register against the lowered baseline.
assert.equal(
  classifyCliWorker(1, 1, 30, 3600),
  "pending",
  "classifyCliWorker must stay pending while only the previous task's marker is visible",
);
assert.equal(
  classifyCliWorker(0, 0, 300, 3600),
  "pending",
  "classifyCliWorker must stay pending after the leftover marker scrolled off and the caller lowered the baseline",
);
assert.equal(
  classifyCliWorker(0, 1, 600, 3600),
  "completed",
  "classifyCliWorker must classify this task's own marker as completed against the lowered baseline",
);

assert.equal(
  classifyCliWorker(1, 1, 3600, 3600),
  "timeout",
  "classifyCliWorker must classify no marker-count change at/after timeout as timeout",
);
assert.equal(
  classifyCliWorker(1, 1, 4000, 3600),
  "timeout",
  "classifyCliWorker must classify no marker-count change past timeout as timeout",
);
assert.equal(
  classifyCliWorker(1, 2, 3700, 3600),
  "completed",
  "classifyCliWorker must prefer completed over timeout when the marker count did increase, even past the timeout boundary",
);

// --- selectNewRunDir ------------------------------------------------------

assert.equal(
  selectNewRunDir(
    [
      { name: "dispatch-aaa-worker-5", mtimeMs: 1000 },
      { name: "dispatch-bbb-worker-5", mtimeMs: 2000 },
    ],
    1500,
  ),
  "dispatch-bbb-worker-5",
  "selectNewRunDir must pick the newest dir at/after the threshold by mtime",
);
assert.equal(
  selectNewRunDir(
    [
      { name: "dispatch-aaa-worker-5", mtimeMs: 1000 },
      { name: "dispatch-bbb-worker-5", mtimeMs: 2000 },
    ],
    5000,
  ),
  null,
  "selectNewRunDir must return null when no directory was created since the threshold",
);
assert.equal(
  selectNewRunDir(["not-a-dispatch-dir", "dispatch-ccc-worker-6"]),
  "dispatch-ccc-worker-6",
  "selectNewRunDir must ignore non-dispatch-prefixed entries and fall back to lexicographic selection without mtime",
);
assert.equal(selectNewRunDir([]), null, "selectNewRunDir must return null for an empty list");
assert.equal(selectNewRunDir(undefined), null, "selectNewRunDir must tolerate non-array input");

// --- command builders ----------------------------------------------------

assert.equal(
  buildReadyCheckCommand(),
  "winsmux benchmark ready-check",
  "buildReadyCheckCommand must return the exact verified command string",
);
assert.equal(
  buildDispatchCommand("WB-001"),
  "winsmux benchmark dispatch task WB-001",
  "buildDispatchCommand must return the exact verified command format with the task id substituted",
);

// --- resolveTaskSelection -------------------------------------------------

const allTaskIds = ["WB-001", "WB-002", "WB-003"];
assert.deepEqual(
  resolveTaskSelection(allTaskIds, undefined),
  { taskIds: ["WB-001", "WB-002", "WB-003"], unknown: [] },
  "resolveTaskSelection must return the full task list when no selection is requested",
);
assert.deepEqual(
  resolveTaskSelection(allTaskIds, "WB-002,WB-001"),
  { taskIds: ["WB-002", "WB-001"], unknown: [] },
  "resolveTaskSelection must honor requested order for a comma-separated string",
);
assert.deepEqual(
  resolveTaskSelection(allTaskIds, ["WB-002", "WB-999"]),
  { taskIds: ["WB-002"], unknown: ["WB-999"] },
  "resolveTaskSelection must drop unknown ids from the run list but report them",
);
assert.deepEqual(
  resolveTaskSelection(allTaskIds, "WB-001,WB-001"),
  { taskIds: ["WB-001"], unknown: [] },
  "resolveTaskSelection must de-duplicate repeated requested ids",
);

// --- getPacketMarkers -----------------------------------------------------

assert.deepEqual(
  getPacketMarkers("1. `BAKEOFF_ROUND_A_BEGIN`\n...\n5. `BAKEOFF_ROUND_A_END`"),
  { begin: "BAKEOFF_ROUND_A_BEGIN", end: "BAKEOFF_ROUND_A_END" },
  "getPacketMarkers must extract both begin and end marker literals from packet text",
);
assert.deepEqual(
  getPacketMarkers(""),
  { begin: "", end: "" },
  "getPacketMarkers must return empty strings for empty input",
);
assert.deepEqual(
  getPacketMarkers("no markers here"),
  { begin: "", end: "" },
  "getPacketMarkers must return empty strings when no marker literals are present",
);

// --- classifyApiOutcome ----------------------------------------------------

const markersA = { begin: "BAKEOFF_ROUND_A_BEGIN", end: "BAKEOFF_ROUND_A_END" };

assert.equal(
  classifyApiOutcome(
    JSON.stringify({ status: "succeeded" }),
    "BAKEOFF_ROUND_A_BEGIN\nsome work\nBAKEOFF_ROUND_A_END",
    markersA,
  ),
  "completed",
  "classifyApiOutcome must classify succeeded + both markers present as completed",
);
assert.equal(
  classifyApiOutcome(
    JSON.stringify({ status: "succeeded" }),
    "BAKEOFF_ROUND_A_BEGIN\nsome work only, no end marker",
    markersA,
  ),
  "invalid_output",
  "classifyApiOutcome must downgrade succeeded + missing end marker to invalid_output",
);
assert.equal(
  classifyApiOutcome(
    JSON.stringify({ status: "succeeded" }),
    "no markers at all in this response",
    markersA,
  ),
  "invalid_output",
  "classifyApiOutcome must downgrade succeeded + missing both markers to invalid_output",
);
assert.equal(
  classifyApiOutcome(JSON.stringify({ status: "blocked", reason: "api_llm_runner_unconfigured" }), "", markersA),
  "blocked",
  "classifyApiOutcome must pass through blocked unchanged regardless of response text/markers",
);
assert.equal(
  classifyApiOutcome(JSON.stringify({ status: "failed" }), "", markersA),
  "failed",
  "classifyApiOutcome must pass through failed unchanged regardless of response text/markers",
);
assert.equal(
  classifyApiOutcome(JSON.stringify({ status: "running" }), "", markersA),
  "pending",
  "classifyApiOutcome must pass through pending unchanged",
);
assert.equal(
  classifyApiOutcome(
    JSON.stringify({ status: "succeeded" }),
    "BAKEOFF_ROUND_A_BEGIN\nBAKEOFF_ROUND_A_END",
    { begin: "", end: "" },
  ),
  "invalid_output",
  "classifyApiOutcome must downgrade to invalid_output when the packet itself had no extractable markers",
);

// --- buildRunId -------------------------------------------------------

assert.equal(
  buildRunId("runner-20260703T041530Z", "WB-001"),
  "runner-20260703t041530z-wb-001",
  "buildRunId must produce a deterministic, filesystem-safe, lowercased slug from runner timestamp + task id",
);
assert.equal(
  buildRunId("runner-20260703T041530Z", "WB-001"),
  buildRunId("runner-20260703T041530Z", "WB-001"),
  "buildRunId must be deterministic for identical inputs",
);
assert.notEqual(
  buildRunId("runner-20260703T041530Z", "WB-001"),
  buildRunId("runner-20260703T041530Z", "WB-002"),
  "buildRunId must differ for different task ids",
);

// --- mapRunnerStatusToCommandStatus ----------------------------------------

assert.equal(mapRunnerStatusToCommandStatus("completed"), "completed", "mapRunnerStatusToCommandStatus must pass through completed");
assert.equal(mapRunnerStatusToCommandStatus("timeout"), "timeout", "mapRunnerStatusToCommandStatus must pass through timeout");
assert.equal(mapRunnerStatusToCommandStatus("failed"), "failed", "mapRunnerStatusToCommandStatus must pass through failed");
assert.equal(mapRunnerStatusToCommandStatus("blocked"), "blocked", "mapRunnerStatusToCommandStatus must pass through blocked");
assert.equal(mapRunnerStatusToCommandStatus("invalid_output"), "invalid_output", "mapRunnerStatusToCommandStatus must pass through invalid_output");
assert.equal(mapRunnerStatusToCommandStatus("dispatch_failed"), "failed", "mapRunnerStatusToCommandStatus must map runner-only dispatch_failed to failed");
assert.equal(mapRunnerStatusToCommandStatus("pending"), "failed", "mapRunnerStatusToCommandStatus must map a leftover pending status (runner bug guard) to failed");
assert.equal(mapRunnerStatusToCommandStatus("something-unrecognized"), "failed", "mapRunnerStatusToCommandStatus must map any unrecognized status to failed as the safe fallback");

// --- buildRunManifest -------------------------------------------------

const manifestObj = buildRunManifest({
  runId: "runner-20260703t041530z-wb-001",
  taskId: "WB-001",
  taskClass: "investigation_design",
  activeWorkers: [
    { worker: "worker-1", cli: "unknown", model: "unknown", role: "unknown", pane: "%2", status: "completed" },
  ],
  endMarkerPresent: true,
  recordingStatus: "not_declared",
  recordingPublishable: false,
  executionStatus: "completed",
  generatedAtIso: "2026-07-03T04:15:30.000Z",
});
assert.equal(manifestObj.run_id, "runner-20260703t041530z-wb-001", "buildRunManifest must set run_id from input");
assert.equal(manifestObj.task_class, "investigation_design", "buildRunManifest must set task_class from input");
assert.deepEqual(manifestObj.recording, { status: "not_declared", publishable: false }, "buildRunManifest must build recording object with input status/publishable");
assert.equal(manifestObj.evidence.end_marker_present, true, "buildRunManifest must set evidence.end_marker_present from input");
assert.equal(manifestObj.evidence.packet_hash_match, false, "buildRunManifest must default packet_hash_match to false when not passed true");
assert.equal(manifestObj.execution.status, "completed", "buildRunManifest must set execution.status from input");
assert.equal(manifestObj.active_workers.length, 1, "buildRunManifest must carry through active_workers array");

const manifestHashTrue = buildRunManifest({
  runId: "r",
  taskId: "WB-001",
  packetHashMatch: true,
});
assert.equal(manifestHashTrue.evidence.packet_hash_match, true, "buildRunManifest must pass through a genuinely verified packetHashMatch=true");

const manifestDefaults = buildRunManifest({ runId: "r", taskId: "WB-001" });
assert.equal(manifestDefaults.task_class, "unknown", "buildRunManifest must default task_class to unknown when absent");
assert.equal(manifestDefaults.recording.status, "not_declared", "buildRunManifest must default recording.status to not_declared");
assert.equal(manifestDefaults.recording.publishable, false, "buildRunManifest must default recording.publishable to false");
assert.equal(manifestDefaults.execution.status, "unknown", "buildRunManifest must default execution.status to unknown");
assert.deepEqual(manifestDefaults.active_workers, [], "buildRunManifest must default active_workers to an empty array");

// --- buildCommandRow ----------------------------------------------------

const commandRow = buildCommandRow({
  worker: "worker-1",
  cli: "unknown",
  model: "unknown",
  role: "unknown",
  pane: "%2",
  taskId: "WB-001",
  taskClass: "investigation_design",
  runnerStatus: "completed",
  elapsedSeconds: 12.3456,
  endMarkerPresent: true,
});
assert.equal(commandRow.status, "completed", "buildCommandRow must map runnerStatus through mapRunnerStatusToCommandStatus");
assert.equal(commandRow.elapsed_seconds, 12.346, "buildCommandRow must round elapsed_seconds to 3 decimal places");
assert.equal(commandRow.end_marker_present, true, "buildCommandRow must carry through end_marker_present");
assert.equal(commandRow.packet_hash_match, false, "buildCommandRow must default packet_hash_match to false when not passed true");
assert.equal(commandRow.task_id, "WB-001", "buildCommandRow must carry through task_id");

const commandRowHashTrue = buildCommandRow({
  worker: "worker-1",
  taskId: "WB-001",
  runnerStatus: "completed",
  elapsedSeconds: 1,
  endMarkerPresent: true,
  packetHashMatch: true,
});
assert.equal(commandRowHashTrue.packet_hash_match, true, "buildCommandRow must pass through a genuinely verified packetHashMatch=true");

const commandRowTimeout = buildCommandRow({
  worker: "worker-2",
  taskId: "WB-001",
  runnerStatus: "timeout",
  elapsedSeconds: null,
  endMarkerPresent: false,
});
assert.equal(commandRowTimeout.status, "timeout", "buildCommandRow must map timeout status through");
assert.equal(commandRowTimeout.elapsed_seconds, null, "buildCommandRow must pass through null elapsed_seconds rather than coercing to 0/NaN");
assert.equal(commandRowTimeout.cli, "unknown", "buildCommandRow must default cli to unknown when absent");

// --- buildHarnessPromptMirror / extractLatestSha256 -------------------

const mirrorPack = { pack_id: "winsmux-cli-bakeoff-v1", default_timeout_seconds: 3600 };
const mirrorTask = { task_id: "WB-001", title: "Sample Task", timeout_seconds: 1800 };
const mirrorPrompt = buildHarnessPromptMirror(mirrorPack, mirrorTask, "  Do the thing.  \n");
assert.equal(
  mirrorPrompt,
  [
    "Harness Bench task packet",
    "Pack: winsmux-cli-bakeoff-v1",
    "Task: WB-001",
    "Title: Sample Task",
    "Timeout seconds: 1800",
    "",
    "Instructions:",
    "Do the thing.",
    "",
  ].join("\n"),
  "buildHarnessPromptMirror must reproduce the exact desktop prompt string (header lines + trimmed packet content + trailing blank line)",
);

// The check file (not the pure lib) is allowed to compute sha256 itself, to
// avoid ever hardcoding an expected hash by hand.
const mirrorSha = createHash("sha256").update(mirrorPrompt, "utf8").digest("hex");
assert.equal(mirrorSha.length, 64, "sanity: computed sha256 hex digest must be 64 chars");

assert.equal(
  extractLatestSha256(`sha256: ${mirrorSha}`),
  mirrorSha,
  "extractLatestSha256 must extract a 64-hex value following a sha256 label",
);
assert.equal(
  extractLatestSha256(`some other detail\nsha256   ${mirrorSha}\nmore text`),
  mirrorSha,
  "extractLatestSha256 must tolerate whitespace/punctuation between the sha256 label and the hex value",
);
const otherHash = "a".repeat(64);
assert.equal(
  extractLatestSha256(`sha256: ${otherHash}\nsha256: ${mirrorSha}`),
  mirrorSha,
  "extractLatestSha256 must return the LAST labeled sha256 match when multiple are present",
);
assert.equal(
  extractLatestSha256(`no label here, just a bare hex run ${mirrorSha} in the middle of text`),
  mirrorSha,
  "extractLatestSha256 must fall back to the last bare 64-hex-char run when no sha256 label is found",
);
assert.equal(
  extractLatestSha256("nothing hashy here"),
  "",
  "extractLatestSha256 must return empty string when no hash-shaped text is found",
);
assert.equal(extractLatestSha256(""), "", "extractLatestSha256 must return empty string for empty input");
assert.equal(extractLatestSha256(undefined), "", "extractLatestSha256 must tolerate non-string input");

// --- classifyCliOutcome -----------------------------------------------

assert.equal(
  classifyCliOutcome("completed", true),
  "completed",
  "classifyCliOutcome must classify completed+beginObserved=true as completed",
);
assert.equal(
  classifyCliOutcome("completed", false),
  "invalid_output",
  "classifyCliOutcome must downgrade completed+beginObserved=false to invalid_output (END marker seen but BEGIN marker never observed)",
);
assert.equal(
  classifyCliOutcome("pending", false),
  "pending",
  "classifyCliOutcome must pass through pending unchanged regardless of beginObserved",
);
assert.equal(
  classifyCliOutcome("timeout", false),
  "timeout",
  "classifyCliOutcome must pass through timeout unchanged regardless of beginObserved",
);
assert.equal(
  classifyCliOutcome("timeout", true),
  "timeout",
  "classifyCliOutcome must pass through timeout unchanged even when beginObserved=true",
);

// --- countSha256Occurrences ------------------------------------------------

assert.equal(countSha256Occurrences(""), 0, "countSha256Occurrences must return 0 for empty text");
assert.equal(countSha256Occurrences("nothing hashy here"), 0, "countSha256Occurrences must return 0 when no sha256-labeled hash is present");
assert.equal(
  countSha256Occurrences(`sha256: ${"a".repeat(64)}`),
  1,
  "countSha256Occurrences must count a single sha256-labeled hash",
);
assert.equal(
  countSha256Occurrences(`sha256: ${"a".repeat(64)}\nsha256   ${"b".repeat(64)}`),
  2,
  "countSha256Occurrences must count multiple sha256-labeled hashes",
);
assert.equal(
  countSha256Occurrences(undefined),
  0,
  "countSha256Occurrences must tolerate non-string input",
);

// --- countDispatchBlockedNotices ---------------------------------------

assert.equal(countDispatchBlockedNotices(""), 0, "countDispatchBlockedNotices must return 0 for empty text");
assert.equal(countDispatchBlockedNotices("all clear"), 0, "countDispatchBlockedNotices must return 0 when no blocked/failed notice title is present");
assert.equal(
  countDispatchBlockedNotices("Benchmark dispatch blocked: missing worker status rows"),
  1,
  "countDispatchBlockedNotices must match the English 'Benchmark dispatch blocked' title",
);
assert.equal(
  countDispatchBlockedNotices("ベンチ課題投入を停止しました"),
  1,
  "countDispatchBlockedNotices must match the localized 'ベンチ課題投入を停止' title",
);
assert.equal(
  countDispatchBlockedNotices("Benchmark dispatch failed: unexpected error"),
  1,
  "countDispatchBlockedNotices must match the English 'Benchmark dispatch failed' title",
);
assert.equal(
  countDispatchBlockedNotices("ベンチ課題投入に失敗しました"),
  1,
  "countDispatchBlockedNotices must match the localized 'ベンチ課題投入に失敗' title",
);
assert.equal(
  countDispatchBlockedNotices("Benchmark dispatch blocked\nベンチ課題投入を停止\nBenchmark dispatch failed\nベンチ課題投入に失敗"),
  4,
  "countDispatchBlockedNotices must count multiple distinct notice titles in the same text",
);
assert.equal(
  countDispatchBlockedNotices(undefined),
  0,
  "countDispatchBlockedNotices must tolerate non-string input",
);

// --- extractPtyCaptureText -------------------------------------------

assert.equal(
  extractPtyCaptureText({ paneId: "worker-1", output: "hello pane text" }),
  "hello pane text",
  "extractPtyCaptureText must extract the output field from a pty_capture result object",
);
assert.equal(
  extractPtyCaptureText({ paneId: "worker-1", output: "" }),
  "",
  "extractPtyCaptureText must return an empty string for a genuinely empty pane, not null",
);
assert.equal(
  extractPtyCaptureText({ paneId: "worker-1" }),
  null,
  "extractPtyCaptureText must return null when the output field is missing",
);
assert.equal(
  extractPtyCaptureText({ paneId: "worker-1", output: 12345 }),
  null,
  "extractPtyCaptureText must return null when output is not a string",
);
assert.equal(extractPtyCaptureText(null), null, "extractPtyCaptureText must return null for null input");
assert.equal(extractPtyCaptureText(undefined), null, "extractPtyCaptureText must return null for undefined input");
assert.equal(extractPtyCaptureText("not an object"), null, "extractPtyCaptureText must return null for non-object input");

console.log("bakeoff-runner-check: ok");
