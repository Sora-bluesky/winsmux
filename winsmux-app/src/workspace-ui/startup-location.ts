type SourceChange = { path: string; summary: string; paneLabel: string; worktree: string; status: 'modified' | 'added' | 'deleted' | 'renamed'; risk: 'low' | 'medium' | 'high'; branch: string; lines: string; commitCandidate: boolean; needsAttention: boolean; run: string; review: string; staged?: boolean };
export type PopoutPayload = Readonly<
  { mode: 'preview'; url: string; portLabel: string; sourceLabel: string; lastSeenAt: number; runId?: string; runLabel?: string } |
  { mode: 'editor'; path: string; worktree: string; summary: string; origin: 'explorer' | 'context'; modified: boolean; sourceChange?: SourceChange | null; content?: string; runId?: string; runLabel?: string }
>;
function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype; }
function keys(value: Record<string, unknown>, required: string[], optional: string[] = []) {
  return required.every(key => Object.prototype.hasOwnProperty.call(value, key)) && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}
function optionalText(value: Record<string, unknown>, key: string) { return !Object.prototype.hasOwnProperty.call(value, key) || typeof value[key] === 'string'; }
export function localPreviewUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  try { const url = new URL(value); return url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname) && url.username === '' && url.password === ''; } catch { return false; }
}
export function validatePopoutPayload(value: unknown): PopoutPayload | null {
  if (!record(value) || !optionalText(value, 'runId') || !optionalText(value, 'runLabel')) return null;
  if (value.mode === 'preview') {
    if (!keys(value, ['mode', 'url', 'portLabel', 'sourceLabel', 'lastSeenAt'], ['runId', 'runLabel']) || !localPreviewUrl(value.url) || typeof value.portLabel !== 'string' || typeof value.sourceLabel !== 'string' || typeof value.lastSeenAt !== 'number' || !Number.isFinite(value.lastSeenAt)) return null;
  } else if (value.mode === 'editor') {
    if (!keys(value, ['mode', 'path', 'worktree', 'summary', 'origin', 'modified'], ['sourceChange', 'content', 'runId', 'runLabel']) || typeof value.path !== 'string' || !value.path || typeof value.worktree !== 'string' || typeof value.summary !== 'string' || !['explorer', 'context'].includes(value.origin as string) || typeof value.modified !== 'boolean' || !optionalText(value, 'content')) return null;
    if (Object.prototype.hasOwnProperty.call(value, 'sourceChange') && value.sourceChange !== null) {
      const change = value.sourceChange;
      if (!record(change) || !keys(change, ['path', 'summary', 'paneLabel', 'worktree', 'status', 'risk', 'branch', 'lines', 'commitCandidate', 'needsAttention', 'run', 'review'], ['staged']) || !['path', 'summary', 'paneLabel', 'worktree', 'branch', 'lines', 'run', 'review'].every(key => typeof change[key] === 'string') || !['modified', 'added', 'deleted', 'renamed'].includes(change.status as string) || !['low', 'medium', 'high'].includes(change.risk as string) || typeof change.commitCandidate !== 'boolean' || typeof change.needsAttention !== 'boolean' || ('staged' in change && typeof change.staged !== 'boolean')) return null;
    }
  } else return null;
  const copy = structuredClone(value) as unknown as PopoutPayload;
  if (copy.mode === 'editor' && copy.sourceChange) Object.freeze(copy.sourceChange);
  return Object.freeze(copy);
}

export type StartupRoute = Readonly<{ kind: 'main' } | { kind: 'secondary'; payload: PopoutPayload } | { kind: 'closed' }>;
export function selectStartupRoute(native: boolean, label: string, search: string, storage: Pick<Storage, 'getItem' | 'removeItem'>): StartupRoute {
  const query = new URLSearchParams(search);
  if (!native) return Object.freeze({ kind: 'closed' });
  if (label === 'main' && [...query].length === 0) return Object.freeze({ kind: 'main' });
  if (!/^secondary-surface-[A-Za-z0-9-]+$/.test(label) || [...query].length !== 2 || query.getAll('popout').length !== 1 || query.get('popout') !== '1' || query.getAll('popout-key').length !== 1) return Object.freeze({ kind: 'closed' });
  const key = query.get('popout-key');
  if (!key?.startsWith('winsmux.popout-surface.')) return Object.freeze({ kind: 'closed' });
  try {
    const raw = storage.getItem(key);
    const payload = raw === null ? null : validatePopoutPayload(JSON.parse(raw));
    if (!payload) return Object.freeze({ kind: 'closed' });
    storage.removeItem(key);
    return Object.freeze({ kind: 'secondary', payload });
  } catch { return Object.freeze({ kind: 'closed' }); }
}

