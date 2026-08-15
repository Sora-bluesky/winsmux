use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map};

pub(crate) const USAGE: &str = "usage: winsmux workspace-migrate --action <list|preview|apply|rollback> --json [--preset <id>] [--project-dir <path>]";

const WORKSPACE_MIGRATE_LIST_JSON: &str = "{\"schema_version\":1,\"action\":\"list\",\"presets\":[{\"preset_id\":\"bugfix\"},{\"preset_id\":\"review\"},{\"preset_id\":\"research\"},{\"preset_id\":\"benchmark\"}]}\n";
const WORKSPACE_MIGRATE_SHIPPED_PRESETS: [&str; 4] = ["bugfix", "review", "research", "benchmark"];
const WORKSPACE_MIGRATE_SIDECAR_NAME: &str = "workspace-preset.json";

enum WorkspaceMigrateCommand {
    List,
    Preview {
        preset: String,
        project_dir: PathBuf,
    },
    Apply {
        preset: String,
        project_dir: PathBuf,
    },
    Rollback {
        project_dir: PathBuf,
    },
}

#[derive(Deserialize, Serialize)]
struct WorkspaceMigrateSidecar {
    schema_version: u64,
    preset_id: String,
    yaml_existed: bool,
    previous_yaml: String,
}

pub fn run_workspace_migrate_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{USAGE}");
        return Ok(());
    }

    let command = parse_workspace_migrate_options(args)?;
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    match command {
        WorkspaceMigrateCommand::List => {
            stdout.write_all(WORKSPACE_MIGRATE_LIST_JSON.as_bytes())?;
        }
        WorkspaceMigrateCommand::Preview {
            preset,
            project_dir,
        } => {
            let payload = preview_workspace_migrate_preset(&preset, &project_dir)?;
            stdout.write_all(payload.as_bytes())?;
        }
        WorkspaceMigrateCommand::Apply {
            preset,
            project_dir,
        } => {
            let payload = apply_workspace_migrate_preset(&preset, &project_dir)?;
            stdout.write_all(payload.as_bytes())?;
        }
        WorkspaceMigrateCommand::Rollback { project_dir } => {
            let payload = rollback_workspace_migrate(&project_dir)?;
            stdout.write_all(payload.as_bytes())?;
        }
    }
    Ok(())
}

fn should_print_help(args: &[&String]) -> bool {
    args.iter().any(|arg| *arg == "-h" || *arg == "--help")
}

fn required_option_value(args: &[&String], index: usize, flag: &str) -> io::Result<String> {
    let Some(value) = args.get(index + 1) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{flag} requires a value"),
        ));
    };
    Ok(value.to_string())
}

fn workspace_migrate_action_json(action: &str, preset: &str) -> String {
    if action == "preview" {
        format!(
            "{{\"schema_version\":1,\"action\":\"preview\",\"preset_id\":\"{preset}\",\"recipe_id\":\"{preset}\",\"sinks\":[{{\"path\":\".winsmux.yaml\",\"kind\":\"workspace-recipes\"}},{{\"path\":\".winsmux/workspace-preset.json\",\"kind\":\"adoption-sidecar\"}}]}}\n"
        )
    } else {
        format!(
            "{{\"schema_version\":1,\"action\":\"{action}\",\"preset_id\":\"{preset}\",\"recipe_id\":\"{preset}\"}}\n"
        )
    }
}

fn workspace_migrate_yaml_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux.yaml")
}

fn workspace_migrate_sidecar_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join(WORKSPACE_MIGRATE_SIDECAR_NAME)
}

fn shipped_workspace_recipe(preset: &str) -> serde_json::Value {
    json!({
        "schema-version": 1,
        "panes": [{
            "pane-key": "implement",
            "workflow-role": "implementer",
            "slot-ref": "worker-1",
            "requires-capabilities": ["file-edit"],
            "region": "main",
            "worktree": {
                "mode": "managed",
                "name-template": format!("{preset}-implement")
            }
        }],
        "startup-actions": [{
            "action-id": "prepare-implement-worktree",
            "kind": "ensure-managed-worktree",
            "pane-ref": "implement"
        }]
    })
}

