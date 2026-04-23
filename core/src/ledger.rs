use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::manifest_contract::{NormalizedManifestPane, WinsmuxManifest};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

#[derive(Debug)]
pub struct LedgerSnapshot {
    manifest: WinsmuxManifest,
    events: Vec<EventRecord>,
    panes: Vec<NormalizedManifestPane>,
    panes_by_id: HashMap<String, NormalizedManifestPane>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerPaneReadModel {
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
    pub event_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerBoardSummary {
    pub pane_count: usize,
    pub dirty_panes: usize,
    pub review_pending: usize,
    pub review_failed: usize,
    pub review_passed: usize,
    pub tasks_in_progress: usize,
    pub tasks_blocked: usize,
    pub by_state: BTreeMap<String, usize>,
    pub by_review: BTreeMap<String, usize>,
    pub by_task_state: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerBoardPane {
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub state: String,
    pub task_id: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub last_event_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerBoardProjection {
    pub summary: LedgerBoardSummary,
    pub panes: Vec<LedgerBoardPane>,
}

impl LedgerSnapshot {
    pub fn from_project_dir(project_dir: impl AsRef<Path>) -> Result<Self, String> {
        let winsmux_dir = project_dir.as_ref().join(".winsmux");
        Self::from_paths(
            winsmux_dir.join("manifest.yaml"),
            winsmux_dir.join("events.jsonl"),
        )
    }

    pub fn from_paths(
        manifest_path: impl AsRef<Path>,
        events_path: impl AsRef<Path>,
    ) -> Result<Self, String> {
        let manifest_path = manifest_path.as_ref();
        let events_path = events_path.as_ref();

        let manifest_yaml = std::fs::read_to_string(manifest_path).map_err(|err| {
            format!(
                "failed to read manifest '{}': {err}",
                manifest_path.display()
            )
        })?;
        let events_jsonl = match std::fs::read_to_string(events_path) {
            Ok(content) => content,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(err) => {
                return Err(format!(
                    "failed to read events '{}': {err}",
                    events_path.display()
                ));
            }
        };

        let project_dir = project_dir_from_manifest_path(manifest_path);

        Self::from_manifest_and_events_with_project_dir(&manifest_yaml, &events_jsonl, &project_dir)
    }

    pub fn from_manifest_and_events(
        manifest_yaml: &str,
        events_jsonl: &str,
    ) -> Result<Self, String> {
        Self::from_manifest_and_events_with_project_dir(manifest_yaml, events_jsonl, "")
    }

    fn from_manifest_and_events_with_project_dir(
        manifest_yaml: &str,
        events_jsonl: &str,
        project_dir: &str,
    ) -> Result<Self, String> {
        let manifest = WinsmuxManifest::from_yaml(manifest_yaml)
            .map_err(|err| format!("failed to parse manifest: {err}"))?;
        manifest.validate()?;

        let events = parse_event_jsonl(events_jsonl)?;
        let panes = manifest.normalized_panes_with_project_dir(project_dir);
        let panes_by_id = index_panes_by_id(&panes)?;

        let snapshot = Self {
            manifest,
            events,
            panes,
            panes_by_id,
        };
        snapshot.validate_event_sessions()?;
        Ok(snapshot)
    }

    pub fn session_name(&self) -> &str {
        &self.manifest.session.name
    }

    pub fn pane_count(&self) -> usize {
        self.panes.len()
    }

    pub fn event_count(&self) -> usize {
        self.events.len()
    }

    pub fn pane_labels(&self) -> Vec<String> {
        self.panes.iter().map(|pane| pane.label.clone()).collect()
    }

    pub fn events_for_pane(&self, pane_id: &str) -> Vec<&EventRecord> {
        self.events
            .iter()
            .filter(|event| event.pane_id == pane_id)
            .collect()
    }

    pub fn unknown_event_pane_ids(&self) -> Vec<String> {
        let known: HashSet<&str> = self.panes_by_id.keys().map(String::as_str).collect();
        let mut unknown: Vec<String> = self
            .events
            .iter()
            .filter_map(|event| {
                let pane_id = event.pane_id.trim();
                if pane_id.is_empty() || known.contains(pane_id) {
                    None
                } else {
                    Some(pane_id.to_string())
                }
            })
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        unknown.sort();
        unknown
    }

    pub fn pane_read_models(&self) -> Vec<LedgerPaneReadModel> {
        self.panes
            .iter()
            .map(|pane| {
                let event_count = self.events_for_pane(&pane.pane_id).len();
                LedgerPaneReadModel {
                    label: pane.label.clone(),
                    pane_id: pane.pane_id.clone(),
                    role: pane.role.clone(),
                    state: pane.state.clone(),
                    task_id: pane.task_id.clone(),
                    task: pane.task.clone(),
                    task_state: pane.task_state.clone(),
                    review_state: pane.review_state.clone(),
                    priority: pane.priority.clone(),
                    branch: pane.branch.clone(),
                    worktree: pane.worktree.clone(),
                    head_sha: pane.head_sha.clone(),
                    changed_file_count: pane.changed_file_count,
                    last_event: pane.last_event.clone(),
                    last_event_at: pane.last_event_at.clone(),
                    event_count,
                }
            })
            .collect()
    }

    pub fn board_summary(&self) -> LedgerBoardSummary {
        let panes = self.pane_read_models();
        LedgerBoardSummary {
            pane_count: panes.len(),
            dirty_panes: panes
                .iter()
                .filter(|pane| pane.changed_file_count > 0)
                .count(),
            review_pending: panes
                .iter()
                .filter(|pane| pane.review_state.eq_ignore_ascii_case("pending"))
                .count(),
            review_failed: panes
                .iter()
                .filter(|pane| {
                    pane.review_state.eq_ignore_ascii_case("fail")
                        || pane.review_state.eq_ignore_ascii_case("failed")
                })
                .count(),
            review_passed: panes
                .iter()
                .filter(|pane| pane.review_state.eq_ignore_ascii_case("pass"))
                .count(),
            tasks_in_progress: panes
                .iter()
                .filter(|pane| pane.task_state == "in_progress")
                .count(),
            tasks_blocked: panes
                .iter()
                .filter(|pane| pane.task_state == "blocked")
                .count(),
            by_state: count_by(&panes, |pane| &pane.state),
            by_review: count_by(&panes, |pane| &pane.review_state),
            by_task_state: count_by(&panes, |pane| &pane.task_state),
        }
    }

    pub fn board_projection(&self) -> LedgerBoardProjection {
        let panes = self
            .pane_read_models()
            .into_iter()
            .map(|pane| LedgerBoardPane {
                label: pane.label,
                pane_id: pane.pane_id,
                role: pane.role,
                state: pane.state,
                task_id: pane.task_id,
                task: pane.task,
                task_state: pane.task_state,
                review_state: pane.review_state,
                branch: pane.branch,
                worktree: pane.worktree,
                head_sha: pane.head_sha,
                changed_file_count: pane.changed_file_count,
                last_event_at: pane.last_event_at,
            })
            .collect();

        LedgerBoardProjection {
            summary: self.board_summary(),
            panes,
        }
    }

    fn validate_event_sessions(&self) -> Result<(), String> {
        let session_name = self.session_name();
        if session_name.trim().is_empty() {
            return Ok(());
        }

        for event in &self.events {
            if event.session.trim().is_empty() || event.session == session_name {
                continue;
            }

            return Err(format!(
                "event '{}' belongs to session '{}', expected '{}'",
                event.event, event.session, session_name
            ));
        }

        Ok(())
    }
}

fn project_dir_from_manifest_path(manifest_path: &Path) -> String {
    let project_dir_path = manifest_path
        .parent()
        .and_then(|winsmux_dir| winsmux_dir.parent())
        .unwrap_or_else(|| Path::new(""));
    let project_dir_path = if project_dir_path.as_os_str().is_empty() {
        Path::new(".")
    } else {
        project_dir_path
    };

    project_dir_path
        .canonicalize()
        .unwrap_or_else(|_| project_dir_path.to_path_buf())
        .to_string_lossy()
        .to_string()
}

fn count_by<F>(panes: &[LedgerPaneReadModel], selector: F) -> BTreeMap<String, usize>
where
    F: Fn(&LedgerPaneReadModel) -> &str,
{
    let mut counts = BTreeMap::new();
    for pane in panes {
        let raw_value = selector(pane).trim();
        let value = if raw_value.is_empty() {
            "unknown"
        } else {
            raw_value
        };
        *counts.entry(value.to_string()).or_insert(0) += 1;
    }
    counts
}

fn index_panes_by_id(
    panes: &[NormalizedManifestPane],
) -> Result<HashMap<String, NormalizedManifestPane>, String> {
    let mut panes_by_id = HashMap::new();
    for pane in panes {
        let pane_id = pane.pane_id.trim();
        if pane_id.is_empty() {
            continue;
        }
        if panes_by_id
            .insert(pane_id.to_string(), pane.clone())
            .is_some()
        {
            return Err(format!("duplicate manifest pane_id '{pane_id}'"));
        }
    }
    Ok(panes_by_id)
}

#[cfg(test)]
mod tests {
    use super::{project_dir_from_manifest_path, LedgerSnapshot};
    use std::path::Path;

    const MANIFEST_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/manifest.yaml");
    const EVENTS_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/events.jsonl");

    #[test]
    fn ledger_snapshot_loads_manifest_and_events() {
        let snapshot =
            LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE).unwrap();

        assert_eq!(snapshot.session_name(), "winsmux-orchestra");
        assert_eq!(snapshot.pane_count(), 2);
        assert_eq!(snapshot.event_count(), 5);
        assert!(snapshot.pane_labels().contains(&"builder-1".to_string()));
        assert_eq!(snapshot.events_for_pane("%2").len(), 2);
        assert_eq!(
            snapshot.unknown_event_pane_ids(),
            vec!["%7".to_string(), "%9".to_string()]
        );
    }

    #[test]
    fn ledger_snapshot_rejects_wrong_event_session() {
        let events = r#"{"timestamp":"2026-04-23T12:00:00+09:00","session":"other","event":"pane.completed"}"#;

        let err = LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, events).unwrap_err();

        assert!(err.contains("belongs to session 'other'"));
    }

    #[test]
    fn ledger_snapshot_rejects_duplicate_manifest_pane_id() {
        let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
"#;

        let err = LedgerSnapshot::from_manifest_and_events(manifest, "").unwrap_err();

        assert!(err.contains("duplicate manifest pane_id '%2'"));
    }

    #[test]
    fn ledger_project_dir_from_bare_winsmux_manifest_path_uses_current_dir() {
        let project_dir = project_dir_from_manifest_path(Path::new(".winsmux/manifest.yaml"));
        let expected = Path::new(".")
            .canonicalize()
            .expect("current dir should be available")
            .to_string_lossy()
            .to_string();

        assert_eq!(project_dir, expected);
    }
}
