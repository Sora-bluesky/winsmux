import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';

const repository = 'Sora-bluesky/winsmux';
const base = 'https://api.github.com/repos/' + repository;
const required = ['secret-scan', 'public-surface', 'install-e2e', 'native-lifecycle-source', 'common-contract-drift',
  'pester', 'core-build-test', 'desktop-build-test', 'desktop-release-process', 'desktop-nsis-lifecycle', 'task811-receipt-bind',
  'helper-linux-negatives', 'workspace-journey-native'];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const number = value => Number.isSafeInteger(value) && value > 0;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const observed = new WeakMap();
const freeze = value => {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); } return value;
};
function snapshot(file, expectedSha) {
  const target = physicalPath(file), before = fs.lstatSync(target, { bigint: true });
  demand(before.isFile() && before.nlink === 1n && !before.isSymbolicLink(), 'Plain CI observer source required.');
  const fd = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(fd, { bigint: true }), bytes = fs.readFileSync(fd), after = fs.lstatSync(target, { bigint: true });
    const identity = value => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(value[key])).join(':');
    demand(identity(before) === identity(held) && identity(held) === identity(after) && sha(bytes) === expectedSha,
      'CI observer input differs from independent source observation.');
    return { target, bytes, sha256: expectedSha, identity: identity(after) };
  } finally { fs.closeSync(fd); }
}
function retain(file, bytes) {
  const fd = fs.openSync(file, 'wx');
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function inventory(value, workflowSha) {
  demand(value?.schema === 'winsmux-required-ci-inventory/v1' && value.workflow_sha256 === workflowSha
    && same(value.required_categories, required) && same(Object.keys(value.names), [...required, 'merge-gate'])
    && Object.values(value.names).every(names => Array.isArray(names) && names.length > 0
      && names.every(name => typeof name === 'string' && name.length > 0)), 'Complete source-derived CI inventory required.');
  const names = Object.values(value.names).flat();
  demand(new Set(names).size === names.length && value.required_job_count === names.length, 'CI matrix inventory differs.');
  return value;
}

/** Validate complete original API bodies, never their claimed approved/pass.
 * This pure function produces no observed-origin brand or stage authority.
 */
function validateCandidateSources({ sourceCommit, sourceTree, workflowSha256, commit, workflow }) {
  demand(commit?.sha === sourceCommit && commit.tree?.sha === sourceTree, 'GitHub commit/tree differs from candidate.');
  demand(workflow?.type === 'file' && workflow.path === '.github/workflows/test.yml' && workflow.encoding === 'base64'
    && typeof workflow.content === 'string' && typeof workflow.sha === 'string', 'Exact workflow source original required.');
  const encoded = workflow.content.replaceAll('\n', '');
  demand(/^[A-Za-z0-9+/]*={0,2}$/u.test(encoded) && encoded.length % 4 === 0, 'Invalid GitHub workflow encoding.');
  const bytes = Buffer.from(encoded, 'base64');
  demand(bytes.toString('base64') === encoded && sha(bytes) === workflowSha256
    && createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes])).digest('hex') === workflow.sha,
  'GitHub workflow bytes differ from frozen source.');
}

export function validateGithubRequiredChecksPayload({ sourceCommit, sourceTree, workflowSha256, jobInventory,
  commit, workflow, run, jobs, jobsTotal }) {
  inventory(jobInventory, workflowSha256);
  validateCandidateSources({ sourceCommit, sourceTree, workflowSha256, commit, workflow });
  demand(number(run?.id) && number(run.run_attempt) && run.head_sha === sourceCommit
    && (run.path === '.github/workflows/test.yml' || /^\.github\/workflows\/test\.yml@[^\s]+$/u.test(run.path ?? ''))
    && run.repository?.full_name?.toLowerCase() === repository.toLowerCase() && run.head_repository?.full_name?.toLowerCase() === repository.toLowerCase()
    && run.url === `${base}/actions/runs/${run.id}`, 'CI run source, repository or attempt differs.');
  demand(Array.isArray(jobs) && Number.isSafeInteger(jobsTotal) && jobsTotal === jobs.length
    && new Set(jobs.map(job => job.id)).size === jobs.length, 'CI original jobs pagination incomplete/duplicate.');
  for (const job of jobs) demand(number(job.id) && job.run_id === run.id && job.run_url === run.url && job.head_sha === sourceCommit
    && job.url === `${base}/actions/jobs/${job.id}` && typeof job.name === 'string', 'CI job original belongs to another run/head.');
  const results = Object.entries(jobInventory.names).map(([category, names]) => ({ category, members: names.map(name => {
    const matches = jobs.filter(job => job.name === name);
    demand(matches.length === 1, 'Required CI matrix member missing/ambiguous: ' + name);
    const job = matches[0];
    return { name, id: job.id, status: job.status, conclusion: job.conclusion,
      passed: job.status === 'completed' && job.conclusion === 'success' };
  }) }));
  const passed = run.status === 'completed' && run.conclusion === 'success' && results.every(row => row.members.every(job => job.passed));
  return freeze({ passed, required_categories: required.length, required_jobs: jobInventory.required_job_count,
    run_id: run.id, run_attempt: run.run_attempt, results, publication_admitted: false });
}

