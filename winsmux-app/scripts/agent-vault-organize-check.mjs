import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadAgentVaultOrganizeModule() {
  const sourcePath = path.resolve("src/agentVaultOrganize.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-agent-vault-organize-"));
  const modulePath = path.join(tempDir, "agentVaultOrganize.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  AGENT_VAULT_ORGANIZE_STORAGE_KEY,
  archiveSession,
  assignSessionToGroup,
  buildAgentVaultForkLaunchCommand,
  buildAgentVaultResumeCommand,
  resolveAgentVaultLaunchDirectory,
  shouldQueueAgentVaultLaunchCwd,
  applyAgentVaultGroupPrompt,
  persistableAgentVaultWorkspaceKey,
  emptyAgentVaultOrganize,
  groupNameForSession,
  isArchived,
  isResumeCommand,
  loadAgentVaultOrganize,
  parseAgentVaultOrganizeJson,
  recordFork,
  removeSessionFromGroup,
  searchTextWithGroupName,
  serializeAgentVaultOrganize,
  unarchiveSession,
  visibleVaultEntryIds,
} = await loadAgentVaultOrganizeModule();

const entries = [
  { id: "summary:run-id", searchText: "summary run-id claude title workspace" },
  { id: "worker:w1", searchText: "worker w1 codex other" },
];

function assertOk(result) {
  assert.equal(result.ok, true, result.error ?? "expected organize mutation to succeed");
  return result.state;
}

// V01: empty / missing JSON → default empty organize; all entries visible
const v01Empty = parseAgentVaultOrganizeJson("");
const v01Missing = parseAgentVaultOrganizeJson(undefined);
assert.deepEqual(v01Empty, emptyAgentVaultOrganize());
assert.deepEqual(v01Missing, emptyAgentVaultOrganize());
assert.deepEqual(v01Empty, {
  schema_version: 1,
  archivedIds: [],
  groups: [],
  forks: [],
});
assert.deepEqual(visibleVaultEntryIds(entries, v01Empty, false), ["summary:run-id", "worker:w1"]);
assert.equal(AGENT_VAULT_ORGANIZE_STORAGE_KEY, "winsmux.agent-vault.organize.v1");

// V02: archive id → hidden unless showArchived
const v02 = assertOk(archiveSession(emptyAgentVaultOrganize(), "summary:run-id"));
assert.equal(isArchived(v02, "summary:run-id"), true);
assert.deepEqual(visibleVaultEntryIds(entries, v02, false), ["worker:w1"]);
assert.deepEqual(visibleVaultEntryIds(entries, v02, true), ["summary:run-id", "worker:w1"]);

// V03: unarchive → visible again
const v03 = assertOk(unarchiveSession(v02, "summary:run-id"));
assert.equal(isArchived(v03, "summary:run-id"), false);
assert.deepEqual(visibleVaultEntryIds(entries, v03, false), ["summary:run-id", "worker:w1"]);

// V04: assign group name → session in exactly one group; search text includes name
const v04 = assertOk(assignSessionToGroup(emptyAgentVaultOrganize(), "summary:run-id", "release"));
assert.equal(v04.groups.length, 1);
assert.equal(groupNameForSession(v04, "summary:run-id"), "release");
assert.equal(v04.groups.filter((group) => group.sessionIds.includes("summary:run-id")).length, 1);
assert.match(searchTextWithGroupName(entries[0], v04), /release/);
assert.equal(searchTextWithGroupName(entries[1], v04).includes("release"), false);

// V05: move to second group → removed from first
const v05 = assertOk(assignSessionToGroup(v04, "summary:run-id", "hotfix"));
assert.equal(groupNameForSession(v05, "summary:run-id"), "hotfix");
assert.equal(v05.groups.find((group) => group.name === "release")?.sessionIds.includes("summary:run-id") ?? false, false);
assert.equal(v05.groups.filter((group) => group.sessionIds.includes("summary:run-id")).length, 1);

