import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { assertNsisGeneration } from '../../scripts/assert-nsis-generation.mjs';

const root = path.resolve('.evidence/workspace-package', `nsis-input-check-${randomUUID()}`);
fs.mkdirSync(root, { recursive: true });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const originalSource = path.resolve('winsmux-app/src-tauri');
const options = process.argv.slice(2);
assert.ok(options.length === 0 || (options.length === 4 && options[0] === '--plugin' && options[2] === '--plugin-sha256'));
const realDll = options.length ? fs.readFileSync(options[1]) : Buffer.alloc(128);
if (options.length) assert.equal(hash(realDll), options[3]);
else {
  // Minimal PE header exercises input shape only, with no executable code.
  realDll.writeUInt16LE(0x5a4d, 0); realDll.writeUInt32LE(64, 0x3c);
  realDll.writeUInt32LE(0x4550, 64); realDll.writeUInt16LE(0x14c, 68); realDll.writeUInt16LE(0x2000, 86);
}
function snapshot(directory) {
  const entries = {};
  function visit(base, prefix = '') {
    for (const name of fs.readdirSync(base)) {
      const relative = prefix + name;
      const full = path.join(base, name);
      const stat = fs.lstatSync(full);
      if (stat.isSymbolicLink()) entries[relative] = { link: fs.readlinkSync(full) };
      else if (stat.isDirectory()) { entries[relative + '/'] = 'directory'; visit(full, relative + '/'); }
      else entries[relative] = hash(fs.readFileSync(full));
    }
  }
  visit(directory);
  return entries;
}
function fixture(name) {
  const source = path.join(root, name, 'source');
  fs.mkdirSync(path.join(source, 'nsis'), { recursive: true });
  for (const relative of ['nsis/installer.nsi', 'nsis/winsmux-utils.nsh', 'nsis-installer-hooks.nsh']) {
    fs.copyFileSync(path.join(originalSource, relative), path.join(source, relative));
  }
  const files = {
    'winsmux-x86_64-pc-windows-msvc.exe': Buffer.from('synthetic companion test bytes'),
    'winsmux-workspace-mcp-x86_64-pc-windows-msvc.exe': Buffer.from('synthetic MCP test bytes'),
    'nsis/winsmux-utils.nsh': fs.readFileSync(path.join(source, 'nsis/winsmux-utils.nsh')),
    'nsis/plugins/winsmux_nsis_utils.dll': realDll,
    // These test bytes exercise inventory only. They are not license certification.
    'licenses/manifest.json': Buffer.from('{"synthetic":"license inventory only"}'),
    'licenses/THIRD_PARTY_NOTICES.txt': Buffer.from('synthetic license inventory only'),
  };
  const generation = path.join(source, 'binaries');
  for (const [relative, bytes] of Object.entries(files)) {
    const full = path.join(generation, relative);
    fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes);
  }
  const manifest = { schema: 'winsmux-distribution-generation/v1', version: '0.38.0', build_profile: 'release',
    host: 'x86_64-pc-windows-msvc', files: Object.entries(files).map(([relative, bytes]) =>
      ({ path: relative, bytes: bytes.length, sha256: hash(bytes) })),
    plugin: { source_commit: '13d9edd27b69310e108d6fbd49f90992f8a05390',
      rustc_commit: 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96', lock_sha256: '1'.repeat(64), dll_sha256: hash(realDll) } };
  return { source, generation, manifest, options: { srcTauri: source,
    projectOutput: path.join(root, name, 'output'), manifestSha256: '',
    hookSha256: hash(fs.readFileSync(path.join(source, 'nsis-installer-hooks.nsh'))) } };
}
const cases = [];
function run(name, mutate, accepted = false) {
  const f = fixture(name); mutate?.(f);
  const manifestBytes = Buffer.from(JSON.stringify(f.manifest));
  const manifestFile = path.join(f.generation, 'distribution-manifest.json');
  fs.writeFileSync(manifestFile, manifestBytes); f.options.manifestSha256 = hash(manifestBytes);
  if (name === 'missing-manifest') fs.renameSync(manifestFile, manifestFile + '.missing');
  if (name === 'wrong-manifest-identity') f.options.manifestSha256 = '0'.repeat(64);
  if (name === 'duplicate-json-property') fs.writeFileSync(manifestFile,
    manifestBytes.toString().replace('"files":', '"files":[],"files":'));
  if (name === 'duplicate-json-property') f.options.manifestSha256 = hash(fs.readFileSync(manifestFile));
  const before = snapshot(root);
  if (accepted) { const result = assertNsisGeneration(f.options);
    assert.equal(result.status, 'compiler_inputs_verified');
    assert.equal(result.compiler_launched, false); assert.equal(result.installation_complete, false);
  } else assert.throws(() => assertNsisGeneration(f.options), name);
  assert.deepEqual(snapshot(root), before, `${name}: inputs or outputs changed`);
  cases.push({ name, result: 'passed', expectation: accepted ? 'input-only success' : 'refusal', inputs_unchanged: true });
}
run('complete-frozen-inputs', null, true);
for (const target of ['nsis/plugins/winsmux_nsis_utils.dll', 'nsis/winsmux-utils.nsh',
  'licenses/manifest.json', 'licenses/THIRD_PARTY_NOTICES.txt', 'winsmux-workspace-mcp-x86_64-pc-windows-msvc.exe']) {
  run(`missing-${target.replaceAll('/', '-')}`, f => fs.renameSync(path.join(f.generation, target), path.join(f.generation, target + '.missing')));
  run(`altered-${target.replaceAll('/', '-')}`, f => fs.appendFileSync(path.join(f.generation, target), 'altered'));
}
run('required-license-omitted-from-manifest', f => {
  const target = 'licenses/manifest.json';
  f.manifest.files = f.manifest.files.filter(row => row.path !== target);
  fs.renameSync(path.join(f.generation, target), path.join(root, 'omitted-license.json'));
});
run('unlisted-input', f => fs.writeFileSync(path.join(f.generation, 'stray.dll'), realDll));
run('unlisted-empty-directory', f => fs.mkdirSync(path.join(f.generation, 'stray')));
run('duplicate-case-path', f => f.manifest.files.push({ ...f.manifest.files[0], path: f.manifest.files[0].path.toUpperCase() }));
run('relative-path-escape', f => { f.manifest.files[0].path = '../escape.exe'; });
run('absolute-path', f => { f.manifest.files[0].path = path.join(root, 'outside.exe'); });
run('missing-manifest');
run('wrong-manifest-identity');
run('duplicate-json-property');
run('pending-recovery', f => fs.writeFileSync(path.join(f.source, 'binaries.recovery.pending'), 'recovery'));
run('pending-directory', f => fs.mkdirSync(path.join(f.source, 'binaries.recovery.pending')));
run('license-stage-pending', f => fs.writeFileSync(path.join(f.generation, 'licenses/.licenses.pending'), 'incomplete'));
run('retained-empty-directory', f => {
  fs.mkdirSync(path.join(f.generation, 'preserved-empty')); f.manifest.retained_directories = ['preserved-empty'];
}, true);
run('duplicate-retained-directory', f => {
  fs.mkdirSync(path.join(f.generation, 'preserved-empty')); f.manifest.retained_directories = ['preserved-empty', 'PRESERVED-EMPTY'];
});
run('unlisted-retained-directory', f => { f.manifest.retained_directories = ['missing']; });
run('retained-owned-directory', f => { f.manifest.retained_directories = ['licenses']; });
run('pending-dangling-link', f => fs.symlinkSync(path.join(root, 'missing-marker-target'), path.join(f.source, 'binaries.recovery.pending'), 'junction'));
run('deletion-overlaps-generation', f => { f.options.projectOutput = path.dirname(f.generation); });
run('deletion-nested-in-generation', f => { f.options.projectOutput = path.join(f.generation, 'target'); });
run('deletion-overlaps-template', f => { f.options.projectOutput = f.source; });
run('linked-generation', f => {
  const target = f.generation + '.original'; fs.renameSync(f.generation, target);
  fs.symlinkSync(target, f.generation, 'junction');
});
run('hardlinked-dll', f => {
  const original = path.join(f.generation, 'nsis/plugins/winsmux_nsis_utils.dll');
  fs.linkSync(original, path.join(root, 'dll-hardlink.dll'));
});
run('changed-hook', f => fs.appendFileSync(path.join(f.source, 'nsis-installer-hooks.nsh'), '; changed'));
run('wrong-hook-anchor', f => {
  const hook = path.join(f.source, 'nsis-installer-hooks.nsh');
  fs.writeFileSync(hook, fs.readFileSync(hook, 'utf8').replace('${__FILEDIR__}', '${EXEDIR}'));
  f.options.hookSha256 = hash(fs.readFileSync(hook));
});
run('changed-template', f => fs.appendFileSync(path.join(f.source, 'nsis/installer.nsi'), '; changed'));
run('old-namespace-utils', f => fs.writeFileSync(path.join(f.source, 'nsis/winsmux-utils.nsh'),
  fs.readFileSync(path.join(f.source, 'nsis/winsmux-utils.nsh'), 'utf8').replaceAll('winsmux_nsis_utils::', 'nsis_tauri_utils::')));
run('unknown-plugin-source', f => { f.manifest.plugin.source_commit = '0'.repeat(40); });
run('wrong-DLL-provenance', f => { f.manifest.plugin.dll_sha256 = '0'.repeat(64); });
run('non-PE-DLL', f => {
  const relative = 'nsis/plugins/winsmux_nsis_utils.dll'; const bytes = Buffer.alloc(64);
  fs.writeFileSync(path.join(f.generation, relative), bytes);
  Object.assign(f.manifest.files.find(row => row.path === relative), { bytes: bytes.length, sha256: hash(bytes) });
  f.manifest.plugin.dll_sha256 = hash(bytes);
});
const f = fixture('real-CLI'); const manifestBytes = Buffer.from(JSON.stringify(f.manifest));
fs.writeFileSync(path.join(f.generation, 'distribution-manifest.json'), manifestBytes);
const args = ['scripts/assert-nsis-generation.mjs', '--source', f.source, '--project-output', f.options.projectOutput,
  '--manifest-sha256', hash(manifestBytes), '--hook-sha256', f.options.hookSha256];
const before = snapshot(root);
for (const expected of [0, 1]) {
  if (expected) fs.writeFileSync(path.join(f.source, 'binaries.recovery.pending'), 'pending');
  const current = snapshot(root);
  const child = spawnSync(process.execPath, args, { encoding: 'utf8' });
  assert.equal(child.status, expected); assert.equal(JSON.parse(child.stdout).compiler_launched, false);
  assert.deepEqual(snapshot(root), current);
  cases.push({ name: expected ? 'CLI-refusal' : 'CLI-success', result: 'passed', inputs_unchanged: true });
}
assert.equal(Object.keys(before).length + 1, Object.keys(snapshot(root)).length);
fs.writeFileSync(path.join(root, 'result.json'), JSON.stringify({ scope: 'compiler-inputs-only', passed: cases.length,
  failed: 0, actual_DLL_used: options.length > 0, compiler_launched: false, license_full_terms_certified: false, cases }, null, 2) + '\n');
console.log(JSON.stringify({ result: path.join(root, 'result.json'), passed: cases.length, failed: 0 }));
