export function restoreWorkspaceFocus(origin:HTMLElement|null,fallbacks:readonly (HTMLElement|undefined)[]) {
  const usable=(element:HTMLElement|undefined|null):element is HTMLElement=>!!element&&element.isConnected&&!element.closest('[hidden], [inert], dialog:not([open])')&&element.getClientRects().length>0&&!(element instanceof HTMLButtonElement&&element.disabled);
  const target=[origin,...fallbacks].find(usable);target?.focus();
}
export function installWorkspaceShortcuts(root:HTMLElement,options:{enabled():boolean;composing():boolean;search():void;create():void;close():void}) {
  const key=(event:KeyboardEvent)=>{
    if(event.key==='F6'&&!event.ctrlKey&&!event.altKey&&!event.metaKey&&!event.isComposing&&event.keyCode!==229&&!options.composing()){
      // Keep native dialogs in charge of their own focus cycle and return destination.
      if(root.querySelector('dialog[open]'))return;
      const usable=(element:HTMLElement)=>!element.closest('[hidden], [inert]')&&element.getClientRects().length>0&&!element.matches(':disabled');
      const toolbar=root.querySelector<HTMLElement>('.workspace-toolbar');
      const control=toolbar&&Array.from(toolbar.querySelectorAll<HTMLElement>('button, input')).find(usable);
      const terminals=Array.from(root.querySelectorAll<HTMLElement>('.workspace-terminal')).filter(usable);
      const regions=[...(control?[{region:toolbar!,target:control}]:[]),...terminals.map(slot=>({region:slot,target:slot.querySelector<HTMLElement>('textarea[tabindex="0"]')??slot}))];
      if(!regions.length)return;
      const index=regions.findIndex(row=>row.region.contains(root.ownerDocument.activeElement));
      const next=index<0?(event.shiftKey?regions.length-1:0):(index+(event.shiftKey?-1:1)+regions.length)%regions.length;
      event.preventDefault();event.stopImmediatePropagation();regions[next].target.focus();return;
    }
    if(!options.enabled()||options.composing()||event.isComposing||event.keyCode===229||!event.ctrlKey||!event.shiftKey||event.altKey||event.metaKey)return;
    const action=event.key.toLowerCase()==='p'?options.search:event.key.toLowerCase()==='t'?options.create:event.key.toLowerCase()==='w'?options.close:null;
    if(!action)return;event.preventDefault();event.stopImmediatePropagation();action();
  };
  root.addEventListener('keydown',key,true);return()=>root.removeEventListener('keydown',key,true);
}

/** One ordered owner for both key and wheel zoom; the native setter scales the whole webview. */
export function installWorkspaceZoom(root:HTMLElement,setZoom:(factor:number)=>Promise<void>,explain:(message:string)=>void) {
  let percent=100;let applied=100;let retired=false;let pending=Promise.resolve();
  const change=(next:number)=>{
    percent=Math.max(50,Math.min(300,next));
    const requested=percent;
    pending=pending.then(async()=>{
      if(retired)return;
      try{await setZoom(requested/100);applied=requested;}
      catch{if(!retired){if(percent===requested)percent=applied;explain('表示倍率を変更できませんでした。もう一度操作してください。');}}
    });
  };
  const key=(event:KeyboardEvent)=>{
    if(!event.ctrlKey||event.altKey||event.metaKey||event.isComposing||event.keyCode===229)return;
    const direction=event.key==='+'||event.key==='='?1:event.key==='-'?-1:event.key==='0'?0:null;
    if(direction===null)return;
    event.preventDefault();event.stopImmediatePropagation();change(direction===0?100:percent+direction*10);
  };
  const wheel=(event:WheelEvent)=>{
    if(!event.ctrlKey||event.altKey||event.metaKey||event.deltaY===0)return;
    event.preventDefault();event.stopImmediatePropagation();change(percent+(event.deltaY<0?10:-10));
  };
  root.addEventListener('keydown',key,true);root.addEventListener('wheel',wheel,{capture:true,passive:false});
  return()=>{retired=true;root.removeEventListener('keydown',key,true);root.removeEventListener('wheel',wheel,true);};
}
