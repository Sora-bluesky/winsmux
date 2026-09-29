import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i < 0 ? fallback : process.argv[i + 1]; };
const dependencies = resolve(arg('--dependency-root', app));
const evidence = resolve(arg('--evidence-dir', resolve(app, '../.evidence/TASK-873/commands')));
const baselinePath = arg('--baseline', null);
const require = createRequire(resolve(dependencies, 'package.json'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const paths = ['src/workspace-ui/agent-commands.ts', 'scripts/workspace-agent-commands-check.mjs', 'src/workspace-ui/project-pane-controller.ts', 'src/generated/workspace-contract.ts'];
const identity = () => paths.map(path => { const bytes = readFileSync(resolve(app, path)); return { path, bytes: bytes.length, sha256: hash(bytes) }; });
const before = identity();
const baseline = baselinePath ? JSON.parse(readFileSync(baselinePath, 'utf8')) : null;
function protectedIdentity() {
  if (!baseline) return null;
  const outside = baseline.outside.map(file => { const bytes = readFileSync(resolve(baseline.root, file.path)); return { path: file.path, bytes: bytes.length, sha256: hash(bytes) }; });
  const head = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: baseline.root, encoding: 'utf8' });
  if (head.status !== 0) throw new Error('HEAD observation failed');
  return { outside, head: head.stdout.trim(), index_sha256: hash(readFileSync(baseline.index_path)), confirmed_layout_sha256: hash(readFileSync(resolve(process.env.LOCALAPPDATA, 'winsmux/workspace/v1/confirmed.json'))) };
}
const protectedBefore = protectedIdentity();
mkdirSync(evidence, { recursive: true });
const checks = [];
const traces = [];
const started = new Date().toISOString();
let compile = null;
let failure = null;
const check = (name, actual, expected = true) => {
  const passed = JSON.stringify(actual) === JSON.stringify(expected);
  checks.push({ name, actual, expected, passed });
  if (!passed) throw new Error(name);
};
try {
  if (baseline) {
    check('all preserved sources before execution', protectedBefore.outside, baseline.outside);
    check('real HEAD before execution', protectedBefore.head, baseline.real_head);
    check('real index before execution', protectedBefore.index_sha256, baseline.index_sha256);
    check('confirmed user layout before execution', protectedBefore.confirmed_layout_sha256, baseline.confirmed_layout_sha256);
  }
  compile = spawnSync(process.execPath, [require.resolve('typescript/bin/tsc'), '--noEmit', '--target', 'ES2020', '--module', 'ESNext', '--lib', 'ES2020,DOM,DOM.Iterable', '--moduleResolution', 'bundler', '--strict', '--noUnusedLocals', '--noUnusedParameters', '--noFallthroughCasesInSwitch', '--isolatedModules', resolve(app, paths[0])], { encoding: 'utf8' });
  writeFileSync(resolve(evidence, 'typescript.txt'), compile.stdout + compile.stderr, 'utf8');
  check('strict TypeScript', compile.status, 0);
  const { build } = require('esbuild');
  await build({ entryPoints: [resolve(app, paths[0])], outfile: resolve(evidence, 'agent-commands.mjs'), bundle: true, format: 'esm', platform: 'node', target: 'es2020', logLevel: 'silent' });
  const { createAgentCommandSession } = await import(pathToFileURL(resolve(evidence, 'agent-commands.mjs')).href);
  const I = '11111111-1111-4111-8111-111111111111';
  const P = '22222222-2222-4222-8222-222222222222';
  const Q = '33333333-3333-4333-8333-333333333333';
  const R = '44444444-4444-4444-8444-444444444444';
  const N = '55555555-5555-4555-8555-555555555555';
  const B = '66666666-6666-4666-8666-666666666666';
  const cwd = 'C:\\作業\\日本語';
  const clone = v => structuredClone(v);
  const flush = () => new Promise(resolve => setImmediate(resolve));
  let fixtureIndex = 0;
  function fixture({ provider = 'codex', runId = null, kind = 'launch-agent', process = 'running', evidenceKind = 'unavailable', work = 'unknown', exitCode = null, interruptFirst = runId !== null, cleanupComplete = null } = {}) {
    const trace = { fixture: ++fixtureIndex, provider, kind, runId, requests: [], notices: [] }; traces.push(trace);
    let ordinal = 0;
    const nextId = () => `77777777-7777-4777-8777-${(++ordinal).toString(16).padStart(12, '0')}`;
    const observation = () => ({ run_id: R, pane_id: Q, current: state.current, process: state.process, evidence: state.evidenceKind, work: state.work, exit_code: state.exitCode, observed_at: '2026-09-28T00:00:00Z' });
    const state = { runId, process, evidenceKind, work, exitCode, cleanupComplete, current: true, project: P, pane: Q, root: 'verified', cwd, version: '1.2.3', providers: null, seq: 5, revision: 9, responseEdit: null, dataEdit: null, error: null, record: 'completed', recordOutcome: 'succeeded', recordError: null, hold: null, held: [] };
    const ok = (req, data) => ({ schema_version: 1, instance_id: I, operation_id: req.operation_id, accepted: true, topology_revision: state.revision, event_seq: state.seq, result: { operation: req.operation, data }, error: null });
    const errors = {
      permission_denied: [false, 'Permission denied.'], unsupported_capability: [false, 'Capability is unavailable.'],
      runtime_failed: [true, 'Runtime operation failed.'], state_unknown: [false, 'Operation state is unknown.'],
      in_progress: [true, 'Operation is in progress.'], root_changed: [false, 'Root identity changed.'],
    };
    const refused = (req, code) => ({ ...ok(req, {}), accepted: false, result: null, error: { code, message: errors[code][1], target_id: null, retryable: errors[code][0] } });
    function response(req) {
      let data;
      switch (req.operation) {
        case 'capabilities.get': data = { schema_version: 1, max_message_bytes: 1048576, replay_capacity: { retained_bytes: 1048576, active_bytes: 1048576 }, operations: ['agent.launch', 'run.interrupt'], providers: state.providers ?? [{ provider: 'codex', version: state.version }, { provider: 'claude', version: state.version }], shell_profile_ids: ['powershell'] }; break;
        case 'project.list': data = { selected_project_id: state.project, projects: [{ project_id: P, path: state.cwd, root_state: state.root, display_name: '日本語' }] }; break;
        case 'pane.list': data = { project_id: P, selected_pane_id: state.pane, root: { kind: 'leaf', pane_id: Q }, panes: [{ pane_id: Q, project_id: P, current_run_id: state.runId, observation: state.runId ? observation() : null, path: cwd, display_name: '端末' }] }; break;
        case 'run.get': data = { run: observation(), ...(req.params.include_cleanup === true ? { cleanup_complete: state.cleanupComplete ?? (state.process === 'exited' && state.evidenceKind === 'process_exit') } : {}) }; break;
        case 'run.interrupt': data = { run_id: R, phase: 'accepted' }; break;
        case 'agent.launch': data = { pane_id: Q, run_id: N, phase: 'accepted' }; break;
        case 'operation.get': data = { operation: { operation_id: req.params.operation_id, phase: state.record, outcome: state.record === 'completed' ? state.recordOutcome : null, error_code: state.record === 'completed' ? state.recordError : null } }; break;
        default: throw new Error(req.operation);
      }
      if (state.dataEdit) data = state.dataEdit(req, data);
      let got = state.error && ['agent.launch', 'run.interrupt'].includes(req.operation) ? refused(req, state.error) : ok(req, data);
      if (state.responseEdit) got = state.responseEdit(req, got);
      return got;
    }
    const ownerKey = { instanceId: I, ownerGeneration: '1' };
    const port = { ownerKey, recover(origin, req) {
      if (origin.instanceId !== ownerKey.instanceId || origin.ownerGeneration !== ownerKey.ownerGeneration) throw new Error('owner_mismatch');
      return port.exchange(req);
    }, exchange(req) {
      trace.requests.push(clone(req));
      if (state.hold === req.operation) return new Promise((resolve, reject) => state.held.push({ req, resolve, reject }));
      if (state.hold === `throw:${req.operation}`) throw new Error('transport failed');
      if (state.hold === `reject:${req.operation}`) return Promise.reject(new Error('transport failed'));
      return Promise.resolve(response(req));
    } };
    const session = createAgentCommandSession({ instanceId: I, generation: 'g1', ownerKey, port, operationId: nextId });
    let notices = [];
    const notify = n => { notices.push(clone(n)); trace.notices.push(clone(n)); };
    let lease = session.bind(P, Q, notify);
    const intent = () => ({ instanceId: I, generation: 'g1', projectId: P, paneId: Q, runId, kind, ...(kind === 'launch-agent' ? { provider, detectedVersion: '1.2.3', cwd, model: ' model 日本語 ', effort: ' high ', interruptFirst } : {}) });
    const mutations = () => trace.requests.filter(r => ['agent.launch', 'run.interrupt'].includes(r.operation));
    return { state, trace, session, intent, mutations, notices: () => notices, nextId,
      submit(i = intent()) { return lease.submit(i, nextId()); },
      release() { const held = state.held.shift(); if (!held) throw new Error('missing held request'); held.resolve(response(held.req)); },
      bind(pane = Q) { lease = session.bind(P, pane, notify); return lease; },
      dispose() { lease.dispose(); },
      clearNotices() { notices = []; },
    };
  }
  function assertGuard(f, expectedRun) {
    const launched = f.mutations().find(r => r.operation === 'agent.launch');
    check('launch explicit nullable guard and unchanged parameters', launched.params, { pane_id: Q, provider: f.trace.provider, model: ' model 日本語 ', effort: ' high ', expected_current_run_id: expectedRun });
    check('all requests fixed schema/instance/revision and unique IDs', f.trace.requests.every(r => r.schema_version === 1 && r.instance_id === I && r.expected_topology_revision === null) && new Set(f.trace.requests.map(r => r.operation_id)).size === f.trace.requests.length);
  }
  // Normal delayed exit is a different entry point from explicit lost-response
  // recovery. Preserve the recovery tests below and prove the whole event family.
  for (const provider of ['codex', 'claude']) {
    for (const kind of ['launch-agent', 'interrupt-run']) {
      for (const process of ['running', 'starting']) {
        const f = fixture({ provider, kind, runId: R, process });
        f.submit(); await flush();
        check('direct interrupt receipt precedes normal actual exit', [f.mutations().map(r => r.operation), f.session.getState().busy, f.session.getState().pending.facts.fenced], [['run.interrupt'], true, false]);
        const original = f.mutations()[0].operation_id;
        await f.session.observe();
        check('normal running hint neither recovers nor fences', [f.mutations().length, f.trace.requests.filter(r => r.operation === 'operation.get').length, f.session.getState().pending.facts.fenced], [1, 0, false]);
        const quiet = f.trace.requests.length; await flush();
        check('no event means no automatic poll', f.trace.requests.length, quiet);
        f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
        await f.session.observe(); await flush();
        check(`${provider}/${kind}/${process} delayed exit completes original journey`, [f.mutations().map(r => r.operation), f.session.getState().busy, f.session.getState().last.disposition], [kind === 'launch-agent' ? ['run.interrupt', 'agent.launch'] : ['run.interrupt'], false, 'completed']);
        check('normal notification preserves original interrupt identity', f.mutations()[0].operation_id, original);
        if (kind === 'launch-agent') assertGuard(f, R);
        const terminal = f.trace.requests.length; await f.session.observe(); await flush();
        check('late hints after terminal cause no reads or mutations', f.trace.requests.length, terminal);
      }
      const f = fixture({ provider, kind, runId: R }); f.submit(); await flush();
      f.state.hold = 'run.get';
      const reading = f.session.observe(); await flush();
      check('normal read is held independently of the direct receipt', f.state.held.length, 1);
      const hints = Array.from({ length: 5 }, () => f.session.observe());
      check('held same-stage normal hints coalesce into existing read', hints.every(p => p === reading));
      // Deliver the earlier running snapshot after the actual exit hint. A lost
      // hint here would leave the original normal chain pending forever.
      f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; f.state.hold = null;
      let stale = true;
      f.state.dataEdit = (req, data) => {
        if (req.operation === 'run.get' && stale) { stale = false; return { run: { ...data.run, process: 'running', evidence: 'unavailable', work: 'unknown', exit_code: null } }; }
        return data;
      };
      const heldCount = f.trace.requests.filter(r => r.operation === 'run.get').length;
      f.release(); await reading; await flush();
      check('inflight exit hint survives earlier running result once', f.trace.requests.filter(r => r.operation === 'run.get').length, heldCount + 1);
      check('preserved hint completes once without record recovery', [f.mutations().map(r => r.operation), f.session.getState().busy, f.trace.requests.filter(r => r.operation === 'operation.get').length], [kind === 'launch-agent' ? ['run.interrupt', 'agent.launch'] : ['run.interrupt'], false, 0]);
      if (kind === 'launch-agent') assertGuard(f, R);
    }
    for (const hold of ['run.get', 'capabilities.get', 'project.list', 'pane.list']) {
      for (const delivery of ['valid', 'unavailable']) {
        const f = fixture({ provider, runId: R }); f.submit(); await flush();
        f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; f.state.hold = hold;
        const reading = f.session.observe(); await flush();
        check(`normal ${hold} inspection has reached held port`, f.state.held.length, 1);
        const hints = [f.session.observe(), f.session.observe(), f.session.observe()];
        check('multiple normal hints share the single inspection', hints.every(p => p === reading));
        f.state.hold = null;
        if (delivery === 'valid') f.release();
        else f.state.held.shift().reject(new Error('read delivery unavailable'));
        await reading; await flush();
        check(`${hold}/${delivery} hint is consumed only for same current stage`, [f.mutations().map(r => r.operation), f.session.getState().busy, f.trace.requests.filter(r => r.operation === 'operation.get').length], [['run.interrupt', 'agent.launch'], false, 0]);
        assertGuard(f, R);
        const quiet = f.trace.requests.length; await flush();
        check('next launch does not inherit a prior-stage hint', f.trace.requests.length, quiet);
      }
      for (const retirement of ['recheck', 'dispose', 'rebind', 'disconnect', 'retire_host']) {
        for (const order of ['hint_first', 'fence_first']) {
          const f = fixture({ provider, runId: R }); f.submit(); await flush();
          f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; f.state.hold = hold;
          const reading = f.session.observe(); await flush();
          const retire = () => {
            if (retirement === 'recheck') return f.session.recheck();
            if (retirement === 'dispose') f.dispose();
            if (retirement === 'rebind') f.bind(B);
            if (retirement === 'disconnect') f.session.setConnected(false);
            if (retirement === 'retire_host') f.session.retireHost();
            return Promise.resolve();
          };
          let recovering;
          if (order === 'hint_first') { void f.session.observe(); recovering = retire(); }
          else { recovering = retire(); void f.session.observe(); }
          const count = f.trace.requests.length;
          f.state.hold = null; f.clearNotices(); f.release(); await reading; await recovering; await flush();
          check(`${provider}/${hold}/${retirement}/${order} cannot emit followup`, f.mutations().map(r => r.operation), ['run.interrupt']);
          check('fenced hint cannot derive fresh target reads', f.trace.requests.filter(r => ['capabilities.get', 'project.list', 'pane.list'].includes(r.operation)).length, f.trace.requests.slice(0, count).filter(r => ['capabilities.get', 'project.list', 'pane.list'].includes(r.operation)).length);
          if (['dispose', 'rebind', 'retire_host'].includes(retirement)) check('late inspection has no old settlement projection', f.notices().filter(n => n.kind === 'settlement').length, 0);
          const after = f.trace.requests.length; await f.session.observe(); await flush();
          check('fence survives every later normal hint', f.trace.requests.length, after);
          f.session.retireHost();
        }
      }
    }
    for (const kind of ['launch-agent', 'interrupt-run']) {
      for (const phase of ['preflight', 'unresolved', 'recovered']) {
        const f = fixture({ provider, kind, runId: R });
        f.state.hold = phase === 'preflight' ? 'capabilities.get' : 'run.interrupt';
        f.submit(); await flush();
        if (phase === 'recovered') {
          f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
          await f.session.recheck();
        }
        const before = f.trace.requests.length;
        await f.session.observe(); await flush();
        check(`${provider}/${kind}/${phase} event hint cannot become recovery`, f.trace.requests.length, before);
        check('hint never resends unresolved or recovered mutation', f.mutations().length, phase === 'preflight' ? 0 : 1);
        f.session.retireHost(); f.state.hold = null; f.release(); await flush();
      }
    }
    for (const boundary of ['provider_event', 'wrong_run', 'wrong_pane', 'replacement', 'unknown']) {
      const f = fixture({ provider, runId: R }); f.submit(); await flush();
      f.state.process = boundary === 'unknown' ? 'unknown' : 'exited';
      f.state.evidenceKind = boundary === 'provider_event' ? 'provider_event' : boundary === 'unknown' ? 'unavailable' : 'process_exit';
      f.state.work = 'succeeded'; f.state.exitCode = 0;
      f.state.dataEdit = (req, data) => {
        if (req.operation !== 'run.get') return data;
        if (boundary === 'wrong_run') data.run.run_id = B;
        if (boundary === 'wrong_pane') data.run.pane_id = B;
        if (boundary === 'replacement') data.run.current = false;
        return data;
      };
      await f.session.observe(); await flush();
      check(`normal ${boundary} cannot authorize a later launch`, [f.mutations().map(r => r.operation), f.session.getState().busy], [['run.interrupt'], boundary !== 'replacement']);
      if (boundary === 'replacement') check('history replacement settles predecessor scope', f.session.getState().last.disposition, 'partial');
      f.session.retireHost();
    }
    for (const boundary of ['version', 'root', 'cwd', 'project', 'pane', 'runId']) {
      const f = fixture({ provider, runId: R }); f.submit(); await flush();
      f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
      f.state[boundary] = ['project', 'pane', 'runId'].includes(boundary) ? B : 'changed';
      await f.session.observe(); await flush();
      check(`normal fresh ${boundary} mismatch refuses followup`, [f.mutations().map(r => r.operation), f.session.getState().busy, f.session.getState().last.disposition], [['run.interrupt'], false, 'refused']);
    }
    const retired = fixture({ provider, runId: R });
    const oldLease = retired.bind(); retired.state.hold = 'capabilities.get'; retired.submit(); await flush();
    retired.dispose(); retired.state.hold = null; retired.bind(); retired.submit(); await flush();
    const count = retired.trace.requests.length;
    await oldLease.observe(); await flush();
    check('old projection hint cannot inspect the new command', retired.trace.requests.length, count);
    retired.session.retireHost(); retired.release(); await flush();
  }
  // Same captured R/pane history is valid exit evidence, never continuation authority.
  for (const provider of ['codex', 'claude']) for (const kind of ['launch-agent', 'interrupt-run']) {
    for (const delivery of ['direct', 'held']) for (const projection of ['visible', 'dispose', 'rebind', 'disconnect', 'recheck']) for (const earlyHistory of [false, true]) {
      const f = fixture({ provider, kind, runId: R });
      if (delivery === 'held') f.state.hold = 'run.interrupt';
      const ticket = f.nextId(); const originalIntent = f.intent();
      check('history command admitted', f.session.bind(P, Q, n => { f.trace.notices.push(clone(n)); }).submit(originalIntent, ticket));
      await flush(); const original = f.mutations()[0].operation_id;
      if (projection === 'dispose') f.session.bind(P, Q, () => {}).dispose();
      if (projection === 'rebind') f.bind(B);
      if (projection === 'disconnect') f.session.setConnected(false);
      if (projection === 'recheck') await f.session.recheck();
      f.state.current = false; f.state.runId = N;
      const atHistory = f.trace.notices.length;
      if (projection === 'disconnect') f.session.setConnected(true);
      if (earlyHistory) {
        if (delivery === 'direct' && projection === 'visible') await f.session.observe(); else await f.session.recheck();
        check('history without actual exit keeps predecessor pending and fenced', [f.session.getState().busy, f.session.getState().pending.facts.fenced], [true, true]);
        // A later current=true read cannot clear a fence established by history.
        f.state.current = true; await f.session.recheck();
        check('history fence cannot be cleared by a later current read', f.session.getState().pending.facts.fenced);
        f.state.current = false;
      }
      f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
      if (!earlyHistory && delivery === 'direct' && projection === 'visible') await f.session.observe(); else await f.session.recheck();
      await flush();
      check(`${provider}/${kind}/${delivery}/${projection}/early=${earlyHistory} history settles original scope`, [f.session.getState().busy, f.session.getState().last.disposition, f.session.getState().last.ticket], [false, kind === 'launch-agent' ? 'partial' : 'completed', ticket]);
      check('history settlement preserves captured run and original mutation ID', [f.session.getState().last.target.runId, f.mutations().map(r => [r.operation, r.operation_id])], [R, [['run.interrupt', original]]]);
      check('history recovery queries only the original interrupt ID', f.trace.requests.filter(r => r.operation === 'operation.get').every(r => r.params.operation_id === original));
      if (['dispose', 'rebind'].includes(projection)) check('retired history projection receives no old settlement', f.trace.notices.slice(atHistory).filter(n => n.kind === 'settlement').length, 0);
      f.state.hold = null; f.state.current = true; f.state.runId = null; f.state.process = 'running'; f.state.evidenceKind = 'unavailable';
      f.bind();
      check('new independent command admitted after history settlement', f.submit({ ...originalIntent, runId: null, kind: 'launch-agent', provider, detectedVersion: '1.2.3', cwd, model: ' model 日本語 ', effort: ' high ', interruptFirst: false }));
      await flush();
      if (delivery === 'held') { f.release(); await flush(); }
      check('late original direct result cannot replace new command or replay old mutation', [f.mutations().map(r => r.operation), f.session.getState().last.disposition, f.session.getState().last.target.runId], [['run.interrupt', 'agent.launch'], 'completed', null]);
      const count = f.trace.requests.length; await f.session.observe(); await f.session.recheck(); await flush();
      check('history terminal cannot resume from late hints', f.trace.requests.length, count);
      f.session.retireHost();
    }
    const preflight = fixture({ provider, kind, runId: R, process: 'exited', evidenceKind: 'process_exit' }); preflight.state.current = false;
    check('history unsent preflight admitted for validation', preflight.submit()); await flush();
    check('history unsent preflight refuses and releases latch with no mutation', [preflight.mutations().length, preflight.session.getState().busy, preflight.session.getState().last.disposition], [0, false, 'refused']);
    for (const invalid of ['wrong_run', 'wrong_pane', 'provider_event', 'unknown', 'malformed_current', 'extra_data', 'extra_run', 'missing_cleanup', 'cleanup_type', 'bad_timestamp', 'impossible_work']) {
      const f = fixture({ provider, kind, runId: R }); f.submit(); await flush();
      f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; f.state.current = false;
      f.state.dataEdit = (req, data) => {
        if (req.operation !== 'run.get') return data;
        if (invalid === 'wrong_run') data.run.run_id = B;
        if (invalid === 'wrong_pane') data.run.pane_id = B;
        if (invalid === 'provider_event') { data.run.evidence = 'provider_event'; if ('cleanup_complete' in data) data.cleanup_complete = false; }
        if (invalid === 'unknown') { data.run.process = 'unknown'; data.run.evidence = 'unavailable'; if ('cleanup_complete' in data) data.cleanup_complete = false; }
        if (invalid === 'malformed_current') data.run.current = 'false';
        if (invalid === 'extra_data') data.extra = 1;
        if (invalid === 'extra_run') data.run.extra = 1;
        if (invalid === 'missing_cleanup' && kind === 'launch-agent') delete data.cleanup_complete;
        if (invalid === 'cleanup_type' && kind === 'launch-agent') data.cleanup_complete = 1;
        if (invalid === 'bad_timestamp') data.run.observed_at = '2026-02-30T00:00:00Z';
        if (invalid === 'impossible_work') data.run.work = 'running';
        return data;
      };
      if (kind === 'interrupt-run' && ['missing_cleanup', 'cleanup_type'].includes(invalid)) { f.session.retireHost(); continue; }
      await f.session.observe(); await flush();
      check(`history ${invalid} cannot prove exit or issue successor`, [f.session.getState().busy, f.mutations().map(r => r.operation)], [true, ['run.interrupt']]);
      f.state.dataEdit = null; await f.session.recheck(); await flush();
      check('valid original history read can recover after invalid observation', [f.session.getState().busy, f.session.getState().last.disposition], [false, kind === 'launch-agent' ? 'partial' : 'completed']);
      f.session.retireHost();
    }
  }
  for (const provider of ['codex', 'claude']) {
    const fresh = fixture({ provider }); check(`${provider} fresh admitted`, fresh.submit()); await flush();
    check(`${provider} fresh exactly one launch`, fresh.mutations().map(r => r.operation), ['agent.launch']);
    assertGuard(fresh, null); check('accepted new run ID is receipt only', fresh.session.getState().last.launchRunId, N);
    check('fresh terminal releases latch', fresh.session.getState().busy, false);
    const ended = fixture({ provider, runId: R, process: 'exited', evidenceKind: 'process_exit' }); ended.submit(); await flush();
    check('actual exited skips interrupt', ended.mutations().map(r => r.operation), ['agent.launch']); assertGuard(ended, R);
    for (const process of ['starting', 'running']) {
      const f = fixture({ provider, runId: R, process }); f.submit(); await flush();
      check('live run interrupts once and holds until actual exit', [f.mutations().map(r => r.operation), f.session.getState().busy], [['run.interrupt'], true]);
      f.state.process = 'exited'; f.state.evidenceKind = 'provider_event'; await f.session.recheck();
      check('provider event alone cannot prove process exit', [f.mutations().length, f.session.getState().busy], [1, true]);
      // Explicit recheck fences a later launch, even when subsequent exit becomes known.
      f.state.evidenceKind = 'process_exit'; await f.session.recheck();
      check('rechecked interrupt chain confirms only front stage', [f.mutations().map(r => r.operation), f.session.getState().busy, f.session.getState().last.disposition], [['run.interrupt'], false, 'partial']);
      const direct = fixture({ provider, runId: R, process });
      direct.state.dataEdit = (req, data) => { if (req.operation === 'run.interrupt') { direct.state.process = 'exited'; direct.state.evidenceKind = 'process_exit'; } return data; };
      direct.submit(); await flush();
      check('direct actual exit plus fresh selection advances exactly once', direct.mutations().map(r => r.operation), ['run.interrupt', 'agent.launch']); assertGuard(direct, R);
    }
    for (const kind of ['launch-agent', 'interrupt-run']) {
      for (const hold of ['capabilities.get', 'project.list', 'pane.list', 'run.get']) {
        for (const retirement of ['dispose', 'rebind', 'disconnect']) {
          const f = fixture({ provider, kind, runId: R }); f.state.hold = hold; f.submit(); await flush();
          check('preflight has reached held read', f.state.held.length, 1);
          f.clearNotices();
          if (retirement === 'dispose') f.dispose();
          if (retirement === 'rebind') f.bind(B);
          if (retirement === 'disconnect') f.session.setConnected(false);
          check(`${provider}/${kind}/${hold}/${retirement} synchronously cancels unsent`, [f.session.getState().busy, f.mutations().length, f.session.getState().last.disposition], [false, 0, 'unsent_cancelled']);
          if (retirement !== 'disconnect') check('retired lease receives no settlement', f.notices().filter(n => n.kind === 'settlement').length, 0);
          f.session.setConnected(true); f.bind(); f.state.hold = null; f.submit(); await flush();
          check('new same-target command progresses before old held read released', [f.state.held.length, f.mutations().length], [1, 1]);
          const identity = f.session.getState(); const requestCount = f.trace.requests.length; f.release(); await flush();
          check('old preflight result changes no command or request', [f.session.getState(), f.trace.requests.length], [identity, requestCount]);
          f.session.retireHost();
        }
      }
      for (const timing of ['old_lease', 'new_command', 'retired_host']) {
        const runId = kind === 'launch-agent' ? null : R;
        const f = fixture({ provider, kind, runId }); const mutation = kind === 'launch-agent' ? 'agent.launch' : 'run.interrupt';
        f.state.hold = mutation; f.submit(); await flush();
        check('mutation identity saved while direct Promise is unresolved', [f.session.getState().pending.phase, f.state.held.length], ['dispatched', 1]);
        const original = f.mutations()[0]; f.dispose(); f.bind(); f.clearNotices();
        if (kind === 'interrupt-run') { f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; }
        const a = f.session.recheck(); const b = f.session.recheck(); check('simultaneous readonly rechecks share exact Promise', a === b);
        await a;
        check('unresolved direct does not block original-ID operation.get', f.trace.requests.filter(r => r.operation === 'operation.get').map(r => r.params.operation_id), [original.operation_id]);
        check('recovered terminal releases original latch without resend', [f.session.getState().busy, f.mutations().length], [false, 1]);
        check('new projection receives no old settlement', f.notices().filter(n => n.kind === 'settlement').length, 0);
        if (kind === 'launch-agent') check('record completion never attributes a new run', [f.session.getState().last.launchRunId, f.session.getState().last.disposition], [null, 'partial']);
        if (timing === 'new_command') {
          // Retain a second unresolved request while the old direct response arrives.
          if (kind === 'interrupt-run') { f.state.process = 'running'; f.state.evidenceKind = 'unavailable'; }
          f.submit(); await flush(); check('new command reaches own mutation', f.mutations().length, 2);
        }
        if (timing === 'retired_host') f.session.retireHost();
        f.clearNotices(); const beforeLate = f.session.getState(); const count = f.mutations().length; f.release(); await flush();
        check(`${timing} late original direct is inert`, [f.session.getState(), f.mutations().length, f.notices().length], [beforeLate, count, 0]);
        f.session.retireHost();
      }
    }
  }
  for (const kind of ['launch-agent', 'interrupt-run']) {
    const f = fixture({ kind, runId: R, process: 'exited', evidenceKind: 'process_exit', work: 'failed', exitCode: 7 }); f.submit(); await flush();
    check('failed actual exit still proves process termination', [f.mutations().length, f.session.getState().busy], [kind === 'launch-agent' ? 1 : 0, false]);
  }
  for (const field of ['provider', 'detectedVersion', 'cwd', 'model', 'effort', 'generation', 'runId', 'instanceId', 'projectId', 'paneId', 'interruptFirst']) {
    const f = fixture(); const intent = f.intent(); intent[field] = field === 'interruptFirst' ? true : field === 'model' || field === 'effort' ? '' : 'invalid';
    const admitted = f.submit(intent); await flush();
    check(`invalid captured ${field} never mutates`, f.mutations().length, 0);
    if (!['detectedVersion', 'cwd'].includes(field)) check(`invalid ${field} fails synchronous admission`, admitted, false);
  }
  for (const field of ['version', 'cwd', 'root', 'project', 'pane', 'runId']) {
    const f = fixture(); f.state[field] = field === 'runId' ? R : field === 'project' || field === 'pane' ? B : 'changed'; f.submit(); await flush();
    check(`fresh ${field} mismatch refuses with no mutation`, [f.mutations().length, f.session.getState().busy], [0, false]);
  }
  for (const providers of [[], [{ provider: 'codex', version: '1.2.3' }, { provider: 'codex', version: '1.2.3' }], [{ provider: 'other', version: '1.2.3' }]]) {
    const f = fixture(); f.state.providers = providers; f.submit(); await flush(); check('missing/duplicate/unknown provider never mutates', f.mutations().length, 0);
  }
  for (const process of ['unknown', 'running', 'starting', 'exited']) {
    const f = fixture({ runId: R, process, evidenceKind: process === 'exited' ? 'provider_event' : 'unavailable', interruptFirst: false }); f.submit(); await flush();
    check('no implied interrupt or provider-event exit launch', f.mutations().length, 0);
  }
  for (const params of [{ model: null, effort: null }, { model: ' ', effort: ' 日本語 ' }]) {
    const f = fixture(); f.submit({ ...f.intent(), ...params }); await flush();
    check('nullable and literal model/effort preserved', { model: f.mutations()[0].params.model, effort: f.mutations()[0].params.effort }, params);
  }
  for (const kind of ['launch-agent', 'interrupt-run']) {
    for (const error of ['permission_denied', 'unsupported_capability', 'runtime_failed', 'state_unknown', 'in_progress', 'root_changed']) {
      const f = fixture({ kind, runId: kind === 'interrupt-run' ? R : null }); f.state.error = error; f.submit(); await flush();
      check(`canonical ${error} preserves unknown distinction`, [f.mutations().length, f.session.getState().busy], [1, ['state_unknown', 'in_progress'].includes(error)]);
      check('canonical error never switches provider or retries', f.mutations().map(r => r.operation), [kind === 'launch-agent' ? 'agent.launch' : 'run.interrupt']);
      f.session.retireHost();
    }
    for (const field of ['schema_version', 'instance_id', 'operation_id', 'operation', 'topology_revision', 'event_seq', 'payload']) {
      const f = fixture({ kind, runId: kind === 'interrupt-run' ? R : null });
      f.state.responseEdit = (req, got) => {
        if (!['agent.launch', 'run.interrupt'].includes(req.operation)) return got;
        if (field === 'operation') got.result.operation = 'project.list';
        else if (field === 'payload') got.result.data.phase = 'completed';
        else got[field] = field === 'schema_version' ? 2 : field.endsWith('revision') || field === 'event_seq' ? -1 : B;
        return got;
      };
      f.submit(); await flush(); check(`invalid direct ${field} cannot release or retry`, [f.session.getState().busy, f.mutations().length], [true, 1]);
      f.state.responseEdit = null;
      if (kind === 'interrupt-run') { f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; }
      await f.session.recheck(); check('invalid direct recovered only by original operation', [f.session.getState().busy, f.mutations().length], [false, 1]); f.session.retireHost();
    }
  }
  for (const record of ['accepted', 'in_progress', 'unknown', 'absent', 'invalid_id', 'failed', 'succeeded']) {
    const f = fixture(); f.state.hold = 'agent.launch'; f.submit(); await flush();
    if (['accepted', 'in_progress', 'unknown'].includes(record)) f.state.record = record;
    if (record === 'failed') { f.state.recordOutcome = 'failed'; f.state.recordError = 'permission_denied'; }
    if (record === 'absent') f.state.dataEdit = (req, data) => req.operation === 'operation.get' ? {} : data;
    if (record === 'invalid_id') f.state.dataEdit = (req, data) => { if (req.operation === 'operation.get') data.operation.operation_id = B; return data; };
    await f.session.recheck();
    check(`operation record ${record} outcome`, [f.session.getState().busy, f.mutations().length], [!['failed', 'succeeded'].includes(record), 1]);
    f.session.retireHost();
  }
  for (const kind of ['launch-agent', 'interrupt-run']) {
    for (const failureKind of ['throw', 'reject']) {
      const f = fixture({ kind, runId: kind === 'interrupt-run' ? R : null });
      f.state.hold = `${failureKind}:${kind === 'launch-agent' ? 'agent.launch' : 'run.interrupt'}`; f.submit(); await flush();
      check('transport failure retains original dispatched identity', [f.mutations().length, f.session.getState().busy, f.session.getState().pending.facts.knowledge], [1, true, 'awaiting_record']);
      f.state.hold = null;
      if (kind === 'interrupt-run') { f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; }
      await f.session.recheck();
      check('transport failure recheck never resends mutation', [f.mutations().length, f.session.getState().busy], [1, false]);
    }
    for (const hold of ['run.get', 'capabilities.get', 'project.list', 'pane.list']) {
      const f = fixture({ kind: 'launch-agent', runId: R });
      f.state.dataEdit = (req, data) => { if (req.operation === 'run.interrupt') { f.state.process = 'exited'; f.state.evidenceKind = 'process_exit'; f.state.hold = hold; } return data; };
      f.submit(); await flush(); check('interrupt prerequisite proof reaches held read', f.state.held.length, 1);
      f.dispose(); f.bind(); f.clearNotices(); f.state.hold = null; f.release(); await flush();
      check('lease retirement during actual-exit/target proof forbids next launch', [f.mutations().map(r => r.operation), f.session.getState().busy, f.notices().filter(n => n.kind === 'settlement').length], [['run.interrupt'], false, 0]);
    }
  }
  for (const fact of ['wrong_run', 'wrong_pane', 'not_current', 'unknown', 'provider_work_done']) {
    const f = fixture({ runId: R });
    f.state.dataEdit = (req, data) => {
      if (req.operation !== 'run.get') return data;
      if (fact === 'wrong_run') data.run.run_id = N;
      if (fact === 'wrong_pane') data.run.pane_id = B;
      if (fact === 'not_current') data.run.current = false;
      if (fact === 'unknown') data.run.process = 'unknown';
      if (fact === 'provider_work_done') { data.run.work = 'succeeded'; data.run.evidence = 'provider_event'; }
      return data;
    }; f.submit(); await flush();
    check(`run ${fact} cannot authorize a launch`, f.mutations().filter(r => r.operation === 'agent.launch').length, 0);
    if (fact !== 'provider_work_done') check('unverified run causes no interruption', f.mutations().length, 0);
    f.session.retireHost();
  }
  for (const operation of ['capabilities.get', 'project.list', 'pane.list', 'run.get']) {
    const f = fixture({ runId: R }); f.state.responseEdit = (req, got) => { if (req.operation === operation) got.instance_id = B; return got; }; f.submit(); await flush();
    check(`wrong readonly correlation ${operation} never mutates`, [f.mutations().length, f.session.getState().busy], [0, false]);
  }
  const reentrant = fixture();
  const reentrantLease = reentrant.session.bind(P, Q, notice => { if (notice.kind === 'busy' && notice.busy) reentrant.session.setConnected(false); });
  reentrantLease.submit(reentrant.intent(), reentrant.nextId()); await flush();
  check('callback retirement at admission cannot issue a read or mutation', [reentrant.trace.requests.length, reentrant.session.getState().busy], [0, false]);
  for (const boundary of ['occupancy', 'selection', 'cwd', 'version']) {
    const f = fixture({ runId: R }); f.state.dataEdit = (req, data) => {
      if (req.operation === 'run.interrupt') {
        f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
        if (boundary === 'occupancy') f.state.runId = N;
        if (boundary === 'selection') f.state.pane = B;
        if (boundary === 'cwd') f.state.cwd = 'C:\\別';
        if (boundary === 'version') f.state.version = '2.0';
      } return data;
    }; f.submit(); await flush();
    check(`changed ${boundary} after interrupt forbids launch`, [f.mutations().map(r => r.operation), f.session.getState().busy], [['run.interrupt'], false]);
  }
  for (const ordering of ['direct_first', 'record_first']) {
    const f = fixture({ runId: R }); f.state.hold = 'run.interrupt'; f.submit(); await flush(); f.state.hold = 'operation.get';
    const recovering = f.session.recheck(); await flush();
    f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
    if (ordering === 'direct_first') { f.release(); await flush(); f.release(); }
    else { const saved = f.state.held.splice(1, 1)[0]; saved.resolve({ schema_version: 1, instance_id: I, operation_id: saved.req.operation_id, accepted: true, topology_revision: 9, event_seq: 5, result: { operation: 'operation.get', data: { operation: { operation_id: f.mutations()[0].operation_id, phase: 'completed', outcome: 'succeeded', error_code: null } } }, error: null }); await flush(); f.release(); }
    await recovering; await flush();
    check(`${ordering} direct/query crossing settles only original stage`, [f.mutations().map(r => r.operation), f.session.getState().busy], [['run.interrupt'], false]);
  }
  for (const provider of ['codex', 'claude']) {
    const f = fixture({ provider, kind: 'interrupt-run', runId: R });
    f.state.dataEdit = (req, data) => { if (req.operation === 'run.interrupt') f.state.hold = 'run.get'; return data; };
    f.submit(); await flush();
    check(`${provider} original run Q is held after accepted interrupt`, [f.state.held.length, f.session.getState().busy], [1, true]);
    const old = f.state.held[0];
    f.session.setConnected(false); f.session.setConnected(true);
    f.state.hold = null; f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
    await f.session.recheck(); await flush();
    check(`${provider} new connection reads exit without waiting for old run Q`, [f.trace.requests.filter(r => r.operation === 'run.get').length, f.session.getState().busy, f.mutations().length], [3, false, 1]);
    const settled = f.session.getState().last;
    old.resolve({ schema_version: 1, instance_id: I, operation_id: old.req.operation_id, accepted: true, topology_revision: 9, event_seq: 5,
      result: { operation: 'run.get', data: { run: { run_id: R, pane_id: Q, current: true, process: 'running', work: 'running', evidence: 'provider_event', exit_code: null, observed_at: '2026-09-28T00:00:00Z' } } }, error: null });
    await flush();
    check(`${provider} late old run Q cannot revive mutation or continuation`, [f.session.getState().last, f.session.getState().busy, f.mutations().length], [settled, false, 1]);
  }
  const duplicate = fixture(); duplicate.state.hold = 'agent.launch'; check('first submit admitted', duplicate.submit()); check('rapid duplicate blocked', duplicate.submit(), false); await flush();
  duplicate.bind(B); duplicate.bind(); check('A B A keeps host latch', duplicate.submit(), false);
  duplicate.session.setConnected(false); duplicate.session.setConnected(true); check('reconnect cannot discard dispatched latch', duplicate.submit(), false);
  duplicate.session.retireHost(); const newHost = fixture(); check('actual new host independent admission', newHost.submit()); await flush(); check('new host completed', newHost.session.getState().busy, false);
  const retired = duplicate.session.getState(); duplicate.release(); await flush(); check('old host response cannot affect retired session', duplicate.session.getState(), retired);
  for (const arrival of ['success', 'refused', 'exception']) {
    const f = fixture(); f.state.hold = 'agent.launch'; f.submit(); await flush();
    const original = f.mutations()[0];
    const oldCount = f.trace.requests.length;
    const successorReads = [];
    const successorPort = { ownerKey: { instanceId: I, ownerGeneration: '1' }, recover(origin, req) {
      if (origin.instanceId !== I || origin.ownerGeneration !== '1') throw new Error('owner_mismatch');
      return successorPort.exchange(req);
    }, exchange(req) {
      successorReads.push(clone(req));
      if (req.operation !== 'operation.get') throw new Error('unexpected successor operation');
      return Promise.resolve({ schema_version: 1, instance_id: I, operation_id: req.operation_id, accepted: true,
        topology_revision: 9, event_seq: 5, result: { operation: 'operation.get', data: { operation: {
          operation_id: original.operation_id, phase: 'completed', outcome: 'succeeded', error_code: null,
        } } }, error: null });
    } };
    f.session.setConnected(false);
    check(`${arrival} successor binds recovery read port`, f.session.bindRecoveryPort(successorPort), true);
    await f.session.recheck(); await flush();
    check(`${arrival} recovery uses successor distinct-ID read only`, [f.trace.requests.length, successorReads.map(r => [r.operation, r.params.operation_id, r.operation_id !== original.operation_id]), f.mutations().length],
      [oldCount, [['operation.get', original.operation_id, true]], 1]);
    const recovered = f.session.getState();
    const held = f.state.held.shift();
    if (arrival === 'exception') held.reject(new Error('transport failed'));
    else if (arrival === 'refused') held.resolve({ schema_version: 1, instance_id: I, operation_id: original.operation_id, accepted: false,
      topology_revision: 9, event_seq: 5, result: null, error: { code: 'permission_denied', message: 'Permission denied.', target_id: null, retryable: false } });
    else held.resolve({ schema_version: 1, instance_id: I, operation_id: original.operation_id, accepted: true,
      topology_revision: 9, event_seq: 5, result: { operation: 'agent.launch', data: { pane_id: Q, run_id: N, phase: 'accepted' } }, error: null });
    await flush();
    check(`${arrival} A late mutation cannot change B recovery`, [f.session.getState(), f.trace.requests.length, successorReads.length], [recovered, oldCount, 1]);
    f.session.retireHost();
  }
  for (const field of ['revision', 'seq']) {
    const f = fixture(); f.state.responseEdit = (req, got) => { if (req.operation === 'pane.list') got[field === 'revision' ? 'topology_revision' : 'event_seq'] = field === 'revision' ? 10 : 4; return got; }; f.submit(); await flush();
    check(`inconsistent preflight ${field} blocks mutation`, f.mutations().length, 0);
  }
  // The successor needs cleanup as well as actual exit. These are separate
  // observations; only an externally delivered observation drives the owner.
  for (const provider of ['codex', 'claude']) {
    for (const process of ['starting', 'running', 'exited']) {
      const ended = process === 'exited';
      const f = fixture({ provider, runId: R, process, evidenceKind: ended ? 'process_exit' : 'unavailable', cleanupComplete: false });
      f.submit(); await flush();
      check(`${provider}/${process} initial cleanup wait never launches`, f.mutations().map(r => r.operation), ended ? [] : ['run.interrupt']);
      f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
      await f.session.observe(); await flush();
      check('actual exit with unfinished cleanup remains busy', f.session.getState().busy);
      check('cleanup false sends no successor', f.mutations().filter(r => r.operation === 'agent.launch').length, 0);
      const count = f.trace.requests.length; await flush(); await flush();
      check('read completion does not poll itself', f.trace.requests.length, count);
      f.state.cleanupComplete = true;
      await f.session.observe(); await flush();
      check('fresh correlated cleanup authorizes one guarded successor', f.mutations().map(r => r.operation), ended ? ['agent.launch'] : ['run.interrupt', 'agent.launch']);
      assertGuard(f, R);
      check('cleanup continuation releases semantic latch', f.session.getState().busy, false);
      check('cleanup extension requested on every normal run read', f.trace.requests.filter(r => r.operation === 'run.get').every(r => r.params.include_cleanup === true));
      const terminal = f.trace.requests.length; await f.session.observe(); await f.session.observe(); await flush();
      check('later hints cannot replay cleanup successor', f.trace.requests.length, terminal);
    }
    for (const ended of [false, true]) {
      const f = fixture({ provider, runId: R, process: ended ? 'exited' : 'running', evidenceKind: ended ? 'process_exit' : 'unavailable', cleanupComplete: false });
      f.submit(); await flush(); f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
      await f.session.observe(); await flush();
      f.state.hold = 'run.get';
      const first = f.session.observe(); await flush(); const second = f.session.observe(); const third = f.session.observe();
      check('cleanup read hints coalesce in the same flight', first === second && second === third);
      check('only one cleanup read is held', f.state.held.length, 1);
      f.state.cleanupComplete = true; f.state.hold = null; f.release(); await first; await flush();
      check('coalesced hint cannot transfer into successor stage', f.mutations().filter(r => r.operation === 'agent.launch').length, 1);
      check('coalesced cleanup reaches terminal', f.session.getState().busy, false);
      const after = f.trace.requests.length; await flush(); check('old hint has no feedback loop', f.trace.requests.length, after);
    }
    for (const cancel of ['recheck', 'dispose', 'rebind', 'disconnect', 'retire_host']) {
      for (const held of [false, true]) {
        const f = fixture({ provider, runId: R, process: 'exited', evidenceKind: 'process_exit', cleanupComplete: false });
        f.submit(); await flush();
        let reading;
        if (held) { f.state.hold = 'run.get'; reading = f.session.observe(); await flush(); }
        if (cancel === 'recheck') await f.session.recheck();
        if (cancel === 'dispose') f.dispose();
        if (cancel === 'rebind') f.bind(B);
        if (cancel === 'disconnect') f.session.setConnected(false);
        if (cancel === 'retire_host') f.session.retireHost();
        check(`${provider}/${cancel}/held=${held} cancels unsent cleanup immediately`, [f.session.getState().busy, f.mutations().length], [false, 0]);
        if (cancel !== 'retire_host') check('unsent preparation cancellation is explicit', f.session.getState().last.disposition, 'unsent_cancelled');
        f.state.cleanupComplete = true;
        if (held) { f.state.hold = null; f.release(); await reading; }
        if (cancel === 'disconnect') f.session.setConnected(true);
        await f.session.observe(); await flush();
        check('late cleanup and recovery cannot revive cancelled preflight', f.mutations().length, 0);
        f.session.retireHost();
      }
    }
    const backwards = fixture({ provider, runId: R, process: 'exited', evidenceKind: 'process_exit', cleanupComplete: false });
    backwards.submit(); await flush(); backwards.state.process = 'running'; backwards.state.evidenceKind = 'unavailable';
    await backwards.session.observe(); await flush();
    check('unsent exited wait cannot become a second interrupt', [backwards.mutations().length, backwards.session.getState().busy], [0, false]);
    for (const boundary of ['version', 'root', 'cwd', 'project', 'pane', 'runId']) {
      for (const ended of [false, true]) {
        const f = fixture({ provider, runId: R, process: ended ? 'exited' : 'running', evidenceKind: ended ? 'process_exit' : 'unavailable', cleanupComplete: false });
        f.submit(); await flush(); f.state.process = 'exited'; f.state.evidenceKind = 'process_exit';
        await f.session.observe(); await flush(); f.state.cleanupComplete = true;
        f.state[boundary] = ['project', 'pane', 'runId'].includes(boundary) ? B : 'changed';
        await f.session.observe(); await flush();
        check(`cleanup then fresh ${boundary}/ended=${ended} refuses successor`, [f.mutations().filter(r => r.operation === 'agent.launch').length, f.session.getState().busy, f.session.getState().last.disposition], [0, false, 'refused']);
      }
    }
    for (const flag of [undefined, null, 0, 'true', [], {}]) {
      const f = fixture({ provider, runId: R, process: 'exited', evidenceKind: 'process_exit' });
      f.state.dataEdit = (req, data) => {
        if (req.operation === 'run.get') { if (flag === undefined) delete data.cleanup_complete; else data.cleanup_complete = flag; }
        return data;
      };
      f.submit(); await flush();
      check('missing or nonboolean readiness never authorizes a mutation', [f.mutations().length, f.session.getState().busy], [0, false]);
    }
    const incoherent = fixture({ provider, runId: R, process: 'running', cleanupComplete: true });
    incoherent.submit(); await flush(); check('ready flag with running observation never mutates', incoherent.mutations().length, 0);
    const historical = fixture({ provider, runId: R, process: 'exited', evidenceKind: 'process_exit', cleanupComplete: true });
    historical.state.dataEdit = (req, data) => { if (req.operation === 'run.get') data.run.current = false; return data; };
    historical.submit(); await flush(); check('history readiness is never current launch authority', historical.mutations().length, 0);
    const recovered = fixture({ provider, runId: R, cleanupComplete: false }); recovered.state.hold = 'run.interrupt'; recovered.submit(); await flush();
    recovered.state.process = 'exited'; recovered.state.evidenceKind = 'process_exit';
    await recovered.session.recheck(); await flush();
    check('recovered compound settles predecessor without cleanup', [recovered.session.getState().busy, recovered.session.getState().last.disposition, recovered.mutations().map(r => r.operation)], [false, 'partial', ['run.interrupt']]);
    recovered.state.cleanupComplete = true; recovered.release(); await recovered.session.observe(); await flush();
    check('late direct and cleanup cannot revive recovered chain', recovered.mutations().map(r => r.operation), ['run.interrupt']);
    const single = fixture({ provider, kind: 'interrupt-run', runId: R, cleanupComplete: false }); single.submit(); await flush(); single.state.process = 'exited'; single.state.evidenceKind = 'process_exit';
    await single.session.observe(); await flush();
    check('standalone interrupt completes on actual exit despite cleanup false', [single.session.getState().busy, single.session.getState().last.disposition], [false, 'completed']);
    check('standalone interrupt keeps legacy read shape', single.trace.requests.filter(r => r.operation === 'run.get').every(r => !Object.hasOwn(r.params, 'include_cleanup')));
  }
} catch (error) { failure = error.stack ?? String(error); }
const after = identity();
const protectedAfter = protectedIdentity();
if (JSON.stringify(before) !== JSON.stringify(after)) failure ??= 'Source changed during execution';
if (JSON.stringify(protectedBefore) !== JSON.stringify(protectedAfter)) failure ??= 'Protected files changed during execution';
writeFileSync(resolve(evidence, 'port-traces.json'), JSON.stringify(traces, null, 2) + '\n', 'utf8');
const result = { started, finished: new Date().toISOString(), scope: 'pure bundled command owner; not native GUI/Rust/provider acceptance', dependency_root: dependencies, before, after, protected_before: protectedBefore, protected_after: protectedAfter, compile_exit: compile?.status ?? null, checks, passed: checks.filter(c => c.passed).length, failure };
writeFileSync(resolve(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n', 'utf8');
console.log(JSON.stringify({ evidence, passed: result.passed, failure, source_preserved: JSON.stringify(before) === JSON.stringify(after), protected_preserved: JSON.stringify(protectedBefore) === JSON.stringify(protectedAfter) }));
if (failure) process.exitCode = 1;
