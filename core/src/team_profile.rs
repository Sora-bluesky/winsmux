use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs, io,
    path::{Path, PathBuf},
};

use serde::Serialize;
use serde_json::{json, Map, Value as JsonValue};
use serde_yaml::{Mapping, Value};
use sha2::{Digest, Sha256};

use crate::project_settings_render;
use crate::workspace_recipe::parse_workspace_yaml;

pub(crate) const USAGE: &str = "usage: winsmux team-profile --action <validate|resolve|save|reset-field|classify|project-launch|settings-view|start-gate|pre-release-gate> --json [--project-dir <path>] [--slot-id <id>] [--field <name>] [--value <value>] [--task-class <id>] [--delegation <id>] [--text <text>] [--session-id <id>] [--worktree <path>] [--read-write-scope <scope>]";

const OFFICIAL_PRESET_ID: &str = "official-balanced-v1";
const OFFICIAL_PRESET_YAML: &str =
    include_str!("../../winsmux-core/agents/team-profiles/official-balanced-v1.yaml");
const MODEL_CAPABILITIES_TS: &str = include_str!("../../winsmux-app/src/modelCapabilities.ts");
const SLOT_IDS: [&str; 6] = [
    "worker-1", "worker-2", "worker-3", "worker-4", "worker-5", "worker-6",
];
const ROLE_PROFILES: [&str; 5] = [
    "architect", "builder", "reviewer", "researcher", "maintainer",
];
const LIFECYCLES: [&str; 3] = ["session", "task", "one-shot"];
const TASK_CLASSES: [&str; 9] = [
    "architecture",
    "protocol",
    "security",
    "implementation",
    "test",
    "review",
    "research",
    "documentation",
    "repository-operations",
];
const WORKER_DELEGATION: [&str; 3] = [
    "frozen-spec-implementation",
    "repro-fix",
    "mechanical-migration",
];
const OPERATOR_DELEGATION: [&str; 5] = [
    "design-judgment",
    "api-judgment",
    "small-tweak",
    "secrets-mcp",
    "destructive-ops",
];
const LANE_B_SLOT_FIELDS: [&str; 7] = [
    "provider",
    "model",
    "reasoning-effort",
    "role-profile",
    "lifecycle",
    "task-classes",
    "delegation",
];
const TEAM_PROFILE_FIELDS: [&str; 4] = [
    "schema-version",
    "preset",
    "preset-revision",
    "update-policy",
];

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ValidationIssue {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slot_id: Option<String>,
    pub field: String,
    pub code: String,
    pub severity: String,
    pub remediation: String,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ResolvedSlot {
    #[serde(rename = "slot-id")]
    pub slot_id: String,
    pub provider: String,
    pub model: String,
    #[serde(rename = "launch-model")]
    pub launch_model: String,
    #[serde(rename = "reasoning-effort")]
    pub reasoning_effort: String,
    #[serde(rename = "role-profile")]
    pub role_profile: String,
    pub lifecycle: String,
    #[serde(rename = "task-classes")]
    pub task_classes: Vec<String>,
    pub delegation: Vec<String>,
    pub overrides: Vec<String>,
    #[serde(rename = "worker-backend", skip_serializing_if = "Option::is_none")]
    pub worker_backend: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ResolvedTeam {
    pub opted_in: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub team_profile: Option<TeamProfileMeta>,
    pub slots: Vec<ResolvedSlot>,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct TeamProfileMeta {
    #[serde(rename = "schema-version")]
    pub schema_version: i64,
    pub preset: String,
    #[serde(rename = "preset-revision")]
    pub preset_revision: i64,
    #[serde(rename = "update-policy")]
    pub update_policy: String,
}

#[derive(Clone, Debug)]
struct SlotRecord {
    slot_id: String,
    provider: String,
    model: String,
    reasoning_effort: String,
    role_profile: String,
    lifecycle: String,
    task_classes: Vec<String>,
    delegation: Vec<String>,
    worker_backend: Option<String>,
}

#[derive(Clone, Debug)]
struct ModelEntry {
    id: String,
    provider_id: String,
    launch_model: String,
    supported_effort_ids: Vec<String>,
    required_backend: String,
    readiness_state: String,
}

#[derive(Clone, Debug)]
struct Catalog {
    providers: BTreeSet<String>,
    provider_readiness: BTreeMap<String, String>,
    models: BTreeMap<String, ModelEntry>,
    backends: BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug)]
struct OverlaySlot {
    slot_id: String,
    fields: BTreeMap<String, Value>,
    extras: Mapping,
}

#[derive(Default)]
struct DispatchOptions {
    task_class: Option<String>,
    delegation: Option<String>,
    slot_id: Option<String>,
    project_dir: Option<PathBuf>,
    output: Option<PathBuf>,
    text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum DispatchGate {
    Passthrough,
    Refused(String),
    Classified { slot_id: String },
}

pub(crate) fn run_team_profile_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let mut action = None;
    let mut project_dir = None;
    let mut json = false;
    let mut slot_id = None;
    let mut field = None;
    let mut value = None;
    let mut task_class = None;
    let mut delegation = None;
    let mut text = None;
    let mut session_id = None;
    let mut worktree = None;
    let mut read_write_scope = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--action" => {
                action = Some(required_option(args, index, "--action")?);
                index += 2;
            }
            "--project-dir" => {
                project_dir = Some(PathBuf::from(required_option(args, index, "--project-dir")?));
                index += 2;
            }
            "--slot-id" => {
                slot_id = Some(required_option(args, index, "--slot-id")?);
                index += 2;
            }
            "--field" => {
                field = Some(required_option(args, index, "--field")?);
                index += 2;
            }
            "--value" => {
                value = Some(required_option(args, index, "--value")?);
                index += 2;
            }
            "--task-class" => {
                task_class = Some(required_option(args, index, "--task-class")?);
                index += 2;
            }
            "--delegation" => {
                delegation = Some(required_option(args, index, "--delegation")?);
                index += 2;
            }
            "--text" => {
                text = Some(required_option(args, index, "--text")?);
                index += 2;
            }
            "--session-id" => {
                session_id = Some(required_option(args, index, "--session-id")?);
                index += 2;
            }
            "--worktree" => {
                worktree = Some(required_option(args, index, "--worktree")?);
                index += 2;
            }
            "--read-write-scope" => {
                read_write_scope = Some(required_option(args, index, "--read-write-scope")?);
                index += 2;
            }
            "--json" => {
                json = true;
                index += 1;
            }
            _ => {
                return Err(invalid_input("unknown team-profile argument."));
            }
        }
    }
    if !json {
        return Err(invalid_input("team-profile requires --json."));
    }
    let action = action.ok_or_else(|| {
        invalid_input("team-profile requires --action validate, resolve, save, reset-field, classify, project-launch, settings-view, start-gate, or pre-release-gate.")
    })?;
    let project_dir = project_dir.unwrap_or(env::current_dir()?);
    match action.as_str() {
        "validate" => match resolve_project(&project_dir) {
            Ok(team) => print_json(json!({"schema_version":1,"ok":true,"team":team})),
            Err(issues) => print_issues(issues),
        },
        "resolve" => match resolve_project(&project_dir) {
            Ok(team) => print_json(json!({"schema_version":1,"ok":true,"team":team})),
            Err(issues) => print_issues(issues),
        },
        "save" => {
            let slot_id = slot_id.ok_or_else(|| invalid_input("save requires --slot-id."))?;
            let field = field.ok_or_else(|| invalid_input("save requires --field."))?;
            let value = value.ok_or_else(|| invalid_input("save requires --value."))?;
            save_slot_field(&project_dir, &slot_id, &field, &value)?;
            print_json(json!({"schema_version":1,"ok":true,"action":"save"}))
        }
        "reset-field" => {
            let slot_id = slot_id.ok_or_else(|| invalid_input("reset-field requires --slot-id."))?;
            let field = field.ok_or_else(|| invalid_input("reset-field requires --field."))?;
            reset_slot_field(&project_dir, &slot_id, &field)?;
            print_json(json!({"schema_version":1,"ok":true,"action":"reset-field"}))
        }
        "classify" => {
            let payload = classify_project(
                &project_dir,
                task_class.as_deref(),
                delegation.as_deref(),
                slot_id.as_deref(),
                text.as_deref().unwrap_or(""),
            )?;
            print_json(payload)
        }
        "project-launch" => {
            let slot_id = slot_id.ok_or_else(|| invalid_input("project-launch requires --slot-id."))?;
            let session_id = session_id.ok_or_else(|| invalid_input("project-launch requires --session-id."))?;
            let payload = crate::prompt_bundle::project_launch(
                &project_dir,
                &session_id,
                &slot_id,
                worktree.as_deref(),
                read_write_scope.as_deref(),
            )?;
            print_json(payload)
        }
        "settings-view" => print_json(crate::team_profile_settings::settings_view(&project_dir)),
        "start-gate" => {
            let (payload, allowed) = crate::team_profile_settings::start_gate(&project_dir);
            print_json(payload.clone())?;
            if allowed {
                Ok(())
            } else {
                Err(invalid_data("team-profile start gate refused."))
            }
        }
        "pre-release-gate" => {
            let payload = crate::team_profile_settings::pre_release_gate();
            print_json(payload.clone())?;
            if payload["ok"] == true {
                Ok(())
            } else {
                Err(invalid_data("team-profile pre-release gate failed."))
            }
        }
        _ => Err(invalid_input(
            "team-profile --action must be validate, resolve, save, reset-field, classify, project-launch, settings-view, start-gate, or pre-release-gate.",
        )),
    }
}

