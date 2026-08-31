import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  DESKTOP_STATUS_STAGE_TABLE,
  PROCESS_RESULT_DECISION_TABLE,
  executeStageProjection,
  normalizeSpawnResult,
  parseSetOutput,
  resolveMsvcEnvironment,
  sanitizeStatusEnvironment,
} from "./windows-msvc-env.mjs";
import {
  isDirectExecution,
  projectRunResult,
  runDesktopStatusE2E,
} from "./desktop-status-e2e.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const APP_DIR = path.resolve(SCRIPT_DIR, "..");
const RUNNER_PATH = path.join(SCRIPT_DIR, "desktop-pane-e2e.mjs");

const checks = [];
function check(name, body) {
  body();
  checks.push(name);
}

function deepFrozen(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function") || seen.has(value)) return true;
  seen.add(value);
  if (!Object.isFrozen(value)) return false;
  return Reflect.ownKeys(value).every((key) => deepFrozen(value[key], seen));
}

function stage(id) {
  const found = DESKTOP_STATUS_STAGE_TABLE.find((entry) => entry.id === id);
  assert.ok(found, `missing canonical stage ${id}`);
  return found;
}

function makeCapturedEnv(overrides = {}) {
  return {
    VSCMD_VER: "17.14.0",
    VCINSTALLDIR: "C:\\VS\\VC\\",
    WindowsSdkDir: "C:\\SDK\\",
    INCLUDE: "C:\\VS\\include",
    LIB: "C:\\VS\\lib",
    PATH: "C:\\VS\\bin;C:\\Windows\\System32",
    ...overrides,
  };
}

function setBuffer(env = makeCapturedEnv()) {
  const text = `${Object.entries(env).map(([key, value]) => `${key}=${value}`).join("\r\n")}\r\n`;
  return Buffer.from(text, "utf16le");
}

function resolverHarness({
  platform = "win32",
  baseEnv = { "ProgramFiles(x86)": "C:\\Program Files (x86)", ComSpec: "C:\\Windows\\System32\\cmd.exe" },
  vswhereResult = { status: 0, signal: null, stdout: "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\r\n" },
  captureResult = { status: 0, signal: null, stdout: setBuffer() },
  spawnThrowAt = null,
  statBehavior = () => ({ isFile: () => true }),
} = {}) {
  const calls = [];
  const spawnSyncFn = (file, argv, options) => {
    const index = calls.length;
    calls.push({ file, argv, options });
    if (spawnThrowAt === index) throw new Error("injected");
    return index === 0 ? vswhereResult : captureResult;
  };
  const statCalls = [];
  const statSyncFn = (target, ...rest) => {
    statCalls.push({ target, rest });
    return statBehavior(target, statCalls.length - 1);
  };
  return {
    calls,
    statCalls,
    result: () => resolveMsvcEnvironment({ platform, baseEnv, spawnSyncFn, statSyncFn }),
  };
}

function ownThrowing(name) {
  const target = {};
  Object.defineProperty(target, name, { enumerable: true, get() { throw new Error("getter"); } });
  return target;
}

function proxyProbeThrow(name) {
  return new Proxy({}, { getOwnPropertyDescriptor(_target, key) { if (key === name) throw new Error("probe"); return undefined; } });
}

check("stage table is the one deep-frozen execution vocabulary", () => {
  assert.equal(DESKTOP_STATUS_STAGE_TABLE.length, 22);
  assert.ok(deepFrozen(DESKTOP_STATUS_STAGE_TABLE));
  assert.equal(new Set(DESKTOP_STATUS_STAGE_TABLE.map(({ id }) => id)).size, DESKTOP_STATUS_STAGE_TABLE.length);
  for (const [index, entry] of DESKTOP_STATUS_STAGE_TABLE.entries()) {
    assert.deepEqual(Object.keys(entry).sort(), ["child_policy", "exit_policy", "id", "internal_failure_code", "msvc_source_policy", "operation", "owner", "public_failure_code"].sort());
    assert.equal(typeof entry.operation, "function", `${entry.id} operation`);
    const ownerProjection = DESKTOP_STATUS_STAGE_TABLE.filter(({ owner }) => owner === entry.owner);
    assert.equal(ownerProjection.includes(entry), true, `${entry.id} owner projection`);
    assert.equal(DESKTOP_STATUS_STAGE_TABLE.indexOf(entry), index);
  }
  const internalCodes = new Set(DESKTOP_STATUS_STAGE_TABLE.map(({ internal_failure_code }) => internal_failure_code));
  const publicCodes = new Set(DESKTOP_STATUS_STAGE_TABLE.map(({ public_failure_code }) => public_failure_code));
  assert.ok(internalCodes.size > 1 && publicCodes.size > 1);
  const renamed = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.internal_failure_code !== row.public_failure_code);
  assert.ok(renamed.length > 0);
  assert.ok(renamed.every((row) => row.internal_failure_code === "MSVC_NODE_INJECTION_PRESENT"));
  assert.throws(() => executeStageProjection({ owner: "unknown", context: {} }), /invalid stage projection/);
});

