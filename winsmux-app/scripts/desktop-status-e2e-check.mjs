import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  DESKTOP_STATUS_STAGE_TABLE,
  PROCESS_RESULT_DECISION_TABLE,
  executeStageProjection,
  parseSetOutput,
  resolveMsvcEnvironment,
} from "./windows-msvc-env.mjs";
import {
  isDirectExecution,
  projectRunResult,
  runDesktopStatusE2E,
} from "./desktop-status-e2e.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const APP_DIR = path.resolve(SCRIPT_DIR, "..");
const WRAPPER_PATH = path.join(SCRIPT_DIR, "desktop-status-e2e.mjs");
const RUNNER_PATH = path.join(SCRIPT_DIR, "desktop-pane-e2e.mjs");
const PROGRAM_FILES_X86 = "C:\\Program Files (x86)";
const VS_INSTALLATION = `${PROGRAM_FILES_X86}\\Microsoft Visual Studio\\2022\\BuildTools`;
const VSWHERE_PATH = `${PROGRAM_FILES_X86}\\Microsoft Visual Studio\\Installer\\vswhere.exe`;
const VSDEVCMD_PATH = `${VS_INSTALLATION}\\Common7\\Tools\\VsDevCmd.bat`;
const COMSPEC_PATH = "C:\\Windows\\System32\\cmd.exe";
const NODE_KEYS = Object.freeze(["NODE_OPTIONS", "NODE_PATH"]);
const CONTROL_KEYS = Object.freeze([
  "WINSMUX_DESKTOP_E2E_CONTROL_PIPE_TOKEN",
  "WINSMUX_DESKTOP_E2E_CDP_TIMEOUT_MS",
]);
const EXPECTED_OWNER_ORDER_SHA256 = Object.freeze({
  resolver: "d66d22ff8e80c365c7000c56b3abcaa78ebbd7f03b57e65e3b4b59e2abc7f7d5",
  wrapper: "1691a570a064adf8a0979b5eed6bf99e181eb6e62200ef4fa088245761439473",
});

const checks = [];
let processResultCoverage = null;
function check(name, body) {
  body();
  checks.push(name);
}

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function deepFrozen(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function") || seen.has(value)) return true;
  seen.add(value);
  if (!Object.isFrozen(value)) return false;
  return Reflect.ownKeys(value).every((key) => deepFrozen(value[key], seen));
}

function rowsFor(owner) {
  return DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.owner === owner);
}

function rowById(id) {
  const row = DESKTOP_STATUS_STAGE_TABLE.find((candidate) => candidate.id === id);
  assert.ok(row, `missing canonical stage ${id}`);
  return row;
}

