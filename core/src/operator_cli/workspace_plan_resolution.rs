use std::{io, path::Path};

use crate::workspace_project_settings;
use crate::workspace_recipe::SlotCapabilities;

use super::{
    finalize_bridge_settings, read_workspace_plan_global_option,
    read_workspace_plan_global_settings, resolve_slot_agent_config, BridgeSettings,
    WorkspacePlanGlobalOptionRead,
};

pub(super) fn finalize_workspace_plan_settings_from_root_with_global_reader<F>(
    project_dir: &Path,
    root: &serde_yaml::Value,
    read_global: &mut F,
) -> io::Result<BridgeSettings>
where
    F: FnMut(&str) -> Option<String>,
{
    let globals = read_workspace_plan_global_settings(read_global)?;
    let project = workspace_project_settings::parse_value(root)?;
    finalize_bridge_settings(project_dir, &globals, &project)
}

pub(super) fn resolve_workspace_plan_slot_capabilities(
    project_dir: &Path,
    settings: &BridgeSettings,
) -> io::Result<Vec<SlotCapabilities>> {
    settings
        .agent_slots
        .iter()
        .map(|slot| {
            let effective = resolve_slot_agent_config(project_dir, settings, &slot.slot_id)
                .map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "failed to resolve the effective slot catalog.",
                    )
                })?;
            let legacy_untyped_capabilities = effective.capability_adapter.trim().is_empty()
                && effective.capability_command.trim().is_empty();
            Ok(SlotCapabilities {
                slot_id: slot.slot_id.clone(),
                supports_file_edit: legacy_untyped_capabilities || effective.supports_file_edit,
                supports_verification: legacy_untyped_capabilities
                    || effective.supports_verification,
                supports_structured_result: legacy_untyped_capabilities
                    || effective.supports_structured_result,
            })
        })
        .collect()
}

pub(super) fn resolve_workspace_migration_slot_capabilities(
    project_dir: &Path,
    root: &serde_yaml::Value,
) -> io::Result<Vec<SlotCapabilities>> {
    let mut source_available = true;
    let mut read_global = |name: &str| {
        if !source_available {
            return None;
        }
        match read_workspace_plan_global_option(name) {
            WorkspacePlanGlobalOptionRead::Value(value) => Some(value),
            WorkspacePlanGlobalOptionRead::Missing => None,
            WorkspacePlanGlobalOptionRead::SourceUnavailable => {
                source_available = false;
                None
            }
        }
    };
    let settings = finalize_workspace_plan_settings_from_root_with_global_reader(
        project_dir,
        root,
        &mut read_global,
    )?;
    resolve_workspace_plan_slot_capabilities(project_dir, &settings)
}
