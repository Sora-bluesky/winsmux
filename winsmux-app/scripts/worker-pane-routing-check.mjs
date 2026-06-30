import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadWorkerPaneRoutingModule() {
  const sourcePath = path.resolve("src/workerPaneRouting.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-worker-pane-routing-"));
  const modulePath = path.join(tempDir, "workerPaneRouting.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  findBoardPaneForWorkbenchPane,
  findWorkerStatusRowByPaneAlias,
  getWorkerStatusPaneAliases,
  resolveWorkbenchPaneIdForBackendPaneId,
} = await loadWorkerPaneRoutingModule();

const rows = [
  { slot_id: "worker-1", slot: "worker-1", pane_id: "%2" },
  { slot_id: "worker-2", slot: "worker-2", pane_id: "%5" },
];
const visiblePaneIds = new Set(["worker-1", "worker-2"]);

assert.deepEqual(getWorkerStatusPaneAliases(rows[0]), ["worker-1", "%2"]);
assert.equal(findWorkerStatusRowByPaneAlias(rows, "%2"), rows[0]);
assert.equal(findWorkerStatusRowByPaneAlias(rows, "worker-2"), rows[1]);
assert.equal(findWorkerStatusRowByPaneAlias(rows, "unknown"), null);

assert.equal(resolveWorkbenchPaneIdForBackendPaneId("%2", rows, visiblePaneIds), "worker-1");
assert.equal(resolveWorkbenchPaneIdForBackendPaneId("worker-2", rows, visiblePaneIds), "worker-2");
assert.equal(resolveWorkbenchPaneIdForBackendPaneId(" %5 ", rows, visiblePaneIds), "worker-2");
assert.equal(resolveWorkbenchPaneIdForBackendPaneId("%9", rows, visiblePaneIds), null);
assert.equal(resolveWorkbenchPaneIdForBackendPaneId("   ", rows, visiblePaneIds), null);

const boardPanes = [
  { pane_id: "worker-1", label: "worker-1" },
  { pane_id: "worker-2", label: "worker-2" },
];

assert.equal(findBoardPaneForWorkbenchPane(boardPanes, "%2", rows), boardPanes[0]);
assert.equal(findBoardPaneForWorkbenchPane(boardPanes, "worker-2", rows), boardPanes[1]);
assert.equal(findBoardPaneForWorkbenchPane(boardPanes, "%9", rows), null);

const paneBuffers = new Map([
  ["worker-1", ""],
  ["worker-2", ""],
]);

function appendBackendOutputToVisiblePane(backendPaneId, data) {
  const visiblePaneId = resolveWorkbenchPaneIdForBackendPaneId(backendPaneId, rows, visiblePaneIds);
  if (!visiblePaneId || !paneBuffers.has(visiblePaneId)) {
    return false;
  }
  paneBuffers.set(visiblePaneId, `${paneBuffers.get(visiblePaneId)}${data}`);
  return true;
}

assert.equal(appendBackendOutputToVisiblePane("%2", "WORKER1_RESULT"), true);
assert.equal(paneBuffers.get("worker-1"), "WORKER1_RESULT");
assert.equal(paneBuffers.get("worker-2"), "");

assert.equal(appendBackendOutputToVisiblePane("%5", "WORKER2_RESULT"), true);
assert.equal(paneBuffers.get("worker-1"), "WORKER1_RESULT");
assert.equal(paneBuffers.get("worker-2"), "WORKER2_RESULT");

assert.equal(appendBackendOutputToVisiblePane("%9", "UNKNOWN_RESULT"), false);
assert.equal(paneBuffers.get("worker-1"), "WORKER1_RESULT");
assert.equal(paneBuffers.get("worker-2"), "WORKER2_RESULT");

const paneLifecycle = new Map([
  ["worker-1", "not_started"],
  ["worker-2", "not_started"],
]);

function applyBackendLifecycleEvent(backendPaneId, reason) {
  const visiblePaneId = resolveWorkbenchPaneIdForBackendPaneId(backendPaneId, rows, visiblePaneIds);
  if (!visiblePaneId || !paneLifecycle.has(visiblePaneId)) {
    return false;
  }
  if (reason === "pty.spawn" || reason === "pty.respawn") {
    paneLifecycle.set(visiblePaneId, "running");
    return true;
  }
  if (reason === "pty.close") {
    paneLifecycle.set(visiblePaneId, "stopped");
    return true;
  }
  return false;
}

assert.equal(applyBackendLifecycleEvent("%2", "pty.spawn"), true);
assert.equal(paneLifecycle.get("worker-1"), "running");
assert.equal(paneLifecycle.get("worker-2"), "not_started");

assert.equal(applyBackendLifecycleEvent("%5", "pty.respawn"), true);
assert.equal(paneLifecycle.get("worker-2"), "running");

assert.equal(applyBackendLifecycleEvent("%2", "pty.close"), true);
assert.equal(paneLifecycle.get("worker-1"), "stopped");

assert.equal(applyBackendLifecycleEvent("%9", "pty.spawn"), false);
assert.equal(paneLifecycle.get("worker-1"), "stopped");
assert.equal(paneLifecycle.get("worker-2"), "running");

console.log("worker-pane-routing-check: ok");
