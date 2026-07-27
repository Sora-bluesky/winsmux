use std::{
    collections::BTreeSet,
    env, fs,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::{Map as JsonMap, Value as JsonValue};
use sha2::{Digest, Sha256};

use crate::workspace_recipe::{parse_workspace_yaml, SlotCapabilities};

use super::{replace_file_with_temp, temp_write_path, with_file_lock, write_json};

const PRESET_CATALOG_YAML: &str = include_str!("../../presets/workspace-presets-v1.yaml");
const PRESET_IDS: [&str; 4] = ["bugfix", "review", "research", "benchmark"];
const LANE_A_KEYS: [&str; 3] = ["workspace-recipes", "workflows", "context-packs"];
const CONFIG_NAME: &str = ".winsmux.yaml";
const RUNTIME_NAME: &str = ".winsmux";
const JOURNAL_NAME: &str = "workspace-migration-v1.json";
const MAX_CONFIG_BYTES: u64 = 4 * 1024 * 1024;
const MAX_JOURNAL_BYTES: u64 = 6 * 1024 * 1024;
const MAX_PATH_BYTES: usize = 4096;
const MAX_COMPONENT_BYTES: usize = 255;
const GENERIC_ERROR: &str = "workspace migration rejected.";
const USAGE: &str = "usage: winsmux workspace-migrate --action <list|preview|apply|rollback> [--preset <id>] [--migration-id <64-lower-hex>] [--project-dir <path>] --json";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct PresetCatalog {
    schema_version: u64,
    presets: Vec<PresetDefinition>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct PresetDefinition {
    preset_id: String,
    display_name: String,
    purpose: String,
    lane_a: serde_yaml::Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MigrationAction {
    List,
    Preview,
    Apply,
    Rollback,
}

impl MigrationAction {
    fn parse(value: &str) -> io::Result<Self> {
        match value {
            "list" => Ok(Self::List),
            "preview" => Ok(Self::Preview),
            "apply" => Ok(Self::Apply),
            "rollback" => Ok(Self::Rollback),
            _ => Err(rejected()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Preview => "preview",
            Self::Apply => "apply",
            Self::Rollback => "rollback",
        }
    }
}

#[derive(Debug)]
struct MigrationOptions {
    action: MigrationAction,
    preset_id: Option<String>,
    migration_id: Option<String>,
    project_dir: Option<String>,
}

#[derive(Clone, Debug)]
struct ConfigSnapshot {
    existed: bool,
    bytes: Vec<u8>,
}

struct SelectedProjectDir {
    path: PathBuf,
    _lease: File,
}

impl SelectedProjectDir {
    fn path(&self) -> &Path {
        &self.path
    }
}

#[derive(Debug)]
struct ParsedProject {
    source: ConfigSnapshot,
    yaml_body: String,
    had_bom: bool,
    root: serde_yaml::Value,
}

#[derive(Debug)]
struct ProposalEvaluation {
    source: ConfigSnapshot,
    target_bytes: Option<Vec<u8>>,
    proposal_yaml: String,
    proposal_sha256: String,
    unsupported_code: Option<&'static str>,
}

impl ProposalEvaluation {
    fn is_ready(&self) -> bool {
        self.unsupported_code.is_none() && self.target_bytes.is_some()
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct MigrationJournal {
    schema_version: u64,
    migration_id: String,
    preset_id: String,
    original_existed: bool,
    original_base64: String,
    source_sha256: String,
    target_sha256: String,
}

#[derive(Debug)]
struct ValidatedJournal {
    value: MigrationJournal,
    original_bytes: Vec<u8>,
}

#[derive(Serialize)]
struct PresetSummary<'a> {
    preset_id: &'a str,
    display_name: &'a str,
    purpose: &'a str,
}

#[derive(Serialize)]
struct ListPayload<'a> {
    schema_version: u64,
    action: &'static str,
    status: &'static str,
    presets: Vec<PresetSummary<'a>>,
}

#[derive(Serialize)]
struct PreviewPayload {
    schema_version: u64,
    action: &'static str,
    preset_id: String,
    status: &'static str,
    applicable: bool,
    unsupported_codes: Vec<&'static str>,
    rollback_available_after_apply: bool,
    lane_b_preserved: bool,
    unknown_compatible_fields_preserved: bool,
    proposal_yaml: String,
    proposal_sha256: String,
}

#[derive(Serialize)]
struct MutationPayload {
    schema_version: u64,
    action: &'static str,
    status: &'static str,
    migration_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    preset_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rollback_command: Option<String>,
}

pub fn run(args: &[&String], raw_prefix_is_valid: bool) -> io::Result<()> {
    if !raw_prefix_is_valid {
        return Err(rejected());
    }
    if args.len() == 1 && matches!(args[0].as_str(), "-h" | "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    run_inner(args).map_err(|_| rejected())
}

fn run_inner(args: &[&String]) -> io::Result<()> {
    let options = parse_options(args)?;
    let catalog = load_catalog()?;
    match options.action {
        MigrationAction::List => run_list(&catalog),
        MigrationAction::Preview => {
            let preset = find_preset(&catalog, options.preset_id.as_deref())?;
            let project_dir = resolve_project_dir(options.project_dir.as_deref())?;
            run_preview(project_dir.path(), preset)
        }
        MigrationAction::Apply => {
            let preset = find_preset(&catalog, options.preset_id.as_deref())?;
            let project_dir = resolve_project_dir(options.project_dir.as_deref())?;
            run_apply(project_dir.path(), preset)
        }
        MigrationAction::Rollback => {
            let project_dir = resolve_project_dir(options.project_dir.as_deref())?;
            run_rollback(
                project_dir.path(),
                options.migration_id.as_deref().ok_or_else(rejected)?,
            )
        }
    }
}

fn parse_options(args: &[&String]) -> io::Result<MigrationOptions> {
    let mut action = None;
    let mut preset_id = None;
    let mut migration_id = None;
    let mut project_dir = None;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--action" => {
                if action.is_some() {
                    return Err(rejected());
                }
                action = Some(MigrationAction::parse(option_value(args, index)?)?);
                index += 2;
            }
            "--preset" => {
                if preset_id.is_some() {
                    return Err(rejected());
                }
                preset_id = Some(option_value(args, index)?.to_string());
                index += 2;
            }
            "--migration-id" => {
                if migration_id.is_some() {
                    return Err(rejected());
                }
                migration_id = Some(option_value(args, index)?.to_string());
                index += 2;
            }
            "--project-dir" => {
                if project_dir.is_some() {
                    return Err(rejected());
                }
                project_dir = Some(option_value(args, index)?.to_string());
                index += 2;
            }
            "--json" => {
                if json {
                    return Err(rejected());
                }
                json = true;
                index += 1;
            }
            _ => return Err(rejected()),
        }
    }

    let action = action.ok_or_else(rejected)?;
    if !json {
        return Err(rejected());
    }
    match action {
        MigrationAction::List
            if preset_id.is_none() && migration_id.is_none() && project_dir.is_none() => {}
        MigrationAction::Preview | MigrationAction::Apply
            if preset_id.is_some() && migration_id.is_none() => {}
        MigrationAction::Rollback if preset_id.is_none() && migration_id.is_some() => {}
        _ => return Err(rejected()),
    }
    if preset_id
        .as_deref()
        .is_some_and(|value| !is_stable_id(value))
        || migration_id
            .as_deref()
            .is_some_and(|value| !is_lower_hex(value, 64))
    {
        return Err(rejected());
    }
    Ok(MigrationOptions {
        action,
        preset_id,
        migration_id,
        project_dir,
    })
}

fn option_value<'a>(args: &'a [&String], index: usize) -> io::Result<&'a str> {
    args.get(index + 1)
        .map(|value| value.as_str())
        .filter(|value| !value.is_empty() && !value.starts_with("--"))
        .ok_or_else(rejected)
}

