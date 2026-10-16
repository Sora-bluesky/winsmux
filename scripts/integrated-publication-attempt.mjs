import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';

// Parent-owned persistence, not a permission store. Once an effect is possible,
// all managed preparation paths retain this marker, even for failure/unknown.
// Recovery observes native owner/roots/Job and actual public bytes. It never
// clears the freeze or authorizes publication. There is no JSON/CLI dispatch.
const issued = new WeakSet();
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (value, reason) => { if (!value) throw new Error(reason); };
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}
function markerPath(namespaceRoot, version) {
  requireValue(version === '0.38.0', 'Refrozen contract required for another integrated version.');
  return physicalPath(path.join(physicalPath(namespaceRoot), `v${version}`, 'publish', 'in-flight.json'));
}
function exists(file) {
  try { fs.lstatSync(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
function plain(file) {
  const target = physicalPath(file);
  const before = fs.lstatSync(target, { bigint: true });
  requireValue(before.isFile() && !before.isSymbolicLink() && before.nlink === 1n, 'Plain single-link attempt record required.');
  const descriptor = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(descriptor, { bigint: true });
    const bytes = fs.readFileSync(descriptor);
    const after = fs.lstatSync(target, { bigint: true });
    const identity = stat => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key])).join(':');
    requireValue(identity(before) === identity(held) && identity(held) === identity(after), 'Attempt record changed during observation.');
    return { target, bytes, sha256: sha(bytes), identity: identity(after) };
  } finally { fs.closeSync(descriptor); }
}
function owner(value, bundle) {
  requireValue(exact(value, ['pid', 'creation_filetime', 'job_name', 'keeper']) && Number.isInteger(value.pid) && value.pid > 0 && value.pid <= 0xffffffff
    && typeof value.creation_filetime === 'string' && /^[1-9][0-9]*$/u.test(value.creation_filetime)
    && BigInt(value.creation_filetime) <= 0x7fffffffffffffffn
    && /^Local\\winsmux-integrated-publication-[a-f0-9]{32}$/u.test(value.job_name), 'Measured native owner and Job identity required.');
  const keeper = value.keeper;
  requireValue(exact(keeper, ['pid', 'creation_filetime', 'pipe_name', 'attempt', 'candidate_manifest_sha256', 'implementation_sha256', 'script_sha256'])
    && Number.isInteger(keeper.pid) && keeper.pid > 0 && keeper.pid <= 0xffffffff && keeper.pid !== value.pid
    && typeof keeper.creation_filetime === 'string' && /^[1-9][0-9]*$/u.test(keeper.creation_filetime)
    && BigInt(keeper.creation_filetime) <= 0x7fffffffffffffffn
    && keeper.pipe_name === `winsmux-publication-keeper-${value.job_name.slice(-32)}`
    && keeper.attempt === bundle.identity.attempt && keeper.candidate_manifest_sha256 === bundle.identity.manifest_sha256
    && /^[a-f0-9]{64}$/u.test(keeper.implementation_sha256) && /^[a-f0-9]{64}$/u.test(keeper.script_sha256),
  'Measured keeper identity and fixed candidate binding required.');
}

function actor(value) {
  requireValue(exact(value, ['pid', 'creation_filetime']) && Number.isInteger(value.pid) && value.pid > 0 && value.pid <= 0xffffffff
    && typeof value.creation_filetime === 'string' && /^[1-9][0-9]*$/u.test(value.creation_filetime)
    && BigInt(value.creation_filetime) <= 0x7fffffffffffffffn, 'Measured authority actor identity required.');
}

export function assertPublicationPreparationAllowed(namespaceRoot, version) {
  const marker = markerPath(namespaceRoot, version);
  requireValue(!exists(marker), 'Publication attempt is frozen; retain bytes and recover that attempt.');
  return Object.freeze({ preparation_unfrozen: true, publication_admitted: false });
}

function validateRecord(contract, bundle, record) {
  requireValue(exact(record, ['schema', 'state', 'candidate_identity', 'bundle_root', 'bundle_root_identity',
    'contract_inventory_sha256', 'contract_controls_sha256', 'assets', 'owner', 'actor'])
    && record.schema === 'winsmux-publication-in-flight/v2' && record.state === 'in_flight'
    && same(record.candidate_identity, bundle.identity) && record.bundle_root === bundle.root
    && record.bundle_root_identity === bundle.root_identity
    && record.contract_inventory_sha256 === contract.inventory_sha256 && record.contract_controls_sha256 === contract.controls_sha256
    && same(record.assets, bundle.assets), 'Frozen attempt differs from current canonical candidate.');
  owner(record.owner, bundle);
  actor(record.actor);
}

