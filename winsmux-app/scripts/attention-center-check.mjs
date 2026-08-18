import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadAttentionCenterModule() {
  const sourcePath = path.resolve("src/attentionCenter.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-attention-center-"));
  const modulePath = path.join(tempDir, "attentionCenter.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  ATTENTION_CENTER_STORAGE_KEY,
  COMPANION_WINSMUX_MISSING_STATUS,
  alignAttentionCenterProject,
  attentionFilterCounts,
  attentionJumpTarget,
  buildEventsCommandArgv,
  classifyAttention,
  emptyAttentionCenterState,
  isCompanionWinsmuxMissingError,
  isPaneBufferAuthority,
  isPaneBufferEventSource,
  loadAttentionCenterState,
  markAllRead,
  markEventRead,
  nextLastSeenCursor,
  parseAttentionCenterState,
  parseEventsCommandJson,
  readEventsCommandSnapshot,
  serializeAttentionCenterState,
  unreadEvents,
} = await loadAttentionCenterModule();

const attentionSource = await readFile(path.resolve("src/attentionCenter.ts"), "utf8");
assert.doesNotMatch(
  attentionSource,
  /appendPaneOutputBuffer|capture-pane|capturePtyPane|outputBuffer|pty_capture/,
);
assert.equal(isPaneBufferAuthority("pty"), false);
assert.equal(isPaneBufferAuthority("capture-pane"), false);
assert.equal(isPaneBufferAuthority("resume"), false);
assert.equal(isPaneBufferAuthority("appendPaneOutputBuffer"), false);
assert.equal(isPaneBufferEventSource("pty"), true);
assert.equal(isPaneBufferEventSource("capture-pane"), true);
assert.equal(isPaneBufferEventSource("events --json"), false);

// A01: empty wrapper → empty unread
const a01 = parseEventsCommandJson('{"cursor":0,"events":[]}');
assert.deepEqual(a01, { cursor: 0, events: [] });
assert.deepEqual(unreadEvents(a01.events, 0), []);
assert.deepEqual(attentionFilterCounts(a01.events, 0), {
  unread: 0,
  waiting: 0,
  approval: 0,
  failure: 0,
});

// A02: requires_action cursor 3, lastSeen 0 → unread + approval/failure from kind
const a02Approval = {
  type: "requires_action",
  cursor: 3,
  pane_id: "%2",
  kind: "board.approval.requested",
};
const a02Failure = {
  type: "requires_action",
  cursor: 3,
  pane_id: "%3",
  kind: "pane.crashed",
};
const a02Snapshot = parseEventsCommandJson(JSON.stringify({
  cursor: 4,
  events: [a02Approval],
}));
assert.equal(unreadEvents(a02Snapshot.events, 0).length, 1);
assert.equal(classifyAttention(a02Approval), "approval");
assert.equal(classifyAttention(a02Failure), "failure");
assert.equal(classifyAttention({ type: "requires_action", cursor: 3, kind: "operator.blocked" }), "waiting");
assert.deepEqual(attentionFilterCounts(a02Snapshot.events, 0), {
  unread: 1,
  waiting: 0,
  approval: 1,
  failure: 0,
});

// A03: lastSeenCursor 3, same event cursor 3 → not unread
assert.deepEqual(unreadEvents(a02Snapshot.events, 3), []);
assert.equal(attentionFilterCounts(a02Snapshot.events, 3).unread, 0);

// A04: message_received → waiting-to-collect / unread artifact
const a04Event = { type: "message_received", cursor: 2, run_id: "run-1", task_id: "TASK-1" };
const a04 = parseEventsCommandJson(JSON.stringify({ cursor: 3, events: [a04Event] }));
assert.equal(classifyAttention(a04Event), "waiting");
assert.equal(unreadEvents(a04.events, 0).length, 1);
assert.equal(attentionFilterCounts(a04.events, 0).waiting, 1);
assert.equal(attentionJumpTarget(a04Event, ["run-1"]).runId, "run-1");
assert.equal(attentionJumpTarget(a04Event, ["run-1"]).paneId, null);

