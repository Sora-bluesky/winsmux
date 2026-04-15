#!/usr/bin/env node
// sh-circuit-breaker.js — Session end checklist (Stop hook)
// Displays a checklist on Stop, then allows the stop immediately.
// Ref: PROPOSAL-29 (TASK-104)
// Event: Stop
// Target response time: < 50ms
"use strict";

const {
  readHookInput,
  allow,
  readSession,
  writeSession,
  appendEvidence,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-circuit-breaker";

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const sessionId = input.session_id || input.sessionId || "";
  const session = readSession();

  // Reset session state
  session.stop_hook_active = false;
  session.retry_count = 0;
  session.last_stop_at = 0;
  writeSession(session);

  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "Stop",
      decision: "allow",
      reason: "Session end checklist displayed",
      session_id: sessionId,
    });
  } catch {
    // Evidence failure is non-blocking
  }

  // Stop hooks do not use hookSpecificOutput additionalContext. Keep this allow path silent.
  allow();
} catch (_err) {
  // Control hook — fail-open (allow stop on error)
  allow();
}