function mixedCase(value) {
  return [...value].map((character, index) => index % 2 === 0 ? character.toLowerCase() : character.toUpperCase()).join("");
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

function setBuffer(environment = makeCapturedEnv()) {
  const text = `${Object.entries(environment).map(([key, value]) => `${key}=${value}`).join("\r\n")}\r\n`;
  return Buffer.from(text, "utf16le");
}

const runnerSource = readFileSync(RUNNER_PATH, "utf8");
const runnerEnvironmentKeys = [...new Set(runnerSource.match(/WINSMUX_DESKTOP_E2E_[A-Z0-9_]+/g))];
const overrideKeys = Object.freeze(runnerEnvironmentKeys.filter((key) => !CONTROL_KEYS.includes(key)));

function makeResolverExecution(options = {}) {
  const baseEnv = options.baseEnv ?? { "ProgramFiles(x86)": PROGRAM_FILES_X86, ComSpec: COMSPEC_PATH };
  const vswhereResult = Object.hasOwn(options, "vswhereResult") ? options.vswhereResult : { status: 0, signal: null, stdout: `${VS_INSTALLATION}\r\n` };
  const captureResult = Object.hasOwn(options, "captureResult") ? options.captureResult : { status: 0, signal: null, stdout: setBuffer() };
  const spawnThrowIndex = options.spawnThrowIndex ?? -1;
  const statFailureIndex = options.statFailureIndex ?? -1;
  const statBehavior = options.statBehavior ?? null;
  const spawnCalls = [];
  const statCalls = [];
  const effects = [];
  const spawnSyncFn = (file, argv, options) => {
    const index = spawnCalls.length;
    effects.push(["vswhere-launch", "capture-launch"][index] ?? `unexpected-spawn-${index}`);
    spawnCalls.push({ file, argv, options });
    if (index === spawnThrowIndex) throw new Error("injected spawn failure");
    return index === 0 ? vswhereResult : captureResult;
  };
  const statSyncFn = (target, ...rest) => {
    const index = statCalls.length;
    effects.push(["vswhere-file", "vsdevcmd-file", "comspec-file"][index] ?? `unexpected-stat-${index}`);
    statCalls.push({ target, rest });
    if (statBehavior) return statBehavior(target, index);
    return { isFile: () => index !== statFailureIndex };
  };
  const context = { platform: "win32", baseEnv, spawnSyncFn, statSyncFn };
  return {
    context,
    spawnCalls,
    statCalls,
    effects,
    execute: () => executeStageProjection({ owner: "resolver", context }),
    resolve: () => resolveMsvcEnvironment({ platform: "win32", baseEnv, spawnSyncFn, statSyncFn }),
  };
}

function makeWrapperExecution(options = {}) {
  const argv = options.argv ?? [];
  const resolvedEnv = options.resolvedEnv ?? { Keep: "yes" };
  const resolverThrow = options.resolverThrow ?? false;
  const runnerThrow = options.runnerThrow ?? false;
  const runnerResult = Object.hasOwn(options, "runnerResult") ? options.runnerResult : { status: 0 };
  const resolverCalls = [];
  const runnerCalls = [];
  const effects = [];
  const msvcSourceRef = { value: null };
  const resolveMsvcFn = (...args) => {
    effects.push("resolver-call");
    resolverCalls.push(args);
    if (resolverThrow) throw new Error("injected resolver failure");
    return { ok: true, source: "vsdevcmd", env: resolvedEnv, vsdevcmd_path: VSDEVCMD_PATH };
  };
  const spawnSyncFn = (...args) => {
    effects.push("runner-launch");
    runnerCalls.push(args);
    if (runnerThrow) throw new Error("injected runner failure");
    return runnerResult;
  };
  const context = {
    argv: Object.freeze([...argv]),
    platform: "win32",
    baseEnv: {},
    appDir: APP_DIR,
    execPath: "C:\\Node\\node.exe",
    spawnSyncFn,
    resolverSpawnSyncFn: spawnSyncFn,
    statSyncFn: undefined,
    resolveMsvcFn,
    msvcSourceRef,
  };
  return {
    context,
    resolverCalls,
    runnerCalls,
    effects,
    execute: () => executeStageProjection({ owner: "wrapper", context }),
  };
}

function resolverFailureWitness(target) {
  const options = {};
  switch (target.id) {
    case "base-node-injection":
      options.baseEnv = { "ProgramFiles(x86)": PROGRAM_FILES_X86, ComSpec: COMSPEC_PATH, NoDe_OpTiOnS: "injected" };
      break;
    case "program-files": options.baseEnv = { ComSpec: COMSPEC_PATH }; break;
    case "vswhere-file": options.statFailureIndex = 0; break;
    case "vswhere-launch": options.spawnThrowIndex = 0; break;
    case "vswhere-result": options.vswhereResult = { status: 17 }; break;
    case "installation-output": options.vswhereResult = { status: 0, stdout: "\r\n" }; break;
    case "installation-path": options.vswhereResult = { status: 0, stdout: "C:\\bad%path\r\n" }; break;
    case "vsdevcmd-file": options.statFailureIndex = 1; break;
    case "comspec-file": options.statFailureIndex = 2; break;
    case "capture-launch": options.spawnThrowIndex = 1; break;
    case "capture-result": options.captureResult = { status: 19 }; break;
    case "capture-decode": options.captureResult = { status: 0, stdout: Buffer.from([0]) }; break;
    case "set-parse": options.captureResult = { status: 0, stdout: Buffer.from("malformed\r\n", "utf16le") }; break;
    case "required-env": options.captureResult = { status: 0, stdout: setBuffer({ ...makeCapturedEnv(), LIB: "" }) }; break;
    case "captured-node-injection": options.captureResult = { status: 0, stdout: setBuffer(makeCapturedEnv({ nOdE_pAtH: "injected" })) }; break;
    default: assert.fail(`missing resolver witness for ${target.id}`);
  }
  return makeResolverExecution(options);
}

function wrapperFailureWitness(target) {
  switch (target.id) {
    case "arguments": return makeWrapperExecution({ argv: ["unexpected"] });
    case "resolver-call": return makeWrapperExecution({ resolverThrow: true });
    case "final-node-injection": return makeWrapperExecution({ resolvedEnv: { nOdE_oPtIoNs: "injected" } });
    case "final-env": {
      let reads = 0;
      const resolvedEnv = {};
      Object.defineProperty(resolvedEnv, CONTROL_KEYS[0], {
        enumerable: true,
        get() { reads += 1; return reads === 1 ? "first" : "second"; },
      });
      return makeWrapperExecution({ resolvedEnv });
    }
    case "runner-launch": return makeWrapperExecution({ runnerThrow: true });
    case "runner-result": return makeWrapperExecution({ runnerResult: { status: 23 } });
    default: assert.fail(`missing wrapper witness for ${target.id}`);
  }
}

function assertOwnerFailureWitnesses(owner, factory) {
  const rows = rowsFor(owner);
  const observedFailures = [];
  assert.equal(sha256(rows.map((row) => row.id).join("\n")), EXPECTED_OWNER_ORDER_SHA256[owner], `${owner} causal order`);
  for (const [targetIndex, target] of rows.entries()) {
    const witness = factory(target);
    const projection = witness.execute();
    assert.equal(projection.ok, false, `${target.id} must fail`);
    assert.strictEqual(projection.failure_row, target, `${target.id} canonical failure row`);
    observedFailures.push(projection.failure_row.id);
    const reachedRows = rows.slice(0, targetIndex + 1);
    if (owner === "resolver") {
      const spawnMilestones = rows.filter((row) => row.id === "vswhere-launch" || row.id === "capture-launch");
      const statMilestones = rows.filter((row) => row.id === "vswhere-file" || row.id === "vsdevcmd-file" || row.id === "comspec-file");
      assert.equal(witness.spawnCalls.length, spawnMilestones.filter((row) => rows.indexOf(row) <= targetIndex).length, `${target.id} later spawn count`);
      assert.equal(witness.statCalls.length, statMilestones.filter((row) => rows.indexOf(row) <= targetIndex).length, `${target.id} later stat count`);
      const expectedEffects = reachedRows.filter((row) => [...spawnMilestones, ...statMilestones].includes(row)).map((row) => row.id);
      assert.deepEqual(witness.effects, expectedEffects, `${target.id} causal side-effect trace`);
    } else {
      const resolverCallIndex = rows.indexOf(rowById("resolver-call"));
      const runnerLaunchIndex = rows.indexOf(rowById("runner-launch"));
      assert.equal(witness.resolverCalls.length, targetIndex >= resolverCallIndex ? 1 : 0, `${target.id} later resolver count`);
      assert.equal(witness.runnerCalls.length, targetIndex >= runnerLaunchIndex ? 1 : 0, `${target.id} later runner count`);
      const expectedEffects = reachedRows.filter((row) => row.id === "resolver-call" || row.id === "runner-launch").map((row) => row.id);
      assert.deepEqual(witness.effects, expectedEffects, `${target.id} causal side-effect trace`);
    }
  }
  assert.deepEqual(observedFailures, rows.map((row) => row.id), `${owner} observed failure order`);
}

function trackedResult(properties, { probeThrow = null, readThrow = null, absent = [] } = {}) {
  const counts = { probe: Object.create(null), read: Object.create(null) };
  const target = { ...properties };
  for (const key of absent) delete target[key];
  const result = new Proxy(target, {
    getOwnPropertyDescriptor(object, key) {
      counts.probe[key] = (counts.probe[key] ?? 0) + 1;
      if (key === probeThrow) throw new Error("probe failure");
      return Reflect.getOwnPropertyDescriptor(object, key);
    },
    get(object, key, receiver) {
      counts.read[key] = (counts.read[key] ?? 0) + 1;
      if (key === readThrow) throw new Error("getter failure");
      return Reflect.get(object, key, receiver);
    },
  });
  return { result, counts };
}

function validStdoutFor(stageId) {
  return stageId === "capture-result" ? setBuffer() : `${VS_INSTALLATION}\r\n`;
}

function partitionVariants(decisionRow, partition, stageId) {
  const properties = { signal: null, status: 0, stdout: validStdoutFor(stageId) };
  const variants = [];
  const add = (label, changes = {}, faults = {}, expectedCategory = "zero-status", expectedSignal = null, expectedStatus = expectedCategory === "zero-status" ? 0 : null) => {
    const tracked = trackedResult({ ...properties, ...changes }, faults);
    variants.push({ label, ...tracked, expected: { category: expectedCategory, status: expectedStatus, signal: expectedSignal }, targetField: decisionRow.field });
  };
  if (decisionRow.id === "result-object") {
    if (partition.startsWith("non-null object")) add("object");
    else for (const value of [null, undefined, 7]) variants.push({ label: String(value), result: value, counts: null, expected: { category: "malformed", status: null, signal: null }, targetField: null });
  } else if (decisionRow.id === "error-field") {
    if (partition.startsWith("own-property probe throw")) add("probe", {}, { probeThrow: "error" }, "malformed");
    else if (partition.startsWith("own property absent")) add("absent", {}, { absent: ["error"] });
    else if (partition.startsWith("own getter read throw")) add("getter", { error: null }, { readThrow: "error" }, "malformed");
    else if (partition.includes("undefined")) add("undefined", { error: undefined });
    else if (partition.includes("null")) add("null", { error: null });
    else add("other", { error: false }, {}, "error");
  } else if (decisionRow.id === "signal-field") {
    if (partition.startsWith("own-property probe throw")) add("probe", {}, { probeThrow: "signal" }, "malformed");
    else if (partition.startsWith("own property absent")) add("absent", {}, { absent: ["signal"] });
    else if (partition.startsWith("own getter read throw")) add("getter", {}, { readThrow: "signal" }, "malformed");
    else if (partition.includes("undefined")) add("undefined", { signal: undefined });
    else if (partition.includes("null")) add("null", { signal: null });
    else if (partition.includes("matching")) add("safe", { signal: "SIGTERM" }, {}, "signal", "SIGTERM");
    else add("unsafe", { signal: "unsafe" }, {}, "signal", "UNKNOWN_SIGNAL");
  } else if (decisionRow.id === "status-field") {
    if (partition.startsWith("own-property probe throw")) add("probe", {}, { probeThrow: "status" }, "malformed");
    else if (partition.startsWith("own property absent")) add("absent", {}, { absent: ["status"] }, "missing-status");
    else if (partition.startsWith("own getter read throw")) add("getter", {}, { readThrow: "status" }, "malformed");
    else if (partition.includes("not an integer")) add("noninteger", { status: "0" }, {}, "missing-status");
    else if (partition.includes("integer zero")) add("zero", { status: 0 });
    else add("nonzero", { status: 29 }, {}, "nonzero-status", null, 29);
  } else if (decisionRow.id === "success-validator") {
    if (partition.startsWith("validator throw")) add("validator-throw", {}, { readThrow: "stdout" }, "malformed");
    else if (partition.includes("not exactly true")) add("validator-not-true", { stdout: stageId === "capture-result" ? "wrong" : Buffer.alloc(2) }, {}, "malformed");
    else add("validator-true");
  }
  return variants;
}

function executeProcessVariant(stageId, result) {
  if (stageId === "vswhere-result") {
    const witness = makeResolverExecution({ vswhereResult: result });
    return { projection: witness.execute(), childCalls: witness.spawnCalls.length };
  }
  if (stageId === "capture-result") {
    const witness = makeResolverExecution({ captureResult: result });
    return { projection: witness.execute(), childCalls: witness.spawnCalls.length };
  }
  const witness = makeWrapperExecution({ runnerResult: result });
  return { projection: witness.execute(), childCalls: witness.runnerCalls.length };
}

function isProcessPartitionApplicable(stageRow, decisionRow, variant) {
  return !(stageRow.id === "runner-result" && decisionRow.id === "success-validator" && variant.label !== "validator-true");
}

function assertProcessPartitionsThroughStages() {
  const resultStages = rowsFor("resolver").filter((row) => row.id.endsWith("-result"));
  resultStages.push(...rowsFor("wrapper").filter((row) => row.id === "runner-result"));
  assert.deepEqual(resultStages.map((row) => row.id), ["vswhere-result", "capture-result", "runner-result"]);
  const excluded = [];
  const executedPartitions = new Set();
  let successValidatorExecutions = 0;
  let runnerStdoutReads = 0;
  for (const stageRow of resultStages) {
    for (const decisionRow of PROCESS_RESULT_DECISION_TABLE) {
      for (const partition of decisionRow.partitions) {
        const variants = partitionVariants(decisionRow, partition, stageRow.id);
        assert.ok(variants.length > 0, `${stageRow.id}/${decisionRow.id} unhandled partition: ${partition}`);
        for (const variant of variants) {
          const applicabilityKey = `${stageRow.id}/${variant.label}`;
          if (!isProcessPartitionApplicable(stageRow, decisionRow, variant)) {
            excluded.push(applicabilityKey);
            continue;
          }
          executedPartitions.add(`${stageRow.id}/${decisionRow.id}/${partition}`);
          if (decisionRow.id === "success-validator") successValidatorExecutions += 1;
          const { projection, childCalls } = executeProcessVariant(stageRow.id, variant.result);
          if (variant.expected.category === "zero-status") {
            assert.equal(projection.ok, true, `${stageRow.id}/${decisionRow.id}/${variant.label}`);
          } else {
            assert.equal(projection.ok, false, `${stageRow.id}/${decisionRow.id}/${variant.label}`);
            assert.strictEqual(projection.failure_row, stageRow);
            assert.deepEqual(projection.process_snapshot, variant.expected);
          }
          const expectedChildren = stageRow.id === "vswhere-result" ? (projection.ok ? 2 : 1) : stageRow.id === "capture-result" ? 2 : 1;
          assert.equal(childCalls, expectedChildren, `${stageRow.id}/${decisionRow.id}/${variant.label} first failure`);
          if (variant.counts && variant.targetField) {
            const field = variant.targetField;
            if (partition.startsWith("own property absent")) {
              assert.equal(variant.counts.probe[field], 1);
              assert.equal(variant.counts.read[field] ?? 0, 0);
            } else if (partition.includes("getter read") || partition.includes("own value") || partition.includes("matching") || partition.includes("every other own value")) {
              assert.equal(variant.counts.probe[field], 1);
              assert.equal(variant.counts.read[field], 1);
            } else if (partition.startsWith("own-property probe throw")) {
              assert.equal(variant.counts.probe[field], 1);
              assert.equal(variant.counts.read[field] ?? 0, 0);
            }
          }
          if (decisionRow.id === "success-validator") {
            const stdoutReads = variant.counts?.read.stdout ?? 0;
            assert.equal(stdoutReads, stageRow.id === "runner-result" ? 0 : 1, `${stageRow.id} stdout ownership`);
            if (stageRow.id === "runner-result") runnerStdoutReads += stdoutReads;
          }
        }
      }
    }
  }
  const commonRows = PROCESS_RESULT_DECISION_TABLE.filter((row) => row.id !== "success-validator");
  const expectedCommonPartitionStageExecutions = resultStages.length * commonRows.reduce((total, row) => total + row.partitions.length, 0);
  const commonPartitionStageExecutions = [...executedPartitions].filter((key) => commonRows.some((row) => key.includes(`/${row.id}/`))).length;
  const successValidatorRow = PROCESS_RESULT_DECISION_TABLE.find((row) => row.id === "success-validator");
  assert.ok(successValidatorRow);
  assert.equal(commonRows.length, 4);
  assert.equal(commonPartitionStageExecutions, expectedCommonPartitionStageExecutions);
  assert.equal(successValidatorExecutions, successValidatorRow.partitions.length * 2 + 1);
  assert.equal(runnerStdoutReads, 0);
  assert.deepEqual(excluded.sort(), ["runner-result/validator-not-true", "runner-result/validator-throw"]);
  processResultCoverage = Object.freeze({
    common_rows: commonRows.length,
    common_actual_stages: resultStages.length,
    common_partition_stage_executions: commonPartitionStageExecutions,
    success_validator_vswhere_capture_executions: successValidatorRow.partitions.length * 2,
    runner_exact_true_executions: 1,
    runner_stdout_reads: runnerStdoutReads,
    excluded,
  });
}

function environmentAtSanitizationPoint(row, nodeEnvironment) {
  const controls = Object.fromEntries(CONTROL_KEYS.map((key) => [key, `${key}-preserved`]));
  const overrides = Object.fromEntries(overrideKeys.map((key) => [mixedCase(key), "remove"]));
  if (row.id === "base-node-injection") {
    const witness = makeResolverExecution({ baseEnv: { "ProgramFiles(x86)": PROGRAM_FILES_X86, ComSpec: COMSPEC_PATH, ...controls, ...overrides, ...nodeEnvironment } });
    const projection = witness.execute();
    return { projection, childCalls: witness.spawnCalls.length, environment: witness.spawnCalls[0]?.options.env };
  }
  if (row.id === "captured-node-injection") {
    const witness = makeResolverExecution({ captureResult: { status: 0, stdout: setBuffer(makeCapturedEnv({ ...controls, ...overrides, ...nodeEnvironment })) } });
    const projection = witness.execute();
    return { projection, childCalls: witness.spawnCalls.length, environment: projection.ok ? projection.context.env : null };
  }
  if (row.id === "final-node-injection") {
    const witness = makeWrapperExecution({ resolvedEnv: { ...controls, ...overrides, ...nodeEnvironment } });
    const projection = witness.execute();
    return { projection, childCalls: witness.runnerCalls.length, environment: witness.runnerCalls[0]?.[2].env };
  }
  assert.fail(`unexpected sanitization row ${row.id}`);
}

function assertSanitizationPoints() {
  const rows = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.internal_failure_code === "MSVC_NODE_INJECTION_PRESENT");
  assert.equal(rows.length, 3);
  for (const row of rows) {
    const emptyNodes = Object.fromEntries(NODE_KEYS.map((key) => [mixedCase(key), ""]));
    const success = environmentAtSanitizationPoint(row, emptyNodes);
    assert.equal(success.projection.ok, true, `${row.id} empty Node keys`);
    const finalKeys = Object.keys(success.environment);
    assert.ok([...overrideKeys, ...NODE_KEYS].every((key) => !finalKeys.some((candidate) => candidate.toLowerCase() === key.toLowerCase())), `${row.id} removals`);
    for (const key of CONTROL_KEYS) assert.equal(success.environment[key], `${key}-preserved`, `${row.id} ${key}`);
    for (const nodeKey of NODE_KEYS) {
      const failure = environmentAtSanitizationPoint(row, { [mixedCase(nodeKey)]: "injected" });
      assert.equal(failure.projection.ok, false, `${row.id}/${nodeKey}`);
      assert.strictEqual(failure.projection.failure_row, row);
      assert.equal(failure.childCalls, row.id === "captured-node-injection" ? 2 : 0, `${row.id}/${nodeKey} no later child`);
    }
  }
}

