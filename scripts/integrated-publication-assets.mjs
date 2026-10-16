import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { physicalPath } from './distribution-prelaunch.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';

const issuedBundles = new WeakSet();
const bundleObservations = new WeakMap();
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const requireValue = (condition, reason) => { if (!condition) throw new Error(reason); };
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const commit = value => typeof value === 'string' && /^[a-f0-9]{40}$/u.test(value);
const token = value => typeof value === 'string' && /^[A-Za-z0-9._-]+$/u.test(value);
const identityKeys = ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'];
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

export function integratedAssetPaths(contract) {
  assertIssuedIntegratedContract(contract);
  // The current integrated contract has one explicit version and surface set.
  // A new surface/version refreezes this contract rather than accepting a
  // caller's smaller asset list. License sidecars and updater bytes are assets.
  return Object.freeze([
    'core/SHA256SUMS', 'core/winsmux-arm64.exe', 'core/winsmux-arm64.exe.licenses.zip',
    'core/winsmux-remote-helper-linux-x64', 'core/winsmux-x64.exe', 'core/winsmux-x64.exe.licenses.zip',
    'desktop/SHA256SUMS-desktop', 'desktop/latest.json',
    'desktop/winsmux_0.38.0_x64-setup.exe', 'desktop/winsmux_0.38.0_x64-setup.exe.sig',
    'desktop/winsmux_0.38.0_x64-setup.inventory.json',
    'desktop/winsmux_0.38.0_x64_en-US.msi', 'npm/winsmux-0.38.0.tgz', 'release-body.md',
  ].sort());
}

function inventory(root, prefix = '', rows = []) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const relative = prefix + entry.name;
    const target = path.join(root, entry.name);
    const stat = fs.lstatSync(target, { bigint: true });
    requireValue(!stat.isSymbolicLink(), 'Linked publication asset is unsupported.');
    if (stat.isDirectory()) {
      requireValue(prefix === '' && ['core', 'desktop', 'npm'].includes(entry.name), 'Unexpected bundle directory.');
      inventory(target, relative + '/', rows);
    }
    else {
      requireValue(stat.isFile() && stat.nlink === 1n, 'Publication asset must be a plain single-link file.');
      rows.push(relative);
    }
  }
  return rows.sort();
}

function read(root, relative) {
  const target = physicalPath(path.join(root, relative));
  const descriptor = fs.openSync(target, 'r');
  try {
    const before = fs.fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.nlink === 1n && before.ino > 0n, 'Publication asset identity unavailable.');
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, { bigint: true });
    const named = fs.lstatSync(target, { bigint: true });
    requireValue(identityKeys.every(key => before[key] === after[key] && after[key] === named[key]),
      'Publication asset changed during observation.');
    return { bytes, identity: `${before.dev}:${before.ino}`, sha256: sha(bytes) };
  } finally { fs.closeSync(descriptor); }
}

function checkCoordinates(manifest) {
  requireValue(exact(manifest, ['schema', 'version', 'source_commit', 'source_tree', 'attempt', 'producers', 'assets'])
    && manifest.schema === 'winsmux-integrated-publication-assets/v1' && manifest.version === '0.38.0'
    && commit(manifest.source_commit) && commit(manifest.source_tree) && token(manifest.attempt),
  'Exact integrated candidate identity required.');
  requireValue(exact(manifest.producers, ['core', 'desktop', 'npm']), 'Every surface producer required.');
  for (const producer of Object.values(manifest.producers)) requireValue(
    exact(producer, ['run', 'source_commit', 'source_tree']) && token(producer.run)
    && producer.source_commit === manifest.source_commit && producer.source_tree === manifest.source_tree,
  'Producer source or run differs from integrated candidate.');
}

function checksum(bytes, files) {
  const content = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  const expected = [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([name, file]) => `${file.sha256}  ${name}\n`).join('');
  requireValue(content.replaceAll('\r\n', '\n') === expected, 'Checksum asset differs from complete candidate bytes.');
}

/** Observe the full prepared bundle. This verifies bytes, not build provenance,
 * licence entitlement, E2E completion, cryptographic signatures or authority.
 * Native deny-write/delete handles must still be held by the publication host
 * through every real child exit; a JS observation is not that custody proof.
 */