function getOriginal(endpoint) {
  // Public GET only, fixed origin, no credentials or redirect following. An API
  // denial is an incomplete observation, never authority or a reason to publish.
  return new Promise((resolve, reject) => {
    const url = base + endpoint;
    const request = https.get(url, { rejectUnauthorized: true, headers: { Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'winsmux-release-verifier' } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk)); response.on('error', reject);
      response.on('end', () => resolve({ url, status: response.statusCode, bytes: Buffer.concat(chunks),
        server_date: response.headers.date ?? null }));
    });
    request.on('error', reject);
  });
}

/** Trusted host entry: execute the frozen parser and fetch actual GitHub
 * originals. There is no CLI/input-JSON registration or caller fetch callback.
 * A source hash/inventory is a contract; an HTTP observation is separate.
 */
export async function observeGithubRequiredChecks(contract, bundle, { namespaceRoot, parentSession, workflowFile,
  observedWorkflowSha256, pythonImage, observedPythonSha256, parserFile, observedParserSha256 }) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  demand(typeof parentSession === 'string' && parentSession.trim() === parentSession && parentSession.length > 0, 'Actual host session required.');
  const source = snapshot(workflowFile, observedWorkflowSha256), python = snapshot(pythonImage, observedPythonSha256), parser = snapshot(parserFile, observedParserSha256);
  const root = physicalPath(namespaceRoot); demand(fs.statSync(root).isDirectory(), 'Existing owned CI observation namespace required.');
  const directory = path.join(root, 'ci-' + randomUUID()); fs.mkdirSync(directory);
  const started = new Date().toISOString(), originals = [];
  const environment = { PATH: process.env.PATH ?? path.dirname(python.target) };
  for (const key of ['SystemRoot', 'WINDIR', 'COMSPEC']) if (process.env[key]) environment[key] = process.env[key];
  const parsed = spawnSync(python.target, ['-I', '-B', parser.target, source.target, source.sha256], { env: environment, windowsHide: true });
  retain(path.join(directory, 'inventory-stdout.json'), parsed.stdout ?? Buffer.alloc(0));
  retain(path.join(directory, 'inventory-stderr.txt'), parsed.stderr ?? Buffer.alloc(0));
  let result = null, failure = null, jobInventory = null;
  let seenRun = null;
  const fetch = async (endpoint, name) => {
    const original = await getOriginal(endpoint); const file = path.join(directory, name);
    retain(file, original.bytes); originals.push({ file, url: original.url, status: original.status,
      sha256: sha(original.bytes), server_date: original.server_date });
    demand(original.status === 200, 'Actual GitHub original unavailable: HTTP ' + original.status);
    return parseStrictJson(original.bytes);
  };
  const paginated = async (endpoint, key, label) => {
    const rows = [], ids = new Set(); let total = null;
    for (let page = 1; total === null || rows.length < total; page++) {
      const data = await fetch(endpoint + (endpoint.includes('?') ? '&' : '?') + 'per_page=100&page=' + page, label + '-' + page + '.json');
      demand(Number.isSafeInteger(data.total_count) && data.total_count >= 0 && Array.isArray(data[key]), 'Invalid original API pagination.');
      demand(total === null || total === data.total_count, 'GitHub original inventory changed during pagination.'); total = data.total_count;
      demand(data[key].length > 0 || rows.length === total, 'Incomplete original API pagination.');
      for (const row of data[key]) { demand(number(row.id) && !ids.has(row.id), 'Repeated/invalid original API row.'); ids.add(row.id); rows.push(row); }
      demand(rows.length <= total, 'Original API inventory exceeds declared total.');
    }
    return { rows, total };
  };
  const latest = async label => {
    const data = await paginated(`/actions/workflows/test.yml/runs?head_sha=${bundle.identity.source_commit}`, 'workflow_runs', label);
    demand(data.rows.every(row => row.head_sha === bundle.identity.source_commit), 'GitHub head filter returned a different head.');
    return data.rows.sort((a, b) => b.id - a.id)[0] ?? null;
  };
  try {
    demand(!parsed.error && parsed.status === 0 && parsed.signal === null && (parsed.stderr?.length ?? 0) === 0, 'Frozen CI inventory parser did not complete.');
    jobInventory = inventory(parseStrictJson(parsed.stdout), source.sha256);
    const commit = await fetch('/git/commits/' + bundle.identity.source_commit, 'commit.json');
    const workflow = await fetch('/contents/.github/workflows/test.yml?ref=' + bundle.identity.source_commit, 'workflow.json');
    validateCandidateSources({ sourceCommit: bundle.identity.source_commit, sourceTree: bundle.identity.source_tree,
      workflowSha256: source.sha256, commit, workflow });
    seenRun = await latest('runs-before');
    if (seenRun === null) result = { passed: false, state: 'not_run', required_categories: required.length,
      required_jobs: jobInventory.required_job_count, reason: 'No actual test workflow run for exact candidate head.' };
    else {
      const jobs = await paginated(`/actions/runs/${seenRun.id}/attempts/${seenRun.run_attempt}/jobs`, 'jobs', 'jobs');
      result = validateGithubRequiredChecksPayload({ sourceCommit: bundle.identity.source_commit, sourceTree: bundle.identity.source_tree,
        workflowSha256: source.sha256, jobInventory, commit, workflow, run: seenRun, jobs: jobs.rows, jobsTotal: jobs.total });
      const after = await fetch(`/actions/runs/${seenRun.id}`, 'run-after.json'), newest = await latest('runs-after');
      const coordinates = run => [run.id, run.run_attempt, run.head_sha, run.status, run.conclusion, run.updated_at];
      demand(same(coordinates(seenRun), coordinates(after)) && newest && same(coordinates(after), coordinates(newest)),
        'CI run/attempt/latest result changed during observation.');
    }
  } catch (error) { failure = error.message; result = { passed: false, state: 'blocked', reason: failure }; }
  for (const before of [source, python, parser]) demand(snapshot(before.target, before.sha256).identity === before.identity, 'CI observer source/runtime changed.');
  revalidatePublicationBundle(bundle);
  const receipt = freeze({ schema: 'winsmux-observed-required-ci/v1', started_at: started, finished_at: new Date().toISOString(),
    parent_session: parentSession, candidate_identity: bundle.identity, contract_inventory_sha256: contract.inventory_sha256,
    contract_controls_sha256: contract.controls_sha256, workflow_sha256: source.sha256, parser_sha256: parser.sha256,
    python_sha256: python.sha256, parser_native_pid: parsed.pid ?? null, parser_native_exit_code: parsed.status,
    required_checks_inventory_sha256: jobInventory ? sha(Buffer.from(JSON.stringify(jobInventory.names))) : null,
    job_inventory: jobInventory, result, failure, originals, publication_admitted: false,
    required_final_head_checks_verified: false,
    scope: 'Actual public GitHub workflow/attempt and every source-derived required matrix member. CI observation only; no review, native distribution permission, adoption, public dispatch or Windows journey claim.' });
  const file = path.join(directory, 'required-checks.json'), bytes = Buffer.from(JSON.stringify(receipt)); retain(file, bytes);
  observed.set(receipt, { file, sha256: sha(bytes), bytes: Buffer.from(bytes), contract, bundle, parentSession });
  return receipt;
}

