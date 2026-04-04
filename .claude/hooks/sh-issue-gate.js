#!/usr/bin/env node
// sh-issue-gate.js — Issue necessity judgment gate
// Event: PreToolUse (Bash)
// Triggers on: gh issue create
// Warns when a commit-level fix is filed as an Issue
"use strict";

const { readHookInput, allow, appendEvidence } = require("./lib/sh-utils");

const HOOK_NAME = "sh-issue-gate";

// Patterns that suggest the fix is too small for an Issue
const TRIVIAL_TITLE_PATTERNS = [
  /\btypo\b/i,
  /\bwhitespace\b/i,
  /\bindent/i,
  /\bformat/i,
  /\brename\b/i,
  /\bspelling\b/i,
  /\bminor\s+fix\b/i,
  /\bone.?line\b/i,
];

// Patterns that indicate Issue-worthy complexity
const COMPLEX_PATTERNS = [
  /\bdesign\b/i,
  /\barchitect/i,
  /\bmulti.?file\b/i,
  /\bbreaking\b/i,
  /\bregression\b/i,
  /\bsecurity\b/i,
  /\bperformance\b/i,
  /\brace\s+condition\b/i,
  /\bdata\s+loss\b/i,
  /\bcross.?cutting\b/i,
];

if (require.main === module) {
  try {
    const input = readHookInput();
    const command = (input.toolInput && input.toolInput.command) || "";

    // Only trigger on gh issue create
    if (!command.match(/\bgh\s+issue\s+create\b/)) {
      allow();
      return;
    }

    // Extract title from --title flag
    const titleMatch = command.match(/--title\s+["']([^"']+)["']/);
    const title = titleMatch ? titleMatch[1] : "";

    // Extract body from --body flag (may be truncated)
    const bodyMatch = command.match(/--body\s+["']([^"']{0,500})/);
    const body = bodyMatch ? bodyMatch[1] : "";

    const fullText = `${title} ${body}`;

    // Check for trivial patterns
    const trivialMatch = TRIVIAL_TITLE_PATTERNS.find((p) => p.test(title));

    // Check for complex patterns
    const complexMatch = COMPLEX_PATTERNS.find((p) => p.test(fullText));

    if (trivialMatch && !complexMatch) {
      // Warn but allow — this looks like a commit-level fix
      try {
        appendEvidence({
          hook: HOOK_NAME,
          event: "PreToolUse",
          tool: "Bash",
          decision: "allow_with_warning",
          reason: `Trivial pattern detected: ${trivialMatch}`,
          title: title.slice(0, 80),
          session_id: input.sessionId,
        });
      } catch {}

      allow(
        `[${HOOK_NAME}] この修正は Issue ではなく commit message (fix:) で十分な可能性があります。\n` +
          `判断基準: Issue = 設計判断・複数ファイル影響・再発リスク / commit = 1行修正・タイポ・明白なバグ\n` +
          `本当に Issue が必要なら続行してください。`,
      );
      return;
    }

    allow();
  } catch (_err) {
    // fail-open
    allow();
  }
}

module.exports = {
  TRIVIAL_TITLE_PATTERNS,
  COMPLEX_PATTERNS,
};
