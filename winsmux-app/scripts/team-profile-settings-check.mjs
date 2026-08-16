import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadModule(sourcePath, extraFiles = []) {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-team-profile-settings-"));
  const compilerOptions = {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2020,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
  };
  const files = [sourcePath, ...extraFiles];
  for (const file of files) {
    const source = await readFile(file, "utf8");
    const transpiled = ts.transpileModule(source, {
      compilerOptions,
      fileName: file,
    });
    const outName = path.basename(file).replace(/\.ts$/, ".mjs");
    const rewritten = transpiled.outputText.replaceAll('from "./modelCapabilities"', 'from "./modelCapabilities.mjs"');
    await writeFile(path.join(tempDir, outName), rewritten, "utf8");
  }
  try {
    return await import(pathToFileURL(path.join(tempDir, path.basename(sourcePath).replace(/\.ts$/, ".mjs"))).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

class FakeElement {
  constructor(tagName, ownerDocument) {
    this.tagName = tagName;
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.attributes = new Map();
    this.listeners = new Map();
    this.className = "";
    this.textContent = "";
    this.type = "";
  }

  set innerHTML(_value) {
    this.children = [];
    this.textContent = "";
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  click() {
    this.listeners.get("click")?.();
  }
}

class FakeDocument {
  createElement(tagName) {
    return new FakeElement(tagName, this);
  }
}

const sourcePath = path.resolve("src/teamProfileSettings.ts");
const capabilitiesPath = path.resolve("src/modelCapabilities.ts");
const source = await readFile(sourcePath, "utf8");
assert.equal(source.includes("READINESS_CANNOT_RUN"), false, "UI must not duplicate the catalog refuse table");
assert.equal(source.includes("blocked\", \"reference-only\""), false);

const {
  parseTeamProfileSettingsView,
  shouldRefuseTeamProfileStart,
  shouldRefuseTeamProfileApply,
  confirmTeamProfileReset,
  shouldExposeTeamProfileReset,
  keepOverridesAfterPresetApply,
  modelsForProvider,
  effortsForModel,
  formatTeamProfileRuntimeChips,
  renderTeamProfileSettingsPanel,
  TEAM_PROFILE_SLOT_IDS,
} = await loadModule(sourcePath, [capabilitiesPath]);

assert.deepEqual(TEAM_PROFILE_SLOT_IDS, ["worker-1", "worker-2", "worker-3", "worker-4", "worker-5", "worker-6"]);

const preset = {
  "worker-1": { provider: "codex", effort: "xhigh" },
  "worker-6": { provider: "codex", effort: "medium" },
};
const kept = keepOverridesAfterPresetApply(preset, { "worker-6": { effort: "low" } });
assert.equal(kept["worker-6"].effort, "low");
assert.equal(kept["worker-6"].provider, "codex");
assert.equal(kept["worker-1"].effort, "xhigh");

const officialView = parseTeamProfileSettingsView({
  schema_version: 1,
  action: "settings-view",
  opted_in: true,
  ok: true,
  apply_allowed: true,
  start_allowed: true,
  rows: TEAM_PROFILE_SLOT_IDS.map((slot_id) => ({
    slot_id,
    cannot_run: false,
    launch_blocked: false,
    fields: {
      provider: { value: "codex", source: "preset" },
      model: { value: "codex-gpt-5-6-terra", source: "preset" },
      "reasoning-effort": { value: "high", source: slot_id === "worker-6" ? "override" : "preset" },
      "role-profile": { value: "builder", source: "preset" },
      lifecycle: { value: "task", source: "preset" },
    },
    runtime_display: {
      slot_id,
      provider: "codex",
      model: "codex-gpt-5-6-terra",
      reasoning_effort: "high",
      role_profile: "builder",
      lifecycle: "task",
      task_classes: ["implementation"],
      source: slot_id === "worker-6" ? "override" : "preset",
      validation: "ok",
      prompt_bundle_digest: "abc",
    },
    artifact: {
      output: `.winsmux/runs/${slot_id}/result.md`,
      completion_authority: "output-file-and-exit-code",
      pty_capture_is_auxiliary: true,
    },
  })),
  checkpoints: {
    task_785_artifact: {
      completion_authority: "output-file-and-exit-code",
      output_pattern: ".winsmux/runs/<slot-id>/result.md",
      pty_capture_is_auxiliary: true,
    },
    task_662: { status: "pending" },
  },
});

assert.equal(shouldRefuseTeamProfileStart(officialView), false);
assert.equal(shouldRefuseTeamProfileApply(officialView), false);
assert.equal(officialView.rows[5].fields["reasoning-effort"].source, "override");
assert.equal(officialView.checkpoints.task_785_artifact.pty_capture_is_auxiliary, true);

const blockedView = parseTeamProfileSettingsView({
  ...officialView,
  ok: false,
  start_allowed: false,
  apply_allowed: true,
  rows: officialView.rows.map((row, index) => index === 2 ? { ...row, cannot_run: true, launch_blocked: false } : row),
});
assert.equal(shouldRefuseTeamProfileStart(blockedView), true);
assert.equal(shouldRefuseTeamProfileApply(blockedView), false);

const invalidView = parseTeamProfileSettingsView({
  ...officialView,
  apply_allowed: false,
  start_allowed: false,
  ok: false,
});
assert.equal(shouldRefuseTeamProfileApply(invalidView), true);

assert.equal(confirmTeamProfileReset({ confirmed: false }), false);
assert.equal(confirmTeamProfileReset({}), false);
assert.equal(confirmTeamProfileReset({ confirmed: true }), true);
assert.equal(shouldExposeTeamProfileReset(officialView, "override"), true);
assert.equal(shouldExposeTeamProfileReset(officialView, "preset"), false);
assert.equal(shouldExposeTeamProfileReset({ ...officialView, opted_in: false }, "override"), false);
assert.equal(shouldExposeTeamProfileReset({ ...officialView, opted_in: false }, "legacy"), false);

const chips = formatTeamProfileRuntimeChips(officialView.rows[0].runtime_display);
assert.deepEqual(chips.map((chip) => chip.field), ["provider", "model", "effort", "role", "lifecycle", "task-classes", "source", "validation", "bundle"]);
assert.equal(chips.some((chip) => chip.field === "prompt_body"), false);
assert.equal(JSON.stringify(chips).includes("secret"), false);

const fakeDocument = new FakeDocument();
const root = fakeDocument.createElement("div");
root.ownerDocument = fakeDocument;
const resets = [];
assert.equal(renderTeamProfileSettingsPanel(root, officialView, {
  onResetField: (slotId, field) => resets.push(`${slotId}:${field}`),
}), true);
assert.equal(root.children.length >= 2, true);
const grid = root.children[1];
assert.equal(grid.children.length, 6, "settings UI must render six slot rows");
assert.equal(grid.children[5].children[3].getAttribute("data-source"), "override");
assert.equal(grid.children[0].children[1].getAttribute("data-source"), "preset");

function collectResetButtons(node, found = []) {
  for (const child of node.children ?? []) {
    if (String(child.className).includes("team-profile-reset")) {
      found.push(child);
    }
    collectResetButtons(child, found);
  }
  return found;
}

assert.equal(grid.children[0].children[1].children.length, 0, "preset fields must not expose Reset");
const resetButtons = collectResetButtons(grid);
assert.equal(resetButtons.length, 1, "only override fields expose Reset");
const resetButton = grid.children[5].children[3].children[0];
assert.equal(resetButton, resetButtons[0]);
resetButton.click();
assert.deepEqual(resets, []);
assert.equal(resetButton.getAttribute("aria-expanded"), "true");
resetButton.click();
assert.deepEqual(resets, ["worker-6:reasoning-effort"]);

const legacyView = parseTeamProfileSettingsView({
  ...officialView,
  opted_in: false,
  rows: officialView.rows.map((row) => ({
    ...row,
    fields: Object.fromEntries(
      Object.entries(row.fields).map(([field, value]) => [field, { ...value, source: "legacy" }]),
    ),
  })),
});
const legacyRoot = fakeDocument.createElement("div");
legacyRoot.ownerDocument = fakeDocument;
renderTeamProfileSettingsPanel(legacyRoot, legacyView, {
  onResetField: (slotId, field) => resets.push(`legacy:${slotId}:${field}`),
});
assert.equal(collectResetButtons(legacyRoot).length, 0, "legacy roster must not expose Reset");

const refusedRoot = fakeDocument.createElement("div");
refusedRoot.ownerDocument = fakeDocument;
renderTeamProfileSettingsPanel(refusedRoot, blockedView);
assert.equal(refusedRoot.children[1].className, "settings-field-warning");

assert.ok(modelsForProvider("codex").some((model) => model.id === "codex-gpt-5-6-sol"));
assert.ok(effortsForModel("codex-gpt-5-6-sol").includes("xhigh"));
assert.equal(modelsForProvider("codex").some((model) => model.id === "provider-default"), false);

assert.equal(renderTeamProfileSettingsPanel(null, officialView), false);

console.log("team-profile-settings-check passed");