// V06: empty / control-char group name → reject; previous state unchanged
const v06Previous = structuredClone(v04);
const v06Empty = assignSessionToGroup(v04, "summary:run-id", "   ");
const v06Control = assignSessionToGroup(v04, "summary:run-id", "bad\u0007name");
assert.equal(v06Empty.ok, false);
assert.equal(v06Control.ok, false);
assert.deepEqual(v04, v06Previous);
assert.equal(groupNameForSession(v04, "summary:run-id"), "release");

// V07: extra JSON key / schema_version ≠ 1 → reject
assert.throws(() => parseAgentVaultOrganizeJson('{"schema_version":1,"archivedIds":[],"groups":[],"forks":[],"extra":true}'));
assert.throws(() => parseAgentVaultOrganizeJson('{"schema_version":2,"archivedIds":[],"groups":[],"forks":[]}'));
assert.throws(() => parseAgentVaultOrganizeJson('{"schema_version":1,"archivedIds":[],"groups":[{"id":"grp_01","name":"release","sessionIds":["summary:run-id"],"extra":1}],"forks":[]}'));
assert.throws(() => parseAgentVaultOrganizeJson('{"schema_version":1,"archivedIds":[],"groups":[],"forks":[{"id":"fork_01","fromId":"summary:run-id","workspaceKey":"C:/proj","extra":1}]}'));
assert.throws(() => parseAgentVaultOrganizeJson("[]"));
assert.throws(() => parseAgentVaultOrganizeJson("{"));
const v07Previous = structuredClone(v04);
const v07Loaded = loadAgentVaultOrganize('{"schema_version":1,"archivedIds":[],"groups":[],"forks":[],"extra":true}', v04);
assert.equal(v07Loaded.error.includes("rejected"), true);
assert.deepEqual(v07Loaded.state, v07Previous);

// V08: fork record → fromId preserved; does not archive source
const v08 = assertOk(recordFork(emptyAgentVaultOrganize(), "summary:run-id", "C:/proj"));
assert.equal(v08.forks.length, 1);
assert.equal(v08.forks[0].fromId, "summary:run-id");
assert.equal(v08.forks[0].workspaceKey, "workspace");
assert.equal(
  assertOk(recordFork(emptyAgentVaultOrganize(), "summary:run-id", "workspace:c:/users/sorab/secret")).forks[0].workspaceKey,
  "workspace",
);
assert.equal(persistableAgentVaultWorkspaceKey("__this_project__"), "__this_project__");
assert.equal(persistableAgentVaultWorkspaceKey("unknown"), "unknown");
assert.match(v08.forks[0].id, /^fork_[A-Za-z0-9]+$/);
assert.equal(isArchived(v08, "summary:run-id"), false);
assert.deepEqual(visibleVaultEntryIds(entries, v08, false), ["summary:run-id", "worker:w1"]);

// V09: resume command strings → isResumeCommand true
const claudeResume = buildAgentVaultResumeCommand("claude", "run-id");
const codexResume = buildAgentVaultResumeCommand("codex", "run-id");
const opencodeResume = buildAgentVaultResumeCommand("opencode", "run-id");
assert.equal(isResumeCommand(claudeResume), true);
assert.equal(isResumeCommand(codexResume), true);
assert.equal(isResumeCommand(opencodeResume), true);
assert.equal(isResumeCommand("claude --resume"), true);
assert.equal(isResumeCommand("codex resume"), true);
assert.equal(isResumeCommand("opencode --session"), true);

// V10: fork launch command → isResumeCommand false; must not include resume flags
for (const provider of ["claude", "codex", "opencode"]) {
  const forkCommand = buildAgentVaultForkLaunchCommand(provider);
  assert.equal(isResumeCommand(forkCommand), false, `${provider} fork must not be a resume command`);
  assert.equal(forkCommand.includes("--resume"), false);
  assert.equal(/\bcodex\s+resume\b/.test(forkCommand), false);
  assert.equal(forkCommand.includes("--session"), false);
  assert.equal(forkCommand, provider);
}

