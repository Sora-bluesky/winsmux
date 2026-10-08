import type { Request, Response, ErrorCode } from '../generated/workspace-contract';
import type { ViewSnapshot } from './project-pane';
import { restoreWorkspaceFocus } from './focus';
import type { OwnerKey } from './project-pane-controller';

export interface InputTarget {
  readonly instanceId: string; readonly generation: string; readonly projectId: string;
  readonly paneId: string; readonly runId: string; readonly producerId: string;
}
export type TerminalInputOwner = ReturnType<typeof createTerminalInputOwner>;
export interface InputProducer {
  readonly target: InputTarget;
  offer(text: string): boolean;
  focus(text: '\x1b[I' | '\x1b[O'): void;
  pending(bytes: number, active: boolean): boolean;
  canAccept(): boolean;
  retire(): void;
}
export interface InputConnection {
  ownerKey: OwnerKey;
  snapshot(): ViewSnapshot;
  maxBytes(): number;
  exchange(request: Request, beforeDispatch?: () => boolean): Promise<Response>;
  recover(origin: OwnerKey, request: Request): Promise<Response>;
}
export interface InputGuardPort {
  invoke(command: string, args: { requestJson: string }): Promise<unknown>;
  listen(callback: (payload: unknown) => void): Promise<() => void>;
}
type GuardStatus = { lease: string; revision: string; fence: { nonce: string; state: 'pending' | 'approved' | 'released' } | null; resume_allowed: boolean; admission_error: string | null };
type RecordState = 'queued' | 'preflight' | 'sending' | 'held' | 'unknown' | 'failed';
type Sendable = { readonly ownerKey: OwnerKey; readonly request: Request; readonly target: InputTarget; readonly writtenBytes: number };
type InputRecord = Sendable & { readonly charge: number; readonly produced: number; state: RecordState; reason?: string };
type FocusSlot = { text: '\x1b[I' | '\x1b[O'; produced: number };
type ProducerState = { target: InputTarget; ownerKey: OwnerKey; retired: boolean; codecActive: boolean; codecBytes: number; focus: FocusSlot | null };
type FlightPhase = 'preflight' | 'dispatched';
type InputFlight =
  | { kind: 'ledger'; binding: number; record: InputRecord; port: InputConnection; phase: FlightPhase }
  | { kind: 'focus'; binding: number; request: Request; target: InputTarget; ownerKey: OwnerKey; writtenBytes: number; port: InputConnection; phase: FlightPhase };
type GuardEffect = { binding: number; issue: number; lease: string | null; nonce?: string };
const encoder = new TextEncoder();
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const uint = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const id = (v: unknown): v is string => typeof v === 'string' && /^[1-9][0-9]*$/.test(v) && BigInt(v) <= 18446744073709551615n;
const object = (v: unknown, keys: readonly string[]): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === keys.length && keys.every(k => Object.prototype.hasOwnProperty.call(v, k));
export function scalarText(text: string): boolean {
  for (let i=0;i<text.length;i++) {
    const c=text.charCodeAt(i);
    if (c>=0xd800 && c<=0xdbff) { const next=text.charCodeAt(++i); if (!(next>=0xdc00 && next<=0xdfff)) return false; }
    else if (c>=0xdc00 && c<=0xdfff) return false;
  }
  return true;
}
const errors: Record<ErrorCode, readonly [string, boolean]> = {
  invalid_request:['Invalid request.',false], unsupported_version:['Unsupported protocol version.',false], permission_denied:['Permission denied.',false],
  target_not_found:['Target not found.',false], stale_topology:['Topology changed.',true], operation_conflict:['Operation identifier conflict.',false],
  in_progress:['Operation is in progress.',true], not_running:['Run is not running.',false], already_running:['Run is already running.',false],
  unsupported_capability:['Capability is unavailable.',false], output_gap:['Output history is incomplete.',false], persistence_failed:['Persistence failed.',false],
  runtime_failed:['Runtime operation failed.',true], state_unknown:['Operation state is unknown.',false], resource_exhausted:['Resource limit reached.',false],
  root_changed:['Root identity changed.',false], unsupported_file:['File type is unsupported.',false], not_a_repository:['Git repository is unavailable.',false],
};
function knownError(v: unknown): v is ErrorCode { return typeof v === 'string' && Object.prototype.hasOwnProperty.call(errors,v); }
function validGuard(v: unknown): v is GuardStatus {
  return object(v,['lease','revision','fence','resume_allowed','admission_error']) && id(v.lease) && id(v.revision) && typeof v.resume_allowed==='boolean'
    && (v.admission_error===null || ['shutdown_in_progress','shutdown_failed','transport_uncertain'].includes(v.admission_error as string))
    && (v.fence===null || object(v.fence,['nonce','state']) && id(v.fence.nonce) && ['pending','approved','released'].includes(v.fence.state as string))
    && (!v.resume_allowed || v.admission_error===null && v.fence!==null && (v.fence as Record<string,unknown>).state==='released');
}
function envelope(request: Request, value: unknown): value is Response {
  if (!object(value,['schema_version','instance_id','operation_id','accepted','topology_revision','event_seq','result','error']) || value.schema_version!==1 || value.instance_id!==request.instance_id || value.operation_id!==request.operation_id || !uint(value.topology_revision) || !uint(value.event_seq)) return false;
  if (value.accepted===true) return value.error===null && object(value.result,['operation','data']) && value.result.operation===request.operation;
  if (value.accepted!==false || value.result!==null || !object(value.error,['code','message','retryable','target_id']) || !knownError(value.error.code)) return false;
  const definition=errors[value.error.code];
  return value.error.message===definition[0] && value.error.retryable===definition[1] && (value.error.target_id===null || uuid(value.error.target_id))
    && (!['invalid_request','unsupported_version','resource_exhausted'].includes(value.error.code) || value.error.target_id===null);
}

