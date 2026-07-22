use rowan::ast::AstNode;
use serde::Deserialize;
use serde_yaml::{Mapping as SemanticMapping, Value as SemanticValue};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Read, Write};
use std::str::FromStr;
use yaml_edit::{Mapping as CstMapping, YamlFile, YamlNode};

const MAX_STDIN_BYTES: u64 = 4 * 1024 * 1024;
const GENERIC_ERROR: &str = "project settings render failed.";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RenderRequest {
    original_yaml: String,
    desired_settings: serde_json::Map<String, serde_json::Value>,
    owned_keys: Vec<String>,
    nested_contract: NestedContractRequest,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NestedContractRequest {
    agent_slots: KeyedSequenceContractRequest,
    roles: MappingValuesContractRequest,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyedSequenceContractRequest {
    identity_key: String,
    owned_keys: Vec<String>,
    aliases: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MappingValuesContractRequest {
    owned_keys: Vec<String>,
}

struct NestedContract {
    agent_slots: KeyPolicy,
    agent_slot_identity: String,
    roles: KeyPolicy,
}

struct KeyPolicy {
    owned: BTreeSet<String>,
    aliases: BTreeMap<String, String>,
}

struct AgentSlotPairing<'a> {
    original_mappings: Vec<&'a SemanticMapping>,
    desired_mappings: Vec<&'a SemanticMapping>,
    original_ids: Vec<Option<&'a str>>,
    desired_to_original: Vec<Option<usize>>,
}

struct RoleEntry<'a> {
    name: &'a str,
    mapping: &'a SemanticMapping,
}

struct RolePairing<'a> {
    original_entries: Vec<RoleEntry<'a>>,
    desired_entries: Vec<RoleEntry<'a>>,
    desired_to_original: Vec<Option<usize>>,
}

#[derive(Clone, Copy)]
enum RootRenderMode {
    Blank,
    EmptyMapping,
    NonEmptyMapping,
}

struct ParsedDocument {
    source: String,
    semantic: SemanticValue,
    cst: YamlFile,
    explicit_keys: Vec<SemanticValue>,
    root_mode: RootRenderMode,
}

#[derive(Clone, Debug)]
struct RootEntryRange {
    key: String,
    entry_start: usize,
    entry_end: usize,
    key_start: usize,
    value_start: usize,
    value_end: usize,
}

#[derive(Debug)]
struct TextEdit {
    start: usize,
    end: usize,
    replacement: String,
}

pub(crate) fn run(args: &[String]) -> io::Result<()> {
    let rendered = render_from_stdin(args).map_err(|_| generic_error())?;
    io::stdout()
        .lock()
        .write_all(rendered.as_bytes())
        .map_err(|_| generic_error())
}

fn render_from_stdin(args: &[String]) -> Result<String, ()> {
    if !args.is_empty() {
        return Err(());
    }

    let mut input = Vec::new();
    io::stdin()
        .take(MAX_STDIN_BYTES + 1)
        .read_to_end(&mut input)
        .map_err(|_| ())?;
    if input.len() as u64 > MAX_STDIN_BYTES {
        return Err(());
    }

    let request: RenderRequest = serde_json::from_slice(&input).map_err(|_| ())?;
    render(request)
}

fn render(request: RenderRequest) -> Result<String, ()> {
    let RenderRequest {
        original_yaml,
        desired_settings,
        owned_keys,
        nested_contract,
    } = request;
    let nested_contract = NestedContract::new(nested_contract)?;
    let owned = normalize_owned_keys(&owned_keys)?;
    let original = parse_document(&original_yaml, true)?;
    let canonical_output = matches!(
        original.root_mode,
        RootRenderMode::Blank | RootRenderMode::EmptyMapping
    )
    .then(|| canonical_block_document(&desired_settings))
    .transpose()?;
    let desired_explicit = desired_settings
        .keys()
        .map(|key| SemanticValue::String(key.clone()))
        .collect::<Vec<_>>();
    let desired_semantic =
        serde_yaml::to_value(serde_json::Value::Object(desired_settings)).map_err(|_| ())?;

    let original_explicit = explicit_owned_keys(&original.explicit_keys, &owned)?;
    let desired_explicit = explicit_owned_keys(&desired_explicit, &owned)?;
    if desired_explicit.len()
        != desired_semantic
            .as_mapping()
            .map(SemanticMapping::len)
            .ok_or(())?
    {
        return Err(());
    }

    let original_semantic = merged_mapping(&original.semantic)?;
    let desired_semantic = merged_mapping(&desired_semantic)?;
    let original_owned = owned_projection(&original_semantic, &owned)?;
    let desired_owned = owned_projection(&desired_semantic, &owned)?;
    let agent_slot_pairing = agent_slot_pairing(
        original_owned.get("agent_slots"),
        desired_owned.get("agent_slots"),
        &nested_contract,
    )?;
    let role_pairing = role_pairing(original_owned.get("roles"), desired_owned.get("roles"))?;
    let expected_owned = merged_owned_projection(
        &original_owned,
        &desired_owned,
        &nested_contract,
        agent_slot_pairing.as_ref(),
        role_pairing.as_ref(),
    )?;

    // An owned field inherited through YAML merge syntax has no unambiguous CST
    // entry to replace or remove. Refuse it instead of silently shadowing it.
    if original_owned.keys().ne(original_explicit.keys()) {
        return Err(());
    }
    if desired_owned.keys().ne(desired_explicit.keys()) {
        return Err(());
    }

    let mapping = original.cst.document().ok_or(())?.as_mapping().ok_or(())?;
    let result_is_empty =
        expected_owned.is_empty() && unknown_projection(&original_semantic, &owned).is_empty();
    let mut output = match original.root_mode {
        RootRenderMode::Blank => canonical_output.ok_or(())?,
        RootRenderMode::EmptyMapping => {
            let canonical = canonical_output.ok_or(())?;
            if canonical == "{}\n" {
                original.source
            } else {
                replace_root_mapping(&original.source, &mapping, &canonical)?
            }
        }
        RootRenderMode::NonEmptyMapping if result_is_empty => {
            empty_root_mapping_preserving_trivia(&original.source, &mapping)?
        }
        RootRenderMode::NonEmptyMapping => {
            let edits = build_edit_plan(
                &original.source,
                &mapping,
                &original_explicit,
                &desired_explicit,
                &original_owned,
                &desired_owned,
                &expected_owned,
                &nested_contract,
                agent_slot_pairing.as_ref(),
                role_pairing.as_ref(),
            )?;
            apply_edit_plan(original.source, edits)?
        }
    };
    if !output.ends_with('\n') {
        output.push('\n');
    }

    verify_output(&original_semantic, &expected_owned, &owned, &output)?;
    Ok(output)
}

fn generic_error() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, GENERIC_ERROR)
}

fn normalize_owned_keys(keys: &[String]) -> Result<BTreeSet<String>, ()> {
    let mut normalized = BTreeSet::new();
    for key in keys {
        if key.is_empty() || !normalized.insert(normalize_alias(key)) {
            return Err(());
        }
    }
    Ok(normalized)
}

fn normalize_alias(key: &str) -> String {
    key.replace('-', "_").to_ascii_lowercase()
}

impl KeyPolicy {
    fn new(keys: Vec<String>, aliases: BTreeMap<String, String>) -> Result<Self, ()> {
        let mut owned = BTreeSet::new();
        for key in keys {
            let key = normalize_alias(&key);
            if key.is_empty() || !owned.insert(key) {
                return Err(());
            }
        }
        let mut normalized_aliases = BTreeMap::new();
        for (alias, target) in aliases {
            let alias = normalize_alias(&alias);
            let target = normalize_alias(&target);
            if alias.is_empty()
                || alias == target
                || !owned.contains(&target)
                || normalized_aliases.insert(alias, target).is_some()
            {
                return Err(());
            }
        }
        Ok(Self {
            owned,
            aliases: normalized_aliases,
        })
    }

