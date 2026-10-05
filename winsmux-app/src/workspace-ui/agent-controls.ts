import type { InstanceId, PaneSummary, ProjectSummary, Provider, ProviderCapability, RunObservation, U } from '../generated/workspace-contract';

/** The controller commits correlated, ordered observations before supplying frames. */
export interface AgentControlsSnapshot {
  instanceId: InstanceId;
  generation: string;
  observationRevision: U;
  availability: 'available' | 'unavailable' | 'uncertain';
  busy: boolean;
  project: ProjectSummary | null;
  pane: PaneSummary | null;
  capabilities: { state: 'known' | 'unknown'; providers: ProviderCapability[] | null };
}
export interface AgentTarget {
  readonly instanceId: InstanceId;
  readonly generation: string;
  readonly projectId: string;
  readonly paneId: string;
  readonly runId: string | null;
}
export type AgentIntent =
  | (AgentTarget & { readonly kind: 'launch-agent'; readonly provider: Provider; readonly model: string | null; readonly effort: string | null; readonly detectedVersion: string; readonly cwd: string; readonly interruptFirst: boolean })
  | (AgentTarget & { readonly kind: 'interrupt-run'; readonly runId: string });
export type AgentInspection = { kind: 'inspect-installation' | 'focus-terminal' | 'official-docs'; provider: Provider | null; target: AgentTarget | null };
export type AgentSettlementPhase = 'awaiting' | 'unknown' | 'completed' | 'refused';
export interface AgentControlsCallbacks {
  submit(intent: AgentIntent, ticket: string): unknown;
  inspect(intent: AgentInspection): void;
  restoreFocus(target: AgentTarget, origin: HTMLElement): void;
}
interface Pending { ticket: string; intent: AgentIntent; phase: 'awaiting' | 'unknown' }
const processText = { starting: '起動を確認中', running: '稼働中', exited: '終了を観測', unknown: '未確認' };
const workText = { unknown: '未確認', running: '作業中', awaiting_input: '入力待ち', succeeded: '完了', failed: '失敗', interrupted: '中断済み' };
const evidenceText = { process_exit: 'プロセス終了', provider_event: 'CLIの状態通知', unavailable: '未確認' };
const providerText = { codex: 'Codex', claude: 'Claude Code' };
const rootText = { verified: '確認済み', changed: '変わりました', unavailable: '確認できません', unknown: '未確認' };
const validRevision = (value: number) => Number.isSafeInteger(value) && value >= 0;
const sameTarget = (a: AgentTarget, b: AgentTarget) => a.instanceId === b.instanceId && a.generation === b.generation && a.projectId === b.projectId && a.paneId === b.paneId && a.runId === b.runId;
// Keep the generated run/observation union intact and isolate caller mutations.
const copySnapshot = (s: AgentControlsSnapshot): AgentControlsSnapshot => structuredClone(s);
function uuid(crypto: Crypto) {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const h = [...bytes].map(n => n.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Pure UI admission. It never executes a command or infers completion from delivery. */
export function createAgentControls(container: HTMLElement, initial: AgentControlsSnapshot, callbacks: AgentControlsCallbacks) {
  if (!validRevision(initial.observationRevision)) throw new Error('Invalid observation revision');
  const doc = container.ownerDocument;
  const make = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string) => {
    const el = doc.createElement(tag); if (text !== undefined) el.textContent = text; return el;
  };
  const button = (text: string, action: string) => {
    const el = make('button', text); el.type = 'button'; el.dataset.action = action; return el;
  };
  const root = make('section'); root.className = 'workspace-agent-controls'; root.setAttribute('aria-label', 'AIの起動と中断');
  const style = make('style'); style.textContent = `
    .workspace-agent-controls { min-width:0; overflow-wrap:anywhere; }
    .workspace-agent-controls .agent-fields,.workspace-agent-controls .agent-actions { display:flex; flex-wrap:wrap; gap:.6rem; align-items:start; }
    .workspace-agent-controls label { display:flex; flex-direction:column; min-width:0; max-width:100%; }
    .workspace-agent-controls textarea,.workspace-agent-controls select,.workspace-agent-controls button { box-sizing:border-box; max-width:100%; }
    .workspace-agent-controls textarea { width:22rem; }
    .workspace-agent-controls p { white-space:pre-wrap; }
    .workspace-agent-controls dialog { box-sizing:border-box; max-width:calc(100vw - 2rem); max-height:calc(100vh - 2rem); overflow:auto; }
    .workspace-agent-controls :focus-visible { outline:2px solid currentColor; outline-offset:2px; }
    @media (forced-colors:active) { .workspace-agent-controls button,.workspace-agent-controls textarea,.workspace-agent-controls select { border:1px solid ButtonText; } }
  `;
  const heading = make('h2', 'AIを選んで起動'); heading.tabIndex = -1;
  const targetInfo = make('p'); targetInfo.dataset.field = 'target';
  const fields = make('div'); fields.className = 'agent-fields';
  const provider = make('select'); provider.setAttribute('aria-label', 'AIを選択');
  for (const [value, text] of [['', 'AIを選択してください'], ['codex', 'Codex'], ['claude', 'Claude Code']]) {
    const option = make('option', text); option.value = value; provider.append(option);
  }
  const providerLabel = make('label', '使用するAI'); providerLabel.append(provider); fields.append(providerLabel);
  const cliInfo = make('p'); cliInfo.dataset.field = 'cli';
  const options = make('details'); options.append(make('summary', 'モデルと推論の設定（任意）'));
  const model = make('textarea'); model.rows = 2; model.setAttribute('aria-label', 'モデル（任意）');
  const effort = make('textarea'); effort.rows = 2; effort.setAttribute('aria-label', '推論の設定（任意）');
  const modelLabel = make('label', 'モデル'); modelLabel.append(model);
  const effortLabel = make('label', '推論の設定'); effortLabel.append(effort);
  const optionalFields = make('div'); optionalFields.className = 'agent-fields'; optionalFields.append(modelLabel, effortLabel);
  options.append(make('p', '空欄は公式CLIの既定値を使います。指定を受け付けない場合、別のAIや設定へ変更せず理由を表示します。'), optionalFields);
  const launch = button('起動内容を確認', 'launch'); const interrupt = button('現在の実行を中断', 'interrupt');
  const inspect = button('導入状況を再確認', 'inspect-installation'); const terminal = button('ターミナルへ戻る', 'focus-terminal'); const docs = button('公式CLIの案内', 'official-docs');
  const actions = make('div'); actions.className = 'agent-actions'; actions.append(launch, interrupt, inspect, terminal, docs);
  const admission = make('p'); admission.setAttribute('role', 'status'); admission.dataset.field = 'admission';
  const state = make('section'); state.setAttribute('aria-label', '根拠に基づく実行状態');
  const stateMessage = make('p'); stateMessage.dataset.field = 'state';
  const process = make('p'); process.dataset.field = 'process'; const work = make('p'); work.dataset.field = 'work';
  const evidence = make('p'); evidence.dataset.field = 'evidence'; const observedAt = make('p'); observedAt.dataset.field = 'observed-at';
  state.append(stateMessage, process, work, evidence, observedAt);
  const dialog = make('dialog'); dialog.setAttribute('aria-label', 'AIの起動内容を確認');
  const confirmInfo = make('p'); confirmInfo.dataset.field = 'confirmation';
  const confirmReason = make('p'); confirmReason.setAttribute('role', 'status');
  const back = button('戻る', 'confirm-back'); back.autofocus = true;
  const confirm = button('確認した内容で起動', 'confirm-launch');
  const dialogActions = make('div'); dialogActions.className = 'agent-actions'; dialogActions.append(back, confirm);
  dialog.append(make('h2', 'AIの起動内容を確認'), confirmInfo, confirmReason, dialogActions);
  root.append(style, heading, targetInfo, fields, cliInfo, options, actions, admission, state, dialog); container.append(root);
  let snapshot = copySnapshot(initial);
  const lifetime = { instanceId: initial.instanceId, generation: initial.generation };
  let retired = false; let disposed = false; let pending: Pending | null = null;
  let modal: { intent: Extract<AgentIntent, { kind: 'launch-agent' }>; origin: HTMLElement } | null = null;
  let message = '';
  function selectedProvider(): Provider | null { return provider.value === 'codex' || provider.value === 'claude' ? provider.value : null; }
  function detected(p: Provider): string | null {
    const c = snapshot.capabilities;
    if (c.state !== 'known' || c.providers === null) return null;
    if (c.providers.some(x => !x || (x.provider !== 'codex' && x.provider !== 'claude') || typeof x.version !== 'string' || x.version.length === 0)) return null;
    if (new Set(c.providers.map(x => x.provider)).size !== c.providers.length) return null;
    return c.providers.find(x => x.provider === p)?.version ?? null;
  }
  function target(): AgentTarget | null {
    if (!snapshot.project || !snapshot.pane || snapshot.pane.project_id !== snapshot.project.project_id) return null;
    return Object.freeze({ ...lifetime, projectId: snapshot.project.project_id, paneId: snapshot.pane.pane_id, runId: snapshot.pane.current_run_id });
  }
  function observation(): RunObservation | null {
    const p = snapshot.pane; const o = p?.observation;
    return target() && p && o && o.current && o.pane_id === p.pane_id && o.run_id === p.current_run_id ? o : null;
  }
  function baseReady() { return !disposed && !retired && snapshot.availability === 'available' && !snapshot.busy && !!target(); }
  function launchReady() {
    const p = selectedProvider(); const o = observation();
    return baseReady() && !pending && !!p && detected(p) !== null && snapshot.project?.root_state === 'verified' && typeof snapshot.project.path === 'string' && snapshot.project.path.length > 0 &&
      (snapshot.pane?.current_run_id === null ? snapshot.pane.observation === null : !!o && o.process !== 'unknown');
  }
  function interruptReady() { return baseReady() && !pending && !!target()?.runId && !!observation() && observation()?.process !== 'exited'; }
  function modalReason() {
    if (!modal) return '';
    const t = target(); const i = modal.intent;
    if (!baseReady()) return '現在の対象と状態を確認できません。戻って再確認してください。';
    if (!t || !sameTarget(t, i)) return '対象のプロジェクト・ペイン・実行が変わりました。戻って再確認してください。';
    if (snapshot.project?.root_state !== 'verified' || snapshot.project.path !== i.cwd) return '作業場所が変わったか、確認できません。';
    if (detected(i.provider) !== i.detectedVersion) return 'CLIの検出状態または版が変わりました。';
    if (i.runId !== null && (!observation() || observation()?.process === 'unknown')) return '現在の実行状態を確認できません。';
    if (i.runId === null && snapshot.pane?.observation !== null) return '実行と観測の対応を確認できません。';
    if (pending) return '別の操作を確認中です。';
    return '';
  }
  function render() {
    if (disposed) return;
    const t = target(); const p = selectedProvider(); const project = snapshot.project;
    targetInfo.textContent = project ? `現在の対象: ${project.display_name ?? project.project_id} / ${t?.paneId ?? 'ペイン未選択'}\n作業場所: ${project.path ?? '未確認'}（${rootText[project.root_state]}）\n実行: ${t?.runId ?? '未起動'}` : 'プロジェクトとペインを選択してください。';
    cliInfo.textContent = p === null ? '使用するAIを明示的に選択してください。' : snapshot.capabilities.state !== 'known' || snapshot.capabilities.providers === null ? `${providerText[p]}: 検出状態を確認できません。` : detected(p) === null ? `${providerText[p]}: 実行ファイルが見つからないか、検出結果を確認できません。` : `${providerText[p]}: CLI ${detected(p)} を検出済み。認証と指定設定の対応は、公式CLIの結果で確認します。`;
    provider.disabled = model.disabled = effort.disabled = disposed || retired || !!pending || snapshot.busy;
    launch.disabled = !launchReady(); interrupt.disabled = !interruptReady();
    inspect.disabled = docs.disabled = disposed || retired; terminal.disabled = disposed || retired || !t;
    admission.textContent = retired ? 'ホストの世代が変わりました。この画面から操作できません。' : pending ? `${pending.intent.kind === 'interrupt-run' ? pending.phase === 'unknown' ? '中断結果を確認できません' : '中断を確認中' : pending.phase === 'unknown' ? '起動結果を確認できません' : '起動を確認中'}。\n確認中の元対象: ${pending.intent.projectId} / ${pending.intent.paneId} / ${pending.intent.runId ?? '未起動'}。別の対象への再送は行いません。` : message;
    const o = !retired && snapshot.availability === 'available' ? observation() : null;
    stateMessage.textContent = retired || snapshot.availability !== 'available' ? '現在の状態を確認できません。' : snapshot.pane?.current_run_id === null && snapshot.pane.observation === null ? '実行は未起動です。' : o ? `観測した実行: ${o.run_id}` : '実行と観測の対応を確認できません。';
    process.textContent = `プロセス: ${o ? processText[o.process] : '未確認'}`;
    work.textContent = `作業: ${o ? workText[o.work] : '未確認'}`;
    evidence.textContent = `根拠: ${o ? evidenceText[o.evidence] : '未確認'}`;
    observedAt.textContent = `観測時刻: ${o ? o.observed_at : '未確認'}`;
    if (modal) { const reason = modalReason(); confirmReason.textContent = reason; confirm.disabled = !!reason; }
  }
  function failed(ticket: string) {
    if (disposed || retired || pending?.ticket !== ticket) return;
    pending.phase = 'unknown'; render();
  }
  function submit(intent: AgentIntent) {
    if (!baseReady() || pending) return;
    const ticket = uuid(doc.defaultView!.crypto);
    pending = { ticket, intent: Object.freeze({ ...intent }), phase: 'awaiting' }; message = ''; render();
    try {
      // Return values and fulfilled promises acknowledge delivery only.
      Promise.resolve(callbacks.submit(pending.intent, ticket)).catch(() => failed(ticket));
    } catch { failed(ticket); }
  }
  function dismiss(restore: boolean) {
    const old = modal; modal = null;
    if (dialog.open) dialog.close();
    if (restore && old && !disposed && !retired) callbacks.restoreFocus(old.intent, old.origin);
  }
  provider.onchange = () => render();
  launch.onclick = () => {
    if (!launchReady() || modal) return;
    const t = target()!; const p = selectedProvider()!; const o = observation();
    const intent = Object.freeze({ ...t, kind: 'launch-agent' as const, provider: p, model: model.value === '' ? null : model.value, effort: effort.value === '' ? null : effort.value,
      detectedVersion: detected(p)!, cwd: snapshot.project!.path!, interruptFirst: t.runId !== null && o?.process !== 'exited' });
    modal = { intent, origin: launch };
    confirmInfo.textContent = `AI: ${providerText[p]}\nCLI版: ${intent.detectedVersion}\n作業場所: ${intent.cwd}\nモデル: ${intent.model ?? '公式CLIの既定値'}\n推論の設定: ${intent.effort ?? '公式CLIの既定値'}\n対象: ${intent.projectId} / ${intent.paneId}\n現在の実行: ${intent.runId ?? '未起動'}\n${intent.interruptFirst ? '現在の実行を中断し、終了確認後にAIを起動します。' : '確認した対象でAIを起動します。'}`;
    confirm.textContent = intent.interruptFirst ? '現在の実行を中断してAIを起動' : '確認した内容で起動'; render(); dialog.showModal(); back.focus();
  };
  confirm.onclick = () => { if (!modal || modalReason()) { render(); return; } const intent = modal.intent; dismiss(false); submit(intent); };
  back.onclick = () => dismiss(true);
  dialog.oncancel = event => { event.preventDefault(); dismiss(true); };
  interrupt.onclick = () => { if (!interruptReady()) return; const t = target()!; submit(Object.freeze({ ...t, kind: 'interrupt-run', runId: t.runId! })); };
  for (const b of [inspect, terminal, docs]) b.onclick = () => {
    if (disposed || retired || b.disabled) return;
    try { callbacks.inspect({ kind: b.dataset.action as AgentInspection['kind'], target: target(), provider: selectedProvider() }); }
    catch { message = '確認を開始できませんでした。状態を再確認してください。'; render(); }
  };
  render();
  return {
    update(next: AgentControlsSnapshot): boolean {
      if (disposed || retired) return false;
      if (next.instanceId !== lifetime.instanceId || next.generation !== lifetime.generation) {
        retired = true; dismiss(false); render(); return false;
      }
      if (!validRevision(next.observationRevision) || next.observationRevision <= snapshot.observationRevision) return false;
      snapshot = copySnapshot(next); render(); return true;
    },
    settle(ticket: string, original: AgentTarget, phase: AgentSettlementPhase, reason?: string): boolean {
      if (disposed || retired || !pending || pending.ticket !== ticket || !sameTarget(pending.intent, original)) return false;
      if (phase === 'awaiting' || phase === 'unknown') {
        if (pending.phase === phase) return false;
        pending.phase = phase; render(); return true;
      }
      if (phase !== 'completed' && phase !== 'refused') return false;
      pending = null; message = reason || (phase === 'completed' ? '要求の処理を確認しました。実行状態は観測の根拠で確認してください。' : '要求は拒否されました。対象と設定を再確認してください。'); render(); return true;
    },
    dispose() {
      if (disposed) return;
      disposed = true; dismiss(false);
      for (const b of [launch, interrupt, inspect, terminal, docs, back, confirm]) b.onclick = null;
      provider.onchange = null; dialog.oncancel = null; root.remove();
    },
  };
}
