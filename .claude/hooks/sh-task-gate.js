#!/usr/bin/env node
// sh-task-gate.js — Test gate before task completion
// Spec: DETAILED_DESIGN.md §5.8
// Event: TaskCompleted
// Execution order: before sh-pipeline.js
// Target response time: < 30000ms
"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const {
  readHookInput,
  allow,
  deny,
  failClosed,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-task-gate";
const EVIDENCE_PATH = path.join(
  "artifacts",
  "test-results",
  "summary.json",
);
const EVIDENCE_LABEL = "artifacts/test-results/summary.json";
const FRESHNESS_LIMIT_MS = 30000;
const TREE_ID_PATTERN = /^[0-9a-f]{40}$/;
const FAILURE_MODES = new Set([
  "unavailable",
  "harness-error",
  "harness-postflight-error",
]);
const REQUIRED_COUNT_KEYS = [
  "failed",
  "failedBlocks",
  "failedContainers",
  "total",
  "boundedLineFilterCount",
];

function denyGate(reason, detail) {
  deny(`[${HOOK_NAME}] ${reason}: ${detail}`);
}

function isNonNegativeInteger(value) {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

function readEvidence() {
  let stat;
  try {
    stat = fs.statSync(EVIDENCE_PATH);
  } catch {
    denyGate("C1 missing", `${EVIDENCE_LABEL} is missing or unreadable.`);
    return null;
  }

  if (!stat.isFile()) {
    denyGate("C1 missing", `${EVIDENCE_LABEL} is not a readable file.`);
    return null;
  }

  let raw;
  try {
    raw = fs.readFileSync(EVIDENCE_PATH, "utf8");
  } catch {
    denyGate("C1 missing", `${EVIDENCE_LABEL} is missing or unreadable.`);
    return null;
  }

  let summary;
  try {
    summary = JSON.parse(raw);
  } catch {
    denyGate("C2 malformed", `${EVIDENCE_LABEL} is not valid JSON.`);
    return null;
  }

  if (!summary || typeof summary !== "object" || Array.isArray(summary)) {
    denyGate("C2 malformed", `${EVIDENCE_LABEL} must contain a JSON object.`);
    return null;
  }

  return { summary, mtimeMs: stat.mtimeMs };
}

function validateSchema(summary) {
  if (
    Object.prototype.hasOwnProperty.call(summary, "mode") &&
    typeof summary.mode !== "string"
  ) {
    denyGate("C2 malformed", `${EVIDENCE_LABEL} has an invalid mode.`);
    return false;
  }

  if (FAILURE_MODES.has(summary.mode)) {
    denyGate("C4 failing", `${EVIDENCE_LABEL} reports mode ${summary.mode}.`);
    return false;
  }

  for (const key of REQUIRED_COUNT_KEYS) {
    if (!isNonNegativeInteger(summary[key])) {
      denyGate(
        "C2 malformed",
        `${EVIDENCE_LABEL} has an invalid or missing ${key}.`,
      );
      return false;
    }
  }

  if (
    typeof summary.candidateTreeId !== "string" ||
    !TREE_ID_PATTERN.test(summary.candidateTreeId)
  ) {
    denyGate(
      "C2 malformed",
      `${EVIDENCE_LABEL} has an invalid or missing candidateTreeId.`,
    );
    return false;
  }

  return true;
}

function validateFreshness(mtimeMs) {
  const now = Date.now();
  const ageMs = now - mtimeMs;
  if (
    !Number.isFinite(mtimeMs) ||
    mtimeMs > now ||
    ageMs >= FRESHNESS_LIMIT_MS
  ) {
    denyGate(
      "C3 stale",
      `${EVIDENCE_LABEL} is not fresh enough for TaskCompleted.`,
    );
    return false;
  }

  return true;
}

function validatePassingSummary(summary) {
  if (
    summary.failed !== 0 ||
    summary.failedBlocks !== 0 ||
    summary.failedContainers !== 0 ||
    summary.total < 1
  ) {
    denyGate("C4 failing", `${EVIDENCE_LABEL} does not report a passing suite.`);
    return false;
  }

  return true;
}

function readCurrentTreeId() {
  const treeId = execFileSync("git", ["write-tree"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();

  if (!TREE_ID_PATTERN.test(treeId)) {
    throw new Error("git write-tree returned an invalid tree ID");
  }

  return treeId;
}

function validateCurrentTree(summary) {
  if (summary.candidateTreeId !== readCurrentTreeId()) {
    denyGate(
      "C5 tree_mismatch",
      `${EVIDENCE_LABEL} does not match the current candidate tree.`,
    );
    return false;
  }

  return true;
}

function validateFullSuite(summary) {
  if (summary.boundedLineFilterCount !== 0) {
    denyGate(
      "C6 not_full",
      `${EVIDENCE_LABEL} reports a bounded test selection.`,
    );
    return false;
  }

  return true;
}

function main() {
  readHookInput();
  const evidence = readEvidence();
  if (!evidence) return;
  if (!validateSchema(evidence.summary)) return;
  if (!validateFreshness(evidence.mtimeMs)) return;
  if (!validatePassingSummary(evidence.summary)) return;
  if (!validateCurrentTree(evidence.summary)) return;
  if (!validateFullSuite(evidence.summary)) return;

  allow(`[${HOOK_NAME}] Existing full-suite evidence verified.`);
}

function failOnUnexpectedException() {
  const reason = `[${HOOK_NAME}] C7 exception: unexpected evidence verification failure.`;
  try {
    deny(reason);
  } catch {
    failClosed(reason);
  }
}

if (require.main === module) {
  try {
    main();
  } catch {
    failOnUnexpectedException();
  }
}

module.exports = { main };
