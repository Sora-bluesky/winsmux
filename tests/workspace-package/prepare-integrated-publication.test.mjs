import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { publicationFixture, sha } from './publication-fixture.mjs';
import { prepareIntegratedPublicationBundle } from '../../scripts/prepare-integrated-publication.mjs';
import { freezePublicationAttempt } from '../../scripts/integrated-publication-attempt.mjs';
import { readIntegratedPublicationAssets, revalidatePublicationBundle } from '../../scripts/integrated-publication-assets.mjs';
import { observeIntegratedPublicationOrigins, revalidateIntegratedPublicationOrigins, validateOriginProjection, publicationCutoverPaths } from '../../scripts/integrated-publication-origins.mjs';

assert.ok(process.argv[2] && process.argv[3], 'Canonical operator root and actual verified npm trial required.');
const fixture = publicationFixture(path.resolve(process.argv[2]));
const { contract, root, bundle, manifest } = fixture;
const npmTrialFile = path.resolve(process.argv[3]);
const npmResultBytes=fs.readFileSync(npmTrialFile);
assert.equal(sha(npmResultBytes),'8c9ef6d8b93100416e9175783a954cecee3f3992481e310f6f3fb5dab120ae1c');
const npmResult=JSON.parse(npmResultBytes);
const receiptFile=path.join(path.dirname(npmResult.artifact),'npm-candidate.json');
const receiptBytes=fs.readFileSync(receiptFile);
assert.equal(sha(receiptBytes),'d0b1690f30c64de5b220242f75228f323d4ff7299d021f8478a102b78f663d67');
const npmCandidate=JSON.parse(receiptBytes);
const npmTrial={source:npmCandidate.windows.extracted_directory};
const npmProof={passed:npmResult.pack_verified&&npmResult.windows_help_version_verified,native_exit_code:0,
 candidate_receipt_path:receiptFile,candidate_receipt_sha256:sha(receiptBytes),npm_sha256:npmResult.sha256};
assert.equal(npmProof.passed,true);assert.equal(sha(fs.readFileSync(npmCandidate.file)),npmProof.npm_sha256);
const namespaceRoot = path.join(root, 'prepared'); fs.mkdirSync(namespaceRoot);
const input = { namespaceRoot, sourceCommit: manifest.source_commit, sourceTree: manifest.source_tree, producers: manifest.producers,
  sources: bundle.assets.map(row => row.path === 'npm/winsmux-0.38.0.tgz'
    ? { path: row.path, source_file: npmCandidate.file, observed_sha256: npmProof.npm_sha256 }
    : { path: row.path, source_file: path.join(bundle.root, row.path), observed_sha256: row.sha256 }),
  npmSources: ['LICENSE', 'README.md', 'index.mjs', 'install.ps1', 'package.json'].map(name => ({ path: name,
    source_file: path.join(npmTrial.source, name), observed_sha256: npmCandidate.preparation.source_sha256[name] })) };
