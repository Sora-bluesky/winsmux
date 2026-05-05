import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadSourceGraphModule() {
  const sourcePath = path.resolve("src/sourceGraph.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-source-graph-"));
  const modulePath = path.join(tempDir, "sourceGraph.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  getSourceGraphLaneKind,
  normalizeSourceGraphTokens,
} = await loadSourceGraphModule();

assert.deepEqual(normalizeSourceGraphTokens("* |"), ["*", " ", "|"]);
assert.deepEqual(normalizeSourceGraphTokens("| * |"), ["|", " ", "*", " ", "|"]);
assert.deepEqual(normalizeSourceGraphTokens("|\u00a0*"), ["|", "\u00a0", "*"]);
assert.deepEqual(normalizeSourceGraphTokens("* | | | |", 6), ["*", " ", "|", " ", "|", " "]);
assert.deepEqual(normalizeSourceGraphTokens("      *", 6), [" ", " ", " ", " ", " ", " "]);
assert.deepEqual(normalizeSourceGraphTokens("    "), ["*"]);

assert.equal(getSourceGraphLaneKind(" "), "empty");
assert.equal(getSourceGraphLaneKind("\u00a0"), "empty");
assert.equal(getSourceGraphLaneKind("*"), "node");
assert.equal(getSourceGraphLaneKind("|"), "vertical");

console.log("source-graph-check: ok");
