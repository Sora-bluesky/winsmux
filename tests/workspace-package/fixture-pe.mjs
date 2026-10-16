import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Synthetic PE images exercise dependency inspection, not native execution.
export function fixturePe({ machine = 0x8664, normal = [], delayed = [], marker = '', iatDirectory = true } = {}) {
  const bytes = Buffer.alloc(2048), pe = 0x80, optional = pe + 24;
  const is32 = machine === 0x14c, optionalSize = is32 ? 224 : 240;
  const directory = optional + (is32 ? 96 : 112), section = optional + optionalSize;
  bytes.writeUInt16LE(0x5a4d, 0); bytes.writeUInt32LE(pe, 0x3c); bytes.writeUInt32LE(0x4550, pe);
  bytes.writeUInt16LE(machine, pe + 4); bytes.writeUInt16LE(1, pe + 6);
  bytes.writeUInt16LE(optionalSize, pe + 20); bytes.writeUInt16LE(is32 ? 0x10b : 0x20b, optional);
  const imageBase = is32 ? 0x400000n : 0x140000000n;
  if (is32) bytes.writeUInt32LE(Number(imageBase), optional + 28);
  else bytes.writeBigUInt64LE(imageBase, optional + 24);
  bytes.writeUInt32LE(0x2000, optional + 56);
  bytes.writeUInt32LE(512, optional + 60); bytes.writeUInt32LE(16, directory - 4);
  bytes.writeUInt32LE(1536, section + 8); bytes.writeUInt32LE(0x1000, section + 12);
  bytes.writeUInt32LE(1536, section + 16); bytes.writeUInt32LE(512, section + 20);
  let names = 1400, lookups = 1064, addresses = 1216, handles = 1344;
  const width = is32 ? 4 : 8;
  const rva = offset => 0x1000 + offset - 512;
  const pointer = (offset, value) => is32 ? bytes.writeUInt32LE(Number(value), offset) : bytes.writeBigUInt64LE(value, offset);
  bytes.write('TestExport\0', 1802, 'ascii');
  if (normal.length && iatDirectory) {
    bytes.writeUInt32LE(rva(addresses), directory + 12 * 8);
    bytes.writeUInt32LE(normal.length * 2 * width, directory + 12 * 8 + 4);
  }
  for (const [list, index, rowWidth, offset, nameWord] of [[normal, 1, 20, 512, 3], [delayed, 13, 32, 900, 1]]) {
    if (!list.length) continue;
    bytes.writeUInt32LE(0x1000 + offset - 512, directory + index * 8);
    bytes.writeUInt32LE((list.length + 1) * rowWidth, directory + index * 8 + 4);
    for (let i = 0; i < list.length; i++) {
      const row = offset + i * rowWidth;
      if (index === 13) bytes.writeUInt32LE(1, row);
      bytes.writeUInt32LE(0x1000 + names - 512, row + nameWord * 4);
      const lookup = lookups, address = addresses;
      lookups += 2 * width; addresses += 2 * width;
      pointer(lookup, BigInt(rva(1800)));
      pointer(address, index === 13 ? imageBase + BigInt(rva(1850)) : BigInt(rva(1800)));
      bytes.writeUInt32LE(rva(address), row + (index === 13 ? 3 : 4) * 4);
      bytes.writeUInt32LE(rva(lookup), row + (index === 13 ? 4 : 0) * 4);
      if (index === 13) { bytes.writeUInt32LE(rva(handles), row + 8); handles += width; }
      names += bytes.write(list[i] + '\0', names, 'ascii');
    }
  }
  bytes.write(marker, 1900, 'utf8');
  return bytes;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , destination, marker, mode] = process.argv;
  const bytes = fixturePe({ marker,
    normal: [mode === 'dynamic' ? 'vcruntime140.dll' : mode === 'unknown-api' ? 'api-ms-win-core-review-unknown-l999-9-9.dll' : 'KERNEL32.dll'],
    delayed: mode === 'delayed' ? ['msvcp140.dll'] : mode === 'unknown-delay-api' ? ['api-ms-win-core-review-unknown-l999-9-9.dll'] : mode === 'unmapped-delay' ? ['user32.dll'] : [],
    machine: mode === 'wrong-cpu' ? 0xaa64 : 0x8664 });
  if (mode === 'unmapped-import') bytes.writeUInt32LE(0xfffffff0, 528);
  if (mode === 'unmapped-delay') { bytes.writeUInt32LE(0xfffffff0, 912); bytes.writeUInt32LE(0xfffffff0, 916); }
  if (mode === 'unmapped-iat') bytes.writeUInt32LE(0xfffffff0, optionalDirectory(bytes) + 12 * 8);
  if (mode === 'partial-iat') bytes.writeUInt32LE(8, optionalDirectory(bytes) + 12 * 8 + 4);
  fs.writeFileSync(destination, bytes);
}

function optionalDirectory(bytes) { return 0x80 + 24 + (bytes.readUInt16LE(0x80 + 24) === 0x10b ? 96 : 112); }
