import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dependencyIndex = process.argv.indexOf('--dependency-root');
const dependencyRoot = dependencyIndex < 0 ? app : resolve(process.argv[dependencyIndex + 1]);
const require = createRequire(resolve(dependencyRoot, 'package.json'));
const ts = require('typescript');
const { chromium } = require('playwright');
const evidenceIndex=process.argv.indexOf('--evidence-dir');
const evidence = evidenceIndex<0?resolve(app, '../.evidence/rebuild/v0.38.0/TASK-871/view'):resolve(process.argv[evidenceIndex+1]);
mkdirSync(evidence, { recursive: true });
const sourcePath = resolve(app, 'src/workspace-ui/project-pane.ts');
const cssPath = resolve(app, 'src/workspace-ui/project-pane.css');
const source = readFileSync(sourcePath, 'utf8');
const css = readFileSync(cssPath, 'utf8');
const compileArgs = [require.resolve('typescript/bin/tsc'), '--noEmit', '--target', 'ES2020', '--module', 'ESNext', '--lib', 'ES2020,DOM,DOM.Iterable', '--moduleResolution', 'bundler', '--strict', '--noUnusedLocals', '--noUnusedParameters', '--noFallthroughCasesInSwitch', '--isolatedModules', sourcePath];
const compile = spawnSync(process.execPath, compileArgs, { encoding: 'utf8' });
writeFileSync(resolve(evidence, 'typescript.txt'), compile.stdout + compile.stderr, 'utf8');
if (compile.status !== 0) throw new Error(`TypeScript failed (${compile.status}): ${compile.stdout}${compile.stderr}`);
const bundled=await require('esbuild').build({entryPoints:[sourcePath],bundle:true,write:false,format:'esm',platform:'browser',target:'es2020',metafile:true});
const moduleText = bundled.outputFiles[0].text;
writeFileSync(resolve(evidence, 'project-pane.js'), moduleText, 'utf8');
const started = new Date().toISOString();
const browser = await chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
let checks = [];
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  // No server, transport, package download or native product window is involved.
  await page.route('**/*', route => route.abort());
  await page.setContent('<!doctype html><html lang="ja"><meta charset="utf-8"><body><div id="view"></div></body></html>');
  await page.addStyleTag({ content: css });
  checks = await page.evaluate(async moduleText => {
    const { createProjectPaneView } = await import(URL.createObjectURL(new Blob([moduleText], { type: 'text/javascript' })));
    const passed = [];
    const check = (name, condition) => { if (!condition) throw new Error(name); passed.push(name); };
    const clone = value => JSON.parse(JSON.stringify(value));
    const fixture = () => ({ instanceId: 'instance-1', topologyRevision: 7, generation: 'g1', availability: 'available', busy: false,
      projects: { selected_project_id: 'project-1', projects: [
        { project_id: 'project-1', display_name: '同名', path: 'C:\\作業\\日本語', root_state: 'verified' },
        { project_id: 'project-2', display_name: '同名', path: 'C:\\別の作業', root_state: 'verified' }] },
      panes: { project_id: 'project-1', selected_pane_id: 'pane-1', root: { kind: 'split', axis: 'horizontal', ratio: .3,
        first: { kind: 'leaf', pane_id: 'pane-1' }, second: { kind: 'split', axis: 'vertical', ratio: .7, first: { kind: 'leaf', pane_id: 'pane-2' }, second: { kind: 'leaf', pane_id: 'pane-3' } } },
        panes: [1, 2, 3].map(n => ({ pane_id: `pane-${n}`, project_id: 'project-1', display_name: `端末${n}`, path: 'C:\\作業\\日本語', current_run_id: `run-${n}`,
          observation: { pane_id: `pane-${n}`, run_id: `run-${n}`, current: true, process: 'running', work: 'unknown', evidence: 'unavailable', exit_code: null, observed_at: '2026-09-26T01:00:00Z' } })) } });
    let current, view, calls, inspections, mounts, releases, mode, resolvers;
    const host = document.querySelector('#view');
    const reset = (snapshot = fixture(), nextMode = 'unknown') => {
      view?.dispose(); current = snapshot; calls = []; inspections = []; mounts = []; releases = []; resolvers = []; mode = nextMode;
      view = createProjectPaneView(host, current, {
        control: (intent, ticket) => { calls.push({ intent, ticket }); if (mode === 'sync-settle') { view.settle(ticket, { disposition: 'completed' }); return { disposition: 'completed' }; } if (mode === 'throw') throw new Error('started'); if (mode === 'reject') return Promise.reject(new Error('started')); if (mode === 'defer') return new Promise(resolve => resolvers.push(resolve)); return { disposition: mode }; },
        inspect: intent => inspections.push(intent), mountTerminal: (slot, target) => { if (!slot.isConnected) throw new Error(`Disconnected mount ${target.paneId}`); mounts.push({ slot, target }); return () => releases.push(target); },
      });
    };
    const action = (name, pane = 'pane-1') => document.querySelector(`.workspace-pane[data-pane-id="${pane}"] [data-action="${name}"]`);
    const global = name => document.querySelector(`.workspace-toolbar [data-action="${name}"]`);
    const searchResult = label => [...document.querySelectorAll('[data-action="search-result"]')].find(item => item.textContent.includes(label));
    const click = el => { if (!el) throw new Error('missing button'); el.click(); };
    const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
    const render = () => view.render(current);
    const settle = disposition => view.settle(calls.at(-1).ticket, { disposition });
    const removeFirstPane = () => { current.panes.panes.shift(); current.panes.root = { kind: 'split', axis: 'vertical', ratio: .5, first: { kind: 'leaf', pane_id: 'pane-2' }, second: { kind: 'leaf', pane_id: 'pane-3' } }; current.panes.selected_pane_id = 'pane-2'; render(); };
    reset({ ...fixture(), projects: { projects: [], selected_project_id: null }, panes: null });
    check('empty screen principal actions', !!global('open-folder') && !!global('inspect-installation') && !document.querySelector('.workspace-pane') && global('create-pane').disabled);
    click(global('inspect-installation')); check('inspection carries context', inspections[0].kind === 'inspect-installation' && inspections[0].instanceId === 'instance-1');
    reset();
    check('terminal hooks mount connected exact pane slots', mounts.length === 3 && mounts.every(m => m.slot.isConnected && m.slot.parentElement.dataset.paneId === m.target.paneId && m.target.projectId === 'project-1'));
    check('same names retain distinct Japanese paths', document.querySelector('nav').textContent.includes('C:\\作業\\日本語') && document.querySelector('nav').textContent.includes('C:\\別の作業'));
    check('nested canonical split axes and ratio', document.querySelectorAll('.workspace-split').length === 2 && document.querySelector('.workspace-horizontal').style.getPropertyValue('--first-ratio') === '0.3' && document.querySelector('.workspace-vertical').style.getPropertyValue('--first-ratio') === '0.7');
    click(action('split-vertical')); click(action('split-horizontal', 'pane-2')); click(global('forget-project'));
    check('synchronous admission blocks rapid sibling and project controls', calls.length === 1);
    check('split exact identity correlation', JSON.stringify(calls[0].intent) === JSON.stringify({ instanceId: 'instance-1', topologyRevision: 7, generation: 'g1', projectId: 'project-1', paneId: 'pane-1', runId: 'run-1', kind: 'split-pane', axis: 'vertical' }));
    check('pending never states real process success', document.querySelector('[role=status]').textContent.includes('確認待ち'));
    check('wrong ticket cannot release', !view.settle(999, { disposition: 'completed' }) && action('select-pane').disabled);
    await flush(); check('unknown keeps admission', action('select-pane').disabled);
    check('duplicate unknown settlement no effect', !view.settle(calls[0].ticket, { disposition: 'unknown', message: 'duplicate' }));
    click(global('reread')); click(global('dismiss-error')); check('reread cannot release unknown', inspections.at(-1).kind === 'reread' && action('select-pane').disabled);
    current.generation = 'g2'; current.topologyRevision = 8; current.panes.selected_pane_id = 'pane-2'; render();
    check('render selection and revision never release or retry', calls.length === 1 && action('select-pane').disabled && document.querySelector('[role=status]').textContent.includes('pane-1'));
    check('correlated refusal releases', settle('refused') && !action('select-pane').disabled);
    check('duplicate settlement no effect', !settle('completed'));
    click(action('select-pane', 'pane-2')); check('explicit action after refusal fresh identity', calls.length === 2 && calls[1].intent.paneId === 'pane-2' && calls[1].intent.generation === 'g2' && calls[1].ticket === 2);
    for (const failure of ['throw', 'reject']) {
      reset(fixture(), failure); click(action('interrupt-run')); await flush(); render(); click(action('select-pane', 'pane-2'));
      check(`${failure} retains uncertain operation`, calls.length === 1 && action('interrupt-run').disabled && document.querySelector('[role=status]').textContent.includes('未確認'));
      settle('completed'); check(`${failure} explicit determinate recovery`, !action('interrupt-run').disabled);
    }
    reset(fixture(), 'defer'); click(action('select-pane')); const oldView = view; const oldResolve = resolvers[0];
    const next = fixture(); next.instanceId = 'instance-2'; reset(next, 'defer'); click(action('select-pane', 'pane-2')); oldResolve({ disposition: 'completed' }); await flush();
    check('old callback cannot release replacement instance', action('select-pane').disabled && calls.length === 1 && calls[0].intent.instanceId === 'instance-2');
    check('disposed settlement cannot release', !oldView.settle(1, { disposition: 'completed' }));
    reset(); const stale = action('split-horizontal').onclick; current.generation = 'new-generation'; render(); stale.call(action('split-horizontal'), new MouseEvent('click'));
    check('queued old DOM handler is obsolete', calls.length === 0);
    const slot = document.querySelector('.workspace-terminal'); slot.focus(); const heading = document.querySelector('.workspace-pane h2');
    current.panes.panes[0].observation.work = 'awaiting_input'; current.generation = 'state-update'; render();
    check('state update retains terminal mount and focus', mounts.length === 3 && slot === document.querySelector('.workspace-terminal') && document.activeElement === slot && heading === document.querySelector('.workspace-pane h2'));
    let keyboardSeen = false; slot.addEventListener('keydown', () => keyboardSeen = true); slot.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true, cancelable: true }));
    check('terminal keyboard not intercepted by view', keyboardSeen && calls.length === 0);
    reset(); click(action('close-pane')); check('live close opens captured labelled dialog', document.querySelector('dialog').open && document.querySelector('dialog').textContent.includes('run-1') && document.querySelector('dialog').textContent.includes('C:\\作業\\日本語'));
    check('modal initial focus is Return', document.activeElement.dataset.action === 'modal-return');
    current.panes.selected_pane_id = 'pane-2'; current.generation = 'g2'; render(); click(document.querySelector('[data-action=modal-confirm]')); click(document.querySelector('[data-action=modal-confirm]'));
    check('modal captured run stays exact across selection and duplicate confirm', calls.length === 1 && calls[0].intent.paneId === 'pane-1' && calls[0].intent.runId === 'run-1' && calls[0].intent.interruptFirst === true && calls[0].intent.generation === 'g2');
    click(document.querySelector('[data-action=modal-return]')); check('cancel pending modal falls back to exact pane heading', document.activeElement === document.querySelector('.workspace-pane[data-pane-id="pane-1"] h2') && action('close-pane').disabled);
    reset(); const invoke = action('close-pane'); invoke.focus(); click(invoke); click(document.querySelector('[data-action=modal-return]')); check('cancel restores invoker focus', document.activeElement === invoke && calls.length === 0);
    const shortcut = key => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key, ctrlKey: true, shiftKey: true, bubbles: true, cancelable: true }));
    reset(fixture(), 'defer'); click(global('operation-search')); const searchInput = document.querySelector('input[type=search]'); searchInput.focus(); shortcut('W');
    check('search shortcut W transfers sole modal ownership to live close confirmation', !document.querySelectorAll('dialog')[1].open && document.querySelector('dialog').open && [...document.querySelectorAll('dialog[open]')].length === 1 && document.activeElement.dataset.action === 'modal-return' && calls.length === 0);
    click(document.querySelector('[data-action=modal-confirm]')); check('search shortcut W submits exact close once', calls.length === 1 && calls[0].intent.kind === 'close-pane' && calls[0].intent.paneId === 'pane-1');
    check('search shortcut W completed close returns stable main', settle('completed') && [...document.querySelectorAll('dialog[open]')].length === 0 && document.activeElement.tagName === 'MAIN' && calls.length === 1);
    reset(); click(global('operation-search')); document.querySelector('input[type=search]').focus(); shortcut('W'); click(document.querySelector('[data-action=modal-return]'));
    check('search shortcut W Back returns valid close control', [...document.querySelectorAll('dialog[open]')].length === 0 && document.activeElement === action('close-pane') && calls.length === 0);
    reset(); current.panes.selected_pane_id = null; render(); click(global('operation-search')); document.querySelector('input[type=search]').focus(); shortcut('W');
    check('search shortcut W without selected pane leaves search and focus', document.querySelectorAll('dialog')[1].open && !document.querySelector('dialog').open && document.activeElement === document.querySelector('input[type=search]') && calls.length === 0);
    reset(); current.availability = 'unavailable'; render(); click(global('operation-search')); document.querySelector('input[type=search]').focus(); shortcut('W');
    check('search shortcut W unavailable leaves search and focus', document.querySelectorAll('dialog')[1].open && !document.querySelector('dialog').open && document.activeElement === document.querySelector('input[type=search]') && calls.length === 0);
    reset(); click(global('operation-search')); document.querySelector('input[type=search]').focus(); shortcut('P');
    check('search shortcut P is idempotent', document.querySelectorAll('dialog')[1].open && [...document.querySelectorAll('dialog[open]')].length === 1 && document.activeElement === document.querySelector('input[type=search]') && calls.length === 0);
    reset(); click(action('close-pane')); const guardedTarget = document.querySelector('dialog').textContent; const guardedFocus = document.activeElement;
    for (const key of ['P', 'T', 'W']) { shortcut(key); check(`live close confirmation blocks shortcut ${key}`, document.querySelector('dialog').open && !document.querySelectorAll('dialog')[1].open && document.querySelector('dialog').textContent === guardedTarget && document.activeElement === guardedFocus && calls.length === 0); }
    reset(); current.panes.panes[0].current_run_id = null; current.panes.panes[0].observation = null; render(); click(global('operation-search')); document.querySelector('input[type=search]').focus(); shortcut('W');
    check('search shortcut W nonrunning direct close keeps search ownership', document.querySelectorAll('dialog')[1].open && !document.querySelector('dialog').open && document.activeElement === document.querySelector('input[type=search]') && calls.length === 1 && calls[0].intent.runId === null);
    reset(); click(action('close-pane')); current.panes.panes[0].current_run_id = 'replacement'; current.panes.panes[0].observation.run_id = 'replacement'; current.generation = 'g2'; render(); click(document.querySelector('[data-action=modal-confirm]'));
    check('replaced run disables obsolete modal', calls.length === 0 && document.querySelector('[data-action=modal-confirm]').disabled && document.querySelector('dialog').textContent.includes('実行が変わりました'));
    reset(); click(action('close-pane')); current.panes.panes.shift(); current.panes.root = { kind: 'split', axis: 'vertical', ratio: .5, first: { kind: 'leaf', pane_id: 'pane-2' }, second: { kind: 'leaf', pane_id: 'pane-3' } }; current.panes.selected_pane_id = 'pane-2'; render(); click(document.querySelector('[data-action=modal-confirm]')); click(document.querySelector('[data-action=modal-return]'));
    check('removed modal target has no sibling fallback', calls.length === 0 && document.activeElement.tagName === 'MAIN');
    reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]')); removeFirstPane();
    check('submitted close remains pending after target disappears', document.querySelector('dialog').open && document.querySelector('dialog').textContent.includes('確認待ち') && !document.querySelector('dialog').textContent.includes('実行が変わりました') && document.querySelector('[data-action=modal-confirm]').disabled && calls.length === 1);
    check('correlated completed close dismisses dialog and focuses stable main', settle('completed') && !document.querySelector('dialog').open && document.activeElement.tagName === 'MAIN' && document.querySelector('[role=status]').textContent.includes('完了') && calls.length === 1);
    reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]'));
    check('completion before snapshot removal dismisses same dialog', settle('completed') && !document.querySelector('dialog').open && document.activeElement.tagName === 'MAIN'); removeFirstPane();
    check('later target removal cannot reopen completed dialog', !document.querySelector('dialog').open && calls.length === 1);
    reset(fixture(), 'sync-settle'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]')); await flush();
    check('synchronous correlated completion dismisses exactly once', !document.querySelector('dialog').open && document.activeElement.tagName === 'MAIN' && calls.length === 1);
    reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]')); removeFirstPane();
    check('wrong completion cannot dismiss submitted close', !view.settle(calls[0].ticket + 1, { disposition: 'completed' }) && document.querySelector('dialog').open && calls.length === 1);
    check('unknown close remains visible without implicit retry', settle('unknown') && document.querySelector('dialog').open && document.querySelector('dialog').textContent.includes('未確認') && document.querySelector('[data-action=modal-confirm]').disabled && calls.length === 1);
    click(document.querySelector('[data-action=modal-return]')); click(global('operation-search')); const laterSearch = document.querySelectorAll('dialog')[1]; const laterFocus = document.activeElement;
    check('late completion after Back preserves newer screen and focus', settle('completed') && laterSearch.open && document.activeElement === laterFocus && !document.querySelector('dialog').open && calls.length === 1);
    for (const disposition of ['completed', 'refused', 'unknown']) for (const label of ['導入状況を確認', '状態を読み直す']) {
      reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]')); click(document.querySelector('[data-action=modal-return]')); click(global('operation-search'));
      const result = searchResult(label); result.focus(); const before = calls.length;
      view.settle(calls[0].ticket, { disposition });
      check(`late ${disposition} retains live search result focus ${label}`, document.querySelectorAll('dialog')[1].open && searchResult(label) === result && document.activeElement === result && calls.length === before);
    }
    reset(); click(global('operation-search')); const filtered = searchResult('選択：端末1'); filtered.focus(); const searchQuery = document.querySelector('input[type=search]');
    searchQuery.value = '導入状況'; searchQuery.dispatchEvent(new Event('input'));
    filtered.click(); check('filtered result falls back to query and cannot execute detached control', document.activeElement === searchQuery && !filtered.isConnected && calls.length === 0 && document.querySelectorAll('dialog')[1].open);
    reset(); click(global('operation-search')); const disabledResult = searchResult('選択：端末1'); disabledResult.focus(); current.availability = 'unavailable'; render();
    disabledResult.click(); check('disabled result falls back to query without dispatch', document.activeElement === document.querySelector('input[type=search]') && disabledResult.disabled && calls.length === 0);
    reset(); click(global('operation-search')); const removedResult = searchResult('選択：端末1'); removedResult.focus(); removeFirstPane();
    removedResult.click(); check('removed source falls back to query and cannot execute detached result', document.activeElement === document.querySelector('input[type=search]') && !removedResult.isConnected && calls.length === 0 && document.querySelectorAll('dialog')[1].open);
    reset(); click(global('operation-search')); const refreshed = searchResult('選択：端末1'); refreshed.focus(); const oldResultHandler = refreshed.onclick; current.generation = 'g2'; current.panes.panes[0].display_name = '更新端末'; render();
    check('same source retains result DOM and focus while refreshing label and handler', searchResult('選択：更新端末') === refreshed && document.activeElement === refreshed && refreshed.onclick !== oldResultHandler);
    click(refreshed); check('refreshed search result sends current generation once', calls.length === 1 && calls[0].intent.generation === 'g2' && calls[0].intent.paneId === 'pane-1');
    reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]')); click(document.querySelector('[data-action=modal-return]')); click(global('operation-search')); searchResult('導入状況を確認').focus(); click(document.querySelector('[data-action=close-search]')); const afterSearch = document.activeElement;
    check('late result after search closes cannot steal later focus', settle('completed') && !document.querySelectorAll('dialog')[1].open && document.activeElement === afterSearch && calls.length === 1);
    reset(fixture(), 'defer'); click(action('close-pane')); click(document.querySelector('[data-action=modal-confirm]'));
    check('refused close keeps dialog and disables retry', settle('refused') && document.querySelector('dialog').open && document.querySelector('dialog').textContent.includes('拒否') && document.querySelector('[data-action=modal-confirm]').disabled && calls.length === 1);
    current.panes.selected_pane_id = 'pane-2'; render(); const modalFocus = document.activeElement; const modalTarget = document.querySelector('dialog').textContent;
    click(action('close-pane', 'pane-2')); document.querySelector('[data-action=modal-return]').dispatchEvent(new KeyboardEvent('keydown', { key: 'W', ctrlKey: true, shiftKey: true, bubbles: true, cancelable: true }));
    check('close reentry preserves first target and focus after refusal', document.querySelector('dialog').open && document.querySelector('dialog').textContent === modalTarget && document.activeElement === modalFocus && document.querySelector('[data-action=modal-confirm]').disabled && calls.length === 1);
    click(document.querySelector('[data-action=modal-return]')); click(action('close-pane', 'pane-2'));
    check('explicit new close after Back can name new pane', document.querySelector('dialog').open && document.querySelector('dialog').textContent.includes('pane-2') && calls.length === 1);
    for (const process of ['starting', 'running', 'unknown']) { reset(); current.panes.panes[0].observation.process = process; render(); click(action('close-pane')); check(`${process} run requires modal`, document.querySelector('dialog').open && calls.length === 0); }
    reset(); current.panes.panes[0].current_run_id = null; current.panes.panes[0].observation = null; render();
    check('restored unstarted pane explicit and run actions unavailable', document.querySelector('.workspace-pane').textContent.includes('配置のみ復元・未起動') && action('resize-pane').disabled && action('interrupt-run').disabled);
    click(action('close-pane')); check('unstarted close direct exact null run', calls[0].intent.runId === null && !document.querySelector('dialog').open);
    reset(); current.panes.panes[0].observation.process = 'exited'; current.panes.panes[0].observation.evidence = 'process_exit'; render(); click(action('close-pane')); check('confirmed exited close direct', calls[0].intent.kind === 'close-pane' && !calls[0].intent.interruptFirst);
    reset(); current.panes.panes[0].observation.process = 'exited'; render(); click(action('close-pane')); check('unavailable exit evidence remains protected', document.querySelector('dialog').open && calls.length === 0);
    for (const availability of ['unavailable', 'uncertain']) { reset(); current.availability = availability; render(); click(action('split-horizontal')); check(`${availability} preserves identities denies controls`, calls.length === 0 && mounts.length === 3 && action('select-pane').disabled && document.querySelector('.workspace-pane').textContent.includes('run-1')); }
    reset(); current.busy = true; render(); click(action('select-pane')); check('caller busy denies control', calls.length === 0 && action('select-pane').disabled);
    reset(); current.error = 'permission_denied：この対象への操作は許可されていません'; render(); check('permission error retained without fallback', document.querySelector('[role=status]').textContent.includes('permission_denied') && mounts.length === 3 && calls.length === 0);
    for (const root_state of ['unavailable', 'changed', 'unknown']) { reset(); current.projects.projects[0].root_state = root_state; render(); check(`${root_state} root denies creation and split retains close`, global('create-pane').disabled && action('split-horizontal').disabled && !action('close-pane').disabled && document.querySelector('nav').textContent.includes('作業場所')); }
    for (const defect of ['selection', 'membership', 'duplicate', 'observation', 'ratio']) {
      reset(); if (defect === 'selection') current.panes.selected_pane_id = 'missing'; if (defect === 'membership') current.panes.root.first.pane_id = 'missing'; if (defect === 'duplicate') current.panes.root.first.pane_id = 'pane-2'; if (defect === 'observation') current.panes.panes[0].observation.run_id = 'wrong'; if (defect === 'ratio') current.panes.root.ratio = 1;
      render(); click(global('forget-project')); check(`${defect} inconsistency denies domain`, global('forget-project').disabled && calls.length === 0 && document.querySelector('[role=status]').textContent.includes('対応を確認できません'));
    }
    reset(); current.projects.projects[0].display_name = '<img src=x onerror=alert(1)>'; current.projects.projects[0].path = '<script>bad</script>'; current.panes.panes[0].display_name = '<svg onload=alert(1)>'; current.error = '<img src=x>'; render();
    check('all target and error text uses literal text', !document.querySelector('img,svg,script') && document.querySelector('h1').textContent.includes('<script>') && document.querySelector('h2').textContent.includes('<svg'));
    for (const dimension of [0, 1]) for (const value of [1, 32767, 0, -1, 1.5, 32768, 99999, 'NaN', 'Infinity']) {
      reset(); const inputs = document.querySelector('.workspace-pane').querySelectorAll('input'); inputs[dimension].value = String(value); click(action('resize-pane'));
      const legal = value === 1 || value === 32767;
      check(`resize dimension ${dimension} value ${value}`, legal ? calls.length === 1 && calls[0].intent.kind === 'resize-pane' && calls[0].intent[dimension === 0 ? 'rows' : 'cols'] === value && calls[0].intent.runId === 'run-1' : calls.length === 0 && document.querySelector('.workspace-pane fieldset [role=status]').textContent.includes('整数'));
    }
    reset(); click(global('operation-search')); check('operation search focus and named dialog', document.activeElement.type === 'search' && document.querySelectorAll('dialog')[1].open);
    const q = document.querySelector('input[type=search]'); q.value = '左右に分割'; q.dispatchEvent(new Event('input')); const menu = document.querySelector('[data-action=search-result]'); click(menu); click(action('split-horizontal'));
    check('search result visibly names exact pane', menu.textContent.includes('端末1 / pane-1'));
    check('search shares admission and target correlation', calls.length === 1 && calls[0].intent.kind === 'split-pane' && calls[0].intent.paneId === 'pane-1');
    reset(); click(global('toggle-projects')); check('collapsed list hidden from keyboard', document.querySelector('nav').hidden && global('toggle-projects').getAttribute('aria-expanded') === 'false');
    click(global('toggle-projects')); check('drawer can reopen', !document.querySelector('nav').hidden);
    check('details initially collapsed', !document.querySelector('details').open && !document.querySelector('details').hidden);
    current.panes.selected_pane_id = null; render(); check('no selected pane hides details', document.querySelector('details').hidden);
    reset(); const oldButton = action('split-horizontal'); const oldHandler = oldButton.onclick; view.dispose(); oldHandler.call(oldButton, new MouseEvent('click'));
    check('disposal removes handlers releases each terminal once', calls.length === 0 && releases.length === 3 && !host.children.length);
    reset(); let replaced = false; try { view.render({ ...current, instanceId: 'wrong-instance' }); } catch { replaced = true; }
    check('host replacement requires explicit disposal', replaced);
    click(global('forget-project')); check('forget exact named project has no directory deletion intent', calls[0].intent.kind === 'forget-project' && calls[0].intent.projectId === 'project-1' && global('forget-project').textContent.includes('ファイルは保持'));
    settle('refused'); click(document.querySelectorAll('nav button')[1]);
    check('same-name sibling selection carries exact project ID', calls[1].intent.kind === 'select-project' && calls[1].intent.projectId === 'project-2');
    settle('completed');
    click(global('toggle-projects'));
    reset(fixture(), 'defer');
    check('callable folder reserves same synchronous ticket', view.requestOpenFolder() && calls.length === 1 && calls[0].intent.kind === 'open-folder' && calls[0].ticket > 0);
    check('callable folder rejects duplicate while pending', !view.requestOpenFolder() && calls.length === 1);
    const callableTicket = calls[0].ticket;
    current = { ...current, generation: 'replacement' }; render();
    check('callable folder keeps ticket across snapshot generation change', calls.length === 1 && !view.requestOpenFolder());
    check('callable folder correlated settlement releases without effect replay', view.settle(callableTicket, { disposition: 'completed' }) && !view.settle(callableTicket, { disposition: 'completed' }) && calls.length === 1);
    reset();
    const captured = { instanceId: current.instanceId, generation: current.generation, topologyRevision: current.topologyRevision, projectId: 'project-1', paneId: 'pane-1', runId: 'run-1', kind: 'resize-pane', rows: 1, cols: 32767 };
    check('callable resize captured boundary dimensions', view.requestPaneResize(captured) && calls.length === 1 && calls[0].intent.runId === 'run-1' && calls[0].intent.rows === 1 && calls[0].intent.cols === 32767);
    check('callable resize never replays admitted pending request', !view.requestPaneResize(captured) && calls.length === 1);
    for (const changed of [{ rows: 0 }, { cols: 32768 }, { rows: 1.5 }, { generation: 'old' }, { topologyRevision: 6 }, { instanceId: 'old' }, { runId: 'old' }, { projectId: 'project-2' }, { paneId: 'missing' }]) {
      reset(); check(`callable resize rejects ${JSON.stringify(changed)}`, !view.requestPaneResize({ ...captured, ...changed }) && calls.length === 0);
    }
    reset(); current = { ...current, busy: true }; render();
    check('callable resize busy does not admit', !view.requestPaneResize(captured) && calls.length === 0);
    reset(); view.dispose();
    check('disposed view rejects both callables', !view.requestOpenFolder() && !view.requestPaneResize(captured) && calls.length === 0);
    reset(); click(global('toggle-projects'));
    // Leave the final fixture ready for the external keyboard and layout checks.
    return passed;
  }, moduleText);
  await page.locator('[data-action=toggle-projects]').focus();
  const keyboardTargets = [];
  for (let n = 0; n < 38; n++) {
    await page.keyboard.press('Tab');
    keyboardTargets.push(await page.evaluate(() => ({ nav: !!document.activeElement.closest('nav'), dialog: !!document.activeElement.closest('dialog'), name: document.activeElement.getAttribute('aria-label') || document.activeElement.textContent })));
  }
  if (keyboardTargets.some(target => target.nav || target.dialog)) throw new Error('Tab entered hidden drawer or closed dialog');
  checks.push('actual Tab excludes hidden drawer and closed dialogs');
  await page.locator('details summary').focus();
  await page.keyboard.press('Enter');
  if (!await page.locator('details').evaluate(el => el.open)) throw new Error('Keyboard could not expand details');
  await page.keyboard.press('Enter');
  if (await page.locator('details').evaluate(el => el.open)) throw new Error('Keyboard could not collapse details');
  checks.push('actual keyboard expands and collapses details');
  await page.locator('[data-action=operation-search]').focus();
  await page.keyboard.press('Enter');
  if (!await page.locator('input[type=search]').evaluate(el => el === document.activeElement)) throw new Error('Search keyboard focus failed');
  await page.keyboard.press('Escape');
  if (!await page.locator('[data-action=operation-search]').evaluate(el => el === document.activeElement)) throw new Error('Search cancel focus failed');
  checks.push('actual keyboard search and Escape restore focus');
  for (const width of [640, 320]) {
    await page.setViewportSize({ width, height: 900 });
    await page.evaluate(() => document.querySelector('.workspace-project-pane').style.zoom = '2');
    const fits = await page.evaluate(() => [...document.querySelectorAll('.workspace-toolbar button, .workspace-pane-controls button, .workspace-pane input')].every(el => el.getBoundingClientRect().right <= innerWidth + 1));
    if (!fits) throw new Error(`Controls overflow at width ${width} / zoom 200%`);
    checks.push(`width ${width} zoom 200% controls fit`);
    const separated = await page.evaluate(() => [...document.querySelectorAll('.workspace-pane')].every(pane => pane.querySelector('fieldset').getBoundingClientRect().bottom <= pane.querySelector('.workspace-terminal').getBoundingClientRect().top));
    if (!separated) throw new Error(`Controls cover terminal at width ${width}`);
    checks.push(`width ${width} zoom 200% terminal remains uncovered`);
  }
  await page.emulateMedia({ forcedColors: 'active' });
  const contrast = await page.evaluate(() => getComputedStyle(document.querySelector('.workspace-project-pane')).forcedColorAdjust === 'auto');
  if (!contrast) throw new Error('forced colors overridden');
  checks.push('forced colors remain automatic');
  await page.screenshot({ path: resolve(evidence, 'narrow-forced-colors.png'), fullPage: true });
} finally { await browser.close(); }
const paths = [...new Set([sourcePath, cssPath, fileURLToPath(import.meta.url),...Object.keys(bundled.metafile.inputs).map(path=>resolve(path))])];
const receipt = { scope: 'independent DOM view only; not native transport or TASK-871 adoption', command: [process.execPath, ...process.argv.slice(1)], nodeVersion: process.version, browserVersion: browser.version(), started, ended: new Date().toISOString(), typescriptExit: compile.status, checks, passed: checks.length,
  sources: paths.map(path => { const bytes = readFileSync(path); return { path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }; }) };
writeFileSync(resolve(evidence, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n', 'utf8');
console.log(JSON.stringify(receipt, null, 2));
