import { isTauri } from "@tauri-apps/api/core";
import { getDesktopFullFile, writeDesktopOrchestraMode } from "./desktopClient";
import {
  ORCHESTRA_MODE_RELATIVE_PATH,
  ORCHESTRA_MODE_STORAGE_KEY,
  launchTargetsAfterMode,
  isMissingOrchestraModeFileError,
  nextWizardStep,
  serializeOrchestraMode,
  shouldShowFirstRunWizard,
  type OrchestraMode,
  type WizardDecision,
  type WizardStepId,
} from "./firstRunOnboarding";
import {
  shouldRefuseTeamProfileStart,
  type TeamProfileSettingsView,
} from "./teamProfileSettings";

export interface FirstRunWizardBindings {
  getLanguageText(en: string, ja: string): string;
  getActiveProjectDir(): string | null;
  promptAndAddProjectSession(): Promise<boolean>;
  recordDogfoodInput(taskRef: string, taskClass: string, payload: unknown): void;
  focusWorkerPane(target: string): void;
  loadTeamProfileSettings(): Promise<void>;
  getTeamProfileSettingsView(): TeamProfileSettingsView | null;
  appendRuntimeNotice(title: string, body: string): void;
  startFocusedWorker(): Promise<void>;
}

let bindings: FirstRunWizardBindings | null = null;
let firstRunWizardOpen = false;
let firstRunWizardStep: WizardStepId = "select-project";
let firstRunWizardError = "";
let firstRunSelectedMode: OrchestraMode | null = null;

export function bindFirstRunWizard(next: FirstRunWizardBindings) {
  bindings = next;
}

function host(): FirstRunWizardBindings {
  if (!bindings) {
    throw new Error("first-run wizard bindings are not installed");
  }
  return bindings;
}

function createTextElement<K extends keyof HTMLElementTagNameMap>(
  tagName: K,
  className: string,
  text: string | number | null | undefined,
) {
  const element = document.createElement(tagName);
  if (className) {
    element.className = className;
  }
  element.textContent = text === null || text === undefined ? "" : String(text);
  return element;
}

export async function maybeStartFirstRunOnboarding(sessionCountAtBoot: number) {
  if (!shouldShowFirstRunWizard(sessionCountAtBoot)) {
    return;
  }
  firstRunWizardOpen = true;
  firstRunWizardError = "";
  firstRunSelectedMode = null;
  const projectDir = host().getActiveProjectDir();
  if (projectDir) {
    const existing = await readExistingOrchestraModeJson(projectDir);
    const decision = wizardDecisionFromExistingMode(sessionCountAtBoot, existing);
    firstRunWizardStep = decision.step;
    firstRunSelectedMode = decision.persistMode;
    firstRunWizardError = decision.modeRejected
      ? host().getLanguageText(
        "The existing orchestra mode file is invalid. Choose Simple or Team again.",
        "既存のオーケストラモードファイルが無効です。Simple または Team を選び直してください。",
      )
      : "";
  } else {
    firstRunWizardStep = "select-project";
  }
  renderFirstRunWizard();
}

export function closeFirstRunWizard() {
  firstRunWizardOpen = false;
  firstRunWizardError = "";
  const overlay = document.getElementById("first-run-wizard");
  if (!overlay) {
    return;
  }
  overlay.classList.remove("open");
  overlay.hidden = true;
  overlay.replaceChildren();
}

function ensureFirstRunWizard() {
  let overlay = document.getElementById("first-run-wizard");
  if (overlay) {
    return overlay;
  }
  overlay = document.createElement("div");
  overlay.id = "first-run-wizard";
  overlay.className = "first-run-wizard";
  overlay.setAttribute("role", "presentation");
  document.body.appendChild(overlay);
  return overlay;
}

type ExistingOrchestraModeRead =
  | { status: "missing" }
  | { status: "present"; json: string }
  | { status: "unreadable" };

function wizardDecisionFromExistingMode(
  sessionCount: number,
  existing: ExistingOrchestraModeRead,
): WizardDecision {
  if (existing.status === "unreadable") {
    return nextWizardStep({
      sessionCount,
      projectChosen: true,
      existingModeReadFailed: true,
    });
  }
  return nextWizardStep({
    sessionCount,
    projectChosen: true,
    existingModeJson: existing.status === "present" ? existing.json : null,
  });
}

function desktopErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function readExistingOrchestraModeJson(projectDir: string | null): Promise<ExistingOrchestraModeRead> {
  if (!projectDir) {
    return { status: "missing" };
  }
  if (!isTauri()) {
    try {
      const stored = window.localStorage.getItem(ORCHESTRA_MODE_STORAGE_KEY);
      return stored === null ? { status: "missing" } : { status: "present", json: stored };
    } catch {
      return { status: "unreadable" };
    }
  }
  try {
    const file = await getDesktopFullFile(ORCHESTRA_MODE_RELATIVE_PATH, undefined, projectDir);
    return { status: "present", json: file.content };
  } catch (error) {
    if (isMissingOrchestraModeFileError(desktopErrorMessage(error))) {
      return { status: "missing" };
    }
    return { status: "unreadable" };
  }
}

async function persistFirstRunOrchestraMode(mode: OrchestraMode) {
  const projectDir = host().getActiveProjectDir();
  if (!projectDir) {
    throw new Error(host().getLanguageText("Select a project folder first.", "先にプロジェクトフォルダを選択してください。"));
  }
  const json = serializeOrchestraMode(mode);
  try {
    window.localStorage.setItem(ORCHESTRA_MODE_STORAGE_KEY, json);
  } catch (error) {
    console.warn("Failed to persist orchestra mode locally", error);
  }
  if (!isTauri()) {
    return;
  }
  try {
    await writeDesktopOrchestraMode(projectDir, ORCHESTRA_MODE_RELATIVE_PATH, json);
  } catch (error) {
    try {
      window.localStorage.removeItem(ORCHESTRA_MODE_STORAGE_KEY);
    } catch {
      // Keep fail-closed: do not leave a local mode after a rejected project write.
    }
    throw error;
  }
}

async function handleFirstRunSelectProject() {
  const selected = await host().promptAndAddProjectSession();
  if (!selected) {
    firstRunWizardStep = nextWizardStep({
      sessionCount: 0,
      pickerCancelled: true,
    }).step;
    renderFirstRunWizard();
    return;
  }
  const existing = await readExistingOrchestraModeJson(host().getActiveProjectDir());
  const decision = wizardDecisionFromExistingMode(0, existing);
  firstRunWizardStep = decision.step;
  firstRunSelectedMode = decision.persistMode;
  firstRunWizardError = decision.modeRejected
    ? host().getLanguageText(
      "The existing orchestra mode file is invalid. Choose Simple or Team again.",
      "既存のオーケストラモードファイルが無効です。Simple または Team を選び直してください。",
    )
    : "";
  renderFirstRunWizard();
}

async function handleFirstRunChooseMode(mode: OrchestraMode) {
  const decision = nextWizardStep({
    sessionCount: 0,
    projectChosen: true,
    selectedMode: mode,
  });
  if (decision.writeMode && decision.persistMode) {
    try {
      await persistFirstRunOrchestraMode(decision.persistMode);
    } catch (error) {
      firstRunWizardError = error instanceof Error ? error.message : String(error);
      firstRunWizardStep = "choose-mode";
      renderFirstRunWizard();
      return;
    }
  }
  firstRunSelectedMode = decision.persistMode;
  firstRunWizardStep = decision.step;
  firstRunWizardError = "";
  host().recordDogfoodInput("desktop-first-run-mode", "first_launch_mode_selection", {
    selected: true,
    mode: decision.persistMode,
  });
  renderFirstRunWizard();
}

function handleFirstRunModeCancel() {
  const decision = nextWizardStep({
    sessionCount: 0,
    projectChosen: true,
    modeStepCancelled: true,
  });
  firstRunSelectedMode = null;
  firstRunWizardStep = decision.step;
  renderFirstRunWizard();
}

async function handleFirstRunLaunch() {
  const mode = firstRunSelectedMode;
  if (!mode) {
    firstRunWizardStep = "choose-mode";
    renderFirstRunWizard();
    return;
  }
  closeFirstRunWizard();
  await launchFirstRunManagedWorker(mode);
}

async function launchFirstRunManagedWorker(mode: OrchestraMode) {
  const runtime = host();
  const targets = launchTargetsAfterMode(mode);
  const target = targets[0];
  if (target) {
    runtime.focusWorkerPane(target);
    if (mode === "team") {
      await runtime.loadTeamProfileSettings();
      const view = runtime.getTeamProfileSettingsView();
      if (!view || shouldRefuseTeamProfileStart(view)) {
        runtime.appendRuntimeNotice(
          runtime.getLanguageText("Worker start blocked", "ワーカー起動を停止"),
          runtime.getLanguageText(
            "Start refused. One or more slots cannot run.",
            "起動できません。実行できないスロットがあります。",
          ),
        );
        return;
      }
    }
    await runtime.startFocusedWorker();
  }
}

