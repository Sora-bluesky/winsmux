export function restoreWorkspaceFocus(origin:HTMLElement|null,fallbacks:readonly (HTMLElement|undefined)[]) {
  const usable=(element:HTMLElement|undefined|null):element is HTMLElement=>!!element&&element.isConnected&&!element.closest('[hidden], [inert], dialog:not([open])')&&element.getClientRects().length>0&&!(element instanceof HTMLButtonElement&&element.disabled);
  const target=[origin,...fallbacks].find(usable);target?.focus();
}
export function installWorkspaceShortcuts(root:HTMLElement,options:{enabled():boolean;composing():boolean;search():void;create():void;close():void}) {
  const key=(event:KeyboardEvent)=>{
    if(!options.enabled()||options.composing()||event.isComposing||event.keyCode===229||!event.ctrlKey||!event.shiftKey||event.altKey||event.metaKey)return;
    const action=event.key.toLowerCase()==='p'?options.search:event.key.toLowerCase()==='t'?options.create:event.key.toLowerCase()==='w'?options.close:null;
    if(!action)return;event.preventDefault();event.stopImmediatePropagation();action();
  };
  root.addEventListener('keydown',key,true);return()=>root.removeEventListener('keydown',key,true);
}
