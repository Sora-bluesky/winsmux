// Durable CLI Bakeoff runner (#1120).
//
// Drives a live winsmux desktop session end-to-end over CDP: runs a
// ready-check (which is also what starts the six worker PTYs on a fresh
// desktop launch -- see the ordering note below), THEN confirms the six
// worker panes are reachable, dispatches each benchmark-pack task, polls
// every worker to completion or timeout, appends one JSON line per task to a
// runner log under
// .winsmux/evidence/cli-bakeoff-runner-logs/runner-<UTC>/ (kept outside the
// summarize scan root -- see the runEvidenceDir comment below), and writes a
// summarize-cli-bakeoff.ps1-compatible run directory (manifest.json +
// commands.jsonl) per task under .winsmux/evidence/cli-bakeoff/<run_id>/.
//
// This script only talks to an already-running desktop app over CDP -- it
// does not build, launch, or install anything. If the desktop app is not
// up, it exits cleanly with code 2 instead of throwing.
//
// Pane-capture story (fixed round-9, first-source verified):
//
// The desktop app's worker panes are IN-PROCESS Tauri PTYs, spawned via
// spawn_pty/openpty (winsmux-app/src-tauri/src/lib.rs:1105, ~1175) and held
// in the PtyManager's in-memory `panes` map keyed by pane_id (worker slot
// label, e.g. "worker-1"). The external `winsmux capture-pane` CLI command
// only reads psmux SERVER sessions discovered via
// %USERPROFILE%\.psmux\<session>.port (core/src/session.rs:584) -- a
// completely disjoint process/session universe from the desktop app's
// in-memory PTYs. On a machine where no separate psmux server session is
// running (the normal case for a desktop-only bakeoff), `winsmux
// capture-pane -t <pane_id>` can NEVER read a desktop worker pane, no matter
// how correct the pane_id is. This is why the previous execFile-based
// capturePane() always failed here.
//
// The correct read path is the SAME one the app's own worker-readiness logic
// uses (see capturePtyPane(target) in winsmux-app/src/main.ts:4022, called
// with `target` being the worker slot id): capturePtyPane(paneId) ->
// pty.capture -> the Tauri command `pty_capture(pane_id, lines)`
// (winsmux-app/src-tauri/src/lib.rs:1087-1093, which reads directly out of
// the in-process PtyManager via capture_pty at lib.rs:1336-1356). This
// runner now calls that same command directly over CDP
// (window.__TAURI__.core.invoke), instead of going through psmux at all.
//
// capturePane's signature is therefore capturePane(port, workerId): the
// worker SLOT id ("worker-1".."worker-6"), not a manifest pane_id. Tauri v2
// camelCases command args in JS invocations (Rust `pane_id` -> JS
// `paneId`), so the invoke payload is `{ paneId, lines }`. `lines` is an
// optional u16 cap on how much scrollback is returned; this runner passes
// a generous value since it greps the whole capture for markers.
//
// Preflight ordering (fresh-launch fix): the pty_capture reachability
// preflight runs AFTER the ready-check confirms all six workers, not
// before. On a documented fresh desktop launch, worker PTYs are not started
// until runBenchmarkReadyCheckFromOperatorCommand (winsmux-app/src/main.ts)
// expands the six panes and calls ensurePanePtyStarted -- which happens
// during the ready-check itself. Probing pty_capture before the ready-check
// runs would fail on a clean launch every time, and only appeared to work
// previously when the panes had already been started by hand ahead of time.
// --dry-run does not run the ready-check or the capture preflight at all:
// it only verifies CDP connectivity, the benchmark pack/manifest, and the
// planned task/worker set, since panes are not guaranteed to exist yet at
// that point. A real (non-dry-run) invocation still hard-requires every
// worker to be capturable, right after the ready-check succeeds and before
// any task is dispatched -- this ordering fix does not weaken that
// guarantee, it only moves the check to where it can actually pass.
//
// Usage:
//   node scripts/run-cli-bakeoff.mjs [--port 9237] [--tasks WB-001,WB-002]
//     [--timeout 3600] [--poll 25] [--project-dir <path>] [--dry-run]
//     [--recording-status <status>] [--recording-publishable]
//
// --project-dir defaults to the same path
// scripts/start-cli-bakeoff-desktop.ps1 launches the desktop app with
// (.winsmux/evidence/v03623-coordination-benchmark-project, repo-root
// relative). The desktop app is started with that directory as its
// --project-dir, so its manifest.yaml and per-worker worker-runs live under
// <project-dir>/.winsmux/, not under the repo root's own .winsmux/. Passing
// a stale/repo-root path here would read a manifest.yaml the running
// desktop app never wrote (see #1109).

import { mkdir, appendFile, writeFile, readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
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
  classifyCliOutcome,
  buildCliDispatchEchoMarker,
  extractLatestDispatchId,
  countCliMarkersAfterEchoReceipt,
  hasTaskTimedOut,
  selectNewRunDir,
  buildReadyCheckCommand,
  buildDispatchCommand,
  resolveTaskSelection,
  isOfficialTaskSelection,
  buildRunId,
  mapRunnerStatusToCommandStatus,
  buildRunManifest,
  buildCommandRow,
  buildHarnessPromptMirror,
  extractLatestSha256,
  countSha256Occurrences,
  countDispatchBlockedNotices,
  extractPtyCaptureText,
} from "./bakeoff-runner-lib.mjs";

