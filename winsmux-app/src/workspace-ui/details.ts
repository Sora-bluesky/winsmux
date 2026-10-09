import type { ArtifactDiffData, ArtifactListData, ArtifactReadData, ArtifactRef, DiagnosticsData, ErrorCode, LayoutRestoreData, OperationName, OperationStatus, PaneSummary, ProjectSummary } from '../generated/workspace-contract';

export interface DetailsHostLifetime { readonly instanceId: string; readonly nonce: string }
export interface DetailsTarget {
  readonly instanceId: string;
  readonly generation: string;
  readonly projectId: string | null;
  readonly artifactId: string | null;
}
export type DetailsIntent = DetailsTarget & (
  | { readonly kind: 'register'; readonly source: 'picker' | 'git'; readonly relativePath: string | null }
  | { readonly kind: 'restore' }
  | { readonly kind: 'list' }
  | { readonly kind: 'read' | 'diff'; readonly maxBytes: number }
  | { readonly kind: 'diagnostics' }
);
type MutationIntent = Extract<DetailsIntent, { kind: 'register' | 'restore' }>;
export type DetailsTerminal =
  | { kind: 'completed'; operation: OperationStatus }
  | { kind: 'refused'; code: ErrorCode }
  | { kind: 'picker-cancelled' };
export type DetailsResult =
  | { kind: 'error'; code: ErrorCode }
  | { kind: 'unconfirmed'; message: string }
  | { kind: 'read'; data: ArtifactReadData }
  | { kind: 'diff'; data: ArtifactDiffData }
  | { kind: 'list'; data: ArtifactListData }
  | { kind: 'register'; artifact: ArtifactRef }
  | { kind: 'restore'; data: LayoutRestoreData; observedInstanceId: string; observedGeneration: number; projects: ProjectSummary[]; panes: PaneSummary[] }
  | { kind: 'diagnostics'; data: DiagnosticsData };
export interface DetailsProjection { ticket: string; intent: DetailsIntent; result: DetailsResult }
export interface DetailsSnapshot {
  instanceId: string;
  generation: string;
  revision: number;
  /** Advance only for an explicit external selection command. */
  selectionRevision: number;
  /** Advance only for a fresh authoritative inventory observation. */
  artifactsRevision: number;
  availability: 'available' | 'unavailable' | 'uncertain';
  project: ProjectSummary | null;
  artifacts: ArtifactListData | null;
  /** Last external command, paired with selectionRevision; it may outlive its inventory entry. */
  selectedArtifactId: string | null;
  maxBytes: number;
  projection?: DetailsProjection | null;
}
export interface DetailsCallbacks {
  /** Auxiliary notification. The host-lifetime session owns selection even if delivery fails. */
  selectionChanged(target: DetailsTarget): unknown;
  /** Reserve the exact mutation flight before the admission notification. No picker or request is sent here. */
  reserveMutation(intent: Extract<DetailsIntent, {kind: 'register' | 'restore'}>, ticket: string): boolean;
  /** Delivery is not completion. The controller independently validates Rust results. */
  submit(intent: DetailsIntent, ticket: string): unknown;
  /** Return true only after the clipboard write is confirmed. */
  copy(text: string): unknown;
}
const operations: readonly OperationName[] = ['capabilities.get', 'connection.request', 'connection.list', 'connection.decide', 'connection.revoke', 'host.stop', 'project.list', 'project.open', 'project.select', 'project.forget', 'pane.list', 'pane.create', 'pane.split', 'pane.select', 'pane.close', 'pane.resize', 'shell.launch', 'agent.launch', 'input.write', 'input.key', 'run.get', 'run.interrupt', 'operation.get', 'output.read', 'events.wait', 'layout.save', 'layout.restore', 'artifact.register', 'artifact.list', 'artifact.read', 'artifact.diff', 'artifact.choose', 'artifact.choice.list', 'diagnostics.get'];
const errors: readonly ErrorCode[] = ['invalid_request', 'unsupported_version', 'permission_denied', 'target_not_found', 'stale_topology', 'operation_conflict', 'in_progress', 'not_running', 'already_running', 'unsupported_capability', 'output_gap', 'persistence_failed', 'runtime_failed', 'state_unknown', 'resource_exhausted', 'root_changed', 'unsupported_file', 'not_a_repository'];
const errorText: Partial<Record<ErrorCode, string>> = {
  target_not_found: '対象が見つかりません。削除された可能性があります。',
  root_changed: 'プロジェクトの場所が変わりました。対象を再確認してください。',
  permission_denied: 'この対象を読む権限がありません。',
  unsupported_file: 'このファイル形式は確認できません。',
  persistence_failed: '保存済みの配置を復元できません。破損や書込み状態を確認してください。',
  unsupported_version: '保存形式の版を確認できません。',
  not_a_repository: 'Gitの差分を確認できません。',
};
const validNumber = (n: number) => Number.isSafeInteger(n) && n >= 0;
const validId = (s: unknown): s is string => typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s);
const nonempty = (s: unknown): s is string => typeof s === 'string' && s.length > 0;
function relativePath(value: unknown): value is string {
  return nonempty(value) && !/[\p{Cc}\\:]/u.test(value) && value.split('/').every(part =>
    part !== '' && part !== '.' && part !== '..' && !/[. ]$/.test(part)
    && !/^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$/i.test(part.split('.')[0]));
}
const equalLifetime = (a: DetailsHostLifetime, b: DetailsHostLifetime) => a.instanceId === b.instanceId && a.nonce === b.nonce;
const sameTarget = (a: DetailsTarget, b: DetailsTarget) => a.instanceId === b.instanceId && a.generation === b.generation && a.projectId === b.projectId && a.artifactId === b.artifactId;
function sameIntent(a: DetailsIntent, b: DetailsIntent): boolean {
  if (!sameTarget(a, b) || a.kind !== b.kind) return false;
  if (a.kind === 'register') return b.kind === 'register' && a.source === b.source && a.relativePath === b.relativePath;
  if (a.kind === 'read' || a.kind === 'diff') return (b.kind === 'read' || b.kind === 'diff') && a.maxBytes === b.maxBytes;
  return true;
}
const mutation = (i: DetailsIntent): i is MutationIntent => i.kind === 'register' || i.kind === 'restore';
const hostScope = (i: DetailsIntent) => i.kind === 'restore' || i.kind === 'diagnostics';
const validError = (s: unknown): s is ErrorCode => errors.includes(s as ErrorCode);
function validArtifact(a: ArtifactRef, projectId: string): boolean {
  return !!a && validId(a.artifact_id) && a.project_id === projectId && relativePath(a.relative_path)
    && ((a.association === null && a.run_id === null) || (a.association === 'caller_selected' && validId(a.run_id)));
}
function validList(list: ArtifactListData, projectId: string): boolean {
  return !!list && Array.isArray(list.registered) && Array.isArray(list.git_candidates)
    && list.registered.every(a => validArtifact(a, projectId))
    && new Set(list.registered.map(a => a.artifact_id)).size === list.registered.length
    && list.git_candidates.every(relativePath) && new Set(list.git_candidates).size === list.git_candidates.length
    && (list.git_candidates_error === null || list.git_candidates_error === 'resource_exhausted' || list.git_candidates_error === 'unsupported_file');
}
function gitCandidateReason(value: ArtifactListData['git_candidates_error'] | undefined): string | null {
  if (value === 'resource_exhausted') return 'プロジェクトフォルダー全体が1 MiBを超えるため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。';
  if (value === 'unsupported_file') return 'プロジェクトフォルダーにジャンクション、シンボリックリンク、ハードリンク、または入れ子の .git があるため、Git の変更の候補を表示できません。登録済みの成果物は表示しています。';
  return null;
}
function diagnosticProjection(data: DiagnosticsData): string | null {
  const validSet = (v: unknown, allowed: readonly string[]) => Array.isArray(v) && v.every(s => typeof s === 'string' && allowed.includes(s)) && new Set(v).size === v.length;
  if (!data || data.protocol_version !== 1 || data.product_version !== '0.38.0'
    || !['unpaired', 'pending', 'granted', 'revoked'].includes(data.connection_state)
    || !validSet(data.capabilities, operations) || !validSet(data.failure_codes, errors)) return null;
  return JSON.stringify({ protocol_version: 1, product_version: '0.38.0', connection_state: data.connection_state,
    capabilities: [...data.capabilities], failure_codes: [...data.failure_codes] }, null, 2);
}
interface Pending { ticket: string; intent: DetailsIntent; phase: 'awaiting' | 'unknown'; owner: string; contextEpoch: number; inventoryEpoch: number; expectedPath: string | null }
interface Receipt { ticket: string; intent: MutationIntent; owner: string; contextEpoch: number; outcome: 'succeeded' | 'failed' | 'cancelled'; code: ErrorCode | null; expectedPath: string | null; consumed: boolean }

