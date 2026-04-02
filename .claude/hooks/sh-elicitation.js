#!/usr/bin/env node
// sh-elicitation.js — Elicitation phishing & scope guard
// Spec: DETAILED_DESIGN.md §5.5
// Event: Elicitation
// Target response time: < 20ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  deny,
  nfkcNormalize,
  appendEvidence,
  SH_DIR,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-elicitation";
const ALLOWED_MCP_FILE = path.join(
  SH_DIR,
  "config",
  "allowed-mcp-servers.json",
);

// ---------------------------------------------------------------------------
// Phishing Patterns
// ---------------------------------------------------------------------------

const PHISHING_PATTERNS = [
  { pattern: /[0oO][0oO]gle/i, label: "google typosquatting" },
  { pattern: /anthroplc|anthr0pic/i, label: "anthropic typosquatting" },
  { pattern: /g[il1]thub/i, label: "github typosquatting" },
  { pattern: /m[il1]crosoft/i, label: "microsoft typosquatting" },
  { pattern: /\.(tk|ml|ga|cf|gq)$/i, label: "free TLD (high abuse)" },
];

// Excessive OAuth scopes
const EXCESSIVE_SCOPES = ["admin", "write:all", "repo:delete", "user:email"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Extract URLs from text.
 * @param {string} text
 * @returns {string[]}
 */
function extractUrls(text) {
  const urlRegex = /https?:\/\/[^\s"'<>]+/gi;
  return text.match(urlRegex) || [];
}

/**
 * Extract domain from URL.
 * @param {string} url
 * @returns {string}
 */
function extractDomain(url) {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/**
 * Load allowed MCP servers list.
 * @returns {string[]}
 */
function loadAllowedServers() {
  try {
    if (!fs.existsSync(ALLOWED_MCP_FILE)) return [];
    const data = JSON.parse(fs.readFileSync(ALLOWED_MCP_FILE, "utf8"));
    return Array.isArray(data) ? data : data.servers || [];
  } catch {
    return [];
  }
}

/**
 * Check if a domain matches phishing patterns.
 * @param {string} domain
 * @returns {{ matched: boolean, label: string }|null}
 */
function checkPhishing(domain) {
  const normalized = nfkcNormalize(domain);
  for (const { pattern, label } of PHISHING_PATTERNS) {
    if (pattern.test(normalized)) {
      return { matched: true, label };
    }
  }
  return null;
}

/**
 * Check if requested scopes contain excessive permissions.
 * @param {string[]} scopes
 * @returns {string[]} excessive scopes found
 */
function checkExcessiveScopes(scopes) {
  if (!Array.isArray(scopes)) return [];
  return scopes.filter((s) =>
    EXCESSIVE_SCOPES.some((ex) => s.toLowerCase().includes(ex.toLowerCase())),
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const input = readHookInput();
  const requestStr = JSON.stringify(input.toolInput);

  // Step 1: Extract URLs
  const urls = extractUrls(requestStr);

  // Step 2: Check each URL for phishing
  for (const url of urls) {
    const domain = extractDomain(url);
    if (!domain) continue;

    const phishing = checkPhishing(domain);
    if (phishing) {
      try {
        appendEvidence({
          hook: HOOK_NAME,
          event: "Elicitation",
          decision: "deny",
          reason: "phishing_detected",
          domain,
          label: phishing.label,
          session_id: input.sessionId,
        });
      } catch {
        // Non-blocking
      }

      deny(
        `[${HOOK_NAME}] フィッシングドメイン検出: ${domain} (${phishing.label})`,
      );
      return;
    }
  }

  // Step 3: Check allowed MCP servers (if URLs present)
  const allowedServers = loadAllowedServers();
  if (urls.length > 0 && allowedServers.length > 0) {
    for (const url of urls) {
      const domain = extractDomain(url);
      if (!domain) continue;

      const isAllowed = allowedServers.some(
        (server) => domain === server || domain.endsWith("." + server),
      );

      if (!isAllowed) {
        try {
          appendEvidence({
            hook: HOOK_NAME,
            event: "Elicitation",
            decision: "deny",
            reason: "unauthorized_mcp",
            domain,
            session_id: input.sessionId,
          });
        } catch {
          // Non-blocking
        }

        deny(`[${HOOK_NAME}] 未許可の MCP サーバー: ${domain}`);
        return;
      }
    }
  }

  // Step 4: Check OAuth scopes
  const scopes = input.toolInput.scopes || input.toolInput.scope || [];
  const scopeList = Array.isArray(scopes)
    ? scopes
    : typeof scopes === "string"
      ? scopes.split(/[,\s]+/)
      : [];
  const excessive = checkExcessiveScopes(scopeList);

  if (excessive.length > 0) {
    try {
      appendEvidence({
        hook: HOOK_NAME,
        event: "Elicitation",
        decision: "allow",
        reason: "excessive_scope_warning",
        scopes: excessive,
        session_id: input.sessionId,
      });
    } catch {
      // Non-blocking
    }

    allow(
      `[${HOOK_NAME}] 警告: 過剰な OAuth スコープが要求されています: ${excessive.join(", ")}。本当に必要か確認してください。`,
    );
    return;
  }

  // Step 5: All clean — allow
  try {
    appendEvidence({
      hook: HOOK_NAME,
      event: "Elicitation",
      decision: "allow",
      url_count: urls.length,
      session_id: input.sessionId,
    });
  } catch {
    // Non-blocking
  }

  allow();
} catch (err) {
  // SECURITY hook — fail-close
  process.stdout.write(
    JSON.stringify({
      reason: `[${HOOK_NAME}] Hook error (fail-close): ${err.message}`,
    }),
  );
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  PHISHING_PATTERNS,
  EXCESSIVE_SCOPES,
  extractUrls,
  extractDomain,
  loadAllowedServers,
  checkPhishing,
  checkExcessiveScopes,
};