// A05: extra key on attention-center localStorage JSON → reject, previous state kept
const a05Previous = emptyAttentionCenterState("/tmp/proj");
a05Previous.lastSeenCursor = 7;
const a05Loaded = loadAttentionCenterState(
  '{"schema_version":1,"projectDir":"/tmp/proj","lastSeenCursor":0,"extra":true}',
  a05Previous,
);
assert.match(a05Loaded.error, /rejected/i);
assert.deepEqual(a05Loaded.state, a05Previous);
assert.throws(() => parseAttentionCenterState('{"schema_version":2,"projectDir":"","lastSeenCursor":0}'));
assert.throws(() => parseAttentionCenterState("[]"));
assert.equal(ATTENTION_CENTER_STORAGE_KEY, "winsmux.attention-center.v1");

// A06: malformed events stdout / missing events array → fail closed, no rows
assert.throws(() => parseEventsCommandJson("{"));
assert.throws(() => parseEventsCommandJson("[]"));
assert.throws(() => parseEventsCommandJson('{"cursor":0}'));
assert.throws(() => parseEventsCommandJson('{"events":[]}'));
assert.throws(() => parseEventsCommandJson('{"type":"thread_created","cursor":1}'));
const a06Malformed = readEventsCommandSnapshot({ exitCode: 0, stdout: "not-json", stderr: "" });
assert.equal(a06Malformed.ok, false);
assert.equal(a06Malformed.reason, "malformed");
assert.deepEqual(a06Malformed.snapshot.events, []);
const a06Usage = readEventsCommandSnapshot({
  exitCode: 1,
  stdout: "",
  stderr: "usage: winsmux events [cursor] [--follow] [--json] [--project-dir <path>]",
});
assert.equal(a06Usage.ok, false);
assert.equal(a06Usage.reason, "usage");
assert.deepEqual(a06Usage.snapshot.events, []);

// A07: unknown condensed type → ignored; wrapper cursor still consumed
const a07 = parseEventsCommandJson(JSON.stringify({
  cursor: 9,
  events: [{ type: "pipeline_verify_pass", cursor: 8, extra: "allowed" }],
}));
assert.equal(a07.cursor, 9);
assert.equal(classifyAttention(a07.events[0]), "ignored");
assert.deepEqual(unreadEvents(a07.events, 0), []);
const a07Marked = markAllRead(emptyAttentionCenterState("/tmp/proj"), a07.cursor);
assert.equal(a07Marked.lastSeenCursor, 9);

// A08: mark-all-read → lastSeenCursor = snapshot cursor
const a08State = emptyAttentionCenterState("/repo");
a08State.lastSeenCursor = 1;
const a08 = markAllRead(a08State, 12);
assert.equal(a08.lastSeenCursor, 12);
assert.equal(a08.projectDir, "/repo");
assert.deepEqual(Object.keys(JSON.parse(serializeAttentionCenterState(a08))), [
  "schema_version",
  "projectDir",
  "lastSeenCursor",
]);

// A09: jump target prefers pane_id; missing pane does not invent an id
const a09Pane = attentionJumpTarget({ type: "thread_created", cursor: 0, pane_id: "%1", run_id: "run-1" }, ["run-1"]);
assert.equal(a09Pane.paneId, "%1");
assert.equal(a09Pane.statusOnly, false);
const a09Missing = attentionJumpTarget({ type: "status_idle", cursor: 1, stop_reason: "completed" }, ["run-1"]);
assert.equal(a09Missing.paneId, null);
assert.equal(a09Missing.runId, null);
assert.equal(a09Missing.statusOnly, true);
const a09UnknownRun = attentionJumpTarget({ type: "message_received", cursor: 2, run_id: "run-missing" }, ["run-1"]);
assert.equal(a09UnknownRun.paneId, null);
assert.equal(a09UnknownRun.statusOnly, true);

// A10: resume/capture/pty strings are not an event source
assert.equal(isPaneBufferAuthority("pty"), false);
assert.equal(isPaneBufferAuthority("capture-pane"), false);
assert.equal(isPaneBufferAuthority("resume"), false);
assert.equal(isPaneBufferEventSource("pty"), true);
assert.equal(isPaneBufferEventSource("capture-pane"), true);
assert.equal(isPaneBufferEventSource("resume"), true);
assert.doesNotMatch(attentionSource, /appendPaneOutputBuffer|capture-pane|outputBuffer/);

