import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepareInstallFixture } from '../../scripts/prepare-install-e2e-fixture.mjs';
import { coreSourceInventory, coreSourceInventoryIdentity } from '../../scripts/build-core-candidate.mjs';
import { fixturePe } from './fixture-pe.mjs';
import { checkedWindowsLicenseBuildInputs } from '../../scripts/windows-license-build-inputs.mjs';
import { buildDistributionLicenses } from '../../scripts/stage-distribution-licenses.mjs';
import { renderCoreRelease } from '../../scripts/stage-core-release.mjs';
import { checkedPowerShellEnvironment } from '../../scripts/distribution-prelaunch.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const literal = value => "'" + value.replaceAll("'", "''") + "'";

test('private transport projects only HTTP and refuses stale, altered and ambiguous inputs', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wm-fixture-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  const candidate = path.join(root, 'candidate'); fs.mkdirSync(candidate);
  const commit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8', windowsHide: true });
  assert.equal(commit.status, 0); const sourceCommit = commit.stdout.trim();
  const original = fs.readFileSync(path.join(repo, 'install.ps1'));
  // Synthetic candidate metadata and PE bytes exercise validation only. They
  // are never executed or reported as a real compiler/installer/public proof.
  const target = 'x86_64-pc-windows-msvc';
  const { licenseOptions } = checkedWindowsLicenseBuildInputs({ repoRoot: repo, version: '0.38.0', host: target,
    rustcCommit: 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96' });
  const { files: licenses } = buildDistributionLicenses(licenseOptions);
  const { files } = renderCoreRelease({ version: '0.38.0', target, executable: fixturePe({ normal: ['kernel32.dll'] }), licenses });
  for (const [name, bytes] of files) fs.writeFileSync(path.join(candidate, name), bytes);
  const receipt = { schema: 'core-ci-candidate/v1', source_commit: sourceCommit, version: '0.38.0', release_tag: 'v0.38.0',
    target: 'x86_64-pc-windows-msvc', consumer_source_sha256: hash(original), build_origin_verified: true,
    native_redistribution_verified: false, publication_admitted: false,
    source_inventory_sha256: coreSourceInventoryIdentity(coreSourceInventory()),
    compiler: { host: 'x86_64-pc-windows-msvc', release: '1.96.0', commit: 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96' },
    executable_sha256: hash(files.get('winsmux-x64.exe')), files: [...files].map(([name, bytes]) => ({ path: name, bytes: bytes.length, sha256: hash(bytes) })) };
  const receiptPath = path.join(candidate, 'core-candidate.json');
  const saveReceipt = value => fs.writeFileSync(receiptPath, JSON.stringify(value)); saveReceipt(receipt);
  const request = { candidateDirectory: candidate, sourceCommit, version: '0.38.0', output: path.join(root, 'fixture') };
  for (const change of [{ source_commit: '0'.repeat(40) }, { version: '0.38.1' }, { release_tag: 'v0.38.1' },
    { target: 'aarch64-pc-windows-msvc' }, { build_origin_verified: false }, { native_redistribution_verified: true },
    { publication_admitted: true }, { source_inventory_sha256: '0'.repeat(64) },
    { files: receipt.files.slice(1) }, { files: [receipt.files[0], receipt.files[0], receipt.files[2]] }]) {
    saveReceipt({ ...receipt, ...change }); assert.throws(() => prepareInstallFixture(request));
    assert.equal(fs.existsSync(request.output), false);
  }
  saveReceipt(receipt);
  const binary = path.join(candidate, 'winsmux-x64.exe');
  fs.appendFileSync(binary, 'changed'); assert.throws(() => prepareInstallFixture(request));
  fs.writeFileSync(binary, files.get('winsmux-x64.exe'));
  fs.writeFileSync(path.join(candidate, 'stray'), 'unexpected'); assert.throws(() => prepareInstallFixture(request));
  fs.unlinkSync(path.join(candidate, 'stray'));
  const proof = prepareInstallFixture(request);
  assert.equal(proof.product_body_unchanged, true);
  assert.equal(proof.public_release_acquisition_proven, false);
  assert.equal(proof.original_installer_sha256, hash(original));
  assert.notEqual(proof.fixture_installer_sha256, hash(original));
  // Exercise the real stage -> pristine tarball -> fixture tarball connection.
  // This is npm packaging only; neither synthetic PE nor installer is executed.
  fs.mkdirSync(path.join(repo, '.evidence'), { recursive: true });
  const packageRoot = fs.mkdtempSync(path.join(repo, '.evidence/npm-source-'));
  t.after(() => fs.rmSync(packageRoot, { recursive: true }));
  const stage = path.join(packageRoot, 'stage');
  const mismatched = spawnSync(process.execPath, [path.join(repo, 'scripts/stage-npm-release.mjs'),
    '--version', '0.38.1', '--out', stage], {
    cwd: repo, env: checkedPowerShellEnvironment(repo), windowsHide: true, encoding: 'utf8',
  });
  assert.notEqual(mismatched.status, 0);
  assert.match(mismatched.stderr, /Requested npm native version differs from VERSION/u);
  assert.equal(fs.existsSync(stage), false);
  const staged = spawnSync(process.execPath, [path.join(repo, 'scripts/stage-npm-release.mjs'),
    '--version', '0.38.0', '--out', stage], {
    cwd: repo, env: checkedPowerShellEnvironment(repo), windowsHide: true, encoding: 'utf8',
  });
  assert.equal(staged.status, 0, staged.stderr);
  assert.deepEqual(fs.readFileSync(path.join(stage, 'install.ps1')), original);
  const pristineIndex = fs.readFileSync(path.join(stage, 'index.mjs'));
  const pristineMetadata = fs.readFileSync(path.join(stage, 'package.json'));
  const npmCli = path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js');
  assert.ok(fs.existsSync(npmCli), 'The installed Node npm CLI must exist.');
  const npmConfig = path.join(packageRoot, 'npmrc'); fs.writeFileSync(npmConfig, '');
  function pack(label) {
    const output = path.join(packageRoot, label); fs.mkdirSync(output);
    const packed = spawnSync(process.execPath, [npmCli, 'pack', '--json', '--pack-destination', output,
      '--cache', path.join(packageRoot, 'cache'), '--userconfig', npmConfig], {
      cwd: stage, windowsHide: true, encoding: 'utf8',
    });
    assert.equal(packed.status, 0, packed.stderr);
    const [entry] = JSON.parse(packed.stdout);
    const tarball = path.join(output, entry.filename);
    const extracted = path.join(output, 'extracted'); fs.mkdirSync(extracted);
    const extraction = spawnSync('tar', ['-xzf', tarball, '-C', extracted], { windowsHide: true, encoding: 'utf8' });
    assert.equal(extraction.status, 0, extraction.stderr);
    assert.deepEqual(fs.readFileSync(path.join(extracted, 'package/index.mjs')), pristineIndex);
    assert.deepEqual(fs.readFileSync(path.join(extracted, 'package/package.json')), pristineMetadata);
    return { bytes: fs.readFileSync(tarball), installer: fs.readFileSync(path.join(extracted, 'package/install.ps1')) };
  }
  const pristine = pack('pristine');
  assert.equal(hash(pristine.installer), proof.original_installer_sha256);
  fs.copyFileSync(proof.installer, path.join(stage, 'install.ps1'));
  const projectedPackage = pack('fixture');
  assert.equal(hash(projectedPackage.installer), proof.fixture_installer_sha256);
  assert.notEqual(hash(pristine.bytes), hash(projectedPackage.bytes));
  const transport = JSON.parse(fs.readFileSync(path.join(request.output, 'transport.json')));
  for (const ref of [sourceCommit, 'v0.38.0', 'main']) {
    const row = transport.responses[`https://raw.githubusercontent.com/Sora-bluesky/winsmux/${ref}/install.ps1`];
    assert.deepEqual(fs.readFileSync(row.file), original);
  }
  const projected = fs.readFileSync(proof.installer, 'utf8');
  assert.ok(projected.includes('function Invoke-RestMethod'));
  assert.ok(projected.includes('function Invoke-WebRequest'));
  assert.throws(() => prepareInstallFixture(request));
});

test('real PowerShell fixture GET and HEAD use the same snapshot; unknown requests fail closed', { skip: process.platform !== 'win32' }, t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wm-http-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  const source = fs.readFileSync(path.join(repo, 'scripts/prepare-install-e2e-fixture.mjs'), 'utf8');
  const begin = source.indexOf('function Read-WinsmuxFixtureResponse {');
  const end = source.indexOf('\n`;\n', begin);
  assert.ok(begin > 0 && end > begin);
  const body = source.slice(begin, end);
  const response = Buffer.from('raw source\r\n'); const responseFile = path.join(root, 'source'); fs.writeFileSync(responseFile, response);
  const uri = 'https://winsmux-fixture.invalid/known';
  const map = Buffer.from(JSON.stringify({ responses: { [uri]: { file: responseFile, bytes: response.length, sha256: hash(response), kind: 'text' }, [uri + '/missing']: { kind: 'missing' } } }));
  const mapFile = path.join(root, 'map.json'); fs.writeFileSync(mapFile, map);
  const script = path.join(root, 'probe.ps1'); const copied = path.join(root, 'copied');
  fs.writeFileSync(script, `$ErrorActionPreference='Stop'\n$script:WinsmuxFixtureMapPath=${literal(mapFile)}\n$script:WinsmuxFixtureMapHash='${hash(map)}'\n${body}\n` +
    `Invoke-RestMethod -Uri '${uri}' -OutFile ${literal(copied)}\n` +
    `if ((Invoke-WebRequest -Uri '${uri}' -Method Head -UseBasicParsing).StatusCode -ne 200) { throw 'HEAD failed' }\n` +
    `foreach ($request in @('https://example.com/', '${uri}?changed')) { $refused=$false; try { Invoke-RestMethod -Uri $request } catch { $refused=$true }; if (-not $refused) { throw 'Unexpected external request accepted' } }\n` +
    `foreach ($method in @('Get','Head')) { $refused=$false; try { Read-WinsmuxFixtureResponse -Uri '${uri}/missing' -Method $method } catch { $refused=$_.Exception.Message -match '404 Not Found' }; if (-not $refused) { throw 'Optional source absence was not preserved' } }\n` +
    `$refused=$false; try { Invoke-WebRequest -Uri '${uri}' -Method Post } catch { $refused=$true }; if (-not $refused) { throw 'Unexpected method accepted' }\n` +
    `[IO.File]::AppendAllText(${literal(responseFile)},'changed'); $refused=$false; try { Invoke-WebRequest -Uri '${uri}' -Method Head } catch { $refused=$true }; if (-not $refused) { throw 'Altered HEAD accepted' }\n` +
    `Write-Output 'fixture-http-proof-complete'\n`);
  const result = spawnSync('pwsh', ['-NoProfile', '-File', script], { cwd: repo, encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), 'fixture-http-proof-complete');
  assert.deepEqual(fs.readFileSync(copied), response);
});
