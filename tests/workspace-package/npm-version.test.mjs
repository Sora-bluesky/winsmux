import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const evidence = path.join(repo, ".evidence/workspace-package", `npm-${randomUUID()}`);
fs.mkdirSync(evidence, { recursive: true });
const results = [];
function write(root, relative, bytes) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
}
function fixture(name, version = "0.38.0") {
  const root = path.join(evidence, name, "repo");
  write(root, "VERSION", `${version}\n`);
  write(root, "Cargo.toml", '[workspace]\nmembers = ["core", "core/crates/winsmux-workspace-mcp", "winsmux-app/src-tauri"]\nresolver = "2"\n');
  let lock = "version = 4\n";
  for (const [name, relative] of [["winsmux", "core"], ["winsmux-app", "winsmux-app/src-tauri"], ["winsmux-workspace-mcp", "core/crates/winsmux-workspace-mcp"]]) {
    write(root, `${relative}/Cargo.toml`, `[package]\nname = "${name}"\nversion = "${version}"\nedition = "2021"\n`);
    write(root, `${relative}/src/main.rs`, "fn main() {}\n");
    lock += `\n[[package]]\nname = "${name}"\nversion = "${version}"\n`;
  }
  write(root, "Cargo.lock", lock);
  write(root, "install.ps1", `$VERSION = "${version}"\n# native fallback\n`);
  write(root, "LICENSE", "public license fixture\n");
  write(root, "winsmux-app/package.json", JSON.stringify({version}));
  write(root, "winsmux-app/package-lock.json", JSON.stringify({version, packages: { "": {version} }}));
  write(root, "winsmux-app/src-tauri/tauri.conf.json", JSON.stringify({version}));
  write(root, "packages/winsmux/package.json", JSON.stringify({name:"winsmux",version:"0.0.0-development",private:false}));
  write(root, "packages/winsmux/index.mjs", "// public package entry\n");
  write(root, "packages/winsmux/nested/README.md", "source canary\n");
  for (const file of ["scripts/stage-npm-release.mjs", "scripts/assert-distribution-version.ps1", "scripts/distribution-prelaunch.mjs"]) {
    write(root, file, fs.readFileSync(path.join(repo, file)));
  }
  write(root, "child.ps1", fs.readFileSync(path.join(repo,"tests/workspace-package/fixture-child.ps1")));
  write(root, "winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1", fs.readFileSync(path.join(repo,"winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1")));
  write(root, "winsmux-app/src-tauri/scripts/prepare-companion-cli.mjs", fs.readFileSync(path.join(repo,"winsmux-app/src-tauri/scripts/prepare-companion-cli.mjs")));
  return root;
}
function snapshot(root) {
  const files = new Map();
  function walk(dir) {
    for (const item of fs.readdirSync(dir)) {
      const file = path.join(dir, item); const stat = fs.lstatSync(file);
      if (stat.isSymbolicLink()) { files.set(path.relative(root,file), `link:${fs.readlinkSync(file)}`); }
      else if (stat.isDirectory()) { walk(file); }
      else { files.set(path.relative(root,file), fs.readFileSync(file).toString("hex")); }
    }
  }
  walk(root); return files;
}
function unchanged(root, before) {
  for (const [file, bytes] of before) {
    const full = path.join(root,file);
    const actual = fs.lstatSync(full).isSymbolicLink() ? `link:${fs.readlinkSync(full)}` : fs.readFileSync(full).toString("hex");
    assert.equal(actual, bytes, `input changed: ${file}`);
  }
}
const preload = path.join(evidence,"faults.mjs");
fs.writeFileSync(preload, `import fs from 'node:fs';
const rename=fs.renameSync, write=fs.writeFileSync, read=fs.readdirSync, unlink=fs.unlinkSync, flush=fs.fsyncSync, open=fs.openSync;
let published=false,restored=false,readFailed=false;
fs.renameSync=function(a,b){ const mode=process.env.NPM_FIXTURE_FAULT;
 const canonical=process.env.NPM_FIXTURE_CANONICAL;
 if(mode==='park-old' && String(a)===canonical && !published) throw new Error('injected old parking failure');
 if(mode==='readback-park' && String(a)===canonical && published) throw new Error('injected new parking failure');
 if ((mode==='publish'||mode==='restore') && String(a).includes('.stage.')) throw new Error('injected publish failure');
 if (['restore','readback-restore'].includes(mode) && String(a).includes('.backup.')) throw new Error('injected restoration failure');
 const result=rename.apply(this,arguments);
 if(String(b)===canonical && String(a).includes('.stage.'))published=true;
 if(String(b)===canonical && String(a).includes('.backup.'))restored=true;
 return result; };
fs.writeFileSync=function(a,b){const mode=process.env.NPM_FIXTURE_FAULT;
 if(mode==='copy' && String(a).includes('.stage.')) throw new Error('injected copy failure');
 if(mode==='marker-write' && typeof a==='number')throw new Error('injected marker write failure');
 return write.apply(this,arguments); };
fs.openSync=function(a){if(process.env.NPM_FIXTURE_FAULT==='marker-create' && String(a).endsWith('.recovery.pending'))throw new Error('injected marker create failure');return open.apply(this,arguments);};
fs.fsyncSync=function(){if(process.env.NPM_FIXTURE_FAULT==='marker-flush')throw new Error('injected marker flush failure');return flush.apply(this,arguments);};
fs.unlinkSync=function(a){if(process.env.NPM_FIXTURE_FAULT==='marker-remove' && String(a).endsWith('.recovery.pending'))throw new Error('injected marker removal failure');return unlink.apply(this,arguments);};
fs.readdirSync=function(a){const mode=process.env.NPM_FIXTURE_FAULT;
 if(String(a)===process.env.NPM_FIXTURE_CANONICAL && published && !readFailed && mode.startsWith('readback')){readFailed=true;throw new Error('injected published readback failure');}
 if(String(a)===process.env.NPM_FIXTURE_CANONICAL && restored && mode==='readback-verify')throw new Error('injected original readback failure');
 return read.apply(this,arguments);};
`);
function run(root, args, fault = "") {
  const result = spawnSync(process.execPath, [...(fault ? ["--import", pathToFileURL(preload).href] : []), "scripts/stage-npm-release.mjs", ...args],
    {cwd:root, encoding:"utf8", windowsHide:true, env:{...process.env,CARGO_NET_OFFLINE:"true",NPM_FIXTURE_FAULT:fault,NPM_FIXTURE_CANONICAL:path.resolve(root,args[args.indexOf('--out')+1])}});
  write(evidence, `invocation-${randomUUID()}.log`, `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
  return result;
}
function record(name, output) {
  results.push({name,passed:true,exit:output.status});
  write(evidence, `${name}.log`, `${output.stdout ?? ""}\n${output.stderr ?? ""}`);
  console.log(`PASS ${name}`);
}
function companion(root) {
  const result=spawnSync("pwsh",["-NoLogo","-NoProfile","-File",path.join(root,"child.ps1")],
    {cwd:root,encoding:"utf8",windowsHide:true,env:{...process.env,CARGO_NET_OFFLINE:"true"}});
  write(evidence,`companion-${randomUUID()}.log`,`${result.stdout ?? ""}\n${result.stderr ?? ""}`);
  return result;
}
function gateOnly(root) {
  return spawnSync("pwsh",["-NoLogo","-NoProfile","-File",path.join(root,"scripts/assert-distribution-version.ps1"),"-RepoRoot",root],
    {cwd:root,encoding:"utf8",windowsHide:true,env:{...process.env,CARGO_NET_OFFLINE:"true"}});
}
function assertRejectedEntrances(root, out, expectedDiagnostic) {
  const before=snapshot(root), canonical=snapshot(out);
  const direct=gateOnly(root), build=companion(root), npm=run(root,["--version","0.38.0","--out",out]);
  for(const result of [direct,build,npm]) {
    assert.notEqual(result.status,0);
    if(expectedDiagnostic) assert.match(result.stderr,expectedDiagnostic);
  }
  assert.deepEqual(snapshot(root),before);assert.deepEqual(snapshot(out),canonical);
  for(const relative of ['cargo.jsonl','bundle-started','winsmux-app/src-tauri/binaries.prepare.lock']) assert(!fs.existsSync(path.join(root,relative)));
  assert(!fs.existsSync(`${out}.prepare.lock`));
  return {...npm,entrance_exits:[direct.status,build.status,npm.status]};
}
try {
  for (const [name, version, tag, packageVersion] of [
    ["stable","0.38.0","v0.38.0","0.38.0"],
    ["hotfix","0.38.0","v0.38.0.2","0.38.0-pkgfix.2"],
    ["prerelease","0.38.0-rc.1","v0.38.0-rc.1","0.38.0-rc.1"],
    ["prerelease-hotfix","0.38.0-rc.1","v0.38.0.2-rc.1","0.38.0-pkgfix.2.rc.1"],
  ]) {
    const root=fixture(name,version), before=snapshot(root), out=path.join(root,"output/npm-release/winsmux");
    const result=run(root,["--release-tag",tag,"--out",out]); assert.equal(result.status,0,result.stderr);
    const pkg=JSON.parse(fs.readFileSync(path.join(out,"package.json"))); assert.equal(pkg.version,packageVersion);assert.equal(pkg.winsmuxReleaseTag,tag);
    assert.match(fs.readFileSync(path.join(out,"install.ps1"),"utf8"),new RegExp(`\\$VERSION\\s*=\\s*"${version.replaceAll(".","\\.")}"`));
    assert.deepEqual(fs.readFileSync(path.join(out,"LICENSE")),fs.readFileSync(path.join(root,"LICENSE")));
    unchanged(root,before);record(name,result);
  }
  const invalid = [
    ["wrong-native",["--version","0.37.0"]], ["wrong-tag-native",["--release-tag","v0.37.0.2"]],
    ["reserved-version",["--version","0.38.0-pkgfix.1"]], ["reserved-tag",["--release-tag","v0.38.0-pkgfix.1"]],
    ["leading-zero",["--release-tag","v00.38.0"]], ["revision-leading-zero",["--release-tag","v0.38.0.01"]],
    ["prerelease-leading-zero",["--release-tag","v0.38.0-01"]], ["duplicate-option",["--version","0.38.0","--version","0.38.0"]],
    ["both-options",["--version","0.38.0","--release-tag","v0.38.0"]], ["unknown-option",["--other","0.38.0"]],
  ];
  for (const [name,args] of invalid) {
    const root=fixture(name);write(root,"output/winsmux/prior.txt","old");const before=snapshot(root);
    const result=run(root,[...args,"--out","output/winsmux"]);assert.notEqual(result.status,0);unchanged(root,before);
    assert(!fs.existsSync(path.join(root,"output/winsmux.prepare.lock")));record(name,result);
  }
  for (const [name,relative] of [["source-equal","packages/winsmux"],["source-ancestor","packages"],
    ["source-descendant","packages/winsmux/new/output"],["repo-equal","."],["repo-ancestor",".."],
    ["version-leaf","VERSION"],["installer-leaf","install.ps1"],["license-leaf","LICENSE"],
    ["rust-source","core/new/output"],["gui-source","winsmux-app/src-tauri/output"],["dot-alias","packages/winsmux/../winsmux"],
    ["case-alias","PACKAGES/WINSMUX"]]) {
    const root=fixture(name),before=snapshot(root),result=run(root,["--version","0.38.0","--out",relative]);
    assert.notEqual(result.status,0);assert.match(result.stderr,/overlap/);assert.deepEqual(snapshot(root),before);record(name,result);
  }
  for (const name of ["output-junction","source-junction","source-tree-junction"]) {
    const root=fixture(name);const external=path.join(evidence,name,"external");fs.mkdirSync(external);write(external,"canary","untouched");
    let out="output/winsmux";
    if(name==="output-junction") {fs.symlinkSync(external,path.join(root,"alias"),"junction");out="alias/winsmux";}
    if(name==="source-junction") {fs.renameSync(path.join(root,"packages/winsmux"),path.join(root,"source-retained"));fs.symlinkSync(path.join(root,"source-retained"),path.join(root,"packages/winsmux"),"junction");}
    if(name==="source-tree-junction") {fs.symlinkSync(external,path.join(root,"packages/winsmux/linked"),"junction");}
    const before=snapshot(root), result=run(root,["--version","0.38.0","--out",out]);assert.notEqual(result.status,0);assert.match(result.stderr,/Linked/);
    assert.deepEqual(snapshot(root),before);assert.equal(fs.readFileSync(path.join(external,"canary"),"utf8"),"untouched");record(name,result);
  }
  for (const name of ["copy-failure","publish-failure","restore-failure","initial-publish-failure","held-lock","external-output"]) {
    const root=fixture(name), out=path.join(evidence,name,"owned-output"), prior=name!=="initial-publish-failure";
    if(prior)write(out,"prior.txt","old generation");
    let held;if(name==="held-lock")held=fs.openSync(`${out}.prepare.lock`,"wx");
    const before=snapshot(root);const fault=name==="copy-failure"?"copy":name==="restore-failure"?"restore":name.includes("publish")?"publish":"";
    const result=run(root,["--version","0.38.0","--out",out],fault);unchanged(root,before);
    if(name==="external-output") {assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(fs.readFileSync(path.join(out,"package.json"))).version,"0.38.0");}
    else {
      assert.notEqual(result.status,0);
      if (fault) { assert.match(result.stderr,/injected|recovery required/); }
      if(name==="restore-failure") {
        assert(!fs.existsSync(out));const backups=fs.readdirSync(path.dirname(out)).filter(n=>n.startsWith("owned-output.backup."));assert.equal(backups.length,1);
        assert.equal(fs.readFileSync(path.join(path.dirname(out),backups[0],"prior.txt"),"utf8"),"old generation");
        const retry=run(root,["--version","0.38.0","--out",out]);assert.notEqual(retry.status,0);assert.match(retry.stderr,/recovery required/);assert(!fs.existsSync(out));
        for(const alias of [path.join(path.dirname(out),"OWNED-OUTPUT"),path.join(path.dirname(out),"unused/../owned-output")]) {
          const retry=run(root,["--version","0.38.0","--out",alias]);assert.notEqual(retry.status,0);assert.match(retry.stderr,/recovery required/);assert(!fs.existsSync(out));
          assert.equal(fs.readFileSync(path.join(path.dirname(out),backups[0],"prior.txt"),"utf8"),"old generation");
        }
      } else if(prior) {assert.deepEqual([...snapshot(out)],[['prior.txt',Buffer.from('old generation').toString('hex')]]);}
      else {assert(!fs.existsSync(out));}
    }
    if(held!==undefined) {fs.closeSync(held);fs.unlinkSync(`${out}.prepare.lock`);const retry=run(root,["--version","0.38.0","--out",out]);assert.equal(retry.status,0,retry.stderr);}
    if(name==="initial-publish-failure") {const retry=run(root,["--version","0.38.0","--out",out]);assert.equal(retry.status,0,retry.stderr);}
    record(name,result);
  }
  const root=fixture("version-gate-failure");write(root,"winsmux-app/package.json",'{"version":"0.37.0"}');write(root,"output/winsmux/prior.txt","old");
  const before=snapshot(root),result=run(root,["--version","0.38.0","--out","output/winsmux"]);assert.notEqual(result.status,0);assert.match(result.stderr,/version gate failed/);assert.deepEqual(snapshot(root),before);record("version-gate-failure",result);

  const leafLinks=['winsmux-app/src-tauri/tauri.conf.json','winsmux-app/package.json','winsmux-app/package-lock.json',
    'core/Cargo.toml','core/crates/winsmux-workspace-mcp/Cargo.toml','winsmux-app/src-tauri/Cargo.toml','install.ps1',
    'core/src/main.rs','VERSION','Cargo.toml','Cargo.lock'];
  for(const [index,relative] of leafLinks.entries()) {
    const name=`shared-leaf-link-${index}`, root=fixture(name), out=path.join(evidence,name,'owned-output');
    fs.mkdirSync(out);write(out,'prior.txt','retained output');
    const original=path.join(root,relative), target=path.join(out,path.basename(relative));fs.renameSync(original,target);fs.symlinkSync(target,original,'file');
    const result=assertRejectedEntrances(root,out,/Linked distribution source/);record(name,result);
  }
  for(const [index,relative] of ['core/src','core/crates/winsmux-workspace-mcp/src','winsmux-app/src-tauri/src'].entries()) {
    const name=`shared-tree-link-${index}`,root=fixture(name),out=path.join(evidence,name,'owned-output');
    fs.mkdirSync(out);write(out,'prior.txt','retained output');const original=path.join(root,relative),target=path.join(out,'retained-tree');
    fs.renameSync(original,target);fs.symlinkSync(target,original,'junction');const result=assertRejectedEntrances(root,out,/Linked distribution source/);record(name,result);
  }
  const badTypes=[['true',true],['false',false],['empty-array',[]],['matching-array',['0.38.0']],['mixed-array',['0.38.0','other']],
    ['number',38],['null',null],['object',{}],['missing',undefined]];
  const positions=[['frontend','winsmux-app/package.json',[]],['tauri','winsmux-app/src-tauri/tauri.conf.json',[]],
    ['lock-root','winsmux-app/package-lock.json',[]],['lock-package','winsmux-app/package-lock.json',['packages','']]];
  for(const [position,relative,keys] of positions) for(const [type,value] of badTypes) {
    const name=`typed-${position}-${type}`,root=fixture(name),out=path.join(evidence,name,'owned-output');write(out,'prior.txt','retained output');
    const object=JSON.parse(fs.readFileSync(path.join(root,relative)));let parent=object;for(const key of keys)parent=parent[key];
    if(value===undefined)delete parent.version;else parent.version=value;write(root,relative,JSON.stringify(object));
    const result=assertRejectedEntrances(root,out);record(name,result);
  }
  for(const [name,relative,object] of [
    ['frontend-parent','winsmux-app/package.json',[]],['tauri-parent','winsmux-app/src-tauri/tauri.conf.json',true],
    ['lock-parent','winsmux-app/package-lock.json',null],['packages-parent','winsmux-app/package-lock.json',{version:'0.38.0',packages:[]}],
    ['empty-package-parent','winsmux-app/package-lock.json',{version:'0.38.0',packages:{'':true}}],
  ]) {
    const root=fixture(name),out=path.join(evidence,name,'owned-output');write(out,'prior.txt','retained output');write(root,relative,JSON.stringify(object));
    const result=assertRejectedEntrances(root,out);record(name,result);
  }
  for(const prior of [false,true]) for(const fault of ['marker-create','marker-write','marker-flush','park-old','publish','readback','readback-park','readback-restore','readback-verify','marker-remove']) {
    if(!prior && ['park-old','readback-restore','readback-verify'].includes(fault))continue;
    const name='transaction-'+fault+'-'+prior,root=fixture(name),out=path.join(evidence,name,'owned-output');
    if(prior)write(out,'prior.txt','original-generation');
    const before=snapshot(root),result=run(root,['--version','0.38.0','--out',out],fault);
    assert.notEqual(result.status,0,result.stderr);unchanged(root,before);assert(!fs.existsSync(out+'.prepare.lock'));
    const blocked=['marker-write','marker-flush','readback-park','readback-restore','readback-verify','marker-remove'].includes(fault);
    assert.equal(fs.existsSync(out+'.recovery.pending'),blocked);
    const backups=fs.readdirSync(path.dirname(out)).filter(n=>n.startsWith('owned-output.backup.'));
    if(prior && blocked && !['marker-write','marker-flush'].includes(fault)) {
      if(fault==='readback-verify')assert.equal(fs.readFileSync(path.join(out,'prior.txt'),'utf8'),'original-generation');
      else {assert.equal(backups.length,1);assert.equal(fs.readFileSync(path.join(path.dirname(out),backups[0],'prior.txt'),'utf8'),'original-generation');}
    } else if(prior)assert.equal(fs.readFileSync(path.join(out,'prior.txt'),'utf8'),'original-generation');
    else if(!blocked)assert(!fs.existsSync(out));
    const retained=fs.existsSync(out)?snapshot(out):null;
    for(const retryOut of [out,path.join(path.dirname(out),'OWNED-OUTPUT'),path.join(path.dirname(out),'unused/../owned-output')]) {
      const retry=run(root,['--version','0.38.0','--out',retryOut]);
      if(blocked) {assert.notEqual(retry.status,0);assert.match(retry.stderr,/recovery required/);assert.deepEqual(fs.existsSync(out)?snapshot(out):null,retained);}
      else assert.equal(retry.status,0,retry.stderr);
    }
    record(name,result);
  }
  for(const kind of ['empty','invalid','directory','link']) {
    const name='pending-'+kind,root=fixture(name),out=path.join(evidence,name,'owned-output');write(out,'prior.txt','original');
    const marker=out+'.recovery.pending';
    if(kind==='directory')fs.mkdirSync(marker);
    else if(kind==='link')fs.symlinkSync(path.join(root,'VERSION'),marker,'file');
    else fs.writeFileSync(marker,kind==='empty'?'':'invalid bytes');
    const canonical=snapshot(out),result=run(root,['--version','0.38.0','--out',out]);
    assert.notEqual(result.status,0);assert.match(result.stderr,kind==='link'?/Linked/:/recovery required/);assert.deepEqual(snapshot(out),canonical);record(name,result);
  }
  write(evidence,"result.json",JSON.stringify({passed:true,results},null,2));console.log(`Result: ${evidence}/result.json`);
} catch(error) {
  write(evidence,"result.json",JSON.stringify({passed:false,results,failure:error.stack},null,2));throw error;
}
