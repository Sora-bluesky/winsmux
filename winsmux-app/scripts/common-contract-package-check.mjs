import assert from "node:assert/strict";
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
  createOpenRouterApiModelCapability,
  evidenceRecords,
  effortCapabilityIds,
  getRuntimeCatalogEntries,
  modelCapabilities,
  modelReadinessStates,
  modelSourceIds,
  providerCapabilityIds,
  providerCapabilities,
  runtimeWorkerReadinessStates,
  toRuntimeCatalogEntry,
  transportCapabilityIds,
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
assert.match(mainSource, /const runtimeModelCatalog: RuntimeModelCatalogEntry\[\] = getRuntimeCatalogEntries\(\)\.map\(\(entry\) => \(\{/, "MC823-01: main.ts must consume getRuntimeCatalogEntries into runtimeModelCatalog");

const claude5Models = [
  {
    id: "claude-fable-5",
    evidenceId: "anthropic-claude-fable-5-2026-08-01",
    sourceLabel: "Anthropic — Redeploying Claude Fable 5",
    availability: "Requires local Claude Code access and usage credits after 2026-07-07.",
  },
  {
    id: "claude-opus-5",
    evidenceId: "anthropic-claude-opus-5-2026-08-01",
    sourceLabel: "Claude Platform — Claude Opus 5 model and effort",
    availability: "Requires local Claude Code access.",
  },
  {
    id: "claude-sonnet-5",
    evidenceId: "anthropic-claude-sonnet-5-2026-08-01",
    sourceLabel: "Claude Platform — Claude Sonnet 5 model and effort",
    availability: "Requires local Claude Code access.",
  },
];
const expectedClaude5Efforts = ["low", "medium", "high", "max", "xhigh"];
const runtimeCatalogEntries = getRuntimeCatalogEntries();
const expectedClaude5ModelIds = claude5Models.map((entry) => entry.id).sort();
const actualClaude5ModelIds = modelCapabilities
  .filter((entry) => entry.providerId === "claude" && /^claude-[^-]+-5(?:-|$)/.test(entry.id))
  .map((entry) => entry.id)
  .sort();
assert.deepEqual(actualClaude5ModelIds, expectedClaude5ModelIds, "MC823-01: exact Claude major-5 canonical model ID set");

for (const expected of claude5Models) {
  assert.ok(modelCapabilities.find((entry) => entry.id === expected.id), `MC823-01: expected ${expected.id} model capability`);
}

for (const expected of claude5Models) {
  const model = modelCapabilities.find((entry) => entry.id === expected.id);
  assert.ok(model, `MC823-01: expected ${expected.id} model capability`);
  assert.equal(model.providerId, "claude", `MC823-01: ${expected.id} source providerId`);
  assert.equal(model.model, expected.id, `MC823-01: ${expected.id} source model`);
  assert.equal(model.modelSource, "official-doc", `MC823-01: ${expected.id} source modelSource`);
  assert.equal(model.promptTransport, "file", `MC823-01: ${expected.id} source promptTransport`);
  assert.equal(model.authMode, "claude-pro-max-oauth", `MC823-01: ${expected.id} source authMode`);
  assert.equal(model.requiredBackend, "agent-cli", `MC823-01: ${expected.id} source requiredBackend`);
  assert.equal(model.readiness.state, "selectable", `MC823-01: ${expected.id} source readiness state`);
  assert.equal(model.readiness.assignable, true, `MC823-01: ${expected.id} source assignable`);
  assert.equal(model.readiness.availability, expected.availability, `MC823-01: ${expected.id} source availability`);
  assert.deepEqual(model.evidenceIds, [expected.evidenceId], `MC823-01: ${expected.id} source evidenceIds`);

  const evidence = evidenceRecords.find((entry) => entry.id === expected.evidenceId);
  assert.ok(evidence, `MC823-01: expected ${expected.id} evidence record`);
  assert.equal(evidence.kind, "official-doc", `MC823-01: ${expected.id} evidence kind`);
  assert.equal(evidence.sourceLabel, expected.sourceLabel, `MC823-01: ${expected.id} evidence sourceLabel`);
  assert.equal(evidence.captureDate, "2026-08-01", `MC823-01: ${expected.id} evidence captureDate`);

  const runtime = runtimeCatalogEntries.find((entry) => entry.id === expected.id);
  assert.ok(runtime, `MC823-01: expected ${expected.id} runtime catalog entry`);
  assert.equal(runtime.agent, "claude", `MC823-01: ${expected.id} runtime agent`);
  assert.equal(runtime.providerId, "claude", `MC823-01: ${expected.id} runtime providerId`);
  assert.equal(runtime.model, expected.id, `MC823-01: ${expected.id} runtime model`);
  assert.equal(runtime.modelSource, "official-doc", `MC823-01: ${expected.id} runtime modelSource`);
  assert.equal(runtime.promptTransport, "file", `MC823-01: ${expected.id} runtime promptTransport`);
  assert.equal(runtime.authMode, "claude-pro-max-oauth", `MC823-01: ${expected.id} runtime authMode`);
  assert.equal(runtime.requiredBackend, "agent-cli", `MC823-01: ${expected.id} runtime requiredBackend`);
  assert.equal(runtime.status, "selectable", `MC823-01: ${expected.id} runtime status`);
  assert.equal(runtime.availability, expected.availability, `MC823-01: ${expected.id} runtime availability`);
  assert.equal(runtime.evidence, "official-doc", `MC823-01: ${expected.id} runtime evidence kind`);
  assert.equal(runtime.sourceLabel, expected.sourceLabel, `MC823-01: ${expected.id} runtime sourceLabel`);
  assert.equal(runtime.captureDate, "2026-08-01", `MC823-01: ${expected.id} runtime captureDate`);

  assert.equal(model.defaultEffortId, "high", `MC823-02: ${expected.id} source default effort`);
  assert.deepEqual(model.supportedEffortIds, expectedClaude5Efforts, `MC823-02: ${expected.id} source supported efforts`);
  assert.equal(runtime.reasoningEffort, "high", `MC823-02: ${expected.id} runtime default effort`);
  assert.deepEqual(runtime.supportedReasoningEfforts, expectedClaude5Efforts, `MC823-02: ${expected.id} runtime supported efforts`);
}

const fableSource = modelCapabilities.find((entry) => entry.id === "claude-fable-5");
const fableRuntime = runtimeCatalogEntries.find((entry) => entry.id === "claude-fable-5");
assert.ok(fableSource && fableRuntime, "MC823-03: expected Claude Fable 5 source and runtime entries");
assert.equal(fableSource.risk, "usage-credits", "MC823-03: Fable source risk");
assert.equal(fableRuntime.risk, "usage-credits", "MC823-03: Fable runtime risk");
assert.equal(fableSource.readiness.availability, claude5Models[0].availability, "MC823-03: Fable source availability");
assert.equal(fableRuntime.availability, claude5Models[0].availability, "MC823-03: Fable runtime availability");
assert.equal(fableSource.note, "Fable 5 requires usage credits after 2026-07-07. Verify credits before long runs.", "MC823-03: Fable source note");
assert.equal(fableRuntime.note, "Fable 5 requires usage credits after 2026-07-07. Verify credits before long runs.", "MC823-03: Fable runtime note");
assert.equal(fableSource.noteJa, "Fable 5は2026-07-07以降usage creditsが必要です。長時間実行前にcreditsを確認してください。", "MC823-03: Fable source Japanese note");
assert.equal(fableRuntime.noteJa, "Fable 5は2026-07-07以降usage creditsが必要です。長時間実行前にcreditsを確認してください。", "MC823-03: Fable runtime Japanese note");
assert.ok(!fableSource.readiness.availability.includes("included usage"), "MC823-03: Fable source availability must exclude expired included-window wording");
assert.ok(!fableRuntime.availability.includes("included usage"), "MC823-03: Fable runtime availability must exclude expired included-window wording");

const claudeProvider = providerCapabilities.find((provider) => provider.id === "claude");
assert.ok(claudeProvider, "MC823-04: expected Claude provider capability");
assert.equal(claudeProvider.defaultModelId, "claude-opus-4-8", "MC823-04: Claude default model must remain claude-opus-4-8");

const openRouterProvider = providerCapabilities.find((provider) => provider.id === "openrouter");
assert.ok(openRouterProvider, "MC823-05: expected OpenRouter provider capability");
assert.deepEqual(openRouterProvider.supportedModelSources, ["operator-override", "provider-api"], "MC823-05: OpenRouter source boundary");
assert.equal(openRouterProvider.authMode, "api-key-env", "MC823-05: OpenRouter auth boundary");
assert.equal(openRouterProvider.dynamicModelLoading?.source, "provider-api", "MC823-05: OpenRouter dynamic source");
assert.equal(openRouterProvider.requiredBackend, "api_llm", "MC823-05: OpenRouter backend");
const openRouterDynamicModel = createOpenRouterApiModelCapability("acme/example", "Acme Example");
assert.equal(openRouterDynamicModel.modelSource, "provider-api", "MC823-05: createOpenRouterApiModelCapability source");
assert.equal(openRouterDynamicModel.requiredBackend, "api_llm", "MC823-05: createOpenRouterApiModelCapability backend");
assert.equal(openRouterDynamicModel.authMode, "api-key-env", "MC823-05: createOpenRouterApiModelCapability auth");
assert.equal(toRuntimeCatalogEntry(openRouterDynamicModel).modelSource, "provider-api", "MC823-05: OpenRouter runtime source");
assert.equal(toRuntimeCatalogEntry(openRouterDynamicModel).requiredBackend, "api_llm", "MC823-05: OpenRouter runtime backend");
assert.equal(toRuntimeCatalogEntry(openRouterDynamicModel).authMode, "api-key-env", "MC823-05: OpenRouter runtime auth");
for (const [providerId, requiredBackend, authMode] of [
  ["antigravity", "antigravity", "antigravity-official-cli"],
  ["grok-build", "agent-cli", "grok-build-local"],
]) {
  const provider = providerCapabilities.find((entry) => entry.id === providerId);
  assert.ok(provider, `MC823-05: expected ${providerId} provider capability`);
  assert.deepEqual(provider.supportedModelSources, ["cli-discovery"], `MC823-05: ${providerId} source boundary`);
  assert.equal(provider.requiredBackend, requiredBackend, `MC823-05: ${providerId} backend boundary`);
  assert.equal(provider.authMode, authMode, `MC823-05: ${providerId} auth boundary`);

  const providerRuntimeEntries = runtimeCatalogEntries.filter((entry) => entry.providerId === providerId);
  assert.ok(providerRuntimeEntries.length > 0, `MC823-05: expected ${providerId} runtime catalog entries`);
  for (const runtime of providerRuntimeEntries) {
    assert.equal(runtime.modelSource, "cli-discovery", `MC823-05: ${runtime.id} runtime source boundary`);
    assert.equal(runtime.promptTransport, "file", `MC823-05: ${runtime.id} runtime transport boundary`);
    assert.equal(runtime.requiredBackend, requiredBackend, `MC823-05: ${runtime.id} runtime backend boundary`);
    assert.equal(runtime.authMode, authMode, `MC823-05: ${runtime.id} runtime auth boundary`);
  }
}

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
