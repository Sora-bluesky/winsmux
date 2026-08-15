use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

use serde::Serialize;
use serde_json::{json, Value as JsonValue};
use serde_yaml::Value;
use sha2::{Digest, Sha256};

use crate::workspace_recipe::parse_workspace_yaml;

include!(concat!(::core::env!("OUT_DIR"), "/embedded_profiles.rs"));

const REGISTRY_REL: &str = "winsmux-core/agents/profiles";
const REGISTRY_FILE: &str = "registry.yaml";
const INSTRUCTION_FILES: [&str; 3] = [
    "winsmux-core/agents/AGENTS.md",
    ".claude/CLAUDE.md",
    "GEMINI.md",
];
const TRACKED_INSTRUCTION_SHA256: [(&str, &str); 3] = [
    (
        "winsmux-core/agents/AGENTS.md",
        "ebc5696f845388b5dc3c275537161e52db0a85cf5761f98dd851da8125c1a4a3",
    ),
    (
        ".claude/CLAUDE.md",
        "b12b74fc890a6ab468fe458f2f40c39d3e44d3e5921b216b25de711d8e9ded90",
    ),
    (
        "GEMINI.md",
        "f2037a0e37b9557b756865827734ee2af40a8bc2187eb73a67bf5b9e730edffa",
    ),
];
const SECRET_PATTERN: &str = r"(?i)\b(gho_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b|(?:^|\s)(?:GITHUB_TOKEN|GH_TOKEN|API_KEY)\s*=|/Users/|/home/[A-Za-z]|[A-Za-z]:\\Users\\";

