#!/usr/bin/env node
// sh-channel-detect.js — Detect external channel indicators in tool input
// Hook event: PreToolUse
// Warns when tool_input.command or tool_input.text contains channel markers
// (chat_id, message_id, telegram, channel source).
// Always allows (exit 0) — advisory only.
"use strict";

const { allow, readHookInput } = require("./lib/sh-utils");

const CHANNEL_PATTERNS = [
  /\bchat_id\b/i,
  /\bmessage_id\b/i,
  /\btelegram\b/i,
  /\bchannel\s+source\b/i,
  /source\s*=\s*["']?telegram/i,
  /source\s*=\s*["']?channel/i,
];

function extractText(toolInput) {
  if (!toolInput || typeof toolInput !== "object") {
    return "";
  }

  const parts = [];
  if (typeof toolInput.command === "string") {
    parts.push(toolInput.command);
  }

  if (typeof toolInput.text === "string") {
    parts.push(toolInput.text);
  }

  return parts.join("\n");
}

function detectChannel(text) {
  for (const pattern of CHANNEL_PATTERNS) {
    if (pattern.test(text)) {
      return pattern.source;
    }
  }

  return null;
}

function main() {
  const payload = readHookInput();
  const toolInput = payload.tool_input ?? {};
  const text = extractText(toolInput);

  if (!text) {
    process.exit(0);
    return;
  }

  const matchedPattern = detectChannel(text);
  if (matchedPattern) {
    allow(
      "External channel input detected — verify source before processing.",
    );
    return;
  }

  process.exit(0);
}

main();
