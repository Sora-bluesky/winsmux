use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::manifest_contract::{NormalizedManifestPane, WinsmuxManifest};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

#[derive(Debug)]
pub struct LedgerSnapshot {
    manifest: WinsmuxManifest,
    events: Vec<EventRecord>,
    evidence_chain: LedgerEvidenceChainProjection,
    panes: Vec<NormalizedManifestPane>,
    panes_by_id: HashMap<String, NormalizedManifestPane>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerEvidenceChainProjection {
    pub summary: LedgerEvidenceChainSummary,
    pub entries: Vec<LedgerEvidenceChainEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerEvidenceChainSummary {
    pub entry_count: usize,
    pub recorded_count: usize,
    pub verified_count: usize,
    pub tamper_detected_count: usize,
    pub root_hash: String,
    pub integrity_status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerEvidenceChainEntry {
    pub index: usize,
    pub timestamp: String,
    pub event: String,
    pub previous_hash: String,
    pub event_hash: String,
    pub chain_hash: String,
    pub recorded_previous_hash: String,
    pub recorded_event_hash: String,
    pub recorded_chain_hash: String,
    pub integrity_status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerPaneReadModel {
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub state: String,
    pub tokens_remaining: String,
    pub task_id: String,
    pub parent_run_id: String,
    pub goal: String,
    pub task: String,
    pub task_type: String,
    pub task_state: String,
    pub task_owner: String,
    pub review_state: String,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub priority: String,
    pub blocking: bool,
    pub branch: String,
    pub security_policy: String,
    pub worktree: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub changed_files: Vec<String>,
    pub write_scope: Vec<String>,
    pub read_scope: Vec<String>,
    pub constraints: Vec<String>,
    pub expected_output: String,
    pub verification_plan: Vec<String>,
    pub review_required: bool,
    pub provider_target: String,
    pub agent_role: String,
    pub timeout_policy: String,
    pub handoff_refs: Vec<String>,
    pub last_event: String,
    pub last_event_at: String,
    pub event_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerBoardPane {
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub state: String,
    pub task_id: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub last_event_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerBoardProjection {
    pub summary: LedgerBoardSummary,
    pub panes: Vec<LedgerBoardPane>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerInboxSummary {
    pub item_count: usize,
    pub by_kind: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub branch: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub event: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerInboxProjection {
    pub summary: LedgerInboxSummary,
    pub items: Vec<LedgerInboxItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerDigestSummary {
    pub item_count: usize,
    pub dirty_items: usize,
    pub review_pending: usize,
    pub review_failed: usize,
    pub actionable_items: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
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
    pub phase: String,
    pub activity: String,
    pub detail: String,
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
    pub verification_verdict_summary: LedgerVerdictSummary,
    pub security_verdict_summary: LedgerVerdictSummary,
    pub monitoring_verdict_summary: LedgerVerdictSummary,
    pub verification_outcome: String,
    pub security_blocked: String,
    pub hypothesis: String,
    pub confidence: Option<f64>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerVerdictSummary {
    pub kind: String,
    pub verdict: String,
    pub summary: String,
    pub event: String,
    pub timestamp: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerDigestProjection {
    pub summary: LedgerDigestSummary,
    pub items: Vec<LedgerDigestItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerExplainProjection {
    pub run: LedgerExplainRun,
    pub explanation: LedgerExplainExplanation,
    pub evidence_digest: LedgerDigestItem,
    pub recent_events: Vec<LedgerExplainRecentEvent>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerExplainRun {
    pub run_id: String,
    pub task_id: String,
    pub parent_run_id: String,
    pub goal: String,
    pub task: String,
    pub task_type: String,
    pub priority: String,
    pub blocking: bool,
    pub state: String,
    pub task_state: String,
    pub review_state: String,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub branch: String,
    pub head_sha: String,
    pub worktree: String,
    pub primary_label: String,
    pub primary_pane_id: String,
    pub primary_role: String,
    pub last_event: String,
    pub last_event_at: String,
    pub tokens_remaining: String,
    pub pane_count: usize,
    pub changed_file_count: usize,
    pub labels: Vec<String>,
    pub pane_ids: Vec<String>,
    pub roles: Vec<String>,
    pub provider_target: String,
    pub agent_role: String,
    pub write_scope: Vec<String>,
    pub read_scope: Vec<String>,
    pub constraints: Vec<String>,
    pub expected_output: String,
    pub verification_plan: Vec<String>,
    pub review_required: bool,
    pub timeout_policy: String,
    pub handoff_refs: Vec<String>,
    pub action_items: Vec<LedgerExplainActionItem>,
    pub experiment_packet: LedgerExplainExperimentPacket,
    pub security_policy: Value,
    pub security_verdict: Value,
    pub verification_contract: Value,
    pub verification_result: Value,
    pub verification_evidence: Value,
    pub context_contract: Value,
    pub tdd_gate: Value,
    pub verification_envelope: Value,
    pub audit_chain: Value,
    pub outcome: Value,
    pub phase_gate: Value,
    pub draft_pr_gate: Value,
    pub changed_files: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerExplainExplanation {
    pub summary: String,
    pub reasons: Vec<String>,
    pub next_action: String,
    pub current_state: LedgerExplainCurrentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerExplainCurrentState {
    pub state: String,
    pub task_state: String,
    pub review_state: String,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub last_event: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerExplainActionItem {
    pub kind: String,
    pub message: String,
    pub event: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerExplainExperimentPacket {
    pub hypothesis: String,
    pub test_plan: Vec<String>,
    pub result: String,
    pub confidence: Option<f64>,
    pub next_action: String,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
    pub run_id: String,
    pub slot: String,
    pub branch: String,
    pub worktree: String,
    pub env_fingerprint: String,
    pub command_hash: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerExplainRecentEvent {
    pub timestamp: String,
    pub event: String,
    pub status: String,
    pub message: String,
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub task_id: String,
    pub branch: String,
    pub head_sha: String,
    pub source: String,
    pub hypothesis: String,
    pub test_plan: Option<Vec<String>>,
    pub result: String,
    pub confidence: Option<f64>,
    pub next_action: String,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
    pub run_id: String,
    pub slot: String,
    pub worktree: String,
    pub env_fingerprint: String,
    pub command_hash: String,
    pub observation_pack: Value,
    pub consultation_packet: Value,
    pub verification_contract: Value,
    pub verification_result: Value,
    pub security_verdict: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerStatusPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub session: LedgerStatusSession,
    pub evidence_chain: LedgerEvidenceChainSummary,
    pub summary: LedgerBoardSummary,
    pub panes: Vec<LedgerPaneReadModel>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerStatusSession {
    pub name: String,
    pub pane_count: usize,
    pub event_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerBoardPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub summary: LedgerBoardSummary,
    pub panes: Vec<LedgerBoardPane>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerInboxPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub summary: LedgerInboxSummary,
    pub items: Vec<LedgerInboxItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerDigestPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub summary: LedgerDigestSummary,
    pub items: Vec<LedgerDigestItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerRunsPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub summary: LedgerRunsSummary,
    pub runs: Vec<LedgerRunProjection>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerRunsSummary {
    pub run_count: usize,
    pub blocked_runs: usize,
    pub review_pending: usize,
    pub dirty_runs: usize,
    pub action_item_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerRunProjection {
    pub run_id: String,
    pub task_id: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub primary_label: String,
    pub primary_pane_id: String,
    pub primary_role: String,
    pub state: String,
    pub tokens_remaining: String,
    pub last_event: String,
    pub last_event_at: String,
    pub pane_count: usize,
    pub changed_file_count: usize,
    pub labels: Vec<String>,
    pub pane_ids: Vec<String>,
    pub roles: Vec<String>,
    pub changed_files: Vec<String>,
    pub action_items: Vec<LedgerExplainActionItem>,
    pub parent_run_id: String,
    pub goal: String,
    pub task_type: String,
    pub priority: String,
    pub blocking: bool,
    pub write_scope: Vec<String>,
    pub read_scope: Vec<String>,
    pub constraints: Vec<String>,
    pub expected_output: String,
    pub verification_plan: Vec<String>,
    pub review_required: bool,
    pub verification_verdict_summary: LedgerVerdictSummary,
    pub security_verdict_summary: LedgerVerdictSummary,
    pub monitoring_verdict_summary: LedgerVerdictSummary,
    pub provider_target: String,
    pub agent_role: String,
    pub timeout_policy: String,
    pub handoff_refs: Vec<String>,
    pub experiment_packet: Option<LedgerExplainExperimentPacket>,
    pub security_policy: Value,
    pub security_verdict: Value,
    pub verification_contract: Value,
    pub verification_result: Value,
    pub verification_evidence: Value,
    pub context_contract: Value,
    pub tdd_gate: Value,
    pub verification_envelope: Value,
    pub audit_chain: Value,
    pub outcome: Value,
    pub phase_gate: Value,
    pub draft_pr_gate: Value,
    pub run_packet: Option<LedgerRunPacket>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerRunPacket {
    pub run_id: String,
    pub task_id: String,
    pub parent_run_id: String,
    pub goal: String,
    pub task: String,
    pub task_type: String,
    pub priority: String,
    pub blocking: bool,
    pub phase: String,
    pub activity: String,
    pub detail: String,
    pub write_scope: Vec<String>,
    pub read_scope: Vec<String>,
    pub constraints: Vec<String>,
    pub expected_output: String,
    pub verification_plan: Vec<String>,
    pub review_required: bool,
    pub provider_target: String,
    pub agent_role: String,
    pub timeout_policy: String,
    pub handoff_refs: Vec<String>,
    pub branch: String,
    pub head_sha: String,
    pub primary_label: String,
    pub primary_pane_id: String,
    pub primary_role: String,
    pub labels: Vec<String>,
    pub pane_ids: Vec<String>,
    pub roles: Vec<String>,
    pub changed_files: Vec<String>,
    pub security_policy: Value,
    pub security_verdict: Value,
    pub verification_contract: Value,
    pub verification_result: Value,
    pub verification_evidence: Value,
    pub context_contract: Value,
    pub tdd_gate: Value,
    pub verification_envelope: Value,
    pub audit_chain: Value,
    pub outcome: Value,
    pub phase_gate: Value,
    pub draft_pr_gate: Value,
    pub last_event: String,
    pub last_event_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LedgerExplainPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub run: LedgerExplainRun,
    pub observation_pack: Value,
    pub consultation_packet: Value,
    pub evidence_digest: LedgerDigestItem,
    pub explanation: LedgerExplainExplanation,
    pub review_state: Value,
    pub recent_events: Vec<LedgerExplainRecentEvent>,
}

impl LedgerStatusPayload {
    pub fn from_snapshot(
        generated_at: String,
        project_dir: String,
        snapshot: &LedgerSnapshot,
    ) -> Self {
        Self {
            generated_at,
            project_dir,
            session: LedgerStatusSession {
                name: snapshot.session_name().to_string(),
                pane_count: snapshot.pane_count(),
                event_count: snapshot.event_count(),
            },
            evidence_chain: snapshot.evidence_chain.summary.clone(),
            summary: snapshot.board_summary(),
            panes: snapshot.pane_read_models(),
        }
    }
}

impl LedgerBoardPayload {
    pub fn from_projection(
        generated_at: String,
        project_dir: String,
        projection: LedgerBoardProjection,
    ) -> Self {
        Self {
            generated_at,
            project_dir,
            summary: projection.summary,
            panes: projection.panes,
        }
    }
}

impl LedgerInboxPayload {
    pub fn from_projection(
        generated_at: String,
        project_dir: String,
        projection: LedgerInboxProjection,
    ) -> Self {
        Self {
            generated_at,
            project_dir,
            summary: projection.summary,
            items: projection.items,
        }
    }
}

impl LedgerDigestPayload {
    pub fn from_projection(
        generated_at: String,
        project_dir: String,
        projection: LedgerDigestProjection,
    ) -> Self {
        Self {
            generated_at,
            project_dir,
            summary: projection.summary,
            items: projection.items,
        }
    }
}

impl LedgerRunsPayload {
    pub fn from_snapshot(
        generated_at: String,
        project_dir: String,
        snapshot: &LedgerSnapshot,
    ) -> Self {
        let runs: Vec<LedgerRunProjection> = snapshot
            .digest_projection()
            .items
            .into_iter()
            .map(|item| {
                let explain = snapshot.explain_projection(&item.run_id);
                LedgerRunProjection::from_digest_item(
                    item,
                    explain.as_ref().map(|projection| &projection.run),
                )
            })
            .collect();
        let summary = LedgerRunsSummary {
            run_count: runs.len(),
            blocked_runs: runs
                .iter()
                .filter(|run| run.task_state.eq_ignore_ascii_case("blocked"))
                .count(),
            review_pending: runs
                .iter()
                .filter(|run| run.review_state.eq_ignore_ascii_case("pending"))
                .count(),
            dirty_runs: runs.iter().filter(|run| run.changed_file_count > 0).count(),
            action_item_count: runs.iter().map(|run| run.action_items.len()).sum(),
        };
        Self {
            generated_at,
            project_dir,
            summary,
            runs,
        }
    }
}

impl LedgerRunProjection {
    fn from_digest_item(item: LedgerDigestItem, run: Option<&LedgerExplainRun>) -> Self {
        let primary_label = item.label.clone();
        let primary_pane_id = item.pane_id.clone();
        let primary_role = item.role.clone();
        let verification_verdict_summary = item.verification_verdict_summary.clone();
        let security_verdict_summary = item.security_verdict_summary.clone();
        let monitoring_verdict_summary = item.monitoring_verdict_summary.clone();

        Self {
            run_id: item.run_id,
            task_id: item.task_id,
            task: item.task,
            task_state: item.task_state,
            review_state: item.review_state,
            phase: item.phase,
            activity: item.activity,
            detail: item.detail,
            branch: item.branch,
            worktree: item.worktree,
            head_sha: item.head_sha,
            primary_label: primary_label.clone(),
            primary_pane_id: primary_pane_id.clone(),
            primary_role: primary_role.clone(),
            state: run.map(|run| run.state.clone()).unwrap_or_default(),
            tokens_remaining: run
                .map(|run| run.tokens_remaining.clone())
                .unwrap_or_default(),
            last_event: item.last_event,
            last_event_at: item.last_event_at,
            pane_count: run.map(|run| run.pane_count).unwrap_or(1),
            changed_file_count: item.changed_file_count,
            labels: run
                .map(|run| run.labels.clone())
                .unwrap_or_else(|| vec![primary_label]),
            pane_ids: run
                .map(|run| run.pane_ids.clone())
                .unwrap_or_else(|| vec![primary_pane_id]),
            roles: run
                .map(|run| run.roles.clone())
                .unwrap_or_else(|| vec![primary_role.clone()]),
            changed_files: item.changed_files,
            action_items: run.map(|run| run.action_items.clone()).unwrap_or_default(),
            parent_run_id: run.map(|run| run.parent_run_id.clone()).unwrap_or_default(),
            goal: run.map(|run| run.goal.clone()).unwrap_or_default(),
            task_type: run.map(|run| run.task_type.clone()).unwrap_or_default(),
            priority: run.map(|run| run.priority.clone()).unwrap_or_default(),
            blocking: run.map(|run| run.blocking).unwrap_or(false),
            write_scope: run.map(|run| run.write_scope.clone()).unwrap_or_default(),
            read_scope: run.map(|run| run.read_scope.clone()).unwrap_or_default(),
            constraints: run.map(|run| run.constraints.clone()).unwrap_or_default(),
            expected_output: run
                .map(|run| run.expected_output.clone())
                .unwrap_or_default(),
            verification_plan: run
                .map(|run| run.verification_plan.clone())
                .unwrap_or_default(),
            review_required: run.map(|run| run.review_required).unwrap_or(false),
            verification_verdict_summary,
            security_verdict_summary,
            monitoring_verdict_summary,
            provider_target: item.provider_target,
            agent_role: run
                .map(|run| run.agent_role.clone())
                .unwrap_or(primary_role),
            timeout_policy: run
                .map(|run| run.timeout_policy.clone())
                .unwrap_or_default(),
            handoff_refs: run.map(|run| run.handoff_refs.clone()).unwrap_or_default(),
            experiment_packet: run.map(|run| run.experiment_packet.clone()),
            security_policy: run
                .map(|run| run.security_policy.clone())
                .unwrap_or(Value::Null),
            security_verdict: run
                .map(|run| run.security_verdict.clone())
                .unwrap_or(Value::Null),
            verification_contract: run
                .map(|run| run.verification_contract.clone())
                .unwrap_or(Value::Null),
            verification_result: run
                .map(|run| run.verification_result.clone())
                .unwrap_or(Value::Null),
            verification_evidence: run
                .map(|run| run.verification_evidence.clone())
                .unwrap_or(Value::Null),
            context_contract: run
                .map(|run| run.context_contract.clone())
                .unwrap_or(Value::Null),
            tdd_gate: run.map(|run| run.tdd_gate.clone()).unwrap_or(Value::Null),
            verification_envelope: run
                .map(|run| run.verification_envelope.clone())
                .unwrap_or(Value::Null),
            audit_chain: run
                .map(|run| run.audit_chain.clone())
                .unwrap_or(Value::Null),
            outcome: run.map(|run| run.outcome.clone()).unwrap_or(Value::Null),
            phase_gate: run.map(|run| run.phase_gate.clone()).unwrap_or(Value::Null),
            draft_pr_gate: run
                .map(|run| run.draft_pr_gate.clone())
                .unwrap_or(Value::Null),
            run_packet: run.map(LedgerRunPacket::from_explain_run),
        }
    }
}

impl LedgerRunPacket {
    fn from_explain_run(run: &LedgerExplainRun) -> Self {
        Self {
            run_id: run.run_id.clone(),
            task_id: run.task_id.clone(),
            parent_run_id: run.parent_run_id.clone(),
            goal: run.goal.clone(),
            task: run.task.clone(),
            task_type: run.task_type.clone(),
            priority: run.priority.clone(),
            blocking: run.blocking,
            phase: run.phase.clone(),
            activity: run.activity.clone(),
            detail: run.detail.clone(),
            write_scope: run.write_scope.clone(),
            read_scope: run.read_scope.clone(),
            constraints: run.constraints.clone(),
            expected_output: run.expected_output.clone(),
            verification_plan: run.verification_plan.clone(),
            review_required: run.review_required,
            provider_target: run.provider_target.clone(),
            agent_role: run.agent_role.clone(),
            timeout_policy: run.timeout_policy.clone(),
            handoff_refs: run.handoff_refs.clone(),
            branch: run.branch.clone(),
            head_sha: run.head_sha.clone(),
            primary_label: run.primary_label.clone(),
            primary_pane_id: run.primary_pane_id.clone(),
            primary_role: run.primary_role.clone(),
            labels: run.labels.clone(),
            pane_ids: run.pane_ids.clone(),
            roles: run.roles.clone(),
            changed_files: run.changed_files.clone(),
            security_policy: run.security_policy.clone(),
            security_verdict: run.security_verdict.clone(),
            verification_contract: run.verification_contract.clone(),
            verification_result: run.verification_result.clone(),
            verification_evidence: run.verification_evidence.clone(),
            context_contract: run.context_contract.clone(),
            tdd_gate: run.tdd_gate.clone(),
            verification_envelope: run.verification_envelope.clone(),
            audit_chain: run.audit_chain.clone(),
            outcome: run.outcome.clone(),
            phase_gate: run.phase_gate.clone(),
            draft_pr_gate: run.draft_pr_gate.clone(),
            last_event: run.last_event.clone(),
            last_event_at: run.last_event_at.clone(),
        }
    }
}

impl LedgerExplainPayload {
    pub fn from_projection(
        generated_at: String,
        project_dir: String,
        projection: LedgerExplainProjection,
        observation_pack: Value,
        consultation_packet: Value,
        review_state: Value,
    ) -> Self {
        Self {
            generated_at,
            project_dir,
            run: projection.run,
            observation_pack,
            consultation_packet,
            evidence_digest: projection.evidence_digest,
            explanation: projection.explanation,
            review_state,
            recent_events: projection.recent_events,
        }
    }
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
        let evidence_chain = build_evidence_chain(events_jsonl, &events)?;
        let panes = manifest.normalized_panes_with_project_dir(project_dir);
        let panes_by_id = index_panes_by_id(&panes)?;

        let snapshot = Self {
            manifest,
            events,
            evidence_chain,
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

    pub fn evidence_chain_projection(&self) -> LedgerEvidenceChainProjection {
        self.evidence_chain.clone()
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
                let (phase, activity, detail) = run_state_model(
                    &pane.state,
                    &pane.task_state,
                    &pane.review_state,
                    "",
                    &pane.last_event,
                );
                LedgerPaneReadModel {
                    label: pane.label.clone(),
                    pane_id: pane.pane_id.clone(),
                    role: pane.role.clone(),
                    state: pane.state.clone(),
                    tokens_remaining: pane.tokens_remaining.clone(),
                    task_id: pane.task_id.clone(),
                    parent_run_id: pane.parent_run_id.clone(),
                    goal: pane.goal.clone(),
                    task: pane.task.clone(),
                    task_type: pane.task_type.clone(),
                    task_state: pane.task_state.clone(),
                    task_owner: pane.task_owner.clone(),
                    review_state: pane.review_state.clone(),
                    phase,
                    activity,
                    detail,
                    priority: pane.priority.clone(),
                    blocking: pane.blocking,
                    branch: pane.branch.clone(),
                    security_policy: pane.security_policy.clone(),
                    worktree: pane.worktree.clone(),
                    head_sha: pane.head_sha.clone(),
                    changed_file_count: pane.changed_file_count,
                    changed_files: pane.changed_files.clone(),
                    write_scope: pane.write_scope.clone(),
                    read_scope: pane.read_scope.clone(),
                    constraints: pane.constraints.clone(),
                    expected_output: pane.expected_output.clone(),
                    verification_plan: pane.verification_plan.clone(),
                    review_required: pane.review_required,
                    provider_target: pane.provider_target.clone(),
                    agent_role: pane.agent_role.clone(),
                    timeout_policy: pane.timeout_policy.clone(),
                    handoff_refs: pane.handoff_refs.clone(),
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
                phase: pane.phase,
                activity: pane.activity,
                detail: pane.detail,
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

    pub fn explain_projection(&self, run_id: &str) -> Option<LedgerExplainProjection> {
        let evidence_digest = self
            .digest_projection()
            .items
            .into_iter()
            .find(|item| item.run_id == run_id)?;
        let mut panes: Vec<_> = self
            .pane_read_models()
            .into_iter()
            .filter(|pane| pane_matches_digest_item(pane, &evidence_digest))
            .collect();
        panes.sort_by(|left, right| left.label.cmp(&right.label));
        let primary_pane = panes.first()?;
        let action_items: Vec<_> = self
            .inbox_projection()
            .items
            .into_iter()
            .filter(|item| inbox_item_matches_explain_run(item, &evidence_digest, &panes))
            .map(explain_action_item_from_inbox)
            .collect();
        let mut recent_events: Vec<_> = self
            .events
            .iter()
            .enumerate()
            .filter(|(_, event)| event_matches_explain_run(event, &evidence_digest, &panes))
            .collect();
        recent_events.sort_by(|(left_index, left), (right_index, right)| {
            right
                .timestamp
                .cmp(&left.timestamp)
                .then_with(|| right_index.cmp(left_index))
        });
        let recent_event_records = recent_events.clone();
        let recent_events: Vec<_> = recent_events
            .into_iter()
            .map(|(_, event)| explain_recent_event_from_event(event))
            .collect();
        let experiment_packet = explain_experiment_packet(&recent_events, &evidence_digest);
        let security_verdict =
            first_event_value(&recent_events, |event| event.security_verdict.clone());
        let verification_contract =
            first_event_value(&recent_events, |event| event.verification_contract.clone());
        let verification_result =
            first_event_value(&recent_events, |event| event.verification_result.clone());
        let verification_evidence = verification_evidence_from_event_records(&recent_event_records);

        let mut labels = unique_sorted(panes.iter().map(|pane| pane.label.as_str()));
        let mut pane_ids = unique_sorted(panes.iter().map(|pane| pane.pane_id.as_str()));
        let mut roles = unique_sorted(panes.iter().map(|pane| pane.role.as_str()));
        if labels.is_empty() {
            labels.push(evidence_digest.label.clone());
        }
        if pane_ids.is_empty() {
            pane_ids.push(evidence_digest.pane_id.clone());
        }
        if roles.is_empty() {
            roles.push(evidence_digest.role.clone());
        }

        let mut run = LedgerExplainRun {
            run_id: evidence_digest.run_id.clone(),
            task_id: evidence_digest.task_id.clone(),
            parent_run_id: primary_pane.parent_run_id.clone(),
            goal: primary_pane.goal.clone(),
            task: evidence_digest.task.clone(),
            task_type: primary_pane.task_type.clone(),
            priority: primary_pane.priority.clone(),
            blocking: primary_pane.blocking,
            state: primary_pane.state.clone(),
            task_state: evidence_digest.task_state.clone(),
            review_state: evidence_digest.review_state.clone(),
            phase: evidence_digest.phase.clone(),
            activity: evidence_digest.activity.clone(),
            detail: evidence_digest.detail.clone(),
            branch: evidence_digest.branch.clone(),
            head_sha: evidence_digest.head_sha.clone(),
            worktree: evidence_digest.worktree.clone(),
            primary_label: primary_pane.label.clone(),
            primary_pane_id: primary_pane.pane_id.clone(),
            primary_role: primary_pane.role.clone(),
            last_event: evidence_digest.last_event.clone(),
            last_event_at: evidence_digest.last_event_at.clone(),
            tokens_remaining: primary_pane.tokens_remaining.clone(),
            pane_count: panes.len(),
            changed_file_count: evidence_digest.changed_file_count,
            labels,
            pane_ids,
            roles,
            provider_target: evidence_digest.provider_target.clone(),
            agent_role: primary_pane.agent_role.clone(),
            write_scope: primary_pane.write_scope.clone(),
            read_scope: primary_pane.read_scope.clone(),
            constraints: primary_pane.constraints.clone(),
            expected_output: primary_pane.expected_output.clone(),
            verification_plan: primary_pane.verification_plan.clone(),
            review_required: primary_pane.review_required,
            timeout_policy: primary_pane.timeout_policy.clone(),
            handoff_refs: primary_pane.handoff_refs.clone(),
            action_items: action_items.clone(),
            experiment_packet,
            security_policy: manifest_security_policy_value(&primary_pane.security_policy),
            security_verdict,
            verification_contract,
            verification_result,
            verification_evidence,
            context_contract: Value::Null,
            tdd_gate: Value::Null,
            verification_envelope: Value::Null,
            audit_chain: Value::Null,
            outcome: Value::Null,
            phase_gate: Value::Null,
            draft_pr_gate: Value::Null,
            changed_files: evidence_digest.changed_files.clone(),
        };
        run.draft_pr_gate = run_draft_pr_gate_value(&run, &recent_event_records);
        run.tdd_gate = run_tdd_gate_value(&run, &recent_event_records);
        run.phase_gate = run_phase_gate_value(&run, &recent_event_records, &run.draft_pr_gate);
        run.context_contract = context_contract_value(&run.verification_evidence);
        run.audit_chain = run_audit_chain_value(&run, &recent_event_records);
        run.verification_envelope = run_verification_envelope_value(&run);
        run.outcome = run_outcome_value(&run, &run.phase_gate, &run.draft_pr_gate);
        let explanation = explain_explanation(&run, &evidence_digest);

        Some(LedgerExplainProjection {
            run,
            explanation,
            evidence_digest,
            recent_events,
        })
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

pub fn attach_evidence_chain_to_event(
    existing_events_jsonl: &str,
    event: &Value,
) -> Result<Value, String> {
    let existing_records = parse_event_jsonl(existing_events_jsonl)?;
    let existing_chain = build_evidence_chain(existing_events_jsonl, &existing_records)?;
    let previous_hash = existing_chain.summary.root_hash;
    let event_hash = evidence_event_hash(event)?;
    let chain_hash = evidence_chain_hash(&previous_hash, &event_hash);

    let mut event = event.clone();
    let Some(event_object) = event.as_object_mut() else {
        return Err("event record must be a JSON object".to_string());
    };

    let data = event_object
        .entry("data".to_string())
        .or_insert_with(|| Value::Object(serde_json::Map::new()));
    let Some(data_object) = data.as_object_mut() else {
        return Err("event.data must be an object".to_string());
    };

    data_object.insert(
        "evidence_chain".to_string(),
        serde_json::json!({
            "previous_hash": previous_hash,
            "event_hash": event_hash,
            "chain_hash": chain_hash,
        }),
    );

    Ok(event)
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
                phase: pane.phase.clone(),
                activity: pane.activity.clone(),
                detail: pane.detail.clone(),
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
                verification_verdict_summary: empty_verdict_summary("verification"),
                security_verdict_summary: empty_verdict_summary("security"),
                monitoring_verdict_summary: empty_verdict_summary("monitoring"),
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
        set_if_empty(&mut self.item.phase, &pane.phase);
        set_if_empty(&mut self.item.activity, &pane.activity);
        set_if_empty(&mut self.item.detail, &pane.detail);
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
            if let Some(summary) = verdict_summary_from_event("verification", event) {
                self.item.verification_outcome = summary.verdict.clone();
                self.item.verification_verdict_summary = summary;
            }
        }
        if is_security_event(&event.event) {
            if let Some(summary) = verdict_summary_from_event("security", event) {
                self.item.security_blocked = summary.verdict.clone();
                self.item.security_verdict_summary = summary;
            }
        }
        if is_monitoring_event(&event.event) {
            if let Some(summary) = verdict_summary_from_event("monitoring", event) {
                self.item.monitoring_verdict_summary = summary;
            }
        }
    }

    fn into_item(mut self) -> LedgerDigestItem {
        self.item.next_action = run_next_action(
            &self.action_items,
            &self.item.review_state,
            &self.item.task_state,
        );
        let (phase, activity, detail) = run_state_model(
            "",
            &self.item.task_state,
            &self.item.review_state,
            &self.item.next_action,
            &self.item.last_event,
        );
        self.item.phase = phase;
        self.item.activity = activity;
        self.item.detail = detail;
        self.item.action_item_count = self.action_items.len();
        self.item
    }
}

impl LedgerInboxItem {
    fn from_manifest_pane(kind: &str, message: String, pane: &LedgerPaneReadModel) -> Self {
        let (phase, activity, detail) = run_state_model(
            &pane.state,
            &pane.task_state,
            &pane.review_state,
            kind,
            &pane.last_event,
        );
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
            phase,
            activity,
            detail,
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
        let (phase, activity, detail) = run_state_model("", "", "", kind, &event_label);

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
            phase,
            activity,
            detail,
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
        "needs_user_decision",
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

fn run_state_model(
    state: &str,
    task_state: &str,
    review_state: &str,
    event_kind: &str,
    last_event: &str,
) -> (String, String, String) {
    let state_text = state.to_ascii_lowercase();
    let task_text = task_state.to_ascii_lowercase();
    let review_text = review_state.to_ascii_uppercase();
    let kind_text = event_kind.to_ascii_lowercase();
    let event_text = last_event.to_ascii_lowercase();

    if matches!(kind_text.as_str(), "commit_ready" | "task_completed")
        || matches!(
            task_text.as_str(),
            "completed" | "task_completed" | "done" | "commit_ready"
        )
    {
        let detail = if kind_text.is_empty() {
            "task_completed"
        } else {
            kind_text.as_str()
        };
        return ("package".into(), "completed".into(), detail.into());
    }
    if matches!(kind_text.as_str(), "needs_user_decision" | "draft_pr_required")
        || event_text == "operator.draft_pr.required"
    {
        return (
            "package".into(),
            "waiting_for_input".into(),
            "needs_user_decision".into(),
        );
    }
    if matches!(review_text.as_str(), "FAIL" | "FAILED") || kind_text == "review_failed" {
        return ("review".into(), "blocked".into(), "review_failed".into());
    }
    if review_text == "PENDING" || matches!(kind_text.as_str(), "review_pending" | "review_requested")
    {
        let detail = if kind_text == "review_requested" {
            "review_requested"
        } else {
            "review_pending"
        };
        return ("review".into(), "waiting_for_input".into(), detail.into());
    }
    if review_text == "PASS" {
        return (
            "package".into(),
            "waiting_for_input".into(),
            "needs_user_decision".into(),
        );
    }
    if task_text == "blocked"
        || matches!(kind_text.as_str(), "blocked" | "task_blocked")
        || event_text.contains("blocked")
    {
        let detail = if kind_text.is_empty() {
            "task_blocked"
        } else {
            kind_text.as_str()
        };
        return ("build".into(), "blocked".into(), detail.into());
    }
    if matches!(state_text.as_str(), "offline" | "crashed" | "hung" | "bootstrap_invalid")
        || matches!(kind_text.as_str(), "crashed" | "hung" | "bootstrap_invalid")
    {
        let detail = if kind_text.is_empty() {
            state_text.as_str()
        } else {
            kind_text.as_str()
        };
        return ("build".into(), "offline".into(), detail.into());
    }
    if task_text == "backlog" || kind_text == "dispatch_needed" || state_text == "idle" {
        let detail = if !kind_text.is_empty() {
            kind_text.as_str()
        } else if !task_text.is_empty() {
            task_text.as_str()
        } else {
            "idle"
        };
        return ("brainstorm".into(), "waiting_for_input".into(), detail.into());
    }
    if !task_text.is_empty() {
        return ("build".into(), "running".into(), task_text);
    }
    if !state_text.is_empty() {
        let activity = if state_text == "busy" {
            "running"
        } else {
            "waiting_for_input"
        };
        return ("build".into(), activity.into(), state_text);
    }

    ("build".into(), "running".into(), "in_progress".into())
}

fn pane_matches_digest_item(pane: &LedgerPaneReadModel, item: &LedgerDigestItem) -> bool {
    run_id_from_pane(pane) == item.run_id
        || (!pane.task_id.trim().is_empty() && pane.task_id == item.task_id)
        || (!pane.branch.trim().is_empty() && pane.branch == item.branch)
        || (!pane.head_sha.trim().is_empty() && pane.head_sha == item.head_sha)
        || (!pane.label.trim().is_empty() && pane.label == item.label)
        || (!pane.pane_id.trim().is_empty() && pane.pane_id == item.pane_id)
}

fn inbox_item_matches_digest_item(item: &LedgerInboxItem, digest: &LedgerDigestItem) -> bool {
    if !item.task_id.trim().is_empty() {
        return !digest.task_id.trim().is_empty() && item.task_id == digest.task_id;
    }
    (!item.branch.trim().is_empty() && item.branch == digest.branch)
        || (!item.head_sha.trim().is_empty() && item.head_sha == digest.head_sha)
        || (!item.label.trim().is_empty() && item.label == digest.label)
        || (!item.pane_id.trim().is_empty() && item.pane_id == digest.pane_id)
}

fn inbox_item_matches_explain_run(
    item: &LedgerInboxItem,
    digest: &LedgerDigestItem,
    panes: &[LedgerPaneReadModel],
) -> bool {
    if inbox_item_matches_digest_item(item, digest) {
        return true;
    }
    if !item.task_id.trim().is_empty() {
        return false;
    }
    panes.iter().any(|pane| {
        (!item.pane_id.trim().is_empty() && item.pane_id == pane.pane_id)
            || (!item.label.trim().is_empty() && item.label == pane.label)
    })
}

fn event_matches_digest_item(event: &EventRecord, digest: &LedgerDigestItem) -> bool {
    let event_run_id = event_data_string(&event.data, "run_id");
    let event_task_id = event_data_string(&event.data, "task_id");
    let event_branch = event_branch(event);
    let event_head_sha = event_head_sha(event);

    if !event_run_id.trim().is_empty() {
        return event_run_id == digest.run_id;
    }
    if !event_task_id.trim().is_empty() {
        return !digest.task_id.trim().is_empty() && event_task_id == digest.task_id;
    }
    if !event.pane_id.trim().is_empty() {
        return event.pane_id == digest.pane_id;
    }
    if !event.label.trim().is_empty() {
        return event.label == digest.label;
    }
    if !event_branch.trim().is_empty() && !digest.branch.trim().is_empty() {
        return event_branch == digest.branch;
    }
    !event_head_sha.trim().is_empty() && event_head_sha == digest.head_sha
}

fn event_matches_explain_run(
    event: &EventRecord,
    digest: &LedgerDigestItem,
    panes: &[LedgerPaneReadModel],
) -> bool {
    if event_matches_digest_item(event, digest) {
        return true;
    }
    let event_task_id = event_data_string(&event.data, "task_id");
    let event_run_id = event_data_string(&event.data, "run_id");
    if !event_task_id.trim().is_empty() || !event_run_id.trim().is_empty() {
        return false;
    }
    panes.iter().any(|pane| {
        (!event.pane_id.trim().is_empty() && event.pane_id == pane.pane_id)
            || (!event.label.trim().is_empty() && event.label == pane.label)
    })
}

fn explain_action_item_from_inbox(item: LedgerInboxItem) -> LedgerExplainActionItem {
    LedgerExplainActionItem {
        kind: item.kind,
        message: item.message,
        event: item.event,
        timestamp: item.timestamp,
        source: item.source,
    }
}

fn explain_recent_event_from_event(event: &EventRecord) -> LedgerExplainRecentEvent {
    LedgerExplainRecentEvent {
        timestamp: event.timestamp.clone(),
        event: event.event.clone(),
        status: event.status.clone(),
        message: event.message.clone(),
        label: event.label.clone(),
        pane_id: event.pane_id.clone(),
        role: event.role.clone(),
        task_id: event_data_string(&event.data, "task_id"),
        branch: event_branch(event),
        head_sha: event_head_sha(event),
        source: event_data_string(&event.data, "source"),
        hypothesis: event_data_string(&event.data, "hypothesis"),
        test_plan: event_data_string_list_option(&event.data, "test_plan"),
        result: event_data_string(&event.data, "result"),
        confidence: event_data_f64(&event.data, "confidence"),
        next_action: event_data_string(&event.data, "next_action"),
        observation_pack_ref: event_data_string(&event.data, "observation_pack_ref"),
        consultation_ref: event_data_string(&event.data, "consultation_ref"),
        run_id: event_data_string(&event.data, "run_id"),
        slot: event_data_string(&event.data, "slot"),
        worktree: event_data_string(&event.data, "worktree"),
        env_fingerprint: event_data_string(&event.data, "env_fingerprint"),
        command_hash: event_data_string(&event.data, "command_hash"),
        observation_pack: event_data_value(&event.data, "observation_pack"),
        consultation_packet: event_data_value(&event.data, "consultation_packet"),
        verification_contract: event_data_value(&event.data, "verification_contract"),
        verification_result: event_data_value(&event.data, "verification_result"),
        security_verdict: first_non_null_value([
            event_data_value(&event.data, "security_verdict"),
            event_data_value(&event.data, "verdict"),
        ]),
    }
}

fn explain_experiment_packet(
    events: &[LedgerExplainRecentEvent],
    digest: &LedgerDigestItem,
) -> LedgerExplainExperimentPacket {
    let mut hypothesis = String::new();
    let mut test_plan = Vec::new();
    let mut result = String::new();
    let mut confidence = None;
    let mut next_action = String::new();
    let mut observation_pack_ref = String::new();
    let mut consultation_ref = String::new();
    let mut run_id = String::new();
    let mut slot = String::new();
    let mut branch = String::new();
    let mut worktree = String::new();
    let mut env_fingerprint = String::new();
    let mut command_hash = String::new();

    for event in events {
        set_if_empty(&mut hypothesis, &event.hypothesis);
        if test_plan.is_empty() {
            if let Some(event_test_plan) = &event.test_plan {
                if !event_test_plan.is_empty() {
                    test_plan = event_test_plan.clone();
                }
            }
        }
        set_if_empty(&mut result, &event.result);
        if confidence.is_none() {
            confidence = event.confidence;
        }
        set_if_empty(&mut next_action, &event.next_action);
        set_if_empty(&mut observation_pack_ref, &event.observation_pack_ref);
        set_if_empty(&mut consultation_ref, &event.consultation_ref);
        set_if_empty(&mut run_id, &event.run_id);
        set_if_empty(&mut slot, &event.slot);
        set_if_empty(&mut branch, &event.branch);
        set_if_empty(&mut worktree, &event.worktree);
        set_if_empty(&mut env_fingerprint, &event.env_fingerprint);
        set_if_empty(&mut command_hash, &event.command_hash);
    }

    LedgerExplainExperimentPacket {
        hypothesis: first_non_empty(&hypothesis, &digest.hypothesis),
        test_plan,
        result,
        confidence: confidence.or(digest.confidence),
        next_action: first_non_empty(&next_action, &digest.next_action),
        observation_pack_ref: first_non_empty(&observation_pack_ref, &digest.observation_pack_ref),
        consultation_ref: first_non_empty(&consultation_ref, &digest.consultation_ref),
        run_id,
        slot,
        branch: first_non_empty(&branch, &digest.branch),
        worktree,
        env_fingerprint,
        command_hash,
    }
}

fn explain_explanation(
    run: &LedgerExplainRun,
    digest: &LedgerDigestItem,
) -> LedgerExplainExplanation {
    let mut reasons = Vec::new();
    push_reason(&mut reasons, "task_state", &run.task_state);
    push_reason(&mut reasons, "review_state", &run.review_state);
    push_reason(&mut reasons, "last_event", &run.last_event);
    push_reason(&mut reasons, "verification", &digest.verification_outcome);
    push_reason(&mut reasons, "security", &digest.security_blocked);
    for item in run.action_items.iter().take(3) {
        push_reason(&mut reasons, "action", &item.kind);
    }

    LedgerExplainExplanation {
        summary: run.task.clone(),
        reasons,
        next_action: digest.next_action.clone(),
        current_state: LedgerExplainCurrentState {
            state: run.state.clone(),
            task_state: run.task_state.clone(),
            review_state: run.review_state.clone(),
            phase: run.phase.clone(),
            activity: run.activity.clone(),
            detail: run.detail.clone(),
            last_event: run.last_event.clone(),
        },
    }
}

#[derive(Clone)]
struct RunPhaseStage {
    stage: &'static str,
    status: String,
    reason: String,
    event: String,
}

fn set_run_phase_stage(
    stages: &mut [RunPhaseStage],
    name: &str,
    status: &str,
    reason: &str,
    event: &str,
) {
    if let Some(stage) = stages.iter_mut().find(|stage| stage.stage == name) {
        stage.status = status.to_string();
        if !reason.trim().is_empty() {
            stage.reason = reason.to_string();
        }
        if !event.trim().is_empty() {
            stage.event = event.to_string();
        }
    }
}

fn run_phase_gate_value(
    run: &LedgerExplainRun,
    events: &[(usize, &EventRecord)],
    draft_pr_gate: &Value,
) -> Value {
    let order = vec!["plan", "build", "test", "review", "package"];
    let mut stages: Vec<_> = order
        .iter()
        .map(|stage| RunPhaseStage {
            stage: *stage,
            status: "pending".to_string(),
            reason: String::new(),
            event: String::new(),
        })
        .collect();

    if !run.goal.trim().is_empty() || !run.verification_plan.is_empty() {
        set_run_phase_stage(&mut stages, "plan", "completed", "run_plan_recorded", "");
    }
    if !run.task_state.trim().is_empty() {
        set_run_phase_stage(&mut stages, "build", "in_progress", &run.task_state, "");
    }

    let mut stop_reason = String::new();
    let mut stop_stage = String::new();
    let mut ordered_events = events.to_vec();
    ordered_events.sort_by(|(left_index, left), (right_index, right)| {
        left.timestamp
            .cmp(&right.timestamp)
            .then_with(|| left_index.cmp(right_index))
    });

    for (_, event) in ordered_events {
        match event.event.as_str() {
            "pipeline.decompose.completed" => {
                set_run_phase_stage(&mut stages, "plan", "completed", "decomposed", &event.event)
            }
            "pipeline.dispatch.assigned" => set_run_phase_stage(
                &mut stages,
                "build",
                "in_progress",
                "assigned",
                &event.event,
            ),
            "pipeline.collect.completed" => set_run_phase_stage(
                &mut stages,
                "build",
                "completed",
                "collected",
                &event.event,
            ),
            "pipeline.verify.pass" => {
                set_run_phase_stage(
                    &mut stages,
                    "test",
                    "completed",
                    "verification_passed",
                    &event.event,
                );
                if stop_stage == "test" {
                    stop_reason.clear();
                    stop_stage.clear();
                }
            }
            "pipeline.verify.fail" => {
                set_run_phase_stage(
                    &mut stages,
                    "test",
                    "blocked",
                    "verification_failed",
                    &event.event,
                );
                stop_reason = "verification_failed".to_string();
                stop_stage = "test".to_string();
            }
            "pipeline.verify.partial" => {
                set_run_phase_stage(
                    &mut stages,
                    "test",
                    "waiting_for_input",
                    "verification_partial",
                    &event.event,
                );
                stop_reason = "needs_user_decision".to_string();
                stop_stage = "test".to_string();
            }
            "operator.review_requested" => set_run_phase_stage(
                &mut stages,
                "review",
                "waiting_for_input",
                "review_requested",
                &event.event,
            ),
            "operator.review_failed" => {
                set_run_phase_stage(
                    &mut stages,
                    "review",
                    "blocked",
                    "review_failed",
                    &event.event,
                );
                stop_reason = "review_failed".to_string();
                stop_stage = "review".to_string();
            }
            "pipeline.escalate.required" => {
                set_run_phase_stage(
                    &mut stages,
                    "review",
                    "waiting_for_input",
                    "needs_user_decision",
                    &event.event,
                );
                stop_reason = "needs_user_decision".to_string();
                stop_stage = "review".to_string();
            }
            "operator.draft_pr.required" => {
                set_run_phase_stage(
                    &mut stages,
                    "package",
                    "waiting_for_input",
                    "needs_user_decision",
                    &event.event,
                );
                stop_reason = "needs_user_decision".to_string();
                stop_stage = "package".to_string();
            }
            "operator.draft_pr.created" if draft_pr_event_matches_run_head(run, event) => {
                set_run_phase_stage(
                    &mut stages,
                    "package",
                    "waiting_for_input",
                    "draft_pr",
                    &event.event,
                );
                stop_reason = "draft_pr".to_string();
                stop_stage = "package".to_string();
            }
            "operator.commit_ready" => {
                set_run_phase_stage(
                    &mut stages,
                    "package",
                    "completed",
                    "commit_ready",
                    &event.event,
                );
                stop_reason.clear();
                stop_stage.clear();
            }
            _ => {}
        }
    }

    if run.review_state == "PASS" {
        set_run_phase_stage(&mut stages, "review", "completed", "review_passed", "");
        if stop_stage == "review" {
            stop_reason.clear();
            stop_stage.clear();
        }
        let draft_pr_gate_state = value_field_string(draft_pr_gate, "state");
        if !draft_pr_gate_state.trim().is_empty() && draft_pr_gate_state != "passed" {
            set_run_phase_stage(
                &mut stages,
                "package",
                "waiting_for_input",
                "needs_user_decision",
                "",
            );
            stop_reason = "needs_user_decision".to_string();
            stop_stage = "package".to_string();
        }
    } else if run.review_state == "PENDING" {
        set_run_phase_stage(
            &mut stages,
            "review",
            "waiting_for_input",
            "review_pending",
            "",
        );
    } else if matches!(run.review_state.as_str(), "FAIL" | "FAILED") {
        set_run_phase_stage(&mut stages, "review", "blocked", "review_failed", "");
        stop_reason = "review_failed".to_string();
        stop_stage = "review".to_string();
    }

    if matches!(
        run.task_state.as_str(),
        "completed" | "task_completed" | "commit_ready" | "done"
    ) {
        set_run_phase_stage(&mut stages, "build", "completed", &run.task_state, "");
        set_run_phase_stage(&mut stages, "package", "completed", &run.task_state, "");
        if matches!(run.task_state.as_str(), "commit_ready" | "done") {
            stop_reason.clear();
            stop_stage.clear();
        }
    }

    if value_field_string(&run.tdd_gate, "state") == "blocked" {
        set_run_phase_stage(&mut stages, "test", "blocked", "tdd_evidence_missing", "");
        stop_reason = "tdd_evidence_missing".to_string();
        stop_stage = "test".to_string();
    }

    let current_stage = stages
        .iter()
        .rev()
        .find(|stage| stage.status != "pending")
        .map(|stage| stage.stage)
        .unwrap_or("plan");
    let stage_values: Vec<_> = stages
        .iter()
        .map(|stage| {
            json!({
                "stage": stage.stage,
                "status": stage.status,
                "reason": stage.reason,
                "event": stage.event,
            })
        })
        .collect();
    let stop_required = !stop_reason.trim().is_empty();

    json!({
        "order": order,
        "current_stage": current_stage,
        "stages": stage_values,
        "stop_required": stop_required,
        "stop_reason": stop_reason,
        "stop_stage": stop_stage,
        "auto_continue_allowed": !stop_required,
        "requires_human_decision": matches!(stop_reason.as_str(), "needs_user_decision" | "draft_pr"),
    })
}

fn run_requires_tdd_gate(run: &LedgerExplainRun) -> bool {
    let task_type = run.task_type.to_ascii_lowercase();
    matches!(
        task_type.as_str(),
        "bug" | "bugfix" | "fix" | "defect" | "core_logic" | "core-logic" | "core"
    ) || run.changed_files.iter().any(|path| {
        let normalized = path.replace('\\', "/").to_ascii_lowercase();
        normalized.starts_with("core/src/")
            || normalized.starts_with("winsmux-core/scripts/")
            || normalized == "scripts/winsmux-core.ps1"
    })
}

fn run_tdd_gate_value(run: &LedgerExplainRun, events: &[(usize, &EventRecord)]) -> Value {
    let required = run_requires_tdd_gate(run);
    let mut ordered_events = events.to_vec();
    ordered_events.sort_by(|(left_index, left), (right_index, right)| {
        left.timestamp
            .cmp(&right.timestamp)
            .then_with(|| left_index.cmp(right_index))
    });

    let red_event = ordered_events.iter().find(|(_, event)| {
        matches!(
            event.event.as_str(),
            "pipeline.tdd.red"
                | "pipeline.test.red"
                | "pipeline.test_first.fail"
                | "pipeline.test_first.failed"
        ) || event_data_string(&event.data, "tdd_phase").eq_ignore_ascii_case("red")
            || event_data_string(&event.data, "test_first").eq_ignore_ascii_case("true")
    });
    let exception_event = ordered_events.iter().find(|(_, event)| {
        let reason = event_data_string(&event.data, "reason");
        let exception_reason = event_data_string(&event.data, "tdd_exception_reason");
        (event.event == "pipeline.tdd.exception"
            && (!exception_reason.trim().is_empty() || !reason.trim().is_empty()))
            || !exception_reason.trim().is_empty()
            || (event.event == "pipeline.policy.exception" && !reason.trim().is_empty())
    });

    let mut state = "not_required";
    let mut reason = "not_required";
    let mut blocked_reasons: Vec<&str> = Vec::new();
    if required {
        if red_event.is_some() {
            state = "passed";
            reason = "red_test_evidence_recorded";
        } else if exception_event.is_some() {
            state = "waived";
            reason = "exception_recorded";
        } else {
            state = "blocked";
            reason = "tdd_evidence_missing";
            blocked_reasons
                .push("test-first evidence is missing for a bug fix or core logic change");
        }
    }

    let exception_reason = exception_event
        .map(|(_, event)| {
            let explicit = event_data_string(&event.data, "tdd_exception_reason");
            if explicit.trim().is_empty() {
                event_data_string(&event.data, "reason")
            } else {
                explicit
            }
        })
        .unwrap_or_default();

    json!({
        "policy": "test_first_required",
        "required": required,
        "state": state,
        "reason": reason,
        "blocked_reasons": blocked_reasons,
        "exception_reason": exception_reason,
        "red_event": red_event.map(|(_, event)| event.event.clone()).unwrap_or_default(),
        "exception_event": exception_event.map(|(_, event)| event.event.clone()).unwrap_or_default(),
    })
}

fn run_draft_pr_gate_value(run: &LedgerExplainRun, events: &[(usize, &EventRecord)]) -> Value {
    let draft_pr_event = events
        .iter()
        .map(|(_, event)| *event)
        .find(|event| {
            event.event == "operator.draft_pr.created" && draft_pr_event_matches_run_head(run, event)
        });
    let draft_pr_url = draft_pr_event
        .map(|event| event_data_string(&event.data, "draft_pr_url"))
        .unwrap_or_default();
    let trigger = if draft_pr_event.is_some() {
        "operator.draft_pr.created"
    } else {
        "review_state"
    };
    let handoff_package = run_draft_pr_handoff_package_value(run, &draft_pr_url);
    let blocked_count = handoff_package
        .get("blocked_reasons")
        .and_then(|value| value.as_array())
        .map(|items| items.len())
        .unwrap_or(0);
    let state = if blocked_count > 0 {
        "blocked"
    } else if draft_pr_event.is_some() {
        "passed"
    } else {
        "required"
    };

    json!({
        "kind": "human_judgement",
        "target": "draft_pr",
        "state": state,
        "trigger": trigger,
        "draft_pr_url": draft_pr_url,
        "auto_merge_allowed": false,
        "merge_requires_human": true,
        "handoff_package": handoff_package,
    })
}

fn run_draft_pr_handoff_package_value(run: &LedgerExplainRun, draft_pr_url: &str) -> Value {
    let verification_outcome = value_field_string(&run.verification_result, "outcome");
    let verification_summary = value_field_string(&run.verification_result, "summary");
    let verification_next_action = value_field_string(&run.verification_result, "next_action");
    let security_verdict = value_field_string(&run.security_verdict, "verdict");
    let security_reason = value_field_string(&run.security_verdict, "reason");
    let mut blocked_reasons = Vec::new();
    let mut remaining_risks = Vec::new();

    if verification_outcome.trim().is_empty() {
        blocked_reasons.push("verification evidence is missing".to_string());
        remaining_risks.push("verification evidence is missing".to_string());
    }
    if run.review_required && !matches!(run.review_state.as_str(), "PASS" | "FAIL" | "FAILED") {
        let reason = format!("review state is unresolved: {}", run.review_state);
        blocked_reasons.push(reason.clone());
        remaining_risks.push(reason);
    }
    if matches!(run.review_state.as_str(), "FAIL" | "FAILED") {
        let reason = format!("review failed: {}", run.review_state);
        blocked_reasons.push(reason.clone());
        remaining_risks.push(reason);
    }
    if !verification_outcome.trim().is_empty() && verification_outcome != "PASS" {
        remaining_risks.push(format!("verification outcome is {verification_outcome}"));
    }
    if security_verdict == "BLOCK" {
        let reason = if security_reason.trim().is_empty() {
            "security policy blocked the run".to_string()
        } else {
            security_reason
        };
        blocked_reasons.push(reason.clone());
        remaining_risks.push(reason);
    }

    let summary = first_non_empty_string(vec![
        verification_summary.clone(),
        run.experiment_packet.result.clone(),
        run.task.clone(),
        run.goal.clone(),
    ]);
    let mut suggested_next_action = if !blocked_reasons.is_empty() {
        "resolve blocked reasons before creating or merging a draft PR".to_string()
    } else if draft_pr_url.trim().is_empty() {
        "create a draft PR and request human review".to_string()
    } else {
        "human reviewer must decide whether to merge".to_string()
    };
    if !verification_next_action.trim().is_empty() && !blocked_reasons.is_empty() {
        suggested_next_action = verification_next_action.clone();
    }

    json!({
        "summary": summary,
        "validation": {
            "evidence_complete": !verification_outcome.trim().is_empty(),
            "outcome": verification_outcome,
            "summary": verification_summary,
            "next_action": verification_next_action,
            "verification_plan": run.verification_plan.clone(),
            "changed_files": run.changed_files.clone(),
        },
        "remaining_risks": remaining_risks,
        "suggested_next_action": suggested_next_action,
        "blocked_reasons": blocked_reasons,
        "package_complete": blocked_reasons.is_empty(),
        "human_judgement_required": true,
        "automatic_merge_allowed": false,
    })
}

fn run_audit_chain_value(run: &LedgerExplainRun, events: &[(usize, &EventRecord)]) -> Value {
    let mut ordered_events = events.to_vec();
    ordered_events.sort_by(|(left_index, left), (right_index, right)| {
        left.timestamp
            .cmp(&right.timestamp)
            .then_with(|| left_index.cmp(right_index))
    });
    let review_request = ordered_events
        .iter()
        .map(|(_, event)| *event)
        .find(|event| event.event == "operator.review_requested");
    let decision_event = run_audit_chain_decision_event(run, &ordered_events);
    let chain_events: Vec<_> = ordered_events
        .iter()
        .filter(|(_, event)| is_audit_chain_event(&event.event))
        .map(|(_, event)| audit_chain_event_value(event))
        .collect();

    json!({
        "chain_id": run.run_id,
        "subject": {
            "task_id": run.task_id,
            "task": run.task,
            "task_type": run.task_type,
            "priority": run.priority,
            "branch": run.branch,
            "head_sha": run.head_sha,
            "changed_files": run.changed_files,
            "context_contract": run.context_contract,
        },
        "actor": {
            "label": run.primary_label,
            "pane_id": run.primary_pane_id,
            "role": run.primary_role,
            "provider_target": run.provider_target,
            "agent_role": if run.agent_role.trim().is_empty() {
                run.primary_role.clone()
            } else {
                run.agent_role.clone()
            },
        },
        "approval": {
            "required": run.review_required,
            "state": audit_chain_approval_state(&run.review_state, run.review_required),
            "verdict": run.review_state,
            "requested_at": review_request.map(|event| event_timestamp_text(&event.timestamp)).unwrap_or_default(),
            "requested_event": review_request.map(|event| event.event.clone()).unwrap_or_default(),
            "requested_reviewer_label": review_request.map(|event| event.label.clone()).unwrap_or_default(),
            "requested_reviewer_pane": review_request.map(|event| event.pane_id.clone()).unwrap_or_default(),
            "requested_reviewer_role": review_request.map(|event| event.role.clone()).unwrap_or_default(),
            "decided_at": decision_event.map(|event| event_timestamp_text(&event.timestamp)).unwrap_or_default(),
            "decided_event": decision_event.map(|event| event.event.clone()).unwrap_or_default(),
            "human_judgement_required": run.review_required,
            "automatic_merge_allowed": false,
        },
        "events": chain_events,
    })
}

fn audit_chain_approval_state(review_state: &str, review_required: bool) -> &'static str {
    if review_state.eq_ignore_ascii_case("PASS") {
        "approved"
    } else if review_state.eq_ignore_ascii_case("FAIL")
        || review_state.eq_ignore_ascii_case("FAILED")
    {
        "failed"
    } else if review_state.eq_ignore_ascii_case("PENDING") {
        "pending"
    } else if review_required {
        "missing"
    } else {
        "not_required"
    }
}

fn run_audit_chain_decision_event<'a>(
    run: &LedgerExplainRun,
    events: &'a [(usize, &EventRecord)],
) -> Option<&'a EventRecord> {
    let decision_events: &[&str] = if run.review_state.eq_ignore_ascii_case("PASS") {
        &["operator.review_passed", "review.pass"]
    } else if run.review_state.eq_ignore_ascii_case("FAIL")
        || run.review_state.eq_ignore_ascii_case("FAILED")
    {
        &["operator.review_failed", "review.fail"]
    } else {
        &[]
    };
    if decision_events.is_empty() {
        return None;
    }

    events
        .iter()
        .map(|(_, event)| *event)
        .find(|event| decision_events.contains(&event.event.as_str()))
}

fn is_audit_chain_event(event: &str) -> bool {
    matches!(
        event,
        "operator.review_requested"
            | "operator.review_passed"
            | "operator.review_failed"
            | "review.pass"
            | "review.fail"
            | "pane.approval_waiting"
            | "pipeline.tdd.red"
            | "pipeline.tdd.exception"
            | "pipeline.verify.pass"
            | "pipeline.verify.fail"
            | "pipeline.verify.partial"
            | "pipeline.security.allowed"
            | "pipeline.security.blocked"
            | "security.policy.allowed"
            | "security.policy.blocked"
            | "operator.draft_pr.created"
            | "operator.draft_pr.required"
    )
}

fn audit_chain_event_value(event: &EventRecord) -> Value {
    let action = event_data_string(&event.data, "action");
    let what = if action.trim().is_empty() {
        event.event.clone()
    } else {
        action
    };

    json!({
        "at": event_timestamp_text(&event.timestamp),
        "event": event.event,
        "who": {
            "label": event.label,
            "pane_id": event.pane_id,
            "role": event.role,
        },
        "what": what,
        "task_id": event_data_string(&event.data, "task_id"),
        "run_id": event_data_string(&event.data, "run_id"),
        "branch": event_branch(event),
        "head_sha": event_head_sha(event),
        "message": event.message,
    })
}

fn run_verification_envelope_value(run: &LedgerExplainRun) -> Value {
    let verification_outcome = value_field_string(&run.verification_result, "outcome");
    let verification_summary = value_field_string(&run.verification_result, "summary");
    let verification_next_action = value_field_string(&run.verification_result, "next_action");
    let security_verdict = first_non_empty(
        &value_field_string(&run.security_verdict, "verdict"),
        run.security_verdict.as_str().unwrap_or_default(),
    );
    let security_reason = value_field_string(&run.security_verdict, "reason");
    let approval = run
        .audit_chain
        .get("approval")
        .cloned()
        .unwrap_or(Value::Null);
    let approval_state = value_field_string(&approval, "state");
    let audit_events = run
        .audit_chain
        .get("events")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let draft_pr_gate_state = value_field_string(&run.draft_pr_gate, "state");
    let phase_gate_stop_reason = value_field_string(&run.phase_gate, "stop_reason");
    let phase_gate_stop_stage = value_field_string(&run.phase_gate, "stop_stage");
    let evidence_complete = !verification_outcome.trim().is_empty()
        && !run.verification_evidence.is_null()
        && !run.audit_chain.is_null();

    let mut blocked_reasons = Vec::new();
    if verification_outcome.trim().is_empty() {
        blocked_reasons.push("verification evidence is missing".to_string());
    } else if verification_outcome != "PASS" {
        blocked_reasons.push(format!("verification outcome is {verification_outcome}"));
    }
    if security_verdict == "BLOCK" {
        blocked_reasons.push(if security_reason.trim().is_empty() {
            "security policy blocked the run".to_string()
        } else {
            security_reason.clone()
        });
    }
    if run.review_required && approval_state != "approved" {
        blocked_reasons.push(format!(
            "approval state is unresolved: {}",
            first_non_empty(&approval_state, &run.review_state)
        ));
    }
    if !draft_pr_gate_state.trim().is_empty() && draft_pr_gate_state != "passed" {
        blocked_reasons.push(format!("draft PR gate is {draft_pr_gate_state}"));
    }
    if !phase_gate_stop_reason.trim().is_empty() {
        let stage = if phase_gate_stop_stage.trim().is_empty() {
            "unknown"
        } else {
            phase_gate_stop_stage.as_str()
        };
        blocked_reasons.push(format!(
            "phase gate stopped at {stage}: {phase_gate_stop_reason}"
        ));
    }

    let human_judgement_required = run.review_required
        || !draft_pr_gate_state.trim().is_empty() && draft_pr_gate_state != "passed"
        || phase_gate_stop_reason == "needs_user_decision";

    let status = if !blocked_reasons.is_empty() {
        "blocked"
    } else if human_judgement_required {
        "approved"
    } else {
        "ready"
    };

    json!({
        "contract_version": 1,
        "packet_type": "verification_envelope",
        "scope": "release_run",
        "run_id": run.run_id,
        "task_id": run.task_id,
        "static_gates": {
            "verification_plan": run.verification_plan,
            "changed_files": run.changed_files,
            "review_required": run.review_required,
            "required_fields": [
                "verification_evidence",
                "context_contract",
                "security_verdict",
                "audit_chain",
                "draft_pr_gate",
                "phase_gate"
            ]
        },
        "dynamic_gates": {
            "verification": {
                "outcome": verification_outcome,
                "summary": verification_summary,
                "next_action": verification_next_action,
                "evidence_complete": evidence_complete
            },
            "security": {
                "verdict": security_verdict,
                "reason": security_reason,
                "blocked": security_verdict == "BLOCK"
            },
            "approval": approval,
            "context": run.context_contract,
            "draft_pr": run.draft_pr_gate,
            "phase": run.phase_gate,
            "audit": {
                "chain_id": value_field_string(&run.audit_chain, "chain_id"),
                "event_count": audit_events,
                "last_event": run.last_event
            }
        },
        "release_decision": {
            "status": status,
            "blocked_reasons": blocked_reasons,
            "human_judgement_required": human_judgement_required,
            "automatic_merge_allowed": false
        },
        "verification_evidence": run.verification_evidence,
        "context_contract": run.context_contract,
        "security_verdict": run.security_verdict,
        "audit_chain": run.audit_chain,
    })
}

fn event_timestamp_text(timestamp: &str) -> String {
    DateTime::parse_from_rfc3339(timestamp)
        .map(|value| {
            value
                .with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::Secs, true)
        })
        .unwrap_or_else(|_| timestamp.to_string())
}

fn run_outcome_value(run: &LedgerExplainRun, phase_gate: &Value, draft_pr_gate: &Value) -> Value {
    let phase_gate_stop_reason = value_field_string(phase_gate, "stop_reason");
    let draft_pr_gate_state = value_field_string(draft_pr_gate, "state");
    let status = if matches!(run.review_state.as_str(), "FAIL" | "FAILED") {
        "failed".to_string()
    } else if phase_gate_stop_reason == "needs_user_decision" {
        "needs_user_decision".to_string()
    } else if !phase_gate_stop_reason.trim().is_empty() {
        "blocked".to_string()
    } else if run.review_state == "PASS" && draft_pr_gate_state != "passed" {
        "needs_user_decision".to_string()
    } else if run.review_state == "PASS"
        || matches!(
            run.task_state.as_str(),
            "completed" | "task_completed" | "commit_ready" | "done"
        )
    {
        "completed".to_string()
    } else if run.task_state == "blocked" {
        "blocked".to_string()
    } else if run.task_state == "in_progress" {
        "in_progress".to_string()
    } else {
        run.task_state.clone()
    };

    let reason = first_non_empty_string(vec![
        value_field_string(&run.verification_result, "summary"),
        run.experiment_packet.result.clone(),
        run.last_event.clone(),
    ]);

    json!({
        "status": status,
        "reason": reason,
        "confidence": run.experiment_packet.confidence,
        "source_event": run.last_event,
    })
}

fn draft_pr_event_matches_run_head(run: &LedgerExplainRun, event: &EventRecord) -> bool {
    if run.head_sha.trim().is_empty() {
        return true;
    }
    let event_head_sha = event_head_sha(event);
    !event_head_sha.trim().is_empty() && event_head_sha == run.head_sha
}

fn value_field_string(value: &Value, key: &str) -> String {
    value
        .as_object()
        .and_then(|map| map.get(key))
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string()
}

fn value_field(value: &Value, key: &str) -> Value {
    value
        .as_object()
        .and_then(|map| map.get(key))
        .cloned()
        .unwrap_or(Value::Null)
}

fn push_reason(reasons: &mut Vec<String>, key: &str, value: &str) {
    if !value.trim().is_empty() {
        let separator = if key == "action" { ":" } else { "=" };
        reasons.push(format!("{key}{separator}{value}"));
    }
}

fn event_data_value(data: &Value, key: &str) -> Value {
    data.as_object()
        .and_then(|map| map.get(key))
        .cloned()
        .unwrap_or(Value::Null)
}

fn verification_evidence_from_event_records(events: &[(usize, &EventRecord)]) -> Value {
    events
        .iter()
        .filter(|(_, event)| is_verification_event(&event.event))
        .map(|(_, event)| verification_evidence_value(&event.data))
        .find(|value| !value.is_null())
        .unwrap_or(Value::Null)
}

fn verification_evidence_value(data: &Value) -> Value {
    if !data.is_object() {
        return Value::Null;
    }

    json!({
        "build": verification_evidence_field(data, "build"),
        "test": verification_evidence_field(data, "test"),
        "browser": verification_evidence_field(data, "browser"),
        "screenshot": verification_evidence_field(data, "screenshot"),
        "recording": verification_evidence_field(data, "recording"),
        "context_budget": verification_evidence_field(data, "context_budget"),
        "context_estimate": verification_evidence_field(data, "context_estimate"),
        "context_pack_id": verification_evidence_field(data, "context_pack_id"),
        "context_pack_version": verification_evidence_field(data, "context_pack_version"),
        "tool_output_pruned_count": verification_evidence_field(data, "tool_output_pruned_count"),
        "context_pressure": verification_evidence_field(data, "context_pressure"),
        "context_mode": verification_evidence_field(data, "context_mode"),
        "context_fork_reason": verification_evidence_field(data, "context_fork_reason"),
    })
}

fn context_contract_value(verification_evidence: &Value) -> Value {
    let requested_mode = value_field_string(verification_evidence, "context_mode");
    let fork_reason = value_field_string(verification_evidence, "context_fork_reason");
    let context_mode =
        if requested_mode.eq_ignore_ascii_case("fork") && !fork_reason.trim().is_empty() {
            "fork"
        } else {
            "isolated"
        };
    let fork_reason_value = if context_mode == "fork" {
        Value::String(fork_reason)
    } else {
        Value::Null
    };

    json!({
        "contract_version": 1,
        "packet_type": "context_budget_contract",
        "scope": "run",
        "context_pack_id": value_field(verification_evidence, "context_pack_id"),
        "context_pack_version": value_field(verification_evidence, "context_pack_version"),
        "context_budget": value_field(verification_evidence, "context_budget"),
        "context_estimate": value_field(verification_evidence, "context_estimate"),
        "context_pressure": value_field(verification_evidence, "context_pressure"),
        "tool_output_pruned_count": value_field(verification_evidence, "tool_output_pruned_count"),
        "context_mode": context_mode,
        "fork_reason": fork_reason_value,
        "fork_allowed": context_mode == "fork",
        "prompt_body_stored": false,
        "private_memory_stored": false,
        "local_reference_paths_stored": false,
        "tool_output_pruning": {
            "evidence_only": true,
            "raw_tool_output_stored": false
        }
    })
}

fn verification_evidence_field(data: &Value, key: &str) -> Value {
    for container_name in [
        "verification_evidence",
        "verification_result",
        "verification_contract",
    ] {
        let nested = data
            .as_object()
            .and_then(|map| map.get(container_name))
            .and_then(|container| container.as_object())
            .and_then(|container| container.get(key))
            .cloned();
        if let Some(value) = nested {
            return value;
        }
    }

    event_data_value(data, key)
}

fn event_data_string_list_option(data: &Value, key: &str) -> Option<Vec<String>> {
    data.as_object()
        .and_then(|map| map.get(key))
        .and_then(|value| {
            if let Some(items) = value.as_array() {
                Some(
                    items
                        .iter()
                        .filter_map(|item| item.as_str())
                        .map(str::to_string)
                        .filter(|item| !item.trim().is_empty())
                        .collect(),
                )
            } else {
                value.as_str().map(|text| {
                    text.split('|')
                        .map(str::trim)
                        .filter(|item| !item.is_empty())
                        .map(str::to_string)
                        .collect()
                })
            }
        })
}

fn manifest_security_policy_value(raw: &str) -> Value {
    if raw.trim().is_empty() {
        return Value::Null;
    }
    serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()))
}

fn first_event_value<F>(events: &[LedgerExplainRecentEvent], selector: F) -> Value
where
    F: Fn(&LedgerExplainRecentEvent) -> Value,
{
    events
        .iter()
        .map(selector)
        .find(|value| !value.is_null())
        .unwrap_or(Value::Null)
}

fn first_non_null_value<const N: usize>(values: [Value; N]) -> Value {
    values
        .into_iter()
        .find(|value| !value.is_null())
        .unwrap_or(Value::Null)
}

fn first_non_empty(primary: &str, fallback: &str) -> String {
    if !primary.trim().is_empty() {
        primary.to_string()
    } else {
        fallback.to_string()
    }
}

fn build_evidence_chain(
    events_jsonl: &str,
    events: &[EventRecord],
) -> Result<LedgerEvidenceChainProjection, String> {
    let mut entries = Vec::new();
    let mut previous_hash = String::new();

    for (index, line) in events_jsonl
        .lines()
        .filter(|line| !line.trim().is_empty())
        .enumerate()
    {
        let event_value: Value = serde_json::from_str(line)
            .map_err(|err| format!("failed to parse event line {}: {}", index + 1, err))?;
        let event = events
            .get(index)
            .ok_or_else(|| format!("event line {} did not produce a typed record", index + 1))?;
        let event_hash = evidence_event_hash(&event_value)?;
        let chain_hash = evidence_chain_hash(&previous_hash, &event_hash);
        let recorded_previous_hash = evidence_chain_field(&event_value, "previous_hash");
        let recorded_event_hash = evidence_chain_field(&event_value, "event_hash");
        let recorded_chain_hash = evidence_chain_field(&event_value, "chain_hash");
        let integrity_status = evidence_integrity_status(
            &previous_hash,
            &event_hash,
            &chain_hash,
            &recorded_previous_hash,
            &recorded_event_hash,
            &recorded_chain_hash,
        );

        entries.push(LedgerEvidenceChainEntry {
            index,
            timestamp: event.timestamp.clone(),
            event: event.event.clone(),
            previous_hash: previous_hash.clone(),
            event_hash,
            chain_hash: chain_hash.clone(),
            recorded_previous_hash,
            recorded_event_hash,
            recorded_chain_hash,
            integrity_status,
        });
        previous_hash = chain_hash;
    }

    let recorded_count = entries
        .iter()
        .filter(|entry| {
            !entry.recorded_previous_hash.trim().is_empty()
                || !entry.recorded_event_hash.trim().is_empty()
                || !entry.recorded_chain_hash.trim().is_empty()
        })
        .count();
    let verified_count = entries
        .iter()
        .filter(|entry| entry.integrity_status == "verified")
        .count();
    let tamper_detected_count = entries
        .iter()
        .filter(|entry| entry.integrity_status == "tamper_detected")
        .count();
    let integrity_status = if tamper_detected_count > 0 {
        "tamper_detected"
    } else if recorded_count == entries.len() && !entries.is_empty() {
        "verified"
    } else {
        "partial"
    }
    .to_string();

    Ok(LedgerEvidenceChainProjection {
        summary: LedgerEvidenceChainSummary {
            entry_count: entries.len(),
            recorded_count,
            verified_count,
            tamper_detected_count,
            root_hash: previous_hash,
            integrity_status,
        },
        entries,
    })
}

fn evidence_event_hash(event: &Value) -> Result<String, String> {
    let mut event = event.clone();
    if let Some(data) = event.get_mut("data").and_then(Value::as_object_mut) {
        data.remove("evidence_chain");
    }
    let canonical = serde_json::to_string(&event)
        .map_err(|err| format!("failed to serialize event for evidence hash: {err}"))?;
    Ok(sha256_hex(canonical.as_bytes()))
}

fn evidence_chain_hash(previous_hash: &str, event_hash: &str) -> String {
    let payload = format!("{previous_hash}\n{event_hash}");
    sha256_hex(payload.as_bytes())
}

fn evidence_chain_field(event: &Value, field: &str) -> String {
    event
        .get("data")
        .and_then(|data| data.get("evidence_chain"))
        .and_then(|chain| chain.get(field))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn evidence_integrity_status(
    previous_hash: &str,
    event_hash: &str,
    chain_hash: &str,
    recorded_previous_hash: &str,
    recorded_event_hash: &str,
    recorded_chain_hash: &str,
) -> String {
    if recorded_previous_hash.trim().is_empty()
        && recorded_event_hash.trim().is_empty()
        && recorded_chain_hash.trim().is_empty()
    {
        return "unrecorded".to_string();
    }

    if recorded_previous_hash == previous_hash
        && recorded_event_hash == event_hash
        && recorded_chain_hash == chain_hash
    {
        return "verified".to_string();
    }

    "tamper_detected".to_string()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unique_sorted<'a, I>(values: I) -> Vec<String>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut values: Vec<_> = values
        .into_iter()
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    values.sort();
    values
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
        "approval_waiting" | "needs_user_decision" | "review_requested" | "review_pending" => 1,
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
        "operator.draft_pr.required" => "needs_user_decision",
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

fn event_data_value_string(data: &Value, key: &str) -> String {
    event_data_string_option(data, key).unwrap_or_default()
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

fn empty_verdict_summary(kind: &str) -> LedgerVerdictSummary {
    LedgerVerdictSummary {
        kind: kind.to_string(),
        verdict: String::new(),
        summary: String::new(),
        event: String::new(),
        timestamp: String::new(),
    }
}

fn verdict_summary_from_event(kind: &str, event: &EventRecord) -> Option<LedgerVerdictSummary> {
    let verdict = match kind {
        "verification" => first_non_empty_string(vec![
            event_data_nested_string(&event.data, "verification_result", "outcome")
                .unwrap_or_default(),
            event_data_value_string(&event.data, "verification_result"),
            event_data_value_string(&event.data, "outcome"),
            verification_event_default_verdict(&event.event).to_string(),
            event_status_verification_verdict(&event.status),
        ]),
        "security" => first_non_empty_string(vec![
            event_data_nested_string(&event.data, "security_verdict", "verdict")
                .unwrap_or_default(),
            event_data_value_string(&event.data, "security_verdict"),
            event_data_value_string(&event.data, "verdict"),
            security_event_default_verdict(&event.event).to_string(),
            event_status_security_verdict(&event.status),
        ]),
        "monitoring" => first_non_empty_string(vec![
            event_data_value_string(&event.data, "verdict"),
            event_data_value_string(&event.data, "status"),
            event.status.clone(),
        ]),
        _ => String::new(),
    };
    let summary = match kind {
        "verification" => first_non_empty_string(vec![
            event_data_nested_string(&event.data, "verification_result", "summary")
                .unwrap_or_default(),
            event_data_value_string(&event.data, "summary"),
            event.message.clone(),
        ]),
        "security" => first_non_empty_string(vec![
            event_data_nested_string(&event.data, "security_verdict", "summary")
                .unwrap_or_default(),
            event_data_nested_string(&event.data, "security_verdict", "reason").unwrap_or_default(),
            event_data_value_string(&event.data, "summary"),
            event_data_value_string(&event.data, "reason"),
            event.message.clone(),
        ]),
        "monitoring" => first_non_empty_string(vec![
            event_data_value_string(&event.data, "summary"),
            event.message.clone(),
        ]),
        _ => String::new(),
    };

    if verdict.trim().is_empty() && summary.trim().is_empty() {
        return None;
    }

    Some(LedgerVerdictSummary {
        kind: kind.to_string(),
        verdict,
        summary,
        event: event.event.clone(),
        timestamp: event.timestamp.clone(),
    })
}

fn first_non_empty_string(values: Vec<String>) -> String {
    values
        .into_iter()
        .find(|value| !value.trim().is_empty())
        .unwrap_or_default()
}

fn verification_event_default_verdict(event_name: &str) -> &'static str {
    match event_name {
        "pipeline.verify.pass" => "PASS",
        "pipeline.verify.fail" => "FAIL",
        "pipeline.verify.partial" => "PARTIAL",
        _ => "",
    }
}

fn event_status_verification_verdict(status: &str) -> String {
    match status {
        "PASS" | "FAIL" | "PARTIAL" => status.to_string(),
        _ => String::new(),
    }
}

fn security_event_default_verdict(event_name: &str) -> &'static str {
    match event_name {
        "pipeline.security.allowed" | "security.policy.allowed" => "ALLOW",
        "pipeline.security.blocked" | "security.policy.blocked" => "BLOCK",
        _ => "",
    }
}

fn event_status_security_verdict(status: &str) -> String {
    match status {
        "ALLOW" | "BLOCK" => status.to_string(),
        _ => String::new(),
    }
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

fn is_monitoring_event(event_name: &str) -> bool {
    matches!(event_name, "monitor.status")
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
        .then_with(|| inbox_source_rank(&left.source).cmp(&inbox_source_rank(&right.source)))
        .then_with(|| right.timestamp.cmp(&left.timestamp))
        .then_with(|| left.label.cmp(&right.label))
}

fn inbox_source_rank(source: &str) -> usize {
    match source {
        "manifest" => 0,
        "events" => 1,
        _ => 2,
    }
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
