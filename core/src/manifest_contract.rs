use serde::de::{MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::fmt;

#[derive(Debug, Deserialize)]
pub struct WinsmuxManifest {
    pub version: ManifestU32,
    pub session: ManifestSession,
    pub panes: ManifestPanes,
}

#[derive(Debug, Deserialize)]
pub struct ManifestSession {
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub name: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub project_dir: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub started: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub ended: String,
}

#[derive(Debug)]
pub enum ManifestPanes {
    Map(Vec<(String, ManifestPane)>),
    List(Vec<ManifestPane>),
}

impl<'de> Deserialize<'de> for ManifestPanes {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(ManifestPanesVisitor)
    }
}

struct ManifestPanesVisitor;

impl<'de> Visitor<'de> for ManifestPanesVisitor {
    type Value = ManifestPanes;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a pane map or pane list")
    }

    fn visit_map<M>(self, mut access: M) -> Result<Self::Value, M::Error>
    where
        M: MapAccess<'de>,
    {
        let mut panes = Vec::new();
        while let Some(entry) = access.next_entry::<String, ManifestPane>()? {
            panes.push(entry);
        }
        Ok(ManifestPanes::Map(panes))
    }

    fn visit_seq<S>(self, mut access: S) -> Result<Self::Value, S::Error>
    where
        S: SeqAccess<'de>,
    {
        let mut panes = Vec::new();
        while let Some(pane) = access.next_element::<ManifestPane>()? {
            panes.push(pane);
        }
        Ok(ManifestPanes::List(panes))
    }
}

#[derive(Debug, Deserialize)]
pub struct ManifestPane {
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub label: String,
    #[serde(deserialize_with = "deserialize_manifest_string")]
    pub pane_id: String,
    #[serde(deserialize_with = "deserialize_manifest_string")]
    pub role: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub state: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub status: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub tokens_remaining: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub task_id: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub parent_run_id: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub goal: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub task: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub task_type: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub task_state: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub task_owner: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub review_state: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub priority: String,
    #[serde(default)]
    pub blocking: ManifestBool,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub branch: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub security_policy: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub launch_dir: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub builder_worktree_path: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub worktree_git_dir: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub worktree: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub head_sha: String,
    #[serde(default)]
    pub changed_file_count: ManifestUsize,
    #[serde(default)]
    pub changed_files: ManifestStringList,
    #[serde(default)]
    pub write_scope: ManifestStringList,
    #[serde(default)]
    pub read_scope: ManifestStringList,
    #[serde(default)]
    pub constraints: ManifestStringList,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub expected_output: String,
    #[serde(default)]
    pub verification_plan: ManifestStringList,
    #[serde(default)]
    pub review_required: ManifestBool,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub provider_target: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub agent_role: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub timeout_policy: String,
    #[serde(default)]
    pub handoff_refs: ManifestStringList,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub last_event: String,
    #[serde(default, deserialize_with = "deserialize_manifest_string")]
    pub last_event_at: String,
}