fn load_catalog() -> io::Result<PresetCatalog> {
    let root = parse_workspace_yaml(PRESET_CATALOG_YAML)?;
    let catalog: PresetCatalog = serde_yaml::from_value(root).map_err(|_| rejected())?;
    if catalog.schema_version != 1 || catalog.presets.len() != PRESET_IDS.len() {
        return Err(rejected());
    }

    let synthetic_slots = vec![SlotCapabilities {
        slot_id: "worker-1".to_string(),
        supports_file_edit: true,
        supports_verification: true,
        supports_structured_result: true,
    }];
    for (preset, expected_id) in catalog.presets.iter().zip(PRESET_IDS) {
        if preset.preset_id != expected_id
            || !is_stable_id(&preset.preset_id)
            || !is_public_metadata(&preset.display_name)
            || !is_public_metadata(&preset.purpose)
        {
            return Err(rejected());
        }
        validate_lane_a_shape(preset)?;
        crate::workflow::normalize_workspace_plan_payload(
            &preset.lane_a,
            &preset.preset_id,
            Some(&preset.preset_id),
            Some("migration-preview"),
            &synthetic_slots,
        )?;
        crate::context_pack::validate_context_pack_policy(&preset.lane_a, &preset.preset_id)?;
    }
    Ok(catalog)
}

