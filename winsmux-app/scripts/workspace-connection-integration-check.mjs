import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const { build } = require('esbuild');
const { chromium } = require('playwright');
const shims = {
  '@tauri-apps/api/core': 'export const invoke=(name,args)=>globalThis.fixture.invoke(name,args);',
  '@tauri-apps/api/webviewWindow': 'export const getCurrentWebviewWindow=()=>({label:"main"}); export class WebviewWindow { constructor(){throw Error("unexpected secondary window")} }',
  '@tauri-apps/api/event': 'export const listen=async(name,callback)=>{globalThis.fixture.listeners[name]=callback;return()=>{delete globalThis.fixture.listeners[name]}};',
  '@tauri-apps/plugin-dialog': 'export const open=async()=>null;',
  xterm: 'export class Terminal { constructor(){this.cols=0;this.rows=0;this.options={};this.parser={registerCsiHandler:()=>({dispose(){}})}} loadAddon(){} open(slot){this.textarea=document.createElement("textarea");slot.append(this.textarea)} write(){} reset(){} onResize(){return{dispose(){}}} onData(handler){this.sendInput=handler;globalThis.fixture.term=this;return{dispose(){}}} onKey(){return{dispose(){}}} attachCustomKeyEventHandler(){} hasSelection(){return false} dispose(){} }',
  '@xterm/addon-fit': 'export class FitAddon {fit(){}}',
};
const bundled = await build({ entryPoints: [resolve(app, 'src/workspace-ui/startup-mount.ts')], bundle: true, write: false,
  format: 'esm', platform: 'browser', target: 'es2020', plugins: [{ name: 'closed-native-effects', setup(b) {
    b.onResolve({ filter: /.*/ }, args => args.path in shims ? { path: args.path, namespace: 'effect' } : args.path.endsWith('.css') ? { path: args.path, namespace: 'css' } : undefined);
    b.onLoad({ filter: /.*/, namespace: 'effect' }, args => ({ contents: shims[args.path], loader: 'js' }));
    b.onLoad({ filter: /.*/, namespace: 'css' }, () => ({ contents: '', loader: 'js' }));
  } }] });
