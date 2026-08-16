import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadWorkerPaneInputModule() {
  const sourcePath = path.resolve("src/workerPaneInput.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-worker-pane-input-"));
  const modulePath = path.join(tempDir, "workerPaneInput.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  isDirectWorkerPaneInputEnabled,
  shouldForwardWorkerPaneInput,
} = await loadWorkerPaneInputModule();

assert.equal(isDirectWorkerPaneInputEnabled(undefined), false);
assert.equal(isDirectWorkerPaneInputEnabled(null), false);
assert.equal(isDirectWorkerPaneInputEnabled(false), false);
assert.equal(isDirectWorkerPaneInputEnabled("true"), false);
assert.equal(isDirectWorkerPaneInputEnabled(true), true);

assert.equal(shouldForwardWorkerPaneInput("user", undefined), false);
assert.equal(shouldForwardWorkerPaneInput("user", false), false);
assert.equal(shouldForwardWorkerPaneInput("user", true), true);
assert.equal(shouldForwardWorkerPaneInput("dispatch", undefined), true);
assert.equal(shouldForwardWorkerPaneInput("dispatch", false), true);
assert.equal(shouldForwardWorkerPaneInput("dispatch", true), true);

console.log("worker-pane-input-check: ok");