    fn normalize(&self, key: &str) -> String {
        let key = normalize_alias(key);
        self.aliases.get(&key).cloned().unwrap_or(key)
    }
}

impl NestedContract {
    fn new(request: NestedContractRequest) -> Result<Self, ()> {
        let agent_slots =
            KeyPolicy::new(request.agent_slots.owned_keys, request.agent_slots.aliases)?;
        let agent_slot_identity = agent_slots.normalize(&request.agent_slots.identity_key);
        if !agent_slots.owned.contains(&agent_slot_identity) {
            return Err(());
        }
        let roles = KeyPolicy::new(request.roles.owned_keys, BTreeMap::new())?;
        Ok(Self {
            agent_slots,
            agent_slot_identity,
            roles,
        })
    }
}

fn parse_document(source: &str, blank_as_mapping: bool) -> Result<ParsedDocument, ()> {
    let lexical_blank = source.trim().is_empty();
    if lexical_blank && !blank_as_mapping {
        return Err(());
    }
    let source = if lexical_blank {
        "{}\n".to_string()
    } else {
        source.to_string()
    };

    let documents = serde_yaml::Deserializer::from_str(&source)
        .map(SemanticValue::deserialize)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| ())?;
    if documents.len() != 1 || !documents[0].is_mapping() {
        return Err(());
    }
    let semantic_empty = documents[0]
        .as_mapping()
        .is_some_and(SemanticMapping::is_empty);

    let cst = YamlFile::from_str(&source).map_err(|_| ())?;
    let cst_documents = cst.documents().collect::<Vec<_>>();
    if cst_documents.len() != 1 {
        return Err(());
    }
    let mapping = cst_documents[0].as_mapping().ok_or(())?;
    let explicit_keys = cst_mapping_keys(&mapping)?;
    reject_duplicate_keys(&explicit_keys)?;
    let root_mode = if lexical_blank {
        RootRenderMode::Blank
    } else if semantic_empty {
        RootRenderMode::EmptyMapping
    } else {
        RootRenderMode::NonEmptyMapping
    };

    Ok(ParsedDocument {
        source,
        semantic: documents.into_iter().next().ok_or(())?,
        cst,
        explicit_keys,
        root_mode,
    })
}

fn cst_mapping_keys(mapping: &CstMapping) -> Result<Vec<SemanticValue>, ()> {
    mapping
        .entries()
        .map(|entry| {
            let key = entry.key_node().ok_or(())?.to_string();
            serde_yaml::from_str::<SemanticValue>(&key).map_err(|_| ())
        })
        .collect()
}

fn reject_duplicate_keys(keys: &[SemanticValue]) -> Result<(), ()> {
    for (index, key) in keys.iter().enumerate() {
        if keys[..index].iter().any(|previous| previous == key) {
            return Err(());
        }
    }
    Ok(())
}

fn explicit_owned_keys(
    keys: &[SemanticValue],
    owned: &BTreeSet<String>,
) -> Result<BTreeMap<String, String>, ()> {
    let mut result = BTreeMap::new();
    for key in keys {
        let Some(key) = key.as_str() else {
            continue;
        };
        let normalized = normalize_alias(key);
        if owned.contains(&normalized) && result.insert(normalized, key.to_string()).is_some() {
            return Err(());
        }
    }
    Ok(result)
}

fn merged_mapping(value: &SemanticValue) -> Result<SemanticMapping, ()> {
    let mut merged = value.clone();
    merged.apply_merge().map_err(|_| ())?;
    match merged {
        SemanticValue::Mapping(mapping) => Ok(mapping),
        _ => Err(()),
    }
}

fn owned_projection(
    mapping: &SemanticMapping,
    owned: &BTreeSet<String>,
) -> Result<BTreeMap<String, SemanticValue>, ()> {
    let mut result = BTreeMap::new();
    for (key, value) in mapping {
        let Some(key) = key.as_str() else {
            continue;
        };
        let normalized = normalize_alias(key);
        if owned.contains(&normalized) && result.insert(normalized, value.clone()).is_some() {
            return Err(());
        }
    }
    Ok(result)
}

fn unknown_projection(mapping: &SemanticMapping, owned: &BTreeSet<String>) -> SemanticMapping {
    mapping
        .iter()
        .filter(|(key, _)| {
            key.as_str()
                .map(|key| !owned.contains(&normalize_alias(key)))
                .unwrap_or(true)
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

fn mapping_value<'a>(
    mapping: &'a SemanticMapping,
    normalized_key: &str,
    policy: &KeyPolicy,
) -> Result<Option<&'a SemanticValue>, ()> {
    let mut found = None;
    for (key, value) in mapping {
        let Some(key) = key.as_str() else {
            continue;
        };
        if policy.normalize(key) == normalized_key {
            if found.replace(value).is_some() {
                return Err(());
            }
        }
    }
    Ok(found)
}

fn merged_known_mapping(
    original: &SemanticMapping,
    desired: &SemanticMapping,
    policy: &KeyPolicy,
) -> Result<SemanticMapping, ()> {
    let mut result = SemanticMapping::new();
    let mut original_known = BTreeMap::new();
    for (key, value) in original {
        let normalized = key.as_str().map(|key| policy.normalize(key));
        if normalized
            .as_ref()
            .is_some_and(|key| policy.owned.contains(key))
        {
            if original_known
                .insert(normalized.ok_or(())?, key.clone())
                .is_some()
            {
                return Err(());
            }
        } else {
            result.insert(key.clone(), value.clone());
        }
    }

    let mut desired_known = BTreeSet::new();
    for (key, value) in desired {
        let key_text = key.as_str().ok_or(())?;
        let normalized = policy.normalize(key_text);
        if !policy.owned.contains(&normalized) || !desired_known.insert(normalized) {
            return Err(());
        }
        let output_key = original_known
            .get(&policy.normalize(key_text))
            .unwrap_or(key);
        result.insert(output_key.clone(), value.clone());
    }
    Ok(result)
}

fn slot_id<'a>(
    mapping: &'a SemanticMapping,
    contract: &NestedContract,
) -> Result<Option<&'a str>, ()> {
    Ok(mapping_value(
        mapping,
        &contract.agent_slot_identity,
        &contract.agent_slots,
    )?
    .and_then(SemanticValue::as_str))
}

fn normalize_identity(identity: &str) -> String {
    identity.trim().to_ascii_lowercase()
}

