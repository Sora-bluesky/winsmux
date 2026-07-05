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

const { hasWorkerReadyPrompt, hasWorkerReadyPromptInAnySource } = await loadWorkerReadinessPromptModule();

/**
 * Test-only helper: simulate a fixed-width terminal column wrap. This
 * mirrors how a real pty-capture source turns a very long, in-place
 * re-drawn command line (no newline between repaints once ANSI control
 * sequences are stripped) into many real physical terminal rows -- each
 * row is still "\n"-joined normally, but adjacent repaints glue directly
 * onto each other with no separating whitespace at the wrap seam.
 */
function wrapIntoFixedWidthLines(text, width) {
  const lines = [];
  for (let i = 0; i < text.length; i += width) {
    lines.push(text.slice(i, i + width));
  }
  return lines;
}

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

// #1115 (P3 follow-up): once enough ordinary lines have scrolled between a
// stale launch echo/"Starting Codex..." marker and the current footer, the
// pane must resolve to ready again. hasPendingWorkerLaunchMarker must only
// suppress readiness for a marker near the footer (a genuine fresh launch),
// not for a marker still technically present somewhere in the buffered
// scrollback history that inspectWorkerPaneReadiness feeds in ahead of the
// live capture (see entry.outputBuffer in main.ts). Simulate 7 ordinary
// dialogue lines (a normal assistant response) scrolling past between the
// stale echo/marker and the eventual idle footer.
const staleLaunchMarkerWithIdleFooterAfterScrollback = [
  "> codex --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox",
  "Starting Codex...",
  "I looked at the repository structure and found the entry point.",
  "The main module wires up the CLI argument parser first.",
  "Then it loads the configuration file from the working directory.",
  "After that it initializes the worker pool for parallel tasks.",
  "Finally it prints a short summary of what changed.",
  "Let me know if you would like me to explain any part in more detail.",
  "Is there anything else you would like me to look into?",
  "gpt-5.5 xhigh fast",
].join("\n");
assert.equal(
  hasWorkerReadyPrompt(staleLaunchMarkerWithIdleFooterAfterScrollback),
  true,
  "idle footer must classify as ready once a stale launch marker has scrolled out of the near-footer window",
);

// #1115 comment 4872058128 (root cause, Fixture A): a real six-pane Harness
// Bench capture of worker-2 (Codex/gpt-5.5) reproduced this exact shape.
// inspectWorkerPaneReadiness in main.ts joins three capture sources with
// "\n" -- entry.outputBuffer, the live getWorkerPaneVisibleText DOM
// snapshot, and the freshest capturePtyPane(...).output, in that order --
// and only the LAST 10 non-empty lines of the combined blob were inspected
// for readiness. capturePtyPane(...).output is always the last (most
// tail-dominant) source. Here the pane's own launch command is long
// (absolute -C/--add-dir paths), the terminal keeps re-drawing it in
// place, and once ANSI control sequences are stripped, six repaints glue
// directly onto each other with no separating whitespace at the seam
// (".../workdircodex -c model=gpt-5.5...") while still wrapping across
// many real terminal rows. That alone produces far more than 10 physical
// lines, so the naive trailing-10-line window over the full join is 100%
// redraw noise and never sees the idle banner
// (getWorkerPaneVisibleText correctly holds it in the *middle* source).
const codexWorker2VisibleIdleBanner = [
  "Tip: Try the Codex App. Run codex app or visit https://chatgpt.com/codex?app-landing-page=true",
  "- You have 3 usage limit resets available. Run /usage to use one.",
  "› Explain this codebase",
  "gpt-5.5 xhigh fast",
].join("\n");

const codexWorker2LaunchCommand =
  "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh --disable plugins "
  + "-c mcp_servers.playwright.enabled=false --sandbox danger-full-access "
  + "-C /workdir --add-dir /workdir";

// Six in-place repaints, glued with zero separating characters, then
// hard-wrapped into ~30-column terminal rows -- comfortably more than the
// 10-line trailing window inspected by hasWorkerReadyPrompt.
const codexWorker2PtyCaptureRedrawSource = wrapIntoFixedWidthLines(
  codexWorker2LaunchCommand.repeat(6),
  30,
).join("\n");

