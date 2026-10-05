import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readIntegratedPublicationContract } from '../../scripts/integrated-publication-contract.mjs';
import { integratedAssetPaths, readIntegratedPublicationAssets, assertIssuedPublicationBundle } from '../../scripts/integrated-publication-assets.mjs';

assert.ok(process.argv[2], 'Pass the canonical operator root.');
const contract = readIntegratedPublicationContract(path.resolve(process.argv[2]));
const root = path.resolve('.evidence/workspace-package', `publication-assets-${randomUUID()}`);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const files = new Map(integratedAssetPaths(contract).map(name => [name, Buffer.from(`Synthetic integrity fixture: ${name}\n`)]));
files.set('desktop/winsmux_0.38.0_x64-setup.exe.sig', Buffer.from('synthetic-updater-signature\n'));
files.set('desktop/latest.json', Buffer.from(JSON.stringify({ version: '0.38.0', notes: 'Synthetic metadata only',
  pub_date: '2026-10-03T00:00:00Z', platforms: { 'windows-x86_64': {
    signature: 'synthetic-updater-signature',
    url: 'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.0_x64-setup.exe',
  } } })));
// Match the producer's filename ordering.
for (const [surface, checksum] of [['core', 'SHA256SUMS'], ['desktop', 'SHA256SUMS-desktop']]) files.set(`${surface}/${checksum}`,
  Buffer.from([...files].filter(([name]) => name.startsWith(`${surface}/`) && name !== `${surface}/${checksum}`)
    .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([name, bytes]) => `${sha(bytes)}  ${name.slice(surface.length + 1)}\n`).join('')));
