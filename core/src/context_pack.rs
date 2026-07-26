use crate::manifest_contract::{
    canonical_public_path_key, is_context_pack_id, is_safe_public_path_identity,
    PUBLIC_REF_MAX_BYTES, PUBLIC_REPO_PATH_MAX_BYTES,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    io::{self, Read},
};

const CONTEXT_PACK_SCHEMA_VERSION: u64 = 1;
const DEFAULT_MAX_FILES: usize = 100;
const DEFAULT_MAX_BYTES: usize = 262_144;
const DEFAULT_MAX_EVIDENCE_REFS: usize = 50;
const HARD_MAX_FILES: usize = 1_000;
const HARD_MAX_BYTES: usize = 1_048_576;
const HARD_MAX_EVIDENCE_REFS: usize = 500;
const MAX_ID_BYTES: usize = 256;
const MAX_CONTEXT_PACK_INPUT_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug)]
pub(crate) struct ContextPackError;

type ContextPackResult<T> = Result<T, ContextPackError>;

#[derive(Debug)]
pub(crate) struct ContextPackCliSelection {
    pack_id: String,
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum WorkspacePlanOutput<T> {
    Legacy(T),
    WithContext(serde_json::Value),
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ContextPackProjection {
    canonical_json: String,
    digest: String,
    byte_count: usize,
    manifest_projection: ContextPackManifestProjection,
}

#[derive(Clone, Debug, Serialize)]
struct ContextPackManifestProjection {
    pack_id: String,
    schema_version: u64,
    digest: String,
    byte_count: usize,
    source_head: String,
    policy_fingerprint: String,
    limits: ContextPackLimits,
    omissions: ContextPackOmissions,
    privacy_result: &'static str,
}

#[derive(Clone, Debug, Serialize)]
struct CanonicalContextPack {
    schema_version: u64,
    pack_id: String,
    source_head: String,
    policy_fingerprint: String,
    limits: ContextPackLimits,
    groups: ContextPackGroups,
    omissions: ContextPackOmissions,
    privacy_result: &'static str,
}

#[derive(Clone, Debug, Default, Serialize)]
struct ContextPackGroups {
    code_map: Vec<CodeMapEntry>,
    changed_files: Vec<ChangedFileEntry>,
    tests: Vec<TestEntry>,
    evidence_refs: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
struct ContextPackOmissions {
    code_map: u64,
    changed_files: u64,
    tests: u64,
    evidence_refs: u64,
    omitted_by_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
struct ContextPackLimits {
    max_files: usize,
    max_bytes: usize,
    max_evidence_refs: usize,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "kebab-case")]
enum IncludeGroup {
    CodeMap,
    ChangedFiles,
    Tests,
    EvidenceRefs,
}

impl IncludeGroup {
    const ALL: [Self; 4] = [
        Self::CodeMap,
        Self::ChangedFiles,
        Self::Tests,
        Self::EvidenceRefs,
    ];
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ContextPackPolicy {
    schema_version: u64,
    include: Vec<IncludeGroup>,
    #[serde(default)]
    limits: ContextPackPolicyLimits,
    #[serde(default)]
    privacy: ContextPackPrivacy,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ContextPackPolicyLimits {
    #[serde(default = "default_max_files")]
    max_files: usize,
    #[serde(default = "default_max_bytes")]
    max_bytes: usize,
    #[serde(default = "default_max_evidence_refs")]
    max_evidence_refs: usize,
}

impl Default for ContextPackPolicyLimits {
    fn default() -> Self {
        Self {
            max_files: DEFAULT_MAX_FILES,
            max_bytes: DEFAULT_MAX_BYTES,
            max_evidence_refs: DEFAULT_MAX_EVIDENCE_REFS,
        }
    }
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ContextPackPrivacy {
    #[serde(default)]
    raw_transcript: bool,
    #[serde(default)]
    prompt_bodies: bool,
    #[serde(default)]
    secrets: bool,
    #[serde(default)]
    private_local_paths: bool,
}

#[derive(Serialize)]
struct NormalizedPolicyFingerprint {
    schema_version: u64,
    include: Vec<IncludeGroup>,
    limits: ContextPackLimits,
    privacy: ContextPackPrivacy,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextPackInput {
    schema_version: u64,
    source_head: String,
    #[serde(default)]
    code_map: Vec<CodeMapEntry>,
    #[serde(default)]
    changed_files: Vec<ChangedFileEntry>,
    #[serde(default)]
    tests: Vec<TestEntry>,
    #[serde(default)]
    evidence_refs: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CodeMapEntry {
    path: String,
    content_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ChangedFileEntry {
    path: String,
    status: ChangedFileStatus,
    content_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
enum ChangedFileStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TestEntry {
    test_id: String,
    outcome: TestOutcome,
    evidence_ref: String,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
enum TestOutcome {
    Passed,
    Failed,
    Blocked,
    NotApplicable,
}

pub(crate) fn split_cli<T>(
    args: &[&String],
    parse_legacy: impl FnOnce(&[&String]) -> io::Result<T>,
) -> io::Result<(Option<ContextPackCliSelection>, T)> {
    let mut legacy_args = Vec::with_capacity(args.len());
    let mut pack_id = None;
    let mut input = None;
    let mut index = 0;
    while index < args.len() {
        let slot = match args[index].as_str() {
            "--context-pack-id" => Some(&mut pack_id),
            "--context-pack-input" => Some(&mut input),
            value if value.starts_with("--context-pack") => {
                return Err(context_pack_rejected());
            }
            _ => None,
        };
        let Some(slot) = slot else {
            legacy_args.push(args[index]);
            index += 1;
            continue;
        };
        let Some(value) = args.get(index + 1) else {
            return Err(context_pack_rejected());
        };
        if slot.replace(value.to_string()).is_some() {
            return Err(context_pack_rejected());
        }
        index += 2;
    }
    let selection = match (pack_id, input) {
        (None, None) => None,
        (Some(pack_id), Some(input)) if input == "-" && is_context_pack_id(&pack_id) => {
            Some(ContextPackCliSelection { pack_id })
        }
        _ => return Err(context_pack_rejected()),
    };
    Ok((selection, parse_legacy(&legacy_args)?))
}

pub(crate) fn apply_cli<T: Serialize>(
    root: &serde_yaml::Value,
    selection: Option<ContextPackCliSelection>,
    payload: T,
) -> io::Result<WorkspacePlanOutput<T>> {
    let Some(selection) = selection else {
        return Ok(WorkspacePlanOutput::Legacy(payload));
    };
    let mut input = Vec::new();
    io::stdin()
        .take((MAX_CONTEXT_PACK_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|_| context_pack_rejected())?;
    if input.len() > MAX_CONTEXT_PACK_INPUT_BYTES {
        return Err(context_pack_rejected());
    }
    let context_pack = build_context_pack(root, &selection.pack_id, &input)
        .map_err(|_| context_pack_rejected())?;
    let mut output = serde_json::to_value(payload).map_err(|_| context_pack_rejected())?;
    output
        .as_object_mut()
        .ok_or_else(context_pack_rejected)?
        .insert(
            "context_pack".to_string(),
            serde_json::to_value(context_pack).map_err(|_| context_pack_rejected())?,
        );
    Ok(WorkspacePlanOutput::WithContext(output))
}

fn context_pack_rejected() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "context pack rejected.")
}

pub(crate) fn build_context_pack(
    root: &serde_yaml::Value,
    pack_id: &str,
    input_bytes: &[u8],
) -> ContextPackResult<ContextPackProjection> {
    if !is_context_pack_id(pack_id) {
        return Err(ContextPackError);
    }
    let (include, limits, policy_fingerprint) = normalize_policy(root, pack_id)?;
    let mut input: ContextPackInput =
        serde_json::from_slice(input_bytes).map_err(|_| ContextPackError)?;
    validate_input(&input)?;

    input.code_map.sort_by(|left, right| {
        (&left.path, &left.content_sha256).cmp(&(&right.path, &right.content_sha256))
    });
    input.changed_files.sort_by(|left, right| {
        (&left.path, &left.status, &left.content_sha256).cmp(&(
            &right.path,
            &right.status,
            &right.content_sha256,
        ))
    });
    input.tests.sort_by(|left, right| {
        (&left.test_id, &left.outcome, &left.evidence_ref).cmp(&(
            &right.test_id,
            &right.outcome,
            &right.evidence_ref,
        ))
    });
    input.evidence_refs.sort();

    let include = include.into_iter().collect::<BTreeSet<_>>();
    let mut groups = ContextPackGroups::default();
    let mut omissions = ContextPackOmissions::default();

    let mut remaining_files = limits.max_files;
    if include.contains(&IncludeGroup::CodeMap) {
        let keep = remaining_files.min(input.code_map.len());
        groups
            .code_map
            .extend(input.code_map.iter().take(keep).cloned());
        omissions.code_map = (input.code_map.len() - keep) as u64;
        remaining_files -= keep;
    } else {
        omissions.code_map = input.code_map.len() as u64;
    }
    if include.contains(&IncludeGroup::ChangedFiles) {
        let keep = remaining_files.min(input.changed_files.len());
        groups
            .changed_files
            .extend(input.changed_files.iter().take(keep).cloned());
        omissions.changed_files = (input.changed_files.len() - keep) as u64;
    } else {
        omissions.changed_files = input.changed_files.len() as u64;
    }

    let mut remaining_refs = limits.max_evidence_refs;
    if include.contains(&IncludeGroup::Tests) {
        let keep = remaining_refs.min(input.tests.len());
        groups.tests.extend(input.tests.iter().take(keep).cloned());
        omissions.tests = (input.tests.len() - keep) as u64;
        remaining_refs -= keep;
    } else {
        omissions.tests = input.tests.len() as u64;
    }
    if include.contains(&IncludeGroup::EvidenceRefs) {
        let keep = remaining_refs.min(input.evidence_refs.len());
        groups
            .evidence_refs
            .extend(input.evidence_refs.iter().take(keep).cloned());
        omissions.evidence_refs = (input.evidence_refs.len() - keep) as u64;
    } else {
        omissions.evidence_refs = input.evidence_refs.len() as u64;
    }

    let mut canonical = CanonicalContextPack {
        schema_version: CONTEXT_PACK_SCHEMA_VERSION,
        pack_id: pack_id.to_string(),
        source_head: input.source_head,
        policy_fingerprint: policy_fingerprint.clone(),
        limits: limits.clone(),
        groups,
        omissions,
        privacy_result: "pass",
    };
    let canonical_bytes = loop {
        let bytes = serde_json::to_vec(&canonical).map_err(|_| ContextPackError)?;
        if bytes.len() <= limits.max_bytes {
            break bytes;
        }
        if !remove_one_for_byte_limit(&mut canonical) {
            return Err(ContextPackError);
        }
    };

    let digest = sha256(&canonical_bytes);
    let byte_count = canonical_bytes.len();
    let canonical_json = String::from_utf8(canonical_bytes).map_err(|_| ContextPackError)?;
    let manifest_projection = ContextPackManifestProjection {
        pack_id: pack_id.to_string(),
        schema_version: CONTEXT_PACK_SCHEMA_VERSION,
        digest: digest.clone(),
        byte_count,
        source_head: canonical.source_head.clone(),
        policy_fingerprint,
        limits,
        omissions: canonical.omissions,
        privacy_result: "pass",
    };
    Ok(ContextPackProjection {
        canonical_json,
        digest,
        byte_count,
        manifest_projection,
    })
}

fn normalize_policy(
    root: &serde_yaml::Value,
    pack_id: &str,
) -> ContextPackResult<(Vec<IncludeGroup>, ContextPackLimits, String)> {
    let root = root.as_mapping().ok_or(ContextPackError)?;
    let policies = root
        .get(serde_yaml::Value::String("context-packs".to_string()))
        .and_then(serde_yaml::Value::as_mapping)
        .ok_or(ContextPackError)?;
    let raw = policies
        .get(serde_yaml::Value::String(pack_id.to_string()))
        .ok_or(ContextPackError)?;
    let policy: ContextPackPolicy =
        serde_yaml::from_value(raw.clone()).map_err(|_| ContextPackError)?;
    if policy.schema_version != CONTEXT_PACK_SCHEMA_VERSION || policy.include.is_empty() {
        return Err(ContextPackError);
    }
    let selected = policy.include.iter().copied().collect::<BTreeSet<_>>();
    if selected.len() != policy.include.len() {
        return Err(ContextPackError);
    }
    if policy.limits.max_files == 0
        || policy.limits.max_files > HARD_MAX_FILES
        || policy.limits.max_bytes == 0
        || policy.limits.max_bytes > HARD_MAX_BYTES
        || policy.limits.max_evidence_refs == 0
        || policy.limits.max_evidence_refs > HARD_MAX_EVIDENCE_REFS
        || policy.privacy.raw_transcript
        || policy.privacy.prompt_bodies
        || policy.privacy.secrets
        || policy.privacy.private_local_paths
    {
        return Err(ContextPackError);
    }
    let include = IncludeGroup::ALL
        .into_iter()
        .filter(|group| selected.contains(group))
        .collect::<Vec<_>>();
    let limits = ContextPackLimits {
        max_files: policy.limits.max_files,
        max_bytes: policy.limits.max_bytes,
        max_evidence_refs: policy.limits.max_evidence_refs,
    };
    let normalized = NormalizedPolicyFingerprint {
        schema_version: CONTEXT_PACK_SCHEMA_VERSION,
        include: include.clone(),
        limits: limits.clone(),
        privacy: policy.privacy,
    };
    let policy_bytes = serde_json::to_vec(&normalized).map_err(|_| ContextPackError)?;
    Ok((include, limits, sha256(&policy_bytes)))
}

fn validate_input(input: &ContextPackInput) -> ContextPackResult<()> {
    if input.schema_version != CONTEXT_PACK_SCHEMA_VERSION || !is_lower_hex(&input.source_head, 40)
    {
        return Err(ContextPackError);
    }

    let mut code_paths = BTreeSet::new();
    for entry in &input.code_map {
        if !is_safe_repo_path(&entry.path)
            || !is_sha256(&entry.content_sha256)
            || !code_paths.insert(canonical_public_path_key(&entry.path))
        {
            return Err(ContextPackError);
        }
    }

    let mut changed_paths = BTreeSet::new();
    for entry in &input.changed_files {
        if !is_safe_repo_path(&entry.path)
            || !is_sha256(&entry.content_sha256)
            || !changed_paths.insert(canonical_public_path_key(&entry.path))
        {
            return Err(ContextPackError);
        }
    }

    let mut test_ids = BTreeSet::new();
    let mut evidence_refs = BTreeSet::new();
    for entry in &input.tests {
        if !is_stable_test_id(&entry.test_id)
            || !is_safe_evidence_ref(&entry.evidence_ref)
            || !test_ids.insert(entry.test_id.as_str())
            || !evidence_refs.insert(canonical_public_path_key(&entry.evidence_ref))
        {
            return Err(ContextPackError);
        }
    }
    for evidence_ref in &input.evidence_refs {
        if !is_safe_evidence_ref(evidence_ref)
            || !evidence_refs.insert(canonical_public_path_key(evidence_ref))
        {
            return Err(ContextPackError);
        }
    }
    Ok(())
}

fn remove_one_for_byte_limit(pack: &mut CanonicalContextPack) -> bool {
    if pack.groups.evidence_refs.pop().is_some() {
        pack.omissions.evidence_refs += 1;
    } else if pack.groups.tests.pop().is_some() {
        pack.omissions.tests += 1;
    } else if pack.groups.changed_files.pop().is_some() {
        pack.omissions.changed_files += 1;
    } else if pack.groups.code_map.pop().is_some() {
        pack.omissions.code_map += 1;
    } else {
        return false;
    }
    pack.omissions.omitted_by_bytes += 1;
    true
}

fn is_stable_test_id(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_ID_BYTES || !value.is_ascii() {
        return false;
    }
    value.split("::").all(|segment| {
        !segment.is_empty()
            && segment
                .bytes()
                .next()
                .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            && segment.bytes().all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'.' | b'_' | b'-')
            })
    })
}

fn is_safe_repo_path(value: &str) -> bool {
    if value.is_empty()
        || !value.is_ascii()
        || value.starts_with('/')
        || value.ends_with('/')
        || value.contains('\\')
        || value.contains(':')
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'/'))
    {
        return false;
    }
    is_safe_public_path_identity(value, value, PUBLIC_REPO_PATH_MAX_BYTES)
}

fn is_safe_evidence_ref(value: &str) -> bool {
    if value.is_empty()
        || !value.is_ascii()
        || value.contains('\\')
        || value.contains("..")
        || value.contains("//")
    {
        return false;
    }
    let tail = value
        .strip_prefix("evidence:")
        .or_else(|| value.strip_prefix("context:"))
        .or_else(|| value.strip_prefix("context-packs/"));
    let Some(tail) = tail else {
        return false;
    };
    if tail.is_empty()
        || tail.starts_with('/')
        || tail.ends_with('/')
        || !tail
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        return false;
    }
    tail.bytes().all(|byte| {
        byte.is_ascii_lowercase()
            || byte.is_ascii_digit()
            || matches!(byte, b'.' | b'_' | b'-' | b'/')
    }) && is_safe_public_path_identity(value, tail, PUBLIC_REF_MAX_BYTES)
}

fn is_sha256(value: &str) -> bool {
    value
        .strip_prefix("sha256:")
        .is_some_and(|hex| is_lower_hex(hex, 64))
}

fn is_lower_hex(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
}

const fn default_max_files() -> usize {
    DEFAULT_MAX_FILES
}

const fn default_max_bytes() -> usize {
    DEFAULT_MAX_BYTES
}

const fn default_max_evidence_refs() -> usize {
    DEFAULT_MAX_EVIDENCE_REFS
}

#[cfg(test)]
mod tests {
    use super::is_safe_repo_path;

    #[test]
    fn private_runtime_namespaces_are_case_insensitive_on_windows() {
        for path in [
            ".GIT/config",
            ".Winsmux/private.json",
            "core/.git/config",
            "core/.WINSMUX/private.json",
        ] {
            assert!(!is_safe_repo_path(path), "{path} must remain private");
        }
        assert!(is_safe_repo_path("core/src/context_pack.rs"));
    }
}
