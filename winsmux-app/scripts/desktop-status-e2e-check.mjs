import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  DESKTOP_STATUS_STAGE_TABLE,
  PROCESS_RESULT_DECISION_TABLE,
  executeCanonicalStage,
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

const checks = [];
let processResultCoverage = null;
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

function stageFailureWitness(target) {
  if (target.owner === "resolver") return resolverFailureWitness(target);
  if (target.owner === "wrapper") return wrapperFailureWitness(target);
  if (target.owner === "main") {
    return {
      execute: () => executeStageProjection({ owner: target.owner, context: {} }),
    };
  }
  assert.fail(`missing owner witness for ${target.owner}`);
}

function assertOwnerFailureWitnesses(owner) {
  const rows = rowsFor(owner);
  const observedFailures = [];
  for (const [targetIndex, target] of rows.entries()) {
    const witness = stageFailureWitness(target);
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
    } else if (owner === "wrapper") {
      const resolverCallIndex = rows.indexOf(rowById("resolver-call"));
      const runnerLaunchIndex = rows.indexOf(rowById("runner-launch"));
      assert.equal(witness.resolverCalls.length, targetIndex >= resolverCallIndex ? 1 : 0, `${target.id} later resolver count`);
      assert.equal(witness.runnerCalls.length, targetIndex >= runnerLaunchIndex ? 1 : 0, `${target.id} later runner count`);
      const expectedEffects = reachedRows.filter((row) => row.id === "resolver-call" || row.id === "runner-launch").map((row) => row.id);
      assert.deepEqual(witness.effects, expectedEffects, `${target.id} causal side-effect trace`);
    } else {
      assert.equal(owner, "main");
      assert.equal(rows.length, 1);
      assert.equal(projection.process_snapshot, null);
      const projected = projectRunResult({ projection, msvcSource: null });
      assert.deepEqual(projected, { ok: false, failure_code: target.public_failure_code, failure_stage: target.id, exit_code: 1, child_status: null, child_signal: null, msvc_source: null });
    }
  }
  assert.deepEqual(observedFailures, rows.map((row) => row.id), `${owner} observed failure order`);
}

function assertAllOwnerFailureWitnesses() {
  const owners = [...new Set(DESKTOP_STATUS_STAGE_TABLE.map((row) => row.owner))];
  assert.ok(owners.length > 0);
  for (const owner of owners) assertOwnerFailureWitnesses(owner);
}

const processAccessFields = Object.freeze(PROCESS_RESULT_DECISION_TABLE.filter((row) => row.field !== null).map((row) => row.field));
const handledProcessPartitionKeys = new Set();

function emptyAccessMap() {
  return Object.fromEntries(processAccessFields.map((field) => [field, 0]));
}

function processPartitionKey(decisionRow, partition) {
  const rowIndex = PROCESS_RESULT_DECISION_TABLE.indexOf(decisionRow);
  const partitionIndex = decisionRow.partitions.indexOf(partition);
  assert.ok(rowIndex >= 0 && partitionIndex >= 0);
  assert.equal(decisionRow.partitions.lastIndexOf(partition), partitionIndex, `${decisionRow.id} duplicate partition`);
  return `${rowIndex}/${partitionIndex}/${partition}`;
}

function applyContinuationBaseline({ probe, read }, rows, result_stdout_kind) {
  for (const row of rows) {
    if (row.field === null) continue;
    if (row.field === "stdout") {
      read.stdout = result_stdout_kind === "none" ? 0 : 1;
    } else {
      probe[row.field] = 1;
      read[row.field] = 1;
    }
  }
}

