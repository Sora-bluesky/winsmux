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
    desired_yaml: String,
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

struct ParsedDocument {
    source: String,
    semantic: SemanticValue,
    cst: YamlFile,
    explicit_keys: Vec<SemanticValue>,
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
    let nested_contract = NestedContract::new(request.nested_contract)?;
    let owned = normalize_owned_keys(&request.owned_keys)?;
    let original = parse_document(&request.original_yaml, true)?;
    let desired = parse_document(&request.desired_yaml, false)?;

    let original_explicit = explicit_owned_keys(&original.explicit_keys, &owned)?;
    let desired_explicit = explicit_owned_keys(&desired.explicit_keys, &owned)?;
    if desired_explicit.len() != desired.explicit_keys.len() {
        return Err(());
    }

    let original_semantic = merged_mapping(&original.semantic)?;
    let desired_semantic = merged_mapping(&desired.semantic)?;
    let original_owned = owned_projection(&original_semantic, &owned)?;
    let desired_owned = owned_projection(&desired_semantic, &owned)?;
    let expected_owned =
        merged_owned_projection(&original_owned, &desired_owned, &nested_contract)?;

    // An owned field inherited through YAML merge syntax has no unambiguous CST
    // entry to replace or remove. Refuse it instead of silently shadowing it.
    if original_owned.keys().ne(original_explicit.keys()) {
        return Err(());
    }
    if desired_owned.keys().ne(desired_explicit.keys()) {
        return Err(());
    }

