import type { AgentControlsSnapshot } from './agent-controls';
import type { PaneSummary, RunObservation } from '../generated/workspace-contract';

export type AgentObservationInput = Omit<AgentControlsSnapshot, 'observationRevision'> & { eventSeq: number };
export type AgentObservationTicket = Readonly<{ attempt: number; instanceId: string; generation: string; selection: string }>;

const validCounter = (value: number) => Number.isSafeInteger(value) && value >= 0;
const selection = (frame: Pick<AgentControlsSnapshot, 'project' | 'pane'>) =>
  JSON.stringify([frame.project?.project_id ?? null, frame.pane?.pane_id ?? null, frame.pane?.current_run_id ?? null]);
const identity = (run: RunObservation | null | undefined) => run ? [run.run_id, run.pane_id, run.current, run.process, run.work, run.evidence, run.exit_code] : null;
// Provider probes finish independently of the host runtime event stream.
// Only runtime facts must remain identical at one runtime event sequence.
const runtimeCanonical = (frame: AgentObservationInput) => JSON.stringify([
  frame.project && [frame.project.project_id, frame.project.display_name, frame.project.path, frame.project.root_state],
  frame.pane && [frame.pane.pane_id, frame.pane.project_id, frame.pane.display_name, frame.pane.path, frame.pane.current_run_id, identity(frame.pane.observation)],
]);
const canonical = (frame: AgentObservationInput) => JSON.stringify([
  runtimeCanonical(frame),
  frame.capabilities.state, frame.capabilities.providers?.map(row => [row.provider, row.version]) ?? null,
]);
const copy = <T>(value: T): T => structuredClone(value);
const sameRun = (a: PaneSummary | null, b: PaneSummary | null) => !!a && !!b && a.current_run_id !== null && a.current_run_id === b.current_run_id && a.pane_id === b.pane_id;

/** Commits one correlated host observation to one GUI generation. Delivery is not state evidence. */
export function createAgentObservation(initial: AgentControlsSnapshot) {
  if (!validCounter(initial.observationRevision)) throw new Error('Invalid observation revision');
  const lifetime = { instanceId: initial.instanceId, generation: initial.generation };
  let frame = copy(initial);
  let issued = 0;
  let settled = 0;
  let hostSeq = -1;
  let hostState: string | null = null;
  let hostSelection = selection(initial);
  let currentSelection = hostSelection;
  let retired = false;
  function next(nextFrame: AgentControlsSnapshot): AgentControlsSnapshot | null {
    if (!validCounter(frame.observationRevision + 1)) return null;
    frame = copy({ ...nextFrame, observationRevision: frame.observationRevision + 1 });
    return copy(frame);
  }
  function uncertain(): AgentControlsSnapshot | null {
    if (frame.availability === 'uncertain') return null;
    return next({ ...frame, availability: 'uncertain' });
  }
  function current(ticket: AgentObservationTicket) {
    return !retired && ticket.instanceId === lifetime.instanceId && ticket.generation === lifetime.generation &&
      ticket.selection === currentSelection && validCounter(ticket.attempt) && ticket.attempt === issued && ticket.attempt > settled;
  }
  return {
    getFrame: () => copy(frame),
    setLocal(value: Pick<AgentControlsSnapshot, 'project' | 'pane' | 'busy' | 'availability'>): AgentControlsSnapshot | null {
      if (retired) return null;
      const key = selection(value);
      const changed = key !== currentSelection;
      currentSelection = key;
      const old = frame;
      const project = copy(value.project);
      const pane = changed ? null : old.pane;
      const availability = changed || value.availability !== 'available' ? 'uncertain' : old.availability;
      const candidate = { ...old, project, pane, busy: value.busy, availability } satisfies AgentControlsSnapshot;
      if (JSON.stringify(candidate) === JSON.stringify(old)) return null;
      return next(candidate);
    },
    begin(): AgentObservationTicket | null {
      if (retired || !validCounter(issued + 1)) return null;
      return Object.freeze({ attempt: ++issued, ...lifetime, selection: currentSelection });
    },
    failure(ticket: AgentObservationTicket): AgentControlsSnapshot | null {
      if (!current(ticket)) return null;
      settled = ticket.attempt;
      return uncertain();
    },
    commit(ticket: AgentObservationTicket, value: AgentObservationInput): AgentControlsSnapshot | null {
      if (!current(ticket) || value.instanceId !== lifetime.instanceId || value.generation !== lifetime.generation ||
        selection(value) !== ticket.selection || !validCounter(value.eventSeq) || value.availability !== 'available') return null;
      settled = ticket.attempt;
      if (value.eventSeq < hostSeq) return null;
      const nextState = runtimeCanonical(value);
      if (value.eventSeq === hostSeq && hostSelection === ticket.selection && hostState !== nextState) return uncertain();
      if (sameRun(frame.pane, value.pane) && frame.pane?.observation?.process === 'exited' && value.pane?.observation?.process !== 'exited') return uncertain();
      if (value.pane?.current_run_id !== null && (!value.pane?.observation || value.pane.observation.run_id !== value.pane.current_run_id || !value.pane.observation.current || value.pane.observation.pane_id !== value.pane.pane_id)) return uncertain();
      hostSeq = value.eventSeq;
      hostState = nextState;
      hostSelection = ticket.selection;
      const { eventSeq: _eventSeq, ...display } = copy(value);
      const candidate: AgentControlsSnapshot = { ...display, observationRevision: frame.observationRevision };
      if (frame.availability === 'available' && canonical(value) === canonical({ ...frame, eventSeq: hostSeq })) return null;
      return next(candidate);
    },
    retire() { retired = true; },
  };
}
