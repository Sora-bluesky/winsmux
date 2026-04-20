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

const args = parseArgs(process.argv);
const version = args.version;
const outDir = args.out;

if (!version || !outDir) {
  throw new Error("Usage: node scripts/stage-npm-release.mjs --version <semver> --out <dir>");
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
delete stagedPackage.private;
fs.writeFileSync(stagedPackagePath, `${JSON.stringify(stagedPackage, null, 2)}\n`);

const licenseSource = path.join(repoRoot, "LICENSE");
if (fs.existsSync(licenseSource)) {
  fs.copyFileSync(licenseSource, path.join(targetDir, "LICENSE"));
}

console.log(`Staged winsmux npm package at ${targetDir}`);
