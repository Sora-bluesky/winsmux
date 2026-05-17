#!/usr/bin/env node
// sh-plugin-loader.js - Loads repository-local hook plugins.
// Event: any registered hook event
"use strict";

const fs = require("fs");
const path = require("path");
const {
  readHookInput,
  getHookEventName,
  isPreToolUseEvent,
  appendEvidence,
  failClosed,
} = require("./lib/sh-utils");

const HOOK_NAME = "sh-plugin-loader";
const PLUGIN_ROOT = path.join(".claude", "hooks", "plugins");
const DEFAULT_ORDER = 1000;

function writeStdout(payload) {
  fs.writeSync(process.stdout.fd, payload, null, "utf8");
}

function getPluginRoot(repoRoot = process.cwd()) {
  return path.resolve(repoRoot, PLUGIN_ROOT);
}

function isPathInside(parent, child) {
  const relative = path.relative(parent, child);
  return relative !== "" && !relative.startsWith("..") && !path.isAbsolute(relative);
}

function discoverPluginFiles(pluginRoot = getPluginRoot()) {
  if (!fs.existsSync(pluginRoot)) {
    return [];
  }

  const rootRealPath = fs.realpathSync(pluginRoot);
  return fs
    .readdirSync(pluginRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
    .map((entry) => {
      const fullPath = path.join(pluginRoot, entry.name);
      const stat = fs.lstatSync(fullPath);
      if (stat.isSymbolicLink()) {
        return null;
      }

      const realPath = fs.realpathSync(fullPath);
      if (!isPathInside(rootRealPath, realPath)) {
        return null;
      }

      return {
        fileName: entry.name,
        fullPath,
        realPath,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.fileName.localeCompare(b.fileName));
}

function normalizeEvents(events) {
  if (!Array.isArray(events) || events.length === 0) {
    return ["*"];
  }

  return events
    .map((event) => String(event || "").trim())
    .filter(Boolean);
}

function normalizeOrder(order) {
  const parsed = Number(order);
  return Number.isFinite(parsed) ? parsed : DEFAULT_ORDER;
}

function normalizePlugin(file, pluginModule) {
  const candidate =
    pluginModule && typeof pluginModule === "object" && pluginModule.default
      ? pluginModule.default
      : pluginModule;

  if (typeof candidate === "function") {
    return {
      name: path.basename(file.fileName, ".js"),
      fileName: file.fileName,
      order: DEFAULT_ORDER,
      events: ["*"],
      enabled: true,
      failClosed: true,
      run: candidate,
    };
  }

  if (!candidate || typeof candidate !== "object" || typeof candidate.run !== "function") {
    throw new Error(`${file.fileName} must export a function or an object with run(input, context).`);
  }

  return {
    name: String(candidate.name || path.basename(file.fileName, ".js")),
    fileName: file.fileName,
    order: normalizeOrder(candidate.order),
    events: normalizeEvents(candidate.events),
    enabled: candidate.enabled !== false,
    failClosed: candidate.failClosed !== false,
    run: candidate.run,
  };
}

async function withConsoleCapture(fn) {
  const captured = [];
  const original = {
    log: console.log,
    warn: console.warn,
    error: console.error,
  };

  console.log = (...args) => captured.push({ stream: "stdout", message: args.map(String).join(" ") });
  console.warn = (...args) => captured.push({ stream: "stderr", message: args.map(String).join(" ") });
  console.error = (...args) => captured.push({ stream: "stderr", message: args.map(String).join(" ") });

  try {
    const value = await fn();
    return { value, captured };
  } finally {
    console.log = original.log;
    console.warn = original.warn;
    console.error = original.error;
  }
}

async function loadPlugins(pluginRoot = getPluginRoot()) {
  const plugins = [];
  const failures = [];

  for (const file of discoverPluginFiles(pluginRoot)) {
    try {
      const loaded = await withConsoleCapture(async () => {
        delete require.cache[require.resolve(file.realPath)];
        return normalizePlugin(file, require(file.realPath));
      });
      plugins.push({ ...loaded.value, consoleMessages: loaded.captured });
    } catch (error) {
      failures.push({
        fileName: file.fileName,
        failClosed: true,
        error: error && error.message ? error.message : String(error),
      });
    }
  }

  plugins.sort((a, b) => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    const byName = a.name.localeCompare(b.name);
    if (byName !== 0) {
      return byName;
    }
    return a.fileName.localeCompare(b.fileName);
  });

  return { plugins, failures };
}

function pluginMatchesEvent(plugin, eventName) {
  const normalizedEvent = String(eventName || "").toLowerCase();
  return plugin.events.some((event) => {
    const normalized = String(event || "").toLowerCase();
    return normalized === "*" || normalized === normalizedEvent;
  });
}

function flattenResult(plugin, result) {
  if (result == null || result === false) {
    return {};
  }
  if (typeof result === "string") {
    return { additionalContext: result };
  }
  if (typeof result !== "object" || Array.isArray(result)) {
    return { additionalContext: String(result) };
  }

  const output = result.hookSpecificOutput || result;
  const permissionDecision = output.permissionDecision || result.permissionDecision || result.decision;
  const permissionDecisionReason =
    output.permissionDecisionReason || result.permissionDecisionReason || result.reason || result.message;

  return {
    plugin: plugin.name,
    permissionDecision,
    permissionDecisionReason,
    systemMessage: result.systemMessage || output.systemMessage,
    additionalContext: output.additionalContext || result.additionalContext,
    updatedInput: output.updatedInput || result.updatedInput,
    updatedMCPToolOutput: output.updatedMCPToolOutput || result.updatedMCPToolOutput,
  };
}

function appendPluginEvidence(entry) {
  appendEvidence({
    hook: HOOK_NAME,
    ...entry,
  });
}

async function runPlugins(input, options = {}) {
  const eventName = getHookEventName(input) || "Unknown";
  const pluginRoot = options.pluginRoot || getPluginRoot(options.repoRoot || process.cwd());
  const { plugins, failures } = await loadPlugins(pluginRoot);
  const matched = [];
  const denials = [];
  const contexts = [];
  const updates = {};

  for (const failure of failures) {
    appendPluginEvidence({
      event: eventName,
      decision: "error",
      stage: "load",
      plugin: failure.fileName,
      error: failure.error,
    });
    denials.push(`[${failure.fileName}] plugin load failed: ${failure.error}`);
  }

  for (const plugin of plugins) {
    if (!plugin.enabled || !pluginMatchesEvent(plugin, eventName)) {
      continue;
    }

    matched.push(plugin.name);
    if (plugin.consoleMessages.length > 0) {
      appendPluginEvidence({
        event: eventName,
        decision: "observe",
        stage: "load-console",
        plugin: plugin.name,
        console: plugin.consoleMessages,
      });
    }

    try {
      const runResult = await withConsoleCapture(() =>
        plugin.run(input, {
          eventName,
          pluginName: plugin.name,
          repoRoot: options.repoRoot || process.cwd(),
        }),
      );
      if (runResult.captured.length > 0) {
        appendPluginEvidence({
          event: eventName,
          decision: "observe",
          stage: "run-console",
          plugin: plugin.name,
          console: runResult.captured,
        });
      }

      const flattened = flattenResult(plugin, runResult.value);
      if (flattened.additionalContext) {
        contexts.push(`[${plugin.name}] ${flattened.additionalContext}`);
      }
      if (flattened.updatedInput) {
        updates.updatedInput = flattened.updatedInput;
      }
      if (flattened.updatedMCPToolOutput) {
        updates.updatedMCPToolOutput = flattened.updatedMCPToolOutput;
      }
      if (String(flattened.permissionDecision || "").toLowerCase() === "deny") {
        denials.push(
          `[${plugin.name}] ${flattened.permissionDecisionReason || "plugin denied the hook event"}`,
        );
      }
    } catch (error) {
      const message = error && error.message ? error.message : String(error);
      appendPluginEvidence({
        event: eventName,
        decision: plugin.failClosed ? "deny" : "allow",
        stage: "run",
        plugin: plugin.name,
        error: message,
      });

      if (plugin.failClosed) {
        denials.push(`[${plugin.name}] plugin failed: ${message}`);
      }
    }
  }

  return {
    eventName,
    matched,
    denials,
    contexts,
    updates,
  };
}

function buildReply(input, result) {
  const hookEventName = result.eventName || getHookEventName(input) || "Unknown";
  if (result.denials.length > 0) {
    const reason = result.denials.join("; ");
    if (isPreToolUseEvent(input)) {
      return {
        hookSpecificOutput: {
          hookEventName,
          permissionDecision: "deny",
          permissionDecisionReason: reason,
        },
        systemMessage: `[${HOOK_NAME}] ${reason}`,
      };
    }

    throw new Error(reason);
  }

  const hookSpecificOutput = {
    hookEventName,
    ...result.updates,
  };
  if (result.contexts.length > 0) {
    hookSpecificOutput.additionalContext = result.contexts.join("\n");
  }

  if (Object.keys(hookSpecificOutput).length === 1) {
    return null;
  }

  return { hookSpecificOutput };
}

async function main() {
  const input = readHookInput();
  try {
    const result = await runPlugins(input);
    const reply = buildReply(input, result);
    if (reply) {
      writeStdout(`${JSON.stringify(reply)}\n`);
    }
    process.exit(0);
  } catch (error) {
    failClosed(`[${HOOK_NAME}] Hook error (fail-close): ${error.message}`);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  HOOK_NAME,
  PLUGIN_ROOT,
  discoverPluginFiles,
  normalizePlugin,
  loadPlugins,
  pluginMatchesEvent,
  flattenResult,
  runPlugins,
  buildReply,
};
