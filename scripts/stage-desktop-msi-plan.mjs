import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { physicalPath, checkedPowerShellEnvironment } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertCanonicalBundledDistribution } from './stage-bundled-distribution.mjs';

const host64 = 'x86_64-pc-windows-msvc';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(value, reason) { if (!value) throw new Error(reason); }
function localPath(value) {
  requireValue(typeof value === 'string' && path.isAbsolute(value)
    && !/["$\x00-\x1f]/u.test(value) && !value.split(/[/\\]/u).some(part => part === '.' || part === '..'),
  'MSI input must be an absolute ordinary path without traversal or preprocessor syntax.');
  return physicalPath(value);
}
function plain(file) {
  const resolved = localPath(file); const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'MSI input must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
function exists(file) {
  try { fs.lstatSync(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
function overlap(a, b) {
  const left = localPath(a).toLowerCase(); const right = localPath(b).toLowerCase();
  return left === right || left.startsWith(right + path.sep) || right.startsWith(left + path.sep);
}
function exact(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join('\0') === keys.slice().sort().join('\0');
}
function paths(guiPath) {
  return { planPath: guiPath + '.winsmux-msi-plan.json', includePath: guiPath + '.winsmux-plan.wxi' };
}
function includeBytes(guiPath, helperPath, planBytes, guiRow, cliRow) {
  const { planPath } = paths(guiPath);
  const constants = { WinsmuxMsiPlanPath: planPath, WinsmuxMsiPlanSha256: digest(planBytes),
    WinsmuxMsiHelperPath: helperPath, WinsmuxMsiHelperSha256: cliRow.sha256,
    WinsmuxMsiGuiSha256: guiRow.sha256, WinsmuxMsiGuiBytes: guiRow.bytes };
  return Buffer.from('<Include>\n' + Object.entries(constants)
    .map(([name, value]) => '  <?define ' + name + '="' + String(value) + '"?>\n').join('') + '</Include>\n');
}
function checkedPair(guiPath) {
  const pair = paths(guiPath);
  requireValue(exists(pair.planPath) === exists(pair.includePath), 'MSI plan pair is incomplete.');
  if (exists(pair.planPath)) return { ...pair, planBytes: plain(pair.planPath), includeBytes: plain(pair.includePath) };
  return pair;
}
function signerDirectory(directory, expected = null) {
  requireValue(localPath(directory) === directory, 'Signer TEMP physical spelling differs.');
  const stat = fs.lstatSync(directory, { bigint: true });
  requireValue(stat.isDirectory() && !stat.isSymbolicLink() && stat.dev >= 0n && stat.ino > 0n,
    'Signer TEMP must be a plain directory with physical identity.');
  const identity = stat.dev.toString() + ':' + stat.ino.toString();
  requireValue((expected === null || identity === expected) && fs.readdirSync(directory).length === 0,
    'Signer TEMP was replaced or is not empty.');
  return identity;
}
function invokeSigner(repoRoot, assetPath, verifyOnly, env, sdkTempRoot) {
  const root = localPath(sdkTempRoot);
  requireValue(root === localPath(os.tmpdir()) && root === localPath(env.TEMP) && root === localPath(env.TMP),
    'Signer parent TEMP differs from admitted SDK root.');
  const directory = path.join(root, 'winsmux-sign-' + randomUUID());
  // mkdir is exclusive. Existing children are never adopted or removed.
  fs.mkdirSync(directory);
  let identity = null;
  try {
    identity = signerDirectory(directory);
    const childEnv = {};
    for (const [key, value] of Object.entries(env)) if (!['TEMP', 'TMP'].includes(key.toUpperCase())) childEnv[key] = value;
    childEnv.TEMP = directory; childEnv.TMP = directory;
    const signerEnv = checkedPowerShellEnvironment(repoRoot, [assetPath], childEnv, directory);
    requireValue(signerEnv.TEMP === directory && signerEnv.TMP === directory
      && Object.keys(signerEnv).filter(key => ['TEMP', 'TMP'].includes(key.toUpperCase())).sort().join(',') === 'TEMP,TMP'
      && Object.entries(childEnv).every(([key, value]) => signerEnv[key] === value)
      && Object.keys(signerEnv).length === Object.keys(childEnv).length, 'Signer child environment differs.');
    signerDirectory(directory, identity);
    const args = ['-NoLogo', '-NoProfile', '-File', path.join(repoRoot, 'winsmux-app/src-tauri/scripts/sign-windows-bundle.ps1'),
      '-AssetPath', assetPath];
    if (verifyOnly) args.push('-VerifyOnly');
    const result = spawnSync('pwsh', args, { cwd: path.join(repoRoot, 'winsmux-app/src-tauri'), env: signerEnv,
      encoding: 'utf8', windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
    requireValue(!result.error && !result.signal && result.status === 0, 'Windows asset signing or verification failed.');
  } finally {
    // Unknown contents or replaced/missing identity remain untouched and fail the callback.
    requireValue(identity !== null, 'Signer TEMP identity was not established.');
    signerDirectory(directory, identity);
    fs.rmdirSync(directory);
  }
}
function relative(value) {
  requireValue(typeof value === 'string' && value.length > 0 && !/[\\:"$\x00-\x1f]/u.test(value)
    && !value.split('/').some(part => !part || part === '.' || part === '..'), 'Invalid MSI member path.');
  return value;
}
function checkedPlan(bytes, flavor = 'msi') {
  const plan = parseStrictJson(bytes);
  requireValue(exact(plan, ['schema', 'flavor', 'version', 'host', 'files'])
    && plan.schema === 'winsmux-desktop-install-plan/v1' && plan.flavor === flavor && plan.host === host64
    && typeof plan.version === 'string' && /^\d+\.\d+\.\d+$/u.test(plan.version) && Array.isArray(plan.files), 'Invalid MSI plan.');
  const required = new Map([['winsmux-app.exe', 'gui'], ['winsmux.exe', 'cli'],
    ['winsmux-workspace-mcp.exe', 'mcp']]);
  if (flavor === 'msi') required.set('winsmux_app_lib.dll', 'app_lib');
  const seen = new Set(); let previous = '';
  for (const row of plan.files) {
    requireValue(exact(row, ['role', 'path', 'bytes', 'sha256']) && Number.isSafeInteger(row.bytes) && row.bytes > 0
      && typeof row.sha256 === 'string' && /^[a-f0-9]{64}$/u.test(row.sha256), 'Invalid MSI member identity.');
    relative(row.path);
    requireValue(!seen.has(row.path.toLowerCase()) && row.path > previous, 'Duplicate or unsorted MSI member.');
    requireValue(required.get(row.path) === row.role || (row.path.startsWith('licenses/') && row.role === 'license'), 'Unknown MSI member role.');
    seen.add(row.path.toLowerCase()); previous = row.path;
  }
  requireValue([...required.keys()].every(name => seen.has(name)) && plan.files.some(row => row.role === 'license'), 'MSI plan is incomplete.');
  requireValue(Buffer.from(JSON.stringify(plan, null, 2) + '\n').equals(bytes), 'MSI plan is not in canonical encoding.');
  return plan;
}

/** Read the existing distribution gate as strict UTF-8, including non-ASCII output paths. */
export function readDesktopDistributionVersion(repoRoot, env) {
  const repo = localPath(repoRoot);
  const literal = value => "'" + value.replaceAll("'", "''") + "'";
  const command = "$ErrorActionPreference = 'Stop'; "
    + '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & '
    + literal(path.join(repo, 'scripts/assert-distribution-version.ps1'))
    + ' -RepoRoot ' + literal(repo) + ' -AsJson; if (-not $?) { exit 1 }';
  const gate = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-EncodedCommand',
    Buffer.from(command, 'utf16le').toString('base64')],
  { cwd: repo, env, windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
  requireValue(!gate.error && !gate.signal && gate.status === 0, 'Distribution read set failed.');
  return parseStrictJson(gate.stdout);
}

/** Bind the canonical companions and licenses to this exact, final desktop executable. */
export function stageDesktopMsiPlan({ repoRoot, srcTauri, guiPath, host, version, rustcCommit, projectOutput, signed }) {
  const repo = localPath(repoRoot), source = localPath(srcTauri), output = localPath(projectOutput), gui = localPath(guiPath);
  requireValue(source === localPath(path.join(repo, 'winsmux-app/src-tauri'))
    && gui === localPath(path.join(output, 'winsmux-app.exe')) && path.basename(output) === 'release'
    && path.basename(path.dirname(output)) !== host64 && host === host64 && typeof signed === 'boolean', 'MSI release source/GUI layout differs.');
  for (const protectedPath of [source, path.join(repo, 'distribution')]) {
    requireValue(!overlap(output, protectedPath), 'MSI output overlaps protected source.');
  }
  const pair = checkedPair(gui);
  assertDesktopBundleNamespace(gui);
  // This shared guard owns runtime, version, manifest inventory and immutable license authority.
  assertCanonicalBundledDistribution({ repoRoot: repo, host, version, rustcCommit, projectOutput: output });
  const canonical = path.join(source, 'binaries');
  const manifest = parseStrictJson(plain(path.join(canonical, 'distribution-manifest.json')));
  const companionPaths = new Map([['winsmux-' + host + '.exe', ['cli', 'winsmux.exe']],
    ['winsmux-workspace-mcp-' + host + '.exe', ['mcp', 'winsmux-workspace-mcp.exe']]]);
  const internal = new Set(['nsis/winsmux-utils.nsh', 'nsis/plugins/winsmux_nsis_utils.dll']);
  const rows = [];
  for (const row of manifest.files) {
    const member = relative(row.path);
    if (internal.has(member)) continue;
    const role = companionPaths.get(member);
    requireValue(role || member.startsWith('licenses/'), 'Unknown canonical MSI source member.');
    const bytes = plain(path.join(canonical, member));
    requireValue(bytes.length === row.bytes && digest(bytes) === row.sha256, 'Canonical MSI source bytes differ.');
    rows.push({ role: role ? role[0] : 'license', path: role ? role[1] : member, bytes: bytes.length, sha256: digest(bytes) });
  }
  const guiBefore = plain(gui), library = plain(path.join(output, 'winsmux_app_lib.dll'));
  requireValue(bundleFlavor(guiBefore) === 'msi', 'MSI GUI bundle marker differs.');
  requireValue(guiBefore.length > 0 && library.length > 0, 'Desktop release bytes are missing.');
  const guiBytes = plain(gui);
  rows.push({ role: 'gui', path: 'winsmux-app.exe', bytes: guiBytes.length, sha256: digest(guiBytes) },
    { role: 'app_lib', path: 'winsmux_app_lib.dll', bytes: library.length, sha256: digest(library) });
  rows.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  const planBytes = Buffer.from(JSON.stringify({ schema: 'winsmux-desktop-install-plan/v1', flavor: 'msi', version, host, files: rows }, null, 2) + '\n');
  checkedPlan(planBytes);
  const helperPath = localPath(path.join(canonical, 'winsmux-' + host + '.exe'));
  const include = includeBytes(gui, helperPath, planBytes, rows.find(row => row.role === 'gui'), rows.find(row => row.role === 'cli'));
  if (pair.planBytes) {
    requireValue(pair.planBytes.equals(planBytes) && pair.includeBytes.equals(include), 'Existing MSI plan pair is stale or unknown.');
  } else {
    // Both temporaries are complete and read back before either compile input is published.
    const temporary = [pair.planPath, pair.includePath].map(file => file + '.tmp-' + randomUUID());
    try {
      for (const [index, bytes] of [planBytes, include].entries()) {
        const fd = fs.openSync(temporary[index], 'wx');
        try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
        requireValue(plain(temporary[index]).equals(bytes), 'MSI temporary readback differs.');
      }
      requireValue(!exists(pair.planPath) && !exists(pair.includePath), 'MSI output pair changed during publication.');
      fs.renameSync(temporary[0], pair.planPath); fs.renameSync(temporary[1], pair.includePath);
    } catch (error) {
      for (const [index, bytes] of [planBytes, include].entries()) removeOwned([pair.planPath, pair.includePath][index], bytes);
      throw error;
    } finally {
      for (const file of temporary) if (exists(file)) fs.unlinkSync(file);
    }
  }
  requireValue(plain(pair.planPath).equals(planBytes) && plain(pair.includePath).equals(include)
    && plain(gui).equals(guiBytes) && plain(path.join(output, 'winsmux_app_lib.dll')).equals(library), 'MSI frozen bytes/readback differs.');
  return { status: 'desktop_msi_plan_staged', plan_path: pair.planPath, include_path: pair.includePath,
    plan_sha256: digest(planBytes), gui_sha256: digest(guiBytes), helper_sha256: rows.find(row => row.role === 'cli').sha256,
    files: rows.length, signed, compiler_launched: false, installation_complete: false };
}


const phaseSchema = 'winsmux-desktop-bundle-phase/v1';
const marker = Buffer.from('__TAURI_BUNDLE_TYPE_VAR_');
const tags = { msi: 'MSI', nsis: 'NSS' };
const phasePath = gui => gui + '.winsmux-bundle-phase.json';
const sha = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
function flavorPair(gui, flavor) {
  return flavor === 'msi' ? paths(gui)
    : { planPath: gui + '.winsmux-nsis-plan.json', includePath: gui + '.winsmux-nsis-plan.nsh' };
}
function markerOffset(bytes) {
  const at = bytes.indexOf(marker);
  requireValue(at >= 0 && bytes.indexOf(marker, at + 1) < 0 && at + marker.length + 3 <= bytes.length,
    'Desktop GUI bundle marker is missing or ambiguous.');
  return at + marker.length;
}
function bundleFlavor(bytes, unpatched = false) {
  const at = markerOffset(bytes), tag = bytes.subarray(at, at + 3).toString('ascii');
  const flavor = Object.keys(tags).find(value => tags[value] === tag);
  requireValue(flavor || (unpatched && tag === 'UNK'), 'Desktop GUI bundle marker is unsupported.');
  return flavor ?? 'unpatched';
}
function expectedHashes(bytes) {
  requireValue(bundleFlavor(bytes, true) === 'unpatched', 'Original UNK GUI is required.');
  const at = markerOffset(bytes);
  return Object.fromEntries(Object.entries(tags).map(([flavor, tag]) => {
    const patched = Buffer.from(bytes); patched.write(tag, at, 'ascii'); return [flavor, digest(patched)];
  }));
}
function removeOwned(file, bytes) {
  if (!exists(file)) return true;
  try { if (!plain(file).equals(bytes)) return false; fs.unlinkSync(file); return true; } catch { return false; }
}
function stateBytes(state) { return Buffer.from(JSON.stringify(state, null, 2) + '\n'); }
function artifactPaths(gui, version, flavor) {
  const output = path.dirname(gui), stem = 'winsmux_' + version + '_x64';
  return flavor === 'msi'
    ? new Map(['en-US', 'ja-JP'].map(label => [label, path.join(output, 'bundle/msi', stem + '_' + label + '.msi')]))
    : new Map([['setup', path.join(output, 'bundle/nsis', stem + '-setup.exe')]]);
}
function sealed(gui, state, record) {
  return record.compiler_inputs_ready && record.artifacts.length === artifactPaths(gui, state.version, record.flavor).size;
}
function checkedPhase(bytes, gui) {
  const state = parseStrictJson(bytes);
  requireValue(exact(state, ['schema', 'invocation_id', 'gui_path', 'host', 'version', 'signed',
    'generation_manifest_sha256', 'input_gui_sha256', 'input_app_lib_sha256', 'sdk_temp_root',
    'expected_pre_sign', 'phase', 'records', 'prior_pairs'])
    && state.schema === phaseSchema && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/u.test(state.invocation_id)
    && state.gui_path === gui && state.host === host64 && typeof state.version === 'string'
    && /^\d+\.\d+\.\d+$/u.test(state.version) && typeof state.signed === 'boolean'
    && sha(state.generation_manifest_sha256) && sha(state.input_gui_sha256)
    && (state.input_app_lib_sha256 === null || sha(state.input_app_lib_sha256))
    && typeof state.sdk_temp_root === 'string' && state.sdk_temp_root === localPath(state.sdk_temp_root)
    && exact(state.expected_pre_sign, ['msi', 'nsis'])
    && Object.values(state.expected_pre_sign).every(value => value === null || sha(value))
    && ['admitting', 'admitted', 'preparing', 'frozen', 'failed'].includes(state.phase)
    && Array.isArray(state.records) && Array.isArray(state.prior_pairs)
    && state.records.length <= 2 && state.prior_pairs.length <= 2, 'Invalid desktop bundle phase.');
  const order = state.records.map(row => row.flavor).join(',');
  requireValue(['', 'msi', 'nsis', 'msi,nsis'].includes(order)
    && (!['admitting', 'admitted'].includes(state.phase) || state.records.length === 0)
    && (state.phase !== 'frozen' || state.records.length > 0), 'Invalid desktop bundle phase order.');
  for (const [rows, keys] of [[state.records, ['flavor', 'gui_sha256', 'plan_sha256', 'include_sha256', 'compiler_inputs_ready', 'artifacts']],
    [state.prior_pairs, ['flavor', 'plan_sha256', 'include_sha256']]]) {
    const seen = new Set();
    for (const row of rows) {
      requireValue(exact(row, keys) && Object.hasOwn(tags, row.flavor) && !seen.has(row.flavor)
        && sha(row.plan_sha256) && sha(row.include_sha256), 'Invalid desktop phase pair record.');
      seen.add(row.flavor);
      if (rows === state.records) {
        requireValue(sha(row.gui_sha256) && typeof row.compiler_inputs_ready === 'boolean'
          && Array.isArray(row.artifacts) && row.artifacts.length <= artifactPaths(gui, state.version, row.flavor).size
          && (row.flavor !== 'nsis' || row.compiler_inputs_ready), 'Invalid compiler observations.');
        const labels = new Set();
        for (const item of row.artifacts) {
          requireValue(exact(item, ['output', 'bytes', 'sha256']) && artifactPaths(gui, state.version, row.flavor).has(item.output)
            && !labels.has(item.output) && Number.isSafeInteger(item.bytes) && item.bytes > 0 && sha(item.sha256)
            && row.compiler_inputs_ready, 'Invalid artifact observation.');
          labels.add(item.output);
        }
        requireValue(state.expected_pre_sign[row.flavor] === null, 'Consumed flavor still has an admission hash.');
      }
    }
  }
  requireValue(!state.records.some(row => row.flavor === 'msi') || state.input_app_lib_sha256 !== null, 'MSI record lacks admitted library.');
  requireValue(state.records.length < 2 || sealed(gui, state, state.records[0]), 'Unsealed format transition.');
  requireValue(stateBytes(state).equals(bytes), 'Desktop phase encoding is not canonical.');
  return state;
}
function readPhase(gui) {
  requireValue(exists(phasePath(gui)), 'Desktop bundle admission is missing.');
  return checkedPhase(plain(phasePath(gui)), gui);
}
function publishState(gui, state) {
  const bytes = stateBytes(state), file = phasePath(gui), temporary = file + '.tmp-' + state.invocation_id;
  checkedPhase(bytes, gui);
  try {
    const fd = fs.openSync(temporary, 'wx');
    try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    requireValue(plain(temporary).equals(bytes), 'Desktop phase temporary readback differs.');
    fs.renameSync(temporary, file);
    requireValue(plain(file).equals(bytes), 'Desktop phase publication readback differs.');
  } finally { removeOwned(temporary, bytes); }
}
function backupPaths(gui, state, flavor) {
  const prefix = gui + '.winsmux-bundle-old-' + state.invocation_id + '-' + flavor;
  return { planPath: prefix + '-plan', includePath: prefix + '-include' };
}
export function assertDesktopBundleNamespace(guiPath) {
  const gui = localPath(guiPath), known = new Set([phasePath(gui)]);
  for (const flavor of Object.keys(tags)) for (const file of Object.values(flavorPair(gui, flavor))) known.add(file);
  const state = exists(phasePath(gui)) ? readPhase(gui) : null;
  if (!state) {
    const flavor = bundleFlavor(plain(gui), true);
    for (const other of Object.keys(tags)) if (other !== flavor)
      for (const file of Object.values(flavorPair(gui, other))) requireValue(!exists(file), 'Unbound other-flavor pair exists.');
  }
  for (const row of state?.prior_pairs ?? []) {
    const backup = backupPaths(gui, state, row.flavor);
    for (const [key, hash] of [['planPath', row.plan_sha256], ['includePath', row.include_sha256]]) {
      if (exists(backup[key])) requireValue(digest(plain(backup[key])) === hash, 'Desktop owned backup differs.');
      known.add(backup[key]);
    }
  }
  const prefix = path.basename(gui).toLowerCase() + '.winsmux-';
  for (const name of fs.readdirSync(path.dirname(gui))) if (name.toLowerCase().startsWith(prefix))
    requireValue(known.has(path.join(path.dirname(gui), name)), 'Unknown adjacent desktop bundle output.');
}
function generationHash(source) { return digest(plain(path.join(source, 'binaries/distribution-manifest.json'))); }
function identityMatches(file, row) {
  const bytes = plain(file);
  requireValue(bytes.length === row.bytes && digest(bytes) === row.sha256, 'Frozen desktop member differs: ' + row.path);
  return bytes;
}
function canonicalRows(options) {
  const root = path.join(options.srcTauri, 'binaries'), manifest = parseStrictJson(plain(path.join(root, 'distribution-manifest.json')));
  return manifest.files.map(row => ({ ...row, source: localPath(path.join(root, relative(row.path))) }));
}
function planSources(options, plan) {
  const root = path.join(options.srcTauri, 'binaries');
  return plan.files.map(row => ({ ...row, source: localPath(row.role === 'cli' ? path.join(root, 'winsmux-' + options.host + '.exe')
    : row.role === 'mcp' ? path.join(root, 'winsmux-workspace-mcp-' + options.host + '.exe')
    : row.role === 'license' ? path.join(root, row.path) : path.join(options.projectOutput, row.path)) }));
}
function expectedInclude(options, plan, bytes) {
  const guiRow = plan.files.find(row => row.role === 'gui'), cliRow = plan.files.find(row => row.role === 'cli');
  const helper = path.join(options.srcTauri, 'binaries/winsmux-' + options.host + '.exe');
  if (plan.flavor === 'msi') return includeBytes(options.guiPath, helper, bytes, guiRow, cliRow);
  const constants = { WINSMUX_NSIS_PLAN_PATH: flavorPair(options.guiPath, 'nsis').planPath,
    WINSMUX_NSIS_PLAN_SHA256: digest(bytes), WINSMUX_NSIS_HELPER_PATH: helper,
    WINSMUX_NSIS_HELPER_SHA256: cliRow.sha256, WINSMUX_NSIS_GUI_BYTES: String(guiRow.bytes),
    WINSMUX_NSIS_GUI_SHA256: guiRow.sha256, WINSMUX_NSIS_VERSION: options.version, WINSMUX_NSIS_HOST: options.host };
  const literal = value => value.replaceAll('$', '$$').replaceAll('"', '$\\"');
  return Buffer.from(Object.entries(constants).map(([key, value]) => '!define ' + key + ' "' + literal(value) + '"').join('\n') + '\n');
}
function verifiedPair(options, row, backup = null) {
  const pair = backup ?? flavorPair(options.guiPath, row.flavor);
  const bytes = plain(pair.planPath), include = plain(pair.includePath);
  requireValue(digest(bytes) === row.plan_sha256 && digest(include) === row.include_sha256, 'Desktop recorded pair differs.');
  const plan = checkedPlan(bytes, row.flavor);
  if (Object.hasOwn(row, 'gui_sha256')) requireValue(plan.files.find(item => item.role === 'gui').sha256 === row.gui_sha256, 'Recorded GUI and plan row differ.');
  requireValue(plan.host === options.host && plan.version === options.version, 'Desktop recorded plan generation differs.');
  requireValue(include.equals(expectedInclude(options, plan, bytes)), 'Desktop include literals differ.');
  return { pair, bytes, include, plan };
}
function validatePlanSources(options, plan, skipGui = false) {
  const canonical = canonicalRows(options), planned = planSources(options, plan);
  const expected = canonical.filter(row => row.path.startsWith('licenses/') || /^winsmux(?:-workspace-mcp)?-x86_64-pc-windows-msvc\.exe$/u.test(row.path))
    .map(row => row.path.startsWith('licenses/') ? row.path : row.path.replace('-' + options.host, ''));
  expected.push('winsmux-app.exe'); if (plan.flavor === 'msi') expected.push('winsmux_app_lib.dll');
  requireValue(expected.sort().join('\0') === plan.files.map(row => row.path).join('\0'), 'Desktop plan inventory differs.');
  for (const row of planned) if (!skipGui || row.role !== 'gui') identityMatches(row.source, row);
}
function checkedInventory(options) {
  const configFile = path.join(options.srcTauri, 'tauri.conf.json');
  const base = parseStrictJson(plain(configFile));
  function merge(left, right) {
    const out = { ...left };
    for (const [key, value] of Object.entries(right)) out[key] = value && typeof value === 'object' && !Array.isArray(value)
      ? merge(left[key] ?? {}, value) : value;
    return out;
  }
  const effective = process.env.TAURI_CONFIG ? merge(base, parseStrictJson(Buffer.from(process.env.TAURI_CONFIG))) : base;
  const bundle = effective.bundle, wix = bundle?.windows?.wix, nsis = bundle?.windows?.nsis;
  requireValue(JSON.stringify(bundle?.externalBin) === JSON.stringify(['binaries/winsmux', 'binaries/winsmux-workspace-mcp'])
    && exact(bundle?.resources, ['binaries/licenses']) && bundle.resources['binaries/licenses'] === 'licenses'
    && (!effective.mainBinaryName || effective.mainBinaryName === 'winsmux-app')
    && wix?.template === 'wix/installer.wxs' && nsis?.template === 'nsis/installer.nsi'
    && nsis.installerHooks === 'nsis-installer-hooks.nsh'
    && (!wix.mergeModules || wix.mergeModules.length === 0)
    && Object.keys(wix.language ?? {}).sort().join(',') === 'en-US,ja-JP', 'Unsupported desktop resource/binary configuration.');
  const cargo = new TextDecoder('utf-8', { fatal: true }).decode(plain(path.join(options.srcTauri, 'Cargo.toml')));
  requireValue(!/^\s*\[\[bin\]\]/mu.test(cargo) && !/^\s*autobins\s*=\s*false/mu.test(cargo)
    && !exists(path.join(options.srcTauri, 'src/bin')), 'Unsupported desktop normal binary inventory.');
  const dlls = fs.readdirSync(options.projectOutput).filter(name => /\.dll$/iu.test(name));
  requireValue(dlls.length <= 1 && (dlls.length === 0 || dlls[0] === 'winsmux_app_lib.dll')
    && !fs.readdirSync(options.projectOutput).some(name => /\.msm$/iu.test(name)), 'Unsupported desktop DLL/MSM inventory.');
  if (dlls.length) plain(path.join(options.projectOutput, dlls[0]));
}
function parentTemp(options) {
  const values = [os.tmpdir()];
  for (const [key, value] of Object.entries(process.env)) if (['TEMP', 'TMP'].includes(key.toUpperCase())) {
    requireValue(typeof value === 'string' && value.length > 0, 'Empty SDK temporary root.'); values.push(value);
  }
  const roots = values.map(localPath), root = roots[0];
  requireValue(roots.every(value => value === root) && fs.lstatSync(root).isDirectory(), 'SDK temporary roots differ.');
  for (const protectedPath of [options.srcTauri, path.join(options.repoRoot, 'distribution'), options.projectOutput])
    requireValue(!overlap(root, protectedPath), 'SDK temporary root overlaps protected inputs.');
  for (const name of fs.readdirSync(root)) if (['winsmux.exe', 'winsmux-workspace-mcp.exe'].includes(name.toLowerCase()))
    requireValue(['winsmux.exe', 'winsmux-workspace-mcp.exe'].includes(name), 'SDK companion copy case alias.');
  return root;
}
function compilerCopies(options, state, plan, required = true) {
  for (const row of plan.files.filter(row => ['cli', 'mcp'].includes(row.role))) {
    const file = localPath(path.join(state.sdk_temp_root, row.path));
    if (!required && !exists(file)) continue;
    identityMatches(file, row);
  }
}
function canonicalGuard(options, state) {
  requireValue(generationHash(options.srcTauri) === state.generation_manifest_sha256, 'Desktop canonical generation changed.');
  assertCanonicalBundledDistribution(options);
  checkedInventory(options);
  requireValue(parentTemp(options) === state.sdk_temp_root, 'SDK temporary root changed.');
  for (const row of canonicalRows(options)) identityMatches(row.source, row);
  assertDesktopBundleNamespace(options.guiPath);
  if (['admitted', 'preparing'].includes(state.phase) && !state.records.some(row => row.flavor === 'msi')) {
    const old = state.prior_pairs.find(row => row.flavor === 'msi');
    const plan = old ? verifiedPair(options, old, backupPaths(options.guiPath, state, 'msi')).plan : null;
    for (const name of ['winsmux.exe', 'winsmux-workspace-mcp.exe']) if (exists(path.join(state.sdk_temp_root, name))) {
      requireValue(plan, 'Unowned SDK companion copy appeared before compiler.');
      identityMatches(path.join(state.sdk_temp_root, name), plan.files.find(row => row.path === name));
    }
  }
}
function fullGuard(options, state, allowedGui = null) {
  canonicalGuard(options, state);
  for (const row of state.prior_pairs) verifiedPair(options, row, backupPaths(options.guiPath, state, row.flavor));
  for (const record of state.records) {
    const { plan } = verifiedPair(options, record);
    validatePlanSources(options, plan, true);
    if (record.flavor === 'msi' && record.compiler_inputs_ready) compilerCopies(options, state, plan);
    for (const item of record.artifacts) identityMatches(artifactPaths(options.guiPath, state.version, record.flavor).get(item.output), item);
  }
  const current = state.records.at(-1), gui = plain(options.guiPath);
  if (current) {
    const hash = digest(gui);
    requireValue(hash === current.gui_sha256 || (sealed(options.guiPath, state, current) && hash === state.input_gui_sha256)
      || (allowedGui !== null && hash === allowedGui), 'Desktop GUI changed during compiler interval.');
  } else requireValue(digest(gui) === state.input_gui_sha256 || Object.values(state.expected_pre_sign).includes(digest(gui)),
    'Desktop admitted GUI changed.');
  if (!state.records.some(row => row.flavor === 'msi')) {
    const library = path.join(options.projectOutput, 'winsmux_app_lib.dll');
    requireValue(state.input_app_lib_sha256 === null ? !exists(library) : digest(plain(library)) === state.input_app_lib_sha256,
      'Admitted app library changed.');
  }
}
function checkedPrevious(options, previous) {
  requireValue(previous.phase === 'frozen' && previous.version === options.version && previous.host === options.host
    && previous.signed === options.signed && previous.generation_manifest_sha256 === generationHash(options.srcTauri)
    && previous.records.every(row => sealed(options.guiPath, previous, row)), 'Prior desktop phase is incomplete or differs.');
  assertDesktopBundleNamespace(options.guiPath);
  const latest = new Map();
  for (const row of previous.prior_pairs) {
    const check = verifiedPair(options, row, backupPaths(options.guiPath, previous, row.flavor));
    for (const member of planSources(options, check.plan)) if (['cli', 'mcp', 'license'].includes(member.role)) identityMatches(member.source, member);
    latest.set(row.flavor, { row, ...check });
  }
  for (const row of previous.records) {
    const check = verifiedPair(options, row);
    for (const item of row.artifacts) identityMatches(artifactPaths(options.guiPath, previous.version, row.flavor).get(item.output), item);
    for (const member of planSources(options, check.plan)) if (['cli', 'mcp', 'license'].includes(member.role)) identityMatches(member.source, member);
    latest.set(row.flavor, { row: { flavor: row.flavor, plan_sha256: row.plan_sha256, include_sha256: row.include_sha256 }, ...check });
  }
  return [...latest.values()];
}
export function beginDesktopBundle(options) {
  const { host, version, signed } = options;
  options = { ...options, repoRoot: localPath(options.repoRoot), srcTauri: localPath(options.srcTauri),
    guiPath: localPath(options.guiPath), projectOutput: localPath(options.projectOutput) };
  const { repoRoot: repo, srcTauri: source, guiPath: gui, projectOutput: output } = options;
  requireValue(source === localPath(path.join(repo, 'winsmux-app/src-tauri'))
    && gui === localPath(path.join(output, 'winsmux-app.exe')) && path.basename(output) === 'release'
    && path.basename(path.dirname(output)) !== host64 && host === host64 && typeof signed === 'boolean', 'Desktop admission layout differs.');
  for (const protectedPath of [source, path.join(repo, 'distribution')])
    requireValue(!overlap(output, protectedPath), 'Desktop admission overlaps protected source.');
  assertCanonicalBundledDistribution(options); checkedInventory(options); assertDesktopBundleNamespace(gui);
  const bytes = plain(gui), expected = expectedHashes(bytes), library = path.join(output, 'winsmux_app_lib.dll');
  const temp = parentTemp(options), previous = exists(phasePath(gui)) ? readPhase(gui) : null;
  const retired = previous ? checkedPrevious(options, previous) : [];
  const previousMsi = previous?.records.find(row => row.flavor === 'msi');
  for (const name of ['winsmux.exe', 'winsmux-workspace-mcp.exe']) if (exists(path.join(temp, name))) {
    requireValue(previousMsi && previous.sdk_temp_root === temp, 'Unowned preexisting SDK companion copy.');
    const { plan } = verifiedPair(options, previousMsi);
    identityMatches(path.join(temp, name), plan.files.find(row => row.path === name));
  }
  if (!previous) for (const flavor of Object.keys(tags)) for (const file of Object.values(flavorPair(gui, flavor)))
    requireValue(!exists(file), 'Desktop pair without phase ownership is refused.');
  const state = { schema: phaseSchema, invocation_id: randomUUID(), gui_path: gui, host, version, signed,
    generation_manifest_sha256: generationHash(source), input_gui_sha256: digest(bytes),
    input_app_lib_sha256: exists(library) ? digest(plain(library)) : null, sdk_temp_root: temp,
    expected_pre_sign: expected, phase: 'admitting', records: [], prior_pairs: retired.map(item => item.row) };
  publishState(gui, state);
  try {
    for (const item of retired) {
      const backup = backupPaths(gui, state, item.row.flavor);
      for (const [key, value] of [['planPath', item.bytes], ['includePath', item.include]]) {
        requireValue(!exists(backup[key]) && plain(item.pair[key]).equals(value), 'Retired desktop pair changed.');
        fs.renameSync(item.pair[key], backup[key]);
        requireValue(plain(backup[key]).equals(value), 'Retired desktop pair readback differs.');
      }
    }
    for (const flavor of Object.keys(tags)) for (const file of Object.values(flavorPair(gui, flavor)))
      requireValue(!exists(file), 'Prior public desktop pair remains.');
    state.phase = 'admitted'; publishState(gui, state);
    fullGuard(options, state);
  } catch (error) { state.phase = 'failed'; try { publishState(gui, state); } catch { /* Preserve incomplete state. */ } throw error; }
  return { status: 'desktop_bundle_admitted', input_gui_sha256: state.input_gui_sha256, compiler_launched: false };
}
function callbackOptions(repo, env) {
  const verified = readDesktopDistributionVersion(repo, env);
  const rustc = spawnSync('rustc', ['-Vv'], { cwd: repo, env, encoding: 'utf8', windowsHide: true });
  requireValue(!rustc.error && !rustc.signal && rustc.status === 0, 'Rust compiler identity unavailable.');
  const host = /^host: ([A-Za-z0-9_-]+)$/mu.exec(rustc.stdout)?.[1];
  const rustcCommit = /^commit-hash: ([a-f0-9]{40})$/mu.exec(rustc.stdout)?.[1];
  requireValue(host === host64 && rustcCommit, 'Desktop callback compiler identity differs.');
  const projectOutput = localPath(path.join(localPath(verified.build_target_root), 'release'));
  return { repoRoot: repo, srcTauri: path.join(repo, 'winsmux-app/src-tauri'), guiPath: path.join(projectOutput, 'winsmux-app.exe'),
    host, version: verified.version, rustcCommit, projectOutput };
}
function failedState(gui, state) {
  state.phase = 'failed'; try { publishState(gui, state); } catch { /* Keep truthful incomplete evidence. */ }
}
function cleanConsumedBackup(gui, state, flavor) {
  const row = state.prior_pairs.find(item => item.flavor === flavor);
  if (!row) return;
  const backup = backupPaths(gui, state, flavor), held = Object.entries(backup).map(([key, file]) => ({ file, bytes: plain(file), hash: row[key === 'planPath' ? 'plan_sha256' : 'include_sha256'] }));
  requireValue(held.every(item => digest(item.bytes) === item.hash), 'Consumed backup changed.');
  try {
    for (const item of held) requireValue(removeOwned(item.file, item.bytes), 'Consumed backup cleanup failed.');
    state.prior_pairs = state.prior_pairs.filter(item => item.flavor !== flavor);
    publishState(gui, state);
  } catch (error) {
    for (const item of held) if (!exists(item.file)) {
      const fd = fs.openSync(item.file, 'wx');
      try { fs.writeFileSync(fd, item.bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    }
    if (!state.prior_pairs.some(item => item.flavor === flavor)) state.prior_pairs.push(row);
    throw error;
  }
}
export async function signDesktopMsiAsset({ repoRoot, assetPath, signed }) {
  const repo = localPath(repoRoot), asset = localPath(assetPath), env = checkedPowerShellEnvironment(repo);
  requireValue(typeof signed === 'boolean', 'Desktop callback signing mode is required.');
  const options = { ...callbackOptions(repo, env), signed }, gui = localPath(options.guiPath), state = readPhase(gui);
  requireValue(['admitted', 'frozen'].includes(state.phase) && state.signed === signed
    && state.version === options.version && state.host === options.host, 'Desktop callback phase/mode differs.');
  const current = state.records.at(-1), canonical = path.join(options.srcTauri, 'binaries');
  const rows = canonicalRows(options), canonicalAsset = rows.find(row => row.source === asset);
  const copyName = ['winsmux.exe', 'winsmux-workspace-mcp.exe'].find(name => asset === localPath(path.join(state.sdk_temp_root, name)));
  const library = localPath(path.join(options.projectOutput, 'winsmux_app_lib.dll'));
  const knownArtifacts = state.records.flatMap(record => [...artifactPaths(gui, state.version, record.flavor)]
    .map(([label, file]) => ({ record, label, file })));
  if (asset !== gui && !canonicalAsset && !copyName && asset !== library && !knownArtifacts.some(item => item.file === asset)) {
    requireValue((overlap(asset, options.projectOutput) || overlap(asset, state.sdk_temp_root))
      && !overlap(asset, canonical) && !overlap(asset, path.join(repo, 'distribution'))
      && !asset.startsWith(gui + '.winsmux-') && !['winsmux-app.exe', 'winsmux_app_lib.dll', 'winsmux.exe', 'winsmux-workspace-mcp.exe'].includes(path.basename(asset).toLowerCase())
      && !/\.msi$/iu.test(asset) && !/-setup\.exe$/iu.test(asset), 'Unsupported reserved desktop signing target.');
  }
  plain(asset);
  // Exact immutable classification happens before any mutating signer.
  if (canonicalAsset) {
    fullGuard(options, state); identityMatches(asset, canonicalAsset);
    requireValue(['winsmux-' + options.host + '.exe', 'winsmux-workspace-mcp-' + options.host + '.exe'].includes(canonicalAsset.path),
      'Canonical control/license inputs cannot enter the signer.');
    if (signed) invokeSigner(repo, asset, true, env, state.sdk_temp_root);
    fullGuard(options, state); identityMatches(asset, canonicalAsset);
    return { status: 'canonical_companion_verified', signed };
  }
  if (asset === gui) {
    const before = plain(gui), flavor = bundleFlavor(before), hash = digest(before);
    if (state.phase === 'frozen' && current?.flavor === flavor) {
      fullGuard(options, state); requireValue(hash === current.gui_sha256, 'Frozen same-flavor GUI changed.');
      if (signed) invokeSigner(repo, gui, true, env, state.sdk_temp_root);
      fullGuard(options, state);
      return { status: 'frozen_gui_verified', flavor, gui_sha256: hash, signed };
    }
    requireValue((state.phase === 'admitted' && !current)
      || (state.phase === 'frozen' && current?.flavor === 'msi' && flavor === 'nsis'
        && state.records.length === 1 && sealed(gui, state, current)), 'Desktop compiler phase transition is refused.');
    requireValue(hash === state.expected_pre_sign[flavor], 'Desktop postpatch GUI differs from admission.');
    fullGuard(options, state, hash);
    if (flavor === 'msi') {
      requireValue(state.input_app_lib_sha256 !== null && digest(plain(library)) === state.input_app_lib_sha256, 'MSI app library is missing or changed.');
    }
    const producer = flavor === 'msi' ? stageDesktopMsiPlan : (await import('./stage-desktop-nsis-plan.mjs')).stageDesktopNsisPlan;
    requireValue(typeof producer === 'function', 'Desktop flavor producer unavailable.');
    state.phase = 'preparing'; publishState(gui, state);
    let published = null;
    try {
      if (signed) invokeSigner(repo, gui, false, env, state.sdk_temp_root);
      bundleFlavor(plain(gui)); requireValue(bundleFlavor(plain(gui)) === flavor, 'Signer changed GUI marker.');
      const finalGui = plain(gui);
      canonicalGuard(options, state);
      if (flavor === 'msi') {
        requireValue(digest(plain(library)) === state.input_app_lib_sha256, 'Signer changed app library before its signing boundary.');
        if (signed) invokeSigner(repo, library, false, env, state.sdk_temp_root);
        requireValue(plain(gui).equals(finalGui), 'Library signing changed GUI.');
        canonicalGuard(options, state);
      } else if (state.input_app_lib_sha256 !== null && !state.records.some(row => row.flavor === 'msi'))
        requireValue(digest(plain(library)) === state.input_app_lib_sha256, 'NSS signing changed unplanned app library.');
      const pair = flavorPair(gui, flavor);
      requireValue(!exists(pair.planPath) && !exists(pair.includePath), 'Active pair was not retired.');
      await producer({ ...options, signed });
      const planBytes = plain(pair.planPath), include = plain(pair.includePath), plan = checkedPlan(planBytes, flavor);
      published = { pair, planBytes, include };
      validatePlanSources(options, plan);
      requireValue(include.equals(expectedInclude(options, plan, planBytes)), 'Produced include binding differs.');
      requireValue(plain(gui).equals(finalGui), 'Plan production changed final GUI.');
      state.records.push({ flavor, gui_sha256: digest(finalGui), plan_sha256: digest(planBytes), include_sha256: digest(include),
        compiler_inputs_ready: flavor === 'nsis', artifacts: [] });
      state.expected_pre_sign[flavor] = null; state.phase = 'frozen'; publishState(gui, state);
      cleanConsumedBackup(gui, state, flavor); fullGuard(options, state);
      return { status: 'desktop_plan_frozen', flavor, gui_sha256: digest(finalGui), plan_sha256: digest(planBytes), signed };
    } catch (error) {
      if (published) { removeOwned(published.pair.planPath, published.planBytes); removeOwned(published.pair.includePath, published.include); }
      failedState(gui, state); throw error;
    }
  }
  try {
    requireValue(state.phase === 'frozen' && current, 'Unplanned signing requires a frozen compiler interval.');
    fullGuard(options, state);
    if (asset === library || copyName) {
      const msi = state.records.find(row => row.flavor === 'msi');
      requireValue(msi, 'Planned MSI source/copy callback is out of phase.');
      const { plan } = verifiedPair(options, msi);
      compilerCopies(options, state, plan);
      const row = plan.files.find(item => item.path === (copyName ?? 'winsmux_app_lib.dll'));
      identityMatches(asset, row);
      if (signed) invokeSigner(repo, asset, true, env, state.sdk_temp_root);
      compilerCopies(options, state, plan); fullGuard(options, state); identityMatches(asset, row);
      if (asset === library && !msi.compiler_inputs_ready) {
        msi.compiler_inputs_ready = true; publishState(gui, state);
      }
      return { status: 'planned_compiler_source_verified', signed };
    }
    requireValue(current.compiler_inputs_ready, 'MSI compiler copies have not been verified.');
    const item = knownArtifacts.find(row => row.file === asset);
    if (item) {
      const recorded = item.record.artifacts.find(row => row.output === item.label);
      if (recorded) {
        identityMatches(asset, recorded);
        if (signed) invokeSigner(repo, asset, true, env, state.sdk_temp_root);
        identityMatches(asset, recorded); fullGuard(options, state);
        return { status: 'frozen_artifact_verified', output: item.label, signed };
      }
      requireValue(item.record === current, 'Earlier format container callback is out of phase.');
      if (signed) invokeSigner(repo, asset, false, env, state.sdk_temp_root);
      fullGuard(options, state);
      const bytes = plain(asset); requireValue(bytes.length > 0, 'Empty desktop container.');
      current.artifacts.push({ output: item.label, bytes: bytes.length, sha256: digest(bytes) });
      publishState(gui, state); fullGuard(options, state);
      return { status: 'desktop_artifact_recorded', output: item.label, signed };
    }
    requireValue(!sealed(gui, state, current), 'Unexpected signer after compiler completion.');
    if (signed) invokeSigner(repo, asset, false, env, state.sdk_temp_root);
    fullGuard(options, state);
    return { status: signed ? 'existing_signer_delegated' : 'unsigned_asset_unchanged', gui_changed: false };
  } catch (error) { failedState(gui, state); throw error; }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const run = async () => {
    requireValue(process.argv.length === 5 && process.argv[2] === '--sign-asset'
      && ['--unsigned', '--signed'].includes(process.argv[4]), 'Exactly one asset and explicit signing mode are required.');
    const repoRoot = physicalPath(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
    return signDesktopMsiAsset({ repoRoot, assetPath: path.resolve(process.argv[3]), signed: process.argv[4] === '--signed' });
  };
  // Let this module finish evaluation before the NSIS producer imports its guard.
  run().then(result => console.log(JSON.stringify(result))).catch(() => {
    console.log(JSON.stringify({ status: 'refused', compiler_launched: false })); process.exitCode = 1;
  });
}
