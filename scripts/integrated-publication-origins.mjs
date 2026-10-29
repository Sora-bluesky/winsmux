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
  '.githooks/pre-commit-whitelist.ps1',
  'core/crates/winsmux-workspace-mcp/tests/stdio_e2e.rs',
  'core/crates/winsmux-workspace/tests/host_authorization.rs',
  'scripts/integrated-publication-origins.mjs',
  'tests/workspace-gate-map/dispositions.mjs',
  'tests/workspace-gate-map/gate-map.json',
  'tests/workspace-journey/ci-run.ps1',
  'tests/workspace-journey/run.ps1',
  'tests/workspace-package/prepare-integrated-publication.test.mjs',
  'winsmux-app/scripts/fixtures/ime-probe-win11-edge.txt',
  'winsmux-app/scripts/workspace-desktop-input-check.mjs',
  'winsmux-app/src-tauri/src/lib.rs',
  'winsmux-app/src-tauri/src/webview_accelerators.rs',
  'winsmux-app/src-tauri/tauri.conf.json',
  'winsmux-app/src-tauri/tests/workspace_native_webview.rs',
  'winsmux-app/src/workspace-ui/focus.ts',
  'winsmux-app/src/workspace-ui/project-pane.css',
  'winsmux-app/src/workspace-ui/project-pane.ts',
  'winsmux-app/src/workspace-ui/startup-mount.ts',
  'winsmux-app/src/workspace-ui/terminal-input-codec.ts',
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
const fixedBase = 'e29de959ceb6d5502fd05bef676482f2941d9cb6';
const fixedTree = 'c40417425a0d029c47dff7f396a6676c71e284e8';
// Core/npm keep their true original producer coordinates; signed Desktop uses final source S.
// The assembly receipt binds CH1: the retained helper keeps its 9158bf27 origin,
// is not rebuilt, and does not claim a strict-current collector or hosted build.
const producerCoordinates = freeze({
  "core": {
    "kind": "private-core-assembly",
    "source_commit": "e29de959ceb6d5502fd05bef676482f2941d9cb6",
    "source_tree": "c40417425a0d029c47dff7f396a6676c71e284e8",
    "run": "local-assembly-06d9fd4c-41a0-4d14-b5d3-bbb5a7e5975d",
    "inner_origins": [
      {
        "kind": "windows-x64",
        "source_commit": "e29de959ceb6d5502fd05bef676482f2941d9cb6",
        "run": "local-g10-3a0b6eb3-1cc1-4c3f-af5e-c8b815b87158",
        "receipt_sha256": "240a5fd2183bab12296c73865a5c1044b51973c4c1828ebcad3affe9019ead0a"
      },
      {
        "kind": "windows-arm64",
        "source_commit": "e29de959ceb6d5502fd05bef676482f2941d9cb6",
        "run": "local-g10-3a0b6eb3-1cc1-4c3f-af5e-c8b815b87158",
        "receipt_sha256": "80611015df33cf5a389974f6b4b1a20926366d5fbfc90253a8f5a036bc5de7e0"
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
      "sha256": "f8c7e580953e19f5b7f1ab99cfd038960df89c167a1068a652f7bedac4e8684b"
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
    "source_commit": "e29de959ceb6d5502fd05bef676482f2941d9cb6",
    "source_tree": "c40417425a0d029c47dff7f396a6676c71e284e8",
    "run": "local-npm-e29de959",
    "inner_origins": [
      {
        "kind": "local-npm-pack-and-windows-help-version",
        "source_commit": "e29de959ceb6d5502fd05bef676482f2941d9cb6",
        "run": "local-npm-e29de959",
        "receipt_sha256": "3926bee9672c32e3eb503fac7a474511123a188d5a7f7f30a8a6f2425f0c3d8b"
      }
    ],
    "original_receipt": {
      "bytes": 252,
      "sha256": "3926bee9672c32e3eb503fac7a474511123a188d5a7f7f30a8a6f2425f0c3d8b"
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
// so only the e29de959 before bytes are pinned here; the host observes the after digests.
const expectedSourceChanges = Object.freeze({
  '.githooks/pre-commit-whitelist.ps1': '44718f56d74c461f5cc9f89a666a5a301957c37641f02f60d6df88fcafdbdd28',
  'core/crates/winsmux-workspace-mcp/tests/stdio_e2e.rs': 'a360918da5e8552c70598264713c8fb657bb681357c9247bef39139ac150a3fd',
  'core/crates/winsmux-workspace/tests/host_authorization.rs': 'bab48e4a807bfbd5d3e51df87fcb0dd7f1439aa5f4471343611257dbdc205892',
  'scripts/integrated-publication-origins.mjs': 'e552acfcf14120349d9cdbb678538479cdb2ff22dc3231a341d7dcd715df245a',
  'tests/workspace-gate-map/dispositions.mjs': '3e4c677b8a0f1664944f5e89720ecb169f386148c037f5828acf10a80c9ac315',
  'tests/workspace-gate-map/gate-map.json': 'b7d0e71316ef56b55f69bff6c0e68c323954969cf2df31f584f08f9fd0ce3306',
  'tests/workspace-journey/ci-run.ps1': '3b406b98b521a049b929c31747df09ca22af36b09230f2d6d641cc658978e96d',
  'tests/workspace-journey/run.ps1': '839262845c117081ea784a5e61a3c9a1b8e55cd7f1c8803f7c6c775d3a05bbe6',
  'tests/workspace-package/prepare-integrated-publication.test.mjs': '629b0cbb2f7751834530b1fbb95f7ed7fc5d29fab18baf39c15d38d460623afc',
  'winsmux-app/src-tauri/src/lib.rs': '9d558cc6308d27d3236f88c8e4a9ed462795114e9bea852ce917c45a9666aae8',
  'winsmux-app/src-tauri/src/webview_accelerators.rs': '42ebb3066987fadc14b47078d38d899d96025b8ea8519521fc8748154c1a8853',
  'winsmux-app/src-tauri/tauri.conf.json': '0d89cb8325baa0bfd781082e13078fa72713554e50d74f132e0dd4ac32e6074e',
  'winsmux-app/src-tauri/tests/workspace_native_webview.rs': '7c06b1f65a14e378954c20cb4e3e32a7cac7216ab89617f7eecc7ea7dcb15984',
  'winsmux-app/src/workspace-ui/focus.ts': '7e246888c333e44c998f16be11ced127a86f7933900c3c6e64176995a971ebdc',
  'winsmux-app/src/workspace-ui/project-pane.css': 'c5af16daf7dec3408a880895390bbb587fb87664e66f7949f4c15f9797a5f2f1',
  'winsmux-app/src/workspace-ui/project-pane.ts': '4abb4f8167cce53dcd6f6b537107936f0cfe08585a52cd64e41bdb5905355d3b',
  'winsmux-app/src/workspace-ui/startup-mount.ts': '85b79561b04d1b735b3f69f1b055319cd0ef410a246cfca0db92d756b6dccbc2',
  'winsmux-app/src/workspace-ui/terminal-input-codec.ts': 'a9b3fc1fa3be269b2015dbbbe78391c91ecf2700f5c046a645a3a96c9776a890',
});
// Paths absent at fixedBase; their rows carry before_sha256 null.
const expectedSourceAdditions = Object.freeze([
  'winsmux-app/scripts/fixtures/ime-probe-win11-edge.txt',
  'winsmux-app/scripts/workspace-desktop-input-check.mjs',
]);
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