/** One volatile ledger belongs to the main root, never to a rendered terminal. */
export function createTerminalInputOwner(root: HTMLElement, guard: InputGuardPort, allocate: () => string = () => crypto.randomUUID()) {
  const doc=root.ownerDocument; const binding=allocate();
  let connection: InputConnection | null=null; let lease: string | null=null; let revision=0n;
  let retainedLimit=0;
  let frozen=true; let controlDepth=0; let disposed=false;
  let connectionBinding=0; let flight: InputFlight | null=null; let produced=0;
  let guardIssue=0; let confirmIssue=0; const confirmations=new Map<InputRecord,number>();
  let fenceLocked=false; let approvalPossible=false; let resumeAllowed=false;
  let fence: GuardStatus['fence']=null;
  let releaseListener: (() => void) | null=null; let replying: GuardEffect | null=null; let lastReply: GuardEffect | null=null;
  let notice='入力の受付条件を確認しています。';
  const producers=new Map<string,ProducerState>();
  /** Ledger rows are user input or a reply the child asked for. A focus report stays in its producer slot, stamped with the same production counter, and never enters this ledger. */
  const records: InputRecord[]=[];
  const sequences=new Map<string,number>();
  const observers=new Set<() => void>();
  const panel=doc.createElement('section'); panel.className='workspace-input-confirmation'; panel.setAttribute('aria-label','入力の確認'); panel.tabIndex=-1;
  const heading=doc.createElement('h2'); heading.textContent='入力の確認';
  const status=doc.createElement('p'); status.setAttribute('role','status'); status.setAttribute('aria-live','polite');
  const list=doc.createElement('div'); const heldControls=doc.createElement('div'); panel.append(heading,status,list,heldControls); root.append(panel);
  const guardRecovery=doc.createElement('section'); guardRecovery.className='workspace-input-confirmation workspace-input-recovery'; guardRecovery.setAttribute('aria-label','入力の受付状態の再確認'); guardRecovery.tabIndex=-1; guardRecovery.hidden=true;
  const recoveryHeading=doc.createElement('h2'); recoveryHeading.textContent='入力の受付状態の再確認'; guardRecovery.append(recoveryHeading); root.append(guardRecovery);
  let guardRecoveryShown=false;
  const rowElements=new Map<string,{row:HTMLParagraphElement;text:Text;confirm:HTMLButtonElement;close:HTMLButtonElement}>();
  const heldElements=new Map<string,{send:HTMLButtonElement;discard:HTMLButtonElement}>();
  type FocusOrigin={element:HTMLElement;instanceId:string;generation:string;projectId:string|null;paneId:string|null;runId:string|null;terminal:boolean;producerId:string|null};
  let focusOrigin:FocusOrigin|null=null;let focusedFence:string|null=null;
  function rememberFocus(element:HTMLElement|null) {
    if (!element || !root.contains(element) || panel.contains(element) || guardRecovery.contains(element)) return;
    const snapshot=connection?.snapshot();if(!snapshot)return;
    const pane=element.closest<HTMLElement>('.workspace-pane');
    const terminal=!!element.closest('.workspace-terminal');
    const producer=terminal?Array.from(producers.values()).find(p=>!p.retired&&p.target.paneId===pane?.dataset.paneId&&p.target.runId===pane?.dataset.runId&&targetValid(p.target)):undefined;
    focusOrigin={element,instanceId:snapshot.instanceId,generation:snapshot.generation,projectId:snapshot.projects.selected_project_id,paneId:pane?.dataset.paneId??null,runId:pane?.dataset.runId||null,terminal,producerId:producer?.target.producerId??null};
  }
  const rememberOrigin=(event:FocusEvent)=>{if(event.relatedTarget instanceof HTMLElement)rememberFocus(event.relatedTarget);};
  panel.addEventListener('focusin',rememberOrigin); guardRecovery.addEventListener('focusin',rememberOrigin);
  function returnFocus() {
    const saved=focusOrigin;const snapshot=connection?.snapshot();
    const same=saved&&snapshot&&saved.instanceId===snapshot.instanceId&&saved.generation===snapshot.generation&&saved.projectId===snapshot.projects.selected_project_id;
    const pane=same&&saved.paneId?Array.from(root.querySelectorAll<HTMLElement>('.workspace-pane')).find(el=>el.dataset.paneId===saved.paneId&&el.dataset.projectId===saved.projectId):undefined;
    const producer=saved?.producerId?producers.get(saved.producerId):undefined;
    const live=saved&&!saved.terminal||producer&&!producer.retired&&targetValid(producer.target);
    const origin=same&&live&&root.contains(saved.element)&&!saved.element.matches(':disabled')&&snapshot.availability==='available'&&(!saved.paneId||pane&&pane.dataset.runId===(saved.runId??''))?saved.element:null;
    restoreWorkspaceFocus(origin,[pane?.querySelector<HTMLElement>('h2')??undefined,root.querySelector<HTMLElement>('main')??undefined]);
    focusOrigin=null;
  }
  const button=(label:string,action:()=>void)=>{const b=doc.createElement('button'); b.type='button'; b.textContent=label; b.onclick=action; return b;};
  const recheck=button('入力の受付状態を再確認',()=>{void recoverGuard();}); panel.append(recheck);
  function showGuardRecovery(show:boolean) {
    if(disposed || guardRecoveryShown===show)return;
    const focused=doc.activeElement===recheck; guardRecoveryShown=show;
    if(show)guardRecovery.append(status,recheck);
    else {panel.insertBefore(status,list);panel.append(recheck);}
    paint();
    if(focused){
      if(!recheck.closest('[inert],[hidden]'))recheck.focus({preventScroll:true});
      else returnFocus();
    }
  }
  function used() { return records.reduce((n,r)=>n+r.charge,0)+Array.from(producers.values()).reduce((n,p)=>n+p.codecBytes,0); }
  function cap() { const limit=connection?.maxBytes(); if (uint(limit) && limit>0) retainedLimit=limit; return retainedLimit; }
  function targetValid(target:InputTarget, confirmationOnly=false) {
    const snapshot=connection?.snapshot(); if (!snapshot || snapshot.instanceId!==target.instanceId) return false;
    if (confirmationOnly) return true;
    return snapshot.generation===target.generation && snapshot.availability==='available' && snapshot.projects.selected_project_id===target.projectId
      && snapshot.projects.projects.some(p=>p.project_id===target.projectId) && snapshot.panes?.project_id===target.projectId
      && snapshot.panes.panes.some(p=>p.pane_id===target.paneId && p.current_run_id===target.runId);
  }
  const sameOwner=(a:OwnerKey,b:OwnerKey)=>a.instanceId===b.instanceId&&a.ownerGeneration===b.ownerGeneration;
  const currentRecords=()=>records.filter(r=>connection&&sameOwner(r.ownerKey,connection.ownerKey));
  const sequenceKey=(r:{readonly ownerKey:OwnerKey;readonly target:InputTarget})=>JSON.stringify([r.ownerKey.instanceId,r.ownerKey.ownerGeneration,r.target.runId]);
  const ledgerFlight=()=>flight?.kind==='ledger';
  function quiescent() { return controlDepth===0 && !ledgerFlight() && records.length===0 && Array.from(producers.values()).every(p=>!p.codecActive); }
  function needsConfirmation() { return records.some(r=>r.state==='held'||r.state==='unknown'||r.state==='failed'); }
  function paint() {
    const focused=doc.activeElement instanceof HTMLElement&&(panel.contains(doc.activeElement)||guardRecovery.contains(doc.activeElement))?doc.activeElement:null;
    const message=notice||(guardRecoveryShown?'host の現在状態を確認するまで入力を保持します。':'');
    if(status.textContent!==message)status.textContent=message;
    panel.hidden=guardRecoveryShown?!needsConfirmation():!notice&&!needsConfirmation();
    guardRecovery.hidden=!guardRecoveryShown;
    const retainedIds=new Set(records.map(r=>r.request.operation_id));
    for(const [key,elements]of rowElements)if(!retainedIds.has(key)){elements.row.remove();rowElements.delete(key);}
    for (const record of records) {
      const key=record.request.operation_id;let elements=rowElements.get(key);
      if(!elements){
        const row=doc.createElement('p');const text=doc.createTextNode('');
        const confirmButton=button('元の操作の結果を確認',()=>{void confirm(record);});
        const close=button('確認済みの拒否を閉じる',()=>{remove(record);changed();void pump();});
        row.append(text,confirmButton,close);list.append(row);elements={row,text,confirm:confirmButton,close};rowElements.set(key,elements);
      }
      const description={queued:'送信待ち',preflight:'送信前の状態確認中',sending:'配送の確認中',held:'未送信で保持',unknown:'配送結果は不明',failed:'確定した拒否'}[record.state];
      const metadata=`${description} / プロジェクト ${record.target.projectId} / ペイン ${record.target.paneId} / 実行 ${record.target.runId} / 操作 ${record.request.operation_id}`;
      if(elements.text.data!==metadata)elements.text.data=metadata;
      elements.confirm.hidden=record.state!=='unknown'&&record.state!=='failed';elements.close.hidden=record.state!=='failed';
    }
    const heldIds=new Set(records.filter(r=>r.state==='held').map(r=>r.target.producerId));
    for(const [key,elements]of heldElements)if(!heldIds.has(key)){elements.send.remove();elements.discard.remove();heldElements.delete(key);}
    for(const producerId of heldIds)if(!heldElements.has(producerId)){
      const send=button('この対象の保持入力を送る',()=>{resume(producerId);});
      const discardButton=button('この対象の未送信入力を破棄',()=>{discard(producerId);});
      heldControls.append(send,discardButton);heldElements.set(producerId,{send,discard:discardButton});
    }
    if(focused&&(!focused.isConnected||focused.closest('[hidden]')))returnFocus();
  }
  function remove(record:InputRecord) { const index=records.indexOf(record); if (index>=0) records.splice(index,1); }
  function collect() {
    for (const [key,p] of producers) if (p.retired && !p.codecActive && !records.some(r=>r.target.producerId===key)) {
      producers.delete(key);
      const sequence=JSON.stringify([p.ownerKey.instanceId,p.ownerKey.ownerGeneration,p.target.runId]);
      if (!Array.from(producers.values()).some(other=>sameOwner(other.ownerKey,p.ownerKey)&&other.target.runId===p.target.runId)
        && !records.some(r=>sameOwner(r.ownerKey,p.ownerKey)&&r.target.runId===p.target.runId)) sequences.delete(sequence);
    }
  }
  function changed() { collect(); paint(); for(const observe of observers)observe(); }
  function holdQueued(reason:string) { for (const r of records) if (r.state==='queued') {r.state='held'; r.reason=reason;} }
  function retireFlight(reason:string) {
    const prior=flight; if (!prior) return;
    flight=null;
    if (prior.kind==='focus') { if (prior.phase!=='dispatched') return; }
    else {
      if (!records.includes(prior.record)) return;
      prior.record.state=prior.phase==='preflight'?'held':'unknown'; prior.record.reason=reason;
    }
    holdQueued('preceding_not_confirmed');
    notice=prior.phase==='preflight'?'元の入力は未送信で保持しています。'
      :'元の入力の配送結果は不明です。元の操作を確認してください。';
  }
  function stopReason(message:string) { notice=message; changed(); }
  const currentEffect=(effect:GuardEffect) => !disposed && effect.binding===connectionBinding
    && effect.issue===guardIssue && (effect.lease===null || effect.lease===lease);
  async function applyGuard(value:unknown,effect:GuardEffect) {
    if(!currentEffect(effect))return;
    if (!validGuard(value) || lease!==null && value.lease!==lease) { frozen=true; stopReason('入力の受付状態を確認できません。再確認してください。'); return; }
    if (BigInt(value.revision)<revision) return;
    lease=value.lease; revision=BigInt(value.revision);
    fence=value.fence;
    if (value.fence?.state==='pending') {
      fenceLocked=true;resumeAllowed=false;frozen=true;
      const safe=quiescent();
      notice=safe?'入力の受付を止めて終了を確認しています。':'変換・配送・保持入力の確認が必要なため終了を止めました。';
      const key=`${lease}:${value.fence.nonce}`;const first=focusedFence!==key;focusedFence=key;
      changed();
      const recoveryPanel=guardRecoveryShown?guardRecovery:panel;
      if(!safe&&first&&!recoveryPanel.contains(doc.activeElement)){rememberFocus(doc.activeElement instanceof HTMLElement?doc.activeElement:null);recoveryPanel.focus();}
      if (replying?.binding===effect.binding && replying.nonce===value.fence.nonce
        || lastReply?.binding===effect.binding && lastReply.nonce===value.fence.nonce) return;
      const nonce=value.fence.nonce; const replyEffect={...effect,nonce}; replying=replyEffect;
      if(safe)approvalPossible=true;
      let refreshCurrent=false;
      try {
        const response=await guard.invoke('workspace_input_guard_reply',{requestJson:JSON.stringify({lease,nonce,safe})});
        if(!currentEffect(replyEffect) || replying!==replyEffect){refreshCurrent=!disposed&&replyEffect.binding===connectionBinding&&replyEffect.lease===lease;return;}
        lastReply=replyEffect; await applyGuard(response,replyEffect);
      } catch { if(currentEffect(replyEffect) && replying===replyEffect)stopReason('終了への入力確認の結果は未確認です。入力の受付状態を再確認してください。');
        else refreshCurrent=!disposed&&replyEffect.binding===connectionBinding&&replyEffect.lease===lease; }
      finally { if (replying===replyEffect) replying=null; if(refreshCurrent)void recoverGuard(); }
      return;
    }
    if(value.fence?.state==='approved' || value.fence?.state==='released' && !value.resume_allowed){fenceLocked=true;resumeAllowed=false;}
    if(value.fence?.state==='released' && value.resume_allowed){fenceLocked=false;approvalPossible=false;resumeAllowed=true;}
    const wasFrozen=frozen;
    frozen=fenceLocked || value.admission_error!==null;
    notice=frozen?'入力の受付を止めています。終了の結果を確認してください。':needsConfirmation()?'保持した入力を確認してください。':'';
    changed();
    if (wasFrozen && !frozen) void pump();
  }
  async function recoverGuard() {
    if (disposed || lease===null) return;
    const effect:GuardEffect={binding:connectionBinding,issue:++guardIssue,lease};
    try { await applyGuard(await guard.invoke('workspace_input_guard_status',{requestJson:JSON.stringify({lease:effect.lease})}),effect); }
    catch { if(currentEffect(effect)){frozen=true;stopReason('入力の受付状態を確認できません。再確認してください。');} }
  }
  function validInputResponse(record:Sendable,response:Response) {
    if (!envelope(record.request,response)) return false;
    if (!response.accepted) return true;
    const data:unknown=response.result?.data;
    const keys=record.request.operation==='input.key'?['input_seq','key','pane_id','run_id','sent','written_bytes']:['input_seq','pane_id','run_id','written_bytes'];
    if (!object(data,keys) || !uint(data.input_seq) || data.input_seq<1 || data.input_seq<=(sequences.get(sequenceKey(record))??0) || data.pane_id!==record.target.paneId || data.run_id!==record.target.runId || data.written_bytes!==record.writtenBytes) return false;
    return record.request.operation!=='input.key' || data.sent===true && data.key==='interrupt';
  }
  function sendable(own:InputFlight):Sendable { return own.kind==='ledger'?own.record:own; }
  function nextSend(): {kind:'ledger';record:InputRecord} | {kind:'focus';state:ProducerState;slot:FocusSlot} | null {
    const queued=currentRecords().find(r=>r.state==='queued');
    let chosen:{state:ProducerState;slot:FocusSlot}|null=null;
    if (connection) for (const state of producers.values()) {
      if (state.retired || state.focus===null || !sameOwner(state.ownerKey,connection.ownerKey) || !targetValid(state.target)) continue;
      if (!chosen || state.focus.produced<chosen.slot.produced) chosen={state,slot:state.focus};
    }
    if (chosen && (!queued || chosen.slot.produced<queued.produced)) return {kind:'focus',state:chosen.state,slot:chosen.slot};
    if (queued && !targetValid(queued.target)) { holdQueued('target_retired'); stopReason('元の対象を確認できないため未送信で保持しています。'); return null; }
    return queued?{kind:'ledger',record:queued}:null;
  }
  function settle(own:InputFlight,result:{outcome:'accepted';response:Response}|{outcome:'refused';response:Response}|{outcome:'thrown';error:unknown}) {
    const sent=sendable(own);
    if (own.kind==='focus') {
      if (result.outcome==='thrown' && own.phase==='preflight' && result.error instanceof Error && result.error.message==='host_not_sent') return;
      if (result.outcome==='refused' && result.response.error?.code!=='state_unknown' && result.response.error?.code!=='in_progress') return;
      if (result.outcome==='accepted') { sequences.set(sequenceKey(sent),(result.response.result!.data as {input_seq:number}).input_seq); return; }
      holdQueued('preceding_not_confirmed');
      notice=result.outcome==='thrown' && own.phase==='preflight' ? 'host が送信を受け付ける状態を確認できず、入力は未送信で保持しています。'
        : result.outcome==='thrown' ? '入力の配送結果は不明です。元の操作を確認してください。'
        : '入力の配送を確認してください。自動で再送しません。';
      return;
    }
    if (result.outcome==='accepted') { sequences.set(sequenceKey(sent),(result.response.result!.data as {input_seq:number}).input_seq); remove(own.record); notice=''; return; }
    if (result.outcome==='refused') {
      own.record.state=result.response.error?.code==='state_unknown' || result.response.error?.code==='in_progress' ? 'unknown':'failed';
      holdQueued('preceding_not_confirmed'); notice='入力の配送を確認してください。自動で再送しません。'; return;
    }
    const unsent=own.phase==='preflight';
    own.record.state=unsent?'held':'unknown';
    holdQueued('preceding_not_confirmed'); notice=unsent?'host が送信を受け付ける状態を確認できず、入力は未送信で保持しています。'
      :'入力の配送結果は不明です。元の操作を確認してください。';
  }
  async function pump() {
    if (disposed || frozen || controlDepth>0 || flight || !connection || currentRecords().some(r=>['unknown','held','failed'].includes(r.state))) return;
    const port=connection, next=nextSend();
    if (!next) return;
    let own:InputFlight;
    if (next.kind==='ledger') own={kind:'ledger',binding:connectionBinding,record:next.record,port,phase:'preflight'};
    else {
      const operation_id=allocate(); if (!uuid(operation_id)) throw new Error('input_id_invalid');
      const text=next.slot.text;
      own={kind:'focus',binding:connectionBinding,request:{schema_version:1,instance_id:next.state.target.instanceId,operation_id,expected_topology_revision:null,operation:'input.write',params:{pane_id:next.state.target.paneId,run_id:next.state.target.runId,text}},target:next.state.target,ownerKey:next.state.ownerKey,writtenBytes:encoder.encode(text).byteLength,port,phase:'preflight'};
      next.state.focus=null;
    }
    flight=own; if (own.kind==='ledger') own.record.state='preflight'; changed();
    try {
      const response=await port.exchange(sendable(own).request,()=>{
        if (flight!==own || own.binding!==connectionBinding || connection!==port || !targetValid(sendable(own).target)
          || producers.get(sendable(own).target.producerId)?.retired) return false;
        own.phase='dispatched'; if (own.kind==='ledger') own.record.state='sending';
        queueMicrotask(()=>{if(flight===own)changed();});
        return true;
      });
      if (flight!==own) return;
      if (!validInputResponse(sendable(own),response)) throw new Error('protocol_failed');
      settle(own,response.accepted?{outcome:'accepted',response}:{outcome:'refused',response});
    } catch (error) {
      if (flight!==own) return;
      settle(own,{outcome:'thrown',error});
    } finally {
      if (flight===own) { flight=null; changed(); await recoverGuard(); if (!disposed) void pump(); }
    }
  }
  async function confirm(record:InputRecord) {
    if (!records.includes(record) || !['unknown','failed'].includes(record.state) || !targetValid(record.target,true) || !connection) { stopReason('元の作業セッションに接続できないため結果を確認できません。'); return; }
    const port=connection;const bound=connectionBinding;const issue=++confirmIssue;confirmations.set(record,issue);
    const current=()=>!disposed&&connectionBinding===bound&&connection===port&&confirmations.get(record)===issue;
    const request:Request={schema_version:1,instance_id:record.target.instanceId,operation_id:allocate(),expected_topology_revision:null,operation:'operation.get',params:{operation_id:record.request.operation_id}};
    if (encoder.encode(JSON.stringify(request)).byteLength>cap()) {stopReason('確認要求が許容サイズを超えています。');return;}
    let removed=false;
    try {
      const response=await port.recover(record.ownerKey,request);
      if(!current()||!records.includes(record))return;
      const data:unknown=response.result?.data;
      if (!envelope(request,response) || !response.accepted || !object(data,['operation'])) throw new Error('protocol_failed');
      const result=data.operation;
      if (!object(result,['error_code','operation_id','outcome','phase']) || result.operation_id!==record.request.operation_id) throw new Error('protocol_failed');
      if (['accepted','in_progress','unknown'].includes(result.phase as string) && result.outcome===null && result.error_code===null) {notice='元の入力操作の結果はまだ未確定です。';}
      else if (result.phase==='completed' && result.outcome==='succeeded' && result.error_code===null) { remove(record); notice='元の操作の成功記録を確認しました。保持入力は自動で送りません。'; removed=true; }
      else if (result.phase==='completed' && result.outcome==='failed' && knownError(result.error_code)) {record.state=result.error_code==='state_unknown'?'unknown':'failed';notice='元の操作の結果を確認しました。保持入力は自動で送りません。';}
      else throw new Error('protocol_failed');
    } catch {if(!current())return;notice='元の入力操作の結果を確認できません。記録を保持しています。';}
    if(!current())return;
    confirmations.delete(record);changed();await recoverGuard();
    if(removed&&!disposed)void pump();
  }
  function resume(producerId:string) {
    const held=records.filter(r=>r.target.producerId===producerId && r.state==='held');
    if (frozen || controlDepth>0 || ledgerFlight() || currentRecords().some(r=>r.state==='unknown' || r.state==='failed') || held.some(r=>!connection||!sameOwner(r.ownerKey,connection.ownerKey)||!targetValid(r.target))) {stopReason('元の対象と配送状態の確認が必要です。別の実行へは送りません。');return;}
    for (const r of held) r.state='queued'; notice=''; changed(); void pump();
  }
  function discard(producerId:string) {
    for (const r of [...records]) if (r.target.producerId===producerId && r.state==='held') remove(r);
    notice=records.some(r=>r.state==='unknown')?'送信済みの不明な結果は保持しています。':''; changed(); void pump();
  }
  return {
    async initialize() {
      const effect:GuardEffect={binding:connectionBinding,issue:++guardIssue,lease:null};
      try {
        if (!uuid(binding)) throw new Error('input_guard_invalid');
        releaseListener=await guard.listen(payload=>{
          if (!disposed && object(payload,['lease','revision']) && payload.lease===lease && id(payload.revision) && BigInt(payload.revision)>=revision) void recoverGuard();
        });
        if (disposed) {releaseListener();return;}
        await applyGuard(await guard.invoke('workspace_input_guard_register',{requestJson:JSON.stringify({binding})}),effect);
      } catch {if(currentEffect(effect)){frozen=true;stopReason('入力の受付を登録できません。出力を保持しています。');}}
    },
    connect(next:InputConnection) { if(connection!==next) {retireFlight('connection_replaced'); connectionBinding++;guardIssue++;confirmations.clear();} connection=next; changed(); void pump(); void recoverGuard(); },
    disconnect() { cap(); retireFlight('connection_retired'); connectionBinding++;guardIssue++;confirmations.clear();connection=null; holdQueued('connection_retired'); changed(); },
    blockHost() { retireFlight('host_unconfirmed'); connectionBinding++;guardIssue++;confirmations.clear();frozen=true; connection=null; holdQueued('host_unconfirmed'); stopReason('host の現在状態を確認するまで入力を保持します。'); },
    produce(target:InputTarget):InputProducer {
      if (!Object.values(target).every(uuid) || producers.has(target.producerId) || !connection || connection.ownerKey.instanceId!==target.instanceId) throw new Error('input_target_invalid');
      const immutable=Object.freeze({...target}); const state:ProducerState={target:immutable,ownerKey:connection.ownerKey,retired:false,codecActive:false,codecBytes:0,focus:null}; producers.set(target.producerId,state);
      return {
        target:immutable,
        canAccept:()=>!disposed && !state.retired && !frozen && !fenceLocked && controlDepth===0 && lease!==null && !!connection && sameOwner(state.ownerKey,connection.ownerKey) && cap()>0 && targetValid(immutable),
        pending(bytes,active) {
          if(active && !state.codecActive && (frozen || fenceLocked)) {stopReason('終了確認中のため新しい変換入力を受け付けていません。');return false;}
          if (!uint(bytes) || bytes+used()-state.codecBytes>cap()) {state.codecActive=true;state.codecBytes=0;stopReason('変換中の入力全体が上限を超えています。変換を取消してください。');return false;}
          state.codecBytes=bytes;state.codecActive=active;changed();return true;
        },
        offer(text) {
          if (disposed || state.retired || !text || !connection || !sameOwner(state.ownerKey,connection.ownerKey)) return false;
          if(frozen || fenceLocked){stopReason('終了確認中のため新しい入力を受け付けていません。');return false;}
          if (!scalarText(text)) {stopReason('入力全体をUnicode文字として確認できないため送信していません。');return false;}
          const operation_id=allocate(); if (!uuid(operation_id)) throw new Error('input_id_invalid');
          const request:Request=text==='\x03'?{schema_version:1,instance_id:immutable.instanceId,operation_id,expected_topology_revision:null,operation:'input.key',params:{pane_id:immutable.paneId,run_id:immutable.runId,key:'interrupt'}}:{schema_version:1,instance_id:immutable.instanceId,operation_id,expected_topology_revision:null,operation:'input.write',params:{pane_id:immutable.paneId,run_id:immutable.runId,text}};
          const charge=encoder.encode(JSON.stringify({target:immutable,request})).byteLength;
          if (!cap() || encoder.encode(JSON.stringify(request)).byteLength>cap() || used()+charge>cap()) {stopReason('入力全体が保持できるサイズを超えているため送信していません。');return false;}
          const held=frozen || controlDepth>0 || !connection || !sameOwner(state.ownerKey,connection.ownerKey) || !targetValid(immutable) || currentRecords().some(r=>['held','unknown','failed'].includes(r.state));
          records.push({ownerKey:state.ownerKey,target:immutable,request,charge,writtenBytes:encoder.encode(text).byteLength,produced:++produced,state:held?'held':'queued'});
          notice=held?'元の対象へ未送信で保持しています。':'';changed();void pump();return true;
        },
        focus(text) {
          if (disposed || state.retired) return;
          state.focus={text,produced:++produced}; void pump();
        },
        retire() {state.retired=true;state.codecBytes=0;state.codecActive=false;state.focus=null;
          if(flight && (flight.kind==='ledger'?flight.record.target.producerId:flight.target.producerId)===target.producerId)retireFlight('target_retired');
          for (const r of records) if(r.target.producerId===target.producerId && r.state==='queued') r.state='held';changed();void pump();},
      };
    },
    admitControl() {
      if (disposed || frozen || fenceLocked || lease===null || controlDepth!==0 || ledgerFlight() || currentRecords().length!==0 || Array.from(producers.values()).some(p=>!p.retired&&p.codecActive&&connection&&sameOwner(p.ownerKey,connection.ownerKey))) {stopReason('変換・配送・保持入力を確認してから操作してください。');return null;}
      controlDepth++; return () => {controlDepth=Math.max(0,controlDepth-1);changed();void pump();};
    },
    hasPendingComposition:()=>Array.from(producers.values()).some(p=>p.codecActive),
    explain:stopReason,
    refresh() { changed(); void pump(); },
    observe(callback:()=>void) {observers.add(callback);return()=>observers.delete(callback);},
    recoverGuard,
    guardRecovery,
    showGuardRecovery,
    inspect:()=>({frozen,lease,revision:revision.toString(),fenceLocked,approvalPossible,resumeAllowed,fenceState:fence?.state??null,usedBytes:used(),records:records.map(r=>({operationId:r.request.operation_id,target:r.target,state:r.state}))}),
    dispose() {if(disposed)return;disposed=true;retireFlight('owner_disposed');flight=null;frozen=true;releaseListener?.();releaseListener=null;const focused=panel.contains(doc.activeElement)||guardRecovery.contains(doc.activeElement);panel.hidden=true;guardRecovery.hidden=true;if(focused)returnFocus();connection=null;observers.clear();rowElements.clear();heldElements.clear();panel.remove();guardRecovery.remove();},
  };
}