    let mapping = original.cst.document().ok_or(())?.as_mapping().ok_or(())?;
    let edits = build_edit_plan(
        &original.source,
        &mapping,
        &original_explicit,
        &desired_explicit,
        &original_owned,
        &desired_owned,
        &nested_contract,
    )?;
    let mut output = apply_edit_plan(original.source, edits)?;
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
    key.replace('-', "_")
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
    let source = if blank_as_mapping && source.trim().is_empty() {
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

    let cst = YamlFile::from_str(&source).map_err(|_| ())?;
    let cst_documents = cst.documents().collect::<Vec<_>>();
    if cst_documents.len() != 1 {
        return Err(());
    }
    let mapping = cst_documents[0].as_mapping().ok_or(())?;
    let explicit_keys = cst_mapping_keys(&mapping)?;
    reject_duplicate_keys(&explicit_keys)?;

    Ok(ParsedDocument {
        source,
        semantic: documents.into_iter().next().ok_or(())?,
        cst,
        explicit_keys,
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

fn merged_agent_slots(
    original: &SemanticValue,
    desired: &SemanticValue,
    contract: &NestedContract,
) -> Result<SemanticValue, ()> {
    let original = original.as_sequence().ok_or(())?;
    let desired = desired.as_sequence().ok_or(())?;
    let has_unknown = original.iter().try_fold(false, |found, value| {
        let mapping = value.as_mapping().ok_or(())?;
        Ok::<_, ()>(found || mapping_has_unknown_keys(mapping, &contract.agent_slots))
    })?;
    let mut original_by_id = BTreeMap::new();
    for value in original {
        let mapping = value.as_mapping().ok_or(())?;
        let Some(id) = slot_id(mapping, contract)? else {
            if mapping.keys().any(|key| {
                key.as_str()
                    .map(|key| contract.agent_slots.normalize(key))
                    .is_none_or(|key| !contract.agent_slots.owned.contains(&key))
            }) {
                return Err(());
            }
            continue;
        };
        if original_by_id.insert(id.to_string(), mapping).is_some() {
            return Err(());
        }
    }

    let mut desired_ids = BTreeSet::new();
    let mut merged = Vec::with_capacity(desired.len());
    for value in desired {
        let mapping = value.as_mapping().ok_or(())?;
        let id = slot_id(mapping, contract)?.ok_or(())?;
        if !desired_ids.insert(id.to_string()) {
            return Err(());
        }
        let value = match original_by_id.get(id) {
            Some(original) => SemanticValue::Mapping(merged_known_mapping(
                original,
                mapping,
                &contract.agent_slots,
            )?),
            None => {
                merged_known_mapping(&SemanticMapping::new(), mapping, &contract.agent_slots)?;
                value.clone()
            }
        };
        merged.push(value);
    }
    if has_unknown {
        Ok(SemanticValue::Sequence(merged))
    } else {
        Ok(SemanticValue::Sequence(desired.clone()))
    }
}

fn merged_roles(
    original: &SemanticValue,
    desired: &SemanticValue,
    contract: &NestedContract,
) -> Result<SemanticValue, ()> {
    let original = original.as_mapping().ok_or(())?;
    let desired = desired.as_mapping().ok_or(())?;
    let mut merged = SemanticMapping::new();
    for (role, desired_value) in desired {
        let role_name = role.as_str().ok_or(())?;
        let desired_mapping = desired_value.as_mapping().ok_or(())?;
        let value = match original.get(SemanticValue::String(role_name.to_string())) {
            Some(original_value) => {
                let original_mapping = original_value.as_mapping().ok_or(())?;
                SemanticValue::Mapping(merged_known_mapping(
                    original_mapping,
                    desired_mapping,
                    &contract.roles,
                )?)
            }
            None => {
                merged_known_mapping(&SemanticMapping::new(), desired_mapping, &contract.roles)?;
                desired_value.clone()
            }
        };
        merged.insert(role.clone(), value);
    }
    Ok(SemanticValue::Mapping(merged))
}

fn merged_owned_projection(
    original: &BTreeMap<String, SemanticValue>,
    desired: &BTreeMap<String, SemanticValue>,
    contract: &NestedContract,
) -> Result<BTreeMap<String, SemanticValue>, ()> {
    desired
        .iter()
        .map(|(key, value)| {
            let merged = match (key.as_str(), original.get(key)) {
                ("agent_slots", Some(original)) => merged_agent_slots(original, value, contract)?,
                ("roles", Some(original)) => merged_roles(original, value, contract)?,
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
            let original_value = source.get(entry.value_start..entry.value_end).ok_or(())?;
            let value_without_line_endings = original_value.trim_end_matches(['\r', '\n']);
            let trailing_line_endings = &original_value[value_without_line_endings.len()..];
            edits.push(TextEdit {
                start: entry.value_start,
                end: entry.value_end,
                replacement: format!(
                    "{}{}",
                    semantic_value_as_json(value)?,
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
            Ok(format!(
                "{}: {}",
                serde_json::to_string(key).map_err(|_| ())?,
                semantic_value_as_json(desired_values.get(normalized).ok_or(())?)?
            ))
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

fn build_agent_slots_edit_plan(
    source: &str,
    cst: &YamlNode,
    original: &SemanticValue,
    desired: &SemanticValue,
    contract: &NestedContract,
) -> Result<Option<Vec<TextEdit>>, ()> {
    let original = original.as_sequence().ok_or(())?;
    let desired = desired.as_sequence().ok_or(())?;
    let original_mappings = original
        .iter()
        .map(|value| value.as_mapping().ok_or(()))
        .collect::<Result<Vec<_>, _>>()?;
    let has_unknown = original_mappings
        .iter()
        .any(|mapping| mapping_has_unknown_keys(mapping, &contract.agent_slots));
    if !has_unknown {
        return Ok(None);
    }

    let original_ids = original_mappings
        .iter()
        .map(|mapping| slot_id(mapping, contract)?.map(str::to_string).ok_or(()))
        .collect::<Result<Vec<_>, ()>>()?;
    let desired_mappings = desired
        .iter()
        .map(|value| value.as_mapping().ok_or(()))
        .collect::<Result<Vec<_>, _>>()?;
    let desired_ids = desired_mappings
        .iter()
        .map(|mapping| slot_id(mapping, contract)?.map(str::to_string).ok_or(()))
        .collect::<Result<Vec<_>, ()>>()?;
    if original_ids != desired_ids {
        return Err(());
    }

    let sequence = match cst {
        YamlNode::Sequence(sequence) => sequence,
        _ => return Err(()),
    };
    if sequence.len() != original_mappings.len() {
        return Err(());
    }
    let mut edits = Vec::new();
    for (index, (original, desired)) in original_mappings
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
    cst: &YamlNode,
    original: &SemanticValue,
    desired: &SemanticValue,
    contract: &NestedContract,
) -> Result<Option<Vec<TextEdit>>, ()> {
    let (original, desired, mapping) = match (original.as_mapping(), desired.as_mapping(), cst) {
        (Some(original), Some(desired), YamlNode::Mapping(mapping)) => (original, desired, mapping),
        _ => return Ok(None),
    };
    reject_duplicate_keys(&cst_mapping_keys(mapping)?)?;
    let entries = root_entry_ranges(mapping)?;
    let mut edits = Vec::new();

    for entry in &entries {
        let role = SemanticValue::String(entry.key.clone());
        if let Some(desired_value) = desired.get(&role) {
            let original_value = original.get(&role).ok_or(())?;
            match (
                mapping_value_node(mapping, &entry.key)?,
                original_value.as_mapping(),
                desired_value.as_mapping(),
            ) {
                (YamlNode::Mapping(role_mapping), Some(original), Some(desired)) => {
                    edits.extend(build_flat_mapping_edit_plan(
                        source,
                        &role_mapping,
                        original,
                        desired,
                        &contract.roles,
                    )?);
                }
                _ => {
                    edits.push(TextEdit {
                        start: entry.value_start,
                        end: entry.value_end,
                        replacement: semantic_value_as_json(desired_value)?,
                    });
                }
            }
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

    let additions = desired
        .iter()
        .filter_map(|(key, value)| {
            let key = key.as_str()?;
            (!entries.iter().any(|entry| entry.key == key)).then_some((key, value))
        })
        .map(|(key, value)| {
            Ok(format!(
                "{}: {}",
                serde_json::to_string(key).map_err(|_| ())?,
                semantic_value_as_json(value)?
            ))
        })
        .collect::<Result<Vec<_>, ()>>()?;
    if !additions.is_empty() {
        let removed = entries
            .iter()
            .filter(|entry| !desired.contains_key(SemanticValue::String(entry.key.clone())))
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
    Ok(Some(edits))
}

fn build_edit_plan(
    source: &str,
    mapping: &CstMapping,
    original: &BTreeMap<String, String>,
    desired: &BTreeMap<String, String>,
    original_values: &BTreeMap<String, SemanticValue>,
    desired_values: &BTreeMap<String, SemanticValue>,
    nested_contract: &NestedContract,
) -> Result<Vec<TextEdit>, ()> {
    let entries = root_entry_ranges(mapping)?;
    let mut edits = Vec::new();

    for (normalized, original_key) in original {
        let entry = entries
            .iter()
            .find(|entry| entry.key == *original_key)
            .ok_or(())?;
        if let Some(desired_value) = desired_values.get(normalized) {
            let original_value = original_values.get(normalized).ok_or(())?;
            let cst_value = mapping_value_node(mapping, original_key)?;
            let recursive_edits = match normalized.as_str() {
                "agent_slots" => build_agent_slots_edit_plan(
                    source,
                    &cst_value,
                    original_value,
                    desired_value,
                    nested_contract,
                )?,
                "roles" => build_roles_edit_plan(
                    source,
                    &cst_value,
                    original_value,
                    desired_value,
                    nested_contract,
                )?,
                _ => None,
            };
            if let Some(recursive_edits) = recursive_edits {
                edits.extend(recursive_edits);
                continue;
            }
            let original_value = source.get(entry.value_start..entry.value_end).ok_or(())?;
            let value_without_line_endings = original_value.trim_end_matches(['\r', '\n']);
            let trailing_line_endings = &original_value[value_without_line_endings.len()..];
            edits.push(TextEdit {
                start: entry.value_start,
                end: entry.value_end,
                replacement: format!(
                    "{}{}",
                    semantic_value_as_json(desired_value)?,
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
            let value = desired_values.get(normalized).ok_or(())?;
            additions.push(format!(
                "{}: {}",
                serde_json::to_string(desired_key).map_err(|_| ())?,
                semantic_value_as_json(value)?
            ));
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
    let additions = additions.join(&format!("\n{indentation}"));
    Ok(TextEdit {
        start: end,
        end,
        replacement: format!("{prefix}{indentation}{additions}\n"),
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
