import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const mainSource = await readFile("src/main.ts", "utf8");
const viewportHarness = await readFile("scripts/viewport-harness.mjs", "utf8");
const modelCapabilitiesSource = await readFile("src/modelCapabilities.ts", "utf8");

assert.match(
  mainSource,
  /type ComposerPermissionMode = "auto" \| "default" \| "acceptEdits" \| "plan" \| "bypassPermissions";/,
  "Composer permission modes must stay aligned with Claude Code CLI permission-mode values.",
);

assert.match(
  mainSource,
  /function defaultComposerSessionControls\(\): ComposerSessionControlState \{[\s\S]*?permissionMode:\s*"auto"/,
  "New operator sessions must default to Claude Code auto permission mode.",
);

assert.doesNotMatch(
  mainSource,
  /value === "auto"[\s\S]*?return "default"/,
  "Stored auto permission mode must not be normalized back to default.",
);

assert.match(
  mainSource,
  /value:\s*"opus-4\.7"[\s\S]*?cliModel:\s*"claude-opus-4-7"/,
  "Opus 4.7 must remain a selectable Claude Code model with its CLI model id.",
);

assert.match(
  mainSource,
  /value:\s*"fable-5"[\s\S]*?cliModel:\s*"claude-fable-5"/,
  "Fable 5 must remain selectable with the Claude Code CLI model id.",
);

assert.doesNotMatch(
  mainSource,
  /\{\s*value:\s*"fable-5"[^}\n]*disabled:\s*true/,
  "Fable 5 must not remain disabled after Anthropic restored official access.",
);

assert.match(
  mainSource,
  /const storedModelOption = composerModelOptions\.find\(\(item\) => item\.value === storedModel\);[\s\S]*?const model = storedModelOption && !storedModelOption\.disabled \? storedModelOption\.value : fallback\.model;/,
  "Stored composer models must be accepted when they are present and not disabled.",
);

assert.ok(
  mainSource.includes("function detectComposerModelFromOperatorText(text: string)")
    && mainSource.includes("runtimeModelCandidates")
    && mainSource.includes("statusLinePattern")
    && mainSource.includes("new RegExp(`\\\\bmodel\\\\s*:\\\\s*")
    && mainSource.includes("runtimeModelCandidates[runtimeModelCandidates.length - 1]?.value"),
  "Operator PTY output must be able to report the current runtime model, including Opus 4.7.",
);

assert.match(
  mainSource,
  /observedOperatorRuntimeModel[\s\S]*?Current operator runtime model[\s\S]*?Next startup setting/,
  "Composer model display must distinguish current operator runtime from the next startup setting.",
);

assert.match(
  mainSource,
  /function markOperatorPtyStoppedFromExternalEvent\(\)[\s\S]*?clearObservedOperatorRuntimeModel\(\);/,
  "Observed operator runtime model must be cleared when the operator PTY stops.",
);

assert.match(
  mainSource,
  /setOperatorRuntimeOutputForTest:[\s\S]*?updateObservedOperatorRuntimeModelFromOutput\(value\)/,
  "Viewport harness must expose a test hook for operator runtime model observations.",
);

assert.match(
  mainSource,
  /function appendOperatorPtyOutput\(data: string\)[\s\S]*?updateObservedOperatorRuntimeModelFromOutput\(body\)/,
  "Real operator PTY output must update the observed runtime model, not only the viewport test hook.",
);

assert.doesNotMatch(
  mainSource,
  /storedModel === "opus-4\.7"/,
  "Opus 4.7 must not be migrated back to the Opus 4.8 fallback.",
);

assert.match(
  viewportHarness,
  /model:\s*"opus-4\.7"[\s\S]*?--model claude-opus-4-7/,
  "Viewport harness must verify that stored Opus 4.7 reaches operator startup input.",
);

assert.match(
  viewportHarness,
  /permissionMode:\s*"auto"[\s\S]*?--permission-mode auto/,
  "Viewport harness must verify that auto permission mode reaches operator startup input.",
);

assert.match(
  viewportHarness,
  /permissionMode:\s*"default"[\s\S]*?--permission-mode default/,
  "Viewport harness must verify that confirm-permissions mode reaches operator startup input.",
);

assert.match(
  viewportHarness,
  /Plan mode[\s\S]*?--permission-mode plan/,
  "Viewport harness must verify that Plan mode reaches operator startup input.",
);

assert.match(
  mainSource,
  /function renderOperatorApprovalModePanel\(japanese: boolean\)[\s\S]*?composerPermissionModeOptions[\s\S]*?setComposerPermissionMode\(option\.value\)/,
  "Settings must expose the same operator approval mode options as the composer footer.",
);

assert.match(
  mainSource,
  /function createRuntimeEffortControl\([\s\S]*?runtime-effort-control-claude[\s\S]*?runtime-effort-range[\s\S]*?runtime-effort-step/,
  "Settings must expose a Claude-specific effort control instead of a plain select-only UI.",
);

assert.match(
  mainSource,
  /claude:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"max",\s*"xhigh"\]/,
  "Claude runtime effort order must keep Ultra/xhigh as the highest option.",
);

assert.match(
  mainSource,
  /function getRuntimeReasoningOrderForProvider\([\s\S]*?codex:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"max",\s*"xhigh"\]/,
  "Codex runtime effort order must keep Max immediately before xhigh.",
);

assert.match(
  mainSource,
  /function getRuntimeReasoningOptionsForProvider\([\s\S]*?codex:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"xhigh"\]/,
  "Codex provider fallback effort choices must exclude Max while retaining xhigh.",
);

for (const provider of ["antigravity", "grok-build", "openrouter"]) {
  assert.match(
    mainSource,
    new RegExp(`["']?${provider.replace("-", "\\-")}["']?:\\s*\\["provider-default"\\]`),
    `${provider} must stay provider-default only in desktop runtime effort filtering.`,
  );
}

assert.match(
  modelCapabilitiesSource,
  /id:\s*"claude"[\s\S]*?supportedEffortIds:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"max",\s*"xhigh"\]/,
  "Claude provider capabilities must retain Max and Ultra/xhigh.",
);

