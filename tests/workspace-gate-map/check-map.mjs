// Recomputes every gate, every CI entrypoint and every weakening finding between the fixed bases and a
// tree-ish, then requires the gate-map.json stored at that same tree-ish to account for each one.
// Everything is read from git objects at --ref; the working tree is never consulted. Findings compare the
// base trees with the target tree only, so the same tree gives the same result on a branch head, on a
// pull-request merge ref and on the merge commit that lands it.
// Usage: node check-map.mjs [--ref <tree-ish>] [--emit-findings] [--map <file>]
//   --emit-findings prints findings, gates and entrypoints instead of verifying; --map substitutes
//   a map file for the one at --ref (only honoured together with --emit-findings).
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.resolve(here, '../..');
export const MAP_DIR = 'tests/workspace-gate-map/';
export const MAP_PATH = `${MAP_DIR}gate-map.json`;
export const SCHEMA = 'winsmux-gate-map/v3';

export function git(argv, input) {
  const r = spawnSync('git', ['-C', repo, ...argv], { input, maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`git ${argv.join(' ')}: ${r.stderr}`);
  return r.stdout;
}
export const gitOk = argv => spawnSync('git', ['-C', repo, ...argv], { maxBuffer: 1 << 30 }).status === 0;
export const sha256 = buf => createHash('sha256').update(buf).digest('hex');
export const lf = text => text.replace(/\r\n/g, '\n');
const show = spec => lf(git(['show', spec]).toString('utf8'));
const isAncestor = (commit, ref) => gitOk(['cat-file', '-e', `${commit}^{commit}`]) && git(['rev-list', '--count', `${ref}..${commit}`]).toString('utf8').trim() === '0';

const EXCLUDE = ['.evidence/', '.references/', '.worktrees/', 'tasks/'];
const excluded = p => EXCLUDE.some(x => p.startsWith(x));
function classify(p) {
  if (excluded(p)) return null;
  const low = p.toLowerCase();
  if (/^\.github\/(workflows\/[^/]+\.ya?ml|actions\/[^/]+\/action\.ya?ml)$/.test(p)) return 'workflow';
  if (low.endsWith('.tests.ps1')) return 'pester';
  if (p.endsWith('.rs') && (p.includes('/tests/') || p.includes('/tests-rs/') || p.startsWith('tests/'))) return 'rust_test_target';
  if (/\.test\.(mjs|js|cjs|ts|ps1)$/.test(low)) return 'script_test';
  if (p.endsWith('Cargo.toml')) return 'cargo_manifest';
  if (p.startsWith('scripts/') && /(test-|audit|gitleaks|check|verify|smoke|gate)/.test(low)) return 'release_public_secret_script';
  if (p.startsWith('.githooks/')) return 'githook';
  if (low.includes('gitleaks')) return 'secret_config';
  return null;
}
const PAT = {
  rust_tests: /#\[(tokio::)?test\b/g,
  rust_ignore: /#\[ignore/g,
  rust_assert: /\b(assert(_eq|_ne|_matches)?!|panic!|\.expect\(|\.unwrap_err\()/g,
  pester_it: /^\s*It\s+['"]/gm,
  pester_skip: /(-Skip\b|Set-ItResult\s+-Skipped|-Pending\b|Set-ItResult\s+-Inconclusive)/g,
  pester_should: /\bShould\b/g,
  js_tests: /\b(test|it)\s*\(\s*['"`]/g,
  js_skip: /(\b(test|it|describe)\.(skip|todo)\b|\bskip\s*:\s*true)/g,
  js_assert: /\bassert(\.\w+)?\s*\(/g,
  ps_throw: /\b(throw|exit\s+1|Write-Error)\b/g,
};
const METRICS = {
  rust_test_target: ['rust_tests', 'rust_ignore', 'rust_assert'],
  rust_src: ['rust_tests', 'rust_ignore', 'rust_assert'],
  pester: ['pester_it', 'pester_skip', 'pester_should'],
  script_test: ['js_tests', 'js_skip', 'js_assert', 'pester_it', 'ps_throw'],
  release_public_secret_script: ['ps_throw'],
  githook: ['ps_throw'],
  ci_script: ['js_tests', 'js_skip', 'js_assert', 'pester_it', 'ps_throw'],
};
const metrics = (kind, text) => Object.fromEntries((METRICS[kind] ?? []).map(k => [k, (text.match(PAT[k]) ?? []).length]));
const isSkip = k => k.endsWith('skip') || k.endsWith('ignore');

export function lsTree(treeish) {
  const out = new Map();
  for (const line of git(['ls-tree', '-r', '--format=%(objectname) %(path)', treeish]).toString('utf8').split('\n')) {
    if (!line) continue;
    const i = line.indexOf(' ');
    out.set(line.slice(i + 1), line.slice(0, i));
  }
  return out;
}
const blobCache = new Map();
function readBlobs(oids) {
  const need = [...new Set(oids)].filter(o => !blobCache.has(o));
  if (need.length === 0) return;
  const out = git(['cat-file', '--batch'], need.join('\n') + '\n');
  let pos = 0;
  for (const oid of need) {
    const nl = out.indexOf(10, pos);
    const header = out.subarray(pos, nl).toString('utf8').split(' ');
    if (header[0] !== oid || header[1] !== 'blob') throw new Error(`cat-file batch: ${header.join(' ')}`);
    const size = Number(header[2]);
    blobCache.set(oid, out.subarray(nl + 1, nl + 1 + size).toString('utf8'));
    pos = nl + 1 + size + 1;
  }
}
const text = oid => blobCache.get(oid);
export const fileText = (tree, p) => (tree.has(p) ? (readBlobs([tree.get(p)]), text(tree.get(p))) : null);

// CI entrypoints: every repository script a workflow, composite action or package.json script runs, and
// transitively every script those scripts name, followed to a fixed point with no depth limit.
// Classification by name never decides membership here; a discovered path becomes a gate even when no
// name rule matches it. The only files a hop does not enter are the product runtime and sources, which
// are the subject the checks read and run, not checks themselves.
const SCRIPT_EXT = /\.(ps1|psm1|mjs|cjs|js|ts|py|sh)$/;
const PRODUCT_RUNTIME = p => /^(winsmux-core\/|packages\/|sdk\/|core\/|\.claude\/|winsmux-app\/src\/|winsmux-app\/src-tauri\/src\/)/.test(p) || p === 'install.ps1' || p.endsWith('.ts');
const PATH_TOKEN = /(?<![\w@.-])(?:\.{1,2}\/)?(?:[\w@.-]+\/)+[\w@.-]+\.(?:ps1|psm1|mjs|cjs|js|ts|py|sh)\b|(?<![\w@./-])\.\/[\w@.-]+\.(?:ps1|psm1|mjs|cjs|js|ts|py|sh)\b/g;
// Inside a script a sibling may be named without a directory, as in Join-Path $PSScriptRoot 'run.ps1'.
const SIBLING_TOKEN = /(?<=['"])[\w@.-]+\.(?:ps1|psm1|mjs|cjs|js|ts|py|sh)(?=['"])/g;
const SCANNABLE = /\.(ps1|psm1|mjs|cjs|js|sh)$/;
function normalize(base, token) {
  const joined = path.posix.normalize(path.posix.join(base, token));
  return joined.startsWith('../') || joined === '..' ? null : joined;
}
function resolveToken(tree, bases, token) {
  for (const base of bases) {
    const p = normalize(base, token);
    if (p && tree.has(p)) return p;
  }
  return null;
}
function packageScripts(tree) {
  const out = new Map();
  for (const p of tree.keys()) {
    if (excluded(p) || !/(^|\/)package\.json$/.test(p)) continue;
    let json;
    try { json = JSON.parse(fileText(tree, p)); } catch { continue; }
    for (const [name, command] of Object.entries(json.scripts ?? {})) {
      if (out.has(name)) throw new Error(`npm script ${name} is defined in more than one package.json`);
      out.set(name, { source: p, dir: path.posix.dirname(p), command });
    }
  }
  return out;
}
export function discoverEntrypoints(tree, localRunners) {
  const scripts = packageScripts(tree);
  const rows = new Map();
  const add = (source, line, invoked) => {
    const k = `${source}|${line}|${invoked}`;
    if (!rows.has(k)) rows.set(k, { source, line, invokes: invoked });
  };
  const scanLine = (source, lineNo, line, bases, follow) => {
    for (const m of line.matchAll(PATH_TOKEN)) {
      const hit = resolveToken(tree, bases, m[0]);
      if (hit && hit !== source && SCRIPT_EXT.test(hit)) add(source, lineNo, hit);
    }
    if (follow) {
      for (const m of line.matchAll(/\bnpm\s+run\s+([\w:.-]+)/g)) {
        const script = scripts.get(m[1]);
        if (!script) continue;
        for (const t of script.command.matchAll(PATH_TOKEN)) {
          const hit = resolveToken(tree, [script.dir], t[0]);
          if (hit && SCRIPT_EXT.test(hit)) add(source, lineNo, hit);
        }
      }
    }
  };
  for (const p of tree.keys()) {
    if (classify(p) !== 'workflow') continue;
    const lines = fileText(tree, p).split('\n');
    lines.forEach((line, i) => scanLine(p, i + 1, line, ['.', 'winsmux-app'], true));
  }
  for (const [, script] of scripts) {
    script.command.split(/\s*(?:&&|;)\s*/).forEach(part => {
      for (const t of part.matchAll(PATH_TOKEN)) {
        const hit = resolveToken(tree, [script.dir], t[0]);
        if (hit && SCRIPT_EXT.test(hit)) add(script.source, 0, hit);
      }
    });
  }
  for (const runner of localRunners) if (tree.has(runner.path)) add(MAP_PATH, 0, runner.path);
  // Transitive closure: every invoked script is scanned once, and scripts it names are queued in turn.
  const scanned = new Set();
  const queue = [...new Set([...rows.values()].map(r => r.invokes))];
  while (queue.length > 0) {
    const entry = queue.shift();
    // The disposition data names paths as anchors, not as invocations; it is a gate but not a source.
    if (scanned.has(entry) || !SCANNABLE.test(entry) || entry === `${MAP_DIR}dispositions.mjs`) continue;
    scanned.add(entry);
    const dir = path.posix.dirname(entry);
    fileText(tree, entry).split('\n').forEach((line, i) => {
      for (const m of [...line.matchAll(PATH_TOKEN), ...line.matchAll(SIBLING_TOKEN)]) {
        const hit = resolveToken(tree, [dir, '.', 'winsmux-app'], m[0]);
        if (hit && hit !== entry && SCRIPT_EXT.test(hit) && !excluded(hit) && !PRODUCT_RUNTIME(hit)) {
          add(entry, i + 1, hit);
          if (!scanned.has(hit)) queue.push(hit);
        }
      }
    });
  }
  return [...rows.values()].sort((x, y) => (x.source < y.source ? -1 : x.source > y.source ? 1 : x.line - y.line || (x.invokes < y.invokes ? -1 : 1)));
}

function cargoTargets(t) {
  return [...t.matchAll(/\[\[test\]\]([^[]*)/g)].map(m => (m[1].match(/name\s*=\s*"([^"]+)"/) ?? [])[1] ?? null);
}

function inventory(tree, entrypoints) {
  const gates = new Map(), rustCandidates = [];
  for (const [p, oid] of tree) {
    const kind = classify(p);
    if (kind) gates.set(p, { oid, kind });
    else if (p.endsWith('.rs') && !excluded(p)) rustCandidates.push([p, oid]);
  }
  for (const e of entrypoints) if (!gates.has(e.invokes)) gates.set(e.invokes, { oid: tree.get(e.invokes), kind: 'ci_script' });
  readBlobs([...gates.values()].map(g => g.oid).concat(rustCandidates.map(([, o]) => o)));
  for (const [p, oid] of rustCandidates) {
    if (!gates.has(p) && (text(oid).match(PAT.rust_tests) ?? []).length > 0) gates.set(p, { oid, kind: 'rust_src' });
  }
  for (const g of gates.values()) g.metrics = metrics(g.kind, text(g.oid));
  return gates;
}

const RUST_FN = /#\[(?:tokio::)?test\b[^\n]*\n(?:\s*#\[[^\n]*\n)*\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/g;
const PESTER_IT = /^\s*It\s+(['"])(.*?)\1/gm;
const JS_T = /\b(?:test|it)\s*\(\s*(['"`])(.*?)\1/g;
// Names are keyed by file and name, so moving or deleting a case in one file is visible even when
// another file carries the same name.
function testNames(tree) {
  const out = { rust: new Map(), pester: new Map(), js: new Map() };
  const files = [];
  for (const [p, oid] of tree) {
    if (excluded(p)) continue;
    const low = p.toLowerCase();
    if (p.endsWith('.rs')) files.push([p, oid, 'rust', RUST_FN, 1]);
    else if (low.endsWith('.tests.ps1') || low.endsWith('.test.ps1')) files.push([p, oid, 'pester', PESTER_IT, 2]);
    else if (/\.test\.(mjs|js|cjs|ts)$/.test(p)) files.push([p, oid, 'js', JS_T, 2]);
  }
  readBlobs(files.map(f => f[1]));
  for (const [p, oid, kind, rx, g] of files) {
    const t = text(oid);
    if (kind === 'rust' && !t.includes('#[')) continue;
    for (const m of t.matchAll(rx)) {
      const k = `${p}|${m[g]}`;
      if (!out[kind].has(k)) out[kind].set(k, { path: p, name: m[g], line: t.slice(0, m.index).split('\n').length });
    }
  }
  return out;
}

// Structural lines of a workflow: job keys, step names, triggers, needs, if, uses and one-line run
// commands. The map stores the removed and added lines and check-map recomputes them.
const STRUCTURAL = /^(?:  [A-Za-z0-9_-]+:\s*$|\s*-?\s*(?:name|needs|if|uses|run|on|working-directory):\s*\S.*$|on:\s*$)/;
function structuralDiff(baseText, targetText) {
  const pick = t => lf(t).split('\n').map(l => l.replace(/\s+$/, '')).filter(l => STRUCTURAL.test(l));
  const a = pick(baseText), b = pick(targetText);
  const count = list => list.reduce((m, l) => m.set(l, (m.get(l) ?? 0) + 1), new Map());
  const ca = count(a), cb = count(b);
  const removed = [], added = [];
  for (const [l, n] of ca) for (let i = (cb.get(l) ?? 0); i < n; i++) removed.push(l);
  for (const [l, n] of cb) for (let i = (ca.get(l) ?? 0); i < n; i++) added.push(l);
  return { removed: removed.sort(), added: added.sort() };
}

export function computeFindings(ref, map) {
  const target = lsTree(ref);
  const entrypoints = discoverEntrypoints(target, map.local_runners ?? []);
  const targetInv = inventory(target, entrypoints), targetNames = testNames(target);
  const findings = [];
  for (const [base, commit] of Object.entries(map.bases)) {
    const baseTree = lsTree(commit), baseInv = inventory(baseTree, discoverEntrypoints(baseTree, map.local_runners ?? [])), baseNames = testNames(baseTree);
    for (const [p, a] of baseInv) {
      const b = targetInv.get(p);
      if (!b) { findings.push({ type: 'deleted-gate', base, path: p, kind: a.kind }); continue; }
      if (a.oid === b.oid) continue;
      for (const [k, old] of Object.entries(a.metrics)) {
        const now = b.metrics[k] ?? 0;
        if (!isSkip(k) && now < old) findings.push({ type: 'metric-decrease', base, path: p, metric: k, old, new: now });
      }
      for (const [k, now] of Object.entries(b.metrics)) {
        const old = a.metrics[k] ?? 0;
        if (isSkip(k) && now > old) findings.push({ type: 'skip-increase', base, path: p, metric: k, old, new: now });
      }
      if (a.kind === 'workflow') {
        findings.push({ type: 'workflow-changed', base, path: p, structural_diff: structuralDiff(text(a.oid), text(b.oid)) });
      }
      if (a.kind === 'cargo_manifest') {
        const after = new Set(cargoTargets(text(b.oid)));
        for (const name of cargoTargets(text(a.oid))) if (!after.has(name)) findings.push({ type: 'cargo-target-removed', base, path: p, name });
      }
    }
    for (const kind of ['rust', 'pester', 'js']) {
      for (const [k, loc] of baseNames[kind]) {
        if (!targetNames[kind].has(k)) findings.push({ type: 'name-absent', base, kind, path: loc.path, name: loc.name, base_line: loc.line });
      }
    }
  }
  const gates = [...targetInv].map(([p, g]) => ({ path: p, kind: g.kind })).sort((x, y) => (x.path < y.path ? -1 : 1));
  return { target, findings, gates, entrypoints };
}

// Findings are keyed by what the two trees show. A workflow row is keyed by path and base, never by blob
// ids; its structural diff is compared separately, so editing a workflow asks for the row to be
// regenerated, not re-keyed.
export const keyOf = f => {
  switch (f.type) {
    case 'metric-decrease': case 'skip-increase': return `${f.type}|${f.path}|${f.metric}|${f.old}|${f.new}`;
    case 'cargo-target-removed': return `${f.type}|${f.path}|${f.name}`;
    case 'name-absent': return `${f.type}|${f.kind}|${f.path}|${f.name}`;
    case 'workflow-changed': return `${f.type}|${f.path}|${f.base ?? (f.bases ?? [])[0]}`;
    default: return `${f.type}|${f.path}`;
  }
};

// A body anchor names one Pester It or one Rust fn and pins the normalized text of its whole block, so
// keeping the title and the Should count while weakening an expectation changes the digest.
const normalizeBlock = lines => lines.map(l => l.trim()).filter(Boolean).join('\n');
export function blockDigest(fileContent, anchor) {
  const lines = lf(fileContent).split('\n');
  const title = anchor.it !== undefined
    ? l => /^\s*It\s+(['"])(.*?)\1/.exec(l)?.[2] === anchor.it
    : l => new RegExp(`(?:^|\\s)fn\\s+${anchor.fn.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`).test(l);
  const starts = lines.map((l, i) => (title(l) ? i : -1)).filter(i => i >= 0);
  if (starts.length !== 1) return { error: starts.length === 0 ? 'block not found' : `block title occurs ${starts.length} times` };
  const start = starts[0];
  const indent = lines[start].match(/^\s*/)[0];
  let end = -1;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith(indent) && lines[i].slice(indent.length).replace(/\s+$/, '') === '}') { end = i; break; }
  }
  if (end < 0) return { error: 'block has no closing brace at its own indentation' };
  const block = lines.slice(start, end + 1);
  return { digest: sha256(normalizeBlock(block)), lines: block.length };
}
const TITLE_ONLY = /^(?:It\s+['"].*['"]|(?:pub\s+)?(?:async\s+)?fn\s+\w+\s*\(?)$/;
export const isWeakAnchor = a => a.contains !== undefined && TITLE_ONLY.test(a.contains.trim());

function main() {
  const args = process.argv.slice(2);
  const opt = name => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
  const ref = opt('--ref') ?? 'HEAD';
  const emitOnly = args.includes('--emit-findings');
  const mapSource = emitOnly && opt('--map') ? lf(fs.readFileSync(opt('--map'), 'utf8')) : show(`${ref}:${MAP_PATH}`);
  const map = JSON.parse(mapSource);
  if (map.schema !== SCHEMA) throw new Error(`unsupported map schema ${map.schema}`);

  const { target, findings, gates, entrypoints } = computeFindings(ref, map);
  if (emitOnly) {
    process.stdout.write(JSON.stringify({ ref, findings, gates, entrypoints }, null, 1) + '\n');
    process.exit(0);
  }

  const failures = [];
  const fileAt = p => fileText(target, p);
  for (const [name, commit] of Object.entries(map.bases)) if (!isAncestor(commit, ref)) failures.push(`base ${name} (${commit}) is not an ancestor of ${ref}`);

  function verifyAnchor(a, label) {
    const t = fileAt(a.path);
    if (t === null) { failures.push(`${label}: ${a.path} is absent at ${ref}`); return false; }
    if (a.contains !== undefined) {
      if (!lf(t).includes(a.contains)) { failures.push(`${label}: ${a.path} no longer contains ${JSON.stringify(a.contains)}`); return false; }
      return true;
    }
    if (a.it === undefined && a.fn === undefined) { failures.push(`${label}: anchor has neither contains nor it/fn`); return false; }
    const got = blockDigest(t, a);
    if (got.error) { failures.push(`${label}: ${a.path} ${a.it !== undefined ? `It '${a.it}'` : `fn ${a.fn}`}: ${got.error}`); return false; }
    if (got.digest !== a.body_sha256) { failures.push(`${label}: ${a.path} ${a.it !== undefined ? `It '${a.it}'` : `fn ${a.fn}`} body differs from the pinned digest`); return false; }
    return true;
  }
  function verifyAnchors(list, label, strong) {
    if (!Array.isArray(list) || list.length === 0) { failures.push(`${label}: no anchor`); return false; }
    let ok = true;
    for (const a of list) if (!verifyAnchor(a, label)) ok = false;
    if (strong && list.every(isWeakAnchor)) { failures.push(`${label}: every anchor is a test title; pin a body digest or an assertion line`); ok = false; }
    return ok;
  }

  const mapGates = new Map(map.gates.map(g => [g.path, g]));
  for (const g of gates) {
    const m = mapGates.get(g.path);
    if (!m) failures.push(`gate not in map: ${g.path} (${g.kind})`);
    else if (m.kind !== g.kind || !Array.isArray(m.q_ids) || m.q_ids.length === 0) failures.push(`gate row differs or has no Q-ID: ${g.path}`);
    mapGates.delete(g.path);
  }
  for (const p of mapGates.keys()) failures.push(`map lists a gate that is absent at ${ref}: ${p}`);

  const entryKey = e => `${e.source}|${e.line}|${e.invokes}`;
  const listedEntries = new Map(map.entrypoints.map(e => [entryKey(e), e]));
  for (const e of entrypoints) {
    const m = listedEntries.get(entryKey(e));
    if (!m) failures.push(`CI entrypoint not in map: ${entryKey(e)}`);
    listedEntries.delete(entryKey(e));
  }
  for (const k of listedEntries.keys()) failures.push(`map lists a CI entrypoint that is not invoked at ${ref}: ${k}`);
  for (const e of map.entrypoints) {
    const src = fileAt(e.source);
    if (src === null) { failures.push(`entrypoint source absent: ${e.source}`); continue; }
    if (e.line > 0 && !(lf(src).split('\n')[e.line - 1] ?? '').includes(e.text)) failures.push(`entrypoint text differs: ${entryKey(e)}`);
    if (e.line === 0 && e.source !== MAP_PATH && !lf(src).includes(e.text)) failures.push(`entrypoint text differs: ${entryKey(e)}`);
    if (e.source === MAP_PATH && !(map.local_runners ?? []).some(r => r.path === e.invokes && typeof r.invoked_by === 'string' && r.invoked_by.length > 0)) failures.push(`local runner without invoker: ${e.invokes}`);
    if (fileAt(e.invokes) === null) failures.push(`entrypoint target absent: ${e.invokes}`);
  }

  const pinByPath = new Map();
  for (const pin of map.pins) {
    pinByPath.set(pin.path, pin);
    const data = git(['cat-file', 'blob', pin.blob]);
    if (data.length !== pin.bytes || sha256(data) !== pin.sha256) failures.push(`pin ${pin.path}: blob bytes differ`);
    if (!isAncestor(pin.commit, ref)) failures.push(`pin ${pin.path}: ${pin.commit} is not an ancestor of ${ref}`);
    else if (git(['rev-parse', `${pin.commit}:${pin.path}`]).toString('utf8').trim() !== pin.blob) failures.push(`pin ${pin.path}: not the blob at ${pin.commit}`);
    if (fileAt(pin.path) !== null) failures.push(`pin ${pin.path}: a preserved record is back in the public tree at ${ref}`);
  }
  const pb = map.preservation_basis;
  const hasPreservationBasis = pb && typeof pb.sha256 === 'string' && /^[0-9a-f]{64}$/.test(pb.sha256) && Number.isInteger(pb.bytes) && pb.bytes > 0;

  const DISPOSITIONS = new Set(['guarded', 'preserved', 'retired', 'reclassified']);
  function verifyDisposition(c, label) {
    if (!DISPOSITIONS.has(c.disposition)) { failures.push(`no disposition: ${label}`); return; }
    if (typeof c.reason !== 'string' || c.reason.length < 20) failures.push(`no reason: ${label}`);
    switch (c.disposition) {
      case 'guarded':
        verifyAnchors(c.selectors, `${label} selectors`, true);
        break;
      case 'preserved':
        if (!Array.isArray(c.pins) || c.pins.length === 0) failures.push(`${label}: preserved without pins`);
        for (const p of c.pins ?? []) if (!pinByPath.has(p)) failures.push(`${label}: unknown pin ${p}`);
        verifyAnchors(c.basis, `${label} basis`, false);
        if (!hasPreservationBasis) failures.push(`${label}: preserved without a pinned preservation basis document`);
        break;
      case 'retired':
        verifyAnchors(c.basis, `${label} basis`, false);
        if (Array.isArray(c.selectors) && c.selectors.length > 0) verifyAnchors(c.selectors, `${label} selectors`, true);
        else if (typeof c.unguarded_reason !== 'string' || c.unguarded_reason.length < 40) failures.push(`${label}: retired without a guarding selector or an unguarded_reason`);
        break;
      case 'reclassified':
        verifyAnchors(c.basis, `${label} basis`, false);
        break;
    }
  }

  const byKey = new Map();
  for (const entry of map.findings) {
    const k = keyOf(entry);
    if (byKey.has(k)) failures.push(`duplicate map finding: ${k}`);
    byKey.set(k, { entry, bases: new Set(), finding: null });
  }
  let accounted = 0;
  for (const f of findings) {
    const hit = byKey.get(keyOf(f));
    if (!hit) { failures.push(`unaccounted finding (${f.base}): ${keyOf(f)}`); continue; }
    hit.bases.add(f.base);
    hit.finding = f;
    accounted++;
  }
  const counts = Object.fromEntries([...DISPOSITIONS].map(d => [d, 0]));
  for (const [k, { entry, bases, finding }] of byKey) {
    if (bases.size === 0) { failures.push(`stale map finding: ${k}`); continue; }
    const listed = new Set(entry.bases ?? []);
    if (listed.size !== bases.size || [...bases].some(b => !listed.has(b))) failures.push(`map finding bases differ: ${k} expected ${[...bases].join(',')}`);
    if (entry.type === 'workflow-changed') {
      if (JSON.stringify(entry.structural_diff) !== JSON.stringify(finding.structural_diff)) failures.push(`structural diff differs: ${k}`);
    }
    const components = Array.isArray(entry.components) ? entry.components : null;
    if (components && entry.disposition) failures.push(`both disposition and components: ${k}`);
    if (!components) { verifyDisposition(entry, k); counts[entry.disposition] = (counts[entry.disposition] ?? 0) + 1; continue; }
    if (components.length < 2) failures.push(`components need at least two parts: ${k}`);
    components.forEach((c, i) => { verifyDisposition(c, `${k} #${i + 1}`); counts[c.disposition] = (counts[c.disposition] ?? 0) + 1; });
    if (entry.type === 'metric-decrease') {
      // The per-commit attribution inside deltas is explanatory; only the tree-to-tree total is checked.
      const total = components.flatMap(c => c.deltas ?? []).reduce((s, d) => s + d.delta, 0);
      if (total !== entry.new - entry.old) failures.push(`component deltas sum to ${total}, finding is ${entry.new - entry.old}: ${k}`);
    }
  }

  const summary = {
    ref, tree: git(['rev-parse', `${ref}^{tree}`]).toString('utf8').trim(),
    gates: gates.length, entrypoints: entrypoints.length, findings: findings.length, map_findings: map.findings.length, accounted,
    by_disposition: counts, pins: map.pins.length, failures,
  };
  process.stdout.write(JSON.stringify(summary, null, 1) + '\n');
  process.exit(failures.length === 0 ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