function expectedAccessVector({ decisionRow, partition, result_stdout_kind }) {
  assert.ok(["string", "buffer", "none"].includes(result_stdout_kind));
  const rowIndex = PROCESS_RESULT_DECISION_TABLE.indexOf(decisionRow);
  assert.ok(rowIndex >= 0);
  const key = processPartitionKey(decisionRow, partition);
  const expected = { probe: emptyAccessMap(), read: emptyAccessMap() };
  const earlierRows = PROCESS_RESULT_DECISION_TABLE.slice(0, rowIndex);
  const laterRows = PROCESS_RESULT_DECISION_TABLE.slice(rowIndex + 1);
  applyContinuationBaseline(expected, earlierRows, result_stdout_kind);

  let continues = false;
  if (decisionRow.id === "result-object") {
    if (partition.startsWith("non-null object")) continues = true;
    else if (!partition.includes("terminal malformed")) assert.fail(`unhandled oracle partition ${key}`);
  } else if (["error-field", "signal-field", "status-field"].includes(decisionRow.id)) {
    const field = decisionRow.field;
    if (partition.startsWith("own-property probe throw") || partition.startsWith("own property absent")) {
      expected.probe[field] = 1;
    } else if (partition.startsWith("own getter read throw") || partition.includes("own value") || partition.includes("own integer") || partition.includes("matching") || partition.includes("every other own")) {
      expected.probe[field] = 1;
      expected.read[field] = 1;
    } else {
      assert.fail(`unhandled oracle partition ${key}`);
    }
    if (decisionRow.id === "error-field" || decisionRow.id === "signal-field") {
      continues = partition.startsWith("own property absent") || partition.includes("undefined") || partition.includes("null -> continue");
    } else {
      continues = partition.includes("integer zero");
    }
  } else if (decisionRow.id === "success-validator") {
    if (!partition.startsWith("validator throw") && !partition.includes("not exactly true") && !partition.includes("exactly true")) {
      assert.fail(`unhandled oracle partition ${key}`);
    }
    expected.read.stdout = result_stdout_kind === "none" ? 0 : 1;
  } else {
    assert.fail(`unhandled oracle row ${decisionRow.id}`);
  }
  if (continues) applyContinuationBaseline(expected, laterRows, result_stdout_kind);
  handledProcessPartitionKeys.add(key);
  Object.freeze(expected.probe);
  Object.freeze(expected.read);
  return Object.freeze(expected);
}

function trackedResult(properties, { probeThrow = null, readThrow = null, absent = [] } = {}) {
  const counts = { probe: emptyAccessMap(), read: emptyAccessMap() };
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

function validStdoutFor(stageRow) {
  if (stageRow.result_stdout_kind === "string") return `${VS_INSTALLATION}\r\n`;
  if (stageRow.result_stdout_kind === "buffer") return setBuffer();
  if (stageRow.result_stdout_kind === "none") return Buffer.alloc(2);
  assert.fail(`unexpected result stdout kind ${stageRow.result_stdout_kind}`);
}

function partitionVariants(decisionRow, partition, stageRow) {
  const properties = { error: null, signal: null, status: 0, stdout: validStdoutFor(stageRow) };
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
    else if (partition.includes("not exactly true")) add("validator-not-true", { stdout: stageRow.result_stdout_kind === "buffer" ? "wrong" : Buffer.alloc(2) }, {}, "malformed");
    else add("validator-true");
  }
  return variants;
}

function executeProcessVariant(stageRow, result) {
  if (stageRow.result_stdout_kind === "string" && stageRow.owner === "resolver") {
    const witness = makeResolverExecution({ vswhereResult: result });
    return { projection: witness.execute(), childCalls: witness.spawnCalls.length };
  }
  if (stageRow.result_stdout_kind === "buffer" && stageRow.owner === "resolver") {
    const witness = makeResolverExecution({ captureResult: result });
    return { projection: witness.execute(), childCalls: witness.spawnCalls.length };
  }
  assert.equal(stageRow.result_stdout_kind, "none");
  assert.equal(stageRow.owner, "wrapper");
  const witness = makeWrapperExecution({ runnerResult: result });
  return { projection: witness.execute(), childCalls: witness.runnerCalls.length };
}

function isProcessPartitionApplicable(stageRow, decisionRow, partition) {
  return !(stageRow.result_stdout_kind === "none" && decisionRow.field === "stdout" && !partition.startsWith("validator result exactly true"));
}