pub(crate) fn gate_dispatch(args: &[&String]) -> io::Result<DispatchGate> {
    let options = parse_dispatch_options(args);
    let project_dir = options
        .project_dir
        .clone()
        .unwrap_or(env::current_dir()?);
    let yaml_path = project_dir.join(".winsmux.yaml");
    if !yaml_path.exists() {
        return Ok(DispatchGate::Passthrough);
    }
    let yaml = fs::read_to_string(&yaml_path)?;
    if !document_has_team_profile(&yaml) {
        return Ok(DispatchGate::Passthrough);
    }
    let payload = classify_project(
        &project_dir,
        options.task_class.as_deref(),
        options.delegation.as_deref(),
        options.slot_id.as_deref(),
        &options.text,
    )?;
    let status = payload
        .get("status")
        .and_then(JsonValue::as_str)
        .unwrap_or("refused");
    if status != "dispatchable" {
        return Ok(DispatchGate::Refused(payload.to_string()));
    }
    let slot_id = payload
        .get("slot_id")
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if let Some(slot_id) = slot_id {
        Ok(DispatchGate::Classified {
            slot_id: slot_id.to_string(),
        })
    } else {
        Ok(DispatchGate::Passthrough)
    }
}

pub(crate) fn with_classified_slot(cmd_args: &[&String], slot_id: &str) -> Vec<String> {
    let mut forwarded: Vec<String> = cmd_args.iter().map(|arg| (*arg).clone()).collect();
    if dispatch_args_have_slot_id(&forwarded) {
        return forwarded;
    }
    if let Some(separator) = forwarded.iter().position(|arg| arg == "--") {
        forwarded.insert(separator, "--slot-id".to_string());
        forwarded.insert(separator + 1, slot_id.to_string());
    } else {
        forwarded.push("--slot-id".to_string());
        forwarded.push(slot_id.to_string());
    }
    forwarded
}

fn dispatch_args_have_slot_id(args: &[String]) -> bool {
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--slot-id" => return true,
            "--" => return false,
            _ => index += 1,
        }
    }
    false
}

fn print_json(value: JsonValue) -> io::Result<()> {
    println!("{}", value);
    Ok(())
}

fn print_issues(issues: Vec<ValidationIssue>) -> io::Result<()> {
    print_json(json!({"schema_version":1,"ok":false,"issues":issues}))?;
    Err(invalid_data("team-profile validation failed."))
}

fn required_option(args: &[&String], index: usize, flag: &str) -> io::Result<String> {
    args.get(index + 1)
        .map(|value| (*value).clone())
        .ok_or_else(|| invalid_input(format!("{flag} requires a value.")))
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn issue(
    slot_id: Option<&str>,
    field: &str,
    code: &str,
    remediation: impl Into<String>,
) -> ValidationIssue {
    ValidationIssue {
        slot_id: slot_id.map(str::to_string),
        field: field.to_string(),
        code: code.to_string(),
        severity: "error".to_string(),
        remediation: remediation.into(),
    }
}

pub(crate) fn document_has_team_profile(yaml: &str) -> bool {
    match parse_workspace_yaml(yaml) {
        Ok(root) => root.as_mapping().is_some_and(|mapping| {
            mapping.contains_key(&Value::String("team-profile".into()))
                || mapping.contains_key(&Value::String("team_profile".into()))
        }),
        Err(_) => yaml.lines().any(|line| {
            let trimmed = line.trim().trim_start_matches(|c: char| matches!(c, '\'' | '"'));
            trimmed.starts_with("team-profile:") || trimmed.starts_with("team_profile:")
        }),
    }
}

fn parse_dispatch_options(args: &[&String]) -> DispatchOptions {
    let mut options = DispatchOptions::default();
    let mut index = 0;
    let mut text = Vec::new();
    while index < args.len() {
        match args[index].as_str() {
            "--task-class" if index + 1 < args.len() => {
                options.task_class = Some(args[index + 1].to_string());
                index += 2;
            }
            "--delegation" if index + 1 < args.len() => {
                options.delegation = Some(args[index + 1].to_string());
                index += 2;
            }
            "--slot-id" if index + 1 < args.len() => {
                options.slot_id = Some(args[index + 1].to_string());
                index += 2;
            }
            "--project-dir" if index + 1 < args.len() => {
                options.project_dir = Some(PathBuf::from(args[index + 1].as_str()));
                index += 2;
            }
            "--output" | "-o" if index + 1 < args.len() => {
                options.output = Some(PathBuf::from(args[index + 1].as_str()));
                index += 2;
            }
            "--json" => index += 1,
            "--" => {
                text.extend(args[index + 1..].iter().map(|value| (*value).clone()));
                break;
            }
            other => {
                text.push(other.to_string());
                index += 1;
            }
        }
    }
    options.text = text.join(" ");
    options
}

fn catalog() -> Catalog {
    parse_model_capabilities(MODEL_CAPABILITIES_TS)
}

fn parse_model_capabilities(source: &str) -> Catalog {
    let providers = parse_ts_string_array(source, "providerCapabilityIds")
        .into_iter()
        .collect();
    let mut backends = BTreeMap::new();
    for object in extract_objects(array_body(source, "backendCapabilities")) {
        if let Some(id) = ts_string_field(object, "id") {
            backends.insert(id, ts_string_array_field(object, "assignableBackends"));
        }
    }
    let mut models = BTreeMap::new();
    for object in extract_objects(array_body(source, "modelCapabilities")) {
        let Some(id) = ts_string_field(object, "id") else {
            continue;
        };
        let Some(provider_id) = ts_string_field(object, "providerId") else {
            continue;
        };
        models.insert(
            id.clone(),
            ModelEntry {
                id,
                provider_id,
                launch_model: ts_string_field(object, "model").unwrap_or_default(),
                supported_effort_ids: ts_string_array_field(object, "supportedEffortIds"),
                required_backend: ts_string_field(object, "requiredBackend").unwrap_or_default(),
                readiness_state: ts_readiness_state(object).unwrap_or_default(),
            },
        );
    }
    let mut provider_readiness = BTreeMap::new();
    for object in extract_objects(array_body(source, "providerCapabilities")) {
        if let Some(id) = ts_string_field(object, "id") {
            if let Some(state) = ts_readiness_state(object) {
                provider_readiness.insert(id, state);
            }
        }
    }
    Catalog {
        providers,
        provider_readiness,
        models,
        backends,
    }
}

fn array_body<'a>(source: &'a str, export_name: &str) -> &'a str {
    let marker = format!("export const {export_name}");
    let Some(start) = source.find(&marker) else {
        return "";
    };
    let rest = &source[start..];
    // Skip TypeScript type brackets such as `readonly ModelCapability[] = [`.
    let Some(eq) = rest.find('=') else {
        return "";
    };
    let assigned = &rest[eq..];
    let Some(open) = assigned.find('[') else {
        return "";
    };
    let absolute = start + eq + open;
    let mut depth = 0;
    let mut in_str = false;
    let mut escape = false;
    for (offset, ch) in source[absolute..].char_indices() {
        if in_str {
            if escape {
                escape = false;
            } else if ch == '\\' {
                escape = true;
            } else if ch == '"' {
                in_str = false;
            }
            continue;
        }
        match ch {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return &source[absolute + 1..absolute + offset];
                }
            }
            _ => {}
        }
    }
    ""
}

fn parse_ts_string_array(source: &str, export_name: &str) -> Vec<String> {
    quoted_strings(array_body(source, export_name))
}

fn quoted_strings(body: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut in_str = false;
    let mut escape = false;
    let mut current = String::new();
    for ch in body.chars() {
        if in_str {
            if escape {
                current.push(ch);
                escape = false;
            } else if ch == '\\' {
                escape = true;
            } else if ch == '"' {
                values.push(std::mem::take(&mut current));
                in_str = false;
            } else {
                current.push(ch);
            }
        } else if ch == '"' {
            in_str = true;
        }
    }
    values
}

fn extract_objects(body: &str) -> Vec<&str> {
    let mut objects = Vec::new();
    let bytes = body.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            let start = i;
            let mut depth = 0;
            let mut in_str = false;
            let mut escape = false;
            while i < bytes.len() {
                let c = bytes[i];
                if in_str {
                    if escape {
                        escape = false;
                    } else if c == b'\\' {
                        escape = true;
                    } else if c == b'"' {
                        in_str = false;
                    }
                } else if c == b'"' {
                    in_str = true;
                } else if c == b'{' {
                    depth += 1;
                } else if c == b'}' {
                    depth -= 1;
                    if depth == 0 {
                        objects.push(&body[start..=i]);
                        break;
                    }
                }
                i += 1;
            }
        }
        i += 1;
    }
    objects
}

