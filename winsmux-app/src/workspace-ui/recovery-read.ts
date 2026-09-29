/** A query attempt belongs to one connection epoch, not to the mutation it observes. */
export function createRecoveryReadGate() {
  let epoch = 0;
  let serial = 0;
  let active: ReadAttempt | null = null;

  type ReadAttempt = Readonly<{ epoch: number; serial: number }>;
  return {
    epoch: () => epoch,
    invalidate() { epoch++; active = null; },
    begin(): ReadAttempt | null {
      if (active) return null;
      const attempt = Object.freeze({ epoch, serial: ++serial });
      active = attempt;
      return attempt;
    },
    current(attempt: ReadAttempt): boolean { return active === attempt && attempt.epoch === epoch; },
    end(attempt: ReadAttempt): void { if (active === attempt) active = null; },
  };
}
