import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { checkedPowerShellEnvironment, physicalPath } from "./distribution-prelaunch.mjs";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!["--version", "--release-tag", "--out"].includes(key) ||
        Object.hasOwn(args, key.slice(2)) || !argv[i + 1] || argv[i + 1].startsWith("--")) {
      throw new Error(`Invalid or duplicate staging argument: ${key}`);
    }
    args[key.slice(2)] = argv[i + 1];
  }
  if (!args.out || Boolean(args.version) === Boolean(args["release-tag"])) {
    throw new Error("Specify --out and exactly one of --version or --release-tag");
  }
  return args;
}
const number = "(?:0|[1-9][0-9]*)";
const identifier = "(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)";
const nativePattern = new RegExp(`^${number}\\.${number}\\.${number}(?:-${identifier}(?:\\.${identifier})*)?$`);
const tagPattern = new RegExp(`^v(?<base>${number}\\.${number}\\.${number})(?:\\.(?<revision>${number}))?(?<suffix>-${identifier}(?:\\.${identifier})*)?$`);
function nativeVersion(version) {
  if (!nativePattern.test(version) || /-pkgfix(?:\.|$)/u.test(version)) {
    throw new Error(`Unsupported native release version: ${version}`);
  }
  return version;
}
function coordinates(args) {
  if (args.version) {
    const version = nativeVersion(args.version);
    return { nativeVersion: version, packageVersion: version, releaseTag: `v${version}` };
  }
  const match = tagPattern.exec(args["release-tag"]);
  if (!match) { throw new Error(`Unsupported release tag: ${args["release-tag"]}`); }
  const { base, revision, suffix = "" } = match.groups;
  const version = nativeVersion(`${base}${suffix}`);
  return {
    nativeVersion: version,
    packageVersion: revision === undefined ? version : `${base}-pkgfix.${revision}${suffix ? `.${suffix.slice(1)}` : ""}`,
    releaseTag: args["release-tag"],
  };
}
// Operator-owned filesystem; existing links/junction ancestors are refused.
// No guarantee is made against adversarial filesystem replacement.
function namespaceKey(input) {
  const normalized = path.resolve(input);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}
