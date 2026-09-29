import type { CapabilitiesData, ErrorCode, InstanceId, OperationName, PaneCloseParams, PaneListData, ProjectListData, Request, Response, RunObservation, U } from '../generated/workspace-contract';
import type { ControlIntent, InspectionIntent, Settlement, ViewSnapshot } from './project-pane';

/** The port owns raw-byte Rust validation and host lifetime. This layer additionally
 * checks object shape, correlation and the supported payload's domain invariants.
 * It never interprets transport failure as a canonical RPC refusal. */
export type OwnerKey = Readonly<{ instanceId: string; ownerGeneration: string }>;
export interface ProjectPanePort {
  readonly ownerKey: OwnerKey;
  exchange(request: Request): Promise<Response>;
  recover(origin: OwnerKey, request: Request): Promise<Response>;
}
export interface ControllerOptions {
  instanceId: InstanceId;
  generation: string;
  ownerKey: OwnerKey;
  port: ProjectPanePort;
  pickFolder(): Promise<string | null>;
  snapshot(snapshot: ViewSnapshot): void;
  settlement(ticket: number, result: Settlement): void;
  installation(data: CapabilitiesData | null, message?: string): void;
}
type Knowledge = 'unresolved' | 'awaiting_record' | 'unknown' | 'failure' | 'success';
type ExitFact = 'none' | 'running' | 'unknown' | 'exited_same';
type TargetFact = 'not_required' | 'awaiting' | 'verified' | 'changed' | 'unknown';
export interface StageFacts {
  kind: 'instant' | 'interrupt'; remaining: boolean; fenced: boolean;
  knowledge: Knowledge; exitFact: ExitFact; targetFact: TargetFact;
  dataComplete: boolean; contradiction: boolean; live: boolean; nextIssued: boolean;
  continuationCleanup?: 'not_required' | 'awaiting' | 'ready' | 'unknown';
}
type Decision = 'ignore' | 'hold_unknown' | 'await_rpc' | 'inspect_record' | 'settle_refused' | 'inspect_run' | 'settle_partial_refused' | 'inspect_snapshot' | 'advance_once' | 'await_next_stage' | 'settle_completed';
export type Evidence =
  | { kind: 'rpc_unavailable' | 'rpc_invalid' | 'record_wait' | 'record_absent' | 'query_outer_failure' }
  | { kind: 'rpc_success' | 'record_success' }
  | { kind: 'rpc_error' | 'record_error'; code: ErrorCode }
  | { kind: 'run_fact'; fact: ExitFact }
  | { kind: 'cleanup_fact'; fact: 'awaiting' | 'ready' | 'unknown' }
  | { kind: 'target_fact'; fact: TargetFact }
  | { kind: 'advance_committed' | 'settlement_committed' };

