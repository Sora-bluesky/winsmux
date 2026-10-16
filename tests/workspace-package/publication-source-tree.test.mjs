import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID,createHash } from 'node:crypto';
import { observePublicationTools } from '../../scripts/observe-publication-tools.mjs';
import { observePublicationSourceTree,revalidatePublicationSourceTree } from '../../scripts/observe-publication-source-tree.mjs';

let checks=0;
const root=path.resolve('.evidence/workspace-package/source-tree-'+randomUUID());fs.mkdirSync(root,{recursive:true});
const fixture=name=>{
  const folder=path.join(root,name),npm=path.join(folder,'npm');fs.mkdirSync(path.join(npm,'bin'),{recursive:true});fs.mkdirSync(path.join(npm,'lib'));
  const paths={githubCli:path.join(folder,'gh.exe'),nodeExecutable:path.join(folder,'node.exe'),npmCli:path.join(npm,'bin','npm-cli.js')};
  fs.writeFileSync(paths.githubCli,'MZsynthetic-gh',{flag:'wx'});fs.writeFileSync(paths.nodeExecutable,'MZsynthetic-node',{flag:'wx'});
  fs.writeFileSync(paths.npmCli,"require('../lib/cli.js')\n",{flag:'wx'});fs.writeFileSync(path.join(npm,'lib','cli.js'),'module.exports=1\n',{flag:'wx'});
  fs.writeFileSync(path.join(npm,'package.json'),'{"name":"npm","synthetic":true}\n',{flag:'wx'});
  const tools=observePublicationTools(paths);return {folder,npm,paths,tools,tree:observePublicationSourceTree(tools)};
};
const refused=(operation,pattern)=>{assert.throws(operation,pattern);checks++;};
const valid=fixture('valid');
assert.equal(valid.tree.files.length,3);checks++;
assert.equal(valid.tree.directories.length,3);checks++;
assert.ok(valid.tree.files.some(row=>row.relative_path==='lib/cli.js'));checks++;
assert.ok(Object.isFrozen(valid.tree.files)&&Object.isFrozen(valid.tree.files[0].identity));checks++;
assert.equal(revalidatePublicationSourceTree(valid.tree).source_inventory_integrity_verified,true);checks++;
assert.equal(valid.tree.module_namespace_closed,false);checks++;
assert.equal(valid.tree.native_custody_verified,false);checks++;
assert.equal(valid.tree.publication_admitted,false);checks++;
refused(()=>revalidatePublicationSourceTree(JSON.parse(JSON.stringify(valid.tree))),/Original process-local/u);
refused(()=>observePublicationSourceTree(JSON.parse(JSON.stringify(valid.tools))),/Actual process-local/u);
const changed=fixture('changed');fs.writeFileSync(path.join(changed.npm,'lib','cli.js'),'module.exports=2\n');
refused(()=>revalidatePublicationSourceTree(changed.tree),/Observed npm source tree changed/u);
const added=fixture('added');fs.writeFileSync(path.join(added.npm,'lib','new-loader.js'),'module.exports=3\n',{flag:'wx'});
refused(()=>revalidatePublicationSourceTree(added.tree),/Observed npm source tree changed/u);
const replaced=fixture('same-bytes-replacement');
const old=path.join(replaced.npm,'lib','cli.js');fs.renameSync(old,path.join(replaced.npm,'lib','preserved-old-cli.js'));fs.writeFileSync(old,'module.exports=1\n',{flag:'wx'});
refused(()=>revalidatePublicationSourceTree(replaced.tree),/Observed npm source tree changed/u);
const linked=fixture('hardlink');fs.linkSync(path.join(linked.npm,'lib','cli.js'),path.join(linked.npm,'lib','alias.js'));
refused(()=>observePublicationSourceTree(linked.tools),/single-link/u);
let actual=null;
if(process.argv[2]==='actual') {
  const paths={githubCli:'C:/Users/sorab/AppData/Local/Programs/GitHub CLI/bin/gh.exe',nodeExecutable:'C:/Program Files/nodejs/node.exe',npmCli:'C:/Program Files/nodejs/node_modules/npm/bin/npm-cli.js'};
  const tools=observePublicationTools(paths),tree=observePublicationSourceTree(tools);
  assert.equal(revalidatePublicationSourceTree(tree).source_inventory_integrity_verified,true);checks++;
  actual={root:tree.root,files:tree.files.length,directories:tree.directories.length,bytes:tree.files.reduce((total,row)=>total+row.bytes,0),
    inventory_sha256:tree.inventory_sha256,module_namespace_closed:false,native_custody_verified:false,publication_admitted:false};
  fs.writeFileSync(path.join(root,'actual-source-inventory.json'),JSON.stringify(tree)+'\n',{flag:'wx'});
}
const sourceNames=['scripts/observe-publication-source-tree.mjs','scripts/observe-publication-tools.mjs','tests/workspace-package/publication-source-tree.test.mjs'];
const source=Object.fromEntries(sourceNames.map(name=>[name,createHash('sha256').update(fs.readFileSync(name)).digest('hex')]));
const result={passed:true,checks,actual,source_sha256:source,public_effects_executed:0,publication_admitted:false,
  scope:'Synthetic source mutation/namespace/hardlink/reforged-origin refusals and optional installed npm byte observation. No runtime module guard, native custody or public dispatch.'};
fs.writeFileSync(path.join(root,'result.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({passed:true,checks,actual,original_result:path.join(root,'result.json')}));
