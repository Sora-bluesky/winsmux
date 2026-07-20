import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
    }
    args[key] = value;
    i += 1;
  }
  return args;
}

function copyDir(sourceDir, targetDir) {
  fs.mkdirSync(targetDir, { recursive: true });
  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    if (entry.isDirectory()) {
      copyDir(sourcePath, targetPath);
      continue;
    }
    fs.copyFileSync(sourcePath, targetPath);
  }
}

function isSemver(version) {
  return /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version);
}

function coordinatesFromReleaseTag(releaseTag) {
  const normalizedTag = releaseTag.trim().replace(/^v/iu, "");
  const match = /^(?<binary>\d+\.\d+\.\d+)(?:\.(?<revision>\d+))?(?<suffix>-[0-9A-Za-z.-]+)?$/u.exec(
    normalizedTag,
  );
  if (!match) {
    throw new Error(`Unsupported winsmux release tag format: ${releaseTag}`);
  }
  const suffix = match.groups.suffix ?? "";
  const packageVersion = match.groups.revision
    ? `${match.groups.binary}-hotfix.${match.groups.revision}${suffix ? `.${suffix.slice(1)}` : ""}`
    : `${match.groups.binary}${suffix}`;
  return { packageVersion, releaseTag: `v${normalizedTag}` };
}

const args = parseArgs(process.argv);
if (Boolean(args.version) === Boolean(args["release-tag"])) {
  throw new Error("Specify exactly one of --version or --release-tag");
}
const coordinates = args["release-tag"]
  ? coordinatesFromReleaseTag(args["release-tag"])
  : { packageVersion: args.version, releaseTag: `v${args.version}` };
const version = coordinates.packageVersion;
const outDir = args.out;

if (!version || !outDir) {
  throw new Error(
    "Usage: node scripts/stage-npm-release.mjs (--version <semver> | --release-tag <tag>) --out <dir>",
  );
}

if (!isSemver(version)) {
  throw new Error(`Invalid semver: ${version}`);
}

const repoRoot = process.cwd();
const sourceDir = path.join(repoRoot, "packages", "winsmux");
const sourcePackagePath = path.join(sourceDir, "package.json");

if (!fs.existsSync(sourcePackagePath)) {
  console.log("winsmux npm package source is missing; skipping stage.");
  process.exit(0);
}

const sourcePackage = JSON.parse(fs.readFileSync(sourcePackagePath, "utf8"));
if (sourcePackage.private !== false) {
  console.log("winsmux npm package is still gated (private=true); skipping stage.");
  process.exit(0);
}

const targetDir = path.resolve(repoRoot, outDir);
fs.rmSync(targetDir, { recursive: true, force: true });
copyDir(sourceDir, targetDir);

const stagedPackagePath = path.join(targetDir, "package.json");
const stagedPackage = JSON.parse(fs.readFileSync(stagedPackagePath, "utf8"));
stagedPackage.version = version;
stagedPackage.winsmuxReleaseTag = coordinates.releaseTag;
delete stagedPackage.private;
fs.writeFileSync(stagedPackagePath, `${JSON.stringify(stagedPackage, null, 2)}\n`);

const licenseSource = path.join(repoRoot, "LICENSE");
if (fs.existsSync(licenseSource)) {
  fs.copyFileSync(licenseSource, path.join(targetDir, "LICENSE"));
}

const installScriptSource = path.join(repoRoot, "install.ps1");
if (fs.existsSync(installScriptSource)) {
  const installScript = fs.readFileSync(installScriptSource, "utf8");
  const versionPatched = installScript.replace(
    /\$VERSION\s*=\s*"[^"]*"/u,
    `$VERSION      = "${version}"`,
  );
  fs.writeFileSync(path.join(targetDir, "install.ps1"), versionPatched);
}

console.log(`Staged winsmux npm package at ${targetDir}`);
