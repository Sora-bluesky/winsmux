import { spawnSync } from "node:child_process";
import { statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  executeStageProjection,
  resolveMsvcEnvironment,
} from "./windows-msvc-env.mjs";

const MODULE_PATH = fileURLToPath(import.meta.url);
const APP_DIR = path.resolve(path.dirname(MODULE_PATH), "..");

export function isDirectExecution({ argv1, modulePath, platform }) {
  if (argv1 === undefined) return false;
  try {
    const normalize = platform === "win32" ? path.win32.resolve : path.resolve;
    const left = normalize(argv1);
    const right = normalize(modulePath);
    return platform === "win32" ? left.toLowerCase() === right.toLowerCase() : left === right;
  } catch {
    return false;
  }
}

export function projectRunResult({ projection, msvcSource }) {
  if (projection?.ok === true) {
    return {
      ok: true,
      failure_code: null,
      failure_stage: null,
      exit_code: 0,
      child_status: 0,
      child_signal: null,
      msvc_source: msvcSource,
    };
  }

  const row = projection.failure_row;
  const processSnapshot = projection.process_snapshot;
  let exitCode = 1;
  let childStatus = null;
  let childSignal = null;
  if (row.child_policy === "from-process-result" && processSnapshot !== null) {
    if (processSnapshot.category === "nonzero-status") {
      childStatus = processSnapshot.status;
      if (processSnapshot.status >= 1 && processSnapshot.status <= 255) exitCode = processSnapshot.status;
    } else if (processSnapshot.category === "signal") {
      childSignal = processSnapshot.signal;
    }
  }
  return {
    ok: false,
    failure_code: row.public_failure_code,
    failure_stage: row.id,
    exit_code: exitCode,
    child_status: childStatus,
    child_signal: childSignal,
    msvc_source: row.msvc_source_policy === "resolved" ? msvcSource : null,
  };
}

export function runDesktopStatusE2E({ argv, platform, baseEnv, appDir, execPath, spawnSyncFn, resolveMsvcFn }) {
  const msvcSourceRef = { value: null };
  const projection = executeStageProjection({
    owner: "wrapper",
    context: {
      argv: Object.freeze([...argv]),
      platform,
      baseEnv: { ...baseEnv },
      appDir,
      execPath,
      spawnSyncFn,
      resolverSpawnSyncFn: spawnSyncFn,
      statSyncFn: undefined,
      resolveMsvcFn,
      msvcSourceRef,
    },
  });
  return projectRunResult({ projection, msvcSource: msvcSourceRef.value });
}

function writeFailure(result) {
  const diagnostic = {
    schema: "winsmux-desktop-status-wrapper/v1",
    ok: result.ok,
    failure_code: result.failure_code,
    failure_stage: result.failure_stage,
    exit_code: result.exit_code,
    child_status: result.child_status,
    child_signal: result.child_signal,
    msvc_source: result.msvc_source,
  };
  process.stderr.write(`${JSON.stringify(diagnostic)}\n`);
}

export function main({
  spawnSyncFn = spawnSync,
  resolveMsvcFn = ({ platform, baseEnv, spawnSyncFn: resolverSpawnSyncFn }) => resolveMsvcEnvironment({
    platform,
    baseEnv,
    spawnSyncFn: resolverSpawnSyncFn,
    statSyncFn: statSync,
  }),
} = {}) {
  let result;
  try {
    result = runDesktopStatusE2E({
      argv: process.argv.slice(2),
      platform: process.platform,
      baseEnv: process.env,
      appDir: APP_DIR,
      execPath: process.execPath,
      spawnSyncFn,
      resolveMsvcFn,
    });
  } catch {
    const projection = executeStageProjection({ owner: "main", context: {} });
    result = projectRunResult({ projection, msvcSource: null });
  }
  if (!result.ok) writeFailure(result);
  process.exitCode = result.exit_code;
}

if (isDirectExecution({ argv1: process.argv[1], modulePath: MODULE_PATH, platform: process.platform })) {
  main();
}
