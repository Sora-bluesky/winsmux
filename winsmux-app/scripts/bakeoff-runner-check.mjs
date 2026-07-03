import assert from "node:assert/strict";
import {
  parseManifestPaneIds,
  collectReadyWorkers,
  countCompletionMarkerLines,
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

// --- countCompletionMarkerLines -------------------------------------------

assert.equal(countCompletionMarkerLines(""), 0, "countCompletionMarkerLines must return 0 for empty text");
assert.equal(countCompletionMarkerLines("no marker here"), 0, "countCompletionMarkerLines must return 0 when marker absent");
assert.equal(
  countCompletionMarkerLines("task 1 done\nBAKEOFF_ROUND_A_END\nmore text"),
  1,
  "countCompletionMarkerLines must count a bare worker-printed marker line",
);
assert.equal(
  countCompletionMarkerLines("> BAKEOFF_ROUND_A_END"),
  1,
  "countCompletionMarkerLines must allow bare TUI decoration (prompt chevron) around the marker",
);
assert.equal(
  countCompletionMarkerLines("5. `BAKEOFF_ROUND_A_END`"),
  0,
  "countCompletionMarkerLines must not count the packet's backtick-wrapped instruction line echoed into the pane at dispatch",
);
assert.equal(
  countCompletionMarkerLines("  5. BAKEOFF_ROUND_A_END"),
  0,
  "countCompletionMarkerLines must not count a numbered instruction step even when a TUI strips the backticks",
);
assert.equal(
  countCompletionMarkerLines("I will print BAKEOFF_ROUND_A_END when finished"),
  0,
  "countCompletionMarkerLines must not count the worker narrating the marker inside prose",
);
assert.equal(
  countCompletionMarkerLines("Pack: winsmux-cli-bakeoff-v1\n5. `BAKEOFF_ROUND_A_END`\nwork output\nBAKEOFF_ROUND_A_END"),
  1,
  "countCompletionMarkerLines must count only the worker's own completion line when the echoed packet is also visible",
);
assert.equal(
  countCompletionMarkerLines("BAKEOFF_ROUND_A_END\nsome output\nBAKEOFF_ROUND_A_END"),
  2,
  "countCompletionMarkerLines must count multiple worker-printed marker lines across a pane transcript",
);
assert.equal(
  countCompletionMarkerLines("BAKEOFF_ROUND_B_END\nBAKEOFF_ROUND_A_END", "BAKEOFF_ROUND_B_END"),
  1,
  "countCompletionMarkerLines must count only the requested round's marker, ignoring other rounds' markers",
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
assert.equal(manifestObj.evidence.packet_hash_match, false, "buildRunManifest must never fabricate packet_hash_match=true");
assert.equal(manifestObj.execution.status, "completed", "buildRunManifest must set execution.status from input");
assert.equal(manifestObj.active_workers.length, 1, "buildRunManifest must carry through active_workers array");

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
assert.equal(commandRow.packet_hash_match, false, "buildCommandRow must never fabricate packet_hash_match=true");
assert.equal(commandRow.task_id, "WB-001", "buildCommandRow must carry through task_id");

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

console.log("bakeoff-runner-check: ok");
