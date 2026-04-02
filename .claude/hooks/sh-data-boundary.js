#!/usr/bin/env node
// sh-data-boundary.js — Production data boundary guard + jurisdiction tracking
// Spec: DETAILED_DESIGN.md §3.4
// Hook event: PreToolUse
// Matcher: Bash|WebFetch
// Target response time: < 50ms
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  allow,
  deny,
  readSession,
  appendEvidence,
} = require("./lib/sh-utils");

// ---------------------------------------------------------------------------
// Config Paths
// ---------------------------------------------------------------------------

const SH_CONFIG_DIR = path.join(".shield-harness", "config");
const PRODUCTION_HOSTS_FILE = path.join(SH_CONFIG_DIR, "production-hosts.json");
const ALLOWED_JURISDICTIONS_FILE = path.join(
  SH_CONFIG_DIR,
  "allowed-jurisdictions.json",
);

// ---------------------------------------------------------------------------
// Default Production Host Patterns (used when config file has "patterns" key)
// ---------------------------------------------------------------------------

const DEFAULT_PROD_PATTERNS = [
  /\bprod-/i,
  /\bproduction\./i,
  /\.prod\./i,
  /\bprod\b.*\.(rds|database|db|sql)/i,
];

// ---------------------------------------------------------------------------
// Hostname Extraction from Bash Commands
// ---------------------------------------------------------------------------

// Commands that commonly connect to external hosts
const HOST_EXTRACTORS = [
  // curl/wget: extract URL or host argument
  {
    pattern: /\b(?:curl|wget)\s+(?:[^\s]*\s+)*(?:https?:\/\/)?([^\s/:]+)/i,
    group: 1,
  },
  // ssh: user@host or just host
  { pattern: /\bssh\s+(?:[^\s]*\s+)*(?:\w+@)?([^\s/:]+)/i, group: 1 },
  // psql: -h host
  { pattern: /\bpsql\b.*?\s+-h\s+([^\s]+)/i, group: 1 },
  // psql: host in connection string
  { pattern: /\bpsql\b.*?(?:host=|\/\/)([^\s/:;]+)/i, group: 1 },
  // mysql: -h host
  { pattern: /\bmysql\b.*?\s+-h\s+([^\s]+)/i, group: 1 },
  // mongosh/mongo: host in connection string
  {
    pattern: /\b(?:mongosh|mongo)\b.*?(?:mongodb(?:\+srv)?:\/\/)([^\s/:]+)/i,
    group: 1,
  },
  // redis-cli: -h host
  { pattern: /\bredis-cli\b.*?\s+-h\s+([^\s]+)/i, group: 1 },
];

/**
 * Extract hostnames from a Bash command string.
 * @param {string} command
 * @returns {string[]} Array of extracted hostnames (lowercase).
 */
function extractHostsFromCommand(command) {
  const hosts = [];
  for (const extractor of HOST_EXTRACTORS) {
    const match = command.match(extractor.pattern);
    if (match && match[extractor.group]) {
      hosts.push(match[extractor.group].toLowerCase());
    }
  }
  return hosts;
}

/**
 * Extract hostname from a URL string.
 * Applies URL decoding before parsing to defeat percent-encoding evasion.
 * @param {string} url
 * @returns {string|null} Lowercase hostname or null.
 */
function extractHostFromUrl(url) {
  // Decode percent-encoded characters before parsing (SSRF evasion defense)
  let decoded = url;
  try {
    decoded = decodeURIComponent(url);
  } catch {
    // Malformed percent encoding — proceed with original
  }

  try {
    const parsed = new URL(decoded);
    return parsed.hostname.toLowerCase();
  } catch {
    // Try extracting with regex as fallback
    const match = decoded.match(/^https?:\/\/([^/:]+)/i);
    return match ? match[1].toLowerCase() : null;
  }
}

// ---------------------------------------------------------------------------
// Config Loaders (fail-safe: missing config = skip check)
// ---------------------------------------------------------------------------

