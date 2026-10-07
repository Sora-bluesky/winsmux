import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { physicalPath, checkedPowerShellEnvironment } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertWindowsRuntime } from './assert-windows-runtime.mjs';
import { checkedWindowsLicenseBuildInputs } from './windows-license-build-inputs.mjs';
import { buildDistributionLicenses } from './stage-distribution-licenses.mjs';
import { renderCoreRelease } from './stage-core-release.mjs';
import { coreTargets, bytesHash, readCorePlain, exactCoreObject, requireCore, coreTargetMeasurementIdentity, coreSourceInventory, coreSourceInventoryIdentity } from './build-core-candidate.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const coreFields = ['schema', 'version', 'release_tag', 'target', 'source_commit', 'run_identity',
  'source_inventory_sha256', 'compiler', 'binding_sha256', 'target_measurement_sha256',
  'build_plan_sha256', 'consumer_source_sha256', 'catalog_sha256', 'dependency', 'license_files',
  'executable_sha256', 'files', 'build_origin_verified', 'native_redistribution_verified', 'publication_admitted'];
const helperFields = ['schema', 'version', 'release_tag', 'source_commit', 'run_identity', 'source_inventory_sha256', 'compiler_commit', 'files', 'publication_admitted'];
const coreDirectories = ['winsmux-windows-x64', 'winsmux-windows-arm64'];
const helperDirectory = 'winsmux-remote-helper-linux-x64';
const helperName = helperDirectory;

export function assertCoreHelperImage(raw) {
  requireCore(Buffer.isBuffer(raw) && raw.length >= 64
    && raw.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))
    && raw[4] === 2 && raw[5] === 1 && raw[6] === 1 && raw.readUInt16LE(18) === 62
    && [2, 3].includes(raw.readUInt16LE(16)) && raw.readUInt32LE(20) === 1
    && raw.readUInt16LE(52) === 64, 'Packaged helper is not Linux x64 ELF.');
}

function closedDirectory(directory, names) {
  requireCore(fs.lstatSync(physicalPath(directory)).isDirectory(), 'Candidate artifact directory required.');
  requireCore(JSON.stringify(fs.readdirSync(directory).sort()) === JSON.stringify(names.slice().sort()),
    'Candidate artifact inventory differs.');
}
function checkedFiles(directory, rows, expected) {
  requireCore(Array.isArray(rows) && rows.length === expected.length, 'Exact candidate files required.');
  const files = new Map();
  for (const row of rows) {
    requireCore(exactCoreObject(row, ['path', 'bytes', 'sha256']) && expected.includes(row.path)
      && !files.has(row.path) && Number.isSafeInteger(row.bytes) && row.bytes > 0 && /^[a-f0-9]{64}$/u.test(row.sha256),
      'Invalid candidate file identity.');
    const raw = readCorePlain(path.join(directory, row.path));
    requireCore(raw.length === row.bytes && bytesHash(raw) === row.sha256, 'Candidate file bytes changed.');
    files.set(row.path, raw);
  }
  return files;
}
function identity(receipt, request, version) {
  requireCore(receipt.version === version && receipt.release_tag === request.releaseTag
    && request.releaseTag === 'v' + version && receipt.source_commit === request.sourceCommit
    && receipt.run_identity === request.runIdentity && receipt.publication_admitted === false,
    'Candidate source, run or version differs.');
}
function validateSidecar(executable, zip, asset, target, version, licenseFiles, environment) {
  const consumer = bytesHash(readCorePlain(path.join(repo, 'install.ps1')));
  // Preserve the collection's artifact boundary in the child snapshot; the
  // shared renderer also checks and passes its actual PowerShell environment.
  const result = spawnSync(process.execPath, [fileURLToPath(import.meta.url), 'validate-sidecar'],
    { cwd: repo, env: environment, windowsHide: true, input: JSON.stringify({
      executable: executable.toString('base64'), archive: zip.toString('base64'), version, target }), maxBuffer: 1024 * 1024 });
  requireCore(!result.error && result.signal === null && result.status === 0 && result.stderr.length === 0,
    'Aggregated Core sidecar consumer refused.');
  const receipt = parseStrictJson(result.stdout);
  requireCore(exactCoreObject(receipt, ['schema', 'accepted', 'consumer_source_sha256', 'archive_sha256', 'license_files'])
    && receipt.schema === 'core-bound-sidecar-validation/v1' && receipt.accepted === true
    && receipt.consumer_source_sha256 === consumer && receipt.archive_sha256 === bytesHash(zip)
    && receipt.license_files === licenseFiles, 'Aggregated consumer response differs.');
}