function assertProcessPartitionsThroughStages() {
  assert.deepEqual(processAccessFields, ["error", "signal", "status", "stdout"]);
  const resultStages = DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.result_stdout_kind !== null);
  assert.equal(resultStages.length, 3);
  const excluded = [];
  const executedPartitions = new Set();
  let successValidatorExecutions = 0;
  let runnerStdoutReads = 0;
  for (const stageRow of resultStages) {
    for (const decisionRow of PROCESS_RESULT_DECISION_TABLE) {
      for (const partition of decisionRow.partitions) {
        const expectedVector = expectedAccessVector({ decisionRow, partition, result_stdout_kind: stageRow.result_stdout_kind });
        const variants = partitionVariants(decisionRow, partition, stageRow);
        assert.ok(variants.length > 0, `${stageRow.id}/${decisionRow.id} unhandled partition: ${partition}`);
        for (const variant of variants) {
          const applicabilityKey = `${stageRow.id}/${decisionRow.id}/${variant.label}`;
          if (!isProcessPartitionApplicable(stageRow, decisionRow, partition)) {
            excluded.push(applicabilityKey);
            continue;
          }
          const executionKey = `${DESKTOP_STATUS_STAGE_TABLE.indexOf(stageRow)}/${processPartitionKey(decisionRow, partition)}`;
          executedPartitions.add(executionKey);
          if (decisionRow.id === "success-validator") successValidatorExecutions += 1;
          const { projection, childCalls } = executeProcessVariant(stageRow, variant.result);
          const actualVector = variant.counts ?? { probe: emptyAccessMap(), read: emptyAccessMap() };
          assert.deepEqual(actualVector.probe, expectedVector.probe, `${stageRow.id}/${decisionRow.id}/${variant.label} probe vector`);
          assert.deepEqual(actualVector.read, expectedVector.read, `${stageRow.id}/${decisionRow.id}/${variant.label} read vector`);
          if (variant.expected.category === "zero-status") {
            assert.equal(projection.ok, true, `${stageRow.id}/${decisionRow.id}/${variant.label}`);
          } else {
            assert.equal(projection.ok, false, `${stageRow.id}/${decisionRow.id}/${variant.label}`);
            assert.strictEqual(projection.failure_row, stageRow);
            assert.deepEqual(projection.process_snapshot, variant.expected);
          }
          const expectedChildren = stageRow.result_stdout_kind === "string" ? (projection.ok ? 2 : 1) : stageRow.result_stdout_kind === "buffer" ? 2 : 1;
          assert.equal(childCalls, expectedChildren, `${stageRow.id}/${decisionRow.id}/${variant.label} first failure`);
          if (decisionRow.id === "success-validator") {
            const stdoutReads = actualVector.read.stdout;
            assert.equal(stdoutReads, stageRow.result_stdout_kind === "none" ? 0 : 1, `${stageRow.id} stdout ownership`);
            if (stageRow.result_stdout_kind === "none") runnerStdoutReads += stdoutReads;
          }
        }
      }
    }
  }
  const commonRows = PROCESS_RESULT_DECISION_TABLE.filter((row) => row.id !== "success-validator");
  const expectedCommonPartitionStageExecutions = resultStages.length * commonRows.reduce((total, row) => total + row.partitions.length, 0);
  const expectedCommonExecutionKeys = new Set();
  for (const stageRow of resultStages) {
    for (const decisionRow of commonRows) {
      for (const partition of decisionRow.partitions) {
        expectedCommonExecutionKeys.add(`${DESKTOP_STATUS_STAGE_TABLE.indexOf(stageRow)}/${processPartitionKey(decisionRow, partition)}`);
      }
    }
  }
  const commonPartitionStageExecutions = [...expectedCommonExecutionKeys].filter((key) => executedPartitions.has(key)).length;
  const successValidatorRow = PROCESS_RESULT_DECISION_TABLE.find((row) => row.id === "success-validator");
  assert.ok(successValidatorRow);
  assert.equal(commonRows.length, 4);
  assert.equal(commonPartitionStageExecutions, expectedCommonPartitionStageExecutions);
  assert.equal(successValidatorExecutions, successValidatorRow.partitions.length * 2 + 1);
  assert.equal(runnerStdoutReads, 0);
  assert.equal(excluded.length, 2);
  assert.ok(excluded.every((key) => key.includes("/success-validator/validator-")));
  const declaredPartitionKeys = new Set();
  for (const decisionRow of PROCESS_RESULT_DECISION_TABLE) {
    for (const partition of decisionRow.partitions) declaredPartitionKeys.add(processPartitionKey(decisionRow, partition));
  }
  assert.deepEqual([...handledProcessPartitionKeys].sort(), [...declaredPartitionKeys].sort());
  processResultCoverage = Object.freeze({
    common_rows: commonRows.length,
    derived_actual_result_stage_count: resultStages.length,
    executed_partition_stage_count: executedPartitions.size,
    common_partition_stage_executions: commonPartitionStageExecutions,
    success_validator_vswhere_capture_executions: successValidatorRow.partitions.length * 2,
    runner_exact_true_executions: 1,
    runner_stdout_reads: runnerStdoutReads,
    derived_exclusions: excluded.sort(),
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
    assert.deepEqual(Object.keys(row).sort(), ["child_policy", "exit_policy", "id", "internal_failure_code", "msvc_source_policy", "operation", "owner", "public_failure_code", "result_stdout_kind"].sort());
    assert.equal(typeof row.operation, "function");
    assert.ok([null, "string", "buffer", "none"].includes(row.result_stdout_kind));
  }
  const resultKindCounts = Object.fromEntries(["string", "buffer", "none"].map((kind) => [kind, DESKTOP_STATUS_STAGE_TABLE.filter((row) => row.result_stdout_kind === kind).length]));
  assert.deepEqual(resultKindCounts, { string: 1, buffer: 1, none: 1 });
  for (const row of PROCESS_RESULT_DECISION_TABLE) {
    assert.deepEqual(Object.keys(row).sort(), ["field", "id", "operation", "partitions"].sort());
    assert.equal(typeof row.operation, "function");
  }
  assert.throws(() => executeStageProjection({ owner: "unknown", context: {} }), /invalid stage projection/);
  assert.throws(() => executeCanonicalStage({ stageRow: {}, context: {} }), /invalid canonical stage/);
  assert.throws(() => executeCanonicalStage({ stageRow: DESKTOP_STATUS_STAGE_TABLE[0], context: null }), /invalid canonical stage/);
});