fn deserialize_manifest_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
pub enum ManifestStringList {
    List(Vec<String>),
    JsonString(String),
    Null,
    #[default]
    Empty,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum ManifestU32 {
    Number(u32),
    String(String),
}

impl ManifestU32 {
    pub fn value(&self) -> Option<u32> {
        match self {
            Self::Number(value) => Some(*value),
            Self::String(value) => value.trim().parse().ok(),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
pub enum ManifestUsize {
    Number(usize),
    String(String),
    #[default]
    Empty,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
pub enum ManifestBool {
    Bool(bool),
    String(String),
    #[default]
    Empty,
}

impl ManifestBool {
    pub fn value(&self) -> Option<bool> {
        match self {
            Self::Bool(value) => Some(*value),
            Self::String(value) => match value.trim().to_ascii_lowercase().as_str() {
                "true" => Some(true),
                "false" => Some(false),
                _ => None,
            },
            Self::Empty => Some(false),
        }
    }
}

impl ManifestUsize {
    pub fn value(&self) -> Option<usize> {
        match self {
            Self::Number(value) => Some(*value),
            Self::String(value) => value.trim().parse().ok(),
            Self::Empty => Some(0),
        }
    }
}

impl ManifestStringList {
    pub fn values(&self) -> Vec<String> {
        match self {
            Self::List(values) => values.clone(),
            Self::JsonString(raw) => serde_json::from_str(raw).unwrap_or_else(|_| {
                if raw.trim().is_empty() {
                    Vec::new()
                } else {
                    vec![raw.clone()]
                }
            }),
            Self::Null => Vec::new(),
            Self::Empty => Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedManifestPane {
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub state: String,
    pub task_id: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub priority: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub last_event: String,
    pub last_event_at: String,
}

impl WinsmuxManifest {
    pub fn from_yaml(content: &str) -> Result<Self, serde_yaml::Error> {
        let normalized = normalize_legacy_manifest_yaml(content);
        serde_yaml::from_str(&normalized)
    }

    pub fn normalized_panes(&self) -> Vec<NormalizedManifestPane> {
        self.normalized_panes_with_project_dir("")
    }

    pub fn normalized_panes_with_project_dir(
        &self,
        project_dir: &str,
    ) -> Vec<NormalizedManifestPane> {
        let project_dir = if self.session.project_dir.trim().is_empty() {
            project_dir
        } else {
            &self.session.project_dir
        };

        match &self.panes {
            ManifestPanes::Map(panes) => panes
                .iter()
                .map(|(label, pane)| normalize_manifest_pane(project_dir, label, pane))
                .collect(),
            ManifestPanes::List(panes) => panes
                .iter()
                .map(|pane| normalize_manifest_pane(project_dir, &pane.label, pane))
                .collect(),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version.value() != Some(1) {
            return Err(format!(
                "unsupported manifest version: {:?}",
                self.version.value()
            ));
        }
        for pane in self.panes_with_labels() {
            validate_pane(&pane.0, pane.1)?;
        }
        Ok(())
    }

    fn panes_with_labels(&self) -> Vec<(String, &ManifestPane)> {
        match &self.panes {
            ManifestPanes::Map(panes) => panes
                .iter()
                .map(|(label, pane)| {
                    let normalized = if pane.label.trim().is_empty() {
                        label.clone()
                    } else {
                        pane.label.clone()
                    };
                    (normalized, pane)
                })
                .collect(),
            ManifestPanes::List(panes) => panes
                .iter()
                .map(|pane| (pane.label.clone(), pane))
                .collect(),
        }
    }
}

fn normalize_manifest_pane(
    project_dir: &str,
    label: &str,
    pane: &ManifestPane,
) -> NormalizedManifestPane {
    let normalized_label = if pane.label.is_empty() {
        label.to_string()
    } else {
        pane.label.clone()
    };
    NormalizedManifestPane {
        label: normalized_label.clone(),
        pane_id: pane.pane_id.clone(),
        role: pane.role.clone(),
        state: normalize_pane_state(&pane.state, &pane.status),
        task_id: pane.task_id.clone(),
        task: pane.task.clone(),
        task_state: pane.task_state.clone(),
        review_state: pane.review_state.clone(),
        priority: pane.priority.clone(),
        branch: pane.branch.clone(),
        worktree: normalize_pane_worktree(
            project_dir,
            &normalized_label,
            &pane.role,
            &pane.branch,
            &pane.worktree,
            &pane.launch_dir,
            &pane.builder_worktree_path,
        ),
        head_sha: pane.head_sha.clone(),
        changed_file_count: pane.changed_file_count.value().unwrap_or(0),
        last_event: pane.last_event.clone(),
        last_event_at: pane.last_event_at.clone(),
    }
}

fn normalize_pane_worktree(
    project_dir: &str,
    label: &str,
    role: &str,
    branch: &str,
    worktree: &str,
    launch_dir: &str,
    builder_worktree_path: &str,
) -> String {
    let is_managed_worktree = is_managed_worktree_role(role);
    if !is_managed_worktree {
        return String::new();
    }

    let project_dir = project_dir.trim();
    for candidate in [launch_dir.trim(), builder_worktree_path.trim()] {
        if candidate.is_empty() || same_path(candidate, project_dir) {
            continue;
        }
        return relativize_path(project_dir, candidate);
    }

    if !worktree.trim().is_empty() {
        return worktree.trim().to_string();
    }

    let label = label.trim();
    if is_managed_worktree && !label.is_empty() && branch.trim() == format!("worktree-{label}") {
        return format!(".worktrees/{label}");
    }

    String::new()
}

fn normalize_pane_state(state: &str, status: &str) -> String {
    if state.trim().is_empty() {
        status.to_string()
    } else {
        state.to_string()
    }
}

fn is_managed_worktree_role(role: &str) -> bool {
    matches!(
        role.trim().to_ascii_lowercase().as_str(),
        "builder" | "worker"
    )
}

fn same_path(left: &str, right: &str) -> bool {
    if left.is_empty() || right.is_empty() {
        return false;
    }
    normalize_path_for_compare(left) == normalize_path_for_compare(right)
}

fn relativize_path(project_dir: &str, candidate: &str) -> String {
    let project = normalize_path_for_compare(project_dir);
    let normalized_candidate = normalize_path_for_compare(candidate);

    if project.is_empty() || !normalized_candidate.starts_with(&(project.clone() + "/")) {
        return candidate.trim().to_string();
    }

    normalized_candidate[project.len() + 1..].to_string()
}

fn normalize_path_for_compare(path: &str) -> String {
    let normalized = path
        .trim()
        .trim_end_matches(['\\', '/'])
        .replace('\\', "/")
        .to_ascii_lowercase();

    if let Some(path) = normalized.strip_prefix("//?/unc/") {
        return format!("//{path}");
    }
    if let Some(path) = normalized.strip_prefix("//?/") {
        return path.to_string();
    }

    normalized
}

fn normalize_legacy_manifest_yaml(content: &str) -> String {
    let mut in_panes = false;
    let mut normalized = Vec::new();
    for raw_line in content.lines() {
        let trimmed = raw_line.trim_start();
        let indent = raw_line.len() - trimmed.len();
        if indent == 0 && trimmed.ends_with(':') {
            in_panes = trimmed == "panes:";
        }
        if in_panes && raw_line.starts_with("  - label:") {
            let label = raw_line
                .split_once(':')
                .map(|(_, value)| value.trim())
                .unwrap_or_default()
                .trim_matches('\'')
                .trim_matches('"')
                .replace('\'', "''");
            normalized.push(format!("  '{label}':"));
            continue;
        }
        normalized.push(normalize_legacy_manifest_line(raw_line));
    }
    normalized.join("\n")
}

fn normalize_legacy_manifest_line(line: &str) -> String {
    let Some((head, tail)) = line.split_once(':') else {
        return line.to_string();
    };
    let Some(value_start) = tail.find(|ch: char| !ch.is_whitespace()) else {
        return line.to_string();
    };
    let (spacing, raw_value) = tail.split_at(value_start);
    if !raw_value.starts_with('%') {
        return line.to_string();
    }
    if raw_value.starts_with("%#") {
        return line.to_string();
    }
    let mut comment_index = None;
    let mut previous = '\0';
    for (index, ch) in raw_value.char_indices() {
        if ch == '#' && previous.is_whitespace() {
            comment_index = Some(index);
            break;
        }
        previous = ch;
    }
    match comment_index {
        Some(index) => {
            let (value, comment) = raw_value.split_at(index);
            format!(
                "{head}:{spacing}'{}' {}",
                value.trim_end(),
                comment.trim_start()
            )
        }
        None => format!("{head}:{spacing}'{}'", raw_value.trim_end()),
    }
}

fn validate_pane(label: &str, pane: &ManifestPane) -> Result<(), String> {
    if label.trim().is_empty() {
        return Err("manifest pane requires label".to_string());
    }
    if pane.pane_id.trim().is_empty() {
        return Err(format!("manifest pane '{label}' requires pane_id"));
    }
    if pane.role.trim().is_empty() {
        return Err(format!("manifest pane '{label}' requires role"));
    }
    if !pane.review_state.trim().is_empty() {
        if pane.branch.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' review_state requires branch"
            ));
        }
        if pane.head_sha.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' review_state requires head_sha"
            ));
        }
    }
    let Some(changed_file_count) = pane.changed_file_count.value() else {
        return Err(format!(
            "manifest pane '{label}' changed_file_count must be numeric"
        ));
    };
    if changed_file_count > 0 && pane.changed_files.values().is_empty() {
        return Err(format!(
            "manifest pane '{label}' changed_file_count requires changed_files"
        ));
    }
    if !pane.last_event.trim().is_empty() && pane.last_event_at.trim().is_empty() {
        return Err(format!(
            "manifest pane '{label}' last_event requires last_event_at"
        ));
    }
    let has_planning = !pane.goal.trim().is_empty()
        || !pane.task_type.trim().is_empty()
        || !pane.priority.trim().is_empty()
        || !pane.parent_run_id.trim().is_empty();
    if has_planning {
        if pane.parent_run_id.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' planning metadata requires parent_run_id"
            ));
        }
        if pane.goal.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' planning metadata requires goal"
            ));
        }
        if pane.task_type.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' planning metadata requires task_type"
            ));
        }
        if pane.priority.trim().is_empty() {
            return Err(format!(
                "manifest pane '{label}' planning metadata requires priority"
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::WinsmuxManifest;

    const MANIFEST_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/manifest.yaml");

    #[test]
    fn manifest_fixture_deserializes_and_validates() {
        let manifest = WinsmuxManifest::from_yaml(MANIFEST_FIXTURE).unwrap();
        manifest.validate().unwrap();
        assert_eq!(manifest.version.value(), Some(1));
        assert_eq!(manifest.session.name, "winsmux-orchestra");
        assert_eq!(manifest.session.project_dir, "__PROJECT_DIR__");

        let panes = manifest.normalized_panes();
        assert!(panes.iter().any(|pane| pane.label == "builder-1"));
        assert!(panes.iter().any(|pane| pane.label == "reviewer-1"));
    }

    #[test]
    fn manifest_accepts_legacy_list_and_dict_panes() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  reviewer:
    pane_id: "%4"
    role: Reviewer
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.normalized_panes();
        assert!(panes.iter().any(|pane| pane.label == "builder-1"));
        assert!(panes.iter().any(|pane| pane.label == "reviewer"));
    }

    #[test]
    fn manifest_rejects_review_state_without_head_sha() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    review_state: PENDING
    branch: worktree-builder-1
"#,
        )
        .unwrap();
        let err = manifest.validate().unwrap_err();
        assert!(err.contains("review_state requires head_sha"));
    }

    #[test]
    fn manifest_accepts_session_without_project_dir() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  started: 2026-04-23T00:00:00Z
  ended: ""
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        assert_eq!(manifest.session.started, "2026-04-23T00:00:00Z");
    }

    #[test]
    fn manifest_accepts_non_json_changed_files_string() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    changed_file_count: 1
    changed_files: scripts/winsmux-core.ps1
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
    }

    #[test]
    fn manifest_rejects_non_numeric_changed_file_count() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    changed_file_count: nope
    changed_files: scripts/winsmux-core.ps1
