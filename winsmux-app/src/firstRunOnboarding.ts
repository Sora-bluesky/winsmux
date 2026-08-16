export const ORCHESTRA_MODE_STORAGE_KEY = "winsmux.orchestra-mode.v1";
export const ORCHESTRA_MODE_RELATIVE_PATH = ".winsmux/orchestra-mode.json";
export const FIRST_RUN_LAUNCH_TARGET = "worker-1";

export type OrchestraMode = "simple" | "team";
export type WizardStepId = "select-project" | "choose-mode" | "launch" | "skipped";

export interface OrchestraModeDocument {
  schema_version: 1;
  mode: OrchestraMode;
}

export interface WizardDecision {
  step: WizardStepId;
  persistMode: OrchestraMode | null;
  writeMode: boolean;
  launchTargets: string[];
  mustHonorStartGate: boolean;
  modeRejected: boolean;
}

export interface WizardState {
  sessionCount: number;
  projectChosen?: boolean;
  pickerCancelled?: boolean;
  selectedMode?: OrchestraMode | null;
  modeStepCancelled?: boolean;
  existingModeJson?: string | null;
}

const EXTRA_WORKER_PANE_IDS = ["worker-2", "worker-3", "worker-4", "worker-5", "worker-6"] as const;

const HIDE_DECLARATION =
  /(?:display\s*:\s*none|visibility\s*:\s*hidden|\bhidden\b\s*:|height\s*:\s*0(?:px|%|rem|em)?\b|width\s*:\s*0(?:px|%|rem|em)?\b|max-height\s*:\s*0|max-width\s*:\s*0|opacity\s*:\s*0(?:\.0+)?\b|clip(?:-path)?\s*:|transform\s*:[^;]*(?:translate|translateX|translateY|translate3d)\s*\(\s*-?\d{3,}|left\s*:\s*-?\d{3,}px|right\s*:\s*-?\d{3,}px|top\s*:\s*-?\d{3,}px|bottom\s*:\s*-?\d{3,}px|aria-hidden\s*:\s*true)/i;

export function shouldShowFirstRunWizard(sessionCount: number): boolean {
  return !(sessionCount >= 1);
}

export function teamModeStartGateContract(): { mustHonorStartGate: true } {
  return { mustHonorStartGate: true };
}

export function launchTargetAfterMode(mode: OrchestraMode): typeof FIRST_RUN_LAUNCH_TARGET {
  if (mode !== "simple" && mode !== "team") {
    throw new Error("first-run launch target is only defined for simple or team");
  }
  return FIRST_RUN_LAUNCH_TARGET;
}

export function launchTargetsAfterMode(mode: OrchestraMode): readonly string[] {
  return [launchTargetAfterMode(mode)];
}

export function serializeOrchestraMode(mode: OrchestraMode): string {
  if (mode !== "simple" && mode !== "team") {
    throw new Error("orchestra-mode.json mode must be simple or team");
  }
  return JSON.stringify({ schema_version: 1, mode });
}

export function parseOrchestraModeJson(text: string): OrchestraModeDocument {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("orchestra-mode.json is not valid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("orchestra-mode.json must be an object");
  }
  const record = parsed as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== 2 || !keys.includes("schema_version") || !keys.includes("mode")) {
    throw new Error("orchestra-mode.json must contain only schema_version and mode");
  }
  if (record.schema_version !== 1) {
    throw new Error("orchestra-mode.json schema_version must be 1");
  }
  if (record.mode !== "simple" && record.mode !== "team") {
    throw new Error("orchestra-mode.json mode must be simple or team");
  }
  return { schema_version: 1, mode: record.mode };
}

export function isAllowedOrchestraModeRelativePath(relativePath: string): boolean {
  const normalized = relativePath.replace(/\\/g, "/").trim();
  if (normalized.includes("..") || normalized.startsWith("/") || /^[A-Za-z]:/.test(normalized)) {
    return false;
  }
  return normalized === ORCHESTRA_MODE_RELATIVE_PATH;
}

function emptyDecision(step: WizardStepId, extras?: Partial<WizardDecision>): WizardDecision {
  return {
    step,
    persistMode: null,
    writeMode: false,
    launchTargets: [],
    mustHonorStartGate: false,
    modeRejected: false,
    ...extras,
  };
}

function launchDecision(mode: OrchestraMode, writeMode: boolean): WizardDecision {
  return {
    step: "launch",
    persistMode: mode,
    writeMode,
    launchTargets: [...launchTargetsAfterMode(mode)],
    mustHonorStartGate: mode === "team" ? teamModeStartGateContract().mustHonorStartGate : false,
    modeRejected: false,
  };
}

export function nextWizardStep(state: WizardState): WizardDecision {
  const projectChosen = Boolean(state.projectChosen);
  if (!projectChosen && !shouldShowFirstRunWizard(state.sessionCount)) {
    return emptyDecision("skipped");
  }

  if (state.pickerCancelled || !projectChosen) {
    return emptyDecision("select-project");
  }

  let existingMode: OrchestraMode | null = null;
  let modeRejected = false;
  if (typeof state.existingModeJson === "string") {
    try {
      existingMode = parseOrchestraModeJson(state.existingModeJson).mode;
    } catch {
      modeRejected = true;
    }
  }

  if (modeRejected) {
    return emptyDecision("choose-mode", {
      mustHonorStartGate: teamModeStartGateContract().mustHonorStartGate,
      modeRejected: true,
    });
  }

  if (state.modeStepCancelled) {
    return emptyDecision("choose-mode", {
      mustHonorStartGate: teamModeStartGateContract().mustHonorStartGate,
    });
  }

  if (state.selectedMode === "simple" || state.selectedMode === "team") {
    return launchDecision(state.selectedMode, true);
  }

  if (existingMode) {
    return launchDecision(existingMode, false);
  }

  return emptyDecision("choose-mode", {
    mustHonorStartGate: teamModeStartGateContract().mustHonorStartGate,
  });
}

function selectorTargetsExtraWorkerPane(selector: string): boolean {
  return EXTRA_WORKER_PANE_IDS.some((id) => {
    const patterns = [
      new RegExp(`#pane-${id}\\b`, "i"),
      new RegExp(`#${id}\\b`, "i"),
      new RegExp(`\\[id\\s*=\\s*['"]pane-${id}['"]\\]`, "i"),
      new RegExp(`\\[data-(?:pane|worker)(?:-id)?\\s*=\\s*['"]${id}['"]\\]`, "i"),
      new RegExp(`\\.pane-${id}\\b`, "i"),
    ];
    return patterns.some((pattern) => pattern.test(selector));
  });
}

export function simpleModeMustNotHideExtraPanes(cssText: string): boolean {
  const withoutComments = cssText.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = withoutComments.split("}");
  for (const rule of rules) {
    const parts = rule.split("{");
    if (parts.length < 2) {
      continue;
    }
    const selector = parts[0];
    const body = parts.slice(1).join("{");
    if (selectorTargetsExtraWorkerPane(selector) && HIDE_DECLARATION.test(body)) {
      return false;
    }
  }
  return true;
}