export function readIntegratedPublicationAssets(contract, root, manifestBytes) {
  assertIssuedIntegratedContract(contract);
  const manifest = parseStrictJson(manifestBytes);
  checkCoordinates(manifest);
  const expected = integratedAssetPaths(contract);
  requireValue(Array.isArray(manifest.assets) && manifest.assets.length === expected.length,
    'Complete integrated asset list required.');
  requireValue(JSON.stringify(manifest.assets.map(asset => asset.path)) === JSON.stringify(expected),
    'Asset inventory differs from the fixed surface contract.');
  const directory = physicalPath(root);
  const beforeDirectory = fs.lstatSync(directory, { bigint: true });
  requireValue(beforeDirectory.isDirectory() && beforeDirectory.ino > 0n, 'Publication bundle directory required.');
  requireValue(JSON.stringify(inventory(directory)) === JSON.stringify(expected), 'Bundle has missing or additional assets.');
  const observations = new Map();
  for (const asset of manifest.assets) {
    requireValue(exact(asset, ['path', 'bytes', 'sha256', 'producer']) && digest(asset.sha256)
      && Number.isSafeInteger(asset.bytes) && asset.bytes > 0,
    'Exact nonempty asset record required.');
    const surface = asset.path === 'release-body.md' ? 'core' : asset.path.split('/')[0];
    requireValue(asset.producer === manifest.producers[surface].run, 'Asset producer differs.');
    const observation = read(directory, asset.path);
    requireValue(observation.bytes.length === asset.bytes && observation.sha256 === asset.sha256,
      'Actual publication asset bytes differ.');
    observations.set(asset.path, observation);
  }
  const sameDirectory = fs.statSync(directory, { bigint: true });
  requireValue(beforeDirectory.dev === sameDirectory.dev && beforeDirectory.ino === sameDirectory.ino,
    'Bundle directory identity changed.');
  requireValue(JSON.stringify(inventory(directory)) === JSON.stringify(expected), 'Bundle inventory changed during observation.');
  for (const [relative, before] of observations) {
    const after = read(directory, relative);
    requireValue(before.identity === after.identity && before.sha256 === after.sha256,
      'Bundle asset changed during complete observation.');
  }
  for (const [surface, filename] of [['core', 'SHA256SUMS'], ['desktop', 'SHA256SUMS-desktop']]) {
    const files = [...observations].filter(([name]) => name.startsWith(surface + '/') && name !== `${surface}/${filename}`)
      .map(([name, value]) => [name.slice(surface.length + 1), value]);
    checksum(observations.get(`${surface}/${filename}`).bytes, files);
  }
  const latest = parseStrictJson(observations.get('desktop/latest.json').bytes);
  requireValue(exact(latest, ['version', 'notes', 'pub_date', 'platforms']) && latest.version === manifest.version
    && typeof latest.notes === 'string' && typeof latest.pub_date === 'string' && Number.isFinite(Date.parse(latest.pub_date))
    && exact(latest.platforms, ['windows-x86_64'])
    && exact(latest.platforms['windows-x86_64'], ['signature', 'url']), 'Exact updater metadata required.');
  const platform = latest.platforms['windows-x86_64'];
  const signature = new TextDecoder('utf-8', { fatal: true }).decode(observations.get('desktop/winsmux_0.38.0_x64-setup.exe.sig').bytes).trim();
  requireValue(signature.length > 0 && platform.signature === signature
    && platform.url === 'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.0_x64-setup.exe',
  'Updater signature or exact candidate destination differs.');
  const bundle = freeze({
    schema: 'winsmux-observed-publication-bundle/v1',
    identity: { version: manifest.version, source_commit: manifest.source_commit, source_tree: manifest.source_tree,
      attempt: manifest.attempt, assets_sha256: sha(Buffer.from(JSON.stringify(manifest.assets))),
      manifest_sha256: sha(manifestBytes) },
    producers: manifest.producers, assets: manifest.assets,
    root: directory, root_identity: `${sameDirectory.dev}:${sameDirectory.ino}`,
    publication_admitted: false,
  });
  issuedBundles.add(bundle);
  bundleObservations.set(bundle, { contract, manifestBytes: Buffer.from(manifestBytes),
    identities: new Map([...observations].map(([name, value]) => [name, value.identity])) });
  return bundle;
}

export function assertIssuedPublicationBundle(bundle) {
  requireValue(issuedBundles.has(bundle), 'Bundle must be observed by this validator.');
  return bundle;
}

export function revalidatePublicationBundle(bundle) {
  assertIssuedPublicationBundle(bundle);
  const original = bundleObservations.get(bundle);
  const current = readIntegratedPublicationAssets(original.contract, bundle.root, original.manifestBytes);
  const now = bundleObservations.get(current);
  requireValue(current.root_identity === bundle.root_identity && JSON.stringify(current.identity) === JSON.stringify(bundle.identity)
    && [...original.identities].every(([name, identity]) => now.identities.get(name) === identity),
  'Observed bundle identity changed.');
  return bundle;
}
