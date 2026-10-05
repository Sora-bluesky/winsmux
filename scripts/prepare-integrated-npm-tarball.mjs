import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { gunzipSync } from 'node:zlib';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertPublicationPreparationAllowed } from './integrated-publication-attempt.mjs';

// Prepare final registry bytes once. No install/publish, user configuration,
// lifecycle script, or permission token. Old publication entrances are migrated
// only after their protected journey works with this actual tarball.
const names = ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'];
const digest = (bytes, kind = 'sha256') => createHash(kind).update(bytes).digest('hex');
const requireValue = (value, reason) => { if (!value) throw new Error(reason); };
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const identity = stat => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key])).join(':');
function readPlain(file, expectedSha) {
  const target = physicalPath(file);
  const before = fs.lstatSync(target, { bigint: true });
  requireValue(before.isFile() && !before.isSymbolicLink() && before.nlink === 1n, 'Plain single-link npm input required.');
  const handle = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(handle, { bigint: true });
    const bytes = fs.readFileSync(handle);
    const after = fs.lstatSync(target, { bigint: true });
    requireValue(identity(before) === identity(held) && identity(held) === identity(after), 'npm input changed during observation.');
    const sha256 = digest(bytes);
    requireValue(typeof expectedSha === 'string' && /^[a-f0-9]{64}$/u.test(expectedSha) && sha256 === expectedSha, 'npm input differs from independent SHA observation.');
    return { target, bytes, sha256, identity: identity(after) };
  } finally { fs.closeSync(handle); }
}
function inventory(directory) {
  const target = physicalPath(directory);
  requireValue(fs.lstatSync(target).isDirectory() && JSON.stringify(fs.readdirSync(target).sort()) === JSON.stringify(names), 'Closed five-file npm source inventory required.');
  return target;
}
function noOverlap(first, second) {
  const contains = (a, b) => { const relative = path.relative(a, b); return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative)); };
  requireValue(!contains(first, second) && !contains(second, first), 'npm source/runtime and output namespaces overlap.');
}
function writeNew(file, bytes) {
  const handle = fs.openSync(file, 'wx');
  try { fs.writeFileSync(handle, bytes); fs.fsyncSync(handle); } finally { fs.closeSync(handle); }
}
function octal(bytes) {
  const value = bytes.toString('ascii').replaceAll('\0', '').trim();
  requireValue(/^[0-7]+$/u.test(value), 'Non-octal npm tar field.');
  const result = Number.parseInt(value, 8);
  requireValue(Number.isSafeInteger(result) && result >= 0, 'Unsafe npm tar size.'); return result;
}
function tarText(bytes) {
  const zero = bytes.indexOf(0);
  const textBytes = zero < 0 ? bytes : bytes.subarray(0, zero);
  requireValue([...textBytes].every(byte => byte >= 32 && byte < 127), 'Non-ASCII npm tar path.');
  if (zero >= 0) requireValue(bytes.subarray(zero).every(byte => byte === 0), 'Ambiguous npm tar text.');
  return textBytes.toString('ascii');
}
function packageContract(bytes) {
  const pkg = parseStrictJson(bytes);
  requireValue(exact(pkg, ['name', 'version', 'description', 'license', 'type', 'os', 'files', 'bin', 'repository', 'homepage', 'bugs', 'engines', 'winsmuxReleaseTag'])
    && pkg.name === 'winsmux' && pkg.version === '0.38.0' && pkg.winsmuxReleaseTag === 'v0.38.0' && pkg.type === 'module' && pkg.license === 'Apache-2.0'
    && JSON.stringify(pkg.os) === '["win32"]' && JSON.stringify(pkg.files) === '["README.md","index.mjs","install.ps1","LICENSE"]'
    && exact(pkg.bin, ['winsmux']) && pkg.bin.winsmux === 'index.mjs', 'Integrated npm package contract differs.');
  return pkg;
}
export function verifyIntegratedNpmTarball(bytes, expectedFiles) {
  requireValue(Buffer.isBuffer(bytes) && exact(expectedFiles, names) && names.every(name => Buffer.isBuffer(expectedFiles[name])), 'Exact expected npm bytes required.');
  // The closed five-entry archive bounds decompression by its actual expected
  // file sizes, headers, block padding and two end blocks, not a policy limit.
  const maximum = names.reduce((sum, name) => sum + 512 + Math.ceil(expectedFiles[name].length / 512) * 512, 1024);
  const tar = gunzipSync(bytes, { maxOutputLength: maximum });
  requireValue(tar.length % 512 === 0, 'Incomplete npm tar block.');
  const actual = new Set(); let ended = false;
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every(byte => byte === 0)) {
      requireValue(tar.length - offset >= 1024 && tar.subarray(offset).every(byte => byte === 0), 'npm tar end or trailing bytes differ.');
      ended = true; break;
    }
    const sum = header.reduce((total, byte, index) => total + (index >= 148 && index < 156 ? 32 : byte), 0);
    requireValue(octal(header.subarray(148, 156)) === sum, 'npm tar header checksum differs.');
    const magic = header.subarray(257, 263).toString('ascii');
    requireValue((magic === 'ustar\0' || magic === 'ustar ') && tarText(header.subarray(345, 500)) === ''
      && (header[156] === 0 || header[156] === 48) && tarText(header.subarray(157, 257)) === '', 'Non-regular or extended npm tar entry.');
    const fullName = tarText(header.subarray(0, 100));
    const name = fullName.startsWith('package/') ? fullName.slice(8) : '';
    requireValue(names.includes(name) && !actual.has(name), 'Foreign or duplicate npm tar entry.');
    const size = octal(header.subarray(124, 136));
    requireValue(size === expectedFiles[name].length && offset + 512 + size <= tar.length, 'npm tar file size differs.');
    requireValue(tar.subarray(offset + 512, offset + 512 + size).equals(expectedFiles[name]), 'npm tar actual file bytes differ.');
    const next = offset + 512 + Math.ceil(size / 512) * 512;
    requireValue(tar.subarray(offset + 512 + size, next).every(byte => byte === 0), 'npm tar padding differs.');
    actual.add(name); offset = next;
  }
  requireValue(ended && actual.size === names.length, 'Incomplete npm tar inventory.');
  packageContract(expectedFiles['package.json']);
  return Object.freeze({ sha256: digest(bytes), bytes: bytes.length, files: Object.freeze([...names]), publication_admitted: false });
}