fn validate_lane_a_shape(preset: &PresetDefinition) -> io::Result<()> {
    let mapping = preset.lane_a.as_mapping().ok_or_else(rejected)?;
    if mapping.len() != LANE_A_KEYS.len() {
        return Err(rejected());
    }
    for key in LANE_A_KEYS {
        let value = mapping
            .get(serde_yaml::Value::String(key.to_string()))
            .and_then(serde_yaml::Value::as_mapping)
            .ok_or_else(rejected)?;
        if value.len() != 1
            || !value.contains_key(serde_yaml::Value::String(preset.preset_id.clone()))
        {
            return Err(rejected());
        }
    }
    Ok(())
}

fn is_public_metadata(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= 160
        && value
            .chars()
            .all(|ch| !ch.is_control() || matches!(ch, '\t' | '\n'))
}

fn find_preset<'a>(
    catalog: &'a PresetCatalog,
    preset_id: Option<&str>,
) -> io::Result<&'a PresetDefinition> {
    let preset_id = preset_id.ok_or_else(rejected)?;
    catalog
        .presets
        .iter()
        .find(|preset| preset.preset_id == preset_id)
        .ok_or_else(rejected)
}

fn run_list(catalog: &PresetCatalog) -> io::Result<()> {
    let presets = catalog
        .presets
        .iter()
        .map(|preset| PresetSummary {
            preset_id: &preset.preset_id,
            display_name: &preset.display_name,
            purpose: &preset.purpose,
        })
        .collect();
    write_json(&ListPayload {
        schema_version: 1,
        action: MigrationAction::List.as_str(),
        status: "listed",
        presets,
    })
}

fn run_preview(project_dir: &Path, preset: &PresetDefinition) -> io::Result<()> {
    let evaluation = evaluate_proposal(project_dir, preset)?;
    let unsupported_codes = evaluation.unsupported_code.into_iter().collect();
    let payload = PreviewPayload {
        schema_version: 1,
        action: MigrationAction::Preview.as_str(),
        preset_id: preset.preset_id.clone(),
        status: if evaluation.is_ready() {
            "ready"
        } else {
            "unsupported"
        },
        applicable: evaluation.is_ready(),
        unsupported_codes,
        rollback_available_after_apply: true,
        lane_b_preserved: true,
        unknown_compatible_fields_preserved: true,
        proposal_yaml: evaluation.proposal_yaml,
        proposal_sha256: evaluation.proposal_sha256,
    };
    write_json(&payload)
}

fn run_apply(project_dir: &Path, preset: &PresetDefinition) -> io::Result<()> {
    validate_project_targets(project_dir)?;
    if read_journal(project_dir)?.is_none() {
        let evaluation = evaluate_proposal(project_dir, preset)?;
        if !evaluation.is_ready() {
            return Err(rejected());
        }
    }

    let config_path = project_dir.join(CONFIG_NAME);
    let payload = with_file_lock(&config_path, || apply_locked(project_dir, preset))?;
    write_json(&payload)
}

