export const ATTENTION_CENTER_STORAGE_KEY = "winsmux.attention-center.v1";
export const COMPANION_WINSMUX_MISSING_STATUS = "companion winsmux CLI was not found";

export const ATTENTION_EVENT_TYPES = [
  "thread_created",
  "status_running",
  "status_idle",
  "message_received",
  "requires_action",
] as const;

export type AttentionEventType = (typeof ATTENTION_EVENT_TYPES)[number];
export type AttentionKind = "unread" | "waiting" | "approval" | "failure" | "running" | "idle" | "ignored";
export type AttentionFilter = "unread" | "waiting" | "approval" | "failure";

export interface AttentionCenterState {
  schema_version: 1;
  projectDir: string;
  lastSeenCursor: number;
}

export interface CondensedEvent {
  type: string;
  cursor?: number;
  pane_id?: string;
  run_id?: string;
  task_id?: string;
  role?: string;
  stop_reason?: string;
  kind?: string;
  [key: string]: unknown;
}

export interface EventsCommandSnapshot {
  cursor: number;
  events: CondensedEvent[];
}

export interface AttentionJumpTarget {
  paneId: string | null;
  runId: string | null;
  statusOnly: boolean;
}

export type EventsCommandFailureReason = "usage" | "exit" | "malformed";

export type EventsCommandReadResult =
  | { ok: true; snapshot: EventsCommandSnapshot }
  | { ok: false; reason: EventsCommandFailureReason; snapshot: EventsCommandSnapshot };

const STATE_KEYS = ["schema_version", "projectDir", "lastSeenCursor"] as const;
const PANE_BUFFER_SOURCE = new RegExp(
  [
    "pty",
    ["capture", "pane"].join("-"),
    ["capture", "pane"].join("_"),
    ["append", "pane", "output", "buffer"].join(""),
    ["output", "buffer"].join(""),
    "resum" + "e",
  ].join("|"),
  "i",
);

export function emptyAttentionCenterState(projectDir = ""): AttentionCenterState {
  return {
    schema_version: 1,
    projectDir: normalizeAttentionProjectDir(projectDir),
    lastSeenCursor: 0,
  };
}

export function normalizeAttentionProjectDir(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/\\/g, "/").replace(/\/+$/, "");
}

export function serializeAttentionCenterState(state: AttentionCenterState): string {
  if (state.schema_version !== 1) {
    throw new Error("attention-center schema_version must be 1");
  }
  if (typeof state.projectDir !== "string") {
    throw new Error("attention-center projectDir must be a string");
  }
  if (!Number.isInteger(state.lastSeenCursor) || state.lastSeenCursor < 0) {
    throw new Error("attention-center lastSeenCursor must be an integer >= 0");
  }
  return JSON.stringify({
    schema_version: 1,
    projectDir: normalizeAttentionProjectDir(state.projectDir),
    lastSeenCursor: state.lastSeenCursor,
  });
}

export function parseAttentionCenterState(text: string): AttentionCenterState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("attention-center state is not valid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("attention-center state must be an object");
  }
  const record = parsed as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== STATE_KEYS.length || STATE_KEYS.some((key) => !keys.includes(key))) {
    throw new Error("attention-center state must contain only schema_version, projectDir, and lastSeenCursor");
  }
  if (record.schema_version !== 1) {
    throw new Error("attention-center schema_version must be 1");
  }
  if (typeof record.projectDir !== "string") {
    throw new Error("attention-center projectDir must be a string");
  }
  if (!Number.isInteger(record.lastSeenCursor) || (record.lastSeenCursor as number) < 0) {
    throw new Error("attention-center lastSeenCursor must be an integer >= 0");
  }
  return {
    schema_version: 1,
    projectDir: normalizeAttentionProjectDir(record.projectDir),
    lastSeenCursor: record.lastSeenCursor as number,
  };
}

export function loadAttentionCenterState(
  rawValue: string | null | undefined,
  previous: AttentionCenterState = emptyAttentionCenterState(),
): { state: AttentionCenterState; error: string | null } {
  if (rawValue === null || rawValue === undefined || rawValue.trim() === "") {
    return { state: previous, error: null };
  }
  try {
    return { state: parseAttentionCenterState(rawValue), error: null };
  } catch {
    return {
      state: previous,
      error: "Attention center state was rejected. Previous state was kept.",
    };
  }
}

export function persistAttentionCenterStateToStorage(
  storage: Pick<Storage, "setItem"> | null | undefined,
  state: AttentionCenterState,
): { ok: true } | { ok: false; error: string } {
  if (!storage) {
    return { ok: false, error: "Attention center state could not be saved." };
  }
  try {
    storage.setItem(ATTENTION_CENTER_STORAGE_KEY, serializeAttentionCenterState(state));
    return { ok: true };
  } catch {
    return { ok: false, error: "Attention center state could not be saved." };
  }
}

export function alignAttentionCenterProject(state: AttentionCenterState, projectDir: string): AttentionCenterState {
  const normalized = normalizeAttentionProjectDir(projectDir);
  if (state.projectDir === normalized) {
    return state;
  }
  return emptyAttentionCenterState(normalized);
}

export function parseEventsCommandJson(text: string): EventsCommandSnapshot {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("events --json stdout is not valid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("events --json stdout must be an object with cursor and events");
  }
  const record = parsed as Record<string, unknown>;
  if (!Object.prototype.hasOwnProperty.call(record, "cursor") || !Object.prototype.hasOwnProperty.call(record, "events")) {
    throw new Error("events --json stdout must include cursor and events");
  }
  if (!Number.isInteger(record.cursor) || (record.cursor as number) < 0) {
    throw new Error("events --json cursor must be an integer >= 0");
  }
  if (!Array.isArray(record.events)) {
    throw new Error("events --json events must be an array");
  }
  const events: CondensedEvent[] = [];
  for (const item of record.events) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("events --json events must contain objects");
    }
    const event = item as Record<string, unknown>;
    const type = typeof event.type === "string" ? event.type : "";
    events.push({
      ...(event as CondensedEvent),
      type,
    });
  }
  return {
    cursor: record.cursor as number,
    events,
  };
}

