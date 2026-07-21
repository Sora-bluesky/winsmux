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
        &desired_owned,
    )?;
    let mut output = apply_edit_plan(original.source, edits)?;
    if !output.ends_with('\n') {
        output.push('\n');
    }

    verify_output(&original_semantic, &desired_owned, &owned, &output)?;
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

fn semantic_value_as_json(value: &SemanticValue) -> Result<String, ()> {
    let json = serde_json::to_string(value).map_err(|_| ())?;
    let round_trip = serde_yaml::from_str::<SemanticValue>(&json).map_err(|_| ())?;
    if &round_trip != value {
        return Err(());
    }
    Ok(json)
}

fn build_edit_plan(
    source: &str,
    mapping: &CstMapping,
    original: &BTreeMap<String, String>,
    desired: &BTreeMap<String, String>,
    desired_values: &BTreeMap<String, SemanticValue>,
) -> Result<Vec<TextEdit>, ()> {
    let entries = root_entry_ranges(mapping)?;
    let mut edits = Vec::new();

    for (normalized, original_key) in original {
        let entry = entries
            .iter()
            .find(|entry| entry.key == *original_key)
            .ok_or(())?;
        if let Some(desired_value) = desired_values.get(normalized) {
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
                edit.start == close
                    && edit.end == close
                    && edit.replacement.starts_with(", ")
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
    Ok((entry.entry_start, entry.entry_end))
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
        require_flow_separator(source.get(target.value_end..next.key_start).ok_or(())?)?;
        return Ok((target.key_start, next.key_start));
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

fn require_flow_separator(separator: &str) -> Result<(), ()> {
    if separator.contains('#') || separator.trim() != "," {
        return Err(());
    }
    Ok(())
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
    let prefix = if end == 0 || source.as_bytes().get(end - 1) == Some(&b'\n') {
        ""
    } else {
        "\n"
    };
    Ok(TextEdit {
        start: end,
        end,
        replacement: format!("{prefix}{}\n", additions.join("\n")),
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
    });
    for edit in edits {
        source.get(edit.start..edit.end).ok_or(())?;
        source.replace_range(edit.start..edit.end, &edit.replacement);
    }
    Ok(source)
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
