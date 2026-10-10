import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const machines = new Map([['x86_64-pc-windows-msvc', 0x8664],
  ['i686-pc-windows-msvc', 0x14c], ['aarch64-pc-windows-msvc', 0xaa64]]);
const systemDlls = new Set(['kernel32.dll', 'ntdll.dll', 'advapi32.dll', 'user32.dll',
  'userenv.dll', 'bcrypt.dll', 'bcryptprimitives.dll', 'shell32.dll', 'combase.dll',
  'secur32.dll', 'ws2_32.dll', 'ole32.dll', 'oleaut32.dll', 'crypt32.dll',
  'gdi32.dll', 'version.dll', 'winmm.dll', 'iphlpapi.dll', 'netapi32.dll',
  'shlwapi.dll', 'normaliz.dll', 'rpcrt4.dll', 'dbghelp.dll']);
// Exact API-set observed in both real release images. Microsoft inventory:
// https://learn.microsoft.com/en-us/uwp/win32-and-com/win32-apis
// Naming patterns cannot establish membership. Clean-host proof remains separate.
systemDlls.add('api-ms-win-core-synch-l1-2-0.dll');
// Windows handle API-set, documented since Windows 10.0.10240 in the same
// Microsoft inventory and observed in the hosted Windows CLI release image.
systemDlls.add('api-ms-win-core-handle-l1-1-0.dll');
function requireValue(value, reason) { if (!value) throw new Error(reason); }

/** Read-only image inspection. Both ordinary and delayed imports must be OS supplied.
 * This proves image dependencies, not licensing or execution on a clean Windows host.
 */