function contains(parent, child) {
  const relative = path.relative(namespaceKey(parent), namespaceKey(child));
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}
function overlaps(a, b) { return contains(a, b) || contains(b, a); }
function snapshotTree(directory, prefix = "", files = new Map()) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) { throw new Error(`Linked npm source is unsupported: ${file}`); }
    const relative = path.join(prefix, entry.name);
    if (stat.isDirectory()) { snapshotTree(file, relative, files); }
    else if (stat.isFile()) { files.set(relative, fs.readFileSync(file)); }
    else { throw new Error(`Unsupported npm source entry: ${file}`); }
  }
  return files;
}
function verifyFiles(directory, files) {
  const actual = snapshotTree(directory);
  if (actual.size !== files.size) { throw new Error("Published npm generation has unexpected files."); }
  for (const [relative, bytes] of files) {
    if (!actual.get(relative)?.equals(bytes)) { throw new Error(`npm generation bytes differ: ${relative}`); }
  }
}
// Marker existence is the sole retry authority after mutation starts.
function publishGeneration(target, stage, backup, pending, files) {
  const original = fs.existsSync(target) ? snapshotTree(target) : null;
  const marker = fs.openSync(pending, "wx");
  try {
    fs.writeFileSync(marker, JSON.stringify({ target, stage, backup }));
    fs.fsyncSync(marker);
  } finally { fs.closeSync(marker); }
  let parked = false;
  let published = false;
  try {
    if (original) { fs.renameSync(target, backup); parked = true; }
    fs.renameSync(stage, target);
    published = true;
    verifyFiles(target, files);
  } catch (publicationError) {
    try {
      if (published) { fs.renameSync(target, stage); }
      if (parked) { fs.renameSync(backup, target); }
      if (original) { verifyFiles(target, original); }
      else if (fs.existsSync(target)) { throw new Error("Initial npm restoration left canonical output."); }
      fs.unlinkSync(pending);
    } catch (restorationError) {
      throw new Error("npm recovery required; barrier and generations retained: " + pending, { cause: restorationError });
    }
    throw publicationError;
  }
  // A failure to remove this barrier leaves canonical untouched and blocks retry.
  fs.unlinkSync(pending);
}
const args = parseArgs(process.argv.slice(2));
const release = coordinates(args);
const repoRoot = physicalPath(process.cwd());
const sourceDir = physicalPath(path.join(repoRoot, "packages/winsmux"));
const targetDir = physicalPath(path.resolve(repoRoot, args.out));
const generation = randomUUID();
const stageDir = physicalPath(`${targetDir}.stage.${generation}`);
const backupDir = physicalPath(`${targetDir}.backup.${generation}`);
const lockPath = physicalPath(`${targetDir}.prepare.lock`);
const pendingPath = physicalPath(targetDir + ".recovery.pending");
if (fs.existsSync(pendingPath)) { throw new Error("npm recovery required: unresolved generation barrier exists."); }
const protectedOutputs = [targetDir, stageDir, backupDir, lockPath, pendingPath];
if (fs.existsSync(path.dirname(targetDir))) {
  for (const name of fs.readdirSync(path.dirname(targetDir))) {
    const candidate = path.join(path.dirname(targetDir), name);
    if (namespaceKey(candidate).startsWith(namespaceKey(targetDir + ".backup.")) ||
        namespaceKey(candidate).startsWith(namespaceKey(targetDir + ".stage."))) {
      protectedOutputs.push(physicalPath(candidate));
    }
  }
}
// The same gate guards every source read for both preparation entrances.
const gateEnvironment = checkedPowerShellEnvironment(repoRoot, protectedOutputs);
const gate = spawnSync("pwsh", ["-NoLogo", "-NoProfile", "-File",
  path.join(repoRoot, "scripts/assert-distribution-version.ps1"), "-RepoRoot", repoRoot,
  "-Preparation", "Npm", "-ProtectedOutputsJson", JSON.stringify(protectedOutputs), "-AsJson"],
{ cwd: repoRoot, env: gateEnvironment, encoding: "utf8", windowsHide: true });
if (gate.error || gate.status !== 0) {
  throw new Error(`Distribution version gate failed: ${gate.error?.message ?? gate.stderr ?? gate.stdout}`);
}
const verified = JSON.parse(gate.stdout);
if (JSON.stringify(verified.protected_outputs) !== JSON.stringify(protectedOutputs)) {
  throw new Error("Distribution gate protected inventory differs from the requested inventory.");
}
if (verified.schema !== "distribution-read-set/v1" || typeof verified.version !== "string" ||
    !Array.isArray(verified.source_roots) || !verified.source_roots.length ||
    !Array.isArray(verified.source_leaves) || !verified.source_leaves.length ||
    ![...verified.source_roots, ...verified.source_leaves].every(value => typeof value === "string" && path.isAbsolute(value))) {
  throw new Error("Distribution gate did not return a verified source read-set.");
}
const sourceFootprints = [...verified.source_roots, ...verified.source_leaves].map(physicalPath);
for (const output of [targetDir, stageDir, backupDir, lockPath, pendingPath]) {
  for (const source of sourceFootprints) {
    if (overlaps(source, output)) { throw new Error("npm output and distribution source footprints overlap."); }
  }
}
if (fs.existsSync(targetDir) && !fs.statSync(targetDir).isDirectory()) {
  throw new Error("Existing npm output must be a directory.");
}
if (fs.existsSync(stageDir) || fs.existsSync(backupDir)) { throw new Error("npm generation already exists."); }
const version = nativeVersion(verified.version);
if (release.nativeVersion !== version) { throw new Error("Requested npm native version differs from VERSION."); }
const files = snapshotTree(sourceDir);
const sourcePackage = JSON.parse(files.get("package.json").toString("utf8"));
if (sourcePackage.private !== false) { throw new Error("npm package is not enabled for release preparation."); }
sourcePackage.version = release.packageVersion;
sourcePackage.winsmuxReleaseTag = release.releaseTag;
delete sourcePackage.private;
files.set("package.json", Buffer.from(`${JSON.stringify(sourcePackage, null, 2)}\n`));
files.set("LICENSE", fs.readFileSync(path.join(repoRoot, "LICENSE")));
// The canonical version gate already requires one installer VERSION assignment
// equal to the selected native version. Preserve its verified bytes verbatim;
// package repair tags change package metadata, not the native installer body.
files.set("install.ps1", fs.readFileSync(path.join(repoRoot, "install.ps1")));
fs.mkdirSync(path.dirname(targetDir), { recursive: true });
const lock = fs.openSync(lockPath, "wx");
try {
  if (fs.existsSync(pendingPath)) { throw new Error("npm recovery required: unresolved generation barrier exists."); }
  if (!fs.existsSync(targetDir) && fs.readdirSync(path.dirname(targetDir))
    .some(name => namespaceKey(path.join(path.dirname(targetDir), name)).startsWith(namespaceKey(`${targetDir}.backup.`)))) {
    throw new Error("npm recovery required: canonical output is absent and a retained backup exists.");
  }
  fs.mkdirSync(stageDir);
  for (const [relative, bytes] of files) {
    const destination = path.join(stageDir, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, bytes);
  }
  verifyFiles(stageDir, files);
  publishGeneration(targetDir, stageDir, backupDir, pendingPath, files);
  console.log(`Staged winsmux ${release.packageVersion} (${release.releaseTag}; native ${version}) at ${targetDir}`);
} finally {
  fs.closeSync(lock);
  fs.unlinkSync(lockPath);
}