function runNode(args) {
  return spawnSync(process.execPath, args, { cwd: path.resolve(APP_DIR, ".."), encoding: "utf8", windowsHide: true, shell: false });
}

check("canonical tables and owner projections are frozen and complete", () => {
  assert.equal(DESKTOP_STATUS_STAGE_TABLE.length, 22);
  assert.equal(PROCESS_RESULT_DECISION_TABLE.length, 5);
  assert.ok(deepFrozen(DESKTOP_STATUS_STAGE_TABLE));
  assert.ok(deepFrozen(PROCESS_RESULT_DECISION_TABLE));
  assert.equal(new Set(DESKTOP_STATUS_STAGE_TABLE.map((row) => row.id)).size, 22);
  const internalCodes = new Set(DESKTOP_STATUS_STAGE_TABLE.map((row) => row.internal_failure_code));
  const publicCodes = new Set(DESKTOP_STATUS_STAGE_TABLE.map((row) => row.public_failure_code));
  assert.ok(internalCodes.size > 1 && publicCodes.size > 1);
  const renamedRows = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.internal_failure_code !== row.public_failure_code);
  assert.ok(renamedRows.length > 0);
  assert.ok(renamedRows.every((row) => row.internal_failure_code === "MSVC_NODE_INJECTION_PRESENT"));
  assert.equal(runnerEnvironmentKeys.length, 13);
  assert.equal(overrideKeys.length, 11);
  for (const row of DESKTOP_STATUS_STAGE_TABLE) {
    assert.deepEqual(Object.keys(row).sort(), ["child_policy", "exit_policy", "id", "internal_failure_code", "msvc_source_policy", "operation", "owner", "public_failure_code"].sort());
    assert.equal(typeof row.operation, "function");
  }
  for (const row of PROCESS_RESULT_DECISION_TABLE) {
    assert.deepEqual(Object.keys(row).sort(), ["field", "id", "operation", "partitions"].sort());
    assert.equal(typeof row.operation, "function");
  }
  assert.throws(() => executeStageProjection({ owner: "unknown", context: {} }), /invalid stage projection/);
});

