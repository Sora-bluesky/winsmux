import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { randomUUID, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

// Native lifetime fixtures only: no gh/npm execution, credentials, public writes,
// permission JSON or production action-time authority.
const script = fileURLToPath(import.meta.url);
const repo = path.resolve(path.dirname(script), '../..');
const pwsh = process.argv[2] === 'actor' ? null : path.resolve(process.argv[3]);
const hash = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = file => JSON.parse(fs.readFileSync(file));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(condition, reason) {
  const expires = Date.now() + 30000; // Fixture watchdog, no product stop policy.
  while (!condition()) { if (Date.now() > expires) throw new Error(reason); await delay(25); }
}
function lines(stream, receive) {
  let bytes = '';
  stream.setEncoding('utf8'); stream.on('data', part => {
    bytes += part;
    while (bytes.includes('\n')) { const cut = bytes.indexOf('\n'); receive(bytes.slice(0, cut).trim()); bytes = bytes.slice(cut + 1); }
  });
}
if (process.argv[2] === 'actor') {
  const [fixtureRoot, mode, pipe, ownerPid] = process.argv.slice(3);
  let socket, decisionCount=0;
  const done=code=>{
    const file=path.join(fixtureRoot,'authority-actor-result.json');
    const result={actor_pid:process.pid,owner_pid:Number(ownerPid),decisions:decisionCount,exit_code:code};
    const descriptor=fs.openSync(file,'wx');
    try {fs.writeFileSync(descriptor,JSON.stringify(result)+'\n');fs.fsyncSync(descriptor);}finally{fs.closeSync(descriptor);}
    assert.deepEqual(read(file),result);process.exit(code);
  };
  const observedEvents=new Set();
  const receiveEvent=line=>{
    const event=JSON.parse(line);
    if (event.event === 'listening') {
      const bootstrap=read(path.join(fixtureRoot,'authority-bootstrap.json'));
      assert.equal(bootstrap.actor_pid,process.pid);assert.equal(bootstrap.owner_pid,Number(ownerPid));
      assert.equal(bootstrap.node_sha256,hash(process.execPath));assert.equal(bootstrap.script_sha256,hash(script));
      socket=net.createConnection(`\\\\.\\pipe\\${pipe}`);
      socket.on('error', error => { if (!['EPIPE','ECONNRESET'].includes(error.code)) throw error; });
      lines(socket, challenge => {
        const [kind,phase,binding,nonce,...extra]=challenge.split('|');
        assert.equal(kind,'DECIDE'); assert.equal(extra.length,0);
        assert.match(nonce,/^[a-f0-9]{64}$/u); assert.ok(['create','resume'].includes(phase));
        assert.equal(binding,hash(path.join(path.dirname(script),'publication-custody-child.mjs')));
        const actor=read(path.join(fixtureRoot,'authority-actor.json'));
        const actualOwner=read(path.join(fixtureRoot,'authority-owner.json'));
        assert.equal(actor.pid,process.pid); assert.equal(actualOwner.pid,Number(ownerPid));
        assert.ok(fs.existsSync(path.join(fixtureRoot,'authority-flight.json')));
        if (phase==='resume') assert.ok(fs.existsSync(path.join(fixtureRoot,'authority-created.json')));
        decisionCount++;
        // This acknowledgement is confined to a synthetic byte consumer.
        // It is not a production direct-instruction observer.
        socket.write(`PROCEED|${phase}|${binding}|${mode==='wrong-response' ? '0'.repeat(64) : nonce}\n`);
      });
    } else if (event.event === 'bound' && mode==='disconnect-before-create') socket.destroy();
    else if (event.event === 'resumed' && mode==='disconnect-after-resume') {
      done(95);
    }
    else if (event.event === 'resumed' && mode==='disconnect-after-resume-eof') socket.destroy();
  };
  const observeOutput=setInterval(()=>{
    for(const event of ['listening','bound','resumed']) {
      const file=path.join(fixtureRoot,`authority-${event}.json`);
      if(!observedEvents.has(event) && fs.existsSync(file)) {
        observedEvents.add(event); receiveEvent(JSON.stringify(read(file)));
      }
    }
    if(fs.existsSync(path.join(fixtureRoot,'authority-owner-failure.json'))){clearInterval(observeOutput);done(96);}
    if(fs.existsSync(path.join(fixtureRoot,'authority-result.json'))){clearInterval(observeOutput);done(0);}
  },20);
} else {
  const operatorRoot=path.resolve(process.argv[2]);
  assert.ok(fs.statSync(pwsh).isFile());
  const sources=['scripts/IntegratedPublicationCustody.cs','tests/workspace-package/publication-authority.test.mjs',
    'tests/workspace-package/publication-authority-owner-fixture.ps1','tests/workspace-package/publication-authority-recovery-fixture.ps1',
    'tests/workspace-package/publication-custody-child.mjs','scripts/hold-publication-job.ps1','scripts/publication-node-source-guard.mjs'];
  const sourceSha=Object.fromEntries(sources.map(name=>[name,hash(path.join(repo,name))]));
  const cases=[];
  const modes=process.argv[4] && process.argv[4]!=='all' ? [process.argv[4]] : ['normal','disconnect-before-create','wrong-response','disconnect-after-resume'];
  for (const mode of modes) {
    assert.ok(['normal','disconnect-before-create','wrong-response','disconnect-after-resume','disconnect-after-resume-eof','fixed-table-only'].includes(mode));
    const fixture=JSON.parse(execFileSync(process.execPath,[path.join(path.dirname(script),'prepare-publication-custody-fixture.mjs'),operatorRoot],{encoding:'utf8',windowsHide:true}));
    const fixtureRoot=fixture.fixture_root;
    const pipe=randomUUID();
    const guarded=process.argv[5]==='guarded';
    if(guarded) {
      const identity=stat=>Object.fromEntries(['dev','ino','nlink','size','mtimeNs','ctimeNs'].map(key=>[key,String(stat[key])]));
      const directory=path.dirname(script);
      const localSources=[script,path.join(directory,'publication-custody-child.mjs')].sort();
      const manifest={publication_admitted:false,files:localSources.map(file=>({path:file,bytes:fs.statSync(file).size,sha256:hash(file),identity:identity(fs.lstatSync(file,{bigint:true}))})),
        directories:[{path:directory,names:fs.readdirSync(directory).sort((a,b)=>a<b?-1:a>b?1:0),identity:identity(fs.lstatSync(directory,{bigint:true}))}]};
      fs.writeFileSync(path.join(fixtureRoot,'runtime-source-manifest.json'),JSON.stringify(manifest),{flag:'wx'});
    }
    if(mode==='fixed-table-only') {
      const original=read(path.resolve(process.argv[5]));
      assert.equal(original.public_effects_executed,0);assert.equal(original.fixed_operation_table_integrity.operation_table_integrity_verified,true);
      const table=original.fixed_operation_table;
      assert.equal(table.publication_admitted,false);assert.equal(table.entries.length,3);
      const assets=table.entries.flatMap(entry=>entry.assets).sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);
      assert.equal(new Set(assets.map(row=>row.path)).size,14);
      fixture.bundle_root=table.bundle_root;fixture.names=assets.map(row=>row.path);fixture.hashes=assets.map(row=>row.sha256);fixture.candidate_identity=table.candidate_identity;
      fs.writeFileSync(path.join(fixtureRoot,'custody-fixture.json'),JSON.stringify(fixture));
      fs.writeFileSync(path.join(fixtureRoot,'native-operation-table.json'),JSON.stringify(table),{flag:'wx'});
    }
    const nativeOwner=spawn(pwsh,['-NoLogo','-NoProfile','-NonInteractive','-File',path.join(path.dirname(script),'publication-authority-owner-fixture.ps1'),
      '-FixtureRoot',fixtureRoot,'-PipeName',pipe,'-NodeImage',process.execPath,'-NodeHash',hash(process.execPath),'-Mode',mode,...(guarded?['-Guarded']:[])],
      {windowsHide:true,stdio:'ignore'});
    const originalFailure=()=>fs.existsSync(path.join(fixtureRoot,'authority-owner-failure.json'))?fs.readFileSync(path.join(fixtureRoot,'authority-owner-failure.json'),'utf8'):fixtureRoot;
    const actorEnded=new Promise((resolve,reject)=>{nativeOwner.once('error',reject);nativeOwner.once('close',(code,signal)=>resolve({code,signal}));});
    let actorExit=null; actorEnded.then(value=>{actorExit=value;});
    if(mode.startsWith('disconnect-after-resume')) {
      await until(()=>{
        if(actorExit)throw new Error(`Owner ended before native disconnect observation: ${originalFailure()}`);
        return fs.existsSync(path.join(fixtureRoot,'authority-disconnected.json'));
      },
        `Disconnected descendant proof missing; original helper stderr: ${path.join(fixtureRoot,'authority-owner-stderr.txt')}`);
      const disconnected=read(path.join(fixtureRoot,'authority-disconnected.json'));
      assert.ok(disconnected.members>0 && disconnected.write_denied && disconnected.keeper_retained && disconnected.normal_release_refused);
      const originalOwner=read(path.join(fixtureRoot,'authority-owner.json'));
      assert.equal(disconnected.owner_pid,nativeOwner.pid);assert.equal(disconnected.owner_creation_filetime,originalOwner.creation_filetime);
      if(mode==='disconnect-after-resume'){assert.equal(disconnected.actor_exited,true);assert.equal(disconnected.actor_exit_code,95);}
      fs.writeFileSync(path.join(fixtureRoot,'finish-descendant'),'fixture normal exit',{flag:'wx'});
    }
    const ended=await actorEnded;
    assert.equal(ended.signal,null); assert.equal(ended.code,0,originalFailure());
    await until(()=>fs.existsSync(path.join(fixtureRoot,'authority-actor-result.json')),'Original actor result missing');
    const event=read(path.join(fixtureRoot,'authority-actor-result.json'));
    assert.equal(event.owner_pid,nativeOwner.pid);assert.equal(event.exit_code,mode==='disconnect-after-resume'?95:0);
    await until(()=>fs.existsSync(path.join(fixtureRoot,'authority-result.json')),'Native owner original result missing');
    const native=read(path.join(fixtureRoot,'authority-result.json'));
    assert.equal(native.passed,true); assert.equal(native.publication_admitted,false);
    assert.equal(native.actor.pid,event.actor_pid);
    assert.equal(native.native_create_calls,['normal','disconnect-after-resume','disconnect-after-resume-eof'].includes(mode)?1:0);
    assert.equal(event.decisions,['normal','disconnect-after-resume','disconnect-after-resume-eof'].includes(mode)?2:mode==='wrong-response'?1:0);
    let recovery=null;
    if(!['normal','fixed-table-only'].includes(mode)) {
      const owner=read(path.join(fixtureRoot,'authority-owner.json'));
      // The recovery fixture performs native held-identity/Job checks. A brief
      // wait only waits for the helper's normal exit, it never synthesizes exit.
      await delay(300);
      execFileSync(pwsh,['-NoLogo','-NoProfile','-File',path.join(path.dirname(script),'publication-authority-recovery-fixture.ps1'),'-FixtureRoot',fixtureRoot],{encoding:'utf8',windowsHide:true,timeout:20000});
      recovery=read(path.join(fixtureRoot,'authority-recovery-result.json'));
      assert.ok(recovery.passed && recovery.actor_gone && recovery.owner_gone && recovery.roots_gone);
      assert.equal(recovery.job_members,0); assert.equal(recovery.keeper_exit_code,0); assert.equal(recovery.query_handoff_job_name,owner.job_name);
    } else assert.equal(native.normal_release,true);
    cases.push({mode,fixture_root:fixtureRoot,actor_exit_code:event.exit_code,owner_exit_code:ended.code,native_result:native,recovery});
  }
  const after=Object.fromEntries(sources.map(name=>[name,hash(path.join(repo,name))])); assert.deepEqual(after,sourceSha);
  const result={passed:true,cases,source_sha256:sourceSha,source_after_sha256:after,public_effects_executed:0,
    publication_admitted:false,scope:'Actual native-created actor HANDLE/pipe identity, held bootstrap persistence, independent owner lifetime after EOF or actor exit, child descendants and retained QUERY recovery. Synthetic consumer only; fixed public-operation table, fake-peer cases, unresumed-root disconnect, direct authority and four-entry cutover remain unverified.'};
  const output=path.join(repo,'.evidence/workspace-package',`publication-authority-${randomUUID()}`);
  fs.mkdirSync(output); fs.writeFileSync(path.join(output,'result.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({passed:true,modes:cases.map(row=>row.mode),original_result:path.join(output,'result.json'),public_effects_executed:0}));
}
