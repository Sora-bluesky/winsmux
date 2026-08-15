import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadModule(sourcePath) {
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-workflow-gate-"));
  const modulePath = path.join(tempDir, "workflowGate.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");
  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const sourcePath = path.resolve("src/workflowGate.ts");
const source = await readFile(sourcePath, "utf8");
assert.equal(source.includes("status === \"pass\" && status === \"blocked\""), false);

const {
  parseWorkflowGateView,
  isCombinedReleaseComplete,
  blockedIsNotPass,
  shouldTreatGateAsPass,
  desktopConsumesWorkflowGate,
} = await loadModule(sourcePath);

const view = parseWorkflowGateView({
  schema_version: 1,
  action: "workflow-gate",
  ok: true,
  in_repo_merge_ready: true,
  combined_release: { status: "blocked", reason: "windows gates skipped" },
  publication: { github_release: false, npm_publish: false, post_smoke: false, version_bump: false },
  gates: {
    dry_run: { status: "pass" },
    resume: { status: "blocked" },
    rollback_cleanup: { status: "pass" },
    team_profile_718: { status: "pass" },
  },
});

assert.equal(desktopConsumesWorkflowGate(view), true);
assert.equal(isCombinedReleaseComplete(view), false);
assert.equal(blockedIsNotPass(view.combined_release.status), true);
assert.equal(shouldTreatGateAsPass("blocked"), false);
assert.equal(shouldTreatGateAsPass(view.gates.resume.status), false);
assert.equal(view.publication.github_release, false);
assert.equal(view.publication.npm_publish, false);

console.log("workflow-gate-check passed");
