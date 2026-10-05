import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { publicationFixture, sha } from './publication-fixture.mjs';
import { assertPublicationPreparationAllowed, freezePublicationAttempt, readFrozenPublicationAttempt, verifyPublicationRecovery } from '../../scripts/integrated-publication-attempt.mjs';

assert.ok(process.argv[2], 'Canonical operator root required.');
const fixture = publicationFixture(path.resolve(process.argv[2]));
const { contract, bundle, root } = fixture;
const nativeOwner = { pid: 42, creation_filetime: '134350000000000001', job_name: `Local\\winsmux-integrated-publication-${randomUUID().replaceAll('-', '')}` };
nativeOwner.keeper = { pid: 43, creation_filetime: '134350000000000002', pipe_name: `winsmux-publication-keeper-${nativeOwner.job_name.slice(-32)}`,
  attempt: bundle.identity.attempt, candidate_manifest_sha256: bundle.identity.manifest_sha256,
  implementation_sha256: 'a'.repeat(64), script_sha256: 'b'.repeat(64) };
let checks = 0;
const check = action => { action(); checks++; };
const reject = (action, pattern) => check(() => assert.throws(action, pattern));
const observeOwner = () => structuredClone(nativeOwner);
const nativeActor = { pid: 41, creation_filetime: '134350000000000000' };
const observeActor = () => structuredClone(nativeActor);
const freezeAttempt = (candidate = bundle, observe = observeOwner, observeAuthority = observeActor) =>
  freezePublicationAttempt(contract, candidate, root, observe, observeAuthority);
check(() => assert.equal(assertPublicationPreparationAllowed(root, '0.38.0').publication_admitted, false));
reject(() => assertPublicationPreparationAllowed(root, '../0.38.0'), /Refrozen/);
reject(() => freezeAttempt(structuredClone(bundle)), /observed/);
reject(() => freezePublicationAttempt(contract, bundle, root, nativeOwner), /observer/);
for (const bad of [ { ...nativeOwner, pid: 0 }, { ...nativeOwner, creation_filetime: 123 },
  { ...nativeOwner, creation_filetime: '0' }, { ...nativeOwner, creation_filetime: '999999999999999999999' },
  { ...nativeOwner, job_name: 'Local\\other-job' }, { ...nativeOwner, approved: true } ])
  reject(() => freezeAttempt(bundle, () => bad), /identity/);
for (const change of [ keeper => { keeper.pid = nativeOwner.pid; }, keeper => { keeper.creation_filetime = '0'; },
  keeper => { keeper.pipe_name = 'another'; }, keeper => { keeper.attempt = randomUUID(); },
  keeper => { keeper.candidate_manifest_sha256 = '0'.repeat(64); }, keeper => { keeper.implementation_sha256 = null; },
  keeper => { keeper.script_sha256 = ''; }, keeper => { keeper.ready = true; } ]) {
  const bad = structuredClone(nativeOwner); change(bad.keeper);
  reject(() => freezeAttempt(bundle, () => bad), /identity/);
}
reject(() => freezePublicationAttempt(contract, bundle, root, observeOwner), /observers/);
for (const bad of [null, { ...nativeActor, pid: 0 }, { ...nativeActor, pid: 0x100000000 },
  { ...nativeActor, creation_filetime: 123 }, { ...nativeActor, creation_filetime: '0' },
  { ...nativeActor, creation_filetime: '999999999999999999999' }, { ...nativeActor, approved: true }])
  reject(() => freezeAttempt(bundle, observeOwner, () => bad), /actor identity/);
const snapshot = freezeAttempt();
const original = fs.readFileSync(snapshot.file);
check(() => { assert.equal(snapshot.publication_admitted, false); assert.equal(snapshot.original_sha256, sha(original)); });
reject(() => { snapshot.record.owner.pid = 99; }, TypeError);
reject(() => assertPublicationPreparationAllowed(root, '0.38.0'), /frozen/);
reject(() => freezeAttempt(), /frozen/);
reject(() => readFrozenPublicationAttempt(contract, bundle, root, '0'.repeat(64)), /SHA differs/);
const nativeIdle = () => ({ owner: structuredClone(nativeOwner), actor: structuredClone(nativeActor), actor_gone: true,
  owner_gone: true, roots_gone: true, job_found: true, active_members: 0,
  keeper_exit_code: 0, query_handoff_job_name: nativeOwner.job_name });