export function startupLocationAllowed(label: string, href: string): boolean {
  try {
    const url = new URL(href);
    const local = (url.protocol === 'tauri:' && url.hostname === 'localhost') || (['http:', 'https:'].includes(url.protocol) && url.hostname === 'tauri.localhost');
    if (!local || url.port !== '' || url.username !== '' || url.password !== '' || url.href.includes('#')) return false;
    if (label === 'main') return url.pathname === '/' && [...url.searchParams].length === 0;
    if (!/^secondary-surface-[A-Za-z0-9-]+$/.test(label) || !['/', '/index.html'].includes(url.pathname)) return false;
    const pairs = [...url.searchParams];
    return pairs.length === 2 && pairs.filter(([key, value]) => key === 'popout' && value === '1').length === 1
      && pairs.filter(([key, value]) => key === 'popout-key' && value.startsWith('winsmux.popout-surface.')).length === 1;
  } catch { return false; }
}
export type CreationSession = Readonly<{ instance_id: string; schema_version: 1 }>;
export type CreationMetadata = Readonly<{ request_id: string; label: string; key: string; session: CreationSession; generation: string; mode: PopoutPayload['mode'] }>;
export type ReadIntent = Readonly<{ project_dir: string; project_id: string; session: CreationSession; generation: string }>;
export const strictUuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
export function creationSession(v: unknown): v is CreationSession { return record(v) && keys(v, ['instance_id', 'schema_version']) && strictUuid(v.instance_id) && v.schema_version === 1; }
export function validateReadIntent(v: unknown): ReadIntent | null {
  return record(v) && keys(v, ['project_dir', 'project_id', 'session', 'generation']) && typeof v.project_dir === 'string' && v.project_dir.trim().length > 0 && strictUuid(v.project_id) && creationSession(v.session) && strictUuid(v.generation) ? Object.freeze(structuredClone(v)) as ReadIntent : null;
}
export function validateCreationMetadata(v: unknown, label: string, key: string, payload: PopoutPayload): CreationMetadata | null {
  return record(v) && keys(v, ['request_id', 'label', 'key', 'session', 'generation', 'mode']) && strictUuid(v.request_id) && v.label === label && v.key === key && label === 'secondary-surface-' + v.request_id && key === 'winsmux.popout-surface.' + v.request_id && creationSession(v.session) && strictUuid(v.generation) && v.mode === payload.mode ? Object.freeze(structuredClone(v)) as CreationMetadata : null;
}
export type SecondaryCapture = Readonly<{ metadata: CreationMetadata | null; intent: ReadIntent | null; current: () => boolean; dispose: () => void; report: (phase: 'ready' | 'failed' | 'closed') => void }>;
export function captureSecondaryRoute(native: boolean, label: string, href: string, storage: Storage, listen: (callback: (e: StorageEvent) => void) => () => void): Readonly<{ route: StartupRoute; capture: SecondaryCapture | null }> {
  const closedRoute = () => Object.freeze({ route: Object.freeze({ kind: 'closed' as const }), capture: null });
  if (!native || !startupLocationAllowed(label, href)) return closedRoute();
  if (label === 'main') return { route: selectStartupRoute(native, label, new URL(href).search, storage), capture: null };
  const key = new URL(href).searchParams.get('popout-key')!;
  let invalid = false, disposed = false;
  const release = listen(e => { if ((e.storageArea === null || e.storageArea === storage) && (e.key === null || [key, key + '.read-intent', key + '.creation-request'].includes(e.key))) invalid = true; });
  try {
    const raw = storage.getItem(key), payload = raw === null ? null : validatePopoutPayload(JSON.parse(raw));
    if (!payload) throw Error('closed');
    const metadataRaw = storage.getItem(key + '.creation-request');
    const metadata = metadataRaw === null ? null : validateCreationMetadata(JSON.parse(metadataRaw), label, key, payload);
    if ((metadataRaw !== null && metadata === null) || (metadata === null && strictUuid(key.slice('winsmux.popout-surface.'.length)))) throw Error('closed');
    let intent: ReadIntent | null = null, intentRaw: string | null = null;
    if (metadata && payload.mode === 'editor' && payload.content === undefined) {
      intentRaw = storage.getItem(key + '.read-intent'); intent = intentRaw === null ? null : validateReadIntent(JSON.parse(intentRaw));
      if (!intent || JSON.stringify(intent.session) !== JSON.stringify(metadata.session) || intent.generation !== metadata.generation) throw Error('closed');
    }
    if (invalid || storage.getItem(key) !== raw || storage.getItem(key + '.creation-request') !== metadataRaw || intentRaw !== null && storage.getItem(key + '.read-intent') !== intentRaw) throw Error('closed');
    const route = selectStartupRoute(native, label, new URL(href).search, storage);
    if (route.kind !== 'secondary') throw Error('closed');
    if (metadataRaw !== null) { if (invalid || storage.getItem(key + '.creation-request') !== metadataRaw) throw Error('closed'); storage.removeItem(key + '.creation-request'); }
    if (intentRaw !== null) { if (invalid || storage.getItem(key + '.read-intent') !== intentRaw) throw Error('closed'); storage.removeItem(key + '.read-intent'); }
    const current = () => { try { return !disposed && !invalid && storage.getItem(key) === null && (metadata === null || storage.getItem(key + '.creation-request') === null && storage.getItem(key + '.read-intent') === null); } catch { return false; } };
    const phases = new Set<string>();
    return { route, capture: Object.freeze({ metadata, intent, current, dispose() { disposed = true; release(); }, report(phase) {
      if (!metadata || phases.has(phase)) return; phases.add(phase);
      const value = JSON.stringify({ request_id: metadata.request_id, label, key, session: metadata.session, generation: metadata.generation, phase });
      try { storage.setItem(key + '.creation-outcome', value); if (storage.getItem(key + '.creation-outcome') === value) storage.removeItem(key + '.creation-outcome'); } catch { /* Missing notification remains unconfirmed in the request owner. */ }
    } }) };
  } catch { release(); return closedRoute(); }
}
