import type { ArtifactDiffData, ArtifactListData, ArtifactReadData, ArtifactRef, DiagnosticsData, ErrorCode, OperationName, OperationStatus, PaneSummary, ProjectSummary, Request, Response } from '../generated/workspace-contract';
import { createDetails, createDetailsSession, type DetailsHostLifetime, type DetailsIntent, type DetailsResult, type DetailsSnapshot, type DetailsTerminal } from './details';
import type { ViewSnapshot } from './project-pane';
import { createRecoveryReadGate } from './recovery-read';
import type { OwnerKey } from './project-pane-controller';

type Exchange = (request: Request) => Promise<Response>;
export interface DetailsBinding {
  ownerKey: OwnerKey;
  exchange: Exchange;
  recover: (origin: OwnerKey, request: Request) => Promise<Response>;
  pane: () => ViewSnapshot;
  refreshPane: () => Promise<ViewSnapshot | null>;
  maxBytes: () => number;
  pickFile: () => Promise<string | null>;
  copy: (text: string) => Promise<boolean>;
}
export interface DetailsControlAdmission {
  acquire(kind: 'register' | 'restore', ticket: string): (() => void) | null;
}
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const uint = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const record = (v: unknown, keys: readonly string[]): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === keys.length && keys.every(k => Object.prototype.hasOwnProperty.call(v, k));
const codes: readonly ErrorCode[] = ['invalid_request', 'unsupported_version', 'permission_denied', 'target_not_found', 'stale_topology', 'operation_conflict', 'in_progress', 'not_running', 'already_running', 'unsupported_capability', 'output_gap', 'persistence_failed', 'runtime_failed', 'state_unknown', 'resource_exhausted', 'root_changed', 'unsupported_file', 'not_a_repository'];
const errorCode = (v: unknown): v is ErrorCode => codes.includes(v as ErrorCode);
const sameOperation = (request: Request, response: unknown): response is Response => record(response, ['schema_version', 'instance_id', 'operation_id', 'accepted', 'topology_revision', 'event_seq', 'result', 'error'])
  && response.schema_version === 1 && response.instance_id === request.instance_id && response.operation_id === request.operation_id
  && uint(response.topology_revision) && uint(response.event_seq)
  && (response.accepted === true ? response.error === null && record(response.result, ['operation', 'data']) && response.result.operation === request.operation
    : response.accepted === false && response.result === null && record(response.error, ['code', 'retryable', 'message', 'target_id']) && errorCode(response.error.code));
const statusValid = (v: unknown, ticket: string): v is OperationStatus => record(v, ['operation_id', 'phase', 'outcome', 'error_code']) && v.operation_id === ticket
  && (v.phase === 'completed' ? v.outcome === 'succeeded' && v.error_code === null || v.outcome === 'failed' && errorCode(v.error_code)
    : ['accepted', 'in_progress', 'unknown'].includes(v.phase as string) && v.outcome === null && v.error_code === null);
const artifactValid = (v: unknown, projectId: string): v is ArtifactRef => record(v, ['artifact_id', 'project_id', 'relative_path', 'association', 'run_id']) && uuid(v.artifact_id)
  && v.project_id === projectId && typeof v.relative_path === 'string' && relative(v.relative_path)
  && (v.association === null && v.run_id === null || v.association === 'caller_selected' && uuid(v.run_id));
const relative = (v: string) => v.length > 0 && !/[\p{Cc}\\:]/u.test(v) && v.split('/').every(part => part.length > 0 && part !== '.' && part !== '..' && !/[. ]$/.test(part)
  && !/^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$/i.test(part.split('.')[0]));
const listValid = (v: unknown, projectId: string): v is ArtifactListData => record(v, ['registered', 'git_candidates']) && Array.isArray(v.registered) && Array.isArray(v.git_candidates)
  && v.registered.every(a => artifactValid(a, projectId)) && new Set(v.registered.map(a => a.artifact_id)).size === v.registered.length
  && v.git_candidates.every((p: unknown) => typeof p === 'string' && relative(p)) && new Set(v.git_candidates).size === v.git_candidates.length;
