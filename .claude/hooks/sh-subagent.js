#!/usr/bin/env node
// sh-subagent.js — Subagent constraint injection
// Spec: DETAILED_DESIGN.md §5.6
// Event: SubagentStart
// Target response time: < 10ms
"use strict";

const {
  readHookInput,
  allow,
  deny,
  failClosed,
  readSession,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-subagent";
const SUBAGENT_BUDGET_RATIO = 0.25; // 25% cap per subagent

// ---------------------------------------------------------------------------
// Budget Calculation
// ---------------------------------------------------------------------------

/**
 * Calculate subagent token budget from session state.
 * @param {Object} session
 * @returns {number|null}
 */
function calculateSubagentBudget(session) {
  const budget = Number(
    session && session.token_budget && session.token_budget.session_limit,
  );
  if (!Number.isFinite(budget) || budget <= 0) {
    return null;
  }

  const used = Number((session.token_budget && session.token_budget.used) || 0);
  const remaining = Math.max(0, budget - used);
  return Math.floor(remaining * SUBAGENT_BUDGET_RATIO);
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
  const session = readSession();

  const subagentBudget = calculateSubagentBudget(session);
  const budgetText =
    subagentBudget === null
      ? "未設定（セッション予算の制約なし）"
      : `${subagentBudget.toLocaleString()} tokens（セッション残量の 25%）`;

  // Record evidence
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "SubagentStart",
      decision: "allow",
      subagent_budget: subagentBudget,
      session_id: sessionId,
    });
  } catch {
    // Non-blocking
  }

  // Inject constraints via additionalContext
  const constraints = [
    "【Shield Harness サブエージェント制約】",
    `- トークン予算: ${budgetText}`,
    "- ファイル書込: プロジェクトルート内のみ",
    "- ネットワーク: 禁止（WebFetch 不可）",
    "- 他のサブエージェント起動: 禁止",
  ].join("\n");

  allow(constraints);
} catch (err) {
  failClosed(`[${HOOK_NAME}] Hook error (fail-close): ${err.message}`);
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  SUBAGENT_BUDGET_RATIO,
  calculateSubagentBudget,
};