fn ts_field_rest<'a>(object: &'a str, field: &str) -> Option<&'a str> {
    let pattern = format!("{field}:");
    let mut search = object;
    while let Some(idx) = search.find(&pattern) {
        let before = if idx == 0 {
            ' '
        } else {
            search[..idx].chars().next_back().unwrap_or(' ')
        };
        if !before.is_ascii_alphanumeric() {
            return Some(search[idx + pattern.len()..].trim_start());
        }
        search = &search[idx + 1..];
    }
    None
}

fn ts_string_field(object: &str, field: &str) -> Option<String> {
    quoted_strings(ts_field_rest(object, field)?).into_iter().next()
}

fn ts_string_array_field(object: &str, field: &str) -> Vec<String> {
    let Some(rest) = ts_field_rest(object, field) else {
        return Vec::new();
    };
    if !rest.starts_with('[') {
        return Vec::new();
    }
    let Some(close) = rest.find(']') else {
        return Vec::new();
    };
    quoted_strings(&rest[1..close])
}

fn ts_readiness_state(object: &str) -> Option<String> {
    let idx = object.find("readiness:")?;
    ts_string_field(&object[idx..], "state")
}


pub(crate) fn model_readiness(model_id: &str) -> Option<String> {
    catalog().models.get(model_id).map(|model| model.readiness_state.clone())
}

pub(crate) fn provider_readiness(provider_id: &str) -> Option<String> {
    catalog().provider_readiness.get(provider_id).cloned()
}

pub(crate) fn catalog_readiness_states() -> Vec<String> {
    let catalog = catalog();
    let mut states = BTreeSet::new();
    for state in catalog.provider_readiness.values() {
        if !state.is_empty() {
            states.insert(state.clone());
        }
    }
    for model in catalog.models.values() {
        if !model.readiness_state.is_empty() {
            states.insert(model.readiness_state.clone());
        }
    }
    states.into_iter().collect()
}

pub(crate) fn resolve_project(project_dir: &Path) -> Result<ResolvedTeam, Vec<ValidationIssue>> {
    let path = project_dir.join(".winsmux.yaml");
    let yaml = fs::read_to_string(&path).map_err(|_| {
        vec![issue(
            None,
            "document",
            "missing_settings",
            "Create .winsmux.yaml before resolving a Team Profile.",
        )]
    })?;
    resolve_yaml(&yaml, OFFICIAL_PRESET_YAML, &catalog())
}

fn resolve_yaml(
    yaml: &str,
    preset_yaml: &str,
    catalog: &Catalog,
) -> Result<ResolvedTeam, Vec<ValidationIssue>> {
    let root = parse_workspace_yaml(yaml).map_err(|error| {
        vec![issue(
            None,
            "document",
            if error.to_string() == "duplicate YAML mapping key." {
                "duplicate_mapping_key"
            } else {
                "invalid_yaml"
            },
            error.to_string(),
        )]
    })?;
    let mapping = root.as_mapping().ok_or_else(|| {
        vec![issue(
            None,
            "document",
            "root_not_mapping",
            ".winsmux.yaml must be a mapping.",
        )]
    })?;
    if let Some(version) = mapping_lookup(mapping, "config-version")? {
        if yaml_i64(version) != Some(1) {
            return Err(vec![issue(
                None,
                "config-version",
                "unsupported_config_version",
                "config-version must be 1.",
            )]);
        }
    }
    let team_profile_value = mapping_lookup(mapping, "team-profile")?;
    let overlays = parse_overlay_slots(mapping)?;
    if team_profile_value.is_none() {
        return Ok(ResolvedTeam {
            opted_in: false,
            team_profile: None,
            slots: overlays
                .into_iter()
                .map(|overlay| legacy_slot(overlay))
                .collect(),
        });
    }
    let meta = parse_team_profile_meta(team_profile_value.unwrap())?;
    if meta.preset != OFFICIAL_PRESET_ID {
        return Err(vec![issue(
            None,
            "preset",
            "unknown_preset",
            format!("Unknown Team Profile preset '{}'.", meta.preset),
        )]);
    }
    let preset_slots = load_preset(preset_yaml)?;
    let mut overlay_by_id = BTreeMap::new();
    for overlay in overlays {
        if !SLOT_IDS.contains(&overlay.slot_id.as_str()) {
            return Err(vec![issue(
                Some(&overlay.slot_id),
                "slot-id",
                "unknown_slot",
                "Opted-in agent-slots may only override worker-1 through worker-6.",
            )]);
        }
        if overlay_by_id
            .insert(overlay.slot_id.clone(), overlay)
            .is_some()
        {
            return Err(vec![issue(
                None,
                "slot-id",
                "duplicate_slot",
                "agent-slots slot-id values must be unique.",
            )]);
        }
    }
    let mut resolved = Vec::new();
    let mut issues = Vec::new();
    for preset in &preset_slots {
        let overlay = overlay_by_id.remove(&preset.slot_id);
        match resolve_slot(preset, overlay.as_ref(), catalog) {
            Ok(slot) => resolved.push(slot),
            Err(mut slot_issues) => issues.append(&mut slot_issues),
        }
    }
    if !overlay_by_id.is_empty() {
        for slot_id in overlay_by_id.keys() {
            issues.push(issue(
                Some(slot_id),
                "slot-id",
                "unknown_slot",
                "Opted-in agent-slots may not introduce a slot that is not in the preset.",
            ));
        }
    }
    if !issues.is_empty() {
        return Err(issues);
    }
    Ok(ResolvedTeam {
        opted_in: true,
        team_profile: Some(meta),
        slots: resolved,
    })
}

fn legacy_slot(overlay: OverlaySlot) -> ResolvedSlot {
    ResolvedSlot {
        slot_id: overlay.slot_id,
        provider: overlay
            .fields
            .get("provider")
            .and_then(yaml_text)
            .or_else(|| overlay.fields.get("agent").and_then(yaml_text))
            .unwrap_or_default(),
        model: overlay
            .fields
            .get("model")
            .and_then(yaml_text)
            .unwrap_or_default(),
        launch_model: String::new(),
        reasoning_effort: overlay
            .fields
            .get("reasoning-effort")
            .and_then(yaml_text)
            .unwrap_or_default(),
        role_profile: overlay
            .fields
            .get("role-profile")
            .and_then(yaml_text)
            .unwrap_or_default(),
        lifecycle: overlay
            .fields
            .get("lifecycle")
            .and_then(yaml_text)
            .unwrap_or_default(),
        task_classes: overlay
            .fields
            .get("task-classes")
            .and_then(|value| yaml_string_list(value).ok())
            .flatten()
            .unwrap_or_default(),
        delegation: overlay
            .fields
            .get("delegation")
            .and_then(|value| yaml_string_list(value).ok())
            .flatten()
            .unwrap_or_default(),
        overrides: Vec::new(),
        worker_backend: overlay
            .extras
            .get(&Value::String("worker-backend".into()))
            .and_then(yaml_text)
            .or_else(|| {
                overlay
                    .extras
                    .get(&Value::String("worker_backend".into()))
                    .and_then(yaml_text)
            }),
    }
}

fn resolve_slot(
    preset: &SlotRecord,
    overlay: Option<&OverlaySlot>,
    catalog: &Catalog,
) -> Result<ResolvedSlot, Vec<ValidationIssue>> {
    let mut overrides = Vec::new();
    let mut record = preset.clone();
    let mut worker_backend = preset.worker_backend.clone();
    if let Some(overlay) = overlay {
        for field in LANE_B_SLOT_FIELDS {
            if overlay.fields.contains_key(field)
                || (field == "provider" && overlay.fields.contains_key("agent"))
            {
                overrides.push(field.to_string());
            }
        }
        if let Some(provider) = overlay_provider(overlay)? {
            record.provider = provider;
        }
        if let Some(model) = overlay.fields.get("model").and_then(yaml_text) {
            record.model = model;
        }
        if let Some(effort) = overlay.fields.get("reasoning-effort").and_then(yaml_text) {
            record.reasoning_effort = effort;
        }
        if let Some(role) = overlay.fields.get("role-profile").and_then(yaml_text) {
            record.role_profile = role;
        }
        if let Some(lifecycle) = overlay.fields.get("lifecycle").and_then(yaml_text) {
            record.lifecycle = lifecycle;
        }
        if let Some(classes) = overlay.fields.get("task-classes") {
            record.task_classes = yaml_string_list(classes)?.ok_or_else(|| {
                vec![issue(
                    Some(&record.slot_id),
                    "task-classes",
                    "invalid_task_classes",
                    "task-classes must be a non-empty list of registered IDs.",
                )]
            })?;
        }
        if let Some(delegation) = overlay.fields.get("delegation") {
            record.delegation = yaml_string_list(delegation)?.ok_or_else(|| {
                vec![issue(
                    Some(&record.slot_id),
                    "delegation",
                    "invalid_delegation",
                    "delegation must be a non-empty list of worker ownership classes.",
                )]
            })?;
        }
        worker_backend = overlay
            .extras
            .get(&Value::String("worker-backend".into()))
            .and_then(yaml_text)
            .or_else(|| {
                overlay
                    .extras
                    .get(&Value::String("worker_backend".into()))
                    .and_then(yaml_text)
            })
            .or(worker_backend);
    }
    validate_resolved_slot(&record, worker_backend.as_deref(), catalog)?;
    let model = catalog.models.get(&record.model).ok_or_else(|| {
        vec![issue(
            Some(&record.slot_id),
            "model",
            "unknown_model",
            format!("Unknown model capability ID '{}'.", record.model),
        )]
    })?;
    if worker_backend.is_none() {
        worker_backend = inferred_worker_backend(model, catalog);
    }
    Ok(ResolvedSlot {
        slot_id: record.slot_id,
        provider: record.provider,
        model: record.model,
        launch_model: model.launch_model.clone(),
        reasoning_effort: record.reasoning_effort,
        role_profile: record.role_profile,
        lifecycle: record.lifecycle,
        task_classes: record.task_classes,
        delegation: record.delegation,
        overrides,
        worker_backend,
    })
}