fn agent_slot_pairing<'a>(
    original: Option<&'a SemanticValue>,
    desired: Option<&'a SemanticValue>,
    contract: &NestedContract,
) -> Result<Option<AgentSlotPairing<'a>>, ()> {
    let Some(desired) = desired else {
        return Ok(None);
    };
    let original = match original {
        Some(original) => original.as_sequence().ok_or(())?.as_slice(),
        None => &[],
    };
    let desired = desired.as_sequence().ok_or(())?;
    let original_mappings = original
        .iter()
        .map(|value| value.as_mapping().ok_or(()))
        .collect::<Result<Vec<_>, _>>()?;
    let desired_mappings = desired
        .iter()
        .map(|value| value.as_mapping().ok_or(()))
        .collect::<Result<Vec<_>, _>>()?;

    let mut original_by_id = BTreeMap::new();
    let mut original_ids = Vec::with_capacity(original_mappings.len());
    for (index, mapping) in original_mappings.iter().enumerate() {
        let id = slot_id(mapping, contract)?;
        if let Some(id) = id {
            let normalized_id = normalize_identity(id);
            if normalized_id.is_empty() {
                return Err(());
            }
            if original_by_id.insert(normalized_id, index).is_some() {
                return Err(());
            }
        }
        original_ids.push(id);
    }

    let mut desired_ids = BTreeSet::new();
    let mut desired_to_original = Vec::with_capacity(desired_mappings.len());
    for mapping in &desired_mappings {
        let id = slot_id(mapping, contract)?.ok_or(())?;
        let normalized_id = normalize_identity(id);
        if normalized_id.is_empty() || !desired_ids.insert(normalized_id.clone()) {
            return Err(());
        }
        desired_to_original.push(original_by_id.get(&normalized_id).copied());
    }

    Ok(Some(AgentSlotPairing {
        original_mappings,
        desired_mappings,
        original_ids,
        desired_to_original,
    }))
}

fn effective_desired_slot(
    pairing: &AgentSlotPairing<'_>,
    desired_index: usize,
    contract: &NestedContract,
) -> Result<SemanticMapping, ()> {
    let desired = pairing.desired_mappings.get(desired_index).ok_or(())?;
    let mut effective = (*desired).clone();
    let Some(original_index) = pairing
        .desired_to_original
        .get(desired_index)
        .copied()
        .flatten()
    else {
        return Ok(effective);
    };
    let original_id = pairing
        .original_ids
        .get(original_index)
        .copied()
        .flatten()
        .ok_or(())?;
    let mut replaced = false;
    for (key, value) in &mut effective {
        let key = key.as_str().ok_or(())?;
        if contract.agent_slots.normalize(key) == contract.agent_slot_identity {
            if replaced {
                return Err(());
            }
            *value = SemanticValue::String(original_id.to_string());
            replaced = true;
        }
    }
    if !replaced {
        return Err(());
    }
    Ok(effective)
}

fn merged_agent_slots(
    pairing: &AgentSlotPairing<'_>,
    contract: &NestedContract,
) -> Result<SemanticValue, ()> {
    let mut merged = Vec::with_capacity(pairing.desired_mappings.len());
    for desired_index in 0..pairing.desired_mappings.len() {
        let desired = effective_desired_slot(pairing, desired_index, contract)?;
        let value = match pairing.desired_to_original[desired_index] {
            Some(original_index) => SemanticValue::Mapping(merged_known_mapping(
                pairing
                    .original_mappings
                    .get(original_index)
                    .copied()
                    .ok_or(())?,
                &desired,
                &contract.agent_slots,
            )?),
            None => {
                merged_known_mapping(&SemanticMapping::new(), &desired, &contract.agent_slots)?;
                SemanticValue::Mapping(desired)
            }
        };
        merged.push(value);
    }
    Ok(SemanticValue::Sequence(merged))
}

fn role_entries(value: &SemanticValue) -> Result<Vec<RoleEntry<'_>>, ()> {
    value
        .as_mapping()
        .ok_or(())?
        .iter()
        .map(|(name, value)| {
            let name = name.as_str().ok_or(())?;
            let mapping = value.as_mapping().ok_or(())?;
            Ok(RoleEntry { name, mapping })
        })
        .collect()
}

fn role_pairing<'a>(
    original: Option<&'a SemanticValue>,
    desired: Option<&'a SemanticValue>,
) -> Result<Option<RolePairing<'a>>, ()> {
    let Some(desired) = desired else {
        return Ok(None);
    };
    let original_entries = match original {
        Some(original) => role_entries(original)?,
        None => Vec::new(),
    };
    let desired_entries = role_entries(desired)?;
    let mut original_by_id = BTreeMap::new();
    for (index, entry) in original_entries.iter().enumerate() {
        let identity = normalize_identity(entry.name);
        if identity.is_empty() || original_by_id.insert(identity, index).is_some() {
            return Err(());
        }
    }
    let mut desired_ids = BTreeSet::new();
    let mut desired_to_original = Vec::with_capacity(desired_entries.len());
    for entry in &desired_entries {
        let identity = normalize_identity(entry.name);
        if identity.is_empty() || !desired_ids.insert(identity.clone()) {
            return Err(());
        }
        desired_to_original.push(original_by_id.get(&identity).copied());
    }
    Ok(Some(RolePairing {
        original_entries,
        desired_entries,
        desired_to_original,
    }))
}

fn merged_roles(pairing: &RolePairing<'_>, contract: &NestedContract) -> Result<SemanticValue, ()> {
    let mut merged = SemanticMapping::new();
    for (desired_index, desired) in pairing.desired_entries.iter().enumerate() {
        let (name, value) = match pairing.desired_to_original[desired_index] {
            Some(original_index) => {
                let original = pairing.original_entries.get(original_index).ok_or(())?;
                (
                    original.name,
                    SemanticValue::Mapping(merged_known_mapping(
                        original.mapping,
                        desired.mapping,
                        &contract.roles,
                    )?),
                )
            }
            None => {
                merged_known_mapping(&SemanticMapping::new(), desired.mapping, &contract.roles)?;
                (
                    desired.name,
                    SemanticValue::Mapping(desired.mapping.clone()),
                )
            }
        };
        merged.insert(SemanticValue::String(name.to_string()), value);
    }
    Ok(SemanticValue::Mapping(merged))
}

fn merged_owned_projection(
    original: &BTreeMap<String, SemanticValue>,
    desired: &BTreeMap<String, SemanticValue>,
    contract: &NestedContract,
    agent_slot_pairing: Option<&AgentSlotPairing<'_>>,
    role_pairing: Option<&RolePairing<'_>>,
) -> Result<BTreeMap<String, SemanticValue>, ()> {
    desired
        .iter()
        .map(|(key, value)| {
            let merged = match (key.as_str(), original.get(key)) {
                ("agent_slots", _) => merged_agent_slots(agent_slot_pairing.ok_or(())?, contract)?,
                ("roles", _) => merged_roles(role_pairing.ok_or(())?, contract)?,
                _ => value.clone(),
            };
            Ok((key.clone(), merged))
        })
        .collect()
}

fn semantic_value_as_json(value: &SemanticValue) -> Result<String, ()> {
    let json = serde_json::to_string(value).map_err(|_| ())?;
    let round_trip = serde_yaml::from_str::<SemanticValue>(&json).map_err(|_| ())?;
    if &round_trip != value {
        return Err(());
    }
    Ok(json)
}

fn semantic_value_as_json_value(value: &SemanticValue) -> Result<serde_json::Value, ()> {
    let json = serde_json::to_value(value).map_err(|_| ())?;
    let round_trip = serde_yaml::to_value(&json).map_err(|_| ())?;
    if &round_trip != value {
        return Err(());
    }
    Ok(json)
}

fn canonical_block_document(
    mapping: &serde_json::Map<String, serde_json::Value>,
) -> Result<String, ()> {
    // serde_yaml renders dynamic JSON maps as flow collections. New settings
    // must instead match ConvertFrom-BridgeManualYaml: two-space sequence
    // entries and four-space properties inside agent_slots.
    if mapping.is_empty() {
        return Ok("{}\n".to_string());
    }
    let mut output = String::new();
    write_block_mapping(mapping, 0, &mut output)?;
    Ok(output)
}

fn write_block_mapping(
    mapping: &serde_json::Map<String, serde_json::Value>,
    indentation: usize,
    output: &mut String,
) -> Result<(), ()> {
    for (key, value) in mapping {
        write_indentation(output, indentation);
        write_block_mapping_entry(key, value, indentation + 2, output)?;
    }
    Ok(())
}

