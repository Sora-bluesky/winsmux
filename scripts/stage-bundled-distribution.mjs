import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { buildDistributionLicenses, stageDistributionLicenses } from './stage-distribution-licenses.mjs';
import { assertNsisGeneration } from './assert-nsis-generation.mjs';
import { assertWindowsRuntime } from './assert-windows-runtime.mjs';
import { checkedWindowsLicenseBuildInputs, windowsLicenseBindingIdentity as bindingIdentity } from './windows-license-build-inputs.mjs';

const hash = data => createHash('sha256').update(data).digest('hex');
function requireValue(condition, reason) { if (!condition) throw new Error(reason); }
function plain(file) {
  const resolved = physicalPath(file); const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'Distribution input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
function exists(file) {
  try { fs.lstatSync(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
function overlap(a, b) {
  const left = physicalPath(a).toLowerCase(); const right = physicalPath(b).toLowerCase();
  return left === right || left.startsWith(right + path.sep) || right.startsWith(left + path.sep);
}

/** Read-only binding check shared by the producer and both Tauri bundle entrances. */
function checkedBuildInputs({ repoRoot, host, version, rustcCommit }) {
  const { repo, assets, binding } = checkedWindowsLicenseBuildInputs({ repoRoot, host, version, rustcCommit });
  const source = path.join(repo, 'winsmux-app/src-tauri');
  const dll = plain(path.join(source, 'nsis/winsmux_nsis_utils.dll'));
  requireValue(hash(dll) === binding.plugin.dll_sha256, 'Source-built NSIS plugin differs.');
  const utils = plain(path.join(source, 'nsis/winsmux-utils.nsh'));
  requireValue(hash(utils) === '9e2259d2226398ff4e69c1b322ce480ccb51df5d65525ac706b2179bd1db92c4'
    && hash(plain(path.join(source, 'nsis/installer.nsi'))) === '1b691a6d9d526a312f95a156e5b52503bd37aa993173e366ebef9db0b66ba9a9',
  'Pinned compiler inputs differ.');
  const hook = plain(path.join(source, 'nsis-installer-hooks.nsh'));
  return { repo, source, assets, binding, dll, utils, hook };
}

// Direct stage, preparation and canonical bundle acceptance share this authority.
function checkedCompanionBytes(row, host) {
  requireValue(path.isAbsolute(row.path) && /^[a-f0-9]{64}$/u.test(row.sha256 ?? ''), 'Frozen companion identity required.');
  const bytes = plain(row.path);
  requireValue(bytes.length > 0 && hash(bytes) === row.sha256, 'Built companion identity differs.');
  assertWindowsRuntime(bytes, host);
  return bytes;
}

function licenseOptions(assets, binding, version) {
  return { policyPath: path.join(assets, 'policy.json'), policySha256: binding.policy_sha256,
    inputPath: path.join(assets, 'input.json'), catalogPath: path.join(assets, 'manifest.json'),
    catalogSha256: binding.catalog_sha256, textRoot: path.join(assets, 'texts'), sourceRoot: assets, version };
}

export function assertCanonicalBundledDistribution({ repoRoot, host, version, rustcCommit, projectOutput }) {
  const { source, assets, binding, hook } = checkedBuildInputs({ repoRoot, host, version, rustcCommit });
  // If the builder holds its exclusive Windows lease, this read fails before Tauri compiles.
  const lease = path.join(source, 'binaries.prepare.lock');
  if (exists(lease)) plain(lease);
  const canonical = path.join(source, 'binaries');
  const manifestBytes = plain(path.join(canonical, 'distribution-manifest.json'));
  const manifest = parseStrictJson(manifestBytes);
  requireValue(manifest.build_profile === 'release', 'Bundling requires a release companion generation.');
  requireValue(manifest.version === version && manifest.host === host
    && JSON.stringify(manifest.plugin) === JSON.stringify(binding.plugin), 'Published generation binding differs.');
  // The mutable outer inventory cannot redefine required license/source/notice bytes.
  // Use the same read-only renderer as staging, including both generated public files.
  const { files } = buildDistributionLicenses(licenseOptions(assets, binding, version));
  const expected = [...files].map(([relative, bytes]) => ({ path: 'licenses/' + relative,
    bytes: bytes.length, sha256: hash(bytes) })).sort((a, b) => a.path.localeCompare(b.path));
  requireValue(Array.isArray(manifest.files), 'Published license inventory is missing.');
  for (const name of ['winsmux', 'winsmux-workspace-mcp']) {
    const relative = `${name}-${host}.exe`;
    const rows = manifest.files.filter(row => row.path === relative);
    requireValue(rows.length === 1 && Number.isSafeInteger(rows[0].bytes) && rows[0].bytes > 0,
      'Published companion inventory is missing or ambiguous.');
    const bytes = checkedCompanionBytes({ path: path.join(canonical, relative), sha256: rows[0].sha256 }, host);
    requireValue(bytes.length === rows[0].bytes, 'Published companion length differs.');
  }
  const received = manifest.files.filter(row => typeof row.path === 'string'
    && row.path.toLowerCase().startsWith('licenses/')).sort((a, b) => a.path.localeCompare(b.path));
  requireValue(JSON.stringify(received) === JSON.stringify(expected),
    'Published license inventory differs from the complete frozen input.');
  for (const [relative, bytes] of files) {
    requireValue(plain(path.join(canonical, 'licenses', relative)).equals(bytes),
      'Published license bytes differ from the complete frozen input.');
  }
  return assertNsisGeneration({ srcTauri: source, projectOutput,
    manifestSha256: hash(manifestBytes), hookSha256: hash(hook) });
}

/** Prepare one new owned generation. The existing canonical generation is never written here. */
export function stageBundledDistribution({ repoRoot, destination, host, version, rustcCommit, buildProfile, companions }) {
  const { repo, source, assets, binding, dll, utils, hook } = checkedBuildInputs({ repoRoot, host, version, rustcCommit });
  requireValue(buildProfile === 'debug' || buildProfile === 'release', 'Selected companion build profile is required.');
  const out = physicalPath(destination);
  requireValue(Array.isArray(companions) && companions.length === 2
    && companions[0]?.name === 'winsmux' && companions[1]?.name === 'winsmux-workspace-mcp',
  'Exactly the CLI and MCP artifacts are required in canonical order.');
  const inputs = companions.map(row => {
    const bytes = checkedCompanionBytes(row, host);
    return { path: `${row.name}-${host}.exe`, bytes };
  });
  const retainedDirectories = [];
  const canonical = path.join(source, 'binaries');
  const owned = name => name === 'distribution-manifest.json' || name === '.distribution.pending' || name === 'winsmux-core.ps1'
    || name === 'nsis' || name.startsWith('nsis/') || name === 'licenses' || name.startsWith('licenses/')
    || inputs.some(row => row.path === name);
  if (exists(canonical)) {
    physicalPath(canonical);
    requireValue(!exists(path.join(canonical, '.distribution.pending'))
      && !exists(path.join(canonical, 'licenses/.licenses.pending')), 'Canonical generation is incomplete.');
    function retain(directory, prefix = '') {
      for (const name of fs.readdirSync(directory)) {
        const relative = prefix + name; const file = path.join(directory, name); const stat = fs.lstatSync(file);
        requireValue(!stat.isSymbolicLink(), 'Linked canonical generation entry is unsupported.');
        if (owned(relative)) continue;
        if (stat.isDirectory()) { retainedDirectories.push(relative); retain(file, relative + '/'); }
        else inputs.push({ path: relative, bytes: plain(file) });
      }
    }
    retain(canonical);
  }
  requireValue(!overlap(companions[0].path, companions[1].path), 'Companion paths alias.');
  requireValue(path.isAbsolute(destination) && !exists(out)
    && fs.statSync(physicalPath(path.dirname(out))).isDirectory(), 'Staging destination must be a new owned child.');
  for (const protectedPath of [assets, path.join(source, 'binaries'), path.join(source, 'nsis'),
    path.join(source, 'nsis-installer-hooks.nsh'), ...binding.sources.map(row => path.join(repo, row.path)),
    ...companions.map(row => row.path)]) {
    requireValue(!overlap(out, protectedPath), 'Staging destination overlaps protected input or the canonical generation.');
  }
  requireValue(!exists(path.join(source, 'binaries.recovery.pending')), 'Canonical generation recovery is pending.');
  fs.mkdirSync(out);
  const marker = path.join(out, '.distribution.pending');
  fs.writeFileSync(marker, JSON.stringify({ version, binding_sha256: bindingIdentity }), { flag: 'wx' });
  const licenseProof = stageDistributionLicenses({ ...licenseOptions(assets, binding, version),
    destination: path.join(out, 'licenses') });
  inputs.push({ path: 'nsis/winsmux-utils.nsh', bytes: utils }, { path: 'nsis/plugins/winsmux_nsis_utils.dll', bytes: dll });
  for (const row of inputs) {
    const file = path.join(out, row.path); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, row.bytes, { flag: 'wx' });
    requireValue(plain(file).equals(row.bytes), 'Distribution staging bytes differ.');
  }
  const files = [...inputs.map(row => ({ path: row.path, bytes: row.bytes.length, sha256: hash(row.bytes) })),
    ...licenseProof.files.map(row => ({ ...row, path: 'licenses/' + row.path }))].sort((a, b) => a.path.localeCompare(b.path));
  const manifest = { schema: 'winsmux-distribution-generation/v1', version, host, build_profile: buildProfile, files, plugin: binding.plugin };
  if (retainedDirectories.length) {
    manifest.retained_directories = retainedDirectories.sort();
    for (const directory of retainedDirectories) fs.mkdirSync(path.join(out, directory), { recursive: true });
  }
  const manifestBytes = Buffer.from(JSON.stringify(manifest, null, 2) + '\n');
  fs.writeFileSync(path.join(out, 'distribution-manifest.json'), manifestBytes, { flag: 'wx' });
  for (const row of files) { const bytes = plain(path.join(out, row.path));
    requireValue(bytes.length === row.bytes && hash(bytes) === row.sha256, 'Completed generation identity differs.'); }
  fs.unlinkSync(marker);
  // Reuse the same compiler input guard without publishing or launching the compiler.
  // The host validates this exact manifest against canonical paths after atomic publication.
  return { status: 'distribution_generation_staged', version, host, binding_sha256: bindingIdentity,
    manifest_sha256: hash(manifestBytes), hook_sha256: hash(hook), files: files.length,
    license_manifest_sha256: licenseProof.manifest_sha256, distribution_complete: false };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    requireValue(process.argv.length === 3, 'Exactly one owned input file is required.');
    console.log(JSON.stringify(stageBundledDistribution(parseStrictJson(plain(process.argv[2])))));
  } catch { console.log(JSON.stringify({ status: 'refused', compiler_launched: false })); process.exitCode = 1; }
}