fn overlay_provider(overlay: &OverlaySlot) -> Result<Option<String>, Vec<ValidationIssue>> {
    let provider = overlay.fields.get("provider").and_then(yaml_text);
    let agent = overlay.fields.get("agent").and_then(yaml_text);
    match (provider, agent) {
        (Some(provider), Some(agent)) if provider != agent => Err(vec![issue(
            Some(&overlay.slot_id),
            "provider",
            "ambiguous_provider_alias",
            "provider and agent disagree; keep provider as the canonical Team Profile field.",
        )]),
        (Some(provider), _) => Ok(Some(provider)),
        (None, Some(agent)) => Ok(Some(agent)),
        (None, None) => Ok(None),
    }
}

fn inferred_worker_backend(model: &ModelEntry, catalog: &Catalog) -> Option<String> {
    let allowed = catalog.backends.get(&model.required_backend)?;
    let concrete: Vec<String> = allowed
        .iter()
        .filter(|backend| !backend.is_empty() && backend.as_str() != "*")
        .cloned()
        .collect();
    if concrete.len() == 1 {
        Some(concrete[0].clone())
    } else {
        None
    }
}

fn validate_resolved_slot(
    record: &SlotRecord,
    worker_backend: Option<&str>,
    catalog: &Catalog,
) -> Result<(), Vec<ValidationIssue>> {
    let slot_id = record.slot_id.as_str();
    let mut issues = Vec::new();
    if record.provider == "provider-default" || record.model == "provider-default" {
        issues.push(issue(
            Some(slot_id),
            if record.provider == "provider-default" {
                "provider"
            } else {
                "model"
            },
            "provider_default_forbidden",
            "Resolved Team Profile slots must use a concrete provider and model capability ID.",
        ));
    }
    if !catalog.providers.contains(&record.provider) || record.provider == "provider-default" {
        issues.push(issue(
            Some(slot_id),
            "provider",
            "unknown_provider",
            format!("Unknown provider '{}'.", record.provider),
        ));
    }
    match catalog.models.get(&record.model) {
        None => issues.push(issue(
            Some(slot_id),
            "model",
            "unknown_model",
            format!(
                "Unknown model capability ID '{}'. Use a catalog ID, not a raw CLI model argument.",
                record.model
            ),
        )),
        Some(model) => {
            if model.provider_id != record.provider {
                issues.push(issue(
                    Some(slot_id),
                    "model",
                    "model_provider_mismatch",
                    format!(
                        "Model '{}' belongs to provider '{}'.",
                        record.model, model.provider_id
                    ),
                ));
            }
            if !model
                .supported_effort_ids
                .iter()
                .any(|effort| effort == &record.reasoning_effort)
            {
                issues.push(issue(
                    Some(slot_id),
                    "reasoning-effort",
                    "unsupported_effort",
                    format!(
                        "Unsupported reasoning-effort '{}'. Supported values: {}.",
                        record.reasoning_effort,
                        model.supported_effort_ids.join(", ")
                    ),
                ));
            }
            if let Some(backend) = worker_backend {
                let allowed = catalog
                    .backends
                    .get(&model.required_backend)
                    .cloned()
                    .unwrap_or_default();
                let allowed = if allowed.iter().any(|value| value == "*") {
                    vec![backend.to_string()]
                } else {
                    allowed
                };
                if !allowed.iter().any(|value| value == backend) {
                    issues.push(issue(
                        Some(slot_id),
                        "worker-backend",
                        "backend_capability_mismatch",
                        format!(
                            "worker-backend '{}' is not in assignableBackends for required backend '{}'.",
                            backend, model.required_backend
                        ),
                    ));
                }
            }
        }
    }
    if !ROLE_PROFILES.contains(&record.role_profile.as_str()) {
        issues.push(issue(
            Some(slot_id),
            "role-profile",
            "unknown_role_profile",
            format!("Unknown role-profile '{}'.", record.role_profile),
        ));
    }
    if !LIFECYCLES.contains(&record.lifecycle.as_str()) {
        issues.push(issue(
            Some(slot_id),
            "lifecycle",
            "unknown_lifecycle",
            format!("Unknown lifecycle '{}'.", record.lifecycle),
        ));
    }
    if record.task_classes.is_empty() {
        issues.push(issue(
            Some(slot_id),
            "task-classes",
            "empty_task_classes",
            "task-classes must be a non-empty duplicate-free list.",
        ));
    }
    let mut seen = BTreeSet::new();
    for class in &record.task_classes {
        if !TASK_CLASSES.contains(&class.as_str()) {
            issues.push(issue(
                Some(slot_id),
                "task-classes",
                "unknown_task_class",
                format!("Unknown task-class '{class}'."),
            ));
        }
        if !seen.insert(class) {
            issues.push(issue(
                Some(slot_id),
                "task-classes",
                "duplicate_task_class",
                "task-classes must not contain duplicates.",
            ));
        }
    }
    if record.delegation.is_empty() {
        issues.push(issue(
            Some(slot_id),
            "delegation",
            "empty_delegation",
            "delegation must list the worker-owned classes this slot may accept.",
        ));
    }
    let mut seen_delegation = BTreeSet::new();
    for item in &record.delegation {
        if !WORKER_DELEGATION.contains(&item.as_str()) {
            issues.push(issue(
                Some(slot_id),
                "delegation",
                "unknown_delegation",
                format!("Unknown worker delegation class '{item}'."),
            ));
        }
        if !seen_delegation.insert(item) {
            issues.push(issue(
                Some(slot_id),
                "delegation",
                "duplicate_delegation",
                "delegation must not contain duplicates.",
            ));
        }
    }
    if issues.is_empty() {
        Ok(())
    } else {
        Err(issues)
    }
}

fn parse_team_profile_meta(value: &Value) -> Result<TeamProfileMeta, Vec<ValidationIssue>> {
    let mapping = value.as_mapping().ok_or_else(|| {
        vec![issue(
            None,
            "team-profile",
            "invalid_team_profile",
            "team-profile must be a mapping.",
        )]
    })?;
    let schema_version = mapping_lookup(mapping, "schema-version")?
        .and_then(yaml_i64)
        .ok_or_else(|| {
            vec![issue(
                None,
                "schema-version",
                "missing_schema_version",
                "team-profile.schema-version is required and must be 1.",
            )]
        })?;
    if schema_version != 1 {
        return Err(vec![issue(
            None,
            "schema-version",
            "unsupported_schema_version",
            "Unknown team-profile schema-version.",
        )]);
    }
    let preset = mapping_lookup(mapping, "preset")?
        .and_then(yaml_text)
        .ok_or_else(|| {
            vec![issue(
                None,
                "preset",
                "missing_preset",
                "team-profile.preset is required.",
            )]
        })?;
    let preset_revision = mapping_lookup(mapping, "preset-revision")?
        .and_then(yaml_i64)
        .ok_or_else(|| {
            vec![issue(
                None,
                "preset-revision",
                "missing_preset_revision",
                "team-profile.preset-revision is required.",
            )]
        })?;
    let update_policy = mapping_lookup(mapping, "update-policy")?
        .and_then(yaml_text)
        .ok_or_else(|| {
            vec![issue(
                None,
                "update-policy",
                "missing_update_policy",
                "team-profile.update-policy is required.",
            )]
        })?;
    if update_policy != "retain-overrides" {
        return Err(vec![issue(
            None,
            "update-policy",
            "unsupported_update_policy",
            "v1 update-policy must be retain-overrides.",
        )]);
    }
    Ok(TeamProfileMeta {
        schema_version,
        preset,
        preset_revision,
        update_policy,
    })
}

