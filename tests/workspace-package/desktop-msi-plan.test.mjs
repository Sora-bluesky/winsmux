import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { stageBundledDistribution } from '../../scripts/stage-bundled-distribution.mjs';
import { beginDesktopBundle, readDesktopDistributionVersion, stageDesktopMsiPlan, signDesktopMsiAsset, readCompletedSignedBuild } from '../../scripts/stage-desktop-msi-plan.mjs';
import { fixturePe } from './fixture-pe.mjs';

const repo = process.cwd(), root = path.resolve('.evidence/workspace-package', 'desktop-msi-' + randomUUID());
fs.mkdirSync(root, { recursive: true });
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const binding = JSON.parse(fs.readFileSync('distribution/windows-licenses/binding.json'));
const input = path.join(root, 'space 日本語 & fixture'), source = path.join(input, 'winsmux-app/src-tauri');
fs.mkdirSync(input);
const currentAuthorityPath = 'core/crates/winsmux-workspace/src/desktop_current_licenses_v0380.json';
fs.mkdirSync(path.join(input, path.dirname(currentAuthorityPath)), { recursive: true });
fs.copyFileSync(path.join(repo, currentAuthorityPath), path.join(input, currentAuthorityPath));
for (const row of binding.sources) {
  const target = path.join(input, row.path); fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(path.join(repo, row.path), target);
}
for (const relative of ['distribution/windows-licenses', 'winsmux-app/src-tauri/nsis']) {
  fs.cpSync(path.join(repo, relative), path.join(input, relative), { recursive: true });
}
fs.copyFileSync(path.join(repo, 'winsmux-app/src-tauri/nsis-installer-hooks.nsh'), path.join(source, 'nsis-installer-hooks.nsh'));
for (const name of ['tauri.conf.json', 'tauri.ci.conf.json', 'Cargo.toml']) fs.copyFileSync(path.join(repo, 'winsmux-app/src-tauri', name), path.join(source, name));
const build = path.join(root, 'space 日本語 & build', 'release'); fs.mkdirSync(build, { recursive: true });
const companions = ['winsmux', 'winsmux-workspace-mcp'].map(name => {
  const bytes = fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic MSI ' + name });
  const file = path.join(root, name + '.exe'); fs.writeFileSync(file, bytes);
  return { name, path: file, sha256: digest(bytes) };
});
stageBundledDistribution({ repoRoot: input, destination: path.join(root, 'generation'), host: binding.host,
  version: binding.version, rustcCommit: binding.rustc_commit, buildProfile: 'release', companions });
