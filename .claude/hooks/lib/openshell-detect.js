#!/usr/bin/env node
// openshell-detect.js — NVIDIA OpenShell detection & version tracking
// Spec: DETAILED_DESIGN.md §5.1.2, ADR-037
// Purpose: Detect OpenShell availability at SessionStart, track version updates
"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { commandExists, SH_DIR } = require("./sh-utils");

const CACHE_DIR = path.join(SH_DIR, "state");
const CACHE_FILE = path.join(CACHE_DIR, "openshell-version-cache.json");
const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
const CMD_TIMEOUT = 3000; // 3 seconds
const FETCH_TIMEOUT = 5000; // 5 seconds
const RELEASES_URL =
  "https://api.github.com/repos/NVIDIA/OpenShell/releases/latest";

/**
 * Run a command synchronously with timeout. Returns stdout or null on failure.
 * @param {string} cmd
 * @param {number} [timeout]
 * @returns {string|null}
 */
function runCmd(cmd, timeout = CMD_TIMEOUT) {
  try {
    return execSync(cmd, {
      encoding: "utf8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

/**
 * Parse version string from openshell --version output.
 * Expected format: "openshell X.Y.Z" or just "X.Y.Z"
 * @param {string} output
 * @returns {string|null}
 */
function parseVersion(output) {
  if (!output) return null;
  const match = output.match(/(\d+\.\d+\.\d+)/);
  return match ? match[1] : null;
}

/**
 * Read version cache file.
 * @returns {{ latest_version: string, checked_at: string, current_version: string }|null}
 */
function readCache() {
  try {
    return JSON.parse(fs.readFileSync(CACHE_FILE, "utf8"));
  } catch {
    return null;
  }
}

/**
 * Write version cache file atomically.
 * @param {Object} data
 */
function writeCache(data) {
  if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });
  const tmp = `${CACHE_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, CACHE_FILE);
}

/**
 * Fetch latest OpenShell version from GitHub Releases API.
 * Uses curl if available, otherwise Node.js https as fallback.
 * Returns null on any failure (fail-safe).
 * @returns {string|null} version string (e.g., "0.0.14") or null
 */
function fetchLatestVersion() {
  // Try curl first (simpler, faster)
  if (commandExists("curl")) {
    const raw = runCmd(
      `curl -s -H "Accept: application/vnd.github.v3+json" -H "User-Agent: shield-harness" "${RELEASES_URL}"`,
      FETCH_TIMEOUT,
    );
    if (raw) {
      try {
        const data = JSON.parse(raw);
        return (data.tag_name || "").replace(/^v/, "") || null;
      } catch {
        // Parse error — fall through
      }
    }
  }

  // Fallback: Node.js https (via temp script to avoid shell quoting issues)
  const tmpScript = path.join(CACHE_DIR, "fetch-version.js");
  try {
    if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });
    fs.writeFileSync(
      tmpScript,
      'const https=require("https");' +
        'const o={hostname:"api.github.com",path:"/repos/NVIDIA/OpenShell/releases/latest",' +
        'headers:{"User-Agent":"shield-harness","Accept":"application/vnd.github.v3+json"}};' +
        'https.get(o,(r)=>{let d="";r.on("data",(c)=>d+=c);' +
        'r.on("end",()=>{try{process.stdout.write(JSON.parse(d).tag_name||"")}catch{}});})' +
        '.on("error",()=>{});',
    );
    const tag = runCmd(`node "${tmpScript}"`, FETCH_TIMEOUT);
    try {
      fs.unlinkSync(tmpScript);
    } catch {
      // cleanup failure is non-critical
    }
    return tag ? tag.replace(/^v/, "") || null : null;
  } catch {
    return null;
  }
}

/**
 * Check latest version with 24-hour cache.
 * @param {string} currentVersion
 * @returns {{ latest_version: string|null, update_available: boolean }}
 */
function checkLatestVersion(currentVersion) {
  const cache = readCache();
  const now = Date.now();

  // Use cache if within TTL
  if (cache && cache.checked_at) {
    const elapsed = now - new Date(cache.checked_at).getTime();
    if (elapsed < CACHE_TTL_MS && cache.latest_version) {
      return {
        latest_version: cache.latest_version,
        update_available: cache.latest_version !== currentVersion,
      };
    }
  }

  // Fetch from GitHub
  const latest = fetchLatestVersion();
  if (latest) {
    writeCache({
      latest_version: latest,
      checked_at: new Date(now).toISOString(),
      current_version: currentVersion,
    });
    return {
      latest_version: latest,
      update_available: latest !== currentVersion,
    };
  }

  // Network failure — use stale cache if available
  if (cache && cache.latest_version) {
    return {
      latest_version: cache.latest_version,
      update_available: cache.latest_version !== currentVersion,
    };
  }

  return { latest_version: null, update_available: false };
}

/**
 * Detect OpenShell availability, version, container status, and update info.
 * fail-safe: never throws, returns { available: false } on any error.
 * @returns {{
 *   available: boolean,
 *   version: string|null,
 *   docker_available: boolean,
 *   container_running: boolean,
 *   reason: string|null,
 *   latest_version: string|null,
 *   update_available: boolean,
 *   detected_at: string
 * }}
 */
function detectOpenShell() {
  const detected_at = new Date().toISOString();
  const base = {
    available: false,
    version: null,
    docker_available: false,
    container_running: false,
    reason: null,
    latest_version: null,
    update_available: false,
    detected_at,
  };

  try {
    // Step 1: Docker CLI
    if (!commandExists("docker")) {
      return { ...base, reason: "docker_not_found" };
    }
    base.docker_available = true;

    // Step 2: OpenShell CLI
    if (!commandExists("openshell")) {
      return { ...base, reason: "openshell_not_installed" };
    }

    // Step 3: Version
    const versionOutput = runCmd("openshell --version");
    const version = parseVersion(versionOutput);
    base.version = version;

    // Step 4: Container status (strict match to avoid "inactive"/"No active" false positives)
    const listOutput = runCmd("openshell sandbox list");
    const running =
      listOutput !== null &&
      /\brunning\b/i.test(listOutput) &&
      !/\b(not|no|in)active\b/i.test(listOutput);
    base.container_running = running;

    if (!running) {
      return { ...base, reason: "container_not_running" };
    }

    // Step 5: Version tracking (24h cache)
    const versionInfo = checkLatestVersion(version || "0.0.0");
    base.latest_version = versionInfo.latest_version;
    base.update_available = versionInfo.update_available;

    base.available = true;
    return base;
  } catch {
    // Catch-all: detection failure is not a security issue
    return { ...base, reason: "detection_error" };
  }
}

module.exports = { detectOpenShell, fetchLatestVersion, parseVersion };
