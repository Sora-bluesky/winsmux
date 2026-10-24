import type { ErrorCode, OperationName, Request, Response, RunObservation } from '../generated/workspace-contract';
import { decideStage, foldStage, foldRunReadiness, runReadData } from './project-pane-controller';
import type { Evidence, OwnerKey, ProjectPanePort, RunRead, StageFacts } from './project-pane-controller';
import { createRecoveryReadGate } from './recovery-read';

type Target = Readonly<{ instanceId: string; generation: string; projectId: string; paneId: string; runId: string | null }>;
export type AgentCommandIntent = Target & (
  | Readonly<{ kind: 'launch-agent'; provider: 'codex' | 'claude'; detectedVersion: string; cwd: string; model: string | null; effort: string | null; interruptFirst: boolean }>
  | Readonly<{ kind: 'interrupt-run'; runId: string }>
);
export type AgentCommandResult = Readonly<{
  ticket: string; target: Target; phase: 'awaiting' | 'unknown' | 'completed' | 'refused';
  disposition: 'pending' | 'unsent_cancelled' | 'completed' | 'refused' | 'partial';
  launchRunId: string | null; message: string;
}>;
export type AgentCommandNotice = Readonly<{ kind: 'busy'; busy: boolean }> | Readonly<{ kind: 'settlement'; result: AgentCommandResult }>;
export interface AgentCommandOptions {
  instanceId: string; generation: string; ownerKey: OwnerKey; port: ProjectPanePort;
  operationId?(): string;
}
type Lease = { projectId: string; paneId: string; live: boolean; notify(notice: AgentCommandNotice): void };
type Stage = { request: Request; facts: StageFacts; launchRunId: string | null; directAccepted: boolean; inspection: { token: ReadAttempt; promise: Promise<void> } | null; readHint: boolean; driving: boolean; dirty: boolean };
type ReadAttempt = NonNullable<ReturnType<ReturnType<typeof createRecoveryReadGate>['begin']>>;
type Pending = { intent: AgentCommandIntent; ticket: string; ownerKey: OwnerKey; lease: Lease; phase: 'preflight' | 'dispatched'; stage: Stage | null; fenced: boolean; waitingCleanup: boolean; preflightInspection: Promise<void> | null; preflightHint: boolean };
type Obj = Record<string, unknown>;
const object = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const nonempty = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const uint = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const nullableText = (v: unknown) => v === null || nonempty(v);
const codes: readonly ErrorCode[] = ['invalid_request', 'unsupported_version', 'permission_denied', 'target_not_found', 'stale_topology', 'operation_conflict', 'in_progress', 'not_running', 'already_running', 'unsupported_capability', 'output_gap', 'persistence_failed', 'runtime_failed', 'state_unknown', 'resource_exhausted', 'root_changed', 'unsupported_file', 'not_a_repository'];
const codeKnown = (v: unknown): v is ErrorCode => typeof v === 'string' && codes.includes(v as ErrorCode);
const actualExit = (run: RunObservation) => run.process === 'exited' && run.evidence === 'process_exit';

/** Host lifetime owner. The port must return Rust-codec-validated responses;
 * this module checks correlation and the domain facts used to authorize stages.
 * Delivery, operation completion and actual run exit remain separate facts. */
