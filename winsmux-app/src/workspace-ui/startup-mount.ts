import { createSecondaryMount, constructSecondary, type OwnerContext } from './startup-secondary-create';
import { invoke } from '@tauri-apps/api/core';
import { open } from '@tauri-apps/plugin-dialog';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { listen } from '@tauri-apps/api/event';
import { openWorkspaceSession, workspaceRequest, getWorkspaceDiscovery, copyWorkspaceDiscovery, getWorkspaceHostStatus, forceExitUncertainWorkspace, type WorkspaceSession, type WorkspaceHostStatus } from '../workspaceClient';
import { createProjectPaneController, runReadData, type OwnerKey } from './project-pane-controller';
import { createProjectPaneView, type ViewSnapshot } from './project-pane';
import { mountProjectPaneTerminal } from './project-pane-terminal';
import { createTerminalInputOwner } from './terminal-input';
import { restoreWorkspaceFocus } from './focus';
import { createDetailsController } from './details-controller';
import { createAgentControls, type AgentControlsSnapshot } from './agent-controls';
import { createAgentCommandSession, type AgentCommandIntent } from './agent-commands';
import { createAgentObservation } from './agent-observation';
import { createControlAdmission, type ControlLease } from './control-admission';
import { createConnectionController } from './connection-controller';
import { createWorkspaceCopyGate, type CopyReservation } from './workspace-copy-gate';
import { mountConnectionView } from './connection-view';
import type { Request, Response, OutputReadData, EventsWaitData, OperationName, ProviderCapability } from '../generated/workspace-contract';

const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const uint = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
const shape = (value: unknown, keys: string[]): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.prototype.hasOwnProperty.call(value, key));
const timestamp = (value: unknown): value is string => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?Z$/.test(value) && Number.isFinite(new Date(value).getTime()) && new Date(value).toISOString().slice(0, 19) === value.slice(0, 19);
function runObservation(value: unknown) {
  if (!shape(value, ['run_id', 'pane_id', 'process', 'work', 'evidence', 'observed_at', 'current', 'exit_code']) || !uuid(value.run_id) || !uuid(value.pane_id) || !timestamp(value.observed_at) || typeof value.current !== 'boolean' || !(value.exit_code === null || (typeof value.exit_code === 'number' && Number.isInteger(value.exit_code) && value.exit_code >= -2147483648 && value.exit_code <= 2147483647))) return false;
  if (!['starting', 'running', 'exited', 'unknown'].includes(value.process as string) || !['unknown', 'running', 'awaiting_input', 'succeeded', 'failed', 'interrupted'].includes(value.work as string)) return false;
  if (value.evidence === 'unavailable') return value.work === 'unknown' && value.exit_code === null;
  if (value.evidence === 'provider_event' && value.process === 'running') return value.exit_code === null && value.work !== 'interrupted';
  if (value.evidence === 'provider_event' && value.process === 'exited') return (value.exit_code === null || value.exit_code === 0) ? ['unknown', 'succeeded', 'failed', 'interrupted'].includes(value.work as string) : value.work === 'failed' || value.work === 'interrupted';
  return value.evidence === 'process_exit' && value.process === 'exited' && (value.work === 'interrupted' || (value.work === 'unknown' && (value.exit_code === null || value.exit_code === 0)) || (value.work === 'succeeded' && value.exit_code === 0) || (value.work === 'failed' && value.exit_code !== null && value.exit_code !== 0));
}
function operationStatus(value: unknown) {
  if (!shape(value, ['error_code', 'operation_id', 'outcome', 'phase']) || !uuid(value.operation_id)) return false;
  if (['accepted', 'in_progress', 'unknown'].includes(value.phase as string)) return value.outcome === null && value.error_code === null;
  if (value.phase !== 'completed') return false;
  if (value.outcome === 'succeeded') return value.error_code === null;
  return value.outcome === 'failed' && typeof value.error_code === 'string' && ['invalid_request', 'unsupported_version', 'permission_denied', 'target_not_found', 'stale_topology', 'operation_conflict', 'in_progress', 'not_running', 'already_running', 'unsupported_capability', 'output_gap', 'persistence_failed', 'runtime_failed', 'state_unknown', 'resource_exhausted', 'root_changed', 'unsupported_file', 'not_a_repository'].includes(value.error_code);
}
function correlated(request: Request, value: unknown): value is Response {
  return shape(value, ['schema_version', 'instance_id', 'operation_id', 'accepted', 'topology_revision', 'event_seq', 'result', 'error'])
    && value.schema_version === 1 && value.instance_id === request.instance_id && value.operation_id === request.operation_id
    && uint(value.topology_revision) && uint(value.event_seq)
    && (value.accepted === true ? value.error === null && shape(value.result, ['operation', 'data']) && value.result.operation === request.operation
      : value.accepted === false && value.result === null && shape(value.error, ['code', 'message', 'retryable', 'target_id'])
        && typeof value.error.code === 'string' && typeof value.error.message === 'string' && typeof value.error.retryable === 'boolean'
        && (value.error.target_id === null || uuid(value.error.target_id)));
}
const readOnly = new Set<OperationName>(['run.get', 'operation.get', 'capabilities.get', 'project.list', 'pane.list', 'events.wait', 'output.read', 'artifact.list', 'artifact.read', 'artifact.diff', 'artifact.choice.list', 'diagnostics.get', 'connection.list']);
const hostPhases = new Set(['Empty', 'Opening', 'Ready', 'Busy', 'Stopping', 'Unknown', 'ForcePrompt', 'Finishing', 'FailedClosed', 'MainClosed', 'ExitReleased']);
const decimalU64 = (value: unknown): value is string => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) && BigInt(value) <= 18446744073709551615n;
function validHostStatus(value: unknown): value is WorkspaceHostStatus {
  return shape(value, ['instance_id', 'generation', 'revision', 'phase'])
    && (value.instance_id === null || uuid(value.instance_id)) && decimalU64(value.generation)
    && decimalU64(value.revision) && hostPhases.has(value.phase as string);
}
export function validSession(value: unknown): value is WorkspaceSession & { schema_version: 1 } { return shape(value, ['instance_id', 'schema_version']) && uuid(value.instance_id) && value.schema_version === 1; }
export function validReadResponse(request: Request, value: unknown): value is Response {
  if (!shape(value, ['schema_version', 'instance_id', 'operation_id', 'accepted', 'topology_revision', 'event_seq', 'result', 'error']) || value.schema_version !== 1 || value.instance_id !== request.instance_id || value.operation_id !== request.operation_id || !uint(value.topology_revision) || !uint(value.event_seq) || value.accepted !== true || value.error !== null || !shape(value.result, ['operation', 'data']) || value.result.operation !== request.operation) return false;
  const data = value.result.data;
  if (request.operation === 'output.read') return shape(data, ['gap', 'next_cursor', 'run_id', 'text', 'truncated']) && data.run_id === request.params.run_id && typeof data.text === 'string' && typeof data.next_cursor === 'string' && data.next_cursor.length > 0 && typeof data.gap === 'boolean' && typeof data.truncated === 'boolean';
  if (request.operation !== 'events.wait' || !shape(data, ['events', 'next_event_seq', 'status']) || !uint(data.next_event_seq) || data.next_event_seq < request.params.after_event_seq || !['events', 'gap', 'no_change'].includes(data.status as string) || !Array.isArray(data.events)) return false;
  let sequence = request.params.after_event_seq;
  for (const event of data.events) {
    if (!shape(event, ['data', 'event_seq', 'observed_at']) || !uint(event.event_seq) || event.event_seq <= sequence || event.event_seq > data.next_event_seq || !timestamp(event.observed_at) || !shapeEvent(event.data)) return false;
    sequence = event.event_seq;
  }
  return data.status === 'events' ? data.events.length > 0 : data.status === 'no_change' ? data.events.length === 0 : true;
}
function shapeEvent(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const data = value as Record<string, unknown>;
  switch (data.kind) {
    case 'topology_changed': return shape(data, ['kind', 'pane_id', 'project_id', 'topology_revision']) && uint(data.topology_revision) && (data.pane_id === null || uuid(data.pane_id)) && (data.project_id === null || uuid(data.project_id));
    case 'run_state_changed': return shape(data, ['kind', 'run']) && runObservation(data.run);
    case 'operation_state_changed': return shape(data, ['kind', 'operation']) && operationStatus(data.operation);
    case 'connection_state_changed': return shape(data, ['kind', 'connection_id', 'state']) && uuid(data.connection_id) && ['unpaired', 'pending', 'granted', 'revoked'].includes(data.state as string);
    default: return false;
  }
}