// V11: stale archived id → no fake card; other entries unchanged
const v11 = parseAgentVaultOrganizeJson(JSON.stringify({
  schema_version: 1,
  archivedIds: ["summary:gone", "summary:run-id"],
  groups: [],
  forks: [],
}));
assert.deepEqual(visibleVaultEntryIds(entries, v11, false), ["worker:w1"]);
assert.deepEqual(visibleVaultEntryIds(entries, v11, true), ["summary:run-id", "worker:w1"]);
assert.equal(visibleVaultEntryIds(entries, v11, true).includes("summary:gone"), false);

// V12: serializer round-trip → only the keys above
const v12State = {
  schema_version: 1,
  archivedIds: ["summary:run-id"],
  groups: [{ id: "grp_01", name: "release", sessionIds: ["summary:run-id"] }],
  forks: [{ id: "fork_01", fromId: "summary:run-id", workspaceKey: "workspace" }],
};
const v12Json = serializeAgentVaultOrganize(v12State);
const v12Parsed = JSON.parse(v12Json);
assert.deepEqual(Object.keys(v12Parsed), ["schema_version", "archivedIds", "groups", "forks"]);
assert.deepEqual(Object.keys(v12Parsed.groups[0]), ["id", "name", "sessionIds"]);
assert.deepEqual(Object.keys(v12Parsed.forks[0]), ["id", "fromId", "workspaceKey"]);
assert.deepEqual(parseAgentVaultOrganizeJson(v12Json), v12State);
assert.equal(v12Parsed.forks[0].workspaceKey, "workspace");
assert.doesNotMatch(v12Json, /C:\/|\\\\users\\/i);
const v12Legacy = parseAgentVaultOrganizeJson(JSON.stringify({
  schema_version: 1,
  archivedIds: [],
  groups: [],
  forks: [{ id: "fork_01", fromId: "summary:run-id", workspaceKey: "C:/Users/sorab/secret" }],
}));
assert.equal(v12Legacy.forks[0].workspaceKey, "workspace");
assert.doesNotMatch(serializeAgentVaultOrganize(v12Legacy), /Users\/sorab\/secret/i);

// V13: empty/cleared group name is a UI concern; mutation layer still rejects empty assign
const v13 = assertOk(removeSessionFromGroup(v04, "summary:run-id"));
assert.equal(groupNameForSession(v13, "summary:run-id"), null);
assert.equal(v13.groups.find((group) => group.name === "release")?.sessionIds.includes("summary:run-id") ?? false, false);
assert.equal(assignSessionToGroup(v13, "summary:run-id", "").ok, false);
assert.equal(assignSessionToGroup(v13, "summary:run-id", "   ").ok, false);

const groupedForPrompt = assertOk(assignSessionToGroup(emptyAgentVaultOrganize(), "summary:run-id", "release"));
assert.equal(groupNameForSession(assertOk(applyAgentVaultGroupPrompt(groupedForPrompt, "summary:run-id", "")), "summary:run-id"), null);
assert.equal(groupNameForSession(assertOk(applyAgentVaultGroupPrompt(groupedForPrompt, "summary:run-id", "   ")), "summary:run-id"), null);
const invalidPrompt = applyAgentVaultGroupPrompt(groupedForPrompt, "summary:run-id", "x".repeat(65));
assert.equal(invalidPrompt.ok, false);
assert.equal(groupNameForSession(groupedForPrompt, "summary:run-id"), "release");
assert.equal(
  groupNameForSession(assertOk(applyAgentVaultGroupPrompt(groupedForPrompt, "summary:run-id", "follow-up")), "summary:run-id"),
  "follow-up",
);

// V14: fork cwd — `.` / relative worktree resolve against the active project; `..` fail-closed
const baseDir = "C:/Users/sorab/proj";
assert.equal(resolveAgentVaultLaunchDirectory("C:/other/app", baseDir), "C:/other/app");
assert.equal(resolveAgentVaultLaunchDirectory("D:\\other\\app", baseDir), "D:\\other\\app");
assert.equal(resolveAgentVaultLaunchDirectory(".", baseDir), baseDir);
assert.equal(resolveAgentVaultLaunchDirectory("./", baseDir), baseDir);
assert.equal(resolveAgentVaultLaunchDirectory("worktrees/task-665", baseDir), "C:/Users/sorab/proj/worktrees/task-665");
assert.equal(resolveAgentVaultLaunchDirectory("", baseDir), baseDir);
assert.equal(resolveAgentVaultLaunchDirectory("__this_project__", baseDir), baseDir);
assert.equal(resolveAgentVaultLaunchDirectory(".", ""), "");
assert.equal(resolveAgentVaultLaunchDirectory("../escape", baseDir), "");
assert.equal(resolveAgentVaultLaunchDirectory("workspace:c:/other", baseDir), "");
assert.equal(resolveAgentVaultLaunchDirectory("", ""), "");

