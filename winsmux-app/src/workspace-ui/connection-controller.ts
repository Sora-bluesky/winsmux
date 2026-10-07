import type { ConnectionInfo, OperationStatus, Request, Response, Scope } from '../generated/workspace-contract';
import type { ControlLease } from './control-admission';
import type { OwnerKey } from './project-pane-controller';

export interface ConnectionPort {
  readonly ownerKey: OwnerKey;
  exchange(request: Request): Promise<Response>;
  recover(origin: OwnerKey, request: Request): Promise<Response>;
  reserve(ticket: string): ControlLease | null | Promise<ControlLease | null>;
  release(lease: ControlLease): void;
  transportUncertain(): void;
}

interface ConnectionOperationRecord {
  ownerKey: OwnerKey;
  id: string;
  action: 'allow' | 'deny' | 'revoke';
  connectionId: string;
  projectIds: string[];
  scopes: Scope[];
  phase: string;
  outcome: string | null;
  errorCode: string | null;
}
export interface ConnectionSnapshot {
  instanceId: string;
  connections: ConnectionInfo[] | null;
  selectedId: string | null;
  original: ConnectionOperationRecord | null;
  priorUnknown: ConnectionOperationRecord[];
  message: string;
  busy: boolean;
  mutationPending: boolean;
  blocked: boolean;
}

const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const scopes: readonly Scope[] = ['metadata', 'read_output', 'control'];
const unique = (values: unknown, valid: (value: unknown) => boolean): values is string[] => Array.isArray(values) && values.every(valid) && new Set(values).size === values.length;
function validConnection(value: ConnectionInfo): boolean {
  if (!uuid(value.connection_id) || !['authenticating', 'unpaired', 'pending', 'granted', 'closing', 'finished'].includes(value.state)
    || value.executable_name !== null && (typeof value.executable_name !== 'string' || !value.executable_name)
    || !unique(value.requested_project_ids, uuid) || !unique(value.granted_project_ids, uuid)
    || !unique(value.requested_scopes, item => scopes.includes(item as Scope))
    || !unique(value.granted_scopes, item => scopes.includes(item as Scope))) return false;
  if ((value.state === 'pending' || value.state === 'granted') && value.executable_name === null) return false;
  if (value.state !== 'granted' && (value.granted_project_ids.length || value.granted_scopes.length)) return false;
  return value.granted_project_ids.every(id => value.requested_project_ids.includes(id))
    && value.granted_scopes.every(scope => value.requested_scopes.includes(scope));
}
function list(response: Response): ConnectionInfo[] | null {
  if (!response.accepted || response.result?.operation !== 'connection.list') return null;
  const rows = response.result.data.connections;
  if (!Array.isArray(rows) || !rows.every(validConnection) || new Set(rows.map(row => row.connection_id)).size !== rows.length) return null;
  return rows;
}
function operation(response: Response, id: string): OperationStatus | null {
  if (!response.accepted || response.result?.operation !== 'operation.get') return null;
  const status = response.result.data.operation;
  if (!status || status.operation_id !== id) return null;
  if (['accepted', 'in_progress', 'unknown'].includes(status.phase)) return status.outcome === null && status.error_code === null ? status : null;
  if (status.phase !== 'completed') return null;
  return status.outcome === 'succeeded' && status.error_code === null
    || status.outcome === 'failed' && typeof status.error_code === 'string' ? status : null;
}
const uncertain = (error: unknown) => error === 'transport_uncertain' || error instanceof Error && error.message === 'transport_uncertain';
const sameSet = (actual: string[], expected: string[]) => JSON.stringify([...actual].sort()) === JSON.stringify([...expected].sort());