assert.match(
  modelCapabilitiesSource,
  /id:\s*"codex"[\s\S]*?supportedEffortIds:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"xhigh"\]/,
  "Codex provider capabilities must exclude Max while retaining xhigh.",
);

for (const modelId of ["codex-gpt-5-6-sol", "codex-gpt-5-6-terra", "codex-gpt-5-6-luna"]) {
  assert.match(
    modelCapabilitiesSource,
    new RegExp(`id:\\s*"${modelId}"[\\s\\S]*?supportedEffortIds:\\s*\\["low",\\s*"medium",\\s*"high",\\s*"max",\\s*"xhigh"\\]`),
    `${modelId} must retain the GPT-5.6-only Max effort capability.`,
  );
}

assert.match(
  mainSource,
  /function normalizeRuntimeRolePreference\([\s\S]*?getRuntimePreferenceSelectedEntry\(preference\)[\s\S]*?normalizeRuntimeReasoningForEntry\(provider, entry, reasoningEffort\)/,
  "Stored runtime preferences must clamp an unsupported effort before desktop launch.",
);

assert.match(
  mainSource,
  /function runtimeModelSelectionProjectsModel\(model: string, modelSource: string\)[\s\S]*?model[\s\S]*?provider-default[\s\S]*?modelSource[\s\S]*?provider-default/,
  "Runtime preference capability selection must treat provider-default model sources as unprojected.",
);

const projectionFunctionSource = mainSource.match(
  /function runtimeModelSelectionProjectsModel\(model: string, modelSource: string\) \{[\s\S]*?\n\}/,
)?.[0];
assert.ok(projectionFunctionSource, "The shared runtime model projection predicate must remain executable by this contract.");
const projectsRuntimeModel = Function(
  `${projectionFunctionSource.replaceAll(": string", "")}; return runtimeModelSelectionProjectsModel;`,
)();
assert.equal(
  projectsRuntimeModel("gpt-5.6-sol", "provider-default"),
  false,
  "A concrete provider-default-source model must preserve provider-level effort capabilities.",
);
assert.equal(
  projectsRuntimeModel("gpt-5.6-sol", "cli-discovery"),
  true,
  "An explicitly discovered GPT-5.6 model must retain its catalog-specific Max capability.",
);
assert.equal(
  projectsRuntimeModel("gpt-5.6-sol", "configured"),
  true,
  "An explicitly configured GPT-5.6 model must retain its catalog-specific Max capability.",
);

const currentModelEntryFunctionSource = mainSource.match(
  /function createRuntimeCurrentModelEntry\(provider: RuntimeProviderId, model: string, modelSource: string\) \{[\s\S]*?\n\}/,
)?.[0];
assert.ok(
  currentModelEntryFunctionSource,
  "Current concrete model values must have an executable source-preserving entry constructor.",
);
const createCurrentModelEntry = Function(
  "createRuntimeCustomModelEntry",
  "runtimeModelSourceOptions",
  `${currentModelEntryFunctionSource
    .replace(": RuntimeProviderId", "")
    .replaceAll(": string", "")}; return createRuntimeCurrentModelEntry;`,
)(
  (provider, model) => ({ agent: provider, model, modelSource: "operator-override" }),
  [
    { value: "provider-default" },
    { value: "cli-discovery" },
    { value: "provider-api" },
    { value: "official-doc" },
    { value: "operator-override" },
  ],
);
assert.equal(
  createCurrentModelEntry("codex", "gpt-5.6-sol", "provider-default").modelSource,
  "provider-default",
  "C13: applying an unchanged concrete pane model must preserve its provider-default source.",
);
assert.equal(
  createCurrentModelEntry("codex", "gpt-5.6-sol", "provider-default").modelSource,
  "provider-default",
  "C14: an unchanged concrete shared worker model must preserve its provider-default source.",
);
assert.equal(
  createCurrentModelEntry("codex", "gpt-new", "untrusted-source").modelSource,
  "operator-override",
  "An unvalidated source must not escape the normal operator-override custom-input path.",
);

assert.match(
  mainSource,
  /const directMatch = runtimeModelSelectionProjectsModel\(preference\.model, preference\.modelSource\)\s*\?\s*entries\.find/,
  "A GPT-5.6 catalog label must not retain Max when its model source is provider-default.",
);

assert.match(
  mainSource,
  /const renderModelOptions = \(requestedModel\?: string\)[\s\S]*?const projectsCurrentModel = runtimeModelSelectionProjectsModel\(getWorkerModel\(row\), getWorkerModelSource\(row\)\);[\s\S]*?let selectedEntry = projectsCurrentModel\s*\?[\s\S]*?if \(projectsCurrentModel && !selectedEntry && currentCatalogEntry/,
  "Per-pane rendering must gate catalog reclassification with the shared model-source projection predicate.",
);

assert.match(
  mainSource,
  /const customEntry = createRuntimeCurrentModelEntry\(preference\.provider, preference\.model, preference\.modelSource\);/,
  "C14: the shared current-model synthetic entry must inherit the validated stored source.",
);

assert.match(
  mainSource,
  /const representsCurrentModel = [\s\S]*?createRuntimeCurrentModelEntry\(provider, requestedModel, getWorkerModelSource\(row\)\)[\s\S]*?: createRuntimeCustomModelEntry\(provider, requestedModel\)/,
  "C13: only a per-pane synthetic entry representing the unchanged current model may inherit its source.",
);

assert.match(
  mainSource,
  /if \(runtimeRoleDraftState\s*&&\s*!runtimeRolePreferencesEqual\(runtimeRoleDraftState,\s*runtimeRolePreferences\)\) \{[\s\S]*?const nextRuntimeRolePreferences = cloneRuntimeRolePreferences\(runtimeRoleDraftState\);[\s\S]*?await applyRuntimeRolePreferencesToDesktop\(nextRuntimeRolePreferences\);[\s\S]*?runtimeRolePreferences = nextRuntimeRolePreferences;[\s\S]*?persistRuntimeRolePreferences\(\);/,
  "Runtime role preferences must be applied and finalized only when the draft actually changed.",
);

assert.doesNotMatch(
  mainSource,
  /if \(runtimeRoleDraftState\) \{\s*const nextRuntimeRolePreferences = cloneRuntimeRolePreferences\(runtimeRoleDraftState\);/,
  "An unchanged runtime role draft must not block unrelated settings saves with a desktop apply.",
);

assert.doesNotMatch(
  mainSource,
  /runtimeRolePreferences = cloneRuntimeRolePreferences\(runtimeRoleDraftState\);[\s\S]*?persistRuntimeRolePreferences\(\);[\s\S]*?await applyRuntimeRolePreferencesToDesktop/,
  "Runtime role preferences must not be persisted before desktop apply.",
);

for (const provider of ["antigravity", "grok-build", "openrouter"]) {
  assert.match(
    modelCapabilitiesSource,
    new RegExp(`id:\\s*"${provider}"[\\s\\S]*?supportedEffortIds:\\s*\\["provider-default"\\]`),
    `${provider} capabilities must not claim explicit effort overrides.`,
  );
}

assert.match(
  viewportHarness,
  /Bypass permissions[\s\S]*?--permission-mode bypassPermissions/,
  "Viewport harness must verify that Settings can persist Bypass permissions into operator startup input.",
);

assert.match(
  viewportHarness,
  /model:\s*"fable-5"[\s\S]*?--model claude-fable-5/,
  "Viewport harness must verify that selectable Fable 5 persists into the Claude Code startup model.",
);

console.log("composer-session-controls-check: ok");
