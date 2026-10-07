import { WebviewWindow } from '@tauri-apps/api/webviewWindow';
import { creationSession as session, strictUuid as uuid, startupLocationAllowed, validatePopoutPayload as validatePayload, type CreationSession, type ReadIntent } from './startup-location';

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const closed = (v: unknown, fields: string[]): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === fields.length && fields.every(k => Object.prototype.hasOwnProperty.call(v, k));
const defaults = '--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required';
export function validatePolicy(reply: unknown): Readonly<{ additional_browser_args: string | null }> {
  if (!closed(reply, ['additional_browser_args'])) throw Error('policy_invalid');
  const args = reply.additional_browser_args, prefix = defaults + ' --remote-debugging-port=';
  if (args === null) return Object.freeze({ additional_browser_args: null });
  if (typeof args !== 'string' || !args.startsWith(prefix)) throw Error('policy_invalid');
  const p = args.slice(prefix.length);
  if (!/^[1-9][0-9]*$/.test(p) || BigInt(p) < 1024n || BigInt(p) > 65535n) throw Error('policy_invalid');
  return Object.freeze({ additional_browser_args: args });
}
export type OwnerContext = Readonly<{ active: boolean; mounted: boolean; session: CreationSession; generation: string; epoch: number; label: string; href: string; origin: string; selectedProject: { project_id: string; path: string | null; root_state: string } | null }>;
type ConstructOptions = Readonly<{ label: string; url: string; visible: false; additionalBrowserArgs?: string }>;
type SDKCallbacks = { sdkAck(): void; sdkError(): void; observerFailure(): void; notify(event: StorageEvent): void };
type StoragePort = { localArea: Storage; get(key: string): string | null; put(key: string, value: string): void; removeIfSame(key: string, value: string): string | undefined };
export type MountDependencies = { current(): OwnerContext; invoke(): Promise<unknown>; construct(options: ConstructOptions, callbacks: SDKCallbacks): void; storage: StoragePort; allocate(sequence: number): string };
type OwnerDependencies = MountDependencies & { capture: OwnerContext; requests: Map<string, OwnedRequest> };
type OwnedRequest = { requestId: string; key: string; label: string; absolute: string; body: string; sidecar: string; metadataKey: string; metadataRaw: string; intentRaw: string | null; submitted: boolean; sdk: string; child: string; parentInvalidated: boolean; outcome: string; cleanup: Record<string,string>; consumption: { payload: string; metadata: string; intent: string }; conflict: boolean; established: boolean; observerFailure: boolean; reports: Set<string>; capturedSession: CreationSession; capturedGeneration: string; onNotify(e: StorageEvent): void };
type StorageFact = { kind: string; key: string | null; oldValue?: string | null; newValue?: string | null; sourceUrl?: string; value?: Record<string, unknown> };