function sha256Hex(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

// FIX A (round-8): dispatch-confirmation gating replaces the old fixed
// settle sleep.
//
// submitComposerCommand's click-and-return only proves the composer send
// button was clicked; it resolves ~300ms later (its own internal settle,
// see the function body below) and says nothing about whether the desktop
// actually dispatched a benchmark task packet. Per
// dispatchBenchmarkTaskFromOperatorCommand (winsmux-app/src/main.ts
// ~4577-4760), after the composer command is handled the desktop still has
// to: start every worker pane, run waitForWorkerPaneReadiness (up to
// WORKER_READINESS_TIMEOUT_MS = 90_000ms, winsmux-app/src/main.ts ~3883),
// and only THEN call writeWorkerBenchmarkSubmission to actually send the
// packet -- with the "Benchmark task packet dispatched" / JP "ベンチ課題を
// 投入しました" success conversation entry (with its sha256 detail) appended
// only AFTER that submission succeeds. A fixed 10s sleep after the composer
// click could seed baselines long before this echo ever renders (or before
// the dispatch is blocked/fails), which is exactly the false-completion
// bug this fix removes: seeding a baseline that never included the true
// echo lets a stale leftover marker misread as this task's own completion.
//
// The runner now polls the conversation panel itself (readConversationText)
// until it observes ONE of three terminal signals for this dispatch
// attempt, instead of guessing a fixed wait:
//   - success:  countSha256Occurrences(text) increased vs the pre-submit
//               snapshot -- a NEW dispatch success entry rendered.
//   - blocked:  countDispatchBlockedNotices(text) increased -- the desktop
//               itself rejected or failed this dispatch (missing worker
//               rows, launch-approval differences, readiness timeout, or an
//               unhandled dispatch exception).
//   - timeout:  neither signal appeared within DISPATCH_CONFIRM_TIMEOUT_MS.
//               Treated the same as blocked (dispatch_failed) -- never
//               guess that an unconfirmed dispatch actually succeeded.
//
// DISPATCH_CONFIRM_TIMEOUT_MS is WORKER_READINESS_TIMEOUT_MS (90_000, cited
// above) PLUS 60_000ms of headroom for the rest of the dispatch flow
// (worker start loop, packet load, submission writes) that runs before and
// after that readiness wait.
const DISPATCH_CONFIRM_POLL_MS = 3000;
const DISPATCH_CONFIRM_TIMEOUT_MS = 90_000 + 60_000; // WORKER_READINESS_TIMEOUT_MS (90_000) + 60_000 headroom
// Dispatch confirmation proves the desktop accepted the packet, but does not
// prove the pane echo has finished rendering. Poll each CLI pane at this
// cadence until its exact per-dispatch echo receipt appears before allowing
// completion classification.
const ECHO_BASELINE_SETTLE_POLL_MS = 3000;

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..", "..");
const BENCHMARK_PACK_PATH = path.join(REPO_ROOT, "tasks", "cli-bakeoff", "v1", "benchmark-pack.json");
// Must match the -ProjectDir default in scripts/start-cli-bakeoff-desktop.ps1.
const DEFAULT_PROJECT_DIR = path.join(REPO_ROOT, ".winsmux", "evidence", "v03623-coordination-benchmark-project");
const WORKER_LABELS = ["worker-1", "worker-2", "worker-3", "worker-4", "worker-5", "worker-6"];
const API_LLM_WORKERS = new Set(["worker-5", "worker-6"]);
const CLI_WORKERS = new Set(["worker-1", "worker-2", "worker-3", "worker-4"]);

const EXIT_OK = 0;
const EXIT_TASK_FAILURES = 1;
const EXIT_DESKTOP_NOT_UP = 2;
const EXIT_BAD_ARGS = 3;

function parseArgs(argv) {
  const args = {
    port: 9237,
    tasks: undefined,
    timeout: 3600,
    poll: 25,
    projectDir: DEFAULT_PROJECT_DIR,
    dryRun: false,
    // Mirrors run-cli-bakeoff-openrouter.ps1's manifest defaults: a run is
    // "not_declared"/not publishable until an operator explicitly marks it,
    // never defaulted to true.
    recordingStatus: "not_declared",
    recordingPublishable: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--port") {
      args.port = Number(argv[++i]);
    } else if (arg === "--tasks") {
      args.tasks = argv[++i];
    } else if (arg === "--timeout") {
      args.timeout = Number(argv[++i]);
    } else if (arg === "--poll") {
      args.poll = Number(argv[++i]);
    } else if (arg === "--project-dir") {
      args.projectDir = path.resolve(REPO_ROOT, argv[++i]);
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--recording-status") {
      args.recordingStatus = argv[++i];
    } else if (arg === "--recording-publishable") {
      args.recordingPublishable = true;
    }
  }
  return args;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function nowIso() {
  return new Date().toISOString();
}

function runDirTimestamp() {
  // Filesystem-safe UTC timestamp, e.g. 20260703T041530Z.
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/-Z$/, "Z");
}

async function fetchCdpPages(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(5000) });
  if (!res.ok) throw new Error(`CDP /json returned ${res.status}`);
  return res.json();
}

async function getCdpPageWebSocketUrl(port) {
  const pages = await fetchCdpPages(port);
  const page = pages.find((p) => p.type === "page") || pages[0];
  if (!page || !page.webSocketDebuggerUrl) throw new Error("no CDP page with webSocketDebuggerUrl");
  return page.webSocketDebuggerUrl;
}

/**
 * Evaluate a JS expression in the winsmux webview via CDP Runtime.evaluate.
 * Opens and closes a fresh WebSocket connection per call -- calls are
 * infrequent enough (once per poll tick) that connection reuse is not
 * worth the added complexity here.
 */
async function cdpEvaluate(port, expression, timeoutMs = 20000) {
  const wsUrl = await getCdpPageWebSocketUrl(port);
  const ws = new WebSocket(wsUrl);
  const id = 1;

  const result = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { ws.close(); } catch { /* ignore */ }
      reject(new Error("cdp evaluate timeout"));
    }, timeoutMs);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({
        id,
        method: "Runtime.evaluate",
        params: { expression, returnByValue: true, awaitPromise: true, userGesture: true },
      }));
    });
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id !== id) return;
      clearTimeout(timer);
      if (msg.result && msg.result.exceptionDetails) {
        reject(new Error(msg.result.exceptionDetails.text || "cdp evaluate exception"));
      } else {
        resolve(msg.result && msg.result.result ? msg.result.result.value : null);
      }
      try { ws.close(); } catch { /* ignore */ }
    });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error("cdp websocket error"));
    });
  });

  return result;
}

/**
 * Read the composer/pane-header state without submitting anything.
 * Returns the array of pane-header innerText strings currently in the DOM.
 */