export function readFrozenPublicationAttempt(contract, bundle, namespaceRoot, observedRecordSha256) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  requireValue(typeof observedRecordSha256 === 'string' && /^[a-f0-9]{64}$/u.test(observedRecordSha256), 'Parent-observed attempt SHA required.');
  const input = plain(markerPath(namespaceRoot, bundle.identity.version));
  requireValue(input.sha256 === observedRecordSha256, 'Frozen attempt SHA differs from parent observation.');
  const record = parseStrictJson(input.bytes); validateRecord(contract, bundle, record);
  const snapshot = freeze({ file: input.target, original_sha256: input.sha256, original_identity: input.identity,
    record, publication_admitted: false });
  issued.add(snapshot); return snapshot;
}

export function freezePublicationAttempt(contract, bundle, namespaceRoot, observeNativeOwner, observeNativeActor) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  requireValue(typeof observeNativeOwner === 'function' && typeof observeNativeActor === 'function', 'Trusted native owner and actor observers required.');
  assertPublicationPreparationAllowed(namespaceRoot, bundle.identity.version);
  const actualOwner = structuredClone(observeNativeOwner()); owner(actualOwner, bundle);
  const actualActor = structuredClone(observeNativeActor()); actor(actualActor);
  const record = { schema: 'winsmux-publication-in-flight/v2', state: 'in_flight', candidate_identity: bundle.identity,
    bundle_root: bundle.root, bundle_root_identity: bundle.root_identity, contract_inventory_sha256: contract.inventory_sha256,
    contract_controls_sha256: contract.controls_sha256, assets: bundle.assets, owner: actualOwner, actor: actualActor };
  const marker = markerPath(namespaceRoot, bundle.identity.version);
  fs.mkdirSync(path.dirname(marker), { recursive: true }); physicalPath(path.dirname(marker));
  const bytes = Buffer.from(JSON.stringify(record));
  const descriptor = fs.openSync(marker, 'wx');
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  // An interrupted/partial record is preserved and blocks preparation. Neither
  // failure nor a success observation deletes it or regenerates the bundle.
  revalidatePublicationBundle(bundle);
  return readFrozenPublicationAttempt(contract, bundle, namespaceRoot, sha(bytes));
}

export function verifyPublicationRecovery(contract, bundle, snapshot, observeNativeState, observePublicBytes) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle);
  requireValue(issued.has(snapshot), 'Observed frozen attempt snapshot required.');
  revalidatePublicationBundle(bundle); validateRecord(contract, bundle, snapshot.record);
  const current = plain(snapshot.file);
  requireValue(current.sha256 === snapshot.original_sha256 && current.identity === snapshot.original_identity, 'Frozen attempt record changed.');
  requireValue(typeof observeNativeState === 'function' && typeof observePublicBytes === 'function', 'Native and public host observers required.');
  // These callbacks are trusted parent adapters, not parsers returning input
  // flags. They query the actual original owner/root identities and named Job,
  // then the actual release/registry bytes under the same candidate contract.
  const native = observeNativeState(snapshot.record.owner, snapshot.record.actor);
  requireValue(exact(native, ['owner', 'actor', 'actor_gone', 'owner_gone', 'roots_gone', 'job_found', 'active_members', 'keeper_exit_code', 'query_handoff_job_name'])
    && same(native.actor, snapshot.record.actor) && native.actor_gone === true
    && same(native.owner, snapshot.record.owner) && native.owner_gone === true && native.roots_gone === true
    && native.job_found === true && Number.isInteger(native.active_members) && native.active_members === 0
    && native.keeper_exit_code === 0 && native.query_handoff_job_name === snapshot.record.owner.job_name,
  'Original owner, roots and descendants are not proven idle.');
  const publicRows = observePublicBytes(bundle);
  requireValue(Array.isArray(publicRows) && publicRows.length === bundle.assets.length
    && same(publicRows.map(row => row.path).sort(), bundle.assets.map(row => row.path).sort()), 'Complete public byte observations required.');
  const expected = new Map(bundle.assets.map(row => [row.path, row.sha256]));
  const missing = [];
  for (const row of publicRows) {
    requireValue(exact(row, ['path', 'state', 'sha256']), 'Exact public observation required.');
    if (row.state === 'absent' && row.sha256 === null) missing.push(row.path);
    else requireValue(row.state === 'matching' && row.sha256 === expected.get(row.path), 'Public bytes differ or remain unknown; preserve the frozen attempt.');
  }
  return freeze({ candidate_identity: bundle.identity, local_bytes_verified: true, original_processes_idle: true,
    observed_matching: bundle.assets.length - missing.length, missing_operations: missing.sort(),
    attempt_remains_frozen: true, publication_admitted: false });
}
