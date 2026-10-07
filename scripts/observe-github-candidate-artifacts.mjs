import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';

// Protected outcome: all thirteen final bytes originate in the exact frozen
// Core/Desktop/npm producer runs. A status flag, local hash manifest, another
// attempt's archive or a source-only CI success cannot establish this origin.
// This observer never downloads authenticated artifacts, extracts files,
// executes member contents, publishes, or grants native distribution permission.
const repository = 'Sora-bluesky/winsmux';
const base = 'https://api.github.com/repos/' + repository;
const surfaces = ['core', 'desktop', 'npm'];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const number = value => Number.isSafeInteger(value) && value > 0;
const issued = new WeakMap();
const freeze = value => { if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && same(Object.keys(value).sort(), [...keys].sort());
const coordinates = run => [run.id, run.run_attempt, run.head_sha, run.status, run.conclusion, run.updated_at, run.run_started_at];
const artifactCoordinates = value => [value.id, value.name, value.digest, value.expired, value.url,
  value.archive_download_url, value.created_at, value.updated_at, value.expires_at,
  value.workflow_run?.id, value.workflow_run?.head_sha, value.workflow_run?.repository_id, value.workflow_run?.head_repository_id];

function snapshot(file, expected) {
  demand(hash(expected), 'Independent frozen file digest required.');
  const target = physicalPath(file), before = fs.lstatSync(target, { bigint: true });
  demand(before.isFile() && before.nlink === 1n && !before.isSymbolicLink(), 'Plain single-link artifact input required.');
  const identity = value => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(value[key])).join(':');
  const fd = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(fd, { bigint: true }), checksum = createHash('sha256'), buffer = Buffer.alloc(65536);
    let count;
    while ((count = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) checksum.update(buffer.subarray(0, count));
    const after = fs.fstatSync(fd, { bigint: true }), named = fs.lstatSync(target, { bigint: true });
    demand(identity(before) === identity(held) && identity(held) === identity(after) && identity(after) === identity(named)
      && checksum.digest('hex') === expected, 'Artifact input differs from independent observation.');
    return { target, identity: identity(after), sha256: expected };
  } finally { fs.closeSync(fd); }
}
function retain(file, bytes) {
  const fd = fs.openSync(file, 'wx');
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function producer(bundle, surface) {
  const run = bundle.producers[surface]?.run;
  demand(typeof run === 'string' && /^[1-9][0-9]*\.[1-9][0-9]*$/u.test(run), 'Exact GitHub producer run.attempt required.');
  const [id, attempt] = run.split('.').map(Number);
  demand(number(id) && number(attempt), 'Safe positive producer coordinates required.');
  return { id, attempt };
}
export function candidateArtifactMembers(bundle, surface) {
  assertIssuedPublicationBundle(bundle);
  demand(surfaces.includes(surface), 'Fixed integrated producer surface required.');
  const rows = bundle.assets.filter(row => row.path.startsWith(surface + '/') || (surface === 'core' && row.path === 'release-body.md'))
    .map(row => ({ name: path.posix.basename(row.path), bytes: row.bytes, sha256: row.sha256 }));
  // The npm artifact also retains the actual Windows producer's native logs.
  // Their presence is required, but it does not itself prove the Windows gate.
  if (surface === 'npm') for (const name of ['npm-candidate.json', 'help-stdout.txt', 'help-stderr.txt', 'version-stdout.txt', 'version-stderr.txt'])
    rows.push({ name, bytes: null, sha256: null });
  return freeze(rows.sort((a, b) => a.name.localeCompare(b.name, 'en')));
}
function artifactName(surface, head, runId, attempt) {
  return (surface === 'npm' ? 'npm-candidate-' : 'integrated-' + surface + '-') + head + '-' + runId + '-' + attempt;
}

/** Pure original-body validation: never creates observed origin or authority. */
export function validateGithubCandidateArtifactPayload({ surface, sourceCommit, sourceTree, runId, runAttempt,
  workflowSha256, archiveSha256, commit, workflow, run, artifact }) {
  demand(surfaces.includes(surface) && number(runId) && number(runAttempt) && hash(workflowSha256) && hash(archiveSha256)
    && /^[a-f0-9]{40}$/u.test(sourceCommit ?? '') && /^[a-f0-9]{40}$/u.test(sourceTree ?? ''),
    'Exact producer and frozen digest coordinates required.');
  validateProducerSource({ surface, sourceCommit, sourceTree, workflowSha256, commit, workflow });
  const workflowPath = '.github/workflows/release-' + surface + '.yml';
  demand(run?.id === runId && run.run_attempt === runAttempt && run.head_sha === sourceCommit
    && (run.path === workflowPath || (typeof run.path === 'string' && run.path.startsWith(workflowPath + '@')
      && run.path.length > workflowPath.length + 1 && !/\s/u.test(run.path)))
    && run.repository?.full_name?.toLowerCase() === repository.toLowerCase()
    && run.head_repository?.full_name?.toLowerCase() === repository.toLowerCase()
    && number(run.repository?.id) && run.head_repository?.id === run.repository.id
    && run.url === `${base}/actions/runs/${runId}` && run.status === 'completed' && run.conclusion === 'success',
    'Exact successful producer workflow run/attempt required.');
  const started = Date.parse(run.run_started_at), updated = Date.parse(run.updated_at), created = Date.parse(artifact?.created_at);
  demand(Number.isFinite(started) && Number.isFinite(updated) && Number.isFinite(created) && started <= created && created <= updated,
    'Artifact creation belongs outside the completed producer attempt.');
  demand(number(artifact?.id) && artifact.name === artifactName(surface, sourceCommit, runId, runAttempt)
    && artifact.expired === false && artifact.digest === 'sha256:' + archiveSha256
    && artifact.url === `${base}/actions/artifacts/${artifact.id}` && artifact.archive_download_url === artifact.url + '/zip'
    && artifact.workflow_run?.id === runId && artifact.workflow_run.head_sha === sourceCommit
    && artifact.workflow_run.repository_id === run.repository.id && artifact.workflow_run.head_repository_id === run.head_repository.id,
    'Original artifact digest, attempt name or repository differs.');
  return freeze({ surface, run_id: runId, run_attempt: runAttempt, artifact_id: artifact.id,
    archive_sha256: archiveSha256, publication_admitted: false });
}
function validateProducerSource({ surface, sourceCommit, sourceTree, workflowSha256, commit, workflow }) {
  const workflowPath = '.github/workflows/release-' + surface + '.yml';
  demand(commit?.sha === sourceCommit && commit.tree?.sha === sourceTree, 'Artifact source commit/tree differs.');
  demand(workflow?.path === workflowPath && workflow.type === 'file' && workflow.encoding === 'base64'
    && typeof workflow.content === 'string', 'Original producer workflow required.');
  const encoded = workflow.content.replaceAll('\n', '');
  demand(/^[A-Za-z0-9+/]*={0,2}$/u.test(encoded) && encoded.length % 4 === 0, 'Invalid producer workflow encoding.');
  const bytes = Buffer.from(encoded, 'base64');
  demand(bytes.toString('base64') === encoded && sha(bytes) === workflowSha256
    && createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`), bytes])).digest('hex') === workflow.sha,
    'Producer workflow differs from frozen source.');
}
function getOriginal(endpoint) {
  return new Promise((resolve, reject) => {
    const url = base + endpoint;
    const request = https.get(url, { rejectUnauthorized: true, headers: { Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'winsmux-release-verifier' } }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk)); response.on('error', reject);
      response.on('end', () => resolve({ url, status: response.statusCode, bytes: Buffer.concat(chunks), server_date: response.headers.date ?? null }));
    }); request.on('error', reject);
  });
}

/** Parent host observes real public originals. Locally supplied archives and
 * hashes are candidate inputs, checked against independent GitHub originals.
 * No fetch callback or serialized observer is accepted as an origin. */
export async function observeGithubCandidateArtifacts(contract, bundle, { namespaceRoot, parentSession, workflows,
  archives, pythonImage, observedPythonSha256, parserFile, observedParserSha256 }) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  demand(typeof parentSession === 'string' && parentSession.trim() === parentSession && parentSession.length > 0, 'Actual host session required.');
  demand(exact(workflows, surfaces) && exact(archives, surfaces), 'All three producer source/archive inputs required.');
  const coordinates_ = Object.fromEntries(surfaces.map(surface => [surface, producer(bundle, surface)]));
  const inputs = [snapshot(pythonImage, observedPythonSha256), snapshot(parserFile, observedParserSha256)];
  const workflowSources = {}, archiveSources = {};
  for (const surface of surfaces) {
    demand(exact(workflows[surface], ['file', 'observed_sha256']) && exact(archives[surface], ['file', 'observed_sha256']),
      'Exact independently observed producer inputs required.');
    workflowSources[surface] = snapshot(workflows[surface].file, workflows[surface].observed_sha256);
    archiveSources[surface] = snapshot(archives[surface].file, archives[surface].observed_sha256);
    inputs.push(workflowSources[surface], archiveSources[surface]);
  }
  const root = physicalPath(namespaceRoot); demand(fs.statSync(root).isDirectory(), 'Existing owned artifact observation namespace required.');
  const directory = path.join(root, 'ci-artifacts-' + randomUUID()); fs.mkdirSync(directory);
  const started = new Date().toISOString(), originals = [], results = [], native = [];
  const environment = { PATH: process.env.PATH ?? path.dirname(inputs[0].target) };
  for (const key of ['SystemRoot', 'WINDIR', 'COMSPEC']) if (process.env[key]) environment[key] = process.env[key];
  const fetch = async (endpoint, name) => {
    const original = await getOriginal(endpoint), file = path.join(directory, name); retain(file, original.bytes);
    originals.push({ file, url: original.url, status: original.status, sha256: sha(original.bytes), server_date: original.server_date });
    demand(original.status === 200, 'Actual producer original unavailable: HTTP ' + original.status);
    return parseStrictJson(original.bytes);
  };
  let failure = null;
  try {
    const commit = await fetch('/git/commits/' + bundle.identity.source_commit, 'commit.json');
    for (const surface of surfaces) {
      const { id, attempt } = coordinates_[surface];
      const workflow = await fetch('/contents/.github/workflows/release-' + surface + '.yml?ref=' + bundle.identity.source_commit, surface + '-workflow.json');
      validateProducerSource({ surface, sourceCommit: bundle.identity.source_commit, sourceTree: bundle.identity.source_tree,
        workflowSha256: workflowSources[surface].sha256, commit, workflow });
      const run = await fetch('/actions/runs/' + id, surface + '-run-before.json');
      const artifacts = [], ids = new Set(); let total = null;
      for (let page = 1; total === null || artifacts.length < total; page++) {
        const data = await fetch(`/actions/runs/${id}/artifacts?per_page=100&page=${page}`, surface + '-artifacts-' + page + '.json');
        demand(Number.isSafeInteger(data.total_count) && data.total_count >= 0 && Array.isArray(data.artifacts)
          && (total === null || total === data.total_count), 'Producer artifact pagination changed or incomplete.');
        total = data.total_count;
        demand(data.artifacts.length > 0 || artifacts.length === total, 'Producer artifact inventory incomplete.');
        for (const artifact of data.artifacts) { demand(number(artifact.id) && !ids.has(artifact.id), 'Duplicate original artifact identity.'); ids.add(artifact.id); artifacts.push(artifact); }
        demand(artifacts.length <= total, 'Artifact inventory exceeds declared total.');
      }
      const matches = artifacts.filter(row => row.name === artifactName(surface, bundle.identity.source_commit, id, attempt));
      demand(matches.length === 1, 'Exact producer attempt artifact missing or ambiguous.');
      const artifact = matches[0];
      const verified = validateGithubCandidateArtifactPayload({ surface, sourceCommit: bundle.identity.source_commit,
        sourceTree: bundle.identity.source_tree, runId: id, runAttempt: attempt, workflowSha256: workflowSources[surface].sha256,
        archiveSha256: archiveSources[surface].sha256, commit, workflow, run, artifact });
      const members = candidateArtifactMembers(bundle, surface), memberFile = path.join(directory, surface + '-members.json');
      retain(memberFile, Buffer.from(JSON.stringify(members)));
      const parsed = spawnSync(inputs[0].target, ['-I', '-B', inputs[1].target, archiveSources[surface].target,
        verified.archive_sha256, memberFile], { env: environment, windowsHide: true });
      retain(path.join(directory, surface + '-parser-stdout.json'), parsed.stdout ?? Buffer.alloc(0));
      retain(path.join(directory, surface + '-parser-stderr.txt'), parsed.stderr ?? Buffer.alloc(0));
      native.push({ surface, pid: parsed.pid ?? null, exit_code: parsed.status, signal: parsed.signal });
      demand(!parsed.error && parsed.status === 0 && parsed.signal === null && (parsed.stderr?.length ?? 0) === 0,
        'Native closed artifact member verification failed.');
      const actual = parseStrictJson(parsed.stdout);
      demand(actual.schema === 'winsmux-ci-artifact-members/v1' && actual.archive_sha256 === verified.archive_sha256
        && actual.publication_admitted === false && Array.isArray(actual.members) && actual.members.length === members.length
        && same(actual.members.map(row => row.name).sort(), members.map(row => row.name).sort()), 'Native artifact member inventory differs.');
      for (const member of members) if (member.sha256 !== null) {
        const seen = actual.members.find(row => row.name === member.name);
        demand(seen.bytes === member.bytes && seen.sha256 === member.sha256 && seen.bundle_member === true,
          'Native artifact member differs from held bundle.');
      }
      const artifactAfter = await fetch('/actions/artifacts/' + artifact.id, surface + '-artifact-after.json');
      const runAfter = await fetch('/actions/runs/' + id, surface + '-run-after.json');
      validateGithubCandidateArtifactPayload({ surface, sourceCommit: bundle.identity.source_commit,
        sourceTree: bundle.identity.source_tree, runId: id, runAttempt: attempt, workflowSha256: workflowSources[surface].sha256,
        archiveSha256: archiveSources[surface].sha256, commit, workflow, run: runAfter, artifact: artifactAfter });
      demand(same(artifactCoordinates(artifact), artifactCoordinates(artifactAfter)) && same(coordinates(run), coordinates(runAfter)),
        'Producer artifact/run changed during observation.');
      results.push({ ...verified, members: actual.members });
    }
  } catch (error) { failure = error.message; }
  for (const before of inputs) demand(snapshot(before.target, before.sha256).identity === before.identity, 'Producer archive/source/runtime changed.');
  revalidatePublicationBundle(bundle);
  const receipt = freeze({ schema: 'winsmux-observed-candidate-artifacts/v1', started_at: started, finished_at: new Date().toISOString(),
    parent_session: parentSession, candidate_identity: bundle.identity, contract_inventory_sha256: contract.inventory_sha256,
    contract_controls_sha256: contract.controls_sha256, passed: failure === null && results.length === surfaces.length, failure,
    results, native, originals, sources: inputs, publication_admitted: false,
    scope: 'Actual producer API provenance, archive digest and closed member correspondence. No native permission, Windows journey, full mandatory verification, review, adoption or publication claim.' });
  const file = path.join(directory, 'candidate-artifact-hashes.json'), bytes = Buffer.from(JSON.stringify(receipt)); retain(file, bytes);
  issued.set(receipt, { file, bytes: Buffer.from(bytes), contract, bundle, parentSession, inputs });
  return receipt;
}
export function registerObservedGithubCandidateArtifacts(registry, receipt) {
  const origin = issued.get(receipt);
  demand(origin && receipt.passed === true && receipt.native.length === 3 && receipt.native.every(row => row.exit_code === 0 && row.signal === null),
    'Complete actual producer artifact observation required.');
  revalidatePublicationBundle(origin.bundle);
  for (const input of origin.inputs) demand(snapshot(input.target, input.sha256).identity === input.identity, 'Observed producer input changed.');
  for (const original of receipt.originals) snapshot(original.file, original.sha256);
  return registry.registerObservedOriginal({ file: origin.file, observedSha256: sha(origin.bytes), observeOriginal: bytes => {
    demand(bytes.equals(origin.bytes), 'Actual producer observation original changed.');
    return { stage: 'prepare', owner_role: 'high-risk-implementer', session: origin.parentSession, result: 'pass',
      candidate_identity: origin.bundle.identity, contract_inventory_sha256: origin.contract.inventory_sha256,
      contract_controls_sha256: origin.contract.controls_sha256, started_at: receipt.started_at, finished_at: receipt.finished_at,
      obligation_ids: [], evidence_names: ['candidate-artifact-hashes.json'], expected_actual_verified: true,
      environment_sha256: sha(Buffer.from(JSON.stringify({ endpoint: base, inputs: origin.inputs, api_version: '2026-03-10' }))) };
  } });
}