check("process result table is the one five-row deep-frozen classifier", () => {
  assert.equal(PROCESS_RESULT_DECISION_TABLE.length, 5);
  assert.ok(deepFrozen(PROCESS_RESULT_DECISION_TABLE));
  for (const entry of PROCESS_RESULT_DECISION_TABLE) {
    assert.deepEqual(Object.keys(entry).sort(), ["field", "id", "operation", "partitions"].sort());
    assert.equal(typeof entry.operation, "function");
  }
});

check("process result partitions cover all three result stages", () => {
  const validators = {
    "vswhere-result": (value) => typeof value.stdout === "string",
    "capture-result": (value) => Buffer.isBuffer(value.stdout),
    "runner-result": () => true,
  };
  for (const [resultStage, successValidator] of Object.entries(validators)) {
    const normalize = (result) => normalizeSpawnResult({ result, successValidator: () => successValidator(result) });
    assert.deepEqual(normalize(null), { category: "malformed", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize(proxyProbeThrow("error")), { category: "malformed", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize(ownThrowing("error")), { category: "malformed", status: null, signal: null }, resultStage);
    for (const errorValue of [undefined, null]) {
      assert.deepEqual(normalize({ error: errorValue, status: 0, signal: null, stdout: resultStage === "capture-result" ? Buffer.alloc(2) : "" }), { category: "zero-status", status: 0, signal: null }, `${resultStage} nullish error`);
    }
    assert.deepEqual(normalize({ status: 0, signal: null, stdout: resultStage === "capture-result" ? Buffer.alloc(2) : "" }), { category: "zero-status", status: 0, signal: null }, `${resultStage} missing error`);
    assert.deepEqual(normalize({ error: false, status: 0 }), { category: "error", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize(proxyProbeThrow("signal")), { category: "malformed", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize(ownThrowing("signal")), { category: "malformed", status: null, signal: null }, resultStage);
    for (const signalValue of [undefined, null]) {
      assert.deepEqual(normalize({ signal: signalValue, status: 7 }), { category: "nonzero-status", status: 7, signal: null }, `${resultStage} nullish signal`);
    }
    assert.deepEqual(normalize({ signal: "SIGTERM", status: 0 }), { category: "signal", status: null, signal: "SIGTERM" }, resultStage);
    assert.deepEqual(normalize({ signal: "bad", status: 0 }), { category: "signal", status: null, signal: "UNKNOWN_SIGNAL" }, resultStage);
    assert.deepEqual(normalize(proxyProbeThrow("status")), { category: "malformed", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize(ownThrowing("status")), { category: "malformed", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize({}), { category: "missing-status", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize({ status: "0" }), { category: "missing-status", status: null, signal: null }, resultStage);
    assert.deepEqual(normalize({ status: 7 }), { category: "nonzero-status", status: 7, signal: null }, resultStage);
    const invalidStdoutResult = normalize({ status: 0, stdout: resultStage === "capture-result" ? "wrong" : 1 });
    assert.deepEqual(invalidStdoutResult, resultStage === "runner-result"
      ? { category: "zero-status", status: 0, signal: null }
      : { category: "malformed", status: null, signal: null }, resultStage);
  }
  assert.deepEqual(normalizeSpawnResult({ result: { status: 0 }, successValidator: () => { throw new Error("validator"); } }), { category: "malformed", status: null, signal: null });
  assert.deepEqual(normalizeSpawnResult({ result: { status: 0 }, successValidator: () => 1 }), { category: "malformed", status: null, signal: null });
  let stdoutReads = 0;
  const stdoutOnce = { status: 0, get stdout() { stdoutReads += 1; return "ok"; } };
  assert.deepEqual(normalizeSpawnResult({ result: stdoutOnce, successValidator: (result) => typeof result.stdout === "string" }), { category: "zero-status", status: 0, signal: null });
  assert.equal(stdoutReads, 1);
});

check("sanitize removes all runner overrides and rejects nonempty Node injection", () => {
  const runnerSource = readFileSync(RUNNER_PATH, "utf8");
  const runnerKeys = new Set(runnerSource.match(/WINSMUX_DESKTOP_E2E_[A-Z0-9_]+/g));
  assert.equal(runnerKeys.size, 13);
  const preserved = new Set(["WINSMUX_DESKTOP_E2E_CONTROL_PIPE_TOKEN", "WINSMUX_DESKTOP_E2E_CDP_TIMEOUT_MS"]);
  const removed = [...runnerKeys].filter((key) => !preserved.has(key));
  assert.equal(removed.length, 11);
  const input = Object.fromEntries([...removed.map((key) => [key.toLowerCase(), "1"]), ...[...preserved].map((key) => [key, `${key}-value`]), ["node_options", ""], ["NoDe_PaTh", ""]]);
  const sanitized = sanitizeStatusEnvironment({ baseEnv: input, nodeFailureStage: stage("base-node-injection") });
  assert.equal(sanitized.ok, true);
  assert.ok(removed.every((key) => !Object.keys(sanitized.env).some((candidate) => candidate.toLowerCase() === key.toLowerCase())));
  assert.ok([...preserved].every((key) => sanitized.env[key] === `${key}-value`));
  for (const key of ["NODE_OPTIONS", "node_path"]) {
    assert.deepEqual(sanitizeStatusEnvironment({ baseEnv: { [key]: "injected" }, nodeFailureStage: stage("base-node-injection") }), { ok: false });
  }
});

check("set parser preserves values and rejects malformed or duplicate input", () => {
  assert.deepEqual(parseSetOutput("=C:=C:\\x\r\nA=one=two\r\nB=three\r\n"), { ok: true, env: { A: "one=two", B: "three" } });
  assert.deepEqual(parseSetOutput("A=1\nA=2\n"), { ok: false });
  assert.deepEqual(parseSetOutput("missing\n"), { ok: false });
});

check("resolver uses exact transports and accepts measured Program Files path", () => {
  const harness = resolverHarness();
  const result = harness.result();
  assert.equal(result.ok, true);
  assert.equal(result.source, "vsdevcmd");
  assert.equal(harness.calls.length, 2);
  assert.equal(harness.statCalls.length, 3);
  assert.ok(harness.statCalls.every(({ rest }) => rest.length === 0));
  assert.deepEqual(harness.calls[0].argv, ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath", "-utf8"]);
  assert.deepEqual(harness.calls[0].options, { encoding: "utf8", windowsHide: true, shell: false, env: harness.calls[0].options.env });
  assert.equal(harness.calls[1].file.toLowerCase(), "c:\\windows\\system32\\cmd.exe");
  assert.deepEqual(harness.calls[1].argv.slice(0, 5), ["/d", "/s", "/u", "/v:off", "/c"]);
  assert.match(harness.calls[1].argv[5], /^call "C:\\Program Files \(x86\)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\Tools\\VsDevCmd\.bat" -no_logo -arch=x64 -host_arch=x64 >nul && set$/);
  assert.deepEqual({ ...harness.calls[1].options, env: undefined }, { encoding: "buffer", windowsHide: true, windowsVerbatimArguments: true, shell: false, env: undefined });
  assert.strictEqual(harness.calls[0].options.env, harness.calls[1].options.env);
});

check("resolver rejects every cmd metacharacter and each missing required value", () => {
  for (const witness of ['"', "%", "!", "^", "&", "|", "<", ">", "\r", "\n", "\0"]) {
    const harness = resolverHarness({ vswhereResult: { status: 0, stdout: `C:\\VS${witness}bad\r\n` } });
    const expectedStage = witness === "\n" ? "installation-output" : "installation-path";
    assert.deepEqual(harness.result(), { ok: false, failure_row: stage(expectedStage) }, JSON.stringify(witness));
    assert.equal(harness.calls.length, 1);
  }
  for (const required of Object.keys(makeCapturedEnv())) {
    for (const replacement of [undefined, ""]) {
      const env = makeCapturedEnv();
      if (replacement === undefined) delete env[required]; else env[required] = replacement;
      const harness = resolverHarness({ captureResult: { status: 0, stdout: setBuffer(env) } });
      assert.deepEqual(harness.result(), { ok: false, failure_row: stage("required-env") }, `${required}:${String(replacement)}`);
    }
  }
});

check("resolver handles stat boundaries and non-Windows early completion", () => {
  for (const behavior of [
    () => null,
    () => ({}),
    () => ({ get isFile() { throw new Error("getter"); } }),
    () => ({ isFile: 1 }),
    () => ({ isFile() { throw new Error("call"); } }),
    () => ({ isFile: () => "true" }),
    () => ({ isFile: () => false }),
  ]) {
    assert.deepEqual(resolverHarness({ statBehavior: behavior }).result(), { ok: false, failure_row: stage("vswhere-file") });
  }
  const nonWindows = resolverHarness({ platform: "linux", baseEnv: { Keep: "yes", NODE_PATH: "" }, statBehavior: () => { throw new Error("must not stat"); } });
  assert.deepEqual(nonWindows.result(), { ok: true, source: "non-windows", env: { Keep: "yes" }, vsdevcmd_path: null });
  assert.equal(nonWindows.calls.length, 0);
  assert.equal(nonWindows.statCalls.length, 0);
});

check("wrapper projects canonical failures and owns the exact runner spawn", () => {
  const spawnCalls = [];
  const success = runDesktopStatusE2E({
    argv: [], platform: "win32", baseEnv: {}, appDir: APP_DIR, execPath: "C:\\Node\\node.exe",
    resolveMsvcFn: () => ({ ok: true, source: "vsdevcmd", env: { Keep: "yes" }, vsdevcmd_path: "C:\\VS\\VsDevCmd.bat" }),
    spawnSyncFn: (...args) => { spawnCalls.push(args); return { status: 0 }; },
  });
  assert.deepEqual(success, { ok: true, failure_code: null, failure_stage: null, exit_code: 0, child_status: 0, child_signal: null, msvc_source: "vsdevcmd" });
  assert.equal(spawnCalls.length, 1);
  assert.equal(spawnCalls[0][0], "C:\\Node\\node.exe");
  assert.deepEqual(spawnCalls[0][1], [RUNNER_PATH, "--stop-after-worker-status"]);
  assert.deepEqual(spawnCalls[0][2], { cwd: APP_DIR, env: { Keep: "yes" }, stdio: "inherit", windowsHide: false, shell: false });
  const extraArg = runDesktopStatusE2E({ argv: ["unexpected"], platform: "win32", baseEnv: {}, appDir: APP_DIR, execPath: "node", spawnSyncFn: () => { throw new Error("must not spawn"); }, resolveMsvcFn: () => { throw new Error("must not resolve"); } });
  assert.deepEqual(extraArg, projectRunResult({ projection: { ok: false, failure_row: stage("arguments"), process_snapshot: null }, msvcSource: null }));
});

check("all public failure fields are mechanically projected from reached rows", () => {
  for (const row of DESKTOP_STATUS_STAGE_TABLE) {
    const process_snapshot = row.id === "runner-result" ? { category: "nonzero-status", status: 17, signal: null } : null;
    const source = row.msvc_source_policy === "resolved" ? "vsdevcmd" : null;
    const result = projectRunResult({ projection: { ok: false, failure_row: row, process_snapshot }, msvcSource: source });
    assert.deepEqual(Object.keys(result), ["ok", "failure_code", "failure_stage", "exit_code", "child_status", "child_signal", "msvc_source"]);
    assert.equal(result.ok, false);
    assert.equal(result.failure_code, row.public_failure_code);
    assert.equal(result.failure_stage, row.id);
    assert.equal(result.msvc_source, source);
  }
});

check("executor stops at the first reached stage and converts throws", () => {
  for (const owner of new Set(DESKTOP_STATUS_STAGE_TABLE.map(({ owner }) => owner))) {
    const rows = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.owner === owner);
    if (rows.length === 0) continue;
    const first = rows[0];
    const original = first.operation;
    assert.equal(typeof original, "function");
    const result = executeStageProjection({ owner, context: { argv: ["bad"] } });
    assert.equal(result.ok, false);
    assert.strictEqual(result.failure_row, first);
  }
});

check("each canonical stage operation has an injected failure witness", () => {
  for (const row of DESKTOP_STATUS_STAGE_TABLE) {
    const poison = new Proxy({}, { get() { throw new Error(`injected ${row.id}`); } });
    let outcome;
    try { outcome = row.operation(poison); } catch { outcome = { kind: "throw" }; }
    assert.ok(outcome.kind === "fail" || outcome.kind === "throw", `${row.id} failure witness`);
  }
});

check("main guard is silent on import and handles undefined argv", () => {
  assert.equal(isDirectExecution({ argv1: undefined, modulePath: fileURLToPath(pathToFileURL("C:\\x\\module.mjs")), platform: "win32" }), false);
  assert.equal(isDirectExecution({ argv1: "C:\\X\\MODULE.MJS", modulePath: "C:\\x\\module.mjs", platform: "win32" }), true);
  assert.equal(isDirectExecution({ argv1: "/X/module.mjs", modulePath: "/x/module.mjs", platform: "linux" }), false);
});

check("package and v0.36.26 wiring use the wrapper while direct routes remain", () => {
  const packageJson = JSON.parse(readFileSync(path.join(APP_DIR, "package.json"), "utf8"));
  assert.equal(packageJson.scripts["test:desktop-status-e2e"], "node ./scripts/desktop-status-e2e.mjs");
  assert.match(packageJson.scripts["test:desktop-pane-e2e"], /desktop-pane-e2e\.mjs/);
  assert.match(packageJson.scripts["test:desktop-release-popout-e2e"], /desktop-pane-e2e\.mjs --release-popout-only/);
  const gate = readFileSync(path.resolve(APP_DIR, "..", "scripts", "test-v03626-desktop-split-gate.ps1"), "utf8");
  assert.match(gate, /desktop-status-e2e\\\.mjs/);
});

console.log(JSON.stringify({ ok: true, check_count: checks.length, checks }));
