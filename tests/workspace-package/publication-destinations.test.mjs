import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { publicationFixture, sha } from './publication-fixture.mjs';
import { validatePublicReleaseInventory, validatePublicAssetBytes, validatePublicNpmMetadata,
  assertPublicBinaryRedirect, readObservedPublicationRows } from '../../scripts/observe-publication-destinations.mjs';

const fixture = publicationFixture(path.resolve(process.argv[2]));
const { contract, bundle, files, root } = fixture;
let checks = 0;
const check = action => { action(); checks++; };
const reject = (action, pattern) => check(() => assert.throws(action, pattern));
const api = 'https://api.github.com/repos/Sora-bluesky/winsmux';
const release = { id: 42, url: api + '/releases/42', html_url: 'https://github.com/Sora-bluesky/winsmux/releases/tag/v0.38.0',
  tag_name: 'v0.38.0', draft: false, prerelease: false, body: files.get('release-body.md').toString('utf8') };
const assets = bundle.assets.filter(row => /^(core|desktop)\//u.test(row.path)).map((row,index) => ({
  id: index + 1, name: path.posix.basename(row.path), size: row.bytes, state: 'uploaded',
  url: api + '/releases/assets/' + (index+1), digest: 'sha256:' + row.sha256,
  browser_download_url: 'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/' + path.posix.basename(row.path),
  created_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-03T00:00:00Z' }));
check(() => assert.equal(validatePublicReleaseInventory(bundle, release, bundle.identity.source_commit, assets).assets.length, 12));
check(() => assert.equal(validatePublicReleaseInventory(bundle, null, null, []).release_present, false));
check(() => assert.equal(validatePublicReleaseInventory(bundle, release, bundle.identity.source_commit, assets.slice(0,4)).assets.length, 4));
reject(() => validatePublicReleaseInventory(structuredClone(bundle), release, bundle.identity.source_commit, assets), /observed/);
reject(() => validatePublicReleaseInventory(bundle, null, bundle.identity.source_commit, []), /inconsistent/);
reject(() => validatePublicReleaseInventory(bundle, null, null, assets), /inconsistent/);
reject(() => validatePublicReleaseInventory(bundle, release, '0'.repeat(40), assets), /differs/);
for (const change of [ value => { value.id=0; }, value => { value.url=api+'/releases/43'; },
  value => { value.html_url='https://github.com/other/winsmux/releases/tag/v0.38.0'; },
  value => { value.tag_name='v0.37.0'; }, value => { value.draft=true; }, value => { value.prerelease=true; },
  value => { value.body=null; } ]) {
  const value=structuredClone(release); change(value);
  reject(() => validatePublicReleaseInventory(bundle,value,bundle.identity.source_commit,assets), /differs/);
}
for (let index=0; index<assets.length;index++) {
  for (const change of [ value => { value.name='unknown'; }, value => { value.size++; }, value => { value.state='starter'; },
    value => { value.id=0; }, value => { value.url=api+'/releases/assets/900'; },
    value => { value.browser_download_url='https://github.com/other/winsmux/releases/download/v0.38.0/'+value.name; },
    value => { value.digest='sha256:'+'0'.repeat(64); } ]) {
    const value=structuredClone(assets); change(value[index]);
    reject(() => validatePublicReleaseInventory(bundle,release,bundle.identity.source_commit,value), /differs/);
  }
}
for (const change of [ value => value.push(value[0]), value => { value[1].id=value[0].id; },
  value => { value[1].name=value[0].name; } ]) {
  const value=structuredClone(assets);change(value);
  reject(() => validatePublicReleaseInventory(bundle,release,bundle.identity.source_commit,value), /differs/);
}
check(() => {
  const withoutDigest=structuredClone(assets);withoutDigest.forEach(row => delete row.digest);
  assert.equal(validatePublicReleaseInventory(bundle,release,bundle.identity.source_commit,withoutDigest).assets.length,12);
});
for (const row of bundle.assets) {
  check(() => assert.equal(validatePublicAssetBytes(bundle,row.path,files.get(row.path)).sha256,row.sha256));
  reject(() => validatePublicAssetBytes(bundle,row.path,Buffer.from('different')), /differ/);
  const mutated=Buffer.from(files.get(row.path));mutated[0]^=1;
  reject(() => validatePublicAssetBytes(bundle,row.path,mutated), /differ/);
}
reject(() => validatePublicAssetBytes(bundle,'unknown',Buffer.alloc(0)), /differ/);
const npmBytes=files.get('npm/winsmux-0.38.0.tgz');
const npm={name:'winsmux',version:'0.38.0',gitHead:bundle.identity.source_commit,
  dist:{tarball:'https://registry.npmjs.org/winsmux/-/winsmux-0.38.0.tgz',
    shasum:createHash('sha1').update(npmBytes).digest('hex'),
    integrity:'sha512-'+createHash('sha512').update(npmBytes).digest('base64')}};
check(() => assert.equal(validatePublicNpmMetadata(bundle,npm).metadata_verified,true));
check(() => { const value=structuredClone(npm);delete value.dist.integrity;delete value.gitHead;assert.equal(validatePublicNpmMetadata(bundle,value).metadata_verified,true); });
for (const change of [value => {value.name='other';},value => {value.version='0.37.0';},
  value => {value.gitHead='0'.repeat(40);},value => {value.dist.tarball='https://localhost/secret';},
  value => {value.dist.shasum='missing';},value => {value.dist.integrity='sha1-x';},
  value => {value.dist.integrity='sha512-'+'A'.repeat(87)+'=';}]) {
  const value=structuredClone(npm);change(value);
  reject(() => validatePublicNpmMetadata(bundle,value), /differs|required/);
}
const source=api+'/releases/assets/1';
const cdn='https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=synthetic';
check(() => assert.equal(assertPublicBinaryRedirect(source,cdn,new Set([source])),cdn));
check(() => assert.ok(assertPublicBinaryRedirect(source,'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/latest.json',new Set([source]))));
check(() => assert.ok(assertPublicBinaryRedirect(source,'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.0_x64-setup.inventory.json',new Set([source]))));
for(const target of ['http://release-assets.githubusercontent.com/x','https://localhost/x',
  'https://release-assets.githubusercontent.com.evil.example/x','https://user@release-assets.githubusercontent.com/x',
  'https://release-assets.githubusercontent.com:8443/x','https://release-assets.githubusercontent.com/x#fragment',
  'https://github.com/other/winsmux/releases/download/v0.38.0/latest.json',
  'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/unknown',
  'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.1_x64-setup.inventory.json',
  'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.0_arm64-setup.inventory.json',
  'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/../latest.json'])
  reject(() => assertPublicBinaryRedirect(source,target,new Set()), /boundary|another release/);
reject(() => assertPublicBinaryRedirect(source,cdn,new Set([cdn])), /cyclic/);
reject(() => readObservedPublicationRows(contract,bundle,{passed:true,rows:bundle.assets.map(row => ({path:row.path,state:'matching',sha256:row.sha256}))}), /actual public origin/);
const sourceNames=['scripts/observe-publication-destinations.mjs','tests/workspace-package/publication-destinations.test.mjs',
  'scripts/integrated-publication-contract.mjs','scripts/integrated-publication-assets.mjs',
  'scripts/distribution-prelaunch.mjs','scripts/assert-license-inputs.mjs','tests/workspace-package/publication-fixture.mjs'];
const result={observed_at:new Date().toISOString(),passed:true,checks,publication_admitted:false,
  source_sha256:Object.fromEntries(sourceNames.map(name => [name,sha(fs.readFileSync(name))])),
  scope:'Synthetic metadata/binary/redirect adversarial cases. Actual public downloads and origin observation separate; no public write or stage approval.'};
fs.writeFileSync(path.join(root,'public-destinations-target-result.json'),JSON.stringify(result));
console.log(JSON.stringify({...result,original_result:path.join(root,'public-destinations-target-result.json')}));