fn apply_locked(project_dir: &Path, preset: &PresetDefinition) -> io::Result<MutationPayload> {
    validate_project_targets(project_dir)?;
    let config = read_config(project_dir)?;
    if let Some(journal) = read_journal(project_dir)? {
        if journal.value.preset_id != preset.preset_id {
            return Err(rejected());
        }
        if config_matches_target(&config, &journal.value) {
            return Ok(apply_payload(
                "already_applied",
                &preset.preset_id,
                &journal.value.migration_id,
            ));
        }
        if !config_matches_source(&config, &journal.value) {
            return Err(rejected());
        }
        let evaluation = evaluate_proposal(project_dir, preset)?;
        if !evaluation.is_ready() {
            return Err(rejected());
        }
        let target = evaluation.target_bytes.ok_or_else(rejected)?;
        if sha256(&target) != journal.value.target_sha256 {
            return Err(rejected());
        }
        atomic_write(&project_dir.join(CONFIG_NAME), &target)?;
        return Ok(apply_payload(
            "applied",
            &preset.preset_id,
            &journal.value.migration_id,
        ));
    }

    let evaluation = evaluate_proposal(project_dir, preset)?;
    if !evaluation.is_ready() {
        return Err(rejected());
    }
    let target = evaluation.target_bytes.as_deref().ok_or_else(rejected)?;
    let migration_id = new_migration_id()?;
    let runtime_path = project_dir.join(RUNTIME_NAME);
    let runtime_created = ensure_runtime_parent(&runtime_path)?;
    let journal = MigrationJournal {
        schema_version: 1,
        migration_id: migration_id.clone(),
        preset_id: preset.preset_id.clone(),
        original_existed: evaluation.source.existed,
        original_base64: BASE64_STANDARD.encode(&evaluation.source.bytes),
        source_sha256: sha256(&evaluation.source.bytes),
        target_sha256: sha256(target),
    };
    let mut journal_bytes = serde_json::to_vec(&journal).map_err(|_| rejected())?;
    journal_bytes.push(b'\n');
    if journal_bytes.len() as u64 > MAX_JOURNAL_BYTES {
        cleanup_new_runtime_parent(&runtime_path, runtime_created);
        return Err(rejected());
    }
    let journal_path = runtime_path.join(JOURNAL_NAME);
    if let Err(error) = atomic_write(&journal_path, &journal_bytes) {
        cleanup_new_runtime_parent(&runtime_path, runtime_created);
        return Err(error);
    }
    atomic_write(&project_dir.join(CONFIG_NAME), target)?;
    Ok(apply_payload("applied", &preset.preset_id, &migration_id))
}

fn apply_payload(status: &'static str, preset_id: &str, migration_id: &str) -> MutationPayload {
    MutationPayload {
        schema_version: 1,
        action: MigrationAction::Apply.as_str(),
        status,
        migration_id: migration_id.to_string(),
        preset_id: Some(preset_id.to_string()),
        rollback_command: Some(format!(
            "winsmux workspace-migrate --action rollback --migration-id {migration_id} --json"
        )),
    }
}

fn run_rollback(project_dir: &Path, migration_id: &str) -> io::Result<()> {
    validate_project_targets(project_dir)?;
    let journal = read_journal(project_dir)?.ok_or_else(rejected)?;
    if journal.value.migration_id != migration_id {
        return Err(rejected());
    }

    let config_path = project_dir.join(CONFIG_NAME);
    let payload = with_file_lock(&config_path, || rollback_locked(project_dir, migration_id))?;
    write_json(&payload)
}

fn rollback_locked(project_dir: &Path, migration_id: &str) -> io::Result<MutationPayload> {
    validate_project_targets(project_dir)?;
    let journal = read_journal(project_dir)?.ok_or_else(rejected)?;
    if journal.value.migration_id != migration_id {
        return Err(rejected());
    }
    let config = read_config(project_dir)?;
    if config_matches_target(&config, &journal.value) {
        if journal.value.original_existed {
            atomic_write(&project_dir.join(CONFIG_NAME), &journal.original_bytes)?;
        } else {
            fs::remove_file(project_dir.join(CONFIG_NAME))?;
        }
    } else if !config_matches_source(&config, &journal.value) {
        return Err(rejected());
    }

    fs::remove_file(project_dir.join(RUNTIME_NAME).join(JOURNAL_NAME))?;
    Ok(MutationPayload {
        schema_version: 1,
        action: MigrationAction::Rollback.as_str(),
        status: "rolled_back",
        migration_id: migration_id.to_string(),
        preset_id: None,
        rollback_command: None,
    })
}

