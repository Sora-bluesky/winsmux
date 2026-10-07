import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const app=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const option=(name,fallback)=>{const i=process.argv.indexOf(name);return i<0?fallback:resolve(process.argv[i+1]);};
const dependency=option('--dependency-root',app);
const require=createRequire(resolve(dependency,'package.json'));
const {build}=require('esbuild'),{chromium}=require('playwright');
const evidence=option('--evidence-dir',resolve(app,'../.evidence/rebuild/v0.38.0/TASK-872/ime-focus',new Date().toISOString().replaceAll(/[:.]/g,'-')));
mkdirSync(evidence,{recursive:true});
const bundle=await build({stdin:{contents:"export * from './src/workspace-ui/terminal-input';export * from './src/workspace-ui/terminal-input-codec';export * from './src/workspace-ui/focus';export * from './src/workspace-ui/project-pane-controller';export * from './src/workspace-ui/project-pane';",resolveDir:app},bundle:true,write:false,format:'esm',platform:'browser',target:'es2022',metafile:true});
const sdkPath=resolve(dependency,'node_modules/xterm/lib/xterm.js'),sdk=readFileSync(sdkPath),css=readFileSync(resolve(dependency,'node_modules/xterm/css/xterm.css'),'utf8');
const inputPaths=[...Object.keys(bundle.metafile.inputs).filter(p=>p!=='<stdin>').map(p=>resolve(p)),sdkPath,resolve(dependency,'node_modules/xterm/package.json'),fileURLToPath(import.meta.url)];
const identity=()=>inputPaths.map(path=>{const bytes=readFileSync(path);return{path,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};});
const before=identity(),started=new Date().toISOString();
const checks=[];let failure=null,browser;
try {
 browser=await chromium.launch({headless:true,channel:process.env.WINSMUX_TEST_BROWSER_CHANNEL||'msedge'});
 const page=await browser.newPage({viewport:{width:1200,height:800}});
 const fixtureUrl='https://tauri.localhost/';
 await page.route('**/*',route=>route.request().url()===fixtureUrl
  ? route.fulfill({contentType:'text/html; charset=utf-8',body:'<!doctype html><html lang="ja"><main id="root"></main><div id="term" style="width:850px;height:420px"></div><button id="other">別の操作</button></html>'})
  : route.abort());
 await page.goto(fixtureUrl);
 if(!await page.evaluate(()=>isSecureContext&&typeof crypto.randomUUID==='function'))throw Error('local fixture requires secure-context UUID support');
 await page.addStyleTag({content:css});
 await page.addScriptTag({content:sdk.toString('utf8')});
 await page.evaluate(async code=>{globalThis.product=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));},bundle.outputFiles[0].text);
 const integrationChecks=await page.evaluate(async()=>{
  const {createTerminalInputOwner,createProjectPaneController}=globalThis.product;
  const checks=[],check=(name,passed,detail)=>checks.push({name,passed,detail});
  const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
  const target={instanceId:uid(1),generation:uid(2),projectId:uid(3),paneId:uid(4),runId:uid(5),producerId:uid(6)};
  const ownerKey={instanceId:target.instanceId,ownerGeneration:'1'};
  const projects={projects:[{project_id:target.projectId,display_name:'synthetic',path:'C:/synthetic',root_state:'verified'}],selected_project_id:target.projectId};
  const panes={project_id:target.projectId,panes:[{pane_id:target.paneId,project_id:target.projectId,current_run_id:target.runId,display_name:'synthetic',path:'C:/synthetic',observation:{run_id:target.runId,pane_id:target.paneId,process:'running',work:'unknown',evidence:'unavailable',observed_at:'2026-09-27T06:00:00Z',current:true,exit_code:null}}],root:{kind:'leaf',pane_id:target.paneId},selected_pane_id:target.paneId};
  let snapshot={instanceId:target.instanceId,generation:target.generation,topologyRevision:7,availability:'available',busy:false,projects,panes};
  const root=document.querySelector('#root');
  let seq=100,inputSeq=0,mode='defer',resolveInput;
  const ok=(q,data)=>({schema_version:1,instance_id:q.instance_id,operation_id:q.operation_id,accepted:true,topology_revision:7,event_seq:0,result:{operation:q.operation,data},error:null});
  const inputOk=q=>ok(q,{input_seq:++inputSeq,pane_id:q.params.pane_id,run_id:q.params.run_id,written_bytes:new TextEncoder().encode(q.params.text).length});
  const guard={listen:async()=>()=>{},invoke:async()=>({lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null})};
  const owner=createTerminalInputOwner(root,guard,()=>uid(++seq));await owner.initialize();
  const connection={ownerKey,snapshot:()=>snapshot,maxBytes:()=>1048576,exchange:async q=>mode==='defer'?new Promise(r=>{resolveInput=()=>r(inputOk(q));}):inputOk(q),recover:async(origin,q)=>{if(origin.ownerGeneration!=='1')throw Error('owner_mismatch');return ok(q,{operation:{operation_id:q.params.operation_id,phase:'completed',outcome:'succeeded',error_code:null}});}};
  owner.connect(connection);await owner.recoverGuard();
  const producer=owner.produce(target),panel=root.querySelector('section');
  producer.pending(8,true);
  check('ordinary composition keeps root confirmation hidden',panel.hidden,{visible:!panel.hidden});
  producer.pending(0,false);producer.offer('a');producer.offer('b');
  await owner.recoverGuard();
  check('ordinary sending and queued input keep confirmation hidden',panel.hidden,{states:owner.inspect().records.map(r=>r.state)});
  // Retiring makes the second immutable request explicitly held; no bytes are resent.
  producer.retire();resolveInput();for(let n=0;n<24;n++)await Promise.resolve();
  const discard=[...panel.querySelectorAll('button')].find(b=>b.textContent==='この対象の未送信入力を破棄');
  discard.focus();owner.refresh();
  check('refresh retains actionable control and keyboard focus',discard.isConnected&&document.activeElement===discard,{connected:discard.isConnected,focusRetained:document.activeElement===discard});
  const current=[...panel.querySelectorAll('button')].find(b=>b.textContent==='この対象の未送信入力を破棄');current.click();owner.dispose();root.replaceChildren();
     // One immutable ledger survives guard-only recovery; no host operation resumes.
   for (const retained of [false,true]) {
    const recoveryRoot=document.createElement('main');document.body.append(recoveryRoot);
    let guardValue={lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null},guardFailure=false,holdGuard=false,resolveGuard;
    const guardCalls=[],writes=[];
    const recoveryGuard={listen:async()=>()=>{},invoke:async(command,args)=>{
     const request=JSON.parse(args.requestJson);guardCalls.push({command,request});
     if(command==='workspace_input_guard_reply'){
      guardValue={lease:'1',revision:String(BigInt(guardValue.revision)+1n),fence:{nonce:request.nonce,state:request.safe?'approved':'released'},resume_allowed:!request.safe,admission_error:request.safe?'shutdown_in_progress':null};
      return structuredClone(guardValue);
     }
     if(guardFailure)throw Error('synthetic guard failure');
     const value=structuredClone(guardValue);
     if(holdGuard){holdGuard=false;return new Promise(resolve=>{resolveGuard=()=>resolve(value);});}
     return value;
    }};
    const recoveryOwner=createTerminalInputOwner(recoveryRoot,recoveryGuard,()=>uid(++seq));await recoveryOwner.initialize();
    const recoveryConnection={...connection,exchange:async q=>{writes.push(q);return inputOk(q);}};
    recoveryOwner.connect(recoveryConnection);await recoveryOwner.recoverGuard();
    let retainedProducer;
    if(retained){
     retainedProducer=recoveryOwner.produce({...target,producerId:uid(++seq)});
     const release=recoveryOwner.admitControl();check('recovery reserves synthetic control for held input',!!release);
     check('recovery stores original Japanese input',retainedProducer.offer('保持する入力'));
     release();
    }
    const original=JSON.stringify(recoveryOwner.inspect().records),originalBytes=recoveryOwner.inspect().usedBytes;
    recoveryOwner.blockHost();
    const ledger=recoveryRoot.querySelector('.workspace-input-confirmation:not(.workspace-input-recovery)');ledger.inert=true;
    recoveryOwner.showGuardRecovery(true);
    const region=recoveryOwner.guardRecovery,recheck=[...region.querySelectorAll('button')][0];
    const preserved=()=>JSON.stringify(recoveryOwner.inspect().records)===original&&recoveryOwner.inspect().usedBytes===originalBytes&&writes.length===0;
    check('recovery separates guard from retained input controls '+retained,!region.inert&&!region.hidden&&ledger.inert&&region.querySelectorAll('button').length===1&&preserved());
    recheck.focus();recoveryOwner.refresh();check('recovery refresh retains guard focus '+retained,document.activeElement===recheck);
    for(const bad of ['rejected','malformed','wrong-lease']){
     guardFailure=bad==='rejected';guardValue=bad==='malformed'?{lease:'1'}:{lease:bad==='wrong-lease'?'2':'1',revision:'2',fence:null,resume_allowed:false,admission_error:null};
     await recoveryOwner.recoverGuard();
     check('recovery rejects '+bad+' without releasing ledger '+retained,recoveryOwner.inspect().frozen&&ledger.inert&&!region.hidden&&recoveryOwner.inspect().lease==='1'&&preserved());
    }
    guardFailure=false;
    guardValue={lease:'1',revision:'3',fence:{nonce:'7',state:'pending'},resume_allowed:false,admission_error:null};
    await recoveryOwner.recoverGuard();
    const replies=guardCalls.filter(c=>c.command==='workspace_input_guard_reply');
    check('recovery keeps existing quiescence reply '+retained,replies.length===1&&replies[0].request.lease==='1'&&replies[0].request.nonce==='7'&&replies[0].request.safe===!retained&&preserved());
    await recoveryOwner.recoverGuard();
    check('recovery does not repeat same nonce reply '+retained,guardCalls.filter(c=>c.command==='workspace_input_guard_reply').length===1&&preserved());
    const settled=recoveryOwner.inspect();
    guardValue={lease:'1',revision:'1',fence:{nonce:'8',state:'pending'},resume_allowed:false,admission_error:null};
    await recoveryOwner.recoverGuard();
    check('recovery ignores older guard revision '+retained,recoveryOwner.inspect().revision===settled.revision&&recoveryOwner.inspect().fenceState===settled.fenceState&&preserved());
    holdGuard=true;const late=recoveryOwner.recoverGuard();
    guardValue={lease:'1',revision:'6',fence:{nonce:'9',state:'released'},resume_allowed:true,admission_error:null};
    await recoveryOwner.recoverGuard();resolveGuard();await late;
    check('recovery rejects late old guard response '+retained,recoveryOwner.inspect().revision==='6'&&recoveryOwner.inspect().fenceState==='released'&&preserved());
    check('released guard alone cannot admit host input '+retained,ledger.inert&&!region.hidden&&!retainedProducer?.canAccept()&&preserved());
    recheck.focus();ledger.inert=false;recoveryOwner.showGuardRecovery(false);
    check('recovery restores same guard control and focus '+retained,region.hidden&&ledger.contains(recheck)&&(ledger.hidden?document.activeElement!==recheck:document.activeElement===recheck)&&preserved());
    recoveryOwner.dispose();check('recovery disposal removes both regions '+retained,!ledger.isConnected&&!region.isConnected);recoveryRoot.remove();
   }

// Actual adopted controller and actual input owner: inject only synthetic RPC responses.
  mode='success';let controller,resizeActive=false,offered=false,availability=[];
  const second=createTerminalInputOwner(root,guard,()=>uid(++seq));await second.initialize();
  let liveProducer;
  controller=createProjectPaneController({instanceId:target.instanceId,generation:target.generation,ownerKey,pickFolder:async()=>null,
   port:{ownerKey,recover:async(origin,q)=>{if(origin.ownerGeneration!=='1')throw Error('owner_mismatch');return ok(q,{operation:{operation_id:q.params.operation_id,phase:'completed',outcome:'succeeded',error_code:null}});},exchange:async q=>{
    if(q.operation==='capabilities.get')return ok(q,{schema_version:1,operations:['capabilities.get','project.list','pane.list','pane.resize'],max_message_bytes:1048576,providers:[],shell_profile_ids:['pwsh'],replay_capacity:{retained_bytes:134217728,active_bytes:268435456}});
    if(q.operation==='project.list')return ok(q,projects);
    if(q.operation==='pane.list')return ok(q,panes);
    if(q.operation==='pane.resize')return ok(q,q.params);
    throw Error('unexpected RPC');
   }},snapshot:s=>{snapshot=s;second.refresh();if(resizeActive){availability.push(s.availability);if(s.availability==='unavailable'&&!offered){offered=true;liveProducer.offer('resize');}}},settlement:()=>{},installation:()=>{}});
  await controller.refresh();second.connect({...connection,snapshot:controller.getSnapshot});await second.recoverGuard();
  if(controller.getSnapshot().availability!=='available')throw Error('synthetic valid controller fixture did not initialize');
  liveProducer=second.produce({...target,producerId:uid(7)});resizeActive=true;
  const settlement=await controller.control({...target,kind:'resize-pane',topologyRevision:7,rows:24,cols:80},1);
  if(settlement.disposition!=='completed')throw Error('synthetic resize did not complete');
  for(let n=0;n<24;n++)await Promise.resolve();
  check('confirmed non-topological resize does not falsely retire ordinary input',availability.length>0&&!availability.includes('unavailable')&&second.inspect().records.length===0,{availability,states:second.inspect().records.map(r=>r.state)});
  controller.dispose();second.dispose();root.replaceChildren();
  for(const scenario of ['refused','malformed_recovered','lost_recovered','revision_changed','read_failed','state_unknown','run_changed','project_changed']){
   let active=false,changed=false,control,sourceWrites=[],seqno=0,unavailableSeen=false,settled;
   const finalSettlement=new Promise(resolve=>{settled=resolve;});
   const owned=createTerminalInputOwner(root,guard,()=>uid(++seq));await owned.initialize();
   let input;
   const reply=(q,data)=>({...ok(q,data),topology_revision:changed&&scenario==='revision_changed'?8:7});
   const canonicalRefusal=(q,code)=>({...reply(q,null),accepted:false,result:null,error:{code,message:code==='state_unknown'?'Operation state is unknown.':'Target not found.',retryable:false,target_id:null}});
   control=createProjectPaneController({instanceId:target.instanceId,generation:target.generation,ownerKey,pickFolder:async()=>null,installation:()=>{},settlement:(_ticket,result)=>{if(result.disposition==='completed')settled();},snapshot:s=>{
    owned.refresh();if(active&&s.availability==='unavailable'&&!unavailableSeen){unavailableSeen=true;input.offer('protected');}
   },port:{ownerKey,recover(origin,q){if(origin.ownerGeneration!=='1')throw Error('owner_mismatch');return this.exchange(q);},exchange:async q=>{
    if(q.operation==='pane.resize'){
     changed=true;
     if(scenario==='refused')return canonicalRefusal(q,'target_not_found');
     if(scenario==='state_unknown')return canonicalRefusal(q,'state_unknown');
     if(scenario==='lost_recovered')throw Error('synthetic result lost');
     if(scenario==='malformed_recovered')return reply(q,{...q.params,run_id:uid(999)});
     return reply(q,q.params);
    }
    if(q.operation==='operation.get')return reply(q,{operation:{operation_id:q.params.operation_id,phase:'completed',outcome:'succeeded',error_code:null}});
    if(q.operation==='capabilities.get')return reply(q,{schema_version:1,operations:['capabilities.get','project.list','pane.list','pane.resize','operation.get'],max_message_bytes:1048576,providers:[],shell_profile_ids:['pwsh'],replay_capacity:{retained_bytes:134217728,active_bytes:268435456}});
    if(q.operation==='project.list'){
     if(changed&&scenario==='read_failed')throw Error('synthetic read failed');
     return reply(q,changed&&scenario==='project_changed'?{...projects,selected_project_id:null}:projects);
    }
    if(q.operation==='pane.list')return reply(q,changed&&scenario==='run_changed'?{...panes,panes:[{...panes.panes[0],current_run_id:uid(50),observation:{...panes.panes[0].observation,run_id:uid(50)}}]}:panes);
    throw Error('unexpected synthetic RPC '+q.operation);
   }}});
   await control.refresh();if(control.getSnapshot().availability!=='available')throw Error('negative fixture invalid '+scenario);
   owned.connect({ownerKey,snapshot:control.getSnapshot,maxBytes:()=>1048576,recover:async(origin,q)=>{if(origin.ownerGeneration!=='1')throw Error('owner_mismatch');return ok(q,{operation:{operation_id:q.params.operation_id,phase:'completed',outcome:'succeeded',error_code:null}});},exchange:async q=>{sourceWrites.push(q);return ok(q,{input_seq:++seqno,pane_id:q.params.pane_id,run_id:q.params.run_id,written_bytes:new TextEncoder().encode(q.params.text).length});}});await owned.recoverGuard();
   input=owned.produce({...target,producerId:uid(20)});active=true;
   const result=await control.control({...target,kind:'resize-pane',topologyRevision:7,rows:24,cols:80},1);
   if(scenario.endsWith('_recovered')){await new Promise(resolve=>setTimeout(resolve,0));await control.refresh();await finalSettlement;}
   for(let n=0;n<24;n++)await Promise.resolve();
   if(scenario==='state_unknown')check('unknown resize retains original unresolved controller state',result.disposition==='unknown'&&control.getPending()?.facts.knowledge==='unknown',{disposition:result.disposition});
   else {
    if(!unavailableSeen)input.offer('protected');
    for(let n=0;n<24;n++)await Promise.resolve();
    check('negative resize '+scenario+' never promotes stale target or auto resends',owned.inspect().records[0]?.state==='held'&&sourceWrites.length===0,{availability:control.getSnapshot().availability,states:owned.inspect().records.map(r=>r.state),writes:sourceWrites.length});
   }
   control.dispose();owned.dispose();root.replaceChildren();
  }
  return checks;
 });
 for(const item of integrationChecks){if(!item.passed)throw Error(item.name+' '+JSON.stringify(item.detail));checks.push(item.name);}
 const ownerChecks=await page.evaluate(async()=>{
  const {createTerminalInputOwner,scalarText}=globalThis.product;
  const passed=[],check=(name,value)=>{if(!value)throw Error(name);passed.push(name);};
  const flush=async()=>{for(let n=0;n<24;n++)await Promise.resolve();};
  const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
  const target={instanceId:uid(1),generation:uid(2),projectId:uid(3),paneId:uid(4),runId:uid(5),producerId:uid(6)};
  const snap=()=>({instanceId:target.instanceId,generation:target.generation,availability:'available',busy:false,projects:{selected_project_id:target.projectId,projects:[{project_id:target.projectId}]},panes:{project_id:target.projectId,panes:[{pane_id:target.paneId,current_run_id:target.runId}]}});
  const ownerKey={instanceId:target.instanceId,ownerGeneration:'1'};
  const ok=(q,data)=>({schema_version:1,instance_id:q.instance_id,operation_id:q.operation_id,accepted:true,topology_revision:0,event_seq:0,result:{operation:q.operation,data},error:null});
  const messages={invalid_request:['Invalid request.',false],unsupported_version:['Unsupported protocol version.',false],permission_denied:['Permission denied.',false],target_not_found:['Target not found.',false],stale_topology:['Topology changed.',true],operation_conflict:['Operation identifier conflict.',false],in_progress:['Operation is in progress.',true],not_running:['Run is not running.',false],already_running:['Run is already running.',false],unsupported_capability:['Capability is unavailable.',false],output_gap:['Output history is incomplete.',false],persistence_failed:['Persistence failed.',false],runtime_failed:['Runtime operation failed.',true],state_unknown:['Operation state is unknown.',false],resource_exhausted:['Resource limit reached.',false],root_changed:['Root identity changed.',false],unsupported_file:['File type is unsupported.',false],not_a_repository:['Git repository is unavailable.',false]};
  const refused=(q,code)=>({...ok(q,null),accepted:false,result:null,error:{code,message:messages[code][0],retryable:messages[code][1],target_id:null}});
  let current;
  async function fixture(limit=1048576){
   current?.owner.dispose();document.querySelector('#root').replaceChildren();
   let seq=100,listener;
   const f={snapshot:snap(),limit,status:{lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null},calls:[],guardCalls:[],replies:[],deferred:[],seq:0,resolve:null,mode:'success',confirmation:{phase:'unknown',outcome:null,error_code:null}};
   f.guard={listen:async fn=>{listener=fn;f.guardCalls.push('listen');return()=>{listener=null};},invoke:async(name,args)=>{
    const body=JSON.parse(args.requestJson);f.guardCalls.push(name);
    if(name==='workspace_input_guard_register'){check('registration exact UUID binding and listener first',Object.keys(body).join(',')==='binding'&&body.binding===uid(101)&&f.guardCalls[0]==='listen');return structuredClone(f.status);}
    if(name==='workspace_input_guard_status'){if(f.resolve){const capture=structuredClone(f.status);return new Promise(resolve=>f.deferred.push(()=>resolve(capture)));}return structuredClone(f.status);}
    if(name==='workspace_input_guard_reply'){f.replies.push(body);f.status={...f.status,revision:String(BigInt(f.status.revision)+1n),fence:{nonce:body.nonce,state:body.safe?'approved':'released'},resume_allowed:!body.safe,admission_error:body.safe?'shutdown_in_progress':null};return structuredClone(f.status);}
    throw Error('unexpected private command');
   }};
   f.owner=createTerminalInputOwner(document.querySelector('#root'),f.guard,()=>uid(++seq));
   f.success=q=>ok(q,{input_seq:f.seq+=3,pane_id:q.params.pane_id,run_id:q.params.run_id,written_bytes:new TextEncoder().encode(q.operation==='input.key'?'\x03':q.params.text).length,...(q.operation==='input.key'?{key:'interrupt',sent:true}:{})});
   f.exchange=async(q,beforeDispatch)=>{f.calls.push(structuredClone(q));if(q.operation==='operation.get')return ok(q,{operation:{operation_id:q.params.operation_id,...f.confirmation}});if(f.mode==='prewire')throw 'shutdown_in_progress';if(beforeDispatch&&!beforeDispatch())throw Error('host_not_sent');if(f.mode==='defer')return new Promise(resolve=>f.deliver=()=>resolve(f.success(q)));if(f.mode==='unknown')throw Error('IPC result unavailable');if(typeof f.mode==='function')return f.mode(q);return f.success(q);};
   f.connection={ownerKey,snapshot:()=>f.snapshot,maxBytes:()=>f.limit,exchange:(q,beforeDispatch)=>f.exchange(q,beforeDispatch),recover:(origin,q)=>{if(origin.ownerGeneration!=='1')throw Error('owner_mismatch');return f.exchange(q);}};
   await f.owner.initialize();f.owner.connect(f.connection);await flush();f.producer=f.owner.produce(target);f.wake=async()=>{listener?.({lease:f.status.lease,revision:f.status.revision});await flush();};current=f;return f;
  }

  async function focusFixture(){
   const f=await fixture();
   const view=document.createElement('div');view.innerHTML=`<section class="workspace-pane" data-pane-id="${target.paneId}" data-project-id="${target.projectId}" data-run-id="${target.runId}"><h2 tabindex="-1">同じペイン</h2><div class="workspace-terminal"><textarea></textarea></div></section><main tabindex="-1">作業領域</main><button>外側の操作</button>`;
   document.querySelector('#root').append(view);f.view=view;f.origin=view.querySelector('textarea');f.heading=view.querySelector('h2');f.main=view.querySelector('main');f.other=view.querySelector('button');f.panel=document.querySelector('#root .workspace-input-confirmation');f.recheck=[...f.panel.querySelectorAll('button')].find(b=>b.textContent==='入力の受付状態を再確認');return f;
  }
  const pendingStatus=nonce=>({lease:'1',revision:nonce,fence:{nonce,state:'pending'},resume_allowed:false,admission_error:'shutdown_in_progress'});
  let focusCase=await focusFixture();focusCase.origin.focus();focusCase.producer.pending(8,true);
  check('ordinary preedit keeps focus and root confirmation hidden',focusCase.panel.hidden&&document.activeElement===focusCase.origin);
  const originalInvoke=focusCase.guard.invoke;const replyRequests=[];let releaseReply;
  focusCase.guard.invoke=(name,args)=>name==='workspace_input_guard_reply'?new Promise(resolve=>{replyRequests.push(JSON.parse(args.requestJson));releaseReply=()=>resolve(originalInvoke(name,args));}):originalInvoke(name,args);
  focusCase.status=pendingStatus('2');const waiting=focusCase.owner.recoverGuard();await flush();
  check('new unsafe native Pending focuses panel once',document.activeElement===focusCase.panel&&!focusCase.panel.hidden);
  focusCase.recheck.focus();const retainedRecheck=focusCase.recheck;
  await focusCase.owner.recoverGuard();focusCase.owner.refresh();await focusCase.wake();
  check('same pending reply wait status and wake keep same control focus',retainedRecheck.isConnected&&document.activeElement===retainedRecheck&&replyRequests.length===1);
  releaseReply();await waiting;
  check('native unsafe release restores exact origin without clearing composition',document.activeElement===focusCase.origin&&focusCase.owner.hasPendingComposition()&&focusCase.replies.at(-1).safe===false);
  focusCase.producer.pending(0,false);
  focusCase=await focusFixture();focusCase.mode='prewire';focusCase.origin.focus();focusCase.producer.offer('held');await flush();
  const heldDiscard=[...focusCase.panel.querySelectorAll('button')].find(b=>b.textContent==='この対象の未送信入力を破棄');
  if(!heldDiscard)throw Error('prewire held control absent '+JSON.stringify({records:focusCase.owner.inspect().records,notice:focusCase.panel.textContent}));
  heldDiscard.focus();
  focusCase.producer.offer('second held');await flush();await focusCase.owner.recoverGuard();focusCase.owner.refresh();
  check('another held record retains same discard node and focus',heldDiscard.isConnected&&document.activeElement===heldDiscard);
  focusCase.status=pendingStatus('2');await focusCase.owner.recoverGuard();
  check('new Pending preserves focus already inside confirmation',document.activeElement===heldDiscard&&focusCase.replies.at(-1).safe===false);
  focusCase.status=pendingStatus('4');await focusCase.owner.recoverGuard();
  check('later nonce inside panel preserves focus and native reply identity',document.activeElement===heldDiscard&&focusCase.replies.at(-1).nonce==='4');
  heldDiscard.click();check('explicit discard closes panel and restores exact live terminal origin',focusCase.panel.hidden&&document.activeElement===focusCase.origin&&focusCase.owner.inspect().records.length===0);
  focusCase=await focusFixture();focusCase.origin.focus();focusCase.status=pendingStatus('2');await focusCase.owner.recoverGuard();
  check('quiescent native Pending approval does not steal external focus',document.activeElement===focusCase.origin&&focusCase.replies.at(-1).safe===true&&focusCase.owner.inspect().frozen);
  focusCase.recheck.focus();focusCase.status={lease:'1',revision:'4',fence:{nonce:'2',state:'released'},resume_allowed:true,admission_error:null};await focusCase.owner.recoverGuard();
  check('current released status closes confirmation and restores origin',focusCase.panel.hidden&&document.activeElement===focusCase.origin);
  for(const axis of ['removed','hidden','inert','disabled','run','project','generation','instance','retired']){
   const f=await focusFixture();f.mode='prewire';f.origin.focus();f.producer.offer('held');await flush();
   const discard=[...f.panel.querySelectorAll('button')].find(b=>b.textContent==='この対象の未送信入力を破棄');discard.focus();
   if(axis==='removed')f.origin.remove();
   if(axis==='hidden')f.origin.hidden=true;
   if(axis==='inert')f.origin.inert=true;
   if(axis==='disabled')f.origin.disabled=true;
   if(axis==='run'){f.view.querySelector('section').dataset.runId=uid(500);f.snapshot.panes.panes[0].current_run_id=uid(500);}
   if(axis==='project')f.snapshot.projects.selected_project_id=uid(500);
   if(axis==='generation')f.snapshot.generation=uid(500);
   if(axis==='instance')f.snapshot.instanceId=uid(500);
   if(axis==='retired')f.producer.retire();
   discard.click();
   check('confirmation retirement never restores invalid origin '+axis,document.activeElement===(['project','generation','instance'].includes(axis)?f.main:f.heading)&&f.owner.inspect().records.length===0);
  }
  focusCase=await focusFixture();focusCase.mode='prewire';focusCase.origin.focus();focusCase.producer.offer('held');await flush();
  const outsideDiscard=[...focusCase.panel.querySelectorAll('button')].find(b=>b.textContent==='この対象の未送信入力を破棄');outsideDiscard.focus();focusCase.other.focus();
  focusCase.owner.refresh();await focusCase.owner.recoverGuard();outsideDiscard.click();
  check('user external focus is preserved through refresh status and panel close',document.activeElement===focusCase.other);
  focusCase=await focusFixture();focusCase.mode='unknown';focusCase.origin.focus();focusCase.producer.offer('unknown');await flush();
  const confirmation=[...focusCase.panel.querySelectorAll('button')].find(b=>b.textContent==='元の操作の結果を確認'&&!b.hidden);confirmation.focus();
  focusCase.confirmation={phase:'completed',outcome:'succeeded',error_code:null};confirmation.click();await flush();
  check('confirmed record action retirement restores origin without replay',document.activeElement===focusCase.origin&&focusCase.owner.inspect().records.length===0&&focusCase.calls.filter(q=>q.operation==='input.write').length===1);
  focusCase=await focusFixture();focusCase.mode='prewire';focusCase.origin.focus();focusCase.producer.offer('held');await flush();focusCase.recheck.focus();focusCase.owner.dispose();
  check('owner dispose retires panel focus to connected exact origin',document.activeElement===focusCase.origin&&!focusCase.panel.isConnected);
  const click=async label=>{const b=[...document.querySelectorAll('#root button')].find(b=>b.textContent===label);if(!b)throw Error('missing '+label);b.click();await flush();};
  check('Unicode whole scalar rejects lone and swapped surrogates',scalarText('日本語😀𠮷')&&!scalarText('\ud800')&&!scalarText('\udc00')&&!scalarText('\udc00\ud800'));
  let f=await fixture();f.mode='defer';check('first column admitted',f.producer.offer('日本語'));check('second column admitted while first in flight',f.producer.offer('😀'));check('global FIFO no overlapping writes',f.calls.length===1&&f.owner.inspect().records.map(r=>r.state).join(',')==='sending,queued');
  const original=f.owner.inspect().records.map(r=>r.operationId);f.deliver();await flush();check('successful first releases next with original ID',f.calls.length===2&&f.calls[1].operation_id===original[1]);f.deliver();await flush();check('sequence gaps accepted and queue drained',f.owner.inspect().records.length===0);
  check('ETX uses input.key contract',f.producer.offer('\x03'));f.deliver();await flush();check('interrupt is key, not provider run.interrupt',f.calls.at(-1).operation==='input.key'&&f.calls.at(-1).params.key==='interrupt'&&f.owner.inspect().records.length===0);
  f=await fixture();f.snapshot.busy=true;check('resize busy does not block terminal input',f.producer.canAccept()&&f.producer.offer('resize'));await flush();check('resize busy delivers exact pane/run',f.calls.length===1&&f.calls[0].params.run_id===target.runId);
  f=await fixture();f.mode='unknown';f.producer.offer('uncertain');await flush();f.producer.offer('following');await flush();const uncertain=f.owner.inspect().records[0].operationId;check('unknown blocks next; no auto retry',f.calls.length===1&&f.owner.inspect().records.map(r=>r.state).join(',')==='unknown,held');
  for(const phase of ['accepted','in_progress','unknown']){f.confirmation={phase,outcome:null,error_code:null};await click('元の操作の結果を確認');check('operation.get '+phase+' retains original record',f.owner.inspect().records[0].state==='unknown'&&f.calls.at(-1).params.operation_id===uncertain&&f.calls.at(-1).operation==='operation.get');}
  f.confirmation={phase:'completed',outcome:'succeeded',error_code:null};await click('元の操作の結果を確認');check('confirmed original success retains next without send',f.owner.inspect().records.length===1&&f.owner.inspect().records[0].state==='held'&&f.calls.filter(q=>q.operation==='input.write').length===1);
  f.mode='success';await click('この対象の保持入力を送る');check('explicit send preserves original target and drains',f.calls.at(-1).params.text==='following'&&f.owner.inspect().records.length===0);
  for(const code of Object.keys(messages)){
   f=await fixture();f.mode=q=>refused(q,code);f.producer.offer('refusal');await flush();check('canonical refusal classified '+code,f.owner.inspect().records[0]?.state===(['in_progress','state_unknown'].includes(code)?'unknown':'failed')&&f.calls.length===1);
  }
  for(const mutate of [r=>({...r,operation_id:uid(999)}),r=>({...r,extra:true}),r=>({...r,event_seq:NaN}),r=>({...r,result:{...r.result,operation:'run.interrupt'}}),r=>({...r,result:{...r.result,data:{...r.result.data,pane_id:uid(999)}}}),r=>({...r,result:{...r.result,data:{...r.result.data,written_bytes:99}}}),r=>({...r,result:{...r.result,data:{...r.result.data,input_seq:0}}}),r=>({...r,result:{...r.result,data:{...r.result.data,extra:true}}})]){
   f=await fixture();f.mode=q=>mutate(f.success(q));f.producer.offer('strict');await flush();check('malformed success retained unknown '+passed.length,f.owner.inspect().records[0]?.state==='unknown');
  }
  f=await fixture();f.mode=q=>({...refused(q,'permission_denied'),error:{code:'permission_denied',message:'arbitrary',retryable:false,target_id:null}});f.producer.offer('strict error');await flush();check('malformed error is unknown',f.owner.inspect().records[0]?.state==='unknown');
  f=await fixture();f.mode='unknown';f.producer.offer('original');await flush();
  for(const result of [{phase:'completed',outcome:'succeeded',error_code:'runtime_failed'},{phase:'unknown',outcome:'succeeded',error_code:null},{phase:'completed',outcome:'failed',error_code:'invented'}]){f.confirmation=result;await click('元の操作の結果を確認');check('invalid operation outcome retained '+passed.length,f.owner.inspect().records[0]?.state==='unknown');}
  f.confirmation={phase:'completed',outcome:'failed',error_code:'state_unknown'};await click('元の操作の結果を確認');check('completed state_unknown stays unknown',f.owner.inspect().records[0]?.state==='unknown');
  f.confirmation={phase:'completed',outcome:'failed',error_code:'not_running'};await click('元の操作の結果を確認');check('known failed original can be acknowledged',f.owner.inspect().records[0]?.state==='failed');await click('確認済みの拒否を閉じる');check('acknowledgement never resends failed',f.owner.inspect().records.length===0&&f.calls.filter(q=>q.operation==='input.write').length===1);
  f=await fixture();f.mode='prewire';f.producer.offer('preserved');await flush();const preserved=f.owner.inspect().records[0].operationId;check('only known native prewire becomes held',f.owner.inspect().records[0].state==='held');f.owner.disconnect();f.producer.retire();f.owner.connect(f.connection);await flush();check('reconnect does not erase or resend ledger',f.owner.inspect().records[0].operationId===preserved&&f.calls.length===1);await click('この対象の未送信入力を破棄');check('explicit discard of unsent allowed',f.owner.inspect().records.length===0);
  for(const axis of ['generation','instance','run']){f=await fixture();f.mode='prewire';f.producer.offer('old');await flush();if(axis==='generation')f.snapshot.generation=uid(500);if(axis==='instance')f.snapshot.instanceId=uid(500);if(axis==='run')f.snapshot.panes.panes[0].current_run_id=uid(500);f.mode='success';await click('この対象の保持入力を送る');check('retired '+axis+' never sends to new target',f.calls.length===1&&f.owner.inspect().records[0].state==='held');}
  f=await fixture(700);f.mode='defer';check('bounded first record accepted',f.producer.offer('small'));const charge=f.owner.inspect().usedBytes;check('whole JSON capacity is charged beyond raw text',charge>300);check('second whole column over combined capacity refused',!f.producer.offer('second')&&f.calls.length===1);check('pending codec capacity shares ledger cap',!f.producer.pending(700,true));f.deliver();await flush();f.producer.pending(0,false);check('lone surrogate never charged or sent',!f.producer.offer('\ud800')&&f.calls.length===1);
  f=await fixture();f.producer.pending(30,true);check('active composition blocks every control',f.owner.admitControl()===null);f.status={lease:'1',revision:'2',fence:{nonce:'2',state:'pending'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.wake();check('unsafe challenge refuses and native release permits recovery',f.replies.at(-1).safe===false&&!f.owner.inspect().frozen);f.producer.pending(0,false);
  f.status={lease:'1',revision:'4',fence:{nonce:'4',state:'pending'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.wake();check('quiescent challenge approves but stays frozen',f.replies.at(-1).safe===true&&f.owner.inspect().frozen);f.status={lease:'1',revision:'6',fence:{nonce:'4',state:'released'},resume_allowed:true,admission_error:null};await f.wake();check('current released status unfreezes',!f.owner.inspect().frozen);
  f.status={lease:'1',revision:'9007199254740993',fence:{nonce:'7',state:'approved'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.wake();f.status={lease:'1',revision:'9007199254740992',fence:{nonce:'4',state:'released'},resume_allowed:true,admission_error:null};await f.owner.recoverGuard();check('u64 BigInt order rejects old release beyond Number precision',f.owner.inspect().frozen&&f.owner.inspect().revision==='9007199254740993');
  f=await fixture();f.resolve=true;const old=f.owner.recoverGuard();await flush();f.resolve=null;f.status={lease:'1',revision:'2',fence:{nonce:'2',state:'approved'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.owner.recoverGuard();f.deferred.shift()();await old;check('out of order status cannot thaw new fence',f.owner.inspect().frozen&&f.owner.inspect().revision==='2');
  f=await fixture();f.status={lease:'1',revision:'2',fence:{nonce:'2',state:'pending'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.owner.recoverGuard();
  const fencedCount=f.owner.inspect().records.length, fencedWrites=f.calls.length;
  check('native Pending rejects new offer and new IME before ledger entry',!f.producer.offer('after pending')&&!f.producer.pending(4,true)&&f.owner.inspect().records.length===fencedCount&&f.calls.length===fencedWrites);
  f.status={lease:'1',revision:'4',fence:{nonce:'2',state:'approved'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.owner.recoverGuard();
  check('native Approved still rejects offer and held input',!f.producer.offer('after approved')&&!f.producer.pending(4,true)&&f.owner.inspect().records.length===fencedCount);
  f.status={lease:'1',revision:'6',fence:{nonce:'2',state:'released'},resume_allowed:true,admission_error:null};await f.owner.recoverGuard();
  check('current Released and resume reopens input',f.producer.canAccept()&&f.producer.offer('after release'));await flush();
  check('post-release input delivered only once',f.calls.filter(q=>q.operation==='input.write').length===1&&f.owner.inspect().records.length===0);
  f=await fixture();f.producer.pending(8,true);f.status={lease:'1',revision:'2',fence:{nonce:'2',state:'pending'},resume_allowed:false,admission_error:'shutdown_in_progress'};await f.owner.recoverGuard();
  check('existing IME buffer makes challenge unsafe and remains owned',f.replies.at(-1).safe===false&&f.owner.hasPendingComposition()&&f.owner.inspect().records.length===0);
  check('existing preedit may update without becoming a new input record',f.producer.pending(12,true)&&f.owner.hasPendingComposition()&&f.owner.inspect().records.length===0);
  for(const invalid of [{...f.status,lease:'2'},{...f.status,revision:'02'},{...f.status,revision:'18446744073709551616'},{...f.status,extra:true},{...f.status,fence:null,resume_allowed:true,admission_error:null}]){f.status=invalid;await f.owner.recoverGuard();check('invalid private projection fails closed '+passed.length,f.owner.inspect().frozen);}
  f=await fixture();f.mode='unknown';f.producer.offer('PRIVATE_SYNTHETIC_COLUMN');await flush();check('input text absent from rendered confirmation metadata',!document.querySelector('#root').textContent.includes('PRIVATE_SYNTHETIC_COLUMN'));check('guard bodies contain no input text',f.guardCalls.every(name=>typeof name==='string'));f.owner.dispose();return passed;
 });checks.push(...ownerChecks);
 const codecChecks=await page.evaluate(async()=>{
  const {installTerminalInputCodec}=globalThis.product;
  const passed=[],check=(name,value)=>{if(!value)throw Error(name);passed.push(name);};
  const slot=document.querySelector('#term'),other=document.querySelector('#other');
  const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
  function fixture(){slot.replaceChildren();const terminal=new globalThis.Terminal({screenReaderMode:true,disableStdin:false});terminal.open(slot);terminal.focus();const f={terminal,ta:terminal.textarea,out:[],pending:0,active:false,enabled:true,notes:[],retired:false};const producer={target:{instanceId:uid(1),generation:uid(2),projectId:uid(3),paneId:uid(4),runId:uid(5),producerId:uid(6)},offer:text=>{f.out.push(text);return true;},pending:(bytes,active)=>{f.pending=bytes;f.active=active;return true;},canAccept:()=>f.enabled,retire:()=>{f.retired=true;}};f.codec=installTerminalInputCodec(slot,terminal,producer,message=>f.notes.push(message));f.dispose=()=>{f.codec.retire();terminal.dispose();};return f;}
  const event=(ta,type,options={})=>ta.dispatchEvent(type.startsWith('composition')?new CompositionEvent(type,{bubbles:true,...options}):new InputEvent(type,{bubbles:true,cancelable:type==='beforeinput',...options}));
  const key=(ta,type,options)=>ta.dispatchEvent(new KeyboardEvent(type,{bubbles:true,cancelable:true,...options}));
  const start=(f,text)=>{event(f.ta,'compositionstart');f.ta.value=text;event(f.ta,'compositionupdate',{data:text});event(f.ta,'input',{inputType:'insertCompositionText',data:text,isComposing:true});};
  const end=f=>event(f.ta,'compositionend',{data:f.ta.value});
  const tasks=[];const original=setTimeout;globalThis.setTimeout=(fn,delay,...args)=>delay===0?(tasks.push(()=>fn(...args)),tasks.length):original(fn,delay,...args);
  const drain=()=>{while(tasks.length)tasks.shift()();};
  try {
   for(const text of ['日本語','😀','𠮷','日本語😀']){const f=fixture();start(f,text);check('live preedit held '+text,f.out.length===0&&f.active&&f.pending>0&&slot.previousElementSibling.textContent==='変換を取消');key(f.ta,'keydown',{key:'Enter',keyCode:13,isComposing:true});key(f.ta,'keyup',{key:'Enter',keyCode:13,isComposing:true});end(f);event(f.ta,'input',{inputType:'insertFromComposition',data:text});drain();check('composition exactly once '+text,f.out.join('')===text&&f.out.length===1&&!f.active);key(f.ta,'keydown',{key:'Enter',code:'Enter',keyCode:13});check('following ordinary Enter sends one CR '+text,f.out.join('')===text+'\r'&&f.out.length===2);f.dispose();drain();}
   let f=fixture();start(f,'日本語');end(f);other.focus();f.terminal.focus();f.ta.value='unrelated later DOM';drain();check('delayed callback uses captured composition after blur/refocus',f.out.join('')==='日本語'&&document.activeElement===f.ta);f.dispose();drain();
   f=fixture();start(f,'確定');end(f);other.focus();drain();check('blur preserves committed column and does not steal focus',f.out.join('')==='確定'&&document.activeElement===other);f.dispose();drain();
   f=fixture();start(f,'未確定');other.focus();check('active blur preserves preedit without delivery',f.out.length===0&&f.active&&f.ta.value==='未確定');f.terminal.focus();end(f);drain();check('refocus commits original native preedit',f.out.join('')==='未確定');f.dispose();drain();
   f=fixture();start(f,'旧確定');end(f);f.codec.retire();check('retire pending commit belongs to old producer',f.out.join('')==='旧確定'&&f.retired);drain();check('old callback cannot duplicate after retirement',f.out.length===1);f.terminal.dispose();
   f=fixture();start(f,'取消');f.codec.retire();drain();check('retire uncommitted cancels with explanation',f.out.length===0&&f.notes.some(n=>n.includes('取消')));f.terminal.dispose();
   f=fixture();f.enabled=false;event(f.ta,'compositionstart');f.ta.value='拒否';event(f.ta,'compositionupdate',{data:'拒否'});event(f.ta,'compositionend',{data:'拒否'});event(f.ta,'input',{inputType:'insertFromComposition',data:'拒否'});drain();check('fenced late IME events create no accepted composition or delivery',f.out.length===0&&!f.active&&f.pending===0);f.dispose();drain();
   f=fixture();f.enabled=false;f.ta.value='遅着';event(f.ta,'input',{inputType:'insertText',data:'遅着'});drain();check('fenced late ordinary input has no delivery or pending bytes',f.out.length===0&&f.pending===0);f.dispose();drain();
   f=fixture();start(f,'既存');f.enabled=false;end(f);drain();check('fenced existing IME preedit remains visible and undelivered',f.out.length===0&&f.active&&f.ta.value==='既存');f.dispose();drain();
   f=fixture();for(let i=0;i<2;i++){start(f,'同じ');end(f);drain();}check('same repeated composition is two columns',f.out.join('|')==='同じ|同じ');f.dispose();drain();
   f=fixture();event(f.ta,'beforeinput',{inputType:'insertCompositionText',data:'日本語',isComposing:true});f.ta.value='日本語';event(f.ta,'input',{inputType:'insertCompositionText',data:'日本語',isComposing:true});end(f);drain();check('compositionstart absent uses actual beforeinput range',f.out.join('')==='日本語');f.dispose();drain();
   f=fixture();event(f.ta,'beforeinput',{inputType:'insertText',data:'😀'});f.ta.value='😀';event(f.ta,'input',{inputType:'insertText',data:'😀'});check('screen reader emoji from native input delivered once',f.out.join('')==='😀');f.dispose();drain();
   f=fixture();start(f,'先');end(f);event(f.ta,'beforeinput',{inputType:'insertText',data:'次'});f.ta.value='先次';event(f.ta,'input',{inputType:'insertText',data:'次'});drain();check('independent post-composition insertion has two exact columns',f.out.join('|')==='先|次');f.dispose();drain();
   f=fixture();start(f,'先');end(f);f.ta.value='ambiguous';event(f.ta,'input',{inputType:'insertText',data:'ambiguous'});drain();check('ambiguous completion is refused with active retention',f.out.length===0&&f.active&&f.notes.some(n=>n.includes('対応')));f.dispose();drain();
   f=fixture();start(f,'変換');const data=new DataTransfer();data.setData('text/plain','paste');f.ta.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:data}));check('paste during active IME keeps preedit and refuses delivery',f.out.length===0&&f.ta.value==='変換'&&f.active);const cancel=slot.previousElementSibling;cancel.click();check('explicit cancel releases only uncommitted preedit',f.out.length===0&&!f.active&&f.ta.value==='');f.dispose();drain();
   f=fixture();const data2=new DataTransfer();data2.setData('text/plain','一\n二');f.ta.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:data2}));check('ordinary multiline paste public SDK VT normalized once',f.out.join('')==='一\r二'&&f.out.length===1);
   let writeDone=false;f.terminal.write('\x1b[?2004h',()=>{writeDone=true;});drain();check('installed SDK writes bracketed-paste mode',writeDone);
   f.out=[];f.ta.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:data2}));check('bracketed paste retains SDK VT wrapper',f.out.join('')==='\x1b[200~一\r二\x1b[201~'&&f.out.length===1);f.dispose();drain();
   // Native paste has a default DOM insertion after the SDK paste callback.
   // Model that insertion only when not canceled; synthetic paste alone misses it.
   const nativePaste=(f,text,target=f.ta,cancelable=true)=>{const data=new DataTransfer();data.setData('text/plain',text);const event=new ClipboardEvent('paste',{bubbles:true,cancelable,clipboardData:data});target.dispatchEvent(event);if(!event.defaultPrevented&&cancelable){const before=new InputEvent('beforeinput',{bubbles:true,cancelable:true,inputType:'insertFromPaste',data:null});if(f.ta.dispatchEvent(before)){f.ta.value=text.replaceAll('\n','');f.ta.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertFromPaste',data:null}));}}return event;};
   for(const text of ['', '😀', '𠮷', '日本語', '😀\n二行目\n', '一\r\n二\r\n', '一\r二']){
    f=fixture();const first=nativePaste(f,text);check('native paste default insertion canceled '+JSON.stringify(text),first.defaultPrevented&&f.out.length===(text?1:0)&&(!text||f.out[0]===text.replace(/\r?\n/g,'\r'))&&f.ta.value==='');
    const second=nativePaste(f,text,f.terminal.element);check('sibling element and distinct repeat paste once '+JSON.stringify(text),second.defaultPrevented&&f.out.length===(text?2:0)&&(!text||f.out[1]===f.out[0]));f.dispose();drain();
   }
   f=fixture();let pasteModeReady=false;f.terminal.write('\x1b[?2004h',()=>{pasteModeReady=true;});await new Promise(resolve=>original(resolve,0));drain();check('native paste bracketed mode ready',pasteModeReady);const bracketed=nativePaste(f,'😀\n二');check('native bracketed paste single SDK VT column',bracketed.defaultPrevented&&f.out.length===1&&f.out[0]==='\x1b[200~😀\r二\x1b[201~');f.dispose();drain();
   f=fixture();start(f,'先');end(f);const afterIME=nativePaste(f,'😀\n二');drain();check('ended IME commit then native paste remain two distinct columns',afterIME.defaultPrevented&&f.out.length===2&&f.out[0]==='先'&&f.out[1]==='😀\r二');f.dispose();drain();
   f=fixture();start(f,'未確定');const duringIME=nativePaste(f,'😀\n二');check('active IME refuses native default paste and retains preedit',duringIME.defaultPrevented&&f.out.length===0&&f.ta.value==='未確定'&&f.active);f.dispose();drain();
   f=fixture();f.enabled=false;const guarded=nativePaste(f,'😀\n二');check('unavailable producer refuses both paste paths',guarded.defaultPrevented&&f.out.length===0);f.dispose();drain();
   f=fixture();const malformed=nativePaste(f,'😀',f.ta,false);check('noncancelable paste refuses SDK delivery',f.out.length===0&&f.notes.some(n=>n.includes('取消せない'))&&!malformed.defaultPrevented);f.dispose();drain();
   f=fixture();const priorTa=f.ta;f.codec.retire();nativePaste(f,'😀',priorTa);check('retired codec cannot deliver native paste',f.out.length===0&&f.retired);f.terminal.dispose();drain();
   f=fixture();key(f.ta,'keydown',{key:'c',code:'KeyC',keyCode:67,ctrlKey:true});check('ordinary Ctrl+C produces ETX',f.out.join('')==='\x03');f.enabled=false;key(f.ta,'keydown',{key:'Enter',keyCode:13});check('frozen guard blocks key delivery',f.out.length===1);other.focus();key(f.ta,'keyup',{key:'a',keyCode:65});check('old keyup never steals focus',document.activeElement===other);f.dispose();drain();
  }finally{globalThis.setTimeout=original;}
  return passed;
 });checks.push(...codecChecks);
 const searchChecks=await page.evaluate(async()=>{
  const {createProjectPaneView,createTerminalInputOwner,installTerminalInputCodec}=globalThis.product;
  const passed=[],check=(name,value,detail)=>{if(!value)throw Error(name+' '+JSON.stringify(detail));passed.push(name);};
  const flush=async()=>{for(let n=0;n<24;n++)await Promise.resolve();};
  const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
  const root=document.querySelector('#root');
  const routes=[['open-folder','open-folder'],['inspect-installation','inspect-installation'],['create-pane','create-pane'],['forget-project','forget-project'],['reread','reread'],['select-pane','select-pane'],['split-horizontal','split-pane'],['split-vertical','split-pane'],['interrupt-run','interrupt-run'],['close-pane','close-pane'],['resize-pane','resize-pane'],['cancel',null]];
  for(const reporting of [false,true])for(const [action,kind] of routes){
   root.replaceChildren();
   const target={instanceId:uid(1),generation:uid(2),projectId:uid(3),paneId:uid(4),runId:uid(5),producerId:uid(6)};
   const snapshot={instanceId:target.instanceId,generation:target.generation,topologyRevision:7,availability:'available',busy:false,
    projects:{projects:[{project_id:target.projectId,display_name:'synthetic',path:'C:/synthetic',root_state:'verified'}],selected_project_id:target.projectId},
    panes:{project_id:target.projectId,panes:[{pane_id:target.paneId,project_id:target.projectId,current_run_id:target.runId,display_name:'synthetic',observation:null}],root:{kind:'leaf',pane_id:target.paneId},selected_pane_id:target.paneId}};
   let seq=100,inputSeq=0;const writes=[],admissions=[],inspections=[];
   const guard={listen:async()=>()=>{},invoke:async()=>({lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null})};
   const owner=createTerminalInputOwner(root,guard,()=>uid(++seq));await owner.initialize();
   owner.connect({ownerKey:{instanceId:target.instanceId,ownerGeneration:'1'},snapshot:()=>snapshot,maxBytes:()=>1048576,recover:async()=>{throw Error('unexpected recovery');},exchange:async q=>{
    writes.push(q.params.text);return{schema_version:1,instance_id:q.instance_id,operation_id:q.operation_id,accepted:true,topology_revision:7,event_seq:0,result:{operation:q.operation,data:{input_seq:++inputSeq,pane_id:target.paneId,run_id:target.runId,written_bytes:new TextEncoder().encode(q.params.text).length}},error:null};
   }});await owner.recoverGuard();
   let terminal,codec;
   const view=createProjectPaneView(root,snapshot,{
    control:(intent)=>{const release=intent.kind==='resize-pane'?()=>{}:owner.admitControl();admissions.push({kind:intent.kind,accepted:!!release,records:owner.inspect().records.map(r=>r.state)});release?.();return{disposition:release?'completed':'refused'};},inspect:intent=>inspections.push(intent.kind),composing:owner.hasPendingComposition,
    mountTerminal:slot=>{terminal=new globalThis.Terminal({screenReaderMode:true});terminal.open(slot);codec=installTerminalInputCodec(slot,terminal,owner.produce(target),owner.explain);return()=>{codec.retire();terminal.dispose();};}
   });
   if(reporting)await new Promise(resolve=>terminal.write('\x1b[?1004h',resolve));
   terminal.focus();await flush();
   terminal.textarea.dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,cancelable:true,key:'p',ctrlKey:true,shiftKey:true}));await flush();
   const source=action==='cancel'?null:root.querySelector('[data-action="'+action+'"]');
   const label=source?.getAttribute('aria-label')??source?.textContent;
   const result=action==='cancel'?root.querySelector('[data-action="close-search"]'):[...root.querySelectorAll('[data-action="search-result"]')].find(button=>button.textContent===label);
   result.focus();await flush();const before=writes.length;
   result.click();await flush();
    if(action==='close-pane'){
     check('search close opens its captured confirmation '+reporting,root.querySelector('[aria-label="実行中のペインを閉じる"]').open&&admissions.length===0);
     root.querySelector('[data-action="modal-confirm"]').click();await flush();
     check('search close completion dismisses confirmation once '+reporting,!root.querySelector('[aria-label="実行中のペインを閉じる"]').open&&admissions.length===1);
    }
   const read=['inspect-installation','reread'].includes(kind);
   check('search action admits quiescent terminal with focus reporting '+reporting+' '+action,action==='cancel'?admissions.length===0&&inspections.length===0:read?admissions.length===0&&inspections.length===1&&inspections[0]===kind:admissions.length===1&&admissions[0].accepted&&admissions[0].kind===kind,{admissions,inspections,writes:writes.slice(before)});
   check('search activation focus follows execution or cancel '+reporting+' '+action,document.activeElement===(action==='close-pane'?root.querySelector('main'):action==='cancel'?terminal.textarea:source),{active:document.activeElement?.dataset.action,writes:writes.slice(before)});
   check('search activation sends no Enter or unrelated text '+reporting+' '+action,writes.every(text=>['\x1b[I','\x1b[O'].includes(text)),{writes});
   if(action!=='cancel')check('search execution never refocuses terminal before admission '+reporting+' '+action,writes.slice(before).length===0,{writes:writes.slice(before)});
   view.dispose();owner.dispose();
  }
  return passed;
 });checks.push(...searchChecks);
 const focusChecks=await page.evaluate(()=>{
  const {restoreWorkspaceFocus,installWorkspaceShortcuts}=globalThis.product,passed=[];
  const check=(name,value)=>{if(!value)throw Error(name);passed.push(name);};
  const root=document.querySelector('#root');root.innerHTML='<button id="origin">元の操作</button><h2 id="fallback" tabindex="-1">ペイン</h2><dialog><button id="closed">閉じたdialog</button></dialog><button id="hidden" hidden>hidden</button>';
  const origin=root.querySelector('#origin'),fallback=root.querySelector('#fallback');restoreWorkspaceFocus(origin,[fallback]);check('same connected origin receives focus',document.activeElement===origin);origin.remove();restoreWorkspaceFocus(origin,[fallback]);check('removed origin restores nearest pane fallback',document.activeElement===fallback);restoreWorkspaceFocus(root.querySelector('#closed'),[fallback]);check('closed dialog focus excluded',document.activeElement===fallback);restoreWorkspaceFocus(root.querySelector('#hidden'),[fallback]);check('hidden origin focus excluded',document.activeElement===fallback);
  let enabled=true,composing=false;const calls=[];const remove=installWorkspaceShortcuts(root,{enabled:()=>enabled,composing:()=>composing,search:()=>calls.push('search'),create:()=>calls.push('create'),close:()=>calls.push('close')});
  const key=(key,options={})=>fallback.dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,cancelable:true,key,ctrlKey:true,shiftKey:true,...options}));
  for(const k of ['p','t','w'])key(k);check('documented shortcuts reuse exact actions',calls.join(',')==='search,create,close');composing=true;key('p');composing=false;key('t',{isComposing:true});key('w',{keyCode:229});check('IME and 229 suppress all shortcut actions',calls.length===3);enabled=false;key('p');check('single-key-independent shortcut option disables capture',calls.length===3);enabled=true;key('p',{altKey:true});key('p',{metaKey:true});check('OS modifier alternatives remain unhandled',calls.length===3);remove();key('p');check('disposed shortcut handler has no effect',calls.length===3);return passed;
 });checks.push(...focusChecks);
}catch(error){failure=String(error.stack||error);}finally{if(browser)await browser.close();}
const after=identity();if(JSON.stringify(before)!==JSON.stringify(after))failure=(failure||'')+'\nInput source identity changed during run';
const receipt={scope:'actual production input owner, codec and focus with installed xterm in headless Edge; synthetic DOM composition; no native Windows IME, Tauri IPC, PTY or Narrator acceptance',command:[process.execPath,...process.argv.slice(1)],started,ended:new Date().toISOString(),browserVersion:browser?.version(),xtermVersion:JSON.parse(readFileSync(resolve(dependency,'node_modules/xterm/package.json'),'utf8')).version,success:failure===null,passed:checks.length,checks,failure,source_before:before,source_after:after};
writeFileSync(resolve(evidence,'receipt.json'),JSON.stringify(receipt,null,2)+'\n','utf8');
console.log(JSON.stringify({scope:receipt.scope,success:receipt.success,passed:receipt.passed,receipt:resolve(evidence,'receipt.json'),failure}));
if(failure)process.exitCode=1;