export function prepareIntegratedNpmTarball(contract, { namespaceRoot, sourceDirectory, sources, nodeImage, observedNodeSha256, npmCli, observedNpmCliSha256 }) {
  assertIssuedIntegratedContract(contract);
  return prepareNpmReleaseTarball({ namespaceRoot, sourceDirectory, sources, nodeImage, observedNodeSha256, npmCli, observedNpmCliSha256 });
}

// CI prepares bytes without the private operator originals. This leaf grants
// no stage/adoption/publication authority; the host still enforces all stages.
export function prepareNpmReleaseTarball({ namespaceRoot, sourceDirectory, sources, nodeImage, observedNodeSha256, npmCli, observedNpmCliSha256 }) {
  const root = physicalPath(namespaceRoot), source = inventory(sourceDirectory);
  requireValue(fs.statSync(root).isDirectory(), 'Existing parent-owned npm namespace required.');
  noOverlap(source, root);
  assertPublicationPreparationAllowed(root, '0.38.0');
  requireValue(Array.isArray(sources) && sources.length === names.length && sources.every(row => exact(row, ['path', 'observed_sha256']))
    && JSON.stringify(sources.map(row => row.path).sort()) === JSON.stringify(names), 'Independent npm source SHA inventory required.');
  const snapshots = new Map(sources.map(row => [row.path, readPlain(path.join(source, row.path), row.observed_sha256)]));
  const expectedFiles = Object.fromEntries([...snapshots].map(([name, value]) => [name, value.bytes]));
  // Validate package semantics before any process or output creation.
  packageContract(expectedFiles['package.json']);
  const node = readPlain(nodeImage, observedNodeSha256), cli = readPlain(npmCli, observedNpmCliSha256);
  noOverlap(node.target, root); noOverlap(cli.target, root);
  const attemptRoot = path.join(root, 'v0.38.0', 'npm-' + randomUUID());
  fs.mkdirSync(path.dirname(attemptRoot), { recursive: true }); physicalPath(path.dirname(attemptRoot));
  assertPublicationPreparationAllowed(root, '0.38.0'); fs.mkdirSync(attemptRoot);
  const cache = path.join(attemptRoot, 'cache'), temporary = path.join(attemptRoot, 'temporary');
  fs.mkdirSync(cache); fs.mkdirSync(temporary);
  const userConfig = path.join(attemptRoot, 'user.npmrc'), globalConfig = path.join(attemptRoot, 'global.npmrc');
  writeNew(userConfig, Buffer.alloc(0)); writeNew(globalConfig, Buffer.alloc(0));
  const arguments_ = [cli.target, 'pack', '.', '--ignore-scripts', '--offline', '--no-audit', '--no-fund', '--json',
    '--workspaces=false', '--pack-destination', attemptRoot, '--cache', cache, '--userconfig', userConfig, '--globalconfig', globalConfig];
  // npm enables Node's compilation cache at startup, beneath os.tmpdir().
  // It is unnecessary for these isolated two-command producers. Keep it off
  // in this child environment, including deeply nested Windows trial paths.
  const environment = { PATH: process.env.PATH ?? path.dirname(node.target), TEMP: temporary, TMP: temporary,
    NODE_DISABLE_COMPILE_CACHE: '1' };
  for (const name of ['SystemRoot', 'WINDIR', 'COMSPEC']) if (process.env[name]) environment[name] = process.env[name];
  const npmPackageFile = path.resolve(path.dirname(cli.target), '..', 'package.json');
  const npmPackage = readPlain(npmPackageFile, digest(fs.readFileSync(physicalPath(npmPackageFile))));
  const npmMetadata = parseStrictJson(npmPackage.bytes);
  requireValue(npmMetadata.name === 'npm' && typeof npmMetadata.version === 'string', 'Measured installed npm package required.');
  const version = spawnSync(node.target, [cli.target, '--version', '--offline', '--cache', cache, '--userconfig', userConfig, '--globalconfig', globalConfig],
    { cwd: source, env: environment, windowsHide: true, encoding: 'utf8' });
  writeNew(path.join(attemptRoot, 'npm-version-stdout.txt'), Buffer.from(version.stdout ?? ''));
  writeNew(path.join(attemptRoot, 'npm-version-stderr.txt'), Buffer.from(version.stderr ?? ''));
  requireValue(!version.error && version.status === 0 && version.signal === null && version.stdout.trim() === npmMetadata.version,
    'Actual npm version differs from measured runtime package.');
  const result = spawnSync(node.target, arguments_, { cwd: source, env: environment, windowsHide: true, encoding: 'utf8' });
  writeNew(path.join(attemptRoot, 'npm-stdout.json'), Buffer.from(result.stdout ?? ''));
  writeNew(path.join(attemptRoot, 'npm-stderr.txt'), Buffer.from(result.stderr ?? ''));
  requireValue(!result.error && result.status === 0 && result.signal === null, 'Native npm pack failed; retain original diagnostics.');
  const report = parseStrictJson(Buffer.from(result.stdout));
  requireValue(Array.isArray(report) && report.length === 1 && report[0].name === 'winsmux' && report[0].version === '0.38.0'
    && report[0].filename === 'winsmux-0.38.0.tgz', 'Actual npm pack output identity differs.');
  const file = physicalPath(path.join(attemptRoot, 'winsmux-0.38.0.tgz'));
  const observedArchive = fs.readFileSync(file);
  const archive = readPlain(file, digest(observedArchive)).bytes; const verified = verifyIntegratedNpmTarball(archive, expectedFiles);
  requireValue(report[0].size === archive.length && report[0].shasum === digest(archive, 'sha1')
    && report[0].integrity === `sha512-${createHash('sha512').update(archive).digest('base64')}`
    && report[0].entryCount === names.length && report[0].unpackedSize === names.reduce((sum, name) => sum + expectedFiles[name].length, 0)
    && Array.isArray(report[0].files) && report[0].files.every(row => names.includes(row.path) && row.size === expectedFiles[row.path].length)
    && JSON.stringify(report[0].files.map(row => row.path).sort()) === JSON.stringify(names), 'npm report differs from actual tarball.');
  inventory(source);
  for (const original of [...snapshots.values(), node, cli, npmPackage]) {
    const after = readPlain(original.target, original.sha256);
    requireValue(after.identity === original.identity, 'npm source/runtime changed during pack.');
  }
  assertPublicationPreparationAllowed(root, '0.38.0');
  const receipt = { schema: 'winsmux-integrated-npm-preparation/v1', observed_at: new Date().toISOString(), version: '0.38.0',
    file, sha256: verified.sha256, bytes: verified.bytes, files: [...names], native_exit_code: result.status,
    node_sha256: node.sha256, npm_cli_sha256: cli.sha256, npm_package_sha256: npmPackage.sha256,
    npm_version: version.stdout.trim(), npm_version_exit_code: version.status, node_compile_cache: 'disabled-in-child',
    source_sha256: Object.fromEntries([...snapshots].map(([name, value]) => [name, value.sha256])),
    publication_admitted: false, scope: 'Real local npm pack and exact tarball bytes; no Windows install/public dispatch/native distribution permission claim.' };
  writeNew(path.join(attemptRoot, 'npm-preparation.json'), Buffer.from(JSON.stringify(receipt)));
  return Object.freeze({ ...receipt, files: Object.freeze(receipt.files), source_sha256: Object.freeze(receipt.source_sha256) });
}