/** One decision order for direct results, saved results and subsequent reads. */
export function decideStage(s: Readonly<StageFacts>): Decision {
  if (!s.live) return 'ignore';
  if (s.contradiction || s.knowledge === 'unknown') return 'hold_unknown';
  if (s.knowledge === 'unresolved') return 'await_rpc';
  if (s.knowledge === 'awaiting_record') return 'inspect_record';
  if (s.knowledge === 'failure') return 'settle_refused';
  if (s.kind === 'interrupt' && s.exitFact !== 'exited_same') return s.exitFact === 'unknown' ? 'hold_unknown' : 'inspect_run';
  if (!s.dataComplete || (s.remaining && s.fenced)) return 'settle_partial_refused';
  if (s.remaining && s.continuationCleanup === 'unknown') return 'hold_unknown';
  if (s.remaining && s.continuationCleanup === 'awaiting') return 'inspect_run';
  if (s.targetFact === 'changed') return 'settle_refused';
  if (s.targetFact === 'unknown') return 'hold_unknown';
  if (s.targetFact === 'awaiting') return 'inspect_snapshot';
  if (s.remaining) return s.nextIssued ? 'await_next_stage' : 'advance_once';
  return 'settle_completed';
}
const errorDefinitions: Record<ErrorCode, readonly [boolean, string]> = {
  invalid_request: [false, 'Invalid request.'], unsupported_version: [false, 'Unsupported protocol version.'],
  permission_denied: [false, 'Permission denied.'], target_not_found: [false, 'Target not found.'],
  stale_topology: [true, 'Topology changed.'], operation_conflict: [false, 'Operation identifier conflict.'],
  in_progress: [true, 'Operation is in progress.'], not_running: [false, 'Run is not running.'],
  already_running: [false, 'Run is already running.'], unsupported_capability: [false, 'Capability is unavailable.'],
  output_gap: [false, 'Output history is incomplete.'], persistence_failed: [false, 'Persistence failed.'],
  runtime_failed: [true, 'Runtime operation failed.'], state_unknown: [false, 'Operation state is unknown.'],
  resource_exhausted: [false, 'Resource limit reached.'], root_changed: [false, 'Root identity changed.'],
  unsupported_file: [false, 'File type is unsupported.'], not_a_repository: [false, 'Git repository is unavailable.'],
};
const codeKnown = (v: unknown): v is ErrorCode => typeof v === 'string' && Object.prototype.hasOwnProperty.call(errorDefinitions, v);
const classify = (code: ErrorCode): Knowledge => code === 'state_unknown' ? 'unknown' : code === 'in_progress' ? 'awaiting_record' : 'failure';
export function foldStage(s: Readonly<StageFacts>, e: Evidence, matches = true): StageFacts {
  if (!s.live || !matches) return { ...s };
  if (e.kind === 'rpc_unavailable' || e.kind === 'rpc_invalid') {
    return s.knowledge === 'unresolved' || s.knowledge === 'awaiting_record' ? { ...s, knowledge: 'awaiting_record', fenced: true } : { ...s };
  }
  if (e.kind === 'rpc_success' || e.kind === 'record_success' || e.kind === 'rpc_error' || e.kind === 'record_error') {
    const recovered = e.kind.startsWith('record_');
    const knowledge = 'code' in e ? classify(e.code) : 'success';
    if (s.knowledge === 'unknown') return { ...s };
    if (s.knowledge === 'success' || s.knowledge === 'failure') return { ...s, contradiction: s.contradiction || s.knowledge !== knowledge };
    return { ...s, knowledge, fenced: s.fenced || recovered || knowledge === 'unknown' || knowledge === 'awaiting_record', dataComplete: recovered ? s.dataComplete : true };
  }
  if (e.kind === 'record_wait' && (s.knowledge === 'unresolved' || s.knowledge === 'awaiting_record')) return { ...s, knowledge: 'awaiting_record', fenced: true };
  if (e.kind === 'run_fact' && s.kind === 'interrupt' && s.knowledge === 'success') return { ...s, exitFact: e.fact };
  if (e.kind === 'cleanup_fact' && s.kind === 'interrupt' && s.remaining && s.knowledge === 'success' && s.continuationCleanup !== undefined && s.continuationCleanup !== 'not_required') return { ...s, continuationCleanup: e.fact };
  if (e.kind === 'target_fact' && s.knowledge === 'success') return { ...s, targetFact: s.targetFact === 'changed' ? 'changed' : e.fact };
  if (e.kind === 'advance_committed' && decideStage(s) === 'advance_once') return { ...s, nextIssued: true };
  if (e.kind === 'settlement_committed' && decideStage(s).startsWith('settle_')) return { ...s, live: false };
  return { ...s };
}
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const uint = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const text = (v: unknown): v is string => typeof v === 'string';
const nonempty = (v: unknown): v is string => text(v) && v.length > 0;
const nullable = (v: unknown, check: (v: unknown) => boolean) => v === null || check(v);
type Obj = Record<string, unknown>;
function object(v: unknown, keys: readonly string[]): v is Obj {
  return !!v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === keys.length && keys.every(k => Object.prototype.hasOwnProperty.call(v, k));
}
const unique = (v: unknown, check: (v: unknown) => boolean): v is unknown[] => Array.isArray(v) && v.every(check) && new Set(v).size === v.length;
const names: readonly OperationName[] = ['capabilities.get', 'connection.request', 'connection.list', 'connection.decide', 'connection.revoke', 'host.stop', 'project.list', 'project.open', 'project.select', 'project.forget', 'pane.list', 'pane.create', 'pane.split', 'pane.select', 'pane.close', 'pane.resize', 'shell.launch', 'agent.launch', 'input.write', 'input.key', 'run.get', 'run.interrupt', 'operation.get', 'output.read', 'events.wait', 'layout.save', 'layout.restore', 'artifact.register', 'artifact.list', 'artifact.read', 'artifact.diff', 'artifact.choose', 'artifact.choice.list', 'diagnostics.get'];
function timestamp(v: unknown) {
  if (!text(v) || !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?Z$/.test(v)) return false;
  const date = new Date(v); return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 19) === v.slice(0, 19);
}
function observation(v: unknown): v is RunObservation {
  if (!object(v, ['run_id', 'pane_id', 'process', 'work', 'evidence', 'observed_at', 'current', 'exit_code']) || !uuid(v.run_id) || !uuid(v.pane_id) || !timestamp(v.observed_at) || typeof v.current !== 'boolean' || !nullable(v.exit_code, c => typeof c === 'number' && Number.isInteger(c) && c >= -2147483648 && c <= 2147483647)) return false;
  if (!['starting', 'running', 'exited', 'unknown'].includes(v.process as string) || !['unknown', 'running', 'awaiting_input', 'succeeded', 'failed', 'interrupted'].includes(v.work as string)) return false;
  if (v.evidence === 'unavailable') return v.work === 'unknown' && v.exit_code === null;
  if (v.evidence === 'provider_event' && v.process === 'running') return v.exit_code === null && v.work !== 'interrupted';
  if (v.evidence === 'provider_event' && v.process === 'exited') return (v.exit_code === null || v.exit_code === 0) ? ['unknown', 'succeeded', 'failed', 'interrupted'].includes(v.work as string) : v.work === 'failed' || v.work === 'interrupted';
  if (v.evidence !== 'process_exit' || v.process !== 'exited') return false;
  return v.work === 'interrupted' || (v.work === 'unknown' && (v.exit_code === null || v.exit_code === 0)) || (v.work === 'succeeded' && v.exit_code === 0) || (v.work === 'failed' && v.exit_code !== null && v.exit_code !== 0);
}
export type RunRead = { run: RunObservation; cleanupComplete: boolean | null };
/** Decode identity and exit evidence independently from successor authority. */
export function runReadData(data: unknown, capturedRunId: string, includeCleanup: boolean): RunRead | null {
  if (!object(data, includeCleanup ? ['run', 'cleanup_complete'] : ['run']) || !observation(data.run) || data.run.run_id !== capturedRunId) return null;
  if (includeCleanup && (typeof data.cleanup_complete !== 'boolean' || (data.cleanup_complete && !(data.run.process === 'exited' && data.run.evidence === 'process_exit')))) return null;
  return { run: data.run, cleanupComplete: includeCleanup ? data.cleanup_complete as boolean : null };
}
/** Both dispatched interrupt owners consume the same correlated predecessor facts.
 * History preserves exit evidence while permanently fencing continuation. */
