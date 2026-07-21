use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io,
    path::Path,
};

const REASONING_EFFORTS: [&str; 6] =
    ["provider-default", "low", "medium", "high", "max", "xhigh"];

#[derive(Clone, Debug, Default)]
pub(crate) struct ProjectRoleSettings {
    pub(crate) agent: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) model_source: Option<String>,
    pub(crate) reasoning_effort: Option<String>,
    pub(crate) prompt_transport: Option<String>,
    pub(crate) auth_mode: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct ProjectSlotSettings {
    pub(crate) slot_id: String,
    pub(crate) agent: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) model_source: Option<String>,
    pub(crate) reasoning_effort: Option<String>,
    pub(crate) prompt_transport: Option<String>,
    pub(crate) auth_mode: Option<String>,
}

#[derive(Default)]
pub(crate) struct WorkspacePlanProjectSettings {
    pub(crate) agent: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) model_source: Option<String>,
    pub(crate) reasoning_effort: Option<String>,
    pub(crate) prompt_transport: Option<String>,
    pub(crate) auth_mode: Option<String>,
    pub(crate) external_operator: Option<bool>,
    pub(crate) worker_count: Option<i32>,
    pub(crate) legacy_role_layout: Option<bool>,
    pub(crate) legacy_role_count: i64,
    pub(crate) worker_role: ProjectRoleSettings,
    pub(crate) agent_slots: Vec<ProjectSlotSettings>,
}

#[derive(Clone, Copy)]
enum Scope {
    Top,
    Slot,
    Role,
}

pub(crate) fn read(project_dir: &Path) -> io::Result<WorkspacePlanProjectSettings> {
    let path = project_dir.join(".winsmux.yaml");
    if !path.exists() {
        return Ok(WorkspacePlanProjectSettings::default());
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(WorkspacePlanProjectSettings::default());
    }
    let root = serde_yaml::from_str::<serde_yaml::Value>(&raw)
        .map_err(|_| invalid("Invalid project settings YAML."))?;
    parse(&root)
}