/** The original mutation, recovery read, current list, and input lease have separate lifetimes. */
export function createConnectionController(instanceId: string, port: ConnectionPort, allocate: () => string = () => crypto.randomUUID()) {
  let currentPort = port;
  let binding = 0;
  let historyRevision = 0;
  let connections: ConnectionInfo[] | null = null;
  let selectedId: string | null = null;
  let original: ConnectionOperationRecord | null = null;
  const priorUnknown: ConnectionOperationRecord[] = [];
  let lease: ControlLease | null = null;
  let reserving: { binding: number } | null = null;
  let reading: { promise: Promise<void> } | null = null;
  let refreshQueued = false;
  let readFailed = false;
  let blocked = false;
  let retired = false;
  let notice: string | null = null;
  const listeners = new Set<(snapshot: ConnectionSnapshot) => void>();
  const currentRow = (record: ConnectionOperationRecord) => connections?.find(row => row.connection_id === record.connectionId);
  function message(): string {
    if (blocked) return 'host への配送結果が不明です。認可変更と接続情報の公開を停止しました。';
    if (notice) return notice;
    if (!original) return connections ? '現在の接続状態を確認しました。' : readFailed ? '接続状態を確認できません。' : '接続一覧を確認しています。';
    if (original.phase === 'unconfirmed' || original.phase === 'accepted' || original.phase === 'in_progress')
      return connections ? '元の操作を確認中です。現在一覧は別に表示しています。' : '元の操作を確認中です。現在の権限は未確認です。';
    if (original.phase === 'unknown')
      return connections ? '元の操作の成否は未確認です。現在一覧は別に表示しています。新しい明示操作で拒否または失効できます。'
        : '元の操作の成否は未確認です。現在の権限は未確認です。';
    if (original.phase !== 'completed') return '元の操作を確認中です。';
    if (original.outcome === 'failed') return `元の操作は拒否されました: ${original.errorCode ?? '不明'}。${connections ? '現在一覧は別に表示しています。' : '現在の権限は未確認です。'}`;
    if (!connections) return '元の操作は成功しました。現在の権限は未確認です。';
    const current = currentRow(original);
    if (original.action === 'allow') {
      if (current?.state === 'granted' && sameSet(current.granted_project_ids, original.projectIds) && sameSet(current.granted_scopes, original.scopes))
        return '元の操作は成功し、現在の許可も一致しています。';
      if (!current) return '元の許可は成功しましたが、対象接続は現在の一覧にありません。';
      if (current.state === 'closing' || current.state === 'finished') return '元の許可は成功しましたが、現在の権限は無効です。client の終了は別途確認してください。';
      return '元の許可は成功しましたが、現在の許可は一致しません。';
    }
    return current && ['closing', 'finished'].includes(current.state) && !current.granted_project_ids.length && !current.granted_scopes.length
      ? '権限は無効です。対象 client の終了を別途確認してください。'
      : '元の操作は成功しましたが、現在の権限を確定できません。';
  }
  const snapshot = (): ConnectionSnapshot => ({ instanceId, connections: connections?.map(row => ({ ...row,
    requested_project_ids: [...row.requested_project_ids], requested_scopes: [...row.requested_scopes],
    granted_project_ids: [...row.granted_project_ids], granted_scopes: [...row.granted_scopes] })) ?? null,
    selectedId, original: original ? { ...original, projectIds: [...original.projectIds], scopes: [...original.scopes] } : null,
    priorUnknown: priorUnknown.map(row => ({ ...row, projectIds: [...row.projectIds], scopes: [...row.scopes] })),
    message: message(), busy: reading !== null, mutationPending: lease !== null || reserving !== null, blocked });
  function changed() { const value = snapshot(); for (const listener of listeners) listener(value); }
  function request(operationName: 'connection.list' | 'connection.decide' | 'connection.revoke' | 'operation.get', params: object): Request {
    return { schema_version: 1, instance_id: instanceId, operation_id: allocate(), expected_topology_revision: null, operation: operationName, params } as Request;
  }
  function release() { if (lease) { currentPort.release(lease); lease = null; } }
  function blockTransport() {
    if (blocked) return;
    blocked = true; reading = null; refreshQueued = false; connections = null; changed(); currentPort.transportUncertain();
  }
  function readFailure(error: unknown) {
    if (uncertain(error)) { blockTransport(); return; }
    connections = null; readFailed = true; notice = null; changed();
  }
  type ReadContext = { port: ConnectionPort; active(): boolean };
  function beginRead(work: (context: ReadContext) => Promise<void>): Promise<void> {
    if (retired || blocked || reading) return Promise.resolve();
    const bound = binding; const port = currentPort;
    const ticket = { promise: Promise.resolve() };
    reading = ticket; changed();
    const active = () => !retired && !blocked && binding === bound && reading === ticket;
    const run = (async () => {
      try { await work({ port, active }); }
      catch (error) { if (active()) readFailure(error); }
      finally {
        if (active()) {
          const again = refreshQueued;
          refreshQueued = false; reading = null; changed();
          if (again) void refresh();
        }
      }
    })();
    ticket.promise = run;
    return run;
  }
  async function readList(context: ReadContext) {
    const observedRevision = historyRevision;
    const rows = list(await context.port.exchange(request('connection.list', {})));
    if (!rows) throw new Error('protocol_failed');
    if (!context.active() || observedRevision !== historyRevision) return;
    connections = rows; readFailed = false; notice = null;
    if (selectedId && !rows.some(row => row.connection_id === selectedId)) selectedId = null;
    if (original && (original.phase === 'completed' || original.phase === 'unknown')) release();
    changed();
  }
  async function refresh() {
    if (reading && !retired && !blocked) { refreshQueued = true; return; }
    await beginRead(readList);
  }
  async function recheck(id?: string) {
    const target = id ? priorUnknown.find(row => row.id === id) ?? (original?.id === id ? original : null) : original;
    if (!target) return;
    await beginRead(async context => {
      const status = operation(await context.port.recover(target.ownerKey, request('operation.get', { operation_id: target.id })), target.id);
      if (!status) throw new Error('protocol_failed');
      if (!context.active()) return;
      if (target.phase === 'completed' && status.phase === 'completed' && target.outcome !== status.outcome) throw new Error('protocol_failed');
      if (target.phase !== 'completed') {
        const becameTerminal = (status.phase === 'completed' || status.phase === 'unknown') && target.phase !== status.phase;
        target.phase = status.phase; target.outcome = status.outcome; target.errorCode = status.error_code;
        if (becameTerminal) { historyRevision++; connections = null; }
      }
      notice = null; changed();
      await readList(context);
    });
  }
  async function afterCurrentRead(record: ConnectionOperationRecord, admitted: ControlLease, bound: number) {
    const active = () => !retired && !blocked && binding === bound && original === record && lease === admitted;
    while (reading && active()) await reading.promise;
    if (active()) await refresh();
  }
  const activeReadPromise = () => reading?.promise ?? null;
  async function decide(action: 'allow' | 'deny' | 'revoke', connectionId: string, projectIds: string[] = [], grantedScopes: Scope[] = []) {
    if (retired || blocked || reading || lease || reserving || !connections) return false;
    const row = connections.find(item => item.connection_id === connectionId);
    if (!row || (action === 'revoke' ? row.state !== 'granted' : row.state !== 'pending')
      || original?.phase === 'accepted' || original?.phase === 'in_progress' || original?.phase === 'unconfirmed'
      || original?.phase === 'read_failed'
      || (original?.phase === 'unknown' || priorUnknown.some(item => item.phase !== 'completed')) && action === 'allow'
      || action === 'allow' && (!unique(projectIds, uuid) || !unique(grantedScopes, item => scopes.includes(item as Scope))
        || !projectIds.every(id => row.requested_project_ids.includes(id)) || !grantedScopes.every(scope => row.requested_scopes.includes(scope)))) return false;
    const id = allocate(); const reservePort = currentPort; const reserveBound = binding; const listed = connections;
    const reservation = { binding };
    let admitted: ControlLease | null;
    try {
      const candidate = reservePort.reserve(id);
      if (candidate && typeof (candidate as Promise<ControlLease | null>).then === 'function') {
        reserving = reservation; changed();
        admitted = await candidate;
        if (reserving === reservation) reserving = null;
      } else admitted = candidate as ControlLease | null;
    } catch { if (reserving === reservation) reserving = null; admitted = null; }
    if (retired || blocked || reserveBound !== binding || connections !== listed) {
      if (admitted) reservePort.release(admitted);
      changed(); return false;
    }
    if (!admitted) { notice = '別の操作、変換、配送、保持入力の確認後に操作してください。'; changed(); return false; }
    if (original?.phase === 'unknown') priorUnknown.push({ ...original, projectIds: [...original.projectIds], scopes: [...original.scopes] });
    lease = admitted; selectedId = connectionId; notice = null;
    const record: ConnectionOperationRecord = { ownerKey: reservePort.ownerKey, id, action, connectionId, projectIds: action === 'allow' ? [...projectIds] : [],
      scopes: action === 'allow' ? [...grantedScopes] : [], phase: 'unconfirmed', outcome: null, errorCode: null };
    original = record; changed();
    const bound = binding; const port = currentPort;
    const active = () => !retired && !blocked && binding === bound && original === record && lease === admitted;
    const mutation = { schema_version: 1, instance_id: instanceId, operation_id: id, expected_topology_revision: null,
      operation: action === 'revoke' ? 'connection.revoke' : 'connection.decide',
      params: action === 'revoke' ? { connection_id: connectionId } : { connection_id: connectionId, decision: action,
        project_ids: record.projectIds, scopes: record.scopes } } as Request;
    try {
      const reply = await port.exchange(mutation);
      if (!active()) return false;
      if (reply.accepted) {
        const data = reply.result?.data;
        if (reply.result?.operation !== mutation.operation || !data || !('connection_id' in data) || data.connection_id !== connectionId
          || !('state' in data) || data.state !== (action === 'allow' ? 'granted' : 'revoked')
          || action !== 'revoke' && (!('project_ids' in data) || !('scopes' in data)
            || !sameSet(data.project_ids, record.projectIds) || !sameSet(data.scopes, record.scopes))) throw new Error('protocol_failed');
      }
      record.phase = 'completed'; record.outcome = reply.accepted ? 'succeeded' : 'failed'; record.errorCode = reply.accepted ? null : reply.error?.code ?? null;
      historyRevision++; connections = null; notice = null; changed();
      await afterCurrentRead(record, admitted, bound);
      return true;
    } catch (error) {
      if (!active()) return false;
      if (uncertain(error)) { record.phase = 'transport_unknown'; blockTransport(); return false; }
      if (record.phase !== 'completed') { record.phase = 'unconfirmed'; record.outcome = null; record.errorCode = null; }
      connections = null; readFailed = true; notice = null; changed();
      let pending = activeReadPromise();
      while (pending && active()) { await pending; pending = activeReadPromise(); }
      if (active()) await recheck();
      return false;
    }
  }
  return { snapshot, observe(listener: (snapshot: ConnectionSnapshot) => void) { listeners.add(listener); listener(snapshot()); return () => listeners.delete(listener); },
    bind(next: ConnectionPort) { if (retired) return; currentPort = next; binding++; reading = null; refreshQueued = false;
      reserving = null; blocked = false; connections = null; readFailed = false; notice = null; changed(); },
    blockHost() { if (retired || blocked) return; blocked = true; reading = null; refreshQueued = false;
      reserving = null; connections = null; notice = null; changed(); },
    select(id: string | null) { if (id === null || connections?.some(row => row.connection_id === id)) { selectedId = id; changed(); } },
    refresh, recheck, decide,
    retire() { retired = true; binding++; reading = null; reserving = null; refreshQueued = false; connections = null; selectedId = null; listeners.clear();
      if (original?.phase !== 'unconfirmed' && original?.phase !== 'transport_unknown') release(); },
  };
}
