import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID,createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { observePublicationTools } from '../../scripts/observe-publication-tools.mjs';
import { observePublicationRuntimeSources,revalidatePublicationRuntimeSources } from '../../scripts/observe-publication-runtime-sources.mjs';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const root=path.resolve('.evidence/workspace-package/npm-source-guard-'+randomUUID());fs.mkdirSync(root,{recursive:true});
const sourceNames=['scripts/observe-publication-runtime-sources.mjs','scripts/observe-publication-source-tree.mjs',
  'scripts/observe-publication-tools.mjs','scripts/publication-node-source-guard.mjs','tests/workspace-package/publication-npm-guard.test.mjs'];
const hashes=()=>Object.fromEntries(sourceNames.map(file=>[file,sha(fs.readFileSync(file))]));const before=hashes();
const tools=observePublicationTools({githubCli:'C:/Users/sorab/AppData/Local/Programs/GitHub CLI/bin/gh.exe',
  nodeExecutable:'C:/Program Files/nodejs/node.exe',npmCli:'C:/Program Files/nodejs/node_modules/npm/bin/npm-cli.js'});
// One controlled bootstrap in its own stable source directory. The installed
// npm entry and transitive JS/JSON/data files come from actual tool observations.
const sources=path.join(root,'source');fs.mkdirSync(sources);
const bootstrap=path.join(sources,'bootstrap.mjs');fs.writeFileSync(bootstrap,"import {enableCompileCache} from 'node:module';if(enableCompileCache().status!==3)throw new Error('Compile cache enabled');console.log('CACHE_DISABLED');\n",{flag:'wx'});
const guard=path.resolve('scripts/publication-node-source-guard.mjs');
const observed=observePublicationRuntimeSources(tools,[bootstrap],guard);
assert.equal(revalidatePublicationRuntimeSources(observed).runtime_sources_integrity_verified,true);
assert.throws(()=>revalidatePublicationRuntimeSources(structuredClone(observed)),/Original process-local/u);
assert.equal(observed.native_custody_verified,false);
const manifest=path.join(root,'manifest.json');fs.writeFileSync(manifest,JSON.stringify(observed.manifest),{flag:'wx'});
const temp=path.join(root,'temp');fs.mkdirSync(temp);
const userConfig=path.join(temp,'user.npmrc'),globalConfig=path.join(temp,'global.npmrc');fs.writeFileSync(userConfig,'',{flag:'wx'});fs.writeFileSync(globalConfig,'',{flag:'wx'});
const env={SYSTEMROOT:process.env.SystemRoot,WINDIR:process.env.SystemRoot,TEMP:temp,TMP:temp,NODE_DISABLE_COMPILE_CACHE:'1',
  WINSMUX_PUBLICATION_SOURCE_MANIFEST:manifest,WINSMUX_PUBLICATION_SOURCE_SHA256:observed.manifest_sha256};
const common=['--no-addons','--import',pathToFileURL(guard).href];
const cache=spawnSync(tools.nodeExecutable.path,[...common,bootstrap],{cwd:temp,env,encoding:'utf8',windowsHide:true,timeout:30000});
assert.ifError(cache.error);assert.equal(cache.status,0,'Controlled guarded cache probe failed');assert.equal(cache.stdout.trim(),'CACHE_DISABLED');
const npm=spawnSync(tools.nodeExecutable.path,[...common,tools.npmCli.path,'--version','--userconfig='+userConfig,'--globalconfig='+globalConfig,
  '--cache='+path.join(temp,'cache'),'--registry=https://registry.npmjs.org','--ignore-scripts'],{cwd:temp,env,encoding:'utf8',windowsHide:true,timeout:30000});
assert.ifError(npm.error);assert.equal(npm.status,0,'Actual guarded npm version probe failed');assert.match(npm.stdout.trim(),/^\d+\.\d+\.\d+$/u);
assert.equal(npm.stderr,'','Unexpected diagnostic from controlled version probe');
assert.equal(revalidatePublicationRuntimeSources(observed).runtime_sources_integrity_verified,true);assert.deepEqual(hashes(),before);
const result={passed:true,node_version:process.version,npm_version:npm.stdout.trim(),files:observed.manifest.files.length,directories:observed.manifest.directories.length,
  manifest_sha256:observed.manifest_sha256,source_sha256:before,compile_cache_disabled:true,public_effects_executed:0,native_custody_verified:false,publication_admitted:false,
  scope:'Actual installed npm --version under synchronous fixed source guard and empty explicit user/global config. No registry write, real auth, native npm custody or publishConfig priority proof.'};
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({passed:true,node_version:process.version,npm_version:result.npm_version,files:result.files,original_result:path.join(root,'result.json')}));