/** Internal read-only child: expected fixed-catalog bytes, not ZIP self-consistency. */
export function validateBoundCoreSidecar(request) {
  requireCore(exactCoreObject(request, ['executable', 'archive', 'version', 'target'])
    && coreTargets.has(request.target) && typeof request.executable === 'string' && typeof request.archive === 'string',
    'Exact bound sidecar validation input required.');
  const childEnvironment = checkedPowerShellEnvironment(repo);
  requireCore(process.env.TEMP === childEnvironment.TEMP && process.env.TMP === childEnvironment.TMP,
    'Bound sidecar child did not inherit the checked temporary environment.');
  const measured = parseStrictJson(readCorePlain(path.join(repo, 'distribution/windows-licenses/core-targets.json')));
  const { licenseOptions } = checkedWindowsLicenseBuildInputs({ repoRoot: repo, host: measured.compiler_host,
    version: request.version, rustcCommit: measured.rustc_commit });
  const executable = Buffer.from(request.executable, 'base64'), archive = Buffer.from(request.archive, 'base64');
  requireCore(executable.toString('base64') === request.executable && archive.toString('base64') === request.archive,
    'Canonical sidecar byte transport required.');
  const { files: licenses } = buildDistributionLicenses(licenseOptions);
  const expected = renderCoreRelease({ version: request.version, target: request.target, executable, licenses });
  requireCore(archive.equals(expected.files.get(coreTargets.get(request.target) + '.licenses.zip')),
    'Core license ZIP differs from the fixed bound generation.');
  return { schema: 'core-bound-sidecar-validation/v1', accepted: true,
    consumer_source_sha256: bytesHash(readCorePlain(path.join(repo, 'install.ps1'))),
    archive_sha256: bytesHash(archive), license_files: licenses.size };
}

