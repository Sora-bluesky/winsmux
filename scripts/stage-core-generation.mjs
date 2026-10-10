import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { renderCoreRelease } from './stage-core-release.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(value, reason) { if (!value) throw new Error(reason); }
function writeNew(file, bytes) {
  const descriptor = fs.openSync(file, 'wx');
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
}
function readPlain(file) {
  const checked = physicalPath(file), stat = fs.lstatSync(checked);
  requireValue(stat.isFile() && stat.nlink === 1, 'Core staging file is not a plain single-link file.');
  return fs.readFileSync(checked);
}

/** Local staging follows the existing new-generation pattern. It supplies no
 * publication/redistribution authority and never replaces an existing directory.
 * Workspace ownership is exclusive; adversarial concurrent directory replacement
 * and automatic crash recovery are outside this local build-artifact operation.
 */
export function stageCoreGeneration(request) {
  // Consumer and PE refusal precede every directory/marker/write operation.
  const rendered = renderCoreRelease(request);
  const root = physicalPath(path.join(repo, '.winsmux/build/core-release'));
  requireValue(root === path.join(repo, '.winsmux/build/core-release'), 'Core staging namespace differs.');
  fs.mkdirSync(root, { recursive: true });
  const generation = `core-${request.version}-${request.target}-${randomUUID()}`;
  const directory = path.join(root, generation);
  fs.mkdirSync(directory);
  const files = [...rendered.files].map(([name, bytes]) => ({ path: name, bytes: bytes.length, sha256: hash(bytes) }));
  const marker = path.join(directory, '.core.pending');
  const pending = Buffer.from(JSON.stringify({ schema:'core-local-staging/v1', version:request.version,
    target:request.target, files }) + '\n');
  writeNew(marker, pending);
  for (const [name, bytes] of rendered.files) {
    const file = path.join(directory, name);
    writeNew(file, bytes);
    requireValue(readPlain(file).equals(bytes), 'Core staging readback differs.');
  }
  const expected = [...rendered.files.keys(), '.core.pending'].sort();
  requireValue(JSON.stringify(fs.readdirSync(directory).sort()) === JSON.stringify(expected),
    'Core staging inventory differs.');
  for (const [name, bytes] of rendered.files) {
    requireValue(readPlain(path.join(directory, name)).equals(bytes), 'Completed Core staging bytes differ.');
  }
  requireValue(readPlain(marker).equals(pending), 'Core pending identity differs.');
  // Only this successfully read-back generation loses its own pending marker.
  fs.unlinkSync(marker);
  return { schema:'core-local-staging/v1', state:'staged', directory, generation,
    version:request.version, target:request.target, files, publication_admitted:false };
}