fn parse_overlay_slots(root: &Mapping) -> Result<Vec<OverlaySlot>, Vec<ValidationIssue>> {
    let Some(value) = mapping_lookup(root, "agent-slots")? else {
        return Ok(Vec::new());
    };
    let sequence = value.as_sequence().ok_or_else(|| {
        vec![issue(
            None,
            "agent-slots",
            "invalid_agent_slots",
            "agent-slots must be a sequence of mappings.",
        )]
    })?;
    let mut slots = Vec::new();
    let mut seen = BTreeSet::new();
    for item in sequence {
        let mapping = item.as_mapping().ok_or_else(|| {
            vec![issue(
                None,
                "agent-slots",
                "invalid_slot_entry",
                "Every agent-slots entry must be a mapping.",
            )]
        })?;
        let slot_id = mapping_lookup(mapping, "slot-id")?
            .and_then(yaml_text)
            .ok_or_else(|| {
                vec![issue(
                    None,
                    "slot-id",
                    "missing_slot_id",
                    "Every agent-slots entry must include slot-id.",
                )]
            })?;
        if !seen.insert(slot_id.to_ascii_lowercase()) {
            return Err(vec![issue(
                Some(&slot_id),
                "slot-id",
                "duplicate_slot",
                "agent-slots slot-id values must be unique.",
            )]);
        }
        let mut fields = BTreeMap::new();
        let mut extras = Mapping::new();
        for (key, value) in mapping {
            let Some(name) = key.as_str() else {
                continue;
            };
            let canonical = canonical_slot_field(name);
            if canonical == "slot-id"
                || LANE_B_SLOT_FIELDS.contains(&canonical.as_str())
                || canonical == "agent"
            {
                if fields.insert(canonical, value.clone()).is_some() {
                    return Err(vec![issue(
                        Some(&slot_id),
                        name,
                        "ambiguous_alias",
                        format!("Conflicting aliases for '{name}'."),
                    )]);
                }
            } else {
                extras.insert(key.clone(), value.clone());
            }
        }
        slots.push(OverlaySlot {
            slot_id,
            fields,
            extras,
        });
    }
    Ok(slots)
}

fn canonical_slot_field(name: &str) -> String {
    match name.replace('_', "-").as_str() {
        "backend" => "worker-backend".to_string(),
        other => other.to_string(),
    }
}

fn load_preset(yaml: &str) -> Result<Vec<SlotRecord>, Vec<ValidationIssue>> {
    let root = parse_workspace_yaml(yaml).map_err(|_| {
        vec![issue(
            None,
            "preset",
            "invalid_preset",
            "Package Team Profile preset is not valid YAML.",
        )]
    })?;
    let mapping = root.as_mapping().ok_or_else(|| {
        vec![issue(
            None,
            "preset",
            "invalid_preset",
            "Package Team Profile preset must be a mapping.",
        )]
    })?;
    let preset_id = mapping_lookup(mapping, "preset-id")?
        .and_then(yaml_text)
        .unwrap_or_default();
    if preset_id != OFFICIAL_PRESET_ID {
        return Err(vec![issue(
            None,
            "preset",
            "invalid_preset",
            "Package preset-id must be official-balanced-v1.",
        )]);
    }
    let slots_value = mapping_lookup(mapping, "slots")?.ok_or_else(|| {
        vec![issue(
            None,
            "preset",
            "missing_preset_slots",
            "Package preset must declare six slots.",
        )]
    })?;
    let sequence = slots_value.as_sequence().ok_or_else(|| {
        vec![issue(
            None,
            "preset",
            "invalid_preset_slots",
            "Package preset slots must be a sequence.",
        )]
    })?;
    let mut slots = Vec::new();
    for item in sequence {
        let mapping = item.as_mapping().ok_or_else(|| {
            vec![issue(
                None,
                "preset",
                "invalid_preset_slot",
                "Each preset slot must be a mapping.",
            )]
        })?;
        slots.push(preset_slot_from_mapping(mapping)?);
    }
    if slots.len() != 6 {
        return Err(vec![issue(
            None,
            "preset",
            "missing_preset_slot",
            "Package preset must contain exactly six unique worker slots.",
        )]);
    }
    let ids: Vec<String> = slots.iter().map(|slot| slot.slot_id.clone()).collect();
    if ids
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
        != SLOT_IDS.iter().map(|value| value.to_string()).collect::<Vec<_>>()
        || ids != SLOT_IDS.iter().map(|value| value.to_string()).collect::<Vec<_>>()
    {
        return Err(vec![issue(
            None,
            "preset",
            "missing_preset_slot",
            "Package preset must declare worker-1 through worker-6 exactly once.",
        )]);
    }
    let digest = mapping_lookup(mapping, "digest-sha256")?
        .and_then(yaml_text)
        .unwrap_or_default();
    let expected = slot_digest(&slots);
    if digest != expected {
        return Err(vec![issue(
            None,
            "digest-sha256",
            "preset_digest_mismatch",
            "Package preset digest does not match the six canonical slot records.",
        )]);
    }
    Ok(slots)
}

fn preset_slot_from_mapping(mapping: &Mapping) -> Result<SlotRecord, Vec<ValidationIssue>> {
    Ok(SlotRecord {
        slot_id: required_text(mapping, "slot-id")?,
        provider: required_text(mapping, "provider")?,
        model: required_text(mapping, "model")?,
        reasoning_effort: required_text(mapping, "reasoning-effort")?,
        role_profile: required_text(mapping, "role-profile")?,
        lifecycle: required_text(mapping, "lifecycle")?,
        task_classes: required_list(mapping, "task-classes")?,
        delegation: required_list(mapping, "delegation")?,
        worker_backend: mapping_lookup(mapping, "worker-backend")?.and_then(yaml_text),
    })
}

fn required_text(mapping: &Mapping, field: &str) -> Result<String, Vec<ValidationIssue>> {
    mapping_lookup(mapping, field)?
        .and_then(yaml_text)
        .ok_or_else(|| {
            vec![issue(
                None,
                field,
                "invalid_preset_slot",
                format!("Preset slot is missing {field}."),
            )]
        })
}

fn required_list(mapping: &Mapping, field: &str) -> Result<Vec<String>, Vec<ValidationIssue>> {
    yaml_string_list(mapping_lookup(mapping, field)?.unwrap_or(&Value::Null))?.ok_or_else(|| {
        vec![issue(
            None,
            field,
            "invalid_preset_slot",
            format!("Preset slot is missing {field}."),
        )]
    })
}

fn slot_digest(slots: &[SlotRecord]) -> String {
    let payload: Vec<BTreeMap<String, JsonValue>> = slots
        .iter()
        .map(|slot| {
            let mut map = BTreeMap::new();
            map.insert("delegation".into(), json!(slot.delegation));
            map.insert("lifecycle".into(), json!(slot.lifecycle));
            map.insert("model".into(), json!(slot.model));
            map.insert("provider".into(), json!(slot.provider));
            map.insert("reasoning-effort".into(), json!(slot.reasoning_effort));
            map.insert("role-profile".into(), json!(slot.role_profile));
            map.insert("slot-id".into(), json!(slot.slot_id));
            map.insert("task-classes".into(), json!(slot.task_classes));
            map
        })
        .collect();
    format!("{:x}", Sha256::digest(serde_json::to_vec(&payload).unwrap()))
}

fn mapping_lookup<'a>(
    mapping: &'a Mapping,
    kebab: &str,
) -> Result<Option<&'a Value>, Vec<ValidationIssue>> {
    let snake = kebab.replace('-', "_");
    let kebab_value = mapping.get(&Value::String(kebab.to_string()));
    let snake_value = if snake != kebab {
        mapping.get(&Value::String(snake))
    } else {
        None
    };
    if kebab_value.is_some() && snake_value.is_some() {
        return Err(vec![issue(
            None,
            kebab,
            "ambiguous_alias",
            format!("Both '{kebab}' and its snake_case alias are present."),
        )]);
    }
    Ok(kebab_value.or(snake_value))
}

fn yaml_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let text = text.trim();
            (!text.is_empty()).then(|| text.to_string())
        }
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

fn yaml_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_i64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn yaml_string_list(value: &Value) -> Result<Option<Vec<String>>, Vec<ValidationIssue>> {
    match value {
        Value::Null => Ok(None),
        Value::Sequence(items) => {
            let mut values = Vec::new();
            for item in items {
                let Some(text) = yaml_text(item) else {
                    return Err(vec![issue(
                        None,
                        "task-classes",
                        "invalid_list_item",
                        "List values must be scalars.",
                    )]);
                };
                values.push(text);
            }
            Ok(Some(values))
        }
        _ => Err(vec![issue(
            None,
            "task-classes",
            "invalid_list",
            "Expected a YAML sequence.",
        )]),
    }
}

