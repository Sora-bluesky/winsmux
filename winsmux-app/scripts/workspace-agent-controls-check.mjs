import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const option = (name, fallback) => { const i = process.argv.indexOf(name); return i < 0 ? fallback : resolve(process.argv[i + 1]); };
const dependencyRoot = option('--dependency-root', app);
const require = createRequire(resolve(dependencyRoot, 'package.json'));
const evidence = option('--evidence-dir', resolve(app, '../.evidence/rebuild/v0.38.0/TASK-873/view'));
mkdirSync(evidence, { recursive: true });
const source = resolve(app, 'src/workspace-ui/agent-controls.ts');
const hash = p => createHash('sha256').update(readFileSync(p)).digest('hex');
const inputs = [source, fileURLToPath(import.meta.url), resolve(app, 'src/generated/workspace-contract.ts')].map(path => ({ path, sha256: hash(path) }));
const started = new Date().toISOString();
let checks = [], browser, failure = null;
try {
  const args = [require.resolve('typescript/bin/tsc'), '--noEmit', '--target', 'ES2020', '--module', 'ESNext', '--lib', 'ES2020,DOM,DOM.Iterable', '--moduleResolution', 'bundler', '--strict', '--noUnusedLocals', '--noUnusedParameters', '--noFallthroughCasesInSwitch', '--isolatedModules', source];
  const compiled = spawnSync(process.execPath, args, { encoding: 'utf8' });
  writeFileSync(resolve(evidence, 'typescript.txt'), compiled.stdout + compiled.stderr, 'utf8');
  if (compiled.status !== 0) throw new Error(`TypeScript failed (${compiled.status}): ${compiled.stdout}${compiled.stderr}`);
  const bundled = await require('esbuild').build({ entryPoints: [source], bundle: true, write: false, format: 'esm', platform: 'browser', target: 'es2020', metafile: true });
  const moduleText = bundled.outputFiles[0].text;
  writeFileSync(resolve(evidence, 'agent-controls.js'), moduleText, 'utf8');
  browser = await require('playwright').chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route('**/*', route => route.abort());
  await page.setContent('<!doctype html><html lang="ja"><meta charset="utf-8"><body><div id="agent"></div></body></html>');
  const tested = await page.evaluate(async moduleText => {
    const { createAgentControls } = await import(URL.createObjectURL(new Blob([moduleText], { type: 'text/javascript' })));
    const passed = [];
    const check = (name, condition) => { if (!condition) throw new Error(name); passed.push(name); };
    const clone = x => JSON.parse(JSON.stringify(x));
    const fixture = () => ({ instanceId: '00000000-0000-4000-8000-000000000001', generation: 'generation-1', observationRevision: 1, availability: 'available', busy: false,
      project: { project_id: 'project-1', path: 'C:\\作業\\日本語', display_name: '作業', root_state: 'verified' },
      pane: { pane_id: 'pane-1', project_id: 'project-1', display_name: '端末', path: 'C:\\作業\\日本語', current_run_id: 'run-1',
        observation: { current: true, pane_id: 'pane-1', run_id: 'run-1', process: 'running', work: 'unknown', evidence: 'unavailable', observed_at: '2026-09-27T09:00:00Z', exit_code: null } },
      capabilities: { state: 'known', providers: [{ provider: 'codex', version: '0.100.0' }, { provider: 'claude', version: '2.0.0' }] },
    });
    const host = document.querySelector('#agent');
    let view, current, calls, inspections, restores, mode, resolves;
    const button = name => host.querySelector(`[data-action="${name}"]`);
    const field = name => host.querySelector(`[data-field="${name}"]`).textContent;
    const reset = (s = fixture(), behavior = 'return') => {
      view?.dispose(); current = s; calls = []; inspections = []; restores = []; resolves = []; mode = behavior;
      view = createAgentControls(host, current, {
        submit: (intent, ticket) => { calls.push({ intent, ticket });
          if (mode === 'throw') throw new Error('delivery uncertain');
          if (mode === 'reject') return Promise.reject(new Error('delivery uncertain'));
          if (mode === 'defer') return new Promise(resolve => resolves.push(resolve));
          return { phase: 'completed' };
        },
        inspect: intent => inspections.push(intent),
        restoreFocus: (target, origin) => { restores.push({ target, origin }); origin.focus(); },
      });
    };
    const choose = (p = 'codex') => { const select = host.querySelector('select'); select.value = p; select.dispatchEvent(new Event('change')); };
    const update = (change = () => {}) => { const next = clone(current); next.observationRevision++; change(next); current = next; return view.update(next); };
    const open = () => button('launch').click();
    const launch = () => { open(); button('confirm-launch').click(); };
    const settle = phase => { const c = calls.at(-1); return view.settle(c.ticket, c.intent, phase); };
    const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
    try {
      reset(); check('explicit choice no initial fallback', button('launch').disabled && host.querySelector('select').value === '' && calls.length === 0);
      choose(); check('detected Codex version and authentication uncertainty', field('cli').includes('0.100.0') && field('cli').includes('認証') && !button('launch').disabled);
      open(); check('modal labels exact CLI path and current run', host.querySelector('dialog').open && field('confirmation').includes('0.100.0') && field('confirmation').includes(current.project.path) && field('confirmation').includes('run-1'));
      check('safe return gets modal initial focus', document.activeElement === button('confirm-back'));
      button('confirm-back').click(); check('cancel restores exact origin without submission', calls.length === 0 && restores.length === 1 && restores[0].target.runId === 'run-1' && document.activeElement === button('launch'));
      choose('claude'); launch(); await flush();
      check('Claude has no Codex fallback', calls.length === 1 && calls[0].intent.provider === 'claude' && calls[0].intent.detectedVersion === '2.0.0');
      check('empty optional fields mean null', calls[0].intent.model === null && calls[0].intent.effort === null);
      check('running launch captures one interrupt-before-launch intent', calls[0].intent.interruptFirst && calls[0].intent.runId === 'run-1' && calls[0].intent.cwd === current.project.path);
      check('UUID ticket immutable captured intent', /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(calls[0].ticket) && Object.isFrozen(calls[0].intent));
      check('successful callback return never releases admission', button('launch').disabled && field('admission').includes('起動を確認中'));
      button('interrupt').click(); launch(); check('rapid launch and interrupt emit once', calls.length === 1);
      check('wrong ticket cannot release', !view.settle('00000000-0000-4000-8000-000000000009', calls[0].intent, 'completed'));
      for (const key of ['instanceId', 'generation', 'projectId', 'paneId', 'runId']) check(`wrong original ${key} cannot release`, !view.settle(calls[0].ticket, { ...calls[0].intent, [key]: 'wrong' }, 'completed'));
      check('awaiting duplicate inert', !settle('awaiting'));
      check('unknown keeps one admission', settle('unknown') && button('launch').disabled && field('admission').includes('確認できません'));
      check('unknown duplicate inert', !settle('unknown'));
      check('correlated refusal releases only admission', settle('refused') && !button('launch').disabled && field('work').includes('未確認'));
      check('settlement duplicate inert', !settle('completed'));
      launch(); check('new explicit request gets new UUID', calls.length === 2 && calls[0].ticket !== calls[1].ticket);
      reset(); choose(); host.querySelector('details').open = true;
      const values = ['  exact\n日本語🧪  ', ' ']; const textareas = host.querySelectorAll('textarea'); textareas[0].value = values[0]; textareas[1].value = values[1]; choose('claude');
      open(); check('confirmation shows Unicode newline and spaces', field('confirmation').includes(values[0]) && field('confirmation').includes(values[1]));
      button('confirm-launch').click(); check('optional values unchanged across provider switch', calls[0].intent.model === values[0] && calls[0].intent.effort === values[1]);
      for (const capabilities of [{ state: 'unknown', providers: null }, { state: 'known', providers: null }, { state: 'known', providers: [] }, { state: 'known', providers: [{ provider: 'claude', version: '2' }] }, { state: 'known', providers: [{ provider: 'codex', version: '' }] }, { state: 'known', providers: [{ provider: 'codex', version: '1' }, { provider: 'codex', version: '1' }] }, { state: 'known', providers: [{ provider: 'other', version: '1' }] }]) {
        reset({ ...fixture(), capabilities }); choose(); launch();
        check(`unknown/missing/invalid capability ${JSON.stringify(capabilities)}`, calls.length === 0 && button('launch').disabled && !field('cli').includes('を検出済み'));
        button('inspect-installation').click(); button('focus-terminal').click(); button('official-docs').click();
        check('capability recovery emits only inspection intents', inspections.length === 3 && inspections[0].provider === 'codex' && inspections[1].target.paneId === 'pane-1' && calls.length === 0);
      }
      for (const root_state of ['changed', 'unavailable', 'unknown']) {
        reset(); choose(); update(s => { s.project.root_state = root_state; }); launch();
        check(`root ${root_state} blocks launch preserves explicit interrupt`, calls.length === 0 && button('launch').disabled && !button('interrupt').disabled);
      }
      for (const change of [s => { s.project.path = null; }, s => { s.pane.project_id = 'wrong'; }, s => { s.pane.observation.current = false; }, s => { s.pane.observation.run_id = 'old'; }, s => { s.pane.observation.pane_id = 'other'; }, s => { s.pane.observation = null; }]) {
        reset(); choose(); update(change); launch(); check('missing or mismatched current context never launches', calls.length === 0 && button('launch').disabled);
      }
      for (const change of [s => { s.project = null; }, s => { s.pane.project_id = 'wrong'; }, s => { s.pane.observation.current = false; }, s => { s.pane.observation.run_id = 'old'; }, s => { s.pane.observation.pane_id = 'other'; }]) {
        reset(); update(change); button('interrupt').click();
        check('mismatched selection cannot display current process or interrupt', field('process') === 'プロセス: 未確認' && calls.length === 0 && button('interrupt').disabled);
      }
      reset(); const frozenDOM = host.innerHTML; current.pane.observation.work = 'succeeded'; current.project.path = 'caller mutation';
      check('caller mutation without committed frame is inert', host.innerHTML === frozenDOM);
      for (const availability of ['uncertain', 'unavailable']) {
        reset(); choose(); update(s => { s.availability = availability; }); launch(); button('interrupt').click();
        check(`${availability} blocks mutations no current success`, calls.length === 0 && field('state').includes('現在の状態を確認できません') && field('process').includes('未確認'));
      }
      reset(); choose(); update(s => { s.busy = true; }); launch(); button('interrupt').click(); check('caller busy blocks mutations', calls.length === 0);
      for (const change of [s => { s.pane.current_run_id = 'new'; s.pane.observation.run_id = 'new'; }, s => { s.pane.pane_id = 'other'; s.pane.observation.pane_id = 'other'; }, s => { s.project.project_id = 'other'; s.pane.project_id = 'other'; }, s => { s.capabilities.providers[0].version = 'changed'; }, s => { s.capabilities.state = 'unknown'; }, s => { s.project.root_state = 'changed'; }, s => { s.project.path = 'C:\\別の場所'; }, s => { s.availability = 'uncertain'; }]) {
        reset(); choose(); open(); const before = field('confirmation'); update(change); button('confirm-launch').click();
        check('captured confirmation invalidated never retargeted', calls.length === 0 && button('confirm-launch').disabled && field('confirmation') === before);
        button('confirm-back').click(); check('invalidated confirmation still safely returns', !host.querySelector('dialog').open && restores.length === 1 && restores[0].target.runId === 'run-1');
      }
      reset(); choose(); open(); update(s => { s.topologyRevision = 999; }); button('confirm-launch').click(); check('unrelated topology does not invalidate run operation', calls.length === 1 && calls[0].intent.runId === 'run-1');
      for (const process of ['starting', 'running', 'unknown', 'exited']) {
        reset(); choose(); update(s => { s.pane.observation.process = process; s.pane.observation.work = 'unknown'; s.pane.observation.evidence = process === 'exited' ? 'process_exit' : 'unavailable'; });
        check(`${process} observed separately from unknown work`, field('work') === '作業: 未確認');
        if (process === 'unknown') check('unknown process prevents launch', button('launch').disabled);
        else { launch(); check(`${process} correct replacement intent`, calls[0].intent.interruptFirst === (process !== 'exited')); }
      }
      reset(); choose(); update(s => { s.pane.current_run_id = null; s.pane.observation = null; }); launch(); check('unstarted pane direct confirmed launch', calls[0].intent.runId === null && !calls[0].intent.interruptFirst && button('interrupt').disabled);
      reset(); update(s => { s.pane.observation.process = 'exited'; s.pane.observation.exit_code = 0; s.pane.observation.evidence = 'process_exit'; }); check('exit zero never invents work success', field('work') === '作業: 未確認' && button('interrupt').disabled);
      for (const work of ['running', 'awaiting_input', 'succeeded', 'failed', 'unknown']) {
        reset(); update(s => { s.pane.observation.work = work; s.pane.observation.evidence = work === 'unknown' ? 'unavailable' : 'provider_event'; });
        const labels = { running: '作業中', awaiting_input: '入力待ち', succeeded: '完了', failed: '失敗', unknown: '未確認' };
        check(`${work} uses explicit evidence no output inference`, field('work') === `作業: ${labels[work]}` && field('process') === 'プロセス: 稼働中');
      }
      reset(); button('interrupt').click(); check('interrupt is acceptance pending not terminated', calls.length === 1 && field('admission').includes('中断を確認中') && !field('work').includes('中断済み'));
      update(s => { s.pane.observation.process = 'exited'; s.pane.observation.work = 'interrupted'; s.pane.observation.evidence = 'process_exit'; });
      check('actual same-run interrupted terminal displays while pending retained', field('work') === '作業: 中断済み' && field('admission').includes('中断を確認中') && button('launch').disabled);
      const terminalFrame = clone(current); const domBefore = host.innerHTML;
      for (const revision of [1, current.observationRevision, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1]) {
        const stale = clone(current); stale.observationRevision = revision; stale.pane.observation.process = 'running'; stale.pane.observation.work = 'unknown';
        check(`old/equal/invalid revision ${revision} entirely inert`, !view.update(stale) && host.innerHTML === domBefore && calls.length === 1);
      }
      const oldUnknown = clone(terminalFrame); oldUnknown.observationRevision = 1; oldUnknown.availability = 'uncertain';
      check('old observation loss cannot rewind terminal or pending', !view.update(oldUnknown) && host.innerHTML === domBefore);
      update(s => { s.availability = 'uncertain'; }); check('genuine new loss hides current terminal retains pending', field('state').includes('確認できません') && field('work') === '作業: 未確認' && calls.length === 1 && button('launch').disabled);
      const uncertainDOM = host.innerHTML;
      check('delayed old success cannot restore certainty', !view.update(terminalFrame) && host.innerHTML === uncertainDOM);
      update(s => { s.availability = 'available'; }); check('new successful reconfirmation of identical terminal recovers only observation', field('work') === '作業: 中断済み' && field('admission').includes('中断を確認中') && calls.length === 1);
      const recoveredDOM = host.innerHTML;
      check('old failed attempt frame after recovery inert', !view.update(oldUnknown) && host.innerHTML === recoveredDOM);
      const identical = clone(current); identical.observationRevision = current.observationRevision;
      check('duplicate recovered frame cannot clear pending', !view.update(identical) && host.innerHTML === recoveredDOM && calls.length === 1);
      update(s => { s.pane.current_run_id = 'run-2'; s.pane.observation.run_id = 'run-2'; s.pane.observation.process = 'running'; s.pane.observation.work = 'unknown'; s.pane.observation.evidence = 'unavailable'; });
      check('new run has distinct pending original run', field('target').includes('run-2') && field('admission').includes('run-1') && button('interrupt').disabled && calls.length === 1);
      check('correlated completed original does not declare new work complete', settle('completed') && field('work') === '作業: 未確認');
      for (const behavior of ['throw', 'reject', 'defer']) {
        reset(fixture(), behavior); button('interrupt').click(); await flush();
        if (behavior === 'defer') { resolves[0]({ phase: 'completed' }); await flush(); }
        check(`${behavior} delivery never completion or retry`, calls.length === 1 && button('interrupt').disabled && field('admission').includes(behavior === 'defer' ? '確認中' : '確認できません'));
        check(`${behavior} trusted settlement recovers`, settle('refused') && !button('interrupt').disabled);
      }
      reset(fixture(), 'defer'); choose(); launch(); const oldView = view, oldCall = calls[0], oldResolve = resolves[0];
      reset(fixture(), 'defer'); choose(); launch(); oldResolve({ phase: 'completed' }); await flush();
      check('replacement component ticket distinct old promise no effect', oldCall.ticket !== calls[0].ticket && button('launch').disabled && !oldView.settle(oldCall.ticket, oldCall.intent, 'completed'));
      for (const changed of ['instanceId', 'generation']) {
        reset(); choose(); open(); const next = clone(current); next[changed] = 'new'; next.observationRevision = 0;
        check(`different ${changed} retires despite lower revision`, !view.update(next) && !host.querySelector('dialog').open && button('launch').disabled && field('admission').includes('世代'));
        check(`retired ${changed} cannot resurrect`, !view.update(current) && button('launch').disabled && calls.length === 0);
      }
      reset(); button('interrupt').click(); const retained = calls[0]; update(s => { s.generation = 'new'; });
      check('retired pending response cannot release or reissue', !view.settle(retained.ticket, retained.intent, 'completed') && calls.length === 1 && button('interrupt').disabled);
      reset(); choose(); const malicious = '<img src=x onerror=alert(1)>\n<script>bad</script>'; update(s => { s.project.display_name = malicious; s.project.path = malicious; s.capabilities.providers[0].version = malicious; s.pane.observation.observed_at = malicious; });
      host.querySelectorAll('textarea')[0].value = malicious; open(); check('all dynamic text literal no XSS nodes', !host.querySelector('img,script,svg') && field('confirmation').includes(malicious) && field('observed-at').includes(malicious));
      reset(); choose(); const capturedButton = button('launch'), capturedHandler = capturedButton.onclick; view.dispose(); capturedHandler.call(capturedButton, new MouseEvent('click'));
      check('disposed handlers cannot submit and DOM removed', calls.length === 0 && host.children.length === 0);
      reset(); choose(); update(s => { s.observationRevision = Number.MAX_SAFE_INTEGER; }); const highestDOM = host.innerHTML;
      check('safe integer upper boundary accepted', !button('launch').disabled);
      const wrap = clone(current); wrap.observationRevision = 0; check('revision wrap cannot regress', !view.update(wrap) && host.innerHTML === highestDOM);
      reset(); choose(); host.querySelectorAll('textarea')[0].value = '狭幅確認';
      return { passed, failure: null };
    } catch (error) { return { passed, failure: String(error.message ?? error) }; }
  }, moduleText);
  checks.push(...tested.passed);
  if (tested.failure) throw new Error(tested.failure);
  const check = (name, okay) => { if (!okay) throw new Error(name); checks.push(name); };
  await page.getByRole('button', { name: '起動内容を確認', exact: true }).press('Enter');
  check('native Enter opens labelled dialog', await page.getByRole('dialog', { name: 'AIの起動内容を確認' }).isVisible());
  await page.keyboard.press('Escape');
  check('native Escape dismisses and returns focus', !await page.getByRole('dialog', { name: 'AIの起動内容を確認' }).isVisible() && await page.evaluate(() => document.activeElement?.dataset.action === 'launch'));
  await page.getByLabel('AIを選択', { exact: true }).focus();
  await page.keyboard.press('Tab');
  check('collapsed optional settings excluded from native Tab', await page.evaluate(() => document.activeElement?.tagName === 'SUMMARY'));
  await page.keyboard.press('Tab');
  check('Tab after closed details reaches launch not hidden textarea', await page.evaluate(() => document.activeElement?.dataset.action === 'launch'));
  await page.getByText('モデルと推論の設定（任意）', { exact: true }).press('Enter');
  await page.keyboard.press('Tab');
  check('expanded details native Tab reaches model', await page.evaluate(() => document.activeElement?.getAttribute('aria-label') === 'モデル（任意）'));
  await page.setViewportSize({ width: 640, height: 900 });
  await page.emulateMedia({ forcedColors: 'active' });
  check('narrow 200 percent equivalent no horizontal page overflow', await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  check('forced colors preserves native controls and text identity', await page.evaluate(() => matchMedia('(forced-colors: active)').matches && [...document.querySelectorAll('button')].filter(b => !b.closest('dialog')).every(b => b.getBoundingClientRect().width > 0 && b.textContent.length > 0)));
  await page.screenshot({ path: resolve(evidence, 'view-narrow-forced-colors.png'), fullPage: true });
  await page.emulateMedia({ forcedColors: 'none' });
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.screenshot({ path: resolve(evidence, 'view.png'), fullPage: true });
} catch (error) { failure = String(error.stack ?? error); }
finally {
  await browser?.close();
  const unchanged = inputs.every(x => hash(x.path) === x.sha256);
  if (!unchanged && failure === null) failure = 'Input bytes changed during verification';
  const result = { started, ended: new Date().toISOString(), status: failure === null ? 'passed' : 'failed', checks, count: checks.length, failure, inputs, input_bytes_unchanged: unchanged,
    scope: 'production pure view strict TypeScript and real headless DOM only', product_adopted: false,
    not_run: ['raw controller ordering and view coupling', 'real native GUI and provider CLI', 'mandatory full integrated checks and independent frozen review', 'parent adoption'] };
  writeFileSync(resolve(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n', 'utf8');
  process.stdout.write(JSON.stringify({ status: result.status, count: result.count, evidence, failure }) + '\n');
  if (failure !== null) process.exitCode = 1;
}