export function registerObservedGithubRequiredChecks(registry, receipt) {
  const origin = observed.get(receipt);
  demand(origin && receipt.result.passed === true && receipt.parser_native_exit_code === 0, 'Complete actual CI host observation required.');
  revalidatePublicationBundle(origin.bundle);
  for (const original of receipt.originals) snapshot(original.file, original.sha256);
  return registry.registerObservedOriginal({ file: origin.file, observedSha256: origin.sha256, observeOriginal: bytes => {
    demand(bytes.equals(origin.bytes), 'Actual CI original changed.');
    return { stage: 'adopt', owner_role: 'parent', session: origin.parentSession, result: 'pass',
      candidate_identity: origin.bundle.identity, contract_inventory_sha256: origin.contract.inventory_sha256,
      contract_controls_sha256: origin.contract.controls_sha256, started_at: receipt.started_at, finished_at: receipt.finished_at,
      obligation_ids: [], evidence_names: ['required-checks.json'], expected_actual_verified: true,
      environment_sha256: sha(Buffer.from(JSON.stringify({ endpoint: base, workflow: receipt.workflow_sha256,
        parser: receipt.parser_sha256, python: receipt.python_sha256, python_version: receipt.job_inventory.python_version,
        yaml_version: receipt.job_inventory.yaml_version, api_version: '2026-03-10' }))),
      required_checks_inventory_sha256: receipt.required_checks_inventory_sha256,
      required_final_head_checks_verified: false };
  } });
}
