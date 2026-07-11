#!/usr/bin/env node
// sh-operator-playbook.js — Inject the external operator playbook at session start.
// Event: SessionStart
"use strict";

const fs = require("fs");
const path = require("path");
const { readHookInput, allow } = require("./lib/sh-utils");

const HOOK_NAME = "sh-operator-playbook";
const PLAYBOOK_PATH = path.join("docs", "operator-playbook.md");
const PLAYBOOK_LABEL = "docs/operator-playbook.md";
const SUMMARY_HEADING = "### One-paragraph summary for a new operator";

function extractPlaybookSummary(content) {
  const markerIndex = content.indexOf(SUMMARY_HEADING);
  if (markerIndex < 0) {
    throw new Error(`missing summary heading in ${PLAYBOOK_LABEL}`);
  }

  const summary = content
    .slice(markerIndex + SUMMARY_HEADING.length)
    .replace(/\s+/g, " ")
    .trim();
  if (!summary) {
    throw new Error(`empty operator summary in ${PLAYBOOK_LABEL}`);
  }

  return summary;
}

function buildOperatorPlaybookContext(repoRoot = process.cwd()) {
  const fullPath = path.join(repoRoot, PLAYBOOK_PATH);
  if (!fs.existsSync(fullPath)) {
    throw new Error(`${PLAYBOOK_LABEL} not found`);
  }

  const summary = extractPlaybookSummary(fs.readFileSync(fullPath, "utf8"));
  return [
    `[operator-playbook] Before decomposing or dispatching work, consult ${PLAYBOOK_LABEL}.`,
    `Summary: ${summary}`,
  ].join("\n");
}

function buildOperatorPlaybookBlockedContext(error) {
  const reason = error instanceof Error ? error.message : String(error);
  return [
    `[operator-playbook] BLOCKED: ${reason}.`,
    `Restore or repair ${PLAYBOOK_LABEL} before decomposing or dispatching work.`,
  ].join("\n");
}

function main() {
  try {
    readHookInput();
    allow(buildOperatorPlaybookContext());
  } catch (error) {
    // SessionStart cannot deny a tool call. Keep startup available for transient
    // recovery, but inject a distinct blocked state rather than success context.
    allow(buildOperatorPlaybookBlockedContext(error));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  HOOK_NAME,
  PLAYBOOK_LABEL,
  SUMMARY_HEADING,
  extractPlaybookSummary,
  buildOperatorPlaybookContext,
  buildOperatorPlaybookBlockedContext,
};
