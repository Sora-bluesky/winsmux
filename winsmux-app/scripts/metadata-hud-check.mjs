import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadMetadataHudModule() {
  const sourcePath = path.resolve("src/metadataHud.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-metadata-hud-"));
  const modulePath = path.join(tempDir, "metadataHud.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const { hudChipsFromSources, truncateSha } = await loadMetadataHudModule();
const hudSource = await readFile(path.resolve("src/metadataHud.ts"), "utf8");

function chipIds(chips) {
  return chips.map((chip) => chip.id);
}

function chipById(chips, id) {
  return chips.find((chip) => chip.id === id) ?? null;
}

// H01: empty input → no chips
const h01 = hudChipsFromSources({});
assert.deepEqual(h01, []);
assert.deepEqual(hudChipsFromSources(), []);
assert.equal(truncateSha(""), null);
assert.equal(truncateSha("abc"), null);
assert.equal(truncateSha(undefined), null);

// H02: cost hosted + heartbeat running → those two chips only
const h02 = hudChipsFromSources({ cost: "hosted", heartbeat: "running" });
assert.deepEqual(chipIds(h02), ["cost", "heartbeat"]);
assert.equal(chipById(h02, "cost")?.value, "hosted");
assert.equal(chipById(h02, "heartbeat")?.value, "running");
assert.equal(chipById(h02, "cpu"), null);
assert.equal(chipById(h02, "memory"), null);

// H03: tokens_remaining "12k" → context chip
const h03 = hudChipsFromSources({ tokensRemaining: "12k" });
assert.deepEqual(chipIds(h03), ["context"]);
assert.equal(chipById(h03, "context")?.label, "context");
assert.equal(chipById(h03, "context")?.value, "12k");

// H04: branch + 40-char sha → branch chip + head 8 chars
const fullSha = "abcdef0123456789abcdef0123456789abcdef01";
assert.equal(fullSha.length, 40);
assert.equal(truncateSha(fullSha), "abcdef01");
const h04 = hudChipsFromSources({ branch: "cursor/task-667-metadata-hud", headSha: fullSha });
assert.deepEqual(chipIds(h04), ["branch", "head"]);
assert.equal(chipById(h04, "branch")?.value, "cursor/task-667-metadata-hud");
assert.equal(chipById(h04, "head")?.value, "abcdef01");
assert.equal(chipById(h04, "head")?.value.length, 8);
assert.equal(hudChipsFromSources({ headSha: "1234567" }).length, 0);
assert.equal(truncateSha("12345678"), "12345678");

// H05: preview url present → preview chip
const h05 = hudChipsFromSources({ previewUrl: "http://127.0.0.1:4173/" });
assert.deepEqual(chipIds(h05), ["preview"]);
assert.equal(chipById(h05, "preview")?.value, "http://127.0.0.1:4173/");
assert.deepEqual(hudChipsFromSources({ previewUrl: "   " }), []);

// H06: cpu/memory undefined → no cpu/memory chips (including no "0" / "n/a")
const h06 = hudChipsFromSources({
  cost: "local",
  cpuPercent: undefined,
  memoryMb: undefined,
});
assert.deepEqual(chipIds(h06), ["cost"]);
assert.equal(chipById(h06, "cpu"), null);
assert.equal(chipById(h06, "memory"), null);
assert.equal(h06.some((chip) => chip.value === "0" || chip.value.toLowerCase() === "n/a"), false);
assert.equal(hudChipsFromSources({ cpuPercent: Number.NaN, memoryMb: Number.POSITIVE_INFINITY }).length, 0);

// H07: cpu 0 / memory 0 passed explicitly → chips allowed (real zero is data)
const h07 = hudChipsFromSources({ cpuPercent: 0, memoryMb: 0 });
assert.deepEqual(chipIds(h07), ["cpu", "memory"]);
assert.equal(chipById(h07, "cpu")?.value, "0");
assert.equal(chipById(h07, "memory")?.value, "0");
assert.deepEqual(chipIds(hudChipsFromSources({})), []);

// H08: main.ts wires the panel, not the domain module; does not invent cpu/memory HUD defaults
const mainSource = await readFile(path.resolve("src/main.ts"), "utf8");
const panelSource = await readFile(path.resolve("src/metadataHudPanel.ts"), "utf8");
const htmlSource = await readFile(path.resolve("index.html"), "utf8");
const stylesSource = await readFile(path.resolve("src/styles.css"), "utf8");
const splitGateSource = await readFile(path.resolve("../scripts/test-v03626-desktop-split-gate.ps1"), "utf8");

assert.match(mainSource, /from "\.\/metadataHudPanel"/);
assert.doesNotMatch(mainSource, /from "\.\/metadataHud"/);
assert.doesNotMatch(mainSource, /function collectMetadataHudSources|function renderMetadataHud|function metadataHudChipLabel/);
assert.match(mainSource, /bindAndLoadMetadataHud/);
assert.match(mainSource, /renderMetadataHud/);
assert.doesNotMatch(mainSource, /cpuPercent:\s*0/);
assert.doesNotMatch(mainSource, /memoryMb:\s*0/);

assert.match(panelSource, /from "\.\/metadataHud"/);
assert.match(panelSource, /hudChipsFromSources/);
assert.match(panelSource, /getLanguageText\("Metadata", "メタデータ"\)/);
assert.match(panelSource, /openPreviewTarget/);

assert.match(htmlSource, /id="metadata-hud"/);
assert.match(stylesSource, /\.metadata-hud\b/);
assert.doesNotMatch(stylesSource, /#pane-worker-[2-6][^{]*\{[^}]*(?:display\s*:\s*none|visibility\s*:\s*hidden)/);
assert.doesNotMatch(splitGateSource, /metadata-hud-check/);

// H09: serializer/helper does not parse pane buffer strings
assert.doesNotMatch(
  hudSource,
  /appendPaneOutputBuffer|capture-pane|capturePtyPane|outputBuffer|pty_capture/,
);
assert.doesNotMatch(hudSource, /JSON\.parse\(\s*(?:pane|buffer|capture)/i);
assert.doesNotMatch(
  panelSource,
  /appendPaneOutputBuffer|capture-pane|capturePtyPane|outputBuffer|pty_capture/,
);
assert.doesNotMatch(panelSource, /JSON\.parse\(\s*(?:pane|buffer|capture)/i);

console.log("metadata-hud-check: ok");
