import assert from "node:assert/strict";
import {
  parseManifestPaneIds,
  collectReadyWorkers,
  countCompletionMarkerLines,
  taskIdToEndMarker,
  classifyApiRun,
  classifyCliWorker,
  selectNewRunDir,
  buildReadyCheckCommand,
  buildDispatchCommand,
  resolveTaskSelection,
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
  "",
];
assert.deepEqual(
  collectReadyWorkers(headTexts),
  new Set(["worker-1", "worker-3"]),
  "collectReadyWorkers must only include workers whose header text contains the ready phrase",
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

console.log("bakeoff-runner-check: ok");