export function renderFirstRunWizard() {
  if (!firstRunWizardOpen) {
    const existing = document.getElementById("first-run-wizard");
    if (existing) {
      existing.classList.remove("open");
      existing.hidden = true;
      existing.replaceChildren();
    }
    return;
  }

  const t = host().getLanguageText;
  const overlay = ensureFirstRunWizard();
  overlay.hidden = false;
  overlay.classList.add("open");

  const panel = document.createElement("div");
  panel.className = "first-run-wizard-panel";
  panel.setAttribute("role", "dialog");
  panel.setAttribute("aria-modal", "true");
  panel.setAttribute("aria-labelledby", "first-run-wizard-title");

  const content = document.createElement("div");
  content.className = "first-run-wizard-content";

  const stepNumber = firstRunWizardStep === "select-project" ? 1 : firstRunWizardStep === "choose-mode" ? 2 : 3;
  content.appendChild(createTextElement(
    "p",
    "first-run-wizard-step",
    t(`Step ${stepNumber} of 3`, `ステップ ${stepNumber} / 3`),
  ));

  let title = t("Select project folder", "プロジェクトフォルダを選択");
  let body = t("Choose a local project folder", "ローカルプロジェクトのフォルダを選択");
  if (firstRunWizardStep === "choose-mode") {
    title = t("Choose Simple or Team", "Simple または Team を選択");
    body = t(
      "Simple uses one live worker. Team keeps the existing Team Profile start-gate.",
      "Simple はライブワーカーを1つ使います。Team は既存のチームプロファイル起動ゲートを維持します。",
    );
  } else if (firstRunWizardStep === "launch") {
    title = t("Launch", "起動");
    body = t(
      "Start the first managed worker, then focus worker-1.",
      "最初の管理ワーカーを起動し、worker-1 にフォーカスします。",
    );
  }

  const heading = createTextElement("h2", "first-run-wizard-title", title);
  heading.id = "first-run-wizard-title";
  content.appendChild(heading);
  content.appendChild(createTextElement("p", "first-run-wizard-body", body));

  const error = createTextElement("p", "first-run-wizard-error", firstRunWizardError);
  error.hidden = !firstRunWizardError;
  error.setAttribute("role", "alert");
  content.appendChild(error);

  const actions = document.createElement("div");
  actions.className = "first-run-wizard-actions";

  if (firstRunWizardStep === "select-project") {
    const selectButton = document.createElement("button");
    selectButton.type = "button";
    selectButton.className = "first-run-wizard-primary";
    selectButton.textContent = t("Select project", "プロジェクトを選択");
    selectButton.addEventListener("click", () => {
      void handleFirstRunSelectProject();
    });
    actions.appendChild(selectButton);
  } else if (firstRunWizardStep === "choose-mode") {
    const simpleButton = document.createElement("button");
    simpleButton.type = "button";
    simpleButton.className = "first-run-wizard-primary";
    simpleButton.textContent = t("Simple (one live worker)", "Simple（ライブワーカーは1つ）");
    simpleButton.addEventListener("click", () => {
      void handleFirstRunChooseMode("simple");
    });
    const teamButton = document.createElement("button");
    teamButton.type = "button";
    teamButton.className = "first-run-wizard-secondary";
    teamButton.textContent = t(
      "Team (existing Team Profile start-gate)",
      "Team（既存のチームプロファイル起動ゲート）",
    );
    teamButton.addEventListener("click", () => {
      void handleFirstRunChooseMode("team");
    });
    const cancelButton = document.createElement("button");
    cancelButton.type = "button";
    cancelButton.className = "first-run-wizard-cancel";
    cancelButton.textContent = t("Cancel", "キャンセル");
    cancelButton.addEventListener("click", () => {
      handleFirstRunModeCancel();
    });
    actions.appendChild(simpleButton);
    actions.appendChild(teamButton);
    actions.appendChild(cancelButton);
  } else {
    const startButton = document.createElement("button");
    startButton.type = "button";
    startButton.className = "first-run-wizard-primary";
    startButton.textContent = t("Start", "起動");
    startButton.addEventListener("click", () => {
      void handleFirstRunLaunch();
    });
    actions.appendChild(startButton);
  }

  content.appendChild(actions);
  panel.appendChild(content);
  overlay.replaceChildren(panel);
}