for (const [name, bytes] of files) {
  const target = path.join(root, name); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
}
const coordinate = { source_commit: '1'.repeat(40), source_tree: '2'.repeat(40) };
const manifest = { schema: 'winsmux-integrated-publication-assets/v1', version: '0.38.0', ...coordinate,
  attempt: randomUUID(), producers: Object.fromEntries(['core', 'desktop', 'npm'].map(surface =>
    [surface, { ...coordinate, run: `${surface}-run-1` }])),
  assets: integratedAssetPaths(contract).map(name => ({ path: name, bytes: files.get(name).length, sha256: sha(files.get(name)),
    producer: `${name === 'release-body.md' ? 'core' : name.split('/')[0]}-run-1` })),
};
const serialize = value => Buffer.from(JSON.stringify(value));
const observe = input => readIntegratedPublicationAssets(contract, root, serialize(input ?? manifest));
let checks = 0;
const check = fn => { fn(); checks++; };
const reject = (fn, pattern) => check(() => assert.throws(fn, pattern));
const initial = observe();
check(() => {
  assert.strictEqual(assertIssuedPublicationBundle(initial), initial);
  assert.equal(initial.publication_admitted, false);
  assert.equal(initial.assets.length, 13);
  assert.equal(initial.identity.manifest_sha256, sha(serialize(manifest)));
});
reject(() => assertIssuedPublicationBundle(Object.freeze(structuredClone(initial))), /observed/);
reject(() => { initial.assets[0].sha256 = '0'.repeat(64); }, TypeError);
for (const mutate of [
  value => { value.schema = 'unknown'; },
  value => { value.version = '0.38.1'; },
  value => { value.source_commit = '3'.repeat(40); },
  value => { value.source_tree = '3'.repeat(40); },
  value => { value.approved = true; },
  value => { value.producers.desktop.run = 'replacement'; },
  value => { delete value.producers.npm; },
  value => { value.assets.pop(); },
  value => { value.assets.push(value.assets[0]); },
  value => { value.assets[0].path = '../outside'; },
  value => { value.assets[0].path = 'CORE/SHA256SUMS'; },
  value => { value.assets[0].path = 'core/SHA256SUMS:stream'; },
  value => { value.assets[0].bytes = 0; },
  value => { value.assets[0].sha256 = 'f'.repeat(64); },
  value => { value.assets[0].approved = true; },
  value => { value.assets.reverse(); },
]) reject(() => { const changed = structuredClone(manifest); mutate(changed); observe(changed); });
for (const [name, bytes] of files) {
  const file = path.join(root, name);
  fs.writeFileSync(file, Buffer.concat([bytes, Buffer.from('changed')]));
  reject(() => observe(), /bytes differ/);
  fs.writeFileSync(file, bytes);
}
for (const name of files.keys()) {
  const file = path.join(root, name);
  const parked = path.join(path.dirname(root), `${randomUUID()}.parked-test-asset`);
  fs.renameSync(file, parked);
  try { reject(() => observe(), /missing or additional/); }
  finally { fs.renameSync(parked, file); }
}
// Updated caller hashes cannot hide a checksum or updater payload inconsistency.
for (const name of ['core/SHA256SUMS', 'desktop/SHA256SUMS-desktop', 'desktop/latest.json']) {
  const original = files.get(name);
  const changed = name.endsWith('latest.json') ? Buffer.from(original.toString().replace('synthetic-updater-signature', 'another-signature'))
    : Buffer.from('0'.repeat(64) + '  missing.exe\n');
  fs.writeFileSync(path.join(root, name), changed);
  const supplied = structuredClone(manifest);
  const row = supplied.assets.find(asset => asset.path === name); row.bytes = changed.length; row.sha256 = sha(changed);
  reject(() => observe(supplied), /Checksum|signature/);
  fs.writeFileSync(path.join(root, name), original);
}
const originalStat = fs.readFileSync;
const raceTarget = path.join(root, 'npm/winsmux-0.38.0.tgz');
const raceIdentity = fs.statSync(raceTarget, { bigint: true }).ino;
let raceApplied = false;
// Change the file after its first descriptor read; the complete second pass
// and descriptor/path identity checks must reject it rather than accept a hash.
fs.readFileSync = function (target, ...args) {
  const bytes = originalStat.call(fs, target, ...args);
  if (typeof target === 'number' && !raceApplied && fs.fstatSync(target, { bigint: true }).ino === raceIdentity) {
    raceApplied = true;
    fs.writeFileSync(raceTarget, 'mutation during observation');
  }
  return bytes;
};
try { reject(() => observe(), /changed|bytes differ/); }
finally { fs.readFileSync = originalStat; fs.writeFileSync(raceTarget, files.get('npm/winsmux-0.38.0.tgz')); }
check(() => assert.equal(observe().identity.assets_sha256, initial.identity.assets_sha256));
fs.mkdirSync(path.join(root, 'unexpected-empty-directory'));
reject(() => observe(), /Unexpected bundle directory/);
const extraRoot = path.resolve('.evidence/workspace-package', `publication-assets-extra-${randomUUID()}`);
fs.mkdirSync(extraRoot, { recursive: true });
for (const [name, bytes] of files) { const file = path.join(extraRoot, name); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
fs.writeFileSync(path.join(extraRoot, '.hidden'), 'unexpected');
reject(() => readIntegratedPublicationAssets(contract, extraRoot, serialize(manifest)), /additional assets/);
const hardlinkRoot = path.resolve('.evidence/workspace-package', `publication-assets-hardlink-${randomUUID()}`);
fs.mkdirSync(hardlinkRoot, { recursive: true });
for (const [name, bytes] of files) { const file = path.join(hardlinkRoot, name); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
fs.linkSync(path.join(hardlinkRoot, 'release-body.md'), path.join(path.dirname(hardlinkRoot), `${randomUUID()}.hardlink`));
reject(() => readIntegratedPublicationAssets(contract, hardlinkRoot, serialize(manifest)), /single-link/);
console.log(JSON.stringify({ passed: true, checks, assets: initial.assets.length,
  asset_inventory_sha256: initial.identity.assets_sha256, publication_admitted: false,
  scope: 'synthetic integrity and refusal tests; no licence, signature, native E2E or publication claim' }));
