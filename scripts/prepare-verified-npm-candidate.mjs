import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';
import { prepareNpmReleaseTarball, verifyPreparedNpmWindowsEntrypoint } from './prepare-integrated-npm-tarball.mjs';

const names = ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

// A producer receipt is an observation, never an approval. The integration
// host independently binds these bytes to CI provenance and all release gates.
export function prepareVerifiedNpmCandidate({ sourceDirectory, namespaceRoot, npmCli, releaseTag }) {
  if (process.platform !== 'win32') throw new Error('Actual Windows npm candidate preparation required.');
  if (releaseTag !== 'v0.38.0') throw new Error('The current integrated candidate requires exact v0.38.0.');
  const root = physicalPath(namespaceRoot), source = physicalPath(sourceDirectory), cli = physicalPath(npmCli);
  if (!fs.statSync(root).isDirectory() || fs.readdirSync(root).length !== 0) throw new Error('Fresh empty npm candidate namespace required.');
  const input = { namespaceRoot: root, sourceDirectory: source,
    sources: names.map(name => ({ path: name, observed_sha256: sha(fs.readFileSync(path.join(source, name))) })),
    nodeImage: physicalPath(process.execPath), observedNodeSha256: sha(fs.readFileSync(process.execPath)),
    npmCli: cli, observedNpmCliSha256: sha(fs.readFileSync(cli)) };
  const preparation = prepareNpmReleaseTarball(input);
  const windows = verifyPreparedNpmWindowsEntrypoint({ ...input, archiveFile: preparation.file,
    observedArchiveSha256: preparation.sha256 });
  if (preparation.sha256 !== windows.sha256 || preparation.bytes !== windows.bytes
    || sha(fs.readFileSync(preparation.file)) !== preparation.sha256) throw new Error('Prepared/Windows-verified npm bytes differ.');
  const artifact = path.join(root, 'artifact'); fs.mkdirSync(artifact);
  const finalFile = path.join(artifact, 'winsmux-0.38.0.tgz');
  fs.copyFileSync(preparation.file, finalFile, fs.constants.COPYFILE_EXCL);
  if (sha(fs.readFileSync(finalFile)) !== preparation.sha256) throw new Error('npm artifact copy differs from verified archive.');
  const receipt = { schema: 'winsmux-verified-npm-candidate/v1', version: '0.38.0', release_tag: releaseTag,
    file: finalFile, sha256: preparation.sha256, bytes: preparation.bytes,
    preparation, windows, publication_admitted: false };
  for (const action of ['help', 'version']) {
    for (const stream of ['stdout', 'stderr']) fs.copyFileSync(path.join(path.dirname(windows.extracted_directory), action + '-' + stream + '.txt'),
      path.join(artifact, action + '-' + stream + '.txt'), fs.constants.COPYFILE_EXCL);
  }
  const descriptor = fs.openSync(path.join(artifact, 'npm-candidate.json'), 'wx');
  try { fs.writeFileSync(descriptor, JSON.stringify(receipt)); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  return receipt;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const arguments_ = process.argv.slice(2), values = {};
    const allowed = ['--source', '--namespace', '--npm-cli', '--release-tag'];
    for (let index = 0; index < arguments_.length; index += 2) {
      const key = arguments_[index], value = arguments_[index + 1];
      if (!allowed.includes(key) || key in values || !value || value.startsWith('--')) throw new Error('Exact nonduplicate npm candidate arguments required.');
      values[key] = value;
    }
    if (Object.keys(values).length !== allowed.length) throw new Error('Source, fresh namespace, npm CLI and exact release tag required.');
    console.log(JSON.stringify(prepareVerifiedNpmCandidate({ sourceDirectory: values['--source'], namespaceRoot: values['--namespace'],
      npmCli: values['--npm-cli'], releaseTag: values['--release-tag'] })));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