fn write_block_mapping_entry(
    key: &str,
    value: &serde_json::Value,
    child_indentation: usize,
    output: &mut String,
) -> Result<(), ()> {
    output.push_str(&canonical_yaml_key(key)?);
    match value {
        serde_json::Value::Array(_) | serde_json::Value::Object(_) => {
            output.push_str(":\n");
            write_block_container(value, child_indentation, output)
        }
        _ => {
            output.push_str(": ");
            output.push_str(&serde_json::to_string(value).map_err(|_| ())?);
            output.push('\n');
            Ok(())
        }
    }
}

fn write_block_container(
    value: &serde_json::Value,
    indentation: usize,
    output: &mut String,
) -> Result<(), ()> {
    match value {
        serde_json::Value::Object(mapping) if mapping.is_empty() => {
            write_indentation(output, indentation);
            output.push_str("{}\n");
            Ok(())
        }
        serde_json::Value::Object(mapping) => write_block_mapping(mapping, indentation, output),
        serde_json::Value::Array(values) if values.is_empty() => {
            write_indentation(output, indentation);
            output.push_str("[]\n");
            Ok(())
        }
        serde_json::Value::Array(values) => {
            for value in values {
                write_indentation(output, indentation);
                match value {
                    serde_json::Value::Object(mapping) if !mapping.is_empty() => {
                        output.push_str("- ");
                        let mut entries = mapping.iter();
                        let (key, value) = entries.next().ok_or(())?;
                        write_block_mapping_entry(key, value, indentation + 4, output)?;
                        for (key, value) in entries {
                            write_indentation(output, indentation + 2);
                            write_block_mapping_entry(key, value, indentation + 4, output)?;
                        }
                    }
                    serde_json::Value::Array(_) | serde_json::Value::Object(_) => {
                        output.push_str("-\n");
                        write_block_container(value, indentation + 2, output)?;
                    }
                    _ => {
                        output.push_str("- ");
                        output.push_str(&serde_json::to_string(value).map_err(|_| ())?);
                        output.push('\n');
                    }
                }
            }
            Ok(())
        }
        _ => Err(()),
    }
}

fn write_indentation(output: &mut String, indentation: usize) {
    output.extend(std::iter::repeat(' ').take(indentation));
}

fn canonical_yaml_key(key: &str) -> Result<String, ()> {
    let mut characters = key.chars();
    let plain = characters
        .next()
        .is_some_and(|ch| ch.is_ascii_alphabetic() || ch == '_')
        && characters.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
        && !matches!(key.to_ascii_lowercase().as_str(), "null" | "true" | "false");
    if plain {
        Ok(key.to_string())
    } else {
        serde_json::to_string(key).map_err(|_| ())
    }
}

fn mapping_prefers_block_fragments(source: &str, mapping: &CstMapping) -> Result<bool, ()> {
    if !mapping.is_flow_style() {
        return Ok(true);
    }
    if mapping.entries().next().is_some() {
        return Ok(false);
    }
    let start = mapping.byte_range().start as usize;
    let line_start = source[..start]
        .rfind(['\r', '\n'])
        .map_or(0, |index| index + 1);
    Ok(source
        .get(line_start..start)
        .ok_or(())?
        .bytes()
        .all(|byte| matches!(byte, b' ' | b'\t')))
}

fn node_prefers_block_fragments(source: &str, node: &YamlNode) -> Result<bool, ()> {
    match node {
        YamlNode::Mapping(mapping) => mapping_prefers_block_fragments(source, mapping),
        YamlNode::Sequence(sequence) if !sequence.is_flow_style() => Ok(true),
        YamlNode::Sequence(sequence) if sequence.is_empty() => {
            let start = sequence.byte_range().start as usize;
            let line_start = source[..start]
                .rfind(['\r', '\n'])
                .map_or(0, |index| index + 1);
            Ok(source
                .get(line_start..start)
                .ok_or(())?
                .bytes()
                .all(|byte| matches!(byte, b' ' | b'\t')))
        }
        _ => Ok(false),
    }
}

fn canonical_block_mapping_entry_fragment(
    key: &str,
    value: &SemanticValue,
) -> Result<String, ()> {
    let mut output = String::new();
    let value = semantic_value_as_json_value(value)?;
    write_block_mapping_entry(key, &value, 2, &mut output)?;
    Ok(output.trim_end_matches(['\r', '\n']).to_string())
}

fn canonical_block_value_fragment(
    source: &str,
    value_start: usize,
    value: &SemanticValue,
) -> Result<String, ()> {
    let line_start = source[..value_start]
        .rfind(['\r', '\n'])
        .map_or(0, |index| index + 1);
    let indentation = source.get(line_start..value_start).ok_or(())?;
    if !indentation
        .bytes()
        .all(|byte| matches!(byte, b' ' | b'\t'))
    {
        return Err(());
    }
    let value = semantic_value_as_json_value(value)?;
    let mut output = String::new();
    write_block_container(&value, indentation.len(), &mut output)?;
    let output = output.strip_prefix(indentation).ok_or(())?;
    Ok(output.trim_end_matches(['\r', '\n']).to_string())
}

fn style_aware_mapping_entry_fragment(
    source: &str,
    mapping: &CstMapping,
    key: &str,
    value: &SemanticValue,
) -> Result<String, ()> {
    if mapping_prefers_block_fragments(source, mapping)? {
        canonical_block_mapping_entry_fragment(key, value)
    } else {
        Ok(format!(
            "{}: {}",
            serde_json::to_string(key).map_err(|_| ())?,
            semantic_value_as_json(value)?
        ))
    }
}

fn style_aware_value_fragment(
    source: &str,
    prefer_block: bool,
    value_start: usize,
    value: &SemanticValue,
) -> Result<String, ()> {
    if prefer_block
        && matches!(
            value,
            SemanticValue::Mapping(_) | SemanticValue::Sequence(_)
        )
    {
        canonical_block_value_fragment(source, value_start, value)
    } else {
        semantic_value_as_json(value)
    }
}

fn mapping_value_node(mapping: &CstMapping, key: &str) -> Result<YamlNode, ()> {
    mapping
        .entries()
        .find_map(|entry| {
            let key_node = entry.key_node()?;
            let parsed = serde_yaml::from_str::<SemanticValue>(&key_node.to_string()).ok()?;
            (parsed.as_str() == Some(key))
                .then(|| entry.value_node())
                .flatten()
        })
        .ok_or(())
}

fn explicit_known_keys(
    mapping: &CstMapping,
    policy: &KeyPolicy,
) -> Result<BTreeMap<String, String>, ()> {
    reject_duplicate_keys(&cst_mapping_keys(mapping)?)?;
    let mut result = BTreeMap::new();
    for key in cst_mapping_keys(mapping)? {
        let Some(key) = key.as_str() else {
            continue;
        };
        let normalized = policy.normalize(key);
        if policy.owned.contains(&normalized)
            && result.insert(normalized, key.to_string()).is_some()
        {
            return Err(());
        }
    }
    Ok(result)
}

fn desired_known_keys(
    desired: &SemanticMapping,
    policy: &KeyPolicy,
) -> Result<(BTreeMap<String, String>, BTreeMap<String, SemanticValue>), ()> {
    let mut keys = BTreeMap::new();
    let mut values = BTreeMap::new();
    for (key, value) in desired {
        let key = key.as_str().ok_or(())?;
        let normalized = policy.normalize(key);
        if !policy.owned.contains(&normalized)
            || keys.insert(normalized.clone(), key.to_string()).is_some()
        {
            return Err(());
        }
        values.insert(normalized, value.clone());
    }
    Ok((keys, values))
}