check("every resolver row has an executor failure witness", () => assertOwnerFailureWitnesses("resolver", resolverFailureWitness));
check("every wrapper row has an executor failure witness", () => assertOwnerFailureWitnesses("wrapper", wrapperFailureWitness));
check("common process partitions cover three actual stages; success validation covers vswhere/capture plus runner exact-true", assertProcessPartitionsThroughStages);
check("all three canonical sanitization points remove or reject injected values", assertSanitizationPoints);

check("fixed transports use exact executables, argv, options, and shared environment", () => {
  const witness = makeResolverExecution();
  assert.equal(witness.execute().ok, true);
  assert.equal(witness.spawnCalls.length, 2);
  const [vswhere, cmd] = witness.spawnCalls;
  const vswhereArgv = ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath", "-utf8"];
  const command = `call "${VSDEVCMD_PATH}" -no_logo -arch=x64 -host_arch=x64 >nul && set`;
  const cmdArgv = ["/d", "/s", "/u", "/v:off", "/c", command];
  assert.equal(vswhere.file, VSWHERE_PATH);
  assert.equal(vswhere.argv.length, 8);
  assert.deepEqual(vswhere.argv, vswhereArgv);
  assert.deepEqual(Object.keys(vswhere.options).sort(), ["encoding", "env", "shell", "windowsHide"].sort());
  assert.deepEqual({ ...vswhere.options, env: undefined }, { encoding: "utf8", windowsHide: true, shell: false, env: undefined });
  assert.equal(cmd.file, COMSPEC_PATH);
  assert.equal(cmd.argv.length, 6);
  assert.deepEqual(cmd.argv, cmdArgv);
  assert.equal(cmd.argv.filter((value) => value === command).length, 1);
  assert.deepEqual(Object.keys(cmd.options).sort(), ["encoding", "env", "shell", "windowsHide", "windowsVerbatimArguments"].sort());
  assert.deepEqual({ ...cmd.options, env: undefined }, { encoding: "buffer", windowsHide: true, windowsVerbatimArguments: true, shell: false, env: undefined });
  assert.strictEqual(vswhere.options.env, cmd.options.env);
  assert.equal(witness.statCalls.length, 3);
  assert.ok(witness.statCalls.every((call) => call.rest.length === 0));
  const runnerCalls = [];
  const runResult = runDesktopStatusE2E({
    argv: [],
    platform: "win32",
    baseEnv: {},
    appDir: APP_DIR,
    execPath: "C:\\Node\\node.exe",
    resolveMsvcFn: () => ({ ok: true, source: "vsdevcmd", env: { Keep: "yes" }, vsdevcmd_path: VSDEVCMD_PATH }),
    spawnSyncFn: (...args) => { runnerCalls.push(args); return { status: 0 }; },
  });
  assert.deepEqual(runResult, { ok: true, failure_code: null, failure_stage: null, exit_code: 0, child_status: 0, child_signal: null, msvc_source: "vsdevcmd" });
  assert.equal(runnerCalls.length, 1);
  assert.equal(runnerCalls[0][0], "C:\\Node\\node.exe");
  assert.deepEqual(runnerCalls[0][1], [RUNNER_PATH, "--stop-after-worker-status"]);
  assert.deepEqual(runnerCalls[0][2], { cwd: APP_DIR, env: { Keep: "yes" }, stdio: "inherit", windowsHide: false, shell: false });
});

