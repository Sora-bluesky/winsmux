import type { Axis, InstanceId, Node, PaneId, PaneListData, PaneSummary, ProjectId, ProjectListData, ProjectSummary, RunId, U } from '../generated/workspace-contract';
import { installWorkspaceShortcuts, restoreWorkspaceFocus } from './focus';

export interface ViewSnapshot {
  instanceId: InstanceId;
  topologyRevision: U;
  generation: string;
  projects: ProjectListData;
  panes: PaneListData | null;
  availability: 'available' | 'unavailable' | 'uncertain';
  busy: boolean;
  error?: string;
}
interface Context { instanceId: InstanceId; topologyRevision: U; generation: string }
interface ProjectTarget extends Context { projectId: ProjectId }
interface PaneTarget extends ProjectTarget { paneId: PaneId; runId: RunId | null }
export type ControlIntent =
  | (Context & { kind: 'open-folder' })
  | (ProjectTarget & { kind: 'select-project' | 'forget-project' | 'create-pane' })
  | (PaneTarget & { kind: 'select-pane' | 'close-pane'; interruptFirst?: false })
  | (PaneTarget & { kind: 'split-pane'; axis: Axis })
  | (PaneTarget & { kind: 'resize-pane'; runId: RunId; rows: number; cols: number })
  | (PaneTarget & { kind: 'interrupt-run'; runId: RunId })
  | (PaneTarget & { kind: 'close-pane'; runId: RunId; interruptFirst: true });
export type InspectionIntent = Context & { kind: 'inspect-installation' | 'reread' };
export type Settlement = { disposition: 'completed' | 'refused' | 'unknown'; message?: string };
export interface ViewCallbacks {
  control(intent: ControlIntent, ticket: number): Promise<Settlement> | Settlement;
  inspect(intent: InspectionIntent): void;
  mountTerminal?(slot: HTMLElement, target: { projectId: ProjectId; paneId: PaneId }): (() => void) | void;
  composing?(): boolean;
}
interface PaneElements {
  section: HTMLElement; heading: HTMLHeadingElement; status: HTMLElement; slot: HTMLElement;
  buttons: Map<string, HTMLButtonElement>; rows: HTMLInputElement; cols: HTMLInputElement;
  sizeError: HTMLElement; mounted: boolean; unmount?: () => void;
}
const MAX_PANES_PER_PROJECT = 4;
const paneLimitReason = '1つのプロジェクトのペインは4つまでです。';
const processText = { starting: '起動を確認中', running: '稼働中', exited: '終了を観測', unknown: '未確認' };
const workText = { unknown: '未確認', running: '作業中', awaiting_input: '入力待ち', succeeded: '完了', failed: '失敗', interrupted: '中断済み' };
const rootText = { verified: '作業場所を確認済み', unavailable: '作業場所を確認できません', changed: '作業場所が変わりました', unknown: '作業場所は未確認' };
const evidenceText = { process_exit: 'プロセス終了', provider_event: 'CLIの状態通知', unavailable: '未確認' };

