import {
  effortCapabilityIds,
  modelCapabilities,
  providerCapabilityIds,
} from "./modelCapabilities";

export const TEAM_PROFILE_SLOT_IDS = [
  "worker-1",
  "worker-2",
  "worker-3",
  "worker-4",
  "worker-5",
  "worker-6",
] as const;

export const TEAM_PROFILE_ROLE_PROFILES = [
  "architect",
  "builder",
  "reviewer",
  "researcher",
  "maintainer",
] as const;

export const TEAM_PROFILE_LIFECYCLES = ["session", "task", "one-shot"] as const;

export const TEAM_PROFILE_TASK_CLASSES = [
  "architecture",
  "protocol",
  "security",
  "implementation",
  "test",
  "review",
  "research",
  "documentation",
  "repository-operations",
] as const;

export interface TeamProfileFieldView {
  value: unknown;
  source: "preset" | "override" | "legacy";
}

export interface TeamProfileRuntimeDisplay {
  slot_id: string;
  provider: string;
  model: string;
  reasoning_effort: string;
  role_profile: string;
  lifecycle: string;
  task_classes: string[];
  source: string;
  validation: string;
  prompt_bundle_digest?: string | null;
}

export interface TeamProfileSettingsRow {
  slot_id: string;
  cannot_run: boolean;
  launch_blocked: boolean;
  fields: Record<string, TeamProfileFieldView>;
  issues?: unknown[];
  runtime_display: TeamProfileRuntimeDisplay;
  artifact?: {
    output: string;
    completion_authority: string;
    pty_capture_is_auxiliary: boolean;
  };
}

export interface TeamProfileSettingsView {
  schema_version: number;
  action: string;
  opted_in: boolean;
  ok: boolean;
  apply_allowed: boolean;
  start_allowed: boolean;
  update_policy?: string | null;
  rows: TeamProfileSettingsRow[];
  warnings?: unknown[];
  runtime_display?: TeamProfileRuntimeDisplay[];
  checkpoints?: {
    task_785_artifact?: {
      completion_authority: string;
      output_pattern: string;
      pty_capture_is_auxiliary: boolean;
    };
    task_662?: { status: string };
  };
}

export function parseTeamProfileSettingsView(payload: unknown): TeamProfileSettingsView {
  const value = payload as TeamProfileSettingsView;
  if (!value || !Array.isArray(value.rows)) {
    throw new Error("Team Profile settings-view JSON is missing rows.");
  }
  return value;
}

export function shouldRefuseTeamProfileStart(view: TeamProfileSettingsView): boolean {
  return view.opted_in === true && view.start_allowed !== true;
}

export function shouldRefuseTeamProfileApply(view: TeamProfileSettingsView): boolean {
  return view.opted_in === true && view.apply_allowed !== true;
}

export function confirmTeamProfileReset(input: { confirmed?: boolean }): boolean {
  return input.confirmed === true;
}

export function shouldExposeTeamProfileReset(
  view: TeamProfileSettingsView,
  source: TeamProfileFieldView["source"] | string,
): boolean {
  return view.opted_in === true && source === "override";
}

export function keepOverridesAfterPresetApply<T extends Record<string, unknown>>(
  presetSlots: Record<string, T>,
  overlay: Record<string, Partial<T>>,
): Record<string, T> {
  const merged: Record<string, T> = {};
  for (const slotId of Object.keys(presetSlots)) {
    merged[slotId] = {
      ...presetSlots[slotId],
      ...(overlay[slotId] ?? {}),
    };
  }
  return merged;
}

export function modelsForProvider(providerId: string) {
  return modelCapabilities.filter((model) => model.providerId === providerId && model.id !== "provider-default");
}

export function effortsForModel(modelId: string): readonly string[] {
  const model = modelCapabilities.find((entry) => entry.id === modelId);
  if (model?.supportedEffortIds && model.supportedEffortIds.length > 0) {
    return model.supportedEffortIds;
  }
  return effortCapabilityIds;
}

export function providersForTeamProfile() {
  return providerCapabilityIds.filter((id) => id !== "provider-default");
}

