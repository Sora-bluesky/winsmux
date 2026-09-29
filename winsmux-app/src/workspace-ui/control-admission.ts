import type { TerminalInputOwner } from './terminal-input';

export type ControlKind = 'project' | 'resize' | 'agent' | 'register' | 'restore' | 'connection';
export interface ControlLease {
  readonly kind: ControlKind;
  readonly ticket: string;
  readonly host: string;
}

/** One host-local mutation lease across the project, agent and details surfaces. */
export function createControlAdmission(input: TerminalInputOwner) {
  let active: { lease: ControlLease; releaseInput: (() => void) | null } | null = null;
  const listeners = new Set<() => void>();
  function changed() { for (const listener of listeners) listener(); }
  function clear() {
    const previous = active;
    if (!previous) return;
    active = null;
    previous.releaseInput?.();
    changed();
  }
  return {
    reserve(host: string, kind: ControlKind, ticket: string): ControlLease | null {
      if (active || !host || !ticket || input.inspect().frozen) return null;
      const releaseInput = kind === 'resize' ? null : input.admitControl();
      if (kind !== 'resize' && !releaseInput) return null;
      const lease = Object.freeze({ host, kind, ticket });
      active = { lease, releaseInput };
      changed();
      return lease;
    },
    release(lease: ControlLease): boolean {
      if (active?.lease !== lease) return false;
      clear(); return true;
    },
    retireHost(host: string) { if (active?.lease.host === host) clear(); },
    current: () => active?.lease ?? null,
    busy: () => active !== null,
    observe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; },
  };
}