/** Verify the actual final archive's Windows entrypoint, not its source folder.
 * This never packs again and never invokes installer mutations or publication.
 */
export function verifyPreparedNpmWindowsEntrypoint({ namespaceRoot, sourceDirectory, sources, archiveFile,
  observedArchiveSha256, nodeImage, observedNodeSha256 }) {
  requireValue(process.platform === 'win32', 'Real Windows npm entrypoint verification required.');
  const root = physicalPath(namespaceRoot), source = inventory(sourceDirectory);
  requireValue(fs.statSync(root).isDirectory(), 'Existing parent-owned npm namespace required.');
  noOverlap(source, root); assertPublicationPreparationAllowed(root, '0.38.0');
  requireValue(Array.isArray(sources) && sources.length === names.length && sources.every(row => exact(row, ['path', 'observed_sha256']))
    && JSON.stringify(sources.map(row => row.path).sort()) === JSON.stringify(names), 'Independent npm source SHA inventory required.');
  const snapshots = new Map(sources.map(row => [row.path, readPlain(path.join(source, row.path), row.observed_sha256)]));
  const expected = Object.fromEntries([...snapshots].map(([name, value]) => [name, value.bytes]));
  const archive = readPlain(archiveFile, observedArchiveSha256), node = readPlain(nodeImage, observedNodeSha256);
  noOverlap(node.target, root);
  const verified = verifyIntegratedNpmTarball(archive.bytes, expected);
  // Keep producer-owned descendants compact without abbreviating the UUID.
  // PowerShell startup also consumes paths below the isolated profile/TEMP.
  const directory = path.join(root, 'v0.38.0', 'w-' + randomUUID().replaceAll('-', ''));
  fs.mkdirSync(path.dirname(directory), { recursive: true }); physicalPath(path.dirname(directory));
  assertPublicationPreparationAllowed(root, '0.38.0'); fs.mkdirSync(directory);
  const extracted = path.join(directory, 'extracted'); fs.mkdirSync(extracted);
  const tar = gunzipSync(archive.bytes);
  for (let offset = 0; offset + 512 <= tar.length && tar[offset] !== 0;) {
    const name = tarText(tar.subarray(offset, offset + 100)).slice(8);
    const size = octal(tar.subarray(offset + 124, offset + 136));
    writeNew(path.join(extracted, name), tar.subarray(offset + 512, offset + 512 + size));
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  inventory(extracted);
  for (const name of names) readPlain(path.join(extracted, name), snapshots.get(name).sha256);
  const environment = { PATH: process.env.PATH ?? path.dirname(node.target) };
  for (const name of ['SystemRoot', 'WINDIR', 'COMSPEC']) if (process.env[name]) environment[name] = process.env[name];
  for (const name of ['TEMP', 'TMP', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA']) {
    const target = path.join(directory, name.toLowerCase()); fs.mkdirSync(target); environment[name] = target;
  }
  const results = [];
  for (const [action, expectedOutput] of [['help', /^Usage: install\.ps1 \[action\]/mu], ['version', /^winsmux 0\.38\.0\r?\n$/u]]) {
    assertPublicationPreparationAllowed(root, '0.38.0');
    const process_ = spawnSync(node.target, [path.join(extracted, 'index.mjs'), action], { env: environment,
      cwd: extracted, windowsHide: true });
    const stdout = process_.stdout ?? Buffer.alloc(0), stderr = process_.stderr ?? Buffer.alloc(0);
    writeNew(path.join(directory, action + '-stdout.txt'), stdout);
    writeNew(path.join(directory, action + '-stderr.txt'), stderr);
    writeNew(path.join(directory, action + '-native.json'), Buffer.from(JSON.stringify({ status: process_.status,
      signal: process_.signal, spawn_error: process_.error ? { code: process_.error.code, message: process_.error.message } : null })));
    requireValue(!process_.error && process_.status === 0 && process_.signal === null && stderr.length === 0
      && expectedOutput.test(new TextDecoder('utf-8', { fatal: true }).decode(stdout)), 'Actual extracted Windows npm entrypoint failed.');
    results.push({ action, native_exit_code: process_.status, stdout_sha256: digest(stdout), stderr_sha256: digest(stderr) });
  }
  inventory(source); inventory(extracted);
  for (const before of [...snapshots.values(), archive, node]) {
    requireValue(readPlain(before.target, before.sha256).identity === before.identity, 'npm input changed during Windows verification.');
  }
  for (const name of names) readPlain(path.join(extracted, name), snapshots.get(name).sha256);
  assertPublicationPreparationAllowed(root, '0.38.0');
  const receipt = { schema: 'winsmux-npm-windows-entrypoint/v1', observed_at: new Date().toISOString(),
    file: archive.target, sha256: verified.sha256, bytes: verified.bytes, node_sha256: node.sha256,
    source_sha256: Object.fromEntries([...snapshots].map(([name, value]) => [name, value.sha256])),
    extracted_directory: extracted, results, publication_admitted: false,
    scope: 'Exact final tarball extracted on Windows; actual help/version only, no install/public dispatch.' };
  writeNew(path.join(directory, 'npm-windows-verification.json'), Buffer.from(JSON.stringify(receipt)));
  return Object.freeze(receipt);
}
