import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { physicalPath } from './distribution-prelaunch.mjs';
import { revalidatePublicationTools } from './observe-publication-tools.mjs';

// Actual npm package-byte inventory. This does not close module resolution,
// hold native handles, grant authority, execute npm, or inspect user config.
const issued=new WeakMap();
const demand=(condition,reason)=>{if(!condition)throw new Error(reason);};
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const identityKeys=['dev','ino','nlink','size','mtimeNs','ctimeNs'];
const identity=stat=>Object.fromEntries(identityKeys.map(key=>[key,String(stat[key])]));
const freeze=value=>{if(value&&typeof value==='object'){Object.values(value).forEach(freeze);Object.freeze(value);}return value;};
const order=(a,b)=>a<b?-1:a>b?1:0;
function inventory(tools) {
  revalidatePublicationTools(tools);
  const root=path.resolve(path.dirname(tools.npmCli.path),'..');
  demand(physicalPath(root)===root && path.basename(root)==='npm','Exact physical installed npm package root required.');
  const files=[],directories=[];
  const visit=directory=>{
    demand(physicalPath(directory)===directory,'Linked npm source directory refused.');
    const before=fs.lstatSync(directory,{bigint:true});
    demand(before.isDirectory()&&!before.isSymbolicLink(),'Plain npm source directory required.');
    const names=fs.readdirSync(directory).sort(order);
    directories.push({path:directory,identity:identity(before),names});
    for(const name of names) {
      const target=path.join(directory,name), stat=fs.lstatSync(target,{bigint:true});
      demand(!stat.isSymbolicLink() && physicalPath(target)===target,'Linked npm source refused.');
      if(stat.isDirectory())visit(target);
      else {
        demand(stat.isFile()&&stat.nlink===1n,'Plain single-link npm source file required.');
        const descriptor=fs.openSync(target,'r');
        try {
          const opened=fs.fstatSync(descriptor,{bigint:true}), bytes=fs.readFileSync(descriptor);
          const after=fs.fstatSync(descriptor,{bigint:true}), named=fs.lstatSync(target,{bigint:true});
          demand(identityKeys.every(key=>stat[key]===opened[key]&&opened[key]===after[key]&&after[key]===named[key]),'npm source identity changed during observation.');
          files.push({path:target,relative_path:path.relative(root,target).split(path.sep).join('/'),bytes:bytes.length,sha256:sha(bytes),identity:identity(after)});
        } finally {fs.closeSync(descriptor);}
      }
    }
    const after=fs.lstatSync(directory,{bigint:true});
    demand(identityKeys.every(key=>before[key]===after[key])&&JSON.stringify(names)===JSON.stringify(fs.readdirSync(directory).sort(order)),
      'npm source directory changed during observation.');
  };
  visit(root);
  files.sort((a,b)=>order(a.relative_path,b.relative_path));
  directories.sort((a,b)=>order(a.path,b.path));
  const cli=files.find(row=>row.path===tools.npmCli.path);
  demand(cli?.sha256===tools.npmCli.sha256&&JSON.stringify(cli.identity)===JSON.stringify(tools.npmCli.identity),'npm entry differs from actual tool observation.');
  const fixed={root,files,directories};
  return {...fixed,inventory_sha256:sha(Buffer.from(JSON.stringify(fixed))),
    module_namespace_closed:false,native_custody_verified:false,publication_admitted:false};
}
export function observePublicationSourceTree(tools) {
  const result=freeze(inventory(tools));issued.set(result,tools);return result;
}
export function revalidatePublicationSourceTree(tree) {
  const tools=issued.get(tree);demand(tools,'Original process-local npm source inventory required.');
  demand(JSON.stringify(tree)===JSON.stringify(inventory(tools)),'Observed npm source tree changed.');
  return Object.freeze({source_inventory_integrity_verified:true,module_namespace_closed:false,native_custody_verified:false,publication_admitted:false});
}
