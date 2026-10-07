import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { validateGithubRequiredChecksPayload, registerObservedGithubRequiredChecks } from '../../scripts/observe-github-required-checks.mjs';

assert.ok(process.argv[2], 'Actual Python executable required.');
const python = path.resolve(process.argv[2]), parser = path.resolve('scripts/read-required-ci-jobs.py');
const root = path.resolve('.evidence/workspace-package', 'ci-observer-' + randomUUID()); fs.mkdirSync(root, { recursive: true });
const workflowFile = path.resolve('.github/workflows/test.yml'), bytes = fs.readFileSync(workflowFile);
const sha = value => createHash('sha256').update(value).digest('hex');
const sourceNames = ['scripts/observe-github-required-checks.mjs', 'scripts/read-required-ci-jobs.py',
  'tests/workspace-package/github-required-checks.test.mjs', '.github/workflows/test.yml'];
const sources = Object.fromEntries(sourceNames.map(name => [name, sha(fs.readFileSync(name))]));
const derive = (file, expected, label) => {
  const process_ = spawnSync(python, ['-I', '-B', parser, file, expected], { windowsHide: true });
  fs.writeFileSync(path.join(root, label + '-stdout.json'), process_.stdout ?? Buffer.alloc(0), { flag: 'wx' });
  fs.writeFileSync(path.join(root, label + '-stderr.txt'), process_.stderr ?? Buffer.alloc(0), { flag: 'wx' });
  return process_;
};
const native = derive(workflowFile, sha(bytes), 'actual-inventory');
assert.equal(native.status, 0); assert.equal(native.signal, null); assert.equal(native.stderr.length, 0);
const jobInventory = JSON.parse(native.stdout), base = 'https://api.github.com/repos/Sora-bluesky/winsmux';
const names = Object.values(jobInventory.names).flat();
const input = { sourceCommit: '1'.repeat(40), sourceTree: '2'.repeat(40), workflowSha256: sha(bytes), jobInventory,
  commit: { sha: '1'.repeat(40), tree: { sha: '2'.repeat(40) } },
  workflow: { type: 'file', path: '.github/workflows/test.yml', encoding: 'base64', content: bytes.toString('base64'),
    sha: createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes])).digest('hex') },
  run: { id: 501, run_attempt: 2, head_sha: '1'.repeat(40), path: '.github/workflows/test.yml',
    repository: { full_name: 'Sora-bluesky/winsmux' }, head_repository: { full_name: 'Sora-bluesky/winsmux' },
    url: base + '/actions/runs/501', status: 'completed', conclusion: 'success' },
  jobs: names.map((name, index) => ({ id: index + 601, run_id: 501, run_url: base + '/actions/runs/501',
    head_sha: '1'.repeat(40), url: base + '/actions/jobs/' + (index + 601), name, status: 'completed', conclusion: 'success' })),
  jobsTotal: names.length };
let checks = 0;
const check = action => { action(); checks++; };
const validate = value => validateGithubRequiredChecksPayload(value ?? input);
check(() => { const result = validate(); assert.equal(result.passed, true); assert.equal(result.required_categories, 13);
  assert.equal(result.required_jobs, 42); assert.equal(result.publication_admitted, false);
  assert.equal(jobInventory.names.pester.length, 26); assert.equal(jobInventory.names['install-e2e'].length, 3);
  assert.equal(jobInventory.names['helper-linux-negatives'].length, 2); });
