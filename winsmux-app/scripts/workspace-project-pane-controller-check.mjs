import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(app, '..');
const dependencyIndex = process.argv.indexOf('--dependency-root');
const dependencyRoot = dependencyIndex < 0 ? app : resolve(process.argv[dependencyIndex + 1]);
const require = createRequire(resolve(dependencyRoot, 'package.json'));
const ts = require('typescript');
const { build } = require('esbuild');
const evidenceIndex = process.argv.indexOf('--evidence-dir');
const evidence = evidenceIndex < 0 ? resolve(root, '.evidence/rebuild/v0.38.0/TASK-871/controller') : resolve(process.argv[evidenceIndex + 1]);
mkdirSync(evidence, { recursive: true });
const taskTemp = resolve(evidence, 'temp');
mkdirSync(taskTemp, { recursive: true });
process.env.TEMP = taskTemp;
process.env.TMP = taskTemp;
const started = new Date().toISOString();
const run = `controller-${started.replaceAll(/[:.]/g, '-')}`;
const sourcePath = resolve(app, 'src/workspace-ui/project-pane-controller.ts');
const source = readFileSync(sourcePath, 'utf8');
const args = [require.resolve('typescript/bin/tsc'), '--noEmit', '--target', 'ES2022', '--module', 'ESNext', '--lib', 'ES2022,DOM,DOM.Iterable', '--moduleResolution', 'bundler', '--strict', '--noUnusedLocals', '--noUnusedParameters', '--noFallthroughCasesInSwitch', '--isolatedModules', sourcePath];
const compile = spawnSync(process.execPath, args, { encoding: 'utf8' });
writeFileSync(resolve(evidence, `${run}-typescript.txt`), compile.stdout + compile.stderr, 'utf8');
const checks = [];
let failure = null;
let browserSources = [];
const identity = paths => paths.map(path => { const bytes = readFileSync(path); return { path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }; });
const before = identity([sourcePath, fileURLToPath(import.meta.url), resolve(root, 'core/crates/winsmux-workspace/schema/response.schema.json')]);
try {
  assert.equal(compile.status, 0, compile.stdout + compile.stderr);
  const modulePath = resolve(evidence, `${run}.mjs`);
  writeFileSync(modulePath, ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText, 'utf8');
  const { createProjectPaneController, guardedCloseParams, foldStage, decideStage, runReadData, foldRunReadiness } = await import(pathToFileURL(modulePath).href);
  const uuid = n => `${String(n).padStart(8, '0')}-0000-4000-8000-000000000000`;
  const I = uuid(1), P = uuid(3), B = uuid(4), R = uuid(5), R2 = uuid(6), P2 = uuid(7), B2 = uuid(8);
  const errorSchema = JSON.parse(readFileSync(resolve(root, 'core/crates/winsmux-workspace/schema/response.schema.json'), 'utf8')).definitions.WireError;
  const errors = Object.fromEntries(errorSchema.oneOf.map(row => [row.properties.code.const, { code: row.properties.code.const, retryable: row.properties.retryable.const, message: row.properties.message.const, target_id: null }]));
  const codes = Object.keys(errors);
  const obs = (run = R, pane = B, process = 'running', evidence = 'unavailable', current = true) => ({ run_id: run, pane_id: pane, process, evidence, current, observed_at: '2026-09-26T00:00:00.000Z', work: evidence === 'process_exit' ? 'interrupted' : 'unknown', exit_code: evidence === 'process_exit' ? 0 : null });
  function harness({ override, picker = async () => 'C:/synthetic/project', created = true, run = R } = {}) {
    const requests = [], settlements = [], snapshots = [], installations = [];
    const ownerKey = Object.freeze({ instanceId: I, ownerGeneration: '1' });
    let currentOwner = ownerKey;
    let revision = 7, selected = P, selectedPane = B, process = 'running', current = run, cleanupComplete = null;
    let rows = [{ project_id: P, root_state: 'verified', display_name: 'same', path: 'C:/synthetic/one' }, { project_id: P2, root_state: 'verified', display_name: 'same', path: 'C:/synthetic/two' }];
    let paneRows = [{ pane_id: B, project_id: P, current_run_id: current, observation: current === null ? null : obs(current), display_name: 'pane', path: 'C:/synthetic/one' }];
    const response = (req, data) => ({ schema_version: 1, instance_id: I, operation_id: req.operation_id, accepted: true, topology_revision: revision, event_seq: revision, result: { operation: req.operation, data }, error: null });
    const error = (req, code) => ({ ...response(req, null), accepted: false, result: null, error: errors[code] });
    const standard = req => {
      switch (req.operation) {
        case 'capabilities.get': return response(req, { schema_version: 1, operations: ['capabilities.get', 'project.list', 'pane.list', 'project.open', 'project.select', 'project.forget', 'pane.create', 'pane.split', 'pane.select', 'pane.resize', 'pane.close', 'run.interrupt', 'run.get', 'operation.get'], max_message_bytes: 1048576, providers: [{ provider: 'codex', version: '1' }], shell_profile_ids: ['pwsh'], replay_capacity: { retained_bytes: 134217728, active_bytes: 268435456 } });
        case 'project.list': return response(req, { projects: rows, selected_project_id: selected });
        case 'pane.list': { const list = paneRows.filter(row => row.project_id === req.params.project_id).map(row => ({ ...row, current_run_id: row.pane_id === B ? current : row.current_run_id, observation: row.pane_id === B ? current === null ? null : obs(current, B, process, process === 'exited' ? 'process_exit' : 'unavailable') : row.observation })); return response(req, { project_id: req.params.project_id, panes: list, root: list.length === 0 ? null : list.length === 1 ? { kind: 'leaf', pane_id: list[0].pane_id } : { kind: 'split', axis: 'horizontal', ratio: 0.5, first: { kind: 'leaf', pane_id: list[0].pane_id }, second: { kind: 'leaf', pane_id: list[1].pane_id } }, selected_pane_id: list.some(row => row.pane_id === selectedPane) ? selectedPane : null }); }
        case 'project.open': revision++; return response(req, { project_id: P, created });
        case 'project.select': selected = req.params.project_id; selectedPane = null; revision++; return response(req, { selected_project_id: selected, selected_pane_id: null });
        case 'pane.create': case 'pane.split': { paneRows = [...paneRows, { pane_id: B2, project_id: req.operation === 'pane.create' ? req.params.project_id : P, current_run_id: R2, observation: obs(R2, B2), display_name: 'new', path: 'C:/synthetic/two' }]; revision++; return response(req, { pane_id: B2, run_id: R2 }); }
        case 'pane.select': selectedPane = req.params.pane_id; revision++; return response(req, { selected_project_id: selected, selected_pane_id: selectedPane });
        case 'pane.resize': return response(req, structuredClone(req.params));
        case 'run.interrupt': return response(req, { run_id: req.params.run_id, phase: 'accepted' });
        case 'run.get': return response(req, { run: obs(req.params.run_id, B, process, process === 'exited' ? 'process_exit' : 'unavailable', current === req.params.run_id), ...(req.params.include_cleanup === true ? { cleanup_complete: cleanupComplete ?? process === 'exited' } : {}) });
        case 'operation.get': return response(req, { operation: { operation_id: req.params.operation_id, phase: 'completed', outcome: 'succeeded', error_code: null } });
        case 'pane.close': assert.ok(Object.hasOwn(req.params, 'expected_current_run_id')); if (req.params.expected_current_run_id !== current) return error(req, 'target_not_found'); paneRows = paneRows.filter(row => row.pane_id !== req.params.pane_id); selectedPane = null; revision++; return response(req, { pane_id: req.params.pane_id, closed: true, selected_pane_id: null });
        case 'project.forget': rows = rows.filter(row => row.project_id !== req.params.project_id); if (selected === req.params.project_id) selected = null; revision++; return response(req, { project_id: req.params.project_id, removed: true });
        default: throw new Error(`Unexpected request ${req.operation}`);
      }
    };
    const port = { ownerKey, async exchange(req) { if (req.operation === 'operation.get') throw new Error('recovery_port_required'); requests.push(structuredClone(req)); const custom = override ? await override(req, { response, error, standard }) : undefined; return custom === undefined ? standard(req) : custom; },
      async recover(origin, req) { if (req.operation !== 'operation.get' || origin.instanceId !== currentOwner.instanceId || origin.ownerGeneration !== currentOwner.ownerGeneration) throw new Error('owner_mismatch'); requests.push(structuredClone(req)); const custom = override ? await override(req, { response, error, standard }) : undefined; return custom === undefined ? standard(req) : custom; } };
    const controller = createProjectPaneController({ instanceId: I, generation: 'g', ownerKey, pickFolder: picker, port, snapshot: s => snapshots.push(s), settlement: (ticket, result) => settlements.push({ ticket, ...result }), installation: (data, message) => installations.push({ data, message }) });
    const intent = (kind, extra = {}) => ({ instanceId: I, generation: 'g', topologyRevision: controller.getSnapshot().topologyRevision, ...(kind === 'open-folder' ? {} : { projectId: P }), ...(['select-pane', 'resize-pane', 'split-pane', 'close-pane', 'interrupt-run'].includes(kind) ? { paneId: B, runId: current } : {}), kind, ...extra });
    return { controller, requests, settlements, snapshots, installations, intent, setOwnerGeneration(value) { currentOwner = { instanceId: I, ownerGeneration: value }; }, setExit(value = 'exited') { process = value; }, setCurrent(value) { current = value; }, setCleanup(value) { cleanupComplete = value; }, effects() { return requests.filter(req => !['capabilities.get', 'project.list', 'pane.list', 'run.get', 'operation.get'].includes(req.operation)); } };
  }
  async function test(name, fn) { await fn(); checks.push({ name, passed: true }); }
  const ready = async options => { const h = harness(options); await h.controller.refresh(); assert.equal(h.controller.getSnapshot().availability, 'available'); return h; };
  const flush = async () => { for (let n = 0; n < 12; n++) await new Promise(resolve => setImmediate(resolve)); };
  const perform = async (h, intent, ticket = 1) => { const outcome = await h.controller.control(intent, ticket); await flush(); return outcome; };

  for (const remaining of [false, true]) for (const cleanup of [false, true]) for (const fenced of [false, true]) await test(`shared historical exit separates completion from continuation remaining=${remaining}/cleanup=${cleanup}/fenced=${fenced}`, () => {
    const base = { kind: 'interrupt', remaining, fenced, knowledge: 'success', exitFact: 'running', targetFact: remaining ? 'awaiting' : 'not_required', dataComplete: true, contradiction: false, live: true, nextIssued: false, continuationCleanup: remaining ? 'awaiting' : 'not_required' };
    const data = { run: obs(R, B, 'exited', 'process_exit', false), ...(cleanup ? { cleanup_complete: true } : {}) };
    const read = runReadData(data, R, cleanup); assert.ok(read);
    const next = foldRunReadiness(base, read, B);
    assert.equal(next.exitFact, 'exited_same'); assert.equal(next.fenced, true);
    assert.equal(next.targetFact, remaining ? 'changed' : 'not_required');
    assert.notEqual(next.continuationCleanup, 'ready'); assert.equal(decideStage(next), remaining ? 'settle_partial_refused' : 'settle_completed');
    const later = foldRunReadiness(next, runReadData({ ...data, run: { ...data.run, current: true } }, R, cleanup), B);
    assert.equal(later.fenced, true); assert.notEqual(decideStage(later), 'advance_once');
    assert.equal(foldRunReadiness(base, read, B2).exitFact, 'unknown');
    for (const knowledge of ['unknown', 'failure', 'unresolved', 'awaiting_record']) assert.deepEqual(foldRunReadiness({ ...base, knowledge }, read, B), { ...base, knowledge });
  });
  for (const includeCleanup of [false, true]) for (const corrupt of ['wrong_id', 'extra_data', 'extra_run', 'current_type', 'timestamp', 'work', ...(includeCleanup ? ['cleanup_missing', 'cleanup_type', 'cleanup_without_exit'] : [])]) await test(`shared decoder rejects malformed ${corrupt}/cleanup=${includeCleanup}`, () => {
    const data = { run: obs(R, B, 'exited', 'process_exit', false), ...(includeCleanup ? { cleanup_complete: true } : {}) };
    if (corrupt === 'wrong_id') data.run.run_id = R2;
    if (corrupt === 'extra_data') data.extra = true;
    if (corrupt === 'extra_run') data.run.extra = true;
    if (corrupt === 'current_type') data.run.current = 'false';
    if (corrupt === 'timestamp') data.run.observed_at = '2026-02-30T00:00:00Z';
    if (corrupt === 'work') data.run.work = 'running';
    if (corrupt === 'cleanup_missing') delete data.cleanup_complete;
    if (corrupt === 'cleanup_type') data.cleanup_complete = 'true';
    if (corrupt === 'cleanup_without_exit') data.run = obs(R, B);
    assert.equal(runReadData(data, R, includeCleanup), null);
  });
  for (const kind of ['interrupt-run', 'close-pane']) for (const lost of [false, true]) for (const earlyHistory of [false, true]) await test(`history settles captured controller scope ${kind}/lost=${lost}/early=${earlyHistory}`, async () => {
    const h = await ready({ override(req) { if (lost && req.operation === 'run.interrupt') throw new Error('lost original interrupt'); } });
    const captured = h.intent(kind, kind === 'close-pane' ? { interruptFirst: true } : {});
    await perform(h, captured, 71); const original = h.effects()[0].operation_id;
    h.setCurrent(R2);
    if (earlyHistory) {
      await h.controller.refresh(); await flush(); assert.ok(h.controller.getPending()); assert.equal(h.controller.getPending().facts.fenced, true);
      h.setCurrent(R); await h.controller.refresh(); assert.equal(h.controller.getPending().facts.fenced, true); h.setCurrent(R2);
    }
    h.setExit(); await h.controller.refresh(); await h.controller.refresh(); await flush();
    assert.equal(h.controller.getPending(), null); assert.equal(h.controller.getSnapshot().busy, false);
    assert.equal(h.settlements.at(-1).ticket, 71); assert.equal(h.settlements.at(-1).disposition, kind === 'interrupt-run' ? 'completed' : 'refused');
    assert.deepEqual(h.effects().map(r => [r.operation, r.operation_id]), [['run.interrupt', original]]);
    assert.ok(h.requests.filter(r => r.operation === 'operation.get').every(r => r.params.operation_id === original));
    assert.equal(h.controller.getSnapshot().panes.panes[0].current_run_id, R2);
    const newIntent = h.intent('resize-pane', { rows: 25, cols: 90 });
    assert.equal((await perform(h, newIntent, 72)).disposition, 'completed');
    assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt', 'pane.resize']);
    assert.equal(h.effects().at(-1).params.run_id, R2); h.controller.dispose();
  });

  await test('same current interrupt-close waits for cleanup then uses one original guard', async () => {
    const h = await ready(); h.setCleanup(false);
    await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setExit();
    await h.controller.refresh(); await flush();
    assert.equal(h.controller.getPending().facts.exitFact, 'exited_same');
    assert.equal(h.controller.getPending().facts.continuationCleanup, 'awaiting');
    assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']);
    h.setCleanup(true); await h.controller.refresh(); await h.controller.refresh(); await flush();
    assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt', 'pane.close']);
    assert.equal(h.effects().at(-1).params.expected_current_run_id, R);
    assert.equal(h.settlements.at(-1).disposition, 'completed');
  });
  await test('lost interrupt close settles predecessor without waiting for cleanup or sending close', async () => {
    const h = await ready({ override(req) { if (req.operation === 'run.interrupt') throw new Error('lost original response'); } });
    h.setCleanup(false); await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setExit();
    await h.controller.refresh(); await flush(); assert.equal(h.controller.getPending(), null);
    assert.equal(h.settlements.at(-1).disposition, 'refused'); assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']);
    h.setCleanup(true); await h.controller.refresh(); assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']);
  });
  await test('disposed cleanup wait cannot close after later cleanup completion', async () => {
    const h = await ready(); h.setCleanup(false); await perform(h, h.intent('close-pane', { interruptFirst: true }));
    h.setExit(); await h.controller.refresh(); h.controller.dispose(); h.setCleanup(true); await h.controller.refresh();
    assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']);
  });
  for (const invalid of [undefined, null, 'true', 0]) await test(`invalid cleanup ${String(invalid)} cannot authorize close`, async () => {
    const h = await ready({ override(req, api) { if (req.operation === 'run.get' && req.params.include_cleanup) { const response = api.standard(req); if (invalid === undefined) delete response.result.data.cleanup_complete; else response.result.data.cleanup_complete = invalid; return response; } } });
    await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setExit(); await h.controller.refresh();
    assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']); assert.equal(h.controller.getPending().facts.continuationCleanup, 'unknown'); h.controller.dispose();
  });
  await test('cleanup facts preserve the legacy pure contract and cannot authorize running or fenced continuations', () => {
    const base = { kind: 'interrupt', remaining: true, fenced: false, knowledge: 'success', exitFact: 'exited_same', targetFact: 'awaiting', dataComplete: true, contradiction: false, live: true, nextIssued: false };
    assert.equal(decideStage(base), 'inspect_snapshot');
    for (const [cleanup, decision] of [['awaiting', 'inspect_run'], ['unknown', 'hold_unknown'], ['ready', 'inspect_snapshot']]) {
      const facts = { ...base, continuationCleanup: cleanup }; assert.equal(decideStage(facts), decision);
      assert.equal(decideStage({ ...facts, exitFact: 'running' }), 'inspect_run');
      assert.equal(decideStage({ ...facts, fenced: true }), 'settle_partial_refused');
      assert.equal(decideStage({ ...facts, dataComplete: false }), 'settle_partial_refused');
    }
  });
  await test('guard builder preserves null and run, denies omission/undefined/unknown fields before a request', () => {
    assert.deepEqual(guardedCloseParams({ pane_id: B, expected_current_run_id: null }), { pane_id: B, expected_current_run_id: null });
    assert.equal(guardedCloseParams({ pane_id: B, expected_current_run_id: R }).expected_current_run_id, R);
    for (const v of [{ pane_id: B }, { pane_id: B, expected_current_run_id: undefined }, { pane_id: B, expected_current_run_id: false }, { pane_id: B, expected_current_run_id: 'invalid' }, { pane_id: B, expected_current_run_id: R, unknown: 1 }]) assert.throws(() => guardedCloseParams(v));
  });
  for (const [kind, extra, expected] of [
    ['select-project', { projectId: P2 }, ['project.select']], ['forget-project', {}, ['project.forget']], ['create-pane', {}, ['pane.create', 'pane.select']],
    ['split-pane', { axis: 'vertical' }, ['pane.split', 'pane.select']], ['select-pane', {}, ['pane.select']], ['resize-pane', { rows: 32767, cols: 1 }, ['pane.resize']],
  ]) await test(`explicit ${kind} sends exactly its fixed operation list`, async () => { const h = await ready(); assert.equal((await perform(h, h.intent(kind, extra))).disposition, 'completed'); assert.deepEqual(h.effects().map(r => r.operation), expected); assert.equal(new Set(h.requests.map(r => r.operation_id)).size, h.requests.length); assert.ok(!h.requests.some(r => r.operation === 'shell.launch')); });
  for (const created of [true, false]) await test(`open folder created=${created} never starts restored runs or adds a launch`, async () => { const h = await ready({ created }); assert.equal((await perform(h, h.intent('open-folder'))).disposition, 'completed'); assert.deepEqual(h.effects().map(r => r.operation), created ? ['project.open', 'project.select', 'pane.create', 'pane.select'] : ['project.open', 'project.select']); assert.deepEqual(h.effects().map(r => r.expected_topology_revision), created ? [7, 8, 9, 10] : [7, 8]); });
  await test('picker cancellation is complete with zero effects', async () => { const h = await ready({ picker: async () => null }); assert.equal((await perform(h, h.intent('open-folder'))).disposition, 'completed'); assert.equal(h.effects().length, 0); });
  await test('synchronous admission protects delayed picker, direct duplicate and dispose', async () => { let release; const h = await ready({ picker: () => new Promise(done => { release = done; }) }); const first = h.controller.control(h.intent('open-folder'), 1); assert.equal((await h.controller.control(h.intent('create-pane'), 2)).disposition, 'refused'); h.controller.dispose(); release('C:/synthetic/project'); assert.equal((await first).disposition, 'unknown'); await flush(); assert.equal(h.effects().length, 0); });
  for (const extra of [{ instanceId: uuid(99) }, { generation: 'old' }, { topologyRevision: 6 }, { projectId: P2 }, { paneId: B2 }, { runId: R2 }, { rows: 0 }, { cols: 32768 }, { cols: 1.5 }]) await test(`identity/resize admission denies ${JSON.stringify(extra)}`, async () => { const h = await ready(); assert.equal((await perform(h, h.intent('resize-pane', { rows: 24, cols: 80, ...extra }))).disposition, 'refused'); assert.equal(h.effects().length, 0); });
  for (const run of [null, R]) await test(`direct close has explicit expectation ${run ?? 'null'}`, async () => { const h = await ready({ run }); h.setExit(); await h.controller.refresh(); assert.equal((await perform(h, h.intent('close-pane'))).disposition, 'completed'); const close = h.effects().at(-1); assert.deepEqual(close.params, { pane_id: B, expected_current_run_id: run }); });
  for (const compound of [false, true]) await test(`direct interrupt compound=${compound} waits for exact process exit`, async () => { const h = await ready(); const intent = h.intent(compound ? 'close-pane' : 'interrupt-run', compound ? { interruptFirst: true } : {}); assert.equal((await perform(h, intent)).disposition, 'unknown'); assert.equal(h.effects().length, 1); assert.equal(h.controller.getPending().facts.fenced, false); await h.controller.refresh(); assert.equal(h.effects().length, 1); h.setExit(); await h.controller.refresh(); if (compound) await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'completed'); assert.deepEqual(h.effects().map(r => r.operation), compound ? ['run.interrupt', 'pane.close'] : ['run.interrupt']); });
  for (const compound of [false, true]) await test(`lost interrupt compound=${compound} recovers acknowledgement but never recovers continuation authority`, async () => { const h = await ready({ override(req) { if (req.operation === 'run.interrupt') throw new Error('transport closed'); } }); assert.equal((await perform(h, h.intent(compound ? 'close-pane' : 'interrupt-run', compound ? { interruptFirst: true } : {}))).disposition, 'unknown'); const original = h.effects()[0]; await h.controller.refresh(); assert.equal(h.controller.getPending().facts.knowledge, 'success'); assert.equal(h.controller.getPending().facts.fenced, true); assert.equal(h.settlements.at(-1).disposition, 'unknown'); h.setExit(); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, compound ? 'refused' : 'completed'); assert.deepEqual(h.effects().map(r => r.operation), ['run.interrupt']); assert.equal(h.requests.find(r => r.operation === 'operation.get').params.operation_id, original.operation_id); });
  await test('original owner key gates project recovery before any old-ID read', async () => {
    const h = await ready({ override(req) { if (req.operation === 'pane.resize') throw new Error('reply lost'); } });
    assert.equal((await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 }))).disposition, 'unknown');
    const original = h.effects()[0]; h.setOwnerGeneration('2');
    await h.controller.refresh(); await flush();
    assert.equal(h.requests.filter(req => req.operation === 'operation.get').length, 0);
    assert.equal(h.requests.filter(req => req.operation_id === original.operation_id).length, 1);
    assert.equal(h.controller.getPending().request.operation_id, original.operation_id);
    h.setOwnerGeneration('1'); await h.controller.refresh(); await flush();
    assert.equal(h.requests.filter(req => req.operation === 'operation.get' && req.params.operation_id === original.operation_id).length, 1);
    assert.equal(h.requests.filter(req => req.operation_id === original.operation_id).length, 1);
  });
  await test('read-only interrupt failure retains direct acceptance and allows later exact exit and target confirmation', async () => { let broken = true; const h = await ready({ override(req) { if (req.operation === 'run.get' && broken) throw new Error('read failure'); } }); await perform(h, h.intent('close-pane', { interruptFirst: true })); assert.equal(h.controller.getPending().facts.fenced, false); broken = false; h.setExit(); await h.controller.refresh(); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'completed'); assert.equal(h.effects().filter(r => r.operation === 'pane.close').length, 1); });
  await test('changed current after interrupt cannot retarget close', async () => { const h = await ready(); await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setCurrent(R2); h.setExit(); await h.controller.refresh(); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'refused'); assert.equal(h.effects().length, 1); });
  await test('replacement between snapshot and guarded close is correlated refusal without fallback', async () => { const h = await ready({ override(req) { if (req.operation === 'pane.close') h.setCurrent(R2); } }); await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setExit(); await h.controller.refresh(); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'refused'); assert.deepEqual(h.effects().at(-1).params, { pane_id: B, expected_current_run_id: R }); assert.equal(h.effects().length, 2); });
  for (const code of codes) {
    await test(`original code ${code} follows central settlement`, async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') return api.error(req, code); } }); const result = await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); assert.equal(result.disposition, ['state_unknown', 'in_progress'].includes(code) ? 'unknown' : 'refused'); assert.equal(h.effects().length, 1); });
    await test(`query outer code ${code} is not evidence about the original effect`, async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') throw new Error('no response'); if (req.operation === 'operation.get') return api.error(req, code); } }); await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); await h.controller.refresh(); assert.equal(h.controller.getPending().facts.knowledge, 'awaiting_record'); assert.equal(h.effects().length, 1); });
    await test(`query inner code ${code} preserves code meaning`, async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') throw new Error('no response'); if (req.operation === 'operation.get') return api.response(req, { operation: { operation_id: req.params.operation_id, phase: 'completed', outcome: 'failed', error_code: code } }); } }); await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, ['state_unknown', 'in_progress'].includes(code) ? 'unknown' : 'refused'); assert.equal(h.effects().length, 1); });
  }
  for (const phase of ['accepted', 'in_progress', 'completed', 'unknown']) for (const outcome of [null, 'succeeded', 'failed']) for (const code of [null, 'state_unknown', 'runtime_failed', 'unmodeled']) await test(`query phase relation ${phase}/${outcome}/${code}`, async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') throw new Error('no response'); if (req.operation === 'operation.get') return api.response(req, { operation: { operation_id: req.params.operation_id, phase, outcome, error_code: code } }); } }); await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); await h.controller.refresh(); await flush(); const legalSuccess = phase === 'completed' && outcome === 'succeeded' && code === null; const legalFailure = phase === 'completed' && outcome === 'failed' && code === 'runtime_failed'; assert.equal(h.settlements.at(-1).disposition, legalSuccess ? 'completed' : legalFailure ? 'refused' : 'unknown'); assert.equal(h.effects().length, 1); });
  const corrupt = [v => ({ ...v, instance_id: R2 }), v => ({ ...v, operation_id: R2 }), v => ({ ...v, schema_version: 2 }), v => ({ ...v, event_seq: -1 }), v => ({ ...v, extra: true }), v => ({ ...v, error: errors.runtime_failed }), v => ({ ...v, result: { ...v.result, operation: 'pane.select' } }), v => ({ ...v, result: { ...v.result, data: { ...v.result.data, run_id: R2 } } })];
  for (let n = 0; n < corrupt.length; n++) await test(`invalid direct response ${n} holds awaiting record and can recover single stage`, async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') return corrupt[n](api.standard(req)); } }); await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); assert.equal(h.controller.getPending().facts.knowledge, 'awaiting_record'); assert.equal(h.controller.getPending().facts.fenced, true); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'completed'); assert.equal(h.effects().length, 1); });
  await test('saved state_unknown never becomes success through query or later exit', async () => { const h = await ready({ override(req, api) { if (req.operation === 'run.interrupt') return api.error(req, 'state_unknown'); } }); await perform(h, h.intent('close-pane', { interruptFirst: true })); h.setExit(); await h.controller.refresh(); assert.equal(h.controller.getPending().facts.knowledge, 'unknown'); assert.equal(h.effects().length, 1); assert.equal(h.settlements.at(-1).disposition, 'unknown'); });
  await test('lost compound create data stops with partial result and no fabricated pane selection', async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.create') { api.standard(req); throw new Error('lost created ID'); } } }); await perform(h, h.intent('create-pane')); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'refused'); assert.deepEqual(h.effects().map(r => r.operation), ['pane.create']); assert.equal(h.controller.getSnapshot().panes.panes.length, 2); });
  await test('compound final lost response can complete without new continuation', async () => { const h = await ready({ override(req, api) { if (req.operation === 'pane.select') { api.standard(req); throw new Error('lost final'); } } }); await perform(h, h.intent('create-pane')); await h.controller.refresh(); await flush(); assert.equal(h.settlements.at(-1).disposition, 'completed'); assert.deepEqual(h.effects().map(r => r.operation), ['pane.create', 'pane.select']); });
  await test('confirmed effect remains confirmed when post-control display read fails', async () => { let broken = false; const h = await ready({ override(req, api) { if (req.operation === 'pane.resize') { broken = true; return api.standard(req); } if (broken && req.operation === 'project.list') throw new Error('display read'); } }); const done = await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); assert.equal(done.disposition, 'completed'); assert.equal(h.controller.getPending(), null); assert.equal(h.controller.getSnapshot().availability, 'unavailable'); broken = false; await h.controller.refresh(); assert.equal(h.controller.getSnapshot().availability, 'available'); assert.equal(h.effects().length, 1); });
  for (const corruptData of [d => ({ ...d, selected_project_id: R2 }), d => ({ ...d, projects: [...d.projects, d.projects[0]] })]) await test('project snapshot invalid references deny controls', async () => { const h = harness({ override(req, api) { if (req.operation === 'project.list') return api.response(req, corruptData(api.standard(req).result.data)); } }); await h.controller.refresh(); assert.equal(h.controller.getSnapshot().availability, 'unavailable'); assert.equal((await perform(h, h.intent('create-pane'))).disposition, 'refused'); assert.equal(h.effects().length, 0); });
  for (const corruptData of [d => ({ ...d, selected_pane_id: R2 }), d => ({ ...d, panes: [...d.panes, d.panes[0]] }), d => ({ ...d, root: null }), d => ({ ...d, panes: [{ ...d.panes[0], observation: obs(R2) }] }), d => ({ ...d, root: { ...d.root, extra: 1 } })]) await test('pane snapshot invalid domain denies controls', async () => { const h = harness({ override(req, api) { if (req.operation === 'pane.list') return api.response(req, corruptData(api.standard(req).result.data)); } }); await h.controller.refresh(); assert.equal(h.controller.getSnapshot().availability, 'unavailable'); assert.equal(h.effects().length, 0); });
  await test('five pane list stays available', async () => {
    const ids = [10, 11, 12, 13, 14].map(uuid);
    const chain = ids.slice(1).reduce((first, paneId) => ({ kind: 'split', axis: 'horizontal', ratio: 0.5, first, second: { kind: 'leaf', pane_id: paneId } }), { kind: 'leaf', pane_id: ids[0] });
    const rows = ids.map((paneId, index) => ({ pane_id: paneId, project_id: P, current_run_id: uuid(20 + index), observation: obs(uuid(20 + index), paneId), display_name: `pane-${index}`, path: 'C:/synthetic/one' }));
    const h = await ready({ override(req, api) { if (req.operation !== 'pane.list' || req.params.project_id !== P) return; return api.response(req, { project_id: P, panes: rows, root: chain, selected_pane_id: ids[0] }); } });
    assert.equal(h.controller.getSnapshot().availability, 'available');
    assert.equal(h.controller.getSnapshot().panes.panes.length, 5);
    h.controller.dispose();
  });
  await test('revision disagreement retains unavailable view without auto loop', async () => { const h = harness({ override(req, api) { if (req.operation === 'pane.list') return { ...api.standard(req), topology_revision: 8 }; } }); await h.controller.refresh(); assert.equal(h.controller.getSnapshot().availability, 'unavailable'); assert.equal(h.requests.length, 3); });
  await test('installation read neither clears pending nor invokes control', async () => { const h = await ready({ override(req) { if (req.operation === 'pane.resize') throw new Error('lost'); } }); await perform(h, h.intent('resize-pane', { rows: 24, cols: 80 })); await h.controller.inspect({ instanceId: I, generation: 'g', topologyRevision: 7, kind: 'inspect-installation' }); assert.equal(h.installations.length, 1); assert.equal(h.controller.getPending().facts.knowledge, 'awaiting_record'); assert.equal(h.effects().length, 1); });
  await test('all state axes obey fence, identity, exit and one-time continuation laws', () => {
    let states = 0;
    for (const kind of ['instant', 'interrupt']) for (const remaining of [false, true]) for (const fenced of [false, true]) for (const knowledge of ['unresolved', 'awaiting_record', 'unknown', 'failure', 'success']) for (const exitFact of ['none', 'running', 'unknown', 'exited_same']) for (const targetFact of ['not_required', 'awaiting', 'verified', 'changed', 'unknown']) for (const dataComplete of [false, true]) for (const contradiction of [false, true]) for (const live of [false, true]) for (const nextIssued of [false, true]) {
      const s = { kind, remaining, fenced, knowledge, exitFact, targetFact, dataComplete, contradiction, live, nextIssued }; states++;
      const decision = decideStage(s);
      if (!live) assert.equal(decision, 'ignore');
      else if (contradiction || knowledge === 'unknown') assert.equal(decision, 'hold_unknown');
      else if (knowledge === 'success' && kind === 'interrupt' && exitFact !== 'exited_same') assert.ok(['inspect_run', 'hold_unknown'].includes(decision));
      if (fenced) assert.notEqual(decision, 'advance_once');
      if (decision === 'advance_once') { assert.equal(knowledge, 'success'); assert.equal(dataComplete, true); assert.equal(remaining, true); assert.equal(nextIssued, false); const once = foldStage(s, { kind: 'advance_committed' }); assert.equal(decideStage(once), 'await_next_stage'); }
      for (const event of [{ kind: 'rpc_invalid' }, { kind: 'record_success' }, { kind: 'query_outer_failure' }, ...codes.map(code => ({ kind: 'record_error', code })), { kind: 'run_fact', fact: 'exited_same' }, { kind: 'target_fact', fact: 'verified' }]) {
        const after = foldStage(s, event); if (fenced) assert.equal(after.fenced, true); if (knowledge === 'unknown') assert.equal(after.knowledge, 'unknown'); if (targetFact === 'changed') assert.equal(after.targetFact, 'changed'); assert.deepEqual(foldStage(s, event, false), s); if (event.kind === 'query_outer_failure') assert.deepEqual(after, s);
      }
    }
    assert.equal(states, 12800);
  });
  for (const kind of ['create-pane', 'split-pane']) for (const rootState of ['unavailable', 'changed', 'unknown']) await test(`unverified root ${rootState} refuses ${kind} before an effect`, async () => {
    const h = await ready({ override(req, api) { if (req.operation === 'project.list') { const r = api.standard(req); r.result.data.projects[0].root_state = rootState; return r; } } });
    assert.equal((await perform(h, h.intent(kind, { axis: 'horizontal' }))).disposition, 'refused'); assert.equal(h.effects().length, 0);
  });
  for (const kind of ['resize-pane', 'interrupt-run']) await test(`restored null run refuses ${kind} without starting a run`, async () => {
    const h = await ready({ run: null }); assert.equal((await perform(h, h.intent(kind, { rows: 24, cols: 80 }))).disposition, 'refused'); assert.equal(h.effects().length, 0);
  });
  for (const created of [false, true]) await test(`missing shell capability preserves confirmed open stages created=${created}`, async () => {
    const h = await ready({ created, override(req, api) { if (req.operation === 'capabilities.get') { const r = api.standard(req); r.result.data.shell_profile_ids = null; r.result.data.providers = null; return r; } } });
    assert.equal((await perform(h, h.intent('open-folder'))).disposition, created ? 'refused' : 'completed'); assert.deepEqual(h.effects().map(r => r.operation), ['project.open', 'project.select']);
  });
  for (const failStage of ['project.open', 'project.select', 'pane.create', 'pane.select']) await test(`open compound terminal refusal at ${failStage} never sends its suffix`, async () => {
    const h = await ready({ override(req, api) { if (req.operation === failStage) return api.error(req, 'runtime_failed'); } });
    assert.equal((await perform(h, h.intent('open-folder'))).disposition, 'refused'); const all = ['project.open', 'project.select', 'pane.create', 'pane.select']; assert.deepEqual(h.effects().map(r => r.operation), all.slice(0, all.indexOf(failStage) + 1));
  });
  for (const runFact of [
    { process: 'exited', evidence: 'process_exit', current: false, pane_id: B2 },
    { process: 'running', evidence: 'unavailable', current: false },
    { process: 'unknown', evidence: 'unavailable', current: false },
  ]) await test(`interrupt cannot use nonmatching or nonexit run evidence ${JSON.stringify(runFact)}`, async () => {
    const h = await ready({ override(req, api) { if (req.operation === 'run.get') { const r = api.standard(req); Object.assign(r.result.data.run, runFact); if (runFact.process === 'exited') { r.result.data.run.work = 'interrupted'; r.result.data.run.exit_code = 0; } return r; } } });
    assert.equal((await perform(h, h.intent('close-pane', { interruptFirst: true }))).disposition, 'unknown'); await h.controller.refresh(); assert.equal(h.effects().length, 1); assert.equal(h.settlements.at(-1).disposition, 'unknown');
  });
  await test('disposed in-flight effect ignores a late success and sends no compound suffix', async () => {
    let release; const h = await ready({ override(req, api) { if (req.operation === 'pane.create') return new Promise(done => { release = () => done(api.standard(req)); }); } });
    const result = h.controller.control(h.intent('create-pane'), 1); await flush(); h.controller.dispose(); release(); assert.equal((await result).disposition, 'unknown'); await flush(); assert.deepEqual(h.effects().map(r => r.operation), ['pane.create']);
  });
  await test('old read epoch cannot publish after synchronous ticket admission', async () => {
    let hold = false, release; const h = await ready({ override(req, api) { if (hold && req.operation === 'project.list') return new Promise(done => { release = () => done(api.standard(req)); }); } });
    hold = true; const read = h.controller.refresh(); await flush(); const change = h.controller.control(h.intent('select-pane'), 1); await flush(); hold = false; release(); await read; assert.equal((await change).disposition, 'completed'); await flush(); assert.equal(h.controller.getSnapshot().busy, false); assert.equal(h.controller.getSnapshot().topologyRevision, 8);
  });
  const { chromium } = require('playwright');
  const browser = await chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
  try {
    const page = await browser.newPage();
    // Fulfill a synthetic secure origin locally so production crypto.randomUUID
    // is exercised without a polyfill, network request or product transport.
    await page.route('**/*', route => route.request().url() === 'https://task871.invalid/' ? route.fulfill({ contentType: 'text/html', body: '<!doctype html><html lang="ja"><meta charset="utf-8"><body><div id="view"></div></body></html>' }) : route.abort());
    await page.goto('https://task871.invalid/');
    const [controllerBundle, viewBundle] = await Promise.all(['project-pane-controller.ts', 'project-pane.ts'].map(name => build({ entryPoints: [resolve(app, 'src/workspace-ui', name)], bundle: true, write: false, format: 'esm', platform: 'browser', target: 'es2022', metafile: true })));
    browserSources = identity([...new Set([controllerBundle, viewBundle].flatMap(result => Object.keys(result.metafile.inputs).map(path => resolve(path))))]);
    const viewText = viewBundle.outputFiles[0].text;
    const domChecks = await page.evaluate(async ({ controllerText, viewText, errors, I, P, B, R }) => {
      const { createProjectPaneController } = await import(URL.createObjectURL(new Blob([controllerText], { type: 'text/javascript' })));
      const { createProjectPaneView } = await import(URL.createObjectURL(new Blob([viewText], { type: 'text/javascript' })));
      const checks = [], check = (name, condition) => { if (!condition) throw new Error(name); checks.push(name); };
      const flush = async () => { for (let n = 0; n < 8; n++) await new Promise(done => setTimeout(done, 0)); };
      for (const lost of [false, true]) {
        let exited = false, closed = false, revision = 0, view;
        const requests = [], tickets = [], terminals = [];
        const reply = (q, data) => ({ schema_version: 1, instance_id: I, operation_id: q.operation_id, accepted: true, topology_revision: revision, event_seq: revision, result: { operation: q.operation, data }, error: null });
        const run = () => ({ run_id: R, pane_id: B, process: exited ? 'exited' : 'running', work: exited ? 'interrupted' : 'unknown', evidence: exited ? 'process_exit' : 'unavailable', observed_at: '2026-09-26T00:00:00.000Z', current: true, exit_code: exited ? 0 : null });
        const ownerKey = { instanceId: I, ownerGeneration: '1' };
        const port = { ownerKey, exchange(q) { if (q.operation === 'operation.get') throw new Error('recovery_port_required'); return dispatch(q); },
          recover(origin, q) { if (q.operation !== 'operation.get' || origin.instanceId !== ownerKey.instanceId || origin.ownerGeneration !== ownerKey.ownerGeneration) throw new Error('owner_mismatch'); return dispatch(q); } };
        async function dispatch(q) {
          requests.push(structuredClone(q));
          if (q.operation === 'capabilities.get') return reply(q, { schema_version: 1, operations: ['capabilities.get','project.list','pane.list','run.interrupt','run.get','pane.close','operation.get'], max_message_bytes: 1048576, providers: null, shell_profile_ids: null, replay_capacity: { retained_bytes: 134217728, active_bytes: 268435456 } });
          if (q.operation === 'project.list') return reply(q, { projects: [{ project_id: P, root_state: 'verified', display_name: '対象', path: 'C:/synthetic/project' }], selected_project_id: P });
          if (q.operation === 'pane.list') return reply(q, { project_id: P, panes: closed ? [] : [{ pane_id: B, project_id: P, display_name: '端末', path: 'C:/synthetic/project', current_run_id: R, observation: run() }], root: closed ? null : { kind: 'leaf', pane_id: B }, selected_pane_id: closed ? null : B });
          if (q.operation === 'run.interrupt') { if (lost) throw new Error('no Response'); return reply(q, { run_id: R, phase: 'accepted' }); }
          if (q.operation === 'run.get') return reply(q, { run: run(), ...(q.params.include_cleanup === true ? { cleanup_complete: exited } : {}) });
          if (q.operation === 'operation.get') return reply(q, { operation: { operation_id: q.params.operation_id, phase: 'completed', outcome: 'succeeded', error_code: null } });
          if (q.operation === 'pane.close') { if (q.params.expected_current_run_id !== R) return { ...reply(q, null), accepted: false, result: null, error: errors.target_not_found }; closed = true; revision++; return reply(q, { pane_id: B, closed: true, selected_pane_id: null }); }
          throw new Error(q.operation);
        }
        const controller = createProjectPaneController({ instanceId: I, generation: 'dom', ownerKey, pickFolder: async () => null, installation() {}, snapshot: snapshot => view?.render(snapshot), settlement: (ticket, result) => { tickets.push({ ticket, disposition: result.disposition }); view?.settle(ticket, result); }, port });
        await controller.refresh();
        view = createProjectPaneView(document.querySelector('#view'), controller.getSnapshot(), { control: controller.control, inspect: controller.inspect, mountTerminal(slot) { const terminal = document.createElement('span'); terminal.textContent = '固定端末'; slot.append(terminal); terminals.push(terminal); } });
        document.querySelector('[data-action="close-pane"]').click();
        check(`DOM lost=${lost} close opens confirmation without a request`, document.querySelector('dialog').open && requests.every(q => q.operation !== 'run.interrupt'));
        document.querySelector('[data-action="modal-confirm"]').click(); await flush();
        check(`DOM lost=${lost} modal reserves one exact interrupt ticket`, requests.filter(q => q.operation === 'run.interrupt').length === 1 && requests.find(q => q.operation === 'run.interrupt').params.run_id === R && new Set(tickets.map(t => t.ticket)).size === 1);
        check(`DOM lost=${lost} unknown keeps sibling controls disabled`, document.querySelector('[data-action="select-pane"]').disabled && requests.every(q => q.operation !== 'pane.close'));
        await controller.refresh(); await flush();
        check(`DOM lost=${lost} reread retains terminal DOM identity`, terminals.length === 1 && terminals[0].isConnected);
        exited = true; await controller.refresh(); await controller.refresh(); await flush();
        check(`DOM lost=${lost} exact exit settles the original ticket`, tickets.at(-1).disposition === (lost ? 'refused' : 'completed') && new Set(tickets.map(t => t.ticket)).size === 1);
        check(`DOM lost=${lost} guarded continuation obeys sticky fence`, requests.filter(q => q.operation === 'pane.close').length === (lost ? 0 : 1) && requests.every(q => q.operation !== 'shell.launch'));
        view.dispose(); controller.dispose();
      }
      return checks;
    }, { controllerText: controllerBundle.outputFiles[0].text, viewText, errors, I, P, B, R });
    checks.push(...domChecks.map(name => ({ name, passed: true })));
  } finally { await browser.close(); }
} catch (error) { failure = { name: error.name, message: error.message, stack: error.stack }; }
const after = identity(before.map(row => row.path));
const browserAfter = identity(browserSources.map(row => row.path));
if (JSON.stringify(before) !== JSON.stringify(after) || JSON.stringify(browserSources) !== JSON.stringify(browserAfter)) failure = { name: 'SourceIdentityError', message: 'Product or checker source changed during execution' };
const receipt = { schema: 'task871-controller-check/v1', started, ended: new Date().toISOString(), node: process.version, environment: { dependencyRoot, temp: taskTemp, browserChannel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge', headless: true }, typescriptExit: compile.status, passed: checks.length, failed: failure ? 1 : 0, checks, failure, commands: [process.execPath, ...args], sources: after, sourceBefore: before, browserSources, browserAfter, nativeProof: false, adopted: false };
writeFileSync(resolve(evidence, `${run}.receipt.json`), JSON.stringify(receipt, null, 2), 'utf8');
console.log(JSON.stringify({ receipt: `${run}.receipt.json`, passed: receipt.passed, failed: receipt.failed, failure }));
if (failure) process.exitCode = 1;