assert.deepEqual(buildEventsCommandArgv("/tmp/proj", 0), ["events", "--json", "--project-dir", "/tmp/proj"]);
assert.deepEqual(buildEventsCommandArgv("/tmp/proj", 3), ["events", "3", "--json", "--project-dir", "/tmp/proj"]);
assert.equal(nextLastSeenCursor(3, 2), 3);
assert.equal(nextLastSeenCursor(3, 3), 3);
assert.equal(nextLastSeenCursor(3, 5), 5);
assert.equal(markEventRead(emptyAttentionCenterState(), { type: "thread_created", cursor: 4 }).lastSeenCursor, 4);
assert.equal(classifyAttention({ type: "thread_created", cursor: 0 }), "unread");
assert.equal(classifyAttention({ type: "status_running", cursor: 1, pane_id: "%1" }), "running");
assert.equal(classifyAttention({ type: "status_idle", cursor: 2, stop_reason: "completed" }), "idle");
assert.equal(isCompanionWinsmuxMissingError(COMPANION_WINSMUX_MISSING_STATUS), true);
assert.deepEqual(
  alignAttentionCenterProject({ schema_version: 1, projectDir: "/old", lastSeenCursor: 8 }, "/new").lastSeenCursor,
  0,
);

const mainSource = await readFile(path.resolve("src/main.ts"), "utf8");
const panelSource = await readFile(path.resolve("src/attentionCenterPanel.ts"), "utf8");
const htmlSource = await readFile(path.resolve("index.html"), "utf8");
const stylesSource = await readFile(path.resolve("src/styles.css"), "utf8");
const desktopClientSource = await readFile(path.resolve("src/desktopClient.ts"), "utf8");
const libSource = await readFile(path.resolve("src-tauri/src/lib.rs"), "utf8");
const backendSource = await readFile(path.resolve("src-tauri/src/desktop_backend.rs"), "utf8");
const splitGateSource = await readFile(path.resolve("../scripts/test-v03626-desktop-split-gate.ps1"), "utf8");

assert.match(mainSource, /from "\.\/attentionCenterPanel"/);
assert.doesNotMatch(mainSource, /from "\.\/attentionCenter"/);
assert.doesNotMatch(mainSource, /function persistAttentionCenterState|function renderAttentionCenter|function refreshAttentionCenter/);
assert.match(mainSource, /bindAndLoadAttentionCenter/);
assert.match(mainSource, /refreshAttentionCenter/);
assert.match(mainSource, /buildAgentVaultFeedEntries/);
assert.match(mainSource, /focusWorkerPaneFromStatus/);
assert.doesNotMatch(mainSource, /poll-events --json/);
assert.doesNotMatch(mainSource, /appendPaneOutputBuffer\([^)]*attention/i);

assert.match(panelSource, /from "\.\/attentionCenter"/);
assert.match(panelSource, /ATTENTION_CENTER_STORAGE_KEY|winsmux\.attention-center\.v1/);
assert.match(panelSource, /parseEventsCommandJson|readEventsCommandSnapshot/);
assert.match(panelSource, /buildEventsCommandArgv/);
assert.match(panelSource, /getDesktopEventsJson/);
assert.match(panelSource, /getLanguageText\("Attention center", "要確認センター"\)/);
assert.match(panelSource, /getLanguageText\("Mark all read", "すべて既読"\)/);
assert.match(panelSource, /getLanguageText\("Unread", "未読"\)/);
assert.match(panelSource, /getLanguageText\("Waiting", "待機"\)/);
assert.match(panelSource, /getLanguageText\("Approval", "承認"\)/);
assert.match(panelSource, /getLanguageText\("Failure", "失敗"\)/);
assert.match(panelSource, /companion winsmux CLI was not found|COMPANION_WINSMUX_MISSING_STATUS/);
assert.doesNotMatch(panelSource, /poll-events --json/);
assert.doesNotMatch(panelSource, /appendPaneOutputBuffer/);

assert.match(htmlSource, /id="attention-center"/);
assert.match(htmlSource, /id="agent-vault-feed"/);
assert.match(htmlSource, /id="agent-vault-ring"/);

assert.match(stylesSource, /\.attention-center\b/);
assert.doesNotMatch(stylesSource, /#pane-worker-[2-6][^{]*\{[^}]*(?:display\s*:\s*none|visibility\s*:\s*hidden)/);

assert.match(desktopClientSource, /desktop_events_json/);
assert.match(libSource, /fn desktop_events_json/);
assert.match(backendSource, /fn load_desktop_events_json/);
assert.match(backendSource, /events/);
assert.match(backendSource, /--json/);
assert.doesNotMatch(splitGateSource, /attention-center-check/);

console.log("attention-center-check: ok");
