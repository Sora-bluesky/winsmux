use std::collections::{BTreeMap, BTreeSet};
use std::io;

use serde::{
    de::{DeserializeSeed, EnumAccess, Error as _, MapAccess, SeqAccess, VariantAccess, Visitor},
    Deserialize, Serialize,
};
use sha2::{Digest, Sha256};

const SCHEMA_VERSION: u64 = 1;
const DOCUMENT_CONFIG_VERSION: i64 = 1;
const WORKFLOW_ID_TOKEN: &str = "{{workflow-id}}";
const WINDOWS_MAX_COMPONENT_LENGTH: usize = 255;
const WINDOWS_RESERVED_PATH_NAMES: [&str; 22] = [
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];
const DUPLICATE_YAML_MAPPING_KEY_SENTINEL: &str = "winsmux duplicate YAML mapping key";

struct UniqueYamlValueSeed;

impl<'de> DeserializeSeed<'de> for UniqueYamlValueSeed {
    type Value = serde_yaml::Value;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(UniqueYamlValueVisitor)
    }
}

struct UniqueYamlValueVisitor;

impl<'de> Visitor<'de> for UniqueYamlValueVisitor {
    type Value = serde_yaml::Value;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a YAML value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Number(value.into()))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Number(value.into()))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Number(value.into()))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::String(value.to_string()))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::String(value))
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Null)
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(serde_yaml::Value::Null)
    }

    fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        UniqueYamlValueSeed.deserialize(deserializer)
    }

    fn visit_newtype_struct<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        UniqueYamlValueSeed.deserialize(deserializer)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element_seed(UniqueYamlValueSeed)? {
            values.push(value);
        }
        Ok(serde_yaml::Value::Sequence(values))
    }

    fn visit_map<A>(self, mut mapping: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut values = serde_yaml::Mapping::new();
        while let Some(key) = mapping.next_key_seed(UniqueYamlValueSeed)? {
            if values.contains_key(&key) {
                return Err(A::Error::custom(DUPLICATE_YAML_MAPPING_KEY_SENTINEL));
            }
            let value = mapping.next_value_seed(UniqueYamlValueSeed)?;
            values.insert(key, value);
        }
        Ok(serde_yaml::Value::Mapping(values))
    }

    fn visit_enum<A>(self, data: A) -> Result<Self::Value, A::Error>
    where
        A: EnumAccess<'de>,
    {
        let (tag, contents) = data.variant::<String>()?;
        let value = contents.newtype_variant_seed(UniqueYamlValueSeed)?;
        Ok(serde_yaml::Value::Tagged(Box::new(
            serde_yaml::value::TaggedValue {
                tag: serde_yaml::value::Tag::new(tag),
                value,
            },
        )))
    }
}