fn merged_workspace_recipes(original_yaml: &str, preset: &str) -> io::Result<serde_json::Value> {
    let root = crate::workspace_recipe::parse_workspace_yaml(original_yaml)?;
    let mut recipes = match root
        .as_mapping()
        .and_then(|mapping| mapping.get(&serde_yaml::Value::String("workspace-recipes".into())))
    {
        None => Map::new(),
        Some(serde_yaml::Value::Mapping(mapping)) => serde_json::to_value(mapping)
            .ok()
            .and_then(|value| match value {
                serde_json::Value::Object(object) => Some(object),
                _ => None,
            })
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "workspace-recipes must be a mapping.",
                )
            })?,
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "workspace-recipes must be a mapping.",
            ));
        }
    };
    recipes.insert(preset.to_string(), shipped_workspace_recipe(preset));
    Ok(serde_json::Value::Object(recipes))
}

fn replace_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = path.with_file_name(format!(
        "{}.tmp-workspace-migrate",
        path.file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io::Error::new(
                io::ErrorKind::InvalidInput,
                "workspace-migrate cannot write the target path.",
            ))?
    ));
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path).map_err(|error| {
        let _ = fs::remove_file(&tmp);
        error
    })
}

fn workspace_migrate_read_yaml(yaml_path: &Path) -> io::Result<(bool, String)> {
    let yaml_existed = yaml_path.exists();
    let previous_yaml = if yaml_existed {
        fs::read_to_string(yaml_path).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "failed to read project .winsmux.yaml.",
            )
        })?
    } else {
        String::new()
    };
    Ok((yaml_existed, previous_yaml))
}

fn workspace_migrate_render_preset(previous_yaml: &str, preset: &str) -> io::Result<String> {
    let recipes = merged_workspace_recipes(previous_yaml, preset)?;
    crate::project_settings_render::render_owned_workspace_recipes(previous_yaml, recipes)
}

fn preview_workspace_migrate_preset(preset: &str, project_dir: &Path) -> io::Result<String> {
    let yaml_path = workspace_migrate_yaml_path(project_dir);
    let (_yaml_existed, original_yaml) = workspace_migrate_read_yaml(&yaml_path)?;
    workspace_migrate_render_preset(&original_yaml, preset)?;
    Ok(workspace_migrate_action_json("preview", preset))
}

fn apply_workspace_migrate_preset(preset: &str, project_dir: &Path) -> io::Result<String> {
    let yaml_path = workspace_migrate_yaml_path(project_dir);
    let sidecar_path = workspace_migrate_sidecar_path(project_dir);
    if sidecar_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "workspace-migrate apply requires rollback before another apply.",
        ));
    }

    let (yaml_existed, previous_yaml) = workspace_migrate_read_yaml(&yaml_path)?;
    let rendered = workspace_migrate_render_preset(&previous_yaml, preset)?;

    fs::create_dir_all(sidecar_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace-migrate cannot write the adoption sidecar.",
        )
    })?)?;
    let sidecar = WorkspaceMigrateSidecar {
        schema_version: 1,
        preset_id: preset.to_string(),
        yaml_existed,
        previous_yaml,
    };
    let sidecar_bytes = serde_json::to_vec(&sidecar).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "failed to serialize the adoption sidecar.",
        )
    })?;
    replace_file(&sidecar_path, &sidecar_bytes)?;
    if let Err(error) = replace_file(&yaml_path, rendered.as_bytes()) {
        let _ = fs::remove_file(&sidecar_path);
        return Err(error);
    }
    Ok(workspace_migrate_action_json("apply", preset))
}

