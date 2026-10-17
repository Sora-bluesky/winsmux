import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { stageBundledDistribution } from '../../scripts/stage-bundled-distribution.mjs';
import { stageDesktopNsisPlan } from '../../scripts/stage-desktop-nsis-plan.mjs';
import { beginDesktopBundle, signDesktopMsiAsset } from '../../scripts/stage-desktop-msi-plan.mjs';
import { fixturePe } from './fixture-pe.mjs';

// Real producer and coordinator; only PE execution/signing/version subprocesses are synthetic.
const repo = process.cwd();
const root = path.resolve('.evidence/workspace-package', 'desktop-nsis-' + randomUUID());
fs.mkdirSync(root, { recursive: true });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const binding = JSON.parse(fs.readFileSync('distribution/windows-licenses/binding.json'));
const input = path.join(root, "source 日本語 & quote's");
const source = path.join(input, 'winsmux-app/src-tauri');
fs.mkdirSync(input);
const currentAuthorityPath = 'core/crates/winsmux-workspace/src/desktop_current_licenses_v0380.json';
fs.mkdirSync(path.join(input, path.dirname(currentAuthorityPath)), { recursive: true });
fs.copyFileSync(path.join(repo, currentAuthorityPath), path.join(input, currentAuthorityPath));
for (const row of binding.sources) {
  const file = path.join(input, row.path); fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.copyFileSync(path.join(repo, row.path), file);
}
for (const relative of ['distribution/windows-licenses', 'winsmux-app/src-tauri/nsis'])
  fs.cpSync(path.join(repo, relative), path.join(input, relative), { recursive: true });
for (const relative of ['nsis-installer-hooks.nsh', 'tauri.conf.json', 'Cargo.toml'])
  fs.copyFileSync(path.join(repo, 'winsmux-app/src-tauri', relative), path.join(source, relative));
const companions = ['winsmux', 'winsmux-workspace-mcp'].map(name => {
  const bytes = fixturePe({ normal: ['kernel32.dll'], marker: 'synthetic NSIS ' + name });
  const file = path.join(root, name + '.exe'); fs.writeFileSync(file, bytes);
  return { name, path: file, sha256: hash(bytes) };
});
stageBundledDistribution({ repoRoot: input, destination: path.join(root, 'generation'), host: binding.host,
  version: binding.version, rustcCommit: binding.rustc_commit, buildProfile: 'release', companions });