fn parse(root: &serde_yaml::Value) -> io::Result<WorkspacePlanProjectSettings> {
    let values = canonical_mapping(root, Scope::Top)?;
    if let Some(value) = values.get("config_version") {
        if yaml_i32(value) != Some(1) {
            return Err(invalid(
                "Invalid project settings: unsupported config_version.",
            ));
        }
    }

    let mut settings = WorkspacePlanProjectSettings {
        agent: project_text(&values, "agent")?,
        model: project_text(&values, "model")?,
        model_source: project_text(&values, "model_source")?,
        auth_mode: project_text(&values, "auth_mode")?,
        external_operator: project_bool(&values, "external_operator")?,
        worker_count: project_i32(&values, "worker_count")?,
        legacy_role_layout: project_bool(&values, "legacy_role_layout")?,
        ..WorkspacePlanProjectSettings::default()
    };
    settings.prompt_transport = project_domain(
        &values,
        "prompt_transport",
        &["argv", "file", "stdin"],
    )?;
    settings.reasoning_effort =
        project_domain(&values, "reasoning_effort", &REASONING_EFFORTS)?;
    let _ = project_domain(
        &values,
        "worker_backend",
        &["local", "codex", "api_llm", "antigravity", "noop"],
    )?;
    let _ = project_domain(
        &values,
        "execution_profile",
        &["local-windows", "isolated-enterprise"],
    )?;
    let _ = project_domain(
        &values,
        "workspace_lifecycle_preset",
        &["none", "managed-worktree", "ephemeral-worktree"],
    )?;
    settings.agent_slots = match values.get("agent_slots") {
        Some(value) => parse_slots(value)?,
        None => Vec::new(),
    };
    settings.worker_role = match values.get("roles") {
        Some(value) => parse_roles(value)?,
        None => ProjectRoleSettings::default(),
    };
    for key in ["operators", "builders", "researchers", "reviewers"] {
        if let Some(value) = project_i32(&values, key)? {
            settings.legacy_role_count += i64::from(value);
        }
    }
    let _ = project_text(&values, "terminal")?;
    if let Some(value) = values.get("vault_keys") {
        let valid = match value {
            serde_yaml::Value::Sequence(items) => items.iter().all(|item| yaml_text(item).is_some()),
            _ => yaml_text(value).is_some(),
        };
        if !valid {
            return Err(invalid(
                "Invalid project settings: invalid runtime-owned value shape.",
            ));
        }
    }
    Ok(settings)
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn canonical_mapping(
    value: &serde_yaml::Value,
    scope: Scope,
) -> io::Result<BTreeMap<String, serde_yaml::Value>> {
    let mapping = value.as_mapping().ok_or_else(|| {
        invalid(match scope {
            Scope::Top => "Invalid project settings: root must be a mapping.",
            Scope::Slot => {
                "Invalid agent_slots configuration: every slot entry must be a mapping."
            }
            Scope::Role => "Invalid roles configuration: every role entry must be a mapping.",
        })
    })?;
    let mut result = BTreeMap::new();
    for (source_key, value) in mapping {
        let Some(source_key) = source_key.as_str() else {
            continue;
        };
        let mut key = source_key.replace('-', "_").to_ascii_lowercase();
        if matches!(scope, Scope::Top)
            && matches!(key.as_str(), "external_commander" | "commanders")
        {
            return Err(invalid("Retired project setting is not supported."));
        }
        if matches!(scope, Scope::Slot) {
            key = match key.as_str() {
                "backend" => "worker_backend".to_string(),
                "role" => "worker_role".to_string(),
                _ => key,
            };
        }
        if !known_key(&key, scope) {
            continue;
        }
        if result.insert(key, value.clone()).is_some() {
            return Err(invalid(match scope {
                Scope::Top => {
                    "Invalid project settings: conflicting runtime-owned aliases at top level."
                }
                Scope::Slot => {
                    "Invalid agent_slots configuration: conflicting runtime-owned aliases."
                }
                Scope::Role => "Invalid roles configuration: conflicting runtime-owned aliases.",
            }));
        }
    }
    Ok(result)
}

fn known_key(key: &str, scope: Scope) -> bool {
    match scope {
        Scope::Top => matches!(
            key,
            "config_version"
                | "agent"
                | "model"
                | "model_source"
                | "reasoning_effort"
                | "prompt_transport"
                | "auth_mode"
                | "external_operator"
                | "worker_count"
                | "worker_backend"
                | "execution_profile"
                | "agent_slots"
                | "legacy_role_layout"
                | "operators"
                | "builders"
                | "researchers"
                | "reviewers"
                | "vault_keys"
                | "terminal"
                | "workspace_lifecycle_preset"
                | "roles"
        ),
        Scope::Slot => matches!(
            key,
            "slot_id"
                | "runtime_role"
                | "agent"
                | "model"
                | "model_source"
                | "reasoning_effort"
                | "prompt_transport"
                | "mcp_mode"
                | "auth_mode"
                | "worktree_mode"
                | "worker_backend"
                | "execution_profile"
                | "worker_role"
                | "pane_title"
                | "fallback_model"
        ),
        Scope::Role => matches!(
            key,
            "agent"
                | "model"
                | "model_source"
                | "reasoning_effort"
                | "prompt_transport"
                | "auth_mode"
        ),
    }
}

fn yaml_text(value: &serde_yaml::Value) -> Option<String> {
    let text = match value {
        serde_yaml::Value::Bool(value) => value.to_string(),
        serde_yaml::Value::Number(value) => value.to_string(),
        serde_yaml::Value::String(value) => value.to_string(),
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn yaml_bool(value: &serde_yaml::Value) -> Option<bool> {
    let value = yaml_text(value)?;
    match value.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn yaml_i32(value: &serde_yaml::Value) -> Option<i32> {
    yaml_text(value)?.parse::<i32>().ok()
}

fn mapping_text(values: &BTreeMap<String, serde_yaml::Value>, key: &str) -> Option<String> {
    values.get(key).and_then(yaml_text)
}

fn project_text(
    values: &BTreeMap<String, serde_yaml::Value>,
    key: &str,
) -> io::Result<Option<String>> {
    let Some(value) = values.get(key) else {
        return Ok(None);
    };
    yaml_text(value).map(Some).ok_or_else(|| {
        invalid("Invalid project settings: invalid runtime-owned value shape.")
    })
}

fn project_bool(
    values: &BTreeMap<String, serde_yaml::Value>,
    key: &str,
) -> io::Result<Option<bool>> {
    let Some(value) = values.get(key) else {
        return Ok(None);
    };
    yaml_bool(value)
        .map(Some)
        .ok_or_else(|| invalid("Invalid project settings: unsupported runtime-owned value."))
}

fn project_i32(
    values: &BTreeMap<String, serde_yaml::Value>,
    key: &str,
) -> io::Result<Option<i32>> {
    let Some(value) = values.get(key) else {
        return Ok(None);
    };
    yaml_i32(value)
        .map(Some)
        .ok_or_else(|| invalid("Invalid project settings: unsupported runtime-owned value."))
}

fn project_domain(
    values: &BTreeMap<String, serde_yaml::Value>,
    key: &str,
    allowed: &[&str],
) -> io::Result<Option<String>> {
    let Some(value) = values.get(key) else {
        return Ok(None);
    };
    let normalized = yaml_text(value)
        .map(|value| value.to_ascii_lowercase())
        .filter(|value| allowed.contains(&value.as_str()))
        .ok_or_else(|| invalid("Invalid project settings: unsupported runtime-owned value."))?;
    Ok(Some(normalized))
}

fn nested_domain(
    values: &BTreeMap<String, serde_yaml::Value>,
    key: &str,
    allowed: &[&str],
    scope: Scope,
) -> io::Result<Option<String>> {
    let Some(value) = values.get(key) else {
        return Ok(None);
    };
    let normalized = yaml_text(value).expect("known nested values are validated").to_ascii_lowercase();
    if allowed.contains(&normalized.as_str()) {
        Ok(Some(normalized))
    } else {
        Err(invalid(match scope {
            Scope::Slot => {
                "Invalid agent_slots configuration: unsupported runtime-owned value."
            }
            Scope::Role => "Invalid roles configuration: unsupported runtime-owned value.",
            Scope::Top => unreachable!(),
        }))
    }
}

fn parse_slots(value: &serde_yaml::Value) -> io::Result<Vec<ProjectSlotSettings>> {
    let items = value.as_sequence().ok_or_else(|| {
        invalid("Invalid agent_slots configuration: every slot entry must include at least slot_id.")
    })?;
    let mut slots = Vec::new();
    let mut slot_ids = HashMap::new();
    for item in items {
        let values = canonical_mapping(item, Scope::Slot)?;
        if values.values().any(|value| yaml_text(value).is_none()) {
            return Err(invalid(
                "Invalid agent_slots configuration: invalid runtime-owned value shape.",
            ));
        }
        let slot_id = mapping_text(&values, "slot_id").ok_or_else(|| {
            invalid("Invalid agent_slots configuration: every slot entry must include at least slot_id.")
        })?;
        if slot_ids.insert(slot_id.to_ascii_lowercase(), ()).is_some() {
            return Err(invalid(
                "Invalid agent_slots configuration: duplicate slot_id.",
            ));
        }
        let _ = nested_domain(
            &values,
            "worker_backend",
            &["local", "codex", "api_llm", "antigravity", "noop"],
            Scope::Slot,
        )?;
        let _ = nested_domain(
            &values,
            "execution_profile",
            &["local-windows", "isolated-enterprise"],
            Scope::Slot,
        )?;
        let _ = nested_domain(
            &values,
            "mcp_mode",
            &["provider-default", "enabled", "disabled"],
            Scope::Slot,
        )?;
        let _ = nested_domain(&values, "runtime_role", &["worker"], Scope::Slot)?;
        let _ = nested_domain(&values, "worktree_mode", &["managed"], Scope::Slot)?;
        let reasoning_effort =
            nested_domain(&values, "reasoning_effort", &REASONING_EFFORTS, Scope::Slot)?;
        let prompt_transport = nested_domain(
            &values,
            "prompt_transport",
            &["argv", "file", "stdin"],
            Scope::Slot,
        )?;
        let model = mapping_text(&values, "model");
        let model_source = mapping_text(&values, "model_source")
            .or_else(|| model.as_deref().map(inferred_model_source));
        slots.push(ProjectSlotSettings {
            slot_id,
            agent: mapping_text(&values, "agent"),
            model,
            model_source,
            reasoning_effort,
            prompt_transport,
            auth_mode: mapping_text(&values, "auth_mode"),
        });
    }
    Ok(slots)
}

fn parse_roles(value: &serde_yaml::Value) -> io::Result<ProjectRoleSettings> {
    let roles = value
        .as_mapping()
        .ok_or_else(|| invalid("Invalid roles configuration: roles must be a mapping."))?;
    let mut worker = ProjectRoleSettings::default();
    let mut role_names = HashMap::new();
    for (role_name, role_value) in roles {
        let Some(role_name) = role_name.as_str().map(str::trim).filter(|value| !value.is_empty())
        else {
            return Err(invalid("Invalid roles configuration: invalid role name."));
        };
        if role_names
            .insert(role_name.to_ascii_lowercase(), ())
            .is_some()
        {
            return Err(invalid("Invalid roles configuration: duplicate role name."));
        }
        let values = canonical_mapping(role_value, Scope::Role)?;
        if values.values().any(|value| yaml_text(value).is_none()) {
            return Err(invalid(
                "Invalid roles configuration: invalid runtime-owned value shape.",
            ));
        }
        let reasoning_effort =
            nested_domain(&values, "reasoning_effort", &REASONING_EFFORTS, Scope::Role)?;
        let prompt_transport = nested_domain(
            &values,
            "prompt_transport",
            &["argv", "file", "stdin"],
            Scope::Role,
        )?;
        if role_name.eq_ignore_ascii_case("worker") {
            let model = mapping_text(&values, "model");
            worker = ProjectRoleSettings {
                agent: mapping_text(&values, "agent"),
                model: model.clone(),
                model_source: mapping_text(&values, "model_source")
                    .or_else(|| model.as_deref().map(inferred_model_source)),
                reasoning_effort,
                prompt_transport,
                auth_mode: mapping_text(&values, "auth_mode"),
            };
        }
    }
    Ok(worker)
}

fn inferred_model_source(model: &str) -> String {
    if model.trim().is_empty() || model.trim().eq_ignore_ascii_case("provider-default") {
        "provider-default".to_string()
    } else {
        "operator-override".to_string()
    }
}
