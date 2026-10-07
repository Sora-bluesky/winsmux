import type { Terminal } from 'xterm';
import type { InputProducer } from './terminal-input';
import { scalarText } from './terminal-input';

type Baseline={value:string;start:number;end:number};
type Composition={baseline:Baseline;value:string;ended:boolean;blocked:boolean;token:number};
const bytes=(s:string)=>new TextEncoder().encode(s).byteLength;
const compositionInput=(type:string)=>['insertCompositionText','insertFromComposition','deleteCompositionText'].includes(type);
function difference(base:Baseline,value:string):string|null {
  const prefix=base.value.slice(0,base.start); const suffix=base.value.slice(base.end);
  return value.startsWith(prefix) && value.endsWith(suffix) && value.length>=prefix.length+suffix.length ? value.slice(prefix.length,value.length-suffix.length) : null;
}

/** Capture owns composition; xterm owns ordinary VT keys and bracketed paste. */
export function installTerminalInputCodec(slot:HTMLElement, terminal:Terminal, producer:InputProducer, explain:(message:string)=>void) {
  const candidate=terminal.textarea;
  if (!candidate) throw new Error('terminal_textarea_unavailable');
  const textarea:HTMLTextAreaElement=candidate;
  textarea.setAttribute('aria-label',`ペイン ${producer.target.paneId} のターミナル入力`);
  const doc=slot.ownerDocument;
  const preview=doc.createElement('p'); preview.className='workspace-input-preedit'; preview.setAttribute('aria-label','変換中の文字'); preview.setAttribute('aria-live','polite');
  const cancel=doc.createElement('button'); cancel.type='button';cancel.textContent='変換を取消';cancel.hidden=true;
  slot.before(preview,cancel);
  let retired=false;let composition:Composition|null=null;let pendingNative:Baseline|null=null;let token=0;let delayedBlur=false;
  const baseline=():Baseline=>({value:textarea.value,start:textarea.selectionStart??textarea.value.length,end:textarea.selectionEnd??textarea.value.length});
  const relevant=(event:Event)=>event.target===textarea;
  function block(c:Composition,message:string) {
    c.blocked=true;
    if(!producer.pending(bytes(c.value)+bytes(c.baseline.value),true)) {
      c.value='';c.baseline={value:'',start:0,end:0};producer.pending(0,true);
    }
    preview.textContent='変換の内容を確認できません。取消して入力し直してください。';cancel.hidden=false;explain(message);
  }
  function update(c:Composition,value:string) {
    const part=difference(c.baseline,value);
    if (part===null) {block(c,'変換の対象範囲を確認できません。送信していません。');return;}
    if (!producer.pending(bytes(value)+bytes(c.baseline.value),true)) {block(c,'変換中の入力全体が上限を超えています。送信していません。');return;}
    c.value=value;preview.textContent=part;cancel.hidden=false;
  }
  function relayBlur() {
    if (!delayedBlur) return;delayedBlur=false;
    if (!retired && doc.activeElement!==textarea) textarea.dispatchEvent(new FocusEvent('blur'));
  }
  function clear() {composition=null;pendingNative=null;producer.pending(0,false);preview.textContent='';cancel.hidden=true;textarea.value='';relayBlur();}
  function commit(c:Composition) {
    if (retired || composition!==c || !c.ended || c.blocked) return false;
    if (!producer.canAccept()) {explain('終了確認中のため変換文字を送信していません。確定または取消しを確認してください。');return false;}
    const part=difference(c.baseline,c.value);
    if (part===null || !scalarText(part)) {block(c,'確定文字をUnicode文字として確認できません。送信していません。');return false;}
    producer.pending(0,false);
    if (part && !producer.offer(part)) {producer.pending(bytes(c.value)+bytes(c.baseline.value),true);block(c,'確定入力を受け付けられません。取消して入力を確認してください。');return false;}
    clear();return true;
  }
  function begin(base=baseline()) {
    const c:Composition={baseline:base,value:textarea.value,ended:false,blocked:false,token:++token};composition=c;update(c,textarea.value);return c;
  }
  const start=(event:Event)=>{
    if(!relevant(event)||retired)return;event.stopImmediatePropagation();
    if(composition?.ended && !commit(composition))return;
    if(!producer.canAccept()){event.preventDefault();explain('入力の受付を止めています。保持入力を確認してください。');return;}
    begin();
  };
  const change=(event:Event)=>{if(!relevant(event)||retired)return;event.stopImmediatePropagation();
    if(!composition&&!producer.canAccept()){textarea.value=pendingNative?.value??'';pendingNative=null;explain('終了確認中のため新しい変換入力を受け付けていません。');return;}
    const c=composition??begin(pendingNative??baseline());update(c,textarea.value);};
  const end=(event:Event)=>{
    if(!relevant(event)||retired)return;event.stopImmediatePropagation();
    if(!composition&&!producer.canAccept()){textarea.value=pendingNative?.value??'';pendingNative=null;explain('終了確認中のため新しい変換入力を受け付けていません。');return;}
    const c=composition??begin(pendingNative??baseline());update(c,textarea.value);c.ended=true;
    const captured=c.token;
    // One DOM propagation boundary; callback reads the captured snapshot, never a later textarea.
    setTimeout(()=>{if(!retired&&composition===c&&c.token===captured)commit(c);},0);
  };
  const before=(event:Event)=>{
    if(!relevant(event)||retired)return;
    const input=event as InputEvent;
    if(composition?.ended && !compositionInput(input.inputType) && input.isComposing!==true) pendingNative=baseline();
    else if(!composition) pendingNative=baseline();
    if(!composition&&!producer.canAccept()&&event.cancelable){event.preventDefault();event.stopImmediatePropagation();}
  };
  const input=(event:Event)=>{
    if(!relevant(event)||retired)return;event.stopImmediatePropagation();const native=event as InputEvent;
    let c=composition;
    if(!c&&!producer.canAccept()){
      textarea.value=pendingNative?.value??'';pendingNative=null;
      explain('終了確認中のため新しい入力を受け付けていません。');return;
    }
    if(c&&!c.ended){update(c,textarea.value);return;}
    if(c?.ended){
      if(compositionInput(native.inputType)||native.isComposing){update(c,textarea.value);return;}
      const prior=pendingNative;
      const actual=textarea.value;
      // A separate insertion must be proved by its native range and DOM mutation.
      const inserted=prior?difference(prior,actual):null;
      const independent=prior!==null&&typeof native.data==='string'&&inserted===native.data&&actual===prior.value.slice(0,prior.start)+native.data+prior.value.slice(prior.end);
      if(independent){
        if(!commit(c))return;
        if(inserted){producer.offer(inserted);textarea.value='';}
        pendingNative=null;return;
      }
      // A final notification with no independent edit still belongs to this composition.
      if(actual===c.value&&(prior===null||prior.value===c.value)){update(c,actual);pendingNative=null;return;}
      block(c,'確定通知と次の入力の対応を確認できません。入力を重複送信していません。');return;
    }
    if(native.isComposing||compositionInput(native.inputType)){c=begin(pendingNative??baseline());update(c,textarea.value);return;}
    const prior=pendingNative;pendingNative=null;
    const text=prior?difference(prior,textarea.value):typeof native.data==='string'&&textarea.value===native.data?textarea.value:null;
    if(text===null){explain('入力の確定した範囲を確認できません。送信していません。');return;}
    if(text&&producer.offer(text))textarea.value='';
  };
  const blur=(event:Event)=>{
    if(!relevant(event)||retired||!composition)return;
    event.stopImmediatePropagation();delayedBlur=true;update(composition,textarea.value);
  };
  const focus=()=>{delayedBlur=false;};
  const paste=(event:Event)=>{
    if(retired)return;
    if(!event.cancelable){event.stopImmediatePropagation();explain('貼り付けの既定挿入を取消せないため送信していません。');return;}
    if(composition&&!composition.ended){event.preventDefault();event.stopImmediatePropagation();explain('変換を確定または取消してから貼り付けてください。');return;}
    if(composition&&!commit(composition)||!producer.canAccept()){event.preventDefault();event.stopImmediatePropagation();explain('保持入力を確認してから貼り付けてください。');return;}
    // The installed SDK owns the VT column; suppress the browser's second DOM insertion.
    event.preventDefault();
  };
  const context=(event:Event)=>{if(composition&&!composition.ended){event.preventDefault();event.stopImmediatePropagation();explain('変換を確定または取消してから右クリック操作を行ってください。');}else if(composition&&!commit(composition)){event.preventDefault();event.stopImmediatePropagation();}};
  terminal.attachCustomKeyEventHandler(event=>{
    if(retired)return false;
    if(event.isComposing||event.keyCode===229||composition&&!composition.ended)return false;
    if(composition&&!commit(composition)){event.preventDefault();return false;}
    if(event.type==='keyup'&&doc.activeElement!==textarea)return false;
    if(!producer.canAccept()){
      if(event.ctrlKey&&event.key.toLowerCase()==='c'&&terminal.hasSelection())return true;
      event.preventDefault();return false;
    }
    return true;
  });
  const data=terminal.onData(text=>{if(!retired&&text)producer.offer(text);});
  const key=terminal.onKey(({domEvent})=>{domEvent.preventDefault();});
  const listeners:[string,EventListener][]=[['compositionstart',start],['compositionupdate',change],['compositionend',end],['beforeinput',before],['input',input],['blur',blur],['paste',paste],['contextmenu',context]];
  for(const [name,listener]of listeners)slot.addEventListener(name,listener,true);
  textarea.addEventListener('focus',focus);
  cancel.onclick=()=>{if(retired)return;clear();explain('未確定の変換を取消しました。確定した配送記録は保持しています。');textarea.focus();};
  return {
    isComposing:()=>composition!==null,
    retire(){
      if(retired)return;
      if(composition?.ended)commit(composition);
      else if(composition)explain('対象が変わったため未確定の変換を取消しました。確定入力は元の対象に保持しています。');
      retired=true;composition=null;pendingNative=null;producer.pending(0,false);producer.retire();
      for(const [name,listener]of listeners)slot.removeEventListener(name,listener,true);
      textarea.removeEventListener('focus',focus);data.dispose();key.dispose();preview.remove();cancel.remove();
      terminal.attachCustomKeyEventHandler(()=>false);
    },
  };
}
