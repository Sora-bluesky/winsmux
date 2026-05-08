import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadComposerTextModule() {
  const sourcePath = path.resolve("src/composerText.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-composer-text-"));
  const modulePath = path.join(tempDir, "composerText.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const { isComposerCommandText, normalizeComposerPlainTextPaste } = await loadComposerTextModule();

assert.equal(isComposerCommandText("winsmux meta-plan --json"), true);
assert.equal(isComposerCommandText("  winsmux skills --json"), true);
assert.equal(isComposerCommandText("調査してください"), false);

assert.equal(
  normalizeComposerPlainTextPaste('winsmux meta-plan --task "計画して"\n--review-\nrounds 2 --json'),
  'winsmux meta-plan --task "計画して" --review-rounds 2 --json',
);

assert.equal(
  normalizeComposerPlainTextPaste("調査してください。\n編集は禁止です。"),
  "調査してください。\n編集は禁止です。",
);

assert.equal(
  normalizeComposerPlainTextPaste("winsmux skills --json"),
  "winsmux skills --json",
);

console.log("composer-text-check: ok");
