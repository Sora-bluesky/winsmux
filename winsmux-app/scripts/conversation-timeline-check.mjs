import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadConversationTimelineModule() {
  const sourcePath = path.resolve("src/conversationTimeline.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-conversation-timeline-"));
  const modulePath = path.join(tempDir, "conversationTimeline.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  buildDesktopSummaryConversation,
  getVisibleConversationItems,
  shouldShowTimelineDetails,
} = await loadConversationTimelineModule();

const snapshot = {
  generated_at: "2026-07-07T12:34:56.000Z",
  project_dir: "C:/workspace/winsmux",
  board: {
    summary: { pane_count: 6 },
    panes: [],
  },
  inbox: {
    summary: { item_count: 3 },
    items: [
      {
        pane_id: "worker-1",
        label: "Worker 1",
        kind: "review-request",
        message: "Review is waiting.",
        branch: "codex/task-a",
        review_state: "PENDING",
        task_state: "reviewing",
      },
      {
        pane_id: "worker-2",
        label: "",
        kind: "blocked",
        message: "Worker is blocked.",
        branch: "",
        review_state: "",
        task_state: "blocked",
      },
      {
        pane_id: "worker-3",
        label: "Hidden third",
        kind: "info",
        message: "This should be trimmed.",
        branch: "codex/task-c",
        review_state: "PASS",
        task_state: "done",
      },
    ],
  },
  digest: {
    summary: { item_count: 4 },
    items: [],
  },
  run_projections: [
    {
      run_id: "run-pass",
      pane_id: "worker-1",
      label: "Worker 1",
      task: "Passing run",
      branch: "codex/pass",
      next_action: "",
      changed_files: ["src/a.ts"],
      review_state: "PASS",
      verification_outcome: "PASS",
    },
    {
      run_id: "run-pending",
      pane_id: "worker-2",
      label: "Worker 2",
      task: "Pending review",
      branch: "",
      next_action: "review",
      changed_files: [],
      review_state: "PENDING",
      verification_outcome: "",
    },
    {
      run_id: "run-fail",
      pane_id: "worker-3",
      label: "",
      task: "",
      branch: "codex/fail",
      next_action: "fix",
      changed_files: ["src/fail.ts", "src/test.ts"],
      review_state: "FAILED",
      verification_outcome: "FAIL",
    },
    {
      run_id: "run-hidden",
      pane_id: "worker-4",
      label: "Hidden fourth",
      task: "Hidden run",
      branch: "codex/hidden",
      next_action: "ship",
      changed_files: [],
      review_state: "",
      verification_outcome: "",
    },
  ],
};

const items = buildDesktopSummaryConversation(snapshot, { formatTimestamp: () => "12:34" });

assert.equal(items.length, 6, "summary + top 2 inbox + top 3 digest items should be rendered");
assert.deepEqual(items[0].details, [
  { label: "panes", value: "6" },
  { label: "notifications", value: "3" },
  { label: "runs", value: "4" },
]);
assert.equal(items[0].timestamp, "12:34");

assert.equal(items[1].category, "attention");
assert.equal(items[1].actor, "Worker 1");
assert.equal(items[2].actor, "worker-2", "inbox actor should fall back to pane id");
assert.equal(items.some((item) => item.actor === "Hidden third"), false, "only top two inbox items are included");

const passRun = items.find((item) => item.runId === "run-pass");
assert.equal(passRun.category, "activity");
assert.equal(passRun.tone, "success");
assert.equal(passRun.body, "Next idle · 1 changed files · review PASS.");
assert.deepEqual(passRun.chips.map((chip) => chip.action), ["open-explain", "open-source-context"]);

const pendingRun = items.find((item) => item.runId === "run-pending");
assert.equal(pendingRun.category, "review");
assert.equal(pendingRun.tone, "warning");
assert.equal(pendingRun.statusLabel, "PENDING");

const failedRun = items.find((item) => item.runId === "run-fail");
assert.equal(failedRun.category, "review");
assert.equal(failedRun.actor, "worker-3", "digest actor should fall back to pane id");

assert.deepEqual(getVisibleConversationItems(items, "attention").map((item) => item.category), ["attention", "attention"]);
assert.deepEqual(getVisibleConversationItems(items, "review").map((item) => item.runId), ["run-pending", "run-fail"]);
assert.equal(getVisibleConversationItems(items, "activity").every((item) => item.category === "activity" || item.type === "operator"), true);
assert.equal(getVisibleConversationItems(items, "all").length, items.length);

assert.equal(shouldShowTimelineDetails(passRun, "comfortable", null), true);
assert.equal(shouldShowTimelineDetails(passRun, "focused", "run-pass"), true);
assert.equal(shouldShowTimelineDetails(passRun, "focused", "other-run"), false);
assert.equal(shouldShowTimelineDetails(pendingRun, "focused", "other-run"), true);

console.log("conversation-timeline-check: ok");
