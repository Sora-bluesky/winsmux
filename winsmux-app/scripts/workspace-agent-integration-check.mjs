import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const { build } = require('esbuild');
const { chromium } = require('playwright');
const shims = {
  '@tauri-apps/api/core': 'export const invoke=(name,args)=>globalThis.fixture.invoke(name,args);',
  '@tauri-apps/api/webviewWindow': 'export const getCurrentWebviewWindow=()=>({label:"main"}); export class WebviewWindow { constructor(){throw Error("no secondary view in fixture")} }',
  '@tauri-apps/api/event': 'export const listen=async()=>()=>{};',
  '@tauri-apps/plugin-dialog': 'export const open=async()=>null;',
  xterm: 'export class Terminal { constructor(options){this.options=options;this.cols=80;this.rows=24;this.parser={registerCsiHandler:()=>({dispose(){}})}} loadAddon(){} open(slot){this.textarea=document.createElement("textarea");slot.append(this.textarea)} write(){} reset(){} onResize(){return{dispose(){}}} onData(){return{dispose(){}}} onKey(){return{dispose(){}}} attachCustomKeyEventHandler(){} hasSelection(){return false} dispose(){} }',
  '@xterm/addon-fit': 'export class FitAddon {fit(){}}',
};
const bundled = await build({ entryPoints: [resolve(app, 'src/workspace-ui/startup-mount.ts')], bundle: true, write: false,
  format: 'esm', platform: 'browser', target: 'es2020', plugins: [{ name: 'closed-native-effects', setup(b) {
    b.onResolve({ filter: /.*/ }, args => args.path in shims ? { path: args.path, namespace: 'effect' } : args.path.endsWith('.css') ? { path: args.path, namespace: 'css' } : undefined);
    b.onLoad({ filter: /.*/, namespace: 'effect' }, args => ({ contents: shims[args.path], loader: 'js' }));
    b.onLoad({ filter: /.*/, namespace: 'css' }, () => ({ contents: '', loader: 'js' }));
  } }] });
