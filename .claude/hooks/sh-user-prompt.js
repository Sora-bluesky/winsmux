#!/usr/bin/env node
"use strict";

const {
  readHookInput,
  allow,
  loadPatterns,
  nfkcNormalize,
} = require("./lib/sh-utils");

const SEVERITY_ORDER = ["low", "medium", "high", "critical"];
const CHANNEL_MARKERS = [
  /<channel\b[^>]*\bsource\s*=\s*["']?(telegram|discord|channel)["']?[^>]*>/i,
  /\b(?:chat_id|message_id|thread_id|server_id)\b/i,
  /\b(?:telegram|discord)\b/i,
  /\bsource\s*[:=]\s*["']?(telegram|discord|channel)\b/i,
  /"source"\s*:\s*"(telegram|discord|channel)"/i,
];
const EVENT_MARKERS = [
  /<event\b/i,
  /\bevent(?:_type)?\b\s*[:=]/i,
  /"event(?:_type)?"\s*:\s*"/i,
];

function toSeverityIndex(severity) {
  const index = SEVERITY_ORDER.indexOf(String(severity).toLowerCase());
  return index === -1 ? SEVERITY_ORDER.indexOf("medium") : index;
}

function boostSeverity(severity, levels = 1) {
  const index = toSeverityIndex(severity);
  return SEVERITY_ORDER[Math.min(index + Math.max(levels, 0), SEVERITY_ORDER.length - 1)];
}

function compilePattern(pattern) {
  if (typeof pattern !== "string" || pattern.length === 0) {
    return null;
  }

  const slashPattern = pattern.match(/^\/(.+)\/([a-z]*)$/i);
  if (slashPattern) {
    try {
      return new RegExp(slashPattern[1], slashPattern[2]);
    } catch {
      return null;
    }
  }

  try {
    return new RegExp(pattern, "i");
  } catch {
    return null;
  }
}

function flattenPatterns(patternConfig) {
  if (!patternConfig || typeof patternConfig !== "object" || !patternConfig.categories) {
    return [];
  }

  const entries = [];
  for (const [categoryName, category] of Object.entries(patternConfig.categories)) {
    const patterns = Array.isArray(category.patterns) ? category.patterns : [];
    const severity = String(category.severity || "medium").toLowerCase();
    for (const pattern of patterns) {
      entries.push({
        category: categoryName,
        severity,
        pattern,
      });
    }
  }
  return entries;
}

function hasMarker(text, patterns) {
  return patterns.some((pattern) => pattern.test(text));
}

function detectPromptContext(input, prompt) {
  const normalizedPrompt = nfkcNormalize(prompt || "");
  const metadata = nfkcNormalize(JSON.stringify(input || {}));
  const combined = [normalizedPrompt, metadata].filter(Boolean).join("\n");
  const isChannel = hasMarker(combined, CHANNEL_MARKERS);
  const isChannelEvent = isChannel && hasMarker(combined, EVENT_MARKERS);
  return { normalizedPrompt, isChannel, isChannelEvent };
}

function resolveSeverity(baseSeverity, promptContext) {
  let boostCount = 0;
  if (promptContext.isChannel) {
    boostCount += 1;
  }
  if (promptContext.isChannelEvent) {
    boostCount += 1;
  }
  return boostSeverity(baseSeverity, boostCount);
}

function writeDeny(decision) {
  process.stdout.write(`${JSON.stringify(decision)}\n`);
  process.exit(2);
}

function main() {
  const input = readHookInput();
  const prompt = typeof input.prompt === "string" ? input.prompt : "";
  const { normalizedPrompt, isChannel, isChannelEvent } = detectPromptContext(input, prompt);
  const patterns = flattenPatterns(loadPatterns());

  let matchedDecision = null;

  for (const entry of patterns) {
    const regex = compilePattern(entry.pattern);
    if (!regex || !regex.test(normalizedPrompt)) {
      continue;
    }

    const severity = resolveSeverity(entry.severity, { isChannel, isChannelEvent });
    if (!matchedDecision || toSeverityIndex(severity) > toSeverityIndex(matchedDecision.severity)) {
      matchedDecision = {
        category: entry.category,
        pattern: entry.pattern,
        severity,
      };
    }
  }

  if (matchedDecision && toSeverityIndex(matchedDecision.severity) >= toSeverityIndex("high")) {
    writeDeny({
      decision: "deny",
      result: "deny",
      reason: "Injection pattern detected",
      category: matchedDecision.category,
      pattern: matchedDecision.pattern,
      severity: matchedDecision.severity,
    });
    return;
  }

  allow();
}

if (require.main === module) {
  try {
    main();
  } catch {
    allow();
  }
}

module.exports = {
  CHANNEL_MARKERS,
  EVENT_MARKERS,
  SEVERITY_ORDER,
  toSeverityIndex,
  boostSeverity,
  compilePattern,
  flattenPatterns,
  detectPromptContext,
  resolveSeverity,
  writeDeny,
};