check("set parsing, path grammar, required values, and stat boundaries remain closed", () => {
  assert.deepEqual(parseSetOutput("=C:=C:\\x\r\nA=one=two\r\nB=three\r\n"), { ok: true, env: { A: "one=two", B: "three" } });
  assert.deepEqual(parseSetOutput("A=1\nA=2\n"), { ok: false });
  assert.deepEqual(parseSetOutput("missing\n"), { ok: false });
  for (const character of ['"', "%", "!", "^", "&", "|", "<", ">", "\r", "\n", "\0"]) {
    const projection = makeResolverExecution({ vswhereResult: { status: 0, stdout: `C:\\VS${character}bad\r\n` } }).execute();
    assert.strictEqual(projection.failure_row, rowById(character === "\n" ? "installation-output" : "installation-path"));
  }
  for (const required of Object.keys(makeCapturedEnv())) {
    for (const replacement of [undefined, ""]) {
      const environment = makeCapturedEnv();
      if (replacement === undefined) delete environment[required]; else environment[required] = replacement;
      const projection = makeResolverExecution({ captureResult: { status: 0, stdout: setBuffer(environment) } }).execute();
      assert.strictEqual(projection.failure_row, rowById("required-env"));
    }
  }
  for (const behavior of [
    () => null,
    () => ({}),
    () => ({ get isFile() { throw new Error("getter"); } }),
    () => ({ isFile: 1 }),
    () => ({ isFile() { throw new Error("call"); } }),
    () => ({ isFile: () => "true" }),
    () => ({ isFile: () => false }),
  ]) assert.strictEqual(makeResolverExecution({ statBehavior: behavior }).execute().failure_row, rowById("vswhere-file"));
  const nonWindows = resolveMsvcEnvironment({
    platform: "linux",
    baseEnv: { Keep: "yes", NODE_PATH: "" },
    spawnSyncFn: () => { throw new Error("must not spawn"); },
    statSyncFn: () => { throw new Error("must not stat"); },
  });
  assert.deepEqual(nonWindows, { ok: true, source: "non-windows", env: { Keep: "yes" }, vsdevcmd_path: null });
});

