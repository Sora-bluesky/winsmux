import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { integratedContractSources, readIntegratedPublicationContract,
  assertIntegratedObligationInventory, assertIssuedIntegratedContract } from '../../scripts/integrated-publication-contract.mjs';

// Operator originals are local, ignored inputs. Require their root explicitly;
// no checked-in synthetic policy may replace the actual release obligations.
assert.ok(process.argv[2], 'Pass the canonical operator root.');
const originalRoot = path.resolve(process.argv[2]);
const fixtureRoot = path.resolve('.evidence/workspace-package', `publication-contract-${randomUUID()}`);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const originalBytes = Object.fromEntries(Object.entries(integratedContractSources).map(([name, source]) =>
  [name, fs.readFileSync(path.join(originalRoot, source.path))]));
for (const [name, source] of Object.entries(integratedContractSources)) {
  assert.equal(hash(originalBytes[name]), source.sha256);
  const target = path.join(fixtureRoot, source.path);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, originalBytes[name]);
}
const contract = readIntegratedPublicationContract(fixtureRoot);
const plan = JSON.parse(originalBytes.task_plan.toString('utf8'));
const inventory = Buffer.from(JSON.stringify(contract.obligations));
let checks = 0;
function check(fn) { fn(); checks++; }
function rejects(fn, pattern) { check(() => assert.throws(fn, pattern)); }

check(() => {
  assert.equal(contract.tasks.length, 25);
  assert.equal(new Set(contract.obligations.map(row => row.id)).size, contract.obligations.length);
  assert.equal(assertIntegratedObligationInventory(contract, inventory).publication_admitted, false);
  assert.equal(contract.publication_admitted, false);
  assert.strictEqual(assertIssuedIntegratedContract(contract), contract);
});
for (const task of plan.new_tasks.filter(task => task.target_version === 'v0.38.0')) check(() => {
  const rows = contract.obligations.filter(row => row.task === task.id);
  assert.equal(rows.filter(row => row.kind === 'acceptance').length, task.acceptance.length);
  assert.equal(rows.filter(row => row.kind === 'automated').length, 1);
  assert.equal(rows.filter(row => row.kind === 'automated_predicate').length, 1);
  assert.equal(rows.filter(row => row.kind === 'programmatic_e2e').length,
    task.verification.e2e.required ? task.verification.e2e.steps.length : 0);
  assert.equal(rows.filter(row => row.kind === 'manual_windows').length,
    [872, 876, 881, 883, 885].includes(Number(task.id.slice(5))) ? task.verification.windows_action.procedure.length : 0);
  assert.deepEqual(contract.task_contracts[task.id].completion_contract, task.completion_contract);
  assert.deepEqual(contract.task_contracts[task.id].environment_required, task.verification.environment_required);
  assert.deepEqual(contract.task_contracts[task.id].forbidden_substitutes, task.verification.forbidden_substitutes);
});
const workflow = plan.new_tasks.find(task => task.id === 'TASK-885').release_workflow;
check(() => {
  assert.deepEqual(contract.workflow_contract.candidate_identity_contract, workflow.candidate_identity_contract);
  assert.deepEqual(contract.workflow_contract.history_policy, workflow.history_policy);
  assert.deepEqual(contract.global_contract.source_requirements, plan.source_requirements);
  assert.deepEqual(contract.global_contract.completion_definition, plan.completion_definition);
  assert.equal(contract.stages.length, 7);
});
for (const stage of workflow.stages) check(() => {
  const rows = contract.obligations.filter(row => row.stage === stage.stage && row.kind === 'release_stage_evidence');
  assert.equal(rows.length, stage.required_evidence.length);
  const control = contract.workflow_contract.stages.find(row => row.stage === stage.stage);
  assert.equal(control.previous_stage, stage.previous_stage);
  assert.equal(control.independent_session_from_prepare, stage.independent_session_from_prepare);
  assert.deepEqual(control.required_evidence_origins, stage.required_evidence_origins);
  assert.equal(control.windows_action.pass_predicate, stage.windows_action.pass_predicate);
});
check(() => {
  const rows = contract.obligations.filter(row => row.kind === 'release_windows');
  assert.equal(rows.filter(row => row.stage === 'verify_candidate').length, 3);
  assert.equal(rows.filter(row => row.stage === 'verify_published').length, 3);
  assert.ok(!rows.some(row => row.stage === 'publish'));
  assert.equal(contract.obligations.filter(row => row.kind === 'manual_windows_predicate'
    && row.task === 'TASK-885' && row.stage === 'verify_published').length, 1);
  assert.ok(contract.obligations.filter(row => row.kind === 'goal_condition').every(row => row.stage === 'verify_published'));
  assert.equal(contract.obligations.find(row => row.kind === 'completion_contract' && row.task === 'TASK-885').stage, 'verify_published');
});

