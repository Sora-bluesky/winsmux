#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { ZERO_WIDTH_RE } = require("./sh-injection-guard");
const { allow, deny, failClosed } = require("./lib/sh-utils");

const HOOK_NAME = "sh-invisible-char-scan";
const BLOCKED_EXTENSIONS = new Set([
  ".js",
  ".ts",
  ".ps1",
  ".sh",
  ".py",
  ".yaml",
  ".json",
  ".md",
]);

function readInputPayload() {
  const raw = fs.readFileSync(0, "utf8");

  if (!raw.trim()) {
    return {
      payload: {},
      rawInput: "",
      rawTextMode: false,
    };
  }

  try {
    return {
      payload: JSON.parse(raw),
      rawInput: raw,
      rawTextMode: false,
    };
  } catch {
    return {
      payload: {},
      rawInput: raw,
      rawTextMode: true,
    };
  }
}

function getToolInput(payload) {
  if (payload && typeof payload === "object" && !Array.isArray(payload)) {
    if (payload.tool_input && typeof payload.tool_input === "object") {
      return payload.tool_input;
    }
    if (payload.toolInput && typeof payload.toolInput === "object") {
      return payload.toolInput;
    }
  }
  return {};
}

function inferToolName(payload, toolInput) {
  const directName =
    (payload && (payload.tool_name || payload.toolName)) || "";
  if (directName) {
    return String(directName);
  }
  if (typeof toolInput.content === "string") {
    return "Write";
  }
  if (typeof toolInput.new_string === "string") {
    return "Edit";
  }
  return "";
}

function extractTargets(payload, rawInput, rawTextMode) {
  const toolInput = getToolInput(payload);
  const toolName = inferToolName(payload, toolInput);
  const filePath =
    toolInput.file_path ||
    toolInput.file ||
    payload.file_path ||
    payload.file ||
    "";

  if (toolName !== "Write" && toolName !== "Edit") {
    return [];
  }

  const targets = [];
  if (toolName === "Write" && typeof toolInput.content === "string") {
    targets.push({ filePath, source: "content", text: toolInput.content });
  }
  if (toolName === "Edit" && typeof toolInput.new_string === "string") {
    targets.push({ filePath, source: "new_string", text: toolInput.new_string });
  }

  if (typeof toolInput.stdin === "string") {
    targets.push({ filePath, source: "stdin", text: toolInput.stdin });
  }

  if (typeof payload.stdin === "string") {
    targets.push({ filePath, source: "stdin", text: payload.stdin });
  }

  if (targets.length === 0 && rawTextMode) {
    targets.push({ filePath, source: "stdin", text: rawInput });
  }

  return dedupeTargets(targets);
}

function dedupeTargets(targets) {
  const seen = new Set();
  return targets.filter((target) => {
    const key = `${target.filePath}\u0000${target.source}\u0000${target.text}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

function createZeroWidthScanner() {
  return new RegExp(ZERO_WIDTH_RE.source, "u");
}

function isBlockedFile(filePath) {
  const extension = path.extname(String(filePath || "")).toLowerCase();
  return BLOCKED_EXTENSIONS.has(extension);
}

function codePointLabel(char) {
  return `U+${char.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}`;
}

function escapedChar(char) {
  return Array.from(char)
    .map((part) => {
      const value = part.codePointAt(0).toString(16).toUpperCase();
      return value.length <= 4
        ? `\\u${value.padStart(4, "0")}`
        : `\\u{${value}}`;
    })
    .join("");
}

function findInvisibleChars(text) {
  const findings = [];
  const matcher = createZeroWidthScanner();
  let line = 1;
  let column = 1;
  let offset = 0;
  let previousWasCarriageReturn = false;

  for (const char of String(text || "")) {
    if (matcher.test(char)) {
      findings.push({
        char,
        codePoint: codePointLabel(char),
        escaped: escapedChar(char),
        offset,
        line,
        column,
      });
    }

    if (char === "\r") {
      line += 1;
      column = 1;
      previousWasCarriageReturn = true;
    } else if (char === "\n") {
      if (!previousWasCarriageReturn) {
        line += 1;
      }
      column = 1;
      previousWasCarriageReturn = false;
    } else if (char === "\u2028" || char === "\u2029") {
      line += 1;
      column = 1;
      previousWasCarriageReturn = false;
    } else {
      column += 1;
      previousWasCarriageReturn = false;
    }

    offset += char.length;
  }

  return findings;
}

function scanTargets(targets) {
  const results = [];

  for (const target of targets) {
    const findings = findInvisibleChars(target.text);
    if (findings.length === 0) {
      continue;
    }

    results.push({
      filePath: target.filePath || "<unknown file>",
      source: target.source,
      blocked: !target.filePath || isBlockedFile(target.filePath),
      findings,
    });
  }

  return results;
}

function formatFinding(result, finding) {
  return [
    `${result.filePath}`,
    `${result.source}`,
    `${finding.codePoint}`,
    `${finding.escaped}`,
    `line ${finding.line}`,
    `column ${finding.column}`,
    `offset ${finding.offset}`,
    `literal "${finding.char}"`,
  ].join(" | ");
}

function buildMessage(results) {
  const lines = [
    `[${HOOK_NAME}] Invisible Unicode characters detected in tool input.`,
    "Each entry is: file | source | code point | escaped | line | column | offset | literal",
  ];

  for (const result of results) {
    for (const finding of result.findings) {
      lines.push(`- ${formatFinding(result, finding)}`);
    }
  }

  return lines.join("\n");
}

function main() {
  const { payload, rawInput, rawTextMode } = readInputPayload();
  const targets = extractTargets(payload, rawInput, rawTextMode);

  if (targets.length === 0) {
    process.exit(0);
    return;
  }

  const results = scanTargets(targets);
  if (results.length === 0) {
    process.exit(0);
    return;
  }

  const message = buildMessage(results);
  if (results.some((result) => result.blocked)) {
    deny(message);
    return;
  }

  allow(message);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    failClosed(`[${HOOK_NAME}] Hook error: ${error.message}`);
  }
}

module.exports = {
  BLOCKED_EXTENSIONS,
  readInputPayload,
  getToolInput,
  inferToolName,
  extractTargets,
  dedupeTargets,
  createZeroWidthScanner,
  isBlockedFile,
  codePointLabel,
  escapedChar,
  findInvisibleChars,
  scanTargets,
  formatFinding,
  buildMessage,
};