fn evaluate_proposal(
    project_dir: &Path,
    preset: &PresetDefinition,
) -> io::Result<ProposalEvaluation> {
    let source = read_config(project_dir)?;
    let proposal_yaml = serde_yaml::to_string(&preset.lane_a).map_err(|_| rejected())?;
    let proposal_sha256 = sha256(proposal_yaml.as_bytes());
    let project = match parse_project(source.clone()) {
        Ok(project) => project,
        Err(_) => {
            return Ok(unsupported_evaluation(
                source,
                proposal_yaml,
                proposal_sha256,
                "project_config_invalid",
            ))
        }
    };

    if lane_a_is_present(&project.root)? {
        return Ok(unsupported_evaluation(
            project.source,
            proposal_yaml,
            proposal_sha256,
            "lane_a_already_configured",
        ));
    }
    let slots = match effective_slots(project_dir, &project.root) {
        Ok(slots) => slots,
        Err(_) => {
            return Ok(unsupported_evaluation(
                project.source,
                proposal_yaml,
                proposal_sha256,
                "effective_slots_not_supported",
            ))
        }
    };
    if crate::workflow::normalize_workspace_plan_payload(
        &preset.lane_a,
        &preset.preset_id,
        Some(&preset.preset_id),
        Some("migration-preview"),
        &slots,
    )
    .is_err()
    {
        return Ok(unsupported_evaluation(
            project.source,
            proposal_yaml,
            proposal_sha256,
            "effective_slots_not_supported",
        ));
    }

    let target_bytes = match render_preset_target(&project, preset) {
        Ok(target_bytes) => target_bytes,
        Err(_) => {
            return Ok(unsupported_evaluation(
                project.source,
                proposal_yaml,
                proposal_sha256,
                "project_config_invalid",
            ))
        }
    };
    Ok(ProposalEvaluation {
        source: project.source,
        target_bytes: Some(target_bytes),
        proposal_yaml,
        proposal_sha256,
        unsupported_code: None,
    })
}

fn unsupported_evaluation(
    source: ConfigSnapshot,
    proposal_yaml: String,
    proposal_sha256: String,
    code: &'static str,
) -> ProposalEvaluation {
    ProposalEvaluation {
        source,
        target_bytes: None,
        proposal_yaml,
        proposal_sha256,
        unsupported_code: Some(code),
    }
}

fn derive_preset_target(
    source: ConfigSnapshot,
    preset: &PresetDefinition,
) -> io::Result<Vec<u8>> {
    let project = parse_project(source)?;
    if lane_a_is_present(&project.root)? {
        return Err(rejected());
    }
    render_preset_target(&project, preset)
}

fn render_preset_target(
    project: &ParsedProject,
    preset: &PresetDefinition,
) -> io::Result<Vec<u8>> {
    let desired = lane_a_json(&preset.lane_a)?;
    let rendered = crate::project_settings_render::render_owned_root_settings(
        &project.yaml_body,
        desired,
        &LANE_A_KEYS,
    )
    .map_err(|_| rejected())?;
    let mut target_bytes = Vec::with_capacity(rendered.len() + 3);
    if project.had_bom {
        target_bytes.extend_from_slice(&[0xef, 0xbb, 0xbf]);
    }
    target_bytes.extend_from_slice(rendered.as_bytes());
    if target_bytes.len() as u64 > MAX_CONFIG_BYTES {
        return Err(rejected());
    }
    Ok(target_bytes)
}

fn parse_project(source: ConfigSnapshot) -> io::Result<ParsedProject> {
    let (had_bom, body_bytes) = if source.bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        (true, &source.bytes[3..])
    } else {
        (false, source.bytes.as_slice())
    };
    if body_bytes
        .windows(3)
        .any(|window| window == [0xef, 0xbb, 0xbf])
    {
        return Err(rejected());
    }
    let yaml_body = std::str::from_utf8(body_bytes)
        .map_err(|_| rejected())?
        .to_string();
    let root = parse_workspace_yaml(&yaml_body)?;
    if !root.is_mapping() {
        return Err(rejected());
    }
    crate::workspace_project_settings::parse_value(&root)?;
    Ok(ParsedProject {
        source,
        yaml_body,
        had_bom,
        root,
    })
}

fn effective_slots(
    project_dir: &Path,
    root: &serde_yaml::Value,
) -> io::Result<Vec<SlotCapabilities>> {
    super::workspace_plan_resolution::resolve_workspace_migration_slot_capabilities(
        project_dir,
        root,
    )
}

fn lane_a_is_present(root: &serde_yaml::Value) -> io::Result<bool> {
    let mapping = root.as_mapping().ok_or_else(rejected)?;
    let mut seen = BTreeSet::new();
    for key in mapping.keys().filter_map(serde_yaml::Value::as_str) {
        let normalized = key.replace('_', "-").to_ascii_lowercase();
        if LANE_A_KEYS.contains(&normalized.as_str()) && !seen.insert(normalized) {
            return Err(rejected());
        }
    }
    Ok(!seen.is_empty())
}