export function foldRunReadiness(s: Readonly<StageFacts>, read: RunRead | null, capturedPaneId: string): StageFacts {
  if (!s.live || s.kind !== 'interrupt' || s.knowledge !== 'success') return { ...s };
  const same = read?.run.pane_id === capturedPaneId ? read : null;
  const run = same?.run;
  let next = foldStage(s, { kind: 'run_fact', fact: run && run.process === 'exited' && run.evidence === 'process_exit' ? 'exited_same' : run && (run.process === 'running' || run.process === 'starting') ? 'running' : 'unknown' });
  if (run && !run.current) {
    next = { ...next, fenced: true };
    if (next.remaining) next = foldStage(next, { kind: 'target_fact', fact: 'changed' });
  }
  if (s.remaining && s.continuationCleanup !== undefined && s.continuationCleanup !== 'not_required') {
    next = foldStage(next, { kind: 'cleanup_fact', fact: same && run?.current && same.cleanupComplete !== null ? same.cleanupComplete ? 'ready' : 'awaiting' : 'unknown' });
  }
  return next;
}
function projects(v: unknown): v is ProjectListData {
  if (!object(v, ['projects', 'selected_project_id']) || !Array.isArray(v.projects) || !nullable(v.selected_project_id, uuid)) return false;
  const ids = new Set<string>();
  for (const p of v.projects) {
    if (!object(p, ['project_id', 'root_state', 'display_name', 'path']) || !uuid(p.project_id) || ids.has(p.project_id) || !['verified', 'unavailable', 'changed', 'unknown'].includes(p.root_state as string) || !nullable(p.display_name, text) || !nullable(p.path, text)) return false;
    ids.add(p.project_id);
  }
  return v.selected_project_id === null || ids.has(v.selected_project_id as string);
}
function panes(v: unknown): v is PaneListData {
  if (!object(v, ['project_id', 'panes', 'root', 'selected_pane_id']) || !uuid(v.project_id) || !Array.isArray(v.panes) || !nullable(v.selected_pane_id, uuid) || v.panes.length > 4) return false;
  const ids = new Set<string>();
  for (const p of v.panes) {
    if (!object(p, ['pane_id', 'project_id', 'current_run_id', 'observation', 'display_name', 'path']) || !uuid(p.pane_id) || ids.has(p.pane_id) || p.project_id !== v.project_id || !nullable(p.current_run_id, uuid) || !nullable(p.display_name, text) || !nullable(p.path, text)) return false;
    if (p.current_run_id === null ? p.observation !== null : !observation(p.observation) || p.observation.run_id !== p.current_run_id || p.observation.pane_id !== p.pane_id || !p.observation.current) return false;
    ids.add(p.pane_id);
  }
  const leaves = new Set<string>();
  const walk = (n: unknown, depth: number): boolean => {
    if (depth > 7) return false;
    if (object(n, ['kind', 'pane_id']) && n.kind === 'leaf' && uuid(n.pane_id) && ids.has(n.pane_id) && !leaves.has(n.pane_id)) { leaves.add(n.pane_id); return true; }
    return object(n, ['kind', 'axis', 'ratio', 'first', 'second']) && n.kind === 'split' && ['horizontal', 'vertical'].includes(n.axis as string) && typeof n.ratio === 'number' && Number.isFinite(n.ratio) && n.ratio > 0 && n.ratio < 1 && walk(n.first, depth + 1) && walk(n.second, depth + 1);
  };
  return (v.root === null ? ids.size === 0 : walk(v.root, 0) && leaves.size === ids.size) && (v.selected_pane_id === null || ids.has(v.selected_pane_id as string));
}
function capabilities(v: unknown): v is CapabilitiesData {
  return object(v, ['schema_version', 'operations', 'providers', 'shell_profile_ids', 'max_message_bytes', 'replay_capacity']) && v.schema_version === 1 && v.max_message_bytes === 1048576 && unique(v.operations, n => names.includes(n as OperationName)) &&
    object(v.replay_capacity, ['retained_bytes', 'active_bytes']) && uint(v.replay_capacity.retained_bytes) && v.replay_capacity.retained_bytes > 0 && uint(v.replay_capacity.active_bytes) && v.replay_capacity.active_bytes > 0 &&
    ((v.providers === null && v.shell_profile_ids === null) || (Array.isArray(v.providers) && v.providers.every(p => object(p, ['provider', 'version']) && ['codex', 'claude'].includes(p.provider as string) && nonempty(p.version)) && unique(v.shell_profile_ids, nonempty)));
}
function status(v: unknown, originalId: unknown) {
  if (!object(v, ['operation_id', 'phase', 'outcome', 'error_code']) || v.operation_id !== originalId) return false;
  if (v.phase === 'completed') return (v.outcome === 'succeeded' && v.error_code === null) || (v.outcome === 'failed' && codeKnown(v.error_code));
  return ['accepted', 'in_progress', 'unknown'].includes(v.phase as string) && v.outcome === null && v.error_code === null;
}
function dataValid(request: Request, v: unknown): boolean {
  const p = request.params;
  switch (request.operation) {
    case 'capabilities.get': return capabilities(v);
    case 'project.list': return projects(v);
    case 'pane.list': return panes(v) && v.project_id === (p as { project_id: string }).project_id;
    case 'project.open': return object(v, ['project_id', 'created']) && uuid(v.project_id) && typeof v.created === 'boolean';
    case 'project.select': return object(v, ['selected_project_id', 'selected_pane_id']) && v.selected_project_id === (p as { project_id: string | null }).project_id && v.selected_pane_id === null;
    case 'project.forget': return object(v, ['project_id', 'removed']) && v.project_id === (p as { project_id: string }).project_id && v.removed === true;
    case 'pane.create': case 'pane.split': return object(v, ['pane_id', 'run_id']) && uuid(v.pane_id) && uuid(v.run_id) && (request.operation !== 'pane.split' || v.pane_id !== (p as { pane_id: string }).pane_id);
    case 'pane.select': return object(v, ['selected_project_id', 'selected_pane_id']) && nullable(v.selected_project_id, uuid) && v.selected_pane_id === (p as { pane_id: string | null }).pane_id && (v.selected_pane_id === null || v.selected_project_id !== null);
    case 'pane.close': return object(v, ['pane_id', 'closed', 'selected_pane_id']) && v.pane_id === (p as { pane_id: string }).pane_id && v.closed === true && nullable(v.selected_pane_id, uuid) && v.selected_pane_id !== v.pane_id;
    case 'pane.resize': return object(v, ['pane_id', 'run_id', 'rows', 'cols']) && Object.keys(p).every(k => v[k] === (p as unknown as Obj)[k]);
    case 'run.interrupt': return object(v, ['run_id', 'phase']) && v.run_id === (p as { run_id: string }).run_id && v.phase === 'accepted';
    case 'run.get': {
      const cleanup = (p as { include_cleanup?: true }).include_cleanup === true;
      return runReadData(v, (p as { run_id: string }).run_id, cleanup) !== null;
    }
    case 'operation.get': return object(v, ['operation']) && status(v.operation, (p as { operation_id: string }).operation_id);
    default: return false;
  }
}
function responseValid(request: Request, v: unknown): v is Response {
  if (!object(v, ['schema_version', 'instance_id', 'operation_id', 'accepted', 'topology_revision', 'event_seq', 'result', 'error']) || v.schema_version !== 1 || v.instance_id !== request.instance_id || v.operation_id !== request.operation_id || !uint(v.topology_revision) || !uint(v.event_seq)) return false;
  if (v.accepted === true) return v.error === null && object(v.result, ['operation', 'data']) && v.result.operation === request.operation && dataValid(request, v.result.data);
  if (v.accepted !== false || v.result !== null || !object(v.error, ['code', 'retryable', 'message', 'target_id']) || !codeKnown(v.error.code)) return false;
  const [retry, message] = errorDefinitions[v.error.code];
  return v.error.retryable === retry && v.error.message === message && nullable(v.error.target_id, uuid) && (!['invalid_request', 'unsupported_version', 'resource_exhausted'].includes(v.error.code) || v.error.target_id === null);
}