export function constructSecondary(options: ConstructOptions, callbacks: SDKCallbacks) {
  const window = new WebviewWindow(options.label, { url: options.url, visible: false, ...(options.additionalBrowserArgs === undefined ? {} : { additionalBrowserArgs: options.additionalBrowserArgs }) });
  try {
    void window.once('tauri://created', () => callbacks.sdkAck()).catch(() => callbacks.observerFailure());
    void window.once('tauri://error', () => callbacks.sdkError()).catch(() => callbacks.observerFailure());
  } catch { callbacks.observerFailure(); }
}
export const requestSnapshot=(r: OwnedRequest)=>Object.freeze({requestId:r.requestId,label:r.label,key:r.key,submitted:r.submitted,sdk:r.sdk,consumption:{...r.consumption},child:r.child,parentInvalidated:r.parentInvalidated,outcome:r.outcome,established:r.established,observerFailure:r.observerFailure,cleanup:{...r.cleanup},conflict:r.conflict});
// The sole observation boundary consumes actual StorageEvent fields, never caller-classified facts.
export function classifyStorageEvent(event: StorageEvent, r: OwnedRequest, localArea: Storage): StorageFact | null {
 try{
  if(event.storageArea===undefined)return {kind:'mutation',key:null};
  if(event.storageArea!==null&&event.storageArea!==localArea)return null;
  if(event.key===null)return {kind:'mutation',key:null};
  if(![r.key,r.sidecar,r.metadataKey,r.key+'.creation-outcome'].includes(event.key))return null;
  if(!r.submitted)return {kind:'mutation',key:event.key};
  if(typeof event.url!=='string'||typeof event.oldValue!=='string'&&event.oldValue!==null||typeof event.newValue!=='string'&&event.newValue!==null)return {kind:'mutation',key:event.key};
  if(event.url!==r.absolute)return {kind:'mutation',key:event.key};
  if(event.key===r.key+'.creation-outcome'){
   // Both write and remove must carry a closed, matching report. Remove is not another child fact.
   const raw=event.newValue===null?event.oldValue:event.newValue;let value;try{value=raw === null ? null : JSON.parse(raw);}catch{return {kind:'mutation',key:event.key};}
   if(!closed(value,['request_id','label','key','session','generation','phase'])||value.request_id!==r.requestId||value.label!==r.label||value.key!==r.key||!same(value.session,r.capturedSession)||value.generation!==r.capturedGeneration||!['ready','failed','closed'].includes(value.phase as string))return {kind:'mutation',key:event.key};
   if(event.newValue===null)return {kind:'outcome_removed',key:event.key,value};
   if(event.oldValue!==null)return {kind:'mutation',key:event.key};
   return {kind:'child',key:event.key,value,sourceUrl:event.url};
  }
  if(event.key===r.sidecar&&r.intentRaw===null)return {kind:'mutation',key:event.key};
  return {kind:'consumed',key:event.key,oldValue:event.oldValue,newValue:event.newValue,sourceUrl:event.url};
 }catch{return {kind:'mutation',key:null};}
}
function createOwner({capture,current,invoke,construct,storage,allocate,requests}: OwnerDependencies){
 let disposed=false,sequence=0; let pending: Promise<Readonly<{ additional_browser_args: string | null }>> | null = null;const captured=structuredClone(capture),owned=new Set<string>();
 const alive=()=>{const now=current();return !disposed&&session(captured.session)&&uuid(captured.generation)&&now.active===true&&now.mounted===true&&same(now.session,captured.session)&&now.generation===captured.generation&&now.epoch===captured.epoch&&now.label==='main'&&now.href===captured.href&&now.origin===captured.origin&&startupLocationAllowed(now.label,now.href);};
 const policy=()=>{if(!alive())return Promise.reject(Error('stale'));if(!pending)pending=Promise.resolve().then(()=>{if(!alive())throw Error('stale');return invoke();}).then(reply=>{if(!alive())throw Error('stale');return validatePolicy(reply);});return pending;};
 const snapshot=requestSnapshot;
 const update=(r: OwnedRequest)=>{if(!r.submitted&&r.outcome==='failed_before_submit')return;if(!r.conflict&&r.child==='ready'&&r.consumption.payload==='exact'&&r.consumption.metadata==='exact'&&(r.intentRaw===null||r.consumption.intent==='exact'))r.established=true;if(r.established)r.outcome=r.conflict?'established_with_observation_conflict':r.child==='closed'?'established_child_terminal':'established';else if(r.conflict)r.outcome='unconfirmed';else if(r.child==='failed'||r.child==='closed')r.outcome='child_terminal_not_success';else if(r.submitted)r.outcome='unconfirmed';};
 const notification=(r: OwnedRequest,rawEvent: StorageEvent)=>{try{const event=classifyStorageEvent(rawEvent,r,storage.localArea);if(event===null)return;const kind=event.kind;if(kind==='mutation'){r.conflict=true;update(r);return;}if(kind==='outcome_removed'){if(!r.reports.has(rawEvent.oldValue!))r.conflict=true;update(r);return;}if(event.sourceUrl!==r.absolute){r.conflict=true;update(r);return;}
  if(kind==='consumed'){const which=event.key===r.key?'payload':event.key===r.metadataKey?'metadata':event.key===r.sidecar&&r.intentRaw!==null?'intent':null;if(!which)return;const expected=which==='payload'?r.body:which==='metadata'?r.metadataRaw:r.intentRaw;if(event.oldValue===expected&&event.newValue===null)r.consumption[which]='exact';else r.conflict=true;}
  else if(kind==='child'){const v=event.value!;r.reports.add(rawEvent.newValue!);if(r.child==='pending'||r.child===v.phase)r.child=v.phase as string;else if(r.child==='ready'&&v.phase==='closed')r.child='closed';else if(r.child==='closed'&&v.phase==='ready')return;else r.conflict=true;}
  else return;update(r);
 }catch{r.conflict=true;r.outcome='unconfirmed';}};
 return {dispose(){disposed=true;for(const id of owned){const r=requests.get(id)!;r.parentInvalidated=true;update(r);}},inspect(id: string){const r=requests.get(id);return r?snapshot(r):null;},async open(request: unknown){if(!closed(request,['session','generation','payload'])||!same(request.session,captured.session)||request.generation!==captured.generation||!alive())throw Error('invalid_owner');const payload=validatePayload(request.payload);if(!payload)throw Error('invalid_payload');let readIntent: ReadIntent | null=null,capturedProject: OwnerContext['selectedProject']=null;if(payload.mode==='editor'&&payload.content===undefined){const row=current().selectedProject;if(!row||row.root_state!=='verified'||typeof row.path!=='string'||!row.path||!uuid(row.project_id))throw Error('missing_read_root');capturedProject=structuredClone(row);readIntent=Object.freeze({project_dir:row.path,project_id:row.project_id,session:captured.session,generation:captured.generation});}
  const token=allocate(++sequence),key='winsmux.popout-surface.'+token,label='secondary-surface-'+token,url='index.html?popout=1&popout-key='+encodeURIComponent(key),absolute=new URL(url,current().href).href;if(!uuid(token)||requests.has(token)||!startupLocationAllowed(label,absolute))throw Error('target_invalid');
  const r={requestId:token,key,label,absolute,body:JSON.stringify(payload),sidecar:key+'.read-intent',metadataKey:key+'.creation-request',metadataRaw:JSON.stringify({request_id:token,label,key,session:captured.session,generation:captured.generation,mode:payload.mode}),intentRaw:readIntent===null?null:JSON.stringify(readIntent),submitted:false,sdk:'pending',child:'pending',parentInvalidated:false,outcome:'preparing',cleanup:{},consumption:{payload:'pending',metadata:'pending',intent:readIntent===null?'not_needed':'pending'},conflict:false,established:false,observerFailure:false} as OwnedRequest;r.reports=new Set();r.capturedSession=captured.session;r.capturedGeneration=captured.generation;r.onNotify=(event: StorageEvent)=>notification(r,event);requests.set(token,r);owned.add(token);
  const attempted=new Set<string>();try{const p=await policy();if(!alive()||r.conflict)throw Error('stale');if(readIntent&&!same(current().selectedProject,capturedProject))throw Error('read_target_changed');for(const k of [key,r.sidecar,r.metadataKey,key+'.creation-outcome'])if(storage.get(k)!==null)throw Error('publication_collision');for(const [k,v] of ([[key,r.body],[r.sidecar,r.intentRaw],[r.metadataKey,r.metadataRaw]] as Array<[string,string|null]>))if(v!==null){attempted.add(k);storage.put(k,v);}if(!alive()||r.conflict)throw Error('stale');if(readIntent&&!same(current().selectedProject,capturedProject))throw Error('read_target_changed');const options=Object.freeze({label,url,visible:false as const,...(p.additional_browser_args===null?{}:{additionalBrowserArgs:p.additional_browser_args})});
   // Publish request ownership before SDK effect. A returned SDK object is only submission, never native establishment.
   r.submitted=true;r.outcome='unconfirmed';try{construct(options,{sdkAck(){r.sdk=['error','conflicting'].includes(r.sdk)?'conflicting':'ack';update(r);},sdkError(){r.sdk=['ack','conflicting'].includes(r.sdk)?'conflicting':'error';update(r);},observerFailure(){r.observerFailure=true;update(r);},notify:(event: StorageEvent)=>notification(r,event)});}catch{r.sdk='constructor_unknown';update(r);}return snapshot(r);
  }catch(error){r.outcome='failed_before_submit';for(const [k,v] of ([[r.key,r.body],[r.sidecar,r.intentRaw],[r.metadataKey,r.metadataRaw]] as Array<[string,string|null]>))if(v!==null&&attempted.has(k)){try{r.cleanup[k]=r.conflict?'retained_conflict':storage.removeIfSame(k,v)??'exact_check';}catch{r.cleanup[k]='cleanup_unknown';}}throw Object.assign(Error('failed_before_submit'),{receipt:snapshot(r)});}
 }};
}
export function createSecondaryMount({current,invoke,construct,storage,allocate}: MountDependencies){
 const requests=new Map<string, OwnedRequest>();let active: ReturnType<typeof createOwner> | null=null,disposed=false;
 const facade=Object.freeze({openSecondarySurface(request: unknown){if(disposed||active===null)return Promise.reject(Error('mount_inactive'));return active.open(request);},inspectSecondarySurface(id: string){const r=requests.get(id);return r?requestSnapshot(r):null;}});
 return {facade,beginReconnect(){active?.dispose();active=null;},activate(){if(disposed)throw Error('mount_disposed');active?.dispose();active=createOwner({capture:current(),current,invoke,construct,storage,allocate,requests});},dispose(){disposed=true;active?.dispose();active=null;},observeStorage(event: StorageEvent){for(const r of requests.values())r.onNotify(event);}};
}
