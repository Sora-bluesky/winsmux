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

export function persistableAgentVaultWorkspaceKey(key: string): string {
  const normalized = (key ?? "").trim();
  if (normalized === "__this_project__" || normalized === "unknown" || normalized === "workspace") {
    return normalized;
  }
  if (!normalized) {
    return "";
  }
  return "workspace";
}

export function recordFork(
  state: AgentVaultOrganizeState,
  fromId: string,
  workspaceKey: string,
): AgentVaultOrganizeMutationResult {
  const sourceId = readMutableSessionId(fromId);
  const key = persistableAgentVaultWorkspaceKey(readWorkspaceKey(workspaceKey));
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

export function isAbsoluteAgentVaultLaunchPath(value: string): boolean {
  const raw = value.trim();
  if (!raw) {
    return false;
  }
  return /^[A-Za-z]:[\\/]/.test(raw) || raw.startsWith("\\\\") || raw.startsWith("//") || raw.startsWith("/");
}

export function resolveAgentVaultLaunchDirectory(workspacePath: string, baseDir: string): string {
  const raw = (workspacePath ?? "").trim();
  const base = (baseDir ?? "").trim();
  if (raw.startsWith("workspace:")) {
    return "";
  }
  if (!raw || raw === "__this_project__") {
    return isAbsoluteAgentVaultLaunchPath(base) ? base : "";
  }
  if (isAbsoluteAgentVaultLaunchPath(raw)) {
    return raw;
  }
  if (!isAbsoluteAgentVaultLaunchPath(base)) {
    return "";
  }
  const segments = raw.split(/[\\/]+/).filter((part) => part.length > 0 && part !== ".");
  if (segments.some((part) => part === "..")) {
    return "";
  }
  const baseNormalized = base.replace(/[\\/]+$/, "").replace(/\\/g, "/");
  return segments.length === 0 ? baseNormalized : `${baseNormalized}/${segments.join("/")}`;
}

export function shouldQueueAgentVaultLaunchCwd(mode: "resume" | "fork", launchCwd: string): boolean {
  return mode === "fork" && launchCwd !== "";
}

export function applyAgentVaultGroupPrompt(
  state: AgentVaultOrganizeState,
  sessionId: string,
  name: string,
): AgentVaultOrganizeMutationResult {
  if (name.trim() === "") {
    return removeSessionFromGroup(state, sessionId);
  }
  const groupName = normalizeGroupName(name);
  if (!groupName) {
    return { ok: false, error: "Group name must be 1-64 visible characters." };
  }
  return assignSessionToGroup(state, sessionId, groupName);
}

export function normalizeAgentVaultText(value: string | null | undefined, fallback = ""): string {
  const normalized = (value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return normalized || fallback;
}

export function sanitizeAgentVaultDisplayText(value: string | null | undefined, fallback = ""): string {
  return normalizeAgentVaultText(value, fallback)
    .replace(/[A-Za-z]:[\\/][^\s"'<>]+/g, "[local path]")
    .replace(/\\\\[^\s"'<>]+/g, "[network path]");
}

export function truncateAgentVaultText(value: string, limit = 128): string {
  const normalized = sanitizeAgentVaultDisplayText(value);
  return normalized.length > limit ? `${normalized.slice(0, limit - 1)}…` : normalized;
}

function normalizeVaultPath(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/\\/g, "/").replace(/\/+$/, "");
}

export function getAgentVaultWorkspaceKey(
  path: string | null | undefined,
  snapshotProjectDir?: string | null,
  activeProjectDir?: string | null,
): string {
  const normalized = normalizeVaultPath(path);
  const active = normalizeVaultPath(activeProjectDir) || normalizeVaultPath(snapshotProjectDir);
  if (!normalized) {
    return "unknown";
  }
  if (active && normalized.toLowerCase() === active.toLowerCase()) {
    return "__this_project__";
  }
  return `workspace:${normalized.toLowerCase()}`;
}

export function getAgentVaultWorkspaceLabel(
  path: string | null | undefined,
  snapshotProjectDir: string | null | undefined,
  activeProjectDir: string | null | undefined,
  labels: { unknown: string; thisProject: string; workspace: string },
): string {
  const normalized = normalizeVaultPath(path);
  const active = normalizeVaultPath(activeProjectDir) || normalizeVaultPath(snapshotProjectDir);
  if (!normalized) {
    return labels.unknown;
  }
  if (active && normalized.toLowerCase() === active.toLowerCase()) {
    return labels.thisProject;
  }
  const parts = normalized.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? labels.workspace;
}

export function isAgentVaultThisProject(
  path: string | null | undefined,
  snapshotProjectDir?: string | null,
  activeProjectDir?: string | null,
): boolean {
  const normalized = normalizeVaultPath(path);
  const active = normalizeVaultPath(activeProjectDir) || normalizeVaultPath(snapshotProjectDir);
  return Boolean(normalized && active && normalized.toLowerCase() === active.toLowerCase());
}

export function inferAgentVaultProvider(...values: string[]): AgentVaultOrganizeProviderId {
  const text = values.join(" ").toLowerCase();
  if (text.includes("opencode") || text.includes("open code")) {
    return "opencode";
  }
  if (text.includes("codex")) {
    return "codex";
  }
  return "claude";
}

export function getAgentVaultReviewTone(reviewState: string, state: string): "danger" | "warning" | "success" | "info" {
  const review = reviewState.toUpperCase();
  const normalizedState = state.toLowerCase();
  if (review === "FAIL" || review === "FAILED" || normalizedState.includes("blocked")) {
    return "danger";
  }
  if (review === "PENDING" || normalizedState.includes("waiting")) {
    return "warning";
  }
  if (review === "PASS" || normalizedState.includes("ready")) {
    return "success";
  }
  return "info";
}

export function formatAgentVaultLastSeen(
  entryTime: string | null | undefined,
  fallbackTime: string | null | undefined,
  unseenLabel: string,
): string {
  const timestamp = normalizeAgentVaultText(entryTime || fallbackTime || "");
  if (!timestamp) {
    return unseenLabel;
  }
  const parsed = Date.parse(timestamp);
  if (Number.isNaN(parsed)) {
    return timestamp;
  }
  return new Date(parsed).toLocaleString([], {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function buildAgentVaultSearchText(entry: {
  id: string;
  provider: string;
  title: string;
  workspaceLabel: string;
  resumeId: string;
  paneId: string;
  runId: string;
  state: string;
  reviewState: string;
  summary: string;
  providerLabel?: string;
}): string {
  return [
    entry.id,
    entry.provider,
    entry.providerLabel ?? "",
    entry.title,
    entry.workspaceLabel,
    entry.resumeId,
    entry.paneId,
    entry.runId,
    entry.state,
    entry.reviewState,
    entry.summary,
  ].join(" ").toLowerCase();
}

export function createAgentVaultChip(label: string, value: string, tone?: string): HTMLSpanElement {
  const chip = document.createElement("span");
  chip.className = "agent-vault-chip";
  if (tone) {
    chip.dataset.tone = tone;
  }
  chip.textContent = `${label}: ${value}`;
  return chip;
}

export function appendAgentVaultSessionGroup<T>(
  list: HTMLElement,
  key: string,
  label: string,
  groupEntries: T[],
  collapsed: boolean,
  onToggle: () => void,
  renderCard: (entry: T) => HTMLElement,
): void {
  const group = document.createElement("section");
  group.className = "agent-vault-provider-group";
  group.dataset.groupKey = key;
  group.dataset.collapsed = collapsed ? "true" : "false";
  const heading = document.createElement("button");
  heading.type = "button";
  heading.className = "agent-vault-provider-heading";
  heading.setAttribute("aria-expanded", collapsed ? "false" : "true");
  heading.addEventListener("click", onToggle);
  const title = document.createElement("span");
  title.textContent = label;
  const count = document.createElement("span");
  count.className = "agent-vault-provider-count";
  count.textContent = `${groupEntries.length}`;
  heading.append(title, count);
  group.appendChild(heading);
  if (!collapsed) {
    for (const entry of groupEntries) {
      group.appendChild(renderCard(entry));
    }
  }
  list.appendChild(group);
}

export function getAgentVaultNotificationTone(feedEntries: Array<{ tone: string }>): "danger" | "warning" | "info" {
  if (feedEntries.some((entry) => entry.tone === "danger")) {
    return "danger";
  }
  if (feedEntries.some((entry) => entry.tone === "warning")) {
    return "warning";
  }
  return "info";
}

export function renderAgentVaultWorkspaceFilter<T extends { workspaceKey: string; workspaceLabel: string }>(
  root: HTMLSelectElement,
  entries: T[],
  selected: string,
  allLabel: string,
): string {
  const workspaceCounts = new Map<string, { label: string; count: number }>();
  for (const entry of entries) {
    const current = workspaceCounts.get(entry.workspaceKey);
    if (current) {
      current.count += 1;
    } else {
      workspaceCounts.set(entry.workspaceKey, { label: entry.workspaceLabel, count: 1 });
    }
  }
  let nextSelected = selected;
  if (nextSelected !== "all" && !workspaceCounts.has(nextSelected)) {
    nextSelected = "all";
  }
  root.replaceChildren();
  const allOption = document.createElement("option");
  allOption.value = "all";
  allOption.textContent = allLabel;
  root.appendChild(allOption);
  const workspaces = Array.from(workspaceCounts.entries())
    .sort((left, right) => left[1].label.localeCompare(right[1].label));
  for (const [key, workspace] of workspaces) {
    const option = document.createElement("option");
    option.value = key;
    option.textContent = `${workspace.label} (${workspace.count})`;
    root.appendChild(option);
  }
  root.value = nextSelected;
  return nextSelected;
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
  const workspaceKey = persistableAgentVaultWorkspaceKey(readWorkspaceKey(record.workspaceKey));
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

export function persistAgentVaultOrganizeToStorage(
  storage: Pick<Storage, "setItem"> | null | undefined,
  state: AgentVaultOrganizeState,
): { ok: true } | { ok: false; error: string } {
  if (!storage) {
    return { ok: false, error: "Agent Vault organize data could not be saved." };
  }
  try {
    storage.setItem(AGENT_VAULT_ORGANIZE_STORAGE_KEY, serializeAgentVaultOrganize(state));
    return { ok: true };
  } catch {
    return { ok: false, error: "Agent Vault organize data could not be saved." };
  }
}

export function partitionEntriesByUserGroup<T extends { id: string }>(
  entries: T[],
  organize: AgentVaultOrganizeState,
): { groups: Array<{ id: string; name: string; entries: T[] }>; ungrouped: T[] } {
  const groupedIds = new Set<string>();
  const groups: Array<{ id: string; name: string; entries: T[] }> = [];
  for (const group of organize.groups) {
    const members = entries.filter((entry) => group.sessionIds.includes(entry.id));
    if (members.length === 0) {
      continue;
    }
    for (const member of members) {
      groupedIds.add(member.id);
    }
    groups.push({ id: group.id, name: group.name, entries: members });
  }
  return {
    groups,
    ungrouped: entries.filter((entry) => !groupedIds.has(entry.id)),
  };
}

export function createAgentVaultActionButton(
  label: string,
  disabled: boolean,
  onClick: (event: MouseEvent) => void,
): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "agent-vault-action";
  button.textContent = label;
  button.disabled = disabled;
  button.addEventListener("click", onClick);
  return button;
}

export function appendAgentVaultOrganizeActions(
  actions: HTMLElement,
  options: {
    archived: boolean;
    forkDisabled: boolean;
    labels: { archive: string; unarchive: string; group: string; fork: string };
    onArchive: (event: MouseEvent) => void;
    onGroup: (event: MouseEvent) => void;
    onFork: (event: MouseEvent) => void;
  },
): void {
  actions.append(
    createAgentVaultActionButton(
      options.archived ? options.labels.unarchive : options.labels.archive,
      false,
      options.onArchive,
    ),
    createAgentVaultActionButton(options.labels.group, false, options.onGroup),
    createAgentVaultActionButton(options.labels.fork, options.forkDisabled, options.onFork),
  );
}

export function ensureAgentVaultShowArchivedToggle(
  parent: HTMLElement | null,
  options: { pressed: boolean; label: string; onToggle: () => void },
): void {
  if (!parent) {
    return;
  }
  let button = parent.querySelector("#agent-vault-show-archived") as HTMLButtonElement | null;
  if (!button) {
    button = document.createElement("button");
    button.id = "agent-vault-show-archived";
    button.type = "button";
    button.className = "agent-vault-filter-btn";
    button.addEventListener("click", options.onToggle);
    parent.appendChild(button);
  }
  button.textContent = options.label;
  button.setAttribute("aria-pressed", options.pressed ? "true" : "false");
}