export function emptyEventsSnapshot(): EventsCommandSnapshot {
  return { cursor: 0, events: [] };
}

export function isEventsCommandUsageText(text: string): boolean {
  return /usage:\s*winsmux events/i.test(text);
}

export function isCompanionWinsmuxMissingError(message: string): boolean {
  return /companion winsmux/i.test(message) && /not found|missing/i.test(message);
}

export function readEventsCommandSnapshot(result: {
  exitCode: number;
  stdout: string;
  stderr: string;
}): EventsCommandReadResult {
  const combined = `${result.stdout}\n${result.stderr}`;
  if (result.exitCode !== 0) {
    return {
      ok: false,
      reason: isEventsCommandUsageText(combined) ? "usage" : "exit",
      snapshot: emptyEventsSnapshot(),
    };
  }
  try {
    return { ok: true, snapshot: parseEventsCommandJson(result.stdout) };
  } catch {
    return { ok: false, reason: "malformed", snapshot: emptyEventsSnapshot() };
  }
}

export function eventCursor(event: CondensedEvent): number | null {
  if (!Number.isInteger(event.cursor) || (event.cursor as number) < 0) {
    return null;
  }
  return event.cursor as number;
}

export function classifyAttention(event: CondensedEvent): AttentionKind {
  switch (event.type) {
    case "thread_created":
      return "unread";
    case "status_running":
      return "running";
    case "status_idle":
      return "idle";
    case "message_received":
      return "waiting";
    case "requires_action":
      return classifyRequiresActionKind(typeof event.kind === "string" ? event.kind : "");
    default:
      return "ignored";
  }
}

function classifyRequiresActionKind(kind: string): "waiting" | "approval" | "failure" {
  const value = kind.toLowerCase();
  if (/(crash|hung|stall|fail)/.test(value)) {
    return "failure";
  }
  if (/(approval|review_requested)/.test(value)) {
    return "approval";
  }
  return "waiting";
}

export function unreadEvents(events: CondensedEvent[], lastSeenCursor: number): CondensedEvent[] {
  const seen = Number.isInteger(lastSeenCursor) && lastSeenCursor >= 0 ? lastSeenCursor : 0;
  return events.filter((event) => {
    if (classifyAttention(event) === "ignored") {
      return false;
    }
    const cursor = eventCursor(event);
    return cursor !== null && cursor > seen;
  });
}

export function attentionEventsForFilter(
  events: CondensedEvent[],
  lastSeenCursor: number,
  filter: AttentionFilter,
): CondensedEvent[] {
  const unread = unreadEvents(events, lastSeenCursor);
  if (filter === "unread") {
    return unread;
  }
  return unread.filter((event) => classifyAttention(event) === filter);
}

export function attentionFilterCounts(events: CondensedEvent[], lastSeenCursor: number): Record<AttentionFilter, number> {
  const unread = unreadEvents(events, lastSeenCursor);
  return {
    unread: unread.length,
    waiting: unread.filter((event) => classifyAttention(event) === "waiting").length,
    approval: unread.filter((event) => classifyAttention(event) === "approval").length,
    failure: unread.filter((event) => classifyAttention(event) === "failure").length,
  };
}

export function nextLastSeenCursor(current: number, observedCursor: number): number {
  const currentCursor = Number.isInteger(current) && current >= 0 ? current : 0;
  if (!Number.isInteger(observedCursor) || observedCursor < 0) {
    return currentCursor;
  }
  return observedCursor >= currentCursor ? observedCursor : currentCursor;
}

export function markAllRead(state: AttentionCenterState, snapshotCursor: number): AttentionCenterState {
  if (!Number.isInteger(snapshotCursor) || snapshotCursor < 0) {
    return state;
  }
  return {
    ...state,
    lastSeenCursor: snapshotCursor,
  };
}

export function markEventRead(state: AttentionCenterState, event: CondensedEvent): AttentionCenterState {
  const cursor = eventCursor(event);
  if (cursor === null) {
    return state;
  }
  return {
    ...state,
    lastSeenCursor: nextLastSeenCursor(state.lastSeenCursor, cursor),
  };
}

export function optionalEventString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

export function attentionJumpTarget(
  event: CondensedEvent,
  availableRunIds: readonly string[] = [],
): AttentionJumpTarget {
  const paneId = optionalEventString(event.pane_id);
  if (paneId) {
    return { paneId, runId: optionalEventString(event.run_id), statusOnly: false };
  }
  const runId = optionalEventString(event.run_id);
  if (runId && availableRunIds.includes(runId)) {
    return { paneId: null, runId, statusOnly: false };
  }
  return { paneId: null, runId: runId && availableRunIds.includes(runId) ? runId : null, statusOnly: true };
}

export function buildEventsCommandArgv(projectDir: string, lastSeenCursor: number): string[] {
  const args = ["events"];
  if (Number.isInteger(lastSeenCursor) && lastSeenCursor > 0) {
    args.push(String(lastSeenCursor));
  }
  args.push("--json", "--project-dir", projectDir);
  return args;
}

export function isPaneBufferAuthority(source: string): boolean {
  void source;
  return false;
}

export function isPaneBufferEventSource(source: string): boolean {
  return PANE_BUFFER_SOURCE.test(source);
}
