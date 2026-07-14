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
  effortCapabilityIds,
  modelReadinessStates,
  modelSourceIds,
  providerCapabilityIds,
  runtimeWorkerReadinessStates,
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