/**
 * Load production hosts config.
 * Returns null if file doesn't exist (= no restrictions configured).
 *
 * Expected format:
 * {
 *   "hosts": ["prod-db.example.com", "production.internal"],
 *   "patterns": ["prod-", "production\\."]
 * }
 *
 * @returns {{ hosts: string[], patterns: RegExp[] } | null}
 */
function loadProductionHosts() {
  if (!fs.existsSync(PRODUCTION_HOSTS_FILE)) return null;

  try {
    const config = JSON.parse(fs.readFileSync(PRODUCTION_HOSTS_FILE, "utf8"));
    const hosts = (config.hosts || []).map((h) => h.toLowerCase());
    const patterns = (config.patterns || []).map((p) => new RegExp(p, "i"));
    return { hosts, patterns };
  } catch {
    // Corrupted config — fail-close for security
    return { hosts: [], patterns: DEFAULT_PROD_PATTERNS };
  }
}

/**
 * Load allowed jurisdictions config.
 * Returns null if file doesn't exist (= no jurisdiction restrictions).
 *
 * Expected format:
 * {
 *   "allowed": ["JP", "US", "EU"],
 *   "tld_map": { ".jp": "JP", ".us": "US", ".eu": "EU", ".de": "EU", ... }
 * }
 *
 * @returns {{ allowed: Set<string>, tldMap: Object } | null}
 */
function loadAllowedJurisdictions() {
  if (!fs.existsSync(ALLOWED_JURISDICTIONS_FILE)) return null;

  try {
    const config = JSON.parse(
      fs.readFileSync(ALLOWED_JURISDICTIONS_FILE, "utf8"),
    );
    const allowed = new Set((config.allowed || []).map((j) => j.toUpperCase()));
    const tldMap = config.tld_map || {};
    return { allowed, tldMap };
  } catch {
    // Corrupted config — skip jurisdiction check (cannot determine safely)
    return null;
  }
}

// ---------------------------------------------------------------------------
// Production Host Check
// ---------------------------------------------------------------------------

/**
 * Check if a hostname matches production host patterns.
 * @param {string} hostname - Lowercase hostname to check.
 * @param {{ hosts: string[], patterns: RegExp[] }} config
 * @returns {boolean}
 */
function isProductionHost(hostname, config) {
  // Exact match
  if (config.hosts.includes(hostname)) return true;

  // Pattern match
  for (const pattern of config.patterns) {
    if (pattern.test(hostname)) return true;
  }

  return false;
}

// ---------------------------------------------------------------------------
// Internal Host Check (SSRF / private network defense)
// ---------------------------------------------------------------------------

// Cloud metadata service IPs and hostnames
const CLOUD_METADATA_HOSTS = new Set([
  "169.254.169.254", // AWS, Azure
  "metadata.google.internal", // GCP
  "100.100.100.200", // Alibaba Cloud
]);

// Localhost aliases
const LOCALHOST_ALIASES = new Set([
  "127.0.0.1",
  "localhost",
  "0.0.0.0",
  "[::1]",
  "::1",
]);

/**
 * Check if a hostname is an internal/private network address.
 * Detects: cloud metadata endpoints, localhost aliases, RFC 1918 private IPs.
 * @param {string} hostname - Lowercase hostname to check.
 * @returns {boolean}
 */
function isInternalHost(hostname) {
  if (!hostname) return false;

  const h = hostname.toLowerCase();

  // Cloud metadata endpoints
  if (CLOUD_METADATA_HOSTS.has(h)) return true;

  // Localhost aliases
  if (LOCALHOST_ALIASES.has(h)) return true;

  // RFC 1918 private IP ranges
  const ipMatch = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipMatch) {
    const [, a, b] = ipMatch.map(Number);

    // 10.0.0.0/8
    if (a === 10) return true;

    // 172.16.0.0/12 (172.16.x.x — 172.31.x.x)
    if (a === 172 && b >= 16 && b <= 31) return true;

    // 192.168.0.0/16
    if (a === 192 && b === 168) return true;

    // Link-local (169.254.x.x) — covers AWS metadata and other link-local
    if (a === 169 && b === 254) return true;
  }

  // Hostname ending with .internal (GCP convention)
  if (h.endsWith(".internal")) return true;

  return false;
}