export async function mountWorkspaceMain(root: HTMLElement) {
  await invoke<void>('startup_main_policy_ready');
  let disposed = false; let generation = 0; let frame: number | null = null; let unlisten: (() => void) | null = null;
  let active: (() => void) | null = null; let reconnecting = false; let shown = false;
  let details: ReturnType<typeof createDetailsController> | null = null;
  let closeDetails: (() => void) | null = null;
  let creationContext: () => OwnerContext = () => ({ active: false, mounted: false, session: { instance_id: '', schema_version: 1 }, generation: '', epoch: generation, label: '', href: location.href, origin: location.origin, selectedProject: null });
  const creations = createSecondaryMount({ current: () => creationContext(), invoke: () => invoke<unknown>('startup_secondary_creation_policy', {}), construct: constructSecondary, allocate: () => crypto.randomUUID(), storage: { localArea: localStorage, get: key => localStorage.getItem(key), put: (key, value) => localStorage.setItem(key, value), removeIfSame(key, value) { if (localStorage.getItem(key) !== value) return 'superseded'; localStorage.removeItem(key); return 'removed_exact'; } } });
  Object.defineProperties(root, { openSecondarySurface: { value: creations.facade.openSecondarySurface }, inspectSecondarySurface: { value: creations.facade.inspectSecondarySurface } });
  const observeCreation = (event: StorageEvent) => creations.observeStorage(event);
  window.addEventListener('storage', observeCreation);
  const revealOnce = async () => {
    if (shown || disposed) return;
    await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
    if (shown || disposed) return;
    shown = true; await invoke<void>('startup_main_show');
  };
  const status = document.createElement('p'); status.setAttribute('role', 'status');
  const reconnect = document.createElement('button'); reconnect.type = 'button'; reconnect.textContent = '接続を確認し直す'; reconnect.hidden = true;
  const forceExit = document.createElement('button'); forceExit.type = 'button'; forceExit.textContent = '状態不明の host を強制終了'; forceExit.hidden = true;
  forceExit.onclick = async () => { forceExit.disabled = true; try { await forceExitUncertainWorkspace(); } catch (error) {
    if (error !== 'force_exit_cancelled' && !(error instanceof Error && error.message === 'force_exit_cancelled')) status.textContent = `強制終了を確認できません: ${String(error)}`;
    forceExit.disabled = false;
  } };
  const detailsButton = document.createElement('button'); detailsButton.type = 'button'; detailsButton.textContent = '成果物・配置・診断'; detailsButton.disabled = true;
  const detailsMount = document.createElement('div'); detailsMount.setAttribute('aria-label', '成果物・配置・診断の表示領域');
  const agentMount = document.createElement('div'); agentMount.setAttribute('aria-label', 'AIの起動と状態の表示領域');
  const connectionMount = document.createElement('div'); connectionMount.setAttribute('aria-label', 'CLI・MCP 接続の表示領域');
  detailsButton.addEventListener('click', () => { if (!details) return; closeDetails?.(); closeDetails = details.open(detailsMount, detailsButton); });
  root.append(status, reconnect, forceExit, detailsButton, detailsMount, agentMount, connectionMount);
  const input = createTerminalInputOwner(root, {
    invoke: (command,args) => invoke<unknown>(command,args),
    listen: callback => listen('workspace-input-guard-changed', event => callback(event.payload)),
  });
  const admission = createControlAdmission(input);
  let connectedHost: string | null = null;
  let requestGate: ReturnType<typeof createWorkspaceCopyGate> | null = null;
  let ownerSection: OwnerKey | null = null;
  const sameOwner = (a: OwnerKey, b: OwnerKey) => a.instanceId === b.instanceId && a.ownerGeneration === b.ownerGeneration;
  let connectionOwner: ReturnType<typeof createConnectionController> | null = null;
  let connectionView: ReturnType<typeof mountConnectionView> | null = null;
  let hostObservation: { epoch: number; instance: string | null; generation: bigint; revision: bigint; phase: WorkspaceHostStatus['phase'] } | null = null;
  let probeIssued = 0;
  let hostBlocked = true;
  let recoveryPending = false;
  let ownerMismatch = false;
  const hostUnknown = () => hostObservation?.phase === 'Unknown';
  const reserveControl = (host: string, kind: Parameters<typeof admission.reserve>[1], ticket: string, copy?: CopyReservation) =>
    requestGate?.canReserveControl(copy) && !hostBlocked && hostObservation?.phase === 'Ready' && input.inspect().lease !== null
      ? admission.reserve(host, kind, ticket) : null;
  function showRecoveryShell() {
    if (!recoveryPending) {
      recoveryPending = true;
      input.blockHost(); connectionOwner?.blockHost(); details?.blockTransport();
    }
    hostBlocked = true;
    const panel = root.querySelector<HTMLElement>('.workspace-input-confirmation');
    for (const child of root.children) if (child instanceof HTMLElement)
      child.inert = child !== status && child !== reconnect && child !== forceExit && child !== panel;
    input.showGuardRecovery(false);
    detailsButton.disabled = true; forceExit.hidden = true; reconnect.hidden = false; reconnect.disabled = false;
    root.dataset.startupState = 'recovering';
    status.textContent = input.inspect().resumeAllowed
      ? '入力の再開を確認しました。接続を明示的に確認し直してください。'
      : '終了と入力の受付状態を確認中です。入力の確認欄から状態を再確認できます。';
  }
  function blockHost(unknown: boolean) {
    if (recoveryPending && !unknown) { showRecoveryShell(); return; }
    if (unknown) recoveryPending = false;
    hostBlocked = true;
    input.blockHost(); connectionOwner?.blockHost(); details?.blockTransport();
    for (const child of root.children) if (child instanceof HTMLElement)
      child.inert = child !== status && child !== reconnect && child !== forceExit && child !== input.guardRecovery;
    input.showGuardRecovery(true);
    detailsButton.disabled = true;
    forceExit.hidden = !unknown; reconnect.hidden = unknown;
    root.dataset.startupState = unknown ? 'unknown' : 'unconfirmed';
    status.textContent = unknown ? 'host の現在状態は不明です。元の要求と入力を保持しています。'
      : 'host の現在状態を確認できません。要求と入力を保持しています。';
  }
  async function observeHost(epoch: number, expectedInstance: string | null, admit = true): Promise<WorkspaceHostStatus['phase'] | 'unconfirmed'> {
    const ticket = ++probeIssued;
    let value: unknown;
    try { value = await getWorkspaceHostStatus(); }
    catch { value = null; }
    if (disposed || epoch !== generation) return 'unconfirmed';
    if (ticket !== probeIssued) return hostObservation?.epoch === epoch ? hostObservation.phase : 'unconfirmed';
    const previous = hostObservation?.epoch === epoch ? hostObservation : null;
    if (!validHostStatus(value) || expectedInstance !== null && value.instance_id !== expectedInstance) {
      if (previous?.phase === 'Unknown') { blockHost(true); return 'Unknown'; }
      blockHost(false); return 'unconfirmed';
    }
    const nextGeneration = BigInt(value.generation), nextRevision = BigInt(value.revision);
    if (previous?.phase === 'Unknown' && value.instance_id === previous.instance && nextGeneration === previous.generation) {
      blockHost(true); return 'Unknown';
    }
    if (previous && (value.instance_id !== previous.instance || nextGeneration !== previous.generation
      || nextRevision < previous.revision || nextRevision === previous.revision && value.phase !== previous.phase
    )) {
      blockHost(false); return 'unconfirmed';
    }
    hostObservation = { epoch, instance: value.instance_id, generation: nextGeneration, revision: nextRevision, phase: value.phase };
    if (value.phase === 'Unknown') blockHost(true);
    else if (admit && (value.phase === 'Ready' || value.phase === 'Busy')) hostBlocked = false;
    else blockHost(false);
    return value.phase;
  }
  let retiringAgent: ReturnType<typeof createAgentCommandSession> | null = null;
  let retiringAgentLease: ControlLease | null = null;
  let retiringAgentOwnerGeneration: bigint | null = null;
  let retiringProject: { ownerKey: OwnerKey; request: Request; kind: 'instant' | 'interrupt'; runId: string | null; paneId: string | null; lease: ControlLease } | null = null;
  const visibility = () => { if (!disposed && document.hidden && frame !== null) { cancelAnimationFrame(frame); frame = null; } };
  document.addEventListener('visibilitychange', visibility);
  const recoveryWatch = input.observe(() => { if (recoveryPending) showRecoveryShell(); });
  const dispose = () => { if (disposed) return; disposed = true; requestGate?.retire(); requestGate = null; generation++; creations.dispose(); input.disconnect(); window.removeEventListener('storage', observeCreation); active?.(); active = null; connectionView?.dispose(); connectionView = null; connectionOwner?.retire(); connectionOwner = null; retiringAgent?.retireHost(); retiringAgent = null; if (connectedHost) admission.retireHost(connectedHost); connectedHost = null; closeDetails?.(); closeDetails = null; details?.disconnect(); details = null; recoveryWatch(); input.dispose(); if (frame !== null) cancelAnimationFrame(frame); frame = null; unlisten?.(); unlisten = null; reconnect.onclick = null; forceExit.onclick = null; document.removeEventListener('visibilitychange', visibility); window.removeEventListener('unload', dispose); root.dataset.startupState = 'disposed'; delete root.dataset.session; };
  window.addEventListener('unload', dispose, { once: true });
  async function connect() {
    if (disposed || reconnecting) return;
    if (ownerMismatch) {
      const probeEpoch = ++generation; hostObservation = null; hostBlocked = true; probeIssued++;
      const phase = await observeHost(probeEpoch, connectedHost, false);
      if (phase === 'Ready' || phase === 'Busy') {
        const observed: OwnerKey = { instanceId: hostObservation!.instance!, ownerGeneration: hostObservation!.generation.toString() };
        if (ownerSection && sameOwner(ownerSection, observed)) { ownerMismatch = false; recoveryPending = false; void connect(); return; }
      }
      if (phase !== 'Unknown') {
        showRecoveryShell();
        status.textContent = '元のhostと別世代のため旧操作は確認できません。元の操作番号と入力を保持しています。';
      }
      return;
    }
    if (input.hasPendingComposition()) { reconnect.hidden = false; status.textContent = '変換中の文字を確定または取消してから接続を確認し直してください。'; return; }
    if (recoveryPending && !input.inspect().resumeAllowed) { void input.recoverGuard(); showRecoveryShell(); return; }
    recoveryPending = false;
    reconnecting = true; requestGate?.retire(); requestGate = null; creations.beginReconnect(); retiringAgent?.setConnected(false); input.disconnect(); active?.(); active = null; connectionView?.dispose(); connectionView = null; if (frame !== null) cancelAnimationFrame(frame); frame = null;
    const epoch = ++generation; const current = () => !disposed && epoch === generation;
    hostObservation = null; hostBlocked = true; probeIssued++;
    root.dataset.startupState = 'connecting'; delete root.dataset.session; reconnect.hidden = true; status.textContent = '作業セッションを確認しています。';
    let openReturned = false;
    const wire = createWorkspaceCopyGate(); requestGate = wire;
    try {
      const session = await openWorkspaceSession();
      openReturned = true;
      if (!current()) return;
      if (!validSession(session)) throw new Error('protocol_failed');
      const initialPhase = await observeHost(epoch, session.instance_id, false);
      if (!current()) return;
      if (initialPhase !== 'Ready' && initialPhase !== 'Busy') throw new Error(initialPhase === 'Unknown' ? 'transport_uncertain' : 'host_observation_unavailable');
      const observedOwner: OwnerKey = Object.freeze({ instanceId: session.instance_id, ownerGeneration: hostObservation!.generation.toString() });
      if (ownerSection?.instanceId === observedOwner.instanceId && !sameOwner(ownerSection, observedOwner)) {
        ownerMismatch = true;
        showRecoveryShell();
        status.textContent = '元のhostと別世代のため旧操作は確認できません。元の操作番号と入力を保持しています。';
        await revealOnce(); return;
      }
      if (connectedHost !== null && connectedHost !== session.instance_id) {
        connectionOwner?.retire(); connectionOwner = null;
        retiringAgent?.retireHost(); retiringAgent = null; retiringAgentLease = null; retiringAgentOwnerGeneration = null; retiringProject = null;
        admission.retireHost(connectedHost);
      }
      if (ownerSection === null || ownerSection.instanceId !== observedOwner.instanceId) ownerSection = observedOwner;
      connectedHost = session.instance_id;
      hostBlocked = false;
      forceExit.hidden = true;
      for (const child of root.children) if (child instanceof HTMLElement) child.inert = false;
      input.showGuardRecovery(false);
      if (details && details.lifetime.instanceId !== session.instance_id) { closeDetails?.(); closeDetails = null; details.retire(); details = null; }
      details ??= createDetailsController({ instanceId: session.instance_id, nonce: crypto.randomUUID() }, crypto, {
        acquire(kind, ticket) { const lease = reserveControl(session.instance_id, kind, ticket); return lease ? () => { admission.release(lease); } : null; },
      });
      detailsButton.disabled = false;
      const identity = crypto.randomUUID(); root.dataset.session = JSON.stringify(session); root.dataset.generation = identity;
      const initialPath = await invoke<unknown>('desktop_initial_project_dir');
      if (!current()) return;
      if (initialPath !== null && (typeof initialPath !== 'string' || initialPath.length === 0)) throw new Error('protocol_failed');
      let launchPath = initialPath as string | null; let launchReserved = false; let launchTicket: number | null = null; let stopped = false;
      root.dataset.initialPath = launchPath ?? ''; root.dataset.initialOutcome = launchPath === null ? 'not_requested' : 'pending'; delete root.dataset.initialProjectId;
      let maxBytes = 0; let eventSeq = 0;
      // Every operation, including a read, belongs to the epoch that made its
      // port. Original-ID recovery after reconnect uses B's explicit port.
      const ownerGeneration = hostObservation!.generation;
      const ownerKey = observedOwner;
      const sameLiveHost = () => hostObservation?.epoch === epoch && hostObservation.instance === session.instance_id
        && hostObservation.generation === ownerGeneration;
      const port = { ownerKey, exchange: async (request: Request, beforeDispatch?: () => boolean): Promise<Response> => {
        if (request.operation === 'operation.get') throw new Error('recovery_port_required');
        return dispatch(request, beforeDispatch);
      }, recover: async (origin: OwnerKey, request: Request): Promise<Response> => {
        if (request.operation !== 'operation.get' || !sameOwner(origin, ownerKey) || !ownerSection || !sameOwner(origin, ownerSection)) throw new Error('owner_mismatch');
        return dispatch(request);
      } };
      async function dispatch(request: Request, beforeDispatch?: () => boolean): Promise<Response> {
        if (!current() || request.instance_id !== session.instance_id || connectedHost !== session.instance_id) throw new Error('session_closed');
        const inputOperation = request.operation === 'input.write' || request.operation === 'input.key';
        if (hostBlocked || !sameLiveHost()
          || !readOnly.has(request.operation) && (hostObservation?.phase !== 'Ready' && !(inputOperation && hostObservation?.phase === 'Busy')
            || input.inspect().lease === null || input.inspect().frozen))
          throw new Error(hostObservation?.phase === 'Unknown' ? 'transport_uncertain' : 'host_observation_unavailable');
        if (inputOperation && hostObservation?.phase === 'Busy') {
          const phase = await observeHost(epoch, session.instance_id);
          if (!current() || phase !== 'Ready' || hostBlocked || input.inspect().lease === null || input.inspect().frozen)
            throw new Error('host_not_sent');
        }
        let response: Response;
        if (!current() || !sameLiveHost() || !ownerSection || !sameOwner(ownerKey, ownerSection)) throw new Error('session_closed');
        try { response = await wire.send(readOnly.has(request.operation), () => {
          if (!current() || !sameLiveHost() || !ownerSection || !sameOwner(ownerKey, ownerSection)) throw new Error('session_closed');
          if (hostBlocked) throw new Error(hostObservation?.phase === 'Unknown' ? 'transport_uncertain' : 'host_observation_unavailable');
          if (!readOnly.has(request.operation) && (hostObservation?.phase !== 'Ready' || input.inspect().lease === null || input.inspect().frozen)) throw new Error('host_not_sent');
          if (inputOperation && !beforeDispatch?.()) throw new Error('host_not_sent');
          return workspaceRequest(request);
        }); }
        catch (error) {
          if (!current()) throw new Error('session_closed');
          if (!sameLiveHost()) throw new Error('session_closed');
          if (error === 'transport_uncertain' || error instanceof Error && error.message === 'transport_uncertain') {
            const phase = await observeHost(epoch, session.instance_id);
            if (!current()) throw new Error('session_closed');
            throw new Error(phase === 'Unknown' ? 'transport_uncertain'
              : phase === 'Ready' || phase === 'Busy' ? 'reply_unconfirmed' : 'host_observation_unavailable');
          }
          throw error;
        }
        if (!current()) throw new Error('session_closed');
        if (hostBlocked) throw new Error(hostObservation?.phase === 'Unknown' ? 'transport_uncertain' : 'host_observation_unavailable');
        if (!correlated(request, response) || connectedHost !== session.instance_id) throw new Error('protocol_failed');
        if (current() && readOnly.has(request.operation) && hostObservation?.phase === 'Busy') {
          const phase = await observeHost(epoch, session.instance_id);
          if (!current()) throw new Error('session_closed');
          if (phase !== 'Ready' && phase !== 'Busy') throw new Error(phase === 'Unknown' ? 'transport_uncertain' : 'host_observation_unavailable');
        }
        if (current() && response.accepted && response.result?.operation === 'capabilities.get') maxBytes = response.result.data.max_message_bytes;
        if (current() && launchTicket !== null && request.operation === 'project.open' && response.accepted && response.result?.operation === 'project.open') {
          root.dataset.initialProjectId = response.result.data.project_id;
          root.dataset.initialCreated = String(response.result.data.created);
          root.dataset.initialOperationId = request.operation_id;
        }
        return response;
      }
      const connectionPort = { ownerKey, exchange: port.exchange, recover: port.recover,
        async reserve(ticket: string, copy?: CopyReservation) {
          if (hostObservation?.epoch === epoch && hostObservation.phase === 'Busy') {
            const phase = await observeHost(epoch, session.instance_id);
            if (!current() || phase !== 'Ready') return null;
          }
          return current() ? reserveControl(session.instance_id, 'connection', ticket, copy) : null;
        },
        release(lease: ControlLease) { admission.release(lease); },
        transportUncertain: () => { if (hostObservation?.epoch === epoch && hostObservation.phase === 'Unknown') blockHost(true); } };
      if (connectionOwner?.snapshot().instanceId !== session.instance_id) connectionOwner = createConnectionController(session.instance_id, connectionPort);
      else connectionOwner.bind(connectionPort);
      connectionView = mountConnectionView(connectionMount, connectionOwner, {
        async copyCurrent(stillCurrent) {
          const refused = () => new Error('現在の接続情報をコピーできませんでした。接続状態を確認してください。');
          const live = () => current() && stillCurrent() && !hostBlocked && sameLiveHost()
            && input.inspect().lease !== null && !input.inspect().frozen;
          if (!live() || admission.busy()) throw refused();
          const reservation = wire.beginCopy();
          if (!reservation) throw refused();
          let lease: ControlLease | null = null;
          try {
            if (!await reservation.ready || !live()) throw refused();
            const phase = await observeHost(epoch, session.instance_id);
            if (phase !== 'Ready' || !live()) throw refused();
            lease = await connectionPort.reserve(crypto.randomUUID(), reservation);
            if (!lease || !live() || admission.current() !== lease) throw refused();
            const discovery = await getWorkspaceDiscovery(session.instance_id);
            if (!live() || admission.current() !== lease) throw refused();
            const copyPhase = await observeHost(epoch, session.instance_id);
            if (copyPhase !== 'Ready' || !live() || admission.current() !== lease) throw refused();
            return await copyWorkspaceDiscovery(ownerKey.ownerGeneration, discovery);
          } finally {
            try { wire.endCopy(reservation); }
            finally { if (lease) admission.release(lease); }
          }
        },
        current,
      });
      async function query(operation: OperationName, params: object): Promise<Response> {
        if (operation === 'operation.get') throw new Error('recovery_port_required');
        const request = { schema_version: 1, instance_id: session.instance_id, operation_id: crypto.randomUUID(), expected_topology_revision: null, operation, params } as Request;
        return port.exchange(request);
      }
      async function recoverPrior() {
        if (!current()) return;
        if (retiringAgent) {
          if (retiringAgentOwnerGeneration !== ownerGeneration) return;
          if (!retiringAgent.getState().connected && !retiringAgent.bindRecoveryPort(port)) return;
          await retiringAgent.recheck();
          if (!current()) return;
          if (!retiringAgent.getState().busy) {
            if (retiringAgentLease) admission.release(retiringAgentLease);
            retiringAgent.retireHost(); retiringAgent = null; retiringAgentLease = null; retiringAgentOwnerGeneration = null;
          }
        }
        const prior = retiringProject;
        if (!prior || prior.request.instance_id !== session.instance_id) return;
        try {
          const request = { schema_version: 1, instance_id: session.instance_id, operation_id: crypto.randomUUID(), expected_topology_revision: null,
            operation: 'operation.get', params: { operation_id: prior.request.operation_id } } as Request;
          const response = await port.recover(prior.ownerKey, request);
          if (!current() || retiringProject !== prior || !response.accepted || response.result?.operation !== 'operation.get') return;
          const original = response.result.data.operation;
          if (!operationStatus(original) || original.operation_id !== prior.request.operation_id || original.phase !== 'completed') return;
          if (prior.kind === 'interrupt' && original.outcome === 'succeeded') {
            if (!prior.runId || !prior.paneId) return;
            const observed = await query('run.get', { run_id: prior.runId });
            if (!current() || retiringProject !== prior || !observed.accepted || observed.result?.operation !== 'run.get') return;
            const run = runReadData(observed.result.data, prior.runId, false)?.run;
            if (!run || run.pane_id !== prior.paneId || run.process !== 'exited' || run.evidence !== 'process_exit') return;
          }
          admission.release(prior.lease); retiringProject = null;
        } catch { /* Unknown keeps the original ticket and blocks new mutation. */ }
      }
      const terminals = new Map<string, ReturnType<typeof mountProjectPaneTerminal>>();
      let view: ReturnType<typeof createProjectPaneView>;
      let projectLease: ControlLease | null = null;
      let agentLease: ControlLease | null = null;
      let agentBinding: ReturnType<ReturnType<typeof createAgentCommandSession>['bind']> | null = null;
      let boundTarget = '';
      const agentOwner = createAgentCommandSession({ instanceId: session.instance_id, generation: identity, ownerKey, port });
      const initialAgent: AgentControlsSnapshot = { instanceId: session.instance_id, generation: identity, observationRevision: 0,
        availability: 'unavailable', busy: false, project: null, pane: null, capabilities: { state: 'unknown', providers: null } };
      const agentObservation = createAgentObservation(initialAgent);
      const agentView = createAgentControls(agentMount, initialAgent, {
        submit(intent, ticket) {
          const lease = reserveControl(session.instance_id, 'agent', ticket);
          if (!lease || !agentBinding || !agentBinding.submit(intent as AgentCommandIntent, ticket)) {
            if (lease) admission.release(lease);
            agentView.settle(ticket, intent, 'refused', !lease
              ? '変換・配送・別の操作、またはホストの受付状態を確認できないため、要求を送信していません。'
              : 'この画面と操作元の対応を確認できないため、要求を送信していません。'); return false;
          }
          agentLease = lease; schedule(); return true;
        },
        inspect(intent) {
          if (!current()) return;
          if (intent.kind === 'inspect-installation') {
            const snap = controller.getSnapshot();
            void controller.inspect({ kind: 'inspect-installation', instanceId: snap.instanceId, generation: snap.generation, topologyRevision: snap.topologyRevision });
          } else if (intent.kind === 'focus-terminal') {
            const paneId = controller.getSnapshot().panes?.selected_pane_id;
            if (paneId) terminals.get(paneId)?.focus();
          } else status.textContent = 'CodexまたはClaude Codeの公式CLIヘルプは、選択中のターミナルで確認してください。';
        },
        restoreFocus(_target, origin) { restoreWorkspaceFocus(origin, [agentMount.querySelector<HTMLElement>('[data-action="launch"]') ?? undefined]); },
      });
      function projectFrame(snapshot: ViewSnapshot) {
        const project = snapshot.projects.projects.find(row => row.project_id === snapshot.projects.selected_project_id) ?? null;
        const pane = snapshot.panes?.panes.find(row => row.pane_id === snapshot.panes?.selected_pane_id) ?? null;
        const key = project && pane ? `${project.project_id}/${pane.pane_id}` : '';
        if (key !== boundTarget) {
          agentBinding?.dispose(); agentBinding = null; boundTarget = key;
          if (key && project && pane) agentBinding = agentOwner.bind(project.project_id, pane.pane_id, notice => {
            if (!current()) return;
            if (notice.kind === 'settlement') {
              agentView.settle(notice.result.ticket, notice.result.target, notice.result.phase, notice.result.message);
              if ((notice.result.phase === 'completed' || notice.result.phase === 'refused') && agentLease) {
                admission.release(agentLease); agentLease = null;
              }
            }
            updateAgentLocal(controller.getSnapshot());
          });
          if (agentLease && agentOwner.getState().busy) void agentOwner.recheck();
          else if (agentLease) { admission.release(agentLease); agentLease = null; }
        }
        return { project, pane };
      }
      function updateAgentLocal(snapshot: ViewSnapshot) {
        const { project, pane } = projectFrame(snapshot);
        const frozen = input.inspect().frozen;
        if (root.dataset.startupState === 'mounted') {
          reconnect.hidden = false;
          reconnect.textContent = admission.busy() || input.inspect().records.some(record => ['preflight','sending','unknown'].includes(record.state))
            ? '元の操作結果を確認し直す' : '接続を確認し直す';
        }
        const fresh = agentObservation.setLocal({ project, pane, availability: frozen ? 'uncertain' : snapshot.availability,
          busy: admission.busy() || snapshot.busy || frozen });
        if (fresh) agentView.update(fresh);
      }
      const initial: ViewSnapshot = { instanceId: session.instance_id, generation: identity, topologyRevision: 0, projects: { projects: [], selected_project_id: null }, panes: null, availability: 'unavailable', busy: false };
      const controller = createProjectPaneController({
        instanceId: session.instance_id, generation: identity, ownerKey, port,
        async pickFolder() {
          if (launchPath !== null) { const path = launchPath; launchPath = null; return path; }
          const origin=document.activeElement instanceof HTMLElement?document.activeElement:null;
          let selection:unknown;
          try {selection = await open({ directory: true, multiple: false });}
          finally {if(current())restoreWorkspaceFocus(origin,[root.querySelector<HTMLElement>('[data-action="open-folder"]')??undefined,root.querySelector<HTMLElement>('main')??undefined]);}
          if (!current()) return null;
          if (selection !== null && typeof selection !== 'string') throw new Error('フォルダーを確認できません。');
          return selection;
        },
        snapshot(snapshot) {
          if (!current()) return; view.render(snapshot); details?.updatePane(snapshot); for(const terminal of terminals.values())terminal.sync(); input.refresh();
          updateAgentLocal(snapshot);
          if (!launchReserved && launchPath !== null && snapshot.availability === 'available' && !snapshot.busy) {
            launchReserved = true; view.requestOpenFolder();
          }
        },
        settlement(ticket, result) {
          if (projectLease?.ticket === String(ticket) && result.disposition !== 'unknown') { admission.release(projectLease); projectLease = null; }
          if (!current()) return; view.settle(ticket, result); updateAgentLocal(controller.getSnapshot());
          if (ticket === launchTicket) root.dataset.initialOutcome = result.disposition;
        },
        installation(data, message) {
          if (!current()) return;
          status.textContent = data === null ? message ?? '導入状況を確認できません。' : data.providers === null ? 'CLIの導入状況は未確認です。' : `検出したCLI: ${data.providers.map(p => `${p.provider} ${p.version}`).join('、') || '未検出'} / シェル: ${data.shell_profile_ids?.join('、') || '未検出'}`;
        },
      });
      view = createProjectPaneView(root, initial, {
        control(intent, ticket) {
          if (details?.session.restoring()) return {disposition:'refused',message:'配置の復元を確認中です。状態を読み直してから操作してください。'};
          const lease = reserveControl(session.instance_id, intent.kind === 'resize-pane' ? 'resize' : 'project', String(ticket));
          if (!lease) return {disposition:'refused',message:'別の操作、変換、配送、保持入力の確認後に操作してください。'};
          projectLease = lease;
          if (launchReserved && root.dataset.initialOutcome === 'pending' && intent.kind === 'open-folder' && launchTicket === null) launchTicket = ticket;
          return Promise.resolve(controller.control(intent,ticket)).then(result => {
            if (result.disposition !== 'unknown' && projectLease === lease) { admission.release(lease); projectLease = null; }
            return result;
          });
        },
        inspect(intent) { if (!current()) return; if (intent.kind === 'reread') stopped = false; void controller.inspect(intent).then(async()=>{if(!current())return;if(intent.kind==='reread')await details?.refresh();if(!current())return;await input.recoverGuard();if(current())schedule();}); },
        composing:input.hasPendingComposition,
        mountTerminal(slot, target) {
          const terminal = mountProjectPaneTerminal(slot, target.projectId, target.paneId, { snapshot: controller.getSnapshot, resize: intent => view.requestPaneResize(intent), input });
          terminals.set(target.paneId, terminal);
          return () => { terminal.dispose(); if (terminals.get(target.paneId) === terminal) terminals.delete(target.paneId); };
        },
      });
      input.connect({ownerKey,snapshot:controller.getSnapshot,maxBytes:()=>maxBytes,exchange:port.exchange,recover:port.recover});
      details.bind({
        ownerKey, exchange: port.exchange, recover: port.recover, pane: controller.getSnapshot, maxBytes: () => maxBytes,
        async refreshPane() { await controller.refresh(); const snapshot = controller.getSnapshot(); return snapshot.availability === 'available' ? snapshot : null; },
        async pickFile() {
          const origin = document.activeElement instanceof HTMLElement ? document.activeElement : null;
          let selected: unknown;
          try { selected = await open({ directory: false, multiple: false }); }
          finally { if (current()) restoreWorkspaceFocus(origin, [detailsButton, root.querySelector<HTMLElement>('main') ?? undefined]); }
          if (!current()) return null;
          if (selected !== null && typeof selected !== 'string') throw new Error('protocol_failed');
          return selected;
        },
        async copy(text) { try { await navigator.clipboard.writeText(text); return true; } catch { return false; } },
      });
      creationContext = () => { const snapshot = controller.getSnapshot(); return { active: current(), mounted: root.dataset.startupState === 'mounted', session, generation: identity, epoch, label: getCurrentWebviewWindow().label, href: location.href, origin: location.protocol === 'tauri:' ? 'tauri://localhost' : location.origin, selectedProject: snapshot.projects.projects.find(row => row.project_id === snapshot.projects.selected_project_id) ?? null }; };
      creations.activate();
      active = () => {
        connectionView?.dispose(); connectionView = null;
        creations.beginReconnect(); input.disconnect(); stopped = true; details?.disconnect();
        agentOwner.setConnected(false); agentBinding?.dispose(); agentBinding = null;
        if (agentOwner.getState().busy && !retiringAgent) { retiringAgent = agentOwner; retiringAgentLease = agentLease; retiringAgentOwnerGeneration = ownerGeneration; }
        else if (agentLease) admission.release(agentLease);
        agentObservation.retire(); agentView.dispose();
        const stage = controller.getPending();
        if (projectLease && stage) {
          retiringProject = { ownerKey, request: stage.request, kind: stage.facts.kind,
            runId: 'runId' in stage.intent ? stage.intent.runId : null,
            paneId: 'paneId' in stage.intent ? stage.intent.paneId : null, lease: projectLease };
        } else if (projectLease) admission.release(projectLease);
        projectLease = null; controller.dispose(); view.dispose(); terminals.clear(); launchPath = null;
      };
      const read = async (operation: 'events.wait' | 'output.read', params: Request['params']) => {
        const request = { schema_version: 1, instance_id: session.instance_id, operation_id: crypto.randomUUID(), expected_topology_revision: null, operation, params } as Request;
        const response = await port.exchange(request);
        if (!response.accepted && response.error?.code === 'resource_exhausted') return null;
        if (!validReadResponse(request, response)) throw new Error('protocol_failed'); return response;
      };
      async function refreshAgentObservation() {
        const snapshot = controller.getSnapshot();
        updateAgentLocal(snapshot);
        const ticket = agentObservation.begin();
        if (!ticket || snapshot.availability !== 'available') return;
        const { project, pane } = projectFrame(snapshot);
        if (!project || !pane || snapshot.projects.selected_project_id !== project.project_id || snapshot.panes?.selected_pane_id !== pane.pane_id) return;
        try {
          const caps = await query('capabilities.get', {});
          if (!current()) return;
          const projects = await query('project.list', {});
          if (!current()) return;
          const panes = await query('pane.list', { project_id: project.project_id });
          if (!current() || !caps.accepted || caps.result?.operation !== 'capabilities.get' || !projects.accepted || projects.result?.operation !== 'project.list'
            || !panes.accepted || panes.result?.operation !== 'pane.list'
            || caps.topology_revision !== projects.topology_revision || projects.topology_revision !== panes.topology_revision
            || panes.topology_revision !== snapshot.topologyRevision || projects.result.data.selected_project_id !== project.project_id
            || panes.result.data.project_id !== project.project_id || panes.result.data.selected_pane_id !== pane.pane_id) throw new Error('observation_unavailable');
          const selectedProject = projects.result.data.projects.find(row => row.project_id === project.project_id);
          const selectedPane = panes.result.data.panes.find(row => row.pane_id === pane.pane_id);
          const providers = caps.result.data.providers;
          if (!selectedProject || !selectedPane || selectedPane.project_id !== project.project_id
            || selectedPane.current_run_id !== pane.current_run_id
            || providers !== null && (!Array.isArray(providers) || providers.some((row: ProviderCapability) => !['codex', 'claude'].includes(row.provider) || !row.version)
              || new Set(providers.map((row: ProviderCapability) => row.provider)).size !== providers.length)) throw new Error('observation_unavailable');
          let sequence = Math.max(caps.event_seq, projects.event_seq, panes.event_seq);
          if (caps.event_seq > projects.event_seq || projects.event_seq > panes.event_seq) throw new Error('observation_unavailable');
          if (selectedPane.current_run_id !== null) {
            const run = await query('run.get', { run_id: selectedPane.current_run_id });
            if (!current() || !run.accepted || run.result?.operation !== 'run.get' || run.topology_revision !== panes.topology_revision || run.event_seq < sequence) throw new Error('observation_unavailable');
            const observed = runReadData(run.result.data, selectedPane.current_run_id, false)?.run;
            if (!observed || !observed.current || observed.pane_id !== selectedPane.pane_id) throw new Error('observation_unavailable');
            selectedPane.observation = observed; sequence = run.event_seq;
          } else if (selectedPane.observation !== null) throw new Error('observation_unavailable');
          const committed = agentObservation.commit(ticket, { instanceId: session.instance_id, generation: identity,
            availability: 'available', busy: admission.busy() || snapshot.busy, project: selectedProject, pane: selectedPane,
            capabilities: { state: providers === null ? 'unknown' : 'known', providers }, eventSeq: sequence });
          if (committed) agentView.update(committed);
        } catch { const failed = agentObservation.failure(ticket); if (failed) agentView.update(failed); }
      }
      async function cycle() {
        frame = null;
        if (!current() || stopped || hostBlocked || document.hidden) return;
        if (input.inspect().frozen) { agentOwner.setConnected(false); return; }
        try {
          await recoverPrior();
          if (!current() || stopped) return;
          await details?.recoverSameHost();
          if (!current() || stopped) return;
          await agentOwner.observe();
          if (!current() || stopped) return;
          if (agentLease && !agentOwner.getState().busy) { admission.release(agentLease); agentLease = null; }
          const pending = controller.getPending();
          if (pending) await controller.refresh();
          if (!current() || stopped) return;
          await refreshAgentObservation();
          if (!current() || stopped) return;
          const events = await read('events.wait', { after_event_seq: eventSeq, wait_ms: 0 });
          if (!current()) return;
          if (events) { const data = events.result!.data as EventsWaitData; eventSeq = data.next_event_seq;
            if (data.status !== 'no_change') { await controller.refresh(); if (!current() || stopped) return; void connectionOwner?.refresh(); } }
          if (!current() || stopped) return;
          for (const terminal of terminals.values()) {
            if (controller.getSnapshot().busy) break;
            const captured = terminal.readTarget(); if (!captured) continue;
            if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new Error('protocol_failed');
            const output = await read('output.read', { run_id: captured.runId, cursor: captured.cursor, max_bytes: maxBytes });
            if (!current() || stopped) return; if (output) terminal.append(captured, output.result!.data as OutputReadData); terminal.flushResize();
          }
          schedule();
        } catch (error) { if (current()) { if(error==='shutdown_in_progress'){agentOwner.setConnected(false);void input.recoverGuard();}else{agentOwner.setConnected(false); stopped = true; if (!hostBlocked) status.textContent = '出力または作業状態を確認できません。状態を読み直してください。';} } }
      }
      function schedule() { if (current() && !stopped && !hostBlocked && !input.inspect().frozen && !document.hidden && frame === null) frame = requestAnimationFrame(() => { void cycle(); }); }
      const resume = () => { if (!document.hidden) schedule(); };
      document.addEventListener('visibilitychange', resume);
      let agentGuardFrozen = input.inspect().frozen;
      const inputChanges=input.observe(() => {
        const frozen = input.inspect().frozen;
        if (frozen) agentOwner.setConnected(false);
        else if (agentGuardFrozen && current()) { agentOwner.setConnected(true); void agentOwner.recheck(); }
        agentGuardFrozen = frozen;
        if (current()) updateAgentLocal(controller.getSnapshot());
        schedule();
      });
      const admissionChanges=admission.observe(() => { if (current()) updateAgentLocal(controller.getSnapshot()); schedule(); });
      const teardown = active; active = () => { admissionChanges();inputChanges();document.removeEventListener('visibilitychange', resume); teardown(); };
      await controller.refresh(); if (!current()) return;
      if (connectionOwner.snapshot().original && ['unconfirmed', 'accepted', 'in_progress', 'read_failed'].includes(connectionOwner.snapshot().original!.phase)) void connectionOwner.recheck();
      else void connectionOwner.refresh();
      // A held old Q must not hold the mounted UI or its visible recovery control.
      void recoverPrior().catch(() => {}).finally(() => { if (current()) updateAgentLocal(controller.getSnapshot()); });
      void details.recoverSameHost().catch(() => {}).finally(() => { if (current()) updateAgentLocal(controller.getSnapshot()); });
      root.dataset.startupState = 'mounted'; status.textContent = '明示的な操作だけでペインを起動します。';
      updateAgentLocal(controller.getSnapshot());
      await revealOnce(); if (!current()) return; schedule();
    } catch (error) { wire.retire(); if (current()) { active?.(); active = null; connectionView?.dispose(); connectionView = null;
      const shutdown = error === 'shutdown_in_progress' || error instanceof Error && error.message === 'shutdown_in_progress';
      if (!openReturned && shutdown) {
        showRecoveryShell();
        void observeHost(epoch, null).then(phase => { if (!current()) return; if (phase === 'Unknown') blockHost(true); else showRecoveryShell(); });
        void input.recoverGuard();
        delete root.dataset.session; await revealOnce(); return;
      }
      if (!openReturned) await observeHost(epoch, null);
      if (!hostUnknown()) blockHost(false);
      delete root.dataset.session; await revealOnce(); } }
    finally { reconnecting = false; }
  }
  reconnect.onclick = () => { void connect(); };
  try { const release = await listen('workspace-close-refused', () => { if (!disposed) status.textContent = '閉鎖の完了を確認できません。対象と要求を保持しています。'; }); if (disposed) release(); else unlisten = release; }
  catch { status.textContent = '閉鎖通知の購読を確認できません。'; }
  await input.initialize();await connect(); return { dispose };
}
