import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { observePublicationTools, revalidatePublicationTools, observedPublicationInvocations } from '../../scripts/observe-publication-tools.mjs';

const root=path.resolve('.evidence/workspace-package','publication-tools-'+randomUUID());
fs.mkdirSync(root,{recursive:true});
const paths=Object.fromEntries([['githubCli','gh.exe'],['nodeExecutable','node.exe'],['npmCli','npm-cli.js']]
  .map(([key,name])=>[key,path.join(root,name)]));
for(const [key,file] of Object.entries(paths))fs.writeFileSync(file,key==='npmCli'?'// Synthetic npm source only\n':'MZ synthetic byte-observation fixture');
let checks=0;
const check=fn=>{fn();checks++;};
const reject=(fn,pattern)=>check(()=>assert.throws(fn,pattern));
const tools=observePublicationTools(paths);
check(()=>assert.equal(revalidatePublicationTools(tools).local_tool_integrity_verified,true));
check(()=>assert.equal(tools.native_custody_verified,false));
check(()=>assert.equal(tools.publication_admitted,false));
reject(()=>revalidatePublicationTools(structuredClone(tools)),/Actual process-local/);
reject(()=>revalidatePublicationTools({...tools}),/Actual process-local/);
reject(()=>observePublicationTools({...paths,approved:true}),/inventory/);
for(const key of Object.keys(paths)) {
  reject(()=>observePublicationTools({...paths,[key]:path.basename(paths[key])}),/absolute/);
  reject(()=>observePublicationTools({...paths,[key]:paths[key]+'-wrapper'}),/ENOENT|filename/);
  const original=fs.readFileSync(paths[key]);
  fs.appendFileSync(paths[key],'changed');
  reject(()=>revalidatePublicationTools(tools),/changed/);
  fs.writeFileSync(paths[key],original);
  // Restoring bytes cannot restore the previously observed file timestamp.
  reject(()=>revalidatePublicationTools(tools),/changed/);
}
const fresh=observePublicationTools(paths);
reject(()=>observedPublicationInvocations({}, {}, {approved:true}, fresh),/Contract/);
reject(()=>{fresh.githubCli.sha256='0'.repeat(64);},TypeError);
const alias=path.join(root,'alias');fs.mkdirSync(alias);
const duplicate=path.join(alias,'gh.exe');fs.linkSync(paths.githubCli,duplicate);
reject(()=>observePublicationTools(paths),/single-link/);
const sourceNames=['scripts/observe-publication-tools.mjs','tests/workspace-package/publication-tools.test.mjs'];
const result={passed:true,checks,observed_at:new Date().toISOString(),
  source_sha256:Object.fromEntries(sourceNames.map(name=>[name,createHash('sha256').update(fs.readFileSync(name)).digest('hex')])),
  native_custody_verified:false,publication_admitted:false,
  scope:'Synthetic local tool bytes; exact names, process-local origin, native identity, mutation and link refusals; no process execution.'};
const resultFile=path.join(root,'result.json');fs.writeFileSync(resultFile,JSON.stringify(result),{flag:'wx'});
console.log(JSON.stringify({...result,original_result:resultFile}));