// ---------------------------------------------------------------------------
// Jurisdiction Check
// ---------------------------------------------------------------------------

/**
 * Estimate jurisdiction from hostname TLD.
 * @param {string} hostname
 * @param {Object} tldMap - TLD to jurisdiction code mapping.
 * @returns {string|null} Jurisdiction code (e.g., "JP") or null if unknown.
 */
function estimateJurisdiction(hostname, tldMap) {
  // Extract TLD (last dot-segment)
  const parts = hostname.split(".");
  if (parts.length < 2) return null;

  const tld = "." + parts[parts.length - 1];

  // Check custom TLD map
  const upperTld = tld.toLowerCase();
  for (const [key, value] of Object.entries(tldMap)) {
    if (key.toLowerCase() === upperTld) return value.toUpperCase();
  }

  return null;
}

// ---------------------------------------------------------------------------
// Main (only runs when executed directly, not when required for testing)
// ---------------------------------------------------------------------------

if (require.main === module) {
  try {
    const input = readHookInput();
    const toolName = input.toolName;
    const toolInput = input.toolInput;

    // Check channel source for evidence metadata (§8.6.3)
    let isChannel = false;
    try {
      const session = readSession();
      isChannel = session.source === "channel";
    } catch {
      // Session read failure is non-blocking
    }

    // --- Step 1: Production DB host detection ---
    const prodConfig = loadProductionHosts();

    if (prodConfig) {
      let hostsToCheck = [];

      if (toolName === "Bash") {
        const command = (toolInput.command || "").trim();
        hostsToCheck = extractHostsFromCommand(command);
      } else if (toolName === "WebFetch") {
        const url = toolInput.url || "";
        const host = extractHostFromUrl(url);
        if (host) hostsToCheck = [host];
      }

      for (const host of hostsToCheck) {
        if (isProductionHost(host, prodConfig)) {
          appendEvidence({
            event: "data_boundary_deny",
            hook: "sh-data-boundary",
            tool: toolName,
            host: host,
            reason: "production_host_detected",
            is_channel: isChannel,
          });
          deny(`Production environment access is prohibited: ${host}`);
          return;
        }
      }
    }

    // --- Step 2: Jurisdiction check (WebFetch only) ---
    if (toolName === "WebFetch") {
      const jurisdictionConfig = loadAllowedJurisdictions();

      if (jurisdictionConfig) {
        const url = toolInput.url || "";
        const host = extractHostFromUrl(url);

        if (host) {
          const jurisdiction = estimateJurisdiction(
            host,
            jurisdictionConfig.tldMap,
          );

          if (jurisdiction && !jurisdictionConfig.allowed.has(jurisdiction)) {
            appendEvidence({
              event: "data_boundary_deny",
              hook: "sh-data-boundary",
              tool: toolName,
              host: host,
              jurisdiction: jurisdiction,
              reason: "unauthorized_jurisdiction",
              is_channel: isChannel,
            });
            deny(
              `Unauthorized jurisdiction detected: ${jurisdiction} (host: ${host}). ` +
                `Allowed: ${[...jurisdictionConfig.allowed].join(", ")}`,
            );
            return;
          }
        }
      }
    }

    // --- Step 3: All checks passed ---
    allow();
  } catch (err) {
    // fail-close: any uncaught error = deny
    process.stdout.write(
      JSON.stringify({
        reason: `Hook error (sh-data-boundary): ${err.message}`,
      }),
    );
    process.exit(2);
  }
} // end require.main === module

// ---------------------------------------------------------------------------
// Exports (for testing)
// ---------------------------------------------------------------------------

module.exports = {
  // Config paths (for test override)
  PRODUCTION_HOSTS_FILE,
  ALLOWED_JURISDICTIONS_FILE,
  // Functions
  extractHostsFromCommand,
  extractHostFromUrl,
  loadProductionHosts,
  loadAllowedJurisdictions,
  isProductionHost,
  isInternalHost,
  estimateJurisdiction,
};
