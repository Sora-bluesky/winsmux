import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadProjectExplorerTreeModule() {
  const sourcePath = path.resolve("src/projectExplorerTree.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-project-explorer-tree-"));
  const modulePath = path.join(tempDir, "projectExplorerTree.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  buildProjectExplorerTree,
  compareProjectExplorerNodes,
  createProjectExplorerTreeNode,
  getProjectExplorerChildKey,
} = await loadProjectExplorerTreeModule();

assert.equal(getProjectExplorerChildKey("SRC"), "src");

const tree = buildProjectExplorerTree([
  { path: "src/main.ts", kind: "file" },
  { path: "src/components/App.ts", kind: "file", ignored: true },
  { path: "README.md", kind: "file" },
  { path: "src", kind: "directory", has_children: true },
  { path: "Src/ignored.log", kind: "file", ignored: true },
]);

const src = tree.get("src");
assert.equal(src.kind, "directory");
assert.equal(src.hasChildren, true);
assert.equal(src.path, "src");
assert.equal(src.children.get("main.ts").kind, "file");
assert.equal(src.children.get("components").kind, "directory");
assert.equal(src.children.get("components").children.get("app.ts").ignored, true);
assert.equal(src.children.get("ignored.log").ignored, true);

const sorted = [
  createProjectExplorerTreeNode("z-file.ts", "z-file.ts", "file"),
  createProjectExplorerTreeNode("App", "App", "directory"),
  createProjectExplorerTreeNode("readme.md", "readme.md", "file"),
].sort(compareProjectExplorerNodes);

assert.deepEqual(sorted.map((node) => node.label), ["App", "readme.md", "z-file.ts"]);

console.log("project-explorer-tree-check: ok");
