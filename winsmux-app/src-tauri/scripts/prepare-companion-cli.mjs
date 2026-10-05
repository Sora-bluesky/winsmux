import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { checkedPowerShellEnvironment, physicalPath } from "../../../scripts/distribution-prelaunch.mjs";

const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== "--release")) {
  throw new Error("Companion preparation accepts only --release.");
}
const repoRoot = physicalPath(path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.."));
const env = checkedPowerShellEnvironment(repoRoot);
const result = spawnSync("pwsh", ["-NoLogo", "-NoProfile", "-File",
  path.join(repoRoot, "winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1"),
  ...(args.length ? ["-Release"] : [])], { cwd: repoRoot, env, stdio: "inherit", windowsHide: true });
if (result.error) { throw result.error; }
if (result.signal || result.status === null) { throw new Error("Companion preparation did not complete normally."); }
process.exitCode = result.status;
