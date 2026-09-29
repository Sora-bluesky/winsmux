import type { Scope } from '../generated/workspace-contract';
import type { WorkspaceDiscovery } from '../workspaceClient';
import type { createConnectionController } from './connection-controller';

type Controller = ReturnType<typeof createConnectionController>;
const scopeLabels: Record<Scope, string> = { metadata: '構成情報', read_output: '出力の閲覧', control: '操作' };
const stateLabels = { authenticating: '認証中', unpaired: '要求待ち', pending: '許可待ち', granted: '許可中', closing: '終了処理中', finished: '終了' };
const actionLabels = { allow: '許可', deny: '拒否', revoke: '失効' };
function operationText(record: NonNullable<ReturnType<Controller['snapshot']>['original']>) {
  const subset = record.action === 'allow' ? `、指定 project: ${record.projectIds.join('、') || 'なし'}、scope: ${record.scopes.join('、') || 'なし'}` : '';
  return `${actionLabels[record.action]}、ID: ${record.id}、対象: ${record.connectionId}${subset}、元の結果: ${record.phase}/${record.outcome ?? '未確認'}`;
}

export function mountConnectionView(root: HTMLElement, controller: Controller, options: {
  discovery(): Promise<WorkspaceDiscovery>;
  copy(text: string): Promise<boolean>;
  current(): boolean;
}) {
  const doc = root.ownerDocument;
  const section = doc.createElement('section'); section.className = 'workspace-connections'; section.setAttribute('aria-label', '外部接続の管理');
  const heading = doc.createElement('h2'); heading.textContent = 'CLI・MCP の接続';
  const explain = doc.createElement('p'); explain.textContent = '接続情報は現在の GUI host に限り有効です。コピーした情報を CLI または MCP に明示的に渡してください。';
  const discovery = doc.createElement('button'); discovery.type = 'button'; discovery.textContent = '現在の接続情報をコピー';
  const discovered = doc.createElement('p'); discovered.setAttribute('role', 'status');
  const refresh = doc.createElement('button'); refresh.type = 'button'; refresh.textContent = '接続一覧を読み直す';
  const recheck = doc.createElement('button'); recheck.type = 'button'; recheck.textContent = '元の操作を確認し直す';
  const message = doc.createElement('p'); message.setAttribute('role', 'status');
  const prior = doc.createElement('div'); prior.setAttribute('aria-label', '成否が未確認だった元の操作');
  const rows = doc.createElement('div'); rows.className = 'workspace-connection-rows';
  const grant = doc.createElement('fieldset'); const legend = doc.createElement('legend'); legend.textContent = '選択した接続への許可';
  const choices = doc.createElement('div'); const allow = doc.createElement('button'); allow.type = 'button'; allow.textContent = '選択内容を許可';
  const deny = doc.createElement('button'); deny.type = 'button'; deny.textContent = '要求を拒否';
  const revoke = doc.createElement('button'); revoke.type = 'button'; revoke.textContent = '許可を失効';
  grant.append(legend, choices, allow, deny, revoke);
  section.append(heading, explain, discovery, discovered, refresh, recheck, message, prior, rows, grant); root.append(section);
  let copiedInstance: string | null = null;
  let renderedSelectionId: string | null = null;
  let disposed = false;
  discovery.onclick = async () => {
    discovered.textContent = '';
    if (disposed || !options.current() || controller.snapshot().blocked) return;
    try {
      const value = await options.discovery();
      if (disposed || !options.current() || value.instance_id !== controller.snapshot().instanceId || controller.snapshot().blocked) throw new Error('世代が変わりました。');
      const text = JSON.stringify({ instance_id: value.instance_id, pipe_name: value.pipe_name, schema_version: value.schema_version });
      if (!await options.copy(text)) throw new Error('クリップボードへコピーできませんでした。');
      if (disposed || !options.current() || controller.snapshot().blocked) throw new Error('世代が変わりました。');
      copiedInstance = value.instance_id;
      discovered.textContent = `現在の世代 ${value.instance_id} の接続情報をコピーしました。`;
    } catch (error) { copiedInstance = null; discovered.textContent = error instanceof Error ? error.message : '接続情報を取得できませんでした。'; }
  };
  refresh.onclick = () => { void controller.refresh(); };
  recheck.onclick = () => { void controller.recheck(); };
  function selectedChoices() {
    const projectIds: string[] = []; const scopes: Scope[] = [];
    for (const input of choices.querySelectorAll<HTMLInputElement>('input:checked')) {
      if (input.dataset.kind === 'project') projectIds.push(input.value);
      if (input.dataset.kind === 'scope') scopes.push(input.value as Scope);
    }
    return { projectIds, scopes };
  }
  allow.onclick = () => { const selected = controller.snapshot().selectedId; if (!selected) return; const values = selectedChoices(); void controller.decide('allow', selected, values.projectIds, values.scopes); };
  deny.onclick = () => { const selected = controller.snapshot().selectedId; if (selected) void controller.decide('deny', selected); };
  revoke.onclick = () => { const selected = controller.snapshot().selectedId; if (selected) void controller.decide('revoke', selected); };
  const unsubscribe = controller.observe(state => {
    if (disposed) return;
    if (copiedInstance && copiedInstance !== state.instanceId || state.blocked) { copiedInstance = null; discovered.textContent = ''; }
    discovery.disabled = state.blocked || !options.current();
    refresh.disabled = state.busy || state.blocked;
    recheck.hidden = !state.original;
    recheck.disabled = state.busy || state.blocked;
    message.textContent = state.original ? `${state.message} 元の操作: ${operationText(state.original)}。` : state.message;
    const historyFocusId = doc.activeElement instanceof HTMLElement ? doc.activeElement.dataset.historyId : null;
    prior.replaceChildren();
    for (const old of state.priorUnknown) {
      const line = doc.createElement('p'); line.textContent = `過去の元操作: ${operationText(old)}。`;
      const reread = doc.createElement('button'); reread.type = 'button'; reread.textContent = 'この元操作を読み直す'; reread.disabled = state.busy || state.blocked;
      reread.dataset.historyId = old.id;
      reread.onclick = () => { void controller.recheck(old.id); };
      line.append(reread); prior.append(line);
    }
    if (historyFocusId) prior.querySelectorAll<HTMLButtonElement>('button[data-history-id]').forEach(button => { if (button.dataset.historyId === historyFocusId) button.focus({ preventScroll: true }); });
    const focusId = doc.activeElement instanceof HTMLElement ? doc.activeElement.dataset.connectionId : null;
    rows.replaceChildren();
    for (const row of state.connections ?? []) {
      const article = doc.createElement('article');
      const choose = doc.createElement('button'); choose.type = 'button'; choose.textContent = `${row.connection_id} を選択`;
      choose.dataset.connectionId = row.connection_id;
      choose.setAttribute('aria-pressed', String(state.selectedId === row.connection_id)); choose.disabled = state.busy || state.blocked;
      choose.onclick = () => controller.select(row.connection_id);
      const name = doc.createElement('p'); name.textContent = `申告された実行名: ${row.executable_name ?? '未確認'}（権限根拠ではありません）`;
      const status = doc.createElement('p'); status.textContent = `接続状態: ${stateLabels[row.state]}`;
      const requested = doc.createElement('p'); requested.textContent = `要求 project: ${row.requested_project_ids.join('、') || 'なし'} / scope: ${row.requested_scopes.join('、') || 'なし'}`;
      const effective = doc.createElement('p'); effective.textContent = `現在の許可 project: ${row.granted_project_ids.join('、') || 'なし'} / scope: ${row.granted_scopes.join('、') || 'なし'}`;
      const drain = doc.createElement('p'); drain.textContent = row.state === 'closing' ? '権限は無効です。client の終了は確認中です。' : row.state === 'finished' ? 'host 上の接続は終了しました。client 側の終端は別途確認してください。' : '';
      article.append(choose, name, status, requested, effective, drain); rows.append(article);
    }
    if (focusId) rows.querySelectorAll<HTMLButtonElement>('button[data-connection-id]').forEach(button => { if (button.dataset.connectionId === focusId) button.focus({ preventScroll: true }); });
    const retained = renderedSelectionId === state.selectedId ? selectedChoices() : { projectIds: [], scopes: [] };
    renderedSelectionId = state.selectedId;
    choices.replaceChildren();
    const selected = state.connections?.find(row => row.connection_id === state.selectedId);
    const canAllow = !!selected && selected.state === 'pending' && !state.mutationPending
      && !state.original?.phase.match(/^(accepted|in_progress|unconfirmed|read_failed|unknown)$/)
      && !state.priorUnknown.some(record => record.phase !== 'completed');
    if (selected?.state === 'pending') {
      for (const id of selected.requested_project_ids) {
        const label = doc.createElement('label'); const input = doc.createElement('input'); input.type = 'checkbox'; input.dataset.kind = 'project'; input.value = id; input.checked = retained.projectIds.includes(id);
        label.append(input, ` project ${id}`); choices.append(label);
      }
      for (const scope of selected.requested_scopes) {
        const label = doc.createElement('label'); const input = doc.createElement('input'); input.type = 'checkbox'; input.dataset.kind = 'scope'; input.value = scope; input.checked = retained.scopes.includes(scope);
        label.append(input, ` ${scopeLabels[scope]}`); choices.append(label);
      }
    }
    allow.hidden = selected?.state !== 'pending'; allow.disabled = state.busy || state.blocked || !canAllow;
    deny.hidden = selected?.state !== 'pending'; deny.disabled = state.busy || state.mutationPending || state.blocked;
    revoke.hidden = selected?.state !== 'granted'; revoke.disabled = state.busy || state.mutationPending || state.blocked;
  });
  return { dispose() { disposed = true; unsubscribe(); section.remove(); } };
}
