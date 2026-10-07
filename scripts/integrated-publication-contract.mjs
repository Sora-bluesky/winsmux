import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { physicalPath } from './distribution-prelaunch.mjs';

// These are the independently reviewed operator originals, not caller policy.
// Their contents remain local; this module never grants publication authority.
export const integratedContractSources = Object.freeze({
  task_plan: Object.freeze({
    path: '.references/operator-plans/rebuild-v0380-20260906/task-plan.json',
    sha256: '287f8e8ca5ce5ef784c923b64a2d162c3368b2c9e7604b768375a86eb77859b8',
  }),
  execution_acceptance: Object.freeze({
    path: '.references/operator-plans/release-v0380-20260907/EXECUTION-ACCEPTANCE.md',
    sha256: '8d960f04bf37ac62a63c7e14f2b06ab1b5c57783d94507b136c709eadaba7dab',
  }),
  goal: Object.freeze({
    path: '.references/operator-plans/release-v0380-20260907/GOAL.md',
    sha256: '74313f56f43e216052c1ee7817d775f499276e0e75604e6feaf5174e88e9193a',
  }),
});

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (condition, reason) => { if (!condition) throw new Error(reason); };
const manualTasks = new Set([872, 876, 881, 883, 885]);
const stages = Object.freeze(['design_review', 'prepare', 'verify_candidate', 'frozen_review', 'adopt', 'publish', 'verify_published']);
const issuedContracts = new WeakSet();
const requiredGoalSections = Object.freeze([
  '目的', '維持する制約', '承認済みの範囲変更',
  '2026-09-08の利用者指定：不要な旧実装と開発資料を残さない',
  '検証', '2026-09-10の利用者指定：Windows専用と競合比較',
  '追加指定：Microsoft一次情報に基づく検証全体',
]);

