import path from "node:path";

const STATUS_OVERRIDE_KEYS = Object.freeze([
  "WINSMUX_DESKTOP_E2E_LAUNCH_PROJECT_ONLY",
  "WINSMUX_DESKTOP_E2E_RELEASE_POPOUT_ONLY",
  "WINSMUX_DESKTOP_E2E_PACKAGED_RESTORE_ONLY",
  "WINSMUX_DESKTOP_E2E_WORKER_START_ONLY",
  "WINSMUX_DESKTOP_E2E_COMPOSER_ONLY",
  "WINSMUX_DESKTOP_E2E_OPERATOR_SNAPSHOT_ONLY",
  "WINSMUX_DESKTOP_E2E_ASSERT_DUPLICATE_GUARD_ONLY",
  "WINSMUX_DESKTOP_E2E_STOP_AFTER_WORKER_STATUS",
  "WINSMUX_DESKTOP_E2E_FAKE_RUNNING_APPS_JSON",
  "WINSMUX_DESKTOP_E2E_ALLOW_EXISTING_APP",
  "WINSMUX_DESKTOP_E2E_APP_EXE",
]);
const NODE_KEYS = Object.freeze(["NODE_OPTIONS", "NODE_PATH"]);
const PRESERVED_CONTROL_KEYS = Object.freeze([
  "WINSMUX_DESKTOP_E2E_CONTROL_PIPE_TOKEN",
  "WINSMUX_DESKTOP_E2E_CDP_TIMEOUT_MS",
]);
const REQUIRED_MSVC_KEYS = Object.freeze(["VSCMD_VER", "VCINSTALLDIR", "WindowsSdkDir", "INCLUDE", "LIB", "PATH"]);
const SAFE_SIGNAL = /^SIG[A-Z0-9_]{1,31}$/;
const FORBIDDEN_CMD_PATH = /["%!^&|<>\r\n\0]/;

const continueWith = (context) => ({ kind: "continue", context });
const completeWith = (context) => ({ kind: "complete", context });
const failWith = (process_snapshot = null) => ({ kind: "fail", process_snapshot });
const propagate = (failure_row) => ({ kind: "propagate", failure_row });
const snapshot = (category, status = null, signal = null) => ({ category, status, signal });

function oneCaseInsensitiveEntry(environment, requestedKey) {
  const matches = Object.entries(environment).filter(([key]) => key.toLowerCase() === requestedKey.toLowerCase());
  if (matches.length !== 1) return null;
  const [actualKey, value] = matches[0];
  if (typeof value !== "string" || value.length === 0) return null;
  return { actualKey, value };
}

function statRegularFile(statSyncFn, target) {
  try {
    const stat = statSyncFn(target);
    if (stat === null || typeof stat !== "object") return false;
    const isFile = stat.isFile;
    if (typeof isFile !== "function") return false;
    return isFile.call(stat) === true;
  } catch {
    return false;
  }
}

function validInstallationPath(value) {
  return typeof value === "string" && path.win32.isAbsolute(value) && !FORBIDDEN_CMD_PATH.test(value);
}

function makeStage({ id, owner, internal_failure_code, public_failure_code = internal_failure_code, msvc_source_policy = null, child_policy = null, exit_policy = "one" }, implementation) {
  const row = {
    id,
    owner,
    internal_failure_code,
    public_failure_code,
    msvc_source_policy,
    child_policy,
    exit_policy,
    operation: null,
  };
  row.operation = Object.freeze((context) => implementation(context, row));
  return Object.freeze(row);
}

export const PROCESS_RESULT_DECISION_TABLE = Object.freeze([
  Object.freeze({
    id: "result-object", field: null,
    partitions: Object.freeze(["non-null object -> continue", "null, undefined or primitive -> terminal malformed"]),
    operation: Object.freeze((state) => (state.result !== null && typeof state.result === "object" ? null : snapshot("malformed"))),
  }),
  Object.freeze({
    id: "error-field", field: "error",
    partitions: Object.freeze([
      "own-property probe throw -> terminal malformed",
      "own property absent -> continue without a property read",
      "own getter read throw -> terminal malformed",
      "own value undefined -> continue",
      "own value null -> continue",
      "every other own value -> terminal error",
    ]),
    operation: Object.freeze((state) => {
      let own;
      try { own = Object.prototype.hasOwnProperty.call(state.result, "error"); } catch { return snapshot("malformed"); }
      if (!own) return null;
      let value;
      try { value = state.result.error; } catch { return snapshot("malformed"); }
      return value === undefined || value === null ? null : snapshot("error");
    }),
  }),
  Object.freeze({
    id: "signal-field", field: "signal",
    partitions: Object.freeze([
      "own-property probe throw -> terminal malformed",
      "own property absent -> continue without a property read",
      "own getter read throw -> terminal malformed",
      "own value undefined -> continue",
      "own value null -> continue",
      "own string matching ^SIG[A-Z0-9_]{1,31}$ -> terminal signal with that string",
      "every other own value -> terminal signal with UNKNOWN_SIGNAL",
    ]),
    operation: Object.freeze((state) => {
      let own;
      try { own = Object.prototype.hasOwnProperty.call(state.result, "signal"); } catch { return snapshot("malformed"); }
      if (!own) return null;
      let value;
      try { value = state.result.signal; } catch { return snapshot("malformed"); }
      if (value === undefined || value === null) return null;
      return snapshot("signal", null, typeof value === "string" && SAFE_SIGNAL.test(value) ? value : "UNKNOWN_SIGNAL");
    }),
  }),
  Object.freeze({
    id: "status-field", field: "status",
    partitions: Object.freeze([
      "own-property probe throw -> terminal malformed",
      "own property absent -> terminal missing-status without a property read",
      "own getter read throw -> terminal malformed",
      "own value that is not an integer -> terminal missing-status",
      "own integer zero -> continue",
      "every other own integer -> terminal nonzero-status with that integer",
    ]),
    operation: Object.freeze((state) => {
      let own;
      try { own = Object.prototype.hasOwnProperty.call(state.result, "status"); } catch { return snapshot("malformed"); }
      if (!own) return snapshot("missing-status");
      let value;
      try { value = state.result.status; } catch { return snapshot("malformed"); }
      if (!Number.isInteger(value)) return snapshot("missing-status");
      return value === 0 ? null : snapshot("nonzero-status", value);
    }),
  }),
  Object.freeze({
    id: "success-validator", field: "stdout",
    partitions: Object.freeze([
      "validator throw -> terminal malformed",
      "validator result not exactly true -> terminal malformed",
      "validator result exactly true -> terminal zero-status",
    ]),
    operation: Object.freeze((state) => {
      let valid;
      try { valid = state.successValidator(state.result); } catch { return snapshot("malformed"); }
      return valid === true ? snapshot("zero-status", 0) : snapshot("malformed");
    }),
  }),
]);

export function normalizeSpawnResult({ result, successValidator }) {
  const state = { result, successValidator };
  for (const row of PROCESS_RESULT_DECISION_TABLE) {
    try {
      const terminal = row.operation(state);
      if (terminal !== null) return terminal;
    } catch {
      return snapshot("malformed");
    }
  }
  return snapshot("malformed");
}

export const DESKTOP_STATUS_STAGE_TABLE = Object.freeze([
  makeStage({ id: "arguments", owner: "wrapper", internal_failure_code: "DESKTOP_STATUS_ARGUMENTS_INVALID" }, (context) => (
    Array.isArray(context.argv) && context.argv.length === 0 ? continueWith(context) : failWith()
  )),
  makeStage({ id: "resolver-call", owner: "wrapper", internal_failure_code: "DESKTOP_STATUS_WRAPPER_EXCEPTION" }, (context) => {
    const resolved = context.resolveMsvcFn({ platform: context.platform, baseEnv: context.baseEnv, spawnSyncFn: context.resolverSpawnSyncFn, statSyncFn: context.statSyncFn });
    if (resolved?.ok === false && DESKTOP_STATUS_STAGE_TABLE.includes(resolved.failure_row) && resolved.failure_row.owner === "resolver") return propagate(resolved.failure_row);
    if (resolved?.ok !== true || !["non-windows", "vsdevcmd"].includes(resolved.source) || resolved.env === null || typeof resolved.env !== "object") throw new TypeError("malformed resolver result");
    context.msvcSourceRef.value = resolved.source;
    return continueWith({ ...context, resolved });
  }),
  makeStage({ id: "base-node-injection", owner: "resolver", internal_failure_code: "MSVC_NODE_INJECTION_PRESENT", public_failure_code: "DESKTOP_STATUS_NODE_INJECTION_DENIED" }, (context, row) => {
    const sanitized = sanitizeStatusEnvironment({ baseEnv: context.baseEnv, nodeFailureStage: row });
    if (!sanitized.ok) return failWith();
    const next = { ...context, sanitizedBaseEnv: sanitized.env };
    if (context.platform !== "win32") return completeWith({ ...next, source: "non-windows", env: sanitized.env, vsdevcmd_path: null });
    return continueWith(next);
  }),
  makeStage({ id: "program-files", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => {
    const entry = oneCaseInsensitiveEntry(context.sanitizedBaseEnv, "ProgramFiles(x86)");
    if (!entry || !path.win32.isAbsolute(entry.value)) return failWith();
    return continueWith({ ...context, programFilesX86: entry.value });
  }),
  makeStage({ id: "vswhere-file", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => {
    const vswherePath = path.win32.join(context.programFilesX86, "Microsoft Visual Studio", "Installer", "vswhere.exe");
    return statRegularFile(context.statSyncFn, vswherePath) ? continueWith({ ...context, vswherePath }) : failWith();
  }),
  makeStage({ id: "vswhere-launch", owner: "resolver", internal_failure_code: "MSVC_SETUP_FAILED" }, (context) => {
    const vswhereResult = context.spawnSyncFn(context.vswherePath, ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath", "-utf8"], { encoding: "utf8", windowsHide: true, shell: false, env: context.sanitizedBaseEnv });
    return continueWith({ ...context, vswhereResult });
  }),
  makeStage({ id: "vswhere-result", owner: "resolver", internal_failure_code: "MSVC_SETUP_FAILED" }, (context) => {
    let stdout;
    const process_snapshot = normalizeSpawnResult({ result: context.vswhereResult, successValidator: (result) => { stdout = result.stdout; return typeof stdout === "string"; } });
    return process_snapshot.category === "zero-status" ? continueWith({ ...context, vswhereStdout: stdout }) : failWith(process_snapshot);
  }),
  makeStage({ id: "installation-output", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => {
    const lines = context.vswhereStdout.split(/\r?\n/u).map((line) => line.trim()).filter((line) => line.length > 0);
    return lines.length === 1 ? continueWith({ ...context, installationPath: lines[0] }) : failWith();
  }),
  makeStage({ id: "installation-path", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => {
    if (!validInstallationPath(context.installationPath)) return failWith();
    return continueWith({ ...context, vsdevcmdPath: path.win32.join(context.installationPath, "Common7", "Tools", "VsDevCmd.bat") });
  }),
  makeStage({ id: "vsdevcmd-file", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => (
    statRegularFile(context.statSyncFn, context.vsdevcmdPath) ? continueWith(context) : failWith()
  )),
  makeStage({ id: "comspec-file", owner: "resolver", internal_failure_code: "MSVC_TOOLCHAIN_NOT_FOUND" }, (context) => {
    const entry = oneCaseInsensitiveEntry(context.sanitizedBaseEnv, "ComSpec");
    if (!entry || !path.win32.isAbsolute(entry.value) || !statRegularFile(context.statSyncFn, entry.value)) return failWith();
    return continueWith({ ...context, comspecPath: entry.value });
  }),
  makeStage({ id: "capture-launch", owner: "resolver", internal_failure_code: "MSVC_SETUP_FAILED" }, (context) => {
    const command = `call "${context.vsdevcmdPath}" -no_logo -arch=x64 -host_arch=x64 >nul && set`;
    const captureResult = context.spawnSyncFn(context.comspecPath, ["/d", "/s", "/u", "/v:off", "/c", command], { encoding: "buffer", windowsHide: true, windowsVerbatimArguments: true, shell: false, env: context.sanitizedBaseEnv });
    return continueWith({ ...context, captureResult });
  }),
  makeStage({ id: "capture-result", owner: "resolver", internal_failure_code: "MSVC_SETUP_FAILED" }, (context) => {
    let stdout;
    const process_snapshot = normalizeSpawnResult({ result: context.captureResult, successValidator: (result) => { stdout = result.stdout; return Buffer.isBuffer(stdout); } });
    return process_snapshot.category === "zero-status" ? continueWith({ ...context, captureBuffer: stdout }) : failWith(process_snapshot);
  }),
  makeStage({ id: "capture-decode", owner: "resolver", internal_failure_code: "MSVC_ENV_INVALID" }, (context) => {
    if (!Buffer.isBuffer(context.captureBuffer) || context.captureBuffer.length === 0 || context.captureBuffer.length % 2 !== 0) return failWith();
    try {
      const decodedSet = new TextDecoder("utf-16le", { fatal: true }).decode(context.captureBuffer);
      return continueWith({ ...context, decodedSet });
    } catch { return failWith(); }
  }),
  makeStage({ id: "set-parse", owner: "resolver", internal_failure_code: "MSVC_ENV_INVALID" }, (context) => {
    const parsed = parseSetOutput(context.decodedSet);
    return parsed.ok ? continueWith({ ...context, capturedEnv: parsed.env }) : failWith();
  }),
  makeStage({ id: "required-env", owner: "resolver", internal_failure_code: "MSVC_ENV_INVALID" }, (context) => (
    REQUIRED_MSVC_KEYS.every((key) => oneCaseInsensitiveEntry(context.capturedEnv, key) !== null) ? continueWith(context) : failWith()
  )),
  makeStage({ id: "captured-node-injection", owner: "resolver", internal_failure_code: "MSVC_NODE_INJECTION_PRESENT", public_failure_code: "DESKTOP_STATUS_NODE_INJECTION_DENIED" }, (context, row) => {
    const sanitized = sanitizeStatusEnvironment({ baseEnv: context.capturedEnv, nodeFailureStage: row });
    return sanitized.ok ? continueWith({ ...context, source: "vsdevcmd", env: sanitized.env, vsdevcmd_path: context.vsdevcmdPath }) : failWith();
  }),
  makeStage({ id: "final-node-injection", owner: "wrapper", internal_failure_code: "MSVC_NODE_INJECTION_PRESENT", public_failure_code: "DESKTOP_STATUS_NODE_INJECTION_DENIED", msvc_source_policy: "resolved" }, (context, row) => {
    const sanitized = sanitizeStatusEnvironment({ baseEnv: context.resolved.env, nodeFailureStage: row });
    return sanitized.ok ? continueWith({ ...context, finalEnv: sanitized.env }) : failWith();
  }),
  makeStage({ id: "final-env", owner: "wrapper", internal_failure_code: "DESKTOP_STATUS_ENV_INVALID", msvc_source_policy: "resolved" }, (context) => {
    const keys = Object.keys(context.finalEnv);
    if ([...STATUS_OVERRIDE_KEYS, ...NODE_KEYS].some((key) => keys.some((candidate) => candidate.toLowerCase() === key.toLowerCase()))) return failWith();
    for (const key of PRESERVED_CONTROL_KEYS) {
      const before = oneCaseInsensitiveEntry(context.resolved.env, key);
      if (before && oneCaseInsensitiveEntry(context.finalEnv, key)?.value !== before.value) return failWith();
    }
    return continueWith(context);
  }),
  makeStage({ id: "runner-launch", owner: "wrapper", internal_failure_code: "DESKTOP_STATUS_WRAPPER_EXCEPTION", msvc_source_policy: "resolved" }, (context) => {
    const runnerPath = path.resolve(context.appDir, "scripts", "desktop-pane-e2e.mjs");
    const runnerResult = context.spawnSyncFn(context.execPath, [runnerPath, "--stop-after-worker-status"], { cwd: context.appDir, env: context.finalEnv, stdio: "inherit", windowsHide: false, shell: false });
    return continueWith({ ...context, runnerResult });
  }),
  makeStage({ id: "runner-result", owner: "wrapper", internal_failure_code: "DESKTOP_STATUS_CHILD_FAILED", msvc_source_policy: "resolved", child_policy: "from-process-result", exit_policy: "status-1-through-255-else-one" }, (context) => {
    const process_snapshot = normalizeSpawnResult({ result: context.runnerResult, successValidator: () => true });
    return process_snapshot.category === "zero-status" ? continueWith(context) : failWith(process_snapshot);
  }),
  makeStage({ id: "main-catch", owner: "main", internal_failure_code: "DESKTOP_STATUS_WRAPPER_EXCEPTION" }, () => failWith()),
]);

export function executeStageProjection({ owner, context }) {
  const rows = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.owner === owner);
  if (rows.length === 0 || context === null || typeof context !== "object") throw new TypeError("invalid stage projection");
  let current = context;
  for (const row of rows) {
    let operationResult;
    try { operationResult = row.operation(current); } catch { return { ok: false, failure_row: row, process_snapshot: null }; }
    if (operationResult?.kind === "continue" && operationResult.context && typeof operationResult.context === "object") { current = operationResult.context; continue; }
    if (operationResult?.kind === "complete" && operationResult.context && typeof operationResult.context === "object") return { ok: true, completion: "early", context: operationResult.context };
    if (operationResult?.kind === "fail" && (operationResult.process_snapshot === null || typeof operationResult.process_snapshot === "object")) return { ok: false, failure_row: row, process_snapshot: operationResult.process_snapshot };
    if (operationResult?.kind === "propagate" && DESKTOP_STATUS_STAGE_TABLE.includes(operationResult.failure_row) && operationResult.failure_row.owner === "resolver") return { ok: false, failure_row: operationResult.failure_row, process_snapshot: null };
    return { ok: false, failure_row: row, process_snapshot: null };
  }
  return { ok: true, completion: "exhausted", context: current };
}

export function sanitizeStatusEnvironment({ baseEnv, nodeFailureStage }) {
  if (!DESKTOP_STATUS_STAGE_TABLE.includes(nodeFailureStage) || nodeFailureStage.internal_failure_code !== "MSVC_NODE_INJECTION_PRESENT") throw new TypeError("invalid node failure stage");
  let entries;
  try { entries = Object.entries(baseEnv); } catch { return { ok: false }; }
  const environment = {};
  for (const [key, value] of entries) {
    const folded = key.toLowerCase();
    if (STATUS_OVERRIDE_KEYS.some((candidate) => candidate.toLowerCase() === folded)) continue;
    if (NODE_KEYS.some((candidate) => candidate.toLowerCase() === folded)) {
      if (value !== "") return { ok: false };
      continue;
    }
    environment[key] = value;
  }
  return { ok: true, env: environment };
}

export function parseSetOutput(text) {
  try {
    if (typeof text !== "string") return { ok: false };
    const environment = {};
    const foldedKeys = new Set();
    for (let line of text.split("\n")) {
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.length === 0 || line.startsWith("=")) continue;
      const separator = line.indexOf("=");
      if (separator <= 0) return { ok: false };
      const key = line.slice(0, separator);
      const folded = key.toLowerCase();
      if (foldedKeys.has(folded)) return { ok: false };
      foldedKeys.add(folded);
      environment[key] = line.slice(separator + 1);
    }
    return { ok: true, env: environment };
  } catch { return { ok: false }; }
}

export function resolveMsvcEnvironment({ platform, baseEnv, spawnSyncFn, statSyncFn }) {
  try {
    const projection = executeStageProjection({ owner: "resolver", context: { platform, baseEnv, spawnSyncFn, statSyncFn } });
    if (!projection.ok) return { ok: false, failure_row: projection.failure_row };
    const { source, env, vsdevcmd_path } = projection.context;
    return { ok: true, source, env, vsdevcmd_path };
  } catch {
    return { ok: false, failure_row: DESKTOP_STATUS_STAGE_TABLE.find((row) => row.owner === "resolver") };
  }
}
