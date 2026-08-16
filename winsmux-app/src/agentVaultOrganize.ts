export const AGENT_VAULT_ORGANIZE_STORAGE_KEY = "winsmux.agent-vault.organize.v1";

export type AgentVaultOrganizeProviderId = "claude" | "codex" | "opencode";

export interface AgentVaultOrganizeGroup {
  id: string;
  name: string;
  sessionIds: string[];
}

export interface AgentVaultOrganizeFork {
  id: string;
  fromId: string;
  workspaceKey: string;
}

export interface AgentVaultOrganizeState {
  schema_version: 1;
  archivedIds: string[];
  groups: AgentVaultOrganizeGroup[];
  forks: AgentVaultOrganizeFork[];
}

export interface AgentVaultOrganizeEntryRef {
  id: string;
  searchText?: string;
  provider?: string;
  workspaceKey?: string;
  title?: string;
}

export type AgentVaultOrganizeMutationResult =
  | { ok: true; state: AgentVaultOrganizeState }
  | { ok: false; error: string };

const TOP_LEVEL_KEYS = ["schema_version", "archivedIds", "groups", "forks"] as const;
const GROUP_KEYS = ["id", "name", "sessionIds"] as const;
const FORK_KEYS = ["id", "fromId", "workspaceKey"] as const;
const GROUP_ID_PATTERN = /^grp_[A-Za-z0-9]+$/;
const FORK_ID_PATTERN = /^fork_[A-Za-z0-9]+$/;
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/;
const RESUME_COMMAND_PATTERN =
  /(?:^|[\s;&|])(?:claude\s+--resume|codex\s+resume|opencode\s+--session)(?:\s|$)/i;

export function emptyAgentVaultOrganize(): AgentVaultOrganizeState {
  return {
    schema_version: 1,
    archivedIds: [],
    groups: [],
    forks: [],
  };
}

export function parseAgentVaultOrganizeJson(text: string | null | undefined): AgentVaultOrganizeState {
  if (text == null || text.trim() === "") {
    return emptyAgentVaultOrganize();
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("Agent Vault organize data is not valid JSON.");
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Agent Vault organize data must be an object.");
  }

  const record = parsed as Record<string, unknown>;
  assertExactKeys(record, TOP_LEVEL_KEYS, "Agent Vault organize data");
  if (record.schema_version !== 1) {
    throw new Error("Agent Vault organize schema_version must be 1.");
  }
  if (!Array.isArray(record.archivedIds) || !Array.isArray(record.groups) || !Array.isArray(record.forks)) {
    throw new Error("Agent Vault organize archivedIds, groups, and forks must be arrays.");
  }

  const archivedIds = record.archivedIds.map((id, index) => readSessionId(id, `archivedIds[${index}]`));
  assertUniqueStrings(archivedIds, "archivedIds");

  const groups = record.groups.map((item, index) => parseGroup(item, index));
  const forks = record.forks.map((item, index) => parseFork(item, index));
  assertUniqueStrings(groups.map((group) => group.id), "group id");
  assertUniqueStrings(forks.map((fork) => fork.id), "fork id");
  assertSessionInAtMostOneGroup(groups);

  return {
    schema_version: 1,
    archivedIds,
    groups,
    forks,
  };
}

export function serializeAgentVaultOrganize(state: AgentVaultOrganizeState): string {
  const normalized = parseAgentVaultOrganizeJson(JSON.stringify({
    schema_version: 1,
    archivedIds: state.archivedIds,
    groups: state.groups,
    forks: state.forks,
  }));
  return JSON.stringify({
    schema_version: 1,
    archivedIds: normalized.archivedIds,
    groups: normalized.groups.map((group) => ({
      id: group.id,
      name: group.name,
      sessionIds: group.sessionIds,
    })),
    forks: normalized.forks.map((fork) => ({
      id: fork.id,
      fromId: fork.fromId,
      workspaceKey: fork.workspaceKey,
    })),
  });
}

export function archiveSession(state: AgentVaultOrganizeState, sessionId: string): AgentVaultOrganizeMutationResult {
  const id = readMutableSessionId(sessionId);
  if (!id) {
    return { ok: false, error: "Archive requires a vault session id." };
  }
  const next = cloneOrganizeState(state);
  if (!next.archivedIds.includes(id)) {
    next.archivedIds.push(id);
  }
  return { ok: true, state: next };
}

export function unarchiveSession(state: AgentVaultOrganizeState, sessionId: string): AgentVaultOrganizeMutationResult {
  const id = readMutableSessionId(sessionId);
  if (!id) {
    return { ok: false, error: "Unarchive requires a vault session id." };
  }
  const next = cloneOrganizeState(state);
  next.archivedIds = next.archivedIds.filter((item) => item !== id);
  return { ok: true, state: next };
}