/** Returns checked preparation bytes; no final publication authority. */
export function inspectCoreCandidates(request) {
  requireCore(exactCoreObject(request, ['artifactRoot', 'sourceCommit', 'releaseTag', 'runIdentity'])
    && path.isAbsolute(request.artifactRoot) && /^[a-f0-9]{40}$/u.test(request.sourceCommit)
    && /^[A-Za-z0-9._-]+$/u.test(request.runIdentity), 'Exact collection identity required.');
  const root = physicalPath(request.artifactRoot);
  closedDirectory(root, [...coreDirectories, helperDirectory]);
  const version = readCorePlain(path.join(repo, 'VERSION')).toString('utf8').replace(/\r?\n$/u, '');
  const checkout = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8', windowsHide: true });
  requireCore(!checkout.error && checkout.status === 0 && checkout.stdout.trim() === request.sourceCommit,
    'Collection checkout differs from the build source.');
  const binding = bytesHash(readCorePlain(path.join(repo, 'distribution/windows-licenses/binding.json')));
  const measurement = parseStrictJson(readCorePlain(path.join(repo, 'distribution/windows-licenses/core-targets.json')));
  requireCore(bytesHash(readCorePlain(path.join(repo, 'distribution/windows-licenses/core-targets.json'))) === coreTargetMeasurementIdentity,
    'Core measurement source changed.');
  const bound = checkedWindowsLicenseBuildInputs({ repoRoot: repo, host: measurement.compiler_host,
    version, rustcCommit: measurement.rustc_commit });
  requireCore(bytesHash(readCorePlain(bound.licenseOptions.catalogPath)) === bound.binding.catalog_sha256
    && bytesHash(readCorePlain(bound.licenseOptions.policyPath)) === bound.binding.policy_sha256,
    'Collection license catalog or policy differs.');
  const consumer = bytesHash(readCorePlain(path.join(repo, 'install.ps1')));
  const plan = bytesHash(readCorePlain(path.join(repo, 'scripts/windows-distribution-build.mjs')));
  const environment = checkedPowerShellEnvironment(repo, [root]);
  const before = coreSourceInventory();
  const sourceIdentity = coreSourceInventoryIdentity(before);
  const files = new Map(), sidecars = []; let shared = null;
  for (const [index, [target, asset]] of [...coreTargets].entries()) {
    const directory = path.join(root, coreDirectories[index]);
    const expected = [asset, asset + '.licenses.zip', 'SHA256SUMS'];
    closedDirectory(directory, [...expected, 'core-candidate.json']);
    const receipt = parseStrictJson(readCorePlain(path.join(directory, 'core-candidate.json')));
    requireCore(exactCoreObject(receipt, coreFields) && receipt.schema === 'core-ci-candidate/v1' && receipt.target === target,
      'Exact target candidate receipt required.');
    identity(receipt, request, version);
    requireCore(exactCoreObject(receipt.compiler, ['host', 'commit', 'release'])
      && receipt.compiler.host === measurement.compiler_host && receipt.compiler.commit === measurement.rustc_commit
      && receipt.compiler.release === '1.96.0' && receipt.binding_sha256 === binding
      && receipt.target_measurement_sha256 === coreTargetMeasurementIdentity && receipt.build_plan_sha256 === plan
      && receipt.consumer_source_sha256 === consumer && receipt.source_inventory_sha256 === sourceIdentity
      && receipt.catalog_sha256 === bound.binding.catalog_sha256 && receipt.build_origin_verified === true
      && receipt.native_redistribution_verified === false && Number.isSafeInteger(receipt.license_files) && receipt.license_files > 0
      && JSON.stringify(receipt.dependency) === JSON.stringify(measurement.targets[target]), 'Candidate build binding differs.');
    const common = JSON.stringify([receipt.source_inventory_sha256, receipt.compiler, receipt.binding_sha256, receipt.catalog_sha256]);
    requireCore(shared === null || shared === common, 'Core targets came from different sources or toolchains.'); shared = common;
    const own = checkedFiles(directory, receipt.files, expected), executable = own.get(asset), zip = own.get(asset + '.licenses.zip');
    requireCore(receipt.executable_sha256 === bytesHash(executable), 'Candidate executable binding differs.');
    assertWindowsRuntime(executable, target);
    const sums = `${bytesHash(executable)}  ${asset}\n${bytesHash(zip)}  ${asset}.licenses.zip\n`;
    requireCore(own.get('SHA256SUMS').equals(Buffer.from(sums)), 'Core target checksum set differs.');
    sidecars.push([executable, zip, asset, target, version, receipt.license_files, environment]);
    files.set(asset, executable); files.set(asset + '.licenses.zip', zip);
  }
  const helperRoot = path.join(root, helperDirectory);
  closedDirectory(helperRoot, [helperName, 'helper-candidate.json']);
  const helper = parseStrictJson(readCorePlain(path.join(helperRoot, 'helper-candidate.json')));
  requireCore(exactCoreObject(helper, helperFields) && helper.schema === 'core-helper-candidate/v1', 'Exact helper candidate receipt required.');
  identity(helper, request, version);
  requireCore(helper.compiler_commit === measurement.rustc_commit
    && helper.source_inventory_sha256 === sourceIdentity, 'Helper compiler or source differs.');
  const own = checkedFiles(helperRoot, helper.files, [helperName]);
  assertCoreHelperImage(own.get(helperName)); files.set(helperName, own.get(helperName));
  // Complete the closed input inventory before any preparation child is launched.
  for (const parameters of sidecars) validateSidecar(...parameters);
  requireCore(JSON.stringify(before) === JSON.stringify(coreSourceInventory()), 'Collection sources changed during validation.');
  const finalCheckout = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8', windowsHide: true });
  requireCore(!finalCheckout.error && finalCheckout.status === 0 && finalCheckout.stdout.trim() === request.sourceCommit,
    'Collection checkout changed during validation.');
  const checksums = [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([name, raw]) => `${bytesHash(raw)}  ${name}\n`).join('');
  files.set('SHA256SUMS', Buffer.from(checksums));
  return { publication_admitted: false, files };
}

export function collectCoreCandidates(request) {
  const checked = inspectCoreCandidates(request);
  const output = physicalPath(path.join(repo, '.winsmux/build/core-collections', randomUUID()));
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, '.pending'), 'Core collection incomplete\n', { flag: 'wx' });
  for (const [name, raw] of checked.files) {
    fs.writeFileSync(path.join(output, name), raw, { flag: 'wx' });
    requireCore(readCorePlain(path.join(output, name)).equals(raw), 'Core collection readback differs.');
  }
  closedDirectory(output, [...checked.files.keys(), '.pending']);
  for (const [name, raw] of checked.files) requireCore(readCorePlain(path.join(output, name)).equals(raw), 'Completed Core collection bytes differ.');
  fs.unlinkSync(path.join(output, '.pending'));
  return { directory: output, publication_admitted: false,
    files: [...checked.files].map(([name, raw]) => ({ path: name, bytes: raw.length, sha256: bytesHash(raw) })) };
}

