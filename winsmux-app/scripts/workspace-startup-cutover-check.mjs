import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const option = (key, fallback) => { const i=process.argv.indexOf(key); return i<0?fallback:resolve(process.argv[i+1]); };
const source = option('--source-root', app), dependency = option('--dependency-root', source);
const evidence = option('--evidence-dir', resolve(app,'../.evidence/rebuild/v0.38.0/TASK-871/startup'));
const require = createRequire(resolve(dependency,'package.json'));
const { build }=require('esbuild'), { chromium }=require('playwright');
const read = p => readFileSync(existsSync(resolve(app,p))?resolve(app,p):resolve(source,p),'utf8');
mkdirSync(evidence,{recursive:true});
const nativeSource=read('src-tauri/src/lib.rs'), secondaryNativeSource=read('src-tauri/src/startup_secondary_native.rs');
const handlerBody=nativeSource.match(/generate_handler!\[([\s\S]*?)\]/)?.[1];
if(!handlerBody)throw Error('Actual native handler registry absent');
const registeredCommands=handlerBody.split(',').map(name=>name.trim().split('::').at(-1)).filter(Boolean);
if(!registeredCommands.includes('startup_secondary_creation_policy'))throw Error('Closed creation bootstrap missing from native registry');
if(!registeredCommands.includes('startup_secondary_request')||!/#\[tauri::command\][\s\S]*?pub\(crate\) async fn startup_secondary_request/.test(secondaryNativeSource)||registeredCommands.includes('desktop_editor_read'))throw Error('Secondary fixture must match actual native registration');
const shims = {
 '@tauri-apps/api/core': 'export const isTauri=()=>globalThis.fixture.native; export const invoke=(name,args)=>globalThis.fixture.invoke(name,args);',
 '@tauri-apps/api/webviewWindow': 'export const getCurrentWebviewWindow=()=>({label:globalThis.fixture.label,show:async()=>{throw Error("direct JS show forbidden")},close:async()=>{globalThis.fixture.closes++}}); export class WebviewWindow { constructor(){throw Error("constructor must use explicit fixture owner")} }',
 '@tauri-apps/api/event': 'export const listen=async(name,fn)=>{globalThis.fixture.listeners.set(name,fn);return()=>{globalThis.fixture.listeners.delete(name)}};',
 '@tauri-apps/plugin-dialog': 'export const open=async()=>{globalThis.fixture.pickers++;return globalThis.fixture.pick()};',
 xterm: `export class Terminal { constructor(options){this.options=options;globalThis.fixture.terminals.push(this);this.cols=80;this.rows=24;this.parser={registerCsiHandler:()=>({dispose(){}})}} loadAddon(){} open(slot){this.slot=slot;this.textarea=document.createElement('textarea');this.output=document.createElement('span');slot.append(this.output,this.textarea)} write(text){this.output.textContent+=text} reset(){this.output.textContent='';this.textarea.value=''} onResize(fn){this.resize=fn;return{dispose:()=>{this.resize=null}}} onData(fn){this.data=fn;return{dispose:()=>{this.data=null}}} onKey(fn){this.key=fn;return{dispose:()=>{this.key=null}}} attachCustomKeyEventHandler(fn){this.guard=fn} hasSelection(){return false} dispose(){this.disposed=true;this.slot.replaceChildren()} }`,
 '@xterm/addon-fit': 'export class FitAddon { fit(){} }',
};

const ts=require('typescript');
const sdkFile=resolve(dependency,'node_modules/@tauri-apps/api/webviewWindow.js'),windowFile=resolve(dependency,'node_modules/@tauri-apps/api/window.js');
const sdkBytes=readFileSync(sdkFile,'utf8'),windowBytes=readFileSync(windowFile,'utf8');
const members=(file,bytes,className,names)=>{const ast=ts.createSourceFile(file,bytes,ts.ScriptTarget.ES2020,true,ts.ScriptKind.JS),node=ast.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text===className);return node.members.filter(m=>ts.isConstructorDeclaration(m)&&names.includes('constructor')||names.includes(m.name?.getText(ast))).map(m=>m.getText(ast)).join('\n');};
const installedSDK=members(sdkFile,sdkBytes,'WebviewWindow',['constructor','once'])+'\n'+members(windowFile,windowBytes,'Window',['emit','_handleTauriEvent']);
shims['@tauri-apps/api/webviewWindow']='const invoke=(n,a)=>globalThis.fixture.invoke(n,a); const localTauriEvents=["tauri://created","tauri://error"]; export const getCurrentWebviewWindow=()=>({label:globalThis.fixture.label,show:async()=>{throw Error("direct JS show forbidden")},close:async()=>{globalThis.fixture.closes++}}); export class WebviewWindow {\n'+installedSDK+'\n}';

