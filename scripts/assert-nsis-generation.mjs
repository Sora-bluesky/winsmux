import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const validHash = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).sort().join('\0') === keys.slice().sort().join('\0');
const pinnedTemplate = '1b691a6d9d526a312f95a156e5b52503bd37aa993173e366ebef9db0b66ba9a9';
const pinnedUtils = '9e2259d2226398ff4e69c1b322ce480ccb51df5d65525ac706b2179bd1db92c4';
function requireValue(condition, reason) { if (!condition) throw new Error(reason); }
function plainFile(file) {
  const resolved = physicalPath(file);
  const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'NSIS input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
function localRelative(value) {
  requireValue(typeof value === 'string' && value.length > 0 && !value.includes('\\')
    && !value.split('/').some(part => !part || part === '.' || part === '..')
    && !path.isAbsolute(value) && !/[:\x00-\x1f]/u.test(value), 'Invalid generation-relative path.');
  return value;
}
function overlap(left, right) {
  const a = physicalPath(left).toLowerCase();
  const b = physicalPath(right).toLowerCase();
  return a === b || a.startsWith(b + path.sep) || b.startsWith(a + path.sep);
}
function inventory(root) {
  const files = new Map();
  const directories = new Set();
  function visit(directory, prefix = '') {
    for (const name of fs.readdirSync(directory)) {
      const relative = prefix + name;
      const full = path.join(directory, name);
      const stat = fs.lstatSync(full);
      requireValue(!stat.isSymbolicLink(), 'Linked generation entry is unsupported.');
      if (stat.isDirectory()) { directories.add(relative); visit(full, relative + '/'); }
      else { requireValue(stat.isFile() && stat.nlink === 1, 'Non-plain generation entry.'); files.set(relative, full); }
    }
  }
  visit(root);
  return { files, directories };
}

/** Read-only proof of a caller-frozen generation. It neither launches Tauri nor certifies installation. */
export function assertNsisGeneration({ srcTauri, projectOutput, manifestSha256, hookSha256 }) {
  requireValue(validHash(manifestSha256) && validHash(hookSha256), 'Frozen NSIS identities are required.');
  const source = physicalPath(srcTauri);
  requireValue(fs.statSync(source).isDirectory(), 'Tauri source directory is missing.');
  const generation = path.join(source, 'binaries');
  for (const marker of ['binaries.recovery.pending']) {
    // lstat preserves refusal for dangling links and non-file markers too.
    try { fs.lstatSync(path.join(source, marker)); throw new Error('NSIS generation recovery is pending.'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  requireValue(!fs.existsSync(path.join(generation, 'licenses/.licenses.pending')),
    'License generation is incomplete.');
  const templateFile = path.join(source, 'nsis/installer.nsi');
  const utilsFile = path.join(source, 'nsis/winsmux-utils.nsh');
  const hookFile = path.join(source, 'nsis-installer-hooks.nsh');
  const compileOutputs = ['x86', 'x64', 'arm64'].map(arch => path.join(projectOutput, 'nsis', arch));
  requireValue(path.isAbsolute(projectOutput), 'Tauri project output must be absolute.');
  for (const output of compileOutputs) {
    for (const input of [generation, path.dirname(templateFile), hookFile]) {
      requireValue(!overlap(output, input), 'Tauri compiler deletion overlaps protected NSIS inputs.');
    }
  }
  const template = plainFile(templateFile);
  const utils = plainFile(utilsFile);
  const hook = plainFile(hookFile);
  requireValue(digest(template) === pinnedTemplate && digest(utils) === pinnedUtils,
    'Pinned NSIS compiler source differs.');
  requireValue(digest(hook) === hookSha256, 'Frozen installer hook differs.');
  requireValue(hook.toString('utf8').split(/\r?\n/u)
    .filter(line => line.startsWith('!define WINSMUX_NSIS_INPUTS ')).join('\n')
      === '!define WINSMUX_NSIS_INPUTS "${__FILEDIR__}\\binaries\\nsis"', 'Installer hook generation anchor differs.');
  const manifestFile = path.join(generation, 'distribution-manifest.json');
  const manifestBytes = plainFile(manifestFile);
  requireValue(digest(manifestBytes) === manifestSha256, 'Frozen generation manifest differs.');
  const manifest = parseStrictJson(manifestBytes);
  requireValue((exact(manifest, ['schema', 'version', 'host', 'files', 'plugin'])
    || exact(manifest, ['schema', 'version', 'host', 'files', 'plugin', 'retained_directories']))
    && manifest.schema === 'winsmux-distribution-generation/v1'
    && typeof manifest.version === 'string' && /^\d+\.\d+\.\d+$/u.test(manifest.version)
    && typeof manifest.host === 'string' && /^[A-Za-z0-9_-]+$/u.test(manifest.host)
    && Array.isArray(manifest.files), 'Invalid distribution generation manifest.');
  requireValue(exact(manifest.plugin, ['source_commit', 'rustc_commit', 'lock_sha256', 'dll_sha256'])
    && manifest.plugin.source_commit === '13d9edd27b69310e108d6fbd49f90992f8a05390'
    && /^[a-f0-9]{40}$/u.test(manifest.plugin.rustc_commit)
    && validHash(manifest.plugin.lock_sha256) && validHash(manifest.plugin.dll_sha256), 'Plugin provenance is incomplete.');
  const listed = new Map();
  const expectedDirectories = new Set();
  for (const row of manifest.files) {
    requireValue(exact(row, ['path', 'bytes', 'sha256']) && validHash(row.sha256)
      && Number.isSafeInteger(row.bytes) && row.bytes > 0, 'Invalid generation file identity.');
    const relative = localRelative(row.path);
    const folded = relative.toLowerCase();
    requireValue(folded !== 'distribution-manifest.json' && !listed.has(folded), 'Duplicate or self-listed generation input.');
    listed.set(folded, row);
    const parts = relative.split('/');
    parts.pop();
    while (parts.length) { expectedDirectories.add(parts.join('/')); parts.pop(); }
  }
  const actual = inventory(generation);
  if (Object.hasOwn(manifest, 'retained_directories')) {
    requireValue(Array.isArray(manifest.retained_directories), 'Invalid retained directory inventory.');
    const seen = new Set();
    for (const value of manifest.retained_directories) {
      const relative = localRelative(value);
      requireValue(!seen.has(relative.toLowerCase()) && !/^(?:licenses|nsis)(?:\/|$)/u.test(relative),
        'Duplicate or owned retained directory.');
      seen.add(relative.toLowerCase()); expectedDirectories.add(relative);
    }
  }
  requireValue(actual.files.size === listed.size + 1
    && actual.directories.size === expectedDirectories.size
    && [...actual.directories].every(name => expectedDirectories.has(name)), 'Generation entry inventory differs.');
  for (const [relative, file] of actual.files) {
    if (relative === 'distribution-manifest.json') continue;
    const row = listed.get(relative.toLowerCase());
    requireValue(row?.path === relative, 'Unlisted or differently cased generation input.');
    const bytes = plainFile(file);
    requireValue(bytes.length === row.bytes && digest(bytes) === row.sha256, 'Generation file bytes differ.');
  }
  const required = [
    `winsmux-${manifest.host}.exe`, `winsmux-workspace-mcp-${manifest.host}.exe`,
    'nsis/winsmux-utils.nsh', 'nsis/plugins/winsmux_nsis_utils.dll',
    'licenses/manifest.json', 'licenses/THIRD_PARTY_NOTICES.txt',
  ];
  requireValue(required.every(name => listed.has(name.toLowerCase())), 'Required compiler, companion or license input is missing.');
  requireValue(listed.get('nsis/winsmux-utils.nsh').sha256 === pinnedUtils
    && listed.get('nsis/plugins/winsmux_nsis_utils.dll').sha256 === manifest.plugin.dll_sha256,
    'Generation plugin/include identity differs.');
  const dll = plainFile(path.join(generation, 'nsis/plugins/winsmux_nsis_utils.dll'));
  const pe = dll.length > 64 && dll.readUInt16LE(0) === 0x5a4d ? dll.readUInt32LE(0x3c) : -1;
  requireValue(pe >= 0 && pe + 26 <= dll.length && dll.readUInt32LE(pe) === 0x4550
    && dll.readUInt16LE(pe + 4) === 0x14c && (dll.readUInt16LE(pe + 22) & 0x2000) !== 0,
    'NSIS plugin must be an i686 PE DLL.');
  return { status: 'compiler_inputs_verified', manifest_sha256: manifestSha256,
    version: manifest.version, files: listed.size, plugin_sha256: manifest.plugin.dll_sha256,
    installation_complete: false, compiler_launched: false };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const names = new Map([['--source', 'srcTauri'], ['--project-output', 'projectOutput'],
      ['--manifest-sha256', 'manifestSha256'], ['--hook-sha256', 'hookSha256']]);
    const options = {};
    requireValue(process.argv.length === 10, 'Exactly four option pairs are required.');
    for (let i = 2; i < process.argv.length; i += 2) {
      const name = names.get(process.argv[i]);
      requireValue(name && options[name] === undefined, 'Unknown or duplicate option.');
      options[name] = process.argv[i + 1];
    }
    console.log(JSON.stringify(assertNsisGeneration(options)));
  } catch { console.log(JSON.stringify({ status: 'refused', compiler_launched: false })); process.exitCode = 1; }
}
