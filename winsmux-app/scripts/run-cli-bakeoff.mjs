// Durable CLI Bakeoff runner (#1120).
//
// Drives a live winsmux desktop session end-to-end over CDP: confirms the
// six worker panes are reachable, runs a ready-check, dispatches each
// benchmark-pack task, polls every worker to completion or timeout, and
// appends one JSON line per task to a runner log under
// .winsmux/evidence/cli-bakeoff/runner-<UTC>/.
//
// This script only talks to an already-running desktop app over CDP -- it
// does not build, launch, or install anything. If the desktop app is not
// up, it exits cleanly with code 2 instead of throwing.
//
// Usage:
//   node scripts/run-cli-bakeoff.mjs [--port 9237] [--tasks WB-001,WB-002]
//     [--timeout 3600] [--poll 25] [--project-dir <path>] [--dry-run]
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
import {
  parseManifestPaneIds,
  collectReadyWorkers,
  countEndMarkers,
  taskIdToEndMarker,
  classifyApiRun,
  classifyCliWorker,
  selectNewRunDir,
  buildReadyCheckCommand,
  buildDispatchCommand,
  resolveTaskSelection,
} from "./bakeoff-runner-lib.mjs";

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

async function capturePane(paneId) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);
  try {
    const { stdout } = await execFileAsync("winsmux", ["capture-pane", "-t", paneId, "-p"], {
      windowsHide: true,
      maxBuffer: 32 * 1024 * 1024,
    });
    return stdout || "";
  } catch (err) {
    return { error: err.message || String(err) };
  }
}

