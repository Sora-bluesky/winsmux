import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

async function loadFirstRunOnboardingModule() {
  const sourcePath = path.resolve("src/firstRunOnboarding.ts");
  const source = await readFile(sourcePath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: sourcePath,
  });

  const tempDir = await mkdtemp(path.join(os.tmpdir(), "winsmux-first-run-onboarding-"));
  const modulePath = path.join(tempDir, "firstRunOnboarding.mjs");
  await writeFile(modulePath, transpiled.outputText, "utf8");

  try {
    return await import(pathToFileURL(modulePath).href);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const {
  FIRST_RUN_LAUNCH_TARGET,
  ORCHESTRA_MODE_RELATIVE_PATH,
  ORCHESTRA_MODE_STORAGE_KEY,
  isAllowedOrchestraModeRelativePath,
  isMissingOrchestraModeFileError,
  launchTargetAfterMode,
  launchTargetsAfterMode,
  nextWizardStep,
  parseOrchestraModeJson,
  serializeOrchestraMode,
  shouldShowFirstRunWizard,
  simpleModeMustNotHideExtraPanes,
  teamModeStartGateContract,
} = await loadFirstRunOnboardingModule();

function assertNoExtraLaunchTargets(targets) {
  assert.deepEqual(targets, [FIRST_RUN_LAUNCH_TARGET]);
  assert.equal(targets.includes("worker-2"), false);
  assert.equal(targets.includes("worker-3"), false);
  assert.equal(targets.includes("worker-4"), false);
  assert.equal(targets.includes("worker-5"), false);
  assert.equal(targets.includes("worker-6"), false);
}

// F01: sessionCount 0, no mode → show step 1 select project
const f01 = nextWizardStep({ sessionCount: 0 });
assert.equal(shouldShowFirstRunWizard(0), true);
assert.equal(f01.step, "select-project");
assert.equal(f01.writeMode, false);
assert.equal(f01.persistMode, null);

// F02: project chosen, no mode → show step 2; cancel does not write mode
const f02 = nextWizardStep({ sessionCount: 0, projectChosen: true });
assert.equal(f02.step, "choose-mode");
assert.equal(f02.writeMode, false);
const f02Cancel = nextWizardStep({
  sessionCount: 0,
  projectChosen: true,
  modeStepCancelled: true,
});
assert.equal(f02Cancel.step, "choose-mode");
assert.equal(f02Cancel.writeMode, false);
assert.equal(f02Cancel.persistMode, null);

// F03: choose simple → persist mode=simple; launch target worker-1; no hide of extra panes
const f03 = nextWizardStep({ sessionCount: 0, projectChosen: true, selectedMode: "simple" });
assert.equal(f03.step, "launch");
assert.equal(f03.writeMode, true);
assert.equal(f03.persistMode, "simple");
assertNoExtraLaunchTargets(f03.launchTargets);
assert.equal(simpleModeMustNotHideExtraPanes(".pane { display: flex; }"), true);

// F04: choose team → persist mode=team; start-gate refuse still represented
const f04 = nextWizardStep({ sessionCount: 0, projectChosen: true, selectedMode: "team" });
assert.equal(f04.persistMode, "team");
assert.equal(f04.writeMode, true);
assert.equal(f04.mustHonorStartGate, true);
assert.deepEqual(teamModeStartGateContract(), { mustHonorStartGate: true });
assertNoExtraLaunchTargets(f04.launchTargets);

// F05: sessionCount ≥ 1 → skip wizard
assert.equal(shouldShowFirstRunWizard(1), false);
assert.equal(shouldShowFirstRunWizard(8), false);
const f05 = nextWizardStep({ sessionCount: 1 });
assert.equal(f05.step, "skipped");
assert.equal(f05.writeMode, false);

// F06: cancel picker → remain step 1; no session; no mode write
const f06 = nextWizardStep({ sessionCount: 0, pickerCancelled: true });
assert.equal(f06.step, "select-project");
assert.equal(f06.writeMode, false);
assert.equal(f06.persistMode, null);
assert.deepEqual(f06.launchTargets, []);

// F07: extra key / bad mode / wrong schema_version → reject
assert.throws(() => parseOrchestraModeJson('{"schema_version":1,"mode":"simple","extra":true}'));
assert.throws(() => parseOrchestraModeJson('{"schema_version":1,"mode":"advanced"}'));
assert.throws(() => parseOrchestraModeJson('{"schema_version":2,"mode":"simple"}'));
assert.throws(() => parseOrchestraModeJson("[]"));
const f07 = nextWizardStep({
  sessionCount: 0,
  projectChosen: true,
  existingModeJson: '{"schema_version":1,"mode":"simple","extra":1}',
});
assert.equal(f07.step, "choose-mode");
assert.equal(f07.modeRejected, true);
assert.equal(f07.writeMode, false);
assert.deepEqual(f07.launchTargets, []);
const f07Unreadable = nextWizardStep({
  sessionCount: 0,
  projectChosen: true,
  existingModeReadFailed: true,
});
assert.equal(f07Unreadable.step, "choose-mode");
assert.equal(f07Unreadable.modeRejected, true);
assert.equal(f07Unreadable.writeMode, false);
assert.equal(
  isMissingOrchestraModeFileError("desktop_file_read_full(.winsmux/orchestra-mode.json) failed: Failed to read full file: The system cannot find the file specified. (os error 2)"),
  true,
);
assert.equal(
  isMissingOrchestraModeFileError("desktop_file_read_full(.winsmux/orchestra-mode.json) failed: desktop.file.read_full rejected a file larger than 1048576 bytes"),
  false,
);
assert.equal(
  isMissingOrchestraModeFileError("desktop_file_read_full(.winsmux/orchestra-mode.json) failed: Failed to decode full file as UTF-8: invalid utf-8"),
  false,
);

// F08: launch after simple does not include worker-2..6 start targets
assert.equal(launchTargetAfterMode("simple"), "worker-1");
assert.equal(launchTargetAfterMode("team"), "worker-1");
assertNoExtraLaunchTargets(launchTargetsAfterMode("simple"));
assertNoExtraLaunchTargets(launchTargetsAfterMode("team"));
assertNoExtraLaunchTargets(f03.launchTargets);

// F09: CSS contract — helper returns false if hide rules target extra worker panes
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-2 { display: none; }"), false);
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-3 { visibility: hidden; }"), false);
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-4 { height: 0; }"), false);
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-5 { position: absolute; left: -9999px; }"), false);
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-6 { transform: translateX(-100vw); }"), false);
assert.equal(simpleModeMustNotHideExtraPanes('#pane-worker-2 { aria-hidden: true; }'), false);
assert.equal(simpleModeMustNotHideExtraPanes("#pane-worker-1 { display: none; }"), true);
assert.equal(simpleModeMustNotHideExtraPanes(".pane { display: none; }"), true);

const stylesCss = await readFile(path.resolve("src/styles.css"), "utf8");
assert.equal(simpleModeMustNotHideExtraPanes(stylesCss), true);

// F10: serializer round-trip only simple|team
assert.equal(serializeOrchestraMode("simple"), '{"schema_version":1,"mode":"simple"}');
assert.equal(serializeOrchestraMode("team"), '{"schema_version":1,"mode":"team"}');
for (const mode of ["simple", "team"]) {
  const json = serializeOrchestraMode(mode);
  const parsed = parseOrchestraModeJson(json);
  assert.deepEqual(Object.keys(parsed).sort(), ["mode", "schema_version"]);
  assert.deepEqual(parsed, { schema_version: 1, mode });
}
assert.throws(() => serializeOrchestraMode("advanced"));
assert.equal(ORCHESTRA_MODE_STORAGE_KEY, "winsmux.orchestra-mode.v1");
assert.equal(ORCHESTRA_MODE_RELATIVE_PATH, ".winsmux/orchestra-mode.json");
assert.equal(isAllowedOrchestraModeRelativePath(".winsmux/orchestra-mode.json"), true);
assert.equal(isAllowedOrchestraModeRelativePath("../orchestra-mode.json"), false);
assert.equal(isAllowedOrchestraModeRelativePath("/tmp/orchestra-mode.json"), false);
assert.equal(isAllowedOrchestraModeRelativePath(".winsmux/../secrets.json"), false);

const mainSource = await readFile(path.resolve("src/main.ts"), "utf8");
const wizardSource = await readFile(path.resolve("src/firstRunWizard.ts"), "utf8");
assert.match(mainSource, /from "\.\/firstRunWizard"/);
assert.match(mainSource, /maybeStartFirstRunOnboarding/);
assert.match(wizardSource, /from "\.\/firstRunOnboarding"/);
assert.match(wizardSource, /shouldShowFirstRunWizard/);
assert.match(wizardSource, /ORCHESTRA_MODE_STORAGE_KEY/);
assert.match(wizardSource, /first_launch_mode_selection/);
assert.match(wizardSource, /async function launchFirstRunManagedWorker/);
assert.match(wizardSource, /writeDesktopOrchestraMode/);
assert.equal(simpleModeMustNotHideExtraPanes(mainSource), true);
assert.equal(simpleModeMustNotHideExtraPanes(wizardSource), true);

const launchFn = wizardSource.match(/async function launchFirstRunManagedWorker[\s\S]*?\n\}/);
assert.ok(launchFn, "launchFirstRunManagedWorker must exist");
assert.equal(/worker-[2-6]/.test(launchFn[0]), false, "first-run launch must not start worker-2..6");
assert.match(launchFn[0], /launchTargetsAfterMode|launchTargetAfterMode|worker-1/);