fn rollback_workspace_migrate(project_dir: &Path) -> io::Result<String> {
    let yaml_path = workspace_migrate_yaml_path(project_dir);
    let sidecar_path = workspace_migrate_sidecar_path(project_dir);
    let sidecar_bytes = fs::read(&sidecar_path).map_err(|_| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "workspace-migrate rollback requires an adoption sidecar.",
        )
    })?;
    let sidecar: WorkspaceMigrateSidecar = serde_json::from_slice(&sidecar_bytes).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid workspace-migrate adoption sidecar.",
        )
    })?;
    if sidecar.schema_version != 1
        || !WORKSPACE_MIGRATE_SHIPPED_PRESETS.contains(&sidecar.preset_id.as_str())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid workspace-migrate adoption sidecar.",
        ));
    }

    let expected = workspace_migrate_render_preset(&sidecar.previous_yaml, &sidecar.preset_id)?;
    let current = if yaml_path.exists() {
        fs::read(&yaml_path).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "failed to read project .winsmux.yaml.",
            )
        })?
    } else {
        Vec::new()
    };
    if current.as_slice() != expected.as_bytes() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "workspace-migrate rollback requires the applied yaml to be unchanged.",
        ));
    }

    if sidecar.yaml_existed {
        replace_file(&yaml_path, sidecar.previous_yaml.as_bytes())?;
    } else if yaml_path.exists() {
        fs::remove_file(&yaml_path)?;
    }
    fs::remove_file(&sidecar_path)?;
    Ok(workspace_migrate_action_json("rollback", &sidecar.preset_id))
}

fn parse_workspace_migrate_options(args: &[&String]) -> io::Result<WorkspaceMigrateCommand> {
    let mut action: Option<String> = None;
    let mut preset: Option<String> = None;
    let mut project_dir: Option<PathBuf> = None;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--action" => {
                if action.is_some() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--action may be specified only once.",
                    ));
                }
                action = Some(required_option_value(args, index, "--action")?);
                index += 2;
            }
            "--preset" => {
                if preset.is_some() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--preset may be specified only once.",
                    ));
                }
                preset = Some(required_option_value(args, index, "--preset")?);
                index += 2;
            }
            "--project-dir" => {
                if project_dir.is_some() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--project-dir may be specified only once.",
                    ));
                }
                project_dir = Some(PathBuf::from(required_option_value(
                    args,
                    index,
                    "--project-dir",
                )?));
                index += 2;
            }
            "--json" => {
                if json {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--json may be specified only once.",
                    ));
                }
                json = true;
                index += 1;
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown workspace-migrate argument.",
                ));
            }
        }
    }

    let action = action.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace-migrate requires --action list, preview, apply, or rollback.",
        )
    })?;
    if !json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace-migrate requires --json.",
        ));
    }

    match action.as_str() {
        "list" => {
            if preset.is_some() || project_dir.is_some() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workspace-migrate list does not accept --preset or --project-dir.",
                ));
            }
            Ok(WorkspaceMigrateCommand::List)
        }
        "preview" | "apply" => {
            let preset = preset.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("workspace-migrate {action} requires --preset."),
                )
            })?;
            if !WORKSPACE_MIGRATE_SHIPPED_PRESETS.contains(&preset.as_str()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown workspace-migrate preset.",
                ));
            }
            let project_dir = project_dir.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("workspace-migrate {action} requires --project-dir."),
                )
            })?;
            if !project_dir.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("workspace-migrate {action} requires an existing --project-dir."),
                ));
            }
            if action == "preview" {
                Ok(WorkspaceMigrateCommand::Preview {
                    preset,
                    project_dir,
                })
            } else {
                Ok(WorkspaceMigrateCommand::Apply {
                    preset,
                    project_dir,
                })
            }
        }
        "rollback" => {
            if preset.is_some() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workspace-migrate rollback does not accept --preset.",
                ));
            }
            let project_dir = project_dir.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workspace-migrate rollback requires --project-dir.",
                )
            })?;
            if !project_dir.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workspace-migrate rollback requires an existing --project-dir.",
                ));
            }
            Ok(WorkspaceMigrateCommand::Rollback { project_dir })
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace-migrate --action must be list, preview, apply, or rollback.",
        )),
    }
}
