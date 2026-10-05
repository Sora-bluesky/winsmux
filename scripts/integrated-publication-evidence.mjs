import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (condition, reason) => { if (!condition) throw new Error(reason); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const results = new Set(['pass', 'fail', 'not_run', 'blocked', 'incomplete']);
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const text = value => typeof value === 'string' && value.length > 0 && value === value.trim();
const statKeys = ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'];
const issuedRegistries = new WeakMap();

export function assertParentEvidenceRegistry(contract, bundle, registry, parentSession) {
  assertIssuedIntegratedContract(contract);
  assertIssuedPublicationBundle(bundle);
  const binding = issuedRegistries.get(registry);
  requireValue(binding?.contract === contract && binding.bundle === bundle
    && binding.parentSession === parentSession, 'Current parent and exact candidate evidence registry required.');
  return registry;
}
function plain(file) {
  const target = physicalPath(file);
  const descriptor = fs.openSync(target, 'r');
  try {
    const before = fs.fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.nlink === 1n, 'Evidence must be a plain single-link file.');
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, { bigint: true });
    const named = fs.lstatSync(target, { bigint: true });
    requireValue(statKeys.every(key => before[key] === after[key] && after[key] === named[key]),
      'Evidence changed during observation.');
    return { target, bytes, sha256: sha(bytes) };
  } finally { fs.closeSync(descriptor); }
}
function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

/** A parent-only, process-local registry. There is intentionally no CLI,
 * serialized permission token, input-JSON observer, or public dispatch here.
 * observeOriginal is trusted host code that checks the original native/CI/
 * review result and returns the host's observation. It must never be a parser
 * that simply returns the untrusted document's claimed pass/issuer/approved.
 * The host-supplied expected SHA must come from its separate original-result
 * observation, not from the evidence file or caller's JSON.
 */