fs.renameSync(path.join(root, 'generation'), path.join(source, 'binaries'));
const generation = path.join(source, 'binaries');
const manifest = JSON.parse(fs.readFileSync(path.join(generation, 'distribution-manifest.json')));
const licenses = manifest.files.filter(row => row.path.startsWith('licenses/'));
const cases = [];
const pass = name => cases.push({ name, result: 'passed' });
const savedTemp = process.env.TEMP, savedTmp = process.env.TMP;
const nativeSpawn = childProcess.spawnSync, nativeWrite = fs.writeFileSync;
let active, calls = [], signHook = null;
function fixture(marker = 'NSS', signed = false, dll = false) {
  const id = randomUUID(), output = path.join(root, 'output 日本語 & ' + id, 'release');
  const temp = path.join(root, 'temp-' + id); fs.mkdirSync(output, { recursive: true }); fs.mkdirSync(temp);
  process.env.TEMP = temp; process.env.TMP = temp;
  const gui = path.join(output, 'winsmux-app.exe');
  const original = fixturePe({ normal: ['kernel32.dll'], marker: 'synthetic GUI __TAURI_BUNDLE_TYPE_VAR_' + marker + ' ' + id });
  fs.writeFileSync(gui, original);
  const library = path.join(output, 'winsmux_app_lib.dll');
  if (dll) fs.writeFileSync(library, fixturePe({ normal: ['kernel32.dll'], marker: 'synthetic library ' + id }));
  active = { gui, original, temp, library, options: { repoRoot: input, srcTauri: source, guiPath: gui,
    host: binding.host, version: binding.version, rustcCommit: binding.rustc_commit, projectOutput: output, signed } };
  calls = []; signHook = null; return active;
}
const pair = f => [f.gui + '.winsmux-nsis-plan.json', f.gui + '.winsmux-nsis-plan.nsh'];
const state = f => JSON.parse(fs.readFileSync(f.gui + '.winsmux-bundle-phase.json'));
const callback = (f, asset = f.gui) => signDesktopMsiAsset({ repoRoot: input, assetPath: asset, signed: f.options.signed });
function snapshot(base) {
  const rows = {};
  function visit(directory, prefix = '') {
    for (const name of fs.readdirSync(directory)) {
      const file = path.join(directory, name), rel = prefix + name, stat = fs.lstatSync(file);
      if (stat.isSymbolicLink()) rows[rel] = { link: fs.readlinkSync(file) };
      else if (stat.isDirectory()) { rows[rel + '/'] = 'directory'; visit(file, rel + '/'); }
      else rows[rel] = hash(fs.readFileSync(file));
    }
  }
  visit(base); return rows;
}
function patched(f, marker) {
  const bytes = fs.readFileSync(f.gui), prefix = Buffer.from('__TAURI_BUNDLE_TYPE_VAR_'), at = bytes.indexOf(prefix);
  assert.ok(at >= 0 && bytes.indexOf(prefix, at + 1) < 0);
  bytes.write(marker, at + prefix.length, 'ascii'); fs.writeFileSync(f.gui, bytes);
}
function assertPlan(f) {
  const [planFile, includeFile] = pair(f), bytes = fs.readFileSync(planFile), include = fs.readFileSync(includeFile).toString('utf8');
  assert.equal(bytes.includes(Buffer.from([0xef, 0xbb, 0xbf])), false);
  const plan = JSON.parse(bytes); assert.equal(plan.flavor, 'nsis');
  assert.deepEqual(plan.files.filter(row => row.role !== 'license').map(row => row.role).sort(), ['cli', 'gui', 'mcp']);
  assert.equal(plan.files.length, licenses.length + 3); assert.equal(plan.files.some(row => row.role === 'app_lib'), false);
  for (const row of plan.files) {
    const file = row.role === 'gui' ? f.gui : row.role === 'license' ? path.join(generation, row.path)
      : path.join(generation, row.path.replace('.exe', '-' + binding.host + '.exe'));
    const actual = fs.readFileSync(file); assert.equal(row.bytes, actual.length); assert.equal(row.sha256, hash(actual));
  }
  assert.ok(include.includes('WINSMUX_NSIS_PLAN_SHA256 "' + hash(bytes) + '"'));
  assert.ok(include.includes('日本語') && include.includes(' & '));
  assert.ok(include.includes('WINSMUX_NSIS_HELPER_SHA256 "' + plan.files.find(row => row.role === 'cli').sha256 + '"'));
  return { bytes, include: fs.readFileSync(includeFile), plan };
}
function refuse(name, mutate, overrides = {}) {
  const f = fixture(); const restore = mutate?.(f) ?? (() => {});
  try {
    const before = snapshot(root); assert.throws(() => stageDesktopNsisPlan({ ...f.options, ...overrides }), name);
    assert.deepEqual(snapshot(root), before); pass(name);
  } finally { restore(); }
}
function alter(file, bytes) { const previous = fs.readFileSync(file); fs.writeFileSync(file, bytes); return () => fs.writeFileSync(file, previous); }