export function assertWindowsRuntime(bytes, target) {
  requireValue(Buffer.isBuffer(bytes) && machines.has(target), 'Supported Windows target and PE bytes required.');
  const range = (offset, size) => {
    requireValue(Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(size)
      && size >= 0 && offset + size <= bytes.length, 'Truncated PE image.');
    return offset;
  };
  const u16 = offset => bytes.readUInt16LE(range(offset, 2));
  const u32 = offset => bytes.readUInt32LE(range(offset, 4));
  requireValue(u16(0) === 0x5a4d, 'DOS header missing.');
  const pe = u32(0x3c);
  requireValue(pe >= 0x40 && u32(pe) === 0x4550, 'PE signature missing.');
  requireValue(u16(pe + 4) === machines.get(target), 'PE machine differs from the requested target.');
  const count = u16(pe + 6), optionalSize = u16(pe + 20), optional = pe + 24;
  requireValue(count > 0, 'PE section inventory missing.');
  range(optional, optionalSize);
  const magic = u16(optional), is64 = magic === 0x20b;
  requireValue(magic === (target === 'i686-pc-windows-msvc' ? 0x10b : 0x20b), 'PE optional-header architecture differs.');
  const directoryOffset = is64 ? 112 : 96;
  requireValue(optionalSize >= directoryOffset, 'PE optional header is incomplete.');
  const directories = u32(optional + directoryOffset - 4);
  requireValue(directories >= 14 && directories <= 16
    && directoryOffset + directories * 8 <= optionalSize, 'PE import directory inventory is incomplete.');
  const headers = u32(optional + 60), sectionTable = optional + optionalSize;
  const imageSize = u32(optional + 56);
  const pointerWidth = is64 ? 8 : 4;
  const pointer = offset => is64 ? bytes.readBigUInt64LE(range(offset, 8)) : BigInt(u32(offset));
  const imageBase = is64 ? pointer(optional + 24) : BigInt(u32(optional + 28));
  range(sectionTable, count * 40);
  requireValue(headers >= sectionTable + count * 40 && headers <= bytes.length, 'Invalid PE header extent.');
  const sections = [];
  for (let i = 0; i < count; i++) {
    const row = sectionTable + i * 40;
    const virtualSize = u32(row + 8), rva = u32(row + 12), rawSize = u32(row + 16), raw = u32(row + 20);
    range(raw, rawSize);
    const extent = Math.max(virtualSize, rawSize);
    requireValue(rva >= headers && rva + extent <= imageSize
      && !sections.some(s => rva < s.rva + s.extent && s.rva < rva + extent), 'Ambiguous PE section mapping.');
    requireValue(rawSize === 0 || (raw >= headers
      && !sections.some(s => s.rawSize && raw < s.raw + s.rawSize && s.raw < raw + rawSize)), 'Ambiguous PE raw mapping.');
    sections.push({ rva, raw, rawSize, extent });
  }
  const mapped = (rva, size) => {
    requireValue(rva > 0 && size > 0 && rva + size <= 0x100000000, 'Invalid PE RVA.');
    if (rva < headers) { requireValue(rva + size <= headers, 'PE RVA crosses headers.'); return range(rva, size); }
    const matches = sections.filter(s => rva >= s.rva && rva + size <= s.rva + s.rawSize);
    requireValue(matches.length === 1, 'PE RVA has no unique stored bytes.');
    return range(matches[0].raw + rva - matches[0].rva, size);
  };
  requireValue(imageBase > 0n && imageSize >= headers && imageBase + BigInt(imageSize) <= (1n << BigInt(pointerWidth * 8)), 'Invalid PE image extent.');
  // One region inventory covers both descriptor graphs. Only exact shared names
  // may alias; an OFT0 lookup/IAT is explicitly represented as one table.
  const regions = [];
  const ordinaryIats = [];
  const claim = (rva, size, kind, shared = false) => {
    const offset = mapped(rva, size);
    requireValue(rva >= headers, 'Import structure is inside PE headers.');
    for (const region of regions) {
      if (rva < region.rva + region.size && region.rva < rva + size) {
        requireValue(shared && region.shared && kind === region.kind && rva === region.rva && size === region.size,
          'Overlapping PE import structures.');
        return offset;
      }
    }
    regions.push({ rva, size, kind, shared }); return offset;
  };
  // Closed inventory of all four import-related optional-header directories.
  // Descriptor walkers consume these mapped objects; no parallel header reads.
  const importDirectories = new Map([1, 11, 12, 13].map(index => {
    const entry = optional + directoryOffset + index * 8;
    const rva = u32(entry), size = u32(entry + 4);
    if (rva === 0 && size === 0) return [index, null];
    requireValue(rva !== 0 && size !== 0, 'Half-present PE import directory.');
    const offset = mapped(rva, size);
    requireValue(rva >= headers, 'Import directory is inside PE headers.');
    return [index, { rva, size, offset }];
  }));
  requireValue(importDirectories.get(11) === null, 'Bound imports are unsupported.');
  const asciiName = (rva, prefix, kind) => {
    const output = [];
    for (let i = 0; ; i++) {
      const byte = bytes[mapped(rva + prefix + i, 1)];
      if (byte === 0) break;
      requireValue(byte >= 0x21 && byte <= 0x7e, 'Invalid PE import name.');
      output.push(byte);
    }
    requireValue(output.length > 0, 'Empty PE import name.');
    claim(rva, prefix + output.length + 1, kind, true);
    return Buffer.from(output).toString('ascii');
  };
  const dllName = rva => {
    const name = asciiName(rva, 0, 'DLL name').toLowerCase();
    requireValue(/^[a-z0-9_-]+\.dll$/u.test(name), 'Invalid PE DLL name.');
    requireValue(systemDlls.has(name),
      `Non-system or unsupported runtime dependency: ${name}`);
    return name;
  };
  const lookupTable = (rva, kind) => {
    requireValue(rva % pointerWidth === 0, 'Misaligned PE import table.');
    const values = [];
    for (let offset = 0; ; offset += pointerWidth) {
      const value = pointer(mapped(rva + offset, pointerWidth));
      if (value === 0n) break;
      values.push(value);
    }
    requireValue(values.length > 0, 'Empty PE import table.');
    claim(rva, (values.length + 1) * pointerWidth, kind);
    const ordinalBit = 1n << BigInt(pointerWidth * 8 - 1);
    for (const value of values) {
      if (value & ordinalBit) {
        requireValue((value & ~(ordinalBit | 0xffffn)) === 0n && (value & 0xffffn) !== 0n, 'Invalid PE import ordinal.');
      } else {
        requireValue(value <= 0x7fffffffn && value % 2n === 0n, 'Invalid PE hint/name RVA.');
        const hint = Number(value); u16(mapped(hint, 2)); asciiName(hint, 2, 'hint/name');
      }
    }
    return values;
  };
  const addressTable = (rva, values, delayed) => {
    requireValue(rva % pointerWidth === 0, 'Misaligned PE address table.');
    const start = claim(rva, (values.length + 1) * pointerWidth, 'IAT');
    requireValue(pointer(start + values.length * pointerWidth) === 0n, 'Unterminated PE address table.');
    for (let i = 0; i < values.length; i++) {
      const value = pointer(start + i * pointerWidth);
      if (!delayed) requireValue(value === values[i], 'Unbound PE lookup/address tables differ.');
      else {
        requireValue(value >= imageBase && value < imageBase + BigInt(imageSize), 'Invalid delay thunk address.');
        mapped(Number(value - imageBase), 1);
      }
    }
  };
  // Bound images and optional delay binding/unload forms are not part of the
  // measured release-build contract. Reject rather than partially interpret them.
  const readDirectory = (directory, rowSize, delayed) => {
    if (directory === null) return [];
    const { rva, size, offset: start } = directory;
    requireValue(size >= rowSize, 'Invalid PE import directory.');
    claim(rva, size, delayed ? 'delay descriptors' : 'import descriptors');
    const imports = [];
    let terminated = false;
    for (let offset = 0; offset + rowSize <= size; offset += rowSize) {
      const row = start + offset;
      const words = Array.from({ length: rowSize / 4 }, (_, n) => u32(row + n * 4));
      if (words.every(word => word === 0)) {
        requireValue(bytes.subarray(row + rowSize, start + size).every(byte => byte === 0), 'Unexpected data after import terminator.');
        terminated = true; break;
      }
      if (delayed) requireValue(words[0] === 1 && words[5] === 0 && words[6] === 0 && words[7] === 0,
        'Only unbound RVA-based PE delay imports without unload tables are supported.');
      else requireValue(words[1] === 0 && (words[2] === 0 || words[2] === 0xffffffff), 'Bound/forwarded PE imports are unsupported.');
      const nameRva = delayed ? words[1] : words[3];
      requireValue(nameRva !== 0 && (delayed ? words[3] !== 0 && words[4] !== 0 : words[4] !== 0), 'Incomplete PE import descriptor.');
      imports.push(dllName(nameRva));
      const addressRva = words[delayed ? 3 : 4], lookupRva = delayed ? words[4] : words[0];
      const sharedAddress = !delayed && lookupRva === 0;
      const values = lookupTable(sharedAddress ? addressRva : lookupRva, sharedAddress ? 'lookup/IAT' : 'lookup');
      if (!sharedAddress) addressTable(addressRva, values, delayed);
      if (!delayed) ordinaryIats.push({ rva: addressRva, size: (values.length + 1) * pointerWidth });
      if (delayed) {
        requireValue(words[2] % pointerWidth === 0, 'Misaligned delay module handle.');
        requireValue(pointer(claim(words[2], pointerWidth, 'module handle')) === 0n, 'Initialized delay module handle.');
      }
    }
    requireValue(terminated, 'PE import descriptors are unterminated.');
    return imports;
  };
  const imports = readDirectory(importDirectories.get(1), 20, false);
  const delayImports = readDirectory(importDirectories.get(13), 32, true);
  const aggregate = importDirectories.get(12);
  if (aggregate !== null) {
    requireValue(aggregate.rva % pointerWidth === 0 && ordinaryIats.length > 0,
      'IAT directory has no aligned ordinary table inventory.');
    ordinaryIats.sort((a, b) => a.rva - b.rva);
    let end = aggregate.rva;
    for (const table of ordinaryIats) {
      requireValue(table.rva === end, 'IAT directory differs from the complete ordinary table inventory.');
      end += table.size;
    }
    requireValue(end === aggregate.rva + aggregate.size,
      'IAT directory differs from the complete ordinary table inventory.');
  }
  return { schema: 'windows-runtime-proof/v1', target, bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'), imports, delay_imports: delayImports };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    requireValue(process.argv.length === 4, 'Usage: assert-windows-runtime.mjs <exe> <target>');
    console.log(JSON.stringify(assertWindowsRuntime(fs.readFileSync(process.argv[2]), process.argv[3])));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
