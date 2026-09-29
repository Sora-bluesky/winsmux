import { Terminal } from 'xterm';
import { FitAddon } from '@xterm/addon-fit';
import 'xterm/css/xterm.css';
import { installTerminalMouseTrackingReset } from '../terminalMouseTracking';
import type { PaneSummary, OutputReadData } from '../generated/workspace-contract';
import type { ViewSnapshot, ControlIntent } from './project-pane';
import type { TerminalInputOwner } from './terminal-input';
import { installTerminalInputCodec } from './terminal-input-codec';

export interface TerminalMountOptions {
  snapshot(): ViewSnapshot;
  resize(target: Extract<ControlIntent, { kind: 'resize-pane' }>): boolean;
  input?: TerminalInputOwner;
}
export function mountProjectPaneTerminal(slot: HTMLElement, projectId: string, paneId: string, options: TerminalMountOptions) {
  let disposed = false; let runId: string | null = null; let cursor: string | null = null; let epoch = 0;
  let queued: Extract<ControlIntent, { kind: 'resize-pane' }> | null = null;
  let codec: ReturnType<typeof installTerminalInputCodec> | null = null; let inputIdentity='';
  const terminal = new Terminal({ disableStdin: true, cursorBlink: false, scrollback: 5000, screenReaderMode:true });
  const fit = new FitAddon(); terminal.loadAddon(fit); terminal.open(slot);
  const reset = installTerminalMouseTrackingReset({ parser: terminal.parser, write(data) { if (!disposed) terminal.write(data); } });
  const gap = slot.ownerDocument.createElement('p'); gap.className = 'workspace-output-gap'; gap.setAttribute('role', 'status'); slot.before(gap);
  function target(): PaneSummary | undefined {
    const snapshot = options.snapshot();
    return snapshot.projects.selected_project_id === projectId && snapshot.panes?.project_id === projectId ? snapshot.panes.panes.find(p => p.pane_id === paneId) : undefined;
  }
  function sync() {
    const current = target()?.current_run_id ?? null;
    if (current !== runId) { runId = current; cursor = null; epoch++; queued = null; terminal.reset(); gap.textContent = ''; }
    const snapshot=options.snapshot();
    const identity=current===null?'':JSON.stringify([snapshot.instanceId,snapshot.generation,projectId,paneId,current]);
    if (identity!==inputIdentity) {
      codec?.retire();codec=null;inputIdentity=identity;
      terminal.options.disableStdin=true;terminal.options.cursorBlink=false;slot.tabIndex=0;
      if (current!==null && options.input) {
        const producer=options.input.produce({instanceId:snapshot.instanceId,generation:snapshot.generation,projectId,paneId,runId:current,producerId:crypto.randomUUID()});
        codec=installTerminalInputCodec(slot,terminal,producer,options.input.explain);
        terminal.options.disableStdin=false;terminal.options.cursorBlink=true;slot.tabIndex=-1;
        if(terminal.textarea)terminal.textarea.tabIndex=0;
      }
    }
  }
  function offerResize() {
    if (disposed || !slot.isConnected) return;
    sync();
    if (runId === null) return;
    const snapshot = options.snapshot();
    const { rows, cols } = terminal;
    if (![rows, cols].every(n => Number.isInteger(n) && n >= 1 && n <= 32767)) return;
    queued = { instanceId: snapshot.instanceId, generation: snapshot.generation, topologyRevision: snapshot.topologyRevision, projectId, paneId, runId, kind: 'resize-pane', rows, cols };
  }
  const resize = terminal.onResize(offerResize);
  const observer = new ResizeObserver(() => { if (!disposed && slot.isConnected) { fit.fit(); offerResize(); } }); observer.observe(slot);
  return {
    sync,
    readTarget() { sync(); return disposed || runId === null ? null : { runId, cursor, epoch }; },
    append(captured: { runId: string; cursor: string | null; epoch: number }, data: OutputReadData) {
      sync(); if (disposed || captured.epoch !== epoch || captured.runId !== runId || captured.cursor !== cursor || data.run_id !== runId) return;
      if (data.gap || data.truncated) gap.textContent = '出力履歴の一部を取得できませんでした。';
      terminal.write(data.text); cursor = data.next_cursor;
    },
    flushResize() {
      sync(); if (disposed || !queued) return;
      const snapshot = options.snapshot(); const saved = queued;
      if (saved.instanceId !== snapshot.instanceId || saved.generation !== snapshot.generation || saved.topologyRevision !== snapshot.topologyRevision || saved.projectId !== snapshot.projects.selected_project_id || saved.runId !== runId) { queued = null; return; }
      if (snapshot.busy || snapshot.availability !== 'available') return;
      queued = null; options.resize(saved);
    },
    dispose() { if (disposed) return; disposed = true; epoch++; queued = null; codec?.retire();codec=null; observer.disconnect(); resize.dispose(); reset.dispose(); terminal.dispose(); gap.remove(); },
  };
}