try {
  const f = fixture(); const canonicalBefore = snapshot(input), guiBefore = fs.readFileSync(f.gui);
  const first = stageDesktopNsisPlan(f.options), measured = assertPlan(f);
  assert.equal(first.plan_sha256, hash(measured.bytes)); assert.equal(first.installation_complete, false);
  assert.equal(first.signed, false); assert.deepEqual(snapshot(input), canonicalBefore); assert.deepEqual(fs.readFileSync(f.gui), guiBefore);
  pass('real-NSS-three-PE-plan-full-canonical-licenses-helper-and-literal-paths');
  assert.throws(() => stageDesktopNsisPlan(f.options));
  assert.deepEqual(fs.readFileSync(pair(f)[0]), measured.bytes); assert.deepEqual(fs.readFileSync(pair(f)[1]), measured.include);
  pass('existing-active-pair-is-not-refreshed');
  for (const marker of ['UNK', 'MSI']) refuse('wrong-marker-' + marker, f => alter(f.gui, fixturePe({ normal: ['kernel32.dll'], marker: '__TAURI_BUNDLE_TYPE_VAR_' + marker })));
  refuse('duplicate-NSS-marker', f => alter(f.gui, fixturePe({ normal: ['kernel32.dll'], marker: '__TAURI_BUNDLE_TYPE_VAR_NSS __TAURI_BUNDLE_TYPE_VAR_NSS' })));
  for (const [key, value] of [['version', '0.39.0'], ['host', 'aarch64-pc-windows-msvc'], ['rustcCommit', '0'.repeat(40)], ['signed', 'true']])
    refuse('unsupported-' + key, null, { [key]: value });
  refuse('hardlinked-GUI', f => { const copy = f.gui + '.hardlink'; fs.linkSync(f.gui, copy); return () => fs.unlinkSync(copy); });
  refuse('tampered-canonical-license', () => alter(path.join(generation, licenses[0].path), Buffer.from('foreign license')));
  refuse('unknown-adjacent-output', f => { const file = f.gui + '.winsmux-unknown'; fs.writeFileSync(file, 'foreign'); return () => fs.unlinkSync(file); });
  for (const variant of ['mode', 'homepage', 'association', 'start-menu']) refuse('unsupported-registration-' + variant, () => {
    const file = path.join(source, 'tauri.conf.json'), config = JSON.parse(fs.readFileSync(file));
    if (variant === 'mode') config.bundle.windows.nsis.installMode = 'perMachine';
    if (variant === 'homepage') config.bundle.homepage = 'https://example.invalid';
    if (variant === 'association') config.bundle.fileAssociations = [{ ext: ['synthetic'] }];
    if (variant === 'start-menu') config.bundle.windows.nsis.startMenuFolder = 'Other';
    return alter(file, Buffer.from(JSON.stringify(config)));
  });
  for (const foreign of [false, true]) {
    const f = fixture(), [planFile, includeFile] = pair(f), canonical = snapshot(input);
    fs.writeFileSync = function (file, bytes, options) {
      if (file === includeFile) {
        if (foreign) nativeWrite(planFile, 'foreign replacement');
        throw new Error('synthetic second-slot publication failure');
      }
      return nativeWrite(file, bytes, options);
    };
    try { assert.throws(() => stageDesktopNsisPlan(f.options)); }
    finally { fs.writeFileSync = nativeWrite; syncBuiltinESMExports(); }
    assert.equal(fs.existsSync(includeFile), false);
    if (foreign) assert.equal(fs.readFileSync(planFile, 'utf8'), 'foreign replacement');
    else assert.equal(fs.existsSync(planFile), false);
    assert.deepEqual(snapshot(input), canonical);
    pass(foreign ? 'partial-pair-failure-preserves-external-replacement' : 'partial-pair-failure-removes-only-own-first-slot');
  }

  childProcess.spawnSync = (exe, args, spawnOptions) => {
    assert.equal(spawnOptions.windowsHide, true);
    if (exe === 'rustc') return { status: 0, stdout: 'host: ' + binding.host + '\ncommit-hash: ' + binding.rustc_commit + '\n' };
    assert.equal(exe, 'pwsh');
    if (args.includes('-EncodedCommand')) return { status: 0, stdout: Buffer.from(JSON.stringify({ version: binding.version,
      build_target_root: path.dirname(active.options.projectOutput) })) };
    const asset = args[args.indexOf('-AssetPath') + 1], verify = args.includes('-VerifyOnly');
    calls.push({ asset, verify });
    if (!verify) { fs.appendFileSync(asset, '\npublic-synthetic-signature'); signHook?.(asset); }
    return { status: 0, stdout: '' };
  };
  syncBuiltinESMExports();
  const f1 = fixture('UNK', true); const canonical = snapshot(input);
  beginDesktopBundle(f1.options); assert.equal(state(f1).input_app_lib_sha256, null);
  patched(f1, 'NSS'); await callback(f1); const nss1 = assertPlan(f1);
  assert.equal(state(f1).records[0].compiler_inputs_ready, true);
  assert.deepEqual(calls, [{ asset: f1.gui, verify: false }]);
  await callback(f1); assert.equal(calls.at(-1).verify, true); assert.deepEqual(fs.readFileSync(pair(f1)[0]), nss1.bytes);
  pass('signed-NSS-only-no-DLL-GUI-sign-before-real-plan-repeat-VerifyOnly');
  const uninstaller = path.join(f1.temp, 'generated uninstall 日本語 &.exe'); fs.writeFileSync(uninstaller, 'synthetic generated uninstaller');
  await callback(f1, uninstaller); assert.equal(calls.at(-1).verify, false);
  assert.deepEqual(fs.readFileSync(pair(f1)[0]), nss1.bytes); assert.deepEqual(snapshot(input), canonical);
  const setup = path.join(f1.options.projectOutput, 'bundle/nsis/winsmux_' + binding.version + '_x64-setup.exe');
  fs.mkdirSync(path.dirname(setup), { recursive: true }); fs.writeFileSync(setup, 'synthetic setup container');
  await callback(f1, setup); await callback(f1, setup); assert.equal(calls.at(-1).verify, true);
  assert.equal(state(f1).records[0].artifacts.length, 1);
  pass('unplanned-uninstaller-and-exact-setup-callback-preserve-full-NSS-pair');
  fs.writeFileSync(f1.gui, f1.original); beginDesktopBundle(f1.options);
  assert.equal(fs.existsSync(pair(f1)[0]), false); assert.equal(fs.existsSync(pair(f1)[1]), false);
  await assert.rejects(() => callback(f1)); assert.equal(fs.existsSync(pair(f1)[1]), false);
  pass('beforeBundle-retires-old-NSS-pair-missing-current-callback-cannot-reuse');

  const f2 = fixture('UNK', true, true); beginDesktopBundle(f2.options); patched(f2, 'MSI'); await callback(f2);
  for (const name of ['winsmux', 'winsmux-workspace-mcp']) fs.copyFileSync(path.join(generation, name + '-' + binding.host + '.exe'), path.join(f2.temp, name + '.exe'));
  await callback(f2, f2.library);
  for (const label of ['ja-JP', 'en-US']) {
    const artifact = path.join(f2.options.projectOutput, 'bundle/msi/winsmux_' + binding.version + '_x64_' + label + '.msi');
    fs.mkdirSync(path.dirname(artifact), { recursive: true }); fs.writeFileSync(artifact, 'synthetic MSI ' + label); await callback(f2, artifact);
  }
  const msiPlan = fs.readFileSync(f2.gui + '.winsmux-msi-plan.json'), libraryBytes = fs.readFileSync(f2.library);
  fs.writeFileSync(f2.gui, f2.original); patched(f2, 'NSS'); await callback(f2); assertPlan(f2);
  assert.deepEqual(fs.readFileSync(f2.gui + '.winsmux-msi-plan.json'), msiPlan); assert.deepEqual(fs.readFileSync(f2.library), libraryBytes);
  assert.deepEqual(state(f2).records.map(row => row.flavor), ['msi', 'nsis']);
  assert.equal(calls.filter(row => !row.verify && row.asset === f2.library).length, 1);
  pass('sealed-two-locale-MSI-original-derived-NSS-real-three-role-transition');

  for (const target of ['license', 'helper', 'plan', 'gui', 'prior-DLL']) {
    const f = fixture('UNK', true, true); beginDesktopBundle(f.options); patched(f, 'NSS'); await callback(f);
    const asset = path.join(f.temp, 'generated-uninstaller.exe'); fs.writeFileSync(asset, 'synthetic uninstaller');
    const file = target === 'license' ? path.join(generation, licenses[0].path)
      : target === 'helper' ? path.join(generation, 'winsmux-' + binding.host + '.exe')
      : target === 'plan' ? pair(f)[0] : target === 'gui' ? f.gui : f.library;
    const restore = alter(file, Buffer.concat([fs.readFileSync(file), Buffer.from('foreign alteration')]));
    const callCount = calls.length;
    try { await assert.rejects(() => callback(f, asset)); assert.equal(calls.length, callCount); }
    finally { restore(); }
    pass('frozen-' + target + '-tamper-refused-before-unplanned-signer');
  }
  const f3 = fixture('UNK', true); beginDesktopBundle(f3.options); patched(f3, 'NSS'); await callback(f3);
  const tool = path.join(f3.options.projectOutput, 'nsis/x64/Plugins/x86-unicode/System.dll');
  fs.mkdirSync(path.dirname(tool), { recursive: true }); fs.writeFileSync(tool, 'synthetic copied NSIS tool');
  const plannedGui = fs.readFileSync(f3.gui); signHook = () => fs.appendFileSync(f3.gui, 'forbidden signer mutation');
  await assert.rejects(() => callback(f3, tool)); assert.equal(state(f3).phase, 'failed');
  assert.equal(JSON.parse(fs.readFileSync(pair(f3)[0])).files.find(row => row.role === 'gui').sha256, hash(plannedGui));
  pass('unplanned-signer-postguard-detects-GUI-mutation-without-plan-refresh');
} finally {
  fs.writeFileSync = nativeWrite; childProcess.spawnSync = nativeSpawn; syncBuiltinESMExports();
  if (savedTemp === undefined) delete process.env.TEMP; else process.env.TEMP = savedTemp;
  if (savedTmp === undefined) delete process.env.TMP; else process.env.TMP = savedTmp;
}
fs.writeFileSync(path.join(root, 'result.json'), JSON.stringify({ scope: 'real NSIS producer and shared phase with synthetic PE/signer; no installer or genuine certificate',
  passed: cases.length, failed: 0, actual_nsis_producer: true, installer_executed: false, genuine_signatures: false, cases }, null, 2) + '\n');
console.log(JSON.stringify({ result: path.join(root, 'result.json'), passed: cases.length, failed: 0 }));
