import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID,createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const order=(a,b)=>a<b?-1:a>b?1:0;
const keys=['dev','ino','nlink','size','mtimeNs','ctimeNs'];
const identity=stat=>Object.fromEntries(keys.map(key=>[key,String(stat[key])]));
const root=path.resolve('.evidence/workspace-package/source-guard-'+randomUUID());fs.mkdirSync(root,{recursive:true});
const guard=path.resolve('scripts/publication-node-source-guard.mjs');
const sourceBefore=sha(fs.readFileSync(guard));
const rows=[];
function run(name,body,{afterSnapshot,expected=0,profile=true,wrongHash=false}={}) {
  const folder=path.join(root,name),source=path.join(folder,'source');fs.mkdirSync(source,{recursive:true});
  fs.writeFileSync(path.join(source,'main.mjs'),body,{flag:'wx'});
  fs.writeFileSync(path.join(source,'value.mjs'),'export default 19;\n',{flag:'wx'});
  fs.writeFileSync(path.join(source,'value.cjs'),'module.exports=23;\n',{flag:'wx'});
  fs.writeFileSync(path.join(source,'data.json'),'{"answer":29}\n',{flag:'wx'});
  fs.writeFileSync(path.join(source,'fake.node'),'synthetic addon, never executable',{flag:'wx'});
  const names=fs.readdirSync(source).sort(order);
  const manifest={publication_admitted:false,directories:[{path:source,names,identity:identity(fs.lstatSync(source,{bigint:true}))}],
    files:names.map(name=>{const file=path.join(source,name),bytes=fs.readFileSync(file);return {path:file,bytes:bytes.length,sha256:sha(bytes),identity:identity(fs.lstatSync(file,{bigint:true}))};})};
  const manifestPath=path.join(folder,'manifest.json'),manifestBytes=Buffer.from(JSON.stringify(manifest));fs.writeFileSync(manifestPath,manifestBytes,{flag:'wx'});
  if(afterSnapshot)afterSnapshot(source,folder);
  // The fixture process receives only this explicit profile. No system setting
  // or parent environment is changed; the fixture performs no network writes.
  const env={SystemRoot:process.env.SystemRoot,TEMP:folder,TMP:folder,
    WINSMUX_PUBLICATION_SOURCE_MANIFEST:manifestPath,WINSMUX_PUBLICATION_SOURCE_SHA256:wrongHash?'0'.repeat(64):sha(manifestBytes)};
  if(profile)env.NODE_DISABLE_COMPILE_CACHE='1';
  const result=spawnSync(process.execPath,['--no-addons','--import',pathToFileURL(guard).href,path.join(source,'main.mjs')],{env,cwd:source,encoding:'utf8',timeout:30000,windowsHide:true});
  assert.ifError(result.error);assert.equal(result.status,expected,name+': '+result.stderr);
  if(expected!==0)assert.match(result.stderr,/Publication source guard:/u,name);
  rows.push({name,exit_code:result.status,stdout:result.stdout.trim(),guard_refusal:expected!==0});
}
run('esm-cjs-createRequire-json',`import assert from 'node:assert/strict';
import value from './value.mjs';import {createRequire,enableCompileCache} from 'node:module';
const require=createRequire(import.meta.url);assert.equal(value,19);assert.equal(require('./value.cjs'),23);
assert.equal(require('./data.json').answer,29);assert.equal(enableCompileCache().status,3);
console.log('ESM CJS CREATE_REQUIRE JSON CACHE_DISABLED');`);
run('commonjs-require',`import {createRequire} from 'node:module';createRequire(import.meta.url)('./value.cjs');console.log('CJS_OK');`);
run('outside-source',`await import('../outside.mjs');`,{afterSnapshot:(_source,folder)=>fs.writeFileSync(path.join(folder,'outside.mjs'),'export default 1;'),expected:1});
run('url-query',`await import('./value.mjs?alias=1');`,{expected:1});
run('url-fragment',`await import('./value.mjs#alias');`,{expected:1});
run('addon',`import {createRequire} from 'node:module';createRequire(import.meta.url)('./fake.node');`,{expected:1});
run('new-file-before-load',`await import('./added.mjs');`,{afterSnapshot:source=>fs.writeFileSync(path.join(source,'added.mjs'),'export default 1;'),expected:1});
run('new-file-after-start',`import fs from 'node:fs';fs.writeFileSync('added.mjs','export default 1;');await import('./added.mjs');`,{expected:1});
run('source-changed',`await import('./value.mjs');`,{afterSnapshot:source=>fs.writeFileSync(path.join(source,'value.mjs'),'export default 99;'),expected:1});
run('source-exchanged',`await import('./value.mjs');`,{afterSnapshot:(source,folder)=>{const file=path.join(source,'value.mjs');fs.renameSync(file,path.join(folder,'preserved-value.mjs'));fs.writeFileSync(file,'export default 19;\n');},expected:1});
run('hardlink',`await import('./value.mjs');`,{afterSnapshot:(source,folder)=>fs.linkSync(path.join(source,'value.mjs'),path.join(folder,'alias.mjs')),expected:1});
run('manifest-hash',`console.log('MUST_NOT_RUN');`,{wrongHash:true,expected:1});
run('cache-profile-missing',`console.log('MUST_NOT_RUN');`,{profile:false,expected:1});
assert.equal(sha(fs.readFileSync(guard)),sourceBefore);
const result={passed:true,cases:rows.length,rows,node_version:process.version,source_sha256:{'scripts/publication-node-source-guard.mjs':sourceBefore,
  'tests/workspace-package/publication-source-guard.test.mjs':sha(fs.readFileSync(import.meta.filename))},public_effects_executed:0,publication_admitted:false,
  scope:'Actual Node synchronous loader, synthetic controlled sources and explicit child environment. No native source custody or public dispatch.'};
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({passed:true,cases:rows.length,node_version:process.version,original_result:path.join(root,'result.json')}));
