import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadModelCapabilitiesModule() {
  const sourcePath = path.resolve("src/modelCapabilities.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-common-contract-package-"));
  const modulePath = path.join(tempDir, "modelCapabilities.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

function parseStringUnion(source, typeName) {
  const match = new RegExp(`type\\s+${typeName}\\s*=\\s*([^;]+);`).exec(source);
  assert.ok(match, `Expected to find type ${typeName}`);
  return Array.from(match[1].matchAll(/"([^"]+)"/g), (item) => item[1]);
}

function parseTypeAlias(source, typeName) {
  const match = new RegExp(`type\\s+${typeName}\\s*=\\s*([^;]+);`).exec(source);
  assert.ok(match, `Expected to find type ${typeName}`);
  return match[1].trim();
}

function parsePropertyStringUnion(source, propertyName) {
  const match = new RegExp(`\\b${propertyName}\\??:\\s*([^;]+);`).exec(source);
  assert.ok(match, `Expected to find property ${propertyName}`);
  return Array.from(match[1].matchAll(/"([^"]+)"/g), (item) => item[1]);
}

function parsePropertyType(source, propertyName) {
  const match = new RegExp(`\\b${propertyName}\\??:\\s*([^;]+);`).exec(source);
  assert.ok(match, `Expected to find property ${propertyName}`);
  return match[1].trim();
}

function assertSameVocabulary(name, actual, expected) {
  try {
    assert.deepEqual([...actual], [...expected]);
  } catch {
    throw new Error(`${name} diverged. actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`);
  }
}

function assertDivergenceIsDetected(name, actual, expected) {
  assert.throws(
    () => assertSameVocabulary(name, actual, expected),
    /diverged/,
    `${name} should fail when a vocabulary value is missing or renamed`,
  );
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function loadRustParityFixture(name = "common-contract-package.json") {
  const fixturePath = path.resolve("..", "tests", "fixtures", "rust-parity", name);
  return JSON.parse(await readFile(fixturePath, "utf8"));
}

function readinessVocabularyValues(contractPackage, vocabulary) {
  const values = contractPackage.vocabularies?.[vocabulary]?.values;
  assert.ok(Array.isArray(values), `Expected ${vocabulary} values`);
  return values;
}

function assertReadinessVocabularyContract(contractPackage) {
  const modelReadiness = readinessVocabularyValues(contractPackage, "modelReadiness");
  const runtimeWorkerReadiness = readinessVocabularyValues(contractPackage, "runtimeWorkerReadiness");
  const workerPaneReadiness = readinessVocabularyValues(contractPackage, "workerPaneReadiness");

  for (const state of runtimeWorkerReadiness) {
    assert.ok(modelReadiness.includes(state), `Runtime worker readiness ${state} must remain a model-readiness subset`);
  }
  if (JSON.stringify(modelReadiness) === JSON.stringify(workerPaneReadiness)) {
    throw new Error("model readiness and worker pane readiness must stay separate");
  }
  if (modelReadiness.includes("ready")) {
    throw new Error("model readiness must not contain pane state ready");
  }
  if (workerPaneReadiness.includes("selectable")) {
    throw new Error("worker pane readiness must not contain model state selectable");
  }

  assertSameVocabulary("model readiness", modelReadiness, modelReadinessStates);
  assertSameVocabulary("runtime worker readiness", runtimeWorkerReadiness, runtimeWorkerReadinessStates);
  assertSameVocabulary("worker pane readiness", workerPaneReadiness, workerPaneReadinessStates);
}

function applyReadinessVocabularyMutation(contractPackage, mutation) {
  const mutated = JSON.parse(JSON.stringify(contractPackage));
  if (mutation.copyVocabularyValues) {
    const { from, to } = mutation.copyVocabularyValues;
    mutated.vocabularies[to].values = [...readinessVocabularyValues(mutated, from)];
    return mutated;
  }
  if (mutation.removeVocabularyValue) {
    const { vocabulary, value } = mutation.removeVocabularyValue;
    const values = readinessVocabularyValues(mutated, vocabulary);
    const nextValues = values.filter((item) => item !== value);
    assert.notEqual(nextValues.length, values.length, `${vocabulary} fixture must remove ${value}`);
    mutated.vocabularies[vocabulary].values = nextValues;
    return mutated;
  }
  throw new Error(`Unsupported readiness vocabulary mutation: ${JSON.stringify(mutation)}`);
}

const {
  agentVaultCommandProviderIds,
  backendCapabilityIds,
  benchmarkFamilies,
  commonContractPackage,
  commonContractPackageVersion,
  commonContractSurfaceIds,
  effortCapabilityIds,
  evidenceRecords,
  findDuplicateCapabilityIds,
  findInvalidRequiredBackends,
  findUnsupportedDefaultEfforts,
  getModelEffortIds,
  getRuntimeCatalogEntries,
  modelCapabilities,
  modelReadinessStates,
  modelSourceIds,
  providerCapabilityIds,
  providerCapabilityRegistry,
  providerCapabilities,
  runtimeWorkerReadinessStates,
  transportCapabilityIds,
  validateCapabilityRegistry,
  workerPaneReadinessStates,
} = await loadModelCapabilitiesModule();

assert.equal(commonContractPackageVersion, "0.36.28");
assertSameVocabulary("contract surfaces", commonContractPackage.surfaces, commonContractSurfaceIds);
assert.ok(commonContractPackage.surfaces.includes("provider"));
assert.ok(commonContractPackage.surfaces.includes("readiness"));
assert.ok(commonContractPackage.surfaces.includes("manifest"));
assert.ok(commonContractPackage.surfaces.includes("route"));
assert.ok(commonContractPackage.surfaces.includes("capsule"));
assert.ok(commonContractPackage.surfaces.includes("mailbox"));
assert.ok(commonContractPackage.surfaces.includes("settings"));

assertSameVocabulary(
  "runtime provider IDs",
  commonContractPackage.vocabularies.runtimeProviderIds.values,
  providerCapabilityIds,
);
assertSameVocabulary(
  "model sources",
  commonContractPackage.vocabularies.modelSources.values,
  modelSourceIds,
);
assertSameVocabulary(
  "reasoning efforts",
  commonContractPackage.vocabularies.reasoningEfforts.values,
  effortCapabilityIds,
);
assertSameVocabulary(
  "backend capabilities",
  commonContractPackage.vocabularies.backendCapabilities.values,
  backendCapabilityIds,
);
assertSameVocabulary(
  "prompt transports",
  commonContractPackage.vocabularies.promptTransports.values,
  transportCapabilityIds,
);
assertSameVocabulary(
  "model readiness",
  commonContractPackage.vocabularies.modelReadiness.values,
  modelReadinessStates,
);
assertSameVocabulary(
  "runtime worker readiness",
  commonContractPackage.vocabularies.runtimeWorkerReadiness.values,
  runtimeWorkerReadinessStates,
);
assertSameVocabulary(
  "worker pane readiness",
  commonContractPackage.vocabularies.workerPaneReadiness.values,
  workerPaneReadinessStates,
);
assertSameVocabulary(
  "Agent Vault command providers",
  commonContractPackage.vocabularies.agentVaultCommandProviders.values,
  agentVaultCommandProviderIds,
);
assertSameVocabulary(
  "benchmark families",
  commonContractPackage.vocabularies.benchmarkFamilies.values,
  benchmarkFamilies,
);

const mainSource = await readFile(path.resolve("src/main.ts"), "utf8");
assert.equal(parseTypeAlias(mainSource, "RuntimeProviderId"), "ProviderCapabilityId");
assert.equal(parseTypeAlias(mainSource, "RuntimeModelSource"), "ModelSource");
assert.equal(parseTypeAlias(mainSource, "RuntimeReasoningEffort"), "EffortCapabilityId");
assert.equal(parseTypeAlias(mainSource, "RuntimeModelCatalogStatus"), "ReadinessState");
assert.equal(parseTypeAlias(mainSource, "RuntimeModelWorkerReadinessState"), "CommonRuntimeWorkerReadinessState");
assert.equal(parseTypeAlias(mainSource, "RuntimeModelBenchmarkFamily"), "BenchmarkFamily");
assert.equal(parsePropertyType(mainSource, "promptTransport"), "TransportCapabilityId");
assert.equal(parsePropertyType(mainSource, "requiredBackend"), "BackendCapabilityId");
assert.equal(parseTypeAlias(mainSource, "WorkerPaneReadinessState"), "CommonWorkerPaneReadinessState");
assert.equal(parseTypeAlias(mainSource, "AgentVaultProviderId"), "AgentVaultCommandProviderId");

const expectedCodexEfforts = ["provider-default", "low", "medium", "high", "xhigh"];
const expectedGpt56Efforts = ["low", "medium", "high", "max", "xhigh"];
const gpt56CodexModelIds = [
  "codex-gpt-5-6-sol",
  "codex-gpt-5-6-terra",
  "codex-gpt-5-6-luna",
];
const codexProvider = providerCapabilities.find((provider) => provider.id === "codex");
assert.ok(codexProvider, "Expected Codex provider capability");
assert.deepEqual(codexProvider.supportedEffortIds, expectedCodexEfforts);

for (const modelId of gpt56CodexModelIds) {
  const model = modelCapabilities.find((entry) => entry.id === modelId);
  assert.ok(model, "Expected GPT-5.6 model capability " + modelId);
  assert.equal(model.defaultEffortId, "medium", modelId + " must retain the medium default");
  assert.deepEqual(model.supportedEffortIds, expectedGpt56Efforts, modelId + " must retain max before xhigh");
}

for (const model of modelCapabilities) {
  if (model.providerId === "codex" && !gpt56CodexModelIds.includes(model.id)) {
    assert.ok(!model.supportedEffortIds.includes("max"), model.id + " must not claim GPT-5.6 max support");
  }
}

const expectedClaude5Efforts = ["low", "medium", "high", "max", "xhigh"];
const expectedClaude5Models = [
  { id: "claude-fable-5", model: "claude-fable-5" },
  { id: "claude-opus-5", model: "claude-opus-5" },
  { id: "claude-sonnet-5", model: "claude-sonnet-5" },
];
const claudeProvider = providerCapabilities.find((provider) => provider.id === "claude");
assert.ok(claudeProvider, "MC714-03: Expected Claude provider capability");
assert.equal(claudeProvider.defaultModelId, "claude-opus-4-8", "MC714-03: Claude default must not migrate");

assert.deepEqual(findDuplicateCapabilityIds(providerCapabilityRegistry), [], "MC714-01: registry must have unique IDs");
assert.deepEqual(
  findUnsupportedDefaultEfforts(providerCapabilityRegistry),
  [],
  "MC714-02: registry defaults must remain supported",
);
assert.deepEqual(
  findInvalidRequiredBackends(providerCapabilityRegistry),
  [],
  "MC714-05: registry providers and models must use known backends",
);
assert.deepEqual(validateCapabilityRegistry(providerCapabilityRegistry), [], "MC714-01: registry validation must pass");

const runtimeCatalogEntries = getRuntimeCatalogEntries(providerCapabilityRegistry);
for (const expectedModel of expectedClaude5Models) {
  const model = modelCapabilities.find((entry) => entry.id === expectedModel.id);
  assert.ok(model, `MC714-01: Expected ${expectedModel.id} model capability`);
  assert.equal(model.providerId, "claude", `MC714-01: ${expectedModel.id} provider must be Claude`);
  assert.equal(model.model, expectedModel.model, `MC714-01: ${expectedModel.id} canonical model ID diverged`);
  assert.equal(model.modelSource, "official-doc", `MC714-01: ${expectedModel.id} must retain official-doc provenance`);
  assert.ok(model.evidenceIds.includes("official-doc"), `MC714-01: ${expectedModel.id} must retain official evidence`);
  assert.deepEqual(
    {
      promptTransport: model.promptTransport,
      authMode: model.authMode,
      requiredBackend: model.requiredBackend,
      readiness: model.readiness,
    },
    {
      promptTransport: "file",
      authMode: "claude-pro-max-oauth",
      requiredBackend: "agent-cli",
      readiness: {
        state: "selectable",
        assignable: true,
        availability: "Requires local Claude Code access.",
      },
    },
    `MC714-01: ${expectedModel.id} source boundary diverged`,
  );
  assert.equal(model.defaultEffortId, "high", `MC714-02: ${expectedModel.id} default effort must be high`);
  assert.deepEqual(
    getModelEffortIds(model, providerCapabilityRegistry),
    expectedClaude5Efforts,
    `MC714-02: ${expectedModel.id} supported efforts diverged`,
  );

  const runtimeEntry = runtimeCatalogEntries.find((entry) => entry.id === expectedModel.id);
  assert.ok(runtimeEntry, `MC714-01: Expected ${expectedModel.id} runtime catalog projection`);
  assert.equal(runtimeEntry.providerId, "claude", `MC714-01: ${expectedModel.id} runtime provider diverged`);
  assert.equal(runtimeEntry.model, expectedModel.model, `MC714-01: ${expectedModel.id} runtime model diverged`);
  assert.deepEqual(
    {
      agent: runtimeEntry.agent,
      providerId: runtimeEntry.providerId,
      promptTransport: runtimeEntry.promptTransport,
      authMode: runtimeEntry.authMode,
      requiredBackend: runtimeEntry.requiredBackend,
      status: runtimeEntry.status,
      availability: runtimeEntry.availability,
    },
    {
      agent: "claude",
      providerId: "claude",
      promptTransport: "file",
      authMode: "claude-pro-max-oauth",
      requiredBackend: "agent-cli",
      status: "selectable",
      availability: "Requires local Claude Code access.",
    },
    `MC714-01: ${expectedModel.id} runtime boundary diverged`,
  );
  assert.equal(runtimeEntry.reasoningEffort, "high", `MC714-02: ${expectedModel.id} runtime default effort diverged`);
  assert.deepEqual(
    runtimeEntry.supportedReasoningEfforts,
    expectedClaude5Efforts,
    `MC714-02: ${expectedModel.id} runtime supported efforts diverged`,
  );
}

const fable = modelCapabilities.find((entry) => entry.id === "claude-fable-5");
assert.ok(fable, "MC714-04: Expected Fable 5 model capability");
assert.ok(!fable.readiness.availability.includes("2026-07-07"), "MC714-04: Fable availability must not claim the expired credit window");
assert.ok(
  !/usage credits[^.]*2026-07-07/i.test(fable.readiness.availability),
  "MC714-04: Fable availability must not retain the expired usage-credit claim",
);
assert.ok(
  evidenceRecords.some((record) => record.id === "official-doc" && record.kind === "official-doc"),
  "MC714-01: official-doc evidence record must remain available",
);

const openRouterProvider = providerCapabilities.find((provider) => provider.id === "openrouter");
assert.ok(openRouterProvider, "MC714-05: Expected OpenRouter provider capability");
assert.deepEqual(
  openRouterProvider.dynamicModelLoading,
  {
    source: "provider-api",
    url: "https://openrouter.ai/api/v1/models",
    seedModelIds: ["openrouter-sakana-fugu-ultra", "openrouter-glm-5-2", "openrouter-kimi-k2-7-code"],
  },
  "MC714-05: OpenRouter dynamic API authority diverged",
);

for (const providerId of ["antigravity", "grok-build"]) {
  const provider = providerCapabilities.find((entry) => entry.id === providerId);
  assert.ok(provider, `MC714-05: Expected ${providerId} provider capability`);
  assert.deepEqual(provider.supportedModelSources, ["cli-discovery"], `MC714-05: ${providerId} must stay CLI-discovered`);
  assert.equal(provider.dynamicModelLoading, undefined, `MC714-05: ${providerId} must not add a provider API boundary`);
  for (const model of modelCapabilities.filter((entry) => entry.providerId === providerId)) {
    assert.equal(model.modelSource, "cli-discovery", `MC714-05: ${model.id} must stay on the local CLI boundary`);
  }
}
assert.ok(!providerCapabilities.some((provider) => provider.id === "xai"), "MC714-05: direct xAI provider must not be added");
assert.ok(
  !modelCapabilities.some((model) => ["antigravity-preview-05-2026", "grok-4.5", "grok-build-0.1"].includes(model.model)),
  "MC714-05: managed Antigravity or direct xAI models must not replace local CLI entries",
);

const benchmarkPackPath = path.resolve("..", "tasks", "cli-bakeoff", "v1", "benchmark-pack.json");
const benchmarkPackBytes = await readFile(benchmarkPackPath);
assert.equal(benchmarkPackBytes.byteLength, 34608, "MC714-06: benchmark pack byte length diverged");
assert.equal(
  createHash("sha256").update(benchmarkPackBytes).digest("hex"),
  "274fdc929fe5232880284c53fa068dbd5dffbddeae106bde375aab279831499d",
  "MC714-06: benchmark pack SHA-256 diverged",
);
const benchmarkPack = JSON.parse(benchmarkPackBytes.toString("utf8"));
assert.equal(benchmarkPack.tasks.length, 27, "MC714-06: benchmark task count diverged");
assert.equal(benchmarkPack.default_timeout_seconds, 3600, "MC714-06: benchmark timeout diverged");
assert.deepEqual(
  benchmarkPack.default_workers.map((worker) => ({
    pane: worker.pane,
    cli: worker.cli,
    provider: worker.agent ?? null,
    backend: worker.worker_backend ?? null,
    model: worker.model,
    modelSource: worker.model_source ?? null,
    effort: worker.effort ?? null,
  })),
  [
    { pane: "worker-1", cli: "Claude Code", provider: null, backend: null, model: "claude-opus-4-8", modelSource: null, effort: "xhigh" },
    { pane: "worker-2", cli: "Codex", provider: null, backend: null, model: "gpt-5.5", modelSource: null, effort: "xhigh" },
    { pane: "worker-3", cli: "Antigravity CLI", provider: "antigravity", backend: "antigravity", model: "Gemini 3.5 Flash (High)", modelSource: "operator-override", effort: null },
    { pane: "worker-4", cli: "Grok Build", provider: "grok-build", backend: "local", model: "grok-build", modelSource: "cli-discovery", effort: "provider-default" },
    { pane: "worker-5", cli: "OpenRouter API", provider: "openrouter", backend: "api_llm", model: "sakana/fugu-ultra", modelSource: null, effort: "provider-default" },
    { pane: "worker-6", cli: "OpenRouter API", provider: "openrouter", backend: "api_llm", model: "z-ai/glm-5.2", modelSource: null, effort: "provider-default" },
  ],
  "MC714-06: benchmark worker projection diverged",
);

assertReadinessVocabularyContract(commonContractPackage);

assertDivergenceIsDetected(
  "model readiness divergence fixture",
  modelReadinessStates.filter((state) => state !== "setup-required"),
  modelReadinessStates,
);
assertDivergenceIsDetected(
  "model source divergence fixture",
  modelSourceIds.filter((source) => source !== "provider-api"),
  modelSourceIds,
);
assertDivergenceIsDetected(
  "prompt transport divergence fixture",
  transportCapabilityIds.filter((transport) => transport !== "stdin"),
  transportCapabilityIds,
);
assertDivergenceIsDetected(
  "runtime worker repair-action fixture",
  runtimeWorkerReadinessStates.filter((state) => state !== "blocked"),
  runtimeWorkerReadinessStates,
);

const readinessVocabularyFixtures = await loadRustParityFixture("common-contract-readiness-vocabulary-fixtures.json");
assert.equal(readinessVocabularyFixtures.version, commonContractPackageVersion);
for (const fixture of readinessVocabularyFixtures.fixtures) {
  const mutated = applyReadinessVocabularyMutation(commonContractPackage, fixture.mutation);
  assert.throws(
    () => assertReadinessVocabularyContract(mutated),
    new RegExp(escapeRegExp(fixture.expectedError)),
    `${fixture.id} should fail with ${fixture.expectedError}`,
  );
}

assert.deepEqual(await loadRustParityFixture(), commonContractPackage);
assert.deepEqual(await loadRustParityFixture("common-contract-package-v0.36.28.json"), commonContractPackage);

const backendMigration = await loadRustParityFixture("common-contract-backend-migration-v0.36.28.json");
assert.deepEqual(backendMigration.from_versions, ["0.36.24", "0.36.25", "0.36.26", "0.36.27"]);
assert.equal(backendMigration.to_version, commonContractPackageVersion);
assert.equal(backendMigration.current_backend_count, backendCapabilityIds.length);
assert.equal(backendMigration.prior_backend_count, backendMigration.current_backend_count + backendMigration.removed_count);
assert.equal(backendMigration.removed_count, 1);
assert.equal(backendMigration.breaking, true);
assert.equal(backendMigration.source_commit, "59f7ade8");

console.log("common-contract-package-check: ok");
