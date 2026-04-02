#!/usr/bin/env node
// sh-session-end.js — Session cleanup & statistics
// Spec: DETAILED_DESIGN.md §5.8
// Event: SessionEnd
// Target response time: < 200ms
"use strict";

const fs = require("fs");
const {
  readHookInput,
  allow,
  readSession,
  writeSession,
  appendEvidence,
  EVIDENCE_FILE,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-session-end";

// ---------------------------------------------------------------------------
// Statistics computation
// ---------------------------------------------------------------------------

/**
 * Compute session statistics from evidence ledger.
 * @param {string} sessionId
 * @returns {{ toolCalls: number, denials: number, topTools: string[], duration: string }}
 */
function computeStats(sessionId) {
  const stats = { toolCalls: 0, denials: 0, topTools: [], duration: "unknown" };

  try {
    if (!fs.existsSync(EVIDENCE_FILE)) return stats;

    const lines = fs.readFileSync(EVIDENCE_FILE, "utf8").trim().split("\n");
    const toolCounts = {};
    let sessionStart = null;

    for (const line of lines) {
      if (!line) continue;
      try {
        const entry = JSON.parse(line);
        // Only count entries from this session
        if (entry.session_id && entry.session_id !== sessionId) continue;

        if (entry.event === "SessionStart") {
          sessionStart = entry.recorded_at;
        }
        if (entry.tool) {
          stats.toolCalls++;
          toolCounts[entry.tool] = (toolCounts[entry.tool] || 0) + 1;
        }
        if (entry.decision === "deny") {
          stats.denials++;
        }
      } catch {
        // Skip malformed lines
      }
    }

    // Top 3 tools
    stats.topTools = Object.entries(toolCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 3)
      .map(([tool, count]) => `${tool}(${count})`);

    // Duration
    if (sessionStart) {
      const startMs = new Date(sessionStart).getTime();
      const endMs = Date.now();
      const diffMin = Math.round((endMs - startMs) / 60000);
      if (diffMin < 60) {
        stats.duration = `${diffMin}m`;
      } else {
        const h = Math.floor(diffMin / 60);
        const m = diffMin % 60;
        stats.duration = `${h}h${m}m`;
      }
    }
  } catch {
    // Stats computation failure is non-critical
  }

  return stats;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const { sessionId } = input;

  // Compute session stats
  const stats = computeStats(sessionId);

  // Record close marker in evidence ledger
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "SessionEnd",
      decision: "allow",
      summary: {
        tool_calls: stats.toolCalls,
        denials: stats.denials,
        top_tools: stats.topTools,
        duration: stats.duration,
      },
      session_id: sessionId,
    });
  } catch {
    // Evidence failure is non-blocking
  }

  // Reset session.json
  const session = readSession();
  session.retry_count = 0;
  session.stop_hook_active = false;
  session.session_end = new Date().toISOString();
  writeSession(session);

  // Output summary
  const summary = [
    `[${HOOK_NAME}] Session closed.`,
    `  Tool calls: ${stats.toolCalls}, Denials: ${stats.denials}`,
    `  Top tools: ${stats.topTools.join(", ") || "none"}`,
    `  Duration: ${stats.duration}`,
  ].join("\n");

  allow(summary);
} catch (_err) {
  // Operational hook — fail-open
  allow();
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  computeStats,
};
