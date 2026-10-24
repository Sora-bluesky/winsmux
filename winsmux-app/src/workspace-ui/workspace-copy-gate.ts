export interface CopyReservation {
  readonly ready: Promise<boolean>;
}

/** Pause new reads while copying; drain only calls already issued to native. */
export function createWorkspaceCopyGate() {
  const pending = new Set<Promise<void>>();
  const readers = new Set<() => void>();
  let retired = false;
  let active: CopyReservation | null = null;
  let retire!: (ready: boolean) => void;
  const retirement = new Promise<boolean>(resolve => { retire = resolve; });
  function wakeReaders() {
    const waiting = [...readers]; readers.clear();
    for (const wake of waiting) wake();
  }
  return {
    canReserveControl(reservation?: CopyReservation): boolean {
      return !retired && (reservation === undefined
        ? active === null : active !== null && active === reservation);
    },
    async send<T>(readOnly: boolean, invoke: () => Promise<T>): Promise<T> {
      if (active && !readOnly) throw new Error('host_not_sent');
      while (active && !retired) await new Promise<void>(resolve => readers.add(resolve));
      if (retired) throw new Error('session_closed');
      let complete!: () => void;
      const terminal = new Promise<void>(resolve => { complete = resolve; });
      // The check, registration and native invocation share one synchronous turn.
      pending.add(terminal);
      try { return await invoke(); }
      finally { pending.delete(terminal); complete(); }
    },
    beginCopy(): CopyReservation | null {
      if (retired || active) return null;
      const issued = [...pending];
      const reservation = Object.freeze({ ready: Promise.race([
        Promise.all(issued).then(() => !retired), retirement,
      ]) });
      active = reservation;
      return reservation;
    },
    endCopy(reservation: CopyReservation): boolean {
      if (retired || active !== reservation) return false;
      active = null; wakeReaders(); return true;
    },
    retire() {
      if (retired) return;
      retired = true; active = null; retire(false); wakeReaders();
    },
  };
}
