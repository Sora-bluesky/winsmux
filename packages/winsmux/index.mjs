#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageJson = JSON.parse(
  fs.readFileSync(path.join(__dirname, "package.json"), "utf8"),
);

const args = process.argv.slice(2);
const action = args[0] ?? "install";
const installerArgs = toInstallerArgs(args.slice(1));
const supportedActions = new Set(["install", "update", "uninstall", "version", "help"]);
const releaseTag = `v${packageJson.version}`;

if (!supportedActions.has(action)) {
  console.error(`Unknown winsmux action: ${action}`);
  console.error("Supported actions: install, update, uninstall, version, help");
  process.exit(1);
}

if (packageJson.private === true) {
  console.error(
    "The public npm install surface for winsmux is not enabled in this repository yet.",
  );
  console.error(
    "Use the install flows documented in the repository README until the npm contract is ready.",
  );
  process.exit(1);
}

if (process.platform !== "win32") {
  console.error("The winsmux npm package currently supports Windows only.");
  process.exit(1);
}

const installerPath = path.join(__dirname, "install.ps1");
if (!fs.existsSync(installerPath)) {
  console.error("winsmux install.ps1 is missing from this package.");
  process.exit(1);
}

const shell = process.env.ComSpec || "cmd.exe";
const command = [
  "pwsh",
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  installerPath,
  action,
  "-ReleaseTag",
  releaseTag,
  ...installerArgs,
];

const result = spawnSync(shell, ["/d", "/s", "/c", command.map(quoteWindowsArg).join(" ")], {
  stdio: "inherit",
  env: process.env,
});

if (result.error) {
  throw result.error;
}

process.exit(result.status ?? 1);

function quoteWindowsArg(value) {
  if (!/[ \t"]/u.test(value)) {
    return value;
  }

  return `"${value.replace(/"/gu, '""')}"`;
}

function toInstallerArgs(values) {
  const result = [];

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === "--profile") {
      const profile = values[index + 1];
      if (!profile) {
        console.error("Missing value for --profile.");
        process.exit(1);
      }
      result.push("-Profile", profile);
      index += 1;
      continue;
    }

    if (value.startsWith("--profile=")) {
      const profile = value.slice("--profile=".length);
      if (!profile) {
        console.error("Missing value for --profile.");
        process.exit(1);
      }
      result.push("-Profile", profile);
      continue;
    }

    result.push(value);
  }

  return result;
}