export function createAgentCommandSession(options: AgentCommandOptions) {
  if (!uuid(options.instanceId) || !nonempty(options.generation)) throw new Error('操作元を確認できません。');
  let retired = false;
  let connected = true;
  let lease: Lease | null = null;
  let pending: Pending | null = null;
  // A retired command retains its original mutation port. A successor may
  // provide a separate read-only route to inspect that command's original ID.
  let recoveryPort: ProjectPanePort | null = null;
  let last: AgentCommandResult | null = null;
  const usedIds = new Set<string>();
  const tickets = new Set<string>();
  const readGate = createRecoveryReadGate();
  const live = (p: Pending, s?: Stage) => !retired && pending === p && (!s || p.stage === s);
  const projected = (p: Pending) => lease === p.lease && p.lease.live;
  function emit(to: Lease | null, notice: AgentCommandNotice) {
    if (!to?.live || lease !== to) return;
    // A rendering exception cannot change dispatch or release the host latch.
    try { to.notify(notice); } catch { /* The projection owns its rendering failure. */ }
  }
  function busy() { emit(lease, { kind: 'busy', busy: pending !== null }); }
  function target(p: Pending): Target {
    const i = p.intent;
    return Object.freeze({ instanceId: i.instanceId, generation: i.generation, projectId: i.projectId, paneId: i.paneId, runId: i.runId });
  }
  function result(p: Pending, phase: AgentCommandResult['phase'], disposition: AgentCommandResult['disposition'], message: string): AgentCommandResult {
    return Object.freeze({ ticket: p.ticket, target: target(p), phase, disposition, launchRunId: p.stage?.launchRunId ?? null, message });
  }
  function report(p: Pending, phase: 'awaiting' | 'unknown') {
    const cleanup = p.waitingCleanup || (p.stage?.facts.exitFact === 'exited_same' && p.stage.facts.continuationCleanup === 'awaiting');
    const message = cleanup ? '実行の終了を確認しました。後処理の完了を確認中です。後続の起動はまだ送信していません。' : phase === 'awaiting' ? '要求の処理を確認中です。' : '元の要求を再確認してください。実行状態は未確認です。';
    if (live(p) && projected(p)) emit(p.lease, { kind: 'settlement', result: result(p, phase, 'pending', message) });
  }
  function finish(p: Pending, phase: 'completed' | 'refused', disposition: AgentCommandResult['disposition'], message: string) {
    if (!live(p)) return;
    const notice = result(p, phase, disposition, message);
    if (p.stage) p.stage.facts = foldStage(p.stage.facts, { kind: 'settlement_committed' });
    last = notice;
    pending = null;
    if (projected(p)) emit(p.lease, { kind: 'settlement', result: notice });
    busy();
  }
  function fence(p: Pending) {
    if (!live(p)) return;
    p.fenced = true;
    p.preflightHint = false;
    if (p.stage) p.stage.readHint = false;
    if (p.phase === 'preflight') finish(p, 'refused', 'unsent_cancelled', '送信前に取り消しました。');
    else if (p.stage) p.stage.facts = { ...p.stage.facts, fenced: true };
  }
  function retireProjection() {
    const old = lease;
    if (old) old.live = false;
    lease = null;
    if (pending && pending.lease === old) fence(pending);
  }
  function id() {
    const next = options.operationId?.() ?? crypto.randomUUID();
    if (!uuid(next) || usedIds.has(next)) throw new Error('操作番号を確認できません。');
    usedIds.add(next); return next;
  }
  function request(operation: OperationName, params: Obj): Request {
    return Object.freeze({ schema_version: 1, instance_id: options.instanceId, operation_id: id(), operation, expected_topology_revision: null, params: Object.freeze({ ...params }) }) as Request;
  }
  function envelope(req: Request, value: unknown): value is Response {
    if (!object(value) || value.schema_version !== 1 || value.instance_id !== req.instance_id || value.operation_id !== req.operation_id || !uint(value.topology_revision) || !uint(value.event_seq)) return false;
    if (value.accepted === true) return value.error === null && object(value.result) && value.result.operation === req.operation && object(value.result.data);
    return value.accepted === false && value.result === null && object(value.error) && codeKnown(value.error.code);
  }
  async function exchange(req: Request, route: ProjectPanePort = options.port, origin?: OwnerKey): Promise<Response | null> {
    try { const response = origin ? await route.recover(origin, req) : await route.exchange(req); return envelope(req, response) ? response : null; }
    catch { return null; }
  }
  type Group = { revision: number | null; sequence: number };
  async function read(p: Pending, operation: OperationName, params: Obj, group?: Group): Promise<Obj | null> {
    if (!live(p) || !connected) return null;
    const epoch = readGate.epoch();
    const route = p.fenced && recoveryPort ? recoveryPort : options.port;
    const got = await exchange(request(operation, params), route, operation === 'operation.get' ? p.ownerKey : undefined);
    if (!live(p) || epoch !== readGate.epoch() || !got?.accepted || !got.result) return null;
    if (group) {
      if ((group.revision !== null && group.revision !== got.topology_revision) || got.event_seq < group.sequence) return null;
      group.revision = got.topology_revision; group.sequence = got.event_seq;
    }
    return got.result.data as unknown as Obj;
  }
  async function selected(p: Pending): Promise<'verified' | 'changed' | 'unknown'> {
    if (!mayDispatch(p)) return 'unknown';
    const i = p.intent;
    const group: Group = { revision: null, sequence: 0 };
    const caps = await read(p, 'capabilities.get', {}, group);
    if (!mayDispatch(p)) return 'unknown';
    if (!caps || caps.schema_version !== 1 || !Array.isArray(caps.operations) || !caps.operations.includes(i.kind === 'launch-agent' ? 'agent.launch' : 'run.interrupt')) return 'unknown';
    if (i.kind === 'launch-agent') {
      if (!Array.isArray(caps.providers) || !caps.providers.every(v => object(v) && ['codex', 'claude'].includes(v.provider as string) && nonempty(v.version))) return 'unknown';
      const providers = caps.providers as Obj[];
      if (new Set(providers.map(v => v.provider)).size !== providers.length) return 'unknown';
      const provider = providers.find(v => v.provider === i.provider);
      if (!provider || provider.version !== i.detectedVersion) return 'changed';
    }
    const projects = await read(p, 'project.list', {}, group);
    if (!mayDispatch(p)) return 'unknown';
    if (!projects || !Array.isArray(projects.projects) || !projects.projects.every(v => object(v) && uuid(v.project_id))) return 'unknown';
    const rows = projects.projects as Obj[];
    if (new Set(rows.map(v => v.project_id)).size !== rows.length) return 'unknown';
    const project = rows.find(v => v.project_id === i.projectId);
    if (projects.selected_project_id !== i.projectId || !project) return 'changed';
    if (i.kind === 'launch-agent' && (project.root_state !== 'verified' || project.path !== i.cwd)) return 'changed';
    const panes = await read(p, 'pane.list', { project_id: i.projectId }, group);
    if (!mayDispatch(p)) return 'unknown';
    if (!panes || panes.project_id !== i.projectId || !Array.isArray(panes.panes) || !panes.panes.every(v => object(v) && uuid(v.pane_id) && v.project_id === i.projectId && (v.current_run_id === null || uuid(v.current_run_id)))) return 'unknown';
    const paneRows = panes.panes as Obj[];
    if (new Set(paneRows.map(v => v.pane_id)).size !== paneRows.length) return 'unknown';
    const pane = paneRows.find(v => v.pane_id === i.paneId);
    return panes.selected_pane_id === i.paneId && pane?.current_run_id === i.runId ? 'verified' : 'changed';
  }
  async function observed(p: Pending, cleanup: boolean): Promise<RunRead | null> {
    const i = p.intent;
    if (i.runId === null) return null;
    const data = await read(p, 'run.get', cleanup ? { include_cleanup: true, run_id: i.runId } : { run_id: i.runId });
    const got = runReadData(data, i.runId, cleanup);
    return got?.run.pane_id === i.paneId ? got : null;
  }
  function apply(p: Pending, s: Stage, evidence: Evidence) { if (live(p, s)) s.facts = foldStage(s.facts, evidence); }
  function mayDispatch(p: Pending) { return live(p) && !p.fenced && connected && projected(p); }
  function dispatch(p: Pending, operation: 'agent.launch' | 'run.interrupt') {
    if (!mayDispatch(p)) { fence(p); return; }
    const i = p.intent;
    let req: Request;
    try {
      req = operation === 'run.interrupt' ? request(operation, { run_id: i.runId }) : request(operation, {
        pane_id: i.paneId, provider: i.kind === 'launch-agent' ? i.provider : '',
        model: i.kind === 'launch-agent' ? i.model : null, effort: i.kind === 'launch-agent' ? i.effort : null, expected_current_run_id: i.runId,
      });
    } catch { finish(p, 'refused', p.phase === 'preflight' ? 'refused' : 'partial', '要求番号を確認できないため後続を送信していません。'); return; }
    const interrupt = operation === 'run.interrupt';
    const s: Stage = { request: req, launchRunId: null, directAccepted: false, inspection: null, readHint: false, driving: false, dirty: false, facts: {
      kind: interrupt ? 'interrupt' : 'instant', remaining: interrupt && i.kind === 'launch-agent', fenced: false,
      knowledge: 'unresolved', exitFact: 'none', targetFact: interrupt && i.kind === 'launch-agent' ? 'awaiting' : 'not_required',
      dataComplete: interrupt, contradiction: false, live: true, nextIssued: false,
      continuationCleanup: interrupt && i.kind === 'launch-agent' ? 'awaiting' : 'not_required',
    } };
    // Save the immutable identity before invoking the port, with no await or UI callback.
    p.stage = s; p.phase = 'dispatched';
    const dispatchedEpoch = readGate.epoch();
    void exchange(req).then(got => {
      if (!live(p, s) || dispatchedEpoch !== readGate.epoch()) return;
      if (!got) apply(p, s, { kind: 'rpc_invalid' });
      else if (!got.accepted && got.error) apply(p, s, { kind: 'rpc_error', code: got.error.code });
      else {
        const data = got.result?.data as unknown;
        const valid = object(data) && data.phase === 'accepted' && (interrupt ? data.run_id === i.runId : data.pane_id === i.paneId && uuid(data.run_id) && data.run_id !== i.runId);
        if (!valid) apply(p, s, { kind: 'rpc_invalid' });
        else { s.directAccepted = true; if (!interrupt) s.launchRunId = data.run_id as string; apply(p, s, { kind: 'rpc_success' }); }
      }
      drive(p, s, true);
    });
  }
  function drive(p: Pending, s: Stage, permitRead: boolean) {
    if (!live(p, s)) return;
    if (s.driving) { s.dirty = true; return; }
    s.driving = true;
    try {
      do {
        s.dirty = false;
        if (!live(p, s)) return;
        const decision = decideStage(s.facts);
        if (decision === 'advance_once') {
          if (!mayDispatch(p)) { s.facts = { ...s.facts, fenced: true }; s.dirty = true; continue; }
          apply(p, s, { kind: 'advance_committed' });
          dispatch(p, 'agent.launch');
          return;
        }
        if (decision === 'settle_completed') { finish(p, 'completed', 'completed', '要求の処理を確認しました。実行状態は観測の根拠で確認してください。'); return; }
        if (decision === 'settle_partial_refused') { finish(p, 'completed', 'partial', s.facts.kind === 'interrupt' ? '前段の中断と実終了を確認しました。後続の起動は送信していません。' : '操作記録の処理完了を確認しました。起動した実行の番号と状態は未確認です。'); return; }
        if (decision === 'settle_refused') { finish(p, 'refused', 'refused', '確認した対象または操作が拒否されました。後続は送信していません。'); return; }
        if (permitRead && (decision === 'inspect_run' || decision === 'inspect_snapshot')) void inspect(p, s, false);
        report(p, decision === 'await_rpc' || (decision === 'inspect_run' && s.facts.exitFact === 'exited_same' && s.facts.continuationCleanup === 'awaiting') ? 'awaiting' : 'unknown');
      } while (s.dirty);
    } finally { s.driving = false; }
  }
  function inspect(p: Pending, s: Stage, recover: boolean): Promise<void> {
    if (s.inspection && readGate.current(s.inspection.token)) return s.inspection.promise;
    const token = readGate.begin();
    if (!token) return Promise.resolve();
    const currentRead = () => live(p, s) && readGate.current(token);
    const job = Promise.resolve().then(async () => {
      if (!currentRead() || !connected) return;
      if (recover && ['unresolved', 'awaiting_record', 'unknown'].includes(s.facts.knowledge)) {
        const data = await read(p, 'operation.get', { operation_id: s.request.operation_id });
        if (!currentRead()) return;
        const saved = data?.operation;
        if (!object(saved) || saved.operation_id !== s.request.operation_id) apply(p, s, { kind: 'query_outer_failure' });
        else if (saved.phase === 'completed' && saved.outcome === 'succeeded' && saved.error_code === null) apply(p, s, { kind: 'record_success' });
        else if (saved.phase === 'completed' && saved.outcome === 'failed' && codeKnown(saved.error_code)) apply(p, s, { kind: 'record_error', code: saved.error_code });
        else if (['accepted', 'in_progress', 'unknown'].includes(saved.phase as string) && saved.outcome === null && saved.error_code === null) apply(p, s, { kind: saved.phase === 'unknown' ? 'record_absent' : 'record_wait' });
        else apply(p, s, { kind: 'query_outer_failure' });
      }
      if (!currentRead()) return;
      if (s.facts.knowledge === 'success' && s.facts.kind === 'interrupt' && (s.facts.exitFact !== 'exited_same' || s.facts.continuationCleanup === 'awaiting' || s.facts.continuationCleanup === 'unknown') && !s.facts.contradiction) {
        const cleanup = s.facts.remaining && !s.facts.fenced && s.facts.dataComplete;
        const got = await observed(p, cleanup);
        if (!currentRead()) return;
        s.facts = foldRunReadiness(s.facts, got, p.intent.paneId);
        if (s.facts.fenced) { p.fenced = true; s.readHint = false; }
      }
      if (!currentRead()) return;
      if (decideStage(s.facts) === 'inspect_snapshot' || (s.facts.knowledge === 'success' && s.facts.targetFact === 'unknown' && !s.facts.fenced && !s.facts.contradiction)) {
        const fact = await selected(p);
        if (!currentRead()) return;
        apply(p, s, { kind: 'target_fact', fact });
      }
      if (!currentRead()) return;
      drive(p, s, false);
    }).catch(() => { if (currentRead()) report(p, 'unknown'); }).finally(() => {
      if (s.inspection?.token !== token || !readGate.current(token)) return;
      s.inspection = null;
      readGate.end(token);
      const hinted = s.readHint;
      s.readHint = false;
      // Consume only a received hint. This is not a timer or an automatic poll.
      // The old stage cannot pass a hint to a new command or launch stage.
      if (hinted && mayObserve(p, s)) void inspect(p, s, false);
    });
    s.inspection = { token, promise: job };
    return job;
  }
  function preflight(p: Pending): Promise<void> {
    if (p.preflightInspection) return p.preflightInspection;
    const job = Promise.resolve().then(async () => {
      if (!mayDispatch(p) || p.phase !== 'preflight') return;
      const fact = await selected(p);
      if (!live(p)) return;
      if (fact !== 'verified') { finish(p, 'refused', 'refused', '選択・占有・導入版・作業フォルダーを確認できないため送信していません。'); return; }
      if (p.intent.runId === null) { dispatch(p, 'agent.launch'); return; }
      const got = await observed(p, p.intent.kind === 'launch-agent');
      const run = got?.run;
      if (!live(p)) return;
      if (!run || !run.current) { finish(p, 'refused', 'refused', '対象の実行を確認できないため送信していません。'); return; }
      if (actualExit(run)) {
        if (p.intent.kind === 'launch-agent') {
          if (!got?.cleanupComplete) { p.waitingCleanup = true; report(p, 'awaiting'); return; }
          const fresh = await selected(p);
          if (!live(p)) return;
          if (fresh !== 'verified') { finish(p, 'refused', 'refused', '後処理完了後の対象を確認できないため起動していません。'); return; }
          p.waitingCleanup = false;
          dispatch(p, 'agent.launch');
        }
        else finish(p, 'completed', 'completed', '指定した実行の終了を確認しました。中断は送信していません。');
      } else if (!p.waitingCleanup && ['running', 'starting'].includes(run.process) && (p.intent.kind === 'interrupt-run' || p.intent.interruptFirst)) dispatch(p, 'run.interrupt');
      else finish(p, 'refused', 'refused', '実行の終了または明示的な中断指定を確認できないため送信していません。');
    }).catch(() => { if (live(p) && p.phase === 'preflight') finish(p, 'refused', 'refused', '送信前の対象確認に失敗しました。'); }).finally(() => {
      if (p.preflightInspection !== job) return;
      p.preflightInspection = null;
      const hinted = p.preflightHint; p.preflightHint = false;
      if (hinted && p.phase === 'preflight' && p.waitingCleanup && mayDispatch(p)) void preflight(p);
    });
    p.preflightInspection = job;
    return job;
  }
  function validIntent(i: AgentCommandIntent, to: Lease, ticket: string) {
    if (!object(i) || !uuid(ticket) || tickets.has(ticket) || i.instanceId !== options.instanceId || i.generation !== options.generation || i.projectId !== to.projectId || i.paneId !== to.paneId || !(i.runId === null || uuid(i.runId))) return false;
    if (i.kind === 'interrupt-run') return uuid(i.runId);
    return i.kind === 'launch-agent' && ['codex', 'claude'].includes(i.provider) && nonempty(i.detectedVersion) && nonempty(i.cwd) && nullableText(i.model) && nullableText(i.effort) && typeof i.interruptFirst === 'boolean' && !(i.runId === null && i.interruptFirst);
  }
  function recheck(): Promise<void> {
    const p = pending;
    if (!p || !live(p)) return Promise.resolve();
    if (p.phase === 'preflight') { fence(p); return Promise.resolve(); }
    if (!p.stage || !connected) return Promise.resolve();
    const s = p.stage;
    s.readHint = false;
    p.fenced = true; s.facts = { ...s.facts, fenced: true };
    if (s.facts.knowledge === 'unresolved') s.facts = { ...s.facts, knowledge: 'awaiting_record' };
    return inspect(p, s, true);
  }
  function mayObserve(p: Pending, s: Stage) {
    return live(p, s) && mayDispatch(p) && s.directAccepted && s.facts.kind === 'interrupt' &&
      s.facts.knowledge === 'success' && !s.facts.fenced && !s.facts.contradiction && !s.facts.nextIssued;
  }
  function observe(): Promise<void> {
    const p = pending;
    if (p?.phase === 'preflight' && p.waitingCleanup && mayDispatch(p)) {
      if (p.preflightInspection) { p.preflightHint = true; return p.preflightInspection; }
      return preflight(p);
    }
    if (!p?.stage || !mayObserve(p, p.stage)) return Promise.resolve();
    const s = p.stage;
    if (s.inspection && readGate.current(s.inspection.token)) { s.readHint = true; return s.inspection.promise; }
    return inspect(p, s, false);
  }
  return {
    bind(projectId: string, paneId: string, notify: Lease['notify']) {
      if (retired || !uuid(projectId) || !uuid(paneId)) throw new Error('表示先を確認できません。');
      retireProjection();
      const to: Lease = { projectId, paneId, notify, live: true }; lease = to; busy();
      return {
        submit(intent: AgentCommandIntent, ticket: string): boolean {
          if (retired || !connected || pending || lease !== to || !to.live || !validIntent(intent, to, ticket)) return false;
          tickets.add(ticket);
          const p: Pending = { intent: Object.freeze({ ...intent }), ticket, ownerKey: options.ownerKey, lease: to, phase: 'preflight', stage: null, fenced: false, waitingCleanup: false, preflightInspection: null, preflightHint: false };
          pending = p; busy();
          if (live(p)) { report(p, 'awaiting'); void preflight(p); }
          return true;
        },
        recheck,
        observe() { return lease === to && to.live ? observe() : Promise.resolve(); },
        dispose() { if (lease === to) retireProjection(); else to.live = false; },
      };
    },
    recheck,
    observe,
    bindRecoveryPort(route: ProjectPanePort): boolean {
      if (retired || connected || !pending || pending.phase !== 'dispatched' || !pending.fenced || recoveryPort) return false;
      // Invalidate any A read already in flight before B's explicit query.
      readGate.invalidate();
      if (pending.stage) pending.stage.inspection = null;
      recoveryPort = route;
      connected = true;
      busy();
      return true;
    },
    setConnected(value: boolean) {
      connected = value;
      if (!value) {
        recoveryPort = null;
        readGate.invalidate();
        if (pending?.stage) pending.stage.inspection = null;
        if (pending) { fence(pending); if (pending?.stage) drive(pending, pending.stage, false); }
      }
      busy();
    },
    retireHost() {
      retired = true; readGate.invalidate(); recoveryPort = null; retireProjection(); pending = null;
    },
    getState() {
      return structuredClone({ busy: pending !== null, connected, retired, last,
        pending: pending ? { ticket: pending.ticket, intent: pending.intent, phase: pending.phase, request: pending.stage?.request ?? null, facts: pending.stage?.facts ?? null } : null });
    },
  };
}
