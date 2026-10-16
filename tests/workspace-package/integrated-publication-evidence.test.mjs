import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { publicationFixture, sha } from './publication-fixture.mjs';
import { createIntegratedEvidenceRegistry, assertParentEvidenceRegistry } from '../../scripts/integrated-publication-evidence.mjs';
import { checkParentPublicationPrerequisites } from '../../scripts/check-parent-publication-prerequisites.mjs';

assert.ok(process.argv[2], 'Pass the canonical operator root.');
const fixture = publicationFixture(path.resolve(process.argv[2]));
const { contract, bundle, root } = fixture;
const parent = 'synthetic-parent-session';
let checks = 0;
const check = fn => { fn(); checks++; };
const reject = (fn, pattern) => check(() => assert.throws(fn, pattern));
const originals = new Map();
for (const stage of contract.workflow_contract.stages) {
  const file = path.join(root, `${stage.stage}-original.txt`);
  const bytes = Buffer.from(`Synthetic trusted-host observation fixture, not real ${stage.stage} evidence.\n`);
  fs.writeFileSync(file, bytes);
  originals.set(stage.stage, { file, bytes });
}
function observation(stageName) {
  const stage = contract.workflow_contract.stages.find(row => row.stage === stageName);
  const index = contract.stages.indexOf(stageName);
  const ownNames = new Set(contract.workflow_contract.stages.flatMap(row => Object.entries(row.required_evidence_origins)
    .filter(([, origin]) => origin === stageName).map(([name]) => name)));
  return {
    stage: stageName, owner_role: stage.owner_role,
    started_at: `2026-10-03T00:0${index}:00Z`, finished_at: `2026-10-03T00:0${index}:30Z`,
    session: stageName === 'prepare' ? 'synthetic-author-session'
      : stage.independent_session_from_prepare ? `synthetic-independent-${stageName}` : parent,
    result: 'pass', candidate_identity: stage.candidate_identity_state === 'must_not_exist' ? null : bundle.identity,
    contract_inventory_sha256: contract.inventory_sha256, contract_controls_sha256: contract.controls_sha256,
    obligation_ids: contract.obligations.filter(row => row.stage === stageName).map(row => row.id),
    evidence_names: [...ownNames], expected_actual_verified: true, environment_sha256: sha(Buffer.from('synthetic-environment')),
    ...(stage.independent_session_from_prepare ? { review_complete: true, model: 'gpt-6.1-sol',
      effort: stageName === 'design_review' ? 'max' : 'xhigh' } : {}),
    ...(stageName === 'adopt' ? { native_distribution_permission_verified: true,
      native_distribution_source_sha256: [sha(Buffer.from('synthetic licence proof only'))],
      required_final_head_checks_verified: true, required_checks_inventory_sha256: sha(Buffer.from('synthetic mandatory checks')),
      final_head: bundle.identity.source_commit } : {}),
    ...(stageName === 'publish' ? { actual_public_asset_hashes_verified: true } : {}),
    ...(stageName === 'verify_published' ? { actual_download_and_windows_verified: true } : {}),
  };
}
function register(registry, stage, mutation = () => {}) {
  const original = originals.get(stage);
  const facts = observation(stage); mutation(facts);
  const names = facts.evidence_names;
  const receipt = registry.registerObservedOriginal({ file: original.file, observedSha256: sha(original.bytes),
    observeOriginal: bytes => { assert.deepEqual(bytes, original.bytes); return { ...facts, evidence_names: [] }; } });
  for (const name of names) {
    const file = path.join(root, stage, name);
    const bytes = Buffer.from(`Synthetic actual named file, not real release proof: ${stage}/${name}\n`);
    fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes);
    registry.registerObservedOriginal({ file, observedSha256: sha(bytes), observeOriginal: observed => {
      assert.deepEqual(observed, bytes); return { ...facts, evidence_names: [name] }; } });
  }
  return receipt;
}
const make = () => createIntegratedEvidenceRegistry(contract, bundle, parent);
const all = (mutation = () => {}) => {
  const registry = make();
  for (const stage of contract.stages) register(registry, stage, facts => mutation(stage, facts));
  return registry;
};
const registry = make();
check(() => assert.equal(assertParentEvidenceRegistry(contract, bundle, registry, parent), registry));
for (const forged of [{ assertThroughStage: () => ({ stages: ['adopt'], integrity_verified: true }) },
  { ...registry }, null, { approved: true }])
  reject(() => checkParentPublicationPrerequisites(contract, bundle, forged, {}, parent), /evidence registry required/);
