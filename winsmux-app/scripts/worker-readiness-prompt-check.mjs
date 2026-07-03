import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadWorkerReadinessPromptModule() {
  const sourcePath = path.resolve("src/workerReadinessPrompt.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-worker-readiness-prompt-"));
  const modulePath = path.join(tempDir, "workerReadinessPrompt.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const { hasWorkerReadyPrompt } = await loadWorkerReadinessPromptModule();

// #1115: the exact idle banner captured from a real six-pane Harness Bench
// attempt where worker-2 (Codex/gpt-5.5) was stuck "checking readiness"
// forever. The pane is genuinely idle at its ghost-text prompt with no
// percent-context readout and no enter-send glyph -- only the ghost marker
// line and a footer status line ("gpt-5.5 xhigh fast"). This must resolve
// to ready.
const codexGpt55IdleBanner = [
  "Tip: Try the Codex App. Run codex app or visit https://chatgpt.com/codex?app-landing-page=true",
  "- You have 3 usage limit resets available. Run /usage to use one.",
  "› Explain this codebase",
  "gpt-5.5 xhigh fast",
].join("\n");
assert.equal(hasWorkerReadyPrompt(codexGpt55IdleBanner), true, "codex gpt-5.5 idle banner must classify as ready");

// The same footer status line must still be recognized as ready even when
// the ghost-prompt marker line above it did not survive intact (covers a
// buffer/DOM-normalization edge case, not just the marker-line path).
const codexGpt55IdleBannerWithoutGhostMarker = [
  "Tip: Try the Codex App. Run codex app or visit https://chatgpt.com/codex?app-landing-page=true",
  "- You have 3 usage limit resets available. Run /usage to use one.",
  "Explain this codebase",
  "gpt-5.5 xhigh fast",
].join("\n");
assert.equal(
  hasWorkerReadyPrompt(codexGpt55IdleBannerWithoutGhostMarker),
  true,
  "codex gpt-5.5 status line alone must classify as ready even without the ghost marker line",
);

// Existing generic ghost-marker behavior (Claude-style "> " prompt with
// user-entered text) must be unaffected by the new Codex-specific check.
const genericGhostMarkerBanner = [
  "Welcome to Claude Code!",
  "> write a function to reverse a string",
].join("\n");
assert.equal(hasWorkerReadyPrompt(genericGhostMarkerBanner), true, "generic ghost marker banner must remain ready");

// A pane still mid-launch (command echoed, no idle prompt yet) must remain
// not-ready.
const midLaunchBanner = [
  "> codex --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox",
  "Starting Codex...",
].join("\n");
assert.equal(hasWorkerReadyPrompt(midLaunchBanner), false, "mid-launch banner must not classify as ready");

// #1115 (P2 follow-up): the launch command echo and the "Starting Codex..."
// marker can still be present in the recent-lines window *alongside* an
// eventual idle-shaped footer line (e.g. capture happened to land right as
// the footer first rendered, before the echo/marker scrolled out of the
// tail window). The footer text alone must not be trusted while a
// pending-launch marker is still visible -- this must remain not-ready.
const midLaunchBannerWithTrailingIdleFooter = [
  "> codex --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox",
  "Starting Codex...",
  "gpt-5.5 xhigh fast",
].join("\n");
assert.equal(
  hasWorkerReadyPrompt(midLaunchBannerWithTrailingIdleFooter),
  false,
  "mid-launch banner with a trailing idle-shaped footer line must not classify as ready",
);

console.log("worker-readiness-prompt-check: ok");
