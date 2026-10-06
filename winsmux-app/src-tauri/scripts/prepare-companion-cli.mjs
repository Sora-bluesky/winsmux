import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { checkedPowerShellEnvironment, physicalPath } from "../../../scripts/distribution-prelaunch.mjs";

const args = process.argv.slice(2);
if (!(args.length === 0 || (args.length === 1 && args[0] === "--release")
    || (args.length === 2 && args[0] === "--release" && args[1] === "--sign-companions"))) {
  throw new Error("Companion preparation accepts --release and optional --sign-companions in that order.");
}
const repoRoot = physicalPath(path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.."));
const env = checkedPowerShellEnvironment(repoRoot);
const result = spawnSync("pwsh", ["-NoLogo", "-NoProfile", "-File",
  path.join(repoRoot, "winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1"),
  ...(args.length ? ["-Release"] : []), ...(args.length === 2 ? ["-SignCompanions"] : [])],
  { cwd: repoRoot, env, stdio: "inherit", windowsHide: true });
if (result.error) { throw result.error; }
if (result.signal || result.status === null) { throw new Error("Companion preparation did not complete normally."); }
process.exitCode = result.status;
