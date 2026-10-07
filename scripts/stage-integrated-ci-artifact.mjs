import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';

// CI preparation only: copy the already-final bytes into a closed upload
// directory. Actual run/source provenance is observed separately by the parent.
// Do not repack, sign, build, download, publish, or reinterpret a status flag here.
const names = Object.freeze({
  core: ['SHA256SUMS', 'winsmux-arm64.exe', 'winsmux-arm64.exe.licenses.zip',
    'winsmux-remote-helper-linux-x64', 'winsmux-x64.exe', 'winsmux-x64.exe.licenses.zip'],
  desktop: ['SHA256SUMS-desktop', 'latest.json', 'winsmux_0.38.0_x64-setup.exe',
    'winsmux_0.38.0_x64-setup.exe.sig', 'winsmux_0.38.0_x64-setup.inventory.json', 'winsmux_0.38.0_x64_en-US.msi'],
  npm: ['winsmux-0.38.0.tgz', 'npm-candidate.json', 'help-stdout.txt', 'help-stderr.txt', 'version-stdout.txt', 'version-stderr.txt'],
});
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const identity = value => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(value[key])).join(':');
function read(file) {
  const target = physicalPath(file), before = fs.lstatSync(target, { bigint: true });
  demand(before.isFile() && before.nlink === 1n && !before.isSymbolicLink(), 'Plain single-link final producer file required.');
  const fd = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(fd, { bigint: true }), bytes = fs.readFileSync(fd), after = fs.fstatSync(fd, { bigint: true });
    demand(identity(before) === identity(held) && identity(held) === identity(after)
      && identity(after) === identity(fs.lstatSync(target, { bigint: true })), 'Producer input changed while read.');
    return { file: target, bytes, sha256: sha(bytes), identity: identity(after) };
  } finally { fs.closeSync(fd); }
}
function closed(directory, expected) {
  const actual = fs.readdirSync(directory).sort();
  demand(JSON.stringify(actual) === JSON.stringify([...expected].sort()), 'Closed final producer directory required.');
  for (const name of actual) {
    const stat = fs.lstatSync(path.join(directory, name), { bigint: true });
    demand(stat.isFile() && stat.nlink === 1n && !stat.isSymbolicLink(), 'Producer directory contains nonplain members.');
  }
}
export function stageIntegratedCiArtifact({ surface, sourceDirectory, releaseBody, namespaceRoot,
  sourceCommit, runId, runAttempt }) {
  demand(Object.hasOwn(names, surface) && /^[a-f0-9]{40}$/u.test(sourceCommit ?? '')
    && /^[1-9][0-9]*$/u.test(String(runId)) && /^[1-9][0-9]*$/u.test(String(runAttempt))
    && Number.isSafeInteger(Number(runId)) && Number.isSafeInteger(Number(runAttempt)), 'Exact v0.38.0 producer coordinates required.');
  demand(surface === 'core' ? typeof releaseBody === 'string' && releaseBody.length > 0 : releaseBody === undefined,
    'Release body belongs only to the Core producer.');
  const source = physicalPath(sourceDirectory), root = physicalPath(namespaceRoot);
  demand(fs.statSync(source).isDirectory() && fs.statSync(root).isDirectory(), 'Existing producer source and owned namespace required.');
  demand(root !== source && !root.startsWith(source + path.sep), 'Artifact output must be outside producer inputs.');
  closed(source, names[surface]);
  const input = new Map(names[surface].map(name => [name, read(path.join(source, name))]));
  if (surface === 'core') input.set('release-body.md', read(releaseBody));
  for (const [name, value] of input) demand(value.bytes.length > 0 || name.endsWith('-stderr.txt'), 'Empty required final producer asset.');
  if (surface === 'core' || surface === 'desktop') {
    const checksumName = surface === 'core' ? 'SHA256SUMS' : 'SHA256SUMS-desktop';
    const expected = [...input].filter(([name]) => name !== checksumName && name !== 'release-body.md')
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([name, value]) => `${value.sha256}  ${name}\n`).join('');
    demand(input.get(checksumName).bytes.equals(Buffer.from(expected)), 'Final producer checksums differ from uploaded bytes.');
  }
  const directory = path.join(root, 'artifact-' + randomUUID()); fs.mkdirSync(directory);
  const pending = path.join(directory, '.pending'); fs.writeFileSync(pending, 'CI preparation incomplete\n', { flag: 'wx' });
  for (const [name, value] of input) {
    const fd = fs.openSync(path.join(directory, name), 'wx');
    try { fs.writeFileSync(fd, value.bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  }
  closed(directory, [...input.keys(), '.pending']);
  for (const [name, value] of input) {
    const original = read(value.file), copy = read(path.join(directory, name));
    demand(original.identity === value.identity && original.sha256 === value.sha256 && copy.sha256 === value.sha256,
      'Final producer input or artifact copy changed.');
  }
  closed(source, names[surface]);
  fs.unlinkSync(pending); closed(directory, [...input.keys()]);
  const artifactName = (surface === 'npm' ? 'npm-candidate-' : 'integrated-' + surface + '-')
    + sourceCommit + '-' + runId + '-' + runAttempt;
  return Object.freeze({ schema: 'winsmux-staged-ci-artifact/v1', surface, version: '0.38.0', source_commit: sourceCommit,
    producer_run: runId + '.' + runAttempt, artifact_path: directory, artifact_name: artifactName,
    files: [...input].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([name, value]) => ({ path: name, bytes: value.bytes.length, sha256: value.sha256 })),
    source_provenance_verified: false, publication_admitted: false });
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2), values = {}, keys = ['--surface', '--source', '--namespace', '--source-commit', '--run-id', '--run-attempt'];
    for (let index = 0; index < args.length; index += 2) {
      const key = args[index], value = args[index + 1];
      demand([...keys, '--release-body'].includes(key) && !Object.hasOwn(values, key) && value && !value.startsWith('--'), 'Exact nonduplicate CI preparation arguments required.');
      values[key] = value;
    }
    demand(keys.every(key => key in values), 'All fixed producer inputs required.');
    const result = stageIntegratedCiArtifact({ surface: values['--surface'], sourceDirectory: values['--source'],
      namespaceRoot: values['--namespace'], sourceCommit: values['--source-commit'], runId: values['--run-id'],
      runAttempt: values['--run-attempt'], releaseBody: values['--release-body'] });
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT,
      `artifact_path=${result.artifact_path}\nartifact_name=${result.artifact_name}\n`);
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
