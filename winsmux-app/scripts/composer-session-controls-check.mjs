import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const mainSource = await readFile("src/main.ts", "utf8");
const viewportHarness = await readFile("scripts/viewport-harness.mjs", "utf8");

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
  /model:\s*"fable-5"[\s\S]*?--model claude-opus-4-8/,
  "Viewport harness must verify that unavailable Fable 5 falls back to Opus 4.8.",
);

console.log("composer-session-controls-check: ok");