pub(crate) fn parse_workspace_yaml(yaml: &str) -> io::Result<serde_yaml::Value> {
    if yaml.trim().is_empty() {
        return Ok(serde_yaml::Value::Mapping(serde_yaml::Mapping::new()));
    }
    let mut documents = serde_yaml::Deserializer::from_str(yaml);
    let Some(document) = documents.next() else {
        return Ok(serde_yaml::Value::Mapping(serde_yaml::Mapping::new()));
    };
    let root = UniqueYamlValueSeed.deserialize(document).map_err(|error| {
        if error
            .to_string()
            .contains(DUPLICATE_YAML_MAPPING_KEY_SENTINEL)
        {
            invalid_data("duplicate YAML mapping key.")
        } else {
            invalid_data("invalid .winsmux.yaml syntax.")
        }
    })?;
    if documents.next().is_some() {
        return Err(invalid_data("invalid .winsmux.yaml syntax."));
    }
    Ok(root)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SlotCapabilities {
    pub slot_id: String,
    pub supports_file_edit: bool,
    pub supports_verification: bool,
    pub supports_structured_result: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedWorkspacePlan {
    pub schema_version: u64,
    pub config_fingerprint: String,
    pub recipe_id: String,
    pub workflow_id: Option<String>,
    pub application_layout: NormalizedApplicationLayout,
    pub panes: Vec<NormalizedPane>,
    pub startup_actions: Vec<NormalizedStartupAction>,
    pub resolved_bindings: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedApplicationLayout {
    pub schema_version: u64,
    pub columns: Vec<NormalizedApplicationColumn>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedApplicationColumn {
    pub region: String,
    pub panes: Vec<NormalizedApplicationPane>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedApplicationPane {
    pub pane_key: String,
    pub workflow_role: String,
    pub slot_id: String,
    pub worktree: NormalizedWorktree,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedPane {
    pub pane_key: String,
    pub workflow_role: String,
    pub slot_id: String,
    pub required_capabilities: Vec<String>,
    pub region: String,
    pub worktree: NormalizedWorktree,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedWorktree {
    pub mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedStartupAction {
    pub action_id: String,
    pub kind: String,
    pub pane_ref: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct Recipe {
    schema_version: u64,
    panes: Vec<Pane>,
    startup_actions: Vec<StartupAction>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct Pane {
    pane_key: String,
    workflow_role: String,
    #[serde(default)]
    slot_ref: Option<String>,
    #[serde(default)]
    slot_selector: Option<SlotSelector>,
    #[serde(default)]
    requires_capabilities: Vec<String>,
    region: String,
    worktree: Worktree,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct SlotSelector {
    requires_capabilities: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct Worktree {
    mode: String,
    #[serde(default)]
    name_template: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct StartupAction {
    action_id: String,
    kind: String,
    pane_ref: String,
}

#[derive(Serialize)]
struct FingerprintPayload<'a> {
    schema_version: u64,
    recipe_id: &'a str,
    workflow_id: Option<&'a str>,
    panes: &'a [NormalizedPane],
    startup_actions: &'a [NormalizedStartupAction],
    resolved_bindings: &'a BTreeMap<String, String>,
}

pub fn normalize_workspace_plan(
    yaml: &str,
    recipe_id: &str,
    workflow_id: Option<&str>,
    slots: &[SlotCapabilities],
) -> io::Result<NormalizedWorkspacePlan> {
    let root = parse_workspace_yaml(yaml)?;
    normalize_workspace_plan_from_value(&root, recipe_id, workflow_id, slots)
}

pub(crate) fn normalize_workspace_plan_from_value(
    root: &serde_yaml::Value,
    recipe_id: &str,
    workflow_id: Option<&str>,
    slots: &[SlotCapabilities],
) -> io::Result<NormalizedWorkspacePlan> {
    require_stable_id("recipe-id", recipe_id)?;
    if let Some(value) = workflow_id {
        require_stable_id("workflow-id", value)?;
    }

    validate_document_config_version(root)?;
    let recipes = mapping_value(root, "workspace-recipes")?
        .ok_or_else(|| invalid_input("workspace-recipes is not configured."))?;
    let recipes = recipes
        .as_mapping()
        .ok_or_else(|| invalid_data("workspace-recipes must be a mapping."))?;
    let recipe_value = recipes
        .get(&serde_yaml::Value::String(recipe_id.to_string()))
        .ok_or_else(|| invalid_input(format!("workspace recipe '{recipe_id}' was not found.")))?;
    let recipe: Recipe = serde_yaml::from_value(recipe_value.clone())
        .map_err(|_| invalid_data("invalid workspace recipe schema."))?;

    if recipe.schema_version != SCHEMA_VERSION {
        return Err(invalid_data(format!(
            "unsupported workspace recipe schema-version '{}'; supported version is {SCHEMA_VERSION}.",
            recipe.schema_version
        )));
    }
    if recipe.panes.is_empty() || recipe.panes.len() > 12 {
        return Err(invalid_data("workspace recipe must contain 1 to 12 panes."));
    }

    let slot_catalog = validate_slot_catalog(slots)?;
    let mut pane_keys = BTreeSet::new();
    let mut normalized_panes = Vec::with_capacity(recipe.panes.len());
    let mut resolved_bindings = BTreeMap::new();
    let mut resolved_slot_ids = BTreeSet::new();

    for pane in recipe.panes {
        require_stable_id("pane-key", &pane.pane_key)?;
        require_stable_id("workflow-role", &pane.workflow_role)?;
        require_stable_id("region", &pane.region)?;
        if !pane_keys.insert(pane.pane_key.clone()) {
            return Err(invalid_data(format!(
                "duplicate pane-key '{}'.",
                pane.pane_key
            )));
        }
        let mut required_capabilities = Vec::new();
        append_capabilities(&mut required_capabilities, &pane.requires_capabilities)?;
        if let Some(selector) = pane.slot_selector.as_ref() {
            if selector.requires_capabilities.is_empty() {
                return Err(invalid_data(
                    "slot-selector requires at least one capability.",
                ));
            }
            append_capabilities(&mut required_capabilities, &selector.requires_capabilities)?;
        }

        let slot_id = match (pane.slot_ref.as_deref(), pane.slot_selector.as_ref()) {
            (Some(_), Some(_)) | (None, None) => {
                return Err(invalid_data(format!(
                    "pane '{}' must set exactly one of slot-ref or slot-selector.",
                    pane.pane_key
                )));
            }
            (Some(slot_id), None) => {
                require_stable_id("slot-ref", slot_id)?;
                let slot = slot_catalog
                    .get(&canonical_slot_identity(slot_id)?)
                    .ok_or_else(|| {
                        invalid_data(format!(
                            "pane '{}' references unknown slot '{}'.",
                            pane.pane_key, slot_id
                        ))
                    })?;
                require_capabilities(slot, &required_capabilities, &pane.pane_key)?;
                slot.slot_id.clone()
            }
            (None, Some(_)) => {
                let matches: Vec<&SlotCapabilities> = slot_catalog
                    .values()
                    .copied()
                    .filter(|slot| slot_supports_all(slot, &required_capabilities))
                    .collect();
                if matches.len() != 1 {
                    return Err(invalid_data(format!(
                        "pane '{}' slot-selector matched {} slots; exactly one is required.",
                        pane.pane_key,
                        matches.len()
                    )));
                }
                matches[0].slot_id.clone()
            }
        };

        if !resolved_slot_ids.insert(canonical_slot_identity(&slot_id)?) {
            return Err(invalid_data(
                "workspace recipe panes must resolve to distinct slot IDs.",
            ));
        }
        let worktree = normalize_worktree(&pane.worktree, workflow_id)?;
        resolved_bindings.insert(pane.pane_key.clone(), slot_id.clone());
        normalized_panes.push(NormalizedPane {
            pane_key: pane.pane_key,
            workflow_role: pane.workflow_role,
            slot_id,
            required_capabilities,
            region: pane.region,
            worktree,
        });
    }

    let application_layout = build_application_layout(&normalized_panes);
    let mut action_ids = BTreeSet::new();
    let mut normalized_actions = Vec::with_capacity(recipe.startup_actions.len());
    let mut managed_action_counts = BTreeMap::<String, usize>::new();
    let mut ready_action_counts = BTreeMap::<String, usize>::new();
    let mut ready_phase_started = false;
    for action in recipe.startup_actions {
        require_stable_id("action-id", &action.action_id)?;
        require_stable_id("pane-ref", &action.pane_ref)?;
        if !action_ids.insert(action.action_id.clone()) {
            return Err(invalid_data(format!(
                "duplicate action-id '{}'.",
                action.action_id
            )));
        }
        if !pane_keys.contains(&action.pane_ref) {
            return Err(invalid_data(format!(
                "startup action '{}' references unknown pane '{}'.",
                action.action_id, action.pane_ref
            )));
        }
        if !matches!(
            action.kind.as_str(),
            "ensure-managed-worktree" | "ensure-slot-ready"
        ) {
            return Err(invalid_data("unknown startup action kind."));
        }
        let target_pane = normalized_panes
            .iter()
            .find(|pane| pane.pane_key == action.pane_ref)
            .ok_or_else(|| invalid_data("startup action references unknown pane."))?;
        if action.kind == "ensure-managed-worktree" && target_pane.worktree.mode != "managed" {
            return Err(invalid_data(
                "ensure-managed-worktree requires a managed target pane.",
            ));
        }
        if action.kind == "ensure-managed-worktree" {
            if ready_phase_started {
                return Err(invalid_data(
                    "ensure-managed-worktree actions must precede all ensure-slot-ready actions.",
                ));
            }
            *managed_action_counts
                .entry(action.pane_ref.clone())
                .or_default() += 1;
        } else {
            ready_phase_started = true;
            *ready_action_counts
                .entry(action.pane_ref.clone())
                .or_default() += 1;
        }
        normalized_actions.push(NormalizedStartupAction {
            action_id: action.action_id,
            kind: action.kind,
            pane_ref: action.pane_ref,
        });
    }
    for pane in &normalized_panes {
        if ready_action_counts
            .get(&pane.pane_key)
            .copied()
            .unwrap_or(0)
            != 1
        {
            return Err(invalid_data(
                "every pane must have exactly one ensure-slot-ready action.",
            ));
        }
        let managed_count = managed_action_counts
            .get(&pane.pane_key)
            .copied()
            .unwrap_or(0);
        if pane.worktree.mode == "managed" {
            if managed_count != 1 {
                return Err(invalid_data(
                    "every managed pane must have exactly one ensure-managed-worktree action.",
                ));
            }
        } else if managed_count != 0 {
            return Err(invalid_data(
                "read-only-reference panes must not have ensure-managed-worktree actions.",
            ));
        }
    }

    let fingerprint_payload = FingerprintPayload {
        schema_version: SCHEMA_VERSION,
        recipe_id,
        workflow_id,
        panes: &normalized_panes,
        startup_actions: &normalized_actions,
        resolved_bindings: &resolved_bindings,
    };
    let fingerprint_bytes = serde_json::to_vec(&fingerprint_payload).map_err(|error| {
        invalid_data(format!(
            "failed to serialize workspace fingerprint input: {error}"
        ))
    })?;
    let config_fingerprint = format!("sha256:{:x}", Sha256::digest(fingerprint_bytes));

    Ok(NormalizedWorkspacePlan {
        schema_version: SCHEMA_VERSION,
        config_fingerprint,
        recipe_id: recipe_id.to_string(),
        workflow_id: workflow_id.map(str::to_string),
        application_layout,
        panes: normalized_panes,
        startup_actions: normalized_actions,
        resolved_bindings,
    })
}

fn build_application_layout(panes: &[NormalizedPane]) -> NormalizedApplicationLayout {
    let mut columns: Vec<NormalizedApplicationColumn> = Vec::new();
    for pane in panes {
        let application_pane = NormalizedApplicationPane {
            pane_key: pane.pane_key.clone(),
            workflow_role: pane.workflow_role.clone(),
            slot_id: pane.slot_id.clone(),
            worktree: pane.worktree.clone(),
        };
        if let Some(column) = columns
            .iter_mut()
            .find(|column| column.region == pane.region)
        {
            column.panes.push(application_pane);
        } else {
            columns.push(NormalizedApplicationColumn {
                region: pane.region.clone(),
                panes: vec![application_pane],
            });
        }
    }
    NormalizedApplicationLayout {
        schema_version: SCHEMA_VERSION,
        columns,
    }
}

fn validate_document_config_version(root: &serde_yaml::Value) -> io::Result<()> {
    let mapping = root
        .as_mapping()
        .ok_or_else(|| invalid_data(".winsmux.yaml must be a mapping."))?;
    let canonical = mapping.get(&serde_yaml::Value::String("config-version".to_string()));
    let legacy = mapping.get(&serde_yaml::Value::String("config_version".to_string()));

    if canonical.is_some() && legacy.is_some() {
        return Err(invalid_data("ambiguous document config-version."));
    }
    let Some(value) = canonical.or(legacy) else {
        return Ok(());
    };
    let is_supported = match value {
        serde_yaml::Value::Number(number) => number.as_i64() == Some(DOCUMENT_CONFIG_VERSION),
        serde_yaml::Value::String(text) => {
            text.trim().parse::<i64>().ok() == Some(DOCUMENT_CONFIG_VERSION)
        }
        _ => false,
    };
    if !is_supported {
        return Err(invalid_data("invalid document config-version."));
    }
    Ok(())
}

fn mapping_value<'a>(
    root: &'a serde_yaml::Value,
    key: &str,
) -> io::Result<Option<&'a serde_yaml::Value>> {
    let mapping = root
        .as_mapping()
        .ok_or_else(|| invalid_data(".winsmux.yaml must be a mapping."))?;
    Ok(mapping.get(&serde_yaml::Value::String(key.to_string())))
}

fn validate_slot_catalog(
    slots: &[SlotCapabilities],
) -> io::Result<BTreeMap<String, &SlotCapabilities>> {
    let mut catalog = BTreeMap::new();
    for slot in slots {
        let canonical_id = canonical_slot_identity(&slot.slot_id)?;
        if catalog.insert(canonical_id, slot).is_some() {
            return Err(invalid_data(format!(
                "duplicate effective slot-id '{}'.",
                slot.slot_id
            )));
        }
    }
    Ok(catalog)
}

fn canonical_slot_identity(value: &str) -> io::Result<String> {
    let canonical = value.trim().to_ascii_lowercase();
    require_stable_id("slot-id", &canonical)?;
    Ok(canonical)
}

fn append_capabilities(target: &mut Vec<String>, requested: &[String]) -> io::Result<()> {
    for capability in requested {
        if !matches!(capability.as_str(), "file-edit" | "review") {
            return Err(invalid_data("unknown workspace capability."));
        }
        if !target.contains(capability) {
            target.push(capability.clone());
        }
    }
    Ok(())
}

fn require_capabilities(
    slot: &SlotCapabilities,
    required: &[String],
    pane_key: &str,
) -> io::Result<()> {
    if slot_supports_all(slot, required) {
        return Ok(());
    }
    Err(invalid_data(format!(
        "slot '{}' does not satisfy pane '{}' required capabilities.",
        slot.slot_id, pane_key
    )))
}

fn slot_supports_all(slot: &SlotCapabilities, required: &[String]) -> bool {
    required.iter().all(|capability| match capability.as_str() {
        "file-edit" => slot.supports_file_edit,
        "review" => slot.supports_verification && slot.supports_structured_result,
        _ => false,
    })
}

fn normalize_worktree(
    worktree: &Worktree,
    workflow_id: Option<&str>,
) -> io::Result<NormalizedWorktree> {
    match worktree.mode.as_str() {
        "managed" => {
            let template = worktree
                .name_template
                .as_deref()
                .ok_or_else(|| invalid_data("managed worktree requires name-template."))?;
            if !is_safe_worktree_name(template, true) {
                return Err(invalid_data(
                    "managed worktree name-template must resolve to a safe project-local name.",
                ));
            }
            let name = if template.contains(WORKFLOW_ID_TOKEN) {
                let workflow_id = workflow_id.ok_or_else(|| {
                    invalid_input(
                        "managed worktree name-template uses {{workflow-id}} but --workflow-id was not provided.",
                    )
                })?;
                template.replace(WORKFLOW_ID_TOKEN, workflow_id)
            } else {
                template.to_string()
            };
            if !is_safe_worktree_name(&name, false) {
                return Err(invalid_data(
                    "managed worktree name-template must resolve to a safe project-local name.",
                ));
            }
            reject_synthetic_credential(&name)?;
            Ok(NormalizedWorktree {
                mode: worktree.mode.clone(),
                name: Some(name),
            })
        }
        "read-only-reference" => {
            if worktree.name_template.is_some() {
                return Err(invalid_data(
                    "read-only-reference worktree must not set name-template.",
                ));
            }
            Ok(NormalizedWorktree {
                mode: worktree.mode.clone(),
                name: None,
            })
        }
        _ => Err(invalid_data("unknown worktree mode.")),
    }
}

fn require_stable_id(label: &str, value: &str) -> io::Result<()> {
    if !is_stable_id(value) {
        return Err(invalid_data(format!(
            "{label} must be a non-empty stable ASCII identifier."
        )));
    }
    reject_synthetic_credential(value)
}

fn is_stable_id(value: &str) -> bool {
    let mut parts = value.split('-');
    let Some(first) = parts.next() else {
        return false;
    };
    if first.is_empty()
        || !first
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase())
        || !first
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        return false;
    }
    parts.all(|part| {
        !part.is_empty()
            && part
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    })
}

fn is_safe_worktree_name(value: &str, is_template: bool) -> bool {
    if value.len() > WINDOWS_MAX_COMPONENT_LENGTH {
        return false;
    }

    let normalized = if is_template {
        value.replace(WORKFLOW_ID_TOKEN, "workflow-id")
    } else {
        value.to_string()
    };
    let mut bytes = normalized.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    (first.is_ascii_lowercase() || first.is_ascii_digit())
        && !normalized.contains("..")
        && !normalized.ends_with('.')
        && !is_windows_reserved_path_name(&normalized)
        && bytes.all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn is_windows_reserved_path_name(value: &str) -> bool {
    let base_name = value.split('.').next().unwrap_or_default();
    WINDOWS_RESERVED_PATH_NAMES
        .iter()
        .any(|reserved| base_name.eq_ignore_ascii_case(reserved))
}

fn reject_synthetic_credential(value: &str) -> io::Result<()> {
    let bytes = value.as_bytes();
    let contains_credential = bytes.windows(3).enumerate().any(|(index, prefix)| {
        prefix == b"sk-"
            && bytes[index + 3..]
                .iter()
                .take_while(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'_' | b'-')
                })
                .count()
                >= 20
    });
    if contains_credential {
        Err(invalid_data(
            "workspace recipe output must not contain credential-like material.",
        ))
    } else {
        Ok(())
    }
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