fn semantic_known_keys(
    mapping: &SemanticMapping,
    policy: &KeyPolicy,
) -> Result<BTreeSet<String>, ()> {
    let mut result = BTreeSet::new();
    for key in mapping.keys() {
        let Some(key) = key.as_str() else {
            continue;
        };
        let normalized = policy.normalize(key);
        if policy.owned.contains(&normalized) && !result.insert(normalized) {
            return Err(());
        }
    }
    Ok(result)
}

fn build_flat_mapping_edit_plan(
    source: &str,
    mapping: &CstMapping,
    original: &SemanticMapping,
    desired: &SemanticMapping,
    policy: &KeyPolicy,
) -> Result<Vec<TextEdit>, ()> {
    let entries = root_entry_ranges(mapping)?;
    let original_keys = explicit_known_keys(mapping, policy)?;
    let semantic_keys = semantic_known_keys(original, policy)?;
    let explicit_keys = original_keys.keys().cloned().collect::<BTreeSet<_>>();
    if semantic_keys != explicit_keys {
        return Err(());
    }
    let (desired_keys, desired_values) = desired_known_keys(desired, policy)?;
    let mut edits = Vec::new();

    for (normalized, original_key) in &original_keys {
        let entry = entries
            .iter()
            .find(|entry| entry.key == *original_key)
            .ok_or(())?;
        if let Some(value) = desired_values.get(normalized) {
            let original_value_node = mapping_value_node(mapping, original_key)?;
            let original_value = source.get(entry.value_start..entry.value_end).ok_or(())?;
            let value_without_line_endings = original_value.trim_end_matches(['\r', '\n']);
            let trailing_line_endings = &original_value[value_without_line_endings.len()..];
            edits.push(TextEdit {
                start: entry.value_start,
                end: entry.value_end,
                replacement: format!(
                    "{}{}",
                    style_aware_value_fragment(
                        source,
                        node_prefers_block_fragments(source, &original_value_node)?,
                        entry.value_start,
                        value,
                    )?,
                    trailing_line_endings
                ),
            });
        } else {
            let (start, end) = if mapping.is_flow_style() {
                flow_deletion_range(source, mapping, &entries, entry)?
            } else {
                block_deletion_range(source, mapping, entry)?
            };
            edits.push(TextEdit {
                start,
                end,
                replacement: String::new(),
            });
        }
    }

    let additions = desired_keys
        .iter()
        .filter(|(normalized, _)| !original_keys.contains_key(*normalized))
        .map(|(normalized, key)| {
            style_aware_mapping_entry_fragment(
                source,
                mapping,
                key,
                desired_values.get(normalized).ok_or(())?,
            )
        })
        .collect::<Result<Vec<_>, ()>>()?;
    if !additions.is_empty() {
        let removed = original_keys
            .keys()
            .filter(|key| !desired_keys.contains_key(*key))
            .count();
        edits.push(addition_edit(
            source,
            mapping,
            entries.len().checked_sub(removed).ok_or(())?,
            &additions,
        )?);
    }

    let edits = coalesce_deletion_edits(mapping, &entries, edits)?;
    validate_edit_plan(source, mapping, &edits)?;
    Ok(edits)
}

fn mapping_has_unknown_keys(mapping: &SemanticMapping, policy: &KeyPolicy) -> bool {
    mapping.keys().any(|key| {
        key.as_str()
            .map(|key| policy.normalize(key))
            .is_none_or(|key| !policy.owned.contains(&key))
    })
}

fn value_replacement_with_original_line_endings(
    source: &str,
    start: usize,
    end: usize,
    replacement: &str,
) -> Result<String, ()> {
    let original_value = source.get(start..end).ok_or(())?;
    let original_without_line_endings = original_value.trim_end_matches(['\r', '\n']);
    let trailing_line_endings = &original_value[original_without_line_endings.len()..];
    let replacement = replacement.trim_end_matches(['\r', '\n']);
    Ok(format!("{replacement}{trailing_line_endings}"))
}

fn build_agent_slots_edit_plan(
    source: &str,
    cst: &YamlNode,
    pairing: &AgentSlotPairing<'_>,
    contract: &NestedContract,
) -> Result<Option<Vec<TextEdit>>, ()> {
    let has_unknown = pairing
        .original_mappings
        .iter()
        .any(|mapping| mapping_has_unknown_keys(mapping, &contract.agent_slots));
    let preserves_topology = pairing.original_mappings.len() == pairing.desired_mappings.len()
        && pairing.original_ids.iter().all(Option::is_some)
        && pairing
            .desired_to_original
            .iter()
            .enumerate()
            .all(|(desired_index, original_index)| *original_index == Some(desired_index));
    if !preserves_topology {
        return if has_unknown { Err(()) } else { Ok(None) };
    }

    let desired_mappings = (0..pairing.desired_mappings.len())
        .map(|desired_index| effective_desired_slot(pairing, desired_index, contract))
        .collect::<Result<Vec<_>, ()>>()?;

    let sequence = match cst {
        YamlNode::Sequence(sequence) => sequence,
        _ => return Err(()),
    };
    if sequence.len() != pairing.original_mappings.len() {
        return Err(());
    }
    let mut edits = Vec::new();
    for (index, (original, desired)) in pairing
        .original_mappings
        .iter()
        .zip(desired_mappings.iter())
        .enumerate()
    {
        let mapping = match sequence.get(index).ok_or(())? {
            YamlNode::Mapping(mapping) => mapping,
            _ => return Err(()),
        };
        edits.extend(build_flat_mapping_edit_plan(
            source,
            &mapping,
            original,
            desired,
            &contract.agent_slots,
        )?);
    }
    Ok(Some(edits))
}

