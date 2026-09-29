import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(app, 'package.json'));
const { build } = require('esbuild');
const bundle = await build({ entryPoints: [resolve(app, 'src/workspace-ui/connection-controller.ts')], bundle: true, write: false,
  format: 'esm', platform: 'node', target: 'es2020', logLevel: 'silent' });
const { createConnectionController } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].contents).toString('base64')}`);
const I = '11111111-1111-4111-8111-111111111111';
const C = '22222222-2222-4222-8222-222222222222';
const P = '33333333-3333-4333-8333-333333333333';
const Q = '44444444-4444-4444-8444-444444444444';
const assert = (condition, message) => { if (!condition) throw new Error(message); };
let cases = 0;
function scenario({ state = 'pending', lose = null, history = 'completed', readFail = false, malformedReply = false,
  holdMutation = false, holdList = false, sibling = false } = {}) {
  let ordinal = 0; const calls = []; const released = []; let uncertain = 0;
  let losses = lose ? 1 : 0; let mutationSeen = false;
  let pendingMutation = null; let pendingList = null; let heldList = holdList; let listFailOnce = false;
  let row = { connection_id: C, executable_name: 'claimed.exe', requested_project_ids: [P, Q], requested_scopes: ['metadata', 'control'],
    granted_project_ids: state === 'granted' ? [P] : [], granted_scopes: state === 'granted' ? ['metadata'] : [], state };
  const siblingRow = { connection_id: '77777777-7777-4777-8777-777777777777', executable_name: 'other.exe',
    requested_project_ids: [Q], requested_scopes: ['metadata'], granted_project_ids: [Q], granted_scopes: ['metadata'], state: 'granted' };
  const reply = (request, data) => ({ schema_version: 1, instance_id: I, operation_id: request.operation_id, accepted: true,
    topology_revision: 1, event_seq: 1, result: { operation: request.operation, data }, error: null });
  const ownerKey = { instanceId: I, ownerGeneration: '1' };
  const port = { ownerKey, recover(origin, request) {
    assert(origin.instanceId === ownerKey.instanceId && origin.ownerGeneration === ownerKey.ownerGeneration, 'recovery owner is fixed');
    return port.exchange(request);
  }, async exchange(request) {
    calls.push(structuredClone(request));
    if (request.operation === 'connection.list') {
      if (readFail === true || readFail === 'after' && mutationSeen) throw new Error('ipc_lost');
      if (listFailOnce) { listFailOnce = false; throw new Error('list_reply_lost'); }
      if (heldList) { heldList = false; return new Promise((resolve, reject) => { pendingList = { resolve: rows => resolve(reply(request, { connections: rows })), reject }; }); }
      return reply(request, { connections: [row, ...(sibling ? [siblingRow] : [])].filter(Boolean) });
    }
    if (request.operation === 'operation.get') {
      if (readFail === true || readFail === 'after' && mutationSeen) throw new Error('ipc_lost');
      return reply(request, { operation: { operation_id: request.params.operation_id, phase: history,
        outcome: history === 'completed' ? 'succeeded' : null, error_code: null } });
    }
    if (request.operation === 'connection.decide') {
      mutationSeen = true;
      if (request.params.decision === 'allow') row = { ...row, state: 'granted', granted_project_ids: request.params.project_ids, granted_scopes: request.params.scopes };
      else row = { ...row, state: 'closing', granted_project_ids: [], granted_scopes: [] };
      if (losses-- > 0) throw lose === 'host' ? 'transport_uncertain' : new Error('webview_reply_lost');
      if (holdMutation) return new Promise((resolve, reject) => { pendingMutation = { resolve: () => resolve(reply(request, { connection_id: C, state: request.params.decision === 'allow' ? 'granted' : 'revoked',
        project_ids: request.params.project_ids, scopes: request.params.scopes })), reject }; });
      return reply(request, { connection_id: C, state: malformedReply ? 'revoked' : request.params.decision === 'allow' ? 'granted' : 'revoked',
        project_ids: request.params.project_ids, scopes: request.params.scopes });
    }
    if (request.operation === 'connection.revoke') {
      mutationSeen = true;
      row = { ...row, state: 'closing', granted_project_ids: [], granted_scopes: [] };
      if (losses-- > 0) throw lose === 'host' ? 'transport_uncertain' : new Error('webview_reply_lost');
      if (holdMutation) return new Promise((resolve, reject) => { pendingMutation = { resolve: () => resolve(reply(request, { connection_id: C, state: 'revoked' })), reject }; });
      return reply(request, { connection_id: C, state: 'revoked' });
    }
    throw new Error('unexpected operation');
  }, reserve(ticket) { return { ticket, kind: 'connection', host: I }; }, release(lease) { released.push(lease.ticket); }, transportUncertain() { uncertain++; } };
  const allocate = () => `55555555-5555-4555-8555-${(++ordinal).toString(16).padStart(12, '0')}`;
  const controller = createConnectionController(I, port, allocate);
  return { controller, port, calls, released, get uncertain() { return uncertain; }, get row() { return row; }, set row(value) { row = value; },
    get siblingRow() { return siblingRow; }, get pendingMutation() { return pendingMutation; }, get pendingList() { return pendingList; },
    set readFail(value) { readFail = value; }, set history(value) { history = value; }, holdNextList() { heldList = true; },
    failNextList() { listFailOnce = true; } };
}
{
  const fixture = scenario(); await fixture.controller.refresh(); fixture.controller.select(C);
  assert(!await fixture.controller.decide('allow', C, [P, '66666666-6666-4666-8666-666666666666'], ['metadata']), 'overgrant rejected before mutation');
  assert(await fixture.controller.decide('allow', C, [P], ['metadata']), 'partial allow accepted');
  assert(fixture.controller.snapshot().message.includes('現在の許可も一致'), 'current grant separately verified');
  assert(fixture.calls.filter(row => row.operation === 'connection.decide').length === 1, 'one mutation');
  assert(fixture.released.length === 1, 'lease released after current list'); cases++;
}
{
  const fixture = scenario({ lose: 'webview' }); await fixture.controller.refresh();
  await fixture.controller.decide('allow', C, [P], ['metadata']);
  const mutation = fixture.calls.find(row => row.operation === 'connection.decide');
  const recovery = fixture.calls.find(row => row.operation === 'operation.get');
  assert(recovery?.params.operation_id === mutation?.operation_id && recovery.operation_id !== mutation.operation_id, 'original ID read with separate ID');
  assert(fixture.calls.filter(row => row.operation === 'connection.decide').length === 1, 'lost reply never resent');
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.released.length === 1, 'terminal status settles lease'); cases++;
}
{
  for (const action of ['deny', 'revoke']) {
    const fixture = scenario({ state: action === 'revoke' ? 'granted' : 'pending', lose: 'webview' }); await fixture.controller.refresh();
    await fixture.controller.decide(action, C);
    assert(fixture.calls.filter(row => ['connection.decide', 'connection.revoke'].includes(row.operation)).length === 1, `${action} lost reply never resends`);
    assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.row.state === 'closing', `${action} recovery sees current closing`);
    assert(fixture.controller.snapshot().message.includes('client の終了'), `${action} does not claim reader drain`); cases++;
  }
}
{
  for (const action of ['allow', 'deny', 'revoke']) {
    const fixture = scenario({ state: action === 'revoke' ? 'granted' : 'pending', lose: 'host' }); await fixture.controller.refresh();
    await fixture.controller.decide(action, C, action === 'allow' ? [P] : [], action === 'allow' ? ['metadata'] : []);
    assert(fixture.uncertain === 1 && fixture.controller.snapshot().blocked, `${action} host response loss blocks`);
    assert(!fixture.calls.some(row => row.operation === 'operation.get') && fixture.released.length === 0, `${action} Unknown has no recovery mutation`);
    cases++;
  }
}
{
  const fixture = scenario({ lose: 'webview', history: 'unknown' }); await fixture.controller.refresh();
  await fixture.controller.decide('allow', C, [P], ['metadata']);
  assert(fixture.controller.snapshot().original?.phase === 'unknown', 'history miss retained');
  const firstId = fixture.controller.snapshot().original.id;
  assert(!await fixture.controller.decide('allow', C, [P], ['metadata']), 'unknown history blocks allow');
  assert(await fixture.controller.decide('revoke', C), 'new explicit revoke can remove current grant');
  assert(fixture.controller.snapshot().priorUnknown.some(row => row.id === firstId && row.phase === 'unknown'), 'first unknown ID survives new explicit revoke');
  assert(fixture.controller.snapshot().message.includes('client の終了'), 'closing does not claim drain'); cases++;
}
{
  const fixture = scenario({ lose: 'webview', readFail: true });
  await fixture.controller.refresh();
  assert(fixture.controller.snapshot().connections === null, 'read IPC failure has no current grant'); cases++;
}
{
  const fixture = scenario({ readFail: 'after' }); await fixture.controller.refresh();
  await fixture.controller.decide('allow', C, [P], ['metadata']);
  assert(fixture.controller.snapshot().connections === null && fixture.released.length === 0, 'read loss cannot assert current grant or release mutation lease');
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.controller.snapshot().original?.outcome === 'succeeded', 'known original reply survives current-list read loss');
  fixture.readFail = false; await fixture.controller.refresh();
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.released.length === 1, 'current-list reread settles known original response and lease'); cases++;
}
{
  const fixture = scenario({ malformedReply: true }); await fixture.controller.refresh();
  await fixture.controller.decide('allow', C, [P], ['metadata']);
  assert(fixture.calls.filter(row => row.operation === 'connection.decide').length === 1, 'malformed reply does not resend mutation');
  assert(fixture.calls.some(row => row.operation === 'operation.get'), 'malformed reply triggers original ID reread');
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.released.length === 1, 'history and list settle malformed reply'); cases++;
}
{
  const fixture = scenario({ state: 'closing' }); await fixture.controller.refresh();
  assert(!await fixture.controller.decide('deny', C), 'closing target cannot be decided');
  assert(!await fixture.controller.decide('revoke', C), 'closing target cannot be revoked'); cases++;
}
{
  const fixture = scenario(); fixture.row.granted_project_ids = [P];
  await fixture.controller.refresh();
  assert(fixture.controller.snapshot().connections === null, 'malformed pending grant fails closed'); cases++;
}
// One state machine protects the original ID, recovery reads, the mutation lease,
// and the latest list for all three mutation entry points.
const pendingDecisionTable = [
  { action: 'allow', state: 'pending', projectIds: [P], scopes: ['metadata'], current: 'granted' },
  { action: 'deny', state: 'pending', projectIds: [], scopes: [], current: 'closing' },
  { action: 'revoke', state: 'granted', projectIds: [], scopes: [], current: 'closing' },
];
for (const entry of pendingDecisionTable) {
  for (const late of ['reply', 'exception', 'transport_unknown']) {
    const fixture = scenario({ state: entry.state, holdMutation: true }); await fixture.controller.refresh();
    const mutation = fixture.controller.decide(entry.action, C, entry.projectIds, entry.scopes);
    const original = fixture.controller.snapshot().original;
    assert(original?.phase === 'unconfirmed' && fixture.released.length === 0 && fixture.controller.snapshot().mutationPending
      && !fixture.controller.snapshot().busy, `${entry.action} holds mutation lease without blocking recovery reads`);
    await fixture.controller.refresh();
    assert(fixture.controller.snapshot().connections?.[0].state === entry.current && fixture.released.length === 0,
      `${entry.action} reads current state without settling historical result`);
    assert(!await fixture.controller.decide(entry.action, C, entry.projectIds, entry.scopes), `${entry.action} prevents a second mutation`);
    await fixture.controller.recheck();
    const recovered = fixture.controller.snapshot();
    assert(recovered.original?.id === original.id && recovered.original.phase === 'completed', `${entry.action} recovers original ID before reply`);
    assert(recovered.connections?.[0].state === entry.current && fixture.released.length === 1, `${entry.action} releases once after separate list`);
    assert(fixture.calls.filter(row => row.operation === (entry.action === 'revoke' ? 'connection.revoke' : 'connection.decide')).length === 1,
      `${entry.action} original mutation is never resent`);
    const lookup = fixture.calls.find(row => row.operation === 'operation.get');
    assert(lookup?.params.operation_id === original.id && lookup.operation_id !== original.id, `${entry.action} reads history with a different ID`);
    const stable = JSON.stringify(recovered);
    if (late === 'reply') fixture.pendingMutation.resolve();
    else fixture.pendingMutation.reject(late === 'transport_unknown' ? 'transport_uncertain' : new Error('late_webview_error'));
    await mutation;
    assert(JSON.stringify(fixture.controller.snapshot()) === stable && fixture.released.length === 1 && fixture.uncertain === 0,
      `${entry.action} late ${late} cannot overwrite recovered state`);
    cases++;
  }
}
{
  const fixture = scenario({ holdMutation: true, readFail: false }); await fixture.controller.refresh();
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  fixture.readFail = true; await fixture.controller.recheck();
  assert(fixture.controller.snapshot().connections === null && fixture.released.length === 0,
    'failed recovery read does not assert current grant or release lease');
  fixture.readFail = false; await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.released.length === 1,
    'manual read resumes while original promise remains pending');
  fixture.pendingMutation.resolve(); await mutation; cases++;
}
{
  const fixture = scenario({ holdMutation: true, history: 'accepted' }); await fixture.controller.refresh();
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === 'accepted' && fixture.released.length === 0,
    'accepted history retains original lease and permits later reread');
  fixture.history = 'in_progress'; await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === 'in_progress' && fixture.released.length === 0,
    'in-progress history remains unsettled');
  fixture.history = 'completed'; await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === 'completed' && fixture.released.length === 1,
    'terminal history plus list releases once');
  fixture.pendingMutation.resolve(); await mutation; cases++;
}
{
  const fixture = scenario({ holdMutation: true, history: 'unknown' }); await fixture.controller.refresh();
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === 'unknown' && fixture.released.length === 1,
    'unknown history and current list remain separate');
  assert(!await fixture.controller.decide('allow', C, [P], ['metadata']), 'unknown history forbids another allow');
  const old = fixture.pendingMutation; const revoke = fixture.controller.decide('revoke', C);
  assert(fixture.controller.snapshot().original?.action === 'revoke' && fixture.controller.snapshot().priorUnknown.length === 1,
    'unknown history permits only a new explicit revoke and keeps the original ID');
  old.resolve(); await mutation; await fixture.controller.recheck(); fixture.pendingMutation.resolve(); await revoke; cases++;
}
for (const history of ['completed', 'unknown']) {
  const fixture = scenario({ holdMutation: true, history }); await fixture.controller.refresh();
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  fixture.failNextList(); await fixture.controller.recheck();
  assert(fixture.controller.snapshot().original?.phase === history && fixture.controller.snapshot().connections === null
    && fixture.released.length === 0, `${history} history survives lost current-list reply without releasing lease`);
  await fixture.controller.refresh();
  assert(fixture.controller.snapshot().connections?.[0].state === 'granted' && fixture.released.length === 1,
    `${history} manual list reread releases once after current state is known`);
  fixture.pendingMutation.resolve(); await mutation; cases++;
}
{
  const fixture = scenario({ holdMutation: true }); await fixture.controller.refresh();
  const first = fixture.controller.decide('allow', C, [P], ['metadata']); const old = fixture.pendingMutation;
  fixture.controller.bind({ ...fixture.port }); await fixture.controller.recheck();
  assert(fixture.released.length === 1, 'same-host rebind recovers old original');
  const second = fixture.controller.decide('revoke', C); const newId = fixture.controller.snapshot().original?.id;
  assert(newId && newId !== fixture.calls.find(row => row.operation === 'connection.decide')?.operation_id,
    'new explicit operation owns a new ID after recovery');
  old.resolve(); await first;
  assert(fixture.controller.snapshot().original?.id === newId && fixture.controller.snapshot().original?.phase === 'unconfirmed',
    'old response cannot overwrite a newer mutation');
  await fixture.controller.recheck(); fixture.pendingMutation.resolve(); await second;
  assert(fixture.controller.snapshot().original?.id === newId && fixture.released.length === 2, 'new operation settles independently'); cases++;
}
{
  const fixture = scenario({ state: 'granted' }); await fixture.controller.refresh();
  fixture.holdNextList(); const oldRead = fixture.controller.refresh();
  assert(fixture.pendingList !== null, 'old list is held');
  fixture.controller.bind({ ...fixture.port }); fixture.row = { ...fixture.row, state: 'finished', granted_project_ids: [], granted_scopes: [] };
  await fixture.controller.refresh();
  fixture.pendingList.resolve([{ ...fixture.siblingRow }]); await oldRead;
  assert(fixture.controller.snapshot().connections?.[0].state === 'finished', 'old binding list cannot overwrite new binding'); cases++;
}
{
  const fixture = scenario({ state: 'granted' }); await fixture.controller.refresh();
  fixture.holdNextList(); const oldRead = fixture.controller.refresh();
  fixture.controller.bind({ ...fixture.port }); await fixture.controller.refresh();
  fixture.pendingList.reject('transport_uncertain'); await oldRead;
  assert(!fixture.controller.snapshot().blocked && fixture.uncertain === 0 && fixture.controller.snapshot().connections?.[0].state === 'granted',
    'old binding read failure cannot block or erase the new binding observation'); cases++;
}
{
  const fixture = scenario({ holdMutation: true }); await fixture.controller.refresh();
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  fixture.controller.retire(); fixture.pendingMutation.resolve(); await mutation;
  assert(fixture.controller.snapshot().connections === null && fixture.controller.snapshot().original?.phase === 'unconfirmed',
    'retired generation ignores late mutation response'); cases++;
}
{
  const fixture = scenario({ sibling: true }); await fixture.controller.refresh();
  const observations = []; fixture.controller.observe(value => observations.push(value));
  await fixture.controller.decide('allow', C, [P], ['metadata']);
  assert(fixture.controller.snapshot().message.includes('現在の許可も一致'), 'allow grant initially matches');
  fixture.row = { ...fixture.row, state: 'finished', granted_project_ids: [], granted_scopes: [] };
  await fixture.controller.refresh();
  assert(!fixture.controller.snapshot().message.includes('現在の許可も一致') && fixture.controller.snapshot().original?.outcome === 'succeeded',
    'finished client removes current grant claim but preserves historical success');
  assert(observations.every(value => !value.connections?.some(row => row.connection_id === C && row.state === 'finished')
    || !value.message.includes('現在の許可も一致')), 'new list and derived current-grant sentence notify atomically');
  assert(fixture.controller.snapshot().connections?.find(row => row.connection_id === fixture.siblingRow.connection_id)?.state === 'granted',
    'sibling client remains granted');
  fixture.row = null; await fixture.controller.refresh();
  assert(!fixture.controller.snapshot().message.includes('現在の許可も一致') && fixture.controller.snapshot().original?.outcome === 'succeeded',
    'absent target cannot retain current grant claim'); cases++;
}
{
  const fixture = scenario({ holdMutation: true }); await fixture.controller.refresh();
  const before = structuredClone(fixture.row);
  const mutation = fixture.controller.decide('allow', C, [P], ['metadata']);
  fixture.holdNextList(); const oldRead = fixture.controller.refresh();
  fixture.pendingMutation.resolve();
  await Promise.resolve();
  fixture.pendingList.resolve([before]); await oldRead; await mutation;
  assert(fixture.controller.snapshot().connections?.[0].state === 'granted' && fixture.released.length === 1,
    'list started before terminal reply cannot settle or overwrite the later grant observation'); cases++;
}
{
  const fixture = scenario(); await fixture.controller.refresh(); fixture.holdNextList();
  const first = fixture.controller.refresh(); const count = fixture.calls.filter(row => row.operation === 'connection.list').length;
  await fixture.controller.refresh();
  assert(fixture.calls.filter(row => row.operation === 'connection.list').length === count, 'duplicate in-flight list read suppressed');
  fixture.pendingList.resolve([fixture.row]); await first; cases++;
}
{
  const fixture = scenario({ state: 'granted' }); await fixture.controller.refresh();
  const before = structuredClone(fixture.row); fixture.holdNextList();
  const first = fixture.controller.refresh();
  fixture.row = { ...fixture.row, state: 'finished', granted_project_ids: [], granted_scopes: [] };
  void fixture.controller.refresh();
  assert(fixture.calls.filter(row => row.operation === 'connection.list').length === 2, 'event refresh does not overlap an active list read');
  fixture.pendingList.resolve([before]); await first;
  await new Promise(resolve => setTimeout(resolve, 0));
  assert(fixture.calls.filter(row => row.operation === 'connection.list').length === 3
    && fixture.controller.snapshot().connections?.[0].state === 'finished', 'connection event during a read queues one fresh list'); cases++;
}
console.log(`workspace connection UI controller: ${cases} focused scenarios passed`);