function validSnapshot(next: DetailsSnapshot, instanceId: string): boolean {
  return next !== null && typeof next === 'object' && validNumber(next.revision)
    && validNumber(next.selectionRevision) && validNumber(next.artifactsRevision) && next.instanceId === instanceId
    && nonempty(next.generation) && ['available', 'unavailable', 'uncertain'].includes(next.availability)
    && validNumber(next.maxBytes) && next.maxBytes > 0
    && (next.project === null ? next.artifacts === null && next.selectedArtifactId === null : !!next.project && validId(next.project.project_id)
      && ['verified', 'changed', 'unavailable', 'unknown'].includes(next.project.root_state)
      && (next.artifacts === null || validList(next.artifacts, next.project.project_id))
      && (next.selectedArtifactId === null || validId(next.selectedArtifactId)));
}
const sameScope = (a: DetailsSnapshot, b: DetailsSnapshot) => a.instanceId === b.instanceId
  && a.generation === b.generation && a.project?.project_id === b.project?.project_id;

/** One session per real host lifetime, retained by the controller across view disposal. */
export function createDetailsSession(lifetime: DetailsHostLifetime, crypto: Crypto) {
  if (!validId(lifetime.instanceId) || !nonempty(lifetime.nonce)) throw new Error('Invalid host lifetime');
  const host = Object.freeze({ ...lifetime });
  const used = new Set<string>();
  const activeOwners = new Set<string>();
  const listeners = new Set<() => void>();
  let retired = false, transportBlocked = false, latch: Pending | null = null, lease: Pending | null = null, authority: Pending | null = null, receipt: Receipt | null = null;
  // The received baseline never contains local selection or list projections.
  // Both survive disposal in this one real-host session; view contents do not.
  let receivedSnapshot: DetailsSnapshot | null = null, selectionSnapshot: DetailsSnapshot | null = null;
  let selectionConfirmed = false, selectionEpoch = 0, inventoryEpoch = 0, hostEpoch = 0;
  const liveTarget = (intent: DetailsIntent) => !retired && !transportBlocked && selectionConfirmed && !!selectionSnapshot
    && selectionSnapshot.availability === 'available' && intent.instanceId === selectionSnapshot.instanceId
    && intent.generation === selectionSnapshot.generation && (hostScope(intent)
      ? intent.projectId === null && intent.artifactId === null
      : selectionSnapshot.project?.root_state === 'verified' && nonempty(selectionSnapshot.project.path)
        && intent.projectId === selectionSnapshot.project.project_id && intent.artifactId === selectionSnapshot.selectedArtifactId);
  const validIntentArgs = (intent: DetailsIntent): boolean => {
    if (!intent || typeof intent !== 'object') return false;
    switch (intent.kind) {
      case 'register':
        return intent.source === 'picker' ? intent.relativePath === null
          : intent.source === 'git' && relativePath(intent.relativePath)
            && !!selectionSnapshot?.artifacts?.git_candidates.includes(intent.relativePath);
      case 'read':
      case 'diff':
        return intent.artifactId !== null && validNumber(intent.maxBytes) && intent.maxBytes === selectionSnapshot?.maxBytes;
      case 'list':
        return validId(intent.projectId);
      case 'restore':
      case 'diagnostics':
        return intent.projectId === null && intent.artifactId === null;
      default:
        return false;
    }
  };
  const epochFor = (intent: DetailsIntent) => hostScope(intent) ? hostEpoch : selectionEpoch;
  const currentRead = (pending: Pending) => activeOwners.has(pending.owner) && pending.contextEpoch === epochFor(pending.intent)
    && (hostScope(pending.intent) || pending.inventoryEpoch === inventoryEpoch) && liveTarget(pending.intent);
  const currentAuthority = (owner: string, ticket: string, intent: DetailsIntent) => !retired && activeOwners.has(owner)
    && authority?.owner === owner && authority.ticket === ticket && sameIntent(authority.intent, intent)
    && authority.contextEpoch === epochFor(intent) && (mutation(intent) || hostScope(intent) || authority.inventoryEpoch === inventoryEpoch)
    && liveTarget(intent);
  const matchingRead = (owner: string, ticket: string, intent: DetailsIntent) => !!lease
    && lease.owner === owner && lease.ticket === ticket && sameIntent(lease.intent, intent)
    && currentRead(lease) && currentAuthority(owner, ticket, intent);
  const notify = () => { for (const listener of [...listeners]) { try { listener(); } catch { /* A notification cannot roll back a host transition. */ } } };
  const nextTicket = () => {
    let ticket: string;
    do {
      const b = crypto.getRandomValues(new Uint8Array(16)); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
      const h = Array.from(b, n => n.toString(16).padStart(2, '0')).join('');
      ticket = `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
    } while (used.has(ticket));
    used.add(ticket); return ticket;
  };
  return {
    lifetime: host,
    allocateViewId: () => { const owner = nextTicket(); activeOwners.add(owner); return owner; },
    isRetired: () => retired,
    isTransportBlocked: () => transportBlocked,
    mutationPending: () => latch !== null,
    matchesMutation: (ticket: string, originalLifetime: DetailsHostLifetime, originalIntent: DetailsIntent) =>
      !retired && !!latch && latch.ticket === ticket && equalLifetime(host, originalLifetime) && sameIntent(latch.intent, originalIntent),
    restoring: () => latch?.intent.kind === 'restore',
    mutationPhase: () => latch?.phase ?? null,
    readPending: () => lease !== null,
    mayProject: (owner: string, ticket: string, intent: DetailsIntent) => currentAuthority(owner, ticket, intent),
    requestStillPending(owner: string, ticket: string, intent: DetailsIntent): boolean {
      const pending = mutation(intent) ? latch : lease;
      return !retired && !!pending && pending.owner === owner && pending.ticket === ticket && sameIntent(pending.intent, intent);
    },
    selectionState: () => ({ snapshot: structuredClone(selectionSnapshot), confirmed: selectionConfirmed, epoch: selectionEpoch, inventoryEpoch }),
    observeSelection(snapshot: DetailsSnapshot): { accepted: boolean; selectionChanged: boolean } {
      let next: DetailsSnapshot | null = null;
      try { next = structuredClone(snapshot); } catch { /* Invalid delivery remains unconfirmed. */ }
      const prior = receivedSnapshot;
      if (!retired && next && validSnapshot(next, host.instanceId)
        && prior && next.revision === prior.revision && JSON.stringify(next) === JSON.stringify(prior)) {
        return { accepted: false, selectionChanged: false };
      }
      const scopeMatches = !!next && !!prior && sameScope(next, prior);
      const streamsValid = !!next && (!scopeMatches || !!prior && next.selectionRevision >= prior.selectionRevision && next.artifactsRevision >= prior.artifactsRevision
        && (next.selectionRevision !== prior.selectionRevision || next.selectedArtifactId === prior.selectedArtifactId)
        && (next.artifactsRevision !== prior.artifactsRevision || JSON.stringify(next.artifacts) === JSON.stringify(prior.artifacts)));
      if (retired || transportBlocked || !next || !validSnapshot(next, host.instanceId) || prior && next.revision <= prior.revision || !streamsValid) {
        selectionConfirmed = false; selectionEpoch++; hostEpoch++; lease = null; notify(); return { accepted: false, selectionChanged: false };
      }
      const previous = selectionSnapshot;
      const externalSelection = scopeMatches && next.selectionRevision !== prior!.selectionRevision;
      const inventoryChanged = !scopeMatches || next.artifactsRevision !== prior!.artifactsRevision;
      const selectedId = !scopeMatches || externalSelection ? next.selectedArtifactId : previous!.selectedArtifactId;
      const inventory = inventoryChanged ? next.artifacts : previous!.artifacts;
      if ((!scopeMatches || externalSelection) && selectedId !== null && !inventory?.registered.some(a => a.artifact_id === selectedId)) {
        selectionConfirmed = false; selectionEpoch++; hostEpoch++; lease = null; notify(); return { accepted: false, selectionChanged: false };
      }
      const actualId = selectedId !== null && inventory?.registered.some(a => a.artifact_id === selectedId) ? selectedId : null;
      const changed = !selectionConfirmed || !scopeMatches || externalSelection || actualId !== previous!.selectedArtifactId
        || next.project?.path !== previous?.project?.path || next.project?.root_state !== previous?.project?.root_state || next.availability !== 'available';
      if (!prior || prior.generation !== next.generation) hostEpoch++;
      receivedSnapshot = structuredClone(next);
      selectionSnapshot = { ...next, artifacts: structuredClone(inventory), selectedArtifactId: actualId };
      selectionConfirmed = true; if (changed) selectionEpoch++;
      if (inventoryChanged) inventoryEpoch++;
      if (lease && (hostScope(lease.intent) ? !liveTarget(lease.intent) || lease.contextEpoch !== hostEpoch : changed || inventoryChanged)) lease = null;
      notify();
      return { accepted: true, selectionChanged: externalSelection && actualId !== previous!.selectedArtifactId };
    },
    selectArtifact(artifactId: string): boolean {
      const current = selectionSnapshot;
      if (retired || !selectionConfirmed || !current || current.availability !== 'available'
        || current.project?.root_state !== 'verified' || !nonempty(current.project.path)
        || !current.artifacts?.registered.some(a => a.artifact_id === artifactId) || current.selectedArtifactId === artifactId) return false;
      selectionSnapshot = { ...current, selectedArtifactId: artifactId }; selectionEpoch++; lease = null; notify(); return true;
    },
    /** Consume the correlated list and update its overlay before notifying any view. */
    finishList(owner: string, ticket: string, intent: DetailsIntent, inventory: ArtifactListData): boolean {
      if (intent.kind !== 'list' || !matchingRead(owner, ticket, intent)) return false;
      let next: ArtifactListData | null = null;
      try { next = structuredClone(inventory); } catch { /* A malformed matching result consumes only its lease. */ }
      lease = null;
      if (intent.projectId === null || !next || !validList(next, intent.projectId)) { notify(); return false; }
      const current = selectionSnapshot!;
      const selectedId = next.registered.some(a => a.artifact_id === current.selectedArtifactId) ? current.selectedArtifactId : null;
      if (selectedId !== current.selectedArtifactId) selectionEpoch++;
      inventoryEpoch++;
      selectionSnapshot = { ...current, artifacts: next, selectedArtifactId: selectedId };
      notify(); return true;
    },
    subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; },
    begin(intent: DetailsIntent, owner: string, onAccepted?: (ticket: string, frozenIntent: DetailsIntent) => boolean): string | null {
      if (retired || !activeOwners.has(owner) || !validIntentArgs(intent) || !liveTarget(intent)
        || latch?.intent.kind === 'restore' || (mutation(intent) ? latch !== null : lease !== null)) return null;
      let frozenIntent: DetailsIntent;
      try { frozenIntent = Object.freeze(structuredClone(intent)); } catch { return null; }
      const pending = { ticket: nextTicket(), intent: frozenIntent, phase: 'awaiting' as const, owner, contextEpoch: epochFor(intent), inventoryEpoch, expectedPath: null };
      authority = pending;
      if (mutation(intent)) { lease = null; latch = pending; receipt = null; } else lease = pending;
      if (mutation(intent) && onAccepted) {
        let reserved = false;
        try { reserved = onAccepted(pending.ticket, pending.intent) === true; } catch { /* Reservation did not install a flight. */ }
        if (!reserved) {
          receipt = { ticket: pending.ticket, intent: pending.intent as MutationIntent, owner, contextEpoch: pending.contextEpoch,
            outcome: 'failed', code: 'runtime_failed', expectedPath: null, consumed: false };
          latch = null;
        }
      }
      notify(); return pending.ticket;
    },
    markUnknown(ticket: string) {
      const pending = latch?.ticket === ticket ? latch : lease?.ticket === ticket ? lease : null;
      if (pending) { pending.phase = 'unknown'; notify(); }
    },
    prepareMutationPath(ticket: string, originalLifetime: DetailsHostLifetime, originalIntent: DetailsIntent, path: string): boolean {
      if (retired || !latch || latch.ticket !== ticket || latch.phase !== 'awaiting' || latch.expectedPath !== null
        || !equalLifetime(host, originalLifetime) || !sameIntent(latch.intent, originalIntent)
        || latch.intent.kind !== 'register' || !relativePath(path)
        || latch.intent.source === 'git' && latch.intent.relativePath !== path) return false;
      latch.expectedPath = path; return true;
    },
    blockTransport() {
      if (retired || transportBlocked) return;
      transportBlocked = true; selectionConfirmed = false; selectionEpoch++; hostEpoch++;
      if (latch) latch.phase = 'unknown';
      lease = null; authority = null; notify();
    },
    confirmRecoveredTransport(originalLifetime: DetailsHostLifetime) {
      // A new, verified connection may reopen admission only after the original
      // mutation has reached a correlated terminal state.
      if (retired || !transportBlocked || latch || !equalLifetime(host, originalLifetime)) return false;
      transportBlocked = false; selectionConfirmed = false; selectionEpoch++; hostEpoch++;
      lease = null; authority = null; notify(); return true;
    },
    abandonRead(ticket: string) {
      if (lease?.ticket !== ticket) return false;
      lease = null; if (authority?.ticket === ticket) authority = null;
      notify(); return true;
    },
    retireProjection(owner: string) {
      if (!activeOwners.delete(owner)) return;
      if (lease?.owner === owner) lease = null;
      notify();
    },
    finishRead(owner: string, ticket: string, intent: DetailsIntent): boolean {
      if (!matchingRead(owner, ticket, intent)) return false;
      const pending = lease!;
      lease = null; notify();
      // A newer request keeps its authority even if its lease completes synchronously.
      return currentRead(pending) && currentAuthority(owner, ticket, intent);
    },
    settleMutation(ticket: string, originalLifetime: DetailsHostLifetime, originalIntent: DetailsIntent, terminal: DetailsTerminal): boolean {
      if (retired || !latch || latch.ticket !== ticket || !equalLifetime(host, originalLifetime) || !sameIntent(latch.intent, originalIntent) || !mutation(latch.intent)) return false;
      let outcome: Receipt['outcome'], code: ErrorCode | null = null;
      if (terminal.kind === 'completed') {
        const op = terminal.operation;
        if (op.operation_id !== ticket || op.phase !== 'completed') return false;
        if (op.outcome === 'succeeded' && op.error_code === null) outcome = 'succeeded';
        else if (op.outcome === 'failed' && validError(op.error_code)) { outcome = 'failed'; code = op.error_code; }
        else return false;
      } else if (terminal.kind === 'refused' && validError(terminal.code)) { outcome = 'failed'; code = terminal.code; }
      else if (terminal.kind === 'picker-cancelled' && latch.intent.kind === 'register' && latch.intent.source === 'picker') outcome = 'cancelled';
      else return false;
      receipt = { ticket, intent: latch.intent, owner: latch.owner, contextEpoch: latch.contextEpoch, outcome, code, expectedPath: latch.expectedPath, consumed: false };
      latch = null; notify(); return true;
    },
    consumeMutationReceipt(owner: string, ticket: string, intent: DetailsIntent): Receipt | null {
      if (!receipt || receipt.consumed || receipt.owner !== owner || receipt.ticket !== ticket
        || receipt.contextEpoch !== epochFor(intent) || !sameIntent(receipt.intent, intent)
        || !currentAuthority(owner, ticket, intent)) return null;
      receipt.consumed = true; return structuredClone(receipt);
    },
    /** Only after the controller confirms the actual host has ended. Not a disconnect. */
    retireHost(originalLifetime: DetailsHostLifetime): boolean {
      if (retired || !equalLifetime(host, originalLifetime)) return false;
      retired = true; transportBlocked = false; latch = null; lease = null; authority = null; receipt = null; activeOwners.clear();
      selectionConfirmed = false; selectionSnapshot = null; receivedSnapshot = null; selectionEpoch++; inventoryEpoch++; hostEpoch++; notify(); return true;
    },
  };
}
export type DetailsSession = ReturnType<typeof createDetailsSession>;

export function createDetails(container: HTMLElement, initial: DetailsSnapshot, session: DetailsSession, callbacks: DetailsCallbacks, origin?: HTMLElement) {
  const doc = container.ownerDocument;
  const owner = session.allocateViewId();
  let current: DetailsSnapshot = structuredClone(initial), confirmed = false, disposed = false, closed = false;
  let presentationEpoch = -1, presentationInventoryEpoch = -1, projectionText: string | null = null, copyEpoch = 0, copying = false;
  let active: 'artifacts' | 'layout' | 'diagnostics' = 'artifacts';
  const openingTarget = { instanceId: initial.instanceId, generation: initial.generation, projectId: initial.project?.project_id ?? null, artifactId: initial.selectedArtifactId };
  const make = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string) => {
    const node = doc.createElement(tag); if (text !== undefined) node.textContent = text; return node;
  };
  const root = make('section'); root.className = 'workspace-details'; root.setAttribute('aria-label', '成果物・配置・診断');
  const style = make('style'); style.textContent = '.workspace-details{min-width:0;overflow-wrap:anywhere}.workspace-details button{max-width:100%}.workspace-details nav{display:flex;flex-wrap:wrap;gap:.5rem}.workspace-details pre{white-space:pre-wrap;overflow:auto;max-height:30rem;max-width:100%}.workspace-details :focus-visible{outline:2px solid currentColor;outline-offset:2px}.workspace-details [hidden]{display:none!important}';
  const button = (label: string, action: string) => { const node = make('button', label); node.type = 'button'; node.dataset.action = action; return node; };
  const field = (name: string, label: string) => { const node = make('p', label); node.dataset.field = name; return node; };
  const close = button('詳細を閉じる', 'close');
  const heading = make('h2', '成果物・配置・診断'); heading.tabIndex = -1;
  const nav = make('nav'); nav.setAttribute('aria-label', '詳細の表示');
  const tabs = { artifacts: button('成果物', 'artifacts'), layout: button('配置', 'layout'), diagnostics: button('診断', 'diagnostics') };
  nav.append(...Object.values(tabs));
  const panes = { artifacts: make('section'), layout: make('section'), diagnostics: make('section') };
  for (const [key, pane] of Object.entries(panes)) { pane.setAttribute('aria-label', tabs[key as keyof typeof tabs].textContent!); pane.dataset.pane = key; }
  const state = field('state', '対象を確認できません'); state.setAttribute('role', 'status');
  const admission = field('admission', ''); admission.setAttribute('role', 'status');
  const target = field('target', '');
  const pick = button('ファイルを選ぶ', 'pick'), refresh = button('成果物を再確認', 'list');
  const registered = make('div'), candidates = make('div'); registered.setAttribute('aria-label', '登録済みの成果物'); candidates.setAttribute('aria-label', 'Gitの候補');
  const candidateNotice = make('p'); candidateNotice.dataset.field = 'git-candidates-error';
  const artifactButtons = new Map<string, HTMLButtonElement>(), candidateButtons = new Map<string, HTMLButtonElement>();
  const read = button('本文を読む', 'read'), diff = button('差分を読む', 'diff');
  const contentState = field('content-state', '本文は未確認'); contentState.setAttribute('role', 'status');
  const body = make('pre'); body.dataset.field = 'body'; body.setAttribute('aria-label', '成果物の内容');
  panes.artifacts.append(pick, refresh, registered, candidates, target, read, diff, contentState, body);
  const restore = button('配置だけを復元', 'restore');
  const restoreState = field('restore-state', '配置の復元は未確認'); restoreState.setAttribute('role', 'status');
  panes.layout.append(restore, restoreState);
  const diagnose = button('診断を確認', 'diagnostics-get'), copy = button('診断をコピー', 'copy');
  const diagnosticState = field('diagnostics-state', '診断は未確認'); diagnosticState.setAttribute('role', 'status');
  const diagnosticBody = make('pre'); diagnosticBody.dataset.field = 'diagnostics'; diagnosticBody.setAttribute('aria-label', '共有可能な診断');
  panes.diagnostics.append(diagnose, copy, diagnosticState, diagnosticBody);
  root.append(style, heading, close, nav, state, admission, ...Object.values(panes)); container.append(root);
  const capture = (kind: DetailsIntent['kind']): DetailsTarget | null => {
    if (!confirmed) return null;
    const base = { instanceId: current.instanceId, generation: current.generation };
    if (kind === 'restore' || kind === 'diagnostics') return { ...base, projectId: null, artifactId: null };
    return current.project ? { ...base, projectId: current.project.project_id, artifactId: current.selectedArtifactId } : null;
  };
  const selected = () => current.artifacts?.registered.find(a => a.artifact_id === current.selectedArtifactId) ?? null;
  const hostEnabled = () => !disposed && !closed && confirmed && !session.isRetired() && !session.isTransportBlocked() && current.availability === 'available';
  const projectEnabled = () => hostEnabled() && current.project?.root_state === 'verified' && nonempty(current.project.path);
  const sync = () => {
    const host = hostEnabled(), project = projectEnabled(), restoring = session.restoring();
    pick.disabled = !project || session.mutationPending();
    restore.disabled = !host || session.mutationPending();
    refresh.disabled = !project || session.readPending() || restoring;
    diagnose.disabled = !host || session.readPending() || restoring;
    read.disabled = diff.disabled = !project || !selected() || session.readPending() || restoring;
    for (const node of candidates.querySelectorAll<HTMLButtonElement>('button')) node.disabled = !project || session.mutationPending();
    for (const node of registered.querySelectorAll<HTMLButtonElement>('button')) node.disabled = !project;
    copy.disabled = !host || projectionText === null || copying || restoring;
    admission.textContent = session.isRetired() ? 'このホストは終了しています。' : session.isTransportBlocked()
      ? '接続状態が不明で復旧操作を受け付けられません。元操作の完了は未確認です。' : session.mutationPending()
      ? (session.mutationPhase() === 'unknown' ? '登録・復元の完了を確認できません。再操作は元の要求の確認後にできます。' : '登録・復元を確認中です。') : session.readPending() ? '結果を確認中です。' : '';
  };
  const clearRead = () => {
    body.textContent = ''; contentState.textContent = '本文は未確認';
    projectionText = null; diagnosticBody.textContent = ''; diagnosticState.textContent = '診断は未確認'; copyEpoch++; copying = false;
  };
  const clear = () => { clearRead(); restoreState.textContent = '配置の復元は未確認'; };
  const unsubscribe = session.subscribe(() => { if (!disposed && !closed) refreshSelection(); });
  const showPane = (key: typeof active) => {
    const prior = doc.activeElement;
    active = key;
    for (const [name, pane] of Object.entries(panes)) pane.hidden = name !== active;
    for (const [name, tab] of Object.entries(tabs)) tab.setAttribute('aria-pressed', String(name === active));
    if (prior instanceof HTMLElement && root.contains(prior) && prior.closest('[hidden]')) tabs[active].focus();
  };
  for (const [key, tab] of Object.entries(tabs)) tab.addEventListener('click', () => showPane(key as typeof active));
  const submit = (intent: DetailsIntent) => {
    if (intent.kind === 'restore' || intent.kind === 'diagnostics' ? !hostEnabled() : !projectEnabled()) return;
    const ticket = session.begin(intent, owner, mutation(intent)
      ? (reservedTicket, frozenIntent) => callbacks.reserveMutation(frozenIntent as Extract<DetailsIntent, {kind: 'register' | 'restore'}>, reservedTicket)
      : undefined);
    if (ticket === null) return;
    const pending = session.requestStillPending(owner, ticket, intent);
    if (!pending && mutation(intent)) commit({ ticket, intent, result: { kind: 'error', code: 'runtime_failed' } });
    if (pending && session.mayProject(owner, ticket, intent) && hostEnabled()) {
      if (!mutation(intent)) { body.textContent = ''; contentState.textContent = '本文を確認中'; projectionText = null; diagnosticBody.textContent = ''; diagnosticState.textContent = '診断は未確認'; copyEpoch++; }
      if (intent.kind === 'restore') restoreState.textContent = '復元を確認中';
    }
    sync();
    if (!pending || !session.requestStillPending(owner, ticket, intent)) return;
    try { Promise.resolve(callbacks.submit(Object.freeze(structuredClone(intent)), ticket)).catch(() => session.markUnknown(ticket)); }
    catch { session.markUnknown(ticket); }
  };
  const issue = (kind: 'list' | 'restore' | 'diagnostics' | 'read' | 'diff') => {
    const scope = capture(kind); if (!scope) return;
    if (kind === 'read' || kind === 'diff') { if (!selected()) return; submit({ ...scope, kind, maxBytes: current.maxBytes }); }
    else submit({ ...scope, kind });
  };
  pick.addEventListener('click', () => { const scope = capture('register'); if (scope) submit({ ...scope, kind: 'register', source: 'picker', relativePath: null }); });
  refresh.addEventListener('click', () => issue('list')); read.addEventListener('click', () => issue('read')); diff.addEventListener('click', () => issue('diff'));
  restore.addEventListener('click', () => issue('restore')); diagnose.addEventListener('click', () => issue('diagnostics'));
  copy.addEventListener('click', () => {
    if (!hostEnabled() || projectionText === null || copying) return;
    const text = projectionText, epoch = ++copyEpoch; copying = true; copy.disabled = true;
    try { Promise.resolve(callbacks.copy(text)).then(confirmedCopy => {
      if (disposed || epoch !== copyEpoch || text !== projectionText) return;
      copying = false; diagnosticState.textContent = confirmedCopy === true ? '診断をコピーしました' : 'コピーを確認できません'; sync();
    }, () => { if (!disposed && epoch === copyEpoch) { copying = false; diagnosticState.textContent = 'コピーを確認できません'; sync(); } }); }
    catch { copying = false; diagnosticState.textContent = 'コピーを確認できません'; sync(); }
  });
  close.addEventListener('click', () => {
    const scope = capture('list');
    const returnToOrigin = scope && sameTarget(scope, openingTarget) && hostEnabled() && origin?.isConnected && origin.getClientRects().length > 0
      && !origin.closest('[hidden],[aria-hidden="true"]') && !origin.matches(':disabled') && origin.tabIndex >= 0;
    closed = true; session.retireProjection(owner); clear();
    if (returnToOrigin) origin!.focus(); else close.focus();
    for (const pane of Object.values(panes)) pane.hidden = true;
    nav.hidden = true; sync();
  });
  const paintList = (preserveFocus = true) => {
    const priorFocus = doc.activeElement;
    const retire = (map: Map<string, HTMLButtonElement>, keep: Set<string>) => {
      for (const [id, node] of map) if (!keep.has(id)) { if (doc.activeElement === node) close.focus(); node.remove(); map.delete(id); }
    };
    const reason = confirmed ? gitCandidateReason(current.artifacts?.git_candidates_error) : null;
    retire(artifactButtons, new Set(confirmed ? current.artifacts?.registered.map(a => a.artifact_id) : []));
    retire(candidateButtons, new Set(confirmed && !reason ? current.artifacts?.git_candidates : []));
    if (!confirmed || !current.artifacts) { candidateNotice.remove(); return; }
    for (const [index, artifact] of current.artifacts.registered.entries()) {
      let select = artifactButtons.get(artifact.artifact_id);
      if (!select) {
        const artifactId = artifact.artifact_id;
        select = button(artifact.relative_path, 'select-artifact'); select.dataset.artifactId = artifactId;
        select.addEventListener('click', () => {
          if (!projectEnabled() || !current.artifacts?.registered.some(a => a.artifact_id === artifactId)) return;
          if (session.selectArtifact(artifactId)) notifySelection();
        }); artifactButtons.set(artifactId, select);
      }
      select.textContent = artifact.relative_path;
      select.setAttribute('aria-pressed', String(artifact.artifact_id === current.selectedArtifactId));
      if (registered.children[index] !== select) registered.insertBefore(select, registered.children[index] ?? null);
    }
    if (reason) {
      candidateNotice.textContent = reason;
      if (candidateNotice.parentElement !== candidates) candidates.append(candidateNotice);
    } else {
      candidateNotice.remove();
      for (const [index, path] of current.artifacts.git_candidates.entries()) {
        let candidate = candidateButtons.get(path);
        if (!candidate) {
          candidate = button(`登録: ${path}`, 'register-git');
          candidate.addEventListener('click', () => { const scope = capture('register'); if (scope && current.artifacts?.git_candidates.includes(path)) submit({ ...scope, kind: 'register', source: 'git', relativePath: path }); });
          candidateButtons.set(path, candidate);
        }
        if (candidates.children[index] !== candidate) candidates.insertBefore(candidate, candidates.children[index] ?? null);
      }
    }
    if (preserveFocus && priorFocus instanceof HTMLButtonElement && priorFocus.isConnected && root.contains(priorFocus)
      && !priorFocus.closest('[hidden]') && (artifactButtons.has(priorFocus.dataset.artifactId ?? '') || [...candidateButtons.values()].includes(priorFocus))) priorFocus.focus();
  };
  const describe = () => {
    state.textContent = !confirmed ? '対象を確認できません' : current.availability !== 'available' ? '接続状態を確認できません'
      : !current.project ? 'プロジェクトを選択してください' : current.project.root_state !== 'verified' ? 'プロジェクトの場所を確認できません' : '選択した対象を表示しています';
    const artifact = selected(); target.textContent = artifact ? `${artifact.relative_path}${artifact.association === 'caller_selected' ? `\n利用者が選択したrunとの関連: ${artifact.run_id}（実行成功の証拠ではありません）` : ''}` : '成果物を選択してください';
  };
  const commit = (projection: DetailsProjection): boolean => {
    const intent = projection.intent;
    if (intent.kind === 'restore' || intent.kind === 'diagnostics' ? !hostEnabled() : !projectEnabled()) return false;
    const scope = capture(intent.kind);
    if (!scope || !sameTarget(scope, intent)) return false;
    let result: DetailsResult;
    try { result = structuredClone(projection.result); } catch { return false; }
    if (!result || typeof result !== 'object' || !('kind' in result)) return false;
    if (intent.kind === 'list' && result.kind === 'list') {
      if (!session.finishList(owner, projection.ticket, intent, result.data)) return false;
      if (!disposed && !closed) sync(); return true;
    }
    if (result.kind === 'error' && !validError(result.code) || result.kind === 'unconfirmed' && !nonempty(result.message)) return false;
    if ((intent.kind === 'read' || intent.kind === 'diff') && result.kind === intent.kind) {
      const data = result.data;
      if (data.artifact_id !== intent.artifactId || (data.kind !== 'text' && data.kind !== 'binary') || typeof data.truncated !== 'boolean'
        || (data.kind === 'text' ? typeof data.text !== 'string' : data.text !== null || data.truncated !== false)
        || (result.kind === 'read' && !validNumber(result.data.size_bytes))) return false;
    }
    if (intent.kind === 'register' && result.kind === 'register' && (scope.projectId === null || !validArtifact(result.artifact, scope.projectId))) return false;
    if (intent.kind === 'restore' && result.kind === 'restore' && !(result.data.restored === true && validNumber(result.data.generation)
      && result.observedInstanceId === scope.instanceId && result.observedGeneration === result.data.generation
      && Array.isArray(result.projects) && Array.isArray(result.panes)
      && result.projects.every(p => validId(p.project_id) && ['verified', 'changed', 'unavailable', 'unknown'].includes(p.root_state))
      && new Set(result.projects.map(p => p.project_id)).size === result.projects.length
      && result.panes.every(p => validId(p.pane_id) && result.projects.some(project => project.project_id === p.project_id) && p.current_run_id === null && p.observation === null)
      && new Set(result.panes.map(p => p.pane_id)).size === result.panes.length)) return false;
    let receipt: Receipt | null = null;
    if (mutation(intent)) {
      receipt = session.consumeMutationReceipt(owner, projection.ticket, intent); if (!receipt) return false;
    }
    else if (!session.finishRead(owner, projection.ticket, intent)) return false;
    const currentScope = capture(intent.kind);
    if (!hostEnabled() || !session.mayProject(owner, projection.ticket, intent) || !currentScope || !sameTarget(currentScope, intent)) return false;
    let paint: (() => void) | null = null;
    if (result.kind === 'unconfirmed' && (receipt?.outcome === 'succeeded' || receipt?.outcome === 'cancelled' || !receipt)) {
      const message = receipt?.outcome === 'cancelled' ? 'ファイル選択を取り消しました。' : result.message;
      paint = () => { if (intent.kind === 'restore') restoreState.textContent = message;
        else if (intent.kind === 'diagnostics') diagnosticState.textContent = message;
        else contentState.textContent = message; };
    } else if (result.kind === 'error' && (!receipt || receipt.outcome === 'failed' && receipt.code === result.code)) {
      const message = errorText[result.code] ?? '結果を確認できません。対象を再確認してください。';
      paint = () => { if (intent.kind === 'restore') restoreState.textContent = message;
        else if (intent.kind === 'diagnostics') diagnosticState.textContent = message;
        else contentState.textContent = message; };
    } else if (receipt?.outcome === 'succeeded' && intent.kind === 'register' && result.kind === 'register'
      && receipt.expectedPath !== null && receipt.expectedPath === result.artifact.relative_path) {
      paint = () => { contentState.textContent = '登録を確認しました。成果物の一覧を再確認してください。'; };
    } else if (receipt?.outcome === 'succeeded' && intent.kind === 'restore' && result.kind === 'restore') {
      paint = () => { restoreState.textContent = '配置のみ復元・未起動'; };
    } else if (!receipt && (intent.kind === 'read' || intent.kind === 'diff') && result.kind === intent.kind) {
      paint = () => { body.textContent = result.data.kind === 'text' ? result.data.text : '';
        contentState.textContent = result.data.kind === 'binary' ? 'バイナリです。本文は表示しません。'
          : result.data.truncated ? '大容量のため一部を表示しています。'
          : intent.kind === 'diff' ? '差分を表示しています。' : '本文を表示しています。'; };
    } else if (!receipt && intent.kind === 'diagnostics' && result.kind === 'diagnostics') {
      const safe = diagnosticProjection(result.data);
      paint = () => { projectionText = safe; diagnosticBody.textContent = safe ?? '';
        diagnosticState.textContent = safe === null ? '診断を確認できません' : '共有可能な五項目だけを表示しています'; };
    }
    if (!paint) return false;
    clear(); paint();
    sync(); return true;
  };
  const refreshSelection = () => {
    const state = session.selectionState(), changed = state.epoch !== presentationEpoch, inventoryChanged = state.inventoryEpoch !== presentationInventoryEpoch;
    if (state.snapshot) current = state.snapshot;
    confirmed = state.confirmed; presentationEpoch = state.epoch; presentationInventoryEpoch = state.inventoryEpoch;
    if (changed) clear();
    else if (inventoryChanged) clearRead();
    paintList(!changed); describe(); sync();
  };
  const notifySelection = () => {
    const target = capture('list'); if (!target) return;
    try { Promise.resolve(callbacks.selectionChanged(Object.freeze(structuredClone(target)))).catch(() => {}); }
    catch { /* The session already owns the selection; notification is auxiliary. */ }
  };
  const update = (snapshot: DetailsSnapshot): boolean => {
    if (disposed || closed) return false;
    const result = session.observeSelection(snapshot); refreshSelection();
    if (!result.accepted) return false;
    if (result.selectionChanged) notifySelection();
    if (snapshot.projection) commit(snapshot.projection);
    return true;
  };
  update(initial); refreshSelection(); showPane(active);
  return {
    update, commitProjection: commit,
    dispose() { if (disposed) return; disposed = true; unsubscribe(); session.retireProjection(owner); clear(); root.remove(); },
  };
}