fn lane_a_json(value: &serde_yaml::Value) -> io::Result<JsonMap<String, JsonValue>> {
    match serde_json::to_value(value).map_err(|_| rejected())? {
        JsonValue::Object(mapping) => Ok(mapping),
        _ => Err(rejected()),
    }
}

fn resolve_project_dir(raw: Option<&str>) -> io::Result<SelectedProjectDir> {
    let current_dir = env::current_dir()?;
    let path = match raw {
        None | Some(".") => current_dir,
        Some(value) => {
            let supplied = PathBuf::from(value);
            if supplied.is_absolute() {
                supplied
            } else {
                if supplied
                    .components()
                    .any(|component| matches!(component, std::path::Component::ParentDir))
                {
                    return Err(rejected());
                }
                current_dir.join(supplied)
            }
        }
    };
    let text = path.to_str().ok_or_else(rejected)?;
    validate_path_text(text)?;
    let lease = open_project_directory_lease(&path)?;
    validate_project_targets(&path)?;
    Ok(SelectedProjectDir {
        path,
        _lease: lease,
    })
}

#[cfg(windows)]
fn open_project_directory_lease(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    let lease = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .map_err(|_| rejected())?;
    let metadata = lease.metadata().map_err(|_| rejected())?;
    if !metadata.is_dir() || metadata_is_reparse(&metadata) {
        return Err(rejected());
    }
    Ok(lease)
}

#[cfg(not(windows))]
fn open_project_directory_lease(path: &Path) -> io::Result<File> {
    let metadata = fs::symlink_metadata(path).map_err(|_| rejected())?;
    if !metadata.is_dir() || metadata_is_reparse(&metadata) {
        return Err(rejected());
    }
    File::open(path).map_err(|_| rejected())
}

