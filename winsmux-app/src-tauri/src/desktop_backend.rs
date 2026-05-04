use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const DESKTOP_JSON_RPC_VERSION: &str = "2.0";
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_INTERNAL_ERROR: i32 = -32603;
const JSON_RPC_SERVER_ERROR: i32 = -32000;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Serialize, Deserialize)]
pub struct DesktopBoardSummary {
    pub pane_count: usize,
    pub dirty_panes: usize,
    pub review_pending: usize,
    pub review_failed: usize,
    pub review_passed: usize,
    pub tasks_in_progress: usize,
    pub tasks_blocked: usize,
    pub by_state: HashMap<String, usize>,
    pub by_review: HashMap<String, usize>,
    pub by_task_state: HashMap<String, usize>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopBoardSnapshot {
    pub summary: DesktopBoardSummary,
    pub panes: Vec<DesktopBoardPane>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopInboxSummary {
    pub item_count: usize,
    pub by_kind: HashMap<String, usize>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopInboxItem {
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
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
    pub detail: String,
    pub branch: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub event: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopInboxSnapshot {
    pub summary: DesktopInboxSummary,
    pub items: Vec<DesktopInboxItem>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopDigestSummary {
    pub item_count: usize,
    pub dirty_items: usize,
    pub actionable_items: usize,
    pub review_pending: usize,
    pub review_failed: usize,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopBoardPane {
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub state: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
    pub detail: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub changed_file_count: usize,
    pub last_event_at: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopDigestItem {
    pub run_id: String,
    pub task_id: String,
    pub task: String,
    pub label: String,
    pub pane_id: String,
    pub role: String,
    pub provider_target: String,
    pub task_state: String,
    pub review_state: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
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
    pub verification_outcome: String,
    pub security_blocked: String,
    pub hypothesis: String,
    pub confidence: Option<f64>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
    pub last_event_at: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopDigestSnapshot {
    pub summary: DesktopDigestSummary,
    pub items: Vec<DesktopDigestItem>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopSummarySnapshot {
    pub generated_at: String,
    pub project_dir: String,
    pub board: DesktopBoardSnapshot,
    pub inbox: DesktopInboxSnapshot,
    pub digest: DesktopDigestSnapshot,
    pub run_projections: Vec<DesktopRunProjection>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DesktopSummaryRefreshSignal {
    pub source: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopRunProjection {
    pub run_id: String,
    pub pane_id: String,
    pub label: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub head_short: String,
    pub provider_target: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
    pub detail: String,
    pub verification_outcome: String,
    pub security_blocked: String,
    pub changed_files: Vec<String>,
    pub next_action: String,
    pub summary: String,
    pub reasons: Vec<String>,
    pub hypothesis: String,
    pub confidence: Option<f64>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopEditorFilePayload {
    pub path: String,
    pub content: String,
    pub line_count: usize,
    pub truncated: bool,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplorerEntry {
    pub path: String,
    pub kind: String,
    pub has_children: Option<bool>,
    pub ignored: bool,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplorerListPayload {
    pub project_dir: String,
    pub worktree: String,
    pub entries: Vec<DesktopExplorerEntry>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopPromoteTacticResult {
    pub generated_at: String,
    pub run_id: String,
    pub candidate_ref: String,
    pub candidate_path: String,
    pub candidate: DesktopPromoteTacticCandidate,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopPromoteTacticCandidate {
    pub packet_type: String,
    pub kind: String,
    pub title: String,
    pub summary: String,
    pub hypothesis: String,
    pub next_action: String,
    #[serde(default)]
    pub confidence: Option<f64>,
    #[serde(default)]
    pub changed_files: Vec<String>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopCompareRunsResult {
    pub generated_at: String,
    pub left: DesktopCompareRunSide,
    pub right: DesktopCompareRunSide,
    pub shared_changed_files: Vec<String>,
    pub left_only_changed_files: Vec<String>,
    pub right_only_changed_files: Vec<String>,
    #[serde(default)]
    pub confidence_delta: Option<f64>,
    #[serde(default)]
    pub differences: Vec<DesktopCompareDifference>,
    pub recommend: DesktopCompareRecommendation,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopCompareRunSide {
    pub run_id: String,
    pub label: String,
    pub branch: String,
    pub task_state: String,
    pub review_state: String,
    pub state: String,
    pub next_action: String,
    #[serde(default)]
    pub confidence: Option<f64>,
    #[serde(default)]
    pub changed_files: Vec<String>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
    pub recommendable: bool,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopCompareDifference {
    pub field: String,
    pub left: Value,
    pub right: Value,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopCompareRecommendation {
    pub winning_run_id: String,
    pub reconcile_consult: bool,
    pub next_action: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopPickWinnerResult {
    pub run_id: String,
    pub task_id: String,
    pub pane_id: String,
    pub slot: String,
    pub kind: String,
    pub mode: String,
    pub target_slot: String,
    pub recommendation: String,
    pub confidence: Option<f64>,
    pub next_test: String,
    #[serde(default)]
    pub risks: Vec<String>,
    pub consultation_ref: String,
    pub generated_at: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainPayload {
    pub generated_at: String,
    pub project_dir: String,
    pub run: DesktopExplainRun,
    pub explanation: DesktopExplainExplanation,
    pub observation_pack: DesktopExplainObservationPack,
    pub consultation_packet: DesktopExplainConsultationPacket,
    pub evidence_digest: DesktopExplainEvidenceDigest,
    #[serde(default)]
    pub review_state: Option<DesktopReviewStateRecord>,
    #[serde(default)]
    pub recent_events: Vec<DesktopExplainRecentEvent>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainRun {
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
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
    pub detail: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
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
    pub experiment_packet: DesktopExplainExperimentPacket,
    pub security_policy: Value,
    pub security_verdict: Value,
    pub verification_contract: Value,
    pub verification_result: Value,
    #[serde(default)]
    pub changed_files: Vec<String>,
    #[serde(default)]
    pub action_items: Vec<DesktopExplainActionItem>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainExperimentPacket {
    pub hypothesis: String,
    pub test_plan: Vec<String>,
    pub result: String,
    pub confidence: f64,
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

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainExplanation {
    pub summary: String,
    #[serde(default)]
    pub reasons: Vec<String>,
    pub next_action: String,
    pub current_state: DesktopExplainCurrentState,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainCurrentState {
    pub state: String,
    pub task_state: String,
    pub review_state: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub activity: String,
    #[serde(default)]
    pub detail: String,
    pub last_event: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainConsultationPacket {
    pub run_id: String,
    pub task_id: String,
    pub pane_id: String,
    pub slot: String,
    pub kind: String,
    pub mode: String,
    pub target_slot: String,
    pub confidence: f64,
    pub recommendation: String,
    pub next_test: String,
    pub risks: Vec<String>,
    pub generated_at: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainObservationPack {
    pub run_id: String,
    pub task_id: String,
    pub pane_id: String,
    pub slot: String,
    pub hypothesis: String,
    pub test_plan: Vec<String>,
    pub changed_files: Vec<String>,
    pub working_tree_summary: String,
    pub failing_command: String,
    pub env_fingerprint: String,
    pub command_hash: String,
    pub generated_at: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainEvidenceDigest {
    pub next_action: String,
    pub changed_file_count: usize,
    #[serde(default)]
    pub changed_files: Vec<String>,
    pub verification_outcome: String,
    pub security_blocked: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainActionItem {
    pub kind: String,
    pub message: String,
    pub event: String,
    pub timestamp: String,
    pub source: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopExplainRecentEvent {
    pub timestamp: String,
    pub event: String,
    pub label: String,
    pub message: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewStateRecord {
    pub status: String,
    pub branch: String,
    pub head_sha: String,
    pub request: DesktopReviewStateRequest,
    pub reviewer: DesktopReviewStateReviewer,
    #[serde(rename = "updatedAt")]
    pub updated_at: String,
    #[serde(default)]
    pub evidence: Option<DesktopReviewStateEvidence>,
}

#[allow(dead_code)]
pub type DesktopReviewStateSnapshot = BTreeMap<String, DesktopReviewStateRecord>;

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewStateRequest {
    #[serde(default)]
    pub id: Option<String>,
    pub branch: String,
    pub head_sha: String,
    #[serde(default)]
    pub target_review_pane_id: Option<String>,
    #[serde(default)]
    pub target_review_label: Option<String>,
    #[serde(default)]
    pub target_review_role: Option<String>,
    #[serde(default)]
    pub target_reviewer_pane_id: Option<String>,
    #[serde(default)]
    pub target_reviewer_label: Option<String>,
    #[serde(default)]
    pub target_reviewer_role: Option<String>,
    pub review_contract: DesktopReviewContract,
    #[serde(default)]
    pub dispatched_at: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewStateReviewer {
    pub pane_id: String,
    pub label: String,
    pub role: String,
    #[serde(default)]
    pub agent_name: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewStateEvidence {
    #[serde(default)]
    pub approved_at: Option<String>,
    #[serde(default)]
    pub approved_via: Option<String>,
    #[serde(default)]
    pub failed_at: Option<String>,
    #[serde(default)]
    pub failed_via: Option<String>,
    pub review_contract_snapshot: DesktopReviewContract,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewContract {
    pub version: u32,
    pub source_task: String,
    pub issue_ref: String,
    pub style: String,
    pub required_scope: Vec<String>,
    pub checklist_labels: Vec<String>,
    #[serde(default)]
    pub pathspec_policy: Option<DesktopReviewPathspecPolicy>,
    pub rationale: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopReviewPathspecPolicy {
    pub source_task: String,
    pub issue_ref: String,
    pub include_definition_hosts: bool,
    pub incomplete_scope_is_review_gap: bool,
}

#[derive(Deserialize)]
pub struct DesktopJsonRpcRequest {
    pub jsonrpc: String,
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct DesktopJsonRpcError {
    pub code: i32,
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(untagged)]
pub enum DesktopJsonRpcResponse {
    Success {
        jsonrpc: String,
        id: Value,
        result: Value,
    },
    Error {
        jsonrpc: String,
        id: Value,
        error: DesktopJsonRpcError,
    },
}

pub enum DesktopCommand {
    SummarySnapshot {
        project_dir: Option<String>,
    },
    RunExplain {
        run_id: String,
        project_dir: Option<String>,
    },
    RunCompare {
        left_run_id: String,
        right_run_id: String,
        project_dir: Option<String>,
    },
    RunPromote {
        run_id: String,
        project_dir: Option<String>,
    },
    RunPickWinner {
        run_id: String,
        peer_slot: String,
        recommendation: String,
        confidence: Option<f64>,
        next_test: String,
        project_dir: Option<String>,
    },
}

pub enum DesktopStreamCommand {
    Summary { project_dir: Option<String> },
}

impl DesktopCommand {
    fn project_dir(&self) -> Option<&str> {
        match self {
            DesktopCommand::SummarySnapshot { project_dir } => project_dir.as_deref(),
            DesktopCommand::RunExplain { project_dir, .. } => project_dir.as_deref(),
            DesktopCommand::RunCompare { project_dir, .. } => project_dir.as_deref(),
            DesktopCommand::RunPromote { project_dir, .. } => project_dir.as_deref(),
            DesktopCommand::RunPickWinner { project_dir, .. } => project_dir.as_deref(),
        }
    }

    fn winsmux_args(&self) -> Vec<String> {
        match self {
            DesktopCommand::SummarySnapshot { .. } => {
                vec!["desktop-summary".to_string(), "--json".to_string()]
            }
            DesktopCommand::RunExplain { run_id, .. } => {
                vec!["explain".to_string(), run_id.clone(), "--json".to_string()]
            }
            DesktopCommand::RunCompare {
                left_run_id,
                right_run_id,
                ..
            } => {
                vec![
                    "compare-runs".to_string(),
                    left_run_id.clone(),
                    right_run_id.clone(),
                    "--json".to_string(),
                ]
            }
            DesktopCommand::RunPromote { run_id, .. } => {
                vec![
                    "promote-tactic".to_string(),
                    run_id.clone(),
                    "--json".to_string(),
                ]
            }
            DesktopCommand::RunPickWinner {
                run_id,
                peer_slot,
                recommendation,
                confidence,
                next_test,
                ..
            } => {
                let mut args = vec![
                    "consult-result".to_string(),
                    "final".to_string(),
                    "--run-id".to_string(),
                    run_id.clone(),
                    "--message".to_string(),
                    recommendation.clone(),
                    "--target-slot".to_string(),
                    peer_slot.clone(),
                    "--next-test".to_string(),
                    next_test.clone(),
                    "--json".to_string(),
                ];
                if let Some(value) = confidence {
                    args.push("--confidence".to_string());
                    args.push(value.to_string());
                }
                args
            }
        }
    }
}

impl DesktopStreamCommand {
    fn project_dir(&self) -> Option<&str> {
        match self {
            DesktopStreamCommand::Summary { project_dir } => project_dir.as_deref(),
        }
    }

    fn winsmux_args(&self) -> Vec<String> {
        match self {
            DesktopStreamCommand::Summary { .. } => {
                vec![
                    "desktop-summary".to_string(),
                    "--stream".to_string(),
                    "--json".to_string(),
                ]
            }
        }
    }

    fn source_name(&self) -> &'static str {
        match self {
            DesktopStreamCommand::Summary { .. } => "summary",
        }
    }
}

pub trait DesktopCommandTransport {
    fn request_json(&self, command: &DesktopCommand) -> Result<Value, String>;
}

pub struct PwshScriptTransport;

impl DesktopCommandTransport for PwshScriptTransport {
    fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
        run_winsmux_json(
            command.project_dir().map(|path| path.to_string()),
            &command.winsmux_args(),
        )
    }
}

pub fn load_desktop_summary_snapshot(
    transport: &dyn DesktopCommandTransport,
    project_dir: Option<String>,
) -> Result<DesktopSummarySnapshot, String> {
    let snapshot = transport.request_json(&DesktopCommand::SummarySnapshot { project_dir })?;
    serde_json::from_value(snapshot)
        .map_err(|err| format!("Failed to parse desktop summary payload: {err}"))
}

pub fn load_desktop_run_explain(
    transport: &dyn DesktopCommandTransport,
    run_id: String,
    project_dir: Option<String>,
) -> Result<DesktopExplainPayload, String> {
    let payload = transport.request_json(&DesktopCommand::RunExplain {
        run_id,
        project_dir,
    })?;
    let payload: DesktopExplainPayload = serde_json::from_value(payload)
        .map_err(|err| format!("Failed to parse desktop explain payload: {err}"))?;
    if let Some(review_state) = payload.review_state.as_ref() {
        validate_desktop_review_state_record(review_state)
            .map_err(|err| format!("Failed to parse desktop explain payload: {err}"))?;
    }
    Ok(payload)
}

#[allow(dead_code)]
pub fn parse_desktop_review_state_snapshot(
    payload: Value,
) -> Result<DesktopReviewStateSnapshot, String> {
    let snapshot: DesktopReviewStateSnapshot = serde_json::from_value(payload)
        .map_err(|err| format!("Failed to parse review-state payload: {err}"))?;
    for (branch, record) in snapshot.iter() {
        validate_non_empty("review-state branch key", branch)?;
        validate_desktop_review_state_record(record)?;
        if record.branch != *branch {
            return Err(format!(
                "review-state record branch mismatch: key={branch}, record={}",
                record.branch
            ));
        }
    }
    Ok(snapshot)
}

fn validate_desktop_review_state_record(record: &DesktopReviewStateRecord) -> Result<(), String> {
    validate_non_empty("review_state.status", &record.status)?;
    validate_non_empty("review_state.branch", &record.branch)?;
    validate_non_empty("review_state.head_sha", &record.head_sha)?;
    validate_non_empty("review_state.updatedAt", &record.updated_at)?;
    validate_non_empty("review_state.request.branch", &record.request.branch)?;
    validate_non_empty("review_state.request.head_sha", &record.request.head_sha)?;
    validate_equal(
        "review_state.request.branch",
        &record.request.branch,
        "review_state.branch",
        &record.branch,
    )?;
    validate_equal(
        "review_state.request.head_sha",
        &record.request.head_sha,
        "review_state.head_sha",
        &record.head_sha,
    )?;
    validate_non_empty(
        "review_state.request.target_review_pane_id",
        review_request_target_value(
            &record.request.target_review_pane_id,
            &record.request.target_reviewer_pane_id,
        ),
    )?;
    validate_non_empty(
        "review_state.request.target_review_label",
        review_request_target_value(
            &record.request.target_review_label,
            &record.request.target_reviewer_label,
        ),
    )?;
    validate_non_empty(
        "review_state.request.target_review_role",
        review_request_target_value(
            &record.request.target_review_role,
            &record.request.target_reviewer_role,
        ),
    )?;
    validate_non_empty("review_state.reviewer.pane_id", &record.reviewer.pane_id)?;
    validate_non_empty("review_state.reviewer.label", &record.reviewer.label)?;
    validate_non_empty("review_state.reviewer.role", &record.reviewer.role)?;
    validate_desktop_review_contract(
        "review_state.request.review_contract",
        &record.request.review_contract,
    )?;

    match record.status.to_ascii_uppercase().as_str() {
        "PASS" => {
            let evidence = record
                .evidence
                .as_ref()
                .ok_or_else(|| "review_state.evidence is required for PASS".to_string())?;
            validate_non_empty(
                "review_state.evidence.approved_at",
                evidence.approved_at.as_deref().unwrap_or_default(),
            )?;
            validate_non_empty(
                "review_state.evidence.approved_via",
                evidence.approved_via.as_deref().unwrap_or_default(),
            )?;
            validate_desktop_review_contract(
                "review_state.evidence.review_contract_snapshot",
                &evidence.review_contract_snapshot,
            )?;
        }
        "FAIL" | "FAILED" => {
            let evidence = record
                .evidence
                .as_ref()
                .ok_or_else(|| "review_state.evidence is required for FAIL".to_string())?;
            validate_non_empty(
                "review_state.evidence.failed_at",
                evidence.failed_at.as_deref().unwrap_or_default(),
            )?;
            validate_non_empty(
                "review_state.evidence.failed_via",
                evidence.failed_via.as_deref().unwrap_or_default(),
            )?;
            validate_desktop_review_contract(
                "review_state.evidence.review_contract_snapshot",
                &evidence.review_contract_snapshot,
            )?;
        }
        _ => {}
    }

    Ok(())
}

fn validate_desktop_review_contract(
    name: &str,
    contract: &DesktopReviewContract,
) -> Result<(), String> {
    if contract.required_scope.is_empty() {
        return Err(format!("{name}.required_scope must not be empty"));
    }
    Ok(())
}

fn review_request_target_value<'a>(
    primary: &'a Option<String>,
    legacy: &'a Option<String>,
) -> &'a str {
    primary
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| legacy.as_deref().filter(|value| !value.trim().is_empty()))
        .unwrap_or_default()
}

fn validate_equal(
    left_name: &str,
    left: &str,
    right_name: &str,
    right: &str,
) -> Result<(), String> {
    if left != right {
        return Err(format!(
            "{left_name} mismatch: expected {right_name}={right}, got {left}"
        ));
    }
    Ok(())
}

fn validate_non_empty(name: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{name} must not be empty"));
    }
    Ok(())
}

pub fn load_desktop_run_compare(
    transport: &dyn DesktopCommandTransport,
    left_run_id: String,
    right_run_id: String,
    project_dir: Option<String>,
) -> Result<DesktopCompareRunsResult, String> {
    let payload = transport.request_json(&DesktopCommand::RunCompare {
        left_run_id,
        right_run_id,
        project_dir,
    })?;
    serde_json::from_value(payload)
        .map_err(|err| format!("Failed to parse desktop compare payload: {err}"))
}

pub fn load_desktop_run_promote(
    transport: &dyn DesktopCommandTransport,
    run_id: String,
    project_dir: Option<String>,
) -> Result<DesktopPromoteTacticResult, String> {
    let payload = transport.request_json(&DesktopCommand::RunPromote {
        run_id,
        project_dir,
    })?;
    serde_json::from_value(payload)
        .map_err(|err| format!("Failed to parse desktop promote payload: {err}"))
}

pub fn load_desktop_run_pick_winner(
    transport: &dyn DesktopCommandTransport,
    run_id: String,
    peer_slot: String,
    recommendation: String,
    confidence: Option<f64>,
    next_test: String,
    project_dir: Option<String>,
) -> Result<DesktopPickWinnerResult, String> {
    let payload = transport.request_json(&DesktopCommand::RunPickWinner {
        run_id,
        peer_slot,
        recommendation,
        confidence,
        next_test,
        project_dir,
    })?;
    serde_json::from_value(payload)
        .map_err(|err| format!("Failed to parse desktop pick-winner payload: {err}"))
}

pub fn load_desktop_editor_file(
    path: String,
    worktree: Option<String>,
    project_dir: Option<String>,
) -> Result<DesktopEditorFilePayload, String> {
    read_desktop_editor_file(project_dir, worktree, &path)
}

pub fn load_desktop_explorer_entries(
    worktree: Option<String>,
    project_dir: Option<String>,
) -> Result<DesktopExplorerListPayload, String> {
    let read_root = resolve_desktop_read_root(project_dir, worktree)?;
    let mut entries = Vec::new();
    collect_desktop_explorer_entries(&read_root, &read_root, 0, &mut entries)?;
    entries.sort_by(|left, right| {
        let left_is_file = left.kind == "file";
        let right_is_file = right.kind == "file";
        left_is_file
            .cmp(&right_is_file)
            .then_with(|| left.path.to_lowercase().cmp(&right.path.to_lowercase()))
    });

    Ok(DesktopExplorerListPayload {
        project_dir: read_root.to_string_lossy().to_string(),
        worktree: ".".to_string(),
        entries,
    })
}

pub fn handle_desktop_json_rpc(
    transport: &dyn DesktopCommandTransport,
    request: DesktopJsonRpcRequest,
    project_dir: Option<String>,
) -> DesktopJsonRpcResponse {
    let request_id = request.id.clone();
    if request.jsonrpc != DESKTOP_JSON_RPC_VERSION {
        return json_rpc_error(
            request_id,
            JSON_RPC_INVALID_REQUEST,
            "desktop_json_rpc expects jsonrpc=\"2.0\"",
        );
    }

    let params = request.params;
    let resolved_project_dir = resolve_project_dir(project_dir, params.as_ref());

    match request.method.as_str() {
        "desktop.summary.snapshot" => {
            match load_desktop_summary_snapshot(transport, resolved_project_dir) {
                Ok(snapshot) => match serde_json::to_value(snapshot) {
                    Ok(result) => json_rpc_result(request_id, result),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop summary payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.control_plane.contract" => json_rpc_result(
            request_id,
            serde_json::json!({
                "version": 1,
                "transport": "named_pipe_json_rpc",
                "pipe": r"\\.\pipe\winsmux-control",
                "jsonrpc": DESKTOP_JSON_RPC_VERSION,
                "localhost_http": false,
                "websocket": false,
                "methods": [
                    "desktop.control_plane.contract",
                    "desktop.summary.snapshot",
                    "desktop.run.explain",
                    "desktop.run.compare",
                    "desktop.run.promote",
                    "desktop.run.pick_winner",
                    "desktop.explorer.list",
                    "desktop.editor.read",
                ],
            }),
        ),
        "desktop.run.explain" => {
            let run_id = match get_required_string_param(params.as_ref(), &["runId", "run_id"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };

            match load_desktop_run_explain(transport, run_id, resolved_project_dir) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop explain payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.run.compare" => {
            let left_run_id =
                match get_required_string_param(params.as_ref(), &["leftRunId", "left_run_id"]) {
                    Ok(value) => value,
                    Err(err) => {
                        return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                    }
                };
            let right_run_id =
                match get_required_string_param(params.as_ref(), &["rightRunId", "right_run_id"]) {
                    Ok(value) => value,
                    Err(err) => {
                        return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                    }
                };

            match load_desktop_run_compare(
                transport,
                left_run_id,
                right_run_id,
                resolved_project_dir,
            ) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop compare payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.run.promote" => {
            let run_id = match get_required_string_param(params.as_ref(), &["runId", "run_id"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };

            match load_desktop_run_promote(transport, run_id, resolved_project_dir) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop promote payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.run.pick_winner" => {
            let run_id = match get_required_string_param(params.as_ref(), &["runId", "run_id"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };
            let peer_slot =
                match get_required_string_param(params.as_ref(), &["peerSlot", "peer_slot"]) {
                    Ok(value) => value,
                    Err(err) => {
                        return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                    }
                };
            let recommendation =
                match get_required_string_param(params.as_ref(), &["recommendation", "message"]) {
                    Ok(value) => value,
                    Err(err) => {
                        return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                    }
                };
            let next_test =
                match get_required_string_param(params.as_ref(), &["nextTest", "next_test"]) {
                    Ok(value) => value,
                    Err(err) => {
                        return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                    }
                };
            let confidence = get_optional_f64_param(params.as_ref(), &["confidence"]);

            match load_desktop_run_pick_winner(
                transport,
                run_id,
                peer_slot,
                recommendation,
                confidence,
                next_test,
                resolved_project_dir,
            ) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop pick-winner payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.editor.read" => {
            let path = match get_required_string_param(params.as_ref(), &["path"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };
            let worktree = get_optional_string_param(params.as_ref(), &["worktree"]);

            match load_desktop_editor_file(path, worktree, resolved_project_dir) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop editor payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.explorer.list" => {
            let worktree = get_optional_string_param(params.as_ref(), &["worktree"]);
            match load_desktop_explorer_entries(worktree, resolved_project_dir) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop explorer payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        _ => json_rpc_error(
            request_id,
            JSON_RPC_METHOD_NOT_FOUND,
            format!("Unknown desktop JSON-RPC method: {}", request.method),
        ),
    }
}

fn resolve_project_dir(project_dir: Option<String>, params: Option<&Value>) -> Option<String> {
    if let Some(path) = project_dir.filter(|value| !value.trim().is_empty()) {
        return Some(path);
    }

    get_optional_string_param(params, &["projectDir", "project_dir"])
}

fn get_required_string_param(params: Option<&Value>, keys: &[&str]) -> Result<String, String> {
    get_optional_string_param(params, keys)
        .ok_or_else(|| format!("Missing required params field: {}", keys.join(" or ")))
}

fn get_optional_string_param(params: Option<&Value>, keys: &[&str]) -> Option<String> {
    let object = params?.as_object()?;
    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }

    None
}

fn get_optional_f64_param(params: Option<&Value>, keys: &[&str]) -> Option<f64> {
    let object = params?.as_object()?;
    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_f64) {
            return Some(value);
        }
    }

    None
}

fn json_rpc_result(id: Value, result: Value) -> DesktopJsonRpcResponse {
    DesktopJsonRpcResponse::Success {
        jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
        id,
        result,
    }
}

fn json_rpc_error(id: Value, code: i32, message: impl Into<String>) -> DesktopJsonRpcResponse {
    DesktopJsonRpcResponse::Error {
        jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
        id,
        error: DesktopJsonRpcError {
            code,
            message: message.into(),
        },
    }
}

fn looks_like_repo_root(path: &Path) -> bool {
    path.join("scripts").join("winsmux-core.ps1").exists()
}

fn resolve_repo_root() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Ok(current_dir) = std::env::current_dir() {
        candidates.push(current_dir);
    }
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            candidates.push(parent.to_path_buf());
        }
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));

    for candidate in candidates {
        for ancestor in candidate.ancestors() {
            if looks_like_repo_root(ancestor) {
                return Ok(ancestor.to_path_buf());
            }
        }
    }

    Err("Could not locate winsmux repo root from the Tauri runtime".to_string())
}

fn resolve_effective_project_dir(project_dir: Option<String>) -> Result<PathBuf, String> {
    let repo_root = resolve_repo_root()?;
    Ok(match project_dir {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => repo_root,
    })
}

fn build_winsmux_command_text(script_path: &Path, args: &[String]) -> String {
    let script_literal = script_path.to_string_lossy().replace('\'', "''");
    let args_literal = args
        .iter()
        .map(|item| format!("'{}'", item.replace('\'', "''")))
        .collect::<Vec<_>>()
        .join(" ");

    format!("& {{ & '{}' {} }}", script_literal, args_literal)
}

pub fn parse_desktop_summary_stream_signal(
    source: &str,
    line: &str,
) -> Option<DesktopSummaryRefreshSignal> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }

    let payload: Value = serde_json::from_str(trimmed).ok()?;
    let object = payload.as_object()?;

    let optional_string = |key: &str| {
        object
            .get(key)
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.to_string())
    };

    let reason = match source {
        "digest" => object
            .get("run_id")
            .and_then(|value| value.as_str())
            .is_some()
            .then(|| "digest.stream".to_string()),
        "inbox" => {
            object
                .get("kind")
                .and_then(|value| value.as_str())
                .is_some()
                && object
                    .get("pane_id")
                    .and_then(|value| value.as_str())
                    .is_some()
        }
        .then(|| "inbox.stream".to_string()),
        "summary" => optional_string("reason"),
        _ => None,
    };
    let reason = reason?;

    Some(DesktopSummaryRefreshSignal {
        source: source.to_string(),
        reason,
        pane_id: optional_string("pane_id"),
        run_id: optional_string("run_id"),
    })
}

pub fn spawn_desktop_summary_refresh_stream<F>(
    command: DesktopStreamCommand,
    stop_requested: Arc<AtomicBool>,
    mut on_signal: F,
) -> Result<(), String>
where
    F: FnMut(DesktopSummaryRefreshSignal) + Send + 'static,
{
    let repo_root = resolve_repo_root()?;
    let effective_project_dir =
        resolve_effective_project_dir(command.project_dir().map(|value| value.to_string()))?;
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let command_text = build_winsmux_command_text(&script_path, &command.winsmux_args());
    let source = command.source_name().to_string();

    thread::spawn(move || {
        let mut quick_failure_count = 0usize;
        while !stop_requested.load(Ordering::Relaxed) {
            let started_at = Instant::now();
            let mut process = Command::new("pwsh");
            process
                .arg("-NoProfile")
                .arg("-ExecutionPolicy")
                .arg("Bypass")
                .arg("-Command")
                .arg(&command_text)
                .current_dir(&effective_project_dir)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            #[cfg(windows)]
            {
                process.creation_flags(CREATE_NO_WINDOW);
            }

            let mut child = match process.spawn() {
                Ok(child) => child,
                Err(err) => {
                    eprintln!("Failed to start {} summary stream: {}", source, err);
                    quick_failure_count += 1;
                    if quick_failure_count >= 3 {
                        eprintln!(
                            "winsmux {} stream disabled after repeated pwsh start failures",
                            source
                        );
                        break;
                    }
                    if stop_requested.load(Ordering::Relaxed) {
                        break;
                    }
                    thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            if let Some(stderr) = child.stderr.take() {
                let stderr_source = source.clone();
                thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
                            eprintln!("winsmux {} stream stderr: {}", stderr_source, trimmed);
                        }
                    }
                });
            }

            let stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => {
                    eprintln!("winsmux {} stream stdout pipe missing", source);
                    let _ = child.kill();
                    let _ = child.wait();
                    if stop_requested.load(Ordering::Relaxed) {
                        break;
                    }
                    thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if stop_requested.load(Ordering::Relaxed) {
                    let _ = child.kill();
                    break;
                }
                match line {
                    Ok(line) => {
                        if let Some(signal) = parse_desktop_summary_stream_signal(&source, &line) {
                            on_signal(signal);
                        }
                    }
                    Err(err) => {
                        eprintln!("winsmux {} stream read failed: {}", source, err);
                        break;
                    }
                }
            }

            let status = child.wait();
            if stop_requested.load(Ordering::Relaxed) {
                break;
            }
            match status {
                Ok(status) if status.success() => {
                    quick_failure_count = 0;
                }
                Ok(status) if started_at.elapsed() < Duration::from_secs(10) => {
                    quick_failure_count += 1;
                    eprintln!(
                        "winsmux {} stream exited quickly with status {}; attempt {}",
                        source, status, quick_failure_count
                    );
                    if quick_failure_count >= 3 {
                        eprintln!(
                            "winsmux {} stream disabled after repeated quick failures",
                            source
                        );
                        break;
                    }
                }
                Ok(_) => {
                    quick_failure_count = 0;
                }
                Err(err) => {
                    quick_failure_count += 1;
                    eprintln!("winsmux {} stream wait failed: {}", source, err);
                    if quick_failure_count >= 3 {
                        break;
                    }
                }
            }
            thread::sleep(Duration::from_secs(2));
        }
    });

    Ok(())
}

fn resolve_desktop_read_root(
    project_dir: Option<String>,
    worktree: Option<String>,
) -> Result<PathBuf, String> {
    let effective_project_dir = resolve_effective_project_dir(project_dir)?;
    let normalized_project_dir = effective_project_dir
        .canonicalize()
        .map_err(|err| format!("Failed to resolve project root for file preview: {err}"))?;

    let requested_root = match worktree {
        Some(path) if !path.trim().is_empty() => {
            let requested = PathBuf::from(path);
            if requested.is_absolute() {
                requested
            } else {
                effective_project_dir.join(requested)
            }
        }
        _ => effective_project_dir.clone(),
    };

    let normalized_requested_root = requested_root
        .canonicalize()
        .map_err(|err| format!("Failed to resolve worktree root for file preview: {err}"))?;

    if !normalized_requested_root.starts_with(&normalized_project_dir) {
        return Err(
            "desktop.editor.read rejected a worktree path outside the project directory"
                .to_string(),
        );
    }

    Ok(normalized_requested_root)
}

const DESKTOP_EXPLORER_MAX_DEPTH: usize = 5;
const DESKTOP_EXPLORER_MAX_ENTRIES: usize = 1_200;

fn should_descend_desktop_explorer_dir(name: &str) -> bool {
    !matches!(
        name,
        ".git"
            | ".claude"
            | ".playwright-mcp"
            | ".references"
            | ".shield-harness"
            | ".winsmux"
            | ".worktrees"
            | ".tmp"
            | "dist"
            | "node_modules"
            | "output"
            | "target"
    )
}

fn has_desktop_explorer_children(dir: &Path) -> bool {
    fs::read_dir(dir)
        .map(|mut children| {
            children.any(|child| {
                child
                    .ok()
                    .and_then(|entry| entry.file_type().ok())
                    .map(|file_type| file_type.is_dir() || file_type.is_file())
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn collect_desktop_ignored_paths(root: &Path, relative_paths: &[String]) -> HashSet<String> {
    if relative_paths.is_empty() {
        return HashSet::new();
    }

    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(root)
        .args(["check-ignore", "-z", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);

    let Ok(mut child) = command.spawn() else {
        return HashSet::new();
    };

    if let Some(mut stdin) = child.stdin.take() {
        for relative_path in relative_paths {
            if stdin.write_all(relative_path.as_bytes()).is_err() || stdin.write_all(&[0]).is_err() {
                return HashSet::new();
            }
        }
    }

    let Ok(output) = child.wait_with_output() else {
        return HashSet::new();
    };
    if !matches!(output.status.code(), Some(0) | Some(1)) {
        return HashSet::new();
    }

    output
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|item| {
            if item.is_empty() {
                return None;
            }
            String::from_utf8(item.to_vec())
                .ok()
                .map(|path| path.replace('\\', "/").trim_end_matches('/').to_string())
        })
        .filter(|item| !item.is_empty())
        .collect()
}

fn collect_desktop_explorer_entries(
    root: &Path,
    dir: &Path,
    depth: usize,
    entries: &mut Vec<DesktopExplorerEntry>,
) -> Result<(), String> {
    if entries.len() >= DESKTOP_EXPLORER_MAX_ENTRIES {
        return Ok(());
    }

    let mut children = fs::read_dir(dir)
        .map_err(|err| format!("Failed to list project explorer directory: {err}"))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();

    children.sort_by(|left, right| {
        left.file_name()
            .to_string_lossy()
            .to_lowercase()
            .cmp(&right.file_name().to_string_lossy().to_lowercase())
    });

    let mut child_records: Vec<(PathBuf, String, bool, String)> = Vec::new();
    for child in children {
        if entries.len() >= DESKTOP_EXPLORER_MAX_ENTRIES {
            break;
        }
        let Ok(file_type) = child.file_type() else {
            continue;
        };
        let path = child.path();
        let Ok(relative_path) = path.strip_prefix(root) else {
            continue;
        };
        let relative = relative_path.to_string_lossy().replace('\\', "/");
        if relative.is_empty() {
            continue;
        }

        if file_type.is_dir() || file_type.is_file() {
            child_records.push((
                path,
                relative,
                file_type.is_dir(),
                child.file_name().to_string_lossy().to_string(),
            ));
        }
    }

    let ignored_paths = collect_desktop_ignored_paths(
        root,
        &child_records
            .iter()
            .map(|(_, relative, _, _)| relative.clone())
            .collect::<Vec<_>>(),
    );

    for (path, relative, is_dir, name) in child_records {
        if entries.len() >= DESKTOP_EXPLORER_MAX_ENTRIES {
            break;
        }
        let ignored = ignored_paths.contains(&relative) || ignored_paths.contains(&format!("{relative}/"));
        if is_dir {
            entries.push(DesktopExplorerEntry {
                path: relative.clone(),
                kind: "directory".to_string(),
                has_children: Some(has_desktop_explorer_children(&path)),
                ignored,
            });
            if depth < DESKTOP_EXPLORER_MAX_DEPTH && should_descend_desktop_explorer_dir(&name) {
                let _ = collect_desktop_explorer_entries(root, &path, depth + 1, entries);
            }
        } else {
            entries.push(DesktopExplorerEntry {
                path: relative,
                kind: "file".to_string(),
                has_children: None,
                ignored,
            });
        }
    }

    Ok(())
}

fn read_desktop_editor_file(
    project_dir: Option<String>,
    worktree: Option<String>,
    relative_path: &str,
) -> Result<DesktopEditorFilePayload, String> {
    let read_root = resolve_desktop_read_root(project_dir, worktree)?;
    let requested_path = PathBuf::from(relative_path);
    if requested_path.is_absolute() {
        return Err("desktop.editor.read expects a project-relative path".to_string());
    }

    let full_path = read_root.join(&requested_path);
    let normalized_full_path = full_path
        .canonicalize()
        .map_err(|err| format!("Failed to resolve file preview path: {err}"))?;

    if !normalized_full_path.starts_with(&read_root) {
        return Err(
            "desktop.editor.read rejected a path outside the selected worktree".to_string(),
        );
    }

    let bytes = fs::read(&normalized_full_path)
        .map_err(|err| format!("Failed to read file preview: {err}"))?;
    const MAX_PREVIEW_BYTES: usize = 32 * 1024;
    let truncated = bytes.len() > MAX_PREVIEW_BYTES;
    let preview_bytes = if truncated {
        &bytes[..MAX_PREVIEW_BYTES]
    } else {
        bytes.as_slice()
    };
    let content = String::from_utf8_lossy(preview_bytes).to_string();
    let line_count = content.lines().count().max(1);

    Ok(DesktopEditorFilePayload {
        path: requested_path.to_string_lossy().replace('\\', "/"),
        content,
        line_count,
        truncated,
    })
}

fn run_winsmux_json(project_dir: Option<String>, args: &[String]) -> Result<Value, String> {
    let repo_root = resolve_repo_root()?;
    let effective_project_dir = resolve_effective_project_dir(project_dir)?;
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let command_text = build_winsmux_command_text(&script_path, args);

    let output = Command::new("pwsh")
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(command_text)
        .current_dir(&effective_project_dir)
        .output()
        .map_err(|err| format!("Failed to start winsmux-core.ps1: {err}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() { stderr } else { stdout };
        return Err(format!("winsmux-core.ps1 failed: {}", detail));
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stdout.is_empty() {
        return Err("winsmux-core.ps1 returned empty JSON output".to_string());
    }

    serde_json::from_str(&stdout)
        .map_err(|err| format!("Failed to parse winsmux JSON payload: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::path::PathBuf;

    mod rust_parity_support {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/test_support/rust_parity.rs"
        ));
    }

    struct FakeTransport {
        requests: RefCell<Vec<String>>,
        response: Value,
    }

    impl DesktopCommandTransport for FakeTransport {
        fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
            self.requests
                .borrow_mut()
                .push(command.winsmux_args().join(" "));
            Ok(self.response.clone())
        }
    }

    fn rust_parity_repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
    }

    fn read_rust_parity_fixture(name: &str) -> Value {
        rust_parity_support::read_json_fixture(&rust_parity_repo_root(), name)
    }

    fn rust_parity_explain_payload() -> Value {
        read_rust_parity_fixture("explain.json")
    }

    fn rust_parity_review_state_payload() -> Value {
        rust_parity_review_state_snapshot_payload()["worktree-builder-1"].clone()
    }

    fn rust_parity_review_state_snapshot_payload() -> Value {
        read_rust_parity_fixture("review-state.json")
    }

    fn rust_parity_explain_payload_with_review_state() -> Value {
        let mut payload = rust_parity_explain_payload();
        payload["review_state"] = rust_parity_review_state_payload();
        payload
    }

    fn desktop_promote_tactic_payload() -> Value {
        serde_json::json!({
            "generated_at": "__GENERATED_AT__",
            "run_id": "task:task-256",
            "candidate_ref": ".winsmux/playbook-candidates/playbook-candidate-__ID__.json",
            "candidate_path": "__PROJECT_DIR__/.winsmux/playbook-candidates/playbook-candidate-__ID__.json",
            "candidate": {
                "packet_type": "playbook_candidate",
                "kind": "playbook",
                "title": "Stabilize explain contract",
                "summary": "Promote explain contract handling into the playbook.",
                "hypothesis": "The explain path is stable enough to reuse.",
                "next_action": "promote_to_playbook",
                "confidence": 0.82,
                "changed_files": [
                    "winsmux-app/src-tauri/src/desktop_backend.rs",
                    "winsmux-app/src/main.ts"
                ],
                "observation_pack_ref": ".winsmux/observation-packs/observation-pack-__ID__.json",
                "consultation_ref": ".winsmux/consultations/consult-result-__ID__.json"
            }
        })
    }

    fn desktop_compare_runs_payload() -> Value {
        serde_json::json!({
            "generated_at": "__GENERATED_AT__",
            "left": {
                "run_id": "task:task-256",
                "label": "builder-1",
                "branch": "worktree-builder-a",
                "task_state": "completed",
                "review_state": "PASS",
                "state": "idle",
                "next_action": "promote tactic",
                "confidence": 0.85,
                "changed_files": ["scripts/winsmux-core.ps1"],
                "observation_pack_ref": ".winsmux/observation-packs/observation-pack-a.json",
                "consultation_ref": ".winsmux/consultations/consult-result-a.json",
                "recommendable": true
            },
            "right": {
                "run_id": "task:task-257",
                "label": "builder-2",
                "branch": "worktree-builder-b",
                "task_state": "completed",
                "review_state": "PASS",
                "state": "idle",
                "next_action": "reconcile consult",
                "confidence": 0.4,
                "changed_files": [
                    "scripts/winsmux-core.ps1",
                    "tests/winsmux-bridge.Tests.ps1"
                ],
                "observation_pack_ref": ".winsmux/observation-packs/observation-pack-b.json",
                "consultation_ref": ".winsmux/consultations/consult-result-b.json",
                "recommendable": true
            },
            "shared_changed_files": ["scripts/winsmux-core.ps1"],
            "left_only_changed_files": [],
            "right_only_changed_files": ["tests/winsmux-bridge.Tests.ps1"],
            "confidence_delta": 0.45,
            "differences": [
                {
                    "field": "result",
                    "left": "cache hit done",
                    "right": "still dirty"
                },
                {
                    "field": "changed_files",
                    "left": ["scripts/winsmux-core.ps1"],
                    "right": [
                        "scripts/winsmux-core.ps1",
                        "tests/winsmux-bridge.Tests.ps1"
                    ]
                }
            ],
            "recommend": {
                "winning_run_id": "task:task-256",
                "reconcile_consult": true,
                "next_action": "reconcile_consult"
            }
        })
    }

    fn desktop_pick_winner_payload() -> Value {
        serde_json::json!({
            "run_id": "task:task-256",
            "task_id": "task-256",
            "pane_id": "%2",
            "slot": "builder-1",
            "kind": "consult_result",
            "mode": "final",
            "target_slot": "builder-2",
            "recommendation": "Pick builder-1",
            "confidence": 0.85,
            "next_test": "promote tactic",
            "risks": [],
            "consultation_ref": ".winsmux/consultations/consult-result-__ID__.json",
            "generated_at": "__GENERATED_AT__"
        })
    }

    fn expect_missing_explain_run_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["run"]
            .as_object_mut()
            .expect("run must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing run field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    fn expect_missing_explain_action_item_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["run"]["action_items"][0]
            .as_object_mut()
            .expect("run.action_items[0] must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing action item field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    fn rust_parity_run_projection_payload() -> Value {
        let digest = read_rust_parity_fixture("digest.json");
        let item = &digest["items"][0];
        serde_json::json!({
            "run_id": item["run_id"].clone(),
            "pane_id": item["pane_id"].clone(),
            "label": item["label"].clone(),
            "branch": item["branch"].clone(),
            "worktree": item["worktree"].clone(),
            "head_sha": item["head_sha"].clone(),
            "head_short": item["head_short"].clone(),
            "provider_target": item["provider_target"].clone(),
            "task": item["task"].clone(),
            "task_state": item["task_state"].clone(),
            "review_state": item["review_state"].clone(),
            "verification_outcome": item["verification_outcome"].clone(),
            "security_blocked": item["security_blocked"].clone(),
            "changed_files": item["changed_files"].clone(),
            "next_action": item["next_action"].clone(),
            "summary": item["task"].clone(),
            "reasons": [format!("review_state={}", item["review_state"].as_str().unwrap_or_default())],
            "hypothesis": item["hypothesis"].clone(),
            "confidence": item["confidence"].clone(),
            "observation_pack_ref": item["observation_pack_ref"].clone(),
            "consultation_ref": item["consultation_ref"].clone()
        })
    }

    fn rust_parity_summary_snapshot_payload() -> Value {
        serde_json::json!({
            "generated_at": "__GENERATED_AT__",
            "project_dir": "__PROJECT_DIR__",
            "board": read_rust_parity_fixture("board.json"),
            "inbox": read_rust_parity_fixture("inbox.json"),
            "digest": read_rust_parity_fixture("digest.json"),
            "run_projections": [rust_parity_run_projection_payload()]
        })
    }

    fn expect_missing_inbox_item_field(field_name: &str) -> String {
        let mut response = rust_parity_summary_snapshot_payload();
        response["inbox"]["items"][0]
            .as_object_mut()
            .expect("inbox.items[0] must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!(
                "expected summary snapshot parse failure for missing inbox field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    #[test]
    fn load_desktop_summary_snapshot_deserializes_transport_payload() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: rust_parity_summary_snapshot_payload(),
        };

        let snapshot = load_desktop_summary_snapshot(&transport, None).unwrap();

        assert_eq!(snapshot.project_dir, "__PROJECT_DIR__");
        assert_eq!(snapshot.board.summary.pane_count, 2);
        assert_eq!(snapshot.board.summary.tasks_blocked, 0);
        assert_eq!(snapshot.board.summary.by_state["idle"], 1);
        assert_eq!(snapshot.board.summary.by_review["PENDING"], 1);
        assert_eq!(snapshot.board.summary.by_task_state["backlog"], 1);
        assert_eq!(snapshot.board.panes[0].pane_id, "%2");
        assert_eq!(snapshot.board.panes[0].worktree, ".worktrees/builder-1");
        assert_eq!(snapshot.board.panes[0].last_event_at, "__LAST_EVENT_AT__");
        assert_eq!(snapshot.inbox.summary.item_count, 4);
        assert_eq!(snapshot.inbox.summary.by_kind["review_pending"], 1);
        assert_eq!(snapshot.inbox.summary.by_kind["commit_ready"], 1);
        assert_eq!(snapshot.inbox.items[0].priority, 0);
        assert_eq!(snapshot.inbox.items[0].pane_id, "%6");
        assert_eq!(snapshot.inbox.items[0].role, "Worker");
        assert_eq!(snapshot.inbox.items[0].task_id, "task-999");
        assert_eq!(snapshot.inbox.items[0].task, "Fix blocker");
        assert_eq!(snapshot.inbox.items[0].head_sha, "def5678abc1234");
        assert_eq!(snapshot.inbox.items[0].event, "operator.state_transition");
        assert_eq!(snapshot.inbox.items[0].timestamp, "__TIMESTAMP__");
        assert_eq!(snapshot.inbox.items[0].source, "manifest");
        assert_eq!(snapshot.digest.summary.actionable_items, 1);
        assert_eq!(snapshot.digest.summary.dirty_items, 1);
        assert_eq!(snapshot.digest.items[0].run_id, "task:task-246");
        assert_eq!(snapshot.digest.items[0].task_id, "task-246");
        assert_eq!(snapshot.digest.items[0].provider_target, "");
        assert_eq!(snapshot.digest.items[0].action_item_count, 3);
        assert_eq!(
            snapshot.digest.items[0].last_event,
            "operator.review_failed"
        );
        assert_eq!(snapshot.digest.items[0].verification_outcome, "");
        assert_eq!(snapshot.digest.items[0].security_blocked, "");
        assert_eq!(
            snapshot.digest.items[0].observation_pack_ref,
            ".winsmux/observation-packs/observation-pack-__ID__.json"
        );
        assert_eq!(snapshot.digest.items[0].last_event_at, "__LAST_EVENT_AT__");
        assert_eq!(snapshot.run_projections.len(), 1);
        assert_eq!(snapshot.run_projections[0].run_id, "task:task-246");
        assert_eq!(snapshot.run_projections[0].pane_id, "%2");
        assert_eq!(snapshot.run_projections[0].provider_target, "");
        assert_eq!(
            snapshot.run_projections[0].changed_files,
            vec!["scripts/winsmux-core.ps1"]
        );
        assert_eq!(snapshot.run_projections[0].next_action, "review_failed");
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["desktop-summary --json"]
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_required_narrowed_fields() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["board"]["summary"]
            .as_object_mut()
            .expect("board.summary must be an object")
            .remove("tasks_blocked");
        response["inbox"]["items"][0]
            .as_object_mut()
            .expect("inbox.items[0] must be an object")
            .remove("changed_file_count");
        response["board"]["panes"][0]
            .as_object_mut()
            .expect("board.panes[0] must be an object")
            .remove("pane_id");
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("last_event_at");
        response["run_projections"][0]
            .as_object_mut()
            .expect("run_projections[0] must be an object")
            .remove("provider_target");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected narrowed payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("tasks_blocked")
                || err.contains("changed_file_count")
                || err.contains("pane_id")
                || err.contains("last_event_at")
                || err.contains("provider_target")
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_worktree() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("worktree");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing worktree"),
            Err(err) => err,
        };

        assert!(
            err.contains("worktree"),
            "expected missing worktree error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_board_pane_worktree() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["board"]["panes"][0]
            .as_object_mut()
            .expect("board.panes[0] must be an object")
            .remove("worktree");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => {
                panic!("expected summary snapshot parse failure for missing board pane worktree")
            }
            Err(err) => err,
        };

        assert!(
            err.contains("worktree"),
            "expected missing board pane worktree error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_board_summary_by_state() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["board"]["summary"]
            .as_object_mut()
            .expect("board.summary must be an object")
            .remove("by_state");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing by_state"),
            Err(err) => err,
        };

        assert!(
            err.contains("by_state"),
            "expected missing by_state error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_board_summary_by_review() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["board"]["summary"]
            .as_object_mut()
            .expect("board.summary must be an object")
            .remove("by_review");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing by_review"),
            Err(err) => err,
        };

        assert!(
            err.contains("by_review"),
            "expected missing by_review error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_board_summary_by_task_state() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["board"]["summary"]
            .as_object_mut()
            .expect("board.summary must be an object")
            .remove("by_task_state");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing by_task_state"),
            Err(err) => err,
        };

        assert!(
            err.contains("by_task_state"),
            "expected missing by_task_state error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_summary_by_kind() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["inbox"]["summary"]
            .as_object_mut()
            .expect("inbox.summary must be an object")
            .remove("by_kind");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing by_kind"),
            Err(err) => err,
        };

        assert!(
            err.contains("by_kind"),
            "expected missing by_kind error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_priority() {
        let err = expect_missing_inbox_item_field("priority");

        assert!(
            err.contains("priority"),
            "expected missing priority error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_role() {
        let err = expect_missing_inbox_item_field("role");

        assert!(
            err.contains("role"),
            "expected missing role error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_task_id() {
        let err = expect_missing_inbox_item_field("task_id");

        assert!(
            err.contains("task_id"),
            "expected missing task_id error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_task() {
        let err = expect_missing_inbox_item_field("task");

        assert!(
            err.contains("task"),
            "expected missing task error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_head_sha() {
        let err = expect_missing_inbox_item_field("head_sha");

        assert!(
            err.contains("head_sha"),
            "expected missing head_sha error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_event() {
        let err = expect_missing_inbox_item_field("event");

        assert!(
            err.contains("event"),
            "expected missing event error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_timestamp() {
        let err = expect_missing_inbox_item_field("timestamp");

        assert!(
            err.contains("timestamp"),
            "expected missing timestamp error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_inbox_item_source() {
        let err = expect_missing_inbox_item_field("source");

        assert!(
            err.contains("source"),
            "expected missing source error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_task_id() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("task_id");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing task_id"),
            Err(err) => err,
        };

        assert!(
            err.contains("task_id"),
            "expected missing task_id error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_head_sha() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("head_sha");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing head_sha"),
            Err(err) => err,
        };

        assert!(
            err.contains("head_sha"),
            "expected missing head_sha error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_action_item_count() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("action_item_count");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => {
                panic!("expected summary snapshot parse failure for missing action_item_count")
            }
            Err(err) => err,
        };

        assert!(
            err.contains("action_item_count"),
            "expected missing action_item_count error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_provider_target() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("provider_target");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing provider_target"),
            Err(err) => err,
        };

        assert!(
            err.contains("provider_target"),
            "expected missing provider_target error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_last_event() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("last_event");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => panic!("expected summary snapshot parse failure for missing last_event"),
            Err(err) => err,
        };

        assert!(
            err.contains("last_event"),
            "expected missing last_event error, got {err}"
        );
    }

    #[test]
    fn load_desktop_summary_snapshot_rejects_missing_digest_verification_outcome() {
        let mut response = rust_parity_summary_snapshot_payload();
        response["digest"]["items"][0]
            .as_object_mut()
            .expect("digest.items[0] must be an object")
            .remove("verification_outcome");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_summary_snapshot(&transport, None) {
            Ok(_) => {
                panic!("expected summary snapshot parse failure for missing verification_outcome")
            }
            Err(err) => err,
        };

        assert!(
            err.contains("verification_outcome"),
            "expected missing verification_outcome error, got {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_uses_explain_command() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: rust_parity_explain_payload_with_review_state(),
        };

        let payload =
            load_desktop_run_explain(&transport, "task:task-256".to_string(), None).unwrap();

        assert_eq!(payload.run.run_id, "task:task-256");
        assert_eq!(payload.run.task_id, "task-256");
        assert_eq!(payload.run.parent_run_id, "operator:session-1");
        assert_eq!(payload.run.goal, "Ship run contract primitives");
        assert_eq!(payload.run.task, "Implement run ledger");
        assert_eq!(payload.run.task_type, "implementation");
        assert_eq!(payload.run.priority, "P0");
        assert!(payload.run.blocking);
        assert_eq!(payload.generated_at, "__GENERATED_AT__");
        assert_eq!(payload.project_dir, "__PROJECT_DIR__");
        assert_eq!(payload.run.primary_label, "builder-1");
        assert_eq!(payload.run.primary_pane_id, "%2");
        assert_eq!(payload.run.primary_role, "Builder");
        assert_eq!(payload.run.last_event, "operator.review_requested");
        assert_eq!(payload.run.last_event_at, "__LAST_EVENT_AT__");
        assert_eq!(payload.run.tokens_remaining, "64% context left");
        assert_eq!(payload.run.pane_count, 1);
        assert_eq!(payload.run.changed_file_count, 1);
        assert_eq!(payload.run.labels, vec!["builder-1".to_string()]);
        assert_eq!(payload.run.pane_ids, vec!["%2".to_string()]);
        assert_eq!(payload.run.roles, vec!["Builder".to_string()]);
        assert_eq!(payload.run.provider_target, "codex:gpt-5.4");
        assert_eq!(payload.run.agent_role, "worker");
        assert_eq!(
            payload.run.write_scope,
            vec![
                "scripts/winsmux-core.ps1".to_string(),
                "tests/winsmux-bridge.Tests.ps1".to_string()
            ]
        );
        assert_eq!(
            payload.run.read_scope,
            vec!["winsmux-core/scripts/pane-status.ps1".to_string()]
        );
        assert_eq!(
            payload.run.constraints,
            vec!["preserve existing board schema".to_string()]
        );
        assert_eq!(payload.run.expected_output, "Stable explain JSON");
        assert_eq!(
            payload.run.verification_plan,
            vec![
                "Invoke-Pester tests/winsmux-bridge.Tests.ps1".to_string(),
                "verify explain --json contract".to_string()
            ]
        );
        assert!(payload.run.review_required);
        assert_eq!(payload.run.timeout_policy, "standard");
        assert_eq!(
            payload.run.handoff_refs,
            vec!["docs/handoff.md".to_string()]
        );
        assert_eq!(payload.run.experiment_packet.hypothesis, "");
        assert!(payload.run.experiment_packet.test_plan.is_empty());
        assert_eq!(payload.run.experiment_packet.result, "consult before work");
        assert_eq!(payload.run.experiment_packet.confidence, 0.66);
        assert_eq!(
            payload.run.experiment_packet.next_action,
            "approval_waiting"
        );
        assert_eq!(
            payload.run.experiment_packet.observation_pack_ref,
            ".winsmux/observation-packs/observation-pack-__ID__.json"
        );
        assert_eq!(
            payload.run.experiment_packet.consultation_ref,
            ".winsmux/consultations/consult-result-__ID__.json"
        );
        assert_eq!(payload.run.experiment_packet.run_id, "task:task-256");
        assert_eq!(payload.run.experiment_packet.slot, "slot-builder-1");
        assert_eq!(payload.run.experiment_packet.branch, "worktree-builder-1");
        assert_eq!(payload.run.experiment_packet.worktree, "");
        assert_eq!(payload.run.experiment_packet.env_fingerprint, "");
        assert_eq!(payload.run.experiment_packet.command_hash, "");
        assert_eq!(payload.explanation.current_state.state, "idle");
        assert_eq!(payload.explanation.current_state.task_state, "in_progress");
        assert_eq!(payload.explanation.current_state.review_state, "PENDING");
        assert_eq!(
            payload.explanation.current_state.last_event,
            "operator.review_requested"
        );
        assert!(payload.run.security_policy.is_null());
        assert!(payload.run.security_verdict.is_null());
        assert!(payload.run.verification_contract.is_null());
        assert!(payload.run.verification_result.is_null());
        assert_eq!(payload.run.worktree, ".worktrees/builder-1");
        assert_eq!(payload.run.action_items.len(), 2);
        assert_eq!(payload.run.action_items[0].kind, "review_pending");
        assert_eq!(
            payload.run.action_items[0].message,
            "builder-1 が review 待機中。"
        );
        assert_eq!(
            payload.run.action_items[0].event,
            "operator.review_requested"
        );
        assert_eq!(payload.run.action_items[0].timestamp, "__TIMESTAMP__");
        assert_eq!(payload.run.action_items[0].source, "manifest");
        assert_eq!(payload.evidence_digest.next_action, "review_pending");
        assert_eq!(payload.evidence_digest.verification_outcome, "");
        assert_eq!(payload.evidence_digest.security_blocked, "");
        assert_eq!(payload.consultation_packet.run_id, "task:task-256");
        assert_eq!(payload.consultation_packet.task_id, "task-256");
        assert_eq!(payload.consultation_packet.pane_id, "%2");
        assert_eq!(payload.consultation_packet.slot, "slot-builder-1");
        assert_eq!(payload.consultation_packet.kind, "consult_result");
        assert_eq!(payload.consultation_packet.mode, "early");
        assert_eq!(payload.consultation_packet.target_slot, "slot-review-1");
        assert_eq!(payload.consultation_packet.confidence, 0.66);
        assert_eq!(
            payload.consultation_packet.recommendation,
            "consult before work"
        );
        assert_eq!(payload.consultation_packet.next_test, "approval_waiting");
        assert_eq!(
            payload.consultation_packet.risks,
            vec!["needs reviewer confirmation".to_string()]
        );
        assert_eq!(payload.consultation_packet.generated_at, "__GENERATED_AT__");
        assert_eq!(payload.observation_pack.run_id, "task:task-256");
        assert_eq!(payload.observation_pack.task_id, "task-256");
        assert_eq!(payload.observation_pack.pane_id, "%2");
        assert_eq!(payload.observation_pack.slot, "slot-builder-1");
        assert_eq!(
            payload.observation_pack.hypothesis,
            "experiment packet should flow into explain"
        );
        assert_eq!(
            payload.observation_pack.test_plan,
            vec![
                "collect matching events".to_string(),
                "normalize packet".to_string()
            ]
        );
        assert_eq!(
            payload.observation_pack.changed_files,
            vec!["scripts/winsmux-core.ps1".to_string()]
        );
        assert_eq!(
            payload.observation_pack.working_tree_summary,
            "1 file modified"
        );
        assert_eq!(
            payload.observation_pack.failing_command,
            "Invoke-Pester tests/winsmux-bridge.Tests.ps1"
        );
        assert_eq!(payload.observation_pack.env_fingerprint, "env:abc123");
        assert_eq!(payload.observation_pack.command_hash, "cmd:def456");
        assert_eq!(payload.observation_pack.generated_at, "__GENERATED_AT__");
        assert_eq!(
            payload
                .review_state
                .as_ref()
                .map(|state| state.status.as_str()),
            Some("PENDING")
        );
        assert_eq!(
            payload
                .review_state
                .as_ref()
                .map(|state| state.updated_at.as_str()),
            Some("__TIMESTAMP__")
        );
        assert_eq!(
            payload
                .review_state
                .as_ref()
                .map(|state| state.request.review_contract.style.as_str()),
            Some("utility_first")
        );
        assert_eq!(payload.recent_events.len(), 3);
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["explain task:task-256 --json"]
        );
    }

    #[test]
    fn load_desktop_run_promote_uses_promote_command() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_promote_tactic_payload(),
        };

        let payload =
            load_desktop_run_promote(&transport, "task:task-256".to_string(), None).unwrap();

        assert_eq!(payload.run_id, "task:task-256");
        assert_eq!(payload.generated_at, "__GENERATED_AT__");
        assert_eq!(
            payload.candidate_ref,
            ".winsmux/playbook-candidates/playbook-candidate-__ID__.json"
        );
        assert_eq!(payload.candidate.packet_type, "playbook_candidate");
        assert_eq!(payload.candidate.kind, "playbook");
        assert_eq!(payload.candidate.title, "Stabilize explain contract");
        assert_eq!(
            payload.candidate.summary,
            "Promote explain contract handling into the playbook."
        );
        assert_eq!(
            payload.candidate.hypothesis,
            "The explain path is stable enough to reuse."
        );
        assert_eq!(payload.candidate.next_action, "promote_to_playbook");
        assert_eq!(payload.candidate.confidence, Some(0.82));
        assert_eq!(
            payload.candidate.changed_files,
            vec![
                "winsmux-app/src-tauri/src/desktop_backend.rs".to_string(),
                "winsmux-app/src/main.ts".to_string()
            ]
        );
        assert_eq!(
            payload.candidate.observation_pack_ref,
            ".winsmux/observation-packs/observation-pack-__ID__.json"
        );
        assert_eq!(
            payload.candidate.consultation_ref,
            ".winsmux/consultations/consult-result-__ID__.json"
        );
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["promote-tactic task:task-256 --json"]
        );
    }

    #[test]
    fn load_desktop_run_compare_uses_compare_command() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_compare_runs_payload(),
        };

        let payload = load_desktop_run_compare(
            &transport,
            "task:task-256".to_string(),
            "task:task-257".to_string(),
            None,
        )
        .unwrap();

        assert_eq!(payload.left.run_id, "task:task-256");
        assert_eq!(payload.right.run_id, "task:task-257");
        assert_eq!(payload.confidence_delta, Some(0.45));
        assert_eq!(payload.left.changed_files.len(), 1);
        assert_eq!(payload.right.changed_files.len(), 2);
        assert_eq!(payload.differences.len(), 2);
        assert_eq!(payload.recommend.winning_run_id, "task:task-256");
        assert!(payload.recommend.reconcile_consult);
        assert_eq!(payload.recommend.next_action, "reconcile_consult");
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["compare-runs task:task-256 task:task-257 --json"]
        );
    }

    #[test]
    fn load_desktop_run_pick_winner_uses_consult_result_command() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_pick_winner_payload(),
        };

        let payload = load_desktop_run_pick_winner(
            &transport,
            "task:task-256".to_string(),
            "builder-2".to_string(),
            "Pick builder-1".to_string(),
            Some(0.85),
            "promote tactic".to_string(),
            None,
        )
        .unwrap();

        assert_eq!(payload.run_id, "task:task-256");
        assert_eq!(payload.mode, "final");
        assert_eq!(payload.target_slot, "builder-2");
        assert_eq!(payload.recommendation, "Pick builder-1");
        assert_eq!(payload.confidence, Some(0.85));
        assert_eq!(payload.next_test, "promote tactic");
        assert_eq!(
            payload.consultation_ref,
            ".winsmux/consultations/consult-result-__ID__.json"
        );
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["consult-result final --run-id task:task-256 --message Pick builder-1 --target-slot builder-2 --next-test promote tactic --json --confidence 0.85"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_run_explain_and_prunes_extra_packets() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: rust_parity_explain_payload_with_review_state(),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-explain"),
                method: "desktop.run.explain".to_string(),
                params: Some(serde_json::json!({
                    "run_id": "task:task-256"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-explain"));
                assert_eq!(result["run"]["run_id"], "task:task-256");
                assert_eq!(result["run"]["task_id"], "task-256");
                assert_eq!(result["run"]["parent_run_id"], "operator:session-1");
                assert_eq!(result["run"]["goal"], "Ship run contract primitives");
                assert_eq!(result["run"]["priority"], "P0");
                assert_eq!(result["run"]["primary_label"], "builder-1");
                assert_eq!(result["run"]["primary_pane_id"], "%2");
                assert_eq!(result["run"]["last_event"], "operator.review_requested");
                assert_eq!(result["run"]["tokens_remaining"], "64% context left");
                assert_eq!(result["run"]["pane_count"], 1);
                assert_eq!(result["run"]["labels"][0], "builder-1");
                assert_eq!(result["run"]["pane_ids"][0], "%2");
                assert_eq!(result["run"]["roles"][0], "Builder");
                assert_eq!(result["run"]["action_items"][0]["kind"], "review_pending");
                assert_eq!(result["run"]["action_items"][0]["source"], "manifest");
                assert_eq!(result["run"]["provider_target"], "codex:gpt-5.4");
                assert_eq!(
                    result["run"]["experiment_packet"]["result"],
                    "consult before work"
                );
                assert_eq!(result["run"]["experiment_packet"]["confidence"], 0.66);
                assert_eq!(
                    result["run"]["experiment_packet"]["next_action"],
                    "approval_waiting"
                );
                assert_eq!(result["run"]["experiment_packet"]["slot"], "slot-builder-1");
                assert!(result["run"]["security_policy"].is_null());
                assert!(result["run"]["security_verdict"].is_null());
                assert!(result["run"]["verification_contract"].is_null());
                assert!(result["run"]["verification_result"].is_null());
                assert_eq!(result["explanation"]["current_state"]["state"], "idle");
                assert_eq!(
                    result["explanation"]["current_state"]["task_state"],
                    "in_progress"
                );
                assert_eq!(
                    result["explanation"]["current_state"]["review_state"],
                    "PENDING"
                );
                assert_eq!(
                    result["explanation"]["current_state"]["last_event"],
                    "operator.review_requested"
                );
                assert_eq!(
                    result["consultation_packet"]["recommendation"],
                    "consult before work"
                );
                assert_eq!(
                    result["observation_pack"]["working_tree_summary"],
                    "1 file modified"
                );
                let changed_files = result["observation_pack"]["changed_files"]
                    .as_array()
                    .expect("observation_pack.changed_files should be an array");
                assert!(changed_files
                    .iter()
                    .any(|value| { value.as_str() == Some("scripts/winsmux-core.ps1") }));
                assert!(result["observation_pack"].get("packet_type").is_none());
                assert!(result["consultation_packet"].get("packet_type").is_none());
                assert_eq!(result["evidence_digest"]["next_action"], "review_pending");
                assert_eq!(result["review_state"]["status"], "PENDING");
                assert!(result.get("consultation_summary").is_none());
                assert!(result["run"].get("run_packet").is_none());
                assert!(result.get("run_packet").is_none());
                assert!(result.get("result_packet").is_none());
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["explain task:task-256 --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_run_promote() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_promote_tactic_payload(),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-promote"),
                method: "desktop.run.promote".to_string(),
                params: Some(serde_json::json!({
                    "runId": "task:task-256"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-promote"));
                assert_eq!(result["run_id"], "task:task-256");
                assert_eq!(
                    result["candidate_ref"],
                    ".winsmux/playbook-candidates/playbook-candidate-__ID__.json"
                );
                assert_eq!(result["candidate"]["packet_type"], "playbook_candidate");
                assert_eq!(result["candidate"]["kind"], "playbook");
                assert_eq!(result["candidate"]["title"], "Stabilize explain contract");
                assert_eq!(result["candidate"]["next_action"], "promote_to_playbook");
                assert_eq!(result["candidate"]["confidence"], 0.82);
                assert_eq!(
                    result["candidate"]["changed_files"][0],
                    "winsmux-app/src-tauri/src/desktop_backend.rs"
                );
                assert_eq!(
                    result["candidate"]["consultation_ref"],
                    ".winsmux/consultations/consult-result-__ID__.json"
                );
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["promote-tactic task:task-256 --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_run_compare() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_compare_runs_payload(),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-compare"),
                method: "desktop.run.compare".to_string(),
                params: Some(serde_json::json!({
                    "leftRunId": "task:task-256",
                    "rightRunId": "task:task-257"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-compare"));
                assert_eq!(result["left"]["run_id"], "task:task-256");
                assert_eq!(result["right"]["run_id"], "task:task-257");
                assert_eq!(result["confidence_delta"], 0.45);
                assert_eq!(result["differences"][0]["field"], "result");
                assert_eq!(result["recommend"]["winning_run_id"], "task:task-256");
                assert_eq!(result["recommend"]["reconcile_consult"], true);
                assert_eq!(result["recommend"]["next_action"], "reconcile_consult");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["compare-runs task:task-256 task:task-257 --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_run_pick_winner() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: desktop_pick_winner_payload(),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-pick-winner"),
                method: "desktop.run.pick_winner".to_string(),
                params: Some(serde_json::json!({
                    "runId": "task:task-256",
                    "peerSlot": "builder-2",
                    "recommendation": "Pick builder-1",
                    "confidence": 0.85,
                    "nextTest": "promote tactic"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-pick-winner"));
                assert_eq!(result["run_id"], "task:task-256");
                assert_eq!(result["mode"], "final");
                assert_eq!(result["target_slot"], "builder-2");
                assert_eq!(result["recommendation"], "Pick builder-1");
                assert_eq!(result["next_test"], "promote tactic");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["consult-result final --run-id task:task-256 --message Pick builder-1 --target-slot builder-2 --next-test promote tactic --json --confidence 0.85"]
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_head_sha() {
        let err = expect_missing_explain_run_field("head_sha");

        assert!(
            err.contains("head_sha"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_allows_null_review_state() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: rust_parity_explain_payload(),
        };

        let payload =
            load_desktop_run_explain(&transport, "task:task-256".to_string(), None).unwrap();

        assert!(payload.review_state.is_none());
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_explanation_next_action() {
        let mut response = rust_parity_explain_payload();
        response["explanation"]
            .as_object_mut()
            .expect("explanation must be an object")
            .remove("next_action");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("next_action"),
            "unexpected explain parse error: {err}"
        );
    }

    fn expect_missing_explanation_current_state_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["explanation"]["current_state"]
            .as_object_mut()
            .expect("explanation.current_state must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing explanation.current_state field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_explanation_current_state_state() {
        let err = expect_missing_explanation_current_state_field("state");

        assert!(
            err.contains("state"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_explanation_current_state_task_state() {
        let err = expect_missing_explanation_current_state_field("task_state");

        assert!(
            err.contains("task_state"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_explanation_current_state_review_state() {
        let err = expect_missing_explanation_current_state_field("review_state");

        assert!(
            err.contains("review_state"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_explanation_current_state_last_event() {
        let err = expect_missing_explanation_current_state_field("last_event");

        assert!(
            err.contains("last_event"),
            "unexpected explain parse error: {err}"
        );
    }

    fn expect_missing_consultation_packet_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["consultation_packet"]
            .as_object_mut()
            .expect("consultation_packet must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing consultation_packet field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_run_id() {
        let err = expect_missing_consultation_packet_field("run_id");

        assert!(
            err.contains("run_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_task_id() {
        let err = expect_missing_consultation_packet_field("task_id");

        assert!(
            err.contains("task_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_pane_id() {
        let err = expect_missing_consultation_packet_field("pane_id");

        assert!(
            err.contains("pane_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_slot() {
        let err = expect_missing_consultation_packet_field("slot");

        assert!(
            err.contains("slot"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_kind() {
        let err = expect_missing_consultation_packet_field("kind");

        assert!(
            err.contains("kind"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_mode() {
        let err = expect_missing_consultation_packet_field("mode");

        assert!(
            err.contains("mode"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_target_slot() {
        let err = expect_missing_consultation_packet_field("target_slot");

        assert!(
            err.contains("target_slot"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_confidence() {
        let err = expect_missing_consultation_packet_field("confidence");

        assert!(
            err.contains("confidence"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_recommendation() {
        let err = expect_missing_consultation_packet_field("recommendation");

        assert!(
            err.contains("recommendation"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_next_test() {
        let err = expect_missing_consultation_packet_field("next_test");

        assert!(
            err.contains("next_test"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_risks() {
        let err = expect_missing_consultation_packet_field("risks");

        assert!(
            err.contains("risks"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_consultation_packet_generated_at() {
        let err = expect_missing_consultation_packet_field("generated_at");

        assert!(
            err.contains("generated_at"),
            "unexpected explain parse error: {err}"
        );
    }

    fn expect_missing_observation_pack_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["observation_pack"]
            .as_object_mut()
            .expect("observation_pack must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing observation_pack field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_run_id() {
        let err = expect_missing_observation_pack_field("run_id");

        assert!(
            err.contains("run_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_task_id() {
        let err = expect_missing_observation_pack_field("task_id");

        assert!(
            err.contains("task_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_pane_id() {
        let err = expect_missing_observation_pack_field("pane_id");

        assert!(
            err.contains("pane_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_slot() {
        let err = expect_missing_observation_pack_field("slot");

        assert!(
            err.contains("slot"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_hypothesis() {
        let err = expect_missing_observation_pack_field("hypothesis");

        assert!(
            err.contains("hypothesis"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_test_plan() {
        let err = expect_missing_observation_pack_field("test_plan");

        assert!(
            err.contains("test_plan"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_changed_files() {
        let err = expect_missing_observation_pack_field("changed_files");

        assert!(
            err.contains("changed_files"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_working_tree_summary() {
        let err = expect_missing_observation_pack_field("working_tree_summary");

        assert!(
            err.contains("working_tree_summary"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_failing_command() {
        let err = expect_missing_observation_pack_field("failing_command");

        assert!(
            err.contains("failing_command"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_env_fingerprint() {
        let err = expect_missing_observation_pack_field("env_fingerprint");

        assert!(
            err.contains("env_fingerprint"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_command_hash() {
        let err = expect_missing_observation_pack_field("command_hash");

        assert!(
            err.contains("command_hash"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_observation_pack_generated_at() {
        let err = expect_missing_observation_pack_field("generated_at");

        assert!(
            err.contains("generated_at"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_provider_target() {
        let err = expect_missing_explain_run_field("provider_target");

        assert!(
            err.contains("provider_target"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_worktree() {
        let err = expect_missing_explain_run_field("worktree");

        assert!(
            err.contains("worktree"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_task_id() {
        let err = expect_missing_explain_run_field("task_id");

        assert!(
            err.contains("task_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_primary_label() {
        let err = expect_missing_explain_run_field("primary_label");

        assert!(
            err.contains("primary_label"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_primary_pane_id() {
        let err = expect_missing_explain_run_field("primary_pane_id");

        assert!(
            err.contains("primary_pane_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_primary_role() {
        let err = expect_missing_explain_run_field("primary_role");

        assert!(
            err.contains("primary_role"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_last_event() {
        let err = expect_missing_explain_run_field("last_event");

        assert!(
            err.contains("last_event"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_last_event_at() {
        let err = expect_missing_explain_run_field("last_event_at");

        assert!(
            err.contains("last_event_at"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_changed_file_count() {
        let err = expect_missing_explain_run_field("changed_file_count");

        assert!(
            err.contains("changed_file_count"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_pane_count() {
        let err = expect_missing_explain_run_field("pane_count");

        assert!(
            err.contains("pane_count"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_tokens_remaining() {
        let err = expect_missing_explain_run_field("tokens_remaining");

        assert!(
            err.contains("tokens_remaining"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_labels() {
        let err = expect_missing_explain_run_field("labels");

        assert!(
            err.contains("labels"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_pane_ids() {
        let err = expect_missing_explain_run_field("pane_ids");

        assert!(
            err.contains("pane_ids"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_roles() {
        let err = expect_missing_explain_run_field("roles");

        assert!(
            err.contains("roles"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_parent_run_id() {
        let err = expect_missing_explain_run_field("parent_run_id");

        assert!(
            err.contains("parent_run_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_goal() {
        let err = expect_missing_explain_run_field("goal");

        assert!(
            err.contains("goal"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_task_type() {
        let err = expect_missing_explain_run_field("task_type");

        assert!(
            err.contains("task_type"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_priority() {
        let err = expect_missing_explain_run_field("priority");

        assert!(
            err.contains("priority"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_blocking() {
        let err = expect_missing_explain_run_field("blocking");

        assert!(
            err.contains("blocking"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_write_scope() {
        let err = expect_missing_explain_run_field("write_scope");

        assert!(
            err.contains("write_scope"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_read_scope() {
        let err = expect_missing_explain_run_field("read_scope");

        assert!(
            err.contains("read_scope"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_constraints() {
        let err = expect_missing_explain_run_field("constraints");

        assert!(
            err.contains("constraints"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_expected_output() {
        let err = expect_missing_explain_run_field("expected_output");

        assert!(
            err.contains("expected_output"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_verification_plan() {
        let err = expect_missing_explain_run_field("verification_plan");

        assert!(
            err.contains("verification_plan"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_review_required() {
        let err = expect_missing_explain_run_field("review_required");

        assert!(
            err.contains("review_required"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_timeout_policy() {
        let err = expect_missing_explain_run_field("timeout_policy");

        assert!(
            err.contains("timeout_policy"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_handoff_refs() {
        let err = expect_missing_explain_run_field("handoff_refs");

        assert!(
            err.contains("handoff_refs"),
            "unexpected explain parse error: {err}"
        );
    }

    fn expect_missing_explain_experiment_packet_field(field_name: &str) -> String {
        let mut response = rust_parity_explain_payload();
        response["run"]["experiment_packet"]
            .as_object_mut()
            .expect("run.experiment_packet must be an object")
            .remove(field_name);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!(
                "expected explain payload parse failure for missing experiment packet field {}",
                field_name
            ),
            Err(err) => err,
        }
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_hypothesis() {
        let err = expect_missing_explain_experiment_packet_field("hypothesis");

        assert!(
            err.contains("hypothesis"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_test_plan() {
        let err = expect_missing_explain_experiment_packet_field("test_plan");

        assert!(
            err.contains("test_plan"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_result() {
        let err = expect_missing_explain_experiment_packet_field("result");

        assert!(
            err.contains("result"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_confidence() {
        let err = expect_missing_explain_experiment_packet_field("confidence");

        assert!(
            err.contains("confidence"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_next_action() {
        let err = expect_missing_explain_experiment_packet_field("next_action");

        assert!(
            err.contains("next_action"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_observation_pack_ref() {
        let err = expect_missing_explain_experiment_packet_field("observation_pack_ref");

        assert!(
            err.contains("observation_pack_ref"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_consultation_ref() {
        let err = expect_missing_explain_experiment_packet_field("consultation_ref");

        assert!(
            err.contains("consultation_ref"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_run_id() {
        let err = expect_missing_explain_experiment_packet_field("run_id");

        assert!(
            err.contains("run_id"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_slot() {
        let err = expect_missing_explain_experiment_packet_field("slot");

        assert!(
            err.contains("slot"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_branch() {
        let err = expect_missing_explain_experiment_packet_field("branch");

        assert!(
            err.contains("branch"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_worktree() {
        let err = expect_missing_explain_experiment_packet_field("worktree");

        assert!(
            err.contains("worktree"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_env_fingerprint() {
        let err = expect_missing_explain_experiment_packet_field("env_fingerprint");

        assert!(
            err.contains("env_fingerprint"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_experiment_packet_command_hash() {
        let err = expect_missing_explain_experiment_packet_field("command_hash");

        assert!(
            err.contains("command_hash"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_security_policy() {
        let err = expect_missing_explain_run_field("security_policy");

        assert!(
            err.contains("security_policy"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_security_verdict() {
        let err = expect_missing_explain_run_field("security_verdict");

        assert!(
            err.contains("security_verdict"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_verification_contract() {
        let err = expect_missing_explain_run_field("verification_contract");

        assert!(
            err.contains("verification_contract"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_run_verification_result() {
        let err = expect_missing_explain_run_field("verification_result");

        assert!(
            err.contains("verification_result"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_action_item_message() {
        let err = expect_missing_explain_action_item_field("message");

        assert!(
            err.contains("message"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_action_item_source() {
        let err = expect_missing_explain_action_item_field("source");

        assert!(
            err.contains("source"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_evidence_verification_outcome() {
        let mut response = rust_parity_explain_payload();
        response["evidence_digest"]
            .as_object_mut()
            .expect("evidence_digest must be an object")
            .remove("verification_outcome");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("verification_outcome"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_evidence_security_blocked() {
        let mut response = rust_parity_explain_payload();
        response["evidence_digest"]
            .as_object_mut()
            .expect("evidence_digest must be an object")
            .remove("security_blocked");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("security_blocked"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_review_state_status_when_present() {
        let mut response = rust_parity_explain_payload_with_review_state();
        response["review_state"]
            .as_object_mut()
            .expect("review_state must be an object")
            .remove("status");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("status"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_deserializes_branch_map() {
        let snapshot =
            parse_desktop_review_state_snapshot(rust_parity_review_state_snapshot_payload())
                .expect("review-state fixture should deserialize");

        let record = snapshot
            .get("worktree-builder-1")
            .expect("review-state fixture should contain branch key");
        assert_eq!(record.status, "PENDING");
        assert_eq!(record.branch, "worktree-builder-1");
        assert_eq!(record.request.review_contract.source_task, "TASK-210");
        assert_eq!(
            record.request.review_contract.required_scope,
            vec![
                "design_impact".to_string(),
                "replacement_coverage".to_string(),
                "orphaned_artifacts".to_string(),
                "pathspec_completeness".to_string()
            ]
        );
        let pathspec_policy = record
            .request
            .review_contract
            .pathspec_policy
            .as_ref()
            .expect("pathspec policy should be present");
        assert_eq!(pathspec_policy.source_task, "TASK-395");
        assert!(pathspec_policy.include_definition_hosts);
    }

    #[test]
    fn parse_desktop_review_state_snapshot_accepts_legacy_target_reviewer_fields() {
        let mut response = rust_parity_review_state_snapshot_payload();
        let request = response["worktree-builder-1"]["request"]
            .as_object_mut()
            .expect("review-state request must be an object");
        request.remove("target_review_pane_id");
        request.remove("target_review_label");
        request.remove("target_review_role");

        parse_desktop_review_state_snapshot(response)
            .expect("legacy target_reviewer fields should remain readable");
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_missing_target_review_identity() {
        let mut response = rust_parity_review_state_snapshot_payload();
        let request = response["worktree-builder-1"]["request"]
            .as_object_mut()
            .expect("review-state request must be an object");
        request.remove("target_review_pane_id");
        request.remove("target_reviewer_pane_id");

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("target_review_pane_id"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_missing_reviewer() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]
            .as_object_mut()
            .expect("review-state record must be an object")
            .remove("reviewer");

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("reviewer"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_branch_mismatch() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]["branch"] = serde_json::json!("other-branch");

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("branch mismatch"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_request_branch_mismatch() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]["request"]["branch"] = serde_json::json!("other-branch");

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("request.branch"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_request_head_mismatch() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]["request"]["head_sha"] = serde_json::json!("other-head");

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("request.head_sha"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_pass_review_state_without_approved_via() {
        let mut response = rust_parity_explain_payload_with_review_state();
        response["review_state"]["status"] = serde_json::json!("PASS");
        response["review_state"]["evidence"] = serde_json::json!({
            "approved_at": "__TIMESTAMP__",
            "review_contract_snapshot": response["review_state"]["request"]["review_contract"].clone()
        });

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("approved_via"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_fail_without_failed_via() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]["status"] = serde_json::json!("FAIL");
        response["worktree-builder-1"]["evidence"] = serde_json::json!({
            "failed_at": "__TIMESTAMP__",
            "review_contract_snapshot": response["worktree-builder-1"]["request"]["review_contract"].clone()
        });

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("failed_via"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_missing_review_contract_required_scope() {
        let mut response = rust_parity_explain_payload_with_review_state();
        response["review_state"]["request"]["review_contract"]
            .as_object_mut()
            .expect("review_state.request.review_contract must be an object")
            .remove("required_scope");

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("required_scope"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn load_desktop_run_explain_rejects_empty_review_contract_required_scope() {
        let mut response = rust_parity_explain_payload_with_review_state();
        response["review_state"]["request"]["review_contract"]["required_scope"] =
            serde_json::json!([]);

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response,
        };

        let err = match load_desktop_run_explain(&transport, "task:task-256".to_string(), None) {
            Ok(_) => panic!("expected explain payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("required_scope"),
            "unexpected explain parse error: {err}"
        );
    }

    #[test]
    fn parse_desktop_review_state_snapshot_rejects_empty_evidence_required_scope() {
        let mut response = rust_parity_review_state_snapshot_payload();
        response["worktree-builder-1"]["status"] = serde_json::json!("PASS");
        response["worktree-builder-1"]["evidence"] = serde_json::json!({
            "approved_at": "__TIMESTAMP__",
            "approved_via": "winsmux review-approve",
            "review_contract_snapshot": {
                "version": 1,
                "source_task": "TASK-210",
                "issue_ref": "#315",
                "style": "utility_first",
                "required_scope": [],
                "checklist_labels": ["design impact"],
                "rationale": "Contract snapshot"
            }
        });

        let err = match parse_desktop_review_state_snapshot(response) {
            Ok(_) => panic!("expected review-state payload parse failure"),
            Err(err) => err,
        };

        assert!(
            err.contains("required_scope"),
            "unexpected review-state parse error: {err}"
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_editor_read() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-editor-read-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(temp_dir.join("winsmux-app").join("src")).unwrap();
        std::fs::write(
            temp_dir.join("winsmux-app").join("src").join("main.ts"),
            "console.log('hello');\nconsole.log('world');\n",
        )
        .unwrap();

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-file"),
                method: "desktop.editor.read".to_string(),
                params: Some(serde_json::json!({
                    "path": "winsmux-app/src/main.ts",
                    "worktree": "."
                })),
            },
            Some(temp_dir.to_string_lossy().to_string()),
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-file"));
                assert_eq!(result["path"], "winsmux-app/src/main.ts");
                assert_eq!(result["line_count"], 2);
                assert_eq!(result["truncated"], false);
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert!(transport.requests.borrow().is_empty());

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn handle_desktop_json_rpc_routes_editor_read_from_worktree() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-editor-worktree-{}",
            std::process::id()
        ));
        let worktree_dir = temp_dir.join(".worktrees").join("builder-1");
        let target_file = worktree_dir.join("winsmux-app").join("src").join("main.ts");

        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(target_file.parent().unwrap()).unwrap();
        std::fs::write(&target_file, "console.log('worktree');\n").unwrap();

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-worktree"),
                method: "desktop.editor.read".to_string(),
                params: Some(serde_json::json!({
                    "path": "winsmux-app/src/main.ts",
                    "worktree": ".worktrees/builder-1"
                })),
            },
            Some(temp_dir.to_string_lossy().to_string()),
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-worktree"));
                assert_eq!(result["path"], "winsmux-app/src/main.ts");
                assert!(result["content"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("worktree"));
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn handle_desktop_json_rpc_routes_summary_snapshot() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: rust_parity_summary_snapshot_payload(),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-1"),
                method: "desktop.summary.snapshot".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-1"));
                assert_eq!(result["project_dir"], "__PROJECT_DIR__");
                assert_eq!(result["board"]["summary"]["tasks_blocked"], 0);
                assert_eq!(result["board"]["summary"]["by_state"]["busy"], 1);
                assert_eq!(result["board"]["summary"]["by_review"]["unknown"], 1);
                assert_eq!(result["digest"]["summary"]["actionable_items"], 1);
                assert_eq!(result["digest"]["summary"]["dirty_items"], 1);
                assert_eq!(result["inbox"]["summary"]["by_kind"]["approval_waiting"], 1);
                assert_eq!(result["inbox"]["items"][0]["pane_id"], "%6");
                assert_eq!(result["inbox"]["items"][0]["priority"], 0);
                assert_eq!(result["inbox"]["items"][0]["role"], "Worker");
                assert_eq!(result["inbox"]["items"][0]["task_id"], "task-999");
                assert_eq!(result["inbox"]["items"][0]["head_sha"], "def5678abc1234");
                assert_eq!(result["inbox"]["items"][0]["timestamp"], "__TIMESTAMP__");
                assert_eq!(result["board"]["panes"][0]["pane_id"], "%2");
                assert_eq!(result["digest"]["items"][0]["run_id"], "task:task-246");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["desktop-summary --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_rejects_unknown_method() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-2"),
                method: "desktop.unknown".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Error { id, error, .. } => {
                assert_eq!(id, serde_json::json!("req-2"));
                assert_eq!(error.code, JSON_RPC_METHOD_NOT_FOUND);
            }
            DesktopJsonRpcResponse::Success { .. } => panic!("expected error response"),
        }
        assert!(transport.requests.borrow().is_empty());
    }

    #[test]
    fn handle_desktop_json_rpc_requires_run_id_for_explain() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-3"),
                method: "desktop.run.explain".to_string(),
                params: Some(serde_json::json!({})),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            DesktopJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }
        assert!(transport.requests.borrow().is_empty());
    }

    #[test]
    fn parse_desktop_summary_stream_signal_extracts_digest_run_and_pane() {
        let signal = parse_desktop_summary_stream_signal(
            "digest",
            r#"{"run_id":"task:task-289","pane_id":"%4","label":"builder-1"}"#,
        )
        .unwrap();

        assert_eq!(
            signal,
            DesktopSummaryRefreshSignal {
                source: "digest".to_string(),
                reason: "digest.stream".to_string(),
                pane_id: Some("%4".to_string()),
                run_id: Some("task:task-289".to_string()),
            }
        );
    }

    #[test]
    fn parse_desktop_summary_stream_signal_accepts_inbox_items_without_run_id() {
        let signal = parse_desktop_summary_stream_signal(
            "inbox",
            r#"{"kind":"review_requested","pane_id":"%7","label":"reviewer-1"}"#,
        )
        .unwrap();

        assert_eq!(signal.source, "inbox");
        assert_eq!(signal.reason, "inbox.stream");
        assert_eq!(signal.pane_id.as_deref(), Some("%7"));
        assert_eq!(signal.run_id, None);
    }

    #[test]
    fn parse_desktop_summary_stream_signal_accepts_summary_reason_and_run() {
        let signal = parse_desktop_summary_stream_signal(
            "summary",
            r#"{"reason":"pane.completed","pane_id":"%4","run_id":"task:task-289"}"#,
        )
        .unwrap();

        assert_eq!(
            signal,
            DesktopSummaryRefreshSignal {
                source: "summary".to_string(),
                reason: "pane.completed".to_string(),
                pane_id: Some("%4".to_string()),
                run_id: Some("task:task-289".to_string()),
            }
        );
    }

    #[test]
    fn parse_desktop_summary_stream_signal_rejects_untyped_json_lines() {
        assert!(parse_desktop_summary_stream_signal("digest", r#"{"pane_id":"%2"}"#).is_none());
        assert!(
            parse_desktop_summary_stream_signal("inbox", r#"{"message":"missing kind"}"#).is_none()
        );
        assert!(parse_desktop_summary_stream_signal("summary", r#"{"pane_id":"%2"}"#).is_none());
    }
}
