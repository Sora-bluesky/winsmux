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
assert.equal(sha(npmResultBytes),'1db46db17bf5f87e854274f61dc959856ebb5fe3b91bf616232b45255821001d');
const npmResult=JSON.parse(npmResultBytes);
const receiptFile=path.join(path.dirname(npmTrialFile),'npm-candidate.json');
const receiptBytes=fs.readFileSync(receiptFile);
assert.equal(sha(receiptBytes),'0da4d89fa8a82c4594ef5a1acc1e315510385fd8bd4e1de1c00eedbd6a6e4cfe');
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
const base='5a94dd8ab09886294b7843860d23fe0f6bd42d11', tree='9b03d3ac8b91ed0db42193f592316b56649b147b';
const npmHead='5a94dd8ab09886294b7843860d23fe0f6bd42d11';
// Retired b048b00b/c36c0265, c43aed07/9fba0d77, a1ce1975/8014b3a1, 9be98eb5/92b55959, ce0c39ba/4dcec20a 9f1a3fe1/5fcccd2c, G9 c7b62eb4/4c45f4d7 and X f8f73545/f327febf coordinates: the module must refuse the superseded producers.
const retiredG9Base='c7b62eb4aa7001c7fce28cbe5a0bc0ecbdc71bbd', retiredG9Tree='4c45f4d70b30bdfb9000ab9212b9a849d0e349b1', retiredG9AssemblyRun='local-assembly-8d3405cf-7cc3-4cdb-bcd3-5ba68f2726b8';
const retiredXBase='f8f735452109af1bc24adcc8160f0106fa607d81', retiredXTree='f327febf341cd11b79b573c7fe2ae14c22aa821b', retiredXAssemblyRun='local-assembly-eb01f410-65ec-4cf7-ab4f-af8f75ee8ed3';
const retiredNpmHead='b048b00b9291e346c247f2799d96283e21cb471e', retiredNpmTree='c36c02659c7de29251af25d1ae58fdfd45a6bd26';
const retiredBase='c43aed076c076726f616e8a6bf489c8709246f17', retiredTree='9fba0d77cad1d2294e4b6158d1a3f74fdd2410c7', retiredAssemblyRun='local-assembly-c827d952-2d96-4128-adb3-83ce48fbc67b';
const retiredA1ceBase='a1ce1975ceaa6f6dfa9feb2fa2113fb98d65f4e3', retiredA1ceTree='8014b3a17e55b3c484ee8306b1db2a6cba25f139', retiredA1ceAssemblyRun='local-assembly-405ecdc6-c70e-4dda-9416-fa627e4fd9cd';
const retired9be9Base='9be98eb53433e021315d851ca27bacc9ca44d7f7', retired9be9Tree='92b559597878265f1a465a2e500311118a231a86', retired9be9AssemblyRun='local-assembly-27be8c1a-12a0-44df-a8a0-feaffe29e5eb';
const retiredCe0cBase='ce0c39ba0d4852195df95c5b99666a1a3441c887', retiredCe0cTree='4dcec20aafed921f62ce29ebbe148545d39b01c3', retiredCe0cAssemblyRun='local-assembly-905a634a-6d13-4468-b7fa-991acd432aaa';
const retired9f1aBase='9f1a3fe133f248a11500bb24a387b21464191ff4', retired9f1aTree='5fcccd2c67aec1ab11665dd610383aa33c5462e7', retired9f1aAssemblyRun='local-assembly-8995c8b2-8393-4ec4-a255-4a2b31b757f1';
// The S rows: 5a94dd8a before bytes are real pins, after digests are synthetic.
const s5Changes = Object.freeze([
  { path: 'scripts/integrated-publication-origins.mjs', before_sha256: '0db24fac21b69b1c401aba76ebd34e24fc330dffd3616502ecb4a2945e8b1ace', after_sha256: 'd'.repeat(64) },
  { path: 'tests/workspace-package/prepare-integrated-publication.test.mjs', before_sha256: '945368f95cd869f92d6f5912432637f1f416701acae200f43e11a19175508e56', after_sha256: 'e'.repeat(64) },
  { path: 'tests/workspace-gate-map/gate-map.json', before_sha256: 'bbf7e6c2bc8e3ac5ee9ae888665bf4647e6b9110aae446c29214fb5e8e1aeb7f', after_sha256: 'f'.repeat(64) },
  { path: '.github/workflows/test.yml', before_sha256: '72f786f0327c51a784b4f5643cb79680e7f33bd1c8cfe4561fa0bf7c60fcfe32', after_sha256: '3'.repeat(64) },
  { path: 'scripts/winsmux-pester.psm1', before_sha256: '1340ad2f22f53fd7db1cdf2eed909336422956f4c0da40522591933895dc72b5', after_sha256: '4'.repeat(64) },
  { path: 'winsmux-app/src-tauri/wix/installer.wxs', before_sha256: '5457dfaa366882c3e2255fa045f52aaae847cae5712fe10f274a21b622598939', after_sha256: '5'.repeat(64) },
  { path: 'tests/workspace-package/desktop-publisher-contract.mjs', before_sha256: 'b2cd4f61bf7364ac9641aa9451935b32ceb13c374fe44660561539d9289d6c6a', after_sha256: '6'.repeat(64) },
]);
const rowOf = (value, file) => value.source.changes.find(row => row.path === file);
const pin={path:npmProof.candidate_receipt_path,bytes:fs.statSync(npmProof.candidate_receipt_path).size,sha256:npmProof.candidate_receipt_sha256};
const rows=input.sources.map(row=>({path:row.path,source_file:row.source_file,bytes:fs.statSync(row.source_file).size,sha256:row.observed_sha256}));
const evidenceRoot=path.resolve(path.dirname(npmTrialFile),'../..');
const finalSource='a'.repeat(40), finalTree='b'.repeat(40);
const originalReceipt=(file,expected)=>{const bytes=fs.readFileSync(file);assert.equal(sha(bytes),expected);return {path:file,bytes:bytes.length,sha256:expected};};
const coreReceipt=originalReceipt(path.join(evidenceRoot,'receipts/assembly/assembly-proof.json'),'acfbb40c5f8141e15b7618adf73c6a7441d2d113ba5c133319cd5a1bfa522b3c');
const npmReceipt=originalReceipt(npmTrialFile,'1db46db17bf5f87e854274f61dc959856ebb5fe3b91bf616232b45255821001d');
// Coordinates are original evidence facts; payloads and signed preparation below are synthetic.
const producerFixtures = {
  "core": {
    "kind": "private-core-assembly",
    "source_commit": "5a94dd8ab09886294b7843860d23fe0f6bd42d11",
    "source_tree": "9b03d3ac8b91ed0db42193f592316b56649b147b",
    "run": "local-assembly-a88efefc-68da-491f-8791-5eb74c60cc94",
    "inner_origins": [
      {
        "kind": "windows-x64",
        "source_commit": "5a94dd8ab09886294b7843860d23fe0f6bd42d11",
        "run": "local-g10-67c911ba-ffbf-4992-b74d-1fa485c864af",
        "receipt_sha256": "7fa855f72d536f2d892f0c9f1b498d7bdb23c5a28c34b5b6014e37873e1382f9"
      },
      {
        "kind": "windows-arm64",
        "source_commit": "5a94dd8ab09886294b7843860d23fe0f6bd42d11",
        "run": "local-g10-67c911ba-ffbf-4992-b74d-1fa485c864af",
        "receipt_sha256": "18c8c7af0e05be962f8060ba48ba8efb2c3aac47ddce661d81d00080b48d5d4c"
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
      "sha256": "acfbb40c5f8141e15b7618adf73c6a7441d2d113ba5c133319cd5a1bfa522b3c"
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
    "source_commit": "5a94dd8ab09886294b7843860d23fe0f6bd42d11",
    "source_tree": "9b03d3ac8b91ed0db42193f592316b56649b147b",
    "run": "local-npm-5a94dd8a",
    "inner_origins": [
      {
        "kind": "local-npm-pack-and-windows-help-version",
        "source_commit": "5a94dd8ab09886294b7843860d23fe0f6bd42d11",
        "run": "local-npm-5a94dd8a",
        "receipt_sha256": "1db46db17bf5f87e854274f61dc959856ebb5fe3b91bf616232b45255821001d"
      }
    ],
    "original_receipt": {
      "bytes": 252,
      "sha256": "1db46db17bf5f87e854274f61dc959856ebb5fe3b91bf616232b45255821001d"
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

// Read back the preserved seven payloads and the evidence transitively bound by the assembly pin.
const assembly=JSON.parse(fs.readFileSync(coreReceipt.path));
check(()=>{assert.equal(assembly.source_commit,base);assert.equal(assembly.assembly_source_tree,tree);assert.equal(npmResult.source_commit,npmHead);});
check(()=>{assert.equal(assembly.completed,true);assert.equal(assembly.assets.length,6);});
for(const asset of assembly.assets)check(()=>{
  const bytes=fs.readFileSync(path.join(evidenceRoot,'assets/core',asset.path));
  assert.equal(bytes.length,asset.bytes);assert.equal(sha(bytes),asset.sha256);
});
check(()=>{const bytes=fs.readFileSync(path.join(evidenceRoot,'assets/npm/winsmux-0.38.0.tgz'));assert.equal(bytes.length,npmResult.bytes);assert.equal(sha(bytes),npmProof.npm_sha256);});
check(()=>{
  const ch1=JSON.parse(fs.readFileSync(originalReceipt(path.join(evidenceRoot,'inventory/ch1-proof.json'),assembly.ch1_proof_sha256).path));
  assert.equal(ch1.source_commit,base);assert.equal(ch1.dependency_closure_equal,true);
  assert.equal(ch1.helper_sha256,assembly.assets.find(row=>row.path==='winsmux-remote-helper-linux-x64').sha256);
  for(const value of [assembly.helper_rebuilt,ch1.helper_rebuilt,ch1.helper_native_tests_reexecuted,
    assembly.strict_current_collector_passed,ch1.strict_current_collector_passed,assembly.publication_admitted])assert.equal(value,false);
  assert.equal(assembly.origins[2].receipt.source_commit,producerFixtures.core.inner_origins[2].source_commit);
  assert.equal(assembly.origins[2].package_version,'0.36.38');
});
check(()=>{
  const scan=JSON.parse(fs.readFileSync(originalReceipt(path.join(evidenceRoot,'checks/current-core-local-path-scan.json'),assembly.local_path_scan_sha256).path));
  assert.equal(scan.accepted,true);assert.equal(scan.matches,0);
  assert.deepEqual(scan.files.map(row=>({path:row.path,bytes:row.bytes,sha256:row.sha256})),assembly.assets);
});

// Final-source applicability is exactly the S rows with their 5a94dd8a before bytes, independent of producer coordinates.
check(() => { assert.equal(publicationCutoverPaths.length,49); assert.equal(new Set(publicationCutoverPaths).size,49); });
const projection = () => Object.fromEntries(Object.entries(observers).map(([key, observer]) => [key, observer()]));
check(() => assert.deepEqual(validateOriginProjection(projection()).source.changes, [...s5Changes]));
for (const change of [
  value => { rowOf(value,'tests/workspace-package/prepare-integrated-publication.test.mjs').before_sha256=rowOf(value,'scripts/integrated-publication-origins.mjs').before_sha256; },
  value => { rowOf(value,'scripts/integrated-publication-origins.mjs').before_sha256='bf6648e0c277f0c2ba89615302ca9abfa069f3b8ef0cbb83403734fb4a3d6090'; },
  value => { rowOf(value,'tests/workspace-package/prepare-integrated-publication.test.mjs').before_sha256='c98f9601cd8273b4daa1c63baea9b8748874fdf630fcc634333b941c53ef230e'; },
  value => { rowOf(value,'scripts/integrated-publication-origins.mjs').before_sha256='c7634d32ad08aeef487da93b5de9a51e3f45782f6df05faaf5083d509667aa29'; },
  value => { rowOf(value,'tests/workspace-package/prepare-integrated-publication.test.mjs').before_sha256='f0f78947cd4ded2a7edebfefbe7932c2dc035ca0b00fdfe4f68b13f7ea481864'; },
  value => { value.source.changes.push({path:'docs/installation.md',before_sha256:'15a3a5f32bc2ca66fb6a001d4082172f8ef4274fcf0afdd76caed9db2ea53992',after_sha256:'a'.repeat(64)}); },
  value => { value.source.changes.push({path:'docs/installation.ja.md',before_sha256:'548abe5398b961c1ab6e90bdb415427518909fb46e5b10448faf0a0f055586a0',after_sha256:'b'.repeat(64)}); },
  value => { value.source.changes.push({path:'docs/quickstart.md',before_sha256:'405bd316a4d047c88d0e0d5aa6c9c0918aeaa56f3b8f44c7546296006c186434',after_sha256:'2'.repeat(64)}); },
  value => { value.source.changes.push({path:'README.ja.md',before_sha256:'aea26cea75fcad5b162c81af11afe388a83c46bc670896becb6c55cdf646c3cb',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'scripts/test-public-release.ps1',before_sha256:'163ae789ef9c6d0d4138cebd82c2f2beaabd0df6f8b6a5eb1b7404b7fbdad48a',after_sha256:'1'.repeat(64)}); },
  value => { value.source.changes.push({path:'tests/VersionSurface.Tests.ps1',before_sha256:'a112bfbaf9f139af412623f9042ac5fd17090af327b039f66281eb81846ec7ed',after_sha256:'1'.repeat(64)}); },
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
  value => { value.npm.source_commit=retiredCe0cBase; },
  value => { value.core.source_commit=retiredCe0cBase; },
  value => { value.source.base_commit=retiredCe0cBase; value.source.base_tree=retiredCe0cTree; },
  value => { value.npm.source_commit=retiredG9Base; },
  value => { value.core.source_commit=retiredG9Base; },
  value => { value.source.base_commit=retiredG9Base; value.source.base_tree=retiredG9Tree; },
  value => { value.npm.source_commit=retiredXBase; },
  value => { value.core.source_commit=retiredXBase; },
  value => { value.source.base_commit=retiredXBase; value.source.base_tree=retiredXTree; },
  value => { value.npm.source_commit=retired9f1aBase; },
  value => { value.core.source_commit=retired9f1aBase; },
  value => { value.source.base_commit=retired9f1aBase; value.source.base_tree=retired9f1aTree; },
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
  value=>{value.core.inner_origins[2].source_commit=base;},
  value=>{value.core.inner_origins[2].receipt_sha256='0'.repeat(64);},
  value=>{value.core.kind='hosted-core-assembly';},
  value=>{value.core.originals[0]={...value.core.originals[0],bytes:16931,sha256:'8ee0f610748e6d9485c40ecf4825b362861ae352136166440041a209fdb56f97'};},
  value=>{value.npm.originals[0]={...value.npm.originals[0],bytes:1596,sha256:'c9080b4ed7e12f3f38716bed955975ca82e96c580f1a22bdf1738eb627110f23'};},
  value=>{value.npm.source_tree=retiredNpmTree;},
  value=>{value.npm.source_tree=retiredTree;},
  value=>{value.core.run=retiredAssemblyRun;},
  value=>{value.npm.source_tree=retiredA1ceTree;},
  value=>{value.core.run=retiredA1ceAssemblyRun;},
  value=>{value.npm.source_tree=retired9be9Tree;},
  value=>{value.core.run=retired9be9AssemblyRun;},
  value=>{value.npm.source_tree=retiredCe0cTree;},
  value=>{value.core.run=retiredCe0cAssemblyRun;},
  value=>{value.npm.source_tree=retiredG9Tree;},
  value=>{value.core.run=retiredG9AssemblyRun;},
  value=>{value.npm.source_tree=retiredXTree;},
  value=>{value.core.run=retiredXAssemblyRun;},
  value=>{value.npm.source_tree=retired9f1aTree;},
  value=>{value.core.run=retired9f1aAssemblyRun;},
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
