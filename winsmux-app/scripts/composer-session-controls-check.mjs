import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const mainSource = await readFile("src/main.ts", "utf8");
const viewportHarness = await readFile("scripts/viewport-harness.mjs", "utf8");

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
  /value:\s*"fable-5"[\s\S]*?disabled:\s*true/,
  "Fable 5 must stay visible but disabled while it is unavailable.",
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
  viewportHarness,
  /Bypass permissions[\s\S]*?--permission-mode bypassPermissions/,
  "Viewport harness must verify that Settings can persist Bypass permissions into operator startup input.",
);

assert.match(
  viewportHarness,
  /model:\s*"fable-5"[\s\S]*?--model claude-opus-4-8/,
  "Viewport harness must verify that unavailable Fable 5 falls back to Opus 4.8.",
);

console.log("composer-session-controls-check: ok");
