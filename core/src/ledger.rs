use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::manifest_contract::{NormalizedManifestPane, WinsmuxManifest};
use serde_json::Value;
use std::cmp::Ordering;
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
    pub changed_files: Vec<String>,
    pub provider_target: String,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerInboxSummary {
    pub item_count: usize,
    pub by_kind: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerInboxItem {
    pub kind: String,
    pub priority: usize,
    pub message: String,
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub task_id: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub branch: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub event: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerInboxProjection {
    pub summary: LedgerInboxSummary,
    pub items: Vec<LedgerInboxItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerDigestSummary {
    pub item_count: usize,
    pub dirty_items: usize,
    pub review_pending: usize,
    pub review_failed: usize,
    pub actionable_items: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LedgerDigestItem {
    pub run_id: String,
    pub task_id: String,
    pub task: String,
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub provider_target: String,
    pub task_state: String,
    pub review_state: String,
    pub next_action: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub head_short: String,
    pub changed_file_count: usize,
    pub changed_files: Vec<String>,
    pub action_item_count: usize,
    pub last_event: String,
    pub last_event_at: String,
    pub verification_outcome: String,
    pub security_blocked: String,
    pub hypothesis: String,
    pub confidence: Option<f64>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LedgerDigestProjection {
    pub summary: LedgerDigestSummary,
    pub items: Vec<LedgerDigestItem>,
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
                    changed_files: pane.changed_files.clone(),
                    provider_target: pane.provider_target.clone(),
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

    pub fn inbox_projection(&self) -> LedgerInboxProjection {
        let mut items_by_key = BTreeMap::new();

        for pane in self.pane_read_models() {
            let pane_key_base = pane_key_base(&pane.pane_id, &pane.label);
            if pane.review_state.eq_ignore_ascii_case("pending") {
                let key = format!("manifest:review_pending:{pane_key_base}");
                items_by_key.insert(
                    key,
                    LedgerInboxItem::from_manifest_pane(
                        "review_pending",
                        format!("{} が review 待機中。", pane.label),
                        &pane,
                    ),
                );
            }

            if pane.review_state.eq_ignore_ascii_case("fail")
                || pane.review_state.eq_ignore_ascii_case("failed")
            {
                let key = format!("manifest:review_failed:{pane_key_base}");
                items_by_key.insert(
                    key,
                    LedgerInboxItem::from_manifest_pane(
                        "review_failed",
                        format!("{} の review が FAIL。", pane.label),
                        &pane,
                    ),
                );
            }

            if pane.task_state.eq_ignore_ascii_case("blocked") {
                let key = format!("manifest:task_blocked:{pane_key_base}");
                items_by_key.insert(
                    key,
                    LedgerInboxItem::from_manifest_pane(
                        "task_blocked",
                        format!("{} が blocked。", pane.label),
                        &pane,
                    ),
                );
            }
        }

        for event in self.inbox_active_events() {
            let Some(item) = LedgerInboxItem::from_event(event) else {
                continue;
            };
            let key = format!(
                "events:{}:{}",
                item.kind,
                pane_key_base(&item.pane_id, &item.label)
            );
            items_by_key.insert(key, item);
        }

        let mut items: Vec<_> = items_by_key.into_values().collect();
        items.sort_by(compare_inbox_items);
        let by_kind = count_inbox_by_kind(&items);

        LedgerInboxProjection {
            summary: LedgerInboxSummary {
                item_count: items.len(),
                by_kind,
            },
            items,
        }
    }

    pub fn digest_projection(&self) -> LedgerDigestProjection {
        let inbox = self.inbox_projection();
        let mut runs: BTreeMap<String, LedgerDigestRun> = BTreeMap::new();
        for pane in self.pane_read_models() {
            let run_id = run_id_from_pane(&pane);
            if let Some(run) = runs.get_mut(&run_id) {
                run.add_pane(&pane);
            } else {
                runs.insert(run_id, LedgerDigestRun::from_pane(&pane));
            }
        }

        for item in inbox.items {
            for run in runs.values_mut() {
                if run.matches_inbox_item(&item) {
                    run.action_items.push(item.clone());
                    break;
                }
            }
        }

        for run in runs.values_mut() {
            let mut matching_events: Vec<_> = self
                .events
                .iter()
                .enumerate()
                .filter(|(_, event)| run.matches_event(event))
                .collect();
            matching_events.sort_by(|(left_index, left), (right_index, right)| {
                left.timestamp
                    .cmp(&right.timestamp)
                    .then_with(|| left_index.cmp(right_index))
            });
            for (_, event) in matching_events {
                run.apply_event(event);
            }
        }

        let mut items: Vec<_> = runs.into_values().map(LedgerDigestRun::into_item).collect();
        items.sort_by(compare_digest_items);

        LedgerDigestProjection {
            summary: LedgerDigestSummary {
                item_count: items.len(),
                dirty_items: items
                    .iter()
                    .filter(|item| item.changed_file_count > 0)
                    .count(),
                review_pending: items
                    .iter()
                    .filter(|item| item.review_state.eq_ignore_ascii_case("pending"))
                    .count(),
                review_failed: items
                    .iter()
                    .filter(|item| {
                        item.review_state.eq_ignore_ascii_case("fail")
                            || item.review_state.eq_ignore_ascii_case("failed")
                    })
                    .count(),
                actionable_items: items
                    .iter()
                    .filter(|item| !item.next_action.trim().is_empty())
                    .count(),
            },
            items,
        }
    }

    fn inbox_active_events(&self) -> Vec<&EventRecord> {
        let mut keys = Vec::new();
        let mut latest_by_key = HashMap::new();
        for event in &self.events {
            let key = inbox_event_entity_key(event);
            if !latest_by_key.contains_key(&key) {
                keys.push(key.clone());
            }
            latest_by_key.insert(key, event);
        }

        keys.into_iter()
            .filter_map(|key| latest_by_key.remove(&key))
            .collect()
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

#[derive(Debug, Clone)]
struct LedgerDigestRun {
    item: LedgerDigestItem,
    labels: HashSet<String>,
    pane_ids: HashSet<String>,
    roles: HashSet<String>,
    action_items: Vec<LedgerInboxItem>,
}

impl LedgerDigestRun {
    fn from_pane(pane: &LedgerPaneReadModel) -> Self {
        let run_id = run_id_from_pane(pane);
        let mut run = Self {
            item: LedgerDigestItem {
                run_id,
                task_id: pane.task_id.clone(),
                task: pane.task.clone(),
                label: pane.label.clone(),
                pane_id: pane.pane_id.clone(),
                role: pane.role.clone(),
                provider_target: pane.provider_target.clone(),
                task_state: pane.task_state.clone(),
                review_state: pane.review_state.clone(),
                next_action: String::new(),
                branch: pane.branch.clone(),
                worktree: pane.worktree.clone(),
                head_sha: pane.head_sha.clone(),
                head_short: short_head_sha(&pane.head_sha),
                changed_file_count: 0,
                changed_files: Vec::new(),
                action_item_count: 0,
                last_event: pane.last_event.clone(),
                last_event_at: pane.last_event_at.clone(),
                verification_outcome: String::new(),
                security_blocked: String::new(),
                hypothesis: String::new(),
                confidence: None,
                observation_pack_ref: String::new(),
                consultation_ref: String::new(),
            },
            labels: HashSet::new(),
            pane_ids: HashSet::new(),
            roles: HashSet::new(),
            action_items: Vec::new(),
        };
        run.add_pane(pane);
        run
    }

    fn add_pane(&mut self, pane: &LedgerPaneReadModel) {
        self.item.changed_file_count += pane.changed_file_count;
        add_unique_string(&mut self.item.changed_files, &pane.changed_files);
        insert_non_empty(&mut self.labels, &pane.label);
        insert_non_empty(&mut self.pane_ids, &pane.pane_id);
        insert_non_empty(&mut self.roles, &pane.role);
        set_if_empty(&mut self.item.task_id, &pane.task_id);
        set_if_empty(&mut self.item.task, &pane.task);
        set_if_empty(&mut self.item.label, &pane.label);
        set_if_empty(&mut self.item.pane_id, &pane.pane_id);
        set_if_empty(&mut self.item.role, &pane.role);
        set_if_empty(&mut self.item.provider_target, &pane.provider_target);
        set_if_empty(&mut self.item.task_state, &pane.task_state);
        set_if_empty(&mut self.item.review_state, &pane.review_state);
        set_if_empty(&mut self.item.branch, &pane.branch);
        set_if_empty(&mut self.item.worktree, &pane.worktree);
        set_if_empty(&mut self.item.head_sha, &pane.head_sha);
        self.item.head_short = short_head_sha(&self.item.head_sha);
        set_if_empty(&mut self.item.last_event, &pane.last_event);
        set_if_empty(&mut self.item.last_event_at, &pane.last_event_at);
    }

    fn matches_inbox_item(&self, item: &LedgerInboxItem) -> bool {
        (!item.task_id.trim().is_empty() && item.task_id == self.item.task_id)
            || (!item.branch.trim().is_empty() && item.branch == self.item.branch)
            || (!item.head_sha.trim().is_empty() && item.head_sha == self.item.head_sha)
            || (!item.label.trim().is_empty() && self.labels.contains(&item.label))
            || (!item.pane_id.trim().is_empty() && self.pane_ids.contains(&item.pane_id))
    }

    fn matches_event(&self, event: &EventRecord) -> bool {
        let event_run_id = event_data_string(&event.data, "run_id");
        let event_task_id = event_data_string(&event.data, "task_id");
        let event_branch = event_branch(event);
        let event_head_sha = event_head_sha(event);

        if !event_run_id.trim().is_empty() {
            return event_run_id == self.item.run_id;
        }

        if !event_task_id.trim().is_empty() && !self.item.task_id.trim().is_empty() {
            return event_task_id == self.item.task_id;
        }

        if !event.pane_id.trim().is_empty() {
            return self.pane_ids.contains(&event.pane_id);
        }

        if !event.label.trim().is_empty() {
            return self.labels.contains(&event.label);
        }

        if !event_task_id.trim().is_empty() || !self.item.task_id.trim().is_empty() {
            return false;
        }

        (!self.item.branch.trim().is_empty() && self.item.branch == event_branch)
            || (!self.item.head_sha.trim().is_empty() && self.item.head_sha == event_head_sha)
    }

    fn apply_event(&mut self, event: &EventRecord) {
        set_if_present(
            &mut self.item.worktree,
            &event_data_string(&event.data, "worktree"),
        );
        set_if_present(
            &mut self.item.hypothesis,
            &event_data_string(&event.data, "hypothesis"),
        );
        set_if_present(
            &mut self.item.observation_pack_ref,
            &event_data_string(&event.data, "observation_pack_ref"),
        );
        set_if_present(
            &mut self.item.consultation_ref,
            &event_data_string(&event.data, "consultation_ref"),
        );
        if let Some(confidence) = event_data_f64(&event.data, "confidence") {
            self.item.confidence = Some(confidence);
        }
        if is_verification_event(&event.event) {
            if let Some(outcome) =
                event_data_nested_string(&event.data, "verification_result", "outcome")
            {
                self.item.verification_outcome = outcome;
            }
        }
        if is_security_event(&event.event) {
            if let Some(verdict) = event_data_string_option(&event.data, "verdict") {
                self.item.security_blocked = verdict;
            }
        }
    }

    fn into_item(mut self) -> LedgerDigestItem {
        self.item.next_action = run_next_action(
            &self.action_items,
            &self.item.review_state,
            &self.item.task_state,
        );
        self.item.action_item_count = self.action_items.len();
        self.item
    }
}

impl LedgerInboxItem {
    fn from_manifest_pane(kind: &str, message: String, pane: &LedgerPaneReadModel) -> Self {
        Self {
            kind: kind.to_string(),
            priority: inbox_priority(kind),
            message,
            label: pane.label.clone(),
            pane_id: pane.pane_id.clone(),
            role: pane.role.clone(),
            task_id: pane.task_id.clone(),
            task: pane.task.clone(),
            task_state: pane.task_state.clone(),
            review_state: pane.review_state.clone(),
            branch: pane.branch.clone(),
            head_sha: pane.head_sha.clone(),
            changed_file_count: pane.changed_file_count,
            event: pane.last_event.clone(),
            timestamp: pane.last_event_at.clone(),
            source: "manifest".to_string(),
        }
    }

    fn from_event(event: &EventRecord) -> Option<Self> {
        let kind = inbox_actionable_event_kind(event);
        if kind.is_empty() {
            return None;
        }

        let task_id = event_data_string(&event.data, "task_id");
        let branch = if event.branch.trim().is_empty() {
            event_data_string(&event.data, "branch")
        } else {
            event.branch.clone()
        };
        let head_sha = if event.head_sha.trim().is_empty() {
            event_data_string(&event.data, "head_sha")
        } else {
            event.head_sha.clone()
        };
        let status = if event.status.trim().is_empty() {
            event_data_string(&event.data, "to")
        } else {
            event.status.clone()
        };
        let event_label = if status.trim().is_empty() {
            event.event.clone()
        } else {
            status
        };

        Some(Self {
            kind: kind.to_string(),
            priority: inbox_priority(kind),
            message: event.message.clone(),
            label: event.label.clone(),
            pane_id: event.pane_id.clone(),
            role: event.role.clone(),
            task_id,
            task: String::new(),
            task_state: String::new(),
            review_state: String::new(),
            branch,
            head_sha,
            changed_file_count: 0,
            event: event_label,
            timestamp: event.timestamp.clone(),
            source: "events".to_string(),
        })
    }
}

fn run_id_from_pane(pane: &LedgerPaneReadModel) -> String {
    if !pane.task_id.trim().is_empty() {
        return format!("task:{}", pane.task_id);
    }
    if !pane.branch.trim().is_empty() {
        return format!("branch:{}", pane.branch);
    }
    if !pane.pane_id.trim().is_empty() {
        return format!("pane:{}", pane.pane_id);
    }
    format!("label:{}", pane.label)
}

fn run_next_action(
    action_items: &[LedgerInboxItem],
    review_state: &str,
    task_state: &str,
) -> String {
    for kind in [
        "approval_waiting",
        "review_failed",
        "task_blocked",
        "blocked",
        "commit_ready",
        "task_completed",
        "review_pending",
        "dispatch_needed",
    ] {
        if action_items.iter().any(|item| item.kind == kind) {
            return kind.to_string();
        }
    }

    if let Some(item) = action_items
        .iter()
        .find(|item| !item.kind.trim().is_empty())
    {
        return item.kind.clone();
    }

    if !review_state.trim().is_empty() {
        return review_state.to_string();
    }

    task_state.to_string()
}

fn short_head_sha(head_sha: &str) -> String {
    if head_sha.chars().count() <= 7 {
        head_sha.to_string()
    } else {
        head_sha.chars().take(7).collect()
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

fn inbox_priority(kind: &str) -> usize {
    match kind {
        "blocked" | "task_blocked" | "review_failed" | "bootstrap_invalid" | "crashed" | "hung"
        | "stalled" => 0,
        "approval_waiting" | "review_requested" | "review_pending" => 1,
        "dispatch_needed" | "task_completed" | "commit_ready" => 2,
        _ => 3,
    }
}

fn inbox_actionable_event_kind(event: &EventRecord) -> &'static str {
    let data_status = event_data_string(&event.data, "status");
    if event.event == "approval_waiting"
        || event.event == "pane.approval_waiting"
        || event.status == "approval_waiting"
        || (event.event == "monitor.status" && data_status == "approval_waiting")
    {
        return "approval_waiting";
    }

    match event.event.as_str() {
        "pane.idle" => return "dispatch_needed",
        "pane.completed" => return "task_completed",
        "pane.bootstrap_invalid" => return "bootstrap_invalid",
        "pane.crashed" => return "crashed",
        "pane.hung" => return "hung",
        "pane.stalled" => return "stalled",
        _ => {}
    }

    if event.event == "operator.state_transition" {
        match event.status.as_str() {
            "blocked_no_review_target" => return "blocked",
            "blocked_review_failed" => return "review_failed",
            "commit_ready" => return "commit_ready",
            _ => {}
        }

        match data_status.as_str() {
            "blocked_no_review_target" => return "blocked",
            "blocked_review_failed" => return "review_failed",
            "commit_ready" => return "commit_ready",
            _ => {}
        }
    }

    match event.event.as_str() {
        "operator.review_requested" => "review_requested",
        "operator.review_failed" => "review_failed",
        "operator.blocked" => "blocked",
        "operator.commit_ready" => "commit_ready",
        "pipeline.security.blocked" => "blocked",
        "security.policy.blocked" => "blocked",
        _ => "",
    }
}

fn inbox_event_entity_key(event: &EventRecord) -> String {
    if event.event.starts_with("operator.") {
        return "operator".to_string();
    }
    if !event.pane_id.trim().is_empty() {
        return format!("pane:{}", event.pane_id);
    }
    if !event.label.trim().is_empty() {
        return format!("label:{}", event.label);
    }
    format!("event:{}", event.event)
}

fn event_data_string(data: &Value, key: &str) -> String {
    event_data_string_option(data, key).unwrap_or_default()
}

fn event_data_string_option(data: &Value, key: &str) -> Option<String> {
    data.as_object()
        .and_then(|map| map.get(key))
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .filter(|value| !value.trim().is_empty())
}

fn event_data_nested_string(data: &Value, object_key: &str, value_key: &str) -> Option<String> {
    data.as_object()
        .and_then(|map| map.get(object_key))
        .and_then(|value| value.as_object())
        .and_then(|map| map.get(value_key))
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .filter(|value| !value.trim().is_empty())
}

fn event_data_f64(data: &Value, key: &str) -> Option<f64> {
    data.as_object()
        .and_then(|map| map.get(key))
        .and_then(|value| {
            value
                .as_f64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<f64>().ok()))
        })
}

fn is_verification_event(event_name: &str) -> bool {
    matches!(
        event_name,
        "pipeline.verify.pass" | "pipeline.verify.fail" | "pipeline.verify.partial"
    )
}

fn is_security_event(event_name: &str) -> bool {
    matches!(
        event_name,
        "pipeline.security.blocked"
            | "security.policy.blocked"
            | "pipeline.security.allowed"
            | "security.policy.allowed"
    )
}

fn event_branch(event: &EventRecord) -> String {
    if event.branch.trim().is_empty() {
        event_data_string(&event.data, "branch")
    } else {
        event.branch.clone()
    }
}

fn event_head_sha(event: &EventRecord) -> String {
    if event.head_sha.trim().is_empty() {
        event_data_string(&event.data, "head_sha")
    } else {
        event.head_sha.clone()
    }
}

fn insert_non_empty(values: &mut HashSet<String>, value: &str) {
    if !value.trim().is_empty() {
        values.insert(value.to_string());
    }
}

fn set_if_empty(target: &mut String, value: &str) {
    if target.trim().is_empty() && !value.trim().is_empty() {
        *target = value.to_string();
    }
}

fn set_if_present(target: &mut String, value: &str) {
    if !value.trim().is_empty() {
        *target = value.to_string();
    }
}

fn add_unique_string(target: &mut Vec<String>, values: &[String]) {
    for value in values {
        if !value.trim().is_empty() && !target.contains(value) {
            target.push(value.clone());
        }
    }
}

fn pane_key_base(pane_id: &str, label: &str) -> String {
    if !pane_id.trim().is_empty() {
        pane_id.to_string()
    } else {
        label.to_string()
    }
}

fn compare_inbox_items(left: &LedgerInboxItem, right: &LedgerInboxItem) -> Ordering {
    left.priority
        .cmp(&right.priority)
        .then_with(|| right.timestamp.cmp(&left.timestamp))
        .then_with(|| left.label.cmp(&right.label))
}

fn count_inbox_by_kind(items: &[LedgerInboxItem]) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for item in items {
        let kind = if item.kind.trim().is_empty() {
            "unknown"
        } else {
            &item.kind
        };
        *counts.entry(kind.to_string()).or_insert(0) += 1;
    }
    counts
}

fn compare_digest_items(left: &LedgerDigestItem, right: &LedgerDigestItem) -> Ordering {
    right
        .last_event_at
        .cmp(&left.last_event_at)
        .then_with(|| left.run_id.cmp(&right.run_id))
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
