import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { createHash, randomUUID } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { parseStrictJson } from './assert-license-inputs.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';

// This parent adapter observes public bytes for the approved frozen-attempt
// recovery contract. It never changes a release, registry, tag, attempt marker,
// credentials or OS settings. A pure payload result cannot mint observed origin.
const repository = 'Sora-bluesky/winsmux';
const api = 'https://api.github.com/repos/' + repository;
const tag = 'v0.38.0';
const npmVersion = 'https://registry.npmjs.org/winsmux/0.38.0';
const npmArchive = 'https://registry.npmjs.org/winsmux/-/winsmux-0.38.0.tgz';
const issued = new WeakMap();
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const positive = value => Number.isSafeInteger(value) && value > 0;
const freeze = value => { if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
function expectedReleaseAssets(bundle) {
  return new Map(bundle.assets.filter(row => row.path.startsWith('core/') || row.path.startsWith('desktop/'))
    .map(row => [path.posix.basename(row.path), row]));
}
function assetCoordinates(asset) {
  return { id: asset.id, name: asset.name, size: asset.size, state: asset.state,
    url: asset.url, browser_download_url: asset.browser_download_url, digest: asset.digest ?? null,
    created_at: asset.created_at, updated_at: asset.updated_at };
}
function releaseCoordinates(release) {
  return release === null ? null : { id: release.id, url: release.url, html_url: release.html_url,
    tag_name: release.tag_name, draft: release.draft, prerelease: release.prerelease, body: release.body };
}
function npmCoordinates(metadata) {
  return metadata === null ? null : { name: metadata.name, version: metadata.version, dist: metadata.dist, gitHead: metadata.gitHead ?? null };
}

/** Pure metadata validation; absent expected assets remain incomplete. */
export function validatePublicReleaseInventory(bundle, release, resolvedCommit, assets) {
  assertIssuedPublicationBundle(bundle);
  demand(Array.isArray(assets), 'Complete actual release inventory required.');
  if (release === null) {
    demand(assets.length === 0 && resolvedCommit === null, 'Absent release has inconsistent observations.');
    return freeze({ release_present: false, assets: [], publication_admitted: false });
  }
  demand(positive(release.id) && release.url === `${api}/releases/${release.id}`
    && release.html_url === `https://github.com/${repository}/releases/tag/${tag}`
    && release.tag_name === tag && release.draft === false && release.prerelease === false
    && typeof release.body === 'string' && resolvedCommit === bundle.identity.source_commit,
  'Public release identity, tag source or visibility differs.');
  const expected = expectedReleaseAssets(bundle), ids = new Set(), names = new Set();
  for (const asset of assets) {
    const row = expected.get(asset?.name);
    demand(row && positive(asset.id) && !ids.has(asset.id) && !names.has(asset.name)
      && asset.state === 'uploaded' && asset.size === row.bytes
      && asset.url === `${api}/releases/assets/${asset.id}`
      && asset.browser_download_url === `https://github.com/${repository}/releases/download/${tag}/${asset.name}`
      && (asset.digest == null || asset.digest === 'sha256:' + row.sha256),
    'Public asset inventory, identity, size or digest differs.');
    ids.add(asset.id); names.add(asset.name);
  }
  return freeze({ release_present: true, assets: assets.map(assetCoordinates).sort((a, b) => a.name.localeCompare(b.name, 'en')),
    publication_admitted: false });
}

/** Exact binary correspondence, not metadata digest alone, is required. */
export function validatePublicAssetBytes(bundle, relative, bytes) {
  assertIssuedPublicationBundle(bundle);
  const row = bundle.assets.find(asset => asset.path === relative);
  demand(row && Buffer.isBuffer(bytes) && bytes.length === row.bytes && sha(bytes) === row.sha256,
    'Downloaded public bytes differ from frozen candidate.');
  return freeze({ path: relative, state: 'matching', sha256: row.sha256 });
}
export function validatePublicNpmMetadata(bundle, metadata) {
  assertIssuedPublicationBundle(bundle);
  demand(metadata?.name === 'winsmux' && metadata.version === bundle.identity.version
    && metadata.dist?.tarball === npmArchive && /^[a-f0-9]{40}$/u.test(metadata.dist?.shasum ?? '')
    && (metadata.gitHead === undefined || metadata.gitHead === bundle.identity.source_commit),
  'Public npm version, source or tarball destination differs.');
  if (metadata.dist.integrity !== undefined) {
    const integrity = metadata.dist.integrity;
    demand(typeof integrity === 'string' && /^sha512-[A-Za-z0-9+/]{86}==$/u.test(integrity)
      && 'sha512-' + Buffer.from(integrity.slice(7), 'base64').toString('base64') === integrity,
    'Exact npm archive integrity encoding required.');
  }
  return freeze({ metadata_verified: true, publication_admitted: false });
}
function validateNpmBytes(bundle, metadata, bytes) {
  validatePublicNpmMetadata(bundle, metadata);
  demand(createHash('sha1').update(bytes).digest('hex') === metadata.dist.shasum
    && (metadata.dist.integrity === undefined || 'sha512-' + createHash('sha512').update(bytes).digest('base64') === metadata.dist.integrity),
  'Actual npm archive differs from registry integrity.');
  return validatePublicAssetBytes(bundle, 'npm/winsmux-0.38.0.tgz', bytes);
}
function retain(file, bytes) {
  const fd = fs.openSync(file, 'wx');
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function fileHash(file) {
  const target = physicalPath(file), fd = fs.openSync(target, 'r');
  try {
    const before = fs.fstatSync(fd, { bigint: true });
    demand(before.isFile() && before.nlink === 1n, 'Plain single-link public original required.');
    const bytes = fs.readFileSync(fd), after = fs.fstatSync(fd, { bigint: true }), named = fs.lstatSync(target, { bigint: true });
    demand(['dev','ino','nlink','size','mtimeNs','ctimeNs'].every(key => before[key] === after[key] && after[key] === named[key]),
      'Public original changed during observation.');
    return sha(bytes);
  } finally { fs.closeSync(fd); }
}

/** Validate redirect destinations before any request; signed redirect queries
 * remain in memory and are never persisted or emitted. No credential headers. */
export function assertPublicBinaryRedirect(from, to, visited) {
  const source = new URL(from), destination = new URL(to);
  demand(destination.protocol === 'https:' && destination.username === '' && destination.password === ''
    && destination.hash === '' && (destination.port === '' || destination.port === '443')
    && ['github.com', 'release-assets.githubusercontent.com'].includes(destination.hostname)
    && ['api.github.com', 'github.com', 'release-assets.githubusercontent.com'].includes(source.hostname)
    && !(visited?.has(destination.href)), 'Public download redirect is outside the fixed HTTPS boundary or cyclic.');
  if (destination.hostname === 'github.com') demand(destination.pathname.startsWith(`/${repository}/releases/download/${tag}/`)
    && expectedFilename(destination.pathname.split('/').at(-1)), 'Public download redirect targets another release.');
  return destination.href;
}
function expectedFilename(name) {
  return ['SHA256SUMS','winsmux-arm64.exe','winsmux-arm64.exe.licenses.zip','winsmux-remote-helper-linux-x64',
    'winsmux-x64.exe','winsmux-x64.exe.licenses.zip','SHA256SUMS-desktop','latest.json',
    'winsmux_0.38.0_x64-setup.exe','winsmux_0.38.0_x64-setup.exe.sig',
    'winsmux_0.38.0_x64-setup.inventory.json','winsmux_0.38.0_x64_en-US.msi'].includes(name);
}
function request(url, { binary = false, expectedBytes = null, visited = new Set() } = {}) {
  demand(!visited.has(url), 'Cyclic public request.'); visited.add(url);
  return new Promise((resolve, reject) => {
    const headers = { 'User-Agent': 'winsmux-public-byte-observer', Accept: binary ? 'application/octet-stream' : 'application/json' };
    if (new URL(url).hostname === 'api.github.com') {
      headers['X-GitHub-Api-Version'] = '2026-03-10';
      if (!binary) headers.Accept = 'application/vnd.github+json';
    }
    const req = https.get(url, { rejectUnauthorized: true, headers }, response => {
      if ([301,302,303,307,308].includes(response.statusCode)) {
        response.resume();
        try {
          demand(binary && typeof response.headers.location === 'string', 'Metadata redirect refused.');
          const next = assertPublicBinaryRedirect(url, new URL(response.headers.location, url).href, visited);
          request(next, { binary, expectedBytes, visited }).then(resolve, reject);
        } catch (error) { reject(error); }
        return;
      }
      const chunks = []; let length = 0;
      response.on('data', chunk => {
        length += chunk.length;
        if (response.statusCode === 200 && binary && expectedBytes !== null && length > expectedBytes) {
          response.destroy(new Error('Public download exceeds fixed candidate length.')); return;
        }
        chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => resolve({ status: response.statusCode, bytes: Buffer.concat(chunks), server_date: response.headers.date ?? null,
        final_origin: new URL(url).origin }));
    }); req.on('error', reject);
  });
}

/** Only this actual GET/native-file observation mints process-local origin.
 * Input callbacks, caller status JSON and serialized observations cannot. */
export async function observePublicationDestinations(contract, bundle, { namespaceRoot, parentSession }) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  demand(typeof parentSession === 'string' && parentSession.trim() === parentSession && parentSession.length > 0,
    'Actual parent session required.');
  const root = physicalPath(namespaceRoot); demand(fs.statSync(root).isDirectory(), 'Existing owned public observation namespace required.');
  const directory = path.join(root, 'public-bytes-' + randomUUID()); fs.mkdirSync(directory);
  const started = new Date().toISOString(), originals = [], rows = [];
  const get = async (url, name, options) => {
    const actual = await request(url, options), file = path.join(directory, name); retain(file, actual.bytes);
    originals.push({ file, url, status: actual.status, sha256: sha(actual.bytes), server_date: actual.server_date,
      final_origin: actual.final_origin });
    return actual;
  };
  const json = async (url, name, allowAbsent = false) => {
    const actual = await get(url, name);
    if (allowAbsent && actual.status === 404) return null;
    demand(actual.status === 200, 'Public original unavailable: HTTP ' + actual.status);
    return parseStrictJson(actual.bytes);
  };
  const resolveTag = async label => {
    const ref = await json(`${api}/git/ref/tags/${tag}`, label + '-tag-ref.json');
    demand(ref.ref === `refs/tags/${tag}` && ref.url === `${api}/git/refs/tags/${tag}`, 'Exact public tag reference required.');
    let object = ref.object; const visited = new Set(); let index = 0;
    while (object?.type === 'tag') {
      demand(/^[a-f0-9]{40}$/u.test(object.sha ?? '') && !visited.has(object.sha), 'Tag chain invalid or cyclic.');
      visited.add(object.sha);
      const value = await json(`${api}/git/tags/${object.sha}`, `${label}-tag-${index++}.json`);
      demand(value.sha === object.sha, 'Annotated tag identity differs.'); object = value.object;
    }
    demand(object?.type === 'commit' && object.sha === bundle.identity.source_commit, 'Public tag differs from frozen source commit.');
    return object.sha;
  };
  const listAssets = async (release, label) => {
    if (release === null) return [];
    demand(positive(release.id), 'Actual release id required.');
    const all = [];
    for (let page = 1; ; page++) {
      const batch = await json(`${api}/releases/${release.id}/assets?per_page=100&page=${page}`, `${label}-assets-${page}.json`);
      demand(Array.isArray(batch) && batch.length <= 100, 'Actual release pagination invalid.'); all.push(...batch);
      if (batch.length < 100) break;
      demand(all.length <= bundle.assets.filter(row => /^(core|desktop)\//u.test(row.path)).length,
        'Unexpected public release assets exceed fixed set.');
    }
    return all;
  };
  let failure = null;
  try {
    const repo = await json(api, 'repository.json');
    demand(repo.full_name?.toLowerCase() === repository.toLowerCase() && repo.private === false && positive(repo.id),
      'Actual public repository required before accepting not-found.');
    const release = await json(`${api}/releases/tags/${tag}`, 'release-before.json', true);
    const resolved = release === null ? null : await resolveTag('before');
    const assets = await listAssets(release, 'before');
    const inventory = validatePublicReleaseInventory(bundle, release, resolved, assets);
    const present = new Map(assets.map(asset => [asset.name, asset]));
    for (const row of bundle.assets.filter(row => row.path.startsWith('core/') || row.path.startsWith('desktop/'))) {
      const asset = present.get(path.posix.basename(row.path));
      if (asset === undefined) { rows.push({ path: row.path, state: 'absent', sha256: null }); continue; }
      const actual = await get(asset.url, `asset-${asset.id}.bin`, { binary: true, expectedBytes: row.bytes });
      demand(actual.status === 200, 'Public asset download unavailable: HTTP ' + actual.status);
      rows.push(validatePublicAssetBytes(bundle, row.path, actual.bytes));
    }
    if (release === null) rows.push({ path: 'release-body.md', state: 'absent', sha256: null });
    else rows.push(validatePublicAssetBytes(bundle, 'release-body.md', Buffer.from(release.body, 'utf8')));
    const npm = await json(npmVersion, 'npm-before.json', true);
    if (npm === null) rows.push({ path: 'npm/winsmux-0.38.0.tgz', state: 'absent', sha256: null });
    else {
      validatePublicNpmMetadata(bundle, npm);
      const row = bundle.assets.find(asset => asset.path === 'npm/winsmux-0.38.0.tgz');
      const actual = await get(npmArchive, 'npm-archive.tgz', { binary: true, expectedBytes: row.bytes });
      demand(actual.status === 200, 'Public npm archive download unavailable: HTTP ' + actual.status);
      rows.push(validateNpmBytes(bundle, npm, actual.bytes));
    }
    const releaseAfter = await json(`${api}/releases/tags/${tag}`, 'release-after.json', true);
    const resolvedAfter = releaseAfter === null ? null : await resolveTag('after');
    const assetsAfter = await listAssets(releaseAfter, 'after');
    const inventoryAfter = validatePublicReleaseInventory(bundle, releaseAfter, resolvedAfter, assetsAfter);
    const npmAfter = await json(npmVersion, 'npm-after.json', true);
    if (npmAfter !== null) validatePublicNpmMetadata(bundle, npmAfter);
    demand(same(releaseCoordinates(release), releaseCoordinates(releaseAfter)) && same(inventory, inventoryAfter)
      && same(npmCoordinates(npm), npmCoordinates(npmAfter)), 'Public destination changed during complete observation.');
    demand(rows.length === bundle.assets.length && new Set(rows.map(row => row.path)).size === bundle.assets.length,
      'All fixed public byte rows required.');
    for (const original of originals) demand(fileHash(original.file) === original.sha256, 'Actual public original changed.');
    revalidatePublicationBundle(bundle);
  } catch (error) { failure = error.message; }
  const result = freeze({ schema: 'winsmux-public-byte-observation/v1', directory, parent_session: parentSession,
    candidate_identity: bundle.identity, started_at: started, finished_at: new Date().toISOString(),
    passed: failure === null, failure, rows: rows.sort((a, b) => a.path.localeCompare(b.path, 'en')), originals,
    publication_admitted: false });
  const resultFile = path.join(directory, 'public-byte-observation.json'); retain(resultFile, Buffer.from(JSON.stringify(result)));
  issued.set(result, { contract, bundle, resultFile, resultSha256: fileHash(resultFile) }); return result;
}

/** Synchronous bridge for verifyPublicationRecovery's trusted parent callback.
 * Incomplete/forged/changed observations cannot identify operations to retry. */
export function readObservedPublicationRows(contract, bundle, observation) {
  assertIssuedIntegratedContract(contract); assertIssuedPublicationBundle(bundle); revalidatePublicationBundle(bundle);
  const original = issued.get(observation);
  demand(original && original.contract === contract && original.bundle === bundle && observation.passed === true,
    'Complete actual public origin required.');
  demand(fileHash(original.resultFile) === original.resultSha256 && observation.rows.length === bundle.assets.length,
    'Observed public result changed.');
  for (const row of observation.originals) demand(fileHash(row.file) === row.sha256, 'Observed public original changed.');
  return freeze(structuredClone(observation.rows));
}