/** Presence check belongs to the GUI builder, not to the legal legacy decoder. */
export function guardedCloseParams(input: unknown): PaneCloseParams {
  if (!object(input, ['pane_id', 'expected_current_run_id']) || !uuid(input.pane_id) || !nullable(input.expected_current_run_id, uuid)) throw new Error('閉鎖対象の期待値を確認できません。');
  return { pane_id: input.pane_id, expected_current_run_id: input.expected_current_run_id as string | null };
}
type Params = Request['params'];
type Spec = { operation: OperationName; params: Params; kind?: 'interrupt'; remaining?: boolean; needsData?: boolean; target?: boolean; next?: (data: Obj) => Spec };
type Stage = { facts: StageFacts; request: Request; spec: Spec; revision: U; payload: Obj | null; code?: ErrorCode };
type Pending = { ticket: number; intent: ControlIntent; ownerKey: OwnerKey; stage: Stage | null; resolve(result: Settlement): void; answered: boolean; working: boolean };
const refusal = '要求は拒否されました。確認済みの前段は保持しています。';
const unknownMessage = '要求の結果または対象を確認できません。同じ要求を送り直さず、状態の読み直しで確認してください。';

export function createProjectPaneController(options: ControllerOptions) {
  if (!uuid(options.instanceId) || !nonempty(options.generation)) throw new Error('操作セッションの識別子が不正です。');
  let disposed = false; let pending: Pending | null = null; let lastTicket = 0; let readEpoch = 0;
  let readTail = Promise.resolve();
  let caps: CapabilitiesData | null = null;
  const usedIds = new Set<string>();
  let snapshot: ViewSnapshot = { instanceId: options.instanceId, generation: options.generation, topologyRevision: 0, projects: { projects: [], selected_project_id: null }, panes: null, availability: 'unavailable', busy: false };
  const alive = (p: Pending, s?: Stage) => !disposed && pending === p && (!s || p.stage === s);
  function emit() { if (!disposed) options.snapshot(structuredClone({ ...snapshot, busy: pending !== null })); }
  function notify(p: Pending, result: Settlement) {
    if (!alive(p)) return;
    if (!p.answered) { p.answered = true; p.resolve(result); }
    options.settlement(p.ticket, result);
  }
  function id() {
    const value = crypto.randomUUID();
    if (!uuid(value) || usedIds.has(value)) throw new Error('操作識別子を生成できません。');
    usedIds.add(value); return value;
  }
  function request(operation: OperationName, params: Params, revision: U): Request {
    const top = ['project.open', 'project.select', 'project.forget', 'pane.create', 'pane.split', 'pane.select', 'pane.close'].includes(operation);
    const req = { schema_version: 1, instance_id: options.instanceId, operation_id: id(), expected_topology_revision: top ? revision : null, operation, params: structuredClone(params) } as Request;
    // The immutable saved request is the source of truth for all later evidence.
    Object.freeze(req.params); return Object.freeze(req);
  }
  async function exchange(req: Request, origin?: OwnerKey) { try {
    const response = origin ? await options.port.recover(origin, req) : await options.port.exchange(req);
    return responseValid(req, response) ? structuredClone(response) : null;
  } catch { return null; } }
  function serial<T>(fn: () => Promise<T>): Promise<T> {
    const promise = readTail.then(fn); readTail = promise.then(() => undefined, () => undefined); return promise;
  }
  async function readSnapshot(publish = true): Promise<ViewSnapshot | null> {
    const epoch = readEpoch;
    const c = await exchange(request('capabilities.get', {}, snapshot.topologyRevision));
    if (disposed || !c?.accepted || !c.result || c.result.operation !== 'capabilities.get') return unavailable();
    const list = await exchange(request('project.list', {}, snapshot.topologyRevision));
    if (disposed || !list?.accepted || !list.result || list.result.operation !== 'project.list' || c.topology_revision !== list.topology_revision) return unavailable();
    const selected = list.result.data.selected_project_id;
    let paneData: PaneListData | null = null;
    if (selected !== null) {
      const rows = await exchange(request('pane.list', { project_id: selected }, list.topology_revision));
      if (disposed || !rows?.accepted || !rows.result || rows.result.operation !== 'pane.list' || rows.topology_revision !== list.topology_revision) return unavailable();
      paneData = rows.result.data;
    }
    const next: ViewSnapshot = { instanceId: options.instanceId, generation: options.generation, topologyRevision: list.topology_revision, projects: list.result.data, panes: paneData, availability: 'available', busy: pending !== null };
    if (!disposed && epoch === readEpoch) { caps = c.result.data; if (publish) { snapshot = next; emit(); } }
    return epoch === readEpoch && !disposed ? next : null;
    function unavailable() { if (!disposed && epoch === readEpoch && publish) { snapshot = { ...snapshot, availability: 'unavailable', error: '表示の状態を確認できません。状態を読み直してください。' }; emit(); } return null; }
  }
  function validateIntent(intent: ControlIntent) {
    if (snapshot.availability !== 'available' || intent.instanceId !== options.instanceId || intent.generation !== options.generation || intent.topologyRevision !== snapshot.topologyRevision) return false;
    if (!projects(snapshot.projects) || (snapshot.panes !== null && (!panes(snapshot.panes) || snapshot.panes.project_id !== snapshot.projects.selected_project_id))) return false;
    if (intent.kind === 'open-folder') return true;
    if (!('projectId' in intent) || !uuid(intent.projectId)) return false;
    const project = snapshot.projects.projects.find(p => p.project_id === intent.projectId);
    if (!project) return false;
    if (intent.kind === 'select-project' || intent.kind === 'forget-project') return true;
    if (snapshot.projects.selected_project_id !== intent.projectId) return false;
    if (intent.kind === 'create-pane') return project.root_state === 'verified';
    if (!('paneId' in intent) || !uuid(intent.paneId) || !nullable(intent.runId, uuid)) return false;
    const pane = snapshot.panes?.panes.find(p => p.pane_id === intent.paneId);
    if (!pane || pane.project_id !== intent.projectId || pane.current_run_id !== intent.runId) return false;
    switch (intent.kind) {
      case 'split-pane': return project.root_state === 'verified' && ['horizontal', 'vertical'].includes(intent.axis);
      case 'resize-pane': return intent.runId !== null && [intent.rows, intent.cols].every(n => Number.isInteger(n) && n >= 1 && n <= 32767);
      case 'interrupt-run': return intent.runId !== null;
      case 'close-pane': return intent.interruptFirst === true ? intent.runId !== null : intent.runId === null || (pane.observation?.process === 'exited' && pane.observation.evidence === 'process_exit');
      case 'select-pane': return true;
      default: return false;
    }
  }
  function shell(): string { const first = caps?.shell_profile_ids?.[0]; if (!nonempty(first)) throw new Error('通常ペインのシェル能力を確認できません。'); return first; }
  function selectPane(paneId: string): Spec { return { operation: 'pane.select', params: { pane_id: paneId } }; }
  function createPane(projectId: string): Spec { return { operation: 'pane.create', params: { project_id: projectId, shell_profile_id: shell() }, remaining: true, needsData: true, next: d => selectPane(d.pane_id as string) }; }
  function close(intent: Extract<ControlIntent, { kind: 'close-pane' | 'select-pane' }>): Spec { return { operation: 'pane.close', params: guardedCloseParams({ pane_id: intent.paneId, expected_current_run_id: intent.runId }) }; }
  function spec(intent: ControlIntent): Spec {
    switch (intent.kind) {
      case 'select-project': return { operation: 'project.select', params: { project_id: intent.projectId } };
      case 'forget-project': return { operation: 'project.forget', params: { project_id: intent.projectId } };
      case 'create-pane': return createPane(intent.projectId);
      case 'split-pane': return { operation: 'pane.split', params: { pane_id: intent.paneId, axis: intent.axis }, remaining: true, needsData: true, next: d => selectPane(d.pane_id as string) };
      case 'select-pane': return selectPane(intent.paneId);
      case 'resize-pane': return { operation: 'pane.resize', params: { pane_id: intent.paneId, run_id: intent.runId, rows: intent.rows, cols: intent.cols } };
      case 'interrupt-run': return { operation: 'run.interrupt', params: { run_id: intent.runId }, kind: 'interrupt' };
      case 'close-pane': return intent.interruptFirst ? { operation: 'run.interrupt', params: { run_id: intent.runId }, kind: 'interrupt', remaining: true, target: true, next: () => close(intent) } : close(intent);
      default: throw new Error('要求の種類を確認できません。');
    }
  }
  function buildStage(spec: Spec, revision: U) {
    const s: Stage = { request: request(spec.operation, spec.params, revision), spec, revision, payload: null, facts: { kind: spec.kind ?? 'instant', remaining: spec.remaining === true, fenced: false, knowledge: 'unresolved', exitFact: 'none', targetFact: spec.target ? 'awaiting' : 'not_required', dataComplete: !spec.needsData, contradiction: false, live: true, nextIssued: false, continuationCleanup: spec.kind === 'interrupt' && spec.remaining ? 'awaiting' : 'not_required' } };
    return s;
  }
  function apply(p: Pending, s: Stage, e: Evidence) { if (alive(p, s)) s.facts = foldStage(s.facts, e); }
  async function finish(p: Pending, s: Stage, result: Settlement) {
    if (!alive(p, s)) return;
    // A direct resize at the observed revision changes dimensions, not the live input target.
    const keepAvailable = p.intent.kind === 'resize-pane' && result.disposition === 'completed' && s.facts.knowledge === 'success' && !s.facts.fenced && !s.facts.contradiction && snapshot.availability === 'available' && s.revision === snapshot.topologyRevision;
    apply(p, s, { kind: 'settlement_committed' }); notify(p, result); pending = null; readEpoch++;
    if (!keepAvailable) snapshot = { ...snapshot, availability: 'unavailable' }; emit();
    await serial(() => readSnapshot());
  }
  async function issue(p: Pending, s: Stage) {
    const response = await exchange(s.request);
    if (!alive(p, s)) return;
    if (!response) apply(p, s, { kind: 'rpc_invalid' });
    else if (response.accepted && response.result) { s.payload = response.result.data as unknown as Obj; s.revision = response.topology_revision; apply(p, s, { kind: 'rpc_success' }); }
    else if (response.error) { s.code = response.error.code; apply(p, s, { kind: 'rpc_error', code: s.code }); }
    await drive(p, s, true);
  }
  async function inspectRun(p: Pending, s: Stage) {
    if (!('paneId' in p.intent) || !p.intent.runId) return;
    const cleanup = s.facts.remaining && !s.facts.fenced && s.facts.dataComplete;
    const response = await exchange(request('run.get', cleanup ? { include_cleanup: true, run_id: p.intent.runId } : { run_id: p.intent.runId }, s.revision));
    if (!alive(p, s)) return;
    const data = response?.accepted && response.result?.operation === 'run.get' ? response.result.data : null;
    s.facts = foldRunReadiness(s.facts, runReadData(data, p.intent.runId, cleanup), p.intent.paneId);
  }
  async function inspectTarget(p: Pending, s: Stage) {
    const fresh = await serial(() => readSnapshot());
    if (!alive(p, s) || !('paneId' in p.intent)) return;
    const target = p.intent;
    const pane = fresh?.panes?.project_id === target.projectId ? fresh.panes.panes.find(row => row.pane_id === target.paneId) : undefined;
    apply(p, s, { kind: 'target_fact', fact: !fresh ? 'unknown' : !pane || pane.current_run_id !== p.intent.runId ? 'changed' : 'verified' });
    if (fresh && s.facts.targetFact === 'verified') s.revision = fresh.topologyRevision;
  }
  async function drive(p: Pending, s: Stage, readOnce: boolean): Promise<void> {
    if (!alive(p, s)) return;
    const decision = decideStage(s.facts);
    if (decision === 'inspect_run' || (decision === 'hold_unknown' && s.facts.knowledge === 'success' && s.facts.kind === 'interrupt' && (s.facts.exitFact !== 'exited_same' || s.facts.continuationCleanup === 'unknown') && !s.facts.contradiction)) {
      if (readOnce) { await inspectRun(p, s); await drive(p, s, false); return; }
    } else if (decision === 'inspect_snapshot' || (decision === 'hold_unknown' && s.facts.knowledge === 'success' && s.facts.targetFact === 'unknown' && !s.facts.contradiction)) {
      if (readOnce) { await inspectTarget(p, s); await drive(p, s, false); return; }
    } else if (decision === 'advance_once') {
      let stage: Stage;
      try { const next = s.spec.next?.(s.payload ?? {}); if (!next) throw new Error('後続対象を確認できません。'); stage = buildStage(next, s.revision); }
      catch { if (alive(p, s)) { s.facts = { ...s.facts, dataComplete: false }; await drive(p, s, false); } return; }
      apply(p, s, { kind: 'advance_committed' });
      if (!alive(p, s)) return;
      p.stage = stage; await issue(p, stage);
      return;
    } else if (decision === 'settle_refused' || decision === 'settle_partial_refused' || decision === 'settle_completed') {
      await finish(p, s, { disposition: decision === 'settle_completed' ? 'completed' : 'refused', message: decision === 'settle_completed' ? '要求した操作と必要な終了確認が完了しました。' : decision === 'settle_partial_refused' ? '元操作の結果を確認しました。確認済みの前段を保持し、残る操作は送信していません。' : s.facts.targetFact === 'changed' ? '確認した対象が変わったため、後続の閉鎖を送信していません。' : refusal }); return;
    }
    if (alive(p, s) && decision !== 'await_rpc' && decision !== 'ignore') { snapshot = { ...snapshot, error: s.facts.kind === 'interrupt' && s.facts.knowledge === 'success' ? '同じ実行の中断・終了を確認中です。' : unknownMessage }; notify(p, { disposition: 'unknown', message: snapshot.error }); emit(); }
  }
  function control(intent: ControlIntent, ticket: number): Promise<Settlement> {
    if (disposed || pending || !Number.isSafeInteger(ticket) || ticket <= lastTicket || !validateIntent(intent)) return Promise.resolve({ disposition: 'refused', message: '操作対象または操作受付を確認できません。' });
    lastTicket = ticket; readEpoch++;
    let resolve!: (result: Settlement) => void;
    const promise = new Promise<Settlement>(done => { resolve = done; });
    const p: Pending = { ticket, intent: structuredClone(intent), ownerKey: options.ownerKey, stage: null, resolve, answered: false, working: true }; pending = p; emit();
    void (async () => {
      try {
        let first: Spec;
        if (intent.kind === 'open-folder') {
          const path = await options.pickFolder();
          if (!alive(p)) return;
          if (path === null) { notify(p, { disposition: 'completed', message: 'フォルダー選択を取り消しました。' }); pending = null; emit(); return; }
          if (!nonempty(path)) throw new Error('フォルダーを確認できません。');
          first = { operation: 'project.open', params: { path }, remaining: true, needsData: true, next: d => ({ operation: 'project.select', params: { project_id: d.project_id as string }, remaining: d.created === true, next: d.created === true ? () => createPane(d.project_id as string) : undefined }) };
        } else first = spec(intent);
        if (alive(p)) { const stage = buildStage(first, intent.topologyRevision); p.stage = stage; await issue(p, stage); }
      } catch { if (alive(p) && p.stage === null) { notify(p, { disposition: 'refused', message: '要求を構築できなかったため送信していません。' }); pending = null; emit(); } else if (alive(p) && p.stage) { apply(p, p.stage, { kind: 'rpc_unavailable' }); await drive(p, p.stage, false); } }
      finally { if (alive(p)) p.working = false; }
    })();
    return promise;
  }
  async function refresh() {
    const p = pending;
    if (!p) { await serial(() => readSnapshot()); return; }
    if (p.working || !p.stage || !alive(p)) return;
    p.working = true;
    try {
      const s = p.stage;
      if (s.facts.knowledge === 'awaiting_record' || s.facts.knowledge === 'unknown') {
        const got = await exchange(request('operation.get', { operation_id: s.request.operation_id }, s.revision), p.ownerKey);
        if (!alive(p, s)) return;
        if (!got?.accepted || got.result?.operation !== 'operation.get') apply(p, s, { kind: 'query_outer_failure' });
        else {
          const saved = got.result.data.operation;
          if (saved.phase === 'completed' && saved.outcome === 'succeeded') apply(p, s, { kind: 'record_success' });
          else if (saved.phase === 'completed' && saved.outcome === 'failed' && saved.error_code) { s.code = saved.error_code; apply(p, s, { kind: 'record_error', code: saved.error_code }); }
          else apply(p, s, { kind: saved.phase === 'unknown' ? 'record_absent' : 'record_wait' });
        }
      }
      if (alive(p, s)) await drive(p, s, true);
    } finally { if (alive(p)) p.working = false; }
  }
  async function inspect(intent: InspectionIntent) {
    if (disposed || intent.instanceId !== options.instanceId || intent.generation !== options.generation || intent.topologyRevision !== snapshot.topologyRevision) return;
    if (intent.kind === 'reread') { await refresh(); return; }
    const epoch = readEpoch;
    const result = await serial(() => exchange(request('capabilities.get', {}, snapshot.topologyRevision)));
    if (disposed || epoch !== readEpoch) return;
    options.installation(result?.accepted && result.result?.operation === 'capabilities.get' ? result.result.data : null, result?.accepted ? undefined : '導入状況を確認できません。');
  }
  return {
    control, inspect, refresh,
    getSnapshot: () => structuredClone({ ...snapshot, busy: pending !== null }),
    getPending: () => pending?.stage ? structuredClone({ ticket: pending.ticket, intent: pending.intent, request: pending.stage.request, facts: pending.stage.facts }) : null,
    dispose() { disposed = true; readEpoch++; if (pending && !pending.answered) pending.resolve({ disposition: 'unknown', message: '操作画面が終了したため確認を停止しました。' }); pending = null; },
  };
}