const outputs={};const inputs=new Set();
for(const name of ['startup-entry','startup-location','startup-secondary-create','startup-secondary','startup-mount','project-pane-terminal','project-pane-controller']){
 const result=await build({stdin:{contents:`export * from './src/workspace-ui/${name}.ts';`,resolveDir:app,sourcefile:'fixture-entry.ts'},bundle:true,write:false,format:'esm',platform:'browser',target:'es2020',metafile:true,plugins:[{name:'explicit-effect-fixture',setup(b){
  b.onResolve({filter:/.*/},args=>{if(args.path in shims)return{path:args.path,namespace:'effect'};if(args.path.endsWith('.css'))return{path:args.path,namespace:'css'};if(args.path.startsWith('.')){const candidate=resolve(args.resolveDir,args.path), relative=candidate.slice(app.length+1);for(const suffix of ['', '.ts']){const local=resolve(app,relative+suffix),fallback=resolve(source,relative+suffix);if(existsSync(local)||existsSync(fallback))return{path:local,namespace:'project'};}}});
  b.onLoad({filter:/.*/,namespace:'effect'},args=>({contents:shims[args.path],loader:'js'}));
  b.onLoad({filter:/.*/,namespace:'css'},()=>({contents:'',loader:'js'}));
  b.onLoad({filter:/.*/,namespace:'project'},args=>({contents:read(args.path.slice(app.length+1)),loader:extname(args.path)==='.ts'?'ts':'js',resolveDir:dirname(args.path)}));
 }}]});
 outputs[name]=result.outputFiles[0].text;for(const p of Object.keys(result.metafile.inputs))inputs.add(p);
}
if([...inputs].some(p=>/\/(main|ptyClient|firstRunWizard|fleetProjection|desktopClient)\.ts$|scheduler|panels/.test(p.replaceAll('\\','/'))))throw Error('Legacy effect module in live startup closure');
const html=read('index.html').replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'');
const launcher=readFileSync(resolve(app,'../scripts/start-cli-bakeoff-desktop.ps1'),'utf8');
const runner=read('scripts/run-cli-bakeoff.mjs');
const expression=launcher.match(/\$expression = @'\r?\n([\s\S]*?)\r?\n'@/)?.[1];
if(!expression)throw Error('Launcher canonical observation expression absent');
const preloadPath=resolve(evidence,'runner-effect-fixture.mjs');
writeFileSync(preloadPath, `
import { registerHooks } from 'node:module';
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, relative } from 'node:path';
const sparseRoot=${JSON.stringify(app)},sourceRoot=${JSON.stringify(source)};
registerHooks({resolve(specifier,context,nextResolve){
 if(specifier.startsWith('.')&&context.parentURL?.startsWith('file:')){
  const requested=fileURLToPath(new URL(specifier,context.parentURL));const rel=relative(sparseRoot,requested);
  if(!rel.startsWith('..')&&!existsSync(requested)&&existsSync(resolve(sourceRoot,rel)))return nextResolve(pathToFileURL(resolve(sourceRoot,rel)).href,context);
 }
 return nextResolve(specifier,context);
}});
const mode=process.env.WINSMUX_RUNNER_FIXTURE;
globalThis.fetch=async()=>({ok:true,json:async()=>[{type:'page',url:'http://tauri.localhost/',webSocketDebuggerUrl:'ws://explicit-offline-fixture/'}]});
let evaluations=0;
globalThis.WebSocket=class{
 constructor(){this.listeners=new Map();queueMicrotask(()=>this.listeners.get('open')?.())}
 addEventListener(name,fn){this.listeners.set(name,fn)}
 send(text){evaluations++;const request=JSON.parse(text);const value=JSON.stringify({native:true,label:mode==='workspace'?'main':'unknown',href:'http://tauri.localhost/',startup:mode==='workspace',legacy:false});queueMicrotask(()=>this.listeners.get('message')?.({data:JSON.stringify({id:request.id,result:{result:{value}}})}))}
 close(){}
};
process.on('exit',()=>console.log(JSON.stringify({fixture:'offline-runner-boundary',evaluations})));
`, 'utf8');
const browser=await chromium.launch({headless:true,channel:process.env.WINSMUX_TEST_BROWSER_CHANNEL||'msedge'});
const checks=['live import closure contains no retired effect modules'];
try {
 const page=await browser.newPage();await page.route('**/*',route=>route.request().url()==='https://tauri.localhost/'?route.fulfill({contentType:'text/html',body:html}):route.abort());await page.goto('https://tauri.localhost/');
 const passed=await page.evaluate(async ({outputs,expression,registeredCommands})=>{
  const passed=[],check=(name,ok)=>{if(!ok)throw Error(name);passed.push(name)},I='11111111-1111-4111-8111-111111111111',P='22222222-2222-4222-8222-222222222222';
  globalThis.fixture={native:false,label:'unknown',shows:0,closes:0,pickers:0,pick:async()=>null,frames:[],listeners:new Map(),terminals:[],calls:[],initial:null,revision:0,selected:null,root:'C:/fixture/project'};
  const f=globalThis.fixture;
  f.invoke=async(name,args)=>{
   if(name==='plugin:webview|create_webview_window'){f.sdkOptions=args.options;return f.sdkPromise??null;}
   if(name==='startup_secondary_creation_policy'){if(f.label!=='main'||!f.locationAllowed(f.label,location.href)||Object.keys(args).length)throw Error('closed bootstrap denied');return{additional_browser_args:null};}
   if(!registeredCommands.includes(name))throw Error('unregistered native command '+name);
   f.calls.push({name,args});
   if(name==='startup_main_policy_ready'){if(!f.native||f.label!=='main')throw Error('main policy caller denied');return null;}
   if(name==='startup_main_show'){if(!f.native||f.label!=='main')throw Error('main show caller denied');f.shows++;return null;}
   if(name.startsWith('workspace_input_guard_')){
    if(!f.native||f.label!=='main')throw Error('input main caller denied');
    const q=JSON.parse(args.requestJson);
    if(name==='workspace_input_guard_register'&&Object.keys(q).join(',')==='binding'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(q.binding))return{lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null};
    if(name==='workspace_input_guard_status'&&Object.keys(q).join(',')==='lease'&&q.lease==='1')return{lease:'1',revision:'1',fence:null,resume_allowed:false,admission_error:null};
    throw Error('unmodeled input guard request');
   }
   if(name==='startup_secondary_request'){
    if(!f.native||f.label==='main'||!f.locationAllowed(f.label,f.href)||f.origin!==new URL(f.href).origin)throw Error('secondary local caller denied');
    const q=JSON.parse(args.requestJson),keys=Object.keys(q).sort().join(',');
    if(q.kind==='show'&&keys==='kind'){f.shows++;return{shown:true};}
    if(q.kind!=='editor-read'||keys!=='kind,path,project_dir,worktree'||typeof q.project_dir!=='string'||!q.project_dir||!(q.worktree===null||typeof q.worktree==='string')||f.relativeReadPath(q.path)!==q.path)throw Error('closed secondary request denied');
    return{project_dir:q.project_dir,worktree:q.worktree,file:{path:q.path,content:'日本語\r\nconst x = 1;',line_count:2,truncated:false}};
   }
   if(name==='workspace_session_open')return{instance_id:I,schema_version:1};if(name==='workspace_host_status')return{instance_id:I,generation:'1',revision:'1',phase:'Ready'};if(name==='desktop_initial_project_dir')return f.initial;if(name!=='workspace_request')throw Error('unexpected effect '+name);
   const q=JSON.parse(args.requestJson);let data;
   switch(q.operation){case'capabilities.get':data={schema_version:1,operations:['capabilities.get','project.list','pane.list','project.open','project.select','pane.create','pane.select','run.get','operation.get','events.wait','output.read','pane.resize'],max_message_bytes:1048576,providers:[],shell_profile_ids:['pwsh'],replay_capacity:{retained_bytes:134217728,active_bytes:268435456}};break;
    case'project.list':data={projects:f.selected?[{project_id:P,path:f.root,display_name:'fixture',root_state:'verified'}]:[],selected_project_id:f.selected};break;
    case'project.open':f.revision++;data={project_id:P,created:false};break;
    case'project.select':f.selected=q.params.project_id;f.revision++;data={selected_project_id:f.selected,selected_pane_id:null};break;
    case'pane.list':data={project_id:P,selected_pane_id:null,panes:[],root:null};break;
    case'events.wait':data={events:[],next_event_seq:0,status:'no_change'};break;
    default:throw Error('unmodeled fixture request '+q.operation);}
   return{schema_version:1,instance_id:I,operation_id:q.operation_id,accepted:true,topology_revision:f.revision,event_seq:0,result:{operation:q.operation,data},error:null};
  };
  globalThis.requestAnimationFrame=fn=>{f.frames.push(fn);return f.frames.length};globalThis.cancelAnimationFrame=()=>{};
  f.awaitMount=async pending=>{let settled=false,error;pending.then(()=>{settled=true;},value=>{settled=true;error=value;});while(!settled){if(f.frames.length)f.frames.shift()(0);await new Promise(resolve=>setTimeout(resolve,0));}if(error)throw error;return pending;};
  const load=async name=>import(URL.createObjectURL(new Blob([outputs[name]],{type:'text/javascript'})));
  const secondary=await load('startup-secondary'),entry=await load('startup-entry');
  f.locationAllowed=entry.startupLocationAllowed;f.relativeReadPath=secondary.relativeReadPath;
  f.secondaryContext=()=>{f.native=true;f.label='secondary-surface-fixture';f.href='https://tauri.localhost/index.html?popout=1&popout-key=winsmux.popout-surface.fixture';f.origin='https://tauri.localhost';};
  check('actual registry denies missing old alias',!registeredCommands.includes('desktop_editor_read')&&registeredCommands.includes('startup_secondary_request'));
  const key='winsmux.popout-surface.test',query='?popout=1&popout-key='+key,label='secondary-surface-fixture';
  const urlCases=[];const urlCase=(name,label,href,allowed)=>urlCases.push({name,label,href,allowed});
  for(const origin of ['https://tauri.localhost','http://tauri.localhost','tauri://localhost','http://tauri.localhost:80','https://tauri.localhost:443']){urlCase('main '+origin,'main',origin+'/',true);for(const pathname of ['/','/index.html'])urlCase('secondary '+origin+pathname,label,origin+pathname+query,true);}
  for(const href of ['https://tauri.localhost/index.html','https://tauri.localhost/?x=1','https://tauri.localhost/#','https://tauri.localhost/#x','https://tauri.localhost:444/','https://localhost/','https://outside.invalid/','https://user:password@tauri.localhost/','file:///index.html'])urlCase('main closed '+href,'main',href,false);
  for(const bad of ['secondary-surface-','secondary-surface-a_b','secondary-surface-é','secondary-surface-a/b','old-editor','preview','worker-1','unknown'])urlCase('label '+bad,bad,'https://tauri.localhost/index.html'+query,false);
  for(const tail of ['#','#fragment','&extra=1','&popout=1','&popout-key='+key])urlCase('secondary tail '+tail,label,'https://tauri.localhost/index.html'+query+tail,false);
  for(const href of ['https://tauri.localhost:444/index.html'+query,'https://user:password@tauri.localhost/index.html'+query,'https://outside.invalid/index.html'+query,'https://localhost/index.html'+query,'file:///index.html'+query,'https://tauri.localhost/other.html'+query,'https://tauri.localhost/%69ndex.html'+query,'https://tauri.localhost/index.html','https://tauri.localhost/index.html?popout=1','https://tauri.localhost/index.html?popout=0&popout-key='+key,'https://tauri.localhost/index.html?popout=1&popout-key=wrong'])urlCase('secondary closed '+href,label,href,false);
  for(const search of ['?popout-key='+key+'&popout=1','?%70opout=1&popout%2Dkey='+key])urlCase('decoded/order '+search,label,'https://tauri.localhost/index.html'+search,true);
  for(const item of urlCases)check('actual frontend URL table '+item.name,entry.startupLocationAllowed(item.label,item.href)===item.allowed);
  f.secondaryContext();
  for(const item of [ {name:'desktop_editor_read',args:{}},{name:'startup_secondary_request',args:{requestJson:'{"kind":"unknown"}'}},{name:'startup_secondary_request',args:{requestJson:'{"kind":"show","label":"main"}'} }]){let rejected=false;const shows=f.shows;try{await f.invoke(item.name,item.args)}catch{rejected=true}check('registered fixture default deny '+JSON.stringify(item),rejected&&f.shows===shows);}
  for(const changed of [{label:'main'},{label:'unknown'},{origin:'https://outside.invalid'},{href:f.href+'#fragment'}]){const original={label:f.label,origin:f.origin,href:f.href},shows=f.shows;Object.assign(f,changed);let rejected=false;try{await f.invoke('startup_secondary_request',{requestJson:'{"kind":"show"}'})}catch{rejected=true}check('local caller model denies '+JSON.stringify(changed),rejected&&f.shows===shows);Object.assign(f,original);}
  f.native=false;f.label='unknown';
  const editor={mode:'editor',path:'日本語.ts',worktree:'',summary:'fixture',origin:'explorer',modified:false,content:'日本語\r\nconst x = 1;'},preview={mode:'preview',url:'http://localhost:3000/',portLabel:'3000',sourceLabel:'fixture',lastSeenAt:1};
  const storage={values:new Map(),removed:[],getItem(key){return this.values.get(key)??null},removeItem(key){this.removed.push(key);this.values.delete(key)}};
  check('browser and unknown native role closed',entry.selectStartupRoute(false,'main','',storage).kind==='closed'&&entry.selectStartupRoute(true,'unknown','',storage).kind==='closed');
  check('main ordinary query alone admitted',entry.selectStartupRoute(true,'main','',storage).kind==='main'&&entry.selectStartupRoute(true,'main','?popout=1',storage).kind==='closed');
  for(const payload of [editor,preview]){storage.values.set('winsmux.popout-surface.test',JSON.stringify(payload));const route=entry.selectStartupRoute(true,'secondary-surface-test','?popout=1&popout-key=winsmux.popout-surface.test',storage);check('secondary '+payload.mode+' immutable once consume',route.kind==='secondary'&&Object.isFrozen(route)&&Object.isFrozen(route.payload)&&entry.selectStartupRoute(true,'secondary-surface-test','?popout=1&popout-key=winsmux.popout-surface.test',storage).kind==='closed');}
  for(const search of ['?popout=1&popout=1','?popout=1&popout-key=x','?popout=1&popout-key=winsmux.popout-surface.test&extra=1','?popout=1&popout-key=winsmux.popout-surface.test&popout-key=winsmux.popout-surface.test'])check('closed query '+search,entry.selectStartupRoute(true,'secondary-surface-test',search,storage).kind==='closed');
  for(const payload of [{...editor,save:true},{...editor,modified:'false'},{...editor,origin:'other'},{...editor,content:null},{...preview,lastSeenAt:NaN},{...preview,url:'https://localhost:3000/'},{...preview,url:'http://user@localhost:3000/'},{...preview,url:'http://example.com/'},{...preview,extra:true}])check('closed malformed payload '+JSON.stringify(payload),entry.validatePopoutPayload(payload)===null);
  for(const root of [null,'',JSON.stringify({})]){const empty={getItem:key=>key==='winsmux.active-project.v1'?root:'[]'};check('readonly missing root denied '+root,secondary.capturedReadRoot(empty)===null);}
  storage.values.set('winsmux.active-project.v1','C:/fixture');storage.values.set('winsmux.project-sessions.v1',JSON.stringify([{path:'C:/fixture',name:'fixture',lastSeenAt:1}]));check('readonly exact explicit root',secondary.capturedReadRoot(storage)==='C:/fixture');
  check('own property shadow never alters closed validation',entry.validatePopoutPayload({...editor,hasOwnProperty:()=>true})===null&&entry.validatePopoutPayload(Object.assign(Object.create(null),editor))===null&&entry.validatePopoutPayload(Object.create(editor))===null);
  const controllerModule=await load('project-pane-controller');
  const caps={schema_version:1,operations:['capabilities.get','project.list'],max_message_bytes:1048576,providers:null,shell_profile_ids:null,replay_capacity:{retained_bytes:134217728,active_bytes:268435456}};
  const envelope=(q,data)=>({schema_version:1,instance_id:I,operation_id:q.operation_id,accepted:true,topology_revision:0,event_seq:0,result:{operation:q.operation,data},error:null});
  for(const mode of ['own','nullprototype','inherited-required','shadow-extra','inherited-error-constructor','inherited-error-toString']){
   const c=controllerModule.createProjectPaneController({instanceId:I,generation:'fixture',pickFolder:async()=>null,snapshot(){},settlement(){},installation(){},port:{exchange:async q=>{const response=envelope(q,q.operation==='capabilities.get'?caps:{projects:[],selected_project_id:null});if(mode==='nullprototype')return Object.assign(Object.create(null),response);if(mode==='inherited-required'){const inherited=Object.create({schema_version:1});for(const k of Object.keys(response))if(k!=='schema_version')inherited[k]=response[k];return inherited;}if(mode==='shadow-extra')return{...response,hasOwnProperty:()=>true};if(mode.startsWith('inherited-error'))return{...response,accepted:false,result:null,error:{code:mode.endsWith('constructor')?'constructor':'toString',message:'x',retryable:false,target_id:null}};return response;}}});
   await c.refresh();check('controller own-property compatibility '+mode,c.getSnapshot().availability===(['own','nullprototype'].includes(mode)?'available':'unavailable'));c.dispose();
  }
  const mainModule=await load('startup-mount'),O='33333333-3333-4333-8333-333333333333',B='44444444-4444-4444-8444-444444444444',R='55555555-5555-4555-8555-555555555555';
  check('session closed schema1 UUID DTO',mainModule.validSession({instance_id:I,schema_version:1})&&!mainModule.validSession({instance_id:I,schema_version:1,extra:true})&&!mainModule.validSession({instance_id:'fake',schema_version:1})&&!mainModule.validSession({instance_id:I,schema_version:2}));
  const request={schema_version:1,instance_id:I,operation_id:O,expected_topology_revision:null,operation:'events.wait',params:{after_event_seq:0,wait_ms:0}};
  const event=data=>({event_seq:1,observed_at:'2026-09-26T00:00:00Z',data});
  const run={run_id:R,pane_id:B,process:'running',work:'unknown',evidence:'unavailable',observed_at:'2026-09-26T00:00:00Z',current:true,exit_code:null};
  const operation={operation_id:O,phase:'completed',outcome:'succeeded',error_code:null};
  const response=data=>({schema_version:1,instance_id:I,operation_id:O,accepted:true,topology_revision:1,event_seq:1,result:{operation:'events.wait',data},error:null});
  for(const data of [{kind:'topology_changed',pane_id:B,project_id:P,topology_revision:1},{kind:'run_state_changed',run},{kind:'operation_state_changed',operation},{kind:'connection_state_changed',connection_id:O,state:'granted'}])check('closed canonical event '+data.kind,mainModule.validReadResponse(request,response({events:[event(data)],next_event_seq:1,status:'events'})));
  for(const changed of [{run:{}},{run:{...run,extra:true}},{run:{...run,observed_at:'2026-02-30T00:00:00Z'}},{run:{...run,work:'succeeded'}},{run:{...run,exit_code:0}},{run:{...run,process:'unknown',evidence:'process_exit'}},{run:{...run,run_id:'fake'}}])check('nested run event denies '+JSON.stringify(changed),!mainModule.validReadResponse(request,response({events:[event({kind:'run_state_changed',...changed})],next_event_seq:1,status:'events'})));
  for(const changed of [{operation:{}},{operation:{...operation,extra:true}},{operation:{...operation,phase:'unknown'}},{operation:{...operation,outcome:'failed',error_code:'constructor'}},{operation:{...operation,outcome:'failed',error_code:null}},{operation:{...operation,error_code:'target_not_found'}}])check('nested operation event denies '+JSON.stringify(changed),!mainModule.validReadResponse(request,response({events:[event({kind:'operation_state_changed',...changed})],next_event_seq:1,status:'events'})));
  check('event gap may carry valid canonical events',mainModule.validReadResponse(request,response({events:[event({kind:'run_state_changed',run})],next_event_seq:1,status:'gap'})));
  for(const changed of [{instance_id:O},{operation_id:I},{accepted:false,error:{}},{schema_version:2},{topology_revision:-1},{result:{operation:'output.read',data:{}}}])check('read envelope denies '+JSON.stringify(changed),!mainModule.validReadResponse(request,{...response({events:[],next_event_seq:0,status:'no_change'}),...changed}));
  return passed;
 },{outputs,expression,registeredCommands});checks.push(...passed);

 const creationProof=await page.evaluate(async outputs=>{
  const creation=await import(URL.createObjectURL(new Blob([outputs['startup-secondary-create']],{type:'text/javascript'}))),locationModule=await import(URL.createObjectURL(new Blob([outputs['startup-location']],{type:'text/javascript'})));
  const passed=[],assert={equal(a,b){if(a!==b)throw Error('production value mismatch '+JSON.stringify({a,b}));},strictEqual(a,b){if(a!==b)throw Error('reference mismatch');},async rejects(fn){let rejected=false;try{await fn;}catch{rejected=true;}if(!rejected)throw Error('expected rejection');}};
  const assertTruthy=condition=>{if(!condition)throw Error('required fact missing');};
  const asyncTest=async(name,fn)=>{await fn();passed.push('actual creation module '+name);};
  const caller={label:'main',href:'https://tauri.localhost/',origin:'https://tauri.localhost'},editor={mode:'editor',path:'file.ts',worktree:'',summary:'fixture',origin:'context',modified:false,content:'snapshot'},nativeEditor={...editor};delete nativeEditor.content;
  function* orders(list){if(!list.length){yield [];return;}for(let i=0;i<list.length;i++)for(const rest of orders([...list.slice(0,i),...list.slice(i+1)]))yield [list[i],...rest];}
  function mountFixture(invokeOverride=null,payload=editor){let seq=0;const state={...caller,active:true,mounted:true,epoch:1,session:{instance_id:'00000000-0000-4000-8000-000000000011',schema_version:1},generation:'00000000-0000-4000-8000-000000000012'},values=new Map(),callbacks=new Map(),stats={invoke:0,submit:0,remove:0};const mount=creation.createSecondaryMount({current:()=>state,invoke:()=>{stats.invoke++;return invokeOverride?invokeOverride():{additional_browser_args:null};},construct:(o,c)=>{stats.submit++;callbacks.set(o.label,c);},storage:{localArea:localStorage,get:k=>values.get(k)??null,put:(k,v)=>values.set(k,v),removeIfSame(k,v){if(values.get(k)===v){values.delete(k);stats.remove++;return 'removed_exact';}return 'superseded';}},allocate:()=> '00000000-0000-4000-8000-'+String(++seq).padStart(12,'0')});mount.activate();const rawObserve=mount.observeStorage;mount.observeStorage=event=>{const area=event.storageArea===values||event.storageArea===localStorage?localStorage:event.storageArea===null?null:event.storageArea===undefined?undefined:sessionStorage;const candidate={...event,storageArea:area};const valid=area!==undefined&&typeof candidate.url==='string'&&(typeof candidate.key==='string'||candidate.key===null)&&(typeof candidate.oldValue==='string'||candidate.oldValue===null)&&(typeof candidate.newValue==='string'||candidate.newValue===null);rawObserve(valid?new StorageEvent('storage',candidate):candidate);};return {state,values,callbacks,stats,mount,facade:mount.facade,request:()=>({session:structuredClone(state.session),generation:state.generation,payload}),change(){state.epoch++;state.session={instance_id:'00000000-0000-4000-8000-000000000021',schema_version:1};state.generation='00000000-0000-4000-8000-000000000022';}};}
function mountConsume(f,r,field){const key=r.key+(field==='payload'?'':field==='intent'?'.read-intent':'.creation-request'),oldValue=f.values.get(key);f.values.delete(key);f.mount.observeStorage({storageArea:null,key,oldValue,newValue:null,url:new URL('index.html?popout=1&popout-key='+encodeURIComponent(r.key),caller.href).href});}
function mountChildEvent(r,captured,phase='ready'){return {storageArea:null,key:r.key+'.creation-outcome',url:new URL('index.html?popout=1&popout-key='+encodeURIComponent(r.key),caller.href).href,oldValue:null,newValue:JSON.stringify({request_id:r.requestId,label:r.label,key:r.key,session:captured.session,generation:captured.generation,phase})};}
function mountChild(f,r,captured,phase='ready'){const event=mountChildEvent(r,captured,phase);f.values.set(event.key,event.newValue);f.mount.observeStorage(event);f.values.delete(event.key);f.mount.observeStorage({...event,oldValue:event.newValue,newValue:null});}
let mountOrderingScenarios=0;
await asyncTest('same normal facade preserves old submitted request through reconnect and all late SDK/storage orders',async()=>{for(const order of orders(['sdk','payload','metadata','ready'])){const f=mountFixture(),facade=f.facade,oldRequest=f.request(),old=await facade.openSecondarySurface(oldRequest);f.mount.beginReconnect();assert.equal(facade.inspectSecondarySurface(old.requestId).outcome,'unconfirmed');await assert.rejects(facade.openSecondarySurface(oldRequest));f.change();f.mount.activate();const next=await facade.openSecondarySurface(f.request());assert.strictEqual(f.facade,facade);assert.equal(facade.inspectSecondarySurface(old.requestId).parentInvalidated,true);assert.equal(facade.inspectSecondarySurface(next.requestId).parentInvalidated,false);for(const step of order){if(step==='sdk')f.callbacks.get(old.label).sdkAck();else if(step==='ready')mountChild(f,old,oldRequest);else mountConsume(f,old,step);}assert.equal(facade.inspectSecondarySurface(old.requestId).outcome,'established');assert.equal(facade.inspectSecondarySurface(next.requestId).outcome,'unconfirmed');assert.equal(facade.inspectSecondarySurface(next.requestId).parentInvalidated,false);assert.equal(f.stats.remove,0);assert.equal(f.stats.submit,2);mountOrderingScenarios++;}});
await asyncTest('stable facade pending old policy cannot submit into replacement owner',async()=>{let release,first=true;const f=mountFixture(()=>first?(first=false,new Promise(r=>{release=r;})):{additional_browser_args:null}),facade=f.facade,p=facade.openSecondarySurface(f.request());await Promise.resolve();f.mount.beginReconnect();f.change();f.mount.activate();release({additional_browser_args:null});let oldReceipt;try{await p;}catch(e){oldReceipt=e.receipt;}assertTruthy(oldReceipt);assert.equal(facade.inspectSecondarySurface(oldReceipt.requestId).outcome,'failed_before_submit');assert.equal(f.stats.submit,0);const next=await facade.openSecondarySurface(f.request());assert.equal(facade.inspectSecondarySurface(next.requestId).submitted,true);assert.equal(f.stats.submit,1);});
await asyncTest('late old-session report binds to old request, never current session and never newer request',async()=>{const f=mountFixture(),facade=f.facade,oldRequest=f.request(),old=await facade.openSecondarySurface(oldRequest);f.mount.beginReconnect();f.change();f.mount.activate();const next=await facade.openSecondarySurface(f.request());mountConsume(f,old,'payload');mountConsume(f,old,'metadata');mountChild(f,old,f.request());assert.equal(facade.inspectSecondarySurface(old.requestId).outcome,'unconfirmed');assert.equal(facade.inspectSecondarySurface(next.requestId).conflict,false);assert.equal(f.stats.remove,0);});
await asyncTest('current owner disposal does not discard older request; same facade reads both and rejects new submit',async()=>{const f=mountFixture(),facade=f.facade,oldRequest=f.request(),old=await facade.openSecondarySurface(oldRequest);f.mount.beginReconnect();f.change();f.mount.activate();const next=await facade.openSecondarySurface(f.request());f.mount.dispose();await assert.rejects(facade.openSecondarySurface(f.request()));f.callbacks.get(old.label).sdkError();assert.equal(facade.inspectSecondarySurface(old.requestId).sdk,'error');assert.equal(facade.inspectSecondarySurface(next.requestId).sdk,'pending');assert.equal(facade.inspectSecondarySurface(next.requestId).parentInvalidated,true);assert.equal(facade.inspectSecondarySurface('unknown'),null);assert.equal(f.stats.remove,0);});

for(const row of [null,{project_id:'00000000-0000-4000-8000-000000000033',path:null,root_state:'verified'},{project_id:'00000000-0000-4000-8000-000000000033',path:'',root_state:'verified'},{project_id:'00000000-0000-4000-8000-000000000033',path:'C:/fixture',root_state:'unknown'},{project_id:'invalid',path:'C:/fixture',root_state:'verified'}])await asyncTest('selected source ProjectSummary denied before policy/publication/submit '+JSON.stringify(row),async()=>{const f=mountFixture(null,nativeEditor);f.state.selectedProject=row;await assert.rejects(f.facade.openSecondarySurface(f.request()));assert.equal(f.stats.submit,0);assert.equal(f.values.size,0);assert.equal(f.stats.remove,0);});
let rawOrderingScenarios=0;
for(const sdk of ['ack','error'])await asyncTest('raw StorageEvent same-facade full SDK/consume/outcome/reconnect order family '+sdk,async()=>{for(const order of orders(['sdk','payload','intent','metadata','ready','reconnect'])){const f=mountFixture(null,nativeEditor);f.state.selectedProject={project_id:'00000000-0000-4000-8000-000000000033',path:'C:/fixture',root_state:'verified'};const captured=f.request(),r=await f.facade.openSecondarySurface(captured);for(const step of order){if(step==='sdk')sdk==='ack'?f.callbacks.get(r.label).sdkAck():f.callbacks.get(r.label).sdkError();else if(step==='ready')mountChild(f,r,captured);else if(step==='reconnect'){f.mount.beginReconnect();f.change();f.mount.activate();}else mountConsume(f,r,step);}const result=f.facade.inspectSecondarySurface(r.requestId);assert.equal(result.outcome,'established');assert.equal(result.parentInvalidated,true);assert.equal(f.stats.remove,0);assert.equal(f.values.size,0);rawOrderingScenarios++;}});
const rawDecisionCases=[
 ['local clear',()=>({storageArea:null,key:null,oldValue:null,newValue:null,url:caller.href}),'conflict'],
 ['other area clear',()=>({storageArea:{},key:null,oldValue:null,newValue:null,url:caller.href}),'ignore'],
 ['missing area',()=>({key:null,oldValue:null,newValue:null,url:caller.href}),'conflict'],
 ['unknown key',()=>({storageArea:null,key:'unrelated',oldValue:'a',newValue:'b',url:caller.href}),'ignore'],
 ['outcome wrong source',(f,r,c)=>({...mountChildEvent(r,c),url:caller.href}),'conflict'],
 ['outcome malformed',(f,r,c)=>({...mountChildEvent(r,c),newValue:'invalid'}),'conflict'],
 ['outcome absent both',(f,r,c)=>({...mountChildEvent(r,c),newValue:null}),'conflict'],
 ['outcome remove without observed write',(f,r,c)=>{const e=mountChildEvent(r,c,'failed');return {...e,oldValue:e.newValue,newValue:null};},'conflict'],
 ['outcome extra key',(f,r,c)=>{const e=mountChildEvent(r,c);return {...e,newValue:JSON.stringify({...JSON.parse(e.newValue),extra:true})};},'conflict'],
 ['outcome same fields different raw remove',(f,r,c)=>{const e=mountChildEvent(r,c);return {...e,oldValue:JSON.stringify(JSON.parse(e.newValue),null,2),newValue:null};},'conflict'],
 ['outcome nonstring',(f,r,c)=>({...mountChildEvent(r,c),newValue:{}}),'conflict'],
 ['outcome replacement',(f,r,c)=>({...mountChildEvent(r,c),oldValue:'other'}),'conflict'],
 ['outcome wrong session',(f,r,c)=>mountChildEvent(r,{...c,session:{instance_id:'00000000-0000-4000-8000-000000000099',schema_version:1}}),'conflict'],
 ['outcome wrong generation',(f,r,c)=>mountChildEvent(r,{...c,generation:'00000000-0000-4000-8000-000000000099'}),'conflict'],
 ['consumption wrong source',(f,r)=>({storageArea:null,key:r.key,url:caller.href,oldValue:f.values.get(r.key),newValue:null}),'conflict'],
 ['consumption wrong old',(f,r)=>({storageArea:null,key:r.key,url:mountChildEvent(r,f.request()).url,oldValue:'other',newValue:null}),'conflict'],
 ['consumption replacement',(f,r)=>({storageArea:null,key:r.key,url:mountChildEvent(r,f.request()).url,oldValue:f.values.get(r.key),newValue:'replacement'}),'conflict'],
 ['consumption ABA write',(f,r)=>({storageArea:null,key:r.key,url:mountChildEvent(r,f.request()).url,oldValue:null,newValue:f.values.get(r.key)}),'conflict'],
 ['consumption bad url',(f,r)=>({storageArea:null,key:r.key,url:null,oldValue:f.values.get(r.key),newValue:null}),'conflict'],
 ['non-owned reserved intent',(f,r)=>({storageArea:null,key:r.key+'.read-intent',url:mountChildEvent(r,f.request()).url,oldValue:null,newValue:'other'}),'conflict'],
 ['other area own key',(f,r,c)=>({...mountChildEvent(r,c),storageArea:{}}),'ignore'],
 ['local object identity',(f,r,c)=>({...mountChildEvent(r,c),storageArea:f.values}),'ready'],
 ['null area valid',(f,r,c)=>mountChildEvent(r,c),'ready']
];
for(const [name,event,expected] of rawDecisionCases)for(const when of ['before','after','reconnected'])await asyncTest('raw storage decision through same facade '+name+'/'+when,async()=>{const f=mountFixture(),captured=f.request(),r=await f.facade.openSecondarySurface(captured);mountConsume(f,r,'payload');mountConsume(f,r,'metadata');if(when==='after')mountChild(f,r,captured);if(when==='reconnected'){f.mount.beginReconnect();f.change();f.mount.activate();}const e=event(f,r,captured);f.mount.observeStorage(e);mountChild(f,r,captured);const result=f.facade.inspectSecondarySurface(r.requestId);assert.equal(result.conflict,expected==='conflict');assert.equal(result.established,when==='after'||expected!=='conflict');assert.equal(result.outcome,expected==='conflict'?(when==='after'?'established_with_observation_conflict':'unconfirmed'):'established');assert.equal(f.stats.remove,0);});
for(const phase of ['ready','failed','closed'])await asyncTest('raw outcome write/remove and duplicate facts preserve terminal '+phase,async()=>{const f=mountFixture(),c=f.request(),r=await f.facade.openSecondarySurface(c);mountConsume(f,r,'payload');mountConsume(f,r,'metadata');const e=mountChildEvent(r,c,phase);f.mount.observeStorage(e);f.mount.observeStorage({...e,oldValue:e.newValue,newValue:null});f.mount.observeStorage(e);f.mount.observeStorage({...e,oldValue:e.newValue,newValue:null});const result=f.facade.inspectSecondarySurface(r.requestId);assert.equal(result.conflict,false);assert.equal(result.outcome,phase==='ready'?'established':'child_terminal_not_success');assert.equal(f.stats.remove,0);});
await asyncTest('raw clear delivered to both retained old and current request without parent effects',async()=>{const f=mountFixture(),a=await f.facade.openSecondarySurface(f.request());f.mount.beginReconnect();f.change();f.mount.activate();const c=f.request(),b=await f.facade.openSecondarySurface(c);f.mount.observeStorage({storageArea:f.values,key:null,oldValue:null,newValue:null,url:caller.href});for(const r of [a,b]){mountConsume(f,r,'payload');mountConsume(f,r,'metadata');}mountChild(f,b,c);assert.equal(f.facade.inspectSecondarySurface(a.requestId).conflict,true);assert.equal(f.facade.inspectSecondarySurface(b.requestId).outcome,'unconfirmed');assert.equal(f.stats.remove,0);assert.equal(f.stats.submit,2);});
await asyncTest('actual capture/gateway consumes once and child normal outcome leaves no storage',async()=>{const f=mountFixture(null,nativeEditor);f.state.selectedProject={project_id:'00000000-0000-4000-8000-000000000033',path:'C:/fixture',root_state:'verified'};const c=f.request(),r=await f.facade.openSecondarySurface(c),url=mountChildEvent(r,c).url;let removals=0;const storage={getItem:k=>f.values.get(k)??null,setItem(k,value){const oldValue=f.values.get(k)??null;f.values.set(k,value);f.mount.observeStorage({storageArea:localStorage,key:k,url,oldValue,newValue:value});},removeItem(k){const oldValue=f.values.get(k)??null;f.values.delete(k);removals++;f.mount.observeStorage({storageArea:localStorage,key:k,url,oldValue,newValue:null});}};const got=locationModule.captureSecondaryRoute(true,r.label,url,storage,()=>()=>{});assert.equal(got.route.kind,'secondary');assertTruthy(got.capture.intent);assert.equal(got.capture.intent.project_dir,'C:/fixture');assert.equal(got.capture.current(),true);got.capture.report('ready');assert.equal(f.facade.inspectSecondarySurface(r.requestId).outcome,'established');assert.equal(f.values.size,0);assert.equal(removals,4);got.capture.report('ready');assert.equal(removals,4);got.capture.dispose();assert.equal(got.capture.current(),false);assert.equal(f.stats.remove,0);});


let rawConflictOrderingScenarios=0;
for(const sdk of ['ack','error'])await asyncTest('raw clear conflict persists in full consume/outcome/reconnect order family '+sdk,async()=>{for(const order of orders(['clear','payload','intent','metadata','ready','reconnect'])){const f=mountFixture(null,nativeEditor);f.state.selectedProject={project_id:'00000000-0000-4000-8000-000000000033',path:'C:/fixture',root_state:'verified'};const c=f.request(),r=await f.facade.openSecondarySurface(c);sdk==='ack'?f.callbacks.get(r.label).sdkAck():f.callbacks.get(r.label).sdkError();let readyBeforeClear=false;for(const step of order){if(step==='clear'){readyBeforeClear=f.facade.inspectSecondarySurface(r.requestId).established;f.mount.observeStorage({storageArea:f.values,key:null,url:caller.href,oldValue:null,newValue:null});}else if(step==='ready')mountChild(f,r,c);else if(step==='reconnect'){f.mount.beginReconnect();f.change();f.mount.activate();}else mountConsume(f,r,step);}const result=f.facade.inspectSecondarySurface(r.requestId);assert.equal(result.conflict,true);assert.equal(result.established,readyBeforeClear);assert.equal(result.outcome,readyBeforeClear?'established_with_observation_conflict':'unconfirmed');assert.equal(f.stats.remove,0);assert.equal(f.stats.submit,1);rawConflictOrderingScenarios++;}});

await asyncTest('raw clear while policy pending stops publication and submit, terminal failure stays original',async()=>{let release;const f=mountFixture(()=>new Promise(r=>{release=r;})),pending=f.facade.openSecondarySurface(f.request());await Promise.resolve();f.mount.observeStorage({storageArea:f.values,key:null,oldValue:null,newValue:null,url:caller.href});release({additional_browser_args:null});let receipt;try{await pending;}catch(e){receipt=e.receipt;}assertTruthy(receipt);assert.equal(receipt.outcome,'failed_before_submit');assert.equal(receipt.conflict,true);assert.equal(f.values.size,0);assert.equal(f.stats.submit,0);f.mount.observeStorage({storageArea:f.values,key:null,oldValue:null,newValue:null,url:caller.href});assert.equal(f.facade.inspectSecondarySurface(receipt.requestId).outcome,'failed_before_submit');});

  const f=globalThis.fixture;let release,reject;f.sdkPromise=new Promise((a,b)=>{release=a;reject=b;});
  let ack=0,error=0,observer=0;
  creation.constructSecondary({label:'secondary-surface-00000000-0000-4000-8000-000000000001',url:'index.html?popout=1&popout-key=winsmux.popout-surface.00000000-0000-4000-8000-000000000001',visible:false},{sdkAck(){ack++;},sdkError(){error++;},observerFailure(){observer++;}});
  assert.equal(ack,0);assert.equal(f.sdkOptions.visible,false);release();await new Promise(r=>setTimeout(r,0));assert.equal(ack,1);assert.equal(error,0);assert.equal(observer,0);
  f.sdkPromise=new Promise((a,b)=>{release=a;reject=b;});creation.constructSecondary({label:'secondary-surface-00000000-0000-4000-8000-000000000002',url:'index.html?popout=1&popout-key=winsmux.popout-surface.00000000-0000-4000-8000-000000000002',visible:false},{sdkAck(){ack++;},sdkError(){error++;},observerFailure(){observer++;}});reject(Error('fixture closed failure'));await new Promise(r=>setTimeout(r,0));assert.equal(error,1);assert.equal(ack,1);assert.equal(observer,0);delete f.sdkPromise;
  passed.push('actual installed SDK async constructor not promoted from return and exact ACK/error hooks');
  return{passed,rawOrderingScenarios,rawConflictOrderingScenarios,mountOrderingScenarios,storageEventClass:true};
 },outputs);
 checks.push(...creationProof.passed);

 // Fresh page per production mount: callbacks and DOM remain attributable to one role.
 await page.setContent(html);
 const mounted=await page.evaluate(async ({code,editor})=>{const raf=globalThis.requestAnimationFrame;globalThis.requestAnimationFrame=fn=>{queueMicrotask(()=>fn(0));return 1};const f=globalThis.fixture,shown=f.shows;f.secondaryContext();f.calls=[];const prefs=JSON.stringify({theme:'dark',workerInputEnabled:true,voice:true,runtime:'legacy'});localStorage.setItem('winsmux.shell.preferences.v1',prefs);const unrelated=JSON.stringify({x:'preserved'});localStorage.setItem('winsmux.test.unrelated',unrelated);const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));const mount=await module.mountSecondarySurface(editor);window.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'}));window.dispatchEvent(new Event('resize'));const result={readonly:document.querySelector('#editor-code').getAttribute('aria-readonly')==='true',text:document.querySelector('#editor-code').textContent,old:!!document.querySelector('#composer'),calls:f.calls,storage:localStorage.getItem('winsmux.shell.preferences.v1')===prefs&&localStorage.getItem('winsmux.test.unrelated')===unrelated,terminals:f.terminals.length,shows:f.shows-shown};mount.dispose();globalThis.requestAnimationFrame=raf;return result;},{code:outputs['startup-secondary'],editor:{mode:'editor',path:'日本語.ts',worktree:'',summary:'fixture',origin:'explorer',modified:false,content:'日本語\r\nconst x = 1;'}});
 if(!mounted.readonly||!mounted.text.includes('日本語')||mounted.old||mounted.calls.length!==1||mounted.calls[0].name!=='startup_secondary_request'||JSON.parse(mounted.calls[0].args.requestJson).kind!=='show'||!mounted.storage||mounted.terminals||mounted.shows!==1)throw Error('Actual secondary snapshot effect isolation');checks.push('production secondary snapshot readonly render and one firstpaint show; key/resize/storage effects absent');
 await page.setContent('<main id="workspace-startup"></main>');
 console.log(JSON.stringify({fixture_stage:'main-mount'}));
 const main=await page.evaluate(async code=>{const f=globalThis.fixture;f.native=true;f.label='main';f.initial=f.root;f.calls=[];f.frames=[];const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));const promise=module.mountWorkspaceMain(document.querySelector('main'));const mount=await f.awaitMount(promise);for(let n=0;n<12;n++)await new Promise(resolve=>setTimeout(resolve,0));const root=document.querySelector('main');const before={state:root.dataset.startupState,outcome:root.dataset.initialOutcome,created:root.dataset.initialCreated,session:root.dataset.session,shows:f.shows,calls:structuredClone(f.calls),frames:f.frames.length};f.listeners.get('workspace-close-refused')?.();const retained=root.dataset.startupState==='mounted';const secondaryRequest={session:JSON.parse(root.dataset.session),generation:root.dataset.generation,payload:{mode:'editor',path:'normal.ts',worktree:'',summary:'fixture',origin:'context',modified:false,content:'normal facade'}};const owned=await root.openSecondarySurface(secondaryRequest);const sameFacade=root.inspectSecondarySurface;const beforeDispose=sameFacade(owned.requestId);mount.dispose();const afterDispose=sameFacade(owned.requestId);if(!owned.submitted||beforeDispose.outcome!=='unconfirmed'||!afterDispose.parentInvalidated||globalThis.fixture.sdkOptions.label!==owned.label)throw Error('normal mount facade creator lifetime');localStorage.removeItem(owned.key);localStorage.removeItem(owned.key+'.creation-request');const after={state:root.dataset.startupState,listeners:f.listeners.size};return{before,retained,after};},outputs['startup-mount']);
 const names=main.before.calls.map(c=>c.name),ops=main.before.calls.filter(c=>c.name==='workspace_request').map(c=>JSON.parse(c.args.requestJson).operation);
 if(main.before.state!=='mounted'||main.before.outcome!=='completed'||main.before.created!=='false'||names.filter(n=>n==='workspace_session_open').length!==1||ops.filter(n=>n==='project.open').length!==1||ops.includes('pane.create')||ops.includes('shell.launch')||!main.retained||main.after.state!=='disposed'||main.after.listeners)throw Error('Production main restoration/lifetime invariant');checks.push('production main real controller fixture: one open session, explicit same-ticket folder, existing no launch, close refusal retains, actual dispose releases');
 console.log(JSON.stringify({fixture_stage:'terminal-output'}));
 const terminalChecks=await page.evaluate(async code=>{
  const passed=[],check=(n,ok)=>{if(!ok)throw Error(n);passed.push(n)},f=globalThis.fixture;
  const observers=[];globalThis.ResizeObserver=class{constructor(fn){this.fn=fn;observers.push(this)}observe(){}disconnect(){this.disconnected=true}};
  const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));const slot=document.createElement('div');document.body.append(slot);
  let snapshot={instanceId:'instance',generation:'generation',topologyRevision:7,availability:'available',busy:false,projects:{selected_project_id:'project'},panes:{project_id:'project',panes:[{pane_id:'pane',current_run_id:'R1'}]}};const resized=[];
  const terminal=module.mountProjectPaneTerminal(slot,'project','pane',{snapshot:()=>snapshot,resize:value=>{resized.push(value);return false}});const instance=f.terminals.at(-1),target=terminal.readTarget();
  terminal.append(target,{run_id:'R1',text:'one',next_cursor:'c1',gap:true,truncated:false});check('terminal exact cursor and gap explicit',slot.textContent==='one'&&terminal.readTarget().cursor==='c1'&&slot.previousElementSibling.textContent.includes('取得'));
  snapshot.panes.panes[0].current_run_id='R2';terminal.append(target,{run_id:'R1',text:'old',next_cursor:'old',gap:false,truncated:false});check('terminal R1 late reply never reaches R2',slot.textContent===''&&terminal.readTarget().runId==='R2'&&terminal.readTarget().cursor===null);
  instance.rows=1;instance.cols=32767;instance.resize();terminal.flushResize();terminal.flushResize();check('captured boundary resize once even rejected',resized.length===1&&resized[0].runId==='R2'&&resized[0].rows===1&&resized[0].cols===32767);
  for(const value of [0,32768,1.5]){instance.rows=value;instance.resize();terminal.flushResize()}check('terminal invalid dimensions no resize',resized.length===1);
  snapshot.busy=true;instance.rows=24;instance.cols=80;instance.resize();instance.cols=100;instance.resize();terminal.flushResize();check('busy coalesces only unadmitted dimensions',resized.length===1);snapshot.busy=false;terminal.flushResize();check('coalesced captured dimensions admitted once',resized.length===2&&resized[1].cols===100);
  snapshot.busy=true;instance.cols=120;instance.resize();snapshot.generation='replacement';snapshot.busy=false;terminal.flushResize();check('queued old generation resize discarded',resized.length===2);
  const late=terminal.readTarget();terminal.dispose();terminal.append(late,{run_id:'R2',text:'late',next_cursor:'late',gap:false,truncated:false});terminal.flushResize();check('terminal disposal releases observer callback and effects',observers[0].disconnected&&instance.disposed&&instance.resize===null&&resized.length===2&&slot.textContent==='');check('terminal stdin disabled input responsibility stays separate',instance.options.disableStdin===true);
  return passed;
 },outputs['project-pane-terminal']);checks.push(...terminalChecks);
  console.log(JSON.stringify({fixture_stage:'entry'}));
