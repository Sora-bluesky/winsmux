import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { stageBundledDistribution, assertCanonicalBundledDistribution } from '../../scripts/stage-bundled-distribution.mjs';
import { assertNsisGeneration } from '../../scripts/assert-nsis-generation.mjs';
import { buildDistributionLicenses } from '../../scripts/stage-distribution-licenses.mjs';
import { fixturePe } from './fixture-pe.mjs';

const repo = process.cwd();
const root = path.resolve('.evidence/workspace-package', `bundled-generation-${randomUUID()}`);
fs.mkdirSync(root, { recursive: true });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const binding = JSON.parse(fs.readFileSync('distribution/windows-licenses/binding.json', 'utf8'));
function snapshot(directory) {
  const entries = {};
  function visit(base, prefix = '') {
    for (const name of fs.readdirSync(base)) {
      const file = path.join(base, name); const relative = prefix + name; const stat = fs.lstatSync(file);
      if (stat.isSymbolicLink()) entries[relative] = { link: fs.readlinkSync(file) };
      else if (stat.isDirectory()) { entries[relative + '/'] = 'directory'; visit(file, relative + '/'); }
      else entries[relative] = hash(fs.readFileSync(file));
    }
  }
  visit(directory); return entries;
}
function fixture(name) {
  const directory = path.join(root, name); const input = path.join(directory, 'repo');
  fs.mkdirSync(input, { recursive: true });
  for (const row of binding.sources) { const out = path.join(input, row.path);
    fs.mkdirSync(path.dirname(out), { recursive: true }); fs.copyFileSync(path.join(repo, row.path), out); }
  fs.cpSync(path.join(repo, 'distribution/windows-licenses'), path.join(input, 'distribution/windows-licenses'), { recursive: true });
  fs.cpSync(path.join(repo, 'winsmux-app/src-tauri/nsis'), path.join(input, 'winsmux-app/src-tauri/nsis'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'winsmux-app/src-tauri/nsis-installer-hooks.nsh'), path.join(input, 'winsmux-app/src-tauri/nsis-installer-hooks.nsh'));
  const previous = path.join(input, 'winsmux-app/src-tauri/binaries');
  fs.mkdirSync(previous); fs.writeFileSync(path.join(previous, 'old-exe'), 'existing executable');
  fs.writeFileSync(path.join(previous, 'old-license'), 'existing license generation');
  fs.mkdirSync(path.join(previous, 'unrelated-empty-directory'));
  const artifacts = path.join(directory, 'artifacts'); fs.mkdirSync(artifacts);
  const companions = ['winsmux', 'winsmux-workspace-mcp'].map(name => {
    const bytes = fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic generation ' + name });
    const file = path.join(artifacts, name + '.exe'); fs.writeFileSync(file, bytes);
    return { name, path: file, sha256: hash(bytes) };
  });
  return { directory, input, previous, options: { repoRoot: input, destination: path.join(directory, 'stage'),
    host: binding.host, version: binding.version, rustcCommit: binding.rustc_commit, buildProfile: 'release', companions } };
}
const cases = [];
function run(name, mutate, accepted = false, partialStage = false) {
  const f = fixture(name); mutate?.(f);
  const protectedBefore = snapshot(f.input); const priorBefore = snapshot(f.previous);
  if (accepted) {
    const result = stageBundledDistribution(f.options);
    assert.equal(result.files, 325); assert.equal(result.distribution_complete, false);
    assert.equal(fs.readFileSync(path.join(f.options.destination, 'old-exe'), 'utf8'), 'existing executable');
    assert.equal(fs.readFileSync(path.join(f.options.destination, 'old-license'), 'utf8'), 'existing license generation');
    assert.ok(fs.statSync(path.join(f.options.destination, 'unrelated-empty-directory')).isDirectory());
    assert.ok(!fs.existsSync(path.join(f.options.destination, '.distribution.pending')));
    assert.equal(hash(fs.readFileSync(path.join(f.options.destination, 'distribution-manifest.json'))), result.manifest_sha256);
    // Check the exact staged tree with the compiler guard in an isolated source wrapper.
    const source = path.join(f.directory, 'compile-source'); fs.mkdirSync(source);
    fs.cpSync(path.join(f.input, 'winsmux-app/src-tauri/nsis'), path.join(source, 'nsis'), { recursive: true });
    fs.copyFileSync(path.join(f.input, 'winsmux-app/src-tauri/nsis-installer-hooks.nsh'), path.join(source, 'nsis-installer-hooks.nsh'));
    fs.cpSync(f.options.destination, path.join(source, 'binaries'), { recursive: true });
    const proof = assertNsisGeneration({ srcTauri: source, projectOutput: path.join(f.directory, 'target/release'),
      manifestSha256: result.manifest_sha256, hookSha256: result.hook_sha256 });
    assert.equal(proof.files, 325); assert.equal(proof.compiler_launched, false);
  } else {
    assert.throws(() => stageBundledDistribution(f.options), name);
    if (partialStage) assert.ok(fs.existsSync(path.join(f.options.destination, '.distribution.pending')));
    else if (name !== 'existing-stage') assert.ok(!fs.existsSync(f.options.destination));
  }
  assert.deepEqual(snapshot(f.input), protectedBefore); assert.deepEqual(snapshot(f.previous), priorBefore);
  cases.push({ name, result: 'passed', inputs_and_existing_generation_unchanged: true });
}
run('complete-bound-generation', null, true);
run('complete-debug-generation', f => { f.options.buildProfile = 'debug'; }, true);
run('missing-build-profile', f => { delete f.options.buildProfile; });
run('unknown-build-profile', f => { f.options.buildProfile = 'other'; });
for (const profile of ['debug', 'release']) {
  const f = fixture('actual-profile-' + profile);
  f.options.buildProfile = profile;
  fs.mkdirSync(path.join(f.previous, 'licenses'));
  fs.writeFileSync(path.join(f.previous, 'licenses/stale.txt'), 'old owned license');
  fs.writeFileSync(path.join(f.previous, 'distribution-manifest.json'), 'old manifest');
  stageBundledDistribution(f.options);
  fs.renameSync(f.previous, f.previous + '.backup');
  fs.renameSync(f.options.destination, f.previous);
  const manifestPath = path.join(f.previous, 'distribution-manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath));
  assert.equal(manifest.build_profile, profile);
  assert.ok(!fs.existsSync(path.join(f.previous, 'licenses/stale.txt')));
  for (const output of [path.join(f.directory, 'target/release'), path.join(f.directory, 'target', binding.host, 'release')]) {
    const options = { ...f.options, projectOutput: output };
    const before = snapshot(f.input);
    if (profile === 'release') assert.equal(assertCanonicalBundledDistribution(options).compiler_launched, false);
    else assert.throws(() => assertCanonicalBundledDistribution(options), /release companion generation/u);
    assert.deepEqual(snapshot(f.input), before);
  }
  for (const invalid of [undefined, null, '', 'other']) {
    const invalidManifest = { ...manifest, build_profile: invalid };
    fs.writeFileSync(manifestPath, JSON.stringify(invalidManifest));
    assert.throws(() => assertCanonicalBundledDistribution({ ...f.options, projectOutput: path.join(f.directory, 'target/release') }), /release companion generation/u);
  }
  cases.push({name:'selected-profile-and-bundle-boundary-' + profile, result:'passed', synthetic_executables:true});
}
function invalidRuntime(mode) {
  const bytes = fixturePe({ normal: [mode === 'unknown-api' ? 'api-ms-win-core-review-unknown-l999-9-9.dll' : 'kernel32.dll'],
    delayed: mode === 'unknown-delay-api' ? ['api-ms-win-core-review-unknown-l999-9-9.dll'] : mode === 'unmapped-delay' ? ['user32.dll'] : [] });
  if (mode === 'unmapped-import') bytes.writeUInt32LE(0xfffffff0, 528);
  if (mode === 'unmapped-delay') { bytes.writeUInt32LE(0xfffffff0, 912); bytes.writeUInt32LE(0xfffffff0, 916); }
  if (mode === 'unmapped-iat') bytes.writeUInt32LE(0xfffffff0, 0x80 + 24 + 112 + 12 * 8);
  if (mode === 'partial-iat') bytes.writeUInt32LE(8, 0x80 + 24 + 112 + 12 * 8 + 4);
  return bytes;
}
for (const index of [0, 1]) {
  for (const mode of ['unmapped-import', 'unmapped-delay', 'unknown-api', 'unknown-delay-api', 'unmapped-iat', 'partial-iat']) {
    run('stage-runtime-' + index + '-' + mode, f => {
      const bytes = invalidRuntime(mode), row = f.options.companions[index];
      fs.writeFileSync(row.path, bytes); row.sha256 = hash(bytes);
    });
  }
}
run('declaration-line-endings-only', f => {
  for (const row of binding.sources) { const file = path.join(f.input, row.path);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')); }
}, true);
run('wrong-version', f => { f.options.version = '0.39.0'; });
run('unmeasured-toolchain', f => { f.options.rustcCommit = '0'.repeat(40); });
run('unmeasured-host', f => { f.options.host = 'aarch64-pc-windows-msvc'; });
run('changed-lock', f => fs.appendFileSync(path.join(f.input, 'Cargo.lock'), '\nchanged'));
run('changed-declaration', f => fs.appendFileSync(path.join(f.input, 'core/Cargo.toml'), '\nchanged'));
run('changed-policy-binding', f => fs.appendFileSync(path.join(f.input, 'distribution/windows-licenses/binding.json'), '\n'));
run('changed-catalog-input', f => fs.appendFileSync(path.join(f.input, 'distribution/windows-licenses/input.json'), '\n'));
run('missing-owned-DLL', f => fs.renameSync(path.join(f.input, 'winsmux-app/src-tauri/nsis/winsmux_nsis_utils.dll'), path.join(f.directory, 'parked.dll')));
run('changed-owned-DLL', f => fs.appendFileSync(path.join(f.input, 'winsmux-app/src-tauri/nsis/winsmux_nsis_utils.dll'), 'changed'));
run('missing-MCP', f => { f.options.companions.pop(); });
run('wrong-companion-hash', f => { f.options.companions[1].sha256 = '0'.repeat(64); });
run('companion-alias', f => { f.options.companions[1].path = f.options.companions[0].path; f.options.companions[1].sha256 = f.options.companions[0].sha256; });
run('existing-stage', f => fs.mkdirSync(f.options.destination));
run('stage-overlaps-previous', f => { f.options.destination = path.join(f.previous, 'new'); });
run('pending-canonical-generation', f => fs.writeFileSync(path.join(f.input, 'winsmux-app/src-tauri/binaries.recovery.pending'), 'recovery'));
run('pending-canonical-dangling-link', f => fs.symlinkSync(path.join(f.directory, 'missing'), path.join(f.input, 'winsmux-app/src-tauri/binaries.recovery.pending'), 'junction'));
run('incomplete-canonical-stage', f => fs.writeFileSync(path.join(f.previous, '.distribution.pending'), 'incomplete'));
run('changed-full-text', f => {
  const text = fs.readdirSync(path.join(f.input, 'distribution/windows-licenses/texts'))[0];
  fs.appendFileSync(path.join(f.input, 'distribution/windows-licenses/texts', text), 'changed');
}, false, true);
run('missing-covered-source', f => {
  const source = fs.readdirSync(path.join(f.input, 'distribution/windows-licenses/sources'))[0];
  fs.renameSync(path.join(f.input, 'distribution/windows-licenses/sources', source), path.join(f.directory, source));
}, false, true);
const failing = fixture('owned-stage-write-failure'); const prior = snapshot(failing.previous); const inputs = snapshot(failing.input);
const write = fs.writeFileSync;
try {
  fs.writeFileSync = function (file, ...args) {
    if (String(file).endsWith('winsmux-workspace-mcp-x86_64-pc-windows-msvc.exe')) throw new Error('Injected owned stage failure');
    return write.call(fs, file, ...args);
  };
  assert.throws(() => stageBundledDistribution(failing.options));
} finally { fs.writeFileSync = write; }
assert.ok(fs.existsSync(path.join(failing.options.destination, '.distribution.pending')));
assert.deepEqual(snapshot(failing.previous), prior); assert.deepEqual(snapshot(failing.input), inputs);
cases.push({ name: 'owned-stage-write-failure', result: 'passed', partial_stage_retained: true, inputs_and_existing_generation_unchanged: true });
const canonical = fixture('canonical-compiler-entrance');
stageBundledDistribution(canonical.options);
fs.renameSync(canonical.previous, canonical.previous + '.backup');
fs.renameSync(canonical.options.destination, canonical.previous);
const compilerOptions = { ...canonical.options, projectOutput: path.join(canonical.directory, 'target/release') };
const beforeCanonical = snapshot(canonical.input);
assert.equal(assertCanonicalBundledDistribution(compilerOptions).compiler_launched, false);
assert.deepEqual(snapshot(canonical.input), beforeCanonical);
cases.push({ name: 'canonical-compiler-entrance', result: 'passed', inputs_and_existing_generation_unchanged: true });
const licenseManifest = path.join(canonical.previous, 'licenses/manifest.json');
fs.appendFileSync(licenseManifest, '\nchanged');
const beforeRefusal = snapshot(canonical.input);
assert.throws(() => assertCanonicalBundledDistribution(compilerOptions));
assert.deepEqual(snapshot(canonical.input), beforeRefusal);
cases.push({ name: 'canonical-license-generation-refusal', result: 'passed', inputs_and_existing_generation_unchanged: true });
// F1: a self-consistent outer manifest must never redefine immutable license requirements.
const family = fixture('canonical-license-authority-family');
stageBundledDistribution(family.options);
fs.renameSync(family.previous, family.previous + '.backup');
fs.renameSync(family.options.destination, family.previous);
const assets = path.join(family.input, 'distribution/windows-licenses');
const beforeExpected = snapshot(family.input);
const expected = buildDistributionLicenses({ policyPath: path.join(assets, 'policy.json'), policySha256: binding.policy_sha256,
  inputPath: path.join(assets, 'input.json'), catalogPath: path.join(assets, 'manifest.json'), catalogSha256: binding.catalog_sha256,
  textRoot: path.join(assets, 'texts'), sourceRoot: assets, version: binding.version });
assert.equal(expected.files.size, 319);
for (const [relative, bytes] of expected.files) {
  assert.ok(fs.readFileSync(path.join(family.previous, 'licenses', relative)).equals(bytes), relative);
}
assert.deepEqual(snapshot(family.input), beforeExpected);
const outerPath = path.join(family.previous, 'distribution-manifest.json');
const outerBytes = fs.readFileSync(outerPath);
const outputs = [path.join(family.directory, 'target/release'), path.join(family.directory, 'target', binding.host, 'release')];
for (const projectOutput of outputs) {
  assert.equal(assertCanonicalBundledDistribution({ ...family.options, projectOutput }).compiler_launched, false);
}
cases.push({ name: 'complete-319-file-renderer-and-shared-guard-both-layouts', result: 'passed', files: expected.files.size,
  inputs_and_existing_generation_unchanged: true });
function familyCase(name, mutate) {
  const restore = mutate();
  try {
    const before = snapshot(family.input);
    for (const projectOutput of outputs) {
      assert.throws(() => assertCanonicalBundledDistribution({ ...family.options, projectOutput }), name);
      assert.deepEqual(snapshot(family.input), before);
    }
    cases.push({ name, result: 'passed', both_output_layouts_refused: true, inputs_and_existing_generation_unchanged: true });
  } finally { restore(); fs.writeFileSync(outerPath, outerBytes); }
}
for (const name of ['winsmux', 'winsmux-workspace-mcp']) {
  for (const mode of ['unmapped-import', 'unmapped-delay', 'unknown-api', 'unknown-delay-api', 'unmapped-iat', 'partial-iat']) {
    familyCase('canonical-runtime-' + name + '-' + mode, () => {
      const relative = `${name}-${binding.host}.exe`, file = path.join(family.previous, relative);
      const original = fs.readFileSync(file), bytes = invalidRuntime(mode);
      fs.writeFileSync(file, bytes);
      const manifest = JSON.parse(outerBytes), row = manifest.files.find(row => row.path === relative);
      row.bytes = bytes.length; row.sha256 = hash(bytes); fs.writeFileSync(outerPath, JSON.stringify(manifest));
      return () => fs.writeFileSync(file, original);
    });
  }
}
const textPaths = [...expected.files.keys()].filter(relative => relative.startsWith('texts/')).sort();
const sourcePaths = [...expected.files.keys()].filter(relative => relative.startsWith('sources/')).sort();
const required = [...new Set([textPaths[0], textPaths.at(-1), ...sourcePaths, 'THIRD_PARTY_NOTICES.txt', 'manifest.json'])];
for (const [index, relative] of required.entries()) {
  const file = path.join(family.previous, 'licenses', relative); const original = fs.readFileSync(file);
  const asset = 'licenses/' + relative;
  familyCase('self-consistent-omission-' + index, () => {
    const parked = path.join(family.directory, 'parked-' + index);
    fs.renameSync(file, parked);
    const outer = JSON.parse(outerBytes); outer.files = outer.files.filter(row => row.path !== asset);
    fs.writeFileSync(outerPath, JSON.stringify(outer, null, 2) + '\n');
    return () => fs.renameSync(parked, file);
  });
  familyCase('self-consistent-replacement-' + index, () => {
    const altered = Buffer.from(original); altered[altered.length - 1] ^= 1;
    fs.writeFileSync(file, altered);
    const outer = JSON.parse(outerBytes); const row = outer.files.find(row => row.path === asset);
    row.bytes = altered.length; row.sha256 = hash(altered);
    fs.writeFileSync(outerPath, JSON.stringify(outer, null, 2) + '\n');
    return () => fs.writeFileSync(file, original);
  });
  familyCase('self-consistent-renaming-' + index, () => {
    const renamed = file + '.renamed'; fs.renameSync(file, renamed);
    const outer = JSON.parse(outerBytes); outer.files.find(row => row.path === asset).path += '.renamed';
    fs.writeFileSync(outerPath, JSON.stringify(outer, null, 2) + '\n');
    return () => fs.renameSync(renamed, file);
  });
}
familyCase('self-consistent-extra-license-file', () => {
  const file = path.join(family.previous, 'licenses/extra.txt'); const bytes = Buffer.from('Unexpected license payload');
  fs.writeFileSync(file, bytes);
  const outer = JSON.parse(outerBytes); outer.files.push({ path: 'licenses/extra.txt', bytes: bytes.length, sha256: hash(bytes) });
  outer.files.sort((a, b) => a.path.localeCompare(b.path));
  fs.writeFileSync(outerPath, JSON.stringify(outer, null, 2) + '\n');
  return () => fs.renameSync(file, path.join(family.directory, 'parked-extra.txt'));
});
familyCase('complete-files-with-altered-outer-inventory', () => {
  const outer = JSON.parse(outerBytes); outer.files.find(row => row.path.startsWith('licenses/texts/')).sha256 = '0'.repeat(64);
  fs.writeFileSync(outerPath, JSON.stringify(outer, null, 2) + '\n');
  return () => {};
});
assert.deepEqual(snapshot(family.input), beforeExpected);
fs.writeFileSync(path.join(root, 'result.json'), JSON.stringify({ scope: 'bound generation staging, no compiler or installer execution', passed: cases.length, failed: 0, cases }, null, 2) + '\n');
console.log(JSON.stringify({ result: path.join(root, 'result.json'), passed: cases.length, failed: 0 }));
