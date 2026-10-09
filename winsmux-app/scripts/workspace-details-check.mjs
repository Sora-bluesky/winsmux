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
const started = new Date().toISOString();
const evidence = option('--evidence-dir', resolve(app, `../.evidence/rebuild/v0.38.0/TASK-874/view-${started.replace(/[:.]/g, '')}`));
mkdirSync(evidence, { recursive: true });
const source = resolve(app, 'src/workspace-ui/details.ts');
const generated = resolve(app, 'src/generated/workspace-contract.ts');
const hash = p => createHash('sha256').update(readFileSync(p)).digest('hex');
const inputs = [source, fileURLToPath(import.meta.url), generated].map(path => ({ path, sha256: hash(path), bytes: readFileSync(path).length }));
const enumValues = name => [...readFileSync(generated, 'utf8').split('\n').find(line => line.startsWith(`export type ${name} =`)).matchAll(/"([^"]+)"/g)].map(m => m[1]);
let checks = [], browser, failure = null;
try {
  const compiled = spawnSync(process.execPath, [require.resolve('typescript/bin/tsc'), '--noEmit', '--target', 'ES2020', '--module', 'ESNext', '--lib', 'ES2020,DOM,DOM.Iterable', '--moduleResolution', 'bundler', '--strict', '--noUnusedLocals', '--noUnusedParameters', '--noFallthroughCasesInSwitch', '--isolatedModules', source], { encoding: 'utf8' });
  writeFileSync(resolve(evidence, 'typescript.txt'), compiled.stdout + compiled.stderr, 'utf8');
  if (compiled.status !== 0) throw new Error(`TypeScript failed (${compiled.status}): ${compiled.stdout}${compiled.stderr}`);
  const bundled = await require('esbuild').build({ entryPoints: [source], bundle: true, write: false, format: 'esm', platform: 'browser', target: 'es2020', metafile: true });
  if (Object.keys(bundled.metafile.inputs).length !== 1) throw new Error('Pure view unexpectedly imports another runtime module');
  const moduleText = bundled.outputFiles[0].text;
  writeFileSync(resolve(evidence, 'details.js'), moduleText, 'utf8');
  browser = await require('playwright').chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route('**/*', route => route.abort());
  await page.setContent('<!doctype html><html lang="ja"><meta charset="utf-8"><body><button id="origin">詳細を表示</button><button id="other">別の操作</button><div id="details"></div></body></html>');
  const tested = await page.evaluate(async ({ moduleText, operationNames, errorCodes }) => {
    const { createDetails, createDetailsSession } = await import(URL.createObjectURL(new Blob([moduleText], { type: 'text/javascript' })));
    const passed = [], clone = v => structuredClone(v);
    const check = (name, condition) => { if (!condition) throw new Error(name); passed.push(name); };
    const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
    const lifetime = { instanceId: id(1), nonce: 'real-host-lifetime-a' };
    const artifact = (n = 10, path = '結果/資料.txt') => ({ artifact_id: id(n), project_id: id(2), relative_path: path, run_id: null, association: null });
    const fixture = () => ({ instanceId: id(1), generation: 'display-1', revision: 1, selectionRevision: 1, artifactsRevision: 1, availability: 'available',
      project: { project_id: id(2), path: 'C:\\synthetic-secret-path', display_name: '作業', root_state: 'verified' },
      artifacts: { registered: [artifact(), artifact(11, '変更.txt')], git_candidates: ['候補/非Gitも登録.md'], git_candidates_error: null }, selectedArtifactId: id(10), maxBytes: 1024 });
    const diagnostics = () => ({ protocol_version: 1, product_version: '0.38.0', connection_state: 'granted', capabilities: operationNames, failure_codes: errorCodes,
      argv: ['SYNTHETIC_ARGV_SECRET'], env: { TOKEN: 'SYNTHETIC_ENV_SECRET' }, stdout: 'SYNTHETIC_OUTPUT_SECRET', path: 'SYNTHETIC_PATH_SECRET', name: 'SYNTHETIC_NAME_SECRET', artifact_text: 'SYNTHETIC_BODY_SECRET', internal_id: 'SYNTHETIC_ID_SECRET' });
    const host = document.querySelector('#details'), origin = document.querySelector('#origin'), other = document.querySelector('#other');
    let view, session, current, calls, copies, behavior, copyBehavior, selectionBehavior, selections;
    const allCalls = [];
    const btn = action => host.querySelector(`[data-action="${action}"]`);
    const field = name => host.querySelector(`[data-field="${name}"]`).textContent;
    const mount = () => { view = createDetails(host, current, session, { selectionChanged: target => {
      selections.push(target);
      if (selectionBehavior === 'throw') throw new Error('SYNTHETIC_SELECTION_ERROR');
      if (selectionBehavior === 'reject') return Promise.reject(new Error('SYNTHETIC_SELECTION_ERROR'));
      if (selectionBehavior === 'reenter') view.update(clone(current));
      return { phase: 'completed', outcome: 'succeeded' };
    }, reserveMutation: () => true, submit: (intent, ticket) => {
      calls.push({ intent, ticket }); allCalls.push({ intent, ticket });
      if (behavior === 'throw') throw new Error('SYNTHETIC_RAW_ERROR');
      if (behavior === 'reject') return Promise.reject(new Error('SYNTHETIC_RAW_ERROR'));
      return { phase: 'completed', outcome: 'succeeded' };
    }, copy: text => { copies.push(text); if (copyBehavior === 'throw') throw new Error('SYNTHETIC_RAW_ERROR');
      if (copyBehavior === 'reject') return Promise.reject(new Error('SYNTHETIC_RAW_ERROR'));
      if (copyBehavior === 'defer') return new Promise(() => {});
      return copyBehavior === 'unconfirmed' ? undefined : true;
    } }, origin); };
    const reset = (s = fixture(), b = 'return') => {
      view?.dispose(); current = s; calls = []; copies = []; selections = []; behavior = b; copyBehavior = 'confirmed'; selectionBehavior = 'return';
      session = createDetailsSession(lifetime, crypto); mount();
    };
    const update = (change = () => {}) => {
      const s = clone(current); s.revision++; change(s);
      // Existing cases explicitly command changed selection/inventory values.
      // New stream-conflict cases below send their exact invalid frame directly.
      if (s.selectedArtifactId !== current.selectedArtifactId) s.selectionRevision++;
      if (JSON.stringify(s.artifacts) !== JSON.stringify(current.artifacts)) s.artifactsRevision++;
      current = s; return view.update(s);
    };
    const last = () => calls.at(-1);
    const click = action => { if (action === 'restore') btn('layout').click(); if (action === 'diagnostics-get' || action === 'copy') btn('diagnostics').click(); btn(action).click(); };
    const commit = result => { const c = last(); return view.commitProjection({ ...c, result }); };
    const terminal = (c, outcome = 'succeeded') => ({ kind: 'completed', operation: { operation_id: c.ticket, phase: 'completed', outcome, error_code: outcome === 'failed' ? 'runtime_failed' : null } });
    const settle = (c = last(), value = terminal(c), expectedPath = c.intent.source === 'git' ? c.intent.relativePath : '結果/資料.txt') => {
      if (c.intent.kind === 'register' && value.kind === 'completed' && value.operation.outcome === 'succeeded')
        session.prepareMutationPath(c.ticket, lifetime, c.intent, expectedPath);
      return session.settleMutation(c.ticket, lifetime, c.intent, value);
    };
    const resultRestore = () => ({ kind: 'restore', data: { restored: true, generation: 5 }, observedInstanceId: id(1), observedGeneration: 5,
      projects: [fixture().project], panes: [{ pane_id: id(30), project_id: id(2), path: 'C:\\synthetic', display_name: null, current_run_id: null, observation: null }] });
    const resultRead = (text = '日本語 <script>globalThis.unwanted=1</script> \u001b[31m') => ({ kind: 'read', data: { artifact_id: id(10), kind: 'text', size_bytes: 100, text, truncated: false } });
      const flush = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
    let problem = null;
    try {
      reset(); check('mount is effect free', calls.length === 0 && copies.length === 0 && field('body') === '');
      check('native Japanese named regions and status', [...host.querySelectorAll('section')].every(n => n.getAttribute('aria-label')) && host.querySelectorAll('[role="status"]').length === 5);
      check('only visible artifact pane', !host.querySelector('[data-pane="artifacts"]').hidden && host.querySelector('[data-pane="layout"]').hidden && host.querySelector('[data-pane="diagnostics"]').hidden);
      const emptyHost = fixture(); emptyHost.project = null; emptyHost.artifacts = null; emptyHost.selectedArtifactId = null;
      reset(emptyHost);
      check('fresh empty host exposes restore and diagnostics while artifact controls wait for project', !btn('restore').disabled && !btn('diagnostics-get').disabled && btn('pick').disabled && btn('read').disabled);
      click('diagnostics-get');
      check('empty host diagnostics uses null project and artifact target', last().intent.projectId === null && last().intent.artifactId === null && commit({ kind: 'diagnostics', data: diagnostics() }));
      click('restore'); const emptyRestore = clone(last());
      check('empty host restore is one explicit host operation', calls.length === 2 && emptyRestore.intent.projectId === null && emptyRestore.intent.artifactId === null && session.mutationPending());
      settle(emptyRestore); const restoredEmpty = resultRestore(); restoredEmpty.projects = []; restoredEmpty.panes = [];
      check('empty saved layout proves restore without old project or run', view.commitProjection({ ...emptyRestore, result: restoredEmpty }) && field('restore-state') === '配置のみ復元・未起動');
      reset();
      click('read'); click('read'); check('read one explicit intent captured budget and target', calls.length === 1 && last().intent.maxBytes === 1024 && last().intent.artifactId === id(10) && /^[0-9a-f-]{36}$/.test(last().ticket));
      check('callback completion is not content confirmation', field('body') === '' && session.readPending());
      check('safe text result commits', commit(resultRead()) && field('body') === resultRead().data.text && !host.querySelector('pre script') && globalThis.unwanted === undefined);
      check('duplicate read result inert', !commit(resultRead('old')) && field('body') === resultRead().data.text);
      reset(); btn('select-artifact').focus(); const focusedArtifact = document.activeElement;
      update(); check('same scope observation update preserves actual focused DOM button', document.activeElement === focusedArtifact);
      update(s => { s.artifacts.registered.reverse(); }); check('reordered same target list preserves actual focused DOM button', document.activeElement === focusedArtifact);
      focusedArtifact.click(); check('local explicit artifact selection preserves focus', document.activeElement === focusedArtifact && field('body') === '');
      for (const mode of ['read', 'diff']) {
        reset(); click(mode);
        const result = { kind: mode, data: { artifact_id: id(10), kind: 'text', text: '変更の差分 +日本語', truncated: true, ...(mode === 'read' ? { size_bytes: 9000 } : {}) } };
        check(`${mode} truncated explicitly displayed`, commit(result) && field('body') === result.data.text && field('content-state').includes('一部'));
        click(mode); check(`${mode} new request clears old text`, field('body') === '');
        check(`${mode} binary has no text`, commit({ kind: mode, data: { ...result.data, kind: 'binary', text: null, truncated: false } }) && field('body') === '' && field('content-state').includes('バイナリ'));
      }
      for (const code of ['target_not_found', 'root_changed', 'permission_denied', 'unsupported_file', 'runtime_failed', 'not_a_repository']) {
        reset(); click('read'); commit(resultRead('old body')); click('read');
        check(`read failure ${code} clears old body`, commit({ kind: 'error', code }) && field('body') === '' && !field('content-state').includes('表示しています'));
      }
      reset(); click('read'); const oldRead = last();
      update(s => { s.selectedArtifactId = id(11); });
      check('read lease retires on selection', !session.readPending() && field('body') === '' && !view.commitProjection({ ...oldRead, result: resultRead() }));
      update(s => { s.selectedArtifactId = id(10); }); check('returning selection cannot resurrect retired read', !view.commitProjection({ ...oldRead, result: resultRead() }) && field('body') === '');
      for (const change of [s => { s.project = null; s.artifacts = null; s.selectedArtifactId = null; }, s => { s.project.root_state = 'changed'; }, s => { s.project.root_state = 'unavailable'; }, s => { s.project.root_state = 'unknown'; }, s => { s.project.path = null; }, s => { s.availability = 'uncertain'; }, s => { s.availability = 'unavailable'; }]) {
        reset(); update(change); click('pick'); click('restore'); click('read'); click('diagnostics-get');
        const hostAvailable = current.availability === 'available';
        check('project-scoped target is never substituted while host-scoped restore remains available',
          btn('pick').disabled && btn('read').disabled && (hostAvailable
            ? calls.length === 1 && last().intent.kind === 'restore' && last().intent.projectId === null && last().intent.artifactId === null && btn('restore').disabled
            : calls.length === 0 && btn('restore').disabled));
      }
      for (const path of ['../x', '/x', 'a//b', 'a/./b', 'a\\b', 'C:x', 'NUL.txt', 'COM¹.txt', 'a.', 'a ', 'a\nsecret', 'a\u0085b']) {
        reset(); update(s => { s.artifacts.registered[0].relative_path = path; }); click('pick');
        check(`noncanonical relative path refused ${JSON.stringify(path)}`, calls.length === 0 && btn('pick').disabled && field('body') === '');
      }
      for (const change of [s => { s.artifacts.registered[1].artifact_id = id(10); }, s => { s.artifacts.registered[0].project_id = id(3); }, s => { s.artifacts.git_candidates.push(s.artifacts.git_candidates[0]); }, s => { s.selectedArtifactId = id(90); }, s => { s.artifacts.registered[0].association = 'caller_selected'; }, s => { s.artifacts.registered[0].run_id = id(40); }, s => { s.artifacts.git_candidates_error = 'runtime_failed'; }]) {
        reset(); update(change); check('invalid list fails as whole not partial adoption', host.querySelectorAll('[data-action="select-artifact"]').length === 0 && btn('read').disabled);
      }
      reset(); update(s => { s.artifacts.registered[0].association = 'caller_selected'; s.artifacts.registered[0].run_id = id(40); });
      check('caller selected association is not run success', field('target').includes(id(40)) && field('target').includes('実行成功の証拠ではありません'));
      reset(); click('pick'); const picker = last(); settle(picker, { kind: 'picker-cancelled' });
      check('confirmed picker cancellation has no read/register replay/execution', calls.length === 1 && !session.mutationPending() && field('body') === '');
      btn('register-git').click(); const git = last();
      check('Git candidate issues registration only', git.intent.kind === 'register' && git.intent.source === 'git' && git.intent.relativePath === '候補/非Gitも登録.md');
      settle(git); check('registered Git result explicit not auto read', commit({ kind: 'register', artifact: artifact(12, git.intent.relativePath) }) && calls.length === 2 && field('body') === '');
      reset();
      check('null git candidate error shows the candidate', !!btn('register-git') && host.querySelector('[data-field="git-candidates-error"]') === null);
      update(s => { s.artifacts.git_candidates_error = 'resource_exhausted'; });
      check('resource exhausted replaces Git candidates with the size reason', host.querySelector('[data-action="register-git"]') === null && !!host.querySelector(`[data-artifact-id="${id(10)}"]`)
        && field('git-candidates-error') === 'プロジェクトフォルダー全体が1 MiBを超えるため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。');
      update(s => { s.artifacts.git_candidates_error = 'unsupported_file'; });
      check('unsupported file replaces Git candidates with the link reason', host.querySelector('[data-action="register-git"]') === null && !!host.querySelector(`[data-artifact-id="${id(10)}"]`)
        && field('git-candidates-error') === 'プロジェクトフォルダーにジャンクション、シンボリックリンク、ハードリンク、または入れ子の .git があるため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。');
      reset(); click('pick'); const exactPicker = clone(last());
      check('picker receipt records one exact relative path before terminal', session.prepareMutationPath(exactPicker.ticket, lifetime, exactPicker.intent, '結果/資料.txt'));
      settle(exactPicker);
      check('view refuses successful registration for another picker path', !view.commitProjection({ ...exactPicker, result: { kind: 'register', artifact: artifact(12, '別/資料.txt') } })
        && !field('content-state').includes('登録を確認'));

      // Selection/observation family: actual A-to-B, immutable input, one host owner.
      const choose = n => host.querySelector(`[data-artifact-id="${id(n)}"]`).click();
      const selectedId = () => host.querySelector('[data-action="select-artifact"][aria-pressed="true"]')?.dataset.artifactId ?? null;
      for (const mode of ['read', 'diff']) for (const notice of ['return', 'throw', 'reject', 'reenter']) {
        reset(); selectionBehavior = notice;
        click(mode); const oldA = clone(last());
        choose(11); await flush();
        check(`${mode}/${notice} A to B retires A and notifies captured B once`, selections.length === 1 && Object.isFrozen(selections[0])
          && selections[0].artifactId === id(11) && selectedId() === id(11) && !session.readPending());
        check(`${mode}/${notice} exact received frame does not disable B`, !view.update(clone(current)) && !btn(mode).disabled && selectedId() === id(11));
        update(); click(mode); const b = clone(last());
        check(`${mode}/${notice} ordinary higher frame targets B`, b.intent.artifactId === id(11) && selections.length === 1 && field('body') === '');
        check(`${mode}/${notice} old A result cannot consume B lease`, !view.commitProjection({ ...oldA, result: { kind: mode, data: { artifact_id: id(10), kind: 'text', text: 'old A', truncated: false, size_bytes: 5 } } }) && session.readPending());
        check(`${mode}/${notice} B result is displayed safely`, view.commitProjection({ ...b, result: { kind: mode, data: { artifact_id: id(11), kind: 'text', text: 'confirmed B', truncated: false, size_bytes: 11 } } }) && field('body') === 'confirmed B');
        view.dispose(); mount();
        check(`${mode}/${notice} same session remount preserves B but not body or notification replay`, selectedId() === id(11) && field('body') === '' && field('diagnostics') === '' && selections.length === 1);
        click(mode); check(`${mode}/${notice} remount reads B despite controller retaining A`, last().intent.artifactId === id(11));
        update(s => { s.selectionRevision++; });
        check(`${mode}/${notice} explicit new selection command selects A and retires B`, selectedId() === id(10) && !session.readPending()
          && !view.commitProjection({ ...b, result: { kind: mode, data: { artifact_id: id(11), kind: 'text', text: 'late B', truncated: false, size_bytes: 6 } } }) && selections.length === 2);
      }
      for (const kind of ['register', 'restore']) for (const notice of ['throw', 'reject']) {
        reset(); selectionBehavior = notice; click(kind === 'register' ? 'pick' : 'restore'); const pending = clone(last());
        choose(11); await flush(); other.focus(); view.dispose(); mount();
        check(`${kind}/${notice} failed selection notification and remount preserve B and host mutation`, selectedId() === id(11) && session.mutationPending()
          && btn('pick').disabled && btn('restore').disabled && document.activeElement !== origin && field('body') === '' && field('diagnostics') === '');
        click('read'); check(`${kind}/${notice} read admission follows mutation scope`, kind === 'restore'
          ? calls.length === 1 && btn('read').disabled
          : calls.length === 2 && last().intent.artifactId === id(11));
        check(`${kind}/${notice} exact old terminal releases only latch`, settle(pending) && !session.mutationPending()
          && !view.commitProjection({ ...pending, result: kind === 'restore' ? resultRestore() : { kind: 'register', artifact: artifact() } })
          && selectedId() === id(11) && field('body') === '' && field('diagnostics') === '' && !field('restore-state').includes('未起動'));
      }
      reset(); choose(11); click('list');
      const projectedList = { registered: [artifact(), artifact(11, '変更.txt'), artifact(12, '追加.txt')], git_candidates: ['追加候補.txt'], git_candidates_error: null };
      check('correlated list overlay commits without changing received baseline', commit({ kind: 'list', data: projectedList }) && selectedId() === id(11));
      check('original repeated frame preserves list overlay and B', !view.update(clone(current)) && selectedId() === id(11)
        && host.querySelectorAll('[data-action="select-artifact"]').length === 3 && !btn('read').disabled);
      update(); view.dispose(); mount();
      check('ordinary higher frame and same-scope remount retain list overlay', selectedId() === id(11) && host.querySelectorAll('[data-action="select-artifact"]').length === 3);
      update(s => { s.artifacts = { registered: [artifact()], git_candidates: [], git_candidates_error: null }; s.artifactsRevision++; });
      check('fresh authoritative inventory removes B and never falls back to A', selectedId() === null && btn('read').disabled && field('body') === '' && field('diagnostics') === '');
      update(s => { s.selectionRevision++; });
      check('explicit external selection restores A only with new selection revision', selectedId() === id(10) && !btn('read').disabled);
      click('read'); const sameIdPending = clone(last()); update(s => { s.selectionRevision++; });
      check('explicit same ID selection command retires old read without duplicate notification', selectedId() === id(10) && !session.readPending()
        && !view.commitProjection({ ...sameIdPending, result: resultRead('retired same ID') }));
      for (const axis of ['selectionRevision', 'artifactsRevision']) for (const invalid of [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1, undefined]) {
        reset(); choose(11); click('pick'); const pending = clone(last());
        const wrong = clone(current); wrong.revision++; wrong[axis] = invalid;
        check(`${axis}/${String(invalid)} invalid stream fails closed without releasing mutation`, !view.update(wrong) && btn('read').disabled && session.mutationPending());
        view.dispose(); mount();
        check(`${axis}/${String(invalid)} remount does not clear fence using old A baseline`, btn('read').disabled && session.mutationPending());
        update(); click('read');
        check(`${axis}/${String(invalid)} fresh valid frame recovers B not A`, last().intent.artifactId === id(11) && selectedId() === id(11) && settle(pending));
      }
      for (const change of [s => { s.selectedArtifactId = id(11); }, s => { s.artifacts.registered.reverse(); }]) {
        reset(); choose(11); const conflicting = clone(current); conflicting.revision++; change(conflicting);
        check('same stream different values refuse entire frame', !view.update(conflicting) && btn('read').disabled && host.querySelectorAll('[data-action="select-artifact"]').length === 0);
      }
      reset(); choose(11); const beforeClose = selections.length; click('close');
      check('local B never returns focus to A origin and close never replays notification', document.activeElement === btn('close') && selections.length === beforeClose);

      // Inventory/selection family: command history, current inventory and leases share one host transition.
      const inventory = ids => ({ registered: ids.map(n => artifact(n, `${n}.txt`)), git_candidates: [], git_candidates_error: null });
      const receive = s => { const accepted = view.update(s); if (accepted) current = clone(s); return accepted; };
      const freshInventory = list => { const s = clone(current); s.revision++; s.artifactsRevision++; s.artifacts = list; return receive(s); };
      const readResult = (call, text = '現在の成果物') => ({ kind: call.intent.kind,
        data: { artifact_id: call.intent.artifactId, kind: 'text', text, truncated: false, size_bytes: 18 } });
      const artifactCount = () => host.querySelectorAll('[data-action="select-artifact"]').length;
      for (const mode of ['read', 'diff']) for (const selected of [10, 11]) for (const remaining of [[10, 11], [10], [11], []]) {
        const name = `${mode}/selected${selected}/inventory${remaining.join('-') || 'empty'}`;
        reset(); if (selected === 11) choose(11);
        click(mode); check(`${name} original body confirmed`, commit(readResult(last(), '旧本文')) && field('body') === '旧本文');
        click(mode); const old = clone(last());
        check(`${name} authoritative inventory alone accepted`, freshInventory(inventory(remaining)) && artifactCount() === remaining.length);
        const expected = remaining.includes(selected) ? id(selected) : null;
        check(`${name} preserves surviving selection or clears without fallback`, selectedId() === expected && field('body') === '' && field('diagnostics') === ''
          && !session.readPending() && btn(mode).disabled === (expected === null));
        check(`${name} old result cannot revive content`, !view.commitProjection({ ...old, result: readResult(old, '旧遅延本文') }) && field('body') === '');
        update(); view.dispose(); mount();
        check(`${name} repeats and remount retain inventory and derived selection`, artifactCount() === remaining.length && selectedId() === expected && field('body') === '' && current.selectedArtifactId === id(10));
        if (expected !== null) { click(mode); check(`${name} next request reads current target`, last().intent.artifactId === expected && commit(readResult(last()))); }
      }
      for (const mode of ['read', 'diff']) for (const notice of ['return', 'throw', 'reject', 'reenter']) {
        reset(); selectionBehavior = notice; choose(11); await flush();
        check(`${mode}/${notice} historic missing command A does not invalidate B`, freshInventory(inventory([11])) && selectedId() === id(11) && current.selectedArtifactId === id(10));
        view.dispose(); mount(); click(mode);
        check(`${mode}/${notice} B survives inventory and notification failure remount`, last().intent.artifactId === id(11) && commit(readResult(last())) && selections.length === 1);
      }
      for (const order of ['result-before-inventory', 'inventory-before-result']) {
        const s = fixture(); s.selectedArtifactId = id(11); reset(s); click('list'); const old = clone(last());
        if (order === 'result-before-inventory') check(`${order} old list initially correlated`, view.commitProjection({ ...old, result: { kind: 'list', data: inventory([10, 11]) } }));
        check(`${order} new authoritative B list accepted`, freshInventory(inventory([11])) && artifactCount() === 1 && selectedId() === id(11));
        click('read'); const now = clone(last());
        check(`${order} old list cannot resurrect A or consume new read`, !view.commitProjection({ ...old, result: { kind: 'list', data: inventory([10, 11]) } }) && artifactCount() === 1 && session.readPending());
        check(`${order} current read remains usable`, view.commitProjection({ ...now, result: readResult(now) }));
        check(`${order} exact repeated frame preserves latest B list`, !view.update(clone(current)) && artifactCount() === 1 && selectedId() === id(11));
        update(); view.dispose(); mount();
        check(`${order} ordinary notification and remount never resurrect A`, artifactCount() === 1 && selectedId() === id(11) && !host.querySelector(`[data-artifact-id="${id(10)}"]`));
      }
      reset(); choose(11); click('list');
      check('same-version overlay may remove historic command A', commit({ kind: 'list', data: inventory([11]) }) && selectedId() === id(11));
      update(); view.dispose(); mount(); check('same-version overlay excluding command A survives remount', artifactCount() === 1 && selectedId() === id(11));
      const absentCommand = clone(current); absentCommand.revision++; absentCommand.selectionRevision++;
      check('new selection must belong to effective overlay inventory', !receive(absentCommand) && btn('read').disabled && !session.readPending());
      const joint = clone(current); joint.revision++; joint.selectionRevision++; joint.artifactsRevision++; joint.artifacts = inventory([10, 11]);
      check('joint fresh selection and inventory restore A atomically', receive(joint) && selectedId() === id(10) && artifactCount() === 2);
      reset(); choose(11);
      check('null authoritative inventory retains historic command but clears current selection', freshInventory(null) && current.selectedArtifactId === id(10) && selectedId() === null && btn('read').disabled);
      check('returning historic A entry never auto selects A', freshInventory(inventory([10])) && selectedId() === null && artifactCount() === 1);
      const explicit = clone(current); explicit.revision++; explicit.selectionRevision++;
      check('fresh explicit command selects returning A', receive(explicit) && selectedId() === id(10));
      for (const chosen of [null, id(90), 'not-canonical']) {
        reset(); choose(11); const next = clone(current); next.revision++; next.selectionRevision++; next.selectedArtifactId = chosen;
        check(`fresh command ${String(chosen)} validates membership or null`, chosen === null ? receive(next) && selectedId() === null && !btn('pick').disabled : !receive(next) && btn('read').disabled);
      }
      for (const kind of ['list', 'read', 'diff', 'diagnostics']) {
        const s = fixture(); s.selectedArtifactId = id(11); reset(s);
        click(kind === 'diagnostics' ? 'diagnostics-get' : kind); const old = clone(last());
        const result = kind === 'list' ? { kind, data: clone(current.artifacts) } : kind === 'diagnostics' ? { kind, data: diagnostics() } : readResult(old);
        const unchanged = clone(current.artifacts);
        const hostRead = kind === 'diagnostics';
        check(`${kind} fresh inventory affects only project-scoped lease`, freshInventory(unchanged) && (hostRead
          ? session.readPending() && view.commitProjection({ ...old, result }) && field('diagnostics').includes('protocol_version')
          : !session.readPending() && !view.commitProjection({ ...old, result }) && field('body') === '' && field('diagnostics') === '' && btn('copy').disabled));
        click(kind === 'diagnostics' ? 'diagnostics-get' : kind);
        check(`${kind} replacement lease accepts current result`, view.commitProjection({ ...last(), result }));
      }
      for (const kind of ['register', 'restore']) for (const survives of [true, false]) {
        reset(); choose(11); click(kind === 'register' ? 'pick' : 'restore'); const pending = clone(last());
        click('read'); const oldRead = clone(last()); freshInventory(inventory(survives ? [11] : [10]));
        check(`${kind}/survives${survives} inventory preserves latch and blocks duplicate mutation`, session.mutationPending() && btn('pick').disabled && btn('restore').disabled && !session.readPending()
          && !view.commitProjection({ ...oldRead, result: readResult(oldRead) }));
        check(`${kind}/survives${survives} original terminal alone releases latch`, settle(pending, terminal(pending), '11.txt') && !session.mutationPending());
        const result = kind === 'restore' ? resultRestore() : { kind: 'register', artifact: artifact(11, '11.txt') };
        const acceptedAfterRead = view.commitProjection({ ...pending, result });
        check(`${kind}/survives${survives} newer read follows host versus project mutation scope`, kind === 'restore'
          ? acceptedAfterRead && field('restore-state').includes('未起動')
          : !acceptedAfterRead && !field('restore-state').includes('未起動') && !field('content-state').includes('登録を確認'));
        reset(); choose(11); click(kind === 'register' ? 'pick' : 'restore'); const noRead = clone(last());
        freshInventory(inventory(survives ? [11] : [10]));
        check(`${kind}/survives${survives} inventory alone keeps mutation latch`, session.mutationPending() && settle(noRead, terminal(noRead), '11.txt'));
        check(`${kind}/survives${survives} projection lifetime follows its scope`, view.commitProjection({ ...noRead, result }) === (kind === 'restore' || survives)
          && (kind === 'restore' || survives ? field(kind === 'restore' ? 'restore-state' : 'content-state').includes(kind === 'restore' ? '未起動' : '登録を確認') : !field('restore-state').includes('未起動')));
      }
      for (const mode of ['read', 'diff', 'diagnostics']) for (const reenter of ['inventory', 'selection', 'new-request']) {
        const s = fixture(); s.selectedArtifactId = id(11); reset(s); click(mode === 'diagnostics' ? 'diagnostics-get' : mode); const old = clone(last());
        let armed = true;
        const unsubscribe = session.subscribe(() => { if (!armed || session.readPending()) return; armed = false;
          if (reenter === 'inventory') freshInventory(inventory([11]));
          else if (reenter === 'selection') choose(10);
          else click(mode === 'diagnostics' ? 'diagnostics-get' : mode);
        });
        const result = mode === 'diagnostics' ? { kind: mode, data: diagnostics() } : readResult(old, '再入前の旧本文');
        const hostSurvives = mode === 'diagnostics' && reenter !== 'new-request';
        const painted = view.commitProjection({ ...old, result });
        check(`${mode}/${reenter} completion notification reentry respects intent scope`, hostSurvives
          ? painted && field('diagnostics').includes('protocol_version')
          : !painted && field('body') === '' && field('diagnostics') === '' && btn('copy').disabled);
        check(`${mode}/${reenter} reentry preserves current target and new lease`, reenter === 'new-request' ? session.readPending() && last().ticket !== old.ticket : !session.readPending() && selectedId() === id(reenter === 'selection' ? 10 : 11));
        unsubscribe();
      }
      reset(); choose(11); click('list'); const beforeAtomic = clone(last()); let atomicSeen = false, armedList = true;
      const unList = session.subscribe(() => { if (!armedList || session.readPending()) return; armedList = false;
        atomicSeen = session.selectionState().snapshot.artifacts.registered.map(a => a.artifact_id).join() === id(11);
        freshInventory(inventory([12]));
      });
      check('list applies inventory before completion notification reentry', view.commitProjection({ ...beforeAtomic, result: { kind: 'list', data: inventory([11]) } }) && atomicSeen);
      unList(); update(); view.dispose(); mount();
      check('list notification reentry retains newer C inventory without fallback or A revival', artifactCount() === 1 && !!host.querySelector(`[data-artifact-id="${id(12)}"]`) && selectedId() === null && btn('read').disabled);
      for (const kind of ['list', 'read', 'diff', 'diagnostics']) {
        const isolated = createDetailsSession(lifetime, crypto); const s = fixture(); s.selectedArtifactId = id(11); isolated.observeSelection(s);
        const owner = isolated.allocateViewId();
        const intent = { instanceId: s.instanceId, generation: s.generation, projectId: kind === 'diagnostics' ? null : s.project.project_id, artifactId: kind === 'diagnostics' ? null : id(11), kind, maxBytes: 1024 };
        const old = isolated.begin(intent, owner); s.revision++; s.artifactsRevision++; s.artifacts = inventory([11]); isolated.observeSelection(s);
        check(`${kind} host lease follows its inventory scope without any view`, old !== null && (kind === 'diagnostics'
          ? isolated.readPending() && isolated.finishRead(owner, old, intent)
          : !isolated.readPending() && !(kind === 'list' ? isolated.finishList(owner, old, intent, inventory([10, 11])) : isolated.finishRead(owner, old, intent))));
        const next = isolated.begin(intent, owner);
        check(`${kind} stale host result cannot consume newer lease`, next !== null && next !== old && !isolated.finishRead(owner, old, intent) && isolated.readPending());
        check(`${kind} host current result completes without view`, kind === 'list' ? isolated.finishList(owner, next, intent, inventory([11])) : isolated.finishRead(owner, next, intent));
      }
      reset(); click('list'); const invalidList = clone(last());
      check('matching malformed list consumes only its lease and retains inventory', !view.commitProjection({ ...invalidList, result: { kind: 'list', data: inventory([10, 10]) } }) && !session.readPending() && artifactCount() === 2 && selectedId() === id(10));

      // Original mutation family: both entry points and every retirement/terminal axis.
      for (const kind of ['register', 'restore']) for (const phase of ['awaiting', 'unknown']) for (const ending of ['succeeded', 'failed', 'refused']) {
        reset(); click(kind === 'register' ? 'pick' : 'restore'); const old = clone(last());
        if (phase === 'unknown') session.markUnknown(old.ticket);
        click(kind === 'register' ? 'restore' : 'pick'); check(`${kind}/${phase}/${ending} cross mutation blocked`, calls.length === 1);
        for (const project of [id(3), id(2)]) update(s => { s.project.project_id = project; s.artifacts.registered.forEach(a => { a.project_id = project; }); });
        view.dispose(); mount(); click('pick'); click('restore');
        check(`${kind}/${phase}/${ending} A B A remount preserves latch`, calls.length === 1 && session.mutationPending());
        other.focus(); const activeBefore = document.activeElement;
        const end = ending === 'refused' ? { kind: 'refused', code: 'permission_denied' } : terminal(old, ending);
        check(`${kind}/${phase}/${ending} exact late terminal releases once`, settle(old, end) && !session.mutationPending() && !settle(old, end));
        const oldResult = kind === 'restore' ? resultRestore() : { kind: 'register', artifact: artifact() };
        check(`${kind}/${phase}/${ending} late result has no old display or focus`, !view.commitProjection({ ...old, result: oldResult }) && field('body') === '' && field('diagnostics') === '' && !field('restore-state').includes('未起動') && document.activeElement === activeBefore);
        click(kind === 'register' ? 'pick' : 'restore'); click(kind === 'register' ? 'pick' : 'restore');
        check(`${kind}/${phase}/${ending} new explicit action admitted once`, calls.length === 2 && last().ticket !== old.ticket && session.mutationPending());
      }
      for (const kind of ['register', 'restore']) for (const retire of ['project', 'selection', 'generation', 'disconnect']) {
        reset(); click(kind === 'register' ? 'pick' : 'restore'); const old = clone(last());
        if (retire === 'project') { for (const p of [id(3), id(2)]) update(s => { s.project.project_id = p; s.artifacts.registered.forEach(a => { a.project_id = p; }); }); }
        if (retire === 'selection') { for (const a of [id(11), id(10)]) update(s => { s.selectedArtifactId = a; }); }
        if (retire === 'generation') { for (const g of ['display-2', 'display-1']) update(s => { s.generation = g; }); }
        if (retire === 'disconnect') { for (const a of ['unavailable', 'available']) update(s => { s.availability = a; }); }
        other.focus(); const settled = settle(old);
        const painted = view.commitProjection({ ...old, result: kind === 'restore' ? resultRestore() : { kind: 'register', artifact: artifact() } });
        const hostSurvives = kind === 'restore' && retire !== 'generation';
        check(`${kind} ${retire} late terminal follows host or project authority`, settled && painted === hostSurvives
          && document.activeElement === other && field('body') === '' && field('restore-state').includes('未起動') === hostSurvives);
      }
      for (const kind of ['register', 'restore']) {
        reset(); click(kind === 'register' ? 'pick' : 'restore'); const old = clone(last());
        const wrong = clone(old.intent); wrong.projectId = id(3);
        check(`${kind} wrong ticket target lifetime unissued terminal inert`, !session.settleMutation(id(99), lifetime, old.intent, terminal(old))
          && !session.settleMutation(old.ticket, lifetime, wrong, terminal(old))
          && !session.settleMutation(old.ticket, { ...lifetime, nonce: 'different' }, old.intent, terminal(old))
          && !session.settleMutation(old.ticket, lifetime, old.intent, terminal({ ...old, ticket: id(98) })) && session.mutationPending());
        for (const p of ['accepted', 'in_progress', 'unknown']) check(`${kind} ${p} not terminal`, !settle(old, { kind: 'completed', operation: { operation_id: old.ticket, phase: p, outcome: null, error_code: null } }) && session.mutationPending());
        for (const change of [s => { s.generation = 'display-2'; }, s => { s.availability = 'unavailable'; }, s => { s.availability = 'available'; }, s => { s.project.root_state = 'changed'; }, s => { s.project.root_state = 'verified'; }]) {
          update(change); click('pick'); click('restore'); check(`${kind} local epoch or disconnect preserves original mutation`, calls.length === 1 && session.mutationPending());
        }
        check(`${kind} wrong host retirement inert`, !session.retireHost({ ...lifetime, nonce: 'wrong' }) && session.mutationPending());
        const oldSession = session; check(`${kind} real host retirement ends only old session`, oldSession.retireHost(lifetime) && oldSession.isRetired());
        const newSession = createDetailsSession({ ...lifetime, nonce: 'new-real-host' }, crypto);
        check(`${kind} old terminal cannot mutate new lifetime`, !newSession.settleMutation(old.ticket, lifetime, old.intent, terminal(old)) && !newSession.mutationPending()
          && oldSession.begin(old.intent, 'old-view') === null && !oldSession.settleMutation(old.ticket, lifetime, old.intent, terminal(old)));
      }
      for (const kind of ['register', 'restore', 'read', 'diagnostics']) for (const b of ['throw', 'reject', 'return']) {
        reset(fixture(), b); click({ register: 'pick', restore: 'restore', read: 'read', diagnostics: 'diagnostics-get' }[kind]); await flush();
        check(`${kind} ${b} callback cannot prove completion`, calls.length === 1 && (kind === 'register' || kind === 'restore' ? session.mutationPending() : session.readPending())
          && field('body') === '' && field('diagnostics') === '' && !field('restore-state').includes('未起動') && !host.textContent.includes('SYNTHETIC_RAW_ERROR'));
      }
      reset(); click('restore'); check('restore acceptance awaiting actual proof', field('restore-state') === '復元を確認中' && !commit(resultRestore()));
      settle(); check('restore proves same host generation every pane unstarted', commit(resultRestore()) && field('restore-state') === '配置のみ復元・未起動');
      for (const [valid, change] of [[false, r => { r.observedGeneration = 4; }], [false, r => { r.observedInstanceId = id(99); }], [false, r => { r.panes[0].current_run_id = id(40); }], [false, r => { r.panes[0].observation = {}; }], [true, r => { r.projects[0].root_state = 'changed'; }], [true, r => { r.projects = []; r.panes = []; }], [false, r => { r.panes[0].project_id = id(99); }], [false, r => { r.panes.push(clone(r.panes[0])); }]]) {
        reset(); click('restore'); settle(); const r = resultRestore(); change(r);
        const applied = commit(r);
        check('restore proof accepts empty or changed roots while rejecting mismatched identity and running panes', applied === valid && field('restore-state').includes('未起動') === valid && calls.length === 1);
      }
      for (const code of ['persistence_failed', 'unsupported_version', 'root_changed', 'permission_denied']) {
        reset(); click('restore'); settle(last(), { kind: 'refused', code });
        check(`restore failure ${code} no fallback or reexecution`, commit({ kind: 'error', code }) && !field('restore-state').includes('未起動') && calls.length === 1);
      }
      reset(); click('diagnostics-get'); check('safe exact generated diagnostics enums', commit({ kind: 'diagnostics', data: diagnostics() }) && !btn('copy').disabled);
      click('copy'); await flush(); const projection = JSON.parse(copies[0]);
      check('diagnostics sharing exact five fields excludes all synthetic secrets', Object.keys(projection).sort().join() === ['protocol_version', 'product_version', 'connection_state', 'capabilities', 'failure_codes'].sort().join()
        && !copies[0].includes('SYNTHETIC') && !copies[0].includes('00000000') && !copies[0].includes('結果/') && field('diagnostics-state').includes('コピーしました'));
      for (const change of [d => { d.protocol_version = 2; }, d => { d.product_version = '0.38.0 '; }, d => { d.connection_state = 'unknown'; }, d => { d.capabilities = ['artifact.read', 'artifact.read']; }, d => { d.capabilities = ['secret-operation']; }, d => { d.failure_codes = ['runtime_failed', 'runtime_failed']; }, d => { d.failure_codes = ['SYNTHETIC_SECRET']; }, d => { d.capabilities = null; }]) {
        reset(); click('diagnostics-get'); const d = diagnostics(); change(d); commit({ kind: 'diagnostics', data: d }); click('copy');
        check('invalid diagnostic fields disable copy with no partial secret output', btn('copy').disabled && copies.length === 0 && field('diagnostics') === '');
      }
      for (const b of ['throw', 'reject', 'unconfirmed', 'defer']) {
        reset(); copyBehavior = b; click('diagnostics-get'); commit({ kind: 'diagnostics', data: diagnostics() }); click('copy'); click('copy'); await flush();
        check(`copy ${b} not fabricated success`, !field('diagnostics-state').includes('コピーしました') && !host.textContent.includes('SYNTHETIC_RAW_ERROR') && (b !== 'defer' || copies.length === 1));
      }
      reset(); click('diagnostics-get'); const oldDiag = last(); update(s => { s.availability = 'unavailable'; }); update(s => { s.availability = 'available'; });
      check('retired diagnostics cannot be copied after reconnect', !view.commitProjection({ ...oldDiag, result: { kind: 'diagnostics', data: diagnostics() } }) && btn('copy').disabled);
      reset(); const markup = host.innerHTML; current.artifacts.registered[0].relative_path = 'caller mutation';
      check('caller snapshot mutation inert without update', host.innerHTML === markup);
      reset(); click('read'); commit(resultRead('old content'));
      for (const rev of [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1]) {
        const s = fixture(); s.revision = rev; check(`invalid or old revision ${rev} fails closed`, !view.update(s) && field('body') === '' && btn('read').disabled);
      }
      update(); click('pick'); const pending = last(); const equalRevision = clone(current); equalRevision.project.display_name = 'different';
      check('same revision different bytes fails closed preserves mutation', !view.update(equalRevision) && session.mutationPending() && btn('copy').disabled);
      check('authoritative old mutation still settles after invalid frame', settle(pending) && !session.mutationPending());
      reset(); check('null invalid snapshot fails closed instead of throwing', !view.update(null) && btn('read').disabled);
      reset(); const missingProject = clone(current); missingProject.revision++; delete missingProject.project;
      check('missing project invalid snapshot fails closed instead of throwing', !view.update(missingProject) && btn('read').disabled);
      reset(); origin.focus(); click('close'); check('same selected opening origin gets safe focus', document.activeElement === origin && calls.length === 0 && host.querySelector('nav').hidden);
      reset(); update(s => { s.selectedArtifactId = id(11); }); click('close'); check('different selection never focuses old origin', document.activeElement === btn('close') && host.querySelector('nav').hidden);
      reset(); origin.hidden = true; click('close'); check('hidden origin never receives focus', document.activeElement === btn('close')); origin.hidden = false;
      reset(); origin.style.display = 'none'; click('close'); check('CSS hidden origin never receives focus', document.activeElement === btn('close')); origin.style.display = '';
      reset(); btn('read').focus(); btn('layout').click(); check('hidden pane focus safely moves to visible tab', document.activeElement === btn('layout') && host.querySelector('[data-pane="artifacts"]').hidden);

      // All six entries share one display authority while the actual mutation operation remains independent.
      const readonlyKinds = ['read', 'diff', 'list', 'diagnostics'];
      const shownResult = (call, label) => call.intent.kind === 'list' ? { kind: 'list', data: inventory([10, 11]) }
        : call.intent.kind === 'diagnostics' ? { kind: 'diagnostics', data: diagnostics() } : readResult(call, label);
      const mutationResult = call => call.intent.kind === 'restore' ? resultRestore() : { kind: 'register', artifact: artifact(10) };
      const confirmMutation = kind => kind === 'restore' ? field('restore-state').includes('未起動') : field('content-state').includes('登録を確認');
      const showReadOnly = (kind, label) => kind === 'list' ? artifactCount() === 2 && !confirmMutation('register') && !confirmMutation('restore')
        : kind === 'diagnostics' ? field('diagnostics').includes('protocol_version') && !confirmMutation('register') && !confirmMutation('restore')
          : field('body') === label && !confirmMutation('register') && !confirmMutation('restore');
      for (const kind of readonlyKinds) for (const nextKind of ['register', 'restore']) {
        reset(); click(kind === 'diagnostics' ? 'diagnostics-get' : kind); const old = clone(last());
        let armed = true, newerAccepted = false;
        const stop = session.subscribe(() => {
          if (!armed || session.readPending()) return; armed = false;
          click(nextKind === 'register' ? 'pick' : 'restore'); const newer = clone(last());
          newerAccepted = settle(newer) && view.commitProjection({ ...newer, result: mutationResult(newer) });
        });
        const oldAccepted = view.commitProjection({ ...old, result: shownResult(old, '古い本文') }); stop();
        check(`${kind} terminal then ${nextKind} synchronous confirmation keeps new display`, newerAccepted
          && oldAccepted === (kind === 'list') && confirmMutation(nextKind) && field('body') === '' && field('diagnostics') === '');
      }
      for (const kind of ['register', 'restore']) for (const nextKind of readonlyKinds) {
        reset(); click(kind === 'register' ? 'pick' : 'restore'); const old = clone(last());
        let armed = true, newerAccepted = false;
        const stop = session.subscribe(() => {
          if (!armed || session.mutationPending()) return; armed = false;
          click(nextKind === 'diagnostics' ? 'diagnostics-get' : nextKind); const newer = clone(last());
          newerAccepted = view.commitProjection({ ...newer, result: shownResult(newer, '新しい本文') });
        });
        const settled = settle(old), oldAccepted = view.commitProjection({ ...old, result: mutationResult(old) }); stop();
        check(`${kind} terminal then ${nextKind} synchronous result keeps new display`, settled && newerAccepted && !oldAccepted
          && showReadOnly(nextKind, '新しい本文'));
      }
      for (const kind of readonlyKinds) for (const nextKind of ['register', 'restore']) {
        reset(); let armed = true;
        const stop = session.subscribe(() => {
          if (!armed || !session.readPending()) return; armed = false;
          click(nextKind === 'register' ? 'pick' : 'restore');
        });
        click(kind === 'diagnostics' ? 'diagnostics-get' : kind); stop();
        const originalDeliveries = calls.filter(c => c.intent.kind === kind).length;
        const mutationCall = clone(last());
        check(`${kind} admission replaced by ${nextKind} frees undelivered slot`, originalDeliveries === 0
          && mutationCall.intent.kind === nextKind && !session.readPending() && session.mutationPending());
        check(`${kind} late mutation terminal leaves next readonly admissible`, settle(mutationCall) && !session.mutationPending()
          && (click('read'), calls.filter(c => c.intent.kind === 'read').length === 1));
      }
      for (const kind of ['register', 'restore']) for (const nextKind of readonlyKinds) {
        reset(); let armed = true, newer = null, newerAccepted = false;
        const stop = session.subscribe(() => {
          if (!armed || !session.mutationPending()) return; armed = false;
          click(nextKind === 'diagnostics' ? 'diagnostics-get' : nextKind); newer = clone(last());
          newerAccepted = view.commitProjection({ ...newer, result: shownResult(newer, '新しい本文') });
        });
        click(kind === 'register' ? 'pick' : 'restore'); stop();
        const original = calls.find(c => c.intent.kind === kind);
        check(`${kind} admission reentry delivers actual mutation once`, !!original && (kind === 'restore' || !!newer)
          && calls.filter(c => c.intent.kind === kind).length === 1 && session.mutationPending()
          && (kind === 'restore' ? !newerAccepted && calls.length === 1 : newerAccepted));
        const terminalApplied = settle(original), originalPainted = view.commitProjection({ ...original, result: mutationResult(original) });
        check(`${kind} admission reentry protects the legal scope after terminal`, kind === 'restore'
          ? terminalApplied && originalPainted && field('restore-state').includes('未起動')
          : terminalApplied && !originalPainted && showReadOnly(nextKind, '新しい本文'));
      }
      {
        const hostOnly = createDetailsSession(lifetime, crypto), initial = fixture(); hostOnly.observeSelection(initial);
        const firstOwner = hostOnly.allocateViewId(), secondOwner = hostOnly.allocateViewId();
        const intent = { instanceId: initial.instanceId, generation: initial.generation, projectId: initial.project.project_id, artifactId: id(10), kind: 'read', maxBytes: 1024 };
        const first = hostOnly.begin(intent, firstOwner);
        check('host refuses overlapping readonly without changing first lease', first !== null && hostOnly.begin(intent, secondOwner) === null
          && hostOnly.readPending() && hostOnly.mayProject(firstOwner, first, intent));
        check('host completion keeps exact latest request identity after lease release', hostOnly.finishRead(firstOwner, first, intent)
          && !hostOnly.readPending() && hostOnly.mayProject(firstOwner, first, intent));
        const newer = hostOnly.begin(intent, secondOwner);
        check('host new owner replaces completed first display identity', newer !== null && !hostOnly.mayProject(firstOwner, first, intent)
          && hostOnly.mayProject(secondOwner, newer, intent) && !hostOnly.finishRead(firstOwner, first, intent) && hostOnly.readPending());
        check('host wrong owner and ticket cannot consume current lease', !hostOnly.finishRead(firstOwner, newer, intent)
          && !hostOnly.finishRead(secondOwner, first, intent) && hostOnly.readPending());
        hostOnly.retireProjection(secondOwner);
        check('host retired owner cannot admit or display and releases its lease', !hostOnly.readPending() && !hostOnly.mayProject(secondOwner, newer, intent)
          && hostOnly.begin(intent, secondOwner) === null);
        const thirdOwner = hostOnly.allocateViewId(), third = hostOnly.begin(intent, thirdOwner);
        check('host remount owner admits without inheriting retired projection', third !== null && hostOnly.mayProject(thirdOwner, third, intent)
          && !hostOnly.mayProject(secondOwner, newer, intent));
        const mut = { instanceId: initial.instanceId, generation: initial.generation, projectId: initial.project.project_id, artifactId: id(10), kind: 'register', source: 'picker', relativePath: null };
        const mutationTicket = hostOnly.begin(mut, thirdOwner);
        check('host mutation admission retires dispatched readonly lease', mutationTicket !== null && !hostOnly.readPending()
          && !hostOnly.finishRead(thirdOwner, third, intent) && hostOnly.mutationPending());
        const nextRead = hostOnly.begin(intent, thirdOwner);
        check('host readonly may overlap mutation without releasing actual latch', nextRead !== null && hostOnly.mutationPending()
          && !hostOnly.mayProject(thirdOwner, mutationTicket, mut) && hostOnly.mayProject(thirdOwner, nextRead, intent));
        check('host original terminal releases latch but cannot project after newer read', hostOnly.settleMutation(mutationTicket, lifetime, mut, terminal({ ticket: mutationTicket }))
          && !hostOnly.mutationPending() && hostOnly.consumeMutationReceipt(thirdOwner, mutationTicket, mut) === null);
        check('host current readonly completes after old mutation terminal', hostOnly.finishRead(thirdOwner, nextRead, intent));
        const mutationAgain = hostOnly.begin(mut, thirdOwner);
        check('host receipt consumes once for the exact current owner and context', mutationAgain !== null
          && hostOnly.settleMutation(mutationAgain, lifetime, mut, terminal({ ticket: mutationAgain }))
          && hostOnly.consumeMutationReceipt(thirdOwner, mutationAgain, mut)?.ticket === mutationAgain
          && hostOnly.consumeMutationReceipt(thirdOwner, mutationAgain, mut) === null);
        check('host rejects unknown intent and malformed picker before allocating authority',
          hostOnly.begin({ ...mut, kind: 'unknown' }, thirdOwner) === null
          && hostOnly.begin({ ...mut, relativePath: 'outside.txt' }, thirdOwner) === null
          && !hostOnly.mutationPending() && !hostOnly.readPending());
        check('host rejects an unlisted Git candidate without changing the current request',
          hostOnly.begin({ ...mut, source: 'git', relativePath: 'outside.txt' }, thirdOwner) === null
          && hostOnly.mayProject(thirdOwner, mutationAgain, mut) && !hostOnly.mutationPending());
        const listedGit = { ...mut, source: 'git', relativePath: initial.artifacts.git_candidates[0] };
        const listedTicket = hostOnly.begin(listedGit, thirdOwner);
        check('host admits only the inventory-listed Git candidate', listedTicket !== null && hostOnly.mutationPending()
          && hostOnly.settleMutation(listedTicket, lifetime, listedGit, terminal({ ticket: listedTicket }))
          && !hostOnly.mutationPending());
        hostOnly.retireProjection(thirdOwner);
        check('host ended view cannot replay consumed receipt', hostOnly.consumeMutationReceipt(thirdOwner, mutationAgain, mut) === null);
      }
      for (const kind of ['read', 'register']) {
        reset(); let armed = true;
        const stop = session.subscribe(() => { if (!armed || (kind === 'read' ? !session.readPending() : !session.mutationPending())) return; armed = false; click('close'); });
        click(kind === 'read' ? 'read' : 'pick'); stop();
        const delivered = calls.filter(c => c.intent.kind === kind);
        check(`${kind} owner closes during admission without reviving display`, kind === 'read'
          ? delivered.length === 0 && !session.readPending() && host.querySelector('nav').hidden
          : delivered.length === 1 && session.mutationPending() && host.querySelector('nav').hidden);
        if (kind === 'register') check('closed mutation still requires its original terminal', settle(delivered[0]) && !session.mutationPending()
          && !view.commitProjection({ ...delivered[0], result: mutationResult(delivered[0]) }));
      }
      reset(); session.subscribe(() => { throw new Error('SYNTHETIC_NOTIFICATION_FAILURE'); });
      click('read'); check('notification failure cannot strand accepted read', calls.length === 1 && session.readPending() && commit(resultRead('通知失敗後も表示')) && field('body') === '通知失敗後も表示');
      check('all recorded intents limited to nonexecuting adopted responsibilities', allCalls.length > 0 && allCalls.every(c => ['register', 'list', 'read', 'diff', 'restore', 'diagnostics'].includes(c.intent.kind)));
      reset(); click('read'); commit(resultRead('成果物の内容\n<script>実行されません</script>\n日本語と絵文字🙂'));
    } catch (error) { problem = String(error.stack ?? error); }
    return { passed, failure: problem };
  }, { moduleText, operationNames: enumValues('OperationName'), errorCodes: enumValues('ErrorCode') });
  checks.push(...tested.passed);
  if (tested.failure) throw new Error(tested.failure);
  const check = (name, condition) => { if (!condition) throw new Error(name); checks.push(name); };
  await page.getByRole('button', { name: '成果物', exact: true }).focus();
  await page.keyboard.press('Tab'); await page.keyboard.press('Tab'); await page.keyboard.press('Tab');
  check('native Tab excludes hidden restore and diagnostics controls', await page.evaluate(() => document.activeElement?.dataset.action === 'pick'));
  await page.setViewportSize({ width: 640, height: 900 }); await page.emulateMedia({ forcedColors: 'active' });
  check('narrow layout remains within page', await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  check('forced colors retains visible native control names', await page.evaluate(() => matchMedia('(forced-colors: active)').matches && [...document.querySelectorAll('.workspace-details button')].filter(b => !b.closest('[hidden]')).every(b => b.textContent.length && b.getBoundingClientRect().width > 0)));
  await page.screenshot({ path: resolve(evidence, 'view-narrow-forced-colors.png'), fullPage: true });
  await page.emulateMedia({ forcedColors: 'none' }); await page.setViewportSize({ width: 1280, height: 900 });
  await page.screenshot({ path: resolve(evidence, 'view.png'), fullPage: true });
} catch (error) { failure = String(error.stack ?? error); }
finally {
  await browser?.close();
  const unchanged = inputs.every(x => hash(x.path) === x.sha256);
  if (!unchanged && failure === null) failure = 'Input bytes changed during verification';
  const result = { started, ended: new Date().toISOString(), status: failure === null ? 'passed' : 'failed', checks, count: checks.length, failure, inputs, input_bytes_unchanged: unchanged,
    scope: 'Production pure details view, host-lifetime session, strict TypeScript and real headless DOM', product_adopted: false,
    not_run: ['Actual Rust response validation and controller wiring', 'OS picker and native GUI', 'Integrated required checks, independent frozen candidate review and parent adoption', 'Public candidate TASK876/885 actual Windows journey'] };
  writeFileSync(resolve(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n', 'utf8');
  process.stdout.write(JSON.stringify({ status: result.status, count: result.count, evidence, failure }) + '\n');
  if (failure !== null) process.exitCode = 1;
}
