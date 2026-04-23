use serde::{Deserialize, Deserializer};
use std::collections::HashMap;

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

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum ManifestPanes {
    Map(HashMap<String, ManifestPane>),
    List(Vec<ManifestPane>),
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

#[derive(Debug, PartialEq, Eq)]
pub struct NormalizedManifestPane {
    pub label: String,
    pub pane_id: String,
    pub role: String,
}

impl WinsmuxManifest {
    #[cfg(test)]
    pub fn from_yaml(content: &str) -> Result<Self, serde_yaml::Error> {
        let normalized = normalize_legacy_manifest_yaml(content);
        serde_yaml::from_str(&normalized)
    }

    pub fn normalized_panes(&self) -> Vec<NormalizedManifestPane> {
        match &self.panes {
            ManifestPanes::Map(panes) => panes
                .iter()
                .map(|(label, pane)| NormalizedManifestPane {
                    label: if pane.label.is_empty() {
                        label.clone()
                    } else {
                        pane.label.clone()
                    },
                    pane_id: pane.pane_id.clone(),
                    role: pane.role.clone(),
                })
                .collect(),
            ManifestPanes::List(panes) => panes
                .iter()
                .map(|pane| NormalizedManifestPane {
                    label: pane.label.clone(),
                    pane_id: pane.pane_id.clone(),
                    role: pane.role.clone(),
                })
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

#[cfg(test)]
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

#[cfg(test)]
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
    if pane.changed_file_count.value().unwrap_or(usize::MAX) > 0
        && pane.changed_files.values().is_empty()
    {
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