async function readPaneHeaderTexts(port) {
  const expr = `(() => {
    const nodes = document.querySelectorAll('[class*="pane-header"],[class*="worker-header"],[class*="status-band"]');
    const out = [];
    nodes.forEach((n) => { if (n && n.innerText) out.push(n.innerText); });
    return JSON.stringify(out);
  })()`;
  const raw = await cdpEvaluate(port, expr);
  try {
    return JSON.parse(raw) || [];
  } catch {
    return [];
  }
}

/**
 * Read the conversation panel's innerText, used to recover the
 * desktop-displayed "sha256" detail for packet-hash verification. The
 * conversation timeline renders into #conversation-timeline (see
 * renderConversation in winsmux-app/src/main.ts); the broader selector list
 * is kept as a fallback in case that id is renamed, mirroring the tolerant
 * style of readPaneHeaderTexts above.
 */
async function readConversationText(port) {
  const expr = `(() => {
    const el = document.getElementById('conversation-timeline')
      || document.querySelector('[class*="conversation"],[class*="runtime"],[id*="conversation"]');
    return JSON.stringify(el && el.innerText ? el.innerText : "");
  })()`;
  const raw = await cdpEvaluate(port, expr);
  try {
    return JSON.parse(raw) || "";
  } catch {
    return "";
  }
}

/**
 * Submit a command string through the composer textarea + send button.
 * Mirrors the verified cdp-submit.mjs reference implementation.
 */
async function submitComposerCommand(port, commandText) {
  const b64 = Buffer.from(commandText, "utf8").toString("base64");
  const expr = `(async () => {
    const cmd = decodeURIComponent(escape(atob(${JSON.stringify(b64)})));
    const ta = document.getElementById('composer-input');
    if (!ta) return JSON.stringify({ ok:false, reason:'no composer-input' });
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
    setter.call(ta, cmd);
    ta.dispatchEvent(new Event('input', { bubbles:true }));
    ta.focus();

    const deadline = Date.now() + 120000;
    let btn = document.getElementById('send-btn');
    while (btn && btn.disabled && Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 500));
      btn = document.getElementById('send-btn');
    }
    if (!btn) return JSON.stringify({ ok:false, reason:'no send-btn' });
    if (btn.disabled) return JSON.stringify({ ok:false, reason:'send-btn stayed disabled for 120s' });

    btn.click();
    await new Promise(r => setTimeout(r, 300));
    return JSON.stringify({ ok:true, valueAfter: ta.value });
  })()`;
  const raw = await cdpEvaluate(port, expr, 130000);
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = { ok: false, reason: "unparsable submit response" };
  }
  return parsed;
}

/**
 * Capture a worker pane's PTY output via the Tauri `pty_capture` command,
 * invoked directly in the desktop webview over CDP -- see the header
 * comment's "Pane-capture story" for why the external `winsmux capture-pane`
 * CLI cannot reach these panes at all.
 *
 * @param {number} port CDP port of the running desktop app.
 * @param {string} workerId worker SLOT id ("worker-1".."worker-6"), NOT a
 *   manifest pane_id.
 * @returns {Promise<string|{error: string}>} captured text, or an error
 *   object on invoke failure/missing __TAURI__ (same failed-capture contract
 *   callers already handle: null baselines, tick skipping, sweep captures).
 */
async function capturePane(port, workerId) {
  const expr = `(async () => {
    try {
      if (!window.__TAURI__ || !window.__TAURI__.core || !window.__TAURI__.core.invoke) {
        return JSON.stringify({ error: '__TAURI__.core.invoke unavailable' });
      }
      const r = await window.__TAURI__.core.invoke('pty_capture', { paneId: ${JSON.stringify(workerId)}, lines: 2000 });
      return JSON.stringify({ ok: true, result: r });
    } catch (e) {
      return JSON.stringify({ error: (e && e.message) ? e.message : String(e) });
    }
  })()`;
  let raw;
  try {
    raw = await cdpEvaluate(port, expr);
  } catch (err) {
    return { error: err.message || String(err) };
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { error: "unparsable pty_capture response" };
  }
  if (!parsed || parsed.error) {
    return { error: (parsed && parsed.error) || "pty_capture invoke failed" };
  }
  const text = extractPtyCaptureText(parsed.result);
  if (text === null) {
    return { error: "pty_capture result missing output field" };
  }
  return text;
}

async function preflightCapturePorts(port, workerLabels) {
  const results = {};
  for (const worker of workerLabels) {
    const captured = await capturePane(port, worker);
    results[worker] = typeof captured === "string" ? { ok: true } : { ok: false, error: captured.error };
  }
  return results;
}

async function findNewestRunDirSince(runsDir, sinceEpochMs) {
  let entries;
  try {
    entries = await readdir(runsDir);
  } catch {
    return null;
  }
  const withMtime = [];
  for (const name of entries) {
    if (!name.startsWith("dispatch-")) continue;
    try {
      const st = await stat(path.join(runsDir, name));
      withMtime.push({ name, mtimeMs: st.mtimeMs });
    } catch {
      withMtime.push({ name, mtimeMs: undefined });
    }
  }
  return selectNewRunDir(withMtime, sinceEpochMs);
}

async function readRunJsonForTask(evidenceProjectRoot, workerLabel, sinceEpochMs) {
  const runsDir = path.join(evidenceProjectRoot, ".winsmux", "worker-runs", workerLabel);
  const dirName = await findNewestRunDirSince(runsDir, sinceEpochMs);
  if (!dirName) return { found: false };
  const runJsonPath = path.join(runsDir, dirName, "run.json");
  let text;
  try {
    text = await readFile(runJsonPath, "utf8");
  } catch {
    return { found: false };
  }
  // response.txt lives alongside run.json in the same dispatch dir (see
  // run-cli-bakeoff-openrouter.ps1, which resolves $runJson.response
  // relative to the project dir). Reading it here, from the same run dir
  // run.json was found in, keeps marker validation honestly tied to the
  // exact run that produced the status this poll tick is classifying.
  let responseText = "";
  try {
    responseText = await readFile(path.join(runsDir, dirName, "response.txt"), "utf8");
  } catch {
    responseText = "";
  }
  return { found: true, dirName, text, responseText };
}

