import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

function requireValue(value, reason) { if (!value) throw new Error(reason); }
const hash = raw => createHash('sha256').update(raw).digest('hex');
const normalize = text => text.replace(/[A-Z\\]/gu, character => character === '\\' ? '/' : character.toLowerCase());

export function coreLocalPathPrefixes(repoRoot, env = process.env) {
  const profile = env.USERPROFILE || os.homedir();
  return [repoRoot, profile, env.CARGO_HOME || path.join(profile, '.cargo'),
    env.RUSTUP_HOME || path.join(profile, '.rustup')];
}

// Read the same closed, stored ZIP32 format emitted by stage-core-release.mjs.
// Any other representation is unscannable and must fail, never count as clean.
function storedMembers(raw) {
  const end = raw.length - 22;
  requireValue(end >= 0 && raw.readUInt32LE(end) === 0x06054b50 && raw.readUInt32LE(end + 4) === 0
    && raw.readUInt16LE(end + 20) === 0, 'Unscannable Core ZIP directory.');
  const count = raw.readUInt16LE(end + 10), start = raw.readUInt32LE(end + 16);
  requireValue(count > 0 && count < 65535 && raw.readUInt16LE(end + 8) === count
    && start + raw.readUInt32LE(end + 12) === end, 'Unscannable Core ZIP inventory.');
  const members = [], names = new Set(); let central = start, local = 0;
  for (let index = 0; index < count; index++) {
    requireValue(central + 46 <= end && raw.readUInt32LE(central) === 0x02014b50,
      'Unscannable Core ZIP member.');
    const nameLength = raw.readUInt16LE(central + 28), size = raw.readUInt32LE(central + 24);
    const next = central + 46 + nameLength;
    requireValue(nameLength > 0 && next <= end && raw.readUInt16LE(central + 30) === 0
      && raw.readUInt16LE(central + 32) === 0 && raw.readUInt16LE(central + 34) === 0
      && [0, 0x800].includes(raw.readUInt16LE(central + 8)) && raw.readUInt16LE(central + 10) === 0
      && raw.readUInt32LE(central + 20) === size && raw.readUInt32LE(central + 42) === local
      && local + 30 <= start && raw.readUInt32LE(local) === 0x04034b50,
    'Unscannable Core ZIP representation.');
    const content = local + 30 + nameLength;
    requireValue(content + size <= start && raw.readUInt16LE(local + 6) === raw.readUInt16LE(central + 8)
      && raw.readUInt16LE(local + 8) === 0 && raw.readUInt32LE(local + 14) === raw.readUInt32LE(central + 16)
      && raw.readUInt32LE(local + 18) === size && raw.readUInt32LE(local + 22) === size
      && raw.readUInt16LE(local + 26) === nameLength && raw.readUInt16LE(local + 28) === 0
      && raw.subarray(local + 30, content).equals(raw.subarray(central + 46, next)),
    'Unscannable Core ZIP local record.');
    const name = new TextDecoder('utf-8', { fatal: true }).decode(raw.subarray(local + 30, content));
    requireValue(!names.has(name.toLowerCase()), 'Unscannable duplicate Core ZIP member.');
    names.add(name.toLowerCase()); members.push([name, raw.subarray(content, content + size)]);
    local = content + size; central = next;
  }
  requireValue(central === end && local === start, 'Unscannable Core ZIP trailing bytes.');
  return members;
}

export function scanCoreLocalPaths(files, prefixes) {
  requireValue(files instanceof Map && files.size > 0 && Array.isArray(prefixes) && prefixes.length > 0
    && prefixes.every(prefix => typeof prefix === 'string' && path.isAbsolute(prefix) && !/[\0\r\n]/u.test(prefix)),
  'Explicit Core artifacts and absolute forbidden path prefixes required.');
  const needles = [...new Set(prefixes.map(prefix => normalize(prefix).replace(/\/+$/u, '')))];
  requireValue(needles.every(prefix => prefix.length > 0), 'Non-empty forbidden path prefixes required.');
  const count = raw => {
    const text = normalize(raw.toString('latin1')), offsets = new Set();
    for (const encoding of ['utf8', 'utf16le']) {
      for (const prefix of needles) {
        const needle = normalize(Buffer.from(prefix, encoding).toString('latin1'));
        let offset = text.indexOf(needle);
        while (offset >= 0) { offsets.add(offset); offset = text.indexOf(needle, offset + needle.length); }
      }
    }
    // Also refuse foreign producer profiles, which need not match this collector's environment.
    // Product detection strings may be adjacent in the image. Require a legal
    // Windows directory component, so C:\Users\C:\\Users\\ is not a profile.
    for (const pattern of [/[a-z]:\/users\/[^\x00-\x1f/<>:"|?*]+\//gu,
      /[a-z]\0:\0\/\0u\0s\0e\0r\0s\0\/\0(?:(?![\x00-\x1f/<>:"|?*]\0)[\s\S]{2})+\/\0/gu]) {
      for (const match of text.matchAll(pattern)) offsets.add(match.index);
    }
    return offsets.size;
  };
  const rows = [];
  for (const [name, raw] of files) {
    requireValue(typeof name === 'string' && name.length > 0 && Buffer.isBuffer(raw) && raw.length > 0,
      'Unscannable Core artifact bytes.');
    const members = name.toLowerCase().endsWith('.zip') ? storedMembers(raw).map(([member, bytes]) => ({
      path: member, sha256: hash(bytes), bytes: bytes.length, matches: count(bytes) + count(Buffer.from(member)) })) : [];
    // Stored members were scanned above; don't double count them in the ZIP container.
    rows.push({ path: name, bytes: raw.length, sha256: hash(raw),
      matches: members.length ? members.reduce((sum, member) => sum + member.matches, 0) : count(raw), members });
  }
  const matches = rows.reduce((sum, row) => sum + row.matches, 0);
  return { schema: 'core-local-path-scan/v1', accepted: matches === 0, matches, files: rows };
}

export function assertCoreLocalPaths(files, prefixes) {
  const report = scanCoreLocalPaths(files, prefixes);
  requireValue(report.accepted, `Core artifacts contain local build paths (${report.matches} matches).`);
  return report;
}