check("every canonical owner row has an executor failure witness", assertAllOwnerFailureWitnesses);
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
  assert.equal(vswhere.argv.length, 8, `transport/vswhere-argv-length expected=8 actual=${vswhere.argv.length}`);
  assert.deepEqual(vswhere.argv, vswhereArgv);
  assert.deepEqual(Object.keys(vswhere.options).sort(), ["encoding", "env", "shell", "windowsHide"].sort());
  assert.deepEqual({ ...vswhere.options, env: undefined }, { encoding: "utf8", windowsHide: true, shell: false, env: undefined });
  assert.equal(cmd.file, COMSPEC_PATH);
  assert.equal(cmd.argv.length, 6, `transport/cmd-argv-length expected=6 actual=${cmd.argv.length}`);
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
  assert.equal(runnerCalls[0][1].length, 2, `transport/runner-argv-length expected=2 actual=${runnerCalls[0][1].length}`);
  assert.deepEqual(runnerCalls[0][1], [RUNNER_PATH, "--stop-after-worker-status"]);
  assert.deepEqual(runnerCalls[0][2], { cwd: APP_DIR, env: { Keep: "yes" }, stdio: "inherit", windowsHide: false, shell: false });
});

check("set parsing, required values, and stat boundaries remain closed", () => {
  assert.deepEqual(parseSetOutput("=C:=C:\\x\r\nA=one=two\r\nB=three\r\n"), { ok: true, env: { A: "one=two", B: "three" } });
  assert.deepEqual(parseSetOutput("A=1\nA=2\n"), { ok: false });
  assert.deepEqual(parseSetOutput("missing\n"), { ok: false });
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

check("installation path grammar rejects exact code points at its canonical row and accepts full transports", () => {
  const installationPathRow = rowById("installation-path");
  const rejectedCodePoints = [34, 37, 33, 94, 38, 124, 60, 62, 13, 10, 0];
  assert.equal(new Set(rejectedCodePoints).size, rejectedCodePoints.length);
  assert.deepEqual(rejectedCodePoints, [34, 37, 33, 94, 38, 124, 60, 62, 13, 10, 0]);
  for (const codePoint of rejectedCodePoints) {
    const character = String.fromCodePoint(codePoint);
    assert.equal(character.length, 1);
    assert.equal(character.codePointAt(0), codePoint);
    let childCalls = 0;
    const step = executeCanonicalStage({
      stageRow: installationPathRow,
      context: {
        installationPath: `C:\\VS${character}bad`,
        spawnSyncFn: () => { childCalls += 1; throw new Error("later cmd child must not run"); },
      },
    });
    assert.deepEqual(Object.keys(step), ["kind", "failure_row", "process_snapshot"]);
    assert.equal(step.kind, "failure");
    assert.strictEqual(step.failure_row, installationPathRow);
    assert.equal(step.process_snapshot, null);
    assert.equal(childCalls, 0);
  }

  const acceptedPaths = [
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools",
    "C:\\開発\\Visual Studio\\BuildTools",
  ];
  for (const installationPath of acceptedPaths) {
    const expectedVsDevCmd = `${installationPath}\\Common7\\Tools\\VsDevCmd.bat`;
    const step = executeCanonicalStage({ stageRow: installationPathRow, context: { installationPath } });
    assert.equal(step.kind, "continue");
    assert.strictEqual(step.stage_row, installationPathRow);
    assert.equal(step.context.vsdevcmdPath, expectedVsDevCmd);

    const witness = makeResolverExecution({ vswhereResult: { status: 0, signal: null, stdout: `${installationPath}\r\n` } });
    assert.equal(witness.execute().ok, true);
    assert.equal(witness.spawnCalls.length, 2);
    const [vswhere, cmd] = witness.spawnCalls;
    const command = `call "${expectedVsDevCmd}" -no_logo -arch=x64 -host_arch=x64 >nul && set`;
    assert.equal(cmd.file, COMSPEC_PATH);
    assert.deepEqual(cmd.argv, ["/d", "/s", "/u", "/v:off", "/c", command]);
    assert.strictEqual(cmd.options.env, vswhere.options.env);
  }
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
  const mainCatchScript = `
    const { main } = await import(${JSON.stringify(wrapperUrl)});
    process.argv = null;
    main();
  `;
  const mainCatch = runNode(["--input-type=module", "-e", mainCatchScript]);
  assert.equal(mainCatch.status, 1);
  assert.equal(mainCatch.stdout, "");
  assert.equal(mainCatch.stderr.split("\n").filter(Boolean).length, 1);
  const mainDiagnostic = JSON.parse(mainCatch.stderr.trim());
  assert.deepEqual(Object.keys(mainDiagnostic), ["schema", "ok", "failure_code", "failure_stage", "exit_code", "child_status", "child_signal", "msvc_source"]);
  assert.deepEqual(mainDiagnostic, { schema: "winsmux-desktop-status-wrapper/v1", ok: false, failure_code: "DESKTOP_STATUS_WRAPPER_EXCEPTION", failure_stage: "main-catch", exit_code: 1, child_status: null, child_signal: null, msvc_source: null });
  assert.equal(mainCatch.stderr, `${JSON.stringify(mainDiagnostic)}\n`);
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
