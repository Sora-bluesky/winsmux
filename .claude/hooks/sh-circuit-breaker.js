#!/usr/bin/env node
// sh-circuit-breaker.js — Retry loop before agent stops
// Spec: DETAILED_DESIGN.md §5.2
// Event: Stop
// Target response time: < 50ms
"use strict";

const {
  readHookInput,
  allow,
  deny,
  readSession,
  writeSession,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-circuit-breaker";
const MAX_RETRIES = 3;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const session = readSession();

  // Step 1: Check stop_hook_active flag (infinite loop prevention)
  if (session.stop_hook_active === true) {
    session.stop_hook_active = false;
    writeSession(session);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "Stop",
        decision: "allow",
        reason:
          "stop_hook_active flag was set — allowing to prevent infinite loop",
        retry_count: session.retry_count || 0,
        session_id: input.sessionId,
      });
    } catch {
      // Evidence failure is non-blocking
    }

    allow(
      "[sh-circuit-breaker] stop_hook_active detected — allowing stop to prevent loop.",
    );
    return;
  }

  // Step 2: Read and evaluate retry count
  const currentRetry = (session.retry_count || 0) + 1;

  if (currentRetry > MAX_RETRIES) {
    // Retry limit reached — allow the stop
    session.retry_count = 0;
    session.stop_hook_active = false;
    writeSession(session);

    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "Stop",
        decision: "allow",
        reason: `Retry limit reached (${MAX_RETRIES}/${MAX_RETRIES})`,
        retry_count: MAX_RETRIES,
        session_id: input.sessionId,
      });
    } catch {
      // Evidence failure is non-blocking
    }

    allow(
      `[sh-circuit-breaker] リトライ上限（${MAX_RETRIES}回）に到達しました。停止を許可します。`,
    );
    return;
  }

  // Step 3: Retry — deny the stop request
  session.retry_count = currentRetry;
  session.stop_hook_active = true;
  writeSession(session);

  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "Stop",
      decision: "deny",
      reason: `Retry ${currentRetry}/${MAX_RETRIES}`,
      retry_count: currentRetry,
      session_id: input.sessionId,
    });
  } catch {
    // Evidence failure is non-blocking
  }

  deny(
    `[sh-circuit-breaker] リトライ ${currentRetry}/${MAX_RETRIES}。まだ停止しないでください。別のアプローチを試してください。`,
  );
} catch (_err) {
  // Control hook — fail-open (allow stop on error)
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  MAX_RETRIES,
};
