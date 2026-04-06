#!/usr/bin/env node
// sh-task-gate.js — Test gate before task completion
// Spec: DETAILED_DESIGN.md §5.8
// Event: TaskCompleted
// Execution order: before sh-pipeline.js
// Target response time: < 30000ms
"use strict";

const fs = require("fs");
const { execSync } = require("child_process");
const {
  readHookInput,
  allow,
  deny,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-task-gate";

/**
 * Check if Pester test files exist.
 * @returns {boolean}
 */
function hasPesterTests() {
  try {
    const files = fs.readdirSync("tests").filter((f) => f.endsWith(".Tests.ps1"));
    return files.length > 0;
  } catch {
    return false;
  }
}

/**
 * Run Pester tests and return the result.
 * @returns {{ passed: boolean, output: string, total: number, failed: number }}
 */
function runPesterTests() {
  try {
    const output = execSync(
      'pwsh -NoProfile -Command "$env:NO_COLOR=1; Invoke-Pester tests/ -Output Minimal -PassThru | Select-Object -Property TotalCount,FailedCount | ConvertTo-Json"',
      { encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"] },
    );
    try {
      const result = JSON.parse(output.trim());
      return {
        passed: (result.FailedCount || 0) === 0,
        output: `Pester: ${result.TotalCount} tests, ${result.FailedCount} failed`,
        total: result.TotalCount || 0,
        failed: result.FailedCount || 0,
      };
    } catch {
      return { passed: true, output: output.slice(-300), total: 0, failed: 0 };
    }
  } catch (err) {
    const output = (err.stdout || "") + (err.stderr || "");
    return { passed: false, output: output.slice(-300), total: 0, failed: -1 };
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const toolName = input.tool_name || input.toolName || "";
  const toolInput = input.tool_input || input.toolInput || {};
  const sessionId = input.session_id || input.sessionId || "";
  void toolName;
  void toolInput;

  // Step 2: Run Pester tests if available (TASK-039)
  if (hasPesterTests()) {
    const pester = runPesterTests();
    if (!pester.passed) {
      try {
        appendEvidence({
          hook: HOOK_NAME,
          event: "TaskCompleted",
          decision: "deny",
          reason: "pester_failed",
          output: pester.output,
          session_id: sessionId,
        });
      } catch {}
      deny(`[${HOOK_NAME}] Pester テスト失敗。${pester.output}`);
      return;
    }
    allow(`[${HOOK_NAME}] Pester 通過。`);
    return;
  }

  allow();
} catch (err) {
  // Test gate: if we can't run tests, don't block the task (fail-open)
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  hasPesterTests,
  runPesterTests,
};
