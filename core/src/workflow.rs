use std::collections::{BTreeMap, BTreeSet};
use std::io;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::workspace_recipe::{parse_workspace_yaml, NormalizedWorkspacePlan};

const WORKFLOW_SCHEMA_VERSION: u64 = 1;
const RUN_ID_TOKEN: &str = "{{run-id}}";

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
        let workflow = normalize_workflow_plan_from_value(
            root,
            workflow_id,
            run_id,
            &plan.recipe_id,
            &plan.resolved_bindings,
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedTaskInput {
    pub source: String,
    pub privacy: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedWorkflowNode {
    pub node_id: String,
    pub pane_ref: String,
    pub action: String,
    pub depends_on: Vec<String>,
    pub idempotency_key: String,
    pub cleanup: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_pack_ref: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedResumePolicy {
    pub mode: String,
    pub reject_completed_runs: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
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
    action: String,
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
) -> io::Result<NormalizedWorkflowPlan> {
    let root = parse_workspace_yaml(yaml)?;
    normalize_workflow_plan_from_value(
        &root,
        workflow_id,
        run_id,
        selected_recipe_id,
        resolved_bindings,
    )
}

pub(crate) fn normalize_workflow_plan_from_value(
    root: &serde_yaml::Value,
    workflow_id: &str,
    run_id: &str,
    selected_recipe_id: &str,
    resolved_bindings: &BTreeMap<String, String>,
) -> io::Result<NormalizedWorkflowPlan> {
    require_stable_id("workflow-id", workflow_id)?;
    require_stable_id("run-id", run_id)?;
    require_stable_id("recipe-id", selected_recipe_id)?;
    for (pane_ref, slot_id) in resolved_bindings {
        require_stable_id("pane-ref", pane_ref)?;
        require_stable_id("slot-id", slot_id)?;
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
        if !matches!(node.action.as_str(), "operator-dispatch" | "verification") {
            return Err(invalid_data("unknown workflow node action."));
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
        if node.action == "verification" {
            let context_ref = node
                .context_pack_ref
                .as_deref()
                .ok_or_else(|| invalid_data("verification node requires context-pack-ref."))?;
            require_stable_id("context-pack-ref", context_ref)?;
        } else if node.context_pack_ref.is_some() {
            return Err(invalid_data(
                "operator-dispatch node must not set context-pack-ref.",
            ));
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
                action: node.action.clone(),
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

    Ok(NormalizedWorkflowPlan {
        schema_version: WORKFLOW_SCHEMA_VERSION,
        workflow_id: workflow_id.to_string(),
        recipe_ref: selected_recipe_id.to_string(),
        workflow_fingerprint: format!("sha256:{:x}", Sha256::digest(fingerprint_bytes)),
        task_input,
        resolved_bindings: resolved_bindings.clone(),
        nodes,
        resume_policy,
        cleanup_policy,
    })
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

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