check("public RunResult fields are projected only from canonical rows", () => {
  for (const row of DESKTOP_STATUS_STAGE_TABLE) {
    const process_snapshot = row.id === "runner-result" ? { category: "nonzero-status", status: 17, signal: null } : null;
    const source = row.msvc_source_policy === "resolved" ? "vsdevcmd" : null;
    const result = projectRunResult({ projection: { ok: false, failure_row: row, process_snapshot }, msvcSource: source });
    assert.deepEqual(Object.keys(result), ["ok", "failure_code", "failure_stage", "exit_code", "child_status", "child_signal", "msvc_source"]);
    assert.equal(result.failure_code, row.public_failure_code);
    assert.equal(result.failure_stage, row.id);
    assert.equal(result.msvc_source, source);
  }
  const resolverCall = rowById("resolver-call");
  const runnerLaunch = rowById("runner-launch");
  assert.equal(projectRunResult({ projection: { ok: false, failure_row: resolverCall, process_snapshot: null }, msvcSource: "vsdevcmd" }).msvc_source, null);
  assert.equal(projectRunResult({ projection: { ok: false, failure_row: runnerLaunch, process_snapshot: null }, msvcSource: "vsdevcmd" }).msvc_source, "vsdevcmd");
});

check("controlled child processes prove import silence and main stream ownership", () => {
  const wrapperUrl = pathToFileURL(WRAPPER_PATH).href;
  const silentImport = runNode(["--input-type=module", "-e", `await import(${JSON.stringify(wrapperUrl)});`]);
  assert.equal(silentImport.status, 0);
  assert.equal(silentImport.stdout, "");
  assert.equal(silentImport.stderr, "");
  const preChild = runNode([WRAPPER_PATH, "unexpected"]);
  assert.equal(preChild.status, 1);
  assert.equal(preChild.stdout, "");
  assert.equal(preChild.stderr.split("\n").filter(Boolean).length, 1);
  const diagnostic = JSON.parse(preChild.stderr.trim());
  assert.deepEqual(Object.keys(diagnostic), ["schema", "ok", "failure_code", "failure_stage", "exit_code", "child_status", "child_signal", "msvc_source"]);
  assert.deepEqual(diagnostic, { schema: "winsmux-desktop-status-wrapper/v1", ok: false, failure_code: "DESKTOP_STATUS_ARGUMENTS_INVALID", failure_stage: "arguments", exit_code: 1, child_status: null, child_signal: null, msvc_source: null });
  assert.equal(preChild.stderr, `${JSON.stringify(diagnostic)}\n`);
  assert.equal(preChild.stderr.includes(APP_DIR), false);
  assert.equal(preChild.stderr.includes("Error"), false);
  const childScript = `
    const { main } = await import(${JSON.stringify(wrapperUrl)});
    process.argv = [process.execPath];
    main({
      resolveMsvcFn: () => ({ ok: true, source: "vsdevcmd", env: { Keep: "yes" }, vsdevcmd_path: ${JSON.stringify(VSDEVCMD_PATH)} }),
      spawnSyncFn: (_file, _argv, options) => {
        if (options.stdio !== "inherit") throw new Error("child streams captured");
        process.stdout.write("RUNNER_STDOUT_MARKER\\n");
        process.stderr.write("RUNNER_STDERR_MARKER\\n");
        return { status: 0 };
      },
    });
  `;
  const inherited = runNode(["--input-type=module", "-e", childScript]);
  assert.equal(inherited.status, 0);
  assert.equal(inherited.stdout, "RUNNER_STDOUT_MARKER\n");
  assert.equal(inherited.stderr, "RUNNER_STDERR_MARKER\n");
});

