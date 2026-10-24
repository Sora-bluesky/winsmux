import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { readIntegratedPublicationContract } from '../../scripts/integrated-publication-contract.mjs';
import { prepareIntegratedNpmTarball, verifyIntegratedNpmTarball } from '../../scripts/prepare-integrated-npm-tarball.mjs';

const [operatorRoot, trialFile] = process.argv.slice(2);
assert.ok(operatorRoot && trialFile, 'Original operator root and freshly staged native trial required.');
const trial = JSON.parse(fs.readFileSync(trialFile, 'utf8'));
const trialRoot = path.dirname(path.resolve(trialFile));
assert.ok(trialRoot.includes(`${path.sep}.evidence${path.sep}workspace-package${path.sep}npm-native-`), 'Owned native trial required.');
const contract = readIntegratedPublicationContract(path.resolve(operatorRoot));
const hash = (value, kind = 'sha256') => createHash(kind).update(value).digest('hex');
const names = ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'];
const expected = Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(trial.source, name))]));
const input = { namespaceRoot: trial.namespace, sourceDirectory: trial.source,
  sources: names.map(name => ({ path: name, observed_sha256: hash(expected[name]) })),
  nodeImage: trial.node, observedNodeSha256: hash(fs.readFileSync(trial.node)),
  npmCli: trial.npm_cli, observedNpmCliSha256: hash(fs.readFileSync(trial.npm_cli)) };
let checks = 0;
const check = action => { action(); checks++; };
const reject = (action, pattern) => check(() => assert.throws(action, pattern));
const prepare = (value = input) => prepareIntegratedNpmTarball(contract, value);
for (const change of [ value => value.sources.pop(), value => { value.sources[0] = value.sources[1]; },
  value => { value.sources[0].path = '../package.json'; }, value => { value.sources[0].observed_sha256 = '0'.repeat(64); },
  value => { value.sources[0].approved = true; }, value => { value.observedNodeSha256 = '0'.repeat(64); },
  value => { value.observedNpmCliSha256 = '0'.repeat(64); }, value => { value.namespaceRoot = value.sourceDirectory; } ]) {
  const value = structuredClone(input); change(value); reject(() => prepare(value), /inventory|SHA|overlap/u);
}
check(() => assert.deepEqual(fs.readdirSync(trial.namespace), []));
const packageFile = path.join(trial.source, 'package.json');
for (const change of [ pkg => { pkg.version = '0.38.1'; }, pkg => { pkg.winsmuxReleaseTag = 'v0.38.1'; },
  pkg => { pkg.private = false; }, pkg => { pkg.scripts = { prepack: 'exit 99' }; },
  pkg => { pkg.os = ['linux']; }, pkg => { pkg.bin.winsmux = '../index.mjs'; },
  pkg => { pkg.files.push('secret.txt'); }, pkg => { pkg.dependencies = { foreign: '*' }; } ]) {
  const pkg = JSON.parse(expected['package.json']); change(pkg);
  fs.writeFileSync(packageFile, JSON.stringify(pkg));
  const value = structuredClone(input); value.sources.find(row => row.path === 'package.json').observed_sha256 = hash(fs.readFileSync(packageFile));
  reject(() => prepare(value), /package contract/u);
  check(() => assert.deepEqual(fs.readdirSync(trial.namespace), []));
}
fs.writeFileSync(packageFile, expected['package.json']);
const native = prepare();
const archive = fs.readFileSync(native.file);
check(() => { assert.equal(native.native_exit_code, 0); assert.equal(native.publication_admitted, false); assert.equal(native.sha256, hash(archive)); assert.equal(native.bytes, archive.length); });
check(() => assert.deepEqual(verifyIntegratedNpmTarball(archive, expected).files, names));
const tar = gunzipSync(archive);
const headerOffsets = [];
for (let offset = 0; offset + 512 <= tar.length && tar[offset] !== 0;) {
  headerOffsets.push(offset);
  const size = Number.parseInt(tar.subarray(offset + 124, offset + 136).toString('ascii').replaceAll('\0', '').trim(), 8);
  offset += 512 + Math.ceil(size / 512) * 512;
}
check(() => assert.equal(headerOffsets.length, names.length));
const extracted = path.join(trialRoot, 'extracted-' + randomUUID()); fs.mkdirSync(extracted);
for (const offset of headerOffsets) {
  const name = tar.subarray(offset, offset + 100).toString('ascii').split('\0')[0].slice(8);
  check(() => assert.ok(names.includes(name)));
  const size = Number.parseInt(tar.subarray(offset + 124, offset + 136).toString('ascii').replaceAll('\0', '').trim(), 8);
  fs.writeFileSync(path.join(extracted, name), tar.subarray(offset + 512, offset + 512 + size), { flag: 'wx' });
}
for (const name of names) check(() => assert.deepEqual(fs.readFileSync(path.join(extracted, name)), expected[name]));
const environment = { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, WINDIR: process.env.WINDIR,
  USERPROFILE: process.env.USERPROFILE, APPDATA: process.env.APPDATA, LOCALAPPDATA: process.env.LOCALAPPDATA,
  TEMP: path.join(trialRoot, 'entrypoint-temporary'), TMP: path.join(trialRoot, 'entrypoint-temporary') };
