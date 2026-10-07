import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { publicationFixture,sha } from './publication-fixture.mjs';
import { publicationOperations,planObservedIntegratedPublication,revalidateObservedPublicationPlan } from '../../scripts/plan-integrated-publication.mjs';

const {contract,bundle,root}=publicationFixture(path.resolve(process.argv[2]));
const allAbsent=()=>bundle.assets.map(row=>({path:row.path,state:'absent',sha256:null}));
const allMatching=()=>bundle.assets.map(row=>({path:row.path,state:'matching',sha256:row.sha256}));
let checks=0;
const check=action=>{action();checks++;};
const reject=(action,pattern)=>check(()=>assert.throws(action,pattern));
const before=Object.fromEntries(bundle.assets.map(row=>[row.path,sha(fs.readFileSync(path.join(bundle.root,row.path)))]));
const plan=publicationOperations(bundle,allAbsent());
check(()=>assert.equal(plan.operations.length,3));
check(()=>assert.equal(plan.missing_assets.length,14));
check(()=>assert.deepEqual(plan.operations.map(row=>row.kind),['github_release_create','github_release_upload','npm_publish']));
check(()=>assert.equal(plan.operations[0].arguments.at(-1),path.join(bundle.root,'release-body.md')));
check(()=>assert.equal(plan.operations[0].arguments[plan.operations[0].arguments.indexOf('--target')+1],bundle.identity.source_commit));
check(()=>assert.equal(plan.operations[1].assets.length,12));
check(()=>assert.equal(plan.operations[2].arguments[1],path.join(bundle.root,'npm/winsmux-0.38.0.tgz')));
for(const operation of plan.operations){
  check(()=>assert.equal(operation.arguments.some(value=>['--clobber','--force','--generate-notes'].includes(value)),false));
  check(()=>assert.equal(operation.assets.every(row=>bundle.assets.includes(row)),true));
}
check(()=>assert.equal(plan.publication_admitted,false));
check(()=>assert.equal(publicationOperations(bundle,allMatching()).operations.length,0));
for(const asset of bundle.assets.filter(row=>row.path!=='release-body.md')){
  const rows=allMatching();rows.find(row=>row.path===asset.path).state='absent';rows.find(row=>row.path===asset.path).sha256=null;
  const partial=publicationOperations(bundle,rows);
  check(()=>assert.deepEqual(partial.missing_assets,[asset.path]));
  check(()=>assert.equal(partial.operations.length,1));
  check(()=>assert.deepEqual(partial.operations[0].assets,[asset]));
  check(()=>assert.equal(partial.matched_assets,13));
}
const invalids=[rows=>rows.pop(),rows=>rows.push(rows[0]),rows=>{rows[0]=rows[1];},
  rows=>{rows[0].state='unknown';},rows=>{rows[0].sha256='0'.repeat(64);},rows=>{rows[0].approved=true;},
  rows=>{rows[0].state='absent';}];
for(const change of invalids){const rows=allMatching();change(rows);reject(()=>publicationOperations(bundle,rows),/rows|required|conflicting/);}
const bodyOnly=allMatching();bodyOnly.find(row=>row.path==='release-body.md').state='absent';bodyOnly.find(row=>row.path==='release-body.md').sha256=null;
reject(()=>publicationOperations(bundle,bodyOnly),/all fixed release assets/);
reject(()=>publicationOperations(structuredClone(bundle),allAbsent()),/observed/);
reject(()=>planObservedIntegratedPublication(contract,bundle,{passed:true,rows:allAbsent()}),/actual public origin/);
reject(()=>revalidateObservedPublicationPlan(contract,bundle,plan),/Actual parent-observed/);
reject(()=>revalidateObservedPublicationPlan(contract,bundle,structuredClone(plan)),/Actual parent-observed/);
reject(()=>{plan.operations[1].arguments.push('--clobber');},TypeError);
check(()=>assert.deepEqual(Object.fromEntries(bundle.assets.map(row=>[row.path,sha(fs.readFileSync(path.join(bundle.root,row.path)))])),before));
const sources=['scripts/plan-integrated-publication.mjs','tests/workspace-package/publication-plan.test.mjs',
  'scripts/observe-publication-destinations.mjs','scripts/integrated-publication-contract.mjs',
  'scripts/integrated-publication-assets.mjs','scripts/distribution-prelaunch.mjs','scripts/assert-license-inputs.mjs','tests/workspace-package/publication-fixture.mjs'];
const result={passed:true,checks,observed_at:new Date().toISOString(),publication_admitted:false,
  source_sha256:Object.fromEntries(sources.map(name=>[name,sha(fs.readFileSync(name))])),
  scope:'Synthetic fixed whole/partial public observations; missing-only command graph, no dispatch/authority or public effects.'};
fs.writeFileSync(path.join(root,'publication-plan-target-result.json'),JSON.stringify(result));
console.log(JSON.stringify({...result,original_result:path.join(root,'publication-plan-target-result.json')}));