check("direct guard and package/static routes preserve the public entrypoints", () => {
  assert.equal(isDirectExecution({ argv1: undefined, modulePath: "C:\\x\\module.mjs", platform: "win32" }), false);
  assert.equal(isDirectExecution({ argv1: "C:\\X\\MODULE.MJS", modulePath: "C:\\x\\module.mjs", platform: "win32" }), true);
  assert.equal(isDirectExecution({ argv1: "/X/module.mjs", modulePath: "/x/module.mjs", platform: "linux" }), false);
  const packageJson = JSON.parse(readFileSync(path.join(APP_DIR, "package.json"), "utf8"));
  assert.equal(packageJson.scripts["test:desktop-status-e2e"], "node ./scripts/desktop-status-e2e.mjs");
  assert.match(packageJson.scripts["test:desktop-pane-e2e"], /desktop-pane-e2e\.mjs/);
  assert.match(packageJson.scripts["test:desktop-release-popout-e2e"], /desktop-pane-e2e\.mjs --release-popout-only/);
  const gate = readFileSync(path.resolve(APP_DIR, "..", "scripts", "test-v03626-desktop-split-gate.ps1"), "utf8");
  assert.match(gate, /desktop-status-e2e\\\.mjs/);
});

console.log(JSON.stringify({ ok: true, check_count: checks.length, checks, process_result_coverage: processResultCoverage }));