fs.mkdirSync(environment.TEMP);
const entrypoint = [];
for (const [action, expectedOutput] of [['help', /^Usage: install\.ps1 \[action\]/mu], ['version', /^winsmux 0\.38\.0\r?\n$/u]]) {
  const process = spawnSync(trial.node, [path.join(extracted, 'index.mjs'), action], { env: environment, cwd: extracted, windowsHide: true, encoding: 'utf8' });
  fs.writeFileSync(path.join(trialRoot, `entrypoint-${action}-stdout.txt`), process.stdout ?? '', { flag: 'wx' });
  fs.writeFileSync(path.join(trialRoot, `entrypoint-${action}-stderr.txt`), process.stderr ?? '', { flag: 'wx' });
  check(() => { assert.equal(process.status, 0); assert.equal(process.signal, null); assert.match(process.stdout, expectedOutput); assert.equal(process.stderr, ''); });
  entrypoint.push({ action, native_exit_code: process.status, stdout_sha256: hash(process.stdout), expected_actual_verified: true });
}
check(() => assert.equal(hash(fs.readFileSync(native.file)), native.sha256));
function checksum(value, offset) {
  value.fill(32, offset + 148, offset + 156);
  const sum = value.subarray(offset, offset + 512).reduce((total, byte) => total + byte, 0);
  value.write(sum.toString(8).padStart(6, '0') + '\0 ', offset + 148, 'ascii');
}
function damaged(change, pattern) {
  const value = Buffer.from(tar); change(value); reject(() => verifyIntegratedNpmTarball(gzipSync(value), expected), pattern);
}
damaged(value => { value[headerOffsets[0] + 512] ^= 1; }, /actual file bytes/u);
damaged(value => { value[headerOffsets[0] + 148] ^= 1; }, /checksum|octal/u);
damaged(value => { value[headerOffsets[0] + 156] = 50; checksum(value, headerOffsets[0]); }, /Non-regular/u);
damaged(value => { value.fill(0, headerOffsets[0], headerOffsets[0] + 100); value.write('package/../secret.txt', headerOffsets[0]); checksum(value, headerOffsets[0]); }, /Foreign/u);
damaged(value => { const name = value.subarray(headerOffsets[0], headerOffsets[0] + 100); name.copy(value, headerOffsets[1]); checksum(value, headerOffsets[1]); }, /duplicate/u);
damaged(value => { value[headerOffsets[0] + 257] = 120; checksum(value, headerOffsets[0]); }, /extended/u);
damaged(value => { value[headerOffsets[0] + 345] = 120; checksum(value, headerOffsets[0]); }, /extended/u);
damaged(value => { value[value.length - 1] = 1; }, /trailing/u);
reject(() => verifyIntegratedNpmTarball(gzipSync(tar.subarray(0, tar.length - 512)), expected), /end|Incomplete/u);
reject(() => verifyIntegratedNpmTarball(Buffer.from('invalid'), expected), /header|format|data/u);
reject(() => verifyIntegratedNpmTarball(archive, { ...expected, 'extra.txt': Buffer.alloc(0) }), /expected/u);
for (const name of names) check(() => assert.deepEqual(fs.readFileSync(path.join(trial.source, name)), expected[name]));
check(() => assert.equal(hash(fs.readFileSync(native.file)), native.sha256));
const marker = path.join(trial.namespace, 'v0.38.0', 'publish', 'in-flight.json');
fs.mkdirSync(path.dirname(marker)); fs.writeFileSync(marker, '{"approved":true}', { flag: 'wx' });
const generations = fs.readdirSync(path.join(trial.namespace, 'v0.38.0')).sort();
reject(() => prepare(), /frozen/u);
check(() => assert.deepEqual(fs.readdirSync(path.join(trial.namespace, 'v0.38.0')).sort(), generations));
check(() => assert.equal(hash(fs.readFileSync(native.file)), native.sha256));
const result = { observed_at: new Date().toISOString(), passed: true, checks, native_pack: native, extracted_entrypoint: entrypoint,
  native_exit_code: 0, publication_admitted: false,
  scope: 'Actual npm archive, native pack exit, exact five product files, extracted Windows help/version, malformed/archive-entry refusals and frozen-namespace refusal. Installer mutation, CI entrance cutover and public dispatch remain separate.' };
fs.writeFileSync(path.join(trialRoot, 'npm-native-result.json'), JSON.stringify(result), { flag: 'wx' });
console.log(JSON.stringify(result));
