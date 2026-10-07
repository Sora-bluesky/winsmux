import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { prepareVerifiedNpmCandidate } from '../../scripts/prepare-verified-npm-candidate.mjs';

const trialFile = path.resolve(process.argv[2]);
const trial = JSON.parse(fs.readFileSync(trialFile, 'utf8'));
const root = path.dirname(trialFile), names = ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'];
assert.equal(process.platform, 'win32');
assert.ok(root.includes(`${path.sep}.evidence${path.sep}workspace-package${path.sep}npm-native-`));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const originals = Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(trial.source, name))]));
const output = path.join(root, 'verified-candidate-' + randomUUID()); fs.mkdirSync(output);
const args = ['scripts/prepare-verified-npm-candidate.mjs', '--source', trial.source, '--namespace', output,
  '--npm-cli', trial.npm_cli, '--release-tag', 'v0.38.0'];
let checks = 0;
const check = action => { action(); checks++; };
const execute = (arguments_, basename) => {
  const result = spawnSync(trial.node, arguments_, { encoding: 'utf8', windowsHide: true });
  fs.writeFileSync(path.join(root, basename + '-stdout.txt'), result.stdout ?? '', { flag: 'wx' });
  fs.writeFileSync(path.join(root, basename + '-stderr.txt'), result.stderr ?? '', { flag: 'wx' });
  return result;
};
for (const [label, arguments_] of [['missing', args.slice(0, -2)], ['duplicate', [...args, '--source', trial.source]],
  ['unknown', [...args, '--approved', 'true']], ['other-version', [...args.slice(0, -1), 'v0.38.1']]]) {
  const result = execute(arguments_, 'candidate-refused-' + label);
  check(() => { assert.equal(result.status, 1); assert.equal(result.signal, null); assert.equal(result.stdout, ''); });
  check(() => assert.deepEqual(fs.readdirSync(output), []));
}
const native = execute(args, 'candidate-native');
check(() => { assert.equal(native.status, 0); assert.equal(native.signal, null); assert.equal(native.stderr, ''); });
const receipt = JSON.parse(native.stdout), artifact = path.join(output, 'artifact');
check(() => assert.deepEqual(JSON.parse(fs.readFileSync(path.join(artifact, 'npm-candidate.json'))), receipt));
check(() => assert.deepEqual(fs.readdirSync(artifact).sort(), ['help-stderr.txt', 'help-stdout.txt', 'npm-candidate.json',
  'version-stderr.txt', 'version-stdout.txt', 'winsmux-0.38.0.tgz'].sort()));
check(() => { assert.equal(receipt.publication_admitted, false); assert.equal(receipt.preparation.publication_admitted, false);
  assert.equal(receipt.windows.publication_admitted, false); assert.equal(receipt.preparation.native_exit_code, 0);
  assert.equal(receipt.preparation.npm_version_exit_code, 0); });
const archive = fs.readFileSync(receipt.file);
check(() => { assert.equal(receipt.file, path.join(artifact, 'winsmux-0.38.0.tgz')); assert.equal(sha(archive), receipt.sha256);
  assert.equal(receipt.bytes, archive.length); assert.equal(receipt.sha256, receipt.preparation.sha256);
  assert.equal(receipt.sha256, receipt.windows.sha256);
  assert.deepEqual(archive, fs.readFileSync(receipt.preparation.file)); assert.deepEqual(archive, fs.readFileSync(receipt.windows.file)); });
for (const action of ['help', 'version']) {
  const actual = receipt.windows.results.find(row => row.action === action);
  check(() => { assert.equal(actual.native_exit_code, 0);
    assert.equal(sha(fs.readFileSync(path.join(artifact, action + '-stdout.txt'))), actual.stdout_sha256);
    assert.equal(sha(fs.readFileSync(path.join(artifact, action + '-stderr.txt'))), actual.stderr_sha256); });
}
for (const name of names) {
  check(() => { assert.deepEqual(fs.readFileSync(path.join(trial.source, name)), originals[name]);
    assert.deepEqual(fs.readFileSync(path.join(receipt.windows.extracted_directory, name)), originals[name]);
    assert.equal(receipt.preparation.source_sha256[name], sha(originals[name]));
    assert.equal(receipt.windows.source_sha256[name], sha(originals[name])); });
}
const inventory = fs.readdirSync(path.join(output, 'v0.38.0')).sort();
const second = execute(args, 'candidate-existing-refused');
check(() => { assert.equal(second.status, 1); assert.match(second.stderr, /Fresh empty/u); });
check(() => assert.deepEqual(fs.readdirSync(path.join(output, 'v0.38.0')).sort(), inventory));
check(() => assert.equal(sha(fs.readFileSync(receipt.file)), receipt.sha256));
check(() => assert.throws(() => prepareVerifiedNpmCandidate({ sourceDirectory: trial.source,
  namespaceRoot: output, npmCli: trial.npm_cli, releaseTag: 'v0.38.0' }), /Fresh empty/u));
const workflow = fs.readFileSync('.github/workflows/release-npm.yml', 'utf8');
check(() => { assert.match(workflow, /node scripts\/prepare-verified-npm-candidate\.mjs --source output\/npm-release\/winsmux --namespace output\/npm-candidate --npm-cli \$npmCli/u);
  assert.match(workflow, /name: npm-candidate-\$\{\{ github\.sha \}\}-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/u);
  assert.match(workflow, /path: output\/npm-candidate\/artifact\//u); assert.match(workflow, /if-no-files-found: error/u); });
const result = { observed_at: new Date().toISOString(), passed: true, checks, native_exit_code: native.status,
  npm_sha256: receipt.sha256, npm_bytes: receipt.bytes, candidate_receipt_path: path.join(artifact, 'npm-candidate.json'),
  candidate_receipt_sha256: sha(fs.readFileSync(path.join(artifact, 'npm-candidate.json'))),
  publication_admitted: false, scope: 'Real production CLI: pack once, exact extracted Windows help/version, closed artifact handoff and unchanged archive/source. Workflow source wiring only; no hosted CI, integrated publication cutover or installer mutation proof.' };
fs.writeFileSync(path.join(root, 'verified-candidate-result.json'), JSON.stringify(result), { flag: 'wx' });
console.log(JSON.stringify(result));