export function assignSessionToGroup(
  state: AgentVaultOrganizeState,
  sessionId: string,
  name: string,
): AgentVaultOrganizeMutationResult {
  const id = readMutableSessionId(sessionId);
  if (!id) {
    return { ok: false, error: "Group requires a vault session id." };
  }
  const groupName = normalizeGroupName(name);
  if (!groupName) {
    return { ok: false, error: "Group name must be 1-64 visible characters." };
  }

  const next = cloneOrganizeState(state);
  removeSessionFromGroups(next, id);
  const existing = next.groups.find((group) => group.name === groupName);
  if (existing) {
    if (!existing.sessionIds.includes(id)) {
      existing.sessionIds.push(id);
    }
    return { ok: true, state: next };
  }

  next.groups.push({
    id: nextOrganizeId("grp", next.groups.map((group) => group.id)),
    name: groupName,
    sessionIds: [id],
  });
  return { ok: true, state: next };
}

export function removeSessionFromGroup(
  state: AgentVaultOrganizeState,
  sessionId: string,
): AgentVaultOrganizeMutationResult {
  const id = readMutableSessionId(sessionId);
  if (!id) {
    return { ok: false, error: "Remove from group requires a vault session id." };
  }
  const next = cloneOrganizeState(state);
  removeSessionFromGroups(next, id);
  return { ok: true, state: next };
}

export function recordFork(
  state: AgentVaultOrganizeState,
  fromId: string,
  workspaceKey: string,
): AgentVaultOrganizeMutationResult {
  const sourceId = readMutableSessionId(fromId);
  const key = readWorkspaceKey(workspaceKey);
  if (!sourceId || !key) {
    return { ok: false, error: "Fork requires a vault session id and workspace." };
  }
  const next = cloneOrganizeState(state);
  next.forks.push({
    id: nextOrganizeId("fork", next.forks.map((fork) => fork.id)),
    fromId: sourceId,
    workspaceKey: key,
  });
  return { ok: true, state: next };
}

export function isArchived(state: AgentVaultOrganizeState, sessionId: string): boolean {
  return state.archivedIds.includes(sessionId);
}

export function groupNameForSession(state: AgentVaultOrganizeState, sessionId: string): string | null {
  const group = state.groups.find((item) => item.sessionIds.includes(sessionId));
  return group?.name ?? null;
}

export function visibleVaultEntryIds(
  entries: Array<Pick<AgentVaultOrganizeEntryRef, "id">>,
  organize: AgentVaultOrganizeState,
  showArchived: boolean,
): string[] {
  return entries
    .filter((entry) => showArchived || !isArchived(organize, entry.id))
    .map((entry) => entry.id);
}

export function searchTextWithGroupName(
  entry: Pick<AgentVaultOrganizeEntryRef, "id" | "searchText">,
  organize: AgentVaultOrganizeState,
): string {
  const groupName = groupNameForSession(organize, entry.id);
  return [entry.searchText ?? "", groupName ?? ""].join(" ").trim().toLowerCase();
}

export function quotePowerShellArgument(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

export function buildAgentVaultResumeCommand(provider: string, resumeId: string): string {
  const safeResumeId = normalizeResumeId(resumeId);
  if (!safeResumeId) {
    return "";
  }
  switch (provider) {
    case "claude":
      return `claude --resume ${quotePowerShellArgument(safeResumeId)}`;
    case "codex":
      return `codex resume ${quotePowerShellArgument(safeResumeId)}`;
    case "opencode":
      return `opencode --session ${quotePowerShellArgument(safeResumeId)}`;
    default:
      return "";
  }
}

export function buildAgentVaultForkLaunchCommand(provider: string): string {
  switch (provider) {
    case "claude":
      return "claude";
    case "codex":
      return "codex";
    case "opencode":
      return "opencode";
    default:
      return "";
  }
}

export function isResumeCommand(command: string): boolean {
  const normalized = command.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return false;
  }
  return RESUME_COMMAND_PATTERN.test(` ${normalized} `);
}

export function loadAgentVaultOrganize(
  rawValue: string | null | undefined,
  previous: AgentVaultOrganizeState = emptyAgentVaultOrganize(),
): { state: AgentVaultOrganizeState; error: string | null } {
  try {
    return { state: parseAgentVaultOrganizeJson(rawValue), error: null };
  } catch {
    return {
      state: previous,
      error: "Agent Vault organize data was rejected. Previous state was kept.",
    };
  }
}