const projectValid = (v: unknown): v is ProjectSummary => record(v, ['project_id', 'root_state', 'display_name', 'path']) && uuid(v.project_id)
  && ['verified', 'changed', 'unavailable', 'unknown'].includes(v.root_state as string)
  && (v.path === null || typeof v.path === 'string') && (v.display_name === null || typeof v.display_name === 'string');
function stoppedPaneList(v: unknown, projectId: string): v is { project_id: string; panes: PaneSummary[]; root: unknown; selected_pane_id: string | null } {
  if (!record(v, ['project_id', 'panes', 'root', 'selected_pane_id']) || v.project_id !== projectId || !Array.isArray(v.panes)) return false;
  const ids = new Set<string>();
  for (const pane of v.panes) {
    if (!record(pane, ['pane_id', 'project_id', 'current_run_id', 'observation', 'display_name', 'path']) || !uuid(pane.pane_id) || ids.has(pane.pane_id)
      || pane.project_id !== projectId || pane.current_run_id !== null || pane.observation !== null
      || pane.display_name !== null && typeof pane.display_name !== 'string' || pane.path !== null && typeof pane.path !== 'string') return false;
    ids.add(pane.pane_id);
  }
  if (v.selected_pane_id !== null && !ids.has(v.selected_pane_id as string)) return false;
  const leaves = new Set<string>();
  const walk = (node: unknown, depth: number): boolean => {
    if (depth > 7) return false;
    if (record(node, ['kind', 'pane_id'])) {
      if (node.kind !== 'leaf' || !uuid(node.pane_id) || !ids.has(node.pane_id) || leaves.has(node.pane_id)) return false;
      leaves.add(node.pane_id); return true;
    }
    return record(node, ['kind', 'axis', 'ratio', 'first', 'second']) && node.kind === 'split'
      && ['horizontal', 'vertical'].includes(node.axis as string) && typeof node.ratio === 'number' && Number.isFinite(node.ratio)
      && node.ratio > 0 && node.ratio < 1 && walk(node.first, depth + 1) && walk(node.second, depth + 1);
  };
  return v.root === null ? ids.size === 0 : walk(v.root, 0) && leaves.size === ids.size;
}
function driveRelative(root: string, picked: string): string | null {
  const parse = (v: string) => {
    const drivePath = v.startsWith('\\\\?\\') ? v.slice(4) : v;
    if (!/^[A-Za-z]:\\/.test(drivePath) || drivePath.includes('/') || drivePath.startsWith('\\\\')) return null;
    const tail = drivePath.slice(3);
    const parts = tail === '' ? [] : tail.split('\\');
    return parts.every(part => relative(part)) ? { drive: drivePath[0].toLowerCase(), parts } : null;
  };
  const rootDrive = root.startsWith('\\\\?\\') ? root.slice(4) : root;
  const r = parse(rootDrive.length > 3 && root.endsWith('\\') ? root.slice(0, -1) : root), p = parse(picked);
  if (!r || !p || r.drive !== p.drive || p.parts.length <= r.parts.length) return null;
  const same = (a: string, b: string) => /^[\x20-\x7e]+$/.test(a + b) ? a.toLowerCase() === b.toLowerCase() : a === b;
  if (!r.parts.every((part, i) => same(part, p.parts[i]))) return null;
  const path = p.parts.slice(r.parts.length).join('/');
  return relative(path) ? path : null;
}
const uncertainTransport = (error: unknown) => error === 'transport_uncertain' || error instanceof Error && error.message === 'transport_uncertain';
const freshId = (crypto: Crypto): string => {
  const bytes = crypto.getRandomValues(new Uint8Array(16)); bytes[6] = bytes[6] & 15 | 64; bytes[8] = bytes[8] & 63 | 128;
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};

interface MutationFlight {
  ownerKey: OwnerKey;
  ticket: string;
  intent: Extract<DetailsIntent, {kind: 'register' | 'restore'}>;
  port: DetailsBinding | null;
  portEpoch: number;
  targetEpoch: number;
  snapshot: DetailsSnapshot | null;
  phase: 'preparing' | 'sent' | 'terminal';
  payload: DetailsResult | null;
  payloadConflict: boolean;
  replyObserved: boolean;
  path: string | null;
  checkAttempt: ReadAttempt | null;
  release: (() => void) | null;
}
type ReadAttempt = NonNullable<ReturnType<ReturnType<typeof createRecoveryReadGate>['begin']>>;