fn build_roles_edit_plan(
    source: &str,
    role_key: &str,
    cst: &YamlNode,
    pairing: &RolePairing<'_>,
    contract: &NestedContract,
) -> Result<TextEdit, ()> {
    let mapping = match cst {
        YamlNode::Mapping(mapping) => mapping,
        _ => return Err(()),
    };
    reject_duplicate_keys(&cst_mapping_keys(mapping)?)?;
    let entries = root_entry_ranges(mapping)?;
    if entries.len() != pairing.original_entries.len()
        || entries
            .iter()
            .zip(&pairing.original_entries)
            .any(|(entry, original)| entry.key != original.name)
    {
        return Err(());
    }
    let original_range = yaml_node_range(cst)?;
    let original_start = original_range.start as usize;
    let original_end = original_range.end as usize;
    source.get(original_start..original_end).ok_or(())?;

    let desired_for_original = pairing
        .desired_to_original
        .iter()
        .enumerate()
        .filter_map(|(desired_index, original_index)| {
            original_index.map(|original_index| (original_index, desired_index))
        })
        .collect::<BTreeMap<_, _>>();

    // Mapping style belongs to the original roles transaction, not to an
    // intermediate value produced while applying it. When every original
    // block role is removed, build the complete replacement in that original
    // block style instead of reparsing a temporary `{}` as authored flow YAML.
    if !mapping.is_flow_style() && desired_for_original.is_empty() {
        let merged = merged_roles(pairing, contract)?;
        let replacement = canonical_block_value_fragment(source, original_start, &merged)?;
        return Ok(TextEdit {
            start: original_start,
            end: original_end,
            replacement: value_replacement_with_original_line_endings(
                source,
                original_start,
                original_end,
                &replacement,
            )?,
        });
    }

    // Phase 1 owns only descendant edits for matched roles. Applying these
    // before changing sibling topology keeps every later coordinate tied to a
    // freshly parsed CST rather than to the original mapping.
    let mut working_source = source.to_string();
    let mut descendant_edits = Vec::new();
    for (original_index, (entry, original)) in
        entries.iter().zip(&pairing.original_entries).enumerate()
    {
        if let Some(desired_index) = desired_for_original.get(&original_index) {
            let desired = pairing.desired_entries.get(*desired_index).ok_or(())?;
            let merged = merged_known_mapping(original.mapping, desired.mapping, &contract.roles)?;
            if merged.is_empty() {
                descendant_edits.push(TextEdit {
                    start: entry.value_start,
                    end: entry.value_end,
                    replacement: value_replacement_with_original_line_endings(
                        source,
                        entry.value_start,
                        entry.value_end,
                        "{}",
                    )?,
                });
            } else {
                let role_mapping = match mapping_value_node(mapping, &entry.key)? {
                    YamlNode::Mapping(role_mapping) => role_mapping,
                    _ => return Err(()),
                };
                descendant_edits.extend(build_flat_mapping_edit_plan(
                    source,
                    &role_mapping,
                    original.mapping,
                    desired.mapping,
                    &contract.roles,
                )?);
            }
        }
    }
    validate_edit_plan(source, mapping, &descendant_edits)?;
    working_source = apply_edit_plan(working_source, descendant_edits)?;

    // Phase 2 reparses the complete document and removes unmatched original
    // roles using only coordinates from that generation. If none remain, use
    // an explicit empty mapping so the intermediate document is still valid.
    let phase_two_document = parse_document(&working_source, false)?;
    let phase_two_root = phase_two_document
        .cst
        .document()
        .ok_or(())?
        .as_mapping()
        .ok_or(())?;
    let phase_two_value = mapping_value_node(&phase_two_root, role_key)?;
    let phase_two_mapping = match &phase_two_value {
        YamlNode::Mapping(mapping) => mapping,
        _ => return Err(()),
    };
    let phase_two_entries = root_entry_ranges(phase_two_mapping)?;
    if phase_two_entries.len() != pairing.original_entries.len()
        || phase_two_entries
            .iter()
            .zip(&pairing.original_entries)
            .any(|(entry, original)| entry.key != original.name)
    {
        return Err(());
    }

    let mut removal_edits = Vec::new();
    if desired_for_original.is_empty() {
        let range = yaml_node_range(&phase_two_value)?;
        removal_edits.push(TextEdit {
            start: range.start as usize,
            end: range.end as usize,
            replacement: value_replacement_with_original_line_endings(
                &working_source,
                range.start as usize,
                range.end as usize,
                "{}",
            )?,
        });
    } else {
        for (original_index, entry) in phase_two_entries.iter().enumerate() {
            if desired_for_original.contains_key(&original_index) {
                continue;
            }
            let (start, end) = if phase_two_mapping.is_flow_style() {
                flow_deletion_range(
                    &working_source,
                    phase_two_mapping,
                    &phase_two_entries,
                    entry,
                )?
            } else {
                block_deletion_range(&working_source, phase_two_mapping, entry)?
            };
            removal_edits.push(TextEdit {
                start,
                end,
                replacement: String::new(),
            });
        }
        removal_edits =
            coalesce_deletion_edits(phase_two_mapping, &phase_two_entries, removal_edits)?;
    }
    validate_edit_plan(&working_source, phase_two_mapping, &removal_edits)?;
    working_source = apply_edit_plan(working_source, removal_edits)?;

    // Phase 3 reparses again before adding new sibling roles. This deliberately
    // does not coalesce an insertion with a descendant replacement at a shared
    // offset; the parent mapping alone owns this edit.
    let phase_three_document = parse_document(&working_source, false)?;
    let phase_three_root = phase_three_document
        .cst
        .document()
        .ok_or(())?
        .as_mapping()
        .ok_or(())?;
    let phase_three_value = mapping_value_node(&phase_three_root, role_key)?;
    let phase_three_mapping = match &phase_three_value {
        YamlNode::Mapping(mapping) => mapping,
        _ => return Err(()),
    };
    let phase_three_entries = root_entry_ranges(phase_three_mapping)?;
    let additions = pairing
        .desired_entries
        .iter()
        .zip(&pairing.desired_to_original)
        .filter(|(_, original_index)| original_index.is_none())
        .map(|(desired, _)| {
            style_aware_mapping_entry_fragment(
                &working_source,
                phase_three_mapping,
                desired.name,
                &SemanticValue::Mapping(desired.mapping.clone()),
            )
        })
        .collect::<Result<Vec<_>, ()>>()?;
    if !additions.is_empty() {
        let addition = addition_edit(
            &working_source,
            phase_three_mapping,
            phase_three_entries.len(),
            &additions,
        )?;
        validate_edit_plan(
            &working_source,
            phase_three_mapping,
            std::slice::from_ref(&addition),
        )?;
        working_source = apply_edit_plan(working_source, vec![addition])?;
    }

    let final_document = parse_document(&working_source, false)?;
    let final_root = final_document
        .cst
        .document()
        .ok_or(())?
        .as_mapping()
        .ok_or(())?;
    let final_value = mapping_value_node(&final_root, role_key)?;
    let final_range = yaml_node_range(&final_value)?;
    let final_roles = final_document
        .semantic
        .as_mapping()
        .and_then(|mapping| mapping.get(SemanticValue::String(role_key.to_string())))
        .ok_or(())?;
    if final_roles != &merged_roles(pairing, contract)? {
        return Err(());
    }
    let replacement = working_source
        .get(final_range.start as usize..final_range.end as usize)
        .ok_or(())?;
    Ok(TextEdit {
        start: original_start,
        end: original_end,
        replacement: value_replacement_with_original_line_endings(
            source,
            original_start,
            original_end,
            replacement,
        )?,
    })
}

