import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadWorkerStartPlanningModule() {
  const sourcePath = path.resolve("src/workerStartPlanning.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-worker-start-planning-"));
  const modulePath = path.join(tempDir, "workerStartPlanning.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  classifyRestoredWorkerDrift,
  hasWorkerLaunchApprovalDrift,
  selectConfiguredWorkerStartRoster,
} = await loadWorkerStartPlanningModule();

// hasWorkerLaunchApprovalDrift
assert.equal(hasWorkerLaunchApprovalDrift({ approval_differences: [] }), false);
assert.equal(hasWorkerLaunchApprovalDrift({ approval_differences: undefined }), false);
assert.equal(
  hasWorkerLaunchApprovalDrift({ approval_differences: [{ field: "model", approved: "gpt-5", current: "gpt-5.1" }] }),
  true,
);

// classifyRestoredWorkerDrift: #1111 -- a restored, already-running pane whose
// settings have drifted must be flagged as requiring re-approval, but a
// drifted pane that is NOT running yet must not be force-flagged (it will be
// caught by the ordinary start-time approval gate instead).
const driftedRow = { approval_differences: [{ field: "agent", approved: "codex", current: "claude" }] };
const cleanRow = { approval_differences: [] };

const runningDrifted = classifyRestoredWorkerDrift(driftedRow, "worker-3", true);
assert.equal(runningDrifted.drifted, true);
assert.equal(runningDrifted.requiresReapproval, true);
assert.equal(runningDrifted.target, "worker-3");
assert.equal(runningDrifted.differences.length, 1);

const stoppedDrifted = classifyRestoredWorkerDrift(driftedRow, "worker-4", false);
assert.equal(stoppedDrifted.drifted, true);
assert.equal(stoppedDrifted.requiresReapproval, false);

const runningClean = classifyRestoredWorkerDrift(cleanRow, "worker-5", true);
assert.equal(runningClean.drifted, false);
assert.equal(runningClean.requiresReapproval, false);

// selectConfiguredWorkerStartRoster: #1112 -- the roster must cover every
// configured pane id, not only whichever pane happens to be focused.
const configuredIds = ["worker-1", "worker-2", "worker-3", "worker-4", "worker-5", "worker-6"];
const rowsByTarget = new Map([
  ["worker-1", { slot_id: "worker-1", approval_differences: [] }],
  ["worker-2", { slot_id: "worker-2", approval_differences: [] }],
  ["worker-3", { slot_id: "worker-3", approval_differences: [{ field: "model", approved: "a", current: "b" }] }],
  ["worker-4", { slot_id: "worker-4", approval_differences: [] }],
  ["worker-6", { slot_id: "worker-6", approval_differences: [] }],
  // worker-5 intentionally missing to exercise missingTargets.
]);

const roster = selectConfiguredWorkerStartRoster(configuredIds, rowsByTarget);
assert.deepEqual(roster.startable.map((row) => row.slot_id), ["worker-1", "worker-2", "worker-4", "worker-6"]);
assert.deepEqual(roster.blockedBySettings.map((row) => row.slot_id), ["worker-3"]);
assert.deepEqual(roster.missingTargets, ["worker-5"]);

// A fully clean, fully-known roster resolves every configured id as startable.
const cleanRowsByTarget = new Map(configuredIds.map((id) => [id, { slot_id: id, approval_differences: [] }]));
const cleanRoster = selectConfiguredWorkerStartRoster(configuredIds, cleanRowsByTarget);
assert.equal(cleanRoster.startable.length, 6);
assert.equal(cleanRoster.blockedBySettings.length, 0);
assert.equal(cleanRoster.missingTargets.length, 0);

console.log("worker-start-planning-check: ok");
