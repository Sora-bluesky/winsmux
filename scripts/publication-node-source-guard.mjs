import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isBuiltin,registerHooks } from 'node:module';

// Fixed-image synchronous loading guard. The native owner must hold this
// bootstrap, the manifest and all inventoried sources before Node starts.
// Adopted source is trusted; this is not a sandbox for hostile adopted code,
// eval/vm, replacement hooks, arbitrary worker runtimes or direct FS execution.
const fail=reason=>{throw new Error('Publication source guard: '+reason);};
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const identityKeys=['dev','ino','nlink','size','mtimeNs','ctimeNs'];
const order=(a,b)=>a<b?-1:a>b?1:0;
export function installPublicationSourceGuard(manifestFile,expectedSha256) {
  if(typeof manifestFile!=='string'||!path.isAbsolute(manifestFile)||manifestFile.startsWith('\\\\')||
    typeof expectedSha256!=='string'||!/^[a-f0-9]{64}$/u.test(expectedSha256))fail('exact local manifest and hash required');
  const actualManifest=fs.realpathSync.native(manifestFile);
  if(actualManifest!==path.resolve(manifestFile))fail('manifest alias refused');
  const descriptor=fs.openSync(actualManifest,'r');let manifest;
  try {
    const before=fs.fstatSync(descriptor,{bigint:true}),bytes=fs.readFileSync(descriptor),after=fs.fstatSync(descriptor,{bigint:true});
    if(!before.isFile()||before.nlink!==1n||identityKeys.some(key=>before[key]!==after[key])||digest(bytes)!==expectedSha256)
      fail('manifest bytes or identity differ');
    manifest=JSON.parse(bytes.toString('utf8'));
  }finally{fs.closeSync(descriptor);}
  if(!Array.isArray(manifest.files)||!Array.isArray(manifest.directories)||manifest.publication_admitted!==false)
    fail('closed source inventory required; no authority flag');
  const files=new Map(),directories=new Map();
  const validatePath=file=>{
    if(typeof file!=='string'||!path.isAbsolute(file)||file.startsWith('\\\\')||fs.realpathSync.native(file)!==file)
      fail('source alias, reparse or nonlocal path refused');
    // realpath equality alone does not reveal a same-target junction/symlink.
    for(let cursor=file;;cursor=path.dirname(cursor)) {
      if(fs.lstatSync(cursor).isSymbolicLink())fail('source reparse path refused');
      if(path.dirname(cursor)===cursor)break;
    }
  };
  const validateIdentity=(actual,record)=>{
    if(!record||identityKeys.some(key=>String(actual[key])!==record[key]))fail('source identity differs');
  };
  for(const row of manifest.directories) {
    validatePath(row.path);
    if(directories.has(row.path)||!Array.isArray(row.names)||row.names.some(name=>typeof name!=='string'||path.basename(name)!==name))
      fail('duplicate or malformed source directory');
    directories.set(row.path,row);
  }
  const validateDirectory=row=>{
    validatePath(row.path);const actual=fs.lstatSync(row.path,{bigint:true});
    if(!actual.isDirectory())fail('source directory replaced');validateIdentity(actual,row.identity);
    if(JSON.stringify(fs.readdirSync(row.path).sort(order))!==JSON.stringify(row.names))fail('source namespace changed');
  };
  for(const row of manifest.files) {
    validatePath(row.path);
    if(files.has(row.path)||!directories.has(path.dirname(row.path))||typeof row.sha256!=='string'||!/^[a-f0-9]{64}$/u.test(row.sha256))
      fail('duplicate or malformed source file');
    files.set(row.path,row);
  }
  const inspect=file=>{
    const row=files.get(file);if(!row)fail('uninventoried source refused');
    validatePath(file);
    for(let directory=path.dirname(file);directories.has(directory);directory=path.dirname(directory))validateDirectory(directories.get(directory));
    const descriptor=fs.openSync(file,'r');
    try {
      const before=fs.fstatSync(descriptor,{bigint:true});
      if(!before.isFile()||before.nlink!==1n)fail('linked source refused');validateIdentity(before,row.identity);
      const bytes=fs.readFileSync(descriptor),after=fs.fstatSync(descriptor,{bigint:true});
      validateIdentity(after,row.identity);validateIdentity(fs.lstatSync(file,{bigint:true}),row.identity);
      if(bytes.length!==row.bytes||digest(bytes)!==row.sha256)fail('source bytes differ');
      return bytes;
    }finally{fs.closeSync(descriptor);}
  };
  // Verify the complete snapshot before allowing the first application module.
  for(const row of directories.values())validateDirectory(row);
  for(const row of files.values())inspect(row.path);
  const target=url=>{
    if(typeof url!=='string')fail('exact source URL required');
    if(url.startsWith('node:')){if(!isBuiltin(url))fail('unknown builtin refused');return null;}
    const parsed=new URL(url);
    if(parsed.protocol!=='file:'||parsed.hostname||parsed.search||parsed.hash)fail('nonlocal or aliased URL refused');
    const file=fileURLToPath(parsed);
    if(path.extname(file).toLowerCase()==='.node')fail('unadopted native addon refused');
    inspect(file);return file;
  };
  const hooks=registerHooks({
    resolve(specifier,context,nextResolve) {
      const result=nextResolve(specifier,context);target(result.url);return result;
    },
    load(url,context,nextLoad) {
      const file=target(url);const result=nextLoad(url,context);
      return file===null?result:{...result,source:inspect(file)};
    }
  });
  // No uninstall capability is exported. The return value is an observation,
  // not a publication approval or a substitute for actual native custody.
  return Object.freeze({manifest_sha256:expectedSha256,files:files.size,directories:directories.size,
    synchronous_guard_installed:true,publication_admitted:false});
}

if(process.env.WINSMUX_PUBLICATION_SOURCE_MANIFEST!==undefined||process.env.WINSMUX_PUBLICATION_SOURCE_SHA256!==undefined) {
  if(process.env.NODE_DISABLE_COMPILE_CACHE!=='1')fail('fixed compile cache disable profile required');
  installPublicationSourceGuard(process.env.WINSMUX_PUBLICATION_SOURCE_MANIFEST,process.env.WINSMUX_PUBLICATION_SOURCE_SHA256);
}