const publicMatching = () => bundle.assets.map(row => ({ path: row.path, state: 'matching', sha256: row.sha256 }));
const recover = (native = nativeIdle, pub = publicMatching, input = snapshot) => verifyPublicationRecovery(contract, bundle, input, native, pub);
reject(() => recover(nativeIdle, publicMatching, structuredClone(snapshot)), /snapshot/);
reject(() => recover(nativeIdle()), /observers/);
let publicQueries = 0;
for (const change of [ state => { state.actor_gone = false; }, state => { delete state.actor_gone; },
  state => { state.actor.pid++; }, state => { state.actor.creation_filetime = '134350000000000005'; },
  state => { state.actor.approved = true; }, state => { delete state.actor; },
  state => { state.owner_gone = false; }, state => { state.roots_gone = false; },
  state => { state.active_members = 1; }, state => { state.active_members = -1; },
  state => { state.owner.pid++; }, state => { state.pass = true; }, state => { delete state.job_found; }, state => { state.job_found = false; },
  state => { delete state.keeper_exit_code; }, state => { state.keeper_exit_code = 1; }, state => { state.query_handoff_job_name = 'another'; } ]) {
  const state = nativeIdle(); change(state);
  reject(() => recover(() => state, () => { publicQueries++; return publicMatching(); }), /idle/);
}
check(() => assert.equal(publicQueries, 0));
check(() => {
  const actual = recover(); assert.equal(actual.observed_matching, 13); assert.deepEqual(actual.missing_operations, []);
  assert.equal(actual.publication_admitted, false); assert.equal(actual.attempt_remains_frozen, true);
});
check(() => {
  const rows = publicMatching(); rows[0] = { path: rows[0].path, state: 'absent', sha256: null };
  const actual = recover(nativeIdle, () => rows); assert.equal(actual.observed_matching, 12); assert.deepEqual(actual.missing_operations, [rows[0].path]);
});
for (const change of [ rows => rows.pop(), rows => rows.push(rows[0]), rows => { rows[0] = rows[1]; },
  rows => { rows[0].state = 'unknown'; }, rows => { rows[0].state = 'different'; },
  rows => { rows[0].sha256 = '0'.repeat(64); }, rows => { rows[0].state = 'absent'; },
  rows => { rows[0].approved = true; } ]) {
  const rows = publicMatching(); change(rows);
  reject(() => recover(nativeIdle, () => rows), /public|Public/);
}
check(() => assert.deepEqual(fs.readFileSync(snapshot.file), original));
const mutation = record => {
  fs.writeFileSync(snapshot.file, JSON.stringify(record));
  reject(() => readFrozenPublicationAttempt(contract, bundle, root, sha(fs.readFileSync(snapshot.file))), /differs|identity/);
};
for (const change of [ record => { record.schema = 'winsmux-publication-in-flight/v1'; delete record.actor; },
  record => { record.actor.pid = 0; }, record => { record.actor.ready = true; },
  record => { record.state = 'completed'; }, record => { record.assets.pop(); },
  record => { record.candidate_identity.attempt = 'another'; }, record => { record.contract_controls_sha256 = '0'.repeat(64); },
  record => { record.owner_gone = true; } ]) { const record = JSON.parse(original); change(record); mutation(record); }
fs.writeFileSync(snapshot.file, '{"schema":"a","schema":"b"}');
reject(() => readFrozenPublicationAttempt(contract, bundle, root, sha(fs.readFileSync(snapshot.file))), /Duplicate/);
fs.writeFileSync(snapshot.file, original);
reject(() => recover(), /record changed/); // Original inode metadata changed even if bytes were restored.
reject(() => assertPublicationPreparationAllowed(root, '0.38.0'), /frozen/);
console.log(JSON.stringify({ passed: true, checks, publication_admitted: false,
  scope: 'Synthetic parent observers and fixed bundle. Real Windows owner death, original public API observations and actual dispatch are separate obligations.' }));