fn classify_project(
    project_dir: &Path,
    task_class: Option<&str>,
    delegation: Option<&str>,
    requested_slot: Option<&str>,
    _text: &str,
) -> io::Result<JsonValue> {
    let team = match resolve_project(project_dir) {
        Ok(team) => team,
        Err(issues) => {
            return Ok(json!({
                "schema_version": 1,
                "action": "dispatch-classify",
                "delegation": "unclassifiable",
                "status": "refused",
                "reason_code": "invalid_team_profile",
                "issues": issues
            }));
        }
    };
    if !team.opted_in {
        return Ok(json!({
            "schema_version": 1,
            "action": "dispatch-classify",
            "delegation": "legacy",
            "status": "dispatchable",
            "reason_code": "legacy_no_team_profile"
        }));
    }
    classify_team(&team, task_class, delegation, requested_slot)
}

fn classify_team(
    team: &ResolvedTeam,
    task_class: Option<&str>,
    delegation: Option<&str>,
    requested_slot: Option<&str>,
) -> io::Result<JsonValue> {
    let Some(delegation) = delegation.filter(|value| !value.trim().is_empty()) else {
        return Ok(classify_payload(
            "unclassifiable",
            None,
            task_class,
            None,
            "missing_delegation",
            "refused",
        ));
    };
    let Some(task_class) = task_class.filter(|value| !value.trim().is_empty()) else {
        return Ok(classify_payload(
            "unclassifiable",
            Some(delegation),
            None,
            None,
            "missing_task_class",
            "refused",
        ));
    };
    if !TASK_CLASSES.contains(&task_class) {
        return Ok(classify_payload(
            "unclassifiable",
            Some(delegation),
            Some(task_class),
            None,
            "unknown_task_class",
            "refused",
        ));
    }
    if OPERATOR_DELEGATION.contains(&delegation) {
        return Ok(classify_payload(
            "operator",
            Some(delegation),
            Some(task_class),
            None,
            "operator_owned",
            "returned_to_operator",
        ));
    }
    if !WORKER_DELEGATION.contains(&delegation) {
        return Ok(classify_payload(
            "unclassifiable",
            Some(delegation),
            Some(task_class),
            None,
            "unknown_delegation",
            "refused",
        ));
    }
    let mut matches: Vec<&ResolvedSlot> = team
        .slots
        .iter()
        .filter(|slot| {
            slot.task_classes.iter().any(|class| class == task_class)
                && slot.delegation.iter().any(|item| item == delegation)
        })
        .collect();
    if let Some(requested) = requested_slot {
        matches.retain(|slot| slot.slot_id == requested);
    }
    if let Some(slot) = matches.first() {
        match crate::instruction_pack::compose_json(
            &slot.provider,
            &slot.model,
            &slot.role_profile,
            &slot.lifecycle,
            &slot.task_classes,
        ) {
            Ok(pack) => {
                let mut payload = classify_payload(
                    "worker",
                    Some(delegation),
                    Some(task_class),
                    Some(&slot.slot_id),
                    "slot_matched",
                    "dispatchable",
                );
                payload["instruction_pack"] = pack;
                payload["artifact"] = serde_json::json!({
                    "output": format!(".winsmux/runs/{}/result.md", slot.slot_id),
                    "completion_authority": "output-file-and-exit-code",
                    "pty_capture_is_auxiliary": true
                });
                return Ok(payload);
            }
            Err(issues) => {
                return Ok(serde_json::json!({
                    "schema_version": 1,
                    "action": "dispatch-classify",
                    "delegation": "unclassifiable",
                    "delegation_class": delegation,
                    "task_class": task_class,
                    "slot_id": slot.slot_id,
                    "reason_code": "missing_instruction_pack",
                    "status": "refused",
                    "issues": issues
                }));
            }
        }
    }
    Ok(classify_payload(
        "operator",
        Some(delegation),
        Some(task_class),
        None,
        "no_matching_slot",
        "returned_to_operator",
    ))
}

fn classify_payload(
    owner: &str,
    delegation_class: Option<&str>,
    task_class: Option<&str>,
    slot_id: Option<&str>,
    reason_code: &str,
    status: &str,
) -> JsonValue {
    json!({
        "schema_version": 1,
        "action": "dispatch-classify",
        "delegation": owner,
        "delegation_class": delegation_class,
        "task_class": task_class,
        "slot_id": slot_id,
        "reason_code": reason_code,
        "status": status
    })
}

fn project_yaml_path(project_dir: &Path) -> PathBuf {
    if project_dir.ends_with(".winsmux.yaml") {
        project_dir.to_path_buf()
    } else {
        project_dir.join(".winsmux.yaml")
    }
}

fn save_slot_field(
    project_dir: &Path,
    slot_id: &str,
    field: &str,
    value: &str,
) -> io::Result<()> {
    let field = field.replace('_', "-");
    if !LANE_B_SLOT_FIELDS.contains(&field.as_str()) {
        return Err(invalid_input(format!(
            "save --field must be one of {}.",
            LANE_B_SLOT_FIELDS.join(", ")
        )));
    }
    let path = project_yaml_path(project_dir);
    let original = fs::read_to_string(&path)?;
    let mut overlays = overlay_json_from_yaml(&original)?;
    let entry = overlays.iter_mut().find(|entry| {
        entry
            .get("slot-id")
            .or_else(|| entry.get("slot_id"))
            .and_then(JsonValue::as_str)
            == Some(slot_id)
    });
    let json_value = field_to_json(&field, value)?;
    if let Some(entry) = entry {
        entry.insert(field.clone(), json_value);
        if field == "provider" {
            entry.remove("agent");
        }
    } else {
        let mut map = Map::new();
        map.insert("slot-id".into(), json!(slot_id));
        map.insert(field, json_value);
        overlays.push(map);
    }
    let rendered = project_settings_render::render_owned_lane_b(
        &original,
        None,
        Some(JsonValue::Array(
            overlays
                .into_iter()
                .map(|entry| JsonValue::Object(lane_b_desired_slot(&entry)))
                .collect(),
        )),
    )?;
    replace_validated(&path, &original, &rendered)
}

fn reset_slot_field(project_dir: &Path, slot_id: &str, field: &str) -> io::Result<()> {
    let field = field.replace('_', "-");
    if !LANE_B_SLOT_FIELDS.contains(&field.as_str()) {
        return Err(invalid_input(format!(
            "reset-field --field must be one of {}.",
            LANE_B_SLOT_FIELDS.join(", ")
        )));
    }
    let path = project_yaml_path(project_dir);
    let original = fs::read_to_string(&path)?;
    let mut overlays = overlay_json_from_yaml(&original)?;
    overlays.retain_mut(|entry| {
        let matches = entry
            .get("slot-id")
            .or_else(|| entry.get("slot_id"))
            .and_then(JsonValue::as_str)
            == Some(slot_id);
        if matches {
            entry.remove(&field);
            entry.remove(&field.replace('-', "_"));
            if field == "provider" {
                entry.remove("agent");
            }
        }
        let lane_b_remaining = LANE_B_SLOT_FIELDS.iter().any(|name| {
            entry.contains_key(*name) || entry.contains_key(&(*name).replace('-', "_"))
        }) || entry.contains_key("agent");
        let has_extras = entry.keys().any(|key| {
            let canonical = canonical_slot_field(key);
            canonical != "slot-id"
                && canonical != "agent"
                && !LANE_B_SLOT_FIELDS.contains(&canonical.as_str())
        });
        !(matches && !lane_b_remaining && !has_extras)
    });
    let rendered = project_settings_render::render_owned_lane_b(
        &original,
        None,
        Some(JsonValue::Array(
            overlays
                .into_iter()
                .map(|entry| JsonValue::Object(lane_b_desired_slot(&entry)))
                .collect(),
        )),
    )?;
    replace_validated(&path, &original, &rendered)
}

fn lane_b_desired_slot(entry: &Map<String, JsonValue>) -> Map<String, JsonValue> {
    let mut out = Map::new();
    for key in [
        "slot-id",
        "slot_id",
        "agent",
        "provider",
        "model",
        "reasoning-effort",
        "reasoning_effort",
        "role-profile",
        "role_profile",
        "lifecycle",
        "task-classes",
        "task_classes",
        "delegation",
    ] {
        if let Some(value) = entry.get(key) {
            out.insert(key.to_string(), value.clone());
        }
    }
    out
}

fn field_to_json(field: &str, value: &str) -> io::Result<JsonValue> {
    if field == "task-classes" || field == "delegation" {
        let items: Vec<String> = value
            .split(',')
            .map(str::trim)
            .filter(|item| !item.is_empty())
            .map(str::to_string)
            .collect();
        return Ok(json!(items));
    }
    Ok(json!(value))
}

fn overlay_json_from_yaml(yaml: &str) -> io::Result<Vec<Map<String, JsonValue>>> {
    let root = parse_workspace_yaml(yaml)?;
    let mapping = root
        .as_mapping()
        .ok_or_else(|| invalid_data(".winsmux.yaml must be a mapping."))?;
    let Some(value) = mapping
        .get(&Value::String("agent-slots".into()))
        .or_else(|| mapping.get(&Value::String("agent_slots".into())))
    else {
        return Ok(Vec::new());
    };
    let sequence = value
        .as_sequence()
        .ok_or_else(|| invalid_data("agent-slots must be a sequence."))?;
    let mut overlays = Vec::new();
    for item in sequence {
        let slot_mapping = item
            .as_mapping()
            .ok_or_else(|| invalid_data("agent-slots entries must be mappings."))?;
        let mut map = Map::new();
        for (key, value) in slot_mapping {
            let Some(name) = key.as_str() else {
                continue;
            };
            map.insert(name.to_string(), yaml_to_json(value));
        }
        overlays.push(map);
    }
    Ok(overlays)
}