// A missing single original obligation, added obligation, changed origin,
// changed hash, unknown field or reordered stage inventory is a refusal.
for (const mutation of [
  rows => rows.slice(1),
  rows => [...rows, rows[0]],
  rows => { rows[0].source = 'caller'; return rows; },
  rows => { rows[0].content_sha256 = '0'.repeat(64); return rows; },
  rows => { rows[0].approved = true; return rows; },
  rows => rows.reverse(),
]) rejects(() => assertIntegratedObligationInventory(contract,
  Buffer.from(JSON.stringify(mutation(structuredClone(contract.obligations))))), /inventory differs/);
rejects(() => assertIntegratedObligationInventory(contract, Buffer.from('[]')), /inventory differs/);
rejects(() => assertIntegratedObligationInventory(contract, Buffer.from('{}')), /inventory differs/);
rejects(() => assertIntegratedObligationInventory(contract, Buffer.from('[{"id":"a","\\u0069d":"b"}]')), /Duplicate/);
rejects(() => assertIntegratedObligationInventory(contract, Buffer.from([0xff])), /encoded data/);
rejects(() => assertIntegratedObligationInventory(contract, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), inventory])), /BOM-free/);
rejects(() => assertIntegratedObligationInventory(Object.freeze(structuredClone(contract)), inventory), /reviewed originals/);
rejects(() => assertIntegratedObligationInventory(Object.freeze({ schema: contract.schema, obligations: [] }), Buffer.from('[]')), /reviewed originals/);
rejects(() => { contract.obligations[0].stage = 'publish'; }, TypeError);
rejects(() => { contract.workflow_contract.history_policy.preserve_published_history = false; }, TypeError);

// Check every independent source, including legal UTF-8/JSON changes, against
// the exact reviewed bytes. Restore only private copies; originals never change.
for (const [name, source] of Object.entries(integratedContractSources)) {
  const target = path.join(fixtureRoot, source.path);
  fs.writeFileSync(target, Buffer.concat([originalBytes[name], Buffer.from('\n')]));
  rejects(() => readIntegratedPublicationContract(fixtureRoot), /source differs/);
  fs.writeFileSync(target, originalBytes[name]);
}
const source = integratedContractSources.task_plan;
const originalFile = path.join(fixtureRoot, source.path);
const linkedFile = path.join(fixtureRoot, 'hardlinked-plan.json');
fs.linkSync(originalFile, linkedFile);
rejects(() => readIntegratedPublicationContract(fixtureRoot), /single-link/);
// Preserve fixtures for attributable evidence; do not modify/delete originals.
for (const [name, descriptor] of Object.entries(integratedContractSources))
  check(() => assert.equal(hash(fs.readFileSync(path.join(originalRoot, descriptor.path))), hash(originalBytes[name])));
console.log(JSON.stringify({ passed: true, checks, obligations: contract.obligations.length,
  tasks: contract.tasks.length, stages: contract.stages.length,
  inventory_sha256: contract.inventory_sha256, controls_sha256: contract.controls_sha256,
  publication_admitted: false, originals_unchanged: true }));