fn build_edit_plan(
    source: &str,
    mapping: &CstMapping,
    original: &BTreeMap<String, String>,
    desired: &BTreeMap<String, String>,
    original_values: &BTreeMap<String, SemanticValue>,
    desired_values: &BTreeMap<String, SemanticValue>,
    rendered_values: &BTreeMap<String, SemanticValue>,
    nested_contract: &NestedContract,
    agent_slot_pairing: Option<&AgentSlotPairing<'_>>,
    role_pairing: Option<&RolePairing<'_>>,
) -> Result<Vec<TextEdit>, ()> {
    let entries = root_entry_ranges(mapping)?;
    let mut edits = Vec::new();

    for (normalized, original_key) in original {
        let entry = entries
            .iter()
            .find(|entry| entry.key == *original_key)
            .ok_or(())?;
        if desired_values.contains_key(normalized) {
            original_values.get(normalized).ok_or(())?;
            let cst_value = mapping_value_node(mapping, original_key)?;
            let value_prefers_block = node_prefers_block_fragments(source, &cst_value)?;
            let recursive_edits = match normalized.as_str() {
                "agent_slots" => build_agent_slots_edit_plan(
                    source,
                    &cst_value,
                    agent_slot_pairing.ok_or(())?,
                    nested_contract,
                )?,
                "roles" => build_roles_edit_plan(
                    source,
                    original_key,
                    &cst_value,
                    role_pairing.ok_or(())?,
                    nested_contract,
                )
                .map(|edit| vec![edit])
                .map(Some)?,
                _ => None,
            };
            if let Some(recursive_edits) = recursive_edits {
                edits.extend(recursive_edits);
                continue;
            }
            let original_value = source.get(entry.value_start..entry.value_end).ok_or(())?;
            let value_without_line_endings = original_value.trim_end_matches(['\r', '\n']);
            let trailing_line_endings = &original_value[value_without_line_endings.len()..];
            let rendered_value = rendered_values.get(normalized).ok_or(())?;
            edits.push(TextEdit {
                start: entry.value_start,
                end: entry.value_end,
                replacement: format!(
                    "{}{}",
                    style_aware_value_fragment(
                        source,
                        value_prefers_block,
                        entry.value_start,
                        rendered_value,
                    )?,
                    trailing_line_endings
                ),
            });
        } else if mapping.is_flow_style() {
            let (start, end) = flow_deletion_range(source, mapping, &entries, entry)?;
            edits.push(TextEdit {
                start,
                end,
                replacement: String::new(),
            });
        } else {
            let (start, end) = block_deletion_range(source, mapping, entry)?;
            edits.push(TextEdit {
                start,
                end,
                replacement: String::new(),
            });
        }
    }

    let mut additions = Vec::new();
    for (normalized, desired_key) in desired {
        if !original.contains_key(normalized) {
            let value = rendered_values.get(normalized).ok_or(())?;
            additions.push(style_aware_mapping_entry_fragment(
                source,
                mapping,
                desired_key,
                value,
            )?);
        }
    }
    if !additions.is_empty() {
        let removed_entry_count = original
            .keys()
            .filter(|key| !desired.contains_key(*key))
            .count();
        let remaining_entry_count = entries.len().checked_sub(removed_entry_count).ok_or(())?;
        edits.push(addition_edit(
            source,
            mapping,
            remaining_entry_count,
            &additions,
        )?);
    }

    let edits = coalesce_deletion_edits(mapping, &entries, edits)?;
    validate_edit_plan(source, mapping, &edits)?;
    Ok(edits)
}

fn coalesce_deletion_edits(
    mapping: &CstMapping,
    entries: &[RootEntryRange],
    edits: Vec<TextEdit>,
) -> Result<Vec<TextEdit>, ()> {
    let (mut deletions, mut preserved): (Vec<_>, Vec<_>) = edits
        .into_iter()
        .partition(|edit| edit.replacement.is_empty() && edit.start < edit.end);
    deletions.sort_unstable_by_key(|edit| (edit.start, edit.end));

    let mut coalesced: Vec<TextEdit> = Vec::new();
    for deletion in deletions {
        if let Some(previous) = coalesced.last_mut() {
            if deletion.start <= previous.end {
                previous.end = previous.end.max(deletion.end);
                continue;
            }
        }
        coalesced.push(deletion);
    }

    if mapping.is_flow_style() {
        let close = mapping.byte_range().end.checked_sub(1).ok_or(())? as usize;
        for deletion in &coalesced {
            if deletion.end != close {
                continue;
            }
            let Some(first_deleted) = entries
                .iter()
                .position(|entry| entry.key_start == deletion.start)
            else {
                continue;
            };
            if first_deleted == 0 {
                continue;
            }
            if let Some(addition) = preserved.iter_mut().find(|edit| {
                edit.start == close && edit.end == close && edit.replacement.starts_with(", ")
            }) {
                addition.replacement.replace_range(..2, "");
            }
        }
    }

    preserved.extend(coalesced);
    Ok(preserved)
}

fn root_entry_ranges(mapping: &CstMapping) -> Result<Vec<RootEntryRange>, ()> {
    mapping
        .entries()
        .map(|entry| {
            let syntax_range = AstNode::syntax(&entry).text_range();
            let key_node = entry.key_node().ok_or(())?;
            let key = serde_yaml::from_str::<SemanticValue>(&key_node.to_string())
                .map_err(|_| ())?
                .as_str()
                .ok_or(())?
                .to_string();
            let key_range = yaml_node_range(&key_node)?;
            let value_range = yaml_node_range(&entry.value_node().ok_or(())?)?;
            Ok(RootEntryRange {
                key,
                entry_start: u32::from(syntax_range.start()) as usize,
                entry_end: u32::from(syntax_range.end()) as usize,
                key_start: key_range.start as usize,
                value_start: value_range.start as usize,
                value_end: value_range.end as usize,
            })
        })
        .collect()
}

fn yaml_node_range(node: &YamlNode) -> Result<yaml_edit::TextPosition, ()> {
    match node {
        YamlNode::Scalar(scalar) => Ok(scalar.byte_range()),
        YamlNode::Mapping(mapping) => Ok(mapping.byte_range()),
        YamlNode::Sequence(sequence) => Ok(sequence.byte_range()),
        YamlNode::Alias(value) => Ok(yaml_edit::advanced::text_range_to_position(
            value.syntax().text_range(),
        )),
        YamlNode::TaggedNode(value) => Ok(yaml_edit::advanced::text_range_to_position(
            value.syntax().text_range(),
        )),
    }
}

fn block_deletion_range(
    source: &str,
    mapping: &CstMapping,
    entry: &RootEntryRange,
) -> Result<(usize, usize), ()> {
    let range = mapping.byte_range();
    if entry.entry_start < range.start as usize
        || entry.entry_end > range.end as usize
        || entry.entry_start >= entry.entry_end
        || source.get(entry.entry_start..entry.entry_end).is_none()
    {
        return Err(());
    }
    let line_start = source[..entry.entry_start]
        .rfind(['\r', '\n'])
        .map_or(0, |index| index + 1);
    let prefix = source.get(line_start..entry.entry_start).ok_or(())?;
    let start = if prefix.bytes().all(|byte| matches!(byte, b' ' | b'\t')) {
        line_start
    } else {
        entry.entry_start
    };
    Ok((start, entry.entry_end))
}

fn flow_deletion_range(
    source: &str,
    mapping: &CstMapping,
    entries: &[RootEntryRange],
    target: &RootEntryRange,
) -> Result<(usize, usize), ()> {
    let index = entries
        .iter()
        .position(|entry| entry.key_start == target.key_start)
        .ok_or(())?;
    if let Some(next) = entries.get(index + 1) {
        let separator = source.get(target.value_end..next.key_start).ok_or(())?;
        let comma_end = flow_separator_comma_end(separator)?;
        return Ok((target.key_start, target.value_end + comma_end));
    }
    let close = mapping.byte_range().end.checked_sub(1).ok_or(())? as usize;
    if !source
        .get(target.value_end..close)
        .ok_or(())?
        .bytes()
        .all(|byte| byte.is_ascii_whitespace())
    {
        return Err(());
    }
    Ok((target.key_start, close))
}

fn flow_separator_comma_end(separator: &str) -> Result<usize, ()> {
    let comma = separator.find(',').ok_or(())?;
    if !separator[..comma]
        .bytes()
        .all(|byte| byte.is_ascii_whitespace())
    {
        return Err(());
    }
    let mut in_comment = false;
    let mut has_comment = false;
    for byte in separator[comma + 1..].bytes() {
        if in_comment {
            if matches!(byte, b'\r' | b'\n') {
                in_comment = false;
            }
        } else if byte == b'#' {
            in_comment = true;
            has_comment = true;
        } else if !byte.is_ascii_whitespace() {
            return Err(());
        }
    }
    Ok(if has_comment {
        comma + 1
    } else {
        separator.len()
    })
}