function readSource(root, source) {
  const file = physicalPath(path.join(root, source.path));
  const before = fs.lstatSync(file, { bigint: true });
  requireValue(before.isFile() && before.nlink === 1n, 'Contract source must be a plain single-link file.');
  const bytes = fs.readFileSync(file);
  const after = fs.lstatSync(file, { bigint: true });
  requireValue(['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].every(key => before[key] === after[key]),
    'Contract source changed during observation.');
  requireValue(sha(bytes) === source.sha256, 'Reviewed contract source differs.');
  return bytes;
}

function freeze(value) {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

/** Derive the full obligation inventory from pinned originals. No caller subset,
 * status field, flag, or approved=true value can replace these obligations.
 * This is the contract layer; evidence and artifact validation is separate.
 */
export function readIntegratedPublicationContract(operatorRoot) {
  const sourceBytes = {};
  for (const [name, source] of Object.entries(integratedContractSources)) sourceBytes[name] = readSource(operatorRoot, source);
  const plan = parseStrictJson(sourceBytes.task_plan);
  const acceptance = new TextDecoder('utf-8', { fatal: true }).decode(sourceBytes.execution_acceptance);
  const goal = new TextDecoder('utf-8', { fatal: true }).decode(sourceBytes.goal);
  requireValue(Array.isArray(plan.new_tasks)
    && plan.new_tasks.filter(task => task.target_version === 'v0.38.0').length === 25,
  'Exact TASK-861 through TASK-885 inventory required.');
  requireValue(acceptance.includes('| A：実操作の証拠自体が成果 | 872、876、881、883、885 |')
    && acceptance.includes('元の25親責任の`verification.e2e`を一括削除せず'), 'Reviewed manual-operation allocation differs.');

  const obligations = [];
  const taskContracts = {};
  const add = (task, source, selector, kind, stage, value) => {
    requireValue(typeof value === 'string' && value.trim().length > 0, 'Nonempty source obligation required.');
    const identity = { task, source, selector, kind, stage, content_sha256: sha(Buffer.from(value)) };
    obligations.push({ id: sha(Buffer.from(JSON.stringify(identity))), ...identity });
  };
  const tasks = new Set();
  plan.new_tasks.forEach((task, taskIndex) => {
    if (task.target_version !== 'v0.38.0') return;
    const number = Number(task.id?.slice(5));
    requireValue(task.id === `TASK-${number}` && number >= 861 && number <= 885 && !tasks.has(task.id)
      && task.target_version === 'v0.38.0', 'Unexpected, duplicate or differently versioned task.');
    tasks.add(task.id);
    const base = `/new_tasks/${taskIndex}`;
    const row = (selector, kind, value, stage = 'verify_candidate') => add(task.id, 'task_plan', base + selector, kind, stage, value);
    requireValue(Array.isArray(task.acceptance) && task.acceptance.length > 0, 'Original task acceptance required.');
    task.acceptance.forEach((value, index) => row(`/acceptance/${index}`, 'acceptance', value));
    const verification = task.verification;
    requireValue(verification?.automated && verification.e2e && verification.windows_action, 'Original verification contract required.');
    taskContracts[task.id] = {
      depends_on: task.depends_on, requirements: task.requirements,
      completion_contract: task.completion_contract,
      public_release_requires: task.public_release_requires,
      environment_required: verification.environment_required,
      evidence_required: verification.evidence_required,
      forbidden_substitutes: verification.forbidden_substitutes,
      q_ids: verification.q_ids,
      programmatic_e2e_required: verification.e2e.required,
      real_windows_required: manualTasks.has(number),
    };
    // TASK-885's completion explicitly requires verify_published. It remains
    // in the full inventory but cannot become a circular prepublish condition.
    row('/completion_contract', 'completion_contract', JSON.stringify(task.completion_contract),
      number === 885 ? 'verify_published' : 'verify_candidate');
    row('/verification/evidence_required', 'evidence_requirements', JSON.stringify({
      environment_required: verification.environment_required,
      evidence_required: verification.evidence_required,
      forbidden_substitutes: verification.forbidden_substitutes,
    }));
    row('/verification/automated/command_or_procedure', 'automated', verification.automated.command_or_procedure);
    row('/verification/automated/pass_predicate', 'automated_predicate', verification.automated.pass_predicate);
    // B/C remove intermediate manual Cua only. Real programmatic E2E remains.
    requireValue(typeof verification.e2e.required === 'boolean', 'Explicit programmatic E2E applicability required.');
    if (verification.e2e.required) {
      requireValue(Array.isArray(verification.e2e.steps) && verification.e2e.steps.length > 0, 'Original E2E steps required.');
      verification.e2e.steps.forEach((value, index) => row(`/verification/e2e/steps/${index}`, 'programmatic_e2e', value));
      row('/verification/e2e/pass_predicate', 'programmatic_e2e_predicate', verification.e2e.pass_predicate);
    }
    if (manualTasks.has(number)) {
      requireValue(Array.isArray(verification.windows_action.procedure) && verification.windows_action.procedure.length > 0,
        'Required real Windows procedure missing.');
      if (number === 885) requireValue(verification.windows_action.procedure.length === 2
        && verification.windows_action.procedure[0].includes('release_workflow.verify_candidate')
        && verification.windows_action.procedure[1].includes('release_workflow.verify_published'),
      'Separate prepublication and published Windows owners required.');
      verification.windows_action.procedure.forEach((value, index) => {
        // TASK-885 explicitly delegates its two Windows stages. Keep the
        // published stage out of the prepublication predicate to avoid a cycle.
        const stage = number === 885 && index === 1 ? 'verify_published' : 'verify_candidate';
        row(`/verification/windows_action/procedure/${index}`, 'manual_windows', value, stage);
      });
      row('/verification/windows_action/pass_predicate', 'manual_windows_predicate',
        verification.windows_action.pass_predicate, number === 885 ? 'verify_published' : 'verify_candidate');
    }
  });
  for (let number = 861; number <= 885; number++) requireValue(tasks.has(`TASK-${number}`), 'Required task missing.');

  const releaseIndex = plan.new_tasks.findIndex(task => task.id === 'TASK-885');
  const workflow = plan.new_tasks[releaseIndex].release_workflow;
  requireValue(workflow?.schema === 'winsmux-release-workflow/v1' && Array.isArray(workflow.stages)
    && JSON.stringify(workflow.stages.map(stage => stage.stage)) === JSON.stringify(stages), 'Exact release stage order required.');
  workflow.stages.forEach((stage, index) => {
    requireValue(stage.order === index + 1 && stage.previous_stage === (index ? stages[index - 1] : null)
      && Array.isArray(stage.required_evidence) && stage.required_evidence.length > 0, 'Release stage predecessor or evidence differs.');
    requireValue(stage.required_evidence_origins && stage.windows_action
      && stage.required_evidence.every(value => stages.includes(stage.required_evidence_origins[value])),
    'Release evidence origin required.');
    stage.required_evidence.forEach((value, evidenceIndex) => add('TASK-885', 'task_plan',
      `/new_tasks/${releaseIndex}/release_workflow/stages/${index}/required_evidence/${evidenceIndex}`,
      'release_stage_evidence', stage.stage, JSON.stringify({ file: value, origin: stage.required_evidence_origins[value] })));
    if (stage.windows_action.required) stage.windows_action.procedure.forEach((value, procedureIndex) => add('TASK-885', 'task_plan',
      `/new_tasks/${releaseIndex}/release_workflow/stages/${index}/windows_action/procedure/${procedureIndex}`,
      'release_windows', stage.stage, value));
    if (stage.windows_action.required) add('TASK-885', 'task_plan',
      `/new_tasks/${releaseIndex}/release_workflow/stages/${index}/windows_action/pass_predicate`,
      'release_windows_predicate', stage.stage, stage.windows_action.pass_predicate);
  });

  // These constraints are executable inputs to the stage/evidence layer, not
  // an operator's self-reported completion flag. Original execution states
  // record initial planning only and cannot establish a current result.
  const workflowContract = {
    schema: workflow.schema,
    public_side_effect: workflow.public_side_effect,
    stages: workflow.stages.map(({ execution_state, windows_action, ...stage }) => ({
      ...stage,
      windows_action: Object.fromEntries(Object.entries(windows_action).filter(([key]) => key !== 'execution_state')),
    })),
    candidate_identity_contract: workflow.candidate_identity_contract,
    history_policy: workflow.history_policy,
  };
  const globalContract = {
    completion_definition: plan.completion_definition,
    source_requirements: plan.source_requirements,
    implementation_protocol: plan.implementation_protocol,
  };

  const lines = goal.split(/\r?\n/u);
  for (const heading of requiredGoalSections) {
    const start = lines.findIndex(line => line === `## ${heading}`);
    requireValue(start >= 0, 'Required goal section missing.');
    let end = start + 1;
    while (end < lines.length && !lines[end].startsWith('## ')) end++;
    // A complete goal includes publication and postpublication results. Its
    // protected constraints remain fixed controls throughout; its completion
    // is verified only at the final stage, never fabricated before publish.
    add('TASK-885', 'goal', `heading:${heading}`, 'goal_condition', 'verify_published', lines.slice(start + 1, end).join('\n'));
  }
  globalContract.goal_condition_sha256 = obligations.filter(row => row.kind === 'goal_condition')
    .map(row => ({ selector: row.selector, content_sha256: row.content_sha256 }));
  const contract = {
    schema: 'winsmux-integrated-publication-contract/v1',
    sources: Object.fromEntries(Object.entries(integratedContractSources).map(([name, source]) => [name, source.sha256])),
    tasks: [...tasks].sort(), stages: [...stages], obligations,
    task_contracts: taskContracts, workflow_contract: workflowContract, global_contract: globalContract,
    inventory_sha256: sha(Buffer.from(JSON.stringify(obligations))),
    controls_sha256: sha(Buffer.from(JSON.stringify({ taskContracts, workflowContract, globalContract }))),
    publication_admitted: false,
  };
  freeze(contract);
  issuedContracts.add(contract);
  return contract;
}

export function assertIssuedIntegratedContract(contract) {
  requireValue(issuedContracts.has(contract), 'Contract must be read from reviewed originals by this validator.');
  return contract;
}

export function assertIntegratedObligationInventory(contract, bytes) {
  assertIssuedIntegratedContract(contract);
  const supplied = parseStrictJson(bytes);
  requireValue(Array.isArray(supplied) && JSON.stringify(supplied) === JSON.stringify(contract.obligations),
  'Obligation inventory differs from the reviewed originals.');
  return Object.freeze({ inventory_sha256: contract.inventory_sha256, obligations: supplied.length, publication_admitted: false });
}