const source = bundled.outputFiles[0].text;
const browser = await chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
try {
  const page = await browser.newPage();
  await page.route('**/*', route => route.request().url() === 'https://tauri.localhost/'
    ? route.fulfill({ contentType: 'text/html', body: '<!doctype html><html lang="ja"><meta charset="utf-8"><body><main></main></body></html>' }) : route.abort());
  await page.goto('https://tauri.localhost/');
  const result = await page.evaluate(async code => {
    const I = '11111111-1111-4111-8111-111111111111', P = '22222222-2222-4222-8222-222222222222', N = '33333333-3333-4333-8333-333333333333', Q = '55555555-5555-4555-8555-555555555555', R = '66666666-6666-4666-8666-666666666666';
    const f = globalThis.fixture = { calls: [], frames: [], mutation: null, phase: 'accepted', sessions: 0, selected: P, instanceId: I, ownerGeneration: '1' };
    const check = (name, okay) => { if (!okay) throw Error(name); checks.push(name); };
    const checks = [];
    const envelope = (q, data, seq = 0) => ({ schema_version: 1, instance_id: q.instance_id, operation_id: q.operation_id, accepted: true, topology_revision: 1, event_seq: seq, result: { operation: q.operation, data }, error: null });
    const project = { project_id: P, path: 'C:/fixture/project', display_name: 'Fixture', root_state: 'verified' };
    const other = { project_id: Q, path: 'C:/fixture/other', display_name: 'Other', root_state: 'verified' };
    const pane = { pane_id: N, project_id: P, display_name: 'Terminal', path: project.path, current_run_id: null, observation: null };
    f.invoke = async (name, args) => {
      if (name === 'startup_main_policy_ready' || name === 'startup_main_show') return null;
      if (name === 'workspace_session_open') { f.sessions++; return { instance_id: f.instanceId, schema_version: 1 }; }
      if (name === 'workspace_host_status') return { instance_id: f.instanceId, generation: f.ownerGeneration, revision: f.ownerGeneration, phase: 'Ready', force_offer: 'none' };
      if (name === 'desktop_initial_project_dir') return null;
      if (name === 'workspace_input_guard_register' || name === 'workspace_input_guard_status') return { lease: '1', revision: '1', fence: null, resume_allowed: false, admission_error: null };
      if (name !== 'workspace_request') throw Error(`Unexpected native effect ${name}`);
      const q = JSON.parse(args.requestJson); f.calls.push(q);
      switch (q.operation) {
        case 'capabilities.get': return envelope(q, { schema_version: 1, operations: ['capabilities.get', 'project.list', 'pane.list', 'agent.launch', 'run.interrupt', 'operation.get', 'run.get', 'events.wait', 'output.read'], providers: [{ provider: 'codex', version: '0.1' }, { provider: 'claude', version: '0.2' }], shell_profile_ids: ['pwsh'], max_message_bytes: 1048576, replay_capacity: { retained_bytes: 134217728, active_bytes: 268435456 } });
        case 'project.list': return envelope(q, { projects: [project, other], selected_project_id: f.selected });
        case 'pane.list': return q.params.project_id === P ? envelope(q, { project_id: P, selected_pane_id: N, panes: [pane], root: { kind: 'leaf', pane_id: N } }) : envelope(q, { project_id: Q, selected_pane_id: null, panes: [], root: null });
        case 'events.wait': {
          const mode = f.eventMode; f.eventMode = null;
          if (mode === 'resource_exhausted') return { ...envelope(q, null), accepted: false, result: null,
            error: { code: 'resource_exhausted', message: 'Resource limit reached.', retryable: false, target_id: null } };
          return envelope(q, { events: [], next_event_seq: 0, status: mode === 'gap' ? 'gap' : 'no_change' });
        }
        case 'output.read': return envelope(q, { run_id: q.params.run_id, text: '', next_cursor: 'cursor-0', gap: false, truncated: false });
        case 'agent.launch': {
          f.mutation = q;
          if (f.failAgentReply) { f.failAgentReply = false; throw new Error('reply_lost'); }
          return new Promise(resolve => { f.release = () => resolve(envelope(q, { phase: 'accepted', pane_id: N, run_id: '44444444-4444-4444-8444-444444444444' })); });
        }
        case 'project.select':
          if (f.holdProject) return new Promise(resolve => { f.projectMutation = q; f.releaseProject = () => resolve(envelope(q, { selected_project_id: q.params.project_id, selected_pane_id: null })); });
          f.selected = q.params.project_id; return envelope(q, { selected_project_id: f.selected, selected_pane_id: null });
        case 'run.interrupt': return new Promise(resolve => { f.interruptMutation = q; f.releaseInterrupt = () => resolve(envelope(q, { phase: 'accepted', run_id: R })); });
        case 'run.get': return envelope(q, { run: { run_id: R, pane_id: N, current: true, process: f.runExited ? 'exited' : 'running', work: f.runExited ? 'interrupted' : 'running', evidence: f.runExited ? 'process_exit' : 'provider_event', exit_code: null, observed_at: '2026-09-28T00:00:00Z' } }, f.runExited ? 1 : 0);
        case 'operation.get': {
          if (f.holdNextQ) { f.holdNextQ = false; return new Promise(resolve => { f.releaseOldQ = () => resolve(envelope(q, { operation: {
            operation_id: q.params.operation_id, phase: 'completed', outcome: 'failed', error_code: 'runtime_failed' } })); }); }
          return envelope(q, { operation: { operation_id: q.params.operation_id, phase: f.phase, outcome: f.phase === 'completed' ? 'succeeded' : null, error_code: null } });
        }
        default: throw Error(`Unexpected workspace request ${q.operation}`);
      }
    };
    globalThis.requestAnimationFrame = callback => { f.frames.push(callback); return f.frames.length; };
    globalThis.cancelAnimationFrame = () => {};
    const tick = async () => { for (let i = 0; i < 8; i++) await new Promise(done => setTimeout(done, 0)); };
    const frame = async () => { const callback = f.frames.shift(); if (callback) callback(0); await tick(); };
    const module = await import(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    const root = document.querySelector('main');
    const recoverClick = () => {
      const button = root.querySelector(':scope > button');
      check('visible enabled recovery control is user reachable', !!button && !button.hidden && !button.disabled && button.getClientRects().length > 0);
      button.click();
    };
    let ready = false; let mounted;
    const promise = module.mountWorkspaceMain(root).then(value => { mounted = value; ready = true; });
    for (let i = 0; i < 25 && !ready; i++) { await frame(); }
    await promise;
    const agent = root.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    check('production mount exposes agent controls', !!agent?.querySelector('[data-action="launch"]'));
    const select = agent.querySelector('select'); select.value = 'codex'; select.dispatchEvent(new Event('change'));
    for (let i = 0; i < 10 && agent.querySelector('[data-action="launch"]').disabled; i++) await frame();
    check('correlated capabilities make explicit Codex choice available', !agent.querySelector('[data-action="launch"]').disabled);
    agent.querySelector('[data-action="launch"]').click(); agent.querySelector('[data-action="confirm-launch"]').click();
    for (let i = 0; i < 10 && !f.mutation; i++) await tick();
    check('one exact production agent launch dispatched', f.calls.filter(q => q.operation === 'agent.launch').length === 1 && f.mutation.params.provider === 'codex' && f.mutation.params.pane_id === N);
    recoverClick();
    for (let i = 0; i < 20 && f.sessions < 2; i++) await frame();
    for (let i = 0; i < 20 && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === f.mutation.operation_id); i++) await frame();
    check('same-host original-ID read passes held mutation reply', f.sessions === 2 && f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === f.mutation.operation_id));
    check('held original cannot be resent', f.calls.filter(q => q.operation === 'agent.launch').length === 1);
    const currentAgent = root.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    const newSelect = currentAgent.querySelector('select'); newSelect.value = 'codex'; newSelect.dispatchEvent(new Event('change'));
    check('new projection remains busy until original terminal', currentAgent.querySelector('[data-action="launch"]').disabled);
    f.phase = 'completed';
    for (let i = 0; i < 15; i++) await frame();
    const newAgent = root.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    check('original semantic terminal releases admission without resend',
      f.calls.filter(q => q.operation === 'agent.launch').length === 1 && !newAgent.querySelector('[data-action="launch"]').disabled);
    f.phase = 'accepted'; f.failAgentReply = true;
    newAgent.querySelector('[data-action="launch"]').click(); newAgent.querySelector('[data-action="confirm-launch"]').click();
    for (let i = 0; i < 10 && f.calls.filter(q => q.operation === 'agent.launch').length < 2; i++) await tick();
    const lost = f.mutation;
    check('lost agent reply preserves exactly one original request', f.calls.filter(q => q.operation === 'agent.launch').length === 2);
    f.holdNextQ = true;
    recoverClick();
    for (let i = 0; i < 20 && !f.releaseOldQ; i++) await frame();
    check('first original Q can remain held on old connection', !!f.releaseOldQ && f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === lost.operation_id).length === 1);
    f.phase = 'completed';
    recoverClick();
    for (let i = 0; i < 25 && f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === lost.operation_id).length < 2; i++) await frame();
    check('new same-host connection reads original without waiting for old Q', f.calls.filter(q => q.operation === 'operation.get' && q.params.operation_id === lost.operation_id).length >= 2);
    for (let i = 0; i < 15; i++) await frame();
    const recoveredAgent = root.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    const recoveredSelect = recoveredAgent.querySelector('select'); recoveredSelect.value = 'codex'; recoveredSelect.dispatchEvent(new Event('change'));
    check('original terminal alone releases lost agent request', !recoveredAgent.querySelector('[data-action="launch"]').disabled);
    f.releaseOldQ(); await tick();
    check('late old Q cannot reissue or relock agent mutation', f.calls.filter(q => q.operation === 'agent.launch').length === 2
      && !recoveredAgent.querySelector('[data-action="launch"]').disabled);
    const readsBefore = f.calls.filter(q => q.operation === 'capabilities.get').length;
    f.eventMode = 'resource_exhausted'; await frame(); await frame();
    check('events capacity refusal skips only optional read', root.dataset.startupState === 'mounted' && f.calls.filter(q => q.operation === 'capabilities.get').length > readsBefore);
    f.eventMode = 'gap'; await frame(); await frame();
    check('events gap preserves visible state polling', root.dataset.startupState === 'mounted');
    f.phase = 'accepted'; f.holdProject = true;
    [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other')).click();
    for (let i = 0; i < 10 && !f.projectMutation; i++) await tick();
    check('one project mutation dispatched', !!f.projectMutation && f.calls.filter(q => q.operation === 'project.select').length === 1);
    recoverClick();
    for (let i = 0; i < 20 && f.sessions < 4; i++) await frame();
    for (let i = 0; i < 20 && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === f.projectMutation.operation_id); i++) await frame();
    check('project original-ID read passes held reply', f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === f.projectMutation.operation_id));
    check('project held reply does not resend', f.calls.filter(q => q.operation === 'project.select').length === 1);
    [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other')).click();
    await tick();
    check('other project mutation is refused while original is unresolved', f.calls.filter(q => q.operation === 'project.select').length === 1);
    f.phase = 'completed'; f.selected = Q; f.holdProject = false;
    for (let i = 0; i < 12; i++) await frame();
    [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Fixture')).click();
    for (let i = 0; i < 10; i++) await frame();
    check('project semantic terminal releases cross-surface admission', f.calls.filter(q => q.operation === 'project.select').length === 2);
    pane.current_run_id = R;
    pane.observation = { run_id: R, pane_id: N, current: true, process: 'running', work: 'running', evidence: 'provider_event', exit_code: null, observed_at: '2026-09-28T00:00:00Z' };
    root.querySelector('[data-action="reread"]').click();
    for (let i = 0; i < 8; i++) await frame();
    const interrupt = [...root.querySelectorAll('[data-action="interrupt-run"]')].find(button => !button.disabled);
    check('real selected run exposes project interrupt', !!interrupt);
    f.phase = 'accepted'; interrupt.click();
    for (let i = 0; i < 10 && !f.interruptMutation; i++) await tick();
    check('one run interrupt dispatched', !!f.interruptMutation && f.calls.filter(q => q.operation === 'run.interrupt').length === 1);
    recoverClick();
    for (let i = 0; i < 20 && f.sessions < 5; i++) await frame();
    f.phase = 'completed';
    for (let i = 0; i < 12; i++) await frame();
    check('completed interrupt record requires actual same-run exit', f.calls.some(q => q.operation === 'run.get' && q.params.run_id === R));
    const beforeOther = f.calls.filter(q => q.operation === 'project.select').length;
    const otherDuringRun = [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other'));
    check('project controls remain visible during interrupt recovery', !!otherDuringRun);
    otherDuringRun.click(); await tick();
    check('running process keeps cross-surface admission held', f.calls.filter(q => q.operation === 'project.select').length === beforeOther);
    f.runExited = true;
    for (let i = 0; i < 15; i++) await frame();
    [...root.querySelectorAll('[data-action="select-project"]')].find(button => button.textContent.includes('Other')).click();
    for (let i = 0; i < 10; i++) await frame();
    check('same-run actual exit releases original without old continuation', f.calls.filter(q => q.operation === 'project.select').length === beforeOther + 1
      && f.calls.filter(q => q.operation === 'run.interrupt').length === 1);
    mounted.dispose();
    f.calls = []; f.mutation = null; f.release = null; f.phase = 'accepted'; f.ownerGeneration = '1';
    f.selected = P; pane.current_run_id = null; pane.observation = null; f.runExited = false;
    const ownerRoot = document.createElement('main'); document.body.append(ownerRoot);
    let ownerMounted; const ownerOpening = module.mountWorkspaceMain(ownerRoot).then(value => { ownerMounted = value; });
    for (let i = 0; i < 25 && !ownerMounted; i++) await frame(); await ownerOpening;
    const ownerAgent = ownerRoot.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    const ownerSelect = ownerAgent.querySelector('select'); ownerSelect.value = 'codex'; ownerSelect.dispatchEvent(new Event('change'));
    for (let i = 0; i < 10 && ownerAgent.querySelector('[data-action="launch"]').disabled; i++) await frame();
    check('different owner agent original is available to start', !ownerAgent.querySelector('[data-action="launch"]').disabled);
    ownerAgent.querySelector('[data-action="launch"]').click(); ownerAgent.querySelector('[data-action="confirm-launch"]').click();
    for (let i = 0; i < 10 && !f.mutation; i++) await tick();
    const ownerOriginal = f.mutation, ownerLate = f.release;
    check('different owner agent original is dispatched once and pending', !!ownerOriginal && !!ownerLate
      && f.calls.filter(q => q.operation === 'agent.launch').length === 1);
    f.ownerGeneration = '2';
    const ownerReconnect = ownerRoot.querySelector(':scope > button');
    check('different owner agent reconnect is visible and enabled', !!ownerReconnect && !ownerReconnect.hidden
      && !ownerReconnect.disabled && ownerReconnect.getClientRects().length > 0);
    ownerReconnect.click();
    for (let i = 0; i < 25 && ownerRoot.dataset.startupState === 'connecting'; i++) await frame();
    check('different owner agent stays in recovery shell without original Q', ownerRoot.dataset.startupState === 'recovering'
      && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === ownerOriginal.operation_id));
    ownerLate(); await tick();
    check('late old-owner agent answer cannot query or release in new owner', ownerRoot.dataset.startupState === 'recovering'
      && f.calls.filter(q => q.operation === 'agent.launch').length === 1
      && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === ownerOriginal.operation_id));
    ownerMounted.dispose(); ownerRoot.remove();
    const J = '99999999-9999-4999-8999-999999999999';
    f.calls = []; f.mutation = null; f.release = null; f.instanceId = I; f.ownerGeneration = '1';
    const switchedRoot = document.createElement('main'); document.body.append(switchedRoot);
    let switchedMounted; const switchedOpening = module.mountWorkspaceMain(switchedRoot).then(value => { switchedMounted = value; });
    for (let i = 0; i < 25 && !switchedMounted; i++) await frame(); await switchedOpening;
    f.instanceId = J; f.ownerGeneration = '2';
    const switchedReconnect = switchedRoot.querySelector(':scope > button');
    check('agent route to I2/g2 has visible reconnect', !switchedReconnect.hidden && !switchedReconnect.disabled);
    switchedReconnect.click();
    for (let i = 0; i < 25 && switchedRoot.dataset.startupState !== 'mounted'; i++) await frame();
    check('agent route mounts I2/g2 after explicit different-instance switch', switchedRoot.dataset.startupState === 'mounted');
    const switchedAgent = switchedRoot.querySelector('[aria-label="AIの起動と状態の表示領域"]');
    const switchedSelect = switchedAgent.querySelector('select'); switchedSelect.value = 'codex'; switchedSelect.dispatchEvent(new Event('change'));
    for (let i = 0; i < 10 && switchedAgent.querySelector('[data-action="launch"]').disabled; i++) await frame();
    check('I2/g2 agent launch accepts current owner', !switchedAgent.querySelector('[data-action="launch"]').disabled);
    switchedAgent.querySelector('[data-action="launch"]').click(); switchedAgent.querySelector('[data-action="confirm-launch"]').click();
    for (let i = 0; i < 10 && !f.mutation; i++) await tick();
    const switchedOriginal = f.mutation, switchedLate = f.release;
    check('I2/g2 agent original is pending', !!switchedOriginal && !!switchedLate && switchedOriginal.instance_id === J);
    f.ownerGeneration = '3'; switchedReconnect.click();
    for (let i = 0; i < 25 && switchedRoot.dataset.startupState === 'connecting'; i++) await frame();
    check('I2/g3 agent recovery shell refuses old ID Q and replay', switchedRoot.dataset.startupState === 'recovering'
      && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === switchedOriginal.operation_id)
      && f.calls.filter(q => q.operation_id === switchedOriginal.operation_id).length === 1);
    switchedLate(); await tick();
    check('I2/g3 old agent late answer cannot open admission', switchedRoot.dataset.startupState === 'recovering'
      && !f.calls.some(q => q.operation === 'operation.get' && q.params.operation_id === switchedOriginal.operation_id));
    switchedMounted.dispose(); switchedRoot.remove();
    return { passed: checks.length, checks };
  }, source);
  console.log(JSON.stringify(result));
} finally { await browser.close(); }