fn yaml_to_json(value: &Value) -> JsonValue {
    match value {
        Value::Null => JsonValue::Null,
        Value::Bool(flag) => json!(flag),
        Value::Number(number) => {
            if let Some(value) = number.as_i64() {
                json!(value)
            } else if let Some(value) = number.as_f64() {
                json!(value)
            } else {
                JsonValue::Null
            }
        }
        Value::String(text) => json!(text),
        Value::Sequence(items) => JsonValue::Array(items.iter().map(yaml_to_json).collect()),
        Value::Mapping(mapping) => {
            let mut map = Map::new();
            for (key, value) in mapping {
                if let Some(name) = key.as_str() {
                    map.insert(name.to_string(), yaml_to_json(value));
                }
            }
            JsonValue::Object(map)
        }
        Value::Tagged(tagged) => yaml_to_json(&tagged.value),
    }
}

fn replace_validated(path: &Path, original: &str, rendered: &str) -> io::Result<()> {
    if let Err(issues) = resolve_yaml(rendered, OFFICIAL_PRESET_YAML, &catalog()) {
        return Err(invalid_data(serde_json::to_string(&issues).unwrap_or_else(
            |_| "team-profile validation failed.".to_string(),
        )));
    }
    replace_file(path, rendered).map_err(|error| {
        let _ = fs::write(path, original);
        error
    })
}

fn replace_file(path: &Path, contents: &str) -> io::Result<()> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| invalid_input("team-profile cannot write the target path."))?;
    let tmp = path.with_file_name(format!(
        "{}.tmp-team-profile-{}",
        file_name,
        std::process::id()
    ));
    fs::write(&tmp, contents)?;
    let result = replace_existing_file(&tmp, path);
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