async function preflightCapturePaneIds(paneIds) {
  const results = {};
  for (const [worker, paneId] of Object.entries(paneIds)) {
    const captured = await capturePane(paneId);
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
  try {
    const text = await readFile(runJsonPath, "utf8");
    return { found: true, dirName, text };
  } catch {
    return { found: false };
  }
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
  const manifestPath = path.join(args.projectDir, ".winsmux", "manifest.yaml");
  try {
    manifestText = await readFile(manifestPath, "utf8");
  } catch (err) {
    console.log(JSON.stringify({ result: "desktop not up", reason: `cannot read manifest: ${err.message}` }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }

  const pack = JSON.parse(packText);
  const allTaskIds = pack.tasks.map((t) => t.task_id);
  const defaultTimeout = args.timeout || pack.default_timeout_seconds || 3600;
  const { taskIds, unknown } = resolveTaskSelection(allTaskIds, args.tasks);
  if (unknown.length > 0) {
    console.error(`run-cli-bakeoff: ignoring unknown task ids: ${unknown.join(", ")}`);
  }
  if (taskIds.length === 0) {
    console.error("run-cli-bakeoff: no valid task ids to run");
    process.exit(EXIT_BAD_ARGS);
  }

  const paneIds = parseManifestPaneIds(manifestText);
  const missingPaneWorkers = WORKER_LABELS.filter((w) => !paneIds[w]);
  if (missingPaneWorkers.length > 0) {
    console.log(JSON.stringify({
      result: "desktop not up",
      reason: `manifest missing pane_id for: ${missingPaneWorkers.join(", ")}`,
    }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }

  // 3. Preflight capture-pane for every worker.
  const preflight = await preflightCapturePaneIds(paneIds);
  const unreachable = Object.entries(preflight).filter(([, v]) => !v.ok).map(([w]) => w);
  if (unreachable.length > 0) {
    console.log(JSON.stringify({
      result: "desktop not up",
      reason: `capture-pane failed for: ${unreachable.join(", ")}`,
    }));
    process.exit(EXIT_DESKTOP_NOT_UP);
  }

  const evidenceProjectRoot = args.projectDir;
  const runDirName = `runner-${runDirTimestamp()}`;
  const runEvidenceDir = path.join(REPO_ROOT, ".winsmux", "evidence", "cli-bakeoff", runDirName);
  const logPath = path.join(runEvidenceDir, "runner-log.jsonl");

  if (args.dryRun) {
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

  // 5. Run each task.
  let anyFailure = false;

  for (const taskId of taskIds) {
    const endMarker = taskIdToEndMarker(taskId);

    // Seed the baseline marker count for this task's own round marker
    // immediately before dispatch. This is required both to cross round
    // boundaries (e.g. WB-009 -> WB-010 switches from counting
    // BAKEOFF_ROUND_A_END to BAKEOFF_ROUND_B_END) and to avoid misreading
    // leftover markers from a previous run as an instant completion for the
    // very first task of a round.
    const priorMarkerCounts = {};
    for (const w of CLI_WORKERS) {
      const captured = await capturePane(paneIds[w]);
      const paneText = typeof captured === "string" ? captured : "";
      priorMarkerCounts[w] = countEndMarkers(paneText, endMarker);
    }

    const dispatchStartMs = Date.now();
    const dispatchStartIso = nowIso();
    const submitResult = await submitComposerCommand(args.port, buildDispatchCommand(taskId));
    await appendLogLine(logPath, {
      event: "task_dispatch",
      ts: dispatchStartIso,
      taskId,
      endMarker,
      priorMarkerCounts,
      submitOk: !!submitResult.ok,
      submitReason: submitResult.reason,
    });
    if (!submitResult.ok) {
      anyFailure = true;
      await appendLogLine(logPath, { event: "task_result", ts: nowIso(), taskId, status: "dispatch_failed" });
      continue;
    }

    const perWorkerStatus = {};
    for (const w of WORKER_LABELS) perWorkerStatus[w] = "pending";

    const deadlineMs = dispatchStartMs + defaultTimeout * 1000;
    while (Date.now() < deadlineMs) {
      const elapsedSeconds = (Date.now() - dispatchStartMs) / 1000;

      for (const w of CLI_WORKERS) {
        if (perWorkerStatus[w] !== "pending") continue;
        const captured = await capturePane(paneIds[w]);
        const paneText = typeof captured === "string" ? captured : "";
        const currCount = countEndMarkers(paneText, endMarker);
        const status = classifyCliWorker(priorMarkerCounts[w], currCount, elapsedSeconds, defaultTimeout);
        if (status === "completed") {
          perWorkerStatus[w] = "completed";
          const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
          await writeFile(capturePath, paneText, "utf8");
        } else if (status === "timeout") {
          perWorkerStatus[w] = "timeout";
          const capturePath = path.join(runEvidenceDir, `${w}-task-${taskId}.txt`);
          await writeFile(capturePath, paneText, "utf8");
        }
      }

      for (const w of API_LLM_WORKERS) {
        if (perWorkerStatus[w] !== "pending") continue;
        const runInfo = await readRunJsonForTask(evidenceProjectRoot, w, dispatchStartMs);
        if (runInfo.found) {
          const cls = classifyApiRun(runInfo.text);
          if (cls === "completed") perWorkerStatus[w] = "completed";
          else if (cls === "failed") perWorkerStatus[w] = "failed";
        }
        if (perWorkerStatus[w] === "pending" && elapsedSeconds >= defaultTimeout) {
          perWorkerStatus[w] = "timeout";
        }
      }

      if (Object.values(perWorkerStatus).every((s) => s !== "pending")) break;
      await sleep(args.poll * 1000);
    }

    for (const w of WORKER_LABELS) {
      if (perWorkerStatus[w] === "pending") perWorkerStatus[w] = "timeout";
    }
    const taskFailed = Object.values(perWorkerStatus).some((s) => s === "timeout" || s === "failed");
    if (taskFailed) anyFailure = true;

    await appendLogLine(logPath, {
      event: "task_result",
      ts: nowIso(),
      taskId,
      perWorkerStatus,
      elapsedSeconds: (Date.now() - dispatchStartMs) / 1000,
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
