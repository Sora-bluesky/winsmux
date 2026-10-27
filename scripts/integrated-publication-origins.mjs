import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';

// The parent supplies executable observers, as for the original-evidence
// registry. JSON, a caller's pass flag, or a serialized receipt cannot issue
// this capability. Observers own the original producer/source inspection;
// this choke point owns coordinate, complete asset and repeated-byte binding.
const issued = new WeakMap();
const sha = value => createHash('sha256').update(value).digest('hex');
const need = (value, reason) => { if (!value) throw new Error(reason); };
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
const commit = value => typeof value === 'string' && /^[a-f0-9]{40}$/u.test(value);
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const identity = stat => ['dev', 'ino', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key])).join(':');
function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}
export const publicationCutoverPaths = Object.freeze([
  'scripts/integrated-publication-contract.mjs', 'scripts/integrated-publication-origins.mjs',
  'scripts/prepare-integrated-publication.mjs', 'scripts/integrated-publication-assets.mjs',
  'scripts/IntegratedPublicationCustody.cs', 'scripts/observe-publication-destinations.mjs',
  '.github/workflows/release-desktop.yml', '.github/workflows/release-npm.yml',
  'tests/workspace-package/integrated-publication-contract.test.mjs',
  'tests/workspace-package/integrated-publication-assets.test.mjs',
  'tests/workspace-package/prepare-integrated-publication.test.mjs',
  'tests/workspace-package/publication-native-v2.test.ps1',
  'tests/workspace-package/publication-npm-native.test.ps1',
  '.githooks/pre-commit-whitelist.ps1', '.gitignore',
  'scripts/test-public-release.ps1',
  'scripts/observe-github-candidate-artifacts.mjs', 'scripts/stage-desktop-msi-plan.mjs',
  'scripts/desktop-install-inventory.ps1',
  'tests/workspace-package/github-candidate-artifacts.test.mjs',
  'tests/workspace-package/desktop-msi-plan.test.mjs', 'tests/workspace-package/stage-ci-artifact.test.mjs',
  'tests/DesktopInstallReceipt.Tests.ps1', 'tests/VersionSurface.Tests.ps1',
  'tests/ThreatModelContract.Tests.ps1', 'tests/CliBakeoff.Tests.ps1', 'tests/PublicSurfacePolicy.Tests.ps1',
  'tests/workspace-update/run.ps1', 'tests/workspace-update/install-lifecycle.test.ps1',
  'docs/provider-and-model-support.md', 'docs/provider-and-model-support.ja.md',
  'README.md', 'README.ja.md', 'docs/installation.md', 'docs/installation.ja.md',
  'docs/quickstart.md', 'docs/quickstart.ja.md', 'docs/TROUBLESHOOTING.md', 'docs/TROUBLESHOOTING.ja.md',
  'tests/workspace-gate-map/check-map.mjs', 'tests/workspace-gate-map/gate-map.json',
  'tests/workspace-gate-map/run.ps1', '.github/workflows/test.yml',
  'tests/workspace-gate-map/build-map.mjs', 'tests/workspace-gate-map/dispositions.mjs',
  'distribution/windows-licenses/MICROSOFT-COMPONENT-TERMS.ja.txt',
].sort());
export function readOriginFile(row) {
  need(exact(row, ['path', 'bytes', 'sha256']) && typeof row.path === 'string'
    && Number.isSafeInteger(row.bytes) && row.bytes > 0 && digest(row.sha256), 'Exact original file pin required.');
  const file = physicalPath(row.path), before = fs.lstatSync(file, { bigint: true });
  need(before.isFile() && !before.isSymbolicLink() && before.nlink === 1n, 'Plain single-link origin required.');
  const fd = fs.openSync(file, 'r');
  try {
    const held = fs.fstatSync(fd, { bigint: true }), bytes = fs.readFileSync(fd), after = fs.lstatSync(file, { bigint: true });
    need(identity(before) === identity(held) && identity(held) === identity(after)
      && bytes.length === row.bytes && sha(bytes) === row.sha256, 'Origin bytes or physical identity changed.');
    return { bytes, identity: identity(after) };
  } finally { fs.closeSync(fd); }
}
const fixedBase = 'f8f735452109af1bc24adcc8160f0106fa607d81';
const fixedTree = 'f327febf341cd11b79b573c7fe2ae14c22aa821b';
// Core/npm keep their true original producer coordinates; signed Desktop uses final source S.
// The assembly receipt binds CH1: the retained helper keeps its 9158bf27 origin,
// is not rebuilt, and does not claim a strict-current collector or hosted build.
const producerCoordinates = freeze({
  "core": {
    "kind": "private-core-assembly",
    "source_commit": "f8f735452109af1bc24adcc8160f0106fa607d81",
    "source_tree": "f327febf341cd11b79b573c7fe2ae14c22aa821b",
    "run": "local-assembly-eb01f410-65ec-4cf7-ab4f-af8f75ee8ed3",
    "inner_origins": [
      {
        "kind": "windows-x64",
        "source_commit": "f8f735452109af1bc24adcc8160f0106fa607d81",
        "run": "local-g10-50da02e8-ecc5-4a26-8def-e9133fcada41",
        "receipt_sha256": "82f639f7923351313c3f74c63022eab8ae7e111e28a96dccc4dfb231d5d40e0a"
      },
      {
        "kind": "windows-arm64",
        "source_commit": "f8f735452109af1bc24adcc8160f0106fa607d81",
        "run": "local-g10-50da02e8-ecc5-4a26-8def-e9133fcada41",
        "receipt_sha256": "91e2013b5bde14b1b66f1f1f0ec9addaee5746d9a792164c7c6d4fd44bf58111"
      },
      {
        "kind": "linux-helper",
        "source_commit": "9158bf274ab7f0b141e7c6337b3acec1b08196fc",
        "run": "local-24f44a28-c4c3-4e22-b3b1-2b6b21aabf92",
        "receipt_sha256": "fde54fb7ee355a0c5dd3d73ffc10a4faf57b8063a2e0c19d1c274be3f5029e76"
      }
    ],
    "original_receipt": {
      "bytes": 7633,
      "sha256": "1d5edb9d18491d22f5c3dfcb485a27de616715126bce333f15fc93d90bd4371f"
    },
    "asset_paths": [
      "core/SHA256SUMS",
      "core/winsmux-arm64.exe",
      "core/winsmux-arm64.exe.licenses.zip",
      "core/winsmux-remote-helper-linux-x64",
      "core/winsmux-x64.exe",
      "core/winsmux-x64.exe.licenses.zip"
    ]
  },
  "npm": {
    "kind": "local-npm-producer",
    "source_commit": "f8f735452109af1bc24adcc8160f0106fa607d81",
    "source_tree": "f327febf341cd11b79b573c7fe2ae14c22aa821b",
    "run": "local-npm-f8f73545",
    "inner_origins": [
      {
        "kind": "local-npm-pack-and-windows-help-version",
        "source_commit": "f8f735452109af1bc24adcc8160f0106fa607d81",
        "run": "local-npm-f8f73545",
        "receipt_sha256": "ef5422e084f4f06e1af71c44fe5807f39ad26a805c2866235e59322ca19701e6"
      }
    ],
    "original_receipt": {
      "bytes": 252,
      "sha256": "ef5422e084f4f06e1af71c44fe5807f39ad26a805c2866235e59322ca19701e6"
    },
    "asset_paths": [
      "npm/winsmux-0.38.0.tgz"
    ]
  }
});
const desktopAssetPaths = Object.freeze([
  "desktop/SHA256SUMS-desktop",
  "desktop/latest.json",
  "desktop/winsmux_0.38.0_x64-setup.exe",
  "desktop/winsmux_0.38.0_x64-setup.exe.sig",
  "desktop/winsmux_0.38.0_x64-setup.inventory.json",
  "desktop/winsmux_0.38.0_x64_en-US.msi"
]);
// The final source S differs from fixedBase only in these paths. Their after bytes include this module,
// so only the f8f73545 before bytes are pinned here; the host observes the after digests.
const expectedSourceChanges = Object.freeze({
  'scripts/integrated-publication-origins.mjs': '4bf4c81e2d565df332930b52cfcf167c756ac1d376b0189e19478d204966f324',
  'tests/workspace-gate-map/gate-map.json': 'a49ca73e55e05a4449b3ef1734ace74cdb039c6e5d47ed9101d96ce02ecccfb1',
  'tests/workspace-package/prepare-integrated-publication.test.mjs': '4538ecd4de03885d00aba622e471cd949545612ed34eedfbfa5a6447a306aa32',
});
// Paths absent at fixedBase; their rows carry before_sha256 null.
const expectedSourceAdditions = Object.freeze([]);
const expectedSourcePaths = Object.freeze([...Object.keys(expectedSourceChanges), ...expectedSourceAdditions].sort());
// Pure projection is exported for finite positive/negative tests. It never
// issues an origin capability and never makes an original producer current.
export function validateOriginProjection(value) {
  need(exact(value, ['source', 'core', 'desktop', 'npm', 'parent_metadata']), 'Exact typed origin inventory required.');
  const source = value.source;
  need(exact(source, ['kind', 'base_commit', 'base_tree', 'source_commit', 'source_tree', 'changes', 'originals'])
    && source.kind === 'parent-observed-final-source' && source.base_commit === fixedBase && source.base_tree === fixedTree
    && commit(source.source_commit) && commit(source.source_tree) && Array.isArray(source.changes)
    && JSON.stringify(source.changes.map(row => row.path).sort()) === JSON.stringify(expectedSourcePaths)
    && source.changes.every(row => exact(row, ['path', 'before_sha256', 'after_sha256'])
      && publicationCutoverPaths.includes(row.path)
      && (expectedSourceAdditions.includes(row.path)
        ? row.before_sha256 === null
        : Object.hasOwn(expectedSourceChanges, row.path) && row.before_sha256 === expectedSourceChanges[row.path])
      && digest(row.after_sha256) && row.before_sha256 !== row.after_sha256), 'Final source applicability differs.');
  for (const [surface, expected] of Object.entries(producerCoordinates)) {
    const row = value[surface];
    need(exact(row, ['kind', 'source_commit', 'source_tree', 'run', 'inner_origins', 'assets', 'originals'])
      && Array.isArray(row.inner_origins)
      && row.inner_origins.every(origin => exact(origin, ['kind', 'source_commit', 'run', 'receipt_sha256']))
      && Array.isArray(row.assets) && Array.isArray(row.originals), 'Typed producer origin differs.');
    need(row.kind === expected.kind && row.source_commit === expected.source_commit
      && row.source_tree === expected.source_tree && row.run === expected.run
      && row.inner_origins.length === expected.inner_origins.length
      && row.inner_origins.every((origin, index) => Object.entries(expected.inner_origins[index]).every(([key, entry]) => origin[key] === entry)),
    'Original producer coordinate differs.');
    need(row.originals.some(pin => pin.bytes === expected.original_receipt.bytes && pin.sha256 === expected.original_receipt.sha256),
      'Original producer receipt binding differs.');
    need(JSON.stringify(row.assets.map(asset => asset.path).sort()) === JSON.stringify(expected.asset_paths), 'Origin surface differs.');
  }
  const desktop = value.desktop;
  need(exact(desktop, ['kind', 'source_commit', 'source_tree', 'run', 'inner_origins', 'assets', 'originals'])
    && desktop.kind === 'signed-ci-desktop' && desktop.source_commit === source.source_commit && desktop.source_tree === source.source_tree
    && typeof desktop.run === 'string' && /^[1-9][0-9]*\.[1-9][0-9]*$/u.test(desktop.run)
    && desktop.run.split('.').every(part => Number.isSafeInteger(Number(part)))
    && Array.isArray(desktop.inner_origins) && desktop.inner_origins.length === 1
    && exact(desktop.inner_origins[0], ['kind', 'source_commit', 'run', 'receipt_sha256'])
    && desktop.inner_origins[0].kind === 'github-signed-desktop-preparation'
    && desktop.inner_origins[0].source_commit === desktop.source_commit && desktop.inner_origins[0].run === desktop.run
    && digest(desktop.inner_origins[0].receipt_sha256) && Array.isArray(desktop.originals)
    && desktop.originals.some(pin => pin.sha256 === desktop.inner_origins[0].receipt_sha256)
    && Array.isArray(desktop.assets) && JSON.stringify(desktop.assets.map(asset => asset.path).sort()) === JSON.stringify(desktopAssetPaths),
  'Signed Desktop producer must match final source and observed preparation.');
  need(exact(value.parent_metadata, ['kind', 'source_commit', 'source_tree', 'assets', 'originals'])
    && value.parent_metadata.kind === 'parent-final-metadata'
    && value.parent_metadata.source_commit === source.source_commit && value.parent_metadata.source_tree === source.source_tree,
  'Parent metadata source differs.');
  const assets = ['core', 'desktop', 'npm', 'parent_metadata'].flatMap(key => value[key].assets);
  need(assets.length === 14 && new Set(assets.map(row => row.path)).size === 14
    && assets.every(row => exact(row, ['path', 'source_file', 'bytes', 'sha256'])
      && typeof row.path === 'string' && typeof row.source_file === 'string'
      && Number.isSafeInteger(row.bytes) && row.bytes > 0 && digest(row.sha256)), 'Complete origin asset binding required.');
  need(value.core.assets.length === 6 && value.core.assets.every(row => row.path.startsWith('core/'))
    && value.desktop.assets.length === 6 && value.desktop.assets.every(row => row.path.startsWith('desktop/'))
    && value.npm.assets.length === 1 && value.npm.assets[0].path === 'npm/winsmux-0.38.0.tgz'
    && value.parent_metadata.assets.length === 1 && value.parent_metadata.assets[0].path === 'release-body.md', 'Origin surface differs.');
  for (const row of Object.values(value)) need(Array.isArray(row.originals) && row.originals.length > 0,
    'Original source/producer evidence required.');
  return value;
}
function inspect(observers) {
  need(exact(observers, ['source', 'core', 'desktop', 'npm', 'parent_metadata'])
    && Object.values(observers).every(observer => typeof observer === 'function'), 'Parent executable origin observers required.');
  const projection = validateOriginProjection(Object.fromEntries(Object.entries(observers).map(([key, observer]) => [key, observer()])));
  const pins = Object.values(projection).flatMap(row => row.originals)
    .concat(['core', 'desktop', 'npm', 'parent_metadata'].flatMap(key => projection[key].assets.map(row =>
      ({ path: row.source_file, bytes: row.bytes, sha256: row.sha256 }))));
  const observations = pins.map(row => ({ pin: structuredClone(row), identity: readOriginFile(row).identity }));
  return { projection, observations, digest: sha(Buffer.from(JSON.stringify(projection))) };
}
export function observeIntegratedPublicationOrigins(contract, observers) {
  assertIssuedIntegratedContract(contract);
  const first = inspect(observers), second = inspect(observers);
  need(first.digest === second.digest && JSON.stringify(first.observations) === JSON.stringify(second.observations), 'Origin changed during complete observation.');
  const receipt = freeze({ schema: 'winsmux-parent-observed-publication-origins/v1', sha256: first.digest,
    source: structuredClone(first.projection.source), producers: Object.fromEntries(['core', 'desktop', 'npm'].map(key =>
      [key, { source_commit: first.projection[key].source_commit, source_tree: first.projection[key].source_tree, run: first.projection[key].run }])),
    projection: structuredClone(first.projection), publication_admitted: false });
  issued.set(receipt, { contract, observers, observations: first.observations });
  return receipt;
}
export function revalidateIntegratedPublicationOrigins(contract, receipt) {
  assertIssuedIntegratedContract(contract);
  const original = issued.get(receipt);
  need(original && original.contract === contract, 'Parent-observed origin capability required; JSON is not authority.');
  const current = inspect(original.observers);
  need(current.digest === receipt.sha256 && JSON.stringify(current.observations) === JSON.stringify(original.observations), 'Original producer/source observation changed.');
  return receipt;
}
export function assertOriginAssetBinding(contract, receipt, sourceCommit, sourceTree, producers, assets) {
  revalidateIntegratedPublicationOrigins(contract, receipt);
  need(receipt.source.source_commit === sourceCommit && receipt.source.source_tree === sourceTree
    && JSON.stringify(producers) === JSON.stringify(receipt.producers), 'Typed origin/source coordinate differs.');
  const expected = ['core', 'desktop', 'npm', 'parent_metadata'].flatMap(key => receipt.projection[key].assets)
    .map(row => ({ path: row.path, bytes: row.bytes, sha256: row.sha256 })).sort((a,b) => a.path.localeCompare(b.path, 'en'));
  const actual = assets.map(row => ({ path: row.path, bytes: row.bytes, sha256: row.sha256 })).sort((a,b) => a.path.localeCompare(b.path, 'en'));
  need(JSON.stringify(expected) === JSON.stringify(actual), 'Asset differs from original typed producer bytes.');
  return receipt;
}
