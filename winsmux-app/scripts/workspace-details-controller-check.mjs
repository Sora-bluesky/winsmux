import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const source = resolve(app, 'src/workspace-ui/details-controller.ts');
const viewSource = resolve(app, 'src/workspace-ui/details.ts');
const evidence = resolve(app, `../.evidence/rebuild/v0.38.0/TASK-874/controller-${new Date().toISOString().replace(/[:.]/g, '')}`);
mkdirSync(evidence, { recursive: true });
const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
let browser, names = [], failure = null;
try {
  const bundle = await require('esbuild').build({ entryPoints: [source], bundle: true, write: false, format: 'esm', platform: 'browser', target: 'es2020' });
  browser = await require('playwright').chromium.launch({ headless: true, channel: process.env.WINSMUX_TEST_BROWSER_CHANNEL || 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route('**/*', route => route.abort());
  await page.setContent('<!doctype html><html lang="ja"><meta charset="utf-8"><body><button id="origin">詳細を開く</button><div id="mount"></div></body></html>');
  names = await page.evaluate(async moduleText => {
    const { createDetailsController, driveRelative } = await import(URL.createObjectURL(new Blob([moduleText], { type: 'text/javascript' })));
    const passed = [], check = (name, fact) => { if (!fact) throw new Error(name); passed.push(name); };
    const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); await new Promise(resolve => setTimeout(resolve, 0)); };
    const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
    const host = id(1), project = id(2), artifactId = id(3);
    const projectRow = { project_id: project, path: 'C:\\root', display_name: '試験', root_state: 'verified' };
    const artifact = { artifact_id: artifactId, project_id: project, relative_path: 'note.txt', run_id: null, association: null };
    const artifactB = { ...artifact, artifact_id: id(33), relative_path: 'second.txt' };
    const diagnostics = { protocol_version: 1, product_version: '0.38.0', connection_state: 'unpaired', capabilities: ['diagnostics.get'], failure_codes: ['runtime_failed'] };
    const lifetime = { instanceId: host, nonce: 'stable-host-generation' };
    const empty = () => ({ instanceId: host, generation: 'pane-1', topologyRevision: 1, projects: { projects: [], selected_project_id: null }, panes: null, availability: 'available', busy: false });
    const withProject = () => ({ ...empty(), projects: { projects: [projectRow], selected_project_id: project } });
    const mount = document.querySelector('#mount'), origin = document.querySelector('#origin');
    const button = action => mount.querySelector(`[data-action="${action}"]`);
    const field = name => mount.querySelector(`[data-field="${name}"]`)?.textContent ?? '';
    const calls = [];
    let pane = empty(), picked = null, replyLost = false, nativeUnknown = false, failStatus = false, paneListMode = 'empty', malformedRestore = false, diagnosticsExtra = false, readDeleted = false, sentRegister = 0;
    let pickerMode = 'value', pickerRelease = null, directPath = null, directProject = null, registeredRows = [artifact], statusOutcome = 'succeeded', gitCandidatesError = null, omitGitCandidatesError = false;
    let deferStatus = false, statusRelease = null, refuseRegister = false, ambiguousMutation = null;
    let deferArtifactList = false, artifactListRelease = null, deferRead = false, readRelease = null;
    let deferProjectList = false, projectListRelease = null, publishOnRefresh = false;
    const response = (req, data) => ({ schema_version: 1, instance_id: host, operation_id: req.operation_id, accepted: true, topology_revision: pane.topologyRevision, event_seq: 0, result: { operation: req.operation, data }, error: null });
    const exchange = async req => {
      calls.push(structuredClone(req));
      switch (req.operation) {
        case 'diagnostics.get': return response(req, diagnosticsExtra ? { ...diagnostics, argv: 'SYNTHETIC_SECRET' } : diagnostics);
        case 'layout.restore': return ambiguousMutation ? { ...response(req, null), accepted: false, result: null,
          error: { code: ambiguousMutation, retryable: ambiguousMutation === 'in_progress', message: 'unconfirmed', target_id: null } }
          : response(req, { restored: true, generation: malformedRestore ? 'unknown' : 7 });
        case 'operation.get': {
          if (failStatus) { failStatus = false; throw new Error('reply_lost'); }
          if (deferStatus) await new Promise(resolve => { statusRelease = resolve; });
          return response(req, { operation: { operation_id: req.params.operation_id, phase: statusOutcome === 'pending' ? 'in_progress' : 'completed', outcome: statusOutcome === 'pending' ? null : statusOutcome, error_code: statusOutcome === 'failed' ? 'runtime_failed' : null } });
        }
        case 'project.list': {
          if (deferProjectList) await new Promise(resolve => { projectListRelease = resolve; });
          return response(req, pane.projects);
        }
        case 'pane.list': {
          if (paneListMode === 'empty') return response(req, { project_id: req.params.project_id, panes: [], root: null, selected_pane_id: null });
          if (paneListMode === 'five-stopped') {
            const ids = [7, 17, 18, 19, 20].map(id);
            const panes = ids.map(paneId => ({ pane_id: paneId, project_id: req.params.project_id, current_run_id: null, observation: null, display_name: null, path: null }));
            const root = ids.slice(1).reduce((first, paneId) => ({ kind: 'split', axis: 'horizontal', ratio: 0.5, first, second: { kind: 'leaf', pane_id: paneId } }), { kind: 'leaf', pane_id: ids[0] });
            return response(req, { project_id: req.params.project_id, panes, root, selected_pane_id: ids[0] });
          }
          const row = { pane_id: id(7), project_id: req.params.project_id, current_run_id: paneListMode === 'running' ? id(8) : null, observation: null, display_name: null, path: null };
          return response(req, { project_id: req.params.project_id, panes: [row], root: { kind: 'leaf', pane_id: id(7) }, selected_pane_id: id(7) });
        }
        case 'artifact.register': {
          sentRegister++;
          if (ambiguousMutation) return { ...response(req, null), accepted: false, result: null,
            error: { code: ambiguousMutation, retryable: ambiguousMutation === 'in_progress', message: 'unconfirmed', target_id: null } };
          if (refuseRegister) { refuseRegister = false; return { ...response(req, null), accepted: false, result: null, error: { code: 'permission_denied', retryable: false, message: 'denied', target_id: null } }; }
          if (nativeUnknown) throw 'transport_uncertain';
          if (replyLost) throw new Error('reply_lost');
          return response(req, { artifact: { ...artifact, artifact_id: req.params.relative_path === 'note.txt' ? artifactId : id(9), project_id: directProject ?? project, relative_path: directPath ?? req.params.relative_path } });
        }
        case 'artifact.list': {
          if (deferArtifactList) await new Promise(resolve => { artifactListRelease = resolve; });
          const data = { registered: registeredRows, git_candidates: ['git/changed.txt'], git_candidates_error: gitCandidatesError };
          if (omitGitCandidatesError) delete data.git_candidates_error;
          return response(req, data);
        }
        case 'artifact.read': {
          const value = req.params.artifact_id === artifactB.artifact_id ? 'B本文' : '試験本文';
          if (deferRead) await new Promise(resolve => { readRelease = resolve; });
          return readDeleted ? { ...response(req, null), accepted: false, result: null, error: { code: 'target_not_found', retryable: false, message: 'target not found', target_id: null } }
            : response(req, { artifact_id: req.params.artifact_id, kind: 'text', size_bytes: 9, text: value, truncated: false });
        }
        case 'artifact.diff': return response(req, { artifact_id: artifactId, kind: 'binary', text: null, truncated: false });
        default: throw new Error(`unexpected ${req.operation}`);
      }
    };
    const ownerKey = { instanceId: host, ownerGeneration: '1' };
    const port = () => ({ ownerKey, exchange, recover(origin, request) {
      if (origin.instanceId !== ownerKey.instanceId || origin.ownerGeneration !== ownerKey.ownerGeneration) throw new Error('owner_mismatch');
      return this.exchange(request);
    }, pane: () => pane, refreshPane: async () => { if (publishOnRefresh) controller.updatePane(pane); return pane; }, maxBytes: () => 1024, pickFile: () => {
      if (pickerMode === 'throw') throw new Error('picker_failed');
      if (pickerMode === 'reject') return Promise.reject('transport_uncertain');
      if (pickerMode === 'deferred') return new Promise(resolve => { pickerRelease = resolve; });
      return Promise.resolve(picked);
    }, copy: async () => true });
    const bind = controller => controller.bind(port());
    let controller = createDetailsController(lifetime, crypto); bind(controller); let dispose = controller.open(mount, origin);
    check('empty host admits host restore and diagnostics but refuses all artifact controls', !button('restore').disabled && !button('diagnostics-get').disabled && button('pick').disabled && button('read').disabled);
    button('diagnostics').click(); button('diagnostics-get').click(); await flush();
    check('empty host diagnostics reports only explicit safe fields', field('diagnostics').includes('protocol_version') && !field('diagnostics').includes('SYNTHETIC_SECRET') && calls.filter(c => c.operation === 'diagnostics.get').length === 1);
    const emptyDiagnostics = field('diagnostics'), emptySelection = controller.session.selectionState();
    controller.updatePane(empty());
    check('empty host same-scope observation preserves diagnostics and copy', field('diagnostics') === emptyDiagnostics && !button('copy').disabled
      && controller.session.selectionState().epoch === emptySelection.epoch
      && controller.session.selectionState().snapshot.selectionRevision === emptySelection.snapshot.selectionRevision);
    pane = { ...empty(), projects: { projects: [{ ...projectRow, project_id: id(4) }], selected_project_id: null } };
    controller.updatePane(pane);
    const unselectedDiagnostics = field('diagnostics'), unselectedSelection = controller.session.selectionState();
    controller.updatePane(pane);
    check('unselected project-list host repeats without external selection or diagnostics loss', unselectedDiagnostics === emptyDiagnostics
      && field('diagnostics') === emptyDiagnostics && !button('copy').disabled
      && controller.session.selectionState().epoch === unselectedSelection.epoch
      && controller.session.selectionState().snapshot.selectionRevision === unselectedSelection.snapshot.selectionRevision);
    pane = empty(); controller.updatePane(pane);
    diagnosticsExtra = true; button('diagnostics-get').click(); await flush();
    check('unexpected diagnostics field never reaches shared view or copy', field('diagnostics') === '' && button('copy').disabled && !mount.textContent.includes('SYNTHETIC_SECRET'));
    diagnosticsExtra = false;
    button('layout').click(); button('restore').click(); await flush();
    check(`empty host restore verifies terminal and stable complete empty snapshot without a launch ${JSON.stringify({ state: field('restore-state'), operations: calls.map(c => c.operation) })}`, field('restore-state') === '配置のみ復元・未起動' && calls.filter(c => c.operation === 'layout.restore').length === 1 && calls.filter(c => c.operation === 'project.list').length === 2 && !calls.some(c => c.operation.includes('launch')));
    deferProjectList = true; publishOnRefresh = true;
    button('restore').click(); await flush();
    check('old empty-host restore reaches deferred topology confirmation', !!projectListRelease);
    button('diagnostics').click(); button('diagnostics-get').click(); await flush();
    const restoreDiagnostics = field('diagnostics'), restoreSelection = controller.session.selectionState();
    deferProjectList = false; projectListRelease(); await flush();
    check('old empty-host restore refresh preserves newer diagnostics and copy', field('diagnostics') === restoreDiagnostics
      && restoreDiagnostics.includes('product_version') && !button('copy').disabled
      && controller.session.selectionState().epoch === restoreSelection.epoch);
    publishOnRefresh = false; projectListRelease = null;
    paneListMode = 'stopped'; pane = { ...empty(), topologyRevision: 2, projects: { projects: [{ ...projectRow, project_id: id(4), path: 'C:\\different', root_state: 'unavailable' }], selected_project_id: null } }; controller.updatePane(pane);
    button('restore').click(); await flush();
    check('restore accepts different saved project with unavailable root and stopped pane', field('restore-state') === '配置のみ復元・未起動' && calls.filter(c => c.operation === 'pane.list').at(-1).params.project_id === id(4));
    paneListMode = 'running'; button('restore').click(); await flush();
    check('restore cannot claim completion when any restored pane still names a run', !field('restore-state').includes('未起動') && field('restore-state').includes('未確認'));
    paneListMode = 'five-stopped'; button('restore').click(); await flush();
    check('five stopped panes stay restorable', field('restore-state') === '配置のみ復元・未起動');
    paneListMode = 'stopped'; malformedRestore = true; button('restore').click(); await flush();
    check('lost restore generation payload cannot be reconstructed from terminal alone', !field('restore-state').includes('未起動') && field('restore-state').includes('未確認'));
    malformedRestore = false;
    paneListMode = 'empty';
    pane = withProject(); controller.updatePane(pane);
    button('diagnostics').click(); button('diagnostics-get').click(); await flush();
    const selectedProjectRevision = controller.session.selectionState().snapshot.selectionRevision;
    pane = { ...empty(), projects: { projects: [{ ...projectRow, project_id: id(4) }], selected_project_id: null } };
    controller.updatePane(pane);
    const unselectedProjectState = controller.session.selectionState();
    check('project to unselected invalidates prior diagnostics once', unselectedProjectState.snapshot.selectionRevision === selectedProjectRevision + 1
      && field('diagnostics') === '' && button('copy').disabled);
    controller.updatePane(pane);
    check('repeated unselected observation does not create another selection transition', controller.session.selectionState().snapshot.selectionRevision === unselectedProjectState.snapshot.selectionRevision
      && controller.session.selectionState().epoch === unselectedProjectState.epoch);
    button('diagnostics').click(); button('diagnostics-get').click(); await flush();
    pane = withProject(); controller.updatePane(pane);
    const selectedAgainState = controller.session.selectionState();
    check('unselected to project invalidates prior diagnostics once', selectedAgainState.snapshot.selectionRevision === unselectedProjectState.snapshot.selectionRevision + 1
      && field('diagnostics') === '' && button('copy').disabled);
    controller.updatePane(pane);
    check('repeated selected project observation keeps its selection revision', controller.session.selectionState().snapshot.selectionRevision === selectedAgainState.snapshot.selectionRevision
      && controller.session.selectionState().epoch === selectedAgainState.epoch);
    pane = withProject(); controller.updatePane(pane); dispose(); dispose = controller.open(mount, origin);
    const beforeCancel = sentRegister; picked = null; button('pick').click(); await flush();
    check('cancelled picker ends locally with an attributed notice and no Rust mutation', sentRegister === beforeCancel && !controller.session.mutationPending()
      && field('content-state').includes('ファイル選択を取り消しました'));
    picked = 'C:\\outside\\secret.txt'; button('pick').click(); await flush();
    check('outside picker path never reaches Rust registration', sentRegister === 0 && !controller.session.mutationPending());
    check('drive path mapping accepts only exact descendant', driveRelative('C:\\root', 'C:\\root\\note.txt') === 'note.txt'
      && driveRelative('C:\\root', 'C:\\rooted\\note.txt') === null && driveRelative('C:\\root', 'D:\\root\\note.txt') === null
      && driveRelative('C:\\root', '\\\\server\\share\\note.txt') === null && driveRelative('C:\\root', 'C:\\root\\..\\secret.txt') === null);
    check('normal and Rust verbatim drive paths map the same exact descendant', driveRelative('C:\\root', 'C:\\root\\note.txt') === 'note.txt'
      && driveRelative('\\\\?\\C:\\root', 'C:\\root\\note.txt') === 'note.txt'
      && driveRelative('\\\\?\\C:\\root', '\\\\?\\C:\\root\\note.txt') === 'note.txt'
      && driveRelative('C:\\root', '\\\\?\\C:\\root\\note.txt') === 'note.txt');
    check('verbatim mapping rejects other drive, UNC, device, volume and outside roots', driveRelative('\\\\?\\C:\\root', 'D:\\root\\note.txt') === null
      && driveRelative('\\\\?\\C:\\root', '\\\\server\\share\\note.txt') === null
      && driveRelative('\\\\?\\C:\\root', '\\\\?\\UNC\\server\\share\\note.txt') === null
      && driveRelative('\\\\?\\C:\\root', '\\\\.\\C:\\root\\note.txt') === null
      && driveRelative('\\\\?\\C:\\root', '\\\\?\\Volume{1234}\\note.txt') === null
      && driveRelative('\\\\?\\C:\\root', 'C:\\rooted\\note.txt') === null);
    pickerMode = 'throw'; button('pick').click(); await flush();
    check('picker synchronous failure ends original latch locally without workspace send', sentRegister === 0 && !controller.session.mutationPending() && !controller.session.isTransportBlocked());
    pickerMode = 'reject'; button('pick').click(); await flush();
    check('picker rejection named transport_uncertain is local because no request was sent', sentRegister === 0 && !controller.session.mutationPending() && !controller.session.isTransportBlocked());
    pickerMode = 'deferred'; button('pick').click(); await flush();
    pane = { ...withProject(), projects: { projects: [{ ...projectRow, project_id: id(4) }], selected_project_id: id(4) } }; controller.updatePane(pane);
    pane = withProject(); controller.updatePane(pane); pickerRelease('C:\\root\\note.txt'); await flush();
    check('picker A to B to A transition releases original latch and never sends', sentRegister === 0 && !controller.session.mutationPending());
    pickerMode = 'deferred'; button('pick').click(); await flush();
    pane = { ...withProject(), projects: { projects: [{ ...projectRow, root_state: 'unavailable' }], selected_project_id: project } }; controller.updatePane(pane);
    pane = withProject(); controller.updatePane(pane); pickerRelease('C:\\root\\note.txt'); await flush();
    check('picker verified to unavailable to verified transition never sends', sentRegister === 0 && !controller.session.mutationPending());
    pickerMode = 'value';
    picked = 'C:\\root\\note.txt'; button('pick').click(); await flush();
    check('picker registers once after matching project root and terminal', sentRegister === 1 && !controller.session.mutationPending() && field('content-state').includes('登録を確認'));
    button('list').click(); await flush();
    check('correlated inventory exposes registered artifact', !!mount.querySelector(`[data-artifact-id="${artifactId}"]`));
    button('register-git').click(); await flush();
    check('Git candidate registration sends only its relative path without picker or launch', sentRegister === 2
      && calls.filter(c => c.operation === 'artifact.register').at(-1).params.relative_path === 'git/changed.txt' && field('content-state').includes('登録を確認'));
    directPath = 'other.txt'; button('list').click(); await flush(); button('register-git').click(); await flush();
    check('direct response for another path never reports registration success or recovers it from inventory', sentRegister === 3
      && !field('content-state').includes('登録を確認') && !controller.session.mutationPending());
    directPath = null;
    gitCandidatesError = 'resource_exhausted'; button('list').click(); await flush();
    check('resource exhausted keeps the registered artifact and states the size limit', !!mount.querySelector(`[data-artifact-id="${artifactId}"]`)
      && field('git-candidates-error') === 'プロジェクトフォルダー全体が大きすぎる（1 MiBを超えるなど）ため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。'
      && !mount.querySelector('[data-action="register-git"]'));
    gitCandidatesError = 'unsupported_file'; button('list').click(); await flush();
    check('unsupported file keeps the registered artifact and states the link limit', !!mount.querySelector(`[data-artifact-id="${artifactId}"]`)
      && field('git-candidates-error') === 'プロジェクトフォルダーに取り込めないもの（ジャンクション、シンボリックリンク、ハードリンク、入れ子の .git など）があるため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。'
      && !mount.querySelector('[data-action="register-git"]'));
    gitCandidatesError = 'runtime_failed'; button('list').click(); await flush();
    check('unknown git candidate error is refused', field('content-state').includes('確認できません'));
    gitCandidatesError = null; button('list').click(); await flush();
    check('null git candidate error shows candidates again', !!button('register-git') && field('git-candidates-error') === '');
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click(); button('read').click(); await flush();
    check('selected artifact reads text without launching', field('body') === '試験本文' && !calls.some(c => c.operation.includes('launch')));
    button('diff').click(); await flush();
    check('binary diff refuses body display', field('body') === '' && field('content-state').includes('バイナリ'));
    readDeleted = true; button('read').click(); await flush();
    check('deleted artifact refusal retains exact Rust code without stale body', field('body') === '' && field('content-state').includes('対象が見つかりません'));
    readDeleted = false;
    dispose(); controller.retire(); mount.replaceChildren();
    controller = createDetailsController({ instanceId: host, nonce: 'ready-recovery' }, crypto); bind(controller); dispose = controller.open(mount, origin);
    replyLost = true; picked = 'C:\\root\\note.txt'; button('pick').click(); await flush();
    check('Ready reply loss reconciles original operation ID and unique registered result without resend', sentRegister === 4 && !controller.session.mutationPending()
      && field('content-state').includes('登録を確認') && calls.some(c => c.operation === 'operation.get' && c.params.operation_id === calls.filter(x => x.operation === 'artifact.register').at(-1).operation_id));
    dispose(); controller.retire(); mount.replaceChildren();
    controller = createDetailsController({ instanceId: host, nonce: 'same-host-rebind' }, crypto); bind(controller); dispose = controller.open(mount, origin);
    failStatus = true; button('pick').click(); await flush();
    check('interrupted Ready reconciliation retains original register latch', controller.session.mutationPending() && sentRegister === 5);
    controller.disconnect(); bind(controller); await flush();
    check('same-host rebind queries original ticket and leaves its result unconfirmed without resend', !controller.session.mutationPending() && sentRegister === 5
      && field('content-state').includes('未確認') && !field('content-state').includes('登録を確認')
      && calls.some(c => c.operation === 'operation.get' && c.params.operation_id === calls.filter(x => x.operation === 'artifact.register').at(-1).operation_id));
    dispose(); controller.retire(); mount.replaceChildren();
    controller = createDetailsController({ instanceId: host, nonce: 'native-unknown' }, crypto); bind(controller); dispose = controller.open(mount, origin);
    replyLost = false; nativeUnknown = true; const priorQueries = calls.filter(c => c.operation === 'operation.get').length;
    button('pick').click(); await flush();
    check('native Unknown holds original mutation and blocks new controls without polling or resend', controller.session.isTransportBlocked() && controller.session.mutationPending()
      && button('pick').disabled && button('restore').disabled && sentRegister === 6 && calls.filter(c => c.operation === 'operation.get').length === priorQueries
      && field('admission').includes('復旧操作を受け付けられません'));
    bind(controller); await controller.refresh(); await flush();
    check('same-host rebind cannot clear native Unknown latch', controller.session.isTransportBlocked() && controller.session.mutationPending() && sentRegister === 6);
    dispose(); controller.retire();
    mount.replaceChildren(); pane = withProject(); pickerMode = 'deferred'; nativeUnknown = false;
    controller = createDetailsController({ instanceId: host, nonce: 'picker-port-rebind' }, crypto);
    const stablePort = port(); controller.bind(stablePort); dispose = controller.open(mount, origin);
    const beforeRebind = sentRegister, beforeRebindQuery = calls.filter(c => c.operation === 'operation.get').length;
    button('pick').click(); await flush(); controller.bind(stablePort); pickerRelease('C:\\root\\note.txt'); await flush();
    check('same object port rebind locally ends preparing picker without send or status query', sentRegister === beforeRebind
      && calls.filter(c => c.operation === 'operation.get').length === beforeRebindQuery && !controller.session.mutationPending());
    button('pick').click(); await flush(); controller.disconnect(); pickerRelease('C:\\root\\note.txt'); await flush();
    check('disconnect locally ends preparing picker and delayed result cannot send', sentRegister === beforeRebind && !controller.session.mutationPending());
    controller.bind(stablePort); pickerMode = 'value'; picked = 'C:\\root\\note.txt';
    pane = { ...withProject(), projects: { projects: [{ ...projectRow, path: '\\\\?\\C:\\root' }], selected_project_id: project } }; controller.updatePane(pane);
    button('pick').click(); await flush();
    check('actual Rust verbatim root admits normal picker path with exact result', sentRegister === beforeRebind + 1
      && calls.filter(c => c.operation === 'artifact.register').at(-1).params.relative_path === 'note.txt' && field('content-state').includes('登録を確認'));
    replyLost = true; registeredRows = []; button('pick').click(); await flush();
    check('lost direct response with zero matching inventory cannot claim success', sentRegister === beforeRebind + 2
      && !controller.session.mutationPending() && !field('content-state').includes('登録を確認'));
    registeredRows = [artifact, { ...artifact, artifact_id: id(8) }]; button('pick').click(); await flush();
    check('lost direct response with duplicate path inventory cannot claim success', sentRegister === beforeRebind + 3
      && !controller.session.mutationPending() && !field('content-state').includes('登録を確認'));
    replyLost = false; registeredRows = [artifact]; directProject = id(4); button('pick').click(); await flush();
    check('direct response for another project cannot claim success through inventory', sentRegister === beforeRebind + 4
      && !controller.session.mutationPending() && !field('content-state').includes('登録を確認'));
    directProject = null; replyLost = true; statusOutcome = 'pending'; button('pick').click(); await flush();
    check('pending original operation retains latch and sends no duplicate', sentRegister === beforeRebind + 5 && controller.session.mutationPending());
    statusOutcome = 'failed'; await controller.refresh(); await flush();
    check('terminal failure on original operation releases latch without success', !controller.session.mutationPending() && !field('content-state').includes('登録を確認')
      && sentRegister === beforeRebind + 5);
    dispose(); controller.retire();
    const freshReentry = (name, admission) => {
      mount.replaceChildren(); pane = withProject(); pickerMode = 'value'; picked = 'C:\\root\\note.txt';
      deferStatus = false; statusRelease = null; replyLost = false; nativeUnknown = false; statusOutcome = 'succeeded';
      directPath = null; directProject = null; registeredRows = [artifact]; refuseRegister = false; ambiguousMutation = null;
      deferArtifactList = false; artifactListRelease = null; deferRead = false; readRelease = null;
      deferProjectList = false; projectListRelease = null; publishOnRefresh = false;
      gitCandidatesError = null; omitGitCandidatesError = false;
      controller = createDetailsController({ instanceId: host, nonce: `reentry-${name}` }, crypto, admission);
      bind(controller); dispose = controller.open(mount, origin);
    };
    for (const kind of ['succeeded', 'failed', 'picker-cancelled', 'local-refused', 'direct-refused']) {
      freshReentry(kind);
      const before = sentRegister;
      if (kind === 'succeeded' || kind === 'failed') { deferStatus = true; statusOutcome = kind; }
      if (kind === 'picker-cancelled') picked = null;
      if (kind === 'local-refused') picked = 'D:\\outside\\note.txt';
      if (kind === 'direct-refused') refuseRegister = true;
      let armNext = kind !== 'succeeded' && kind !== 'failed', nextAccepted = 0;
      const stop = controller.session.subscribe(() => {
        if (!armNext || controller.session.mutationPending()) return;
        armNext = false; nextAccepted++;
        picked = 'C:\\root\\again.txt'; statusOutcome = 'succeeded'; deferStatus = false;
        button('pick')?.click();
      });
      button('pick').click(); await flush();
      if (kind === 'succeeded' || kind === 'failed') {
        check(`${kind} first operation is sent before its status is released`, !!statusRelease && sentRegister === before + 1 && controller.session.mutationPending());
        armNext = true; deferStatus = false; statusRelease(); await flush();
      }
      const expectedSends = kind === 'picker-cancelled' || kind === 'local-refused' ? 1 : 2;
      check(`${kind} notification cannot erase the next accepted picker flight`, nextAccepted === 1 && sentRegister === before + expectedSends
        && !controller.session.mutationPending() && field('content-state').includes('登録を確認'));
      stop(); dispose(); controller.retire();
    }
    freshReentry('old-register-after-read');
    button('list').click(); await flush();
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click();
    deferStatus = true;
    button('pick').click(); await flush();
    check('register A has a pending terminal query before read B', !!statusRelease && controller.session.mutationPending());
    button('read').click(); await flush();
    check('read B completes while register A is pending', field('body') === '試験本文');
    deferStatus = false; statusRelease(); await flush();
    check('old register A cannot erase the newer read B body', field('body') === '試験本文' && field('content-state').includes('本文を表示'));
    dispose(); controller.retire();
    freshReentry('old-register-after-diagnostics');
    deferStatus = true;
    button('pick').click(); await flush();
    check('register A waits for terminal before diagnostics B', !!statusRelease && controller.session.mutationPending());
    button('diagnostics').click(); button('diagnostics-get').click(); await flush();
    const newerDiagnostics = field('diagnostics'), newerContentState = field('content-state');
    check('diagnostics B completes while register A is pending', newerDiagnostics.includes('product_version'));
    deferStatus = false; statusRelease(); await flush();
    check('old register A cannot change the newer diagnostics projection', field('diagnostics') === newerDiagnostics
      && field('content-state') === newerContentState && !controller.session.mutationPending());
    dispose(); controller.retire();
    freshReentry('old-register-recovery-after-new-register');
    const beforeRecovery = sentRegister;
    replyLost = true; deferArtifactList = true;
    button('pick').click(); await flush();
    check('old register A is awaiting unique inventory recovery after terminal', !!artifactListRelease && !controller.session.mutationPending());
    replyLost = false; deferArtifactList = false;
    button('pick').click(); await flush();
    const newerRegisterState = field('content-state');
    check('new register B succeeds while old A recovery is delayed', sentRegister === beforeRecovery + 2 && newerRegisterState.includes('登録を確認'));
    artifactListRelease(); await flush();
    check('old recovered register A cannot erase new register B success', field('content-state') === newerRegisterState
      && sentRegister === beforeRecovery + 2 && !controller.session.mutationPending());
    dispose(); controller.retire();
    freshReentry('register-recovered-with-git-candidates-error');
    const beforeGitError = sentRegister;
    const beforeGitLists = calls.filter(c => c.operation === 'artifact.list').length;
    gitCandidatesError = 'unsupported_file'; replyLost = true; picked = 'C:\\root\\note.txt';
    button('pick').click(); await flush();
    check('uncertain register recovers through artifact.list when git_candidates_error is set',
      sentRegister === beforeGitError + 1 && calls.filter(c => c.operation === 'artifact.list').length === beforeGitLists + 1
      && !controller.session.mutationPending() && field('content-state').includes('登録を確認'));
    omitGitCandidatesError = true; gitCandidatesError = null;
    button('pick').click(); await flush();
    check('uncertain register recovers through artifact.list when git_candidates_error is omitted',
      sentRegister === beforeGitError + 2 && calls.filter(c => c.operation === 'artifact.list').length === beforeGitLists + 2
      && !controller.session.mutationPending() && field('content-state').includes('登録を確認'));
    dispose(); controller.retire();
    freshReentry('old-read-after-new-read');
    registeredRows = [artifact, artifactB]; button('list').click(); await flush();
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click();
    deferRead = true; button('read').click(); await flush();
    check('read A is held before response', !!readRelease && controller.session.readPending());
    deferRead = false; mount.querySelector(`[data-artifact-id="${artifactB.artifact_id}"]`).click();
    button('read').click(); await flush();
    check('new read B displays second artifact', field('body') === 'B本文');
    readRelease(); await flush();
    check('old read A cannot erase new read B', field('body') === 'B本文' && field('content-state').includes('本文を表示'));
    dispose(); controller.retire();
    freshReentry('old-read-rebind');
    button('list').click(); await flush();
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click();
    deferRead = true; button('read').click(); await flush();
    check('A ordinary artifact read is pending before B bind', !!readRelease && controller.session.readPending());
    controller.disconnect(); controller.bind(port()); await flush();
    const bodyBeforeOldRead = field('body'), stateBeforeOldRead = field('content-state');
    deferRead = false; readRelease(); await flush();
    check('A ordinary read arrival cannot project into B bound view', field('body') === bodyBeforeOldRead
      && field('content-state') === stateBeforeOldRead);
    dispose(); controller.retire();
    freshReentry('old-restore-refresh-after-read');
    button('list').click(); await flush();
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click();
    deferProjectList = true; publishOnRefresh = true;
    button('layout').click(); button('restore').click(); await flush();
    check('old restore A waits for topology confirmation after terminal', !!projectListRelease && !controller.session.mutationPending());
    button('artifacts').click(); button('read').click(); await flush();
    check('read B displays selected artifact while old restore confirmation waits', field('body') === '試験本文');
    deferProjectList = false; projectListRelease(); await flush();
    check('old restore refresh cannot erase newer read B on same target', field('body') === '試験本文' && field('content-state').includes('本文を表示'));
    dispose(); controller.retire();
    freshReentry('local-select-followed-by-same-pane');
    button('list').click(); await flush();
    mount.querySelector(`[data-artifact-id="${artifactId}"]`).click();
    button('read').click(); await flush();
    check('local selected body displays before same-pane observation', field('body') === '試験本文');
    controller.updatePane(pane); await flush();
    check('same-pane observation cannot replay local selection as external command', field('body') === '試験本文' && field('content-state').includes('本文を表示'));
    dispose(); controller.retire();
    freshReentry('begin-aba');
    const beforeAdmission = sentRegister;
    let mutateDuringAdmission = true;
    const stopAdmission = controller.session.subscribe(() => {
      if (!mutateDuringAdmission || !controller.session.mutationPending()) return;
      mutateDuringAdmission = false;
      pane = { ...withProject(), projects: { projects: [{ ...projectRow, project_id: id(4) }], selected_project_id: id(4) } }; controller.updatePane(pane);
      pane = withProject(); controller.updatePane(pane);
    });
    button('pick').click(); await flush();
    check('begin notification A to B to A invalidates original picker before any send', sentRegister === beforeAdmission && !controller.session.mutationPending());
    stopAdmission(); dispose(); controller.retire();
    freshReentry('publish-next-git');
    button('list').click(); await flush();
    pickerMode = 'deferred'; button('pick').click(); await flush();
    const beforePublish = sentRegister, beforePublishCallCount = calls.length;
    let enterFromPublish = true;
    const stopPublish = controller.session.subscribe(() => {
      if (!enterFromPublish || controller.session.mutationPending()) return;
      enterFromPublish = false;
      button('register-git')?.click();
    });
    pane = { ...withProject(), projects: { projects: [{ ...projectRow, project_id: id(4), path: 'C:\\other' }], selected_project_id: id(4) } };
    controller.updatePane(pane); pickerRelease('C:\\root\\note.txt'); await flush();
    check(`publish terminal notification never sends a new Git request through the old project ${JSON.stringify({ beforePublish, sentRegister, calls: calls.slice(beforePublishCallCount).map(c => [c.operation, c.params]) })}`,
      sentRegister === beforePublish && !calls.slice(beforePublishCallCount).some(c => c.operation === 'artifact.register' && c.params.project_id === project));
    stopPublish(); dispose(); controller.retire();
    for (const mode of ['false', 'throw']) {
      freshReentry(`reserve-${mode}`);
      const owner = controller.session.allocateViewId();
      const intent = { instanceId: host, generation: controller.lifetime.nonce, projectId: project, artifactId: null,
        kind: 'register', source: 'picker', relativePath: null };
      const before = sentRegister;
      const ticket = controller.session.begin(intent, owner, () => {
        if (mode === 'throw') throw new Error('reserve_failed');
        return false;
      });
      check(`reservation ${mode} locally ends original ticket without a flight or send`, !!ticket && !controller.session.mutationPending()
        && !controller.session.matchesMutation(ticket, controller.lifetime, intent) && sentRegister === before);
      button('pick').click(); await flush();
      check(`reservation ${mode} permits one later explicit registration`, sentRegister === before + 1 && !controller.session.mutationPending());
      controller.session.retireProjection(owner); dispose(); controller.retire();
    }
    freshReentry('bind-new-port');
    let oldPortRestores = 0, newPortRestores = 0;
    const oldPort = port(), oldExchange = oldPort.exchange;
    oldPort.exchange = req => { if (req.operation === 'layout.restore') oldPortRestores++; return oldExchange(req); };
    controller.bind(oldPort);
    pickerMode = 'deferred'; button('pick').click(); await flush();
    const nextPort = port(), nextExchange = nextPort.exchange;
    nextPort.exchange = req => { if (req.operation === 'layout.restore') newPortRestores++; return nextExchange(req); };
    let restoreOnBind = true;
    const stopBind = controller.session.subscribe(() => {
      if (!restoreOnBind || controller.session.mutationPending()) return;
      restoreOnBind = false; button('restore')?.click();
    });
    controller.bind(nextPort); pickerRelease('C:\\root\\note.txt'); await flush();
    check('bind terminal notification routes next restore only to the new port', oldPortRestores === 0 && newPortRestores === 1
      && !controller.session.mutationPending());
    stopBind(); dispose(); controller.retire();
    freshReentry('disconnect-no-port');
    pickerMode = 'deferred'; button('pick').click(); await flush();
    const beforeDisconnectCalls = calls.length;
    let restoreOnDisconnect = true;
    const stopDisconnect = controller.session.subscribe(() => {
      if (!restoreOnDisconnect || controller.session.mutationPending()) return;
      restoreOnDisconnect = false; button('restore')?.click();
    });
    controller.disconnect(); pickerRelease('C:\\root\\note.txt'); await flush();
    check('disconnect terminal notification cannot send next restore through old port', !calls.slice(beforeDisconnectCalls).some(c => c.operation === 'layout.restore')
      && !controller.session.mutationPending());
    stopDisconnect(); dispose(); controller.retire();
    freshReentry('sync-exchange-failure');
    const interruptedPort = port(), normalExchange = interruptedPort.exchange;
    let syncCalls = 0, syncTicket = null;
    interruptedPort.exchange = req => {
      if (req.operation === 'artifact.register') { syncCalls++; syncTicket = req.operation_id; throw new Error('send_result_unknown'); }
      return normalExchange(req);
    };
    controller.bind(interruptedPort); statusOutcome = 'pending';
    const beforeSyncQueries = calls.filter(c => c.operation === 'operation.get').length;
    button('pick').click(); await flush();
    const originalIntent = { instanceId: host, generation: controller.lifetime.nonce, projectId: project, artifactId: null,
      kind: 'register', source: 'picker', relativePath: null };
    check('synchronous exchange throw after dispatch boundary retains exact original ticket', syncCalls === 1 && !!syncTicket
      && controller.session.matchesMutation(syncTicket, controller.lifetime, originalIntent)
      && !controller.session.matchesMutation(id(90), controller.lifetime, originalIntent)
      && controller.session.mutationPending() && calls.filter(c => c.operation === 'operation.get').length === beforeSyncQueries + 1);
    statusOutcome = 'succeeded'; await controller.refresh(); await flush();
    check('original ticket recovers after synchronous exchange throw without resending', syncCalls === 1 && !controller.session.mutationPending()
      && field('content-state').includes('登録を確認'));
    dispose(); controller.retire();
    freshReentry('retire-sent');
    deferStatus = true; button('pick').click(); await flush();
    const beforeRetire = sentRegister, releaseRetired = statusRelease;
    controller.retire(); deferStatus = false; releaseRetired(); await flush();
    check('retired host cannot resurrect a sent flight or resend its request', sentRegister === beforeRetire && !controller.session.mutationPending()
      && controller.session.isRetired());
    dispose();
    for (const kind of ['register', 'restore']) {
      let acquired = 0, released = 0, original = null, releaseDirect = null;
      freshReentry(`same-host-${kind}`, { acquire() { acquired++; return () => { released++; }; } });
      const oldPort = port(), normal = oldPort.exchange;
      oldPort.exchange = req => {
        if (req.operation === (kind === 'register' ? 'artifact.register' : 'layout.restore')) {
          calls.push(structuredClone(req)); original = req;
          return new Promise(resolve => { releaseDirect = () => resolve(response(req, kind === 'register'
            ? { artifact: { ...artifact, project_id: project, relative_path: 'note.txt' } }
            : { restored: true, generation: 7 })); });
        }
        return normal(req);
      };
      controller.bind(oldPort);
      if (kind === 'restore') button('layout').click();
      const beforeSends = calls.filter(c => c.operation === (kind === 'register' ? 'artifact.register' : 'layout.restore')).length;
      statusOutcome = 'pending'; button(kind === 'register' ? 'pick' : 'restore').click(); await flush();
      check(`${kind} held direct reply keeps original mutation`, !!original && !!releaseDirect && acquired === 1 && released === 0 && controller.session.mutationPending());
      const beforeSamePort = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length;
      await controller.recoverSameHost(); await flush();
      check(`${kind} original Q requires a new verified connection`, calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length === beforeSamePort);
      controller.disconnect(); controller.bind(port());
      const beforeQuery = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length;
      await controller.recoverSameHost(); await flush();
      check(`${kind} same-host query reaches pending original independent of direct reply`, calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length > beforeQuery
        && controller.session.mutationPending() && released === 0);
      statusOutcome = 'succeeded'; await controller.recoverSameHost(); await flush();
      check(`${kind} original terminal releases exactly one admission ${JSON.stringify({ pending: controller.session.mutationPending(), released, acquired, blocked: controller.session.isTransportBlocked(), calls: calls.slice(-8).map(c => [c.operation, c.params?.operation_id]) })}`, !controller.session.mutationPending() && released === 1
        && calls.filter(c => c.operation === original.operation).length === beforeSends + 1);
      releaseDirect(); await flush();
      check(`${kind} old direct reply cannot revive or resend after recovery`, released === 1 && !controller.session.mutationPending()
        && calls.filter(c => c.operation === original.operation).length === beforeSends + 1);
      dispose(); controller.retire();
    }
    for (const kind of ['register', 'restore']) for (const arrival of ['success', 'refused', 'exception']) {
      let acquired = 0, released = 0, original = null, resolveDirect = null, rejectDirect = null;
      freshReentry(`retired-direct-${kind}-${arrival}`, { acquire() { acquired++; return () => { released++; }; } });
      const oldPort = port(), ordinary = oldPort.exchange;
      oldPort.exchange = req => {
        if (req.operation === (kind === 'register' ? 'artifact.register' : 'layout.restore')) {
          calls.push(structuredClone(req)); original = req;
          return new Promise((resolve, reject) => { resolveDirect = resolve; rejectDirect = reject; });
        }
        return ordinary(req);
      };
      controller.bind(oldPort); statusOutcome = 'pending';
      if (kind === 'restore') button('layout').click();
      button(kind === 'register' ? 'pick' : 'restore').click(); await flush();
      check(`${kind}/${arrival} original direct request held on A`, !!original && !!resolveDirect && acquired === 1 && released === 0);
      controller.disconnect(); controller.bind(port());
      await controller.recoverSameHost(); await flush();
      const beforeQ = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length;
      const beforeProjection = field(kind === 'register' ? 'content-state' : 'restore-state');
      check(`${kind}/${arrival} B recovery reads original by distinct ID`, beforeQ === 1
        && calls.some(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id && c.operation_id !== original.operation_id));
      if (arrival === 'exception') rejectDirect(new Error('reply_lost'));
      else if (arrival === 'refused') resolveDirect({ ...response(original, null), accepted: false, result: null,
        error: { code: 'permission_denied', retryable: false, message: 'denied', target_id: null } });
      else resolveDirect(response(original, kind === 'register' ? { artifact } : { restored: true, generation: 7 }));
      await flush();
      check(`${kind}/${arrival} A direct arrival starts no B Q or state transition`,
        calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length === beforeQ
        && controller.session.mutationPending() && released === 0
        && field(kind === 'register' ? 'content-state' : 'restore-state') === beforeProjection);
      statusOutcome = 'succeeded'; await controller.recoverSameHost(); await flush();
      check(`${kind}/${arrival} only B terminal Q settles one original`, !controller.session.mutationPending()
        && released === 1 && calls.filter(c => c.operation === original.operation && c.operation_id === original.operation_id).length === 1);
      dispose(); controller.retire();
    }
    freshReentry('blocked-transport-recovery');
    nativeUnknown = true; statusOutcome = 'pending'; button('pick').click(); await flush();
    const blockedTicket = calls.filter(c => c.operation === 'artifact.register').at(-1).operation_id;
    check('transport unknown holds original ticket and blocks normal admission', controller.session.isTransportBlocked() && controller.session.mutationPending());
    const beforeUnsafeQ = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === blockedTicket).length;
    await controller.recoverSameHost(); await flush();
    check('blocked same-port recovery cannot claim a new connection', calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === blockedTicket).length === beforeUnsafeQ
      && controller.session.isTransportBlocked());
    controller.disconnect(); controller.bind(port()); nativeUnknown = false;
    const beforeBlockedRead = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === blockedTicket).length;
    await controller.recoverSameHost(); await flush();
    check('blocked transport permits exact original Q on same host', calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === blockedTicket).length > beforeBlockedRead
      && controller.session.isTransportBlocked() && controller.session.mutationPending());
    statusOutcome = 'succeeded'; await controller.recoverSameHost(); await flush();
    check('terminal and fresh pane clear same-host transport block', !controller.session.mutationPending() && !controller.session.isTransportBlocked());
    dispose(); controller.retire();
    for (const kind of ['register', 'restore']) for (const code of ['state_unknown', 'in_progress']) {
      let acquired = 0, released = 0;
      freshReentry(`ambiguous-${kind}-${code}`, { acquire() { acquired++; return () => { released++; }; } });
      ambiguousMutation = code; statusOutcome = 'pending';
      if (kind === 'restore') button('layout').click();
      const operation = kind === 'register' ? 'artifact.register' : 'layout.restore';
      const before = calls.filter(c => c.operation === operation).length;
      button(kind === 'register' ? 'pick' : 'restore').click(); await flush();
      const original = calls.filter(c => c.operation === operation).at(-1);
      check(`${kind} ${code} is nonterminal and retains one lease`, !!original && acquired === 1 && released === 0
        && controller.session.mutationPending() && calls.some(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id));
      button(kind === 'register' ? 'pick' : 'restore').click(); await flush();
      check(`${kind} ${code} cannot dispatch a competing mutation`, calls.filter(c => c.operation === operation).length === before + 1);
      ambiguousMutation = null; statusOutcome = 'succeeded'; await controller.refresh(); await flush();
      check(`${kind} ${code} releases only at original terminal`, !controller.session.mutationPending() && released === 1);
      dispose(); controller.retire();
    }
    for (const kind of ['register', 'restore']) {
      let acquired = 0, released = 0, oldRelease = null;
      freshReentry(`held-old-q-${kind}`, { acquire() { acquired++; return () => { released++; }; } });
      const oldPort = port(), normal = oldPort.exchange;
      oldPort.exchange = req => {
        if (req.operation === 'operation.get' && !oldRelease) {
          calls.push(structuredClone(req));
          return new Promise(resolve => { oldRelease = () => resolve(response(req, { operation: {
            operation_id: req.params.operation_id, phase: 'completed', outcome: 'failed', error_code: 'runtime_failed' } })); });
        }
        return normal(req);
      };
      controller.bind(oldPort); replyLost = true; statusOutcome = 'succeeded';
      if (kind === 'restore') button('layout').click();
      button(kind === 'register' ? 'pick' : 'restore').click(); await flush();
      const operation = kind === 'register' ? 'artifact.register' : 'layout.restore';
      const original = calls.filter(c => c.operation === operation).at(-1);
      check(`${kind} old Q is held before reconnect`, !!oldRelease && controller.session.mutationPending() && released === 0);
      const qBefore = calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length;
      controller.disconnect(); controller.bind(port());
      await controller.recoverSameHost(); await flush();
      check(`${kind} new connection reads original despite held old Q ${JSON.stringify({ qBefore, qAfter: calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length, acquired, released, pending: controller.session.mutationPending() })}`, calls.filter(c => c.operation === 'operation.get' && c.params.operation_id === original.operation_id).length === qBefore + 1
        && acquired === 1 && released === 1 && !controller.session.mutationPending());
      const projected = field(kind === 'register' ? 'content-state' : 'restore-state');
      oldRelease(); await flush();
      check(`${kind} late old Q cannot release twice or alter projection`, released === 1 && !controller.session.mutationPending()
        && field(kind === 'register' ? 'content-state' : 'restore-state') === projected
        && calls.filter(c => c.operation === operation).filter(c => c.operation_id === original.operation_id).length === 1);
      dispose(); controller.retire();
    }
    return passed;
  }, bundle.outputFiles[0].text);
} catch (error) { failure = String(error?.stack ?? error); }
finally { if (browser) await browser.close(); }
const result = { status: failure ? 'failed' : 'passed', count: names.length, inputs: [source, viewSource, fileURLToPath(import.meta.url)].map(path => ({ path, sha256: hash(path) })), checks: names, failure };
writeFileSync(resolve(evidence, 'result.json'), JSON.stringify(result, null, 2), 'utf8');
console.log(JSON.stringify({ status: result.status, count: result.count, evidence, failure }));
if (failure) process.exitCode = 1;