fs.renameSync(path.join(root, 'generation'), path.join(source, 'binaries'));
const gui = path.join(build, 'winsmux-app.exe'); fs.writeFileSync(gui, fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic GUI __TAURI_BUNDLE_TYPE_VAR_MSI' }));
const library = path.join(build, 'winsmux_app_lib.dll'); fs.writeFileSync(library, fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic app library' }));
const options = { repoRoot: input, srcTauri: source, guiPath: gui, host: binding.host, version: binding.version,
  rustcCommit: binding.rustc_commit, projectOutput: build, signed: false };
const planFile = gui + '.winsmux-msi-plan.json', includeFile = gui + '.winsmux-plan.wxi';
const cases = [];
function pass(name) { cases.push({ name, result: 'passed' }); }
function sourceIdentity() {
  const result = {};
  function visit(directory, prefix = '') {
    for (const name of fs.readdirSync(directory)) {
      const file = path.join(directory, name), relative = prefix + name, stat = fs.lstatSync(file);
      if (stat.isDirectory()) visit(file, relative + '/');
      else result[relative] = stat.isSymbolicLink() ? 'link' : digest(fs.readFileSync(file));
    }
  }
  visit(input); return result;
}

// This scope exercises only producer admission; no compiler, signer or installer is launched.
function cargoHandoffCases() {
  const saved = { TEMP: process.env.TEMP, TMP: process.env.TMP };
  const phase = f => f.gui + '.winsmux-bundle-phase.json';
  const identity = file => { const s = fs.lstatSync(file, { bigint: true });
    return { dev: String(s.dev), ino: String(s.ino), nlink: String(s.nlink), sha256: digest(fs.readFileSync(file)) }; };
  const snapshot = f => Object.fromEntries([f.gui, f.library, f.guiPeer, f.dllPeer, phase(f)]
    .filter(file => fs.existsSync(file)).map(file => [file, identity(file)]));
  function fresh({ guiLinks = 2, dllLinks = 2, dll = true, signed = false } = {}) {
    const id = randomUUID(), output = path.join(root, 'cargo 日本語 & ' + id, 'release');
    const temp = path.join(root, 'cargo-temp-' + id); fs.mkdirSync(output, { recursive: true }); fs.mkdirSync(temp);
    process.env.TEMP = temp; process.env.TMP = temp;
    const gui = path.join(output, 'winsmux-app.exe'), library = path.join(output, 'winsmux_app_lib.dll');
    const guiPeer = path.join(output, 'deps/winsmux_app.exe'), dllPeer = path.join(output, 'deps/winsmux_app_lib.dll');
    fs.mkdirSync(path.dirname(guiPeer));
    fs.writeFileSync(gui, fixturePe({ normal: ['kernel32.dll'], marker: 'Cargo GUI __TAURI_BUNDLE_TYPE_VAR_UNK ' + id }));
    if (guiLinks === 2) fs.linkSync(gui, guiPeer);
    if (dll) { fs.writeFileSync(library, fixturePe({ normal: ['kernel32.dll'], marker: 'Cargo DLL ' + id }));
      if (dllLinks === 2) fs.linkSync(library, dllPeer); }
    return { gui, library, guiPeer, dllPeer, temp, output,
      options: { ...options, guiPath: gui, projectOutput: output, signed } };
  }
  function reject(name, f, mutate = () => () => {}) {
    const restore = mutate(), before = snapshot(f);
    try { assert.throws(() => beginDesktopBundle(f.options), name); assert.deepEqual(snapshot(f), before); pass(name); }
    finally { restore(); }
  }
  function admit(name, f) {
    const before = snapshot(f); assert.equal(beginDesktopBundle(f.options).status, 'desktop_bundle_admitted');
    for (const [alias, peer] of [[f.gui, f.guiPeer], [f.library, f.dllPeer]]) if (fs.existsSync(alias)) {
      assert.equal(identity(alias).nlink, '1'); assert.equal(identity(alias).sha256, before[alias].sha256);
      if (before[peer]) { const after = identity(peer); assert.equal(after.dev, before[peer].dev);
        assert.equal(after.ino, before[peer].ino); assert.equal(after.sha256, before[peer].sha256); assert.equal(after.nlink, '1');
        assert.notEqual(identity(alias).ino, after.ino); }
      else assert.equal(identity(alias).ino, before[alias].ino);
    }
    assert.equal(JSON.parse(fs.readFileSync(phase(f))).phase, 'admitted'); pass(name);
  }
  function patchGui(f, tag) { const b = fs.readFileSync(f.gui), prefix = Buffer.from('__TAURI_BUNDLE_TYPE_VAR_');
    b.write(tag, b.indexOf(prefix) + prefix.length, 'ascii'); fs.writeFileSync(f.gui, b); }
  function sealed() {
    const f = fresh({ guiLinks: 1, dllLinks: 1 }); beginDesktopBundle(f.options); patchGui(f, 'MSI');
    const staged = stageDesktopMsiPlan(f.options), s = JSON.parse(fs.readFileSync(phase(f)));
    const artifacts = ['en-US', 'ja-JP'].map(label => {
      const file = path.join(f.output, 'bundle/msi/winsmux_' + binding.version + '_x64_' + label + '.msi');
      fs.mkdirSync(path.dirname(file), { recursive: true }); const b = Buffer.from('synthetic sealed ' + label); fs.writeFileSync(file, b);
      return { output: label, bytes: b.length, sha256: digest(b) };
    });
    s.phase = 'frozen'; s.expected_pre_sign.msi = null;
    s.records = [{ flavor: 'msi', gui_sha256: staged.gui_sha256, plan_sha256: staged.plan_sha256,
      include_sha256: digest(fs.readFileSync(f.gui + '.winsmux-plan.wxi')), compiler_inputs_ready: true, artifacts }];
    fs.writeFileSync(phase(f), JSON.stringify(s, null, 2) + '\n');
    // A new Cargo build legitimately replaces these two aliases after the prior sealed compiler interval.
    fs.unlinkSync(f.gui); fs.unlinkSync(f.library);
    fs.writeFileSync(f.gui, fixturePe({ normal: ['kernel32.dll'], marker: 'Rebuilt GUI __TAURI_BUNDLE_TYPE_VAR_UNK ' + randomUUID() }));
    fs.writeFileSync(f.library, fixturePe({ normal: ['kernel32.dll'], marker: 'Rebuilt DLL ' + randomUUID() }));
    fs.linkSync(f.gui, f.guiPeer); fs.linkSync(f.library, f.dllPeer); return f;
  }
  try {
    for (const [name, config] of [ ['cargo-single-link-without-peers', { guiLinks: 1, dllLinks: 1 }],
      ['cargo-fixed-peers-both-two', {}], ['cargo-mixed-gui-single', { guiLinks: 1 }],
      ['cargo-mixed-dll-single', { dllLinks: 1 }], ['cargo-nsis-without-dll', { dll: false }],
      ['cargo-signed-admission-same-handoff', { signed: true }] ]) admit(name, fresh(config));
    for (const [name, mutation] of [
      ['cargo-missing-fixed-peer', f => fs.renameSync(f.guiPeer, f.guiPeer + '.parked')],
      ['cargo-same-bytes-wrong-peer-id', f => { fs.renameSync(f.guiPeer, f.guiPeer + '.parked'); fs.copyFileSync(f.gui, f.guiPeer); }],
      ['cargo-third-link', f => fs.linkSync(f.gui, path.join(f.output, 'third.exe'))],
      ['cargo-wrong-peer-name', f => fs.renameSync(f.guiPeer, path.join(path.dirname(f.guiPeer), 'other.exe'))],
      ['cargo-orphan-temp', f => fs.writeFileSync(f.library + '.winsmux-cargo-' + randomUUID(), 'orphan')],
      ['cargo-unknown-adjacent', f => fs.writeFileSync(f.gui + '.winsmux-foreign', 'unknown')],
      ['cargo-unknown-top-dll', f => fs.writeFileSync(path.join(f.output, 'other.dll'), 'unknown')],
      ['cargo-unowned-sdk-copy', f => fs.writeFileSync(path.join(f.temp, 'winsmux.exe'), 'unknown')]
    ]) { const f = fresh(); mutation(f); reject(name, f); }
    const reparse = fresh(); fs.renameSync(path.join(reparse.output, 'deps'), path.join(reparse.output, 'real-deps'));
    fs.symlinkSync(path.join(reparse.output, 'real-deps'), path.join(reparse.output, 'deps'), 'junction');
    reject('cargo-reparse-peer-directory', reparse);
    for (const [name, file, replacement] of [
      ['cargo-canonical-before-detach', path.join(source, 'binaries/winsmux-' + binding.host + '.exe'), Buffer.from('tampered')],
      ['cargo-config-before-detach', path.join(source, 'tauri.conf.json'), Buffer.from('{}')]
    ]) reject(name, fresh(), () => { const old = fs.readFileSync(file); fs.writeFileSync(file, replacement); return () => fs.writeFileSync(file, old); });
    const rebuild = sealed(), oldState = fs.readFileSync(phase(rebuild)); admit('cargo-sealed-rebuild-new-gui-dll', rebuild);
    assert.notDeepEqual(fs.readFileSync(phase(rebuild)), oldState);
    for (const kind of ['phase', 'plan', 'include', 'artifact', 'sdk-copy']) {
      const f = sealed();
      if (kind === 'phase') { const s = JSON.parse(fs.readFileSync(phase(f))); s.phase = 'failed'; fs.writeFileSync(phase(f), JSON.stringify(s, null, 2) + '\n'); }
      if (kind === 'plan') fs.appendFileSync(f.gui + '.winsmux-msi-plan.json', ' ');
      if (kind === 'include') fs.appendFileSync(f.gui + '.winsmux-plan.wxi', ' ');
      if (kind === 'artifact') fs.appendFileSync(path.join(f.output, 'bundle/msi/winsmux_' + binding.version + '_x64_en-US.msi'), ' ');
      if (kind === 'sdk-copy') fs.writeFileSync(path.join(f.temp, 'winsmux.exe'), 'foreign');
      reject('cargo-old-' + kind + '-before-detach', f);
    }
    // A failure after the first alias is detached must not publish a phase or reconstruct links.
    const partial = fresh(), partialBefore = snapshot(partial), nativeOpen = fs.openSync;
    fs.openSync = function(file, ...args) { if (String(file).startsWith(partial.library + '.winsmux-cargo-')) throw new Error('synthetic copy fault'); return nativeOpen.call(this, file, ...args); };
    try { assert.throws(() => beginDesktopBundle(partial.options)); } finally { fs.openSync = nativeOpen; }
    assert.equal(fs.existsSync(phase(partial)), false); assert.equal(identity(partial.gui).nlink, '1'); assert.equal(identity(partial.library).nlink, '2');
    assert.equal(identity(partial.guiPeer).ino, partialBefore[partial.guiPeer].ino); pass('cargo-partial-failure-no-phase-and-peer-preserved');
    admit('cargo-partial-mixed-reentry', partial);
    const replace = fresh(), replaceBefore = snapshot(replace), nativeRename = fs.renameSync;
    fs.renameSync = function(from, to) { if (to === replace.gui) throw new Error('synthetic rename fault'); return nativeRename.call(this, from, to); };
    try { assert.throws(() => beginDesktopBundle(replace.options)); } finally { fs.renameSync = nativeRename; }
    assert.deepEqual(snapshot(replace), replaceBefore); assert.equal(fs.readdirSync(replace.output).some(n => n.includes('.winsmux-cargo-')), false);
    pass('cargo-replace-failure-owned-copy-cleaned'); admit('cargo-replace-failure-reentry', replace);
    const foreign = fresh(), foreignBefore = snapshot(foreign); let foreignFile;
    fs.renameSync = function(from, to) { if (to === foreign.gui) {
      const held = from + '.held'; nativeRename.call(this, from, held); fs.writeFileSync(from, 'foreign replacement'); foreignFile = from;
      throw new Error('synthetic foreign replacement'); } return nativeRename.call(this, from, to); };
    try { assert.throws(() => beginDesktopBundle(foreign.options)); } finally { fs.renameSync = nativeRename; }
    assert.deepEqual(snapshot(foreign), foreignBefore); assert.equal(fs.readFileSync(foreignFile, 'utf8'), 'foreign replacement');
    pass('cargo-foreign-temp-preserved'); reject('cargo-foreign-orphan-reentry-refused', foreign);
    const changed = fresh(), changedBefore = snapshot(changed), nativeFsync = fs.fsyncSync;
    fs.fsyncSync = function(fd) { nativeFsync.call(this, fd); fs.writeFileSync(changed.guiPeer, 'changed peer bytes'); };
    try { assert.throws(() => beginDesktopBundle(changed.options)); } finally { fs.fsyncSync = nativeFsync; }
    assert.equal(identity(changed.gui).ino, changedBefore[changed.gui].ino); assert.equal(fs.existsSync(phase(changed)), false);
    pass('cargo-peer-mutation-during-copy-refused');
    const partialWrite = fresh(), nativeWrite = fs.writeFileSync; let orphan;
    fs.writeFileSync = function(file, bytes, ...args) { if (typeof file === 'number') { nativeWrite.call(this, file, Buffer.from('partial')); throw new Error('synthetic short copy'); } return nativeWrite.call(this, file, bytes, ...args); };
    try { assert.throws(() => beginDesktopBundle(partialWrite.options)); } finally { fs.writeFileSync = nativeWrite; }
    orphan = fs.readdirSync(partialWrite.output).find(n => n.includes('.winsmux-cargo-'));
    assert.ok(orphan); assert.equal(fs.readFileSync(path.join(partialWrite.output, orphan), 'utf8'), 'partial');
    pass('cargo-incomplete-owned-copy-preserved'); reject('cargo-incomplete-orphan-reentry-refused', partialWrite);
  } finally { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; }
}
cargoHandoffCases();
if (process.argv.includes('--cargo-handoff-only')) {
  console.log(JSON.stringify({ scope: 'cargo-handoff-only', passed: cases.length, failed: 0, cases,
    compiler_launched: false, signer_launched: false, installer_launched: false, evidence_root: root }));
  process.exit(0);
}

const first = stageDesktopMsiPlan(options), planBytes = fs.readFileSync(planFile), includeBytes = fs.readFileSync(includeFile);
assert.equal(first.plan_sha256, digest(planBytes));
const plan = JSON.parse(planBytes);
const currentLicenses = JSON.parse(fs.readFileSync(path.join(input, currentAuthorityPath))).files;
assert.equal(plan.files.length, currentLicenses.length + 4);
assert.deepEqual(plan.files.filter(row=>row.role==='license').map(({path,bytes,sha256})=>({path,bytes,sha256})).sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0),currentLicenses);
assert.equal(plan.files.find(row => row.role === 'gui').sha256, digest(fs.readFileSync(gui)));
assert.equal(stageDesktopMsiPlan(options).plan_sha256, first.plan_sha256);
assert.deepEqual(fs.readFileSync(includeFile), includeBytes);
assert.ok(includeBytes.toString().includes(' & ') && includeBytes.toString().includes('日本語'));
pass('deterministic-plan-exact-gui-canonical-licenses-and-escaped-paths');
const strayGui = path.join(build, 'stray-gui.exe'); fs.copyFileSync(gui, strayGui);
assert.throws(() => stageDesktopMsiPlan({ ...options, guiPath: strayGui }));
assert.equal(stageDesktopMsiPlan(options).plan_sha256, first.plan_sha256);
pass('stray-gui-refused-and-not-incorporated');
function refuse(name, mutate, optionsChanged = options) {
  const restore = mutate?.() ?? (() => {});
  try {
    const before = sourceIdentity(); assert.throws(() => stageDesktopMsiPlan(optionsChanged), name);
    assert.deepEqual(sourceIdentity(), before); pass(name);
  } finally { restore(); }
}
function alter(file, bytes) {
  const before = fs.readFileSync(file); fs.writeFileSync(file, bytes);
  return () => fs.writeFileSync(file, before);
}
function omit(file) { const parked = file + '.parked'; fs.renameSync(file, parked); return () => fs.renameSync(parked, file); }
for (const [key, value] of [['version', '0.39.0'], ['host', 'aarch64-pc-windows-msvc'], ['rustcCommit', '0'.repeat(40)]])
  refuse('wrong-' + key, null, { ...options, [key]: value });
refuse('tampered-canonical-companion', () => alter(path.join(source, 'binaries/winsmux-' + binding.host + '.exe'), Buffer.from('tampered')));
refuse('missing-gui', () => omit(gui));
refuse('missing-app-library', () => omit(library));
refuse('tampered-gui-after-plan-freeze', () => alter(gui, Buffer.from('new GUI')));
refuse('unknown-existing-plan', () => alter(planFile, Buffer.from('{}')));
refuse('missing-half-pair', () => omit(includeFile));
refuse('unknown-existing-include', () => alter(includeFile, Buffer.from('<Include/>')));
refuse('unknown-adjacent-output', () => {
  const file = gui + '.winsmux-unknown'; fs.writeFileSync(file, 'stray'); return () => fs.unlinkSync(file);
});
const manifestFile = path.join(source, 'binaries/distribution-manifest.json');
for (const kind of ['duplicate', 'case-collision', 'escape', 'unknown-role']) {
  refuse('manifest-' + kind, () => {
    const manifest = JSON.parse(fs.readFileSync(manifestFile));
    if (kind === 'duplicate') manifest.files.push({ ...manifest.files[0] });
    if (kind === 'case-collision') manifest.files.push({ ...manifest.files[0], path: manifest.files[0].path.toUpperCase() });
    if (kind === 'escape') manifest.files[0].path = '../escaped';
    if (kind === 'unknown-role') manifest.files[0].path = 'unknown';
    return alter(manifestFile, Buffer.from(JSON.stringify(manifest)));
  });
}
refuse('extra-source-file', () => { const file = path.join(source, 'binaries/stray'); fs.writeFileSync(file, 'stray'); return () => fs.unlinkSync(file); });
refuse('traversal-input', null, { ...options, guiPath: path.join(build, 'child') + path.sep + '..' + path.sep + 'winsmux-app.exe' });
refuse('overlapping-output', null, { ...options, projectOutput: path.join(source, 'release'), guiPath: path.join(source, 'release/winsmux-app.exe') });
const linked = path.join(root, 'linked-build'); fs.symlinkSync(path.dirname(build), linked, 'junction');
refuse('reparse-input', null, { ...options, projectOutput: path.join(linked, 'release'), guiPath: path.join(linked, 'release/winsmux-app.exe') });
refuse('hardlinked-gui', () => { const hardlink = path.join(root, 'gui-hardlink'); fs.linkSync(gui, hardlink); return () => fs.unlinkSync(hardlink); });
refuse('hardlinked-output-pair', () => { const hardlink = path.join(root, 'plan-hardlink'); fs.linkSync(planFile, hardlink); return () => fs.unlinkSync(hardlink); });
const encodingRepo = path.join(root, "encoding 日本語 & quote's repo");
fs.mkdirSync(path.join(encodingRepo, 'scripts'), { recursive: true });
fs.writeFileSync(path.join(encodingRepo, 'scripts/assert-distribution-version.ps1'),
  'param([string]$RepoRoot,[switch]$AsJson)\n'
  + "@{ build_target_root = (Join-Path $RepoRoot 'release'); code_page = [Console]::OutputEncoding.CodePage } | ConvertTo-Json -Compress\n");
const encodedGate = readDesktopDistributionVersion(encodingRepo, process.env);
assert.equal(encodedGate.build_target_root, path.join(encodingRepo, 'release'));
assert.equal(encodedGate.code_page, 65001);
pass('native-gate-UTF8-roundtrip-space-Japanese-ampersand-apostrophe');

const nativeSpawn = childProcess.spawnSync, savedTemp = process.env.TEMP, savedTmp = process.env.TMP;
const calls = [], signerTemps = []; let active, signHook = null, verifyHook = null, spawnFailure = false, signerStatus = 0;
const phaseFile = file => file + '.winsmux-bundle-phase.json';
function patched(file, tag) {
  const bytes = fs.readFileSync(file), prefix = Buffer.from('__TAURI_BUNDLE_TYPE_VAR_'), at = bytes.indexOf(prefix);
  assert.ok(at >= 0 && bytes.indexOf(prefix, at + 1) < 0); bytes.write(tag, at + prefix.length, 'ascii'); fs.writeFileSync(file, bytes);
}
const callback = asset => signDesktopMsiAsset({ repoRoot: input, assetPath: asset ?? active.gui, signed: active.options.signed });
function fixture(signed = true, dll = true, completedLayout = false) {
  const id = randomUUID(), parent = path.join(root, 'phase 日本語 & ' + id);
  const output = path.join(parent, ...(completedLayout ? ['build', 'release'] : ['release'])), temp = completedLayout ? path.join(parent, 'sdk-temp') : path.join(root, 'temp-' + id);
  fs.mkdirSync(output, { recursive: true }); fs.mkdirSync(temp);
  process.env.TEMP = temp; process.env.TMP = temp;
  const gui = path.join(output, 'winsmux-app.exe'), library = path.join(output, 'winsmux_app_lib.dll');
  const original = fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic original __TAURI_BUNDLE_TYPE_VAR_UNK ' + id });
  fs.writeFileSync(gui, original); if (dll) fs.writeFileSync(library, fixturePe({ normal: ['kernel32.dll'], marker: 'Synthetic library ' + id }));
  active = { gui, library, temp, original, options: { ...options, guiPath: gui, projectOutput: output, signed } };
  calls.length = 0; signHook = null; verifyHook = null; spawnFailure = false; signerStatus = 0; return active;
}
function readState(f = active) { return JSON.parse(fs.readFileSync(phaseFile(f.gui))); }
function copyCompanions(f = active) {
  for (const name of ['winsmux', 'winsmux-workspace-mcp'])
    fs.copyFileSync(path.join(source, 'binaries/' + name + '-' + binding.host + '.exe'), path.join(f.temp, name + '.exe'));
}
function artifact(label, f = active) {
  const relative = label === 'setup' ? 'bundle/nsis/winsmux_' + binding.version + '_x64-setup.exe'
    : 'bundle/msi/winsmux_' + binding.version + '_x64_' + label + '.msi';
  return path.join(f.options.projectOutput, relative);
}
async function finishMsi(order = ['en-US', 'ja-JP']) {
  copyCompanions(); await callback(active.library);
  for (const label of order) { const file = artifact(label); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, 'synthetic container ' + label); await callback(file); }
}
async function frozenMsi(signed = true) {
  const f = fixture(signed); beginDesktopBundle(f.options); patched(f.gui, 'MSI'); await callback(); return f;
}
function tool(f = active) {
  const file = path.join(f.options.projectOutput, 'wix/x64/wix/WixUtilExtension.dll');
  fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, 'synthetic copied tool'); return file;
}
const mockNsisPath = path.join(repo, 'scripts/stage-desktop-nsis-plan.mjs');
const existingNsis = fs.existsSync(mockNsisPath) ? fs.readFileSync(mockNsisPath) : null;
const mockNsis = [
  "import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';",
  "const hash=b=>createHash('sha256').update(b).digest('hex');",
  "export function stageDesktopNsisPlan({guiPath,srcTauri,version,host}) {",
  "const manifest=JSON.parse(fs.readFileSync(path.join(srcTauri,'binaries/distribution-manifest.json')));",
  "const files=manifest.files.filter(r=>r.path.startsWith('licenses/')||r.path.endsWith('-'+host+'.exe')).map(r=>({role:r.path.startsWith('licenses/')?'license':r.path.startsWith('winsmux-workspace-mcp-')?'mcp':'cli',path:r.path.replace('-'+host,''),bytes:r.bytes,sha256:r.sha256}));",
  "const gui=fs.readFileSync(guiPath);files.push({role:'gui',path:'winsmux-app.exe',bytes:gui.length,sha256:hash(gui)});",
  "files.sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);",
  "const plan=Buffer.from(JSON.stringify({schema:'winsmux-desktop-install-plan/v1',flavor:'nsis',version,host,files},null,2)+'\\n');",
  "const planPath=guiPath+'.winsmux-nsis-plan.json',includePath=guiPath+'.winsmux-nsis-plan.nsh',helperPath=path.join(srcTauri,'binaries/winsmux-'+host+'.exe');",
  "const constants={WINSMUX_NSIS_PLAN_PATH:planPath,WINSMUX_NSIS_PLAN_SHA256:hash(plan),WINSMUX_NSIS_HELPER_PATH:helperPath,WINSMUX_NSIS_HELPER_SHA256:files.find(r=>r.role==='cli').sha256,WINSMUX_NSIS_GUI_BYTES:String(gui.length),WINSMUX_NSIS_GUI_SHA256:hash(gui),WINSMUX_NSIS_VERSION:version,WINSMUX_NSIS_HOST:host};",
  "const include=Buffer.from(Object.entries(constants).map(([k,v])=>'!define '+k+' \"'+v+'\"').join('\\n')+'\\n');",
  "fs.writeFileSync(planPath,plan,{flag:'wx'});fs.writeFileSync(includePath,include,{flag:'wx'});",
  "}", ""
].join('\n');
try {
  fs.writeFileSync(mockNsisPath, mockNsis);
  childProcess.spawnSync = (exe, argv, spawnOptions) => {
    assert.equal(spawnOptions.windowsHide, true);
    if (exe === 'rustc') return { status: 0, stdout: 'host: ' + binding.host + '\ncommit-hash: ' + binding.rustc_commit + '\n' };
    assert.equal(exe, 'pwsh');
    if (argv.includes('-EncodedCommand')) {
      const command = Buffer.from(argv[argv.indexOf('-EncodedCommand') + 1], 'base64').toString('utf16le');
      assert.ok(command.includes('[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)'));
      return { status: 0, stdout: Buffer.from(JSON.stringify({ version: binding.version, build_target_root: path.dirname(active.options.projectOutput) })) };
    }
    const asset = argv[argv.indexOf('-AssetPath') + 1], verify = argv.includes('-VerifyOnly');
    const directory = spawnOptions.env.TEMP;
    assert.equal(spawnOptions.env.TMP, directory);
    assert.equal(path.dirname(directory), active.temp);
    assert.match(path.basename(directory), /^winsmux-sign-[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/u);
    const stat = fs.lstatSync(directory, { bigint: true });
    assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && stat.ino > 0n);
    assert.deepEqual(fs.readdirSync(directory), []);
    assert.deepEqual(Object.keys(spawnOptions.env).filter(k => ['TEMP', 'TMP'].includes(k.toUpperCase())).sort(), ['TEMP', 'TMP']);
    for (const [key, value] of Object.entries(process.env)) if (!['TEMP', 'TMP'].includes(key.toUpperCase())) assert.ok(spawnOptions.env[key] === value, 'Signer changed a non-TEMP environment entry.');
    for (const protectedPath of [input, active.options.projectOutput, asset]) {
      const a = directory.toLowerCase(), b = path.resolve(protectedPath).toLowerCase();
      assert.ok(a !== b && !a.startsWith(b + path.sep) && !b.startsWith(a + path.sep));
    }
    assert.equal(process.env.TEMP, active.temp); assert.equal(process.env.TMP, active.temp);
    assert.equal(argv.filter(value => value === '-AssetPath').length, 1);
    assert.equal(argv[argv.indexOf('-AssetPath') + 1], asset);
    signerTemps.push({ directory, sdk_temp_root: active.temp, TEMP: spawnOptions.env.TEMP, TMP: spawnOptions.env.TMP,
      dev: stat.dev.toString(), ino: stat.ino.toString(), plain: true, empty: true, argv: [...argv], asset, verify, parent_env_unchanged: true });
    calls.push({ asset, verify });
    if (spawnFailure) return { error: new Error('synthetic launch failure'), status: null };
    if (!verify) { fs.appendFileSync(asset, '\npublic-synthetic-signature'); signHook?.(asset, directory, spawnOptions); }
    else verifyHook?.(asset, directory, spawnOptions);
    return { status: signerStatus, stdout: '' };
  };
  syncBuiltinESMExports();

  const u = fixture(false); beginDesktopBundle(u.options);
  assert.equal(fs.existsSync(u.gui + '.winsmux-plan.wxi'), false); assert.equal(calls.length, 0);
  await assert.rejects(() => callback()); patched(u.gui, 'MSI');
  const exactPatched = fs.readFileSync(u.gui); fs.appendFileSync(u.gui, 'extra');
  await assert.rejects(() => callback()); fs.writeFileSync(u.gui, exactPatched);
  await callback(); assert.equal(calls.length, 0);
  assert.equal(readState().records[0].compiler_inputs_ready, false);
  await finishMsi(['ja-JP', 'en-US']); assert.equal(calls.length, 0);
  assert.deepEqual(readState().records[0].artifacts.map(row => row.output), ['ja-JP', 'en-US']);
  pass('unsigned-MSI-original-admission-full-postpatch-hash-copies-two-locale-seal');

  const signed = await frozenMsi();
  assert.deepEqual(calls, [{ asset: signed.gui, verify: false }, { asset: signed.library, verify: false }]);
  const signedPlanBytes = fs.readFileSync(signed.gui + '.winsmux-msi-plan.json'), signedPlan = JSON.parse(signedPlanBytes);
  for (const row of signedPlan.files.filter(row => ['gui', 'app_lib'].includes(row.role)))
    assert.equal(row.sha256, digest(fs.readFileSync(path.join(signed.options.projectOutput, row.path))));
  copyCompanions(); await callback(signed.library); await callback(path.join(signed.temp, 'winsmux.exe')); await callback(path.join(signed.temp, 'winsmux-workspace-mcp.exe'));
  await callback(); const copiedTool = tool(); await callback(copiedTool);
  assert.deepEqual(calls.slice(2, 6).map(row => row.verify), [true, true, true, true]);
  assert.equal(calls[6].asset, copiedTool); assert.equal(calls[6].verify, false);
  for (const label of ['en-US', 'ja-JP']) { const file = artifact(label); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, 'container ' + label); await callback(file); await callback(file); assert.equal(calls.at(-1).verify, true); }
  assert.deepEqual(fs.readFileSync(signed.gui + '.winsmux-msi-plan.json'), signedPlanBytes);
  pass('signed-MSI-GUI-DLL-sign-before-plan-later-planned-and-container-VerifyOnly');

  const n = fixture(true, false); beginDesktopBundle(n.options); patched(n.gui, 'NSS'); await callback();
  const nplan = JSON.parse(fs.readFileSync(n.gui + '.winsmux-nsis-plan.json'));
  assert.deepEqual(nplan.files.filter(row => row.role !== 'license').map(row => row.role).sort(), ['cli', 'gui', 'mcp']);
  assert.deepEqual(calls, [{ asset: n.gui, verify: false }]);
  const setup = artifact('setup'); fs.mkdirSync(path.dirname(setup), { recursive: true }); fs.writeFileSync(setup, 'NSIS'); await callback(setup);
  fs.writeFileSync(n.gui, n.original); assert.equal(readState().records[0].artifacts.length, 1);
  pass('NSS-only-null-DLL-three-roles-signs-only-GUI-seals-setup');

  const all = await frozenMsi();
  copyCompanions(); await callback(all.library);
  const allMsiPair = fs.readFileSync(all.gui + '.winsmux-msi-plan.json'), allDll = fs.readFileSync(all.library);
  fs.writeFileSync(all.gui, all.original); patched(all.gui, 'NSS');
  const countPartial = calls.length; await assert.rejects(() => callback()); assert.equal(calls.length, countPartial);
  // Return to the current frozen MSI bytes, complete both output callbacks, then model SDK restore.
  const msiSigned = Buffer.concat([Buffer.from(all.original), Buffer.from('\npublic-synthetic-signature')]);
  const msiAt = msiSigned.indexOf(Buffer.from('__TAURI_BUNDLE_TYPE_VAR_')) + 24; msiSigned.write('MSI', msiAt);
  fs.writeFileSync(all.gui, msiSigned);
  for (const label of ['ja-JP', 'en-US']) { const file = artifact(label); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, 'MSI ' + label); await callback(file); }
  fs.writeFileSync(all.gui, all.original); patched(all.gui, 'NSS'); await callback();
  assert.deepEqual(fs.readFileSync(all.library), allDll);
  assert.deepEqual(fs.readFileSync(all.gui + '.winsmux-msi-plan.json'), allMsiPair);
  assert.deepEqual(readState().records.map(row => row.flavor), ['msi', 'nsis']);
  assert.equal(JSON.parse(fs.readFileSync(all.gui + '.winsmux-nsis-plan.json')).files.some(row => row.role === 'app_lib'), false);
  const nsetup = artifact('setup'); fs.mkdirSync(path.dirname(nsetup), { recursive: true }); fs.writeFileSync(nsetup, 'all NSS'); await callback(nsetup);
  fs.writeFileSync(all.gui, all.original);
  const pairBeforeCycle = fs.readFileSync(all.gui + '.winsmux-msi-plan.json'); patched(all.gui, 'MSI');
  await assert.rejects(() => callback()); assert.deepEqual(fs.readFileSync(all.gui + '.winsmux-msi-plan.json'), pairBeforeCycle);
  fs.writeFileSync(all.gui, all.original);
  pass('MSI-partial-refuses-NSS-complete-restore-original-NSS-three-role-preserves-earlier-payload');

  // Readonly completion consumes the real signed producer state/guards; the
  // signer remains the existing synthetic callback. No cryptographic/native claim.
  const completed = fixture(true, true, true); beginDesktopBundle(completed.options); patched(completed.gui, 'MSI'); await callback();
  const request = { repoRoot: input, projectOutput: completed.options.projectOutput, sdkTempRoot: completed.temp };
  const noMoreSignCalls = () => calls.length;
  assert.throws(() => readCompletedSignedBuild(request));
  await finishMsi(); fs.writeFileSync(completed.gui, completed.original); patched(completed.gui, 'NSS'); await callback();
  const completedSetup = artifact('setup'); fs.mkdirSync(path.dirname(completedSetup), { recursive: true }); fs.writeFileSync(completedSetup, 'signed-completion NSS'); await callback(completedSetup);
  fs.writeFileSync(completed.gui, completed.original);
  const beforeReadCalls = noMoreSignCalls(), completedPhase = fs.readFileSync(phaseFile(completed.gui));
  const observed = readCompletedSignedBuild(request);
  assert.equal(observed.signed, true); assert.deepEqual(observed.pairs.map(row => row.flavor), ['msi', 'nsis']);
  assert.equal(observed.phase.sha256, digest(completedPhase)); assert.equal(noMoreSignCalls(), beforeReadCalls);
  assert.deepEqual(fs.readFileSync(phaseFile(completed.gui)), completedPhase);
  assert.equal(observed.pairs[1].gui.sha256, JSON.parse(fs.readFileSync(completed.gui + '.winsmux-nsis-plan.json')).files.find(row => row.role === 'gui').sha256);
  // Same physical SDK root is bound without inheriting it as this reader's TEMP.
  process.env.TEMP = root; process.env.TMP = root;
  try { assert.equal(readCompletedSignedBuild(request).phase.sha256, observed.phase.sha256); }
  finally { process.env.TEMP = completed.temp; process.env.TMP = completed.temp; }
  for (const mutate of [v => { v.signed = false; }, v => { v.phase = 'failed'; }, v => { v.records.pop(); }, v => { v.records[1].flavor = 'msi'; }, v => { v.records[1].artifacts = []; }, v => { v.generation_manifest_sha256 = '0'.repeat(64); }, v => { v.records[1].gui_sha256 = '0'.repeat(64); }, v => { v.sdk_temp_root = root; }]) {
    const state = JSON.parse(completedPhase); mutate(state); fs.writeFileSync(phaseFile(completed.gui), JSON.stringify(state, null, 2) + '\n');
    try { assert.throws(() => readCompletedSignedBuild(request)); assert.equal(noMoreSignCalls(), beforeReadCalls); }
    finally { fs.writeFileSync(phaseFile(completed.gui), completedPhase); }
  }
  for (const file of [completedSetup, completed.gui + '.winsmux-plan.wxi', completed.gui + '.winsmux-nsis-plan.nsh', path.join(completed.temp, 'winsmux.exe'), path.join(source, 'tauri.ci.conf.json')]) {
    const original = fs.readFileSync(file); fs.appendFileSync(file, 'changed');
    try { assert.throws(() => readCompletedSignedBuild(request)); assert.equal(noMoreSignCalls(), beforeReadCalls); }
    finally { fs.writeFileSync(file, original); }
  }
  for (const wrong of [{ ...request, signed: true }, { ...request, sdkTempRoot: root }, { ...request, projectOutput: root }]) assert.throws(() => readCompletedSignedBuild(wrong));
  pass('completed-signed-readonly-both-formats-full-source-plan-artifact-and-SDK-binding-no-sign-phase-write-or-ambient-TEMP');

  // Exact old predicate preimage from b2f1465a; it rejects this legal completed state.
  const oldInventory = " const roles=[['gui','winsmux-app.exe','pe_gui_original'],['cli','winsmux.exe','pe_cli'],['mcp','winsmux-workspace-mcp.exe','pe_mcp']];if(flavor==='msi')roles.push(['app_lib','winsmux_app_lib.dll','pe_app_lib']);\n const expected=[...licenseRows,...roles.map(([role,name,sourceRole])=>({role,path:name,bytes:sources.get(sourceRole).length,sha256:role==='gui'?record.gui_sha256:digest(sources.get(sourceRole))}))].sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);\n need(JSON.stringify(plan.files)===JSON.stringify(expected),'native_transport_plan_inventory_changed');";
  assert.equal(digest(Buffer.from(oldInventory)), '354e677058df4331689da23b6cb46ac2e0a698d4387b3331a8298abd748d9d10');
  const transportSource=fs.readFileSync(path.join(repo,'scripts/test-public-release.ps1'),'utf8').replaceAll('\r\n','\n'), transportLines=transportSource.split('\n');
  const rowStart=transportLines.findIndex(line=>line.startsWith(" const roles=[['gui'"));
  assert.ok(rowStart>=0);
  const currentInventory=transportLines.slice(rowStart,rowStart+3).join('\n');
  assert.ok(currentInventory.endsWith("need(JSON.stringify(plan.files)===JSON.stringify(expected),'native_transport_plan_inventory_changed');"));
  const currentSigned=transportLines.find(line=>line.startsWith("else for(const flavor of ['msi','nsis'])")&&line.includes('native_transport_signed_gui_row_changed'));
  const currentUnsigned=transportLines.find(line=>line.startsWith('if(!signedProfile)for'));
  assert.equal(digest(Buffer.from(currentUnsigned)), '867773dc6a370a4a2a8df6f6e84d44fec3b7f6d693192a5696ab4518231a7d77');
  const {selectTransportLicenseRows}=await import('../../scripts/desktop-native-nsis-observer.mjs');
  const licenseRows=selectTransportLicenseRows(JSON.parse(fs.readFileSync(path.join(source,'binaries/distribution-manifest.json'))));
  const transportInputs=f=>new Map([['pe_gui_original',fs.readFileSync(f.gui)],['pe_app_lib',fs.readFileSync(f.library)],
    ['pe_cli',fs.readFileSync(path.join(source,'binaries/winsmux-'+binding.host+'.exe'))],
    ['pe_mcp',fs.readFileSync(path.join(source,'binaries/winsmux-workspace-mcp-'+binding.host+'.exe'))]]);
  const transportPlans=f=>Object.fromEntries(['msi','nsis'].map(flavor=>[flavor,JSON.parse(fs.readFileSync(f.gui+'.winsmux-'+flavor+'-plan.json'))]));
  const demandTransport=(value,reason)=>{if(!value)throw Error(reason);};
  const evaluateInventory=(code,f,flavor,signedProfile,completion,need=demandTransport,plans=transportPlans(f),sources=transportInputs(f))=>
    new Function('sources','licenseRows','record','signedProfile','completion','plans','flavor','plan','digest','need',code+'\nreturn expected;')
      (sources,licenseRows,readState(f).records.find(row=>row.flavor===flavor),signedProfile,completion,plans,flavor,plans[flavor],digest,need);
  const evaluateSigned=(completion,plans)=>new Function('completion','plans','need','if(false){} '+currentSigned)(completion,plans,demandTransport);
  const signedOperands=[];
  for(const flavor of ['msi','nsis']){
    const planned=transportPlans(completed)[flavor],originalLength=fs.readFileSync(completed.gui).length;
    const signedGui=planned.files.find(row=>row.role==='gui');
    assert.equal(signedGui.bytes-originalLength,27);
    const outcomes=[];const beforeExpected=evaluateInventory(oldInventory,completed,flavor,true,observed,(value,reason)=>outcomes.push({value,reason}));
    assert.deepEqual(beforeExpected.filter(row=>row.role!=='gui'),planned.files.filter(row=>row.role!=='gui'));
    assert.equal(outcomes.length,1);assert.equal(outcomes[0].value,false);
    assert.equal(beforeExpected.find(row=>row.role==='gui').sha256,signedGui.sha256);
    assert.throws(()=>evaluateInventory(oldInventory,completed,flavor,true,observed),/native_transport_plan_inventory_changed/);
    assert.deepEqual(evaluateInventory(currentInventory,completed,flavor,true,observed),planned.files);
    signedOperands.push({flavor,original_bytes:originalLength,plan_gui_bytes:signedGui.bytes,completed_gui_bytes:observed.pairs.find(row=>row.flavor===flavor).gui.bytes,
      non_gui_exact:true,old_inventory_refused:true,repaired_inventory_passed:true});
  }
  evaluateSigned(observed,transportPlans(completed));
  for(const flavor of ['msi','nsis'])for(const [key,value] of [['role','other'],['path','other.exe'],['bytes',1],['sha256','0'.repeat(64)]]){
    const altered=structuredClone(observed);altered.pairs.find(row=>row.flavor===flavor).gui[key]=value;
    assert.throws(()=>evaluateSigned(altered,transportPlans(completed)),/native_transport_signed_gui_row_changed/);
  }
  const damagedSources=transportInputs(completed);damagedSources.set('pe_cli',Buffer.concat([damagedSources.get('pe_cli'),Buffer.from('changed')]));
  assert.throws(()=>evaluateInventory(currentInventory,completed,'msi',true,observed,demandTransport,transportPlans(completed),damagedSources),/native_transport_plan_inventory_changed/);
  const damagedPlan=transportPlans(completed);damagedPlan.nsis.files.find(row=>row.role==='license').bytes++;
  assert.throws(()=>evaluateInventory(currentInventory,completed,'nsis',true,observed,demandTransport,damagedPlan),/native_transport_plan_inventory_changed/);
  cases.push({name:'signed-transport-exact-old-rejects-legal-growth-repaired-both-flavors-full-row-tamper-refused',result:'passed',operands:signedOperands,
    scope:'Original source-extracted predicate over actual producer synthetic signed state. Not the unobserved CI operand values.'});
  const unsignedTransport=await frozenMsi(false);await finishMsi();fs.writeFileSync(unsignedTransport.gui,unsignedTransport.original);patched(unsignedTransport.gui,'NSS');await callback();
  const unsignedSetup=artifact('setup');fs.mkdirSync(path.dirname(unsignedSetup),{recursive:true});fs.writeFileSync(unsignedSetup,'unsigned transport fixture');await callback(unsignedSetup);
  fs.writeFileSync(unsignedTransport.gui,unsignedTransport.original);
  for(const flavor of ['msi','nsis']){
    assert.deepEqual(evaluateInventory(currentInventory,unsignedTransport,flavor,false,null),evaluateInventory(oldInventory,unsignedTransport,flavor,false,null));
    assert.equal(transportPlans(unsignedTransport)[flavor].files.find(row=>row.role==='gui').bytes,unsignedTransport.original.length);
  }
  const original=unsignedTransport.original,marker=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_'),at=original.indexOf(marker),phase=readState(unsignedTransport);
  new Function('signedProfile','original','marker','at','phase','digest','need',currentUnsigned)(false,original,marker,at,phase,digest,demandTransport);
  const changedUnsigned=transportPlans(unsignedTransport);changedUnsigned.msi.files.find(row=>row.role==='gui').bytes++;
  assert.throws(()=>evaluateInventory(currentInventory,unsignedTransport,'msi',false,null,demandTransport,changedUnsigned),/native_transport_plan_inventory_changed/);
  pass('unsigned-transport-original-size-and-exact-three-byte-marker-hash-projection-unchanged');


  for (const mode of ['foreign', 'hardlink', 'case', 'linked']) {
    const f = fixture(false), dest = path.join(f.temp, mode === 'case' ? 'WINSMUX.EXE' : 'winsmux.exe');
    const bytes = Buffer.from('foreign-copy-destination'); fs.writeFileSync(dest, bytes);
    let extra = null;
    if (mode === 'hardlink') { extra = path.join(root, 'hard-' + randomUUID()); fs.linkSync(dest, extra); }
    if (mode === 'linked') { fs.unlinkSync(dest); fs.rmdirSync(f.temp); extra = path.join(root, 'linked-temp-' + randomUUID());
      fs.mkdirSync(extra); fs.writeFileSync(path.join(extra, 'winsmux.exe'), bytes); fs.symlinkSync(extra, f.temp, 'junction'); }
    assert.throws(() => beginDesktopBundle(f.options)); assert.equal(calls.length, 0);
    assert.deepEqual(fs.readFileSync(dest), bytes); assert.equal(fs.existsSync(phaseFile(f.gui)), false);
    if (extra && mode === 'hardlink') fs.unlinkSync(extra);
    pass('pre-copy-destination-' + mode + '-refused-foreign-bytes-preserved');
  }
  const tempMismatch = fixture(false); process.env.TMP = root;
  assert.throws(() => beginDesktopBundle(tempMismatch.options)); process.env.TMP = tempMismatch.temp;
  pass('parent-TEMP-TMP-effective-physical-root-mismatch-refused');
  for (const kind of ['missing', 'duplicate', 'patched', 'unknown']) {
    const f = fixture(false);
    if (kind === 'missing') fs.writeFileSync(f.gui, 'no marker');
    if (kind === 'duplicate') fs.appendFileSync(f.gui, '__TAURI_BUNDLE_TYPE_VAR_UNK');
    if (kind === 'patched') patched(f.gui, 'MSI'); if (kind === 'unknown') patched(f.gui, 'BAD');
    assert.throws(() => beginDesktopBundle(f.options)); assert.equal(calls.length, 0);
    pass('original-GUI-' + kind + '-refused');
  }
  for (const kind of ['dll', 'msm', 'resource', 'binary']) {
    const f = fixture(), cfgPath = path.join(source, 'tauri.conf.json'), cfgBefore = fs.readFileSync(cfgPath);
    let extra;
    if (kind === 'dll' || kind === 'msm') { extra = path.join(f.options.projectOutput, kind === 'dll' ? 'extra.dll' : 'extra.msm'); fs.writeFileSync(extra, 'extra'); }
    else { const cfg = JSON.parse(cfgBefore); if (kind === 'resource') cfg.bundle.resources.extra = 'extra'; else cfg.bundle.externalBin.push('binaries/extra');
      fs.writeFileSync(cfgPath, JSON.stringify(cfg)); }
    try { assert.throws(() => beginDesktopBundle(f.options)); assert.equal(calls.length, 0); }
    finally { fs.writeFileSync(cfgPath, cfgBefore); if (extra) fs.unlinkSync(extra); }
    pass('unplanned-' + kind + '-refused-before-signing');
  }
  const noDll = fixture(true, false); beginDesktopBundle(noDll.options); patched(noDll.gui, 'MSI');
  await assert.rejects(() => callback()); assert.equal(calls.length, 0); pass('MSI-null-DLL-refused-before-signing');

  const immutable = fixture(); beginDesktopBundle(immutable.options);
  for (const name of ['winsmux', 'winsmux-workspace-mcp']) await callback(path.join(source, 'binaries/' + name + '-' + binding.host + '.exe'));
  assert.deepEqual(calls.map(row => row.verify), [true, true]);
  for (const member of ['licenses/manifest.json', 'nsis/winsmux-utils.nsh', 'nsis/plugins/winsmux_nsis_utils.dll']) {
    const count = calls.length; await assert.rejects(() => callback(path.join(source, 'binaries', member))); assert.equal(calls.length, count);
  }
  const unknownCanonical = path.join(source, 'binaries/foreign.dll'); fs.writeFileSync(unknownCanonical, 'foreign');
  try { await assert.rejects(() => callback(unknownCanonical)); assert.equal(calls.length, 2); } finally { fs.unlinkSync(unknownCanonical); }
  pass('canonical-companions-VerifyOnly-license-control-and-unknown-namespace-never-mutating-signer');

  const missingCopies = await frozenMsi();
  await assert.rejects(() => callback(missingCopies.library)); assert.equal(calls.length, 2);
  assert.equal(readState().phase, 'failed'); pass('MSI-copy-missing-refused-before-candle-and-later-sign');
  for (const name of ['winsmux.exe', 'winsmux-workspace-mcp.exe']) {
    const f = await frozenMsi(); copyCompanions(); const dest = path.join(f.temp, name); fs.appendFileSync(dest, 'wrong');
    await assert.rejects(() => callback(f.library)); assert.equal(calls.length, 2); assert.equal(readState().phase, 'failed');
    pass('MSI-compiler-copy-' + name + '-fullhash-tamper-refused');
  }
  const alias = await frozenMsi(), aliasFile = path.join(root, 'alias/release/winsmux-app.exe');
  fs.mkdirSync(path.dirname(aliasFile), { recursive: true }); fs.copyFileSync(alias.gui, aliasFile);
  await assert.rejects(() => callback(aliasFile)); assert.equal(calls.length, 2); pass('same-basename-same-hash-other-physical-GUI-refused');

  for (const sibling of ['gui', 'app_lib', 'cli', 'mcp', 'license', 'control', 'plan', 'include', 'copy-cli', 'copy-mcp']) {
    const f = await frozenMsi(); copyCompanions(); await callback(f.library); const copied = tool();
    const planPath = f.gui + '.winsmux-msi-plan.json', retained = fs.readFileSync(planPath);
    const target = sibling === 'gui' ? f.gui : sibling === 'app_lib' ? f.library
      : sibling === 'cli' ? path.join(source, 'binaries/winsmux-' + binding.host + '.exe')
      : sibling === 'mcp' ? path.join(source, 'binaries/winsmux-workspace-mcp-' + binding.host + '.exe')
      : sibling === 'license' ? path.join(source, 'binaries/licenses/THIRD_PARTY_NOTICES.txt')
      : sibling === 'control' ? path.join(source, 'binaries/nsis/winsmux-utils.nsh')
      : sibling === 'plan' ? planPath : sibling === 'include' ? f.gui + '.winsmux-plan.wxi'
      : path.join(f.temp, sibling === 'copy-cli' ? 'winsmux.exe' : 'winsmux-workspace-mcp.exe');
    const originalTarget = fs.readFileSync(target);
    signHook = () => fs.appendFileSync(target, 'injected sibling mutation');
    try {
      await assert.rejects(() => callback(copied)); assert.equal(readState().phase, 'failed');
      assert.equal(fs.readFileSync(target).equals(originalTarget), false);
      if (sibling !== 'plan') assert.deepEqual(fs.readFileSync(planPath), retained);
    } finally { fs.writeFileSync(target, originalTarget); signHook = null; }
    pass('signer-side-' + sibling + '-mutation-refused-no-plan-refresh');
  }
  const already = fixture(); beginDesktopBundle(already.options);
  const cliSource = path.join(source, 'binaries/winsmux-' + binding.host + '.exe'), cliBefore = fs.readFileSync(cliSource);
  fs.appendFileSync(cliSource, 'already corrupt');
  try { await assert.rejects(() => callback(cliSource)); assert.equal(calls.length, 0); }
  finally { fs.writeFileSync(cliSource, cliBefore); }
  pass('already-tampered-canonical-companion-refused-before-any-signer');
  const changedArtifact = await frozenMsi(); await finishMsi();
  const frozenPlan = fs.readFileSync(changedArtifact.gui + '.winsmux-msi-plan.json'), countArtifact = calls.length;
  fs.appendFileSync(artifact('en-US'), 'changed');
  await assert.rejects(() => callback(artifact('en-US'))); assert.equal(calls.length, countArtifact);
  assert.deepEqual(fs.readFileSync(changedArtifact.gui + '.winsmux-msi-plan.json'), frozenPlan);
  pass('changed-recorded-artifact-refused-before-resigning');

  const rebuild = await frozenMsi(false); await finishMsi(); const oldPair = fs.readFileSync(rebuild.gui + '.winsmux-msi-plan.json');
  fs.writeFileSync(rebuild.gui, Buffer.concat([rebuild.original, Buffer.from('fresh build')])); fs.appendFileSync(rebuild.library, 'fresh library');
  beginDesktopBundle(rebuild.options);
  assert.equal(fs.existsSync(rebuild.gui + '.winsmux-plan.wxi'), false); assert.equal(fs.existsSync(rebuild.gui + '.winsmux-msi-plan.json'), false);
  const retired = readState(), backupPrefix = rebuild.gui + '.winsmux-bundle-old-' + retired.invocation_id + '-msi';
  assert.deepEqual(fs.readFileSync(backupPrefix + '-plan'), oldPair);
  assert.throws(() => stageDesktopMsiPlan(rebuild.options)); assert.equal(readState().phase, 'admitted');
  patched(rebuild.gui, 'MSI'); await callback(); await finishMsi();
  assert.equal(readState().prior_pairs.length, 0); assert.equal(fs.existsSync(backupPrefix + '-plan'), false);
  pass('new-ordinary-rebuild-retires-old-publicpair-new-GUI-DLL-legal-no-callback-no-stale-include');

  // Reuse the completed both-flavor fixture, model a rebuild into MSI only, then carry its unused NSS pair once.
  active = all; process.env.TEMP = all.temp; process.env.TMP = all.temp; calls.length = 0;
  fs.writeFileSync(all.gui, all.original); beginDesktopBundle(all.options);
  assert.equal(fs.existsSync(all.gui + '.winsmux-nsis-plan.nsh'), false);
  patched(all.gui, 'MSI'); await callback(); await finishMsi();
  const withUnused = readState(); assert.deepEqual(withUnused.prior_pairs.map(row => row.flavor), ['nsis']);
  const oldNssBackup = all.gui + '.winsmux-bundle-old-' + withUnused.invocation_id + '-nsis-plan', oldNssBytes = fs.readFileSync(oldNssBackup);
  fs.writeFileSync(all.gui, all.original); beginDesktopBundle(all.options);
  const nextUnused = readState(), newNssBackup = all.gui + '.winsmux-bundle-old-' + nextUnused.invocation_id + '-nsis-plan';
  assert.notEqual(nextUnused.invocation_id, withUnused.invocation_id);
  assert.equal(fs.existsSync(oldNssBackup), false); assert.deepEqual(fs.readFileSync(newNssBackup), oldNssBytes);
  assert.equal(nextUnused.prior_pairs.length, 2);
  pass('unused-old-NSS-backup-legal-in-MSI-only-frozen-and-next-invocation-carry');



  // All Sign/VerifyOnly calls have already recorded direct-child launch facts.
  assert.ok(signerTemps.length > 0);
  assert.ok(signerTemps.every(item => !fs.existsSync(item.directory)));
  pass('every-signer-plain-empty-exclusive-child-env-argv-cleanup-parent-TEMP-unchanged');

  const tempUninstaller = fixture(true, false); beginDesktopBundle(tempUninstaller.options); patched(tempUninstaller.gui, 'NSS'); await callback();
  const uninstaller = path.join(tempUninstaller.temp, 'uninstall 日本語 & generated.exe');
  fs.writeFileSync(uninstaller, 'public generated uninstaller');
  const nssPair = fs.readFileSync(tempUninstaller.gui + '.winsmux-nsis-plan.json');
  await callback(uninstaller); assert.equal(calls.at(-1).asset, uninstaller); assert.equal(calls.at(-1).verify, false);
  assert.deepEqual(fs.readFileSync(tempUninstaller.gui + '.winsmux-nsis-plan.json'), nssPair);
  const completeSetup = artifact('setup'); fs.mkdirSync(path.dirname(completeSetup), { recursive: true });
  fs.writeFileSync(completeSetup, 'public setup'); await callback(completeSetup); await callback(completeSetup);
  assert.equal(calls.at(-1).verify, true);
  fs.writeFileSync(tempUninstaller.gui, tempUninstaller.original);
  pass('NSS-three-role-null-DLL-TEMP-generated-uninstaller-separate-signer-child');

  for (const failureMode of ['collision', 'file', 'link', 'nonempty', 'missing-identity', 'prelaunch-replacement']) {
    const f = fixture(); beginDesktopBundle(f.options); patched(f.gui, 'MSI');
    const mkdirOriginal = fs.mkdirSync, lstatOriginal = fs.lstatSync, readdirOriginal = fs.readdirSync;
    let child = null, foreign = null, replaced = false;
    try {
      fs.mkdirSync = (file, ...args) => {
        if (path.dirname(file) === f.temp && path.basename(file).startsWith('winsmux-sign-')) {
          child = file;
          if (failureMode === 'collision') { fs.writeFileSync(file, 'foreign collision'); return mkdirOriginal(file, ...args); }
          const result = mkdirOriginal(file, ...args);
          if (failureMode === 'file') { fs.rmdirSync(file); fs.writeFileSync(file, 'foreign replacement file'); }
          if (failureMode === 'link') { fs.rmdirSync(file); foreign = path.join(f.temp, 'foreign-target');
            mkdirOriginal(foreign); fs.writeFileSync(path.join(foreign, 'keep.txt'), 'foreign keep');
            fs.symlinkSync(foreign, file, 'junction'); }
          if (failureMode === 'nonempty') fs.writeFileSync(path.join(file, 'keep.txt'), 'unknown contents');
          return result;
        }
        return mkdirOriginal(file, ...args);
      };
      fs.lstatSync = (file, ...args) => {
        const stat = lstatOriginal(file, ...args);
        if (file === child && failureMode === 'missing-identity') return { ...stat, ino: 0n,
          isDirectory: () => true, isSymbolicLink: () => false };
        return stat;
      };
      fs.readdirSync = (file, ...args) => {
        const entries = readdirOriginal(file, ...args);
        if (file === child && failureMode === 'prelaunch-replacement' && !replaced) {
          replaced = true; foreign = file + '-held'; fs.renameSync(file, foreign); mkdirOriginal(file);
        }
        return entries;
      };
      await assert.rejects(() => callback()); assert.equal(calls.length, 0);
    } finally { fs.mkdirSync = mkdirOriginal; fs.lstatSync = lstatOriginal; fs.readdirSync = readdirOriginal; }
    assert.ok(child && fs.existsSync(child)); assert.equal(readState().phase, 'failed');
    assert.equal(fs.existsSync(f.gui + '.winsmux-msi-plan.json'), false);
    if (failureMode === 'collision') assert.equal(fs.readFileSync(child, 'utf8'), 'foreign collision');
    if (failureMode === 'file') assert.equal(fs.readFileSync(child, 'utf8'), 'foreign replacement file');
    if (failureMode === 'nonempty') assert.equal(fs.readFileSync(path.join(child, 'keep.txt'), 'utf8'), 'unknown contents');
    if (failureMode === 'link') assert.equal(fs.readFileSync(path.join(foreign, 'keep.txt'), 'utf8'), 'foreign keep');
    pass('signer-allocation-' + failureMode + '-no-launch-no-fallback-foreign-preserved');
  }
  for (const failureMode of ['leftover', 'replacement', 'missing', 'launch', 'sign', 'rmdir']) {
    const f = fixture(); beginDesktopBundle(f.options); patched(f.gui, 'MSI');
    let child = null, held = null;
    const rmdirOriginal = fs.rmdirSync;
    signHook = (asset, directory) => {
      child = directory;
      if (failureMode === 'leftover') fs.writeFileSync(path.join(directory, 'keep.txt'), 'unknown signer residue');
      if (failureMode === 'replacement') { held = directory + '-held'; fs.renameSync(directory, held); fs.mkdirSync(directory);
        fs.writeFileSync(path.join(directory, 'keep.txt'), 'foreign replacement'); }
      if (failureMode === 'missing') rmdirOriginal(directory);
    };
    spawnFailure = failureMode === 'launch'; signerStatus = failureMode === 'sign' ? 1 : 0;
    if (failureMode === 'rmdir') fs.rmdirSync = directory => {
      if (path.dirname(directory) === f.temp && path.basename(directory).startsWith('winsmux-sign-'))
        throw new Error('controlled empty child rmdir failure');
      return rmdirOriginal(directory);
    };
    try { await assert.rejects(() => callback()); } finally { fs.rmdirSync = rmdirOriginal; spawnFailure = false; signerStatus = 0; signHook = null; }
    const seen = signerTemps.at(-1); child ??= seen.directory;
    assert.equal(readState().phase, 'failed'); assert.equal(fs.existsSync(f.gui + '.winsmux-msi-plan.json'), false);
    if (['leftover', 'replacement', 'rmdir'].includes(failureMode)) assert.ok(fs.existsSync(child));
    if (failureMode === 'leftover') assert.equal(fs.readFileSync(path.join(child, 'keep.txt'), 'utf8'), 'unknown signer residue');
    if (failureMode === 'replacement') assert.equal(fs.readFileSync(path.join(child, 'keep.txt'), 'utf8'), 'foreign replacement');
    if (['missing', 'launch', 'sign'].includes(failureMode)) assert.equal(fs.existsSync(child), false);
    pass('signer-cleanup-' + failureMode + '-failure-no-freeze-unknown-preserved');
  }
  const verifyFailure = await frozenMsi(); copyCompanions();
  const verifyPair = fs.readFileSync(verifyFailure.gui + '.winsmux-msi-plan.json');
  signerStatus = 1;
  try { await assert.rejects(() => callback(verifyFailure.library)); } finally { signerStatus = 0; }
  assert.equal(calls.at(-1).verify, true); assert.equal(readState().phase, 'failed');
  assert.deepEqual(fs.readFileSync(verifyFailure.gui + '.winsmux-msi-plan.json'), verifyPair);
  assert.equal(fs.existsSync(signerTemps.at(-1).directory), false);
  pass('VerifyOnly-error-removes-owned-empty-child-no-refreeze');


  for (const kind of ['empty', 'protected']) {
    const f = fixture(); beginDesktopBundle(f.options); patched(f.gui, 'MSI');
    process.env.TEMP = kind === 'empty' ? '' : input; process.env.TMP = kind === 'empty' ? f.temp : input;
    try { await assert.rejects(() => callback()); assert.equal(calls.length, 0); }
    finally { process.env.TEMP = f.temp; process.env.TMP = f.temp; }
    assert.equal(fs.existsSync(f.gui + '.winsmux-msi-plan.json'), false);
    pass('signer-parent-temp-' + kind + '-refused-before-allocation-or-launch');
  }

  // The candidate bytes are unmodified; this one dependency test double alters only the returned
  // child environment, to prove that the signer boundary rejects a guard/result mismatch.
  const fork = path.join(root, 'child-env-guard-double'); fs.mkdirSync(fork);
  fs.cpSync(path.join(repo, 'scripts'), path.join(fork, 'scripts'), { recursive: true });
  const guardFile = path.join(fork, 'scripts/distribution-prelaunch.mjs');
  let guardSource = fs.readFileSync(guardFile, 'utf8').replace('export function checkedPowerShellEnvironment(', 'function realCheckedPowerShellEnvironment(');
  guardSource += "\nexport function checkedPowerShellEnvironment(...args) { const result = realCheckedPowerShellEnvironment(...args);"
    + " if(args.length===4 && globalThis.task880ChildEnvFailure) { if(globalThis.task880ChildEnvFailure==='key') result.temp=result.TEMP;"
    + " else if(globalThis.task880ChildEnvFailure==='root') result.TMP=globalThis.task880OtherTemp;"
    + " else result.TEMP=globalThis.task880OtherTemp; } return result; }\n";
  fs.writeFileSync(guardFile, guardSource);
  const forked = await import(pathToFileURL(path.join(fork, 'scripts/stage-desktop-msi-plan.mjs')).href);
  for (const mode of ['key', 'root', 'effective']) {
    const f = fixture(); beginDesktopBundle(f.options); patched(f.gui, 'MSI');
    globalThis.task880ChildEnvFailure = mode; globalThis.task880OtherTemp = root;
    try { await assert.rejects(() => forked.signDesktopMsiAsset({ repoRoot: input, assetPath: f.gui, signed: true })); }
    finally { delete globalThis.task880ChildEnvFailure; delete globalThis.task880OtherTemp; }
    assert.equal(calls.length, 0); assert.equal(readState().phase, 'failed');
    assert.equal(fs.readdirSync(f.temp).some(name => name.startsWith('winsmux-sign-')), false);
    pass('signer-child-env-' + mode + '-mismatch-refused-before-spawn');
  }

  for (const mutation of ['unknown-key', 'record-GUI-binding', 'bad-artifact-label', 'wrong-temp']) {
    const f = await frozenMsi(false), pairBytes = fs.readFileSync(f.gui + '.winsmux-msi-plan.json');
    const state = readState();
    if (mutation === 'unknown-key') state.foreign = true;
    if (mutation === 'record-GUI-binding') state.records[0].gui_sha256 = '0'.repeat(64);
    if (mutation === 'bad-artifact-label') { state.records[0].compiler_inputs_ready = true;
      state.records[0].artifacts = [{ output: 'foreign-locale', bytes: 1, sha256: '0'.repeat(64) }]; }
    if (mutation === 'wrong-temp') state.sdk_temp_root = root;
    fs.writeFileSync(phaseFile(f.gui), JSON.stringify(state, null, 2) + '\n');
    await assert.rejects(() => callback()); assert.equal(calls.length, 0);
    assert.deepEqual(fs.readFileSync(f.gui + '.winsmux-msi-plan.json'), pairBytes);
    pass('strict-phase-' + mutation + '-refused-no-plan-refresh');
  }

  const failure = await frozenMsi(false); await finishMsi(); fs.writeFileSync(failure.gui, failure.original);
  const heldPlan = fs.readFileSync(failure.gui + '.winsmux-msi-plan.json'), heldInclude = fs.readFileSync(failure.gui + '.winsmux-plan.wxi');
  beginDesktopBundle(failure.options); patched(failure.gui, 'MSI');
  const nativeRename = fs.renameSync;
  try {
    fs.renameSync = (from, to) => { if (to === failure.gui + '.winsmux-plan.wxi' && from.includes('.tmp-')) throw new Error('controlled partial pair failure'); return nativeRename(from, to); };
    await assert.rejects(() => callback());
  } finally { fs.renameSync = nativeRename; }
  const failed = readState(), failedPrefix = failure.gui + '.winsmux-bundle-old-' + failed.invocation_id + '-msi';
  assert.equal(failed.phase, 'failed'); assert.equal(fs.existsSync(failure.gui + '.winsmux-plan.wxi'), false);
  assert.equal(fs.existsSync(failure.gui + '.winsmux-msi-plan.json'), false);
  assert.deepEqual(fs.readFileSync(failedPrefix + '-plan'), heldPlan); assert.deepEqual(fs.readFileSync(failedPrefix + '-include'), heldInclude);
  assert.throws(() => beginDesktopBundle(failure.options));
  pass('partial-producer-failure-no-old-public-restore-oldbackup-kept-failed-no-reset');

  const foreignFailure = await frozenMsi(false); await finishMsi(); fs.writeFileSync(foreignFailure.gui, foreignFailure.original);
  const foreignOld = fs.readFileSync(foreignFailure.gui + '.winsmux-msi-plan.json');
  beginDesktopBundle(foreignFailure.options); patched(foreignFailure.gui, 'MSI');
  try {
    fs.renameSync = (from, to) => {
      if (to === foreignFailure.gui + '.winsmux-plan.wxi' && from.includes('.tmp-')) {
        fs.writeFileSync(foreignFailure.gui + '.winsmux-msi-plan.json', 'foreign replacement');
        throw new Error('controlled foreign partial publication');
      }
      return nativeRename(from, to);
    };
    await assert.rejects(() => callback());
  } finally { fs.renameSync = nativeRename; }
  const foreignState = readState();
  assert.equal(foreignState.phase, 'failed');
  assert.equal(fs.readFileSync(foreignFailure.gui + '.winsmux-msi-plan.json', 'utf8'), 'foreign replacement');
  assert.equal(fs.existsSync(foreignFailure.gui + '.winsmux-plan.wxi'), false);
  assert.deepEqual(fs.readFileSync(foreignFailure.gui + '.winsmux-bundle-old-' + foreignState.invocation_id + '-msi-plan'), foreignOld);
  pass('foreign-partial-producer-slot-preserved-no-guessed-cleanup-no-old-publicinclude');

  const cleanup = await frozenMsi(false); await finishMsi(); fs.writeFileSync(cleanup.gui, cleanup.original);
  const cleanupOld = fs.readFileSync(cleanup.gui + '.winsmux-msi-plan.json'), cleanupInclude = fs.readFileSync(cleanup.gui + '.winsmux-plan.wxi');
  beginDesktopBundle(cleanup.options); patched(cleanup.gui, 'MSI');
  const nativeUnlink = fs.unlinkSync; let once = true;
  try {
    fs.unlinkSync = file => { if (once && file.includes('.winsmux-bundle-old-') && file.endsWith('-include')) {
      once = false; throw new Error('controlled cleanup failure');
    } return nativeUnlink(file); };
    await assert.rejects(() => callback());
  } finally { fs.unlinkSync = nativeUnlink; }
  const cleanupState = readState(), cleanupPrefix = cleanup.gui + '.winsmux-bundle-old-' + cleanupState.invocation_id + '-msi';
  assert.equal(cleanupState.phase, 'failed');
  assert.equal(fs.existsSync(cleanup.gui + '.winsmux-plan.wxi'), false);
  assert.equal(fs.existsSync(cleanup.gui + '.winsmux-msi-plan.json'), false);
  assert.deepEqual(fs.readFileSync(cleanupPrefix + '-plan'), cleanupOld);
  assert.deepEqual(fs.readFileSync(cleanupPrefix + '-include'), cleanupInclude);
  pass('controlled-backup-cleanup-restores-own-backup-only-no-stale-public-pair');
} finally {
  childProcess.spawnSync = nativeSpawn; syncBuiltinESMExports();
  if (savedTemp === undefined) delete process.env.TEMP; else process.env.TEMP = savedTemp;
  if (savedTmp === undefined) delete process.env.TMP; else process.env.TMP = savedTmp;
  if (existingNsis) fs.writeFileSync(mockNsisPath, existingNsis); else fs.unlinkSync(mockNsisPath);
}
const template = fs.readFileSync('winsmux-app/src-tauri/wix/installer.wxs', 'utf8');
assert.equal((template.match(/MajorUpgrade Schedule="afterInstallInitialize"/gu) ?? []).length, 2);
for (const action of ['DownloadAndInvokeBootstrapper', 'InvokeBootstrapper', 'InvokeStandalone', 'UpdateWebView2ViaEdgeUpdate'])
  assert.ok(template.includes("<Custom Action='" + action + "' After='InstallFiles'>"));
assert.ok(template.includes('Execute="deferred" Impersonate="yes" Return="check"'));
assert.ok(template.includes('BinaryKey="WinsmuxInstallerHelper"'));
assert.ok(template.includes('Action="WinsmuxVerifyStartup" Before="InstallFinalize"'));
assert.ok(template.includes('MSIRESTARTMANAGERCONTROL" Value="Disable"'));
assert.ok(template.includes('Name="winsmux.install-plan.json"'));
assert.ok(template.includes('Action="LaunchApplication" After="InstallFinalize"'));
pass('template-preserves-upgrade-and-optional-launch-adds-plan-verifier');
fs.writeFileSync(path.join(root, 'result.json'), JSON.stringify({ scope: 'MSI producer/template/sign dispatch; synthetic PE/signature fixtures; no installer execution', passed: cases.length, failed: 0, cases, signer_calls: signerTemps.map(row => ({ ...row, retained_at_end: fs.existsSync(row.directory) })) }, null, 2) + '\n');
console.log(JSON.stringify({ result: path.join(root, 'result.json'), passed: cases.length, failed: 0 }));