/** Owns packaging and the real helper check before writing its receipt. */
export function buildCoreHelperCandidate(request) {
  requireCore(exactCoreObject(request, ['sourceCommit', 'releaseTag', 'runIdentity']) && process.platform === 'linux',
    'Native Linux helper build identity required.');
  const { sourceCommit, releaseTag, runIdentity } = request;
  const commit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8', windowsHide: true });
  const compiler = spawnSync('rustc', ['-vV'], { cwd: repo, encoding: 'utf8', windowsHide: true });
  const version = readCorePlain(path.join(repo, 'VERSION')).toString('utf8').replace(/\r?\n$/u, '');
  requireCore(!commit.error && commit.status === 0 && commit.stdout.trim() === sourceCommit
    && /^[a-f0-9]{40}$/u.test(sourceCommit) && releaseTag === 'v' + version
    && /^[A-Za-z0-9._-]+$/u.test(runIdentity) && !compiler.error && compiler.status === 0, 'Helper build identity differs.');
  const commits = compiler.stdout.split(/\r?\n/u).filter(line => line.startsWith('commit-hash: '));
  requireCore(commits.length === 1 && /^[a-f0-9]{40}$/u.test(commits[0].slice(13)), 'Helper compiler identity missing.');
  const measurement = parseStrictJson(readCorePlain(path.join(repo, 'distribution/windows-licenses/core-targets.json')));
  requireCore(commits[0].slice(13) === measurement.rustc_commit
    && compiler.stdout.split(/\r?\n/u).includes('host: x86_64-unknown-linux-gnu')
    && compiler.stdout.split(/\r?\n/u).includes('release: 1.96.0'), 'Helper compiler host or version differs.');
  const root = physicalPath(path.join(repo, '.winsmux/build/core-helper-ci', randomUUID()));
  fs.mkdirSync(root, { recursive: true });
  const artifact = path.join(root, 'artifact'); fs.mkdirSync(artifact);
  const before = coreSourceInventory();
  for (const [step, script] of [['package', 'package-remote-helper.sh'], ['test', 'test-public-remote-helper.sh']]) {
    const result = spawnSync('bash', [path.join(repo, 'scripts', script), path.join(artifact, helperName)],
      { cwd: repo, maxBuffer: 64 * 1024 * 1024 });
    fs.writeFileSync(path.join(root, step + '.stdout'), result.stdout ?? Buffer.alloc(0), { flag: 'wx' });
    fs.writeFileSync(path.join(root, step + '.stderr'), result.stderr ?? Buffer.alloc(0), { flag: 'wx' });
    requireCore(!result.error && result.signal === null && result.status === 0, 'Helper packaging or native check failed.');
  }
  const after = coreSourceInventory();
  requireCore(JSON.stringify(before) === JSON.stringify(after), 'Helper build sources changed.');
  closedDirectory(artifact, [helperName]);
  const raw = readCorePlain(path.join(artifact, helperName)); assertCoreHelperImage(raw);
  const receipt = { schema: 'core-helper-candidate/v1', version, release_tag: releaseTag, source_commit: sourceCommit,
    run_identity: runIdentity, source_inventory_sha256: coreSourceInventoryIdentity(before), compiler_commit: commits[0].slice(13),
    files: [{ path: helperName, bytes: raw.length, sha256: bytesHash(raw) }], publication_admitted: false };
  const receiptBytes = Buffer.from(JSON.stringify(receipt, null, 2) + '\n');
  fs.writeFileSync(path.join(artifact, 'helper-candidate.json'), receiptBytes, { flag: 'wx' });
  closedDirectory(artifact, [helperName, 'helper-candidate.json']);
  const finalCommit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' });
  requireCore(readCorePlain(path.join(artifact, 'helper-candidate.json')).equals(receiptBytes)
    && readCorePlain(path.join(artifact, helperName)).equals(raw) && !finalCommit.error && finalCommit.status === 0
    && JSON.stringify(before) === JSON.stringify(coreSourceInventory())
    && finalCommit.stdout.trim() === sourceCommit, 'Completed helper candidate differs.');
  return { directory: artifact, receipt };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const mode = process.argv[2];
    if (mode === 'validate-sidecar') {
      requireCore(process.argv.length === 3, 'Internal sidecar validation takes no file selection.');
      console.log(JSON.stringify(validateBoundCoreSidecar(parseStrictJson(fs.readFileSync(0)))));
    } else {
    requireCore((mode === 'collect' && process.argv.length === 7) || (mode === 'helper' && process.argv.length === 6),
      'Usage: collect-core-candidates.mjs collect <directory> <commit> <tag> <run> OR helper <commit> <tag> <run>');
    const args = process.argv.slice(3), directory = mode === 'collect' ? args.shift() : null;
    const [sourceCommit, releaseTag, runIdentity] = args;
    const result = mode === 'helper' ? buildCoreHelperCandidate({ sourceCommit, releaseTag, runIdentity })
      : collectCoreCandidates({ artifactRoot: directory, sourceCommit, releaseTag, runIdentity });
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT,
      `${mode === 'collect' ? 'release_path' : 'artifact_path'}=${result.directory}\n`);
    console.log(JSON.stringify(result));
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