/** UI request admission only. The caller owns host operation evidence and transport. */
export function createProjectPaneView(container: HTMLElement, initial: ViewSnapshot, callbacks: ViewCallbacks) {
  const doc = container.ownerDocument;
  const make = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string) => {
    const el = doc.createElement(tag); if (text !== undefined) el.textContent = text; return el;
  };
  const button = (text: string, action: string) => {
    const el = make('button', text); el.type = 'button'; el.dataset.action = action; return el;
  };
  const root = make('section'); root.className = 'workspace-project-pane';
  root.setAttribute('aria-label', 'プロジェクトとペイン');
  const toolbar = make('header'); toolbar.className = 'workspace-toolbar';
  const listToggle = button('プロジェクト一覧', 'toggle-projects'); listToggle.setAttribute('aria-expanded', 'true');
  const title = make('h1'); const open = button('プロジェクトを開く', 'open-folder');
  const inspect = button('導入状況を確認', 'inspect-installation');
  const create = button('新しいペイン', 'create-pane'); const forget = button('一覧から外す（ファイルは保持）', 'forget-project');
  const search = button('操作検索', 'operation-search'); const reread = button('状態を読み直す', 'reread');
  const cancel = button('表示したエラーを閉じる', 'dismiss-error');
  toolbar.append(listToggle, title, open, inspect, create, forget, search, reread, cancel);
  const shortcuts=make('input');shortcuts.type='checkbox';shortcuts.checked=true;
  const shortcutLabel=make('label','アプリのショートカットを使う（Ctrl+Shift+P/T/W）');shortcutLabel.prepend(shortcuts);toolbar.append(shortcutLabel);
  const message = make('p'); message.setAttribute('role', 'status');
  const body = make('div'); body.className = 'workspace-body';
  const aside = make('nav'); aside.setAttribute('aria-label', 'プロジェクト一覧');
  const projectList = make('ul'); aside.append(projectList);
  const main = make('main'); main.tabIndex = -1; main.setAttribute('aria-label', 'ペイン作業領域');
  const empty = make('p'); const layout = make('div'); layout.className = 'workspace-layout';
  const details = make('details'); const summary = make('summary', '選択したペインの詳細');
  const detailText = make('p'); details.append(summary, detailText); main.append(empty, layout, details);
  body.append(aside, main); root.append(toolbar, message, body); container.append(root);
  const dialog = make('dialog'); dialog.setAttribute('aria-label', '実行中のペインを閉じる');
  const dialogTitle = make('h2', '実行中のペインを閉じる'); const dialogTarget = make('p');
  const dialogReason = make('p'); dialogReason.setAttribute('role', 'status');
  const back = button('戻る', 'modal-return'); const confirm = button('中断して閉じる', 'modal-confirm');
  dialog.append(dialogTitle, dialogTarget, dialogReason, back, confirm); root.append(dialog);
  const operations = make('dialog'); operations.setAttribute('aria-label', '操作検索');
  const query = make('input'); query.type = 'search'; query.setAttribute('aria-label', '操作名を検索');
  const results = make('div'); const closeSearch = button('操作検索を閉じる', 'close-search');
  operations.append(make('h2', '操作検索'), query, results, closeSearch); root.append(operations);
  let snapshot = initial;
  let epoch = 0; let disposed = false; let ticketSequence = 0;
  let pending: { ticket: number; intent: ControlIntent; disposition: 'pending' | 'unknown'; message?: string } | null = null;
  let completionFocus: { origin: HTMLElement; instanceId: string; generation: string } | null = null;
  let shortcutOrigin: HTMLElement | null = null;
  const focusChanged = (event: FocusEvent) => { if (completionFocus && event.target !== main) completionFocus = null; };
  doc.addEventListener('focusin', focusChanged);
  let localMessage = ''; let errorDismissed = false;
  type CloseModal = { target: PaneTarget; returnTo: HTMLElement } & (
    | { phase: 'confirmable' }
    | { phase: 'submitted'; ticket: number; outcome: 'pending' | 'unknown' | 'refused'; message?: string }
  );
  let modal: CloseModal | null = null;
  let searchReturn: HTMLElement | null = null;
  let topologyKey = '';
  const panes = new Map<PaneId, PaneElements>();
  const projects = new Map<ProjectId, HTMLButtonElement>();
  const searchResults = new Map<HTMLButtonElement, HTMLButtonElement>();
  const shortcutControl = (control: HTMLButtonElement | undefined) => {
    shortcutOrigin = doc.activeElement instanceof HTMLElement && root.contains(doc.activeElement) ? doc.activeElement : null;
    try { control?.click(); } finally { shortcutOrigin = null; }
  };
  const removeShortcuts=installWorkspaceShortcuts(root,{
    enabled:()=>!disposed&&shortcuts.checked,composing:()=>callbacks.composing?.()??false,
    search:()=>showSearch(doc.activeElement instanceof HTMLElement?doc.activeElement:search),
    create:()=>{if(!modal)shortcutControl(create);},
    close:()=>{const selected=snapshot.panes?.selected_pane_id;if(selected)shortcutControl(panes.get(selected)?.buttons.get('close-pane'));},
  });
  const context = (): Context => ({ instanceId: snapshot.instanceId, topologyRevision: snapshot.topologyRevision, generation: snapshot.generation });
  const selectedProject = () => snapshot.projects.projects.find(p => p.project_id === snapshot.projects.selected_project_id);
  function domainValid() {
    const list = snapshot.projects.projects;
    if (new Set(list.map(p => p.project_id)).size !== list.length) return false;
    if (snapshot.projects.selected_project_id !== null && !selectedProject()) return false;
    const data = snapshot.panes;
    if (!data) return true;
    if (!selectedProject() || data.project_id !== snapshot.projects.selected_project_id) return false;
    if (new Set(data.panes.map(p => p.pane_id)).size !== data.panes.length) return false;
    if (data.selected_pane_id !== null && !data.panes.some(p => p.pane_id === data.selected_pane_id)) return false;
    const leaves: string[] = [];
    const walk = (node: Node): boolean => {
      if (node.kind === 'leaf') { leaves.push(node.pane_id); return true; }
      return (node.axis === 'horizontal' || node.axis === 'vertical') && Number.isFinite(node.ratio) && node.ratio > 0 && node.ratio < 1 && walk(node.first) && walk(node.second);
    };
    if (data.root && !walk(data.root)) return false;
    if (leaves.length !== data.panes.length || new Set(leaves).size !== leaves.length) return false;
    return data.panes.every(p => p.project_id === data.project_id && leaves.includes(p.pane_id) &&
      (p.observation === null || (p.observation.pane_id === p.pane_id && p.observation.run_id === p.current_run_id && p.observation.current)));
  }
  function targetValid(target: ProjectTarget | PaneTarget, checkContext = true) {
    if (checkContext && (target.instanceId !== snapshot.instanceId || target.generation !== snapshot.generation || target.topologyRevision !== snapshot.topologyRevision)) return false;
    if (!snapshot.projects.projects.some(p => p.project_id === target.projectId)) return false;
    if ('paneId' in target) {
      const pane = snapshot.panes?.project_id === target.projectId ? snapshot.panes.panes.find(p => p.pane_id === target.paneId) : undefined;
      return !!pane && pane.current_run_id === target.runId && domainValid();
    }
    return domainValid();
  }
  const canControl = () => !disposed && !pending && !snapshot.busy && snapshot.availability === 'available' && domainValid();
  const paneTarget = (pane: PaneSummary): PaneTarget => ({ ...context(), projectId: pane.project_id, paneId: pane.pane_id, runId: pane.current_run_id });
  const projectTarget = (project: ProjectSummary): ProjectTarget => ({ ...context(), projectId: project.project_id });
  function settle(ticket: number, result: Settlement) {
    if (disposed || !pending || pending.ticket !== ticket) return false;
    if (result.disposition === 'unknown') {
      if (pending.disposition === 'unknown') return false;
      pending.disposition = 'unknown'; pending.message = result.message;
      if (modal?.phase === 'submitted' && modal.ticket === ticket) modal = { ...modal, outcome: 'unknown', message: result.message };
      updateAdmission(); return true;
    }
    if (result.disposition !== 'completed' && result.disposition !== 'refused') return false;
    localMessage = result.message ?? (result.disposition === 'refused' ? '対象への操作は拒否されました。必要なら明示的に操作し直してください。' : '要求の完了を確認しました。表示は読み直した状態に従います。');
    const completedModal = modal?.phase === 'submitted' && modal.ticket === ticket ? modal : null;
    pending = null;
    if (completedModal) {
      if (result.disposition === 'completed') {
        modal = null;
        if (dialog.open) { dialog.close(); restoreFocus(null); }
      } else {
        modal = { ...completedModal, outcome: 'refused', message: result.message };
      }
    }
    updateAdmission(); return true;
  }
  function emit(intent: ControlIntent, capturedEpoch: number, onAdmitted?: (ticket: number) => void) {
    if (capturedEpoch !== epoch || !canControl()) return;
    if ('projectId' in intent && !targetValid(intent)) return;
    if (intent.instanceId !== snapshot.instanceId || intent.generation !== snapshot.generation || intent.topologyRevision !== snapshot.topologyRevision) return;
    const ticket = ++ticketSequence; pending = { ticket, intent, disposition: 'pending' }; localMessage = ''; onAdmitted?.(ticket);
    // Keep focus inside the workspace while its originating control is disabled.
    // A later explicit focus choice cancels the return, including a newer dialog.
    const origin = shortcutOrigin ?? doc.activeElement;
    completionFocus = null;
    if (!dialog.open && !operations.open && origin instanceof HTMLElement && root.contains(origin) && (shortcutOrigin || origin instanceof HTMLButtonElement)) {
      completionFocus = { origin, instanceId: snapshot.instanceId, generation: snapshot.generation };
      main.focus();
    }
    updateAdmission();
    try {
      Promise.resolve(callbacks.control(intent, ticket)).then(result => {
        if (result && typeof result === 'object') settle(ticket, result); else settle(ticket, { disposition: 'unknown' });
      }, () => settle(ticket, { disposition: 'unknown', message: '要求の結果を確認できません。' }));
    } catch { settle(ticket, { disposition: 'unknown', message: '要求の結果を確認できません。' }); }
  }
  function bind(el: HTMLButtonElement, intent: ControlIntent) {
    const captured = epoch; el.onclick = () => emit(intent, captured);
  }
  function restoreFocus(invoker: HTMLElement | null, paneId?: string) {
    restoreWorkspaceFocus(invoker,[paneId?panes.get(paneId)?.heading:undefined,main]);
  }
  function dismissModal() {
    const old = modal; modal = null; if (dialog.open) dialog.close(); restoreFocus(old?.returnTo ?? null, old?.target.paneId);
  }
  back.onclick = dismissModal; dialog.addEventListener('cancel', event => { event.preventDefault(); dismissModal(); });
  function dismissSearch() { if (operations.open) operations.close(); restoreFocus(searchReturn); }
  closeSearch.onclick = dismissSearch; operations.addEventListener('cancel', event => { event.preventDefault(); dismissSearch(); });
  listToggle.onclick = () => {
    if (!aside.hidden && aside.contains(doc.activeElement)) listToggle.focus();
    aside.hidden = !aside.hidden; listToggle.setAttribute('aria-expanded', String(!aside.hidden));
  };
  inspect.onclick = () => { if (!disposed) callbacks.inspect({ ...context(), kind: 'inspect-installation' }); };
  reread.onclick = () => { if (!disposed) callbacks.inspect({ ...context(), kind: 'reread' }); };
  cancel.onclick = () => { errorDismissed = true; localMessage = ''; updateAdmission(); };
  function showSearch(origin:HTMLElement) { if (modal) return; if (operations.open) { query.focus(); return; } searchReturn = origin; query.value = ''; refreshSearch(); search.focus(); operations.showModal(); query.focus(); }
  search.onclick = () => showSearch(search);
  query.oninput = refreshSearch;
  function refreshSearch() {
    const focused = doc.activeElement instanceof HTMLButtonElement && results.contains(doc.activeElement) ? doc.activeElement : null;
    const sources = [open, inspect, create, forget, reread, ...Array.from(panes.values()).flatMap(p => [...p.buttons.values()])];
    const next = new Map<HTMLButtonElement, HTMLButtonElement>();
    for (const source of sources) {
      const label = source.getAttribute('aria-label') ?? source.textContent ?? '';
      if (source.hidden || !label.includes(query.value)) continue;
      const item = searchResults.get(source) ?? button(label, 'search-result');
      item.textContent = label; item.disabled = source.disabled; item.title = source.title;
      const sourceHandler = source.onclick;
      item.onclick = event => { if (!item.disabled && sourceHandler) { if (operations.open) operations.close(); restoreWorkspaceFocus(source,[search,main]); sourceHandler.call(source, event); } };
      next.set(source, item);
    }
    const ordered = [...next.values()];
    for (let i = 0; i < ordered.length; i++) if (results.children.item(i) !== ordered[i]) results.insertBefore(ordered[i], results.children.item(i));
    for (const [source, item] of searchResults) if (!next.has(source)) { item.disabled = true; item.onclick = null; item.remove(); }
    searchResults.clear(); for (const [source, item] of next) searchResults.set(source, item);
    if (focused && operations.open) {
      if (focused.isConnected && !focused.disabled) { if (doc.activeElement !== focused) focused.focus(); }
      else query.focus();
    }
  }
  function updateAdmission() {
    const usable = canControl(); const project = selectedProject();
    const paneCount = project && snapshot.panes && snapshot.panes.project_id === project.project_id ? snapshot.panes.panes.length : 0;
    const paneLimitReached = paneCount >= MAX_PANES_PER_PROJECT;
    open.disabled = !usable;
    create.disabled = !usable || !project || project.root_state !== 'verified' || !snapshot.panes || paneLimitReached;
    create.title = paneLimitReached ? paneLimitReason : '';
    forget.disabled = !usable || !project;
    for (const [id, el] of projects) el.disabled = !usable || !snapshot.projects.projects.some(p => p.project_id === id);
    for (const [id, elements] of panes) {
      const pane = snapshot.panes?.panes.find(p => p.pane_id === id);
      for (const [action, el] of elements.buttons) {
        const split = action === 'split-horizontal' || action === 'split-vertical';
        el.disabled = !usable || !pane ||
          ((action === 'resize-pane' || action === 'interrupt-run') && !pane.current_run_id) ||
          (split && (project?.root_state !== 'verified' || paneLimitReached));
        if (split) el.title = paneLimitReached ? paneLimitReason : '';
      }
    }
    if (pending) {
      const target = pending.intent;
      message.textContent = `要求 ${pending.ticket} ${pending.disposition === 'unknown' ? '結果は未確認' : '確認待ち'}：${target.kind}${'projectId' in target ? ` / プロジェクト ${target.projectId}` : ''}${'paneId' in target ? ` / ペイン ${target.paneId} / 実行 ${target.runId ?? '未起動'}` : ''}${pending.message ? ` — ${pending.message}` : ''}`;
    } else message.textContent = !domainValid() ? '対象・配置・実行の対応を確認できません。状態を読み直してください。' : snapshot.availability !== 'available' ? '対象を保持しています。現在は操作結果を確認できません。状態を読み直してください。' : snapshot.busy ? '要求の確認待ちです。' : localMessage || (!errorDismissed ? snapshot.error ?? '' : '');
    cancel.hidden = !localMessage && (errorDismissed || !snapshot.error);
    if (modal) {
      if (modal.phase === 'confirmable') {
        const valid = targetValid(modal.target, false) && modal.target.instanceId === snapshot.instanceId;
        confirm.disabled = !usable || !valid;
        dialogReason.textContent = !valid ? '対象または実行が変わりました。戻って対象を明示的に選び直し、状態を読み直してください。' : pending ? '要求の確認待ちです。' : '';
      } else {
        confirm.disabled = true;
        dialogReason.textContent = modal.outcome === 'refused' ? `閉鎖要求は拒否されました。${modal.message ?? '戻って状態を読み直してください。'}` : modal.outcome === 'unknown' ? `閉鎖要求の結果は未確認です。${modal.message ?? '戻って状態を読み直してください。'}` : '要求の確認待ちです。';
      }
    }
    if (operations.open) refreshSearch();
    if (completionFocus && !pending && !snapshot.busy) {
      const saved = completionFocus; completionFocus = null;
      if (saved.instanceId === snapshot.instanceId && saved.generation === snapshot.generation && doc.activeElement === main && !dialog.open && !operations.open) {
        restoreWorkspaceFocus(saved.origin, [main]);
      }
    }
  }
  function paneElements(pane: PaneSummary) {
    const found = panes.get(pane.pane_id); if (found) return found;
    const section = make('section'); section.className = 'workspace-pane'; section.dataset.paneId = pane.pane_id;
    const heading = make('h2'); heading.tabIndex = -1; const status = make('p');
    const controls = make('div'); controls.className = 'workspace-pane-controls';
    const buttons = new Map<string, HTMLButtonElement>();
    for (const [action, label] of [['select-pane', '選択'], ['split-horizontal', '左右に分割'], ['split-vertical', '上下に分割'], ['interrupt-run', '中断'], ['close-pane', '閉じる'], ['resize-pane', '端末サイズを適用']]) {
      const el = button(label, action); buttons.set(action, el); controls.append(el);
    }
    const size = make('fieldset'); size.append(make('legend', '端末サイズ（1〜32767）'));
    const rows = make('input'); const cols = make('input');
    for (const [input, label, value] of [[rows, '行数', '24'], [cols, '列数', '80']] as const) {
      input.type = 'number'; input.min = '1'; input.max = '32767'; input.step = '1'; input.value = value;
      const wrapper = make('label', label); wrapper.append(input); size.append(wrapper);
    }
    const sizeError = make('p'); sizeError.setAttribute('role', 'status'); size.append(sizeError);
    const slot = make('div'); slot.className = 'workspace-terminal'; slot.tabIndex = 0;
    section.append(heading, status, controls, size, slot);
    const elements: PaneElements = { section, heading, status, slot, buttons, rows, cols, sizeError, mounted: false };
    panes.set(pane.pane_id, elements); return elements;
  }
  function render(next: ViewSnapshot) {
    if (disposed) return;
    if (next.instanceId !== initial.instanceId) throw new Error('Host replacement requires a new view instance');
    // Capture before removals/reparenting: browser focus may otherwise become BODY.
    // This also covers a topology update arriving after its request settled.
    const renderOrigin = doc.activeElement instanceof HTMLElement && root.contains(doc.activeElement) && !dialog.open && !operations.open ? doc.activeElement : null;
    const renderGeneration = snapshot.generation;
    snapshot = next; epoch++; errorDismissed = false;
    root.dataset.instanceId = snapshot.instanceId; root.dataset.generation = snapshot.generation;
    root.dataset.topologyRevision = String(snapshot.topologyRevision); root.dataset.availability = snapshot.availability;
    root.dataset.selectedProjectId = snapshot.projects.selected_project_id ?? '';
    const project = selectedProject(); title.textContent = project ? `${project.display_name ?? project.project_id} — ${project.path ?? '作業場所は未確認'}` : 'プロジェクトを開いて作業を始める';
    bind(open, { ...context(), kind: 'open-folder' });
    if (project) { bind(create, { ...projectTarget(project), kind: 'create-pane' }); bind(forget, { ...projectTarget(project), kind: 'forget-project' }); }
    const retainedProjects = new Set(snapshot.projects.projects.map(p => p.project_id));
    for (const [id, el] of projects) if (!retainedProjects.has(id)) { el.parentElement?.remove(); projects.delete(id); }
    for (const p of snapshot.projects.projects) {
      let el = projects.get(p.project_id);
      if (!el) { el = button('', 'select-project'); const li = make('li'); li.append(el); projectList.append(li); projects.set(p.project_id, el); }
      el.textContent = `${p.display_name ?? p.project_id} — ${p.path ?? '作業場所は未確認'} / ${rootText[p.root_state]}`;
      el.setAttribute('aria-current', p.project_id === snapshot.projects.selected_project_id ? 'true' : 'false'); bind(el, { ...projectTarget(p), kind: 'select-project' });
    }
    const data = snapshot.panes; const valid = domainValid();
    const retainedPanes = new Set(data?.panes.filter(p => p.project_id === data.project_id).map(p => p.pane_id) ?? []);
    for (const [id, elements] of panes) if (!retainedPanes.has(id)) { elements.unmount?.(); elements.section.remove(); panes.delete(id); }
    if (data) for (const pane of data.panes) {
      if (pane.project_id !== data.project_id) continue;
      const el = paneElements(pane); const target = paneTarget(pane); const captured = epoch;
      el.heading.textContent = `${pane.display_name ?? 'ペイン'} / ${pane.pane_id}`;
      el.slot.setAttribute('aria-label', `ターミナル：${project?.display_name ?? pane.project_id} / ${pane.display_name ?? pane.pane_id}`);
      el.section.setAttribute('aria-label', el.heading.textContent);
      el.section.dataset.selected = String(data.selected_pane_id === pane.pane_id);
      el.section.dataset.projectId = pane.project_id; el.section.dataset.runId = pane.current_run_id ?? '';
      const observation = pane.observation;
      el.status.textContent = target.runId === null ? '配置のみ復元・未起動 / 実行なし' : observation ? `実行 ${target.runId} / プロセス：${processText[observation.process]} / 作業：${workText[observation.work]} / 根拠：${evidenceText[observation.evidence]} / 観測：${observation.observed_at}` : `実行 ${target.runId} / プロセス・作業・根拠：未確認`;
      for (const [action, control] of el.buttons) {
        control.setAttribute('aria-label', `${control.textContent}：${pane.display_name ?? pane.pane_id} / ${pane.pane_id}`);
        if (action === 'select-pane') bind(control, { ...target, kind: 'select-pane' });
        if (action === 'split-horizontal' || action === 'split-vertical') bind(control, { ...target, kind: 'split-pane', axis: action === 'split-horizontal' ? 'horizontal' : 'vertical' });
        if (action === 'interrupt-run') control.onclick = () => { if (target.runId !== null) emit({ ...target, kind: 'interrupt-run', runId: target.runId }, captured); };
        if (action === 'resize-pane') control.onclick = () => {
          if (captured !== epoch || !canControl() || !targetValid(target)) return;
          const rows = el.rows.valueAsNumber; const cols = el.cols.valueAsNumber;
          if (![rows, cols].every(n => Number.isInteger(n) && n >= 1 && n <= 32767)) { el.sizeError.textContent = '行数と列数は1〜32767の整数を指定してください。'; return; }
          el.sizeError.textContent = ''; if (target.runId !== null) emit({ ...target, kind: 'resize-pane', runId: target.runId, rows, cols }, captured);
        };
        if (action === 'close-pane') control.onclick = () => {
          if (modal) return;
          if (captured !== epoch || !canControl() || !targetValid(target)) return;
          if (target.runId === null || (observation?.process === 'exited' && observation.evidence !== 'unavailable')) { emit({ ...target, kind: 'close-pane' }, captured); return; }
          if (operations.open) operations.close();
          modal = { target, returnTo: control, phase: 'confirmable' }; dialogTarget.textContent = `${project?.display_name ?? target.projectId} / ${project?.path ?? '作業場所は未確認'} / ペイン ${target.paneId} / 実行 ${target.runId}`;
          confirm.onclick = () => {
            const current = modal;
            if (!current || current.phase !== 'confirmable' || !targetValid(current.target, false) || current.target.runId === null) return;
            const fresh = { ...current.target, ...context() };
            emit({ ...fresh, kind: 'close-pane', runId: current.target.runId, interruptFirst: true }, epoch, ticket => {
              if (modal === current) modal = { ...current, phase: 'submitted', ticket, outcome: 'pending' };
            });
          };
          updateAdmission(); dialog.showModal(); back.focus();
        };
      }
    }
    const key = JSON.stringify([data?.project_id, valid, data?.root]);
    if (key !== topologyKey) {
      topologyKey = key;
      const draw = (node: Node): HTMLElement => {
        if (node.kind === 'leaf') { const el = panes.get(node.pane_id); if (!el) throw new Error('Invalid topology'); return el.section; }
        const split = make('div'); split.className = `workspace-split workspace-${node.axis}`;
        split.style.setProperty('--first-ratio', String(node.ratio)); split.style.setProperty('--second-ratio', String(1 - node.ratio)); split.append(draw(node.first), draw(node.second)); return split;
      };
      layout.replaceChildren(...(valid && data?.root ? [draw(data.root)] : []));
    }
    if (valid && data) for (const pane of data.panes) {
      const el = panes.get(pane.pane_id);
      if (el && !el.mounted && el.slot.isConnected) {
        el.mounted = true;
        const unmount = callbacks.mountTerminal?.(el.slot, { projectId: pane.project_id, paneId: pane.pane_id });
        el.unmount = unmount || undefined;
      }
    }
    empty.hidden = !!project && !!data?.panes.length && valid;
    empty.textContent = !project ? '開くプロジェクトを選んでください。導入状況も確認できます。' : !valid ? 'ペインの対象と配置を確認できません。状態を読み直してください。' : data ? 'ペインがありません。「新しいペイン」から作成できます。' : 'プロジェクトのペインを読み直してください。';
    const selected = data?.panes.find(p => p.pane_id === data.selected_pane_id);
    details.hidden = !selected || !valid; detailText.textContent = selected ? `プロジェクト ${selected.project_id} / ペイン ${selected.pane_id} / 実行 ${selected.current_run_id ?? '未起動'} / ${selected.path ?? '作業場所は未確認'}` : '';
    if (details.hidden && details.contains(doc.activeElement)) main.focus();
    updateAdmission();
    if (renderOrigin && doc.activeElement === doc.body && !dialog.open && !operations.open) {
      restoreWorkspaceFocus(renderGeneration === snapshot.generation ? renderOrigin : null, [main]);
    }
  }
  render(initial);
  return {
    element: root, render, settle,
    requestOpenFolder() {
      if (!canControl()) return false;
      emit({ ...context(), kind: 'open-folder' }, epoch); return true;
    },
    requestPaneResize(target: Extract<ControlIntent, { kind: 'resize-pane' }>) {
      if (!canControl() || !targetValid(target) || ![target.rows, target.cols].every(n => Number.isInteger(n) && n >= 1 && n <= 32767) || target.runId === null) return false;
      if (target.instanceId !== snapshot.instanceId || target.generation !== snapshot.generation || target.topologyRevision !== snapshot.topologyRevision) return false;
      emit(target, epoch); return true;
    },
    dispose() {
      if (disposed) return; disposed = true; epoch++;
      removeShortcuts();if (dialog.open) dialog.close(); if (operations.open) operations.close();
      completionFocus = null; doc.removeEventListener('focusin', focusChanged);
      for (const el of root.querySelectorAll('button')) el.onclick = null;
      query.oninput = null; searchResults.clear(); for (const pane of panes.values()) pane.unmount?.(); root.remove();
    },
  };
}
