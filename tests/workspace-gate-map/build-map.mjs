// Regenerates gate-map.json from the tree at --ref and the dispositions in dispositions.mjs, so the map is a
// deterministic function of the tree and of the reviewed disposition data. Nothing is read from the working tree.
// Usage: node build-map.mjs [--ref <tree-ish>] (--check | --write <file> | --print)
//   --check  exit 1 unless the regenerated map equals the gate-map.json stored at --ref (CI runs this).
//   --write  write the regenerated map to <file>; --print writes it to stdout.
// Q-IDs and plan tasks of gates are annotations carried over from the map stored at --ref; a gate the stored
// map does not know gets Q-GATES. Everything else (findings, dispositions, anchors, entrypoints, pins) is rebuilt.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MAP_PATH, SCHEMA, blockDigest, computeFindings, fileText, git, keyOf, lf, lsTree } from './check-map.mjs';
import * as D from './dispositions.mjs';

const args = process.argv.slice(2);
const opt = name => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
const ref = opt('--ref') ?? 'HEAD';
const mode = args.includes('--check') ? 'check' : args.includes('--write') ? 'write' : 'print';

const tree = lsTree(ref);
let stored = null;
try { stored = JSON.parse(lf(git(['show', `${ref}:${MAP_PATH}`]).toString('utf8'))); } catch { stored = null; }
const storedGates = new Map((stored?.gates ?? []).map(g => [g.path, g]));

const { findings, gates, entrypoints } = computeFindings(ref, { bases: D.BASES, local_runners: D.LOCAL_RUNNERS });

const problems = [];
function resolveAnchor(a, label) {
  if (a.contains !== undefined) return { path: a.path, contains: a.contains };
  const content = fileText(tree, a.path);
  if (content === null) { problems.push(`${label}: ${a.path} is absent at ${ref}`); return a; }
  const got = blockDigest(content, a);
  if (got.error) { problems.push(`${label}: ${a.path} ${a.it !== undefined ? `It '${a.it}'` : `fn ${a.fn}`}: ${got.error}`); return a; }
  return a.it !== undefined ? { path: a.path, it: a.it, body_sha256: got.digest } : { path: a.path, fn: a.fn, body_sha256: got.digest };
}
function resolveBody(body, label) {
  const out = {};
  for (const [k, v] of Object.entries(body)) {
    if (k === 'selectors' || k === 'basis') out[k] = v.map(a => resolveAnchor(a, `${label} ${k}`));
    else if (k === 'components') out[k] = v.map((c, i) => resolveBody(c, `${label} #${i + 1}`));
    else out[k] = v;
  }
  return out;
}

// Group findings by key; each group becomes one map row with the bases that produced it.
const groups = new Map();
for (const f of findings) {
  const k = keyOf(f);
  if (!groups.has(k)) groups.set(k, { finding: f, bases: new Set() });
  groups.get(k).bases.add(f.base);
}
const matches = (row, f) => Object.entries(row.match).every(([mk, mv]) => f[mk] === mv);
const used = new Set();
const rows = [];
for (const [k, g] of groups) {
  const f = g.finding;
  const entry = {};
  for (const [x, v] of Object.entries(f)) if (x !== 'base' && x !== 'base_line') entry[x] = v;
  entry.bases = [...g.bases].sort();
  if (f.type === 'workflow-changed') {
    entry.base = f.base;
    const body = D.WORKFLOW_ROWS[f.path];
    if (!body) { problems.push(`no workflow disposition for ${f.path}`); continue; }
    used.add(`wf:${f.path}`);
    Object.assign(entry, resolveBody(body, k));
  } else {
    const hits = D.ROWS.map((r, i) => [r, i]).filter(([r]) => matches(r, f));
    if (hits.length !== 1) { problems.push(`${hits.length} dispositions match finding ${k}`); continue; }
    used.add(hits[0][1]);
    Object.assign(entry, resolveBody(hits[0][0].body, k));
  }
  rows.push(entry);
}
D.ROWS.forEach((r, i) => { if (!used.has(i)) problems.push(`disposition matches no finding: ${JSON.stringify(r.match)}`); });
for (const p of Object.keys(D.WORKFLOW_ROWS)) if (!used.has(`wf:${p}`)) problems.push(`workflow disposition matches no finding: ${p}`);
for (const row of rows) {
  if (row.type !== 'metric-decrease' || !row.components) continue;
  const total = row.components.flatMap(c => c.deltas ?? []).reduce((s, d) => s + d.delta, 0);
  if (total !== row.new - row.old) problems.push(`component deltas sum to ${total}, finding is ${row.new - row.old}: ${keyOf(row)}`);
}

const gateRows = gates.map(g => {
  const o = storedGates.get(g.path);
  return { path: g.path, kind: g.kind, q_ids: o?.q_ids?.length ? o.q_ids : ['Q-GATES'], plan_tasks: o?.plan_tasks ?? [] };
});

// Entrypoint text is the invoking line (workflow or script) or the path token inside a package.json script.
const lineCache = new Map();
const linesOf = p => { if (!lineCache.has(p)) lineCache.set(p, lf(fileText(tree, p) ?? '').split('\n')); return lineCache.get(p); };
const entryRows = entrypoints.map(e => {
  let text;
  if (e.source === MAP_PATH) text = e.invokes;
  else if (e.line > 0) text = (linesOf(e.source)[e.line - 1] ?? '').trim();
  else {
    const dir = path.posix.dirname(e.source);
    const rel = path.posix.relative(dir, e.invokes);
    text = rel.startsWith('../') ? rel : `./${rel}`;
    if (!(fileText(tree, e.source) ?? '').includes(text)) problems.push(`package token not found: ${text} in ${e.source}`);
  }
  return { source: e.source, line: e.line, text, invokes: e.invokes };
});

if (problems.length > 0) {
  process.stderr.write(problems.map(p => `build-map: ${p}`).join('\n') + '\n');
  process.exit(2);
}

const map = {
  schema: SCHEMA,
  task: 'TASK-882',
  rule: D.RULE,
  dispositions: D.DISPOSITIONS,
  bases: D.BASES,
  local_runners: D.LOCAL_RUNNERS,
  preservation_basis: D.PRESERVATION_BASIS,
  pins: D.PINS,
  findings: rows,
  entrypoints: entryRows,
  gates: gateRows,
};
const json = JSON.stringify(map, null, 1) + '\n';
if (mode === 'print') process.stdout.write(json);
else if (mode === 'write') fs.writeFileSync(opt('--write'), json);
else {
  const storedText = stored ? lf(git(['show', `${ref}:${MAP_PATH}`]).toString('utf8')) : null;
  if (storedText === json) { process.stdout.write(`gate-map.json at ${ref} equals the regenerated map (${rows.length} findings, ${gateRows.length} gates, ${entryRows.length} entrypoints)\n`); process.exit(0); }
  const a = (storedText ?? '').split('\n'), b = json.split('\n');
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  process.stdout.write(`gate-map.json at ${ref} differs from the regenerated map at line ${i + 1}:\n  stored: ${a[i] ?? '<end>'}\n  rebuilt: ${b[i] ?? '<end>'}\n`);
  process.exit(1);
}
