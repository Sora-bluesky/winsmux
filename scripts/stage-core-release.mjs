import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { physicalPath, checkedPowerShellEnvironment } from './distribution-prelaunch.mjs';
import { assertWindowsRuntime } from './assert-windows-runtime.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const assets = new Map([['x86_64-pc-windows-msvc', 'winsmux-x64.exe'],
  ['aarch64-pc-windows-msvc', 'winsmux-arm64.exe']]);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(value, reason) { if (!value) throw new Error(reason); }
function exact(value, fields) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join('\0') === fields.slice().sort().join('\0');
}


function memberName(name) {
  requireValue(typeof name === 'string' && name.length > 0 && name.length <= 65535
    && /^[A-Za-z0-9._/-]+$/u.test(name) && !name.startsWith('/')
    && name.split('/').every(part => part.length > 0 && part !== '.' && part !== '..'
      && !part.endsWith('.') && !/^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/iu.test(part)),
  'Unsafe license ZIP member name.');
}
const crcTable = Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? (value >>> 1) ^ 0xedb88320 : value >>> 1;
  return value >>> 0;
});
function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 255] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

// Deterministic ZIP32, stored members, fixed DOS epoch, no links or directory entries.
function zipMembers(files) {
  requireValue(files.size > 0 && files.size < 65535, 'ZIP32 entry count exceeded.');
  const local = [], central = [], seen = new Set(); let offset = 0;
  for (const [relative, bytes] of [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
    memberName(relative);
    const key = relative.toLowerCase();
    requireValue(!seen.has(key) && Buffer.isBuffer(bytes) && bytes.length < 0xffffffff,
      'Duplicate, non-byte or oversized ZIP member.');
    seen.add(key);
    const name = Buffer.from(relative), crc = crc32(bytes);
    const head = Buffer.alloc(30), record = Buffer.alloc(46);
    head.writeUInt32LE(0x04034b50); head.writeUInt16LE(20, 4); head.writeUInt16LE(0x800, 6);
    head.writeUInt16LE(0x21, 12); head.writeUInt32LE(crc, 14);
    head.writeUInt32LE(bytes.length, 18); head.writeUInt32LE(bytes.length, 22); head.writeUInt16LE(name.length, 26);
    record.writeUInt32LE(0x02014b50); record.writeUInt16LE(20, 4); record.writeUInt16LE(20, 6);
    record.writeUInt16LE(0x800, 8); record.writeUInt16LE(0x21, 14); record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(bytes.length, 20); record.writeUInt32LE(bytes.length, 24);
    record.writeUInt16LE(name.length, 28); record.writeUInt32LE(offset, 42);
    local.push(head, name, bytes); central.push(record, name); offset += head.length + name.length + bytes.length;
    requireValue(offset < 0xffffffff, 'ZIP32 local extent exceeded.');
  }
  for (const name of seen) {
    const parts = name.split('/');
    for (let i = 1; i < parts.length; i++) requireValue(!seen.has(parts.slice(0, i).join('/')),
      'License ZIP file/directory collision.');
  }
  const centralSize = central.reduce((sum, bytes) => sum + bytes.length, 0);
  requireValue(offset + centralSize + 22 < 0xffffffff, 'ZIP32 archive extent exceeded.');
  const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(files.size, 8); end.writeUInt16LE(files.size, 10);
  end.writeUInt32LE(centralSize, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, ...central, end]);
}

/** Serialization only: returns in-memory bytes, never stages or admits publication.
 * License Map must be derived by buildDistributionLicenses. Its inner identity and
 * closed inventory are preserved; this function supplies no native licensing grant.
 */
export function renderCoreRelease(request) {
  requireValue(exact(request, ['version', 'target', 'executable', 'licenses'])
    && typeof request.version === 'string' && /^\d+\.\d+\.\d+$/u.test(request.version) && assets.has(request.target)
    && Buffer.isBuffer(request.executable) && request.licenses instanceof Map,
  'Invalid Core serialization input.');
  // Every caller uses this launch boundary, including private preparation and
  // public target generation. Keep the checked snapshot explicit at the child.
  const environment = checkedPowerShellEnvironment(repo);
  const { version, target, executable, licenses } = request;
  assertWindowsRuntime(executable, target);
  const innerBytes = licenses.get('manifest.json');
  requireValue(Buffer.isBuffer(innerBytes) && Buffer.isBuffer(licenses.get('THIRD_PARTY_NOTICES.txt')),
    'Complete license generation required.');
  const files = new Map();
  for (const [relative, bytes] of licenses) {
    memberName(relative); requireValue(Buffer.isBuffer(bytes), 'License payload must contain only bytes.');
    files.set('licenses/' + relative, Buffer.from(bytes));
  }
  const asset = assets.get(target), executableBytes = Buffer.from(executable);
  const manifest = { schema: 'winsmux-core-license-sidecar/v1', version, release_tag: 'v' + version,
    asset_name: asset, target, executable_sha256: hash(executableBytes), license_manifest_sha256: hash(innerBytes),
    files: [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([relative, bytes]) => ({ path: relative, bytes: bytes.length, sha256: hash(bytes) })) };
  files.set('manifest.json', Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  const archive = zipMembers(files), zipName = asset + '.licenses.zip';
  // A second schema decoder cannot predict ConvertFrom-Json's date/number types.
  // Validate the original ZIP through the unchanged consumer before returning it.
  const consumerSource = fs.readFileSync(physicalPath(path.join(repo, 'install.ps1')));
  const consumerHash = hash(consumerSource), archiveHash = hash(archive);
  const check = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File',
    physicalPath(path.join(repo, 'scripts/assert-core-sidecar.ps1'))], {
    cwd: repo, env: environment, windowsHide: true, encoding: 'utf8', input: JSON.stringify({ archive: archive.toString('base64'),
      archive_sha256: archiveHash, executable_sha256: hash(executableBytes), version, asset, target }),
  });
  requireValue(!check.error && check.status === 0 && check.signal === null && check.stderr === '',
    'Core sidecar consumer validation failed.');
  const receipt = parseStrictJson(Buffer.from(check.stdout));
  requireValue(exact(receipt, ['schema', 'accepted', 'consumer_source_sha256', 'archive_sha256', 'files'])
    && receipt.schema === 'core-sidecar-consumer-validation/v1' && receipt.accepted === true
    && receipt.consumer_source_sha256 === consumerHash && receipt.archive_sha256 === archiveHash
    && receipt.files === files.size, 'Core sidecar consumer validation response differs.');
  const checksums = Buffer.from(`${hash(executableBytes)}  ${asset}\n${hash(archive)}  ${zipName}\n`);
  return { publication_admitted: false, files: new Map([[asset, executableBytes], [zipName, archive], ['SHA256SUMS', checksums]]) };
}