export function normalizeGroupName(value: unknown): string {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  if (!trimmed || CONTROL_CHARS.test(trimmed)) {
    return "";
  }
  if ([...trimmed].length > 64) {
    return "";
  }
  return trimmed;
}

function parseGroup(value: unknown, index: number): AgentVaultOrganizeGroup {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`groups[${index}] must be an object.`);
  }
  const record = value as Record<string, unknown>;
  assertExactKeys(record, GROUP_KEYS, `groups[${index}]`);
  if (typeof record.id !== "string" || !GROUP_ID_PATTERN.test(record.id)) {
    throw new Error(`groups[${index}].id is invalid.`);
  }
  const name = normalizeGroupName(record.name);
  if (!name) {
    throw new Error(`groups[${index}].name is invalid.`);
  }
  if (!Array.isArray(record.sessionIds)) {
    throw new Error(`groups[${index}].sessionIds must be an array.`);
  }
  const sessionIds = record.sessionIds.map((id, sessionIndex) => (
    readSessionId(id, `groups[${index}].sessionIds[${sessionIndex}]`)
  ));
  assertUniqueStrings(sessionIds, `groups[${index}].sessionIds`);
  return { id: record.id, name, sessionIds };
}

function parseFork(value: unknown, index: number): AgentVaultOrganizeFork {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`forks[${index}] must be an object.`);
  }
  const record = value as Record<string, unknown>;
  assertExactKeys(record, FORK_KEYS, `forks[${index}]`);
  if (typeof record.id !== "string" || !FORK_ID_PATTERN.test(record.id)) {
    throw new Error(`forks[${index}].id is invalid.`);
  }
  const workspaceKey = readWorkspaceKey(record.workspaceKey);
  if (!workspaceKey) {
    throw new Error(`forks[${index}].workspaceKey is invalid.`);
  }
  return {
    id: record.id,
    fromId: readSessionId(record.fromId, `forks[${index}].fromId`),
    workspaceKey,
  };
}

function assertExactKeys(record: Record<string, unknown>, allowed: readonly string[], label: string) {
  const keys = Object.keys(record);
  if (keys.length !== allowed.length || allowed.some((key) => !keys.includes(key))) {
    throw new Error(`${label} must contain only ${allowed.join(", ")}.`);
  }
}

function assertUniqueStrings(values: string[], label: string) {
  if (new Set(values).size !== values.length) {
    throw new Error(`${label} must not contain duplicates.`);
  }
}

function assertSessionInAtMostOneGroup(groups: AgentVaultOrganizeGroup[]) {
  const seen = new Set<string>();
  for (const group of groups) {
    for (const sessionId of group.sessionIds) {
      if (seen.has(sessionId)) {
        throw new Error("A session id may belong to at most one group.");
      }
      seen.add(sessionId);
    }
  }
}

function readSessionId(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim() || CONTROL_CHARS.test(value)) {
    throw new Error(`${label} must be a vault session id.`);
  }
  return value;
}

function readMutableSessionId(value: string): string {
  const normalized = value.trim();
  if (!normalized || CONTROL_CHARS.test(normalized)) {
    return "";
  }
  return normalized;
}

function readWorkspaceKey(value: unknown): string {
  if (typeof value !== "string") {
    return "";
  }
  const normalized = value.trim();
  if (!normalized || CONTROL_CHARS.test(normalized) || normalized.length > 1024) {
    return "";
  }
  return normalized;
}

function normalizeResumeId(value: string): string {
  const normalized = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (!normalized || normalized.length > 512) {
    return "";
  }
  return normalized;
}

function cloneOrganizeState(state: AgentVaultOrganizeState): AgentVaultOrganizeState {
  return {
    schema_version: 1,
    archivedIds: [...state.archivedIds],
    groups: state.groups.map((group) => ({
      id: group.id,
      name: group.name,
      sessionIds: [...group.sessionIds],
    })),
    forks: state.forks.map((fork) => ({
      id: fork.id,
      fromId: fork.fromId,
      workspaceKey: fork.workspaceKey,
    })),
  };
}

function removeSessionFromGroups(state: AgentVaultOrganizeState, sessionId: string) {
  for (const group of state.groups) {
    group.sessionIds = group.sessionIds.filter((id) => id !== sessionId);
  }
}

function nextOrganizeId(prefix: "grp" | "fork", existingIds: string[]): string {
  const existing = new Set(existingIds);
  for (let index = 1; index < 10000; index += 1) {
    const id = `${prefix}_${String(index).padStart(2, "0")}`;
    if (!existing.has(id)) {
      return id;
    }
  }
  throw new Error("Could not allocate an organize id.");
}