fn validate_path_text(value: &str) -> io::Result<()> {
    if value.is_empty()
        || value.as_bytes().contains(&0)
        || value.as_bytes().len() > MAX_PATH_BYTES
        || value.starts_with(r"\\?\")
        || value.starts_with(r"\\.\")
        || value.starts_with(r"\??\")
    {
        return Err(rejected());
    }
    for (index, component) in value.split(['\\', '/']).enumerate() {
        if component.is_empty() {
            continue;
        }
        if index == 0
            && component.len() == 2
            && component.as_bytes()[1] == b':'
            && component.as_bytes()[0].is_ascii_alphabetic()
        {
            continue;
        }
        if component == "."
            || component == ".."
            || component.as_bytes().len() > MAX_COMPONENT_BYTES
            || component.ends_with(['.', ' '])
            || component
                .chars()
                .any(|ch| ch.is_control() || matches!(ch, '<' | '>' | '"' | '|' | '?' | '*'))
            || component.contains(':')
            || is_windows_reserved_component(component)
        {
            return Err(rejected());
        }
    }
    Ok(())
}

fn is_windows_reserved_component(component: &str) -> bool {
    let base = component
        .split('.')
        .next()
        .unwrap_or_default()
        .to_uppercase();
    matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || matches!(
            base.as_str(),
            "COM1"
                | "COM2"
                | "COM3"
                | "COM4"
                | "COM5"
                | "COM6"
                | "COM7"
                | "COM8"
                | "COM9"
                | "LPT1"
                | "LPT2"
                | "LPT3"
                | "LPT4"
                | "LPT5"
                | "LPT6"
                | "LPT7"
                | "LPT8"
                | "LPT9"
                | "COM¹"
                | "COM²"
                | "COM³"
                | "LPT¹"
                | "LPT²"
                | "LPT³"
        )
}

fn validate_project_targets(project_dir: &Path) -> io::Result<()> {
    validate_existing_target(&project_dir.join(CONFIG_NAME), ExistingKind::File)?;
    validate_existing_target(&project_dir.join(RUNTIME_NAME), ExistingKind::Directory)?;
    validate_existing_target(
        &project_dir.join(RUNTIME_NAME).join(JOURNAL_NAME),
        ExistingKind::File,
    )?;
    validate_existing_target(
        &super::lock_path_for(&project_dir.join(CONFIG_NAME)),
        ExistingKind::Directory,
    )
}

#[derive(Clone, Copy)]
enum ExistingKind {
    File,
    Directory,
}

fn validate_existing_target(path: &Path, kind: ExistingKind) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(rejected()),
    };
    if metadata_is_reparse(&metadata)
        || match kind {
            ExistingKind::File => !metadata.is_file(),
            ExistingKind::Directory => !metadata.is_dir(),
        }
    {
        return Err(rejected());
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

fn read_config(project_dir: &Path) -> io::Result<ConfigSnapshot> {
    let path = project_dir.join(CONFIG_NAME);
    let bytes = read_bounded_file(&path, MAX_CONFIG_BYTES)?;
    Ok(match bytes {
        Some(bytes) => ConfigSnapshot {
            existed: true,
            bytes,
        },
        None => ConfigSnapshot {
            existed: false,
            bytes: Vec::new(),
        },
    })
}

fn read_bounded_file(path: &Path, max_bytes: u64) -> io::Result<Option<Vec<u8>>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(rejected()),
    };
    if metadata_is_reparse(&metadata) || !metadata.is_file() || metadata.len() > max_bytes {
        return Err(rejected());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    File::open(path)?
        .take(max_bytes + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        return Err(rejected());
    }
    Ok(Some(bytes))
}

fn read_journal(project_dir: &Path) -> io::Result<Option<ValidatedJournal>> {
    let path = project_dir.join(RUNTIME_NAME).join(JOURNAL_NAME);
    let Some(bytes) = read_bounded_file(&path, MAX_JOURNAL_BYTES)? else {
        return Ok(None);
    };
    std::str::from_utf8(&bytes).map_err(|_| rejected())?;
    let value: MigrationJournal = serde_json::from_slice(&bytes).map_err(|_| rejected())?;
    if value.schema_version != 1
        || !is_lower_hex(&value.migration_id, 64)
        || !PRESET_IDS.contains(&value.preset_id.as_str())
        || !is_sha256(&value.source_sha256)
        || !is_sha256(&value.target_sha256)
    {
        return Err(rejected());
    }
    let original_bytes = BASE64_STANDARD
        .decode(&value.original_base64)
        .map_err(|_| rejected())?;
    if BASE64_STANDARD.encode(&original_bytes) != value.original_base64
        || (!value.original_existed && !original_bytes.is_empty())
        || sha256(&original_bytes) != value.source_sha256
    {
        return Err(rejected());
    }
    let catalog = load_catalog()?;
    let preset = catalog
        .presets
        .iter()
        .find(|preset| preset.preset_id == value.preset_id)
        .ok_or_else(rejected)?;
    let derived_target = derive_preset_target(
        ConfigSnapshot {
            existed: value.original_existed,
            bytes: original_bytes.clone(),
        },
        preset,
    )?;
    if sha256(&derived_target) != value.target_sha256 {
        return Err(rejected());
    }
    Ok(Some(ValidatedJournal {
        value,
        original_bytes,
    }))
}

fn config_matches_source(config: &ConfigSnapshot, journal: &MigrationJournal) -> bool {
    config.existed == journal.original_existed && sha256(&config.bytes) == journal.source_sha256
}

fn config_matches_target(config: &ConfigSnapshot, journal: &MigrationJournal) -> bool {
    config.existed && sha256(&config.bytes) == journal.target_sha256
}

fn ensure_runtime_parent(path: &Path) -> io::Result<bool> {
    match fs::create_dir(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            validate_existing_target(path, ExistingKind::Directory)?;
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn cleanup_new_runtime_parent(path: &Path, created: bool) {
    if created {
        let _ = fs::remove_dir(path);
    }
}

fn atomic_write(path: &Path, content: &[u8]) -> io::Result<()> {
    let temp_path = temp_write_path(path);
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)?;
        file.write_all(content)?;
        file.sync_all()?;
        drop(file);
        replace_file_with_temp(&temp_path, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn new_migration_id() -> io::Result<String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| rejected())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn sha256(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn is_sha256(value: &str) -> bool {
    value
        .strip_prefix("sha256:")
        .is_some_and(|digest| is_lower_hex(digest, 64))
}

fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_stable_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.is_ascii()
        && value
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !value.ends_with('-')
        && !value.contains("--")
}

fn rejected() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, GENERIC_ERROR)
}