#[cfg(windows)]
fn replace_existing_file(tmp_path: &Path, path: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    fn wide(value: &Path) -> Vec<u16> {
        value
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    let tmp = wide(tmp_path);
    let target = wide(path);
    let moved = unsafe {
        MoveFileExW(
            tmp.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_existing_file(tmp_path: &Path, path: &Path) -> io::Result<()> {
    fs::rename(tmp_path, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn opted_in_empty() -> &'static str {
        "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
    }

    fn catalog_fixture() -> Catalog {
        catalog()
    }

    #[test]
    fn every_selectable_catalog_model_has_an_instruction_pack() {
        let catalog = catalog_fixture();
        for (id, model) in &catalog.models {
            if id == "provider-default" {
                continue;
            }
            crate::instruction_pack::compose_pack(
                &model.provider_id,
                id,
                "builder",
                "task",
                &["implementation".to_string()],
            )
            .unwrap_or_else(|issues| panic!("{id}: {issues:?}"));
        }
    }

    #[test]
    fn catalog_contains_official_balanced_models() {
        let catalog = catalog_fixture();
        for id in [
            "codex-gpt-5-6-sol",
            "codex-gpt-5-6-terra",
            "codex-gpt-5-6-luna",
            "openrouter-glm-5-2",
        ] {
            assert!(catalog.models.contains_key(id), "missing {id}");
        }
        assert!(catalog.providers.contains("codex"));
        assert_eq!(
            catalog.backends.get("agent-cli").cloned().unwrap_or_default(),
            vec![
                "".to_string(),
                "local".to_string(),
                "codex".to_string(),
                "claude".to_string()
            ]
        );
    }

    #[test]
    fn official_preset_digest_matches_canonical_slots() {
        let slots = load_preset(OFFICIAL_PRESET_YAML).expect("official preset");
        assert_eq!(slot_digest(&slots), "7d671140ed9020dae23e27458242f5deb1146bead5d4886d6c2f786059a9b8f5");
        assert_eq!(slots.len(), 6);
        assert_eq!(slots[0].role_profile, "architect");
        assert_eq!(slots[5].model, "codex-gpt-5-6-luna");
    }

    #[test]
    fn empty_overrides_resolve_six_preset_slots() {
        let team = resolve_yaml(opted_in_empty(), OFFICIAL_PRESET_YAML, &catalog_fixture())
            .expect("empty overrides");
        assert!(team.opted_in);
        assert_eq!(team.slots.len(), 6);
        assert!(team.slots.iter().all(|slot| slot.overrides.is_empty()));
        assert_eq!(team.slots[1].launch_model, "gpt-5.6-terra");
    }

    #[test]
    fn sparse_overrides_overlay_by_slot_id() {
        let yaml = r#"
config-version: 1
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-6
    provider: openrouter
    model: openrouter-glm-5-2
    worker-backend: api_llm
    reasoning-effort: provider-default
    role-profile: maintainer
    lifecycle: task
    task-classes: [documentation, repository-operations]
"#;
        let team = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).expect("sparse");
        assert_eq!(team.slots.len(), 6);
        let worker6 = &team.slots[5];
        assert_eq!(worker6.provider, "openrouter");
        assert_eq!(worker6.model, "openrouter-glm-5-2");
        assert_eq!(worker6.launch_model, "z-ai/glm-5.2");
        assert_eq!(worker6.worker_backend.as_deref(), Some("api_llm"));
        assert!(worker6.overrides.contains(&"provider".to_string()));
        assert_eq!(team.slots[0].provider, "codex");
        assert!(team.slots[0].worker_backend.is_none());
    }

    #[test]
    fn omitted_worker_backend_is_derived_from_a_unique_assignable_backend() {
        let yaml = r#"
config-version: 1
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-6
    provider: openrouter
    model: openrouter-glm-5-2
    reasoning-effort: provider-default
    role-profile: maintainer
    lifecycle: task
    task-classes: [documentation, repository-operations]
"#;
        let team = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).expect("derived");
        assert_eq!(team.slots[5].worker_backend.as_deref(), Some("api_llm"));
        assert!(team.slots[0].worker_backend.is_none());
    }

    #[test]
    fn agent_alias_maps_to_provider() {
        let yaml = r#"
config-version: 1
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-2
    agent: codex
"#;
        let team = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).expect("alias");
        assert_eq!(team.slots[1].provider, "codex");
        assert!(team.slots[1].overrides.contains(&"provider".to_string()));
    }

    #[test]
    fn seventh_slot_is_rejected() {
        let yaml = format!(
            "{}  - slot-id: worker-7\n    provider: codex\n",
            opted_in_empty().replace("agent-slots: []\n", "agent-slots:\n")
        );
        let error = resolve_yaml(&yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap_err();
        assert!(error.iter().any(|issue| issue.code == "unknown_slot"));
    }

    #[test]
    fn duplicate_mapping_key_is_rejected() {
        let yaml = "team-profile: {}\nteam-profile: {}\n";
        let error = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap_err();
        assert!(error.iter().any(|issue| issue.code == "duplicate_mapping_key"));
    }

    #[test]
    fn duplicate_slot_ids_are_rejected() {
        let yaml = r#"
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-1
  - slot-id: worker-1
"#;
        let error = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap_err();
        assert!(error.iter().any(|issue| issue.code == "duplicate_slot"));
    }

    #[test]
    fn missing_preset_slot_is_rejected() {
        let normalized = OFFICIAL_PRESET_YAML.replace("\r\n", "\n");
        let needle = "  - slot-id: worker-6\n";
        assert!(
            normalized.contains(needle),
            "official preset must contain worker-6 after CRLF normalization"
        );
        let tampered = normalized.replace(needle, "  - slot-id: worker-x\n");
        assert_ne!(tampered, normalized, "tamper must change the preset bytes");
        let error = resolve_yaml(opted_in_empty(), &tampered, &catalog_fixture()).unwrap_err();
        assert!(error
            .iter()
            .any(|issue| issue.code == "missing_preset_slot" || issue.code == "preset_digest_mismatch"));
    }

    #[test]
    fn missing_preset_slot_is_rejected_when_include_str_embeds_crlf() {
        let crlf = OFFICIAL_PRESET_YAML.replace("\r\n", "\n").replace('\n', "\r\n");
        let normalized = crlf.replace("\r\n", "\n");
        let tampered = normalized.replace("  - slot-id: worker-6\n", "  - slot-id: worker-x\n");
        let error = resolve_yaml(opted_in_empty(), &tampered, &catalog_fixture()).unwrap_err();
        assert!(error
            .iter()
            .any(|issue| issue.code == "missing_preset_slot" || issue.code == "preset_digest_mismatch"));
    }

    #[test]
    fn invalid_enum_and_catalog_mismatch_fail_closed() {
        let yaml = r#"
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-1
    model: openrouter-glm-5-2
    reasoning-effort: not-an-effort
    role-profile: wizard
"#;
        let error = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap_err();
        assert!(error.iter().any(|issue| issue.code == "model_provider_mismatch"));
        assert!(error.iter().any(|issue| issue.code == "unknown_role_profile"));
        assert!(error.iter().any(|issue| issue.code == "unsupported_effort"));
    }

    #[test]
    fn legacy_sparse_agent_slots_without_team_profile_stay_unchanged() {
        let yaml = "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n  - slot-id: extra-1\n    model: leftover\n";
        let team = resolve_yaml(yaml, OFFICIAL_PRESET_YAML, &catalog_fixture()).expect("legacy");
        assert!(!team.opted_in);
        assert_eq!(team.slots.len(), 2);
        assert_eq!(team.slots[1].slot_id, "extra-1");
        assert_eq!(team.slots[1].model, "leftover");
    }

    #[test]
    fn save_lane_b_preserves_lane_a_and_unknown_keys() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".winsmux.yaml");
        let original = r#"config-version: 1
workspace-recipes:
  keep-me:
    schema-version: 1
workflows:
  keep: true
context-packs:
  keep: true
future-top-level:
  owner: future
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
  future-lane-b-field: preserve-me
agent-slots:
  - slot-id: worker-2
    agent: codex
    worktree-mode: managed
    pane_title: keep-title
"#;
        fs::write(&path, original).unwrap();
        save_slot_field(dir.path(), "worker-2", "reasoning-effort", "high").unwrap();
        let saved = fs::read_to_string(&path).unwrap();
        assert!(saved.contains("workspace-recipes:"));
        assert!(saved.contains("keep-me:"));
        assert!(saved.contains("workflows:"));
        assert!(saved.contains("context-packs:"));
        assert!(saved.contains("future-top-level:"));
        assert!(saved.contains("future-lane-b-field: preserve-me"));
        assert!(saved.contains("worktree-mode: managed"));
        assert!(saved.contains("pane_title: keep-title"));
        assert!(
            saved.contains("agent: codex")
                || saved.contains("agent: \"codex\"")
                || saved.contains("provider: codex")
                || saved.contains("provider: \"codex\""),
            "expected preserved provider alias, saved={saved}"
        );
        assert!(
            saved.contains("reasoning-effort: high")
                || saved.contains("reasoning-effort: \"high\"")
                || saved.contains("reasoning_effort: high")
        );
        let team = resolve_yaml(&saved, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap();
        assert_eq!(team.slots[1].reasoning_effort, "high");
        assert!(team.slots[1].overrides.contains(&"reasoning-effort".to_string()));
    }

    #[test]
    fn preset_revision_retains_overrides_until_explicit_reset() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".winsmux.yaml");
        fs::write(&path, opted_in_empty().replace(
            "agent-slots: []\n",
            "agent-slots:\n  - slot-id: worker-6\n    reasoning-effort: low\n",
        ))
        .unwrap();
        let before = fs::read_to_string(&path).unwrap();
        assert!(before.contains("reasoning-effort: low"));
        reset_slot_field(dir.path(), "worker-6", "reasoning-effort").unwrap();
        let after = fs::read_to_string(&path).unwrap();
        assert!(!after.contains("reasoning-effort: low"));
        let team = resolve_yaml(&after, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap();
        assert_eq!(team.slots[5].reasoning_effort, "medium");
        assert!(!team.slots[5].overrides.contains(&"reasoning-effort".to_string()));
    }

    #[test]
    fn failed_validation_leaves_original_file_intact() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".winsmux.yaml");
        fs::write(&path, opted_in_empty()).unwrap();
        let original = fs::read_to_string(&path).unwrap();
        let err = save_slot_field(dir.path(), "worker-1", "model", "not-a-catalog-id").unwrap_err();
        assert!(!err.to_string().is_empty());
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn failed_atomic_replace_leaves_destination_intact() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".winsmux.yaml");
        fs::create_dir(&path).unwrap();
        fs::write(path.join("marker"), b"keep").unwrap();
        assert!(replace_file(&path, "config-version: 1\n").is_err());
        assert_eq!(fs::read(path.join("marker")).unwrap(), b"keep");
    }

    #[test]
    fn classify_refuses_unclassifiable_and_returns_operator_owned() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
        let missing = classify_project(dir.path(), None, None, None, "implement anything").unwrap();
        assert_eq!(missing["delegation"], "unclassifiable");
        assert_eq!(missing["reason_code"], "missing_delegation");
        let operator = classify_project(
            dir.path(),
            Some("implementation"),
            Some("destructive-ops"),
            None,
            "reset production",
        )
        .unwrap();
        assert_eq!(operator["delegation"], "operator");
        assert_eq!(operator["reason_code"], "operator_owned");
        let worker = classify_project(
            dir.path(),
            Some("implementation"),
            Some("frozen-spec-implementation"),
            None,
            "implement the frozen spec",
        )
        .unwrap();
        assert_eq!(worker["status"], "dispatchable");
        assert_eq!(worker["slot_id"], "worker-2");
        assert_eq!(worker["instruction_pack"]["a1"]["worker"][0], "frozen-spec-implementation");
        assert!(worker["instruction_pack"]["template_ids"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == "base"));
    }

    #[test]
    fn save_provider_replaces_legacy_agent_alias() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".winsmux.yaml");
        fs::write(
            &path,
            opted_in_empty().replace(
                "agent-slots: []\n",
                "agent-slots:\n  - slot-id: worker-2\n    agent: codex\n",
            ),
        )
        .unwrap();
        save_slot_field(dir.path(), "worker-2", "provider", "codex").unwrap();
        let saved = fs::read_to_string(&path).unwrap();
        let has_provider = saved.contains("provider:");
        let has_agent = saved.contains("agent:");
        assert!(
            has_provider || has_agent,
            "provider save must persist the slot assignment, saved={saved}"
        );
        assert!(
            !(has_provider && has_agent),
            "provider save must not leave both provider and agent keys, saved={saved}"
        );
        let team = resolve_yaml(&saved, OFFICIAL_PRESET_YAML, &catalog_fixture()).unwrap();
        assert_eq!(team.slots[1].provider, "codex");
        assert!(team.slots[1].overrides.contains(&"provider".to_string()));
    }

    #[test]
    fn quoted_team_profile_key_is_detected_as_opt_in() {
        let yaml = "\"team-profile\":\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n";
        assert!(document_has_team_profile(yaml));
        let flow = "{ \"team-profile\": { schema-version: 1, preset: official-balanced-v1, preset-revision: 1, update-policy: retain-overrides }, agent-slots: [] }\n";
        assert!(document_has_team_profile(flow));
        assert!(document_has_team_profile("team_profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"));
        assert!(!document_has_team_profile("agent-slots:\n  - slot-id: worker-1\n"));
    }

    #[test]
    fn gate_dispatch_returns_classified_slot() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
        let task_class = "--task-class".to_string();
        let implementation = "implementation".to_string();
        let delegation = "--delegation".to_string();
        let frozen = "frozen-spec-implementation".to_string();
        let project = "--project-dir".to_string();
        let path = dir.path().to_string_lossy().into_owned();
        let text = "implement the frozen spec".to_string();
        let args = [
            &task_class,
            &implementation,
            &delegation,
            &frozen,
            &project,
            &path,
            &text,
        ];
        match gate_dispatch(&args).unwrap() {
            DispatchGate::Classified { slot_id } => assert_eq!(slot_id, "worker-2"),
            other => panic!("expected classified worker-2, got {other:?}"),
        }
    }

    #[test]
    fn with_classified_slot_appends_missing_slot_flag() {
        let command = "dispatch-task".to_string();
        let text = "implement the frozen spec".to_string();
        let forwarded = with_classified_slot(&[&command, &text], "worker-2");
        assert_eq!(
            forwarded,
            vec![
                "dispatch-task".to_string(),
                "implement the frozen spec".to_string(),
                "--slot-id".to_string(),
                "worker-2".to_string()
            ]
        );
    }

    #[test]
    fn with_classified_slot_keeps_existing_slot_flag() {
        let command = "dispatch-task".to_string();
        let flag = "--slot-id".to_string();
        let slot = "worker-3".to_string();
        let text = "implement the frozen spec".to_string();
        let forwarded = with_classified_slot(&[&command, &flag, &slot, &text], "worker-3");
        assert_eq!(
            forwarded,
            vec![
                "dispatch-task".to_string(),
                "--slot-id".to_string(),
                "worker-3".to_string(),
                "implement the frozen spec".to_string()
            ]
        );
    }

    #[test]
    fn with_classified_slot_inserts_flag_before_end_of_options() {
        let command = "dispatch-task".to_string();
        let separator = "--".to_string();
        let text = "implement the frozen spec".to_string();
        let forwarded = with_classified_slot(&[&command, &separator, &text], "worker-2");
        assert_eq!(
            forwarded,
            vec![
                "dispatch-task".to_string(),
                "--slot-id".to_string(),
                "worker-2".to_string(),
                "--".to_string(),
                "implement the frozen spec".to_string()
            ]
        );
    }
}
