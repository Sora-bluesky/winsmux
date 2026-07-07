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

function parsePropertyStringUnion(source, propertyName) {
  const match = new RegExp(`\\b${propertyName}\\??:\\s*([^;]+);`).exec(source);
  assert.ok(match, `Expected to find property ${propertyName}`);
  return Array.from(match[1].matchAll(/"([^"]+)"/g), (item) => item[1]);
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

async function loadRustParityFixture() {
  const fixturePath = path.resolve("..", "tests", "fixtures", "rust-parity", "common-contract-package.json");
  return JSON.parse(await readFile(fixturePath, "utf8"));
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

assert.equal(commonContractPackageVersion, "0.36.25");
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
assertSameVocabulary("main.ts RuntimeProviderId", parseStringUnion(mainSource, "RuntimeProviderId"), providerCapabilityIds);
assertSameVocabulary("main.ts RuntimeModelSource", parseStringUnion(mainSource, "RuntimeModelSource"), modelSourceIds);
assertSameVocabulary("main.ts RuntimeReasoningEffort", parseStringUnion(mainSource, "RuntimeReasoningEffort"), effortCapabilityIds);
assertSameVocabulary("main.ts RuntimeModelCatalogStatus", parseStringUnion(mainSource, "RuntimeModelCatalogStatus"), modelReadinessStates);
assertSameVocabulary(
  "main.ts RuntimeModelWorkerReadinessState",
  parseStringUnion(mainSource, "RuntimeModelWorkerReadinessState"),
  runtimeWorkerReadinessStates,
);
assertSameVocabulary("main.ts RuntimeModelBenchmarkFamily", parseStringUnion(mainSource, "RuntimeModelBenchmarkFamily"), benchmarkFamilies);
assertSameVocabulary("main.ts promptTransport", parsePropertyStringUnion(mainSource, "promptTransport"), transportCapabilityIds);
assertSameVocabulary("main.ts requiredBackend", parsePropertyStringUnion(mainSource, "requiredBackend"), backendCapabilityIds);
assertSameVocabulary("main.ts WorkerPaneReadinessState", parseStringUnion(mainSource, "WorkerPaneReadinessState"), workerPaneReadinessStates);
assertSameVocabulary("main.ts AgentVaultProviderId", parseStringUnion(mainSource, "AgentVaultProviderId"), agentVaultCommandProviderIds);

for (const state of runtimeWorkerReadinessStates) {
  assert.ok(modelReadinessStates.includes(state), `Runtime worker readiness ${state} must remain a model-readiness subset`);
}
assert.notDeepEqual(modelReadinessStates, workerPaneReadinessStates);
assert.equal(modelReadinessStates.includes("ready"), false);
assert.equal(workerPaneReadinessStates.includes("selectable"), false);

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

assert.deepEqual(await loadRustParityFixture(), commonContractPackage);

console.log("common-contract-package-check: ok");
