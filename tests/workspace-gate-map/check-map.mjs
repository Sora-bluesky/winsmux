// Recomputes every gate and every weakening finding between the fixed bases and a
// tree-ish, then requires gate-map.json to account for each one exactly.
// Usage: node check-map.mjs [--ref <tree-ish>] [--emit-findings]
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const ref = args.includes('--ref') ? args[args.indexOf('--ref') + 1] : 'HEAD';
const emitOnly = args.includes('--emit-findings');
const repo = path.resolve(here, '../..');
const map = JSON.parse(fs.readFileSync(path.join(here, 'gate-map.json'), 'utf8'));

function git(argv, input) {
  const r = spawnSync('git', ['-C', repo, ...argv], { input, maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`git ${argv.join(' ')}: ${r.stderr}`);
  return r.stdout;
}
const sha256 = buf => createHash('sha256').update(buf).digest('hex');
const lf = text => text.replace(/\r\n/g, '\n');

const EXCLUDE = ['.evidence/', '.references/', '.worktrees/', 'tasks/'];
function classify(p) {
  if (EXCLUDE.some(x => p.startsWith(x))) return null;
  const low = p.toLowerCase();
  if (/^(.*\/)?\.github\/workflows\/[^/]+\.ya?ml$/.test(p)) return 'workflow';
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
};
const metrics = (kind, text) => Object.fromEntries((METRICS[kind] ?? []).map(k => [k, (text.match(PAT[k]) ?? []).length]));
const isSkip = k => k.endsWith('skip') || k.endsWith('ignore');

function lsTree(treeish) {
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

function cargoTargets(t) {
  return [...t.matchAll(/\[\[test\]\]([^[]*)/g)].map(m => (m[1].match(/name\s*=\s*"([^"]+)"/) ?? [])[1] ?? null);
}

function inventory(tree) {
  const gates = new Map(), rustCandidates = [];
  for (const [p, oid] of tree) {
    const kind = classify(p);
    if (kind) gates.set(p, { oid, kind });
    else if (p.endsWith('.rs') && !EXCLUDE.some(x => p.startsWith(x))) rustCandidates.push([p, oid]);
  }
  readBlobs([...gates.values()].map(g => g.oid).concat(rustCandidates.map(([, o]) => o)));
  for (const [p, oid] of rustCandidates) {
    if ((text(oid).match(PAT.rust_tests) ?? []).length > 0) gates.set(p, { oid, kind: 'rust_src' });
  }
  for (const g of gates.values()) g.metrics = metrics(g.kind, text(g.oid));
  return gates;
}

const RUST_FN = /#\[(?:tokio::)?test\b[^\n]*\n(?:\s*#\[[^\n]*\n)*\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/g;
const PESTER_IT = /^\s*It\s+(['"])(.*?)\1/gm;
const JS_T = /\b(?:test|it)\s*\(\s*(['"`])(.*?)\1/g;
function testNames(tree) {
  const out = { rust: new Map(), pester: new Map(), js: new Map() };
  const files = [];
  for (const [p, oid] of tree) {
    if (EXCLUDE.some(x => p.startsWith(x))) continue;
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
      const loc = `${p}:${t.slice(0, m.index).split('\n').length}`;
      if (!out[kind].has(m[g])) out[kind].set(m[g], loc);
    }
  }
  return out;
}

function computeFindings() {
  const target = lsTree(ref), targetInv = inventory(target), targetNames = testNames(target);
  const findings = [];
  for (const [base, commit] of Object.entries(map.bases)) {
    const baseTree = lsTree(commit), baseInv = inventory(baseTree), baseNames = testNames(baseTree);
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
      if (a.kind === 'workflow') findings.push({ type: 'workflow-changed', base, path: p, base_blob: a.oid, target_blob: b.oid });
      if (a.kind === 'cargo_manifest') {
        const after = new Set(cargoTargets(text(b.oid)));
        for (const name of cargoTargets(text(a.oid))) if (!after.has(name)) findings.push({ type: 'cargo-target-removed', base, path: p, name });
      }
    }
    for (const kind of ['rust', 'pester', 'js']) {
      for (const [name, loc] of baseNames[kind]) {
        if (!targetNames[kind].has(name)) findings.push({ type: 'name-absent', base, kind, name, base_location: loc });
      }
    }
  }
  const gates = [...targetInv].map(([p, g]) => ({ path: p, kind: g.kind })).sort((x, y) => (x.path < y.path ? -1 : 1));
  return { target, findings, gates };
}

const keyOf = f => {
  switch (f.type) {
    case 'metric-decrease': case 'skip-increase': return `${f.type}|${f.path}|${f.metric}|${f.old}|${f.new}`;
    case 'workflow-changed': return `${f.type}|${f.path}|${f.base_blob}|${f.target_blob}`;
    case 'cargo-target-removed': return `${f.type}|${f.path}|${f.name}`;
    case 'name-absent': return `${f.type}|${f.kind}|${f.name}`;
    default: return `${f.type}|${f.path}`;
  }
};

const { target, findings, gates } = computeFindings();
if (emitOnly) {
  process.stdout.write(JSON.stringify({ ref, findings, gates }, null, 1) + '\n');
  process.exit(0);
}

const failures = [];
const fileAt = p => (target.has(p) ? (readBlobs([target.get(p)]), text(target.get(p))) : null);
function verifyAnchors(list, label) {
  if (!Array.isArray(list) || list.length === 0) { failures.push(`${label}: no selector or basis`); return; }
  for (const a of list) {
    const t = fileAt(a.path);
    if (t === null) failures.push(`${label}: ${a.path} is absent at ${ref}`);
    else if (!lf(t).includes(a.contains)) failures.push(`${label}: ${a.path} no longer contains ${JSON.stringify(a.contains)}`);
  }
}

const mapGates = new Map(map.gates.map(g => [g.path, g]));
for (const g of gates) {
  const m = mapGates.get(g.path);
  if (!m) failures.push(`gate not in map: ${g.path} (${g.kind})`);
  else if (m.kind !== g.kind || !Array.isArray(m.q_ids) || m.q_ids.length === 0) failures.push(`gate row differs or has no Q-ID: ${g.path}`);
  mapGates.delete(g.path);
}
for (const p of mapGates.keys()) failures.push(`map lists a gate that is absent at ${ref}: ${p}`);

const replayIds = new Set();
const replayFile = fileAt('tests/workspace-gate-map/preserved-contracts.test.ps1');
if (replayFile === null) failures.push('replay file absent');
for (const r of map.replays) {
  replayIds.add(r.id);
  const src = lf(git(['show', `${r.source.commit}:${r.source.path}`]).toString('utf8')).split('\n');
  const lines = r.source.lines ? r.source.lines.map(n => src[n - 1]) : src.slice(r.source.start_line - 1, r.source.end_line);
  if (sha256(lines.join('\n')) !== r.text_sha256) failures.push(`replay ${r.id}: source text digest differs`);
  const shifted = lines.map(l => (l ? '    ' + l : '')).join('\n');
  if (replayFile !== null && !lf(replayFile).includes(shifted)) failures.push(`replay ${r.id}: body is not carried verbatim`);
}
for (const pin of map.pins) {
  const data = git(['cat-file', 'blob', pin.blob]);
  if (data.length !== pin.bytes || sha256(data) !== pin.sha256) failures.push(`pin ${pin.path}: blob bytes differ`);
  if (git(['rev-parse', `${pin.commit}:${pin.path}`]).toString('utf8').trim() !== pin.blob) failures.push(`pin ${pin.path}: not the blob at ${pin.commit}`);
}

const byKey = new Map();
for (const entry of map.findings) {
  const k = keyOf(entry);
  if (byKey.has(k)) failures.push(`duplicate map finding: ${k}`);
  byKey.set(k, { entry, bases: new Set() });
}
let accounted = 0;
for (const f of findings) {
  const hit = byKey.get(keyOf(f));
  if (!hit) { failures.push(`unaccounted finding (${f.base}): ${keyOf(f)}`); continue; }
  hit.bases.add(f.base);
  accounted++;
}
const DISPOSITIONS = new Set(['restored', 'replaced', 'replayed', 'reclassified']);
for (const [k, { entry, bases }] of byKey) {
  if (bases.size === 0) { failures.push(`stale map finding: ${k}`); continue; }
  const listed = new Set(entry.bases ?? []);
  if (listed.size !== bases.size || [...bases].some(b => !listed.has(b))) failures.push(`map finding bases differ: ${k} expected ${[...bases].join(',')}`);
  if (!DISPOSITIONS.has(entry.disposition)) { failures.push(`no disposition: ${k}`); continue; }
  if (typeof entry.reason !== 'string' || entry.reason.length < 20) failures.push(`no reason: ${k}`);
  if (entry.disposition === 'replayed') {
    if (!Array.isArray(entry.replay_ids) || entry.replay_ids.length === 0) failures.push(`replayed without replay ids: ${k}`);
    for (const id of entry.replay_ids ?? []) if (!replayIds.has(id)) failures.push(`unknown replay id ${id}: ${k}`);
  }
  if (entry.disposition === 'restored' || entry.disposition === 'replaced') verifyAnchors(entry.selectors, k);
  if (entry.disposition === 'reclassified') verifyAnchors(entry.basis, k);
  if (entry.complements) verifyAnchors(entry.complements, `${k} complement`);
  if (entry.selectors && entry.disposition !== 'restored' && entry.disposition !== 'replaced') verifyAnchors(entry.selectors, k);
}

const summary = {
  ref, tree: git(['rev-parse', `${ref}^{tree}`]).toString('utf8').trim(),
  gates: gates.length, findings: findings.length, map_findings: map.findings.length, accounted,
  by_disposition: Object.fromEntries([...DISPOSITIONS].map(d => [d, map.findings.filter(e => e.disposition === d).length])),
  replays: map.replays.length, pins: map.pins.length, failures,
};
process.stdout.write(JSON.stringify(summary, null, 1) + '\n');
process.exit(failures.length === 0 ? 0 : 1);
