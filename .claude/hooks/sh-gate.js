#!/usr/bin/env node
// sh-gate.js — Destructive command blocker + hook evasion defense
// Spec: DETAILED_DESIGN.md §3.2
// Event: PreToolUse (Bash)
// Target response time: < 50ms
"use strict";

const {
  readHookInput,
  allow,
  deny,
  nfkcNormalize,
  normalizePath,
  appendEvidence,
  trackDeny,
} = require("./lib/sh-utils");

// ---------------------------------------------------------------------------
// Pattern Arrays (§3.2 — all 7 attack vectors + destructive commands)
// ---------------------------------------------------------------------------

// Destructive commands — catastrophic file system / device operations
const DESTRUCTIVE_PATTERNS = [
  [/^rm\s+-rf\s+\//, "rm -rf / (root filesystem destruction)"],
  [/^rm\s+-rf\s+~/, "rm -rf ~ (home directory destruction)"],
  [/^rm\s+-rf\s+\.\//, "rm -rf ./ (relative path destruction)"],
  [/^rm\s+-[a-z]*r[a-z]*\s+-[a-z]*f/, "rm flag separation (destructive)"],
  [/^rm\s+-[a-z]*f[a-z]*\s+-[a-z]*r/, "rm flag separation (destructive)"],
  [/^del\s+\/s\s+\/q\s+[A-Z]:\\/, "del /s /q (Windows recursive delete)"],
  [/^format\s+[A-Z]:/, "format drive (disk format)"],
  [/^mkfs\./, "mkfs (filesystem creation on device)"],
  [/^dd\s+if=.*\s+of=\/dev\//, "dd to device (raw disk write)"],
  [/\bfind\b.*\s-delete/, "find -delete (recursive file deletion)"],
  [/\bshred\b/, "shred (secure file destruction)"],
];

// E-1: Tool switching — bypass Edit/Write tool via Bash scripting languages
const TOOL_SWITCHING_PATTERNS = [
  [/sed\s+-i/, "sed -i (in-place edit bypasses Edit tool)"],
  [
    /sed\s.*['"][^'"]*[/][^'"]*[ew]\s*['"]/,
    "sed e/w modifier (execute/write via sed)",
  ],
  [/sed\s.*-e\s/, "sed -e (expression, potential execute)"],
  [/python3?\s+-c\s+['"].*open\(/, "python -c open() (file write via python)"],
  [/node\s+-e\s+['"].*fs\./, "node -e fs.* (file write via node)"],
  [
    /\bnode\s+-e\s+.*child_process/,
    "node -e child_process (arbitrary exec via node)",
  ],
  [/ruby\s+-e\s+['"].*File\./, "ruby -e File.* (file write via ruby)"],
  [/perl\s+-[pei]/, "perl -p/-e/-i (in-place or eval mode)"],
  [
    /powershell.*-Command.*Set-Content/i,
    "PowerShell Set-Content (file write via powershell)",
  ],
  [/echo\s+.*>\s/, "echo redirect (file write via echo)"],
  [/echo\s+.*>(?=\S)/, "echo redirect no-space (file write via echo)"],
  [/printf\s+.*>\s/, "printf redirect (file write via printf)"],
  [/\|\s*tee\s/, "pipe to tee (file write via tee)"],
  [/\blua\s+-e\b/, "lua -e (arbitrary code execution via lua)"],
  [/\bphp\s+-r\b/, "php -r (arbitrary code execution via php)"],
  [
    /\bawk\b.*\bsystem\s*\(/,
    "awk system() (arbitrary command execution via awk)",
  ],
  [/\bbash\s+-c\b/, "bash -c (arbitrary command execution via bash)"],
];

// E-3: Dynamic linker — execute arbitrary code via loader injection
const DYNAMIC_LINKER_PATTERNS = [
  [/LD_PRELOAD=/, "LD_PRELOAD (shared library injection)"],
  [/LD_LIBRARY_PATH=/, "LD_LIBRARY_PATH (library path hijack)"],
  [/DYLD_INSERT_LIBRARIES=/, "DYLD_INSERT_LIBRARIES (macOS library injection)"],
  [/ld-linux/, "ld-linux (direct dynamic linker invocation)"],
  [/\/lib.*\/ld-/, "/lib*/ld- (dynamic linker path)"],
  [/\/usr\/lib.*\/ld-/, "/usr/lib*/ld- (dynamic linker path)"],
  [/rundll32/i, "rundll32 (Windows DLL execution)"],
];

// E-4: sed dangerous modifiers (subset of tool switching, explicit check)
const SED_DANGER_PATTERNS = [
  [
    /sed\s.*['"][^'"]*[/][^'"]*[ew]\s*['"]/,
    "sed e/w modifier (arbitrary command execution)",
  ],
];

// E-5: Self-config modification — agent modifying its own governance files
const CONFIG_MODIFY_PATTERNS = [
  [/>\s*\.claude\//, "redirect to .claude/ (config overwrite)"],
  [/>>\s*\.claude\//, "append redirect to .claude/ (config modification)"],
  [/tee\s+.*\.claude\//, "tee to .claude/ (config write)"],
  [/cp\s+.*\.claude\//, "cp to .claude/ (config copy)"],
  [/mv\s+.*\.claude\//, "mv to .claude/ (config move)"],
];

// FR-02-06: PATH hijack — override command resolution
const PATH_HIJACK_PATTERNS = [
  [/^PATH=/, "PATH= (command search path override)"],
  [/export\s+PATH=/, "export PATH= (persistent path override)"],
  [/\$SHELL/, "$SHELL (shell variable reference)"],
  [/\$PATH/, "$PATH (path variable reference)"],
  [/env\s+-[SiuC]/, "env -S/-i/-u/-C (environment manipulation)"],
  [/env\s+--split-string/, "env --split-string (argument injection)"],
  [/NODE_OPTIONS\s*=/, "NODE_OPTIONS= (Node.js runtime manipulation)"],
];

// Git security bypass patterns
const GIT_BYPASS_PATTERNS = [
  [/\bgit\b.*--no-verify/, "git --no-verify (hook bypass)"],
  [
    /\bgit\s+config\s+core\.hooksPath/,
    "git config core.hooksPath (hook path hijack)",
  ],
  [/\bgit\s+config\s+alias\./, "git config alias (alias injection)"],
];

// Variable expansion / command substitution patterns
const VARIABLE_EXPANSION_PATTERNS = [
  [/\$\(/, "$() (command substitution)"],
  [/\$\{/, "${} (variable expansion)"],
];

// FR-02-09, FR-02-10: Windows-specific attack vectors
const WINDOWS_PATTERNS = [
  [/\.lnk\b/, ".lnk (Windows shortcut — potential code execution)"],
  [/\.scf\b/, ".scf (Shell Command File — potential code execution)"],
  [/\.url\b/, ".url (Internet shortcut — potential redirect)"],
  [/\.cmd\b/i, ".cmd (Windows batch — uncontrolled execution)"],
  [/\.bat\b/i, ".bat (Windows batch — uncontrolled execution)"],
  [/\bpowershell\b.*-enc/i, "powershell -enc (encoded command — obfuscation)"],
  [/::\$DATA/, "NTFS ADS (Alternate Data Stream)"],
  [/\\\\\?\\UNC\\/, "UNC extended path (network path injection)"],
];

// E-8: Pipeline environment variable spoofing (§8.1)
const PIPELINE_SPOOFING_PATTERNS = [
  [/export\s+SH_PIPELINE/, "export SH_PIPELINE (pipeline env spoofing)"],
  [/SH_PIPELINE=1/, "SH_PIPELINE=1 (pipeline env spoofing)"],
  [/env\s+SH_PIPELINE/, "env SH_PIPELINE (pipeline env spoofing)"],
  [/set\s+SH_PIPELINE/, "set SH_PIPELINE (pipeline env spoofing)"],
];

// E-2: Path obfuscation (checked after normalization)
const PATH_OBFUSCATION_PATTERNS = [
  [/\/proc\/self\/root/, "/proc/self/root (filesystem escape)"],
  [/\/proc\/[0-9]+\/root/, "/proc/PID/root (filesystem escape)"],
  [/PROGRA~[0-9]/, "8.3 short name (path obfuscation)"],
  [/::\$DATA/, "NTFS ADS :$DATA (hidden data stream)"],
  [/::\$INDEX_ALLOCATION/, "NTFS ADS :$INDEX_ALLOCATION"],
];

// ---------------------------------------------------------------------------
// Command preprocessing utilities
// ---------------------------------------------------------------------------

/**
 * Split a command on pipe chain separators (; && || |).
 * Handles simple cases — does NOT parse quoted strings.
 * @param {string} command
 * @returns {string[]}
 */
function splitPipeChain(command) {
  return command.split(/\s*(?:;|&&|\|\|)\s*/);
}

/**
 * Strip sudo prefix from a command.
 * Handles: sudo, sudo -u user, sudo -E, sudo --preserve-env, etc.
 * @param {string} command
 * @returns {string}
 */
function stripSudo(command) {
  return command.replace(
    /^\s*sudo\s+(?:(?:-u\s+\S+|--\S+|-[A-Za-z]+)\s+)*/,
    "",
  );
}

/**
 * Strip command/builtin/env prefix from a command.
 * @param {string} command
 * @returns {string}
 */
function stripPrefix(command) {
  return command.replace(/^\s*(?:command|builtin)\s+/, "");
}

// ---------------------------------------------------------------------------
// Pattern matching engine
// ---------------------------------------------------------------------------

/**
 * Test a command against an array of [RegExp, label] patterns.
 * @param {string} command - Normalized command string
 * @param {Array<[RegExp, string]>} patterns - Pattern array
 * @returns {{ pattern: RegExp, label: string } | null}
 */
function matchPatterns(command, patterns) {
  for (const [pattern, label] of patterns) {
    if (pattern.test(command)) {
      return { pattern, label };
    }
  }
  return null;
}

/**
 * Check a command against all pattern arrays, with pipe-chain splitting,
 * sudo stripping, and prefix stripping.
 * @param {string} command - Raw command string (already NFKC normalized)
 * @param {Array<Array<[RegExp, string]>>} allPatternArrays
 * @returns {{ pattern: RegExp, label: string } | null}
 */
function matchAllPatterns(command, allPatternArrays) {
  // Check the full command first
  for (const patterns of allPatternArrays) {
    const m = matchPatterns(command, patterns);
    if (m) return m;
  }

  // Split on chain separators and check each segment
  const segments = splitPipeChain(command);
  if (segments.length > 1) {
    for (const seg of segments) {
      const cleaned = stripPrefix(stripSudo(seg.trim()));
      for (const patterns of allPatternArrays) {
        const m = matchPatterns(cleaned, patterns);
        if (m) return m;
      }
    }
  }

  // Try sudo + prefix stripping on full command
  const stripped = stripPrefix(stripSudo(command));
  if (stripped !== command) {
    for (const patterns of allPatternArrays) {
      const m = matchPatterns(stripped, patterns);
      if (m) return m;
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Evidence recording helper
// ---------------------------------------------------------------------------

/**
 * Record a deny decision to the evidence ledger.
 * @param {string} hookName
 * @param {string} decision - "deny"
 * @param {string} reason
 * @param {string} command - Truncated command for audit
 * @param {string} sessionId
 */
function recordEvidence(hookName, decision, reason, command, sessionId) {
  try {
    appendEvidence({
      hook: hookName,
      event: "PreToolUse",
      tool: "Bash",
      decision,
      reason,
      command: command.length > 120 ? command.slice(0, 120) + "..." : command,
      session_id: sessionId,
    });
  } catch (_) {
    // Evidence recording failure must not block the deny response
  }
}

// ---------------------------------------------------------------------------
// Main: 10-step judgment flow (§3.2)
// ---------------------------------------------------------------------------

// Guard: only execute main logic when run directly (not when require'd for testing)
if (require.main === module) {
  try {
    const input = readHookInput();
    const command = (input.toolInput && input.toolInput.command) || "";

    // Empty command = not a Bash tool call or no-op — allow
    if (!command) {
      allow();
      return;
    }

    // Step 1: Path normalization (E-2 defense)
    // normalizePath resolves symlinks, Windows backslashes, 8.3 short names
    // We apply it to the command string to detect obfuscated paths
    let normalizedCommand = command;
    // Note: normalizePath works on file paths; for commands we rely on
    // NFKC normalization + pattern matching. Path-specific normalization
    // is applied within PATH_OBFUSCATION_PATTERNS check.

    // Step 2: NFKC normalization (E-7 defense)
    // Normalizes zero-width characters, homoglyphs, fullwidth chars
    normalizedCommand = nfkcNormalize(normalizedCommand);

    // Step 3: Unified pattern matching with pipe-chain splitting,
    // sudo stripping, and prefix stripping
    const allPatternArrays = [
      DESTRUCTIVE_PATTERNS,
      TOOL_SWITCHING_PATTERNS,
      SED_DANGER_PATTERNS,
      DYNAMIC_LINKER_PATTERNS,
      CONFIG_MODIFY_PATTERNS,
      PATH_HIJACK_PATTERNS,
      WINDOWS_PATTERNS,
      PIPELINE_SPOOFING_PATTERNS,
      PATH_OBFUSCATION_PATTERNS,
      GIT_BYPASS_PATTERNS,
      VARIABLE_EXPANSION_PATTERNS,
    ];

    const match = matchAllPatterns(normalizedCommand, allPatternArrays);
    if (match) {
      recordEvidence(
        "sh-gate",
        "deny",
        match.label,
        normalizedCommand,
        input.sessionId,
      );
      const tracker = trackDeny(`gate:${match.label}`);
      if (tracker.exceeded) {
        deny(
          `[sh-gate] PROBING DETECTED: "${match.label}" denied ${tracker.count} times. User confirmation required.`,
        );
      } else {
        deny(`[sh-gate] Blocked: ${match.label}`);
      }
      return;
    }

    // Step 10: All checks passed — allow
    allow();
  } catch (err) {
    // fail-close: any uncaught error = deny (§2.3b)
    process.stdout.write(
      JSON.stringify({
        reason: `Hook error (sh-gate): ${err.message}`,
      }),
    );
    process.exit(2);
  }
} // end require.main guard

// ---------------------------------------------------------------------------
// Exports for testing
// ---------------------------------------------------------------------------
module.exports = {
  DESTRUCTIVE_PATTERNS,
  TOOL_SWITCHING_PATTERNS,
  DYNAMIC_LINKER_PATTERNS,
  SED_DANGER_PATTERNS,
  CONFIG_MODIFY_PATTERNS,
  PATH_HIJACK_PATTERNS,
  WINDOWS_PATTERNS,
  PIPELINE_SPOOFING_PATTERNS,
  PATH_OBFUSCATION_PATTERNS,
  GIT_BYPASS_PATTERNS,
  VARIABLE_EXPANSION_PATTERNS,
  matchPatterns,
  matchAllPatterns,
  splitPipeChain,
  stripSudo,
  stripPrefix,
  recordEvidence,
};