assert.equal(shouldQueueAgentVaultLaunchCwd("fork", "C:/proj"), true);
assert.equal(shouldQueueAgentVaultLaunchCwd("resume", "C:/proj"), false);
assert.equal(shouldQueueAgentVaultLaunchCwd("fork", ""), false);
assert.equal(shouldQueueAgentVaultLaunchCwd("resume", ""), false);

const mainSource = await readFile(path.resolve("src/main.ts"), "utf8");
assert.match(mainSource, /from "\.\/agentVaultOrganize"/);
assert.match(mainSource, /AGENT_VAULT_ORGANIZE_STORAGE_KEY|winsmux\.agent-vault\.organize\.v1/);
assert.match(mainSource, /Show archived/);
assert.match(mainSource, /アーカイブを表示/);
assert.match(mainSource, /getLanguageText\("Archive", "アーカイブ"\)/);
assert.match(mainSource, /getLanguageText\("Unarchive", "アーカイブ解除"\)/);
assert.match(mainSource, /getLanguageText\("Group", "グループ"\)/);
assert.match(mainSource, /getLanguageText\("Fork", "フォーク"\)/);
assert.match(mainSource, /forkAgentVaultSession/);
assert.match(mainSource, /Forked from/);
assert.match(mainSource, /buildAgentVaultForkLaunchCommand/);
assert.match(mainSource, /isResumeCommand/);
assert.match(mainSource, /workspacePath/);
assert.match(mainSource, /shouldQueueAgentVaultLaunchCwd\(mode, launchCwd\)/);
assert.match(mainSource, /queuePaneStartupCwd\(paneId, launchCwd\)/);
assert.match(mainSource, /spawnPtyPane\(paneId, cols, rows, startupInput, cwd\)/);
assert.match(mainSource, /mode === "fork" && !launchCwd/);
assert.match(mainSource, /vaultOrganize\.resolveAgentVaultLaunchDirectory/);
assert.doesNotMatch(mainSource, /function resolveAgentVaultLaunchDirectory/);
assert.match(mainSource, /applyAgentVaultGroupPrompt/);
assert.doesNotMatch(mainSource, /if \(launchCwd\) \{/);
assert.match(mainSource, /id: `worker:\$\{runId\}`/);
assert.doesNotMatch(mainSource, /id: `worker:\$\{target\}`/);
assert.match(mainSource, /row\.heartbeat\?\.run_id \|\| row\.workspace\?\.run_id/);
assert.doesNotMatch(mainSource, /desktop_write_.*organize|writeDesktopOrganize|\.winsmux\/.*organize/i);

const restoreFn = mainSource.slice(mainSource.indexOf("async function restoreAgentVaultSession"));
const recordAt = restoreFn.indexOf("recordFork");
const startedAt = restoreFn.indexOf("ensurePanePtyStarted");
assert.ok(startedAt >= 0, "restoreAgentVaultSession must start a pane");
assert.ok(recordAt > startedAt, "recordFork must run after pane startup succeeds");
const forkGuardAt = restoreFn.indexOf("mode === \"fork\" && !launchCwd");
assert.ok(forkGuardAt >= 0 && (recordAt < 0 || forkGuardAt < recordAt), "fork without a path must fail before recording");

const forbiddenFirstRun = [
  "src/firstRunOnboarding.ts",
  "src/firstRunWizard.ts",
  "scripts/first-run-onboarding-check.mjs",
];
void forbiddenFirstRun;

console.log("agent-vault-organize-check: ok");