for (let index = 0; index < names.length; index++) {
  const value = structuredClone(input); value.jobs.splice(index, 1); value.jobsTotal--;
  check(() => assert.throws(() => validate(value), /matrix member missing/u));
  for (const conclusion of ['failure', 'skipped', 'cancelled']) {
    const changed = structuredClone(input); changed.jobs[index].conclusion = conclusion;
    check(() => assert.equal(validate(changed).passed, false));
  }
  const changed = structuredClone(input); changed.jobs[index].status = 'in_progress';
  check(() => assert.equal(validate(changed).passed, false));
}
for (const change of [ value => { value.commit.sha = '3'.repeat(40); }, value => { value.commit.tree.sha = '3'.repeat(40); },
  value => { value.workflow.path = '.github/workflows/other.yml'; }, value => { value.workflow.encoding = 'raw'; },
  value => { value.workflow.content += '!'; }, value => { value.workflow.content = Buffer.from('changed').toString('base64'); },
  value => { value.workflow.sha = '3'.repeat(40); }, value => { value.run.head_sha = '3'.repeat(40); },
  value => { value.run.path = '.github/workflows/other.yml'; }, value => { value.run.repository.full_name = 'other/winsmux'; },
  value => { value.run.head_repository.full_name = 'fork/winsmux'; }, value => { value.run.url += '/elsewhere'; },
  value => { value.run.run_attempt = 0; }, value => { value.jobsTotal++; }, value => { value.jobs[0] = value.jobs[1]; },
  value => { value.jobs[0].run_id = 99; }, value => { value.jobs[0].head_sha = '3'.repeat(40); },
  value => { value.jobs[0].run_url += '/other'; }, value => { value.jobs[0].url += '/other'; },
  value => { value.jobs[0].id = 0; }, value => { value.jobInventory.required_categories.pop(); },
  value => { value.jobInventory.workflow_sha256 = '0'.repeat(64); }, value => { value.jobInventory.required_job_count--; },
  value => { value.jobs.push({ ...value.jobs[0], id: 990, url: base + '/actions/jobs/990' }); value.jobsTotal++; } ]) {
  const value = structuredClone(input); change(value); check(() => assert.throws(() => validate(value)));
}
for (const conclusion of [null, 'failure', 'skipped', 'timed_out']) {
  const value = structuredClone(input); value.run.conclusion = conclusion;
  check(() => assert.equal(validate(value).passed, false));
}
for (const forged of [validate(), { result: { passed: true }, parser_native_exit_code: 0, approved: true },
  JSON.parse(JSON.stringify(validate())), { ...validate(), required_final_head_checks_verified: true }]) {
  check(() => assert.throws(() => registerObservedGithubRequiredChecks({}, forged), /actual CI host observation/u));
}
const block = bytes.toString('utf8'), merge = block.lastIndexOf('\n  merge-gate:\n');
assert.ok(merge >= 0);
for (const [label, modified] of [
  ['duplicate-root', block + '\njobs: {}\n'],
  ['missing-needed', block.slice(0, merge) + block.slice(merge).replace('      - secret-scan\n', '')],
  ['duplicate-pester-name', block.replace('- name: bridge-agent-orchestra', '- name: bridge-foundation')],
  ['unresolved-matrix', block.replace('Pester Tests (${{ matrix.name }})', 'Pester Tests (${{ github.unreviewed }})')]]) {
  const file = path.join(root, label + '.yml'); fs.writeFileSync(file, modified, { flag: 'wx' });
  const failed = derive(file, sha(Buffer.from(modified)), label);
  check(() => { assert.equal(failed.status, 1); assert.equal(failed.stdout.length, 0); assert.ok(failed.stderr.length > 0); });
}
const mismatch = derive(workflowFile, '0'.repeat(64), 'wrong-workflow-sha');
check(() => { assert.equal(mismatch.status, 1); assert.match(mismatch.stderr.toString('utf8'), /differs from observed/u); });
for (const name of sourceNames) check(() => assert.equal(sha(fs.readFileSync(name)), sources[name]));
const result = { observed_at: new Date().toISOString(), passed: true, checks, native_parser_exit_code: native.status,
  required_categories: 13, required_jobs: 42, python_sha256: sha(fs.readFileSync(python)), source_sha256: sources,
  publication_admitted: false, scope: 'Native frozen workflow parser and all 42 synthetic API job cases; missing matrix members, failed/skipped/in-progress states, source/attempt identity and JSON observation forgery refusals. No real hosted CI success or final-head approval.' };
fs.writeFileSync(path.join(root, 'ci-observer-target-result.json'), JSON.stringify(result), { flag: 'wx' });
console.log(JSON.stringify({ ...result, original_result_path: path.join(root, 'ci-observer-target-result.json') }));
