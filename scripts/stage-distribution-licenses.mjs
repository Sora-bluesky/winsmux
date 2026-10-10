import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { assertLicenseInputs, parseStrictJson } from './assert-license-inputs.mjs';
import { physicalPath } from './distribution-prelaunch.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function requireValue(condition, reason) { if (!condition) throw new Error(reason); }
function plain(file) {
  const resolved = physicalPath(file); const stat = fs.lstatSync(resolved);
  requireValue(stat.isFile() && stat.nlink === 1, 'License source must be a plain single-link file.');
  return fs.readFileSync(resolved);
}
function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function overlap(a, b) {
  const left = physicalPath(a).toLowerCase(); const right = physicalPath(b).toLowerCase();
  return left === right || left.startsWith(right + path.sep) || right.startsWith(left + path.sep);
}
function exists(file) {
  try { fs.lstatSync(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

/** Derive the complete expected generation from caller-frozen inputs without writing anything. */
export function buildDistributionLicenses({ policyPath, policySha256, inputPath, catalogPath,
  catalogSha256, textRoot, sourceRoot, version }) {
  requireValue(/^[a-f0-9]{64}$/u.test(catalogSha256 ?? '') && /^\d+\.\d+\.\d+$/u.test(version ?? ''),
    'Frozen catalog and product version are required.');
  const proof = assertLicenseInputs({ policyPath, policySha256, inputPath, textRoot });
  const catalogBytes = plain(catalogPath);
  requireValue(hash(catalogBytes) === catalogSha256, 'Frozen catalog differs.');
  const catalog = parseStrictJson(catalogBytes);
  const input = parseStrictJson(plain(inputPath));
  const policy = parseStrictJson(plain(policyPath));
  requireValue(catalog.schema === 'distribution-license-catalog/v1' && catalog.policy_sha256 === policySha256
    && Array.isArray(catalog.components) && catalog.components.length === policy.components.length
    && Array.isArray(catalog.source_obligations), 'Catalog component inventory differs.');
  const publicComponents = [];
  for (let i = 0; i < catalog.components.length; i += 1) {
    const entry = catalog.components[i]; const expected = policy.components[i]; const received = input.components[i];
    requireValue(entry.id === expected.id && entry.version === expected.version
      && entry.declared_license === expected.declared_license && entry.choice === expected.choice
      && received.id === entry.id && received.version === entry.version
      && same(entry.documents, received.documents.map(doc => ({ path: 'texts/' + doc.path, sha256: doc.sha256 }))),
    'Catalog attribution or text inventory differs.');
    // Copy only defined public fields. Local input/provenance paths never enter the artifact.
    publicComponents.push({ id: entry.id, version: entry.version, declared_license: entry.declared_license,
      choice: entry.choice, documents: entry.documents });
  }
  const files = new Map();
  function add(relative, bytes) { requireValue(!files.has(relative), 'Duplicate staged license path.'); files.set(relative, bytes); }
  const identities = new Set(input.components.flatMap(row => row.documents.map(doc => doc.sha256)));
  for (const identity of [...identities].sort()) {
    // The catalog uses content-addressed paths; reject an alternative spelling instead of guessing it.
    const rows = input.components.flatMap(row => row.documents).filter(doc => doc.sha256 === identity);
    requireValue(rows.every(row => row.path === identity), 'Text must use its exact content-addressed path.');
    const data = plain(path.join(textRoot, identity)); requireValue(hash(data) === identity, 'License text changed after input check.');
    add('texts/' + identity, data);
  }
  const obligations = [];
  const sourcePaths = new Set();
  for (const obligation of catalog.source_obligations) {
    if (!Object.hasOwn(obligation, 'source_path')) continue;
    requireValue(typeof obligation.source_path === 'string'
      && /^sources\/[A-Za-z0-9_-]+-\d+\.\d+\.\d+(?:[A-Za-z0-9_.+-]*)?\.crate$/u.test(obligation.source_path)
      && /^[a-f0-9]{64}$/u.test(obligation.source_archive_sha256)
      && /^https:\/\/crates\.io\/api\/v1\/crates\/[A-Za-z0-9_-]+\/[A-Za-z0-9_.+-]+\/download$/u.test(obligation.source_url)
      && policy.components.some(component => component.id === obligation.id && component.version === obligation.version
        && component.requirements.some(requirement => requirement.role === 'source_availability'))
      && !sourcePaths.has(obligation.source_path), 'Invalid covered-source obligation.');
    sourcePaths.add(obligation.source_path);
    const data = plain(path.join(sourceRoot, ...obligation.source_path.split('/')));
    requireValue(hash(data) === obligation.source_archive_sha256, 'Covered source archive differs.');
    add(obligation.source_path, data);
    obligations.push({ id: obligation.id, version: obligation.version, source_path: obligation.source_path,
      source_url: obligation.source_url, source_archive_sha256: obligation.source_archive_sha256 });
  }
  for (const component of policy.components.filter(row => row.requirements.some(rule => rule.role === 'source_availability'))) {
    requireValue(obligations.some(row => row.id === component.id && row.version === component.version),
      'Covered source archive is missing from the catalog.');
  }
  const manifest = { schema: 'distribution-license-generation/v1', version,
    policy_sha256: policySha256, input_sha256: proof.input_sha256, catalog_sha256: catalogSha256,
    components: publicComponents, source_obligations: obligations,
    files: [...files].map(([relative, bytes]) => ({ path: relative, bytes: bytes.length, sha256: hash(bytes) })) };
  add('manifest.json', Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  const header = ['winsmux ' + version + ' - third-party license and attribution texts',
    'This notice retains original component conditions; it does not relicense them.',
    'Covered-source archives and their hashes are listed in manifest.json.', '',
    ...publicComponents.map(row => `${row.id} ${row.version}: ${row.choice}`), ''].join('\n');
  add('THIRD_PARTY_NOTICES.txt', Buffer.concat([Buffer.from(header), ...[...identities].sort().flatMap(identity =>
    [Buffer.from('\n===== Original license document SHA-256 ' + identity + ' =====\n'), files.get('texts/' + identity), Buffer.from('\n')])]));
  return { files, components: publicComponents.length };
}

/** Stage validated, caller-frozen bytes in a new directory. Existing generations are never modified. */
export function stageDistributionLicenses(options) {
  const { policyPath, policySha256, inputPath, catalogPath, catalogSha256, textRoot, sourceRoot, destination, version } = options;
  const { files, components } = buildDistributionLicenses(options);
  // Every read and obligation is checked before creating a new owned staging directory.
  const out = physicalPath(destination);
  requireValue(path.isAbsolute(destination) && !exists(out) && fs.statSync(physicalPath(path.dirname(out))).isDirectory(),
    'License destination must be a new child of an existing plain directory.');
  for (const source of [policyPath, inputPath, catalogPath, textRoot, sourceRoot]) {
    requireValue(!overlap(out, source), 'License destination overlaps its protected input.');
  }
  fs.mkdirSync(out);
  const marker = path.join(out, '.licenses.pending');
  fs.writeFileSync(marker, JSON.stringify({ policy_sha256: policySha256, catalog_sha256: catalogSha256 }), { flag: 'wx' });
  for (const [relative, bytes] of files) {
    const file = path.join(out, ...relative.split('/')); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes, { flag: 'wx' });
    requireValue(hash(plain(file)) === hash(bytes), 'Staged license file differs.');
  }
  fs.unlinkSync(marker);
  return { status: 'license_inputs_staged', version, components,
    policy_sha256: policySha256, catalog_sha256: catalogSha256,
    manifest_sha256: hash(files.get('manifest.json')),
    files: [...files].map(([relative, bytes]) => ({ path: relative, bytes: bytes.length, sha256: hash(bytes) })),
    distribution_complete: false };
}
