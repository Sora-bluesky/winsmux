import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertCanonicalBundledDistribution } from './stage-bundled-distribution.mjs';
import { assertWindowsRuntime } from './assert-windows-runtime.mjs';
import { assertDesktopBundleNamespace } from './stage-desktop-msi-plan.mjs';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (ok, why) => { if (!ok) throw new Error(why); };
function plain(file) { const actual = physicalPath(file); const stat = fs.lstatSync(actual);
  requireValue(stat.isFile() && stat.nlink === 1, 'NSIS plan input must be a plain single-link file.');
  return fs.readFileSync(actual); }
function exists(file) { try { fs.lstatSync(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } }
function literal(value) { requireValue(typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f]/u.test(value), 'Unsafe NSIS literal.');
  return value.replaceAll('$', '$$').replaceAll('"', '$\\"'); }
function uniqueNss(bytes) { const marks = [...bytes.toString('latin1').matchAll(/__TAURI_BUNDLE_TYPE_VAR_[A-Z]{3}/gu)].map(m => m[0]);
  requireValue(marks.length === 1 && marks[0] === '__TAURI_BUNDLE_TYPE_VAR_NSS', 'Exact postpatch NSS GUI required.'); }
/** Produces only its own two public slots; the common phase owns retirement/restoration. */
export function stageDesktopNsisPlan({ repoRoot, srcTauri, guiPath, host, version, rustcCommit, projectOutput, signed }) {
  requireValue(host === 'x86_64-pc-windows-msvc' && version === '0.38.0' && typeof signed === 'boolean', 'Unsupported NSIS profile.');
  assertCanonicalBundledDistribution({ repoRoot, host, version, rustcCommit, projectOutput });
  const source = physicalPath(srcTauri); const repo = physicalPath(repoRoot);
  requireValue(source === physicalPath(path.join(repo, 'winsmux-app/src-tauri')), 'Exact Tauri source required.');
  const config = parseStrictJson(plain(path.join(source, 'tauri.conf.json')));
  requireValue((config.bundle?.windows?.nsis?.installMode ?? 'currentUser') === 'currentUser'
    && !config.bundle?.windows?.nsis?.startMenuFolder && !config.bundle?.homepage
    && !config.bundle?.fileAssociations?.length && !config.plugins?.['deep-link']?.desktop, 'Unmodeled NSIS registration configuration.');
  requireValue(path.isAbsolute(guiPath) && path.basename(guiPath) === 'winsmux-app.exe', 'Exact GUI path required.');
  assertDesktopBundleNamespace(guiPath);
  const gui = plain(guiPath); assertWindowsRuntime(gui, host); uniqueNss(gui);
  const generation = path.join(source, 'binaries'); const manifest = parseStrictJson(plain(path.join(generation, 'distribution-manifest.json')));
  const files = [{ role: 'gui', path: 'winsmux-app.exe', bytes: gui.length, sha256: hash(gui) }];
  for (const [name, role] of [['winsmux', 'cli'], ['winsmux-workspace-mcp', 'mcp']]) {
    const bytes = plain(path.join(generation, name + '-' + host + '.exe')); assertWindowsRuntime(bytes, host);
    files.push({ role, path: name + '.exe', bytes: bytes.length, sha256: hash(bytes) });
  }
  for (const row of manifest.files.filter(r => r.path.startsWith('licenses/'))) {
    requireValue(!/[\\:\x00-\x1f~]/u.test(row.path) && row.path.split('/').every(v => v && v !== '.' && v !== '..' && !/[. ]$/u.test(v)), 'Unsafe license member.');
    const bytes = plain(path.join(generation, row.path)); requireValue(bytes.length === row.bytes && hash(bytes) === row.sha256, 'License identity differs.');
    files.push({ role: 'license', path: row.path, bytes: bytes.length, sha256: hash(bytes) });
  }
  files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  requireValue(new Set(files.map(r => r.path.toLowerCase())).size === files.length && files.some(r => r.role === 'license'), 'Ambiguous member inventory.');
  const plan = Buffer.from(JSON.stringify({ schema: 'winsmux-desktop-install-plan/v1', flavor: 'nsis', version, host, files }, null, 2) + '\n');
  const planPath = guiPath + '.winsmux-nsis-plan.json'; const includePath = guiPath + '.winsmux-nsis-plan.nsh';
  const helperPath = path.join(generation, 'winsmux-' + host + '.exe'); const helperHash = files.find(r => r.role === 'cli').sha256;
  const constants = { WINSMUX_NSIS_PLAN_PATH: planPath, WINSMUX_NSIS_PLAN_SHA256: hash(plan), WINSMUX_NSIS_HELPER_PATH: helperPath,
    WINSMUX_NSIS_HELPER_SHA256: helperHash, WINSMUX_NSIS_GUI_BYTES: String(gui.length), WINSMUX_NSIS_GUI_SHA256: hash(gui), WINSMUX_NSIS_VERSION: version, WINSMUX_NSIS_HOST: host };
  const include = Buffer.from(Object.entries(constants).map(([k, v]) => '!define ' + k + ' "' + literal(v) + '"').join('\n') + '\n');
  requireValue(!exists(planPath) && !exists(includePath), 'NSIS public pair must be absent.');
  const owned = new Map();
  try {
    for (const [file, bytes] of [[planPath, plan], [includePath, include]]) {
      fs.writeFileSync(file, bytes, { flag: 'wx' }); owned.set(file, bytes);
      requireValue(plain(file).equals(bytes), 'Published NSIS pair differs.');
    }
    requireValue(plain(guiPath).equals(gui) && plain(helperPath).length === files.find(r => r.role === 'cli').bytes
      && hash(plain(helperPath)) === helperHash, 'Final package bytes changed during NSIS publication.');
  } catch (error) {
    for (const [file, bytes] of owned) { if (exists(file) && plain(file).equals(bytes)) fs.unlinkSync(file); }
    throw error;
  }
  return { status: 'desktop_nsis_plan_staged', plan_path: planPath, include_path: includePath, plan_sha256: hash(plan),
    gui_sha256: hash(gui), helper_sha256: helperHash, files: files.length, signed, installation_complete: false };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { requireValue(process.argv.length === 3, 'One fixed input required.'); console.log(JSON.stringify(stageDesktopNsisPlan(parseStrictJson(plain(process.argv[2]))))); }
  catch { console.log(JSON.stringify({ status: 'refused', installation_complete: false })); process.exitCode = 1; }
}