export function formatTeamProfileRuntimeChips(display: TeamProfileRuntimeDisplay) {
  return [
    { field: "provider", value: display.provider },
    { field: "model", value: display.model },
    { field: "effort", value: display.reasoning_effort },
    { field: "role", value: display.role_profile },
    { field: "lifecycle", value: display.lifecycle },
    { field: "task-classes", value: (display.task_classes ?? []).join(",") },
    { field: "source", value: display.source },
    { field: "validation", value: display.validation },
    { field: "bundle", value: display.prompt_bundle_digest || "none" },
  ];
}

export interface TeamProfileSettingsRenderOptions {
  japanese?: boolean;
  onResetField?: (slotId: string, field: string) => void;
}

export function renderTeamProfileSettingsPanel(
  root: HTMLElement | null,
  view: TeamProfileSettingsView,
  options: TeamProfileSettingsRenderOptions = {},
): boolean {
  if (!root) {
    return false;
  }
  const japanese = Boolean(options.japanese);
  root.innerHTML = "";
  const doc = root.ownerDocument;
  const heading = doc.createElement("div");
  heading.className = "team-profile-settings-title";
  heading.textContent = japanese ? "チームプロファイル" : "Team Profile";
  root.appendChild(heading);

  if (shouldRefuseTeamProfileStart(view)) {
    const banner = doc.createElement("div");
    banner.className = "settings-field-warning";
    banner.setAttribute("role", "alert");
    banner.textContent = japanese
      ? "起動できません。実行できないスロットがあります。"
      : "Start refused. One or more slots cannot run.";
    root.appendChild(banner);
  }

  const table = doc.createElement("div");
  table.className = "team-profile-settings-grid";
  table.setAttribute("role", "table");
  for (const slotId of TEAM_PROFILE_SLOT_IDS) {
    const row = view.rows.find((item) => item.slot_id === slotId);
    const rowEl = doc.createElement("div");
    rowEl.className = "team-profile-settings-row";
    rowEl.setAttribute("role", "row");
    rowEl.setAttribute("data-slot-id", slotId);
    const title = doc.createElement("div");
    title.className = "team-profile-settings-slot";
    title.textContent = slotId;
    rowEl.appendChild(title);
    if (!row) {
      const missing = doc.createElement("div");
      missing.className = "settings-field-warning";
      missing.textContent = japanese ? "未解決" : "unresolved";
      rowEl.appendChild(missing);
      table.appendChild(rowEl);
      continue;
    }
    const fields = ["provider", "model", "reasoning-effort", "role-profile", "lifecycle"] as const;
    for (const field of fields) {
      const cell = doc.createElement("div");
      cell.className = "team-profile-settings-field";
      const source = row.fields?.[field]?.source ?? "preset";
      const value = row.fields?.[field]?.value;
      cell.setAttribute("data-source", String(source));
      cell.textContent = `${field}: ${String(value ?? "")} (${source})`;
      if (shouldExposeTeamProfileReset(view, source)) {
        const reset = doc.createElement("button");
        reset.type = "button";
        reset.className = "ghost-btn ghost-btn-small team-profile-reset";
        reset.setAttribute("aria-label", japanese ? `${slotId} の ${field} をリセット` : `Reset ${slotId} ${field}`);
        reset.setAttribute("aria-expanded", "false");
        reset.textContent = japanese ? "リセット" : "Reset";
        reset.addEventListener("click", () => {
          if (reset.getAttribute("data-confirming") === "true") {
            if (confirmTeamProfileReset({ confirmed: true })) {
              options.onResetField?.(slotId, field);
            }
            reset.setAttribute("data-confirming", "false");
            reset.setAttribute("aria-expanded", "false");
            return;
          }
          reset.setAttribute("data-confirming", "true");
          reset.setAttribute("aria-expanded", "true");
          reset.textContent = japanese ? "確認" : "Confirm reset";
        });
        cell.appendChild(reset);
      }
      rowEl.appendChild(cell);
    }
    if (row.cannot_run || row.launch_blocked) {
      const warn = doc.createElement("div");
      warn.className = "settings-field-warning";
      warn.setAttribute("role", "status");
      warn.textContent = row.cannot_run
        ? (japanese ? "このスロットは実行できません。" : "This slot cannot run.")
        : (japanese ? "起動前に再確認が必要です。" : "Launch requires a runtime recheck.");
      rowEl.appendChild(warn);
    }
    table.appendChild(rowEl);
  }
  root.appendChild(table);
  return true;
}
