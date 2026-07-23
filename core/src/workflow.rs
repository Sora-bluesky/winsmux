use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Write};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::workspace_recipe::{parse_workspace_yaml, NormalizedWorkspacePlan};

const WORKFLOW_SCHEMA_VERSION: u64 = 1;
const RUN_ID_TOKEN: &str = "{{run-id}}";
const MAX_WORKFLOW_RUN_ID_BYTES: usize = 192;
const MAX_WORKFLOW_IDEMPOTENCY_KEY_BYTES: usize = 192;
const MAX_WORKFLOW_STATE_BYTES: usize = 1_048_576;

#[derive(Debug, Default)]
pub(crate) struct WorkflowPlanCliOptions {
    workflow_id: Option<String>,
    run_id: Option<String>,
}

impl WorkflowPlanCliOptions {
    pub(crate) fn parse_option(&mut self, args: &[&String], index: usize) -> io::Result<usize> {
        let flag = args[index].as_str();
        let target = match flag {
            "--workflow-id" => &mut self.workflow_id,
            "--run-id" => &mut self.run_id,
            _ => return Err(invalid_input("unknown workflow plan argument.")),
        };
        if target.is_some() {
            return Err(invalid_input(format!("{flag} may be specified only once.")));
        }
        *target = Some(
            args.get(index + 1)
                .ok_or_else(|| invalid_input(format!("{flag} requires a value")))?
                .to_string(),
        );
        Ok(index + 2)
    }

    pub(crate) fn validate(&self) -> io::Result<()> {
        if self.run_id.is_some() && self.workflow_id.is_none() {
            return Err(invalid_input(
                "workspace-plan --run-id requires --workflow-id.",
            ));
        }
        Ok(())
    }

    pub(crate) fn workflow_id(&self) -> Option<&str> {
        self.workflow_id.as_deref()
    }

