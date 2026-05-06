import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadEditorTargetsModule() {
  const sourcePath = path.resolve("src/editorTargets.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-editor-targets-"));
  const modulePath = path.join(tempDir, "editorTargets.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  getEditorFileKey,
  getSourceChangeKey,
  pickEditorPathCandidate,
  pickSourceChangeKeyCandidate,
} = await loadEditorTargetsModule();

const duplicateCandidates = [
  { path: "winsmux-app/src/main.ts", worktree: "builder-2" },
  { path: "winsmux-app/src/main.ts", worktree: "builder-3" },
];

assert.equal(getEditorFileKey("winsmux-app/src/main.ts"), ".::winsmux-app/src/main.ts");
assert.equal(getEditorFileKey("winsmux-app/src/main.ts", "builder-2"), "builder-2::winsmux-app/src/main.ts");
assert.equal(getSourceChangeKey(duplicateCandidates[1]), "builder-3::winsmux-app/src/main.ts");

assert.deepEqual(
  pickEditorPathCandidate(duplicateCandidates, "winsmux-app/src/main.ts", "builder-3", ""),
  duplicateCandidates[1],
);

assert.deepEqual(
  pickEditorPathCandidate(duplicateCandidates, "winsmux-app/src/main.ts", "", "builder-2::winsmux-app/src/main.ts"),
  duplicateCandidates[0],
);

assert.equal(
  pickEditorPathCandidate(duplicateCandidates, "winsmux-app/src/main.ts", "", ""),
  null,
);

assert.deepEqual(
  pickEditorPathCandidate([{ path: "winsmux-app/src/desktopClient.ts", worktree: "" }], "winsmux-app/src/desktopClient.ts", "", ""),
  { path: "winsmux-app/src/desktopClient.ts", worktree: "" },
);

assert.deepEqual(
  pickSourceChangeKeyCandidate(
    [
      [{ path: "winsmux-app/src/main.ts", worktree: "builder-2" }],
      [
        { path: "winsmux-app/src/main.ts", worktree: "builder-2" },
        { path: "winsmux-app/src/main.ts", worktree: "builder-3" },
      ],
    ],
    "builder-3::winsmux-app/src/main.ts",
  ),
  { path: "winsmux-app/src/main.ts", worktree: "builder-3" },
);

assert.equal(
  pickSourceChangeKeyCandidate(
    [[{ path: "winsmux-app/src/main.ts", worktree: "builder-2" }]],
    "builder-9::winsmux-app/src/main.ts",
  ),
  null,
);

console.log("editor-targets-check: ok");