/** One controller and request ledger per actual Rust host, independent of view recreation. */
export function createDetailsController(lifetime: DetailsHostLifetime, crypto: Crypto, admission?: DetailsControlAdmission) {
  const session = createDetailsSession(lifetime, crypto);
  let binding: DetailsBinding | null = null;
  let view: ReturnType<typeof createDetails> | null = null;
  let revision = 0, selectionRevision = 0, artifactsRevision = 0;
  let selectedProjectId: string | null = null;
  let last: DetailsSnapshot | null = null;
  let mutation: MutationFlight | null = null;
  let targetEpoch = 0, portEpoch = 0, targetKey: string | null = null;
  let blockedAtPortEpoch: number | null = null;
  const readGate = createRecoveryReadGate();
  const message = '元操作の完了は未確認です。再送せず状態を確認してください。';
  function fromPane(pane: ViewSnapshot): DetailsSnapshot {
    const project = pane.projects.projects.find(p => p.project_id === pane.projects.selected_project_id) ?? null;
    const projectId = project?.project_id ?? null;
    if (projectId !== selectedProjectId) { selectedProjectId = projectId; selectionRevision++; }
    return {
      instanceId: lifetime.instanceId, generation: lifetime.nonce, revision: ++revision,
      selectionRevision, artifactsRevision,
      availability: binding && pane.availability === 'available' && !pane.busy ? 'available' : 'unavailable',
      project, artifacts: null, selectedArtifactId: null, maxBytes: Math.max(1, binding?.maxBytes() ?? 1),
    };
  }
  function publish(pane: ViewSnapshot) {
    if (session.isRetired()) return;
    const preparing = mutation?.phase === 'preparing' ? mutation : null;
    const selected = pane.projects.projects.find(p => p.project_id === pane.projects.selected_project_id) ?? null;
    const key = JSON.stringify([pane.instanceId, pane.generation, pane.availability, pane.busy,
      pane.projects.selected_project_id, selected?.project_id ?? null, selected?.root_state ?? null, selected?.path ?? null]);
    const changed = key !== targetKey;
    if (changed) { targetKey = key; targetEpoch++; }
    last = fromPane(pane);
    view?.update(last);
    if (changed && preparing && mutation === preparing) refused(preparing.intent, preparing.ticket, 'root_changed');
  }
  function request(operation: OperationName, params: object, operationId: string = freshId(crypto), expected: number | null = null): Request {
    return { schema_version: 1, instance_id: lifetime.instanceId, operation_id: operationId as Request['operation_id'], expected_topology_revision: expected, operation, params } as Request;
  }
  async function exchange(req: Request): Promise<Response> {
    if (!binding || session.isTransportBlocked()) throw new Error('transport_unavailable');
    const response = await binding.exchange(req);
    if (!sameOperation(req, response)) throw new Error('protocol_failed');
    return response;
  }
  function reserveMutation(intent: Extract<DetailsIntent, {kind: 'register' | 'restore'}>, ticket: string): boolean {
    if (mutation || !binding) return false;
    const release = admission?.acquire(intent.kind, ticket) ?? (admission ? null : () => {});
    if (!release) return false;
    const snapshot = last === null ? null : structuredClone(last);
    const flight: MutationFlight = { ownerKey: binding.ownerKey, ticket, intent, port: binding, portEpoch, targetEpoch, snapshot,
      phase: 'preparing', payload: null, payloadConflict: false, replyObserved: false, path: null, checkAttempt: null, release };
    mutation = flight;
    return true;
  }
  function finishFlight(flight: MutationFlight, terminal: DetailsTerminal): boolean {
    if (mutation !== flight || flight.phase === 'terminal') return false;
    const previous = flight.phase;
    flight.phase = 'terminal'; mutation = null;
    const applied = session.settleMutation(flight.ticket, lifetime, flight.intent, terminal);
    if (!applied && mutation === null && session.matchesMutation(flight.ticket, lifetime, flight.intent)) {
      flight.phase = previous; mutation = flight;
    }
    if (applied) { flight.release?.(); flight.release = null; }
    return applied;
  }
  function projectRead(intent: DetailsIntent, ticket: string, result: DetailsResult) {
    if (view?.commitProjection({ ticket, intent, result }) !== true) session.abandonRead(ticket);
  }
  function refused(intent: DetailsIntent, ticket: string, code: ErrorCode) {
    if (intent.kind === 'register' || intent.kind === 'restore') {
      const flight = mutation;
      if (!flight || flight.ticket !== ticket || !finishFlight(flight, { kind: 'refused', code })) return;
      view?.commitProjection({ ticket, intent, result: { kind: 'error', code } });
    } else projectRead(intent, ticket, { kind: 'error', code });
  }
  function unknown(intent: DetailsIntent, ticket: string, error: unknown) {
    if (uncertainTransport(error)) { blockedAtPortEpoch ??= portEpoch; session.blockTransport(); }
    else session.markUnknown(ticket);
    if (intent.kind !== 'register' && intent.kind !== 'restore')
      projectRead(intent, ticket, { kind: 'unconfirmed', message: session.isTransportBlocked()
        ? '接続状態が不明で復旧操作を受け付けられません。元操作の完了は未確認です。' : message });
  }
  async function status(ticket: string, origin: OwnerKey, port: DetailsBinding): Promise<OperationStatus | null> {
    const req = request('operation.get', { operation_id: ticket });
    const r = await port.recover(origin, req);
    if (!sameOperation(req, r)) return null;
    if (!r.accepted || r.result?.operation !== 'operation.get' || !statusValid(r.result.data.operation, ticket)) return null;
    return r.result.data.operation;
  }
  async function readOn(port: DetailsBinding, req: Request): Promise<Response> {
    const response = await port.exchange(req);
    if (!sameOperation(req, response)) throw new Error('protocol_failed');
    return response;
  }
  async function restored(data: Extract<DetailsResult, {kind: 'restore'}>['data'], port: DetailsBinding, current: () => boolean): Promise<DetailsResult | null> {
    if (!current()) return null;
    const projects = await readOn(port, request('project.list', {}));
    if (!current()) return null;
    if (!projects.accepted || projects.result?.operation !== 'project.list') return null;
    const payload = projects.result.data;
    if (!Array.isArray(payload.projects) || !payload.projects.every(projectValid) || new Set(payload.projects.map(p => p.project_id)).size !== payload.projects.length
      || payload.selected_project_id !== null && !payload.projects.some(p => p.project_id === payload.selected_project_id)) return null;
    const topology = projects.topology_revision, panes: PaneSummary[] = [], ids = new Set<string>();
    for (const project of payload.projects) {
      if (!current()) return null;
      const response = await readOn(port, request('pane.list', { project_id: project.project_id }));
      if (!current()) return null;
      if (!response.accepted || response.result?.operation !== 'pane.list' || response.topology_revision !== topology) return null;
      const list = response.result.data;
      if (!stoppedPaneList(list, project.project_id)) return null;
      for (const pane of list.panes) {
        if (ids.has(pane.pane_id)) return null;
        ids.add(pane.pane_id); panes.push(pane);
      }
    }
    if (!current()) return null;
    const stable = await readOn(port, request('project.list', {}));
    if (!current()) return null;
    if (!stable.accepted || stable.result?.operation !== 'project.list' || stable.topology_revision !== topology
      || JSON.stringify(stable.result.data) !== JSON.stringify(payload)) return null;
    return { kind: 'restore', data, observedInstanceId: lifetime.instanceId, observedGeneration: data.generation, projects: payload.projects, panes };
  }
  async function registerRecovered(flight: MutationFlight, port: DetailsBinding, current: () => boolean): Promise<DetailsResult | null> {
    const projectId = flight.intent.projectId;
    if (!projectId || !flight.path || !current()) return null;
    const r = await readOn(port, request('artifact.list', { project_id: projectId }));
    if (!current()) return null;
    if (!r.accepted || r.result?.operation !== 'artifact.list' || !listValid(r.result.data, projectId)) return null;
    const matches = r.result.data.registered.filter(a => a.relative_path === flight.path);
    return matches.length === 1 ? { kind: 'register', artifact: matches[0] } : null;
  }
  async function reconcile() {
    const flight = mutation;
    const port = binding;
    if (!flight || flight.phase !== 'sent' || !flight.replyObserved || flight.checkAttempt || session.isTransportBlocked() || !port) return;
    const attempt = readGate.begin();
    if (!attempt) return;
    flight.checkAttempt = attempt;
    const currentPort = () => binding === port && portEpoch === attempt.epoch
      && (flight.phase === 'terminal' || readGate.current(attempt));
    const currentFlight = () => currentPort() && mutation === flight;
    try {
      const terminal = await status(flight.ticket, flight.ownerKey, port);
      if (!currentFlight()) return;
      if (!terminal) { session.markUnknown(flight.ticket); return; }
      if (terminal.phase !== 'completed') { session.markUnknown(flight.ticket); return; }
      const applied = finishFlight(flight, { kind: 'completed', operation: terminal } satisfies DetailsTerminal);
      if (!applied) return;
      // The authoritative Q has finished. Later inventory reads only project its
      // result and must not serialize the next mutation's terminal Q.
      readGate.end(attempt);
      if (flight.checkAttempt === attempt) flight.checkAttempt = null;
      if (terminal.outcome === 'failed' && terminal.error_code) {
        if (currentPort()) view?.commitProjection({ ticket: flight.ticket, intent: flight.intent, result: { kind: 'error', code: terminal.error_code } });
        return;
      }
      let result = flight.payload;
      if (flight.intent.kind === 'register' && !result && !flight.payloadConflict) result = await registerRecovered(flight, port, currentPort);
      if (!currentPort()) return;
      if (flight.intent.kind === 'restore' && result?.kind === 'restore') {
        result = await restored(result.data, port, currentPort);
        if (!currentPort()) return;
        if (!await port.refreshPane()) result = null;
      }
      if (currentPort()) view?.commitProjection({ ticket: flight.ticket, intent: flight.intent, result: result ?? { kind: 'unconfirmed', message: '操作は終端しましたが、結果の表示は未確認です。' } });
    } catch (error) { if (currentFlight()) unknown(flight.intent, flight.ticket, error); }
    finally { if (flight.checkAttempt === attempt) flight.checkAttempt = null; readGate.end(attempt); }
  }
  async function recoverSameHost() {
    const port = binding;
    if (!port || port.pane().instanceId !== lifetime.instanceId || session.isRetired()) return;
    const flight = mutation;
    if (flight?.phase === 'sent' && !flight.checkAttempt && portEpoch > flight.portEpoch) {
      const attempt = readGate.begin();
      if (!attempt) return;
      flight.checkAttempt = attempt;
      const currentFlight = () => mutation === flight && binding === port && readGate.current(attempt);
      try {
        // The original ticket is the only read allowed while transport is
        // blocked. It cannot wait for the original mutation delivery promise.
        const req = request('operation.get', { operation_id: flight.ticket });
        const response = await port.recover(flight.ownerKey, req);
        if (!currentFlight()) return;
        if (!sameOperation(req, response) || !response.accepted || response.result?.operation !== 'operation.get'
          || !statusValid(response.result.data.operation, flight.ticket)) { session.markUnknown(flight.ticket); return; }
        const original = response.result.data.operation;
        if (original.phase !== 'completed') { session.markUnknown(flight.ticket); return; }
        finishFlight(flight, { kind: 'completed', operation: original });
      } catch { if (currentFlight()) session.markUnknown(flight.ticket); }
      finally { if (flight.checkAttempt === attempt) flight.checkAttempt = null; readGate.end(attempt); }
    }
    if (session.isTransportBlocked() && mutation === null && binding === port && blockedAtPortEpoch !== null && portEpoch > blockedAtPortEpoch) {
      try {
        const fresh = await port.refreshPane();
        if (binding === port && fresh?.instanceId === lifetime.instanceId && fresh.availability === 'available'
          && session.confirmRecoveredTransport(lifetime)) { blockedAtPortEpoch = null; publish(fresh); }
      } catch { /* The original terminal is known; normal admission stays blocked. */ }
    }
  }
  async function submit(intent: DetailsIntent, ticket: string) {
    const flight: MutationFlight | null = intent.kind === 'register' || intent.kind === 'restore'
      ? mutation?.ticket === ticket && session.matchesMutation(ticket, lifetime, intent) ? mutation : null : null;
    if ((intent.kind === 'register' || intent.kind === 'restore') && (!flight || flight.phase !== 'preparing')) return;
    const port = flight ? flight.port : binding;
    const submittedPortEpoch = flight?.portEpoch ?? portEpoch, submittedTargetEpoch = flight?.targetEpoch ?? targetEpoch;
    const originCurrent = () => binding === port && portEpoch === submittedPortEpoch;
    const admitted = flight ? flight.snapshot : last;
    if (!port || session.isTransportBlocked() || !admitted || admitted.availability !== 'available' || intent.instanceId !== lifetime.instanceId || intent.generation !== lifetime.nonce) {
      refused(intent, ticket, 'state_unknown'); return;
    }
    const project = admitted.project;
    if (intent.kind !== 'restore' && intent.kind !== 'diagnostics' && (!project || project.project_id !== intent.projectId || project.root_state !== 'verified' || !project.path)) {
      refused(intent, ticket, 'root_changed'); return;
    }
    let operation: OperationName, params: object, expected: number | null = null, path: string | null = null;
    try {
      switch (intent.kind) {
        case 'restore': operation = 'layout.restore'; params = {}; expected = port.pane().topologyRevision; break;
        case 'diagnostics': operation = 'diagnostics.get'; params = {}; break;
        case 'list': operation = 'artifact.list'; params = { project_id: intent.projectId }; break;
        case 'read': case 'diff': operation = intent.kind === 'read' ? 'artifact.read' : 'artifact.diff'; params = { artifact_id: intent.artifactId, max_bytes: intent.maxBytes }; break;
        case 'register': {
          if (intent.source === 'picker') {
            const picked = await port.pickFile();
            if (mutation !== flight || flight?.phase !== 'preparing') return;
            if (picked === null) { if (flight && finishFlight(flight, { kind: 'picker-cancelled' }))
              view?.commitProjection({ ticket, intent, result: { kind: 'unconfirmed', message: 'ファイル選択を取り消しました。' } }); return; }
            const fresh = binding?.pane(), freshProject = fresh?.projects.projects.find(p => p.project_id === fresh.projects.selected_project_id);
            if (!fresh || binding !== port || portEpoch !== submittedPortEpoch || targetEpoch !== submittedTargetEpoch
              || fresh.instanceId !== lifetime.instanceId || freshProject?.project_id !== project?.project_id
              || freshProject?.root_state !== 'verified' || freshProject.path !== project?.path || session.isTransportBlocked()) {
              refused(intent, ticket, 'root_changed'); return;
            }
            path = driveRelative(project!.path!, picked);
            if (!path) { refused(intent, ticket, 'permission_denied'); return; }
          } else path = intent.relativePath;
          if (!path || !relative(path)) { refused(intent, ticket, 'invalid_request'); return; }
          operation = 'artifact.register'; params = { project_id: intent.projectId, relative_path: path, run_id: null }; break;
        }
      }
      const req = request(operation, params, ticket, expected);
      if (flight) {
        if (mutation !== flight || flight.phase !== 'preparing' || binding !== port || portEpoch !== submittedPortEpoch || targetEpoch !== submittedTargetEpoch || session.isTransportBlocked()) {
          if (mutation === flight) refused(intent, ticket, 'root_changed');
          return;
        }
        if (intent.kind === 'register' && (!path || !session.prepareMutationPath(ticket, lifetime, intent, path))) { refused(intent, ticket, 'invalid_request'); return; }
        flight.path = path;
        flight.phase = 'sent';
      }
      const response = flight ? await port.exchange(req) : await exchange(req);
      if (!originCurrent()) { if (!flight) session.abandonRead(ticket); return; }
      if (flight) {
        flight.replyObserved = true;
        if (mutation !== flight) return;
        if (!sameOperation(req, response)) { flight.payloadConflict = true; throw new Error('protocol_failed'); }
      }
      if (!response.accepted) {
        const code = response.error!.code;
        if (intent.kind === 'register' || intent.kind === 'restore') {
          if (code === 'state_unknown' || code === 'in_progress') {
            session.markUnknown(ticket);
            if (!session.isTransportBlocked()) await reconcile();
          } else refused(intent, ticket, code);
        }
        else projectRead(intent, ticket, { kind: 'error', code });
        return;
      }
      if (!response.result) throw new Error('protocol_failed');
      const data: unknown = response.result.data;
      if (intent.kind === 'register' || intent.kind === 'restore') {
        if (intent.kind === 'register') {
          if (record(data, ['artifact']) && artifactValid(data.artifact, intent.projectId!) && data.artifact.relative_path === flight!.path)
            flight!.payload = { kind: 'register', artifact: data.artifact };
          else flight!.payloadConflict = true;
        }
        if (intent.kind === 'restore' && record(data, ['restored', 'generation']) && data.restored === true && uint(data.generation)) flight!.payload = { kind: 'restore', data: { restored: true, generation: data.generation }, observedInstanceId: lifetime.instanceId, observedGeneration: data.generation, projects: [], panes: [] };
        await reconcile(); return;
      }
      let result: DetailsResult | null = null;
      if (intent.kind === 'list' && listValid(data, intent.projectId!)) result = { kind: 'list', data };
      if ((intent.kind === 'read' || intent.kind === 'diff') && record(data, intent.kind === 'read' ? ['artifact_id', 'kind', 'size_bytes', 'text', 'truncated'] : ['artifact_id', 'kind', 'text', 'truncated'])
        && data.artifact_id === intent.artifactId && (data.kind === 'binary' ? data.text === null && data.truncated === false : data.kind === 'text' && typeof data.text === 'string' && typeof data.truncated === 'boolean')) {
        if (intent.kind === 'read' && uint(data.size_bytes)) result = { kind: 'read', data: data as ArtifactReadData };
        if (intent.kind === 'diff') result = { kind: 'diff', data: data as ArtifactDiffData };
      }
      if (intent.kind === 'diagnostics' && record(data, ['protocol_version', 'product_version', 'connection_state', 'capabilities', 'failure_codes'])) result = { kind: 'diagnostics', data: data as DiagnosticsData };
      projectRead(intent, ticket, result ?? { kind: 'unconfirmed', message: '応答の対象または内容を確認できません。' });
    } catch (error) {
      if (!originCurrent()) { if (!flight) session.abandonRead(ticket); return; }
      if (flight && mutation !== flight) return;
      if (flight?.phase === 'preparing') { refused(intent, ticket, 'runtime_failed'); return; }
      if (flight) flight.replyObserved = true;
      unknown(intent, ticket, error);
      if (flight && !session.isTransportBlocked()) await reconcile();
    }
  }
  return {
    lifetime, session,
    bind(next: DetailsBinding) { const preparing = mutation?.phase === 'preparing' ? mutation : null; readGate.invalidate(); if (mutation) mutation.checkAttempt = null; portEpoch++; binding = next; publish(next.pane()); if (preparing && mutation === preparing) refused(preparing.intent, preparing.ticket, 'root_changed'); void reconcile(); },
    disconnect() { const preparing = mutation?.phase === 'preparing' ? mutation : null; readGate.invalidate(); if (mutation) mutation.checkAttempt = null; portEpoch++; binding = null; targetEpoch++; if (last) { last = { ...last, revision: ++revision, availability: 'unavailable' }; view?.update(last); } if (preparing && mutation === preparing) refused(preparing.intent, preparing.ticket, 'state_unknown'); },
    updatePane: publish,
    open(container: HTMLElement, origin?: HTMLElement) {
      view?.dispose();
      const initial = last ?? { instanceId: lifetime.instanceId, generation: lifetime.nonce, revision: ++revision, selectionRevision, artifactsRevision, availability: 'unavailable' as const, project: null, artifacts: null, selectedArtifactId: null, maxBytes: 1 };
      view = createDetails(container, initial, session, {
        selectionChanged: () => { /* The session already owns local artifact selection. */ },
        reserveMutation,
        submit: (intent, ticket) => submit(intent, ticket),
        copy: text => binding?.copy(text) ?? Promise.resolve(false),
      }, origin);
      return () => { view?.dispose(); view = null; };
    },
    refresh: reconcile,
    recoverSameHost,
    blockTransport: () => { blockedAtPortEpoch ??= portEpoch; session.blockTransport(); },
    retire() { session.retireHost(lifetime); mutation?.release?.(); mutation = null; view?.dispose(); view = null; binding = null; },
  };
}

export { driveRelative };