#[derive(Clone, Debug, Serialize)]
pub(crate) struct InstructionIssue {
    pub field: String,
    pub code: String,
    pub severity: String,
    pub remediation: String,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ComposedPack {
    #[serde(rename = "template-ids")]
    pub template_ids: Vec<String>,
    pub digest_sha256: String,
    pub body: String,
    pub a1: A1Criteria,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct A1Criteria {
    pub worker: Vec<String>,
    pub operator: Vec<String>,
}

#[derive(Clone, Debug)]
struct Registry {
    a1: A1Criteria,
    base: String,
    providers: BTreeMap<String, String>,
    roles: BTreeMap<String, String>,
    lifecycles: BTreeMap<String, String>,
    task_classes: BTreeMap<String, String>,
    models: BTreeMap<String, ModelTemplate>,
    dynamic_providers: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
struct ModelTemplate {
    provider: String,
    template: String,
}

#[derive(Clone, Debug)]
enum ProfileSource {
    Filesystem(PathBuf),
    Embedded,
}

pub(crate) fn profiles_root() -> io::Result<PathBuf> {
    match profile_source()? {
        ProfileSource::Filesystem(path) => Ok(path),
        ProfileSource::Embedded => Err(io::Error::new(
            ErrorKind::NotFound,
            "instruction-pack registry is embedded; no on-disk profiles root is required.",
        )),
    }
}

fn profile_source() -> io::Result<ProfileSource> {
    if let Some(path) = filesystem_profiles_root() {
        return Ok(ProfileSource::Filesystem(path));
    }
    if embedded_profile(REGISTRY_FILE).is_some() {
        return Ok(ProfileSource::Embedded);
    }
    Err(io::Error::new(
        ErrorKind::NotFound,
        "instruction-pack registry.yaml was not found.",
    ))
}

fn filesystem_profiles_root() -> Option<PathBuf> {
    if let Ok(configured) = env::var("WINSMUX_PROFILES_DIR") {
        let path = PathBuf::from(configured);
        if path.join(REGISTRY_FILE).is_file() {
            return Some(path);
        }
    }
    if let Ok(manifest) = env::var("CARGO_MANIFEST_DIR") {
        let path = Path::new(&manifest).join("..").join(REGISTRY_REL);
        if path.join(REGISTRY_FILE).is_file() {
            return Some(path);
        }
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(dir) = exe.parent() {
            for ancestor in dir.ancestors() {
                let path = ancestor.join(REGISTRY_REL);
                if path.join(REGISTRY_FILE).is_file() {
                    return Some(path);
                }
            }
        }
    }
    if let Ok(cwd) = env::current_dir() {
        for ancestor in cwd.ancestors() {
            let path = ancestor.join(REGISTRY_REL);
            if path.join(REGISTRY_FILE).is_file() {
                return Some(path);
            }
        }
    }
    None
}

pub(crate) fn lint_registry() -> Result<JsonValue, Vec<InstructionIssue>> {
    let source = profile_source().map_err(|error| {
        vec![issue(
            "registry",
            "missing_registry",
            error.to_string(),
        )]
    })?;
    let registry = load_registry(&source)?;
    let mut issues = Vec::new();
    lint_path(&source, &registry.base, "base", &mut issues);
    for (id, template) in &registry.providers {
        lint_path(&source, template, &format!("provider/{id}"), &mut issues);
    }
    for (id, template) in &registry.roles {
        lint_path(&source, template, &format!("role/{id}"), &mut issues);
    }
    for (id, template) in &registry.lifecycles {
        lint_path(&source, template, &format!("lifecycle/{id}"), &mut issues);
    }
    for (id, template) in &registry.task_classes {
        lint_path(&source, template, &format!("task-class/{id}"), &mut issues);
    }
    let mut templates = BTreeSet::new();
    for (id, model) in &registry.models {
        if !templates.insert((model.provider.clone(), model.template.clone()))
            && registry
                .models
                .values()
                .filter(|other| other.template == model.template)
                .count()
                > 1
            && model.provider != "openrouter"
        {
            // Duplicate exact paths are allowed only when intentional; unique IDs are the hard rule.
        }
        let _ = id;
        lint_path(&source, &model.template, &format!("model/{}", id), &mut issues);
        if model.provider.is_empty() || !registry.providers.contains_key(&model.provider) {
            issues.push(issue(
                &format!("model/{id}"),
                "unknown_provider_mapping",
                format!("Model '{id}' maps to unknown provider '{}'.", model.provider),
            ));
        }
    }
    for (provider, template) in &registry.dynamic_providers {
        lint_path(
            &source,
            template,
            &format!("dynamic/{provider}"),
            &mut issues,
        );
    }
    if registry.a1.worker.is_empty() || registry.a1.operator.is_empty() {
        issues.push(issue(
            "a1",
            "missing_a1",
            "Registry A1 worker and operator lists are required.",
        ));
    }
    if issues.is_empty() {
        Ok(json!({
            "schema_version": 1,
            "ok": true,
            "registry_id": "official-instruction-packs-v1",
            "models": registry.models.len(),
        }))
    } else {
        Err(issues)
    }
}

pub(crate) fn compose_pack(
    provider: &str,
    model: &str,
    role: &str,
    lifecycle: &str,
    task_classes: &[String],
) -> Result<ComposedPack, Vec<InstructionIssue>> {
    let source = profile_source().map_err(|error| {
        vec![issue("registry", "missing_registry", error.to_string())]
    })?;
    let registry = load_registry(&source)?;
    let mut template_ids = Vec::new();
    let mut parts = Vec::new();
    push_layer(&source, &registry.base, "base", &mut template_ids, &mut parts)?;
    let provider_template = registry.providers.get(provider).ok_or_else(|| {
        vec![issue(
            "provider",
            "missing_instruction_pack",
            format!("No provider template for '{provider}'."),
        )]
    })?;
    push_layer(
        &source,
        provider_template,
        &format!("provider/{provider}"),
        &mut template_ids,
        &mut parts,
    )?;
    let (model_template, model_template_id) = resolve_model_template(&registry, provider, model)?;
    push_layer(
        &source,
        &model_template,
        &model_template_id,
        &mut template_ids,
        &mut parts,
    )?;
    let role_template = registry.roles.get(role).ok_or_else(|| {
        vec![issue(
            "role-profile",
            "missing_instruction_pack",
            format!("No role template for '{role}'."),
        )]
    })?;
    push_layer(
        &source,
        role_template,
        &format!("role/{role}"),
        &mut template_ids,
        &mut parts,
    )?;
    let lifecycle_template = registry.lifecycles.get(lifecycle).ok_or_else(|| {
        vec![issue(
            "lifecycle",
            "missing_instruction_pack",
            format!("No lifecycle template for '{lifecycle}'."),
        )]
    })?;
    push_layer(
        &source,
        lifecycle_template,
        &format!("lifecycle/{lifecycle}"),
        &mut template_ids,
        &mut parts,
    )?;
    if task_classes.is_empty() {
        return Err(vec![issue(
            "task-classes",
            "missing_instruction_pack",
            "task-classes must be a non-empty list of registered templates.",
        )]);
    }
    for class in task_classes {
        let template = registry.task_classes.get(class).ok_or_else(|| {
            vec![issue(
                "task-classes",
                "missing_instruction_pack",
                format!("No task-class template for '{class}'."),
            )]
        })?;
        push_layer(
            &source,
            template,
            &format!("task/{class}"),
            &mut template_ids,
            &mut parts,
        )?;
    }
    let body = format!("{}\n", parts.join("\n\n"));
    let digest = format!("{:x}", Sha256::digest(body.as_bytes()));
    Ok(ComposedPack {
        template_ids,
        digest_sha256: digest,
        body,
        a1: registry.a1,
    })
}

pub(crate) fn compose_json(
    provider: &str,
    model: &str,
    role: &str,
    lifecycle: &str,
    task_classes: &[String],
) -> Result<JsonValue, Vec<InstructionIssue>> {
    let pack = compose_pack(provider, model, role, lifecycle, task_classes)?;
    Ok(json!({
        "schema_version": 1,
        "template_ids": pack.template_ids,
        "digest_sha256": pack.digest_sha256,
        "a1": pack.a1,
    }))
}

pub(crate) fn tracked_instruction_hashes() -> Result<Vec<(String, String, String)>, Vec<InstructionIssue>> {
    let root = repo_root().map_err(|error| {
        vec![issue("instruction-files", "missing_repo", error.to_string())]
    })?;
    let mut rows = Vec::new();
    for (rel, expected) in TRACKED_INSTRUCTION_SHA256 {
        let path = root.join(rel);
        let bytes = fs::read(&path).map_err(|_| {
            vec![issue(
                rel,
                "missing_instruction_file",
                format!("Tracked instruction file '{rel}' is missing."),
            )]
        })?;
        let normalized = String::from_utf8_lossy(&bytes).replace("\r\n", "\n");
        let actual = format!("{:x}", Sha256::digest(normalized.as_bytes()));
        rows.push((rel.to_string(), expected.to_string(), actual));
    }
    Ok(rows)
}

fn repo_root() -> io::Result<PathBuf> {
    if let Some(profiles) = filesystem_profiles_root() {
        if let Some(root) = profiles.ancestors().nth(3) {
            return Ok(root.to_path_buf());
        }
    }
    let cwd = env::current_dir()?;
    for ancestor in cwd.ancestors() {
        if ancestor.join("winsmux-core/agents/AGENTS.md").is_file() {
            return Ok(ancestor.to_path_buf());
        }
    }
    Err(io::Error::new(ErrorKind::NotFound, "repository root was not found."))
}

fn load_registry(source: &ProfileSource) -> Result<Registry, Vec<InstructionIssue>> {
    let yaml = read_profile_text(source, REGISTRY_FILE).map_err(|_| {
        vec![issue(
            "registry",
            "missing_registry",
            "registry.yaml is missing.",
        )]
    })?;
    if yaml.starts_with('\u{feff}') {
        return Err(vec![issue(
            "registry",
            "utf8_bom",
            "registry.yaml must be UTF-8 without BOM.",
        )]);
    }
    let root_value = parse_workspace_yaml(&yaml).map_err(|error| {
        vec![issue("registry", "invalid_registry", error.to_string())]
    })?;
    let mapping = root_value.as_mapping().ok_or_else(|| {
        vec![issue(
            "registry",
            "invalid_registry",
            "registry.yaml must be a mapping.",
        )]
    })?;
    let schema = mapping
        .get(&Value::String("schema-version".into()))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if schema != 1 {
        return Err(vec![issue(
            "registry",
            "unsupported_schema_version",
            "instruction-pack schema-version must be 1.",
        )]);
    }
    Ok(Registry {
        a1: parse_a1(mapping)?,
        base: required_text(mapping, "base")?,
        providers: id_templates(mapping, "providers")?,
        roles: id_templates(mapping, "roles")?,
        lifecycles: id_templates(mapping, "lifecycles")?,
        task_classes: id_templates(mapping, "task-classes")?,
        models: parse_models(mapping)?,
        dynamic_providers: parse_dynamic(mapping)?,
    })
}

fn parse_a1(mapping: &serde_yaml::Mapping) -> Result<A1Criteria, Vec<InstructionIssue>> {
    let Some(Value::Mapping(a1)) = mapping.get(&Value::String("a1".into())) else {
        return Err(vec![issue("a1", "missing_a1", "Registry A1 block is required.")]);
    };
    Ok(A1Criteria {
        worker: string_list(a1, "worker")?,
        operator: string_list(a1, "operator")?,
    })
}

fn string_list(
    mapping: &serde_yaml::Mapping,
    key: &str,
) -> Result<Vec<String>, Vec<InstructionIssue>> {
    let Some(Value::Sequence(items)) = mapping.get(&Value::String(key.into())) else {
        return Err(vec![issue(
            key,
            "invalid_list",
            format!("{key} must be a sequence."),
        )]);
    };
    let mut values = Vec::new();
    for item in items {
        let Some(text) = item.as_str() else {
            return Err(vec![issue(key, "invalid_list_item", "List values must be strings.")]);
        };
        values.push(text.to_string());
    }
    Ok(values)
}

fn required_text(
    mapping: &serde_yaml::Mapping,
    key: &str,
) -> Result<String, Vec<InstructionIssue>> {
    mapping
        .get(&Value::String(key.into()))
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| vec![issue(key, "missing_field", format!("{key} is required."))])
}

fn id_templates(
    mapping: &serde_yaml::Mapping,
    key: &str,
) -> Result<BTreeMap<String, String>, Vec<InstructionIssue>> {
    let Some(Value::Sequence(items)) = mapping.get(&Value::String(key.into())) else {
        return Err(vec![issue(
            key,
            "invalid_list",
            format!("{key} must be a sequence."),
        )]);
    };
    let mut out = BTreeMap::new();
    for item in items {
        let Some(entry) = item.as_mapping() else {
            return Err(vec![issue(key, "invalid_entry", "Each entry must be a mapping.")]);
        };
        let id = required_text(entry, "id")?;
        let template = required_text(entry, "template")?;
        if out.insert(id.clone(), template).is_some() {
            return Err(vec![issue(
                key,
                "duplicate_id",
                format!("Duplicate '{key}' id '{id}'."),
            )]);
        }
    }
    Ok(out)
}

fn parse_models(
    mapping: &serde_yaml::Mapping,
) -> Result<BTreeMap<String, ModelTemplate>, Vec<InstructionIssue>> {
    let Some(Value::Sequence(items)) = mapping.get(&Value::String("models".into())) else {
        return Err(vec![issue(
            "models",
            "invalid_list",
            "models must be a sequence.",
        )]);
    };
    let mut out = BTreeMap::new();
    for item in items {
        let Some(entry) = item.as_mapping() else {
            return Err(vec![issue("models", "invalid_entry", "Each model must be a mapping.")]);
        };
        let id = required_text(entry, "id")?;
        let model = ModelTemplate {
            provider: required_text(entry, "provider")?,
            template: required_text(entry, "template")?,
        };
        if out.insert(id.clone(), model).is_some() {
            return Err(vec![issue(
                "models",
                "duplicate_id",
                format!("Duplicate model id '{id}'."),
            )]);
        }
    }
    Ok(out)
}

fn parse_dynamic(
    mapping: &serde_yaml::Mapping,
) -> Result<BTreeMap<String, String>, Vec<InstructionIssue>> {
    let Some(Value::Sequence(items)) = mapping.get(&Value::String("dynamic-providers".into())) else {
        return Ok(BTreeMap::new());
    };
    let mut out = BTreeMap::new();
    for item in items {
        let Some(entry) = item.as_mapping() else {
            return Err(vec![issue(
                "dynamic-providers",
                "invalid_entry",
                "Each dynamic provider must be a mapping.",
            )]);
        };
        let provider = required_text(entry, "provider")?;
        let template = required_text(entry, "template")?;
        if out.insert(provider.clone(), template).is_some() {
            return Err(vec![issue(
                "dynamic-providers",
                "duplicate_id",
                format!("Duplicate dynamic provider '{provider}'."),
            )]);
        }
    }
    Ok(out)
}

fn resolve_model_template(
    registry: &Registry,
    provider: &str,
    model: &str,
) -> Result<(String, String), Vec<InstructionIssue>> {
    if let Some(entry) = registry.models.get(model) {
        if entry.provider != provider {
            return Err(vec![issue(
                "model",
                "model_provider_mismatch",
                format!("Instruction pack for '{model}' belongs to '{}'.", entry.provider),
            )]);
        }
        return Ok((
            entry.template.clone(),
            format!("model/{provider}/{model}"),
        ));
    }
    if let Some(template) = registry.dynamic_providers.get(provider) {
        let stem = Path::new(template)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("_dynamic");
        return Ok((template.clone(), format!("model/{provider}/{stem}")));
    }
    Err(vec![issue(
        "model",
        "missing_instruction_pack",
        format!("No instruction pack mapping for model '{model}'."),
    )])
}

fn push_layer(
    source: &ProfileSource,
    rel: &str,
    id: &str,
    ids: &mut Vec<String>,
    parts: &mut Vec<String>,
) -> Result<(), Vec<InstructionIssue>> {
    let text = read_template(source, rel, id)?;
    ids.push(id.to_string());
    parts.push(text);
    Ok(())
}

fn lint_path(source: &ProfileSource, rel: &str, field: &str, issues: &mut Vec<InstructionIssue>) {
    if let Err(mut found) = read_template(source, rel, field) {
        issues.append(&mut found);
    }
}

fn read_profile_text(source: &ProfileSource, rel: &str) -> io::Result<String> {
    match source {
        ProfileSource::Filesystem(root) => fs::read_to_string(root.join(rel)),
        ProfileSource::Embedded => embedded_profile(rel)
            .map(str::to_string)
            .ok_or_else(|| io::Error::new(ErrorKind::NotFound, format!("{rel} is not embedded."))),
    }
}

fn read_profile_bytes(source: &ProfileSource, rel: &str) -> io::Result<Vec<u8>> {
    match source {
        ProfileSource::Filesystem(root) => fs::read(root.join(rel)),
        ProfileSource::Embedded => embedded_profile(rel)
            .map(|text| text.as_bytes().to_vec())
            .ok_or_else(|| io::Error::new(ErrorKind::NotFound, format!("{rel} is not embedded."))),
    }
}

fn read_template(source: &ProfileSource, rel: &str, field: &str) -> Result<String, Vec<InstructionIssue>> {
    if rel.is_empty()
        || Path::new(rel).is_absolute()
        || rel.contains('\0')
        || rel.split(['/', '\\']).any(|part| part == "..")
    {
        return Err(vec![issue(
            field,
            "unsafe_template_path",
            format!("Template path '{rel}' must be a relative path without '..'."),
        )]);
    }
    let bytes = read_profile_bytes(source, rel).map_err(|_| {
        vec![issue(
            field,
            "missing_instruction_pack",
            format!("Template '{rel}' is missing."),
        )]
    })?;
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(vec![issue(
            field,
            "utf8_bom",
            format!("Template '{rel}' must be UTF-8 without BOM."),
        )]);
    }
    let text = String::from_utf8(bytes).map_err(|_| {
        vec![issue(
            field,
            "invalid_utf8",
            format!("Template '{rel}' is not valid UTF-8."),
        )]
    })?;
    if regex_is_match(SECRET_PATTERN, &text) {
        return Err(vec![issue(
            field,
            "secret_or_private_path",
            format!("Template '{rel}' contains a secret or private path."),
        )]);
    }
    Ok(text.trim().to_string())
}

fn regex_is_match(pattern: &str, text: &str) -> bool {
    regex::Regex::new(pattern)
        .map(|re| re.is_match(text))
        .unwrap_or(false)
}

fn issue(field: &str, code: &str, remediation: impl Into<String>) -> InstructionIssue {
    InstructionIssue {
        field: field.to_string(),
        code: code.to_string(),
        severity: "error".to_string(),
        remediation: remediation.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_lint_accepts_official_tree() {
        let report = lint_registry().expect("lint");
        assert_eq!(report["ok"], true);
        assert_eq!(report["models"], 28);
    }

    #[test]
    fn compose_default_architect_slot_is_stable() {
        let pack = compose_pack(
            "codex",
            "codex-gpt-5-6-sol",
            "architect",
            "session",
            &["architecture".into(), "protocol".into(), "security".into()],
        )
        .expect("compose default");
        assert_eq!(
            pack.template_ids,
            vec![
                "base",
                "provider/codex",
                "model/codex/codex-gpt-5-6-sol",
                "role/architect",
                "lifecycle/session",
                "task/architecture",
                "task/protocol",
                "task/security",
            ]
        );
        assert!(pack.body.contains("A1 delegation"));
        assert!(pack.body.contains("frozen-spec-implementation"));
        assert!(!pack.body.contains("TASK-"));
        assert_eq!(pack.digest_sha256.len(), 64);
        assert_eq!(pack.a1.worker.len(), 3);
    }

    #[test]
    fn compose_openrouter_dynamic_does_not_probe_filenames() {
        let pack = compose_pack(
            "openrouter",
            "openrouter-not-in-seed-catalog",
            "maintainer",
            "task",
            &["documentation".into(), "repository-operations".into()],
        )
        .expect("compose dynamic");
        assert!(pack.template_ids.iter().any(|id| id == "model/openrouter/_dynamic"));
        assert!(!pack.template_ids.iter().any(|id| id.contains("not-in-seed")));
        assert!(pack.body.contains("Do not probe sibling filenames"));
        assert!(!pack.body.contains("openrouter-glm-5-2"));
    }

    #[test]
    fn missing_role_fails_closed() {
        let error = compose_pack(
            "codex",
            "codex-gpt-5-6-sol",
            "wizard",
            "session",
            &["architecture".into()],
        )
        .unwrap_err();
        assert!(error.iter().any(|issue| issue.code == "missing_instruction_pack"));
    }

    #[test]
    fn tracked_instruction_files_are_unchanged() {
        let rows = tracked_instruction_hashes().expect("hashes");
        for (rel, expected, actual) in rows {
            assert_eq!(actual, expected, "{rel} hash changed");
        }
        assert_eq!(INSTRUCTION_FILES.len(), 3);
    }

    #[test]
    fn embedded_registry_covers_official_tree() {
        assert!(super::embedded_profile("registry.yaml").is_some());
        assert!(super::embedded_profile("base.md").is_some());
        assert!(super::embedded_profile("providers/codex.md").is_some());
        let pack = compose_pack(
            "codex",
            "codex-gpt-5-6-sol",
            "architect",
            "session",
            &["architecture".into(), "protocol".into(), "security".into()],
        )
        .expect("compose from available source");
        assert_eq!(pack.digest_sha256.len(), 64);
    }
}
