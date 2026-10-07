import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { physicalPath, checkedPowerShellEnvironment } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertWindowsRuntime } from './assert-windows-runtime.mjs';
import { coreSourceInventory, coreSourceInventoryIdentity } from './build-core-candidate.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(value, reason) { if (!value) throw new Error(reason); }
function plain(file) {
  const name = physicalPath(file), stat = fs.lstatSync(name);
  requireValue(stat.isFile() && stat.nlink === 1, 'Fixture input must be a plain single-link file.');
  return fs.readFileSync(name);
}
function git(args, input) {
  const result = spawnSync('git', args, { cwd: repo, input, windowsHide: true, maxBuffer: 256 * 1024 * 1024 });
  requireValue(!result.error && result.status === 0 && result.signal === null, 'Fixture Git source read failed.');
  return result.stdout;
}

// Only this explicit test artifact changes transport. The production installer,
// its guards, npm index and shim are not edited. The private fixture must never
// be published or counted as public-release acquisition evidence.
export function prepareInstallFixture({ candidateDirectory, sourceCommit, version, output }) {
  requireValue(/^[a-f0-9]{40}$/u.test(sourceCommit) && /^\d+\.\d+\.\d+$/u.test(version), 'Exact fixture coordinates required.');
  requireValue(git(['rev-parse', 'HEAD']).toString('utf8').trim() === sourceCommit
    && plain(path.join(repo, 'VERSION')).toString('utf8').trim() === version, 'Fixture checkout coordinates differ.');
  const candidate = physicalPath(candidateDirectory), destination = physicalPath(output);
  requireValue(path.isAbsolute(candidateDirectory) && path.isAbsolute(output) && !fs.existsSync(destination), 'Fresh absolute fixture output required.');
  const names = ['SHA256SUMS', 'core-candidate.json', 'winsmux-x64.exe', 'winsmux-x64.exe.licenses.zip'];
  requireValue(JSON.stringify(fs.readdirSync(candidate).sort()) === JSON.stringify(names), 'Candidate fixture asset inventory differs.');
  const receipt = parseStrictJson(plain(path.join(candidate, 'core-candidate.json')));
  const original = git(['cat-file', 'blob', `${sourceCommit}:install.ps1`]);
  requireValue(original.equals(plain(path.join(repo, 'install.ps1'))), 'Fixture installer differs from its committed source.');
  requireValue(receipt.schema === 'core-ci-candidate/v1' && receipt.source_commit === sourceCommit
    && receipt.version === version && receipt.release_tag === 'v' + version && receipt.target === 'x86_64-pc-windows-msvc'
    && receipt.consumer_source_sha256 === digest(original) && receipt.build_origin_verified === true
    && receipt.native_redistribution_verified === false && receipt.publication_admitted === false
    && receipt.source_inventory_sha256 === coreSourceInventoryIdentity(coreSourceInventory())
    && receipt.compiler?.host === 'x86_64-pc-windows-msvc' && receipt.compiler?.release === '1.96.0'
    && receipt.compiler?.commit === 'ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96', 'Same-source private Core candidate receipt required.');
  const assets = new Map();
  requireValue(Array.isArray(receipt.files) && receipt.files.length === 3, 'Candidate asset receipt is incomplete.');
  for (const row of receipt.files) {
    requireValue(names.includes(row.path) && row.path !== 'core-candidate.json' && !assets.has(row.path), 'Candidate receipt has an unexpected asset.');
    const bytes = plain(path.join(candidate, row.path));
    requireValue(bytes.length === row.bytes && digest(bytes) === row.sha256, 'Candidate asset bytes differ.');
    assets.set(row.path, bytes);
  }
  assertWindowsRuntime(assets.get('winsmux-x64.exe'), receipt.target);
  requireValue(digest(assets.get('winsmux-x64.exe')) === receipt.executable_sha256, 'Candidate executable identity differs.');
  const exeHash = digest(assets.get('winsmux-x64.exe')), archiveHash = digest(assets.get('winsmux-x64.exe.licenses.zip'));
  requireValue(assets.get('SHA256SUMS').equals(Buffer.from(`${exeHash}  winsmux-x64.exe\n${archiveHash}  winsmux-x64.exe.licenses.zip\n`)), 'Candidate paired checksums differ.');
  const sidecar = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(repo, 'scripts/assert-core-sidecar.ps1')], {
    cwd: repo, env: checkedPowerShellEnvironment(repo), windowsHide: true, encoding: 'utf8',
    input: JSON.stringify({ archive: assets.get('winsmux-x64.exe.licenses.zip').toString('base64'),
      archive_sha256: archiveHash, executable_sha256: exeHash, version, asset: 'winsmux-x64.exe', target: receipt.target }),
  });
  requireValue(!sidecar.error && sidecar.status === 0 && sidecar.signal === null && sidecar.stderr === '', 'Candidate sidecar consumer validation failed.');
  const sidecarProof = parseStrictJson(Buffer.from(sidecar.stdout));
  requireValue(sidecarProof.accepted === true && sidecarProof.archive_sha256 === archiveHash
    && sidecarProof.consumer_source_sha256 === digest(original), 'Candidate sidecar consumer receipt differs.');
  const tag = 'v' + version;
  const tree = git(['ls-tree', '-rz', '--full-tree', sourceCommit]).toString('utf8').split('\0').filter(Boolean).map(line => {
    const match = /^100(?:644|755) blob ([a-f0-9]{40})\t(.+)$/u.exec(line);
    requireValue(match && match[2].split('/').every(part => part && part !== '.' && part !== '..')
      && !/[\\:\x00-\x1f]/u.test(match[2]), 'Unexpected fixture source tree member.');
    return { blob: match[1], path: match[2] };
  });
  const blobs = git(['cat-file', '--batch'], Buffer.from(tree.map(row => row.blob + '\n').join('')));
  fs.mkdirSync(destination);
  fs.mkdirSync(path.join(destination, 's'));
  const responses = Object.create(null), sourceRows = [];
  let offset = 0, member = 0;
  function snapshot(bytes) {
    const file = path.join(destination, 's', String(member++));
    fs.writeFileSync(file, bytes, { flag: 'wx' });
    requireValue(plain(file).equals(bytes), 'Fixture source snapshot readback differs.');
    return { file, sha256: digest(bytes), bytes: bytes.length };
  }
  for (const row of tree) {
    const end = blobs.indexOf(10, offset);
    const header = /^([a-f0-9]{40}) blob (\d+)$/u.exec(blobs.subarray(offset, end).toString('ascii'));
    requireValue(header && header[1] === row.blob, 'Ambiguous fixture Git blob response.');
    const length = Number(header[2]);
    requireValue(Number.isSafeInteger(length) && blobs[end + 1 + length] === 10, 'Incomplete fixture Git blob bytes.');
    const bytes = blobs.subarray(end + 1, end + 1 + length); offset = end + 2 + length;
    const saved = snapshot(bytes);
    sourceRows.push({ path: row.path, ...saved });
    for (const ref of [sourceCommit, tag, 'main']) responses[`https://raw.githubusercontent.com/Sora-bluesky/winsmux/${ref}/${row.path}`] = { ...saved, kind: 'text' };
  }
  requireValue(offset === blobs.length, 'Unexpected trailing fixture Git bytes.');
  for (const match of original.toString('utf8').matchAll(/^[ \t]+Download-OptionalFile "([^"\r\n]+)"/gmu)) {
    for (const ref of [sourceCommit, tag, 'main']) {
      const url = `https://raw.githubusercontent.com/Sora-bluesky/winsmux/${ref}/${match[1]}`;
      if (!Object.hasOwn(responses, url)) responses[url] = { kind: 'missing' };
    }
  }
  const releaseAssets = [];
  for (const [name, bytes] of assets) {
    const url = 'https://winsmux-fixture.invalid/assets/' + name;
    responses[url] = { ...snapshot(bytes), kind: 'file' };
    releaseAssets.push({ name, browser_download_url: url });
  }
  const release = snapshot(Buffer.from(JSON.stringify({ tag_name: tag, assets: releaseAssets })));
  for (const suffix of ['latest', 'tags/' + tag]) responses['https://api.github.com/repos/Sora-bluesky/winsmux/releases/' + suffix] = { ...release, kind: 'json' };
  const manifest = Buffer.from(JSON.stringify({ schema: 'install-e2e-transport/v1', source_commit: sourceCommit, version, responses }));
  const mapFile = path.join(destination, 'transport.json');
  fs.writeFileSync(mapFile, manifest, { flag: 'wx' });
  const literal = value => "'" + value.replaceAll("'", "''") + "'";
  const transport = `
# Explicit private fixture transport; no external HTTP, no header logging.
$script:WinsmuxFixtureMapPath = ${literal(mapFile)}
$script:WinsmuxFixtureMapHash = '${digest(manifest)}'
function Read-WinsmuxFixtureResponse {
    param([string]$Uri, [string]$Method = 'Get', [string]$OutFile = '')
    $raw = [IO.File]::ReadAllBytes($script:WinsmuxFixtureMapPath)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant() -cne $script:WinsmuxFixtureMapHash) { throw 'Fixture transport identity differs.' }
    $map = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json -AsHashtable
    if ($Method -cnotin @('Get','Head') -or -not $map.responses.ContainsKey($Uri)) { throw 'Unmapped fixture request refused.' }
    $row = $map.responses[$Uri]
    if ($row.kind -ceq 'missing') { throw '404 Not Found: declared optional fixture source is absent.' }
    $bytes = [IO.File]::ReadAllBytes($row.file)
    if ($bytes.Length -ne $row.bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $row.sha256) { throw 'Fixture response bytes differ.' }
    if ($Method -ceq 'Head') { return [pscustomobject]@{ StatusCode = 200 } }
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $bytes); return }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($row.kind -ceq 'json') { return ($text | ConvertFrom-Json) }
    return $text
}
function Invoke-RestMethod {
    [CmdletBinding()] param([string]$Uri, [hashtable]$Headers, [string]$OutFile, [string]$Method = 'Get')
    Read-WinsmuxFixtureResponse -Uri $Uri -Method $Method -OutFile $OutFile
}
function Invoke-WebRequest {
    [CmdletBinding()] param([string]$Uri, [hashtable]$Headers, [string]$OutFile, [string]$Method = 'Get', [switch]$UseBasicParsing)
    Read-WinsmuxFixtureResponse -Uri $Uri -Method $Method -OutFile $OutFile
}
`;
  const text = new TextDecoder('utf-8', { fatal: true }).decode(original);
  const anchor = '\nfunction Assert-WinsmuxReleaseTag {';
  requireValue(text.indexOf(anchor) > 0 && text.indexOf(anchor) === text.lastIndexOf(anchor), 'Installer transport insertion anchor differs.');
  const position = text.indexOf(anchor);
  const projected = Buffer.from(text.slice(0, position) + transport + text.slice(position));
  requireValue(Buffer.from(projected.toString('utf8').replace(transport, '')).equals(original), 'Fixture projection changed the product installer body.');
  const installer = path.join(destination, 'install.ps1');
  fs.writeFileSync(installer, projected, { flag: 'wx' });
  const proof = { schema: 'install-e2e-fixture/v1', installer, source_commit: sourceCommit, version,
    original_installer_sha256: digest(original), fixture_installer_sha256: digest(projected), transport_sha256: digest(manifest),
    product_body_unchanged: true, source_snapshot: sourceRows, candidate_receipt_sha256: digest(plain(path.join(candidate, 'core-candidate.json'))),
    public_release_acquisition_proven: false, native_redistribution_verified: false };
  fs.writeFileSync(path.join(destination, 'fixture.json'), JSON.stringify(proof, null, 2) + '\n', { flag: 'wx' });
  return proof;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    requireValue(process.argv.length === 6, 'Usage: prepare-install-e2e-fixture.mjs <candidate-dir> <commit> <version> <fresh-output>');
    const proof = prepareInstallFixture({ candidateDirectory: process.argv[2], sourceCommit: process.argv[3], version: process.argv[4], output: process.argv[5] });
    console.log(JSON.stringify({ ...proof, source_snapshot: undefined }));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
