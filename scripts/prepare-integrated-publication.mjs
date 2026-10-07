import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { integratedAssetPaths, readIntegratedPublicationAssets } from './integrated-publication-assets.mjs';
import { assertPublicationPreparationAllowed } from './integrated-publication-attempt.mjs';
import { verifyIntegratedNpmTarball } from './prepare-integrated-npm-tarball.mjs';

// Assemble already-final producer bytes. Signing, npm packing, metadata and
// checksum generation happen before this call. Never re-create a verified
// bundle or overwrite an earlier attempt. No publication or authority here.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (value, reason) => { if (!value) throw new Error(reason); };
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const identity = stat => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key])).join(':');
function readSource(file, expectedSha) {
  const target = physicalPath(file);
  const before = fs.lstatSync(target, { bigint: true });
  requireValue(before.isFile() && !before.isSymbolicLink() && before.nlink === 1n, 'Plain single-link producer asset required.');
  const descriptor = fs.openSync(target, 'r');
  try {
    const held = fs.fstatSync(descriptor, { bigint: true });
    const bytes = fs.readFileSync(descriptor);
    const after = fs.lstatSync(target, { bigint: true });
    requireValue(identity(before) === identity(held) && identity(held) === identity(after), 'Producer asset changed during observation.');
    requireValue(bytes.length > 0 && sha(bytes) === expectedSha, 'Producer bytes differ from independent source observation.');
    return { target, bytes, identity: identity(after), sha256: expectedSha };
  } finally { fs.closeSync(descriptor); }
}
function writeFinal(file, bytes) {
  const descriptor = fs.openSync(file, 'wx');
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}

export function prepareIntegratedPublicationBundle(contract, { namespaceRoot, sourceCommit, sourceTree, producers, sources, npmSources }) {
  assertIssuedIntegratedContract(contract);
  const root = physicalPath(namespaceRoot);
  assertPublicationPreparationAllowed(root, '0.38.0');
  requireValue(fs.statSync(root).isDirectory(), 'Existing parent-owned publication namespace required.');
  requireValue(typeof sourceCommit === 'string' && typeof sourceTree === 'string'
    && /^[a-f0-9]{40}$/u.test(sourceCommit) && /^[a-f0-9]{40}$/u.test(sourceTree), 'Exact source commit and tree required.');
  requireValue(exact(producers, ['core', 'desktop', 'npm']) && Object.values(producers).every(row =>
    exact(row, ['source_commit', 'source_tree', 'run']) && row.source_commit === sourceCommit && row.source_tree === sourceTree
    && typeof row.run === 'string' && /^[A-Za-z0-9._-]+$/u.test(row.run)), 'Same source identity and all producer runs required.');
  const names = integratedAssetPaths(contract);
  requireValue(Array.isArray(sources) && sources.length === names.length
    && sources.every(row => exact(row, ['path', 'source_file', 'observed_sha256']) && typeof row.source_file === 'string'
      && typeof row.observed_sha256 === 'string' && /^[a-f0-9]{64}$/u.test(row.observed_sha256))
    && JSON.stringify(sources.map(row => row.path).sort()) === JSON.stringify(names), 'Complete final producer source inventory required.');
  const observations = new Map(sources.map(row => [row.path, readSource(row.source_file, row.observed_sha256)]));
  const npmNames = ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'];
  requireValue(Array.isArray(npmSources) && npmSources.length === npmNames.length
    && npmSources.every(row => exact(row, ['path', 'source_file', 'observed_sha256']) && typeof row.source_file === 'string'
      && typeof row.observed_sha256 === 'string' && /^[a-f0-9]{64}$/u.test(row.observed_sha256))
    && JSON.stringify(npmSources.map(row => row.path).sort()) === JSON.stringify(npmNames), 'Exact five-file npm producer inventory required.');
  const npmObservations = new Map(npmSources.map(row => [row.path, readSource(row.source_file, row.observed_sha256)]));
  const npmBytes = Object.fromEntries([...npmObservations].map(([name, value]) => [name, value.bytes]));
  // Never accept a directory, renamed synthetic file or a repacked substitute.
  // Validate the actual final tarball against its independently observed five
  // producer files before creating an integrated candidate.
  verifyIntegratedNpmTarball(observations.get('npm/winsmux-0.38.0.tgz').bytes, npmBytes);
  const attempt = randomUUID();
  const versionDirectory = physicalPath(path.join(root, 'v0.38.0'));
  fs.mkdirSync(versionDirectory, { recursive: true }); physicalPath(versionDirectory);
  assertPublicationPreparationAllowed(root, '0.38.0');
  const attemptDirectory = physicalPath(path.join(versionDirectory, attempt));
  fs.mkdirSync(attemptDirectory); // Exclusive new attempt. Prior generations stay intact.
  const bundleRoot = path.join(attemptDirectory, 'bundle');
  fs.mkdirSync(bundleRoot);
  for (const surface of ['core', 'desktop', 'npm']) fs.mkdirSync(path.join(bundleRoot, surface));
  for (const name of names) writeFinal(path.join(bundleRoot, name), observations.get(name).bytes);
  const manifest = { schema: 'winsmux-integrated-publication-assets/v1', version: '0.38.0', source_commit: sourceCommit,
    source_tree: sourceTree, attempt, producers: structuredClone(producers), assets: names.map(name => {
      const source = observations.get(name);
      return { path: name, bytes: source.bytes.length, sha256: source.sha256,
        producer: producers[name === 'release-body.md' ? 'core' : name.split('/')[0]].run };
    }) };
  const manifestBytes = Buffer.from(JSON.stringify(manifest));
  const manifestFile = path.join(attemptDirectory, 'publication-assets.json');
  writeFinal(manifestFile, manifestBytes);
  for (const before of [...observations.values(), ...npmObservations.values()]) {
    const after = readSource(before.target, before.sha256);
    requireValue(after.identity === before.identity, 'Producer identity changed during bundle assembly.');
  }
  assertPublicationPreparationAllowed(root, '0.38.0');
  const bundle = readIntegratedPublicationAssets(contract, bundleRoot, manifestBytes);
  verifyIntegratedNpmTarball(fs.readFileSync(path.join(bundleRoot, 'npm/winsmux-0.38.0.tgz')), npmBytes);
  return Object.freeze({ bundle, manifest_file: manifestFile, manifest_sha256: sha(manifestBytes),
    namespace_root: root, publication_admitted: false });
}
