import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { stageIntegratedCiArtifact } from '../../scripts/stage-integrated-ci-artifact.mjs';
import { publicationFixture, sha } from './publication-fixture.mjs';

assert.ok(process.argv[2] && process.argv[3], 'Operator originals and actual Python executable required.');
const fixture = publicationFixture(process.argv[2]), root = fixture.root;
const names = ['scripts/stage-integrated-ci-artifact.mjs', 'tests/workspace-package/stage-ci-artifact.test.mjs',
  'scripts/distribution-prelaunch.mjs', 'scripts/integrated-publication-contract.mjs', 'scripts/integrated-publication-assets.mjs',
  'scripts/assert-license-inputs.mjs', 'tests/workspace-package/publication-fixture.mjs',
  '.github/workflows/release-core.yml', '.github/workflows/release-desktop.yml'];
const before = Object.fromEntries(names.map(name => [name, sha(fs.readFileSync(name))]));
const namespace = path.join(root, 'staged'); fs.mkdirSync(namespace);
let checks = 0;
const check = action => { action(); checks++; };
const sourceCommit = '1'.repeat(40), runId = '11', runAttempt = '2';
for (const surface of ['core', 'desktop', 'npm']) {
  const sourceDirectory = path.join(root, surface); fs.mkdirSync(sourceDirectory);
  for (const [name, bytes] of fixture.files) if (name.startsWith(surface + '/')) fs.writeFileSync(path.join(sourceDirectory, path.posix.basename(name)), bytes);
  if (surface === 'npm') for (const name of ['npm-candidate.json', 'help-stdout.txt', 'help-stderr.txt', 'version-stdout.txt', 'version-stderr.txt'])
    fs.writeFileSync(path.join(sourceDirectory, name), name.endsWith('-stderr.txt') ? '' : 'synthetic native producer log\n');
  const releaseBody = surface === 'core' ? path.join(fixture.bundle.root, 'release-body.md') : undefined;
  const input = { surface, sourceDirectory, releaseBody, namespaceRoot: namespace, sourceCommit, runId, runAttempt };
  const original = Object.fromEntries(fs.readdirSync(sourceDirectory).map(name => [name, sha(fs.readFileSync(path.join(sourceDirectory, name)))]));
  const result = stageIntegratedCiArtifact(input);
  check(() => {
    assert.equal(result.publication_admitted, false); assert.equal(result.source_provenance_verified, false);
    assert.equal(result.producer_run, '11.2'); assert.equal(result.version, '0.38.0');
    assert.equal(result.artifact_name, (surface === 'npm' ? 'npm-candidate-' : 'integrated-' + surface + '-') + sourceCommit + '-11-2');
    assert.deepEqual(fs.readdirSync(result.artifact_path).sort(), result.files.map(row => row.path).sort());
  });
  for (const file of result.files) check(() => {
    const bytes = fs.readFileSync(path.join(result.artifact_path, file.path));
    assert.equal(bytes.length, file.bytes); assert.equal(sha(bytes), file.sha256);
    assert.equal(file.sha256, file.path === 'release-body.md' ? sha(fs.readFileSync(releaseBody)) : original[file.path]);
  });
  const repeated = stageIntegratedCiArtifact(input);
  check(() => { assert.notEqual(result.artifact_path, repeated.artifact_path); assert.deepEqual(result.files, repeated.files); });
  for (const mutation of [{ surface: 'elsewhere' }, { sourceCommit: '' }, { runId: '0' }, { runId: '01' },
    { runId: '9007199254740992' }, { runAttempt: '-1' }, { runAttempt: '1.5' }, { namespaceRoot: sourceDirectory },
    { releaseBody: surface === 'core' ? undefined : path.join(fixture.bundle.root, 'release-body.md') }]) {
    const current = fs.readdirSync(namespace);
    check(() => { assert.throws(() => stageIntegratedCiArtifact({ ...input, ...mutation })); assert.deepEqual(fs.readdirSync(namespace), current); });
  }
  const extra = path.join(sourceDirectory, 'extra.txt'); fs.writeFileSync(extra, 'stray');
  check(() => assert.throws(() => stageIntegratedCiArtifact(input), /Closed final producer directory/u)); fs.unlinkSync(extra);
  const first = surface === 'core' ? 'winsmux-x64.exe' : surface === 'desktop' ? 'latest.json' : 'winsmux-0.38.0.tgz';
  const file = path.join(sourceDirectory, first), originalBytes = fs.readFileSync(file); fs.unlinkSync(file);
  check(() => assert.throws(() => stageIntegratedCiArtifact(input), /Closed final producer directory/u)); fs.writeFileSync(file, originalBytes);
  const link = path.join(root, surface + '-hardlink'); fs.linkSync(file, link);
  check(() => assert.throws(() => stageIntegratedCiArtifact(input), /nonplain members/u)); fs.unlinkSync(link);
  fs.writeFileSync(file, '');
  check(() => assert.throws(() => stageIntegratedCiArtifact(input), /Empty required final producer asset/u)); fs.writeFileSync(file, originalBytes);
  if (surface !== 'npm') {
    const checksum = path.join(sourceDirectory, surface === 'core' ? 'SHA256SUMS' : 'SHA256SUMS-desktop');
    const bytes = fs.readFileSync(checksum); fs.writeFileSync(checksum, 'wrong checksum\n');
    check(() => assert.throws(() => stageIntegratedCiArtifact(input), /checksums differ/u)); fs.writeFileSync(checksum, bytes);
  }
  const output = path.join(root, surface + '-github-output.txt'); fs.writeFileSync(output, '');
  const env = { ...process.env, GITHUB_OUTPUT: output };
  const args = ['scripts/stage-integrated-ci-artifact.mjs', '--surface', surface, '--source', sourceDirectory,
    '--namespace', namespace, '--source-commit', sourceCommit, '--run-id', runId, '--run-attempt', runAttempt];
  if (surface === 'core') args.push('--release-body', releaseBody);
  const actual = spawnSync(process.execPath, args, { env, windowsHide: true });
  fs.writeFileSync(path.join(root, surface + '-cli-stdout.json'), actual.stdout); fs.writeFileSync(path.join(root, surface + '-cli-stderr.txt'), actual.stderr);
  check(() => {
    assert.equal(actual.status, 0); assert.equal(actual.signal, null); assert.equal(actual.stderr.length, 0);
    const receipt = JSON.parse(actual.stdout), native = fs.readFileSync(output, 'utf8');
    assert.equal(receipt.publication_admitted, false); assert.equal(receipt.source_provenance_verified, false);
    assert.equal(native, `artifact_path=${receipt.artifact_path}\nartifact_name=${receipt.artifact_name}\n`);
    assert.deepEqual(receipt.files, result.files);
  });
  const outputBefore = fs.readFileSync(output), dirsBefore = fs.readdirSync(namespace);
  for (const suffix of [['--run-id', '99'], ['--approved', 'true'], ['--run-attempt']]) {
    const failed = spawnSync(process.execPath, [...args, ...suffix], { env, windowsHide: true });
    check(() => { assert.equal(failed.status, 1); assert.equal(failed.stdout.length, 0);
      assert.deepEqual(fs.readFileSync(output), outputBefore); assert.deepEqual(fs.readdirSync(namespace), dirsBefore); });
  }
  for (const [name, digest] of Object.entries(original)) check(() => assert.equal(sha(fs.readFileSync(path.join(sourceDirectory, name))), digest));
}
// Actual YAML parsing also checks ordering: final bytes and release body are
// staged/uploaded before the old guarded public entrance. No hosted CI claim.
const workflowCheck = `import sys,yaml,json
core=yaml.safe_load(open('.github/workflows/release-core.yml',encoding='utf-8'))['jobs']['release']['steps']
desktop=yaml.safe_load(open('.github/workflows/release-desktop.yml',encoding='utf-8'))['jobs']['build']['steps']
for steps,surface in [(core,'Core'),(desktop,'Desktop')]:
 stage=next(i for i,s in enumerate(steps) if s.get('name')=='Stage final integrated '+surface+' artifact')
 upload=next(i for i,s in enumerate(steps) if s.get('name')=='Upload final integrated '+surface+' artifact')
 assert stage<upload and 'stage-integrated-ci-artifact.mjs' in steps[stage]['run']
 assert steps[upload]['with']['name']=='\u0024{{ steps.integrated.outputs.artifact_name }}'
 assert steps[upload]['with']['path']=='\u0024{{ steps.integrated.outputs.artifact_path }}/'
 assert steps[upload]['with']['if-no-files-found']=='error'
 if surface=='Core': assert upload<next(i for i,s in enumerate(steps) if s.get('name')=='Require integrated publication gate')
 else: assert upload<next(i for i,s in enumerate(steps) if s.get('name')=='Upload desktop bundles to release')
print(json.dumps({'parsed':True,'surfaces':2,'publication_admitted':False}))
`;
const yaml = spawnSync(path.resolve(process.argv[3]), ['-I', '-B', '-c', workflowCheck], { windowsHide: true });
fs.writeFileSync(path.join(root, 'workflow-stdout.json'), yaml.stdout); fs.writeFileSync(path.join(root, 'workflow-stderr.txt'), yaml.stderr);
check(() => { assert.equal(yaml.status, 0); assert.equal(yaml.signal, null); assert.equal(yaml.stderr.length, 0); assert.equal(JSON.parse(yaml.stdout).surfaces, 2); });
for (const name of names) check(() => assert.equal(sha(fs.readFileSync(name)), before[name]));
const result = { observed_at: new Date().toISOString(), passed: true, checks, native_cli_surfaces: 3,
  native_yaml_exit_code: yaml.status, source_sha256: before, publication_admitted: false,
  scope: 'Actual staging/CLI and YAML wiring over synthetic final Core/Desktop/npm bytes. Closed uploads and SHA/readback preservation; no native build, hosted producer execution, public entrance cutover or authority claim.' };
const file = path.join(root, 'ci-staging-target-result.json'); fs.writeFileSync(file, JSON.stringify(result), { flag: 'wx' });
console.log(JSON.stringify({ ...result, original_result_path: file }));
