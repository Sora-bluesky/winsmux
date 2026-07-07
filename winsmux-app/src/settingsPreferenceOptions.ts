export interface SettingsPreferenceOption<T extends string> {
  value: T;
  label: string;
  description: string;
  labelJa?: string;
  descriptionJa?: string;
}

export function getSettingsPreferenceLabel<T extends string>(option: SettingsPreferenceOption<T>, japanese: boolean) {
  return japanese ? (option.labelJa ?? option.label) : option.label;
}

export function getSettingsPreferenceDescription<T extends string>(option: SettingsPreferenceOption<T>, japanese: boolean) {
  return japanese ? (option.descriptionJa ?? option.description) : option.description;
}

export function renderSettingsPreferenceOptions<T extends string>(
  root: HTMLElement | null,
  options: readonly SettingsPreferenceOption<T>[],
  selected: T,
  japanese: boolean,
  onSelect: (value: T) => void,
) {
  if (!root) {
    return false;
  }

  root.innerHTML = "";
  const doc = root.ownerDocument;
  for (const option of options) {
    const button = doc.createElement("button");
    button.type = "button";
    button.className = `settings-option-chip ${option.value === selected ? "is-active" : ""}`;
    button.setAttribute("aria-pressed", option.value === selected ? "true" : "false");

    const label = doc.createElement("span");
    label.className = "settings-option-label";
    label.textContent = getSettingsPreferenceLabel(option, japanese);

    const description = doc.createElement("span");
    description.className = "settings-option-description";
    description.textContent = getSettingsPreferenceDescription(option, japanese);

    button.replaceChildren(label, description);
    button.addEventListener("click", () => onSelect(option.value));
    root.appendChild(button);
  }

  return true;
}