fn addition_edit(
    source: &str,
    mapping: &CstMapping,
    remaining_entry_count: usize,
    additions: &[String],
) -> Result<TextEdit, ()> {
    let range = mapping.byte_range();
    if mapping.is_flow_style() {
        let close = range.end.checked_sub(1).ok_or(())? as usize;
        if source.as_bytes().get(close) != Some(&b'}') {
            return Err(());
        }
        let separator = if remaining_entry_count == 0 {
            ""
        } else if last_significant_flow_char(source.get(range.start as usize..close).ok_or(())?)
            == Some(',')
        {
            " "
        } else {
            ", "
        };
        return Ok(TextEdit {
            start: close,
            end: close,
            replacement: format!("{separator}{}", additions.join(", ")),
        });
    }

    let end = range.end as usize;
    let entries = root_entry_ranges(mapping)?;
    let mut sequence_item_indentation = None;
    let indentation = entries
        .iter()
        .find_map(|entry| {
            let line_start = source[..entry.key_start]
                .rfind(['\r', '\n'])
                .map_or(0, |index| index + 1);
            let prefix = source.get(line_start..entry.key_start)?;
            if prefix.bytes().all(|byte| matches!(byte, b' ' | b'\t')) {
                return Some(Ok(prefix.to_string()));
            }
            let dash = prefix.find('-')?;
            if prefix[..dash]
                .bytes()
                .all(|byte| matches!(byte, b' ' | b'\t'))
                && !prefix[dash + 1..].is_empty()
                && prefix[dash + 1..]
                    .bytes()
                    .all(|byte| matches!(byte, b' ' | b'\t'))
            {
                let mut derived = prefix.to_string();
                derived.replace_range(dash..=dash, " ");
                sequence_item_indentation = Some(derived);
            }
            None
        })
        .transpose()?
        .or(sequence_item_indentation)
        .unwrap_or_default();
    let prefix = if end == 0 || source.as_bytes().get(end - 1) == Some(&b'\n') {
        ""
    } else {
        "\n"
    };
    let additions = additions
        .iter()
        .map(|addition| {
            addition
                .split('\n')
                .map(|line| format!("{indentation}{line}"))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n");
    Ok(TextEdit {
        start: end,
        end,
        replacement: format!("{prefix}{additions}\n"),
    })
}

fn validate_edit_plan(source: &str, mapping: &CstMapping, edits: &[TextEdit]) -> Result<(), ()> {
    let range = mapping.byte_range();
    let start = range.start as usize;
    let end = range.end as usize;
    for edit in edits {
        if edit.start < start || edit.end > end || edit.start > edit.end {
            return Err(());
        }
    }
    let mut ranges = edits
        .iter()
        .map(|edit| (edit.start, edit.end))
        .collect::<Vec<_>>();
    ranges.sort_unstable();
    for pair in ranges.windows(2) {
        if pair[0].1 > pair[1].0 {
            return Err(());
        }
    }
    if end > source.len() {
        return Err(());
    }
    Ok(())
}

fn replace_root_mapping(source: &str, mapping: &CstMapping, canonical: &str) -> Result<String, ()> {
    let range = mapping.byte_range();
    let start = range.start as usize;
    let end = range.end as usize;
    let prefix = source.get(..start).ok_or(())?;
    let suffix = source.get(end..).ok_or(())?;
    if start >= end {
        return Err(());
    }

    let mut replacement = canonical.to_string();
    if (suffix.starts_with('\n') || suffix.starts_with("\r\n")) && replacement.ends_with('\n') {
        replacement.pop();
    }
    let line_start = prefix.rfind(['\r', '\n']).map_or(0, |index| index + 1);
    if !prefix[line_start..].trim().is_empty() {
        let line_ending = if suffix.starts_with("\r\n") {
            "\r\n"
        } else {
            "\n"
        };
        replacement.insert_str(0, line_ending);
    }

    let mut output = source.to_string();
    output.replace_range(start..end, &replacement);
    Ok(output)
}

fn empty_root_mapping_preserving_trivia(
    source: &str,
    mapping: &CstMapping,
) -> Result<String, ()> {
    let entries = root_entry_ranges(mapping)?;
    if entries.is_empty() {
        return Err(());
    }

    let edits = if mapping.is_flow_style() {
        let edits = entries
            .iter()
            .map(|entry| {
                let (start, end) = flow_deletion_range(source, mapping, &entries, entry)?;
                Ok(TextEdit {
                    start,
                    end,
                    replacement: String::new(),
                })
            })
            .collect::<Result<Vec<_>, ()>>()?;
        coalesce_deletion_edits(mapping, &entries, edits)?
    } else {
        entries
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                let prefix = source
                    .get(entry.entry_start..entry.key_start)
                    .ok_or(())?;
                if !prefix
                    .bytes()
                    .all(|byte| matches!(byte, b' ' | b'\t'))
                {
                    return Err(());
                }
                Ok(TextEdit {
                    start: entry.key_start,
                    end: entry.value_end,
                    replacement: if index == 0 {
                        "{}".to_string()
                    } else {
                        String::new()
                    },
                })
            })
            .collect::<Result<Vec<_>, ()>>()?
    };
    validate_edit_plan(source, mapping, &edits)?;
    apply_edit_plan(source.to_string(), edits)
}

fn apply_edit_plan(mut source: String, mut edits: Vec<TextEdit>) -> Result<String, ()> {
    edits.sort_unstable_by(|left, right| {
        right
            .start
            .cmp(&left.start)
            .then_with(|| right.end.cmp(&left.end))
            .then_with(|| {
                // Nested block mappings that end at EOF share the same insertion
                // offset as their ancestors. Apply the shallower insertion first
                // so the deeper insertion is subsequently placed before it.
                insertion_indentation(&left.replacement)
                    .cmp(&insertion_indentation(&right.replacement))
            })
    });
    for edit in edits {
        source.get(edit.start..edit.end).ok_or(())?;
        source.replace_range(edit.start..edit.end, &edit.replacement);
    }
    Ok(source)
}

fn insertion_indentation(replacement: &str) -> usize {
    replacement
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(|line| {
            line.bytes()
                .take_while(|byte| matches!(byte, b' ' | b'\t'))
                .count()
        })
        .unwrap_or(usize::MAX)
}

fn last_significant_flow_char(text: &str) -> Option<char> {
    let mut last = None;
    let mut chars = text.chars().peekable();
    let mut single_quoted = false;
    let mut double_quoted = false;
    let mut escaped = false;
    let mut comment = false;

    while let Some(ch) = chars.next() {
        if comment {
            if ch == '\n' || ch == '\r' {
                comment = false;
            }
            continue;
        }
        if double_quoted {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                double_quoted = false;
            }
            last = Some(ch);
            continue;
        }
        if single_quoted {
            if ch == '\'' {
                if chars.peek() == Some(&'\'') {
                    last = Some(ch);
                    chars.next();
                    continue;
                }
                single_quoted = false;
            }
            last = Some(ch);
            continue;
        }

        match ch {
            '#' => comment = true,
            '"' => {
                double_quoted = true;
                last = Some(ch);
            }
            '\'' => {
                single_quoted = true;
                last = Some(ch);
            }
            ch if !ch.is_whitespace() => last = Some(ch),
            _ => {}
        }
    }
    last
}

fn verify_output(
    original: &SemanticMapping,
    desired_owned: &BTreeMap<String, SemanticValue>,
    owned: &BTreeSet<String>,
    output: &str,
) -> Result<(), ()> {
    let output = parse_document(output, false)?;
    let output_explicit = explicit_owned_keys(&output.explicit_keys, owned)?;
    let output_semantic = merged_mapping(&output.semantic)?;
    let output_owned = owned_projection(&output_semantic, owned)?;
    if output_owned != *desired_owned || output_explicit.keys().ne(desired_owned.keys()) {
        return Err(());
    }
    if unknown_projection(original, owned) != unknown_projection(&output_semantic, owned) {
        return Err(());
    }
    Ok(())
}
