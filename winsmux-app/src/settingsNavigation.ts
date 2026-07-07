export type SettingsScope = "user" | "workspace";

export interface SettingsSectionCandidate {
  id: string;
  text: string;
}

export interface SettingsSectionVisibility {
  id: string;
  scope: SettingsScope;
  visible: boolean;
}

export function getSettingsSectionScope(sectionId: string): SettingsScope {
  return sectionId === "settings-section-workspace" ? "workspace" : "user";
}

export function getSettingsTabScope(tabId: string): SettingsScope {
  return tabId === "settings-tab-workspace" ? "workspace" : "user";
}

export function filterSettingsSections(
  sections: readonly SettingsSectionCandidate[],
  scope: SettingsScope,
  query: string,
) {
  const normalizedQuery = query.trim().toLowerCase();
  let firstVisibleId = "";
  const items: SettingsSectionVisibility[] = sections.map((section) => {
    const sectionScope = getSettingsSectionScope(section.id);
    const visible = sectionScope === scope && (!normalizedQuery || section.text.toLowerCase().includes(normalizedQuery));
    if (visible && !firstVisibleId) {
      firstVisibleId = section.id;
    }
    return {
      id: section.id,
      scope: sectionScope,
      visible,
    };
  });

  return {
    firstVisibleId,
    items,
  };
}

export function shouldDisableSettingsNavItem(targetScope: SettingsScope, currentScope: SettingsScope, query: string, targetHidden: boolean) {
  if (targetScope !== currentScope) {
    return false;
  }
  return Boolean(query.trim() && targetHidden);
}