"#,
        )
        .unwrap();

        let err = manifest.validate().unwrap_err();

        assert!(err.contains("changed_file_count must be numeric"));
    }

    #[test]
    fn manifest_accepts_quoted_numeric_fields() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: "1"
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    changed_file_count: "1"
    changed_files: scripts/winsmux-core.ps1
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        assert_eq!(manifest.version.value(), Some(1));
    }

    #[test]
    fn manifest_accepts_quoted_boolean_fields() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: "1"
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    blocking: "true"
    review_required: "true"
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert_eq!(panes[0].1.blocking.value(), Some(true));
        assert_eq!(panes[0].1.review_required.value(), Some(true));
    }

    #[test]
    fn manifest_accepts_null_changed_files() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    changed_file_count: 0
    changed_files: null
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert!(panes[0].1.changed_files.values().is_empty());
    }

    #[test]
    fn manifest_accepts_current_power_shell_path_fields() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-1
    builder_worktree_path: C:\repo\.worktrees\builder-1
    worktree_git_dir: C:\repo\.git
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert_eq!(panes[0].1.launch_dir, r"C:\repo\.worktrees\builder-1");
        assert_eq!(
            panes[0].1.builder_worktree_path,
            r"C:\repo\.worktrees\builder-1"
        );
        assert_eq!(panes[0].1.worktree_git_dir, r"C:\repo\.git");
    }

    #[test]
    fn manifest_accepts_security_policy_string() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    security_policy: '{"mode":"blocklist","block_patterns":["git reset --hard"]}'
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert!(panes[0].1.security_policy.contains("blocklist"));
    }

    #[test]
    fn manifest_accepts_null_optional_strings() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task: null
    builder_worktree_path: null
    branch: null
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert_eq!(panes[0].1.task, "");
        assert_eq!(panes[0].1.builder_worktree_path, "");
        assert_eq!(panes[0].1.branch, "");
    }

    #[test]
    fn manifest_accepts_unquoted_percent_pane_id_with_comment() {
        let manifest = WinsmuxManifest::from_yaml(
            r#"
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: %2 # current pane
    role: Builder
"#,
        )
        .unwrap();
        manifest.validate().unwrap();
        let panes = manifest.panes_with_labels();
        assert_eq!(panes[0].1.pane_id, "%2");
    }
}