// F11: empty-store first run with --project-dir must use the boot session count,
// not the post-launch-arg session list, and start at choose-mode when a project is already set.
const f11 = nextWizardStep({ sessionCount: 0, projectChosen: true });
assert.equal(shouldShowFirstRunWizard(0), true);
assert.equal(f11.step, "choose-mode");
assert.equal(f11.writeMode, false);
const f11Existing = nextWizardStep({
  sessionCount: 0,
  projectChosen: true,
  existingModeJson: '{"schema_version":1,"mode":"simple"}',
});
assert.equal(f11Existing.step, "launch");
assert.equal(f11Existing.writeMode, false);
assert.match(mainSource, /firstRunSessionCountAtBoot = projectSessionEntries\.length/);
assert.match(mainSource, /await applyInitialProjectDirFromLaunchArgs\(\);/);
assert.match(mainSource, /maybeStartFirstRunOnboarding\(firstRunSessionCountAtBoot\)/);
const bootSnapshotAt = mainSource.indexOf("const firstRunSessionCountAtBoot = projectSessionEntries.length");
const applyLaunchAt = mainSource.indexOf("await applyInitialProjectDirFromLaunchArgs()");
const maybeStartAt = mainSource.indexOf("await maybeStartFirstRunOnboarding(firstRunSessionCountAtBoot)");
assert.ok(bootSnapshotAt >= 0 && applyLaunchAt > bootSnapshotAt && maybeStartAt > applyLaunchAt);
assert.match(wizardSource, /shouldShowFirstRunWizard\(sessionCountAtBoot\)/);
assert.match(wizardSource, /existingModeReadFailed/);
assert.match(wizardSource, /isMissingOrchestraModeFileError/);
assert.match(wizardSource, /status: "unreadable"/);
assert.doesNotMatch(
  wizardSource,
  /getDesktopFullFile[\s\S]{0,240}catch \{[\s\S]{0,40}return null;/,
);
assert.equal(
  /projectSessionEntries\.length/.test(wizardSource),
  false,
  "wizard skip-check must not reread projectSessionEntries.length after launch-arg apply",
);
assert.doesNotMatch(mainSource, /shouldShowFirstRunWizard\(projectSessionEntries\.length\)/);

const desktopClient = await readFile(path.resolve("src/desktopClient.ts"), "utf8");
assert.match(desktopClient, /desktop_write_orchestra_mode/);

const libSource = await readFile(path.resolve("src-tauri/src/lib.rs"), "utf8");
assert.match(libSource, /fn desktop_write_orchestra_mode/);
assert.match(libSource, /fn write_orchestra_mode_file/);
assert.match(libSource, /fn orchestra_mode_target_is_symlink/);
assert.match(libSource, /symlink_metadata/);
assert.match(libSource, /refused a symlink/);

console.log("first-run-onboarding-check: ok");
