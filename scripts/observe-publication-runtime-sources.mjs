import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { observePublicationSourceTree,revalidatePublicationSourceTree } from './observe-publication-source-tree.mjs';

// Actual local source observations for the fixed native bootstrap. The fixed
// candidate/adoption and action-time authority are separate host obligations.
const issued=new WeakMap();
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const keys=['dev','ino','nlink','size','mtimeNs','ctimeNs'];
const identity=stat=>Object.fromEntries(keys.map(key=>[key,String(stat[key])]));
const order=(a,b)=>a<b?-1:a>b?1:0;
const demand=(value,reason)=>{if(!value)throw new Error(reason);};
const freeze=value=>{if(value&&typeof value==='object'){Object.values(value).forEach(freeze);Object.freeze(value);}return value;};
function physical(file,directory=false) {
  demand(typeof file==='string'&&path.isAbsolute(file)&&!file.startsWith('\\\\')&&!file.includes('\0')&&fs.realpathSync.native(file)===file,'Exact physical local source required.');
  for(let current=file;;current=path.dirname(current)){demand(!fs.lstatSync(current).isSymbolicLink(),'Runtime source reparse refused.');if(path.dirname(current)===current)break;}
  const stat=fs.lstatSync(file,{bigint:true});demand(directory?stat.isDirectory():stat.isFile()&&stat.nlink===1n,'Plain single-link runtime source required.');return stat;
}
function observeFile(file) {
  const named=physical(file),descriptor=fs.openSync(file,'r');
  try {
    const before=fs.fstatSync(descriptor,{bigint:true}),bytes=fs.readFileSync(descriptor),after=fs.fstatSync(descriptor,{bigint:true}),last=physical(file);
    demand(keys.every(key=>named[key]===before[key]&&before[key]===after[key]&&after[key]===last[key]),'Runtime source changed during observation.');
    return {path:file,bytes:bytes.length,sha256:sha(bytes),identity:identity(after)};
  }finally{fs.closeSync(descriptor);}
}
function observeDirectory(directory) {
  const before=physical(directory,true),names=fs.readdirSync(directory).sort(order),after=physical(directory,true);
  demand(keys.every(key=>before[key]===after[key])&&JSON.stringify(names)===JSON.stringify(fs.readdirSync(directory).sort(order)),'Runtime namespace changed during observation.');
  return {path:directory,names,identity:identity(after)};
}
function snapshot(tree,bootstrapFiles,guardFile) {
  revalidatePublicationSourceTree(tree);
  demand(Array.isArray(bootstrapFiles)&&bootstrapFiles.length>0&&new Set(bootstrapFiles).size===bootstrapFiles.length,'Fixed unique bootstrap inventory required.');
  const files=new Map(tree.files.map(row=>[row.path,{path:row.path,bytes:row.bytes,sha256:row.sha256,identity:row.identity}]));
  const dirs=new Map(tree.directories.map(row=>[row.path,row]));
  for(const file of bootstrapFiles){demand(!files.has(file),'Bootstrap duplicates installed source.');files.set(file,observeFile(file));const directory=path.dirname(file);if(!dirs.has(directory))dirs.set(directory,observeDirectory(directory));}
  const manifest={files:[...files.values()].sort((a,b)=>order(a.path,b.path)),directories:[...dirs.values()].sort((a,b)=>order(a.path,b.path)),publication_admitted:false};
  const guard=observeFile(guardFile);
  return {manifest,manifest_sha256:sha(Buffer.from(JSON.stringify(manifest))),guard,
    native_custody_verified:false,publication_admitted:false};
}
export function observePublicationRuntimeSources(tools,bootstrapFiles,guardFile) {
  const tree=observePublicationSourceTree(tools),result=freeze(snapshot(tree,bootstrapFiles,guardFile));
  issued.set(result,{tree,bootstrapFiles:[...bootstrapFiles],guardFile});return result;
}
export function revalidatePublicationRuntimeSources(observation) {
  const original=issued.get(observation);demand(original,'Original process-local runtime source observation required.');
  demand(JSON.stringify(snapshot(original.tree,original.bootstrapFiles,original.guardFile))===JSON.stringify(observation),'Runtime source observation changed.');
  return freeze({runtime_sources_integrity_verified:true,native_custody_verified:false,publication_admitted:false});
}