for(const ready of ['loading','complete']){
  await page.setContent(html);
  const once=await page.evaluate(async ({code,ready})=>{const f=globalThis.fixture;f.calls=[];f.frames=[];f.initial=null;f.selected=null;Object.defineProperty(document,'readyState',{configurable:true,get:()=>ready});await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));document.dispatchEvent(new Event('DOMContentLoaded'));document.dispatchEvent(new Event('DOMContentLoaded'));while(!f.frames.length)await new Promise(resolve=>setTimeout(resolve,0));f.frames.shift()(0);for(let n=0;n<12;n++)await new Promise(resolve=>setTimeout(resolve,0));return f.calls.filter(c=>c.name==='workspace_session_open').length;},{code:outputs['startup-entry'],ready});
  if(once!==1)throw Error('Entry duplicated boot '+ready);checks.push('production entry '+ready+' starts once after duplicate ready events');
 }
 const readonlyChecks=await page.evaluate(async ({code,html})=>{
  const raf=globalThis.requestAnimationFrame;globalThis.requestAnimationFrame=fn=>{queueMicrotask(()=>fn(0));return 1};
  const passed=[],check=(n,ok)=>{if(!ok)throw Error(n);passed.push(n)},f=globalThis.fixture,module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));
  f.secondaryContext();
  const restore=()=>{document.documentElement.innerHTML=html.replace(/<!doctype[^>]*>/i,'').replace(/<html[^>]*>|<\/html>/g,'');};
  const editor={mode:'editor',path:'read.ts',worktree:'C:/fixture/root/worktree',summary:'fixture',origin:'context',modified:true};
  const kinds=()=>f.calls.map(c=>c.name==='startup_secondary_request'?JSON.parse(c.args.requestJson).kind:c.name);
  const setRoot=()=>{localStorage.setItem('winsmux.active-project.v1','C:/fixture/root');localStorage.setItem('winsmux.project-sessions.v1',JSON.stringify([{path:'C:/fixture/root',name:'root',lastSeenAt:1}]));};
  const response=(content='日本語\r\nconst x = 1;')=>({project_dir:'C:/fixture/root',worktree:editor.worktree,file:{path:'read.ts',content,line_count:Math.max(1,content.split('\n').length-(content.endsWith('\n')?1:0)),truncated:false}});
  localStorage.removeItem('winsmux.active-project.v1');localStorage.removeItem('winsmux.project-sessions.v1');restore();f.calls=[];
  let mounted=await module.mountSecondarySurface(editor);check('secondary absent root invokes no disk read',kinds().join(',')==='show');mounted.dispose();
  setRoot();restore();f.calls=[];mounted=await module.mountSecondarySurface(editor);check('native readonly supported response validates and renders',kinds().join(',')==='editor-read,show'&&document.querySelector('#editor-code').textContent.includes('日本語'));mounted.dispose();
  const original=f.invoke;
  for(const boundary of ['changed-root','ABA-active','ABA-sessions','clear','disposed']){
   setRoot();restore();f.calls=[];let reply;
   f.invoke=(name,args)=>{if(name==='startup_secondary_request'&&JSON.parse(args.requestJson).kind==='editor-read'){f.calls.push({name,args});return new Promise(resolve=>{reply=resolve})}return original(name,args)};
   const pending=module.mountSecondarySurface(editor);await Promise.resolve();const captured=structuredClone(f.calls);
   if(boundary==='changed-root')localStorage.setItem('winsmux.active-project.v1','C:/fixture/changed');
   else if(boundary==='disposed')window.dispatchEvent(new Event('unload'));
   else {const key=boundary==='ABA-active'?'winsmux.active-project.v1':boundary==='ABA-sessions'?'winsmux.project-sessions.v1':null;window.dispatchEvent(new StorageEvent('storage',{key,storageArea:localStorage}));}
   reply(response('late body forbidden'));mounted=await pending;
   const q=JSON.parse(captured[0]?.args.requestJson||'null');
   check('secondary captured readonly root never late retargets '+boundary,captured.length===1&&captured[0].name==='startup_secondary_request'&&q.kind==='editor-read'&&q.project_dir==='C:/fixture/root'&&q.worktree===editor.worktree&&!document.querySelector('#editor-code').textContent.includes('late body')&&kinds().join(',')===(boundary==='disposed'?'editor-read':'editor-read,show'));
   mounted.dispose();f.invoke=original;
  }
  const good=response();
  for(const [name,reply] of [['null',null],['extra',{...good,extra:true}],['root',{...good,project_dir:'C:/fixture/other'}],['worktree',{...good,worktree:null}],['path',{...good,file:{...good.file,path:'other.ts'}}],['content',{...good,file:{...good.file,content:1}}],['too-large',{...good,file:{...good.file,content:'x'.repeat(32769),line_count:1}}],['lines',{...good,file:{...good.file,line_count:3}}],['truncated',{...good,file:{...good.file,truncated:1}}],['file-extra',{...good,file:{...good.file,extra:true}}]]){
   setRoot();restore();f.calls=[];f.invoke=(command,args)=>{if(command==='startup_secondary_request'&&JSON.parse(args.requestJson).kind==='editor-read'){f.calls.push({name:command,args});return Promise.resolve(reply)}return original(command,args)};
   mounted=await module.mountSecondarySurface(editor);check('readonly response closed '+name,kinds().join(',')==='editor-read,show'&&document.querySelector('#editor-code').textContent==='Backend preview failed to load.');mounted.dispose();f.invoke=original;
  }
  for(const value of ['', '.', '..', '../read.ts','a/../read.ts','/read.ts','C:/read.ts','a//read.ts','read.ts.','CON','a/NUL.txt','x\u0000.ts'])check('relative read path rejects '+JSON.stringify(value),module.relativeReadPath(value)===null);
  for(const [input,expected] of [['read.ts','read.ts'],['a/read.ts','a/read.ts'],['a\\read.ts','a/read.ts'],['日本語.ts','日本語.ts']])check('relative read path supports '+input,module.relativeReadPath(input)===expected);
  restore();f.calls=[];const preview={mode:'preview',url:'http://127.0.0.1:3000/',portLabel:'3000',sourceLabel:'fixture',lastSeenAt:1};let opened=[],copied=[];window.open=(...args)=>{opened.push(args);return null};Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{copied.push(value)}}});
  mounted=await module.mountSecondarySurface(preview);check('preview mount has no owner or old effect',kinds().join(',')==='show'&&document.querySelector('#browser-frame').getAttribute('src')===preview.url&&!document.querySelector('#composer'));
  for(const id of ['browser-reload-btn','browser-copy-btn','browser-open-btn'])document.getElementById(id).click();await Promise.resolve();check('preview controls use captured URL only',copied.length===1&&copied[0]===preview.url&&opened.length===1&&opened[0][0]===preview.url&&opened[0][2]==='noopener');
  document.getElementById('browser-back-btn').click();check('preview back stays readonly empty surface',document.querySelector('#browser-frame').getAttribute('src')==='about:blank'&&!document.querySelector('#workspace-startup'));
  mounted.dispose();for(const id of ['browser-copy-btn','browser-open-btn'])document.getElementById(id).click();await Promise.resolve();check('disposed preview controls have no effects',opened.length===1&&copied.length===1&&kinds().join(',')==='show');
  globalThis.requestAnimationFrame=raf;return passed;
 },{code:outputs['startup-secondary'],html});checks.push(...readonlyChecks);
 await page.setContent('<main id="workspace-startup"></main>');
 console.log(JSON.stringify({fixture_stage:'launcher'}));
 const launcherChecks=await page.evaluate(async ({code,expression})=>{
  const passed=[],check=(n,ok)=>{if(!ok)throw Error(n);passed.push(n)},f=globalThis.fixture;f.native=true;f.label='main';f.initial=f.root;f.frames=[];f.calls=[];
  window.__TAURI__={core:{invoke:(name,args)=>f.invoke(name,args)}};window.__TAURI_INTERNALS__={metadata:{currentWindow:{label:'main'}}};
  const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));const pending=module.mountWorkspaceMain(document.querySelector('main'));const mounted=await f.awaitMount(pending);for(let n=0;n<12;n++)await new Promise(resolve=>setTimeout(resolve,0));
  const root=document.querySelector('main'),view=root.querySelector('.workspace-project-pane');
  const observation=()=>eval(expression.replace('__EXPECTED_PATH__',JSON.stringify(f.root)));
  const callsBefore=f.calls.length,first=JSON.parse(await observation()),reads=f.calls.slice(callsBefore);
  check('actual launcher expression confirms existing empty canonical project',first.ok&&first.created===false&&first.project.project_id===root.dataset.initialProjectId&&first.runs.length===0);
  check('actual launcher expression sends readonly canonical requests only',reads.length===3&&reads.every(c=>c.name==='workspace_request'&&['capabilities.get','project.list','pane.list','run.get'].includes(JSON.parse(c.args.requestJson).operation)));
  const originals={session:root.dataset.session,availability:view.dataset.availability,revision:view.dataset.topologyRevision,generation:root.dataset.generation};
  for(const kind of ['unknown-label','missing-session','bad-session-shape','unknown-session','unavailable','old-revision','initial-refused']){
   const before=f.calls.length;
   if(kind==='unknown-label')window.__TAURI_INTERNALS__.metadata.currentWindow.label='secondary-surface-x';
   if(kind==='missing-session')delete root.dataset.session;
   if(kind==='bad-session-shape')root.dataset.session=JSON.stringify({...JSON.parse(originals.session),extra:true});
   if(kind==='unknown-session')root.dataset.session=JSON.stringify({instance_id:'99999999-9999-4999-8999-999999999999',schema_version:1});
   if(kind==='unavailable')view.dataset.availability='unavailable';
   if(kind==='old-revision')view.dataset.topologyRevision=String(f.revision-1);
   if(kind==='initial-refused')root.dataset.initialOutcome='refused';
   const result=JSON.parse(await observation());check('launcher false observation closed '+kind,!result.ok&&f.calls.slice(before).every(c=>c.name==='workspace_request'));
   window.__TAURI_INTERNALS__.metadata.currentWindow.label='main';root.dataset.session=originals.session;view.dataset.availability=originals.availability;view.dataset.topologyRevision=originals.revision;root.dataset.initialOutcome='completed';
  }
  const nativeInvoke=f.invoke;
  for(const kind of ['TransportUncertain','session_closed','shutdown_in_progress']){const before=f.calls.length;f.invoke=async(name,args)=>{f.calls.push({name,args});throw Error(kind)};const result=JSON.parse(await observation());check('launcher native '+kind+' never reopens owner',!result.ok&&f.calls.slice(before).every(c=>c.name==='workspace_request'));f.invoke=nativeInvoke;}
  f.invoke=async(name,args)=>{const response=await nativeInvoke(name,args);root.dataset.generation='replacement';return response};const result=JSON.parse(await observation());check('launcher generation exchange cannot become success',!result.ok);f.invoke=nativeInvoke;mounted.dispose();return passed;
 },{code:outputs['startup-mount'],expression});checks.push(...launcherChecks);
 await page.evaluate(()=>window.dispatchEvent(new Event('unload')));await page.setContent('<main id="workspace-startup"></main>');
 console.log(JSON.stringify({fixture_stage:'native-failure'}));
 const failure=await page.evaluate(async code=>{const f=globalThis.fixture,original=f.invoke,before=f.shows;f.calls=[];f.frames=[];f.invoke=async(name,args)=>{if(name==='startup_main_policy_ready'||name==='startup_main_show')return original(name,args);f.calls.push({name,args});throw Error('TransportUncertain')};const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));const pending=module.mountWorkspaceMain(document.querySelector('main'));const mount=await f.awaitMount(pending);const root=document.querySelector('main'),button=root.querySelector('button');const visible=root.dataset.startupState==='unconfirmed'&&!button.hidden&&f.shows-before===1;button.click();for(let n=0;n<12;n++)await new Promise(resolve=>setTimeout(resolve,0));const result={visible,shown:f.shows-before,calls:f.calls.map(c=>c.name)};mount.dispose();f.invoke=original;return result;},outputs['startup-mount']);
 if(!failure.visible||failure.shown!==1||failure.calls.filter(name=>name==='workspace_session_open').length!==2||failure.calls.filter(name=>name==='workspace_input_guard_register').length!==1||failure.calls.some(name=>!['startup_main_policy_ready','startup_main_show','workspace_session_open','workspace_input_guard_register','workspace_host_status'].includes(name)))throw Error('Unconfirmed session screen inaccessible or auto reopen');checks.push('main native session failure shows accessible unconfirmed/reconnect once; input binding registers once and failed open probes status read-only');
 const policyDenied=await page.evaluate(async code=>{const f=globalThis.fixture,original=f.invoke,before=f.shows;f.calls=[];f.invoke=(name,args)=>name==='startup_main_policy_ready'?Promise.reject(Error('accelerator_policy_unavailable')):original(name,args);const root=document.createElement('main');document.body.append(root);const module=await import(URL.createObjectURL(new Blob([code],{type:'text/javascript'})));let denied=false;try{await module.mountWorkspaceMain(root)}catch{denied=true}const result={denied,shows:f.shows-before,calls:f.calls.map(c=>c.name),children:root.childElementCount};root.remove();f.invoke=original;return result;},outputs['startup-mount']);
 if(!policyDenied.denied||policyDenied.shows!==0||policyDenied.calls.some(name=>name==='workspace_session_open')||policyDenied.children!==0)throw Error('Failed native accelerator policy must not mount or show main');checks.push('failed native accelerator policy does not mount workspace or show main');
 if(/workspace_session_open|workspace_force_exit|Stop-Process|Stop-RepoWinsmuxDesktopTree|remote-allow-origins/.test(launcher))throw Error('Launcher forbidden effect path');
 if(!launcher.includes("WINSMUX_DESKTOP_TEST_PROFILE'] = 'public-smoke'")||!launcher.includes('creationTicks')||!launcher.includes('CloseMainWindow()'))throw Error('Launcher gate/owned closure absent');checks.push('launcher source has readonly session consumption and exact-owned normal close');
 const guard=runner.indexOf("result: 'unsupported'");if(guard<0||guard>runner.indexOf('// 2. Load benchmark pack + manifest.'))throw Error('Runner effect guard ordering');checks.push('legacy runner unsupported guard precedes pack/readycheck/compose/capture');
} finally {await browser.close();}
for(const mode of ['workspace','unknown']){
 const result=spawnSync(process.execPath,['--import',pathToFileURL(preloadPath).href,resolve(app,'scripts/run-cli-bakeoff.mjs'),'--project-dir',evidence,'--dry-run'],{encoding:'utf8',env:{...process.env,WINSMUX_RUNNER_FIXTURE:mode}});
 const rows=result.stdout.split(/\r?\n/).filter(Boolean).map(line=>{try{return JSON.parse(line)}catch{return null}}).filter(Boolean);
 if(result.status!==3||!rows.some(row=>row.result==='unsupported')||!rows.some(row=>row.fixture==='offline-runner-boundary'&&row.evaluations===1))throw Error('Full old runner entry failed pre-effect unsupported '+mode+': '+result.stdout+result.stderr);
 checks.push('full legacy runner entry '+mode+' unsupported before readycheck/composer/PTy; one readonly classification');
 writeFileSync(resolve(evidence,'runner-'+mode+'.json'),JSON.stringify({mode,exit:result.status,rows,stderr:result.stderr},null,2)+'\n');
}
const sourceIdentities=[...inputs].filter(p=>p.startsWith('project:')).map(p=>{const relative=p.slice('project:'.length).slice(app.length+1);const file=existsSync(resolve(app,relative))?resolve(app,relative):resolve(source,relative);const bytes=readFileSync(file);return{file,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')}});
for(const relative of ['src-tauri/src/lib.rs','src-tauri/src/startup_secondary_native.rs']){const file=existsSync(resolve(app,relative))?resolve(app,relative):resolve(source,relative);const bytes=readFileSync(file);sourceIdentities.push({file,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});}
const receipt={registeredCommands,scope:'explicit offline production-module fixtures and source closure; no native or whole launcher success claimed',passed:checks.length,checks,command:[process.execPath,...process.argv.slice(1)],nodeVersion:process.version,sourceRoot:source,dependencyRoot:dependency,sources:[...inputs].sort(),sourceIdentities,scriptSha256:createHash('sha256').update(readFileSync(fileURLToPath(import.meta.url))).digest('hex')};
writeFileSync(resolve(evidence,'fixture-receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({scope:receipt.scope,passed:checks.length,receipt:resolve(evidence,'fixture-receipt.json'),scriptSha256:receipt.scriptSha256}));