reject(() => assertParentEvidenceRegistry(contract, bundle, registry, 'another-parent'), /evidence registry required/);
const other = publicationFixture(path.resolve(process.argv[2]));
reject(() => assertParentEvidenceRegistry(other.contract, other.bundle, registry, parent), /evidence registry required/);
reject(() => checkParentPublicationPrerequisites(contract, bundle, registry, {}, parent), /stage incomplete/);
for (let index = 0; index < contract.stages.length; index++) {
  const stage = contract.stages[index];
  reject(() => registry.assertThroughStage(stage), /stage incomplete/);
  register(registry, stage);
  check(() => {
    const result = registry.assertThroughStage(stage);
    assert.equal(result.integrity_verified, true);
    assert.equal(result.publication_admitted, false);
    assert.equal(result.stages.length, index + 1);
  });
}
reject(() => registry.assertThroughStage('unknown'), /Unknown release stage/);
reject(() => register(registry, 'prepare'), /retroactive/);
reject(() => register(make(), 'prepare'), /skipped/);
reject(() => register(make(), 'design_review', facts => { facts.started_at = null; }), /start\/finish/);
reject(() => register(make(), 'design_review', facts => { facts.started_at = '2026-10-03T00:01:00Z'; }), /start\/finish/);
reject(() => { const value = make(); register(value, 'design_review'); register(value, 'prepare', facts => {
  facts.started_at = '2026-10-02T00:00:00Z'; }); }, /predecessor/);
const original = originals.get('prepare');
for (const supplied of [undefined, true, { approved: true }, { pass: true, issuer: 'parent' }])
  reject(() => make().registerObservedOriginal({ file: original.file, observedSha256: sha(original.bytes), observeOriginal: supplied }), /host observation/);
reject(() => make().registerObservedOriginal({ file: original.file, observedSha256: '0'.repeat(64), observeOriginal: () => observation('prepare') }), /SHA differs/);
reject(() => make().registerObservedOriginal({ file: originals.get('design_review').file,
  observedSha256: sha(originals.get('design_review').bytes), observeOriginal: () => observation('design_review') }), /actual filename/);
for (const mutate of [
  facts => { facts.owner_role = 'caller'; },
  facts => { facts.result = 'success'; },
  facts => { facts.candidate_identity = { ...facts.candidate_identity, attempt: 'another-attempt' }; },
  facts => { facts.candidate_identity = { ...facts.candidate_identity, source_commit: '3'.repeat(40) }; },
  facts => { facts.candidate_identity = { ...facts.candidate_identity, source_tree: '3'.repeat(40) }; },
  facts => { facts.contract_inventory_sha256 = '0'.repeat(64); },
  facts => { facts.contract_controls_sha256 = '0'.repeat(64); },
  facts => { facts.obligation_ids = [contract.obligations.find(row => row.stage === 'verify_published').id]; },
  facts => { facts.evidence_names = ['published-windows-result.json']; },
  facts => { facts.expected_actual_verified = false; },
  facts => { facts.environment_sha256 = ''; },
]) reject(() => register(make(), 'prepare', mutate));
for (const result of ['fail', 'not_run', 'blocked', 'incomplete']) reject(() => {
  const value = make(); register(value, 'design_review', facts => { facts.result = result; }); value.assertThroughStage('design_review');
}, /unsuccessful/);
for (const mutate of [
  facts => { facts.review_complete = false; },
  facts => { facts.model = 'gpt-6-sol'; },
  facts => { facts.effort = 'high'; },
]) reject(() => register(make(), 'frozen_review', mutate), /independent review/);
for (const session of [parent, 'synthetic-author-session']) reject(() => {
  const value = all((stage, facts) => { if (stage === 'frozen_review') facts.session = session; }); value.assertThroughStage('adopt');
}, /not independent/);
reject(() => all((stage, facts) => { if (stage === 'adopt') facts.session = 'another-parent'; }), /current parent/);
for (const [field, replacement] of [
  ['native_distribution_permission_verified', false], ['native_distribution_source_sha256', []],
  ['required_final_head_checks_verified', false], ['required_checks_inventory_sha256', null], ['final_head', '3'.repeat(40)],
]) reject(() => all((stage, facts) => { if (stage === 'adopt') facts[field] = replacement; }).assertThroughStage('adopt'), /permission|final-head/);
reject(() => all((stage, facts) => { if (stage === 'verify_candidate') facts.obligation_ids.pop(); }).assertThroughStage('adopt'), /obligation missing/);
reject(() => all((stage, facts) => { if (stage === 'prepare') facts.evidence_names.pop(); }).assertThroughStage('adopt'), /stage evidence missing/);
reject(() => all((stage, facts) => { if (stage === 'publish') facts.actual_public_asset_hashes_verified = false; }).assertThroughStage('publish'), /correspondence/);
reject(() => all((stage, facts) => { if (stage === 'verify_published') facts.actual_download_and_windows_verified = false; }).assertThroughStage('verify_published'), /downloaded/);
fs.writeFileSync(original.file, Buffer.from('changed original'));
reject(() => registry.assertThroughStage('adopt'), /original evidence changed/);
fs.writeFileSync(original.file, original.bytes);
const asset = path.join(bundle.root, 'npm/winsmux-0.38.0.tgz');
fs.writeFileSync(asset, Buffer.from('changed actual asset'));
reject(() => registry.assertThroughStage('adopt'), /asset bytes differ/);
fs.writeFileSync(asset, fixture.files.get('npm/winsmux-0.38.0.tgz'));
check(() => assert.equal(registry.assertThroughStage('verify_published').publication_admitted, false));
reject(() => checkParentPublicationPrerequisites(contract, bundle, registry, { publication_admitted: true }, parent), /Actual parent-observed/);
console.log(JSON.stringify({ passed: true, checks, stages: 7, publication_admitted: false,
  scope: 'synthetic host-registration and stage-integrity proof; no real adoption or publication authority' }));