const codexWorker2JoinedText = [
  "", // entry.outputBuffer: empty scrollback at this point in the fixture
  codexWorker2VisibleIdleBanner,
  codexWorker2PtyCaptureRedrawSource,
].filter(Boolean).join("\n");

assert.equal(
  hasWorkerReadyPrompt(codexWorker2JoinedText),
  false,
  "naive tail-10-line window over the joined 3-source blob must reproduce the #1115 comment 4872058128 bug: the in-place redraw run in the pty-capture source dominates the window and hides the idle banner sitting in the visible source",
);
assert.equal(
  hasWorkerReadyPromptInAnySource([
    "",
    codexWorker2VisibleIdleBanner,
    codexWorker2PtyCaptureRedrawSource,
  ]),
  true,
  "per-source readiness must find the idle banner in the visible source even though the pty-capture source is dominated by an in-place redraw run",
);

// #1115 comment 4872058128 (Fixture B, regression): none of the three
// sources shows any ready shape at all -- only launch-command noise -- so
// per-source evaluation must still resolve to not-ready. This guards
// against a change that makes hasWorkerReadyPromptInAnySource too
// permissive (e.g. matching on the mere presence of "codex" in any source).
const noReadyBannerVisibleSource = "> codex --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox";
const noReadyBannerPtyCaptureSource = wrapIntoFixedWidthLines(
  codexWorker2LaunchCommand.repeat(3),
  30,
).join("\n");
assert.equal(
  hasWorkerReadyPromptInAnySource([
    "",
    noReadyBannerVisibleSource,
    noReadyBannerPtyCaptureSource,
  ]),
  false,
  "per-source readiness must stay not-ready when no source shows an idle banner, even with launch-command redraw noise present",
);

// #1115 (P2 follow-up, Codex review): the Grok ghost-input-box signal needs
// two lines -- a "Grok Build" banner line and a "│ > │" / "│ ❯ │" input-box line --
// inside the same trailing-10-lines window (see hasGrokInputBox in
// hasWorkerReadyPrompt). If the two lines land in *different* capture
// sources (e.g. the banner in getWorkerPaneVisibleText, the input box in
// the freshest capturePtyPane output), neither source alone contains both
// lines, so per-source evaluation alone would (incorrectly) report
// not-ready. hasWorkerReadyPromptInAnySource must also check the sources
// joined together so this cross-source case still resolves to ready.
const grokBannerOnlySource = [
  "Grok Build v1.4.2",
  "Ready.",
].join("\n");
const grokInputBoxOnlySource = [
  "│ > │",
].join("\n");
assert.equal(
  hasWorkerReadyPrompt(grokBannerOnlySource),
  false,
  "Grok banner line alone (no input-box line) must not classify as ready",
);
assert.equal(
  hasWorkerReadyPrompt(grokInputBoxOnlySource),
  false,
  "Grok input-box line alone (no banner line) must not classify as ready",
);
assert.equal(
  hasWorkerReadyPromptInAnySource([grokBannerOnlySource, grokInputBoxOnlySource]),
  true,
  "Grok ready signal split across two sources must still resolve to ready via the joined-sources fallback",
);

// #1130: Grok Build 0.2.82 (Composer 2.5 UI) renders the idle composer
// prompt character as "❯" (U+276F) instead of the ">" older builds used.
// The input-box regex must accept both glyphs, or a genuinely idle Grok
// pane is reported not-ready forever. Fixture shape taken from the real
// v0.36.23 bench bring-up capture in issue #1130.
const grokChevronIdleBanner = [
  "◆ session_start  [hooks: 1]",
  "╭──────────────────────────────────────────╮",
  "│ ❯                                        │",
  "╰──────────── Grok Build · always-approve ─╯",
  "Shift+Tab:mode  │  Ctrl+x:shortcuts",
].join("\n");
assert.equal(
  hasWorkerReadyPrompt(grokChevronIdleBanner),
  true,
  "Grok Build ❯ composer row plus banner line must classify as ready (#1130)",
);

const grokChevronInputBoxOnlySource = "│ ❯                                        │";
assert.equal(
  hasWorkerReadyPrompt(grokChevronInputBoxOnlySource),
  false,
  "Grok ❯ input-box line alone (no banner line) must not classify as ready",
);

console.log("worker-readiness-prompt-check: ok");
