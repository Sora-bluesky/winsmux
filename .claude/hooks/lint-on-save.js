"use strict";
/**
 * Post-tool hook: Run linter/formatter on source files after Edit/Write.
 *
 * Triggered after Edit or Write tools modify files.
 * - Python files (.py): Runs ruff (format + lint) and ty (type check) if available
 * - PowerShell files (.ps1, .psm1): Runs PSScriptAnalyzer if available
 * - Other files: Skips silently
 *
 * All tool checks use graceful degradation — missing tools are silently skipped.
 */

const { execFileSync } = require("child_process");
const path = require("path");
const { readHookInput } = require("./lib/sh-utils");

// --- Constants ---

const MAX_PATH_LENGTH = 4096;
const COMMAND_TIMEOUT = 30000;

// --- Path Validation ---

/**
 * Validate file path for security.
 * @param {string} filePath
 * @returns {boolean}
 */
function validatePath(filePath) {
  if (!filePath || filePath.length > MAX_PATH_LENGTH) return false;
  if (filePath.includes("..")) return false;
  return true;
}

// --- Command Execution ---

/**
 * Run a command and return { code, stdout, stderr }.
 * @param {string} cmd
 * @param {string[]} args
 * @param {string} cwd
 * @returns {{ code: number, stdout: string, stderr: string }}
 */
function runCommand(cmd, args, cwd) {
  try {
    const stdout = execFileSync(cmd, args, {
      cwd,
      timeout: COMMAND_TIMEOUT,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { code: 0, stdout: stdout || "", stderr: "" };
  } catch (e) {
    if (e.code === "ENOENT") {
      return { code: -1, stdout: "", stderr: `Command not found: ${cmd}` };
    }
    if (e.killed) {
      return { code: 1, stdout: "", stderr: "Command timed out" };
    }
    return {
      code: e.status || 1,
      stdout: e.stdout || "",
      stderr: e.stderr || "",
    };
  }
}

// --- Python Linting ---

/**
 * Run Python linters (ruff, ty) if available.
 * @param {string} filePath
 * @param {string} projectDir
 * @param {string} relPath
 * @returns {string[]} issues found
 */
function lintPython(filePath, projectDir, relPath) {
  const issues = [];

  // Run ruff format
  let result = runCommand(
    "uv",
    ["run", "ruff", "format", filePath],
    projectDir,
  );
  if (result.code === -1) return []; // uv not found, skip all Python linting
  if (result.code !== 0) {
    issues.push(`ruff format failed:\n${result.stderr || result.stdout}`);
  }

  // Run ruff check with auto-fix
  result = runCommand(
    "uv",
    ["run", "ruff", "check", "--fix", filePath],
    projectDir,
  );
  if (result.code !== 0) {
    const output = result.stdout || result.stderr;
    if (output.trim()) {
      issues.push(`ruff check issues:\n${output}`);
    }
  }

  // Run ty type check
  result = runCommand("uv", ["run", "ty", "check", filePath], projectDir);
  if (result.code !== 0) {
    const output = result.stdout || result.stderr;
    if (output.trim()) {
      issues.push(`ty check issues:\n${output}`);
    }
  }

  if (issues.length > 0) {
    process.stderr.write(`[lint-on-save] Issues found in ${relPath}:\n`);
    for (const issue of issues) {
      process.stderr.write(issue + "\n");
    }
    process.stderr.write("\nPlease review and fix these issues.\n");
  } else {
    process.stdout.write(`[lint-on-save] OK: ${relPath} passed all checks\n`);
  }

  return issues;
}

// --- PowerShell Linting ---

/**
 * Escape a string for safe use inside PowerShell single-quoted string.
 * @param {string} s
 * @returns {string} escaped string, or empty if unsafe
 */
function escapePowershellString(s) {
  if (s.includes("\x00") || s.includes("\n") || s.includes("\r")) {
    return "";
  }
  return s.replace(/'/g, "''");
}

/**
 * Run PowerShell linter (PSScriptAnalyzer) if available.
 * @param {string} filePath
 * @param {string} projectDir
 * @param {string} relPath
 * @returns {string[]} issues found
 */
function lintPowershell(filePath, projectDir, relPath) {
  const issues = [];

  const safePath = escapePowershellString(filePath);
  if (!safePath) {
    process.stderr.write(
      `[lint-on-save] WARNING: Unsafe path rejected for PSScriptAnalyzer: ${relPath}\n`,
    );
    return [];
  }

  const result = runCommand(
    "pwsh",
    [
      "-NoProfile",
      "-Command",
      `Invoke-ScriptAnalyzer -Path '${safePath}' -Severity Warning,Error`,
    ],
    projectDir,
  );

  if (result.code === -1) return []; // pwsh not found, skip
  if (result.code === 0 && result.stdout.trim()) {
    process.stderr.write(
      `[lint-on-save] PSScriptAnalyzer issues in ${relPath}:\n`,
    );
    process.stderr.write(result.stdout + "\n");
    issues.push(result.stdout);
  } else if (result.code === 0) {
    process.stdout.write(
      `[lint-on-save] OK: ${relPath} passed PSScriptAnalyzer\n`,
    );
  }

  return issues;
}

// --- Hook handler ---

/**
 * @param {object} data - PostToolUse hook input
 */
function handler(data) {
  const toolInput = data.toolInput || data.tool_input || {};
  const filePath = toolInput.file_path;

  if (!filePath) return;
  if (!validatePath(filePath)) {
    process.stderr.write(
      `[lint-on-save] WARNING: Invalid path rejected: ${filePath}\n`,
    );
    return;
  }

  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();

  let relPath;
  if (filePath.startsWith(projectDir)) {
    relPath = path.relative(projectDir, filePath);
  } else {
    relPath = filePath;
  }

  if (filePath.endsWith(".py")) {
    lintPython(filePath, projectDir, relPath);
  } else if (filePath.endsWith(".ps1") || filePath.endsWith(".psm1")) {
    lintPowershell(filePath, projectDir, relPath);
  }
  // Other file types: skip silently
}

// --- Exports (for testing) ---

module.exports = {
  validatePath,
  runCommand,
  lintPython,
  lintPowershell,
  escapePowershellString,
  handler,
  MAX_PATH_LENGTH,
  COMMAND_TIMEOUT,
};

// --- Entry point ---

if (require.main === module) {
  try {
    const input = readHookInput();
    handler(input);
  } catch (e) {
    process.stderr.write(`[lint-on-save] Error: ${e.message}\n`);
  }
}