// Executable fixture observers are test code, not serialized producer authority.
// All non-npm payloads are synthetic; no authenticated operation is created.
const base='ce0c39ba0d4852195df95c5b99666a1a3441c887', tree='4dcec20aafed921f62ce29ebbe148545d39b01c3';
const npmHead='ce0c39ba0d4852195df95c5b99666a1a3441c887';
// Retired b048b00b/c36c0265, c43aed07/9fba0d77, a1ce1975/8014b3a1 and 9be98eb5/92b55959 coordinates: the module must refuse the superseded producers.
const retiredNpmHead='b048b00b9291e346c247f2799d96283e21cb471e', retiredNpmTree='c36c02659c7de29251af25d1ae58fdfd45a6bd26';
const retiredBase='c43aed076c076726f616e8a6bf489c8709246f17', retiredTree='9fba0d77cad1d2294e4b6158d1a3f74fdd2410c7', retiredAssemblyRun='local-assembly-c827d952-2d96-4128-adb3-83ce48fbc67b';
const retiredA1ceBase='a1ce1975ceaa6f6dfa9feb2fa2113fb98d65f4e3', retiredA1ceTree='8014b3a17e55b3c484ee8306b1db2a6cba25f139', retiredA1ceAssemblyRun='local-assembly-405ecdc6-c70e-4dda-9416-fa627e4fd9cd';
const retired9be9Base='9be98eb53433e021315d851ca27bacc9ca44d7f7', retired9be9Tree='92b559597878265f1a465a2e500311118a231a86', retired9be9AssemblyRun='local-assembly-27be8c1a-12a0-44df-a8a0-feaffe29e5eb';
// The S rows: ce0c39ba before bytes are real pins, after digests are synthetic.
const s5Changes = Object.freeze([
  { path: 'scripts/integrated-publication-origins.mjs', before_sha256: '4337633cf8d7611465845f34650298fdbc630539168e9d5ebd20e6389721b8fd', after_sha256: 'd'.repeat(64) },
  { path: 'tests/workspace-package/prepare-integrated-publication.test.mjs', before_sha256: '6eacf4582a9c5b27a267e69b1077fbb5f0d230f2a69913c651c46db5b271229e', after_sha256: 'e'.repeat(64) },
  { path: 'tests/workspace-gate-map/gate-map.json', before_sha256: 'cbc47843a2907f55f3f4bc870d77d270e384f283f5d7891fa1d4c005c3e5405f', after_sha256: 'f'.repeat(64) },
]);
const rowOf = (value, file) => value.source.changes.find(row => row.path === file);
const pin={path:npmProof.candidate_receipt_path,bytes:fs.statSync(npmProof.candidate_receipt_path).size,sha256:npmProof.candidate_receipt_sha256};
const rows=input.sources.map(row=>({path:row.path,source_file:row.source_file,bytes:fs.statSync(row.source_file).size,sha256:row.observed_sha256}));
const repositoryRoot=path.resolve(path.dirname(npmTrialFile),'../../..');
const finalSource='a'.repeat(40), finalTree='b'.repeat(40);
const originalReceipt=(file,expected)=>{const bytes=fs.readFileSync(file);assert.equal(sha(bytes),expected);return {path:file,bytes:bytes.length,sha256:expected};};
const coreReceipt=originalReceipt(path.join(repositoryRoot,'.evidence/v0380-core-fixed-assembly-ce0c39ba/905a634a-6d13-4468-b7fa-991acd432aaa/assembly-proof.json'),'0dbad12313af588855e60792bb0321ed8a5f66232e37234c9247c1a9bc5418c8');
const npmReceipt=originalReceipt(npmTrialFile,'8c9ef6d8b93100416e9175783a954cecee3f3992481e310f6f3fb5dab120ae1c');
// Coordinates are original evidence facts; payloads and signed preparation below are synthetic.
const producerFixtures = {
  "core": {
    "kind": "private-core-assembly",
    "source_commit": "ce0c39ba0d4852195df95c5b99666a1a3441c887",
    "source_tree": "4dcec20aafed921f62ce29ebbe148545d39b01c3",
    "run": "local-assembly-905a634a-6d13-4468-b7fa-991acd432aaa",
    "inner_origins": [
      {
        "kind": "windows-x64",
        "source_commit": "ce0c39ba0d4852195df95c5b99666a1a3441c887",
        "run": "local-5d51bbdb-9074-44ad-82a4-6863974d84d2",
        "receipt_sha256": "415ee98ca13d883c2a4e23f52a727c79e179253008a00f0cfbf38c036fe9de31"
      },
      {
        "kind": "windows-arm64",
        "source_commit": "ce0c39ba0d4852195df95c5b99666a1a3441c887",
        "run": "local-5d51bbdb-9074-44ad-82a4-6863974d84d2",
        "receipt_sha256": "523623f6bae475340ede9cd003e243826b66a8e68e375ec67b1e0f5585766308"
      },
      {
        "kind": "linux-helper",
        "source_commit": "9158bf274ab7f0b141e7c6337b3acec1b08196fc",
        "run": "local-24f44a28-c4c3-4e22-b3b1-2b6b21aabf92",
        "receipt_sha256": "fde54fb7ee355a0c5dd3d73ffc10a4faf57b8063a2e0c19d1c274be3f5029e76"
      }
    ],
    "original_receipt": {
      "bytes": 16931,
      "sha256": "0dbad12313af588855e60792bb0321ed8a5f66232e37234c9247c1a9bc5418c8"
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
    "source_commit": "ce0c39ba0d4852195df95c5b99666a1a3441c887",
    "source_tree": "4dcec20aafed921f62ce29ebbe148545d39b01c3",
    "run": "local-npm-ce0c39ba",
    "inner_origins": [
      {
        "kind": "local-npm-pack-and-windows-help-version",
        "source_commit": "ce0c39ba0d4852195df95c5b99666a1a3441c887",
        "run": "local-npm-ce0c39ba",
        "receipt_sha256": "8c9ef6d8b93100416e9175783a954cecee3f3992481e310f6f3fb5dab120ae1c"
      }
    ],
    "original_receipt": {
      "bytes": 1596,
      "sha256": "8c9ef6d8b93100416e9175783a954cecee3f3992481e310f6f3fb5dab120ae1c"
    },
    "asset_paths": [
      "npm/winsmux-0.38.0.tgz"
    ]
  }
};
const producer=surface=>{
  if(surface==='desktop')return {kind:'signed-ci-desktop',source_commit:finalSource,source_tree:finalTree,run:'22.1',
    inner_origins:[{kind:'github-signed-desktop-preparation',source_commit:finalSource,run:'22.1',receipt_sha256:pin.sha256}],
    assets:rows.filter(row=>row.path.startsWith('desktop/')),originals:[pin]};
  const fixed=producerFixtures[surface];
  return {kind:fixed.kind,source_commit:fixed.source_commit,source_tree:fixed.source_tree,run:fixed.run,
    inner_origins:structuredClone(fixed.inner_origins),assets:rows.filter(row=>row.path.startsWith(surface+'/')),
    originals:[surface==='core'?coreReceipt:npmReceipt]};
};
const observers={source:()=>({kind:'parent-observed-final-source',base_commit:base,base_tree:tree,source_commit:finalSource,source_tree:finalTree,changes:s5Changes.map(row=>({...row})),originals:[pin]}),
 core:()=>producer('core'),desktop:()=>producer('desktop'),npm:()=>producer('npm'),
 parent_metadata:()=>({kind:'parent-final-metadata',source_commit:finalSource,source_tree:finalTree,assets:rows.filter(row=>row.path==='release-body.md'),originals:[pin]})};
const origins=observeIntegratedPublicationOrigins(contract,observers);
input.sourceCommit=finalSource;input.sourceTree=finalTree;input.producers=structuredClone(origins.producers);input.origins=origins;
let checks = 0;
const check = action => { action(); checks++; };
const reject = (action, pattern) => check(() => assert.throws(action, pattern));
const cloned = () => ({...structuredClone(input),origins});
const prepare = value => prepareIntegratedPublicationBundle(contract, value ?? input);

// Final-source applicability is exactly the S rows with their ce0c39ba before bytes, independent of producer coordinates.
check(() => { assert.equal(publicationCutoverPaths.length,38); assert.equal(new Set(publicationCutoverPaths).size,38); });
const projection = () => Object.fromEntries(Object.entries(observers).map(([key, observer]) => [key, observer()]));
check(() => assert.deepEqual(validateOriginProjection(projection()).source.changes, [...s5Changes]));
for (const change of [
  value => { rowOf(value,'tests/workspace-package/prepare-integrated-publication.test.mjs').before_sha256=rowOf(value,'scripts/integrated-publication-origins.mjs').before_sha256; },
  value => { rowOf(value,'scripts/integrated-publication-origins.mjs').before_sha256='618f8afc8d1030a5133225562cfc5a891cad6e9153f69d65c361630ef2a0eb77'; },
  value => { rowOf(value,'tests/workspace-package/prepare-integrated-publication.test.mjs').before_sha256='d3700003b8ecde5536f7e76ca483cf6a6e8891fb46762c209da9949ba2fbdcff'; },
  value => { value.source.changes.push({path:'scripts/test-public-release.ps1',before_sha256:'a794c642a43899a86d168c1259ca2eace7bf718a5e681a3ab17ffd7ab6a250a5',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/VersionSurface.Tests.ps1',before_sha256:'799fa6e501308d68156cf5ebff850d637947d609f667d1daa1323a04290fbe19',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/workspace-package/publication-native-v2.test.ps1',before_sha256:'df5f9aa5d28eb22a2729194c762c9940245da6bd804d3100908768fd4ca03b36',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/workspace-package/publication-npm-native.test.ps1',before_sha256:'c188e7fffba1f89128c5a767d5dee9859e32ac2dd25f76eec808f2417929444b',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/workspace-update/run.ps1',before_sha256:null,after_sha256:'d'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/workspace-gate-map/extra.ps1',before_sha256:null,after_sha256:'d'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/workspace-gate-map/run.ps1',before_sha256:null,after_sha256:'c'.repeat(64)}); },
  value => { value.source.changes.push({path:'.gitignore',before_sha256:'b67997120ecc01d7cbca130dc209249f4f4323ae9f832140abb4ed8360f58c48',after_sha256:'f'.repeat(64)}); },
]) { const value=projection(); change(value); reject(()=>validateOriginProjection(value), /applicability/); }
reject(() => { const value=projection(); value.source.changes.push({path:'scripts/desktop-install-inventory.ps1',before_sha256:'0'.repeat(64),after_sha256:'d'.repeat(64)}); validateOriginProjection(value); }, /applicability/);
for (const change of [
  value => { value.source.changes=[]; },
  value => { value.source.changes.pop(); },
  value => { value.source.changes.push({...value.source.changes[0]}); },
  value => { value.source.changes[0].path='Scripts/integrated-publication-origins.mjs'; },
  value => { value.source.changes[0].path='scripts\\integrated-publication-origins.mjs'; },
  value => { value.source.changes[0].path='scripts/foreign.ps1'; },
  value => { value.source.changes[0].before_sha256='0'.repeat(64); },
  value => { value.source.changes[0].after_sha256=value.source.changes[0].before_sha256; },
  value => { value.source.changes[0].before_sha256=value.source.changes[0].before_sha256.slice(1); },
  value => { value.source.changes[0].after_sha256=value.source.changes[0].after_sha256.slice(1); },
  value => { value.source.changes[0].after_sha256=value.source.changes[0].after_sha256.toUpperCase(); },
  value => { value.source.changes[0].before_sha256=null; },
  value => { value.source.changes.push({path:'scripts/unlisted.mjs',before_sha256:null,after_sha256:'d'.repeat(64)}); },
  value => { value.core.source_commit=value.source.source_commit='a'.repeat(40); value.parent_metadata.source_commit=value.source.source_commit; },
  value => { value.npm.source_commit=retiredNpmHead; },
  value => { value.npm.source_commit=retiredBase; },
  value => { value.core.source_commit=retiredBase; },
  value => { value.source.base_commit=retiredBase; value.source.base_tree=retiredTree; },
  value => { value.npm.source_commit=retiredA1ceBase; },
  value => { value.core.source_commit=retiredA1ceBase; },
  value => { value.source.base_commit=retiredA1ceBase; value.source.base_tree=retiredA1ceTree; },
  value => { value.npm.source_commit=retired9be9Base; },
  value => { value.core.source_commit=retired9be9Base; },
  value => { value.source.base_commit=retired9be9Base; value.source.base_tree=retired9be9Tree; },
  value => { value.core.inner_origins=value.core.inner_origins.filter(row=>row.source_commit!==npmHead); },
  value => { value.desktop.assets.pop(); },
]) {
  const value=projection(); change(value);
  reject(()=>validateOriginProjection(value), /applicability|producer coordinate|inner origins|asset binding|surface|Signed Desktop/);
  reject(()=>observeIntegratedPublicationOrigins(contract,Object.fromEntries(Object.keys(value).map(key=>[key,()=>structuredClone(value[key])]))), /applicability|producer coordinate|inner origins|asset binding|surface|Signed Desktop/);
}

// S is supplied by the final source observation, never embedded as a future commit.
check(()=>{const value=projection();for(const row of [value.source,value.desktop,value.parent_metadata]){row.source_commit='d'.repeat(40);row.source_tree='e'.repeat(40);}value.desktop.inner_origins[0].source_commit=value.source.source_commit;validateOriginProjection(value);});
for(const change of [
  value=>{value.desktop.kind='normal-ci-desktop';},
  value=>{value.desktop.source_commit=base;},
  value=>{value.desktop.source_tree=tree;},
  value=>{value.desktop.run='39061830692.1';},
  value=>{value.desktop.inner_origins[0].kind='normal-C-artifact';},
  value=>{value.desktop.inner_origins[0].source_commit=base;},
  value=>{value.desktop.inner_origins[0].run='22.2';},
  value=>{value.desktop.inner_origins[0].receipt_sha256='0'.repeat(64);},
  value=>{value.desktop.originals=[];},
  value=>{value.core.source_tree='0'.repeat(40);},
  value=>{value.core.run='local-other';},
  value=>{value.core.inner_origins[0].receipt_sha256='0'.repeat(64);},
  value=>{value.npm.source_tree=retiredNpmTree;},
  value=>{value.npm.source_tree=retiredTree;},
  value=>{value.core.run=retiredAssemblyRun;},
  value=>{value.npm.source_tree=retiredA1ceTree;},
  value=>{value.core.run=retiredA1ceAssemblyRun;},
  value=>{value.npm.source_tree=retired9be9Tree;},
  value=>{value.core.run=retired9be9AssemblyRun;},
  value=>{value.npm.run='22.1';},
  value=>{value.npm.inner_origins[0].run='22.1';},
  value=>{value.desktop.assets=value.desktop.assets.filter(row=>row.path.endsWith('.exe')||row.path.endsWith('.msi'));},
  value=>{value.desktop.assets.push({...value.desktop.assets[0]});},
  value=>{value.desktop.assets[0]={...value.desktop.assets[0],path:value.desktop.assets[0].path.toUpperCase()};}
]){const value=projection();change(value);reject(()=>validateOriginProjection(value),/producer|Signed Desktop|surface/);}

check(() => assert.ok(Object.isFrozen(origins) && Object.isFrozen(origins.source.changes[0])));
let sourceReads=0;
const changingObservers={...observers,source:()=>{
  const value=observers.source();
  if (++sourceReads===2) value.changes[0].after_sha256='c'.repeat(64);
  return value;
}};
reject(()=>observeIntegratedPublicationOrigins(contract,changingObservers), /Origin changed during complete observation/);
check(()=>assert.equal(sourceReads,2));
const betweenFile=path.join(root,'current-origin-between-reads.bin');
const betweenBytes=Buffer.from('Synthetic original evidence before second observation.\n');
fs.writeFileSync(betweenFile,betweenBytes,{flag:'wx'});
const betweenPin={path:betweenFile,bytes:betweenBytes.length,sha256:sha(betweenBytes)};
let fileReads=0;
reject(()=>observeIntegratedPublicationOrigins(contract,{...observers,source:()=>{
  if (++fileReads===2) fs.appendFileSync(betweenFile,'changed');
  return {...observers.source(),originals:[betweenPin]};
}}),/Origin bytes or physical identity changed/);
check(()=>assert.equal(fileReads,2));
reject(()=>prepare({...input,origins:structuredClone(origins)}),/capability/);
reject(()=>prepare({...input,origins:undefined}),/capability/);
check(()=>revalidateIntegratedPublicationOrigins(contract,origins));
const originalFiles = new Map(input.sources.map(row => [row.source_file, fs.readFileSync(row.source_file)]));
for (const row of input.npmSources) originalFiles.set(row.source_file, fs.readFileSync(row.source_file));
for (const change of [ value => { value.sourceTree = 'a'; }, value => { value.sourceCommit = '1'.repeat(39); },
  value => { value.sourceCommit = { toString() { return '1'.repeat(40); } }; }, value => { value.sourceTree = 2; },
  value => { delete value.producers.desktop; }, value => { value.producers.npm.source_tree = '3'.repeat(40); },
  value => { value.producers.core.run = ''; }, value => { value.producers.core.approved = true; },
  value => { value.sources.pop(); }, value => { value.sources[0] = value.sources[1]; },
  value => { value.sources[0].path = '../release-body.md'; }, value => { value.sources[0].observed_sha256 = '0'.repeat(64); },
  value => { value.sources[0].approved = true; } ]) {
  const value = cloned(); change(value); reject(() => prepare(value), /source|inventory|Producer|producer|origin|coordinate/);
}
check(() => assert.deepEqual(fs.readdirSync(namespaceRoot), []));
for (const change of [ value => { delete value.npmSources; }, value => value.npmSources.pop(),
  value => { value.npmSources[0] = value.npmSources[1]; }, value => { value.npmSources[0].path = '../LICENSE'; },
  value => { value.npmSources[0].observed_sha256 = '0'.repeat(64); }, value => { value.npmSources[0].approved = true; },
  value => { const row = value.sources.find(row => row.path === 'npm/winsmux-0.38.0.tgz');
    row.source_file = path.join(bundle.root, row.path); row.observed_sha256 = bundle.assets.find(asset => asset.path === row.path).sha256; } ]) {
  const value = cloned(); change(value); reject(() => prepare(value), /npm|Producer|header|format|data|Asset differs from original typed producer bytes/u);
  check(() => assert.deepEqual(fs.readdirSync(namespaceRoot), []));
}
const first = prepare();
check(() => {
  assert.equal(first.publication_admitted, false); assert.equal(first.bundle.assets.length, 14);
  assert.equal(first.manifest_sha256, sha(fs.readFileSync(first.manifest_file)));
  assert.notEqual(first.bundle.root, bundle.root); revalidatePublicationBundle(first.bundle);
});
for (const row of input.sources) check(() => assert.deepEqual(fs.readFileSync(path.join(first.bundle.root, row.path)), originalFiles.get(row.source_file)));
check(() => assert.equal(sha(fs.readFileSync(path.join(first.bundle.root, 'npm/winsmux-0.38.0.tgz'))), npmProof.npm_sha256));

// Both public entry points revalidate the same issued capability before consuming assets.
const readPrepared = receipt => {
  const value=JSON.parse(fs.readFileSync(first.manifest_file)); value.origins_sha256=receipt.sha256;
  return readIntegratedPublicationAssets(contract,first.bundle.root,Buffer.from(JSON.stringify(value)),receipt);
};
reject(()=>readPrepared(structuredClone(origins)),/capability/);
const mutableSource=observers.source();
const mutableObservers={...observers,source:()=>structuredClone(mutableSource)};
const mutableOrigins=observeIntegratedPublicationOrigins(contract,mutableObservers);
mutableSource.changes[0].after_sha256='c'.repeat(64);
reject(()=>prepare({...input,origins:mutableOrigins}),/Original producer\/source observation changed/);
reject(()=>readPrepared(mutableOrigins),/Original producer\/source observation changed/);
const issuedFile=path.join(root,'current-origin-after-issuance.bin');
const issuedBytes=Buffer.from('Synthetic original evidence at capability issuance.\n');
fs.writeFileSync(issuedFile,issuedBytes,{flag:'wx'});
const issuedPin={path:issuedFile,bytes:issuedBytes.length,sha256:sha(issuedBytes)};
const fileOrigins=observeIntegratedPublicationOrigins(contract,{...observers,source:()=>({...observers.source(),originals:[issuedPin]})});
fs.appendFileSync(issuedFile,'changed');
reject(()=>prepare({...input,origins:fileOrigins}),/Origin bytes or physical identity changed/);
reject(()=>readPrepared(fileOrigins),/Origin bytes or physical identity changed/);

const second = prepare();
check(() => { assert.notEqual(first.bundle.identity.attempt, second.bundle.identity.attempt); revalidatePublicationBundle(first.bundle); revalidatePublicationBundle(second.bundle); });
const marker = freezePublicationAttempt(contract, first.bundle, namespaceRoot, () => ({ pid: 42, creation_filetime: '134350000000000001',
  job_name: 'Local\\winsmux-integrated-publication-' + 'a'.repeat(32),
  keeper: { pid: 43, creation_filetime: '134350000000000002', pipe_name: 'winsmux-publication-keeper-' + 'a'.repeat(32),
    attempt: first.bundle.identity.attempt, candidate_manifest_sha256: first.bundle.identity.manifest_sha256,
    implementation_sha256: 'b'.repeat(64), script_sha256: 'c'.repeat(64) } }),
  () => ({ pid: 41, creation_filetime: '134350000000000000' }));
const markerBytes = fs.readFileSync(marker.file);
const beforeDirectory = fs.readdirSync(path.join(namespaceRoot, 'v0.38.0')).sort();
reject(() => prepare(), /frozen/);
check(() => assert.deepEqual(fs.readdirSync(path.join(namespaceRoot, 'v0.38.0')).sort(), beforeDirectory));
check(() => assert.deepEqual(fs.readFileSync(marker.file), markerBytes));
for (const [file, bytes] of originalFiles) check(() => assert.deepEqual(fs.readFileSync(file), bytes));
check(() => { revalidatePublicationBundle(first.bundle); revalidatePublicationBundle(second.bundle); });
console.log(JSON.stringify({ passed: true, checks, assets: 14, publication_admitted: false, npm_sha256: npmProof.npm_sha256,
  scope: 'Typed observer capability and original-byte binding with actual Windows-verified npm; Core/Desktop/source payloads are synthetic fixture code; original Core/npm coordinates and receipts are retained. Signed preparation/crypto/Windows success is not asserted. No genuine producer, signature, native permission or publication success claim.' }));