const browser = await chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
try {
  const page = await browser.newPage();
  await page.route('**/*', route => route.request().url() === 'https://tauri.localhost/'
    ? route.fulfill({ contentType: 'text/html', body: '<!doctype html><html lang="ja"><meta charset="utf-8"><body><main></main></body></html>' }) : route.abort());
  await page.goto('https://tauri.localhost/');
  await page.exposeFunction('pressTask876Key', key => page.keyboard.press(key));
  const checks = await page.evaluate(async code => {
    const I = '11111111-1111-4111-8111-111111111111', P = '22222222-2222-4222-8222-222222222222', Q = '55555555-5555-4555-8555-555555555555';
    const A = '33333333-3333-4333-8333-333333333333', B = '44444444-4444-4444-8444-444444444444';
    const N = '66666666-6666-4666-8666-666666666666', R = '77777777-7777-4777-8777-777777777777';
    const R2 = '88888888-8888-4888-8888-888888888888';
    const checks = [];
    const check = (name, ok) => { if (!ok) throw Error(name); checks.push(name); };
    const envelope = (q, data) => ({ schema_version: 1, instance_id: q.instance_id, operation_id: q.operation_id,
      accepted: true, topology_revision: 1, event_seq: 0, result: { operation: q.operation, data }, error: null });
    const row = (id, state) => ({ connection_id: id, state, executable_name: 'fixture',
      requested_project_ids: [P], requested_scopes: ['metadata'],
      granted_project_ids: state === 'granted' ? [P] : [], granted_scopes: state === 'granted' ? ['metadata'] : [] });
    const f = globalThis.fixture = { calls: [], host: 'Ready', revision: 4, instanceId: I, ownerGeneration: '1', rows: [],
      statusCalls: 0, openCalls: 0, pending: null, late: null, guardLease: '1', nextStatus: null, failNextList: false, releaseStatus: null, failOpen: false,
      withRun: false, runId: R, inputSeq: 0, term: null, holdNextInput: false, lateInput: null,
      holdNextGuardStatus: false, lateGuardStatus: null, listeners: {}, guardStatus: null,
      guardReplies: [], holdNextGuardReply: false, lateGuardReply: null, enforceGuardOpen: false,
      holdNextOperationGet: false, lateOperationGet: null,
      holdNextCapabilities: false, lateCapabilities: null,
      holdNextDetailsOperation: null, lateDetails: null, holdNextProject: false, lateProject: null };
    Object.assign(f, { discoveryCalls: 0, copyCalls: [], copyWrites: 0, holdDiscovery: false, lateDiscovery: null,
      holdCopy: false, lateCopy: null, copyError: null, copyReceipt: null, browserCopies: 0 });
    Object.defineProperty(navigator, 'clipboard', { configurable: true,
      value: { writeText: async () => { f.browserCopies++; throw Error('browser clipboard intentionally unavailable'); } } });
    f.invoke = async (name, args) => {
      if (name === 'startup_main_policy_ready' || name === 'startup_main_show') return null;
      if (name === 'workspace_session_open') {
        f.openCalls++;
        if (f.failOpen) throw 'transport_uncertain';
        if (f.enforceGuardOpen && ['pending', 'approved'].includes(f.guardStatus?.fence?.state)) throw 'shutdown_in_progress';
        return { instance_id: f.instanceId, schema_version: 1 };
      }
      if (name === 'workspace_host_status') { f.statusCalls++; const next = f.nextStatus; f.nextStatus = null;
        if (next === 'failed') throw Error('status_probe_failed');
        if (next === 'hold') return new Promise((resolve, reject) => {
          f.releaseStatus = value => resolve(value); f.rejectStatus = reject;
        });
        return next ?? { instance_id: f.instanceId, generation: f.ownerGeneration, revision: String(f.revision), phase: f.host }; }
      if (name === 'workspace_discovery_get') {
        f.discoveryCalls++;
        const value = { instance_id: f.instanceId, pipe_name: '\\\\.\\pipe\\winsmux-workspace-v1-fixture', schema_version: 1 };
        if (f.holdDiscovery) { f.holdDiscovery = false; return new Promise(resolve => { f.lateDiscovery = () => resolve(value); }); }
        return value;
      }
      if (name === 'workspace_discovery_copy') {
        const request = JSON.parse(args.requestJson); f.copyCalls.push(request);
        if (f.host !== 'Ready' || request.owner_generation !== f.ownerGeneration || request.discovery.instance_id !== f.instanceId) throw 'protocol_failed';
        if (f.copyError) { const error = f.copyError; f.copyError = null; throw error; }
        f.copyWrites++;
        const receipt = f.copyReceipt ?? request; f.copyReceipt = null;
        if (f.holdCopy) { f.holdCopy = false; return new Promise(resolve => { f.lateCopy = () => resolve(receipt); }); }
        return receipt;
      }
      if (name === 'desktop_initial_project_dir') return null;
      if (name === 'workspace_input_guard_register' || name === 'workspace_input_guard_status') {
        const status = structuredClone(f.guardStatus ?? { lease: f.guardLease, revision: '1', fence: null, resume_allowed: false, admission_error: null });
        if (name === 'workspace_input_guard_status' && f.holdNextGuardStatus) {
          f.holdNextGuardStatus = false;
          return new Promise((resolve, reject) => { f.lateGuardStatus = { success: () => resolve(status), reject }; });
        }
        return status;
      }
      if (name === 'workspace_input_guard_reply') {
        const body = JSON.parse(args.requestJson); f.guardReplies.push(body);
        const apply = () => {
          if (f.guardStatus?.fence?.state !== 'pending' || f.guardStatus.fence.nonce !== body.nonce) throw 'input_guard_stale';
          f.guardStatus = { lease: body.lease, revision: String(BigInt(f.guardStatus.revision) + 1n),
            fence: { nonce: body.nonce, state: body.safe ? 'approved' : 'released' },
            resume_allowed: !body.safe, admission_error: body.safe ? 'shutdown_in_progress' : null };
          return structuredClone(f.guardStatus);
        };
        if (f.holdNextGuardReply) {
          f.holdNextGuardReply = false;
          const outcome = apply();
          return new Promise((resolve, reject) => { f.lateGuardReply = { success: () => resolve(outcome), reject }; });
        }
        return apply();
      }
      if (name !== 'workspace_request') throw Error(`Unexpected native effect ${name}`);
      const q = JSON.parse(args.requestJson); f.calls.push(q);
      switch (q.operation) {
        case 'capabilities.get': {
          const answer = () => envelope(q, { schema_version: 1, operations: ['capabilities.get', 'project.list', 'pane.list', 'events.wait', 'connection.list', 'connection.decide', 'connection.revoke', 'operation.get', 'run.get', 'output.read', 'input.write'], providers: null, shell_profile_ids: null, max_message_bytes: 1048576, replay_capacity: { retained_bytes: 134217728, active_bytes: 268435456 } });
          if (f.holdNextCapabilities) { f.holdNextCapabilities = false; return new Promise((resolve, reject) => {
            f.lateCapabilities = { success: () => resolve(answer()), refused: () => resolve({ ...envelope(q, null), accepted: false, result: null,
              error: { code: 'not_running', message: 'Run is not running.', retryable: false, target_id: null } }), reject };
          }); }
          return answer();
        }
        case 'project.list': return envelope(q, { projects: [{ project_id: P, path: 'C:/fixture', display_name: 'Fixture', root_state: 'verified' },
          { project_id: Q, path: 'C:/other', display_name: 'Other', root_state: 'verified' }], selected_project_id: P });
        case 'project.select': {
          const answer = () => envelope(q, { selected_project_id: q.params.project_id, selected_pane_id: null });
          if (f.holdNextProject) { f.holdNextProject = false; return new Promise((resolve, reject) => {
            f.lateProject = { success: () => resolve(answer()), refused: () => resolve({ ...envelope(q, null), accepted: false, result: null,
              error: { code: 'permission_denied', message: 'Denied', retryable: false, target_id: null } }), reject };
          }); }
          return answer();
        }
        case 'pane.list': return envelope(q, f.withRun && q.params.project_id === P
          ? { project_id: P, selected_pane_id: N, panes: [{ pane_id: N, project_id: P, display_name: 'Terminal', path: 'C:/fixture', current_run_id: f.runId,
            observation: { run_id: f.runId, pane_id: N, process: 'running', work: 'running', evidence: 'provider_event', observed_at: '2026-09-28T00:00:00Z', current: true, exit_code: null } }], root: { kind: 'leaf', pane_id: N } }
          : { project_id: q.params.project_id, selected_pane_id: null, panes: [], root: null });
        case 'events.wait': return envelope(q, { events: [], next_event_seq: 0, status: 'no_change' });
        case 'output.read': return envelope(q, { run_id: q.params.run_id, text: '', next_cursor: 'cursor-0', gap: false, truncated: false });
        case 'artifact.list': return envelope(q, { registered: [], git_candidates: ['git/changed.txt'] });
        case 'artifact.register':
        case 'layout.restore': {
          const answer = () => envelope(q, q.operation === 'artifact.register'
            ? { artifact: { artifact_id: A, project_id: P, relative_path: q.params.relative_path, run_id: null, association: null } }
            : { restored: true, generation: 1 });
          if (f.holdNextDetailsOperation === q.operation) { f.holdNextDetailsOperation = null;
            return new Promise((resolve, reject) => { f.lateDetails = { success: () => resolve(answer()),
              refused: () => resolve({ ...envelope(q, null), accepted: false, result: null,
                error: { code: 'permission_denied', message: 'Denied', retryable: false, target_id: null } }), reject }; });
          }
          return answer();
        }
        case 'run.get': return envelope(q, { run: { run_id: q.params.run_id, pane_id: N, current: q.params.run_id === f.runId, process: 'running', work: 'running', evidence: 'provider_event', exit_code: null, observed_at: '2026-09-28T00:00:00Z' } });
        case 'input.write': {
          const reply = () => envelope(q, { input_seq: ++f.inputSeq, pane_id: N, run_id: q.params.run_id,
            written_bytes: new TextEncoder().encode(q.params.text).length });
          if (f.holdNextInput) { f.holdNextInput = false; return new Promise((resolve, reject) => {
            f.lateInput = { success: () => resolve(reply()), reject,
              refused: () => resolve({ ...envelope(q, null), accepted: false, result: null,
                error: { code: 'not_running', message: 'Run is not running.', retryable: false, target_id: null } }) };
          }); }
          return reply();
        }
        case 'connection.list': if (f.failNextList) { f.failNextList = false; throw 'transport_uncertain'; }
          return envelope(q, { connections: f.rows });
        case 'operation.get': {
          const success = () => envelope(q, { operation: { operation_id: q.params.operation_id, phase: 'completed', outcome: 'succeeded', error_code: null } });
          if (f.holdNextOperationGet) { f.holdNextOperationGet = false; return new Promise((resolve, reject) => {
            f.lateOperationGet = { success: () => resolve(success()),
              refused: () => resolve({ ...envelope(q, null), accepted: false, result: null,
                error: { code: 'not_running', message: 'Run is not running.', retryable: false, target_id: null } }), reject };
          }); }
          return success();
        }
        case 'connection.decide':
        case 'connection.revoke': f.pending = q; return new Promise((resolve, reject) => { f.late = {
          success: () => resolve(envelope(q, { connection_id: A, state: q.operation === 'connection.revoke' || q.params.decision === 'deny' ? 'revoked' : 'granted', project_ids: q.params.project_ids ?? [], scopes: q.params.scopes ?? [] })),
          refused: () => resolve({ ...envelope(q, null), accepted: false, result: null, error: { code: 'permission_denied', message: 'Denied', retryable: false, target_id: null } }),
          reject,
        }; });
        default: throw Error(`Unexpected workspace request ${q.operation}`);
      }
    };
    const frames = [];
    globalThis.requestAnimationFrame = callback => { frames.push(callback); return frames.length; };
    globalThis.cancelAnimationFrame = () => {};
    const tick = async () => { for (let i = 0; i < 8; i++) await new Promise(done => setTimeout(done, 0)); };
    const frame = async () => { frames.shift()?.(0); await tick(); };
    const keyboardReconnect = async (root, context) => {
      const reconnect = root.querySelector(':scope > button');
      check(context + ' visible enabled reconnect', !!reconnect && !reconnect.hidden && !reconnect.disabled);
      const before = document.createElement('button'); before.type = 'button'; before.textContent = 'fixture focus origin';
      root.insertBefore(before, reconnect); before.focus();
      await globalThis.pressTask876Key('Tab');
      check(context + ' Tab reaches reconnect', document.activeElement === reconnect);
      await globalThis.pressTask876Key('Enter'); before.remove();
    };
    const module = await import(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    for (const scenario of ['success', 'occupied', 'old-generation', 'forged-receipt', 'dispose-discovery', 'blocked-discovery', 'dispose-copy']) {
      Object.assign(f, { calls: [], withRun: false, host: 'Ready', guardLease: '1', guardStatus: null,
        ownerGeneration: '1', discoveryCalls: 0, copyCalls: [], copyWrites: 0,
        holdDiscovery: false, lateDiscovery: null, holdCopy: false, lateCopy: null, browserCopies: 0 });
      f.revision++; f.rows = [row(A, 'pending')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && !mounted; i++) await frame(); await opening;
      const section = root.querySelector('.workspace-connections');
      const button = [...section.querySelectorAll('button')].find(value => value.textContent === '現在の接続情報をコピー');
      const status = button.nextElementSibling;
      check(scenario + ' actual connection copy available', !!button && !button.disabled);
      if (scenario === 'occupied') f.copyError = 'clipboard_unavailable';
      if (scenario === 'forged-receipt') f.copyReceipt = { owner_generation: '2', discovery: {
        instance_id: I, pipe_name: '\\\\.\\pipe\\winsmux-workspace-v1-fixture', schema_version: 1 } };
      if (['dispose-discovery', 'blocked-discovery', 'old-generation'].includes(scenario)) f.holdDiscovery = true;
      if (scenario === 'dispose-copy') f.holdCopy = true;
      button.click(); button.click(); await tick();
      check(scenario + ' repeated click has one discovery request', f.discoveryCalls === 1);
      if (scenario === 'dispose-discovery') {
        mounted.dispose(); f.lateDiscovery(); await tick();
        check('disposed discovery never dispatches native copy', f.copyCalls.length === 0 && !status.textContent.includes('コピーしました'));
      } else if (scenario === 'blocked-discovery') {
        f.host = 'Unknown'; f.revision++; f.failNextList = true;
        [...section.querySelectorAll('button')].find(value => value.textContent === '接続一覧を読み直す').click();
        await tick();
        check('discovery pre-write host block is established', button.disabled && section.textContent.includes('接続'));
        f.lateDiscovery(); await tick();
        check('blocked discovery never dispatches native copy', f.copyCalls.length === 0 && !status.textContent.includes('コピーしました'));
      } else if (scenario === 'old-generation') {
        f.ownerGeneration = '2'; f.lateDiscovery(); await tick();
        check('native refuses old owner generation before clipboard write', f.copyWrites === 0 && !status.textContent.includes('コピーしました'));
      } else if (scenario === 'dispose-copy') {
        check('copy in flight cannot submit a second write', f.copyCalls.length === 1 && button.disabled);
        mounted.dispose(); f.lateCopy(); await tick();
        check('retired copy receipt never paints success', !status.textContent.includes('コピーしました'));
      } else if (scenario === 'success') {
        const request = f.copyCalls[0];
        check('copy uses native exact current owner and three-field discovery', f.copyWrites === 1 && request.owner_generation === '1'
          && Object.keys(request).sort().join() === 'discovery,owner_generation'
          && Object.keys(request.discovery).sort().join() === 'instance_id,pipe_name,schema_version'
          && request.discovery.instance_id === I && status.textContent.includes('コピーしました'));
      } else {
        check(scenario + ' never reports successful copy', !status.textContent.includes('コピーしました') && status.textContent.length > 0);
        check(scenario + ' keeps live connections and permits retry', !!root.querySelector('.workspace-connections') && !button.disabled);
      }
      check(scenario + ' never uses browser clipboard', f.browserCopies === 0);
      mounted.dispose(); root.remove(); frames.length = 0; f.ownerGeneration = '1'; f.host = 'Ready'; f.revision++;
    }
    {
      f.calls = []; f.withRun = false; f.host = 'Ready'; f.guardLease = '1'; f.revision++;
      f.rows = [row(A, 'pending'), row(B, 'granted')]; f.enforceGuardOpen = true;
      f.guardStatus = null; f.guardReplies = []; f.lateGuardReply = null;
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame(); await opening;
      f.guardStatus = { lease: '1', revision: '2', fence: { nonce: '2', state: 'pending' },
        resume_allowed: false, admission_error: 'shutdown_in_progress' };
      f.holdNextGuardReply = true;
      f.listeners['workspace-input-guard-changed']?.({ payload: { lease: '1', revision: '2' } });
      for (let i = 0; i < 20 && !f.lateGuardReply; i++) await tick();
      check('native Pending quiescence sends exact safe reply once', !!f.lateGuardReply
        && f.guardReplies.length === 1 && f.guardReplies[0].safe === true && f.guardReplies[0].nonce === '2');
      await keyboardReconnect(root, 'native approved reply pending');
      for (let i = 0; i < 20 && root.dataset.startupState !== 'recovering'; i++) await frame();
      const inputPanel = root.querySelector('.workspace-input-confirmation');
      check('shutdown in progress leaves a keyboard reachable recovery shell', root.dataset.startupState === 'recovering'
        && !root.querySelector(':scope > button').hidden && !inputPanel.inert && !inputPanel.hidden
        && root.querySelector('.workspace-connections') === null && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      const guardRecheck = [...inputPanel.querySelectorAll('button')].find(button => button.textContent === '入力の受付状態を再確認');
      guardRecheck.focus(); await globalThis.pressTask876Key('Enter'); await tick();
      check('recovery shell guard recheck does not open host or authorize', root.dataset.startupState === 'recovering'
        && f.calls.filter(q => q.operation === 'connection.decide' || q.operation === 'connection.revoke').length === 0);
      const shellText = root.textContent;
      f.lateGuardReply.success(); await tick();
      check('old native reply arrival cannot exit recovery shell', root.dataset.startupState === 'recovering'
        && root.textContent === shellText);
      f.guardStatus = { lease: '1', revision: '4', fence: { nonce: '2', state: 'released' },
        resume_allowed: true, admission_error: null };
      guardRecheck.focus(); await globalThis.pressTask876Key('Enter'); await tick();
      check('released native lease still requires explicit reconnect', root.dataset.startupState === 'recovering');
      await keyboardReconnect(root, 'released recovery shell');
      for (let i = 0; i < 30 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check('explicit reconnect after released lease mounts live host', root.dataset.startupState === 'mounted');
      mounted.dispose(); root.remove(); frames.length = 0; f.enforceGuardOpen = false; f.guardStatus = null;
    }
    {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      const oldTerm = f.term;
      f.holdNextGuardStatus = true; f.lateGuardStatus = null;
      oldTerm.sendInput('old');
      for (let i = 0; i < 20 && !f.lateGuardStatus; i++) await tick();
      check('old input completion begins held guard status', !!f.lateGuardStatus
        && f.calls.filter(q => q.operation === 'input.write').length === 1);
      const oldGuard = f.lateGuardStatus;
      await keyboardReconnect(root, 'A guard status pending');
      for (let i = 0; i < 35 && (root.dataset.startupState !== 'mounted' || f.term === oldTerm); i++) await frame();
      check('new mount has current input producer before old guard settles', root.dataset.startupState === 'mounted' && f.term !== oldTerm);
      oldGuard.reject(Error('old_guard_status_failed')); await tick();
      f.term.sendInput('new'); await tick();
      check('old guard rejection cannot freeze new mounted input', f.calls.filter(q => q.operation === 'input.write').length === 2);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    for (const arrival of ['success', 'refused', 'exception']) {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      f.holdNextCapabilities = false; f.lateCapabilities = null;
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      f.holdNextCapabilities = true;
      for (let i = 0; i < 8 && !f.lateCapabilities; i++) await frame();
      check('A agent observation capabilities held for ' + arrival, !!f.lateCapabilities);
      const late = f.lateCapabilities;
      await keyboardReconnect(root, 'A agent observation pending ' + arrival);
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check('B mounts while A agent observation read is unresolved ' + arrival, root.dataset.startupState === 'mounted');
      const before = f.calls.filter(q => ['project.list', 'pane.list', 'run.get', 'events.wait', 'output.read'].includes(q.operation)).length;
      if (arrival === 'success') late.success(); else if (arrival === 'refused') late.refused();
      else late.reject('transport_uncertain');
      await tick();
      check('retired A agent observation ' + arrival + ' starts no chained host reads',
        f.calls.filter(q => ['project.list', 'pane.list', 'run.get', 'events.wait', 'output.read'].includes(q.operation)).length === before);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    for (const operation of ['artifact.register', 'layout.restore']) for (const arrival of ['success', 'refused', 'exception']) {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      f.holdNextDetailsOperation = operation; f.lateDetails = null;
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      const detailsButton = [...root.querySelectorAll(':scope > button')].find(button => button.textContent === '成果物・配置・診断');
      check(`${operation}/${arrival} real mount exposes details`, !!detailsButton && !detailsButton.disabled);
      detailsButton.click(); await tick();
      const details = root.querySelector('.workspace-details');
      check(`${operation}/${arrival} details opened`, !!details);
      if (operation === 'artifact.register') {
        details.querySelector('[data-action="list"]').click(); await tick();
        const candidate = details.querySelector('[data-action="register-git"]');
        check(`${operation}/${arrival} candidate visible`, !!candidate && !candidate.disabled);
        candidate.click();
      } else {
        details.querySelector('[data-action="layout"]').click();
        details.querySelector('[data-action="restore"]').click();
      }
      for (let i = 0; i < 8 && !f.lateDetails; i++) await tick();
      check(`${operation}/${arrival} A mutation held`, !!f.lateDetails);
      const original = f.calls.find(q => q.operation === operation);
      const late = f.lateDetails;
      await keyboardReconnect(root, `${operation}/${arrival} held original`);
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check(`${operation}/${arrival} B mounts before A answer`, root.dataset.startupState === 'mounted');
      const beforeQ = f.calls.filter(q => q.operation === 'operation.get').length;
      check(`${operation}/${arrival} B reads original by distinct ID`, f.calls.some(q => q.operation === 'operation.get'
        && q.params.operation_id === original.operation_id && q.operation_id !== original.operation_id));
      const beforeState = details.querySelector(`[data-field="${operation === 'artifact.register' ? 'content-state' : 'restore-state'}"]`)?.textContent;
      if (arrival === 'success') late.success(); else if (arrival === 'refused') late.refused(); else late.reject('transport_uncertain');
      await tick();
      check(`${operation}/${arrival} A direct answer cannot initiate B query or change details projection`,
        f.calls.filter(q => q.operation === 'operation.get').length === beforeQ
        && details.querySelector(`[data-field="${operation === 'artifact.register' ? 'content-state' : 'restore-state'}"]`)?.textContent === beforeState);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    const run = async (action, late, hostCase = 'Ready') => {
      f.calls = []; f.pending = null; f.late = null; f.host = 'Ready'; f.nextStatus = null; f.guardLease = '1'; f.revision++;
      f.rows = [row(A, action === 'revoke' ? 'granted' : 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted;
      const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame();
      await opening;
      const section = root.querySelector('.workspace-connections');
      check(action + ' real main mount renders connection view', !!section);
      section.querySelector('[data-connection-id="' + A + '"]').click();
      if (action === 'allow') for (const choice of section.querySelectorAll('input[type=checkbox]')) choice.click();
      const label = action === 'allow' ? '選択内容を許可' : action === 'deny' ? '要求を拒否' : '許可を失効';
      [...section.querySelectorAll('button')].find(b => b.textContent === label).click();
      for (let i = 0; i < 20 && !f.pending; i++) await tick();
      const original = f.pending;
      check(action + ' one held original request', !!original && f.calls.filter(q => q.operation_id === original.operation_id).length === 1);
      f.rows = [row(A, action === 'allow' ? 'granted' : 'closing'), row(B, 'granted')];
      [...section.querySelectorAll('button')].find(b => b.textContent === '元の操作を確認し直す').click();
      for (let i = 0; i < 20 && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id); i++) await tick();
      check(action + ' distinct ID recovers held original', f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id && q.operation_id !== original.operation_id));
      for (let i = 0; i < 20 && f.calls.filter(q => q.operation === 'connection.list').length < 2; i++) await tick();
      check(action + ' recovery reads current list', f.calls.filter(q => q.operation === 'connection.list').length >= 2);
      const message = section.textContent;
      check(action + ' recovered current state shown', action === 'allow' ? message.includes('現在の許可も一致') : message.includes('権限は無効'));
      if (hostCase === 'Unknown' || hostCase === 'Busy') { f.host = hostCase; f.revision++; }
      if (hostCase === 'probe_failed') f.nextStatus = 'failed';
      if (hostCase === 'wrong_generation') f.nextStatus = { instance_id: I, generation: '2', revision: String(f.revision + 1), phase: 'Unknown' };
      if (hostCase === 'invalid_shape') f.nextStatus = { instance_id: I, generation: '1', revision: String(f.revision + 1), phase: 'Unknown', pipe_name: 'forbidden' };
      if (late === 'success') f.late.success(); else if (late === 'refused') f.late.refused(); else f.late.reject('transport_uncertain');
      await tick();
      check(action + ' ' + hostCase + ' late ' + late + ' force exit matches Rust', root.querySelector(':scope > button:nth-of-type(2)').hidden === (hostCase !== 'Unknown'));
      check(action + ' ' + hostCase + ' retains historical ID', section.textContent.includes(original.operation_id));
      if (hostCase === 'Ready' || hostCase === 'Busy') check(action + ' ' + hostCase + ' preserves history and current grant', section.textContent === message);
      else check(action + ' ' + hostCase + ' withdraws effective grant', !section.textContent.includes('現在の許可も一致'));
      check(action + ' late ' + late + ' never replays original', f.calls.filter(q => q.operation_id === original.operation_id).length === 1);
      if (hostCase === 'Ready') { section.querySelector('[data-connection-id="' + B + '"]').click();
        check(action + ' sibling remains actionable', ![...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').disabled); }
      else {
        if (hostCase === 'Busy') {
          section.querySelector('[data-connection-id="' + B + '"]').click();
          [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click();
          await tick();
          check(action + ' Busy keeps sibling intent unsent', f.calls.filter(q => q.operation === 'connection.revoke').length === 0);
        } else check(action + ' ' + hostCase + ' blocks sibling interaction', section.closest('[inert]') !== null
          && f.calls.filter(q => q.operation === 'connection.revoke').length === 0);
        if (hostCase !== 'Busy') {
          const projectButton = [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other'));
          check(action + ' ' + hostCase + ' makes all sibling surfaces inert',
            [...root.children].filter(child => child !== root.querySelector(':scope > p')
              && child !== root.querySelector(':scope > button') && child !== root.querySelector(':scope > button:nth-of-type(2)'))
              .every(child => child.inert));
          const callCount = f.calls.length;
          projectButton?.click(); for (let i = 0; i < 3; i++) await frame();
          check(action + ' ' + hostCase + ' stops project and events requests', f.calls.length === callCount);
        }
        if (hostCase === 'Busy') {
          f.host = 'Ready'; f.revision++;
          [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click();
          await tick();
          check(action + ' Busy to Ready sends the next explicit revoke once',
            f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
        }
      }
      mounted.dispose(); root.remove(); frames.length = 0;
    };
    for (const action of ['allow', 'deny', 'revoke']) for (const late of ['success', 'refused', 'uncertain']) await run(action, late);
    for (const action of ['allow', 'deny', 'revoke']) for (const late of ['success', 'refused', 'uncertain']) {
      f.calls = []; f.pending = null; f.late = null; f.host = 'Ready'; f.nextStatus = null; f.guardLease = '1'; f.revision++;
      f.rows = [row(A, action === 'revoke' ? 'granted' : 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame(); await opening;
      let section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + A + '"]').click();
      if (action === 'allow') for (const choice of section.querySelectorAll('input[type=checkbox]')) choice.click();
      const label = action === 'allow' ? '選択内容を許可' : action === 'deny' ? '要求を拒否' : '許可を失効';
      [...section.querySelectorAll('button')].find(b => b.textContent === label).click();
      for (let i = 0; i < 20 && !f.pending; i++) await tick();
      const original = f.pending, oldLate = f.late;
      check(action + ' old epoch keeps one original', !!original && !!oldLate);
      f.rows = [row(A, action === 'allow' ? 'granted' : 'closing'), row(B, 'granted')];
      await keyboardReconnect(root, action + ' old epoch');
      for (let i = 0; i < 30 && root.dataset.startupState !== 'mounted'; i++) await frame();
      section = root.querySelector('.workspace-connections');
      for (let i = 0; i < 30 && !section.textContent.includes(original.operation_id); i++) await tick();
      check(action + ' new epoch recovers old ID with a distinct read',
        f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id && q.operation_id !== original.operation_id));
      const before = section.textContent, probes = f.statusCalls, requests = f.calls.length;
      f.nextStatus = 'failed';
      if (late === 'success') oldLate.success(); else if (late === 'refused') oldLate.refused(); else oldLate.reject('transport_uncertain');
      await tick();
      check(action + ' old epoch ' + late + ' starts no status probe', f.statusCalls === probes);
      check(action + ' old epoch ' + late + ' preserves new view', root.dataset.startupState === 'mounted'
        && section.textContent === before && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      check(action + ' old epoch ' + late + ' preserves new sibling requests', f.calls.length === requests);
      check(action + ' old epoch ' + late + ' never replays original', f.calls.filter(q => q.operation_id === original.operation_id).length === 1);
      mounted.dispose(); root.remove(); frames.length = 0;
    }
    {
      f.calls = []; f.pending = null; f.late = null; f.host = 'Busy'; f.nextStatus = null; f.guardLease = '1'; f.revision++;
      f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame(); await opening;
      let section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + B + '"]').click();
      f.nextStatus = 'hold'; f.releaseStatus = null;
      [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click();
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('old epoch Busy admission probe remains held', !!f.releaseStatus);
      const releaseOld = f.releaseStatus;
      f.host = 'Ready'; f.revision++;
      await keyboardReconnect(root, 'old Busy reservation');
      for (let i = 0; i < 30 && root.dataset.startupState !== 'mounted'; i++) await frame();
      section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + B + '"]').click();
      [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click(); await tick();
      check('new epoch admission proceeds while old Busy probe is held', f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
      const requests = f.calls.length;
      releaseOld({ instance_id: I, generation: '1', revision: String(f.revision + 1), phase: 'Unknown' }); await tick();
      check('old Busy probe cannot alter new epoch or duplicate mutation', root.dataset.startupState === 'mounted'
        && root.querySelector(':scope > button:nth-of-type(2)').hidden && f.calls.length === requests);
      mounted.dispose(); root.remove(); frames.length = 0;
    }
    {
      f.calls = []; f.pending = null; f.late = null; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++;
      f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      check('real mount has a running terminal input producer', !!f.term?.sendInput);
      const section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + A + '"]').click();
      for (const choice of section.querySelectorAll('input[type=checkbox]')) choice.click();
      [...section.querySelectorAll('button')].find(b => b.textContent === '選択内容を許可').click();
      for (let i = 0; i < 20 && !f.pending; i++) await tick();
      check('running terminal still permits the first connection mutation', !!f.pending);
      f.rows = [row(A, 'granted'), row(B, 'granted')];
      [...section.querySelectorAll('button')].find(b => b.textContent === '元の操作を確認し直す').click();
      for (let i = 0; i < 20 && !section.textContent.includes('現在の許可も一致'); i++) await tick();
      f.host = 'Busy'; f.revision++; f.late.reject('transport_uncertain'); await tick();
      const probeCount = f.statusCalls;
      f.term.sendInput('x'); await tick();
      const inputPanel = root.querySelector('.workspace-input-confirmation');
      check('Busy keeps new terminal input unsent with a distinct record',
        f.calls.filter(q => q.operation === 'input.write').length === 0 && inputPanel.textContent.includes('未送信')
        && f.statusCalls > probeCount && !inputPanel.textContent.includes('配送結果は不明'));
      f.host = 'Ready'; f.revision++;
      const beforeReadProbe = f.statusCalls;
      [...section.querySelectorAll('button')].find(b => b.textContent === '接続一覧を読み直す').click(); await tick();
      check('current epoch read completion reobserves Busy to Ready', f.statusCalls > beforeReadProbe
        && root.dataset.startupState === 'mounted' && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      const discard = [...inputPanel.querySelectorAll('button')].find(button => button.textContent === 'この対象の未送信入力を破棄');
      check('Busy held input needs an explicit disposition', !!discard);
      discard.click(); await tick();
      f.host = 'Busy'; f.revision++; f.failNextList = true;
      [...section.querySelectorAll('button')].find(b => b.textContent === '接続一覧を読み直す').click(); await tick();
      check('current epoch Busy remains available for an explicit input attempt', !f.failNextList
        && root.dataset.startupState === 'mounted');
      f.host = 'Ready'; f.revision++;
      f.term.sendInput('y'); await tick();
      check('Busy to Ready sends a fresh explicit terminal input once',
        f.calls.filter(q => q.operation === 'input.write').length === 1
        && f.calls.find(q => q.operation === 'input.write').params.text === 'y');
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    for (const arrival of ['Ready', 'Unknown', 'failed']) {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Busy'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      check('Busy A mount exposes a real terminal producer', !!f.term?.sendInput);
      const oldTerm = f.term;
      f.nextStatus = 'hold'; f.releaseStatus = null;
      oldTerm.sendInput('a');
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('A predispatch input status probe is held without a write', !!f.releaseStatus
        && f.calls.filter(q => q.operation === 'input.write').length === 0);
      const releaseOld = f.releaseStatus, rejectOld = f.rejectStatus;
      f.host = 'Ready'; f.revision++;
      await keyboardReconnect(root, 'A input preflight');
      for (let i = 0; i < 35 && (root.dataset.startupState !== 'mounted' || f.term === oldTerm); i++) await frame();
      const inputPanel = root.querySelector('.workspace-input-confirmation');
      check('B keeps A predispatch input as unsent held', root.dataset.startupState === 'mounted'
        && f.term !== oldTerm && inputPanel.textContent.includes('未送信')
        && !inputPanel.textContent.includes('配送結果は不明'));
      const discard = [...inputPanel.querySelectorAll('button')].find(button => button.textContent === 'この対象の未送信入力を破棄');
      check('B can explicitly discard A unsent record', !!discard);
      discard.click(); await tick();
      f.holdNextInput = true; f.lateInput = null;
      f.term.sendInput('b'); await tick();
      check('B new input is delivered once while A probe is still held',
        f.calls.filter(q => q.operation === 'input.write').length === 1
        && f.calls.find(q => q.operation === 'input.write').params.text === 'b' && !!f.lateInput);
      const releaseB = f.lateInput;
      const beforeLate = f.calls.length;
      if (arrival === 'failed') rejectOld(Error('old_status_failed'));
      else releaseOld({ instance_id: I, generation: '1', revision: String(f.revision + 1), phase: arrival });
      await tick();
      check('A predispatch late ' + arrival + ' cannot settle B input flight', f.calls.length === beforeLate
        && inputPanel.textContent.includes('配送の確認中') && root.dataset.startupState === 'mounted'
        && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      releaseB.success(); await tick();
      const section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + B + '"]').click();
      [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click(); await tick();
      check('B control is admitted after its own input settles', f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    {
      f.calls = []; f.withRun = true; f.runId = R; f.term = null; f.host = 'Busy'; f.nextStatus = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      check('retired run starts with a real input producer', !!f.term?.sendInput);
      const oldSend = f.term.sendInput;
      f.nextStatus = 'hold'; f.releaseStatus = null;
      oldSend('old run');
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('retired run old Busy preflight remains undispatched', !!f.releaseStatus
        && f.calls.filter(q => q.operation === 'input.write').length === 0);
      const releaseOld = f.releaseStatus;
      f.runId = R2; f.host = 'Ready'; f.revision++;
      root.querySelector('[data-action="reread"]').click();
      for (let i = 0; i < 30 && f.term.sendInput === oldSend; i++) await frame();
      const inputPanel = root.querySelector('.workspace-input-confirmation');
      check('run retirement holds A preflight and installs B producer', f.term.sendInput !== oldSend
        && inputPanel.textContent.includes('未送信') && !inputPanel.textContent.includes('配送結果は不明'));
      f.term.sendInput('blocked by old held input'); await tick();
      check('retired run held record fences new run before explicit discard', f.calls.filter(q => q.operation === 'input.write').length === 0
        && inputPanel.textContent.includes('未送信'));
      const discards = [...inputPanel.querySelectorAll('button')].filter(button => button.textContent === 'この対象の未送信入力を破棄');
      check('old and blocked new run records each require explicit discard', discards.length === 2);
      discards[0].click(); await tick();
      check('old run discard does not silently deliver held new run input', f.calls.filter(q => q.operation === 'input.write').length === 0);
      discards[1].click(); await tick();
      f.term.sendInput('new run'); await tick();
      check('new run input dispatches once while retired probe is held', f.calls.filter(q => q.operation === 'input.write').length === 1
        && f.calls.find(q => q.operation === 'input.write').params.run_id === R2);
      const count = f.calls.length;
      releaseOld({ instance_id: I, generation: '1', revision: String(f.revision + 1), phase: 'Unknown' }); await tick();
      check('retired run late Busy probe cannot dispatch or block current run', f.calls.length === count
        && root.dataset.startupState === 'mounted' && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.runId = R; f.term = null;
    }
    for (const arrival of ['success', 'refused', 'exception']) {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null; f.lateInput = null;
      f.holdNextInput = true; f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      const oldTerm = f.term;
      oldTerm.sendInput('d');
      for (let i = 0; i < 20 && !f.lateInput; i++) await tick();
      const oldInput = f.calls.find(q => q.operation === 'input.write');
      check('A input reaches the sole dispatch boundary before reply loss', !!f.lateInput && !!oldInput);
      const releaseOld = f.lateInput;
      await keyboardReconnect(root, 'A dispatched input');
      for (let i = 0; i < 35 && (root.dataset.startupState !== 'mounted' || f.term === oldTerm); i++) await frame();
      const inputPanel = root.querySelector('.workspace-input-confirmation');
      check('B preserves dispatched A original as unknown with no replay', root.dataset.startupState === 'mounted'
        && f.term !== oldTerm && inputPanel.textContent.includes('配送結果は不明')
        && inputPanel.textContent.includes(oldInput.operation_id)
        && f.calls.filter(q => q.operation === 'input.write').length === 1);
      const confirm = [...inputPanel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認');
      check('B exposes distinct-ID confirmation for A dispatched record', !!confirm);
      confirm.click(); await tick();
      check('B confirms A result by separate operation.get', f.calls.some(q => q.operation === 'operation.get'
        && q.params.operation_id === oldInput.operation_id && q.operation_id !== oldInput.operation_id));
      f.holdNextInput = true; f.lateInput = null;
      f.term.sendInput('e'); await tick();
      check('B new input enters its own flight after explicit confirmation', f.calls.filter(q => q.operation === 'input.write').length === 2
        && f.calls.filter(q => q.operation === 'input.write')[1].params.text === 'e' && !!f.lateInput);
      const releaseB = f.lateInput, beforeLate = inputPanel.textContent;
      if (arrival === 'success') releaseOld.success(); else if (arrival === 'refused') releaseOld.refused();
      else releaseOld.reject('transport_uncertain');
      await tick();
      check('A dispatched late ' + arrival + ' cannot settle B flight', inputPanel.textContent === beforeLate
        && f.calls.filter(q => q.operation === 'input.write').length === 2);
      releaseB.success(); await tick();
      const section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + B + '"]').click();
      [...section.querySelectorAll('button')].find(b => b.textContent === '許可を失効').click(); await tick();
      check('B control resumes after real unknown input was confirmed', f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    for (const arrival of ['success', 'refused', 'exception']) {
      f.calls = []; f.withRun = true; f.term = null; f.host = 'Ready'; f.nextStatus = null;
      f.holdNextInput = true; f.lateInput = null; f.holdNextOperationGet = false; f.lateOperationGet = null;
      f.guardLease = '1'; f.revision++; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      f.term.sendInput('original'); for (let i = 0; i < 20 && !f.lateInput; i++) await tick();
      const original = f.calls.find(q => q.operation === 'input.write');
      f.lateInput.refused(); await tick();
      const panel = root.querySelector('.workspace-input-confirmation');
      check('A failed original retains its ID for explicit confirmation', panel.textContent.includes(original.operation_id));
      f.holdNextOperationGet = true;
      [...panel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認').click();
      for (let i = 0; i < 20 && !f.lateOperationGet; i++) await tick();
      check('A original ID confirmation is held on a distinct read', !!f.lateOperationGet
        && f.calls.find(q => q.operation === 'operation.get').params.operation_id === original.operation_id);
      const oldRead = f.lateOperationGet;
      await keyboardReconnect(root, 'A original ID confirmation pending');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      const before = panel.textContent, beforeCalls = f.calls.length;
      if (arrival === 'success') oldRead.success(); else if (arrival === 'refused') oldRead.refused();
      else oldRead.reject('transport_uncertain');
      await tick();
      check('A late original ID ' + arrival + ' cannot settle B record or notice', root.dataset.startupState === 'mounted'
        && panel.textContent === before && f.calls.length === beforeCalls && panel.textContent.includes(original.operation_id));
      [...panel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認').click(); await tick();
      check('B explicit original ID reread uses a new request and no input replay',
        f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id).length === 2
        && f.calls.filter(q => q.operation === 'input.write').length === 1
        && !panel.textContent.includes(original.operation_id));
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
    }
    for (const hostCase of ['Unknown', 'Busy', 'probe_failed', 'wrong_generation', 'invalid_shape']) await run('allow', 'uncertain', hostCase);
    const initialStatus = async (phase, lease) => {
      f.calls = []; f.rows = [row(A, 'pending'), row(B, 'granted')]; f.host = phase; f.guardLease = lease; f.revision++;
      const root = document.createElement('main'); document.body.append(root);
      let mounted;
      const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame();
      await opening;
      check(phase + ' without lease has correct force gate', root.querySelector(':scope > button:nth-of-type(2)').hidden === (phase !== 'Unknown'));
      if (phase === 'Ready') {
        const section = root.querySelector('.workspace-connections');
        section.querySelector('[data-connection-id="' + A + '"]').click();
        for (const choice of section.querySelectorAll('input[type=checkbox]')) choice.click();
        [...section.querySelectorAll('button')].find(b => b.textContent === '選択内容を許可').click();
        await tick();
        check('Ready without input lease refuses mutation', f.calls.filter(q => q.operation === 'connection.decide').length === 0);
      } else check('Unknown without input lease remains authoritative', root.dataset.startupState === 'unknown');
      mounted.dispose(); root.remove(); frames.length = 0;
    };
    await initialStatus('Ready', null);
    await initialStatus('Unknown', null);
    f.failOpen = true; f.host = 'Unknown'; f.guardLease = null; f.revision++;
    {
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame(); await opening;
      check('failed initial open probes Rust Unknown without input lease', root.dataset.startupState === 'unknown'
        && !root.querySelector(':scope > button:nth-of-type(2)').hidden);
      mounted.dispose(); root.remove(); frames.length = 0;
    }
    f.failOpen = false;
    f.guardLease = '1'; f.host = 'Ready'; f.revision++;
    {
      f.calls = []; f.pending = null; f.rows = [row(A, 'pending'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted;
      const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 30 && !mounted; i++) await frame(); await opening;
      let section = root.querySelector('.workspace-connections');
      section.querySelector('[data-connection-id="' + A + '"]').click();
      for (const choice of section.querySelectorAll('input[type=checkbox]')) choice.click();
      [...section.querySelectorAll('button')].find(b => b.textContent === '選択内容を許可').click();
      for (let i = 0; i < 20 && !f.pending; i++) await tick();
      const original = f.pending;
      f.rows = [row(A, 'granted'), row(B, 'granted')];
      [...section.querySelectorAll('button')].find(b => b.textContent === '元の操作を確認し直す').click();
      for (let i = 0; i < 20 && !section.textContent.includes('現在の許可も一致'); i++) await tick();
      check('inverse probe fixture first recovers original', section.textContent.includes('現在の許可も一致'));
      f.nextStatus = 'hold'; f.releaseStatus = null;
      f.late.reject('transport_uncertain');
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('older status probe remains held', !!f.releaseStatus);
      const releaseOlder = f.releaseStatus;
      f.failNextList = true; f.revision++;
      [...section.querySelectorAll('button')].find(b => b.textContent === '接続一覧を読み直す').click();
      for (let i = 0; i < 20 && f.failNextList; i++) await tick();
      check('newer probe completed after second request failure', !f.failNextList && root.querySelector(':scope > button:nth-of-type(2)').hidden);
      releaseOlder({ instance_id: I, generation: '1', revision: String(f.revision - 1), phase: 'Unknown' }); await tick();
      check('older Unknown arrival cannot replace newer Ready', root.querySelector(':scope > button:nth-of-type(2)').hidden && root.dataset.startupState === 'mounted');
      check('inverse probe never replays original', f.calls.filter(q => q.operation_id === original.operation_id).length === 1);
      f.nextStatus = 'hold'; f.releaseStatus = null; f.failNextList = true;
      [...section.querySelectorAll('button')].find(b => b.textContent === '接続一覧を読み直す').click();
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('old epoch status probe remains held', !!f.releaseStatus);
      const releaseOldEpoch = f.releaseStatus;
      await keyboardReconnect(root, 'old epoch status probe');
      for (let i = 0; i < 30 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check('same host rebinds on new epoch', root.dataset.startupState === 'mounted');
      releaseOldEpoch({ instance_id: I, generation: '1', revision: String(f.revision + 1), phase: 'Unknown' }); await tick();
      section = root.querySelector('.workspace-connections');
      check('old epoch Unknown cannot change new mount', root.querySelector(':scope > button:nth-of-type(2)').hidden && !!section);
      mounted.dispose(); root.remove(); frames.length = 0;
    }
    {
      f.calls = []; f.pending = null; f.late = null; f.host = 'Ready'; f.nextStatus = null;
      f.ownerGeneration = '1'; f.revision++; f.rows = [row(A, 'granted'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && !mounted; i++) await frame(); await opening;
      const section = root.querySelector('.workspace-connections');
      section.querySelector(`[data-connection-id="${A}"]`).click();
      [...section.querySelectorAll('button')].find(button => button.textContent === '許可を失効').click();
      for (let i = 0; i < 12 && !f.pending; i++) await tick();
      check('A owner 1 revoke is pending', !!f.pending);
      const original = f.pending;
      f.ownerGeneration = '2'; f.revision++;
      f.nextStatus = 'hold'; f.releaseStatus = null;
      await keyboardReconnect(root, 'different Rust owner');
      for (let i = 0; i < 20 && !f.releaseStatus; i++) await tick();
      check('initial B status is observational until owner comparison', !!f.releaseStatus
        && f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id).length === 0
        && f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
      f.releaseStatus({ instance_id: I, generation: '2', revision: String(f.revision), phase: 'Ready' });
      for (let i = 0; i < 35 && root.dataset.startupState === 'connecting'; i++) await frame();
      check('different Rust owner cannot query old ID', f.calls.filter(q => q.operation === 'operation.get'
        && q.params.operation_id === original.operation_id).length === 0);
      check('different owner remains in visible recovery shell with original admission held',
        root.dataset.startupState === 'recovering' && !root.querySelector(':scope > button').hidden
        && f.calls.filter(q => q.operation === 'connection.revoke').length === 1);
      const opened = f.openCalls, statusQueries = f.statusCalls;
      await keyboardReconnect(root, 'different owner status-only retry');
      await tick();
      check('different owner retry probes status without reopening host or querying old ID',
        f.openCalls === opened && f.statusCalls === statusQueries + 1
        && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id));
      mounted.dispose(); root.remove(); frames.length = 0; f.ownerGeneration = '1';
    }
    for (const path of ['same-instance', 'after-instance-switch'])
      for (const operation of ['project.select', 'artifact.register', 'layout.restore', 'input.write'])
      for (const arrival of path === 'same-instance' ? ['success', 'refused', 'exception'] : ['success']) {
        f.calls = []; f.pending = null; f.late = null; f.lateProject = null; f.lateDetails = null; f.lateInput = null;
        f.host = 'Ready'; f.nextStatus = null; f.instanceId = I; f.ownerGeneration = '1'; f.revision++;
        f.withRun = operation !== 'project.select'; f.runId = R; f.term = null;
        f.rows = [row(A, 'pending'), row(B, 'granted')];
        f.holdNextProject = operation === 'project.select';
        f.holdNextDetailsOperation = ['artifact.register', 'layout.restore'].includes(operation) ? operation : null;
        f.holdNextInput = operation === 'input.write';
        const root = document.createElement('main'); document.body.append(root);
        let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
        for (let i = 0; i < 35 && (!mounted || operation === 'input.write' && !f.term?.sendInput); i++) await frame(); await opening;
        if (path === 'after-instance-switch') {
          const J = '99999999-9999-4999-8999-999999999999';
          f.instanceId = J; f.ownerGeneration = '2'; f.revision++;
          await keyboardReconnect(root, `${operation} I1/g1 to I2/g2`);
          for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
          check(`${operation} I2/g2 mounts before original`, root.dataset.startupState === 'mounted');
        }
        let details = null;
        if (operation === 'project.select') {
          const other = [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other'));
          check(`different owner ${operation}/${arrival} project choice visible`, !!other && !other.disabled);
          other.click();
        } else if (operation === 'input.write') f.term.sendInput('owner-one');
        else {
          [...root.querySelectorAll(':scope > button')].find(button => button.textContent === '成果物・配置・診断').click();
          details = root.querySelector('.workspace-details');
          if (operation === 'artifact.register') {
            details.querySelector('[data-action="list"]').click(); await tick();
            details.querySelector('[data-action="register-git"]').click();
          } else {
            details.querySelector('[data-action="layout"]').click();
            details.querySelector('[data-action="restore"]').click();
          }
        }
        for (let i = 0; i < 12 && !f.calls.some(q => q.operation === operation); i++) await tick();
        const original = f.calls.find(q => q.operation === operation);
        const late = operation === 'project.select' ? f.lateProject : operation === 'input.write' ? f.lateInput : f.lateDetails;
        check(`different owner ${operation}/${arrival} original dispatched and held`, !!original && !!late);
        f.ownerGeneration = path === 'same-instance' ? '2' : '3'; f.revision++;
        await keyboardReconnect(root, `different owner ${operation}/${arrival}`);
        for (let i = 0; i < 35 && root.dataset.startupState === 'connecting'; i++) await frame();
        check(`different owner ${operation}/${arrival} keeps recovery shell`, root.dataset.startupState === 'recovering');
        const panel = root.querySelector('.workspace-input-confirmation');
        if (operation === 'input.write') {
          check(`different owner ${operation}/${arrival} retains original ID`, panel?.textContent.includes(original.operation_id));
          const confirm = [...panel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認');
          confirm?.click(); await tick();
        }
        const priorQ = f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id).length;
        check(`different owner ${operation}/${arrival} has no original Q`, priorQ === 0);
        const detailState = details?.textContent;
        if (arrival === 'success') late.success(); else if (arrival === 'refused') late.refused(); else late.reject('transport_uncertain');
        await tick();
        check(`different owner ${operation}/${arrival} late answer keeps original untransferred`,
          f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id).length === 0
          && f.calls.filter(q => q.operation === operation).length === 1
          && (operation !== 'input.write' || panel?.textContent.includes(original.operation_id))
          && (details === null || details.textContent === detailState));
        mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null;
      }
    {
      const J = '99999999-9999-4999-8999-999999999999';
      f.calls = []; f.pending = null; f.late = null; f.host = 'Ready'; f.nextStatus = null;
      f.instanceId = I; f.ownerGeneration = '1'; f.revision++; f.rows = [row(A, 'granted'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && !mounted; i++) await frame(); await opening;
      f.instanceId = J; f.ownerGeneration = '2'; f.revision++;
      await keyboardReconnect(root, 'connection I1/g1 to I2/g2');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      const section = root.querySelector('.workspace-connections');
      check('I2/g2 connection controls mount after valid instance switch', root.dataset.startupState === 'mounted' && !!section);
      section.querySelector(`[data-connection-id="${A}"]`).click();
      [...section.querySelectorAll('button')].find(button => button.textContent === '許可を失効').click();
      for (let i = 0; i < 12 && !f.pending; i++) await tick();
      const original = f.pending, late = f.late;
      check('I2/g2 connection original is pending', !!original && !!late && original.instance_id === J);
      f.ownerGeneration = '3'; f.revision++;
      await keyboardReconnect(root, 'connection I2/g2 to I2/g3');
      for (let i = 0; i < 35 && root.dataset.startupState === 'connecting'; i++) await frame();
      check('I2/g3 connection old ID stays unqueried and unresent', root.dataset.startupState === 'recovering'
        && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id)
        && f.calls.filter(q => q.operation_id === original.operation_id).length === 1);
      late.success(); await tick();
      check('I2/g3 connection late old success cannot exit recovery shell', root.dataset.startupState === 'recovering'
        && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id));
      mounted.dispose(); root.remove(); frames.length = 0; f.instanceId = I; f.ownerGeneration = '1';
    }
    {
      const J = '99999999-9999-4999-8999-999999999999';
      f.calls = []; f.instanceId = I; f.ownerGeneration = '1'; f.revision++; f.host = 'Ready'; f.nextStatus = null;
      f.withRun = true; f.runId = R; f.term = null; f.rows = [row(A, 'pending'), row(B, 'granted')];
      f.holdNextInput = true; f.lateInput = null;
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      f.term.sendInput('I1 original'); for (let i = 0; i < 12 && !f.lateInput; i++) await tick();
      const original = f.calls.find(q => q.operation === 'input.write');
      check('I1/g1 input original is dispatched', !!original && !!f.lateInput);
      const lateI1 = f.lateInput;
      f.instanceId = J; f.ownerGeneration = '2'; f.revision++;
      await keyboardReconnect(root, 'I1/g1 to I2/g2');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check('valid different instance I2/g2 mounts while I1 input stays recorded', root.dataset.startupState === 'mounted'
        && root.querySelector('.workspace-input-confirmation')?.textContent.includes(original.operation_id));
      f.term.sendInput('I2 new'); await tick();
      check('I2/g2 new input dispatches once with own instance despite I1 history', f.calls.filter(q => q.operation === 'input.write'
        && q.instance_id === J && q.params.text === 'I2 new').length === 1);
      f.instanceId = I; f.ownerGeneration = '3'; f.revision++;
      await keyboardReconnect(root, 'I2/g2 to I1/g3');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      const panel = root.querySelector('.workspace-input-confirmation');
      check('I1/g3 is a new valid interval and keeps I1/g1 record', root.dataset.startupState === 'mounted'
        && panel?.textContent.includes(original.operation_id));
      [...panel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認')?.click();
      await tick(); lateI1.success(); await tick();
      check('I1/g3 cannot read, replay or erase I1/g1 original', !f.calls.some(q => q.operation === 'operation.get'
        && q.params.operation_id === original.operation_id) && f.calls.filter(q => q.operation_id === original.operation_id).length === 1
        && panel.textContent.includes(original.operation_id));
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null; f.instanceId = I; f.ownerGeneration = '1';
    }
    {
      const J = '99999999-9999-4999-8999-999999999999';
      f.calls = []; f.instanceId = I; f.ownerGeneration = '1'; f.revision++; f.host = 'Ready'; f.nextStatus = null;
      f.withRun = true; f.runId = R; f.term = null; f.rows = [row(A, 'granted'), row(B, 'granted')];
      const root = document.createElement('main'); document.body.append(root);
      let mounted; const opening = module.mountWorkspaceMain(root).then(value => { mounted = value; });
      for (let i = 0; i < 35 && (!mounted || !f.term?.sendInput); i++) await frame(); await opening;
      f.instanceId = J; f.ownerGeneration = '2'; f.revision++;
      await keyboardReconnect(root, 'I1/g1 to I2/g2 before original');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      check('I2/g2 is accepted after different instance', root.dataset.startupState === 'mounted');
      f.holdNextInput = true; f.lateInput = null; f.term.sendInput('I2 original');
      for (let i = 0; i < 12 && !f.lateInput; i++) await tick();
      const original = f.calls.find(q => q.operation === 'input.write' && q.instance_id === J);
      check('I2/g2 input original is pending', !!original && !!f.lateInput);
      const lateI2 = f.lateInput;
      await keyboardReconnect(root, 'I2/g2 same owner recovery');
      for (let i = 0; i < 35 && root.dataset.startupState !== 'mounted'; i++) await frame();
      const sameOwnerPanel = root.querySelector('.workspace-input-confirmation');
      [...sameOwnerPanel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認')?.click();
      for (let i = 0; i < 12 && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id); i++) await tick();
      check('I2/g2 same-owner recovery reads old ID once with a distinct ID', root.dataset.startupState === 'mounted'
        && f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === original.operation_id
          && q.operation_id !== original.operation_id).length === 1);
      lateI2.success(); await tick();
      f.term.sendInput('I2 after recovery'); await tick();
      check('I2/g2 accepts one new input after confirmed original', f.calls.filter(q => q.operation === 'input.write'
        && q.instance_id === J && q.params.text === 'I2 after recovery').length === 1);
      f.holdNextInput = true; f.lateInput = null; f.term.sendInput('I2 second original');
      for (let i = 0; i < 12 && !f.lateInput; i++) await tick();
      const secondOriginal = f.calls.find(q => q.operation === 'input.write' && q.instance_id === J && q.params.text === 'I2 second original');
      check('I2/g2 second original is pending before owner change', !!secondOriginal && !!f.lateInput);
      const lateSecond = f.lateInput;
      f.ownerGeneration = '3'; f.revision++;
      await keyboardReconnect(root, 'I2/g2 to I2/g3');
      for (let i = 0; i < 35 && root.dataset.startupState === 'connecting'; i++) await frame();
      const panel = root.querySelector('.workspace-input-confirmation');
      check('I2/g3 same-instance new-owner remains in recovery shell with original input',
        root.dataset.startupState === 'recovering' && panel?.textContent.includes(secondOriginal.operation_id));
      [...panel.querySelectorAll('button')].find(button => button.textContent === '元の操作の結果を確認')?.click();
      await tick(); lateSecond.success(); await tick();
      check('I2/g3 cannot query, replay or erase I2/g2 original', !f.calls.some(q => q.operation === 'operation.get'
        && q.params.operation_id === secondOriginal.operation_id) && f.calls.filter(q => q.operation_id === secondOriginal.operation_id).length === 1
        && panel.textContent.includes(secondOriginal.operation_id));
      mounted.dispose(); root.remove(); frames.length = 0; f.withRun = false; f.term = null; f.instanceId = I; f.ownerGeneration = '1';
    }
    return checks;
  }, bundled.outputFiles[0].text);
  console.log(`workspace connection integration: ${checks.length} checks passed`);
} finally { await browser.close(); }