export function createIntegratedEvidenceRegistry(contract, bundle, parentSession) {
  assertIssuedIntegratedContract(contract);
  assertIssuedPublicationBundle(bundle);
  requireValue(text(parentSession), 'Current parent session required.');
  const snapshots = new Map();
  const identity = bundle.identity;
  const workflow = contract.workflow_contract;
  const originalObligations = new Map(contract.obligations.map(row => [row.id, row]));
  let latestRegisteredStage = -1;

  function registerObservedOriginal({ file, observedSha256, observeOriginal }) {
    requireValue(hash(observedSha256) && typeof observeOriginal === 'function', 'Independent host observation required.');
    const input = plain(file);
    requireValue(input.sha256 === observedSha256, 'Original evidence SHA differs from parent observation.');
    // Give the trusted observer an independent byte copy. Nothing returned
    // by caller JSON can manufacture a registered snapshot.
    const observation = observeOriginal(Buffer.from(input.bytes));
    requireValue(observation && typeof observation === 'object' && !Array.isArray(observation), 'Host evidence observation required.');
    const stage = workflow.stages.find(row => row.stage === observation.stage);
    requireValue(stage && observation.owner_role === stage.owner_role && text(observation.session)
      && results.has(observation.result), 'Evidence stage, principal or result differs.');
    requireValue(stage.candidate_identity_state === 'must_not_exist' ? observation.candidate_identity === null
      : same(observation.candidate_identity, identity), 'Evidence candidate identity differs.');
    requireValue(observation.contract_inventory_sha256 === contract.inventory_sha256
      && observation.contract_controls_sha256 === contract.controls_sha256, 'Evidence contract differs.');
    requireValue(Array.isArray(observation.obligation_ids) && new Set(observation.obligation_ids).size === observation.obligation_ids.length
      && observation.obligation_ids.every(id => originalObligations.get(id)?.stage === stage.stage), 'Evidence obligation scope differs.');
    requireValue(Array.isArray(observation.evidence_names) && new Set(observation.evidence_names).size === observation.evidence_names.length
      && observation.evidence_names.length <= 1
      && observation.evidence_names.every(name => stage.required_evidence_origins[name] === stage.stage
        && path.basename(input.target) === name), 'Evidence actual filename or origin differs.');
    requireValue(observation.expected_actual_verified === true && text(observation.environment_sha256)
      && hash(observation.environment_sha256), 'Expected/actual and environment observation required.');
    if (stage.independent_session_from_prepare) {
      requireValue(observation.review_complete === true && observation.model === 'gpt-6.1-sol'
        && observation.effort === (stage.stage === 'design_review' ? 'max' : 'xhigh'), 'Complete eligible independent review required.');
    }
    if (stage.owner_role === 'parent') requireValue(observation.session === parentSession, 'Parent-owned stage must come from current parent.');
    const stageIndex = workflow.stages.indexOf(stage);
    requireValue(stageIndex >= latestRegisteredStage && stageIndex <= latestRegisteredStage + 1,
      'Release stage registration is skipped or retroactive.');
    const started = typeof observation.started_at === 'string' ? Date.parse(observation.started_at) : NaN;
    const finished = typeof observation.finished_at === 'string' ? Date.parse(observation.finished_at) : NaN;
    requireValue(Number.isFinite(started) && Number.isFinite(finished) && started <= finished,
      'Measured original stage start/finish required.');
    if (stageIndex > 0) {
      assertThroughStage(stage.previous_stage);
      const previous = [...snapshots.values()].filter(record => record.stage === stage.previous_stage);
      requireValue(previous.every(record => Date.parse(record.finished_at) <= started), 'Release stage preceded its completed predecessor.');
    }
    const snapshot = freeze({ ...structuredClone(observation), file: input.target, original_sha256: input.sha256 });
    const key = sha(Buffer.from(JSON.stringify({ stage: stage.stage, file: input.target, sha256: input.sha256 })));
    requireValue(!snapshots.has(key), 'Original evidence already registered.');
    snapshots.set(key, snapshot);
    latestRegisteredStage = stageIndex;
    return Object.freeze({ key, stage: stage.stage, original_sha256: input.sha256, publication_admitted: false });
  }

  function assertThroughStage(lastStage) {
    revalidatePublicationBundle(bundle);
    const last = workflow.stages.findIndex(row => row.stage === lastStage);
    requireValue(last >= 0, 'Unknown release stage.');
    const records = [...snapshots.values()];
    // Reobserve the original files, not just an old in-memory status string.
    for (const record of records) requireValue(plain(record.file).sha256 === record.original_sha256,
      'Registered original evidence changed.');
    const prepareSessions = new Set(records.filter(record => record.stage === 'prepare').map(record => record.session));
    const completed = [];
    for (const stage of workflow.stages.slice(0, last + 1)) {
      const own = records.filter(record => record.stage === stage.stage);
      requireValue(own.length > 0 && own.every(record => record.result === 'pass'), 'Required release stage incomplete or unsuccessful.');
      if (stage.independent_session_from_prepare) requireValue(own.every(record =>
        record.session !== parentSession && !prepareSessions.has(record.session)), 'Review session is not independent.');
      for (const name of stage.required_evidence) {
        const origin = stage.required_evidence_origins[name];
        requireValue(records.some(record => record.stage === origin && record.result === 'pass' && record.evidence_names.includes(name)),
          'Required original stage evidence missing.');
      }
      for (const obligation of contract.obligations.filter(row => row.stage === stage.stage))
        requireValue(own.some(record => record.obligation_ids.includes(obligation.id)), 'Required original obligation missing.');
      if (stage.stage === 'adopt') {
        requireValue(own.some(record => record.native_distribution_permission_verified === true
          && Array.isArray(record.native_distribution_source_sha256) && record.native_distribution_source_sha256.length > 0
          && record.native_distribution_source_sha256.every(hash)), 'Native distribution permission is unverified.');
        requireValue(own.some(record => record.required_final_head_checks_verified === true
          && record.required_checks_inventory_sha256 && hash(record.required_checks_inventory_sha256)
          && record.final_head === identity.source_commit), 'Original mandatory final-head checks are unverified.');
      }
      // Recording an authorization filename is not authority. A host publication
      // actor must separately check the actual direct message at action time.
      if (stage.stage === 'publish') requireValue(own.some(record => record.actual_public_asset_hashes_verified === true),
        'Actual public/candidate byte correspondence missing.');
      if (stage.stage === 'verify_published') requireValue(own.some(record => record.actual_download_and_windows_verified === true),
        'Actual downloaded public Windows result missing.');
      completed.push(stage.stage);
    }
    return freeze({ integrity_verified: true, stages: completed, candidate_identity: identity,
      registered_originals: records.length, publication_admitted: false });
  }

  const registry = Object.freeze({ registerObservedOriginal, assertThroughStage });
  issuedRegistries.set(registry, { contract, bundle, parentSession });
  return registry;
}