async function appendLogLine(logPath, obj) {
  await appendFile(logPath, `${JSON.stringify(obj)}\n`, "utf8");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!Number.isFinite(args.port) || !Number.isFinite(args.timeout) || !Number.isFinite(args.poll)) {
    console.error("run-cli-bakeoff: invalid --port/--timeout/--poll value");
    process.exit(EXIT_BAD_ARGS);
  }

  // --project-dir is later used verbatim to poll <projectDir>/.winsmux/worker-runs/<worker>
  // for API workers (see readRunJsonForTask). A stale/mistyped project dir must fail fast
  // here, not surface as a misleading one-hour worker timeout during polling: the manifest
  // read below is intentionally non-fatal (informational only), but the project directory
  // itself existing is a hard precondition for that later poll to mean anything.
  try {
    const projectDirStat = await stat(args.projectDir);
    if (!projectDirStat.isDirectory()) {
      throw new Error("not a directory");
    }
  } catch (err) {
    console.error(`run-cli-bakeoff: --project-dir does not exist or is not a directory: ${args.projectDir} (${err.message})`);
    process.exit(EXIT_BAD_ARGS);
  }

  // 1. CDP connectivity check.
  let pages;
  try {
    pages = await fetchCdpPages(args.port);
  } catch (err) {
    console.log(JSON.stringify({ result: "desktop not up", reason: err.message, port: args.port }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }
  if (!Array.isArray(pages) || pages.length === 0) {
    console.log(JSON.stringify({ result: "desktop not up", reason: "no CDP pages", port: args.port }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }

  // 2. Load benchmark pack + manifest.
  let packText;
  let manifestText;
  try {
    packText = await readFile(BENCHMARK_PACK_PATH, "utf8");
  } catch (err) {
    console.log(JSON.stringify({ result: "desktop not up", reason: `cannot read benchmark pack: ${err.message}` }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }
  // manifest.yaml is read for session sanity / informational pane_id
  // reporting only -- it is no longer the capture target roster (see the
  // header comment's "Pane-capture story"). A missing/stale manifest must
  // not hard-fail the run anymore: pty_capture is addressed by worker slot
  // label, not by a manifest pane_id, so this file's absence says nothing
  // about whether pty_capture will succeed.
  const manifestPath = path.join(args.projectDir, ".winsmux", "manifest.yaml");
  try {
    manifestText = await readFile(manifestPath, "utf8");
  } catch (err) {
    console.error(`run-cli-bakeoff: warning: cannot read manifest (informational only): ${err.message}`);
    manifestText = "";
  }

  const pack = JSON.parse(packText);
  const allTaskIds = pack.tasks.map((t) => t.task_id);
  const packDefaultTimeout = Number(pack.default_timeout_seconds || 3600);
  const defaultTimeout = args.timeout || packDefaultTimeout;
  const { taskIds, unknown } = resolveTaskSelection(allTaskIds, args.tasks);
  if (unknown.length > 0) {
    console.error(`run-cli-bakeoff: ignoring unknown task ids: ${unknown.join(", ")}`);
  }
  if (taskIds.length === 0) {
    console.error("run-cli-bakeoff: no valid task ids to run");
    process.exit(EXIT_BAD_ARGS);
  }
  const scoreableGovernance = isOfficialTaskSelection(taskIds, allTaskIds) && defaultTimeout === packDefaultTimeout;

  // paneIds is informational only now (manifest pane_id roster for
  // logging/commands.jsonl metadata) -- it is never used to address a
  // capture call. Warn (do not fail) when the manifest's roster does not
  // cover worker-1..6, since that's still a useful signal that the manifest
  // is stale even though it no longer blocks capture.
  const paneIds = parseManifestPaneIds(manifestText);
  const missingPaneWorkers = WORKER_LABELS.filter((w) => !paneIds[w]);
  if (missingPaneWorkers.length > 0) {
    console.error(`run-cli-bakeoff: warning: manifest pane roster missing pane_id for: ${missingPaneWorkers.join(", ")} (informational; capture uses worker slot ids, not pane_ids)`);
  }

  // NOTE: the pty_capture reachability preflight used to run here, before the
  // ready-check. That ordering is wrong on a documented FRESH desktop launch:
  // the worker PTYs are not spawned until
  // runBenchmarkReadyCheckFromOperatorCommand (winsmux-app/src/main.ts)
  // expands the six panes and calls ensurePanePtyStarted, which happens
  // DURING the ready-check below. Running pty_capture before that point can
  // never succeed on a clean launch -- it only appeared to work when the
  // panes had already been started by hand ahead of time. The preflight is
  // now run AFTER the ready-check has confirmed all six workers are ready
  // (step 4 below), so it is meaningful for both a fresh launch and an
  // already-started desktop.

  const evidenceProjectRoot = args.projectDir;
  const runDirName = `runner-${runDirTimestamp()}`;
  // Supplementary logs/captures live OUTSIDE the summarize scan root:
  // summarize-cli-bakeoff.ps1 (lines ~175-178) scans every child directory
  // of .winsmux/evidence/cli-bakeoff except `summary` and reports any dir
  // without a manifest.json as a manifest_missing run, so parking this
  // runner's own log dir there would add a bogus failed row to every
  // official summary.
  const runEvidenceDir = path.join(REPO_ROOT, ".winsmux", "evidence", "cli-bakeoff-runner-logs", runDirName);
  const logPath = path.join(runEvidenceDir, "runner-log.jsonl");

  if (args.dryRun) {
    // Dry-run intentionally verifies CDP connectivity + the benchmark
    // pack/manifest + the planned task/worker set only -- it does NOT run
    // the ready-check and does NOT probe pty_capture reachability. On a
    // fresh desktop launch the worker PTYs are not started yet (they only
    // come up during the ready-check's pane expansion, see the ordering
    // note above), so requiring capturable panes here would make --dry-run
    // fail on the exact case it exists to validate ahead of time. This
    // reports intent, not live pane state.
    console.log(JSON.stringify({
      result: "dry-run ok",
      port: args.port,
      tasksPlanned: taskIds,
      workersPlanned: WORKER_LABELS,
      timeoutSeconds: defaultTimeout,
      pollSeconds: args.poll,
      projectDir: args.projectDir,
      manifestPath,
      paneIds,
      evidenceDir: runEvidenceDir,
      note: "dry-run does not run the ready-check or verify pty_capture reachability; panes may not be started yet on a fresh desktop launch",
    }, null, 2));
    process.exit(EXIT_OK);
  }

  await mkdir(runEvidenceDir, { recursive: true });
  await writeFile(logPath, "", "utf8");
  await appendLogLine(logPath, {
    event: "run_start",
    ts: nowIso(),
    port: args.port,
    tasks: taskIds,
    timeoutSeconds: defaultTimeout,
    pollSeconds: args.poll,
  });

  // 4. Ready-check: submit and poll for up to ~30s, one retry on shortfall.
  async function runReadyCheck() {
    const submitResult = await submitComposerCommand(args.port, buildReadyCheckCommand());
    if (!submitResult.ok) return { readyWorkers: new Set(), submitResult };
    let readyWorkers = new Set();
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline && readyWorkers.size < WORKER_LABELS.length) {
      await sleep(2000);
      const headTexts = await readPaneHeaderTexts(args.port);
      const found = collectReadyWorkers(headTexts);
      for (const w of found) readyWorkers.add(w);
    }
    return { readyWorkers, submitResult };
  }

  let { readyWorkers } = await runReadyCheck();
  if (readyWorkers.size < WORKER_LABELS.length) {
    const retry = await runReadyCheck();
    for (const w of retry.readyWorkers) readyWorkers.add(w);
  }
  const notReady = WORKER_LABELS.filter((w) => !readyWorkers.has(w));
  await appendLogLine(logPath, {
    event: "ready_check",
    ts: nowIso(),
    readyWorkers: [...readyWorkers],
    notReady,
  });
  if (notReady.length > 0) {
    console.log(JSON.stringify({
      result: "ready-check incomplete",
      readyWorkers: [...readyWorkers],
      notReady,
      logPath,
    }));
    process.exit(EXIT_TASK_FAILURES);
  }

  // Preflight pty_capture for every worker, over CDP, addressed by worker
  // slot label (see the header comment's "Pane-capture story"). This MUST
  // run after the ready-check above, not before: on a fresh desktop launch
  // the worker PTYs are not spawned until the ready-check's pane expansion
  // (ensurePanePtyStarted in winsmux-app/src/main.ts) has run, so pty_capture
  // cannot succeed until that point regardless of pane_id correctness. Real
  // runs still hard-require every worker to be capturable before any task is
  // dispatched -- this is not weakened, just moved to after the point where
  // it can actually succeed.
  const preflight = await preflightCapturePorts(args.port, WORKER_LABELS);
  const unreachable = Object.entries(preflight).filter(([, v]) => !v.ok).map(([w]) => w);
  await appendLogLine(logPath, {
    event: "capture_preflight",
    ts: nowIso(),
    unreachable,
  });
  if (unreachable.length > 0) {
    console.log(JSON.stringify({
      result: "desktop not up",
      reason: `pty_capture failed for: ${unreachable.join(", ")}`,
      logPath,
    }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }

  // Per-run evidence dir that satisfies summarize-cli-bakeoff.ps1's contract
  // (manifest.json + commands.jsonl per dispatched task), written alongside
  // the supplementary runner-log.jsonl / pane-capture evidence above. See
  // .winsmux/evidence/cli-bakeoff/<runDirName>-<taskId>/ per task.
  const runTimestampSlug = runDirName;
  const bakeoffEvidenceRoot = path.join(REPO_ROOT, ".winsmux", "evidence", "cli-bakeoff");

  // cli/model/role metadata for commands.jsonl: this runner only has
  // manifest.yaml's pane_id per worker (parseManifestPaneIds) -- unlike
  // run-cli-bakeoff-openrouter.ps1, it does not fetch worker rows (cli,
  // display_model, role) from the benchmark pack's `default_workers` list,
  // because those rows are not attached to CDP-dispatched desktop workers
  // the way they are to `workers exec` invocations. Emitting 'unknown'
  // here is intentional and honest rather than inventing a cli/model
  // pairing this runner cannot verify from its available inputs.
  const workerMeta = {};
  for (const w of WORKER_LABELS) {
    workerMeta[w] = { cli: "unknown", model: "unknown", role: "unknown", pane: paneIds[w] || "unknown" };
  }

  // Shared writer for the summarize-compatible per-task run directory.
  // Called from BOTH the normal completion path and the dispatch-failed
  // path: the official summary reads only these run dirs (not
  // runner-log.jsonl), so a task whose composer submit failed must still
  // produce failed rows here or it silently vanishes from the benchmark
  // matrix.
  async function writeSummarizeArtifacts({
    taskId,
    taskClass,
    perWorkerStatus,
    perWorkerElapsedSeconds,
    perWorkerEndMarkerPresent,
    executionStatus,
    packetHashMatch,
  }) {
    const runId = buildRunId(runTimestampSlug, taskId);
    const taskRunDir = path.join(bakeoffEvidenceRoot, runId);
    const activeWorkers = WORKER_LABELS.map((w) => ({
      worker: w,
      cli: workerMeta[w].cli,
      model: workerMeta[w].model,
      role: workerMeta[w].role,
      pane: workerMeta[w].pane,
      status: mapRunnerStatusToCommandStatus(perWorkerStatus[w]),
    }));
    const allEndMarkersPresent = WORKER_LABELS.every((w) => perWorkerEndMarkerPresent[w]);
    const manifest = buildRunManifest({
      runId,
      taskId,
      taskClass,
      activeWorkers,
      endMarkerPresent: allEndMarkersPresent,
      packetHashMatch: !!packetHashMatch,
      recordingStatus: args.recordingStatus,
      recordingPublishable: args.recordingPublishable,
      executionStatus,
      generatedAtIso: nowIso(),
      scoreableGovernance,
    });
    const commandRows = WORKER_LABELS.map((w) => buildCommandRow({
      worker: w,
      cli: workerMeta[w].cli,
      model: workerMeta[w].model,
      role: workerMeta[w].role,
      pane: workerMeta[w].pane,
      taskId,
      taskClass,
      runnerStatus: perWorkerStatus[w],
      elapsedSeconds: perWorkerElapsedSeconds[w],
      endMarkerPresent: perWorkerEndMarkerPresent[w],
      packetHashMatch: !!packetHashMatch,
    }));

    await mkdir(taskRunDir, { recursive: true });
    await writeFile(path.join(taskRunDir, "manifest.json"), JSON.stringify(manifest, null, 2), "utf8");
    await writeFile(
      path.join(taskRunDir, "commands.jsonl"),
      commandRows.map((row) => JSON.stringify(row)).join("\n") + "\n",
      "utf8",
    );
    await appendLogLine(logPath, { event: "summarize_artifacts_written", ts: nowIso(), taskId, runId, runDir: taskRunDir });
  }

  // 5. Run each task.
  let anyFailure = false;

  for (const taskId of taskIds) {
    const endMarker = taskIdToEndMarker(taskId);
    const taskEntry = pack.tasks.find((t) => t.task_id === taskId);
    const taskClass = taskEntry && typeof taskEntry.task_class === "string" ? taskEntry.task_class : "unknown";

    // Packet text (and therefore round markers AND the hash-mirror
    // Instructions body) is read from THE PROJECT DIR
    // (<project-dir>/tasks/cli-bakeoff/v1/...), not the repo root: that is
    // what the running desktop app itself reads (getDesktopFullFile with
    // activeProjectDir in winsmux-app/src/main.ts). A repo-root copy can
    // drift from what the live desktop session actually has on disk (see
    // #1109), which would silently desync markers/hash from the real
    // dispatch. Both packetMarkers and the hash mirror below are derived
    // from this SAME read so they can never disagree with each other over
    // which packet text was used.
    let packetText = null;
    let packetMarkers = { begin: "", end: "" };
    if (taskEntry && typeof taskEntry.packet_path === "string") {
      try {
        packetText = await readFile(
          path.join(args.projectDir, "tasks", "cli-bakeoff", "v1", taskEntry.packet_path),
          "utf8",
        );
        packetMarkers = getPacketMarkers(packetText);
      } catch (err) {
        console.log(JSON.stringify({
          result: "desktop not up",
          reason: `cannot read project pack: ${err.message}`,
        }));
        process.exit(EXIT_DESKTOP_NOT_UP);
      }
    }

    // Independently reconstruct the base prompt the desktop builds for this
    // dispatch. After confirmation exposes the per-dispatch echo receipt,
    // append that exact receipt and hash the full interactive prompt for the
    // comparison against the desktop conversation entry below.
    const expectedPrompt = packetText !== null
      ? buildHarnessPromptMirror(pack, taskEntry || {}, packetText)
      : "";

    const dispatchStartMs = Date.now();
    const dispatchStartIso = nowIso();

    // FIX A: snapshot the conversation panel BEFORE submitting, so the
    // post-submit confirmation poll below can detect a NEW success/blocked
    // notice by comparing counts against this pre-submit baseline rather
    // than against whatever unrelated notices already happened to be on
    // screen from a previous task.
    let preConversationText = "";
    try {
      preConversationText = await readConversationText(args.port);
    } catch {
      preConversationText = "";
    }
    const preSha256Count = countSha256Occurrences(preConversationText);
    const preBlockedCount = countDispatchBlockedNotices(preConversationText);
    const submitResult = await submitComposerCommand(args.port, buildDispatchCommand(taskId));

    async function emitDispatchFailedArtifacts(dispatchFailReason) {
      anyFailure = true;
      await appendLogLine(logPath, {
        event: "task_dispatch",
        ts: dispatchStartIso,
        taskId,
        endMarker,
        submitOk: submitResult.ok,
        submitReason: submitResult.ok ? undefined : submitResult.reason,
        dispatchFailReason,
      });
      await appendLogLine(logPath, { event: "task_result", ts: nowIso(), taskId, status: "dispatch_failed" });
      // Emit the same summarize-compatible artifacts with every worker
      // marked dispatch_failed (mapped to 'failed' in commands.jsonl):
      // without them this task would be missing from the official summary
      // entirely instead of showing failed rows.
      const failedStatus = {};
      const failedElapsed = {};
      const failedMarkers = {};
      for (const w of WORKER_LABELS) {
        failedStatus[w] = "dispatch_failed";
        failedElapsed[w] = null;
        failedMarkers[w] = false;
      }
      await writeSummarizeArtifacts({
        taskId,
        taskClass,
        perWorkerStatus: failedStatus,
        perWorkerElapsedSeconds: failedElapsed,
        perWorkerEndMarkerPresent: failedMarkers,
        executionStatus: "dispatch_failed",
        // Baseline seeding (and thus hash verification, which only happens
        // after a CONFIRMED successful dispatch) never ran on this path --
        // honestly false rather than fabricated.
        packetHashMatch: false,
      });
    }

    if (!submitResult.ok) {
      await appendLogLine(logPath, { event: "dispatch_blocked", ts: nowIso(), taskId, reason: `composer submit failed: ${submitResult.reason}` });
      await emitDispatchFailedArtifacts(`composer submit failed: ${submitResult.reason}`);
      continue;
    }

    // FIX A: dispatch-confirmation gating. The composer click succeeding
    // only means the send button was clicked -- it says nothing about
    // whether the desktop actually started workers, passed readiness, and
    // sent the packet (see DISPATCH_CONFIRM_TIMEOUT_MS's doc comment above
    // for the full main.ts flow this is gating on). Poll the conversation
    // panel until this dispatch's own success or blocked/failed notice
    // renders, or until DISPATCH_CONFIRM_TIMEOUT_MS elapses.
    let confirmOutcome = "unconfirmed";
    const confirmDeadlineMs = Date.now() + DISPATCH_CONFIRM_TIMEOUT_MS;
    while (Date.now() < confirmDeadlineMs) {
      await sleep(DISPATCH_CONFIRM_POLL_MS);
      let text = "";
      try {
        text = await readConversationText(args.port);
      } catch {
        text = "";
      }
      if (countDispatchBlockedNotices(text) > preBlockedCount) {
        confirmOutcome = "blocked";
        break;
      }
      if (countSha256Occurrences(text) > preSha256Count) {
        confirmOutcome = "success";
        break;
      }
    }

    if (confirmOutcome === "blocked") {
      await appendLogLine(logPath, { event: "dispatch_blocked", ts: nowIso(), taskId, reason: "desktop conversation showed a dispatch blocked/failed notice" });
      await emitDispatchFailedArtifacts("desktop conversation showed a dispatch blocked/failed notice");
      continue;
    }
    if (confirmOutcome === "unconfirmed") {
      // Timeout without either signal: treated as failed, never guessed as
      // a success. This is the same fail-closed posture as the blocked
      // path above -- an unconfirmed dispatch must not seed baselines or
      // enter the completion poll loop.
      await appendLogLine(logPath, { event: "dispatch_unconfirmed", ts: nowIso(), taskId, reason: `no success or blocked notice within ${DISPATCH_CONFIRM_TIMEOUT_MS}ms` });
      await emitDispatchFailedArtifacts(`dispatch unconfirmed within ${DISPATCH_CONFIRM_TIMEOUT_MS}ms`);
      continue;
    }

    // Read the desktop-displayed sha256 for this dispatch now that success
    // is confirmed, and compare it to our independently computed
    // expectedSha.
    let displayedSha = "";
    let dispatchId = "";
    try {
      const conversationText = await readConversationText(args.port);
      displayedSha = extractLatestSha256(conversationText);
      dispatchId = extractLatestDispatchId(conversationText);
    } catch {
      displayedSha = "";
      dispatchId = "";
    }
    if (!dispatchId) {
      const reason = "confirmed dispatch did not expose a dispatch_id receipt";
      await appendLogLine(logPath, { event: "dispatch_unconfirmed", ts: nowIso(), taskId, reason });
      await emitDispatchFailedArtifacts(reason);
      continue;
    }
    const expectedSha = expectedPrompt
      ? sha256Hex(`${expectedPrompt}\n\n${buildCliDispatchEchoMarker(dispatchId)}`)
      : "";
    const packetHashMatch = expectedSha !== "" && displayedSha !== "" && displayedSha === expectedSha;

    // A dispatch-confirmed echo can still be streaming. A worker gets a
    // baseline only after its exact per-dispatch echo receipt appears. The
    // receipt is appended after the full packet, so it is a stronger settle
    // proof than a timing guess. Each worker still progresses independently
    // through this state in the normal poll loop.
    const priorMarkerCounts = {};
    const priorBeginCounts = {};
    const dispatchEchoMarkers = {};
    const beginObserved = {};
    for (const w of CLI_WORKERS) {
      priorMarkerCounts[w] = null;
      priorBeginCounts[w] = null;
      dispatchEchoMarkers[w] = buildCliDispatchEchoMarker(dispatchId);
      beginObserved[w] = false;
    }

    const deadlineMs = dispatchStartMs + defaultTimeout * 1000;

    await appendLogLine(logPath, {
      event: "task_dispatch",
      ts: dispatchStartIso,
      taskId,
      endMarker,
      dispatchId,
      priorMarkerCounts,
      priorBeginCounts,
      submitOk: true,
      expectedSha,
      displayedSha,
      packetHashMatch,
    });

    const perWorkerStatus = {};
    const perWorkerElapsedSeconds = {};
    const perWorkerEndMarkerPresent = {};
    for (const w of WORKER_LABELS) {
      perWorkerStatus[w] = "pending";
      perWorkerElapsedSeconds[w] = null;
      perWorkerEndMarkerPresent[w] = false;
    }

    while (Date.now() < deadlineMs) {
      const elapsedSeconds = (Date.now() - dispatchStartMs) / 1000;

      for (const w of CLI_WORKERS) {
        if (perWorkerStatus[w] !== "pending") continue;
        const captured = await capturePane(args.port, w);
        if (typeof captured !== "string") {
          // Transient capture failure: skip this tick rather than treating
          // the miss as an empty pane. An empty read would wrongly lower
          // the running-minimum baseline (or instantly complete against a
          // null baseline). The loop deadline still bounds the task and the
          // post-loop sweep marks still-pending workers as timeout.
          continue;
        }
        const paneText = captured;
        const currCount = countEndMarkers(paneText, endMarker);
        const currBeginCount = packetMarkers.begin
          ? countEndMarkers(paneText, packetMarkers.begin)
          : 0;

        let status = null;
        if (priorMarkerCounts[w] === null || priorBeginCounts[w] === null) {
          const receiptMarkerCounts = countCliMarkersAfterEchoReceipt(
            paneText,
            dispatchEchoMarkers[w],
            packetMarkers.begin,
            endMarker,
          );
          if (receiptMarkerCounts === null) {
            continue;
          }
          if (receiptMarkerCounts.endCount > 0) {
            // The receipt is appended after the packet echo. An END marker
            // after it is therefore real worker output, including a worker
            // that completed before a second settle sample was available.
            status = classifyCliOutcome(
              "completed",
              receiptMarkerCounts.beginCount > 0,
            );
          } else {
            // The receipt follows the entire packet echo, so this first
            // receipt-visible capture is the echo-safe baseline. Do not
            // classify it: any later marker increase is worker output.
            priorBeginCounts[w] = currBeginCount;
            priorMarkerCounts[w] = currCount;
            beginObserved[w] = receiptMarkerCounts.beginCount > 0;
            continue;
          }
        } else {
          // FIX B: track the begin-marker running-minimum in parallel with
          // the end-marker one above, using the identical scroll-off-tolerant
          // logic, and set the sticky beginObserved[w] flag whenever a
          // successful capture shows the begin count rise above its running
          // minimum. packetMarkers.begin === "" means this packet had no
          // extractable begin-marker literal at all (see getPacketMarkers) --
          // beginObserved can then never become true, which is intentional
          // (see classifyCliOutcome's doc comment).
          if (currBeginCount < priorBeginCounts[w]) {
            priorBeginCounts[w] = currBeginCount;
          }
          if (currBeginCount > priorBeginCounts[w]) {
            beginObserved[w] = true;
          }

          if (currCount < priorMarkerCounts[w]) {
            // A leftover marker from the previous task scrolled off the
            // visible screen; adopt the smaller count as the new baseline so
            // this task's own marker still registers as an increase.
            priorMarkerCounts[w] = currCount;
          }
          const endStatus = classifyCliWorker(priorMarkerCounts[w], currCount, elapsedSeconds, defaultTimeout);
          // FIX B: gate CLI completion on BOTH round markers, mirroring
          // classifyApiOutcome's both-markers contract for the api_llm path.
          // An END-increment alone (begin never observed) downgrades to
          // invalid_output instead of being accepted as completed.
          status = classifyCliOutcome(endStatus, beginObserved[w]);
        }
        if (status === "completed") {
          perWorkerStatus[w] = "completed";
          perWorkerElapsedSeconds[w] = elapsedSeconds;
          // The CLI completion check is the round-marker line appearing in
          // the pane transcript itself, i.e. the end marker was directly
          // observed -- this is the "CLI: completion marker line observed"
          // verification path called out for evidence.end_marker_present.
          perWorkerEndMarkerPresent[w] = true;
          const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
          await writeFile(capturePath, paneText, "utf8");
        } else if (status === "invalid_output") {
          // END marker was seen but the BEGIN marker never was -- terminal,
          // already counted as a failure by taskFailed's status check below
          // and by mapRunnerStatusToCommandStatus's status mapping.
          perWorkerStatus[w] = "invalid_output";
          perWorkerElapsedSeconds[w] = elapsedSeconds;
          perWorkerEndMarkerPresent[w] = false;
          const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
          await writeFile(capturePath, paneText, "utf8");
        } else if (status === "timeout") {
          perWorkerStatus[w] = "timeout";
          perWorkerElapsedSeconds[w] = elapsedSeconds;
          const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
          await writeFile(capturePath, paneText, "utf8");
        }
      }

      for (const w of API_LLM_WORKERS) {
        if (perWorkerStatus[w] !== "pending") continue;
        let apiElapsedSeconds = (Date.now() - dispatchStartMs) / 1000;
        if (hasTaskTimedOut(apiElapsedSeconds, defaultTimeout)) {
          perWorkerStatus[w] = "timeout";
          perWorkerElapsedSeconds[w] = apiElapsedSeconds;
          continue;
        }
        const runInfo = await readRunJsonForTask(evidenceProjectRoot, w, dispatchStartMs);
        apiElapsedSeconds = (Date.now() - dispatchStartMs) / 1000;
        if (hasTaskTimedOut(apiElapsedSeconds, defaultTimeout)) {
          perWorkerStatus[w] = "timeout";
          perWorkerElapsedSeconds[w] = apiElapsedSeconds;
          continue;
        }
        if (runInfo.found) {
          const cls = classifyApiOutcome(runInfo.text, runInfo.responseText, packetMarkers);
          if (cls === "completed" || cls === "failed" || cls === "blocked" || cls === "invalid_output") {
            perWorkerStatus[w] = cls;
            perWorkerElapsedSeconds[w] = apiElapsedSeconds;
            // Only a fully-validated completed outcome (run.json succeeded
            // AND both round markers found in response.txt) counts as the
            // marker having been verified present; invalid_output means the
            // markers were checked and found missing, so it must stay
            // false.
            perWorkerEndMarkerPresent[w] = cls === "completed";
          }
        }
      }

      if (Object.values(perWorkerStatus).every((s) => s !== "pending")) break;
      const pollDelayMs = [...CLI_WORKERS].some((w) => priorMarkerCounts[w] === null)
        ? ECHO_BASELINE_SETTLE_POLL_MS
        : args.poll * 1000;
      await sleep(pollDelayMs);
    }

    for (const w of WORKER_LABELS) {
      if (perWorkerStatus[w] !== "pending") continue;
      // The poll loop exits at the deadline before an in-loop tick can
      // observe elapsedSeconds >= timeoutSeconds (ticks only run while
      // now < deadline), so this sweep is the real timeout path. Record a
      // final pane capture here -- without it a timed-out worker loses the
      // per-task artifact needed to audit or exclude the result. api_llm
      // workers are included: a timed-out api worker has no run.json
      // either, so its pane capture is the only artifact of the attempt.
      perWorkerStatus[w] = "timeout";
      perWorkerElapsedSeconds[w] = (Date.now() - dispatchStartMs) / 1000;
      const captured = await capturePane(args.port, w);
      if (typeof captured === "string") {
        const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
        await writeFile(capturePath, captured, "utf8");
      }
    }
    const taskFailed = Object.values(perWorkerStatus).some(
      (s) => s === "timeout" || s === "failed" || s === "blocked" || s === "invalid_output",
    );
    if (taskFailed) anyFailure = true;

    await appendLogLine(logPath, {
      event: "task_result",
      ts: nowIso(),
      taskId,
      perWorkerStatus,
      elapsedSeconds: (Date.now() - dispatchStartMs) / 1000,
    });

    await writeSummarizeArtifacts({
      taskId,
      taskClass,
      perWorkerStatus,
      perWorkerElapsedSeconds,
      perWorkerEndMarkerPresent,
      executionStatus: taskFailed ? "completed_with_failures" : "completed",
      packetHashMatch,
    });
  }

  await appendLogLine(logPath, { event: "run_end", ts: nowIso(), anyFailure });

  console.log(JSON.stringify({
    result: anyFailure ? "completed with failures" : "completed",
    logPath,
    evidenceDir: runEvidenceDir,
  }));
  process.exit(anyFailure ? EXIT_TASK_FAILURES : EXIT_OK);
}

main().catch((err) => {
  console.error(`run-cli-bakeoff: unhandled error: ${err.stack || err.message || err}`);
  process.exit(EXIT_DESKTOP_NOT_UP);
});