    pub(crate) fn normalized_payload(
        &self,
        root: &serde_yaml::Value,
        plan: &NormalizedWorkspacePlan,
    ) -> io::Result<Option<serde_json::Value>> {
        let (Some(workflow_id), Some(run_id)) = (&self.workflow_id, &self.run_id) else {
            return Ok(None);
        };
        let pane_worktree_modes = normalized_pane_worktree_modes(plan)?;
        let workflow = normalize_workflow_plan_from_value(
            root,
            workflow_id,
            run_id,
            &plan.recipe_id,
            &plan.resolved_bindings,
            &pane_worktree_modes,
        )?;
        let mut payload = serde_json::to_value(plan).map_err(|error| {
            invalid_data(format!("failed to serialize workspace plan: {error}"))
        })?;
        payload
            .as_object_mut()
            .ok_or_else(|| invalid_data("workspace plan must be an object."))?
            .insert(
                "workflow".to_string(),
                serde_json::to_value(workflow).map_err(|error| {
                    invalid_data(format!("failed to serialize workflow plan: {error}"))
                })?,
            );
        Ok(Some(payload))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedWorkflowPlan {
    pub schema_version: u64,
    pub workflow_id: String,
    pub recipe_ref: String,
    pub workflow_fingerprint: String,
    pub task_input: NormalizedTaskInput,
    pub resolved_bindings: BTreeMap<String, String>,
    pub nodes: Vec<NormalizedWorkflowNode>,
    pub resume_policy: NormalizedResumePolicy,
    pub cleanup_policy: NormalizedCleanupPolicy,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedTaskInput {
    pub source: String,
    pub privacy: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum WorkflowAction {
    OperatorDispatch,
    Verification,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedWorkflowNode {
    pub node_id: String,
    pub pane_ref: String,
    pub action: WorkflowAction,
    pub depends_on: Vec<String>,
    pub idempotency_key: String,
    pub cleanup: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_pack_ref: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedResumePolicy {
    pub mode: String,
    pub reject_completed_runs: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedCleanupPolicy {
    pub mode: String,
    pub on: Vec<String>,
    pub actions: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Planned,
    Ready,
    Running,
    Blocked,
    Failed,
    CleanupPending,
    Succeeded,
    Cancelled,
    RolledBack,
}

impl RunState {
    pub fn allows_resume(self) -> bool {
        !matches!(self, Self::Succeeded | Self::Cancelled | Self::RolledBack)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeState {
    Pending,
    Ready,
    Dispatching,
    Running,
    Blocked,
    Failed,
    Succeeded,
    CleanupPending,
    Cleaned,
    RolledBack,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct Workflow {
    schema_version: u64,
    recipe_ref: String,
    task_input: TaskInput,
    nodes: Vec<WorkflowNode>,
    resume_policy: ResumePolicy,
    cleanup_policy: CleanupPolicy,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct TaskInput {
    source: String,
    privacy: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct WorkflowNode {
    node_id: String,
    pane_ref: String,
    action: WorkflowAction,
    #[serde(default)]
    depends_on: Vec<String>,
    idempotency_key: String,
    cleanup: String,
    #[serde(default)]
    context_pack_ref: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ResumePolicy {
    mode: String,
    reject_completed_runs: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct CleanupPolicy {
    mode: String,
    on: Vec<String>,
    actions: Vec<String>,
}

#[derive(Serialize)]
struct FingerprintPayload<'a> {
    schema_version: u64,
    workflow_id: &'a str,
    recipe_ref: &'a str,
    task_input: &'a NormalizedTaskInput,
    resolved_bindings: &'a BTreeMap<String, String>,
    nodes: &'a [NormalizedWorkflowNode],
    resume_policy: &'a NormalizedResumePolicy,
    cleanup_policy: &'a NormalizedCleanupPolicy,
}

pub fn normalize_workflow_plan(
    yaml: &str,
    workflow_id: &str,
    run_id: &str,
    selected_recipe_id: &str,
    resolved_bindings: &BTreeMap<String, String>,
    pane_worktree_modes: &BTreeMap<String, String>,
) -> io::Result<NormalizedWorkflowPlan> {
    let root = parse_workspace_yaml(yaml)?;
    normalize_workflow_plan_from_value(
        &root,
        workflow_id,
        run_id,
        selected_recipe_id,
        resolved_bindings,
        pane_worktree_modes,
    )
}

fn normalized_pane_worktree_modes(
    plan: &NormalizedWorkspacePlan,
) -> io::Result<BTreeMap<String, String>> {
    let mut modes = BTreeMap::new();
    for pane in &plan.panes {
        let expected_slot = plan.resolved_bindings.get(&pane.pane_key).ok_or_else(|| {
            invalid_data(format!(
                "workspace pane '{}' has no resolved binding.",
                pane.pane_key
            ))
        })?;
        if expected_slot != &pane.slot_id {
            return Err(invalid_data(format!(
                "workspace pane '{}' slot does not match its resolved binding.",
                pane.pane_key
            )));
        }
        if !matches!(
            pane.worktree.mode.as_str(),
            "managed" | "read-only-reference"
        ) {
            return Err(invalid_data(format!(
                "workspace pane '{}' has an unsupported worktree mode.",
                pane.pane_key
            )));
        }
        if modes
            .insert(pane.pane_key.clone(), pane.worktree.mode.clone())
            .is_some()
        {
            return Err(invalid_data(format!(
                "duplicate workspace pane policy '{}'.",
                pane.pane_key
            )));
        }
    }
    if modes.len() != plan.resolved_bindings.len()
        || plan
            .resolved_bindings
            .keys()
            .any(|pane_ref| !modes.contains_key(pane_ref))
    {
        return Err(invalid_data(
            "workspace pane policies must exactly cover resolved bindings.",
        ));
    }
    Ok(modes)
}

pub(crate) fn normalize_workflow_plan_from_value(
    root: &serde_yaml::Value,
    workflow_id: &str,
    run_id: &str,
    selected_recipe_id: &str,
    resolved_bindings: &BTreeMap<String, String>,
    pane_worktree_modes: &BTreeMap<String, String>,
) -> io::Result<NormalizedWorkflowPlan> {
    require_stable_id("workflow-id", workflow_id)?;
    require_workflow_run_id("run-id", run_id)?;
    require_stable_id("recipe-id", selected_recipe_id)?;
    for (pane_ref, slot_id) in resolved_bindings {
        require_stable_id("pane-ref", pane_ref)?;
        require_stable_id("slot-id", slot_id)?;
    }
    if pane_worktree_modes.len() != resolved_bindings.len()
        || resolved_bindings
            .keys()
            .any(|pane_ref| !pane_worktree_modes.contains_key(pane_ref))
    {
        return Err(invalid_data(
            "workflow pane policies must exactly cover resolved bindings.",
        ));
    }
    for (pane_ref, mode) in pane_worktree_modes {
        if !resolved_bindings.contains_key(pane_ref)
            || !matches!(mode.as_str(), "managed" | "read-only-reference")
        {
            return Err(invalid_data("invalid workflow pane worktree policy."));
        }
    }

    let root = root
        .as_mapping()
        .ok_or_else(|| invalid_data(".winsmux.yaml must be a mapping."))?;
    let workflows = root
        .get(&serde_yaml::Value::String("workflows".to_string()))
        .and_then(serde_yaml::Value::as_mapping)
        .ok_or_else(|| invalid_data("workflows must be a mapping."))?;
    let value = workflows
        .get(&serde_yaml::Value::String(workflow_id.to_string()))
        .ok_or_else(|| invalid_input(format!("workflow '{workflow_id}' was not found.")))?;
    let workflow: Workflow = serde_yaml::from_value(value.clone())
        .map_err(|_| invalid_data("invalid workflow schema."))?;

    if workflow.schema_version != WORKFLOW_SCHEMA_VERSION {
        return Err(invalid_data(format!(
            "unsupported workflow schema-version '{}'; supported version is {WORKFLOW_SCHEMA_VERSION}.",
            workflow.schema_version
        )));
    }
    if workflow.recipe_ref != selected_recipe_id {
        return Err(invalid_data(
            "workflow recipe-ref does not match the selected recipe.",
        ));
    }
    if workflow.task_input.source != "runtime-task-file"
        || workflow.task_input.privacy != "digest-only"
    {
        return Err(invalid_data("unsupported workflow task-input contract."));
    }
    if workflow.nodes.is_empty() {
        return Err(invalid_data("workflow must contain at least one node."));
    }
    if workflow.resume_policy.mode != "operator-confirmed"
        || !workflow.resume_policy.reject_completed_runs
    {
        return Err(invalid_data("unsupported workflow resume-policy."));
    }
    if workflow.cleanup_policy.mode != "compensating-actions"
        || workflow.cleanup_policy.actions != ["release-run-lock"]
    {
        return Err(invalid_data("unsupported workflow cleanup-policy actions."));
    }
    let mut cleanup_on = BTreeSet::new();
    for value in &workflow.cleanup_policy.on {
        if !matches!(value.as_str(), "success" | "failure" | "cancel")
            || !cleanup_on.insert(value.clone())
        {
            return Err(invalid_data("invalid workflow cleanup-policy trigger."));
        }
    }
    if cleanup_on
        != BTreeSet::from([
            "cancel".to_string(),
            "failure".to_string(),
            "success".to_string(),
        ])
    {
        return Err(invalid_data(
            "workflow cleanup-policy must cover success, failure, and cancel.",
        ));
    }

    let mut by_id = BTreeMap::new();
    for node in workflow.nodes {
        require_stable_id("node-id", &node.node_id)?;
        require_stable_id("pane-ref", &node.pane_ref)?;
        if !resolved_bindings.contains_key(&node.pane_ref) {
            return Err(invalid_data(format!(
                "workflow node '{}' references unknown pane '{}'.",
                node.node_id, node.pane_ref
            )));
        }
        if node.action == WorkflowAction::OperatorDispatch
            && pane_worktree_modes.get(&node.pane_ref).map(String::as_str) != Some("managed")
        {
            return Err(invalid_data(format!(
                "workflow node '{}' operator-dispatch requires a managed worktree.",
                node.node_id
            )));
        }
        if node.cleanup != "retain" {
            return Err(invalid_data("workflow node cleanup must be retain."));
        }
        let expected_key = format!("{RUN_ID_TOKEN}:{}", node.node_id);
        if node.idempotency_key != expected_key {
            return Err(invalid_data(format!(
                "workflow node '{}' idempotency-key must be '{{{{run-id}}}}:{}'.",
                node.node_id, node.node_id
            )));
        }
        let mut dependencies = BTreeSet::new();
        for dependency in &node.depends_on {
            require_stable_id("depends-on", dependency)?;
            if dependency == &node.node_id {
                return Err(invalid_data("workflow node cannot depend on itself."));
            }
            if !dependencies.insert(dependency.clone()) {
                return Err(invalid_data("duplicate workflow dependency."));
            }
        }
        let node_id = node.node_id.clone();
        if by_id.insert(node_id.clone(), node).is_some() {
            return Err(invalid_data(format!("duplicate node-id '{node_id}'.")));
        }
    }

    for node in by_id.values() {
        for dependency in &node.depends_on {
            if !by_id.contains_key(dependency) {
                return Err(invalid_data(format!(
                    "workflow node '{}' references missing dependency '{}'.",
                    node.node_id, dependency
                )));
            }
        }
    }

    let order = canonical_topological_order(&by_id)?;
    let nodes = order
        .into_iter()
        .map(|node_id| {
            let node = &by_id[&node_id];
            NormalizedWorkflowNode {
                node_id: node.node_id.clone(),
                pane_ref: node.pane_ref.clone(),
                action: node.action,
                depends_on: node
                    .depends_on
                    .iter()
                    .cloned()
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect(),
                idempotency_key: node.idempotency_key.replace(RUN_ID_TOKEN, run_id),
                cleanup: node.cleanup.clone(),
                context_pack_ref: node.context_pack_ref.clone(),
            }
        })
        .collect::<Vec<_>>();
    let task_input = NormalizedTaskInput {
        source: workflow.task_input.source,
        privacy: workflow.task_input.privacy,
    };
    let resume_policy = NormalizedResumePolicy {
        mode: workflow.resume_policy.mode,
        reject_completed_runs: workflow.resume_policy.reject_completed_runs,
    };
    let cleanup_policy = NormalizedCleanupPolicy {
        mode: workflow.cleanup_policy.mode,
        on: cleanup_on.into_iter().collect(),
        actions: vec!["release-run-lock".to_string()],
    };
    let payload = FingerprintPayload {
        schema_version: WORKFLOW_SCHEMA_VERSION,
        workflow_id,
        recipe_ref: selected_recipe_id,
        task_input: &task_input,
        resolved_bindings,
        nodes: &nodes,
        resume_policy: &resume_policy,
        cleanup_policy: &cleanup_policy,
    };
    let fingerprint_bytes = serde_json::to_vec(&payload).map_err(|error| {
        invalid_data(format!(
            "failed to serialize workflow fingerprint input: {error}"
        ))
    })?;

    let plan = NormalizedWorkflowPlan {
        schema_version: WORKFLOW_SCHEMA_VERSION,
        workflow_id: workflow_id.to_string(),
        recipe_ref: selected_recipe_id.to_string(),
        workflow_fingerprint: format!("sha256:{:x}", Sha256::digest(fingerprint_bytes)),
        task_input,
        resolved_bindings: resolved_bindings.clone(),
        nodes,
        resume_policy,
        cleanup_policy,
    };
    validate_normalized_workflow_plan(&plan, run_id)?;
    Ok(plan)
}

fn canonical_topological_order(nodes: &BTreeMap<String, WorkflowNode>) -> io::Result<Vec<String>> {
    let mut remaining = nodes
        .iter()
        .map(|(node_id, node)| {
            (
                node_id.clone(),
                node.depends_on.iter().cloned().collect::<BTreeSet<_>>(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut completed = BTreeSet::new();
    let mut order = Vec::with_capacity(nodes.len());
    while !remaining.is_empty() {
        let ready = remaining
            .iter()
            .filter(|(_, dependencies)| dependencies.is_subset(&completed))
            .map(|(node_id, _)| node_id.clone())
            .next();
        let Some(node_id) = ready else {
            return Err(invalid_data("workflow dependency graph contains a cycle."));
        };
        remaining.remove(&node_id);
        completed.insert(node_id.clone());
        order.push(node_id);
    }
    Ok(order)
}

pub fn initial_node_states(plan: &NormalizedWorkflowPlan) -> BTreeMap<String, NodeState> {
    plan.nodes
        .iter()
        .map(|node| {
            let state = if node.depends_on.is_empty() {
                NodeState::Ready
            } else {
                NodeState::Pending
            };
            (node.node_id.clone(), state)
        })
        .collect()
}

pub fn release_ready_nodes(
    plan: &NormalizedWorkflowPlan,
    states: &mut BTreeMap<String, NodeState>,
) -> BTreeSet<String> {
    let mut released = BTreeSet::new();
    for node in &plan.nodes {
        if states.get(&node.node_id) != Some(&NodeState::Pending) {
            continue;
        }
        if node
            .depends_on
            .iter()
            .all(|dependency| states.get(dependency) == Some(&NodeState::Succeeded))
        {
            states.insert(node.node_id.clone(), NodeState::Ready);
            released.insert(node.node_id.clone());
        }
    }
    released
}

const REDUCER_REQUEST_SCHEMA_VERSION: u64 = 1;
const WORKFLOW_RUN_SCHEMA_VERSION: u64 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ReducerOperation {
    Bootstrap,
    Transition,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapRequest {
    schema_version: u64,
    operation: ReducerOperation,
    plan: NormalizedWorkflowPlan,
    identity: WorkflowRunIdentity,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TransitionRequest {
    schema_version: u64,
    operation: ReducerOperation,
    run: WorkflowRun,
    event: WorkflowEvent,
    durable_proofs: DurableProofs,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkflowRunIdentity {
    run_id: String,
    generation_id: String,
    config_fingerprint: String,
    source_head: String,
    task_sha256: String,
    task_byte_count: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RollbackState {
    NotRequested,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum CleanupActionState {
    Pending,
    Running,
    Blocked,
    Succeeded,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PreservedRunState {
    Succeeded,
    Failed,
    Cancelled,
}

impl From<PreservedRunState> for RunState {
    fn from(value: PreservedRunState) -> Self {
        match value {
            PreservedRunState::Succeeded => Self::Succeeded,
            PreservedRunState::Failed => Self::Failed,
            PreservedRunState::Cancelled => Self::Cancelled,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CleanupActionRecord {
    action_id: String,
    kind: String,
    state: CleanupActionState,
    idempotency_key: String,
    resource_ref: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AcknowledgementStatus {
    Succeeded,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkflowCompletionProof {
    schema_version: u64,
    run_id: String,
    node_id: String,
    idempotency_key: String,
    generation_id: String,
    config_fingerprint: String,
    workflow_fingerprint: String,
    source_head: String,
    pane_id: String,
    status: AcknowledgementStatus,
    evidence_ref: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transport: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum CancellationStatus {
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkflowCancellationProof {
    schema_version: u64,
    run_id: String,
    idempotency_key: String,
    generation_id: String,
    config_fingerprint: String,
    workflow_fingerprint: String,
    source_head: String,
    status: CancellationStatus,
    evidence_ref: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DurableProofs {
    completion_acknowledgements: Vec<WorkflowCompletionProof>,
    cancellation_proofs: Vec<WorkflowCancellationProof>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkflowRuntimeNode {
    node_id: String,
    state: NodeState,
    attempt: u64,
    idempotency_key: String,
    pane_ref: String,
    action: WorkflowAction,
    depends_on: Vec<String>,
    cleanup: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    context_pack_ref: Option<String>,
    evidence_refs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent_cli_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    completion_proof: Option<WorkflowCompletionProof>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkflowRun {
    schema_version: u64,
    workflow_id: String,
    recipe_ref: String,
    run_id: String,
    state: RunState,
    generation_id: String,
    config_fingerprint: String,
    workflow_fingerprint: String,
    source_head: String,
    task_sha256: String,
    task_byte_count: u64,
    resolved_bindings: BTreeMap<String, String>,
    normalized_snapshot: NormalizedWorkflowPlan,
    node_order: Vec<String>,
    nodes: BTreeMap<String, WorkflowRuntimeNode>,
    cleanup_journal: Vec<CleanupActionRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cleanup_preserve_run_state: Option<PreservedRunState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cancellation_proof: Option<WorkflowCancellationProof>,
    rollback_state: RollbackState,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum WorkflowEvent {
    Validate,
    DispatchIntent {
        node_id: String,
    },
    Acknowledge {
        node_id: String,
        acknowledgement: WorkflowCompletionProof,
        resolved_session_id: String,
    },
    Block {
        node_id: String,
    },
    DispatchFailed {
        node_id: String,
    },
    CleanupIntent {
        #[serde(default)]
        preserve_run_state: Option<PreservedRunState>,
    },
    CleanupBlocked,
    CleanupSucceeded,
    Cancel {
        cancellation: WorkflowCancellationProof,
    },
}

pub fn reduce_workflow_state_value(request: &serde_json::Value) -> io::Result<serde_json::Value> {
    let object = request
        .as_object()
        .ok_or_else(|| workflow_state_invalid("reducer request must be an object"))?;
    if object.get("operation").and_then(serde_json::Value::as_str) == Some("transition")
        && object
            .get("run")
            .and_then(serde_json::Value::as_object)
            .and_then(|run| run.get("schema_version"))
            .and_then(serde_json::Value::as_u64)
            == Some(1)
    {
        return Err(invalid_data("workflow_state_migration_required"));
    }

    let schema_version = object
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| workflow_state_invalid("missing reducer schema_version"))?;
    let operation = match object.get("operation").and_then(serde_json::Value::as_str) {
        Some("bootstrap") => ReducerOperation::Bootstrap,
        Some("transition") => ReducerOperation::Transition,
        _ => return Err(workflow_state_invalid("unknown reducer operation")),
    };
    validate_reducer_request_schema(schema_version)?;

    let run = match operation {
        ReducerOperation::Bootstrap => {
            let request: BootstrapRequest = parse_reducer_value(request)?;
            if request.operation != ReducerOperation::Bootstrap {
                return Err(workflow_state_invalid("bootstrap operation changed"));
            }
            validate_reducer_request_schema(request.schema_version)?;
            bootstrap_workflow_run(request.plan, request.identity)?
        }
        ReducerOperation::Transition => {
            let request: TransitionRequest = parse_reducer_value(request)?;
            if request.operation != ReducerOperation::Transition {
                return Err(workflow_state_invalid("transition operation changed"));
            }
            validate_reducer_request_schema(request.schema_version)?;
            transition_workflow_run(request.run, request.event, request.durable_proofs)?
        }
    };
    validate_serialized_workflow_state_bytes(&run)?;
    serde_json::to_value(run).map_err(|error| {
        workflow_state_invalid(format!("failed to serialize reducer output: {error}"))
    })
}

pub fn run_workflow_state_reduce_command(args: &[&String]) -> io::Result<()> {
    if args.len() != 2 || args[0].as_str() != "--request-file" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "workflow state reducer requires --request-file <path>",
        ));
    }
    let bytes = fs::read(args[1])?;
    if bytes.len() > MAX_WORKFLOW_STATE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "workflow state reducer request exceeds 1048576 bytes",
        ));
    }
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) || bytes.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "workflow state reducer request must be BOM-free UTF-8 without NUL",
        ));
    }
    let request = serde_json::from_slice(&bytes).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("workflow state reducer request is invalid JSON: {error}"),
        )
    })?;
    let snapshot = reduce_workflow_state_value(&request)?;
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, &snapshot).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize workflow state reducer output: {error}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}

fn parse_reducer_value<T: for<'de> Deserialize<'de>>(value: &serde_json::Value) -> io::Result<T> {
    serde_json::from_value(value.clone())
        .map_err(|error| workflow_state_invalid(format!("invalid reducer schema: {error}")))
}

fn validate_reducer_request_schema(schema_version: u64) -> io::Result<()> {
    if schema_version != REDUCER_REQUEST_SCHEMA_VERSION {
        return Err(workflow_state_invalid("unsupported reducer schema_version"));
    }
    Ok(())
}

fn bootstrap_workflow_run(
    plan: NormalizedWorkflowPlan,
    identity: WorkflowRunIdentity,
) -> io::Result<WorkflowRun> {
    validate_workflow_run_identity(&identity)?;
    validate_normalized_workflow_plan(&plan, &identity.run_id)?;

    let node_order = plan
        .nodes
        .iter()
        .map(|node| node.node_id.clone())
        .collect::<Vec<_>>();
    let nodes = plan
        .nodes
        .iter()
        .map(|node| {
            let state = if node.depends_on.is_empty() {
                NodeState::Ready
            } else {
                NodeState::Pending
            };
            (
                node.node_id.clone(),
                WorkflowRuntimeNode {
                    node_id: node.node_id.clone(),
                    state,
                    attempt: 0,
                    idempotency_key: node.idempotency_key.clone(),
                    pane_ref: node.pane_ref.clone(),
                    action: node.action,
                    depends_on: node.depends_on.clone(),
                    cleanup: node.cleanup.clone(),
                    context_pack_ref: node.context_pack_ref.clone(),
                    evidence_refs: Vec::new(),
                    agent_cli_session_id: None,
                    completion_proof: None,
                },
            )
        })
        .collect::<BTreeMap<_, _>>();
    let run_id = identity.run_id.clone();
    let mut run = WorkflowRun {
        schema_version: WORKFLOW_RUN_SCHEMA_VERSION,
        workflow_id: plan.workflow_id.clone(),
        recipe_ref: plan.recipe_ref.clone(),
        run_id: identity.run_id,
        state: RunState::Planned,
        generation_id: identity.generation_id,
        config_fingerprint: identity.config_fingerprint,
        workflow_fingerprint: plan.workflow_fingerprint.clone(),
        source_head: identity.source_head,
        task_sha256: identity.task_sha256,
        task_byte_count: identity.task_byte_count,
        resolved_bindings: plan.resolved_bindings.clone(),
        normalized_snapshot: plan,
        node_order,
        nodes,
        cleanup_journal: vec![CleanupActionRecord {
            action_id: "release-run-lock".to_string(),
            kind: "release-run-lock".to_string(),
            state: CleanupActionState::Pending,
            idempotency_key: format!("{run_id}:cleanup:release-run-lock"),
            resource_ref: format!("workflow-run-lock:{run_id}"),
        }],
        cleanup_preserve_run_state: None,
        cancellation_proof: None,
        rollback_state: RollbackState::NotRequested,
    };
    recalculate_run_state(&mut run)?;
    validate_workflow_run(&run, &DurableProofs::default())?;
    Ok(run)
}

fn transition_workflow_run(
    mut run: WorkflowRun,
    event: WorkflowEvent,
    mut durable_proofs: DurableProofs,
) -> io::Result<WorkflowRun> {
    match &event {
        WorkflowEvent::Acknowledge {
            acknowledgement, ..
        } => durable_proofs
            .completion_acknowledgements
            .push(acknowledgement.clone()),
        WorkflowEvent::Cancel { cancellation } => durable_proofs
            .cancellation_proofs
            .push(cancellation.clone()),
        _ => {}
    }
    let durable_proofs = normalize_durable_proofs(&run, durable_proofs)?;
    validate_workflow_run(&run, &durable_proofs)?;
    match event {
        WorkflowEvent::Validate => return Ok(run),
        WorkflowEvent::DispatchIntent { node_id } => {
            if !matches!(run.state, RunState::Ready | RunState::Running) {
                return Err(workflow_state_invalid(
                    "terminal or blocked run cannot dispatch a node",
                ));
            }
            require_stable_id("node_id", &node_id)?;
            let node = run
                .nodes
                .get_mut(&node_id)
                .ok_or_else(|| workflow_state_invalid("unknown workflow node"))?;
            if node.state != NodeState::Ready || node.attempt != 0 {
                return Err(workflow_state_invalid(
                    "dispatch intent requires a pristine ready node",
                ));
            }
            node.state = NodeState::Dispatching;
            node.attempt = 1;
        }
        WorkflowEvent::Acknowledge {
            node_id,
            acknowledgement,
            resolved_session_id,
        } => {
            require_stable_id("node_id", &node_id)?;
            validate_session_id(&resolved_session_id)?;
            let node = run
                .nodes
                .get(&node_id)
                .ok_or_else(|| workflow_state_invalid("unknown workflow node"))?;
            validate_completion_proof(&run, node, &acknowledgement)?;
            if acknowledgement.pane_id != resolved_session_id {
                return Err(workflow_state_invalid(
                    "resolved session does not match acknowledgement pane",
                ));
            }
            if node.state == NodeState::Succeeded {
                if node.completion_proof.as_ref() == Some(&acknowledgement)
                    && node.agent_cli_session_id.as_deref() == Some(resolved_session_id.as_str())
                {
                    return Ok(run);
                }
                return Err(workflow_state_invalid(
                    "succeeded node acknowledgement replay is not identical",
                ));
            }
            if !matches!(run.state, RunState::Running | RunState::Blocked) {
                return Err(workflow_state_invalid(
                    "terminal run cannot accept a new acknowledgement",
                ));
            }
            if !matches!(node.state, NodeState::Dispatching | NodeState::Blocked)
                || node.attempt != 1
            {
                return Err(workflow_state_invalid(
                    "acknowledgement requires a dispatched or blocked node",
                ));
            }
            let evidence_ref = acknowledgement.evidence_ref.clone();
            let node = run
                .nodes
                .get_mut(&node_id)
                .expect("workflow node existence was validated");
            node.state = NodeState::Succeeded;
            node.agent_cli_session_id = Some(resolved_session_id);
            node.evidence_refs = vec![evidence_ref];
            node.completion_proof = Some(acknowledgement);
            release_proof_ready_nodes(&mut run)?;
        }
        WorkflowEvent::Block { node_id } => {
            if run.state != RunState::Running {
                return Err(workflow_state_invalid(
                    "terminal or blocked run cannot block another node",
                ));
            }
            require_stable_id("node_id", &node_id)?;
            let node = run
                .nodes
                .get_mut(&node_id)
                .ok_or_else(|| workflow_state_invalid("unknown workflow node"))?;
            if node.state != NodeState::Dispatching || node.attempt != 1 {
                return Err(workflow_state_invalid("block requires a dispatching node"));
            }
            node.state = NodeState::Blocked;
        }
        WorkflowEvent::DispatchFailed { node_id } => {
            if run.state != RunState::Running {
                return Err(workflow_state_invalid(
                    "terminal or blocked run cannot fail another node",
                ));
            }
            require_stable_id("node_id", &node_id)?;
            let node = run
                .nodes
                .get_mut(&node_id)
                .ok_or_else(|| workflow_state_invalid("unknown workflow node"))?;
            if node.state != NodeState::Dispatching || node.attempt != 1 {
                return Err(workflow_state_invalid(
                    "dispatch failure requires a dispatching node",
                ));
            }
            node.state = NodeState::Failed;
        }
        WorkflowEvent::CleanupIntent { preserve_run_state } => {
            begin_cleanup(&mut run, preserve_run_state)?;
        }
        WorkflowEvent::CleanupBlocked => {
            let action = cleanup_action_mut(&mut run)?;
            if !matches!(
                action.state,
                CleanupActionState::Pending | CleanupActionState::Running
            ) {
                return Err(workflow_state_invalid(
                    "cleanup blocked requires a pending or running cleanup action",
                ));
            }
            action.state = CleanupActionState::Blocked;
        }
        WorkflowEvent::CleanupSucceeded => {
            let action = cleanup_action_mut(&mut run)?;
            if action.state != CleanupActionState::Running {
                return Err(workflow_state_invalid(
                    "cleanup success requires a running cleanup action",
                ));
            }
            action.state = CleanupActionState::Succeeded;
        }
        WorkflowEvent::Cancel { cancellation } => {
            validate_cancellation_proof(&run, &cancellation)?;
            if run.cancellation_proof.as_ref() == Some(&cancellation) {
                return Ok(run);
            }
            if !matches!(
                run.state,
                RunState::Planned | RunState::Ready | RunState::Running | RunState::Blocked
            ) || run.cleanup_journal[0].state != CleanupActionState::Pending
                || run.cleanup_preserve_run_state.is_some()
            {
                return Err(workflow_state_invalid(
                    "terminal or cleaning workflow run cannot be cancelled",
                ));
            }
            run.cancellation_proof = Some(cancellation);
        }
    }
    recalculate_run_state(&mut run)?;
    validate_workflow_run(&run, &durable_proofs)?;
    Ok(run)
}

fn begin_cleanup(
    run: &mut WorkflowRun,
    preserve_run_state: Option<PreservedRunState>,
) -> io::Result<()> {
    let base_state = derive_outcome_run_state(run)?;
    match preserve_run_state {
        Some(preserved) if RunState::from(preserved) != base_state => {
            return Err(workflow_state_invalid(
                "cleanup preserve state does not match the proof-derived run state",
            ));
        }
        None if base_state != RunState::Succeeded => {
            return Err(workflow_state_invalid(
                "cleanup without a preserved terminal requires succeeded nodes",
            ));
        }
        _ => {}
    }
    let action = cleanup_action_mut(run)?;
    if action.state != CleanupActionState::Pending {
        return Err(workflow_state_invalid(
            "cleanup intent requires a pending cleanup action",
        ));
    }
    action.state = CleanupActionState::Running;
    run.cleanup_preserve_run_state = preserve_run_state;
    Ok(())
}

fn cleanup_action_mut(run: &mut WorkflowRun) -> io::Result<&mut CleanupActionRecord> {
    if run.cleanup_journal.len() != 1 {
        return Err(workflow_state_invalid(
            "cleanup journal must contain exactly one action",
        ));
    }
    Ok(&mut run.cleanup_journal[0])
}

fn validate_workflow_run_identity(identity: &WorkflowRunIdentity) -> io::Result<()> {
    require_workflow_run_id("run_id", &identity.run_id)?;
    require_generation_id("generation_id", &identity.generation_id)?;
    validate_digest("config_fingerprint", &identity.config_fingerprint)?;
    validate_digest("task_sha256", &identity.task_sha256)?;
    validate_source_head(&identity.source_head)
}

fn validate_normalized_workflow_plan(
    plan: &NormalizedWorkflowPlan,
    run_id: &str,
) -> io::Result<()> {
    if plan.schema_version != WORKFLOW_SCHEMA_VERSION {
        return Err(workflow_state_invalid(
            "normalized workflow schema_version is unsupported",
        ));
    }
    require_stable_id("workflow_id", &plan.workflow_id)?;
    require_stable_id("recipe_ref", &plan.recipe_ref)?;
    require_workflow_run_id("run_id", run_id)?;
    validate_digest("workflow_fingerprint", &plan.workflow_fingerprint)?;
    if plan.task_input.source != "runtime-task-file" || plan.task_input.privacy != "digest-only" {
        return Err(workflow_state_invalid(
            "normalized workflow task input contract is invalid",
        ));
    }
    if plan.resume_policy.mode != "operator-confirmed" || !plan.resume_policy.reject_completed_runs
    {
        return Err(workflow_state_invalid(
            "normalized workflow resume policy is invalid",
        ));
    }
    if plan.cleanup_policy.mode != "compensating-actions"
        || plan.cleanup_policy.on
            != vec![
                "cancel".to_string(),
                "failure".to_string(),
                "success".to_string(),
            ]
        || plan.cleanup_policy.actions != vec!["release-run-lock".to_string()]
    {
        return Err(workflow_state_invalid(
            "normalized workflow cleanup policy is invalid",
        ));
    }
    for (pane_ref, binding_label) in &plan.resolved_bindings {
        require_stable_id("pane_ref", pane_ref)?;
        require_stable_id("binding_label", binding_label)?;
    }
    if plan.nodes.is_empty() {
        return Err(workflow_state_invalid(
            "normalized workflow must contain at least one node",
        ));
    }

    let mut by_id = BTreeMap::new();
    for node in &plan.nodes {
        require_stable_id("node_id", &node.node_id)?;
        require_stable_id("pane_ref", &node.pane_ref)?;
        if !plan.resolved_bindings.contains_key(&node.pane_ref) {
            return Err(workflow_state_invalid(
                "normalized workflow node references an unknown pane",
            ));
        }
        if node.cleanup != "retain" {
            return Err(workflow_state_invalid(
                "normalized workflow node cleanup is invalid",
            ));
        }
        let expected_idempotency_key = format!("{run_id}:{}", node.node_id);
        require_workflow_idempotency_key(&expected_idempotency_key)?;
        if node.idempotency_key != expected_idempotency_key {
            return Err(workflow_state_invalid(
                "normalized workflow node idempotency key is invalid",
            ));
        }
        let dependencies = node.depends_on.iter().cloned().collect::<BTreeSet<_>>();
        if dependencies.len() != node.depends_on.len()
            || dependencies.iter().cloned().collect::<Vec<_>>() != node.depends_on
            || dependencies.contains(&node.node_id)
        {
            return Err(workflow_state_invalid(
                "normalized workflow dependencies are not canonical",
            ));
        }
        for dependency in &node.depends_on {
            require_stable_id("dependency node_id", dependency)?;
        }
        match node.action {
            WorkflowAction::OperatorDispatch if node.context_pack_ref.is_some() => {
                return Err(workflow_state_invalid(
                    "operator dispatch node must not have a context pack",
                ));
            }
            WorkflowAction::Verification => {
                if node.depends_on.is_empty() {
                    return Err(workflow_state_invalid(
                        "verification node requires a producer dependency",
                    ));
                }
                let context_ref = node.context_pack_ref.as_deref().ok_or_else(|| {
                    workflow_state_invalid("verification node requires a context pack")
                })?;
                require_stable_id("context_pack_ref", context_ref)?;
            }
            WorkflowAction::OperatorDispatch => {}
        }
        if by_id.insert(node.node_id.clone(), node).is_some() {
            return Err(workflow_state_invalid(
                "normalized workflow contains duplicate nodes",
            ));
        }
    }
    for node in &plan.nodes {
        for dependency in &node.depends_on {
            if !by_id.contains_key(dependency) {
                return Err(workflow_state_invalid(
                    "normalized workflow dependency is missing",
                ));
            }
        }
        if node.action == WorkflowAction::Verification {
            let producer_labels = node
                .depends_on
                .iter()
                .map(|dependency| {
                    let producer = by_id[dependency];
                    &plan.resolved_bindings[&producer.pane_ref]
                })
                .collect::<BTreeSet<_>>();
            if producer_labels.len() != 1 {
                return Err(workflow_state_invalid(
                    "verification dependencies do not resolve to one producer binding label",
                ));
            }
        }
    }
    let canonical_order = canonical_normalized_topological_order(&by_id)?;
    let actual_order = plan
        .nodes
        .iter()
        .map(|node| node.node_id.clone())
        .collect::<Vec<_>>();
    if actual_order != canonical_order {
        return Err(workflow_state_invalid(
            "normalized workflow node order is not canonical",
        ));
    }

    let payload = FingerprintPayload {
        schema_version: plan.schema_version,
        workflow_id: &plan.workflow_id,
        recipe_ref: &plan.recipe_ref,
        task_input: &plan.task_input,
        resolved_bindings: &plan.resolved_bindings,
        nodes: &plan.nodes,
        resume_policy: &plan.resume_policy,
        cleanup_policy: &plan.cleanup_policy,
    };
    let fingerprint_bytes = serde_json::to_vec(&payload).map_err(|error| {
        workflow_state_invalid(format!("failed to serialize workflow fingerprint: {error}"))
    })?;
    let expected_fingerprint = format!("sha256:{:x}", Sha256::digest(fingerprint_bytes));
    if plan.workflow_fingerprint != expected_fingerprint {
        return Err(workflow_state_invalid(
            "normalized workflow fingerprint does not match its content",
        ));
    }
    Ok(())
}

fn canonical_normalized_topological_order(
    nodes: &BTreeMap<String, &NormalizedWorkflowNode>,
) -> io::Result<Vec<String>> {
    let mut remaining = nodes
        .iter()
        .map(|(node_id, node)| {
            (
                node_id.clone(),
                node.depends_on.iter().cloned().collect::<BTreeSet<_>>(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut completed = BTreeSet::new();
    let mut order = Vec::with_capacity(nodes.len());
    while !remaining.is_empty() {
        let ready = remaining
            .iter()
            .filter(|(_, dependencies)| dependencies.is_subset(&completed))
            .map(|(node_id, _)| node_id.clone())
            .next();
        let Some(node_id) = ready else {
            return Err(workflow_state_invalid(
                "normalized workflow dependency graph contains a cycle",
            ));
        };
        remaining.remove(&node_id);
        completed.insert(node_id.clone());
        order.push(node_id);
    }
    Ok(order)
}

fn normalize_durable_proofs(run: &WorkflowRun, proofs: DurableProofs) -> io::Result<DurableProofs> {
    let mut completion_by_key = BTreeMap::new();
    for proof in proofs.completion_acknowledgements {
        if proof.run_id != run.run_id {
            return Err(workflow_state_invalid(
                "durable completion proof belongs to another run",
            ));
        }
        let node = run.nodes.get(&proof.node_id).ok_or_else(|| {
            workflow_state_invalid("durable completion proof names an unknown node")
        })?;
        validate_completion_proof(run, node, &proof)?;
        let key = format!(
            "{}\0{}\0{}",
            proof.run_id, proof.node_id, proof.idempotency_key
        );
        if let Some(existing) = completion_by_key.get(&key) {
            if existing != &proof {
                return Err(workflow_state_invalid(
                    "conflicting durable completion proofs share one semantic identity",
                ));
            }
        } else {
            completion_by_key.insert(key, proof);
        }
    }

    let mut cancellation_by_key = BTreeMap::new();
    for proof in proofs.cancellation_proofs {
        validate_cancellation_proof(run, &proof)?;
        let key = format!("{}\0{}", proof.run_id, proof.idempotency_key);
        if let Some(existing) = cancellation_by_key.get(&key) {
            if existing != &proof {
                return Err(workflow_state_invalid(
                    "conflicting durable cancellation proofs share one semantic identity",
                ));
            }
        } else {
            cancellation_by_key.insert(key, proof);
        }
    }
    if cancellation_by_key.len() > 1 {
        return Err(workflow_state_invalid(
            "workflow run has ambiguous durable cancellation proofs",
        ));
    }
    Ok(DurableProofs {
        completion_acknowledgements: completion_by_key.into_values().collect(),
        cancellation_proofs: cancellation_by_key.into_values().collect(),
    })
}

fn validate_workflow_run(run: &WorkflowRun, durable_proofs: &DurableProofs) -> io::Result<()> {
    if run.schema_version != WORKFLOW_RUN_SCHEMA_VERSION {
        return Err(if run.schema_version == 1 {
            invalid_data("workflow_state_migration_required")
        } else {
            workflow_state_invalid("unsupported workflow run schema_version")
        });
    }
    let identity = WorkflowRunIdentity {
        run_id: run.run_id.clone(),
        generation_id: run.generation_id.clone(),
        config_fingerprint: run.config_fingerprint.clone(),
        source_head: run.source_head.clone(),
        task_sha256: run.task_sha256.clone(),
        task_byte_count: run.task_byte_count,
    };
    validate_workflow_run_identity(&identity)?;
    validate_normalized_workflow_plan(&run.normalized_snapshot, &run.run_id)?;
    if run.workflow_id != run.normalized_snapshot.workflow_id
        || run.recipe_ref != run.normalized_snapshot.recipe_ref
        || run.workflow_fingerprint != run.normalized_snapshot.workflow_fingerprint
        || run.resolved_bindings != run.normalized_snapshot.resolved_bindings
    {
        return Err(workflow_state_invalid(
            "workflow run identity does not match its normalized snapshot",
        ));
    }
    let expected_order = run
        .normalized_snapshot
        .nodes
        .iter()
        .map(|node| node.node_id.clone())
        .collect::<Vec<_>>();
    if run.node_order != expected_order || run.nodes.len() != expected_order.len() {
        return Err(workflow_state_invalid(
            "workflow run node projection does not match its normalized snapshot",
        ));
    }
    for definition in &run.normalized_snapshot.nodes {
        let node = run
            .nodes
            .get(&definition.node_id)
            .ok_or_else(|| workflow_state_invalid("workflow run is missing a normalized node"))?;
        if node.node_id != definition.node_id
            || node.action != definition.action
            || node.pane_ref != definition.pane_ref
            || node.depends_on != definition.depends_on
            || node.idempotency_key != definition.idempotency_key
            || node.cleanup != definition.cleanup
            || node.context_pack_ref != definition.context_pack_ref
        {
            return Err(workflow_state_invalid(
                "workflow run immutable node projection changed",
            ));
        }
        validate_runtime_node_tuple(run, node, durable_proofs)?;
    }
    validate_external_cancellation_proof(run, durable_proofs)?;
    validate_cleanup_journal(run)?;
    let expected_state = derive_run_state(run)?;
    if run.state != expected_state {
        return Err(workflow_state_invalid(
            "workflow run state is not proof-derived",
        ));
    }
    Ok(())
}

fn validate_runtime_node_tuple(
    run: &WorkflowRun,
    node: &WorkflowRuntimeNode,
    durable_proofs: &DurableProofs,
) -> io::Result<()> {
    let dependencies_proven = node.depends_on.iter().all(|dependency| {
        run.nodes
            .get(dependency)
            .map(|node| node.state == NodeState::Succeeded && node.completion_proof.is_some())
            .unwrap_or(false)
    });
    let empty_outcome = node.agent_cli_session_id.is_none()
        && node.evidence_refs.is_empty()
        && node.completion_proof.is_none();
    match node.state {
        NodeState::Pending
            if node.attempt == 0
                && empty_outcome
                && !node.depends_on.is_empty()
                && !dependencies_proven => {}
        NodeState::Ready if node.attempt == 0 && empty_outcome && dependencies_proven => {}
        NodeState::Dispatching | NodeState::Blocked | NodeState::Failed
            if node.attempt == 1 && empty_outcome && dependencies_proven => {}
        NodeState::Succeeded if node.attempt == 1 => {
            let proof = node.completion_proof.as_ref().ok_or_else(|| {
                workflow_state_invalid("succeeded node is missing a completion proof")
            })?;
            validate_completion_proof(run, node, proof)?;
            let session = node.agent_cli_session_id.as_deref().ok_or_else(|| {
                workflow_state_invalid("succeeded node is missing its agent session")
            })?;
            validate_session_id(session)?;
            if session != proof.pane_id
                || node.evidence_refs != vec![proof.evidence_ref.clone()]
                || !dependencies_proven
            {
                return Err(workflow_state_invalid(
                    "succeeded node outcome tuple does not match its proof",
                ));
            }
            let external = durable_proofs
                .completion_acknowledgements
                .iter()
                .filter(|candidate| {
                    candidate.run_id == run.run_id
                        && candidate.node_id == node.node_id
                        && candidate.idempotency_key == node.idempotency_key
                })
                .collect::<Vec<_>>();
            if external.len() != 1 || external[0] != proof {
                return Err(workflow_state_invalid(
                    "succeeded node requires exactly one matching external durable proof",
                ));
            }
        }
        _ => {
            return Err(workflow_state_invalid(
                "workflow node state tuple is invalid",
            ));
        }
    }
    Ok(())
}

fn validate_completion_proof(
    run: &WorkflowRun,
    node: &WorkflowRuntimeNode,
    proof: &WorkflowCompletionProof,
) -> io::Result<()> {
    if proof.schema_version != 1
        || proof.run_id != run.run_id
        || proof.node_id != node.node_id
        || proof.idempotency_key != node.idempotency_key
        || proof.generation_id != run.generation_id
        || proof.config_fingerprint != run.config_fingerprint
        || proof.workflow_fingerprint != run.workflow_fingerprint
        || proof.source_head != run.source_head
        || proof.status != AcknowledgementStatus::Succeeded
        || proof.evidence_ref != format!("workflow-ack:{}:{}", run.run_id, node.node_id)
    {
        return Err(workflow_state_invalid(
            "workflow acknowledgement identity does not match the run and node",
        ));
    }
    validate_session_id(&proof.pane_id)?;
    if proof
        .transport
        .as_deref()
        .is_some_and(|value| value != "mailbox")
    {
        return Err(workflow_state_invalid(
            "workflow acknowledgement transport is invalid",
        ));
    }
    if let Some(message_id) = &proof.message_id {
        validate_message_id(message_id)?;
    }
    Ok(())
}

fn validate_cancellation_proof(
    run: &WorkflowRun,
    proof: &WorkflowCancellationProof,
) -> io::Result<()> {
    if proof.schema_version != 1
        || proof.run_id != run.run_id
        || proof.idempotency_key != format!("{}:cancel", run.run_id)
        || proof.generation_id != run.generation_id
        || proof.config_fingerprint != run.config_fingerprint
        || proof.workflow_fingerprint != run.workflow_fingerprint
        || proof.source_head != run.source_head
        || proof.status != CancellationStatus::Cancelled
        || proof.evidence_ref != format!("workflow-cancel:{}", run.run_id)
    {
        return Err(workflow_state_invalid(
            "workflow cancellation proof identity does not match the run",
        ));
    }
    Ok(())
}

fn validate_external_cancellation_proof(
    run: &WorkflowRun,
    durable_proofs: &DurableProofs,
) -> io::Result<()> {
    match &run.cancellation_proof {
        Some(embedded) => {
            validate_cancellation_proof(run, embedded)?;
            if durable_proofs.cancellation_proofs.len() != 1
                || durable_proofs.cancellation_proofs.first() != Some(embedded)
            {
                return Err(workflow_state_invalid(
                    "cancelled run requires exactly one matching external durable proof",
                ));
            }
        }
        None => {}
    }
    Ok(())
}

fn release_proof_ready_nodes(run: &mut WorkflowRun) -> io::Result<()> {
    for node_id in run.node_order.clone() {
        let should_release = {
            let node = run
                .nodes
                .get(&node_id)
                .ok_or_else(|| workflow_state_invalid("workflow node order is invalid"))?;
            node.state == NodeState::Pending
                && node.depends_on.iter().all(|dependency| {
                    run.nodes
                        .get(dependency)
                        .map(|dependency| {
                            dependency.state == NodeState::Succeeded
                                && dependency.completion_proof.is_some()
                        })
                        .unwrap_or(false)
                })
        };
        if should_release {
            run.nodes
                .get_mut(&node_id)
                .expect("workflow node order was validated")
                .state = NodeState::Ready;
        }
    }
    Ok(())
}

fn validate_cleanup_journal(run: &WorkflowRun) -> io::Result<()> {
    if run.cleanup_journal.len() != 1 {
        return Err(workflow_state_invalid(
            "cleanup journal must contain exactly one action",
        ));
    }
    let action = &run.cleanup_journal[0];
    if action.action_id != "release-run-lock"
        || action.kind != "release-run-lock"
        || action.idempotency_key != format!("{}:cleanup:release-run-lock", run.run_id)
        || action.resource_ref != format!("workflow-run-lock:{}", run.run_id)
    {
        return Err(workflow_state_invalid(
            "cleanup journal action identity is invalid",
        ));
    }
    let node_state = derive_outcome_run_state(run)?;
    match (action.state, run.cleanup_preserve_run_state) {
        (CleanupActionState::Pending, Some(_)) => {
            return Err(workflow_state_invalid(
                "pending cleanup must not preserve a run state",
            ));
        }
        (CleanupActionState::Pending, None) => {}
        (_, Some(preserved)) if RunState::from(preserved) == node_state => {}
        (_, None) if node_state == RunState::Succeeded => {}
        _ => {
            return Err(workflow_state_invalid(
                "cleanup state is not supported by proof-derived node outcomes",
            ));
        }
    }
    Ok(())
}

fn recalculate_run_state(run: &mut WorkflowRun) -> io::Result<()> {
    run.state = derive_run_state(run)?;
    Ok(())
}

fn derive_run_state(run: &WorkflowRun) -> io::Result<RunState> {
    let node_state = derive_outcome_run_state(run)?;
    let cleanup = run
        .cleanup_journal
        .first()
        .ok_or_else(|| workflow_state_invalid("cleanup journal is missing"))?;
    let preserved = run.cleanup_preserve_run_state.map(RunState::from);
    Ok(match cleanup.state {
        CleanupActionState::Pending => node_state,
        CleanupActionState::Running => preserved.unwrap_or(RunState::CleanupPending),
        CleanupActionState::Blocked => preserved.unwrap_or(RunState::Blocked),
        CleanupActionState::Succeeded => preserved.unwrap_or(RunState::Succeeded),
    })
}

fn derive_outcome_run_state(run: &WorkflowRun) -> io::Result<RunState> {
    if run.cancellation_proof.is_some() {
        Ok(RunState::Cancelled)
    } else {
        derive_node_run_state(run)
    }
}

fn derive_node_run_state(run: &WorkflowRun) -> io::Result<RunState> {
    if run.nodes.is_empty() {
        return Err(workflow_state_invalid("workflow run has no nodes"));
    }
    let states = run
        .nodes
        .values()
        .map(|node| node.state)
        .collect::<Vec<_>>();
    if states.contains(&NodeState::Failed) {
        return Ok(RunState::Failed);
    }
    if states.contains(&NodeState::Blocked) {
        return Ok(RunState::Blocked);
    }
    if states
        .iter()
        .any(|state| matches!(state, NodeState::Dispatching | NodeState::Running))
    {
        return Ok(RunState::Running);
    }
    if states.iter().all(|state| *state == NodeState::Succeeded) {
        return Ok(RunState::Succeeded);
    }
    let has_progress = run
        .nodes
        .values()
        .any(|node| node.attempt > 0 || node.state == NodeState::Succeeded);
    if states.contains(&NodeState::Ready) {
        return Ok(if has_progress {
            RunState::Running
        } else {
            RunState::Ready
        });
    }
    if states.iter().all(|state| *state == NodeState::Pending) {
        return Ok(if has_progress {
            RunState::Running
        } else {
            RunState::Planned
        });
    }
    Err(workflow_state_invalid(
        "workflow node states cannot derive a run state",
    ))
}

fn validate_digest(label: &str, value: &str) -> io::Result<()> {
    let Some(hex) = value.strip_prefix("sha256:") else {
        return Err(workflow_state_invalid(format!(
            "{label} is not a SHA-256 digest"
        )));
    };
    if hex.len() != 64
        || !hex
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(workflow_state_invalid(format!(
            "{label} is not a SHA-256 digest"
        )));
    }
    Ok(())
}

fn validate_source_head(value: &str) -> io::Result<()> {
    if value.len() != 40
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(workflow_state_invalid(
            "source_head is not a lowercase full commit ID",
        ));
    }
    Ok(())
}

fn validate_session_id(value: &str) -> io::Result<()> {
    if !value.starts_with('%')
        || value.len() < 2
        || !value[1..].bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(workflow_state_invalid("agent session ID is invalid"));
    }
    Ok(())
}

fn validate_message_id(value: &str) -> io::Result<()> {
    let bytes = value.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 128
        || !bytes[0].is_ascii_lowercase()
        || bytes
            .iter()
            .any(|byte| !(byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-'))
    {
        return Err(workflow_state_invalid(
            "workflow acknowledgement message_id is invalid",
        ));
    }
    Ok(())
}

fn workflow_state_invalid(message: impl Into<String>) -> io::Error {
    invalid_data(format!("workflow_state_invalid: {}", message.into()))
}

fn validate_serialized_workflow_state_bytes(run: &WorkflowRun) -> io::Result<()> {
    let byte_count = serde_json::to_vec(run)
        .map_err(|error| {
            workflow_state_invalid(format!("failed to serialize workflow state: {error}"))
        })?
        .len()
        .saturating_add(1);
    if byte_count > MAX_WORKFLOW_STATE_BYTES {
        return Err(workflow_state_invalid(format!(
            "workflow state exceeds {MAX_WORKFLOW_STATE_BYTES} UTF-8 bytes"
        )));
    }
    Ok(())
}

fn require_workflow_run_id(label: &str, value: &str) -> io::Result<()> {
    require_stable_id(label, value)?;
    if value.len() > MAX_WORKFLOW_RUN_ID_BYTES {
        return Err(invalid_data(format!(
            "{label} exceeds {MAX_WORKFLOW_RUN_ID_BYTES} ASCII bytes."
        )));
    }
    Ok(())
}

fn require_workflow_idempotency_key(value: &str) -> io::Result<()> {
    if !value.is_ascii() || value.len() > MAX_WORKFLOW_IDEMPOTENCY_KEY_BYTES {
        return Err(workflow_state_invalid(format!(
            "workflow node idempotency key exceeds {MAX_WORKFLOW_IDEMPOTENCY_KEY_BYTES} ASCII bytes"
        )));
    }
    Ok(())
}

fn require_stable_id(label: &str, value: &str) -> io::Result<()> {
    let bytes = value.as_bytes();
    if bytes.is_empty()
        || !bytes[0].is_ascii_lowercase()
        || bytes
            .iter()
            .any(|byte| !(byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-'))
        || value.ends_with('-')
        || value.contains("--")
    {
        return Err(invalid_data(format!(
            "{label} must be a stable lowercase ASCII identifier."
        )));
    }
    Ok(())
}

fn require_generation_id(label: &str, value: &str) -> io::Result<()> {
    let bytes = value.as_bytes();
    if bytes.len() == 32
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Ok(());
    }
    require_stable_id(label, value)
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
